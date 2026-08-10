// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionRoute} from "../src/pools/PrecisionRoute.sol";
import {PriceTape} from "../src/pools/PriceTape.sol";
import {MockERC20} from "./SwapboardMocks.sol";

contract ExecStub {
    receive() external payable {}
}

/// @dev A hook that is cheap but present, so the clamp refusal is about the
/// hook existing rather than about it being expensive.
contract PresentHook {
    function feeFor(address, address, uint256) external pure returns (uint256) {
        return 1_000;
    }

    function afterSwap(address, address, uint256, uint256, address) external {}
}

/// @dev Findings from the PrecisionRoute and PriceTape audit passes.
contract PrecisionRouteAuditTest is Test {
    PrecisionPoolFactory factory;
    PrecisionRoute router;
    PrecisionPool pool;
    PrecisionPool hookedPool;
    MockERC20 tk;
    ExecStub execStub;
    address exec;

    address lp = address(0xC11);
    address user = address(0xBEEF);

    function setUp() public {
        execStub = new ExecStub();
        exec = address(execStub);
        factory = new PrecisionPoolFactory(exec, type(PrecisionPool).creationCode);
        router = new PrecisionRoute(factory, exec);
        tk = new MockERC20("TK", 18);
        tk.mint(lp, 1e30);
        vm.deal(lp, 100_000 ether);

        vm.startPrank(lp);
        tk.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 1_000 ether}(_mkt(address(0)), 1e18, 1_000 ether, 1e25, 0, lp);
        pool = PrecisionPool(payable(p));

        PresentHook h = new PresentHook();
        (address hp,,,) = factory.createAndSeed{value: 1_000 ether}(_mkt(address(h)), 1e18, 1_000 ether, 1e25, 0, lp);
        hookedPool = PrecisionPool(payable(hp));
        vm.stopPrank();
    }

    function _mkt(address hook) internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(tk),
            sqrtPLow: 0.5e18,
            sqrtPHigh: 2e18,
            fee: hook == address(0) ? 500 : 600,
            hook: hook,
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    /// @dev THE ABORT PATH. If a checkpoint is taken and funded but the
    /// settling call never comes - a branch not taken, a reordered multicall -
    /// the ERC-20 would otherwise stay in the route. Worse than unrecovered:
    /// the next checkpoint snapshots `balanceOf` INCLUDING it, so only the
    /// fresh delta is ever spendable and the residue sits outside every path.
    ///
    /// The destination is the one committed AT CHECKPOINT rather than passed
    /// here, which is the stronger construction: this function is reachable
    /// from inside the funding transfer by anything the token hands control to,
    /// so a caller-chosen recipient would be an easier theft than the
    /// settlement path the intent commitment exists to close.
    function test_AFundedCheckpointCanBeAbortedInsteadOfStranded() public {
        uint256 amount = 1e21;
        tk.mint(user, amount);

        vm.prank(exec);
        router.checkpoint(address(tk), keccak256("whatever"), user);

        vm.prank(user);
        tk.transfer(address(router), amount);
        assertEq(tk.balanceOf(address(router)), amount, "funding did not land");

        uint256 before = tk.balanceOf(user);
        vm.prank(exec);
        uint256 refunded = router.abortCheckpoint(address(tk));

        assertEq(refunded, amount, "wrong amount refunded");
        assertEq(tk.balanceOf(user) - before, amount, "funding was not returned");
        assertEq(tk.balanceOf(address(router)), 0, "route kept the funding");
    }

    /// @dev The abort returns funding only to the address committed at
    /// checkpoint, so it is not a redirection primitive even though anyone the
    /// token calls can trigger it.
    function test_AbortReturnsOnlyToTheCommittedRecipient() public {
        uint256 amount = 1e21;
        tk.mint(user, amount);

        vm.prank(exec);
        router.checkpoint(address(tk), keccak256("whatever"), user);
        vm.prank(user);
        tk.transfer(address(router), amount);

        uint256 badBefore = tk.balanceOf(address(0xBAD));
        uint256 userBefore = tk.balanceOf(user);
        vm.prank(exec);
        router.abortCheckpoint(address(tk));

        assertEq(tk.balanceOf(address(0xBAD)), badBefore, "funding reached an uncommitted address");
        assertEq(tk.balanceOf(user) - userBefore, amount, "committed recipient did not get it");
    }

    /// @dev A stranded balance from an earlier failure is never reachable by a
    /// later route: the next checkpoint bases on the raised balance, so only
    /// the fresh delta is spendable.
    function test_AStrandedBalanceIsNotSpendableByTheNextRoute() public {
        // Simulate an earlier route that funded and never settled or aborted.
        tk.mint(address(router), 7e20);

        uint256 amount = 1e21;
        tk.mint(user, amount);
        vm.prank(exec);
        router.checkpoint(address(tk), keccak256("whatever"), user);
        vm.prank(user);
        tk.transfer(address(router), amount);

        vm.prank(exec);
        uint256 refunded = router.abortCheckpoint(address(tk));
        assertEq(refunded, amount, "abort reached the stranded balance");
        assertEq(tk.balanceOf(address(router)), 7e20, "stranded balance was disturbed");
    }

    /// @dev A hooked pool in a CLAMPED route is refused. The search bisects up
    /// to ~256 times and every probe pays `HOOK_GAS` per hooked hop, so a few
    /// hooked hops exceed the block limit; and the search quotes against
    /// pre-route state while a hooked pool gets control in `afterSwap` between
    /// hops, so it can invalidate the very clamp that was computed.
    function test_RouteUpToRefusesAHookedPool() public {
        address[] memory pools = new address[](1);
        pools[0] = address(hookedPool);
        vm.deal(exec, 10 ether);

        vm.prank(exec);
        vm.expectRevert(PrecisionRoute.HookedNoClamp.selector);
        router.routeUpTo{value: 1 ether}(pools, address(0), address(tk), 1 ether, 0, user, user);
    }

    /// @dev But the EXACT path still takes them: it walks each hop once at a
    /// size the caller fixed, so neither the gas nor the staleness problem
    /// arises. Refusing hooks everywhere would have been the easy overreach.
    function test_ExactRouteStillAcceptsAHookedPool() public {
        address[] memory pools = new address[](1);
        pools[0] = address(hookedPool);
        vm.deal(exec, 10 ether);

        vm.prank(exec);
        uint256 out = router.route{value: 1 ether}(pools, address(0), address(tk), 1 ether, 0, user);
        assertGt(out, 0, "exact route through a hooked pool should still work");
    }

    /// @dev A non-pool in a clamped path now says `NoPool` rather than failing
    /// inside an ABI decode with no reason data.
    function test_RouteUpToNamesANonPoolInsteadOfFailingOpaquely() public {
        address[] memory pools = new address[](1);
        pools[0] = address(0xDEAD);
        vm.deal(exec, 10 ether);

        vm.prank(exec);
        vm.expectRevert(PrecisionRoute.NoPool.selector);
        router.routeUpTo{value: 1 ether}(pools, address(0), address(tk), 1 ether, 0, user, user);
    }

    /// @dev Swapping the entire input leaves nothing for the other side of the
    /// deposit, so the pool used to revert `ZeroAmount()` from two calls away.
    function test_ZapRefusesAFullPortionSwapWithAStatedReason() public {
        vm.deal(exec, 10 ether);
        vm.prank(exec);
        vm.expectRevert(PrecisionRoute.Bad.selector);
        router.zapIn{value: 1 ether}(address(pool), address(0), 1 ether, 1 ether, 0, user, user);
    }

    /// @dev THE DORMANT TAPE. A finished bar only reaches the ring when the
    /// NEXT trade finalises it, and `recent` matches buckets against the wall
    /// clock - so once trading stops and time advances past the live bar, it is
    /// in neither place. Past `BARS` periods its slot has been lapped, and no
    /// `count` recovers it.
    ///
    /// That defeats the one distinction the zero-encoding exists to preserve:
    /// "never traded" versus "traded, then went quiet".
    function test_ADormantPoolStillReportsItsLastBar() public {
        vm.deal(user, 100 ether);
        vm.prank(user);
        pool.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, user);

        // Go quiet for far longer than the ring is deep.
        vm.warp(block.timestamp + 400 * pool.FINE_PERIOD());

        uint256[] memory bars = pool.tape(pool.FINE_PERIOD(), 32);
        uint256 nonEmpty;
        for (uint256 i; i < bars.length; ++i) {
            if (bars[i] != 0) ++nonEmpty;
        }
        assertGt(nonEmpty, 0, "a dormant pool with real history reported nothing");

        (uint32 bucket,,,, uint256 close,,) = PriceTape.decode(bars[0]);
        assertGt(bucket, 0, "the recovered bar has no bucket");
        assertGt(close, 0, "the recovered bar has no price");
    }

    /// @dev `count` is bounded before allocation, so a reader cannot be made to
    /// blow memory on a view. Anything past the ring depth was always zeros.
    function test_TapeCountIsBoundedBeforeAllocating() public view {
        uint256[] memory bars = pool.tape(pool.FINE_PERIOD(), type(uint256).max);
        assertLe(bars.length, PriceTape.BARS, "count was not clamped");
    }
}
