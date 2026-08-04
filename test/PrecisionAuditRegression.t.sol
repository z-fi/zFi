// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Executor stand-in for the prefunded factory route. The real executor is
/// external and immutable, so these tests drive the factory through the same
/// three-step shape it would use - checkpoint, fund, settle - and probe the
/// intervals between the steps.
contract MockExecutor {
    PrecisionPoolFactory factory;

    function setFactory(PrecisionPoolFactory f) external {
        factory = f;
    }

    function _route(address token, uint256 amount, address pool, address originator, address to)
        internal
        pure
        returns (PrecisionPoolFactory.Route memory r)
    {
        r = PrecisionPoolFactory.Route({
            pool: pool,
            originator: originator,
            tokenIn: token,
            amountIn: amount,
            minOut: 0,
            to: to,
            refundTo: to
        });
    }

    function route(address token, uint256 amount, address pool, address payer, address to)
        external
        returns (uint256)
    {
        PrecisionPoolFactory.Route memory r = _route(token, amount, pool, payer, to);
        factory.checkpoint(r);
        MockERC20(token).transferFrom(payer, address(factory), amount);
        return factory.executePrefundedSwap(r);
    }

    /// @dev The cross-checkpoint shape H-03 describes: two live checkpoints at
    /// once, which is what makes a callback during funding able to redirect the
    /// other route.
    function openTwoRoutes(address tokenA, address tokenB) external {
        factory.checkpoint(_route(tokenA, 1, pool_, address(this), address(this)));
        factory.checkpoint(_route(tokenB, 1, pool_, address(this), address(this)));
    }

    /// @dev Fund the factory, then give up on settling and hand the funding back.
    function fundThenAbort(address token, uint256 amount, address payer, address to) external returns (uint256) {
        PrecisionPoolFactory.Route memory r = _route(token, amount, pool_, payer, to);
        factory.checkpoint(r);
        MockERC20(token).transferFrom(payer, address(factory), amount);
        return factory.abortCheckpoint(r);
    }

    /// @dev The H-01 shape: the route is funded for one settlement, and the
    /// call that consumes it names a different recipient. Stands in for a token
    /// callback re-entering a public executor while the route is open.
    function fundThenSettleElsewhere(address token, uint256 amount, address payer, address pool, address elsewhere)
        external
        returns (uint256)
    {
        factory.checkpoint(_route(token, amount, pool, payer, payer));
        MockERC20(token).transferFrom(payer, address(factory), amount);
        return factory.executePrefundedSwap(_route(token, amount, pool, payer, elsewhere));
    }

    /// @dev The same substitution through the abort path.
    function fundThenAbortElsewhere(address token, uint256 amount, address payer, address elsewhere)
        external
        returns (uint256)
    {
        factory.checkpoint(_route(token, amount, pool_, payer, payer));
        MockERC20(token).transferFrom(payer, address(factory), amount);
        return factory.abortCheckpoint(_route(token, amount, pool_, payer, elsewhere));
    }

    function settleWithoutCheckpoint(address pool, address token, uint256 amount, address to)
        external
        returns (uint256)
    {
        return factory.executePrefundedSwap(_route(token, amount, pool, msg.sender, to));
    }

    function abortWithoutRoute(address token, address to) external returns (uint256) {
        return factory.abortCheckpoint(_route(token, 1, pool_, address(this), to));
    }

    /// @dev A pool the mock routes through when the test does not name one.
    address public pool_;

    function setPool(address p) external {
        pool_ = p;
    }
}

/// @dev Regressions for the external audit of PrecisionPool and its factory.
/// Each test pins one finding: that a pool which cannot trade is refused rather
/// than created (H-01), that liquidity operations cannot strip a funded pool of
/// its last executable trade (H-02), that the prefunded route is locked across
/// the funding transfer and can always be unwound (H-03), and that a seed opens
/// at the price it was asked for (M-02).
contract PrecisionAuditRegressionTest is Test {
    PrecisionPoolFactory factory;
    MockExecutor executor;
    MockERC20 a;
    MockERC20 b;

    address lp = address(0x11);
    address trader = address(0x22);
    address attacker = address(0xBAD);

    function setUp() public {
        executor = new MockExecutor();
        factory = new PrecisionPoolFactory(address(executor), type(PrecisionPool).creationCode);
        executor.setFactory(factory);

        a = new MockERC20("A", 18);
        b = new MockERC20("B", 18);
        if (address(a) > address(b)) (a, b) = (b, a);

        address[3] memory who = [lp, trader, attacker];
        for (uint256 i; i < 3; ++i) {
            a.mint(who[i], 1e30);
            b.mint(who[i], 1e30);
            vm.startPrank(who[i]);
            a.approve(address(factory), type(uint256).max);
            b.approve(address(factory), type(uint256).max);
            a.approve(address(executor), type(uint256).max);
            b.approve(address(executor), type(uint256).max);
            vm.stopPrank();
        }

        // Every route commits to a pool, so the mock needs one even for the
        // paths that never reach a swap.
        executor.setPool(address(_seededWithFee(500)));
    }

    function _mkt(uint256 sl, uint256 sh, uint256 fee)
        internal
        view
        returns (PrecisionPoolFactory.Market memory)
    {
        return PrecisionPoolFactory.Market({
            token0: address(a),
            token1: address(b),
            sqrtPLow: sl,
            sqrtPHigh: sh,
            fee: fee,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    /// @dev Seed a healthy, materially funded pool.
    function _seeded() internal returns (PrecisionPool pool) {
        return _seededWithFee(3000);
    }

    /// @dev The fee only distinguishes markets so a test can have its own pool.
    function _seededWithFee(uint256 fee) internal returns (PrecisionPool pool) {
        vm.prank(lp);
        (address p,,,) = factory.createAndSeed(_mkt(1e18, 3e18, fee), 2e18, 1e24, 1e24, 0, lp);
        return PrecisionPool(payable(p));
    }

    /// @dev Whether a real swap of `amount` succeeds, without committing it.
    function _swapWorks(PrecisionPool pool, address tokenIn, uint256 amount) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        vm.startPrank(trader);
        MockERC20(tokenIn).approve(address(pool), type(uint256).max);
        try pool.swapExactIn(tokenIn, amount, 0, trader) returns (uint256 out) {
            ok = out != 0;
        } catch {
            ok = false;
        }
        vm.stopPrank();
        vm.revertToState(snap);
    }

    /// @dev At least one direction has an integer trade that actually executes.
    function _tradeable(PrecisionPool pool) internal returns (bool) {
        for (uint256 n = 1; n <= 1e21; n *= 10) {
            if (_swapWorks(pool, address(a), n)) return true;
            if (_swapWorks(pool, address(b), n)) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- H-01

    /// @dev The audit's material counterexample: a boundary seed whose entire
    /// token1 reserve is worth less than the smallest priceable token0 input.
    /// It passed the old one-unit fee-free predicate, minted shares, burned the
    /// permanent minimum, and then rejected every swap in both directions
    /// forever. It must be refused at creation instead.
    function test_InertBoundarySeedIsRefused() public {
        vm.prank(lp);
        vm.expectRevert(PrecisionPool.InsufficientLiquidity.selector);
        factory.createAndSeed(_mkt(5e29, 1e30, 1), 1e30, 0, 5e23, 0, lp);
    }

    /// @dev The zero-output variant: the one-unit quote rounds to zero, which
    /// the old `output <= reserve` test read as success.
    function test_ZeroOutputSeedIsRefused() public {
        vm.prank(lp);
        vm.expectRevert();
        factory.createAndSeed(_mkt(999900000000000000, 1e18, 0), 1e18, 0, 1, 0, lp);
    }

    /// @dev Whatever a seed is given, it either reverts or produces a pool with
    /// a trade that executes. There is no third outcome where the pool is
    /// created but permanently inert.
    function testFuzz_SeededPoolIsAlwaysTradeable(uint96 amt0, uint96 amt1, uint16 feePips) public {
        uint256 fee = uint256(feePips) % 100_000;
        vm.prank(lp);
        try factory.createAndSeed(_mkt(1e18, 3e18, fee), 2e18, amt0, amt1, 0, lp) returns (
            address p, uint256, uint256, uint256
        ) {
            assertTrue(_tradeable(PrecisionPool(payable(p))), "seeded pool has no executable trade");
        } catch {}
    }

    // ---------------------------------------------------------------- H-02

    /// @dev An LP burning a single share must not be able to take a funded,
    /// working pool into a state where no swap executes.
    function test_OneShareBurnCannotRemoveTheLastExecutableTrade() public {
        PrecisionPool pool = _seeded();
        assertTrue(_tradeable(pool), "pool starts dead");

        vm.prank(lp);
        pool.removeLiquidity(1, 0, 0, lp);

        assertTrue(_tradeable(pool), "one-share burn killed the pool");
    }

    /// @dev The burn/re-add liveness toggle: the cycle must not leave the pool
    /// dead at any point, and must not be free.
    function test_BurnAndReaddCannotTogglePoolLiveness() public {
        PrecisionPool pool = _seeded();
        vm.startPrank(lp);
        a.approve(address(pool), type(uint256).max);
        b.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        for (uint256 i; i < 4; ++i) {
            vm.prank(lp);
            (uint256 got0, uint256 got1) = pool.removeLiquidity(1, 0, 0, lp);
            assertTrue(_tradeable(pool), "burn phase killed the pool");

            // A proportional deposit needs both sides: a one-share burn can
            // return dust on one side and nothing on the other, and the pool
            // rightly refuses to mint against that.
            if (got0 == 0 || got1 == 0) continue;
            vm.prank(lp);
            pool.addLiquidityExact(0, got0, got1, 0, lp);
            assertTrue(_tradeable(pool), "re-add phase killed the pool");
        }
    }

    /// @dev A later proportional deposit is not automatically safe: it moves
    /// the floored virtual reserves by a different rounding than the real
    /// reserves it adds. A deposit into a working pool must leave it working.
    function testFuzz_ProportionalAddCannotRemoveTheLastExecutableTrade(uint96 add0, uint96 add1) public {
        PrecisionPool pool = _seeded();
        assertTrue(_tradeable(pool), "pool starts dead");

        vm.prank(lp);
        try pool.addLiquidityExact(0, add0, add1, 0, lp) {
            assertTrue(_tradeable(pool), "deposit removed the last executable trade");
        } catch {}
    }

    // ---------------------------------------------------------------- H-03

    /// @dev The factory must stay locked across the funding transfer, not just
    /// inside each call. Two live checkpoints are what let a callback during
    /// funding consume the other route.
    function test_CheckpointFundingExecutionIsAtomicallyLocked() public {
        vm.expectRevert(PrecisionPoolFactory.Reentrancy.selector);
        executor.openTwoRoutes(address(a), address(b));
    }

    /// @dev Reopening the same route while one is already in flight is refused.
    function test_SecondCheckpointOnSameTokenIsRefused() public {
        vm.expectRevert(PrecisionPoolFactory.Reentrancy.selector);
        executor.openTwoRoutes(address(a), address(a));
    }

    /// @dev Settlement requires a route this executor actually opened, so an
    /// unfunded call cannot spend whatever the factory happens to hold.
    function test_SettlementWithoutCheckpointIsRefused() public {
        PrecisionPool pool = _seeded();
        a.mint(address(factory), 1e21);

        vm.expectRevert(PrecisionPoolFactory.BadCheckpoint.selector);
        executor.settleWithoutCheckpoint(address(pool), address(a), 1e18, trader);
    }

    /// @dev The open route is bound to the settlement it was checkpointed for.
    /// Holding the lock is not enough on its own: the route is callable during
    /// the funding transfer, so a callback re-entering the executor could
    /// otherwise settle THIS route to a recipient of its choosing.
    function test_OpenRouteCannotBeSettledToAnotherRecipient() public {
        PrecisionPool pool = _seeded();
        uint256 before = a.balanceOf(attacker);

        vm.prank(trader);
        vm.expectRevert(PrecisionPoolFactory.IntentMismatch.selector);
        executor.fundThenSettleElsewhere(address(a), 1e18, trader, address(pool), attacker);

        assertEq(a.balanceOf(attacker), before, "settlement was redirected");
    }

    /// @dev The same substitution through the abort path, which would otherwise
    /// hand the funding straight to an address chosen at abort time.
    function test_OpenRouteCannotBeAbortedToAnotherRecipient() public {
        uint256 before = a.balanceOf(attacker);

        vm.prank(trader);
        vm.expectRevert(PrecisionPoolFactory.IntentMismatch.selector);
        executor.fundThenAbortElsewhere(address(a), 1e18, trader, attacker);

        assertEq(a.balanceOf(attacker), before, "abort refunded an uncommitted address");
    }

    /// @dev A route that funds the factory and then cannot settle must be able
    /// to hand the funding back, rather than stranding it with no authenticated
    /// recovery path.
    function test_FailedExecutorSettlementCannotStrandFunding() public {
        uint256 amount = 5e18;
        uint256 before = a.balanceOf(trader);

        vm.prank(trader);
        uint256 refunded = executor.fundThenAbort(address(a), amount, trader, trader);

        assertEq(refunded, amount, "refund did not match funding");
        assertEq(a.balanceOf(trader), before, "funding was stranded");
        assertEq(a.balanceOf(address(factory)), 0, "factory kept the funding");
    }

    /// @dev The refund is the route's own delta, so a pre-existing factory
    /// balance is not reachable through the abort path.
    function test_AbortRefundsOnlyItsOwnFunding() public {
        uint256 donation = 7e18;
        a.mint(address(factory), donation);

        uint256 amount = 5e18;
        vm.prank(trader);
        uint256 refunded = executor.fundThenAbort(address(a), amount, trader, trader);

        assertEq(refunded, amount, "abort refunded more than it funded");
        assertEq(a.balanceOf(address(factory)), donation, "abort consumed a pre-existing balance");
    }

    /// @dev Aborting with no route open is not a way to reach factory balances.
    function test_AbortWithoutOpenRouteIsRefused() public {
        a.mint(address(factory), 1e21);
        vm.expectRevert(PrecisionPoolFactory.BadCheckpoint.selector);
        executor.abortWithoutRoute(address(a), attacker);
    }

    /// @dev Only the trusted executor drives the route, including the new abort.
    function test_RouteEntryPointsAreExecutorOnly() public {
        PrecisionPoolFactory.Route memory r = PrecisionPoolFactory.Route({
            pool: executor.pool_(),
            originator: attacker,
            tokenIn: address(a),
            amountIn: 1e18,
            minOut: 0,
            to: attacker,
            refundTo: attacker
        });
        vm.startPrank(attacker);
        vm.expectRevert(PrecisionPoolFactory.NotExecutor.selector);
        factory.checkpoint(r);
        vm.expectRevert(PrecisionPoolFactory.NotExecutor.selector);
        factory.abortCheckpoint(r);
        vm.stopPrank();
    }

    /// @dev The happy path still works, and leaves the route closed so the next
    /// hop can open its own.
    function test_RoutedSwapStillSettlesAndClosesTheRoute() public {
        PrecisionPool pool = _seeded();

        vm.prank(trader);
        uint256 out = executor.route(address(a), 1e18, address(pool), trader, trader);
        assertGt(out, 0, "routed swap returned nothing");

        vm.prank(trader);
        uint256 out2 = executor.route(address(a), 1e18, address(pool), trader, trader);
        assertGt(out2, 0, "route did not reopen for the next hop");
    }

    // ------------------------------------------------------------ EIP-170

    /// @dev The factory holds the pool's creation code in a data contract
    /// rather than inline, which is what keeps it deployable at all. The blob
    /// it deploys from must therefore be exactly the compiled pool - a factory
    /// built over the wrong bytes would register non-pools in `isPool`, which
    /// the zap, the route and the policy all trust.
    function test_FactoryDeploysTheCompiledPoolCode() public view {
        bytes memory expected = type(PrecisionPool).creationCode;
        assertEq(factory.poolInitCodeHash(), keccak256(expected), "published hash is not the compiled pool");

        // SSTORE2 prefixes a STOP byte, so the stored code is the blob plus one.
        bytes memory stored = factory.poolCode().code;
        assertEq(stored.length, expected.length + 1, "stored blob is not the pool creation code");
        assertEq(keccak256(expected), keccak256(this.tail(stored)), "stored blob differs from the artifact");
    }

    function tail(bytes calldata b) external pure returns (bytes memory) {
        return b[1:];
    }

    /// @dev A factory with no pool code could never deploy a market, so it is
    /// refused at construction rather than discovered later.
    function test_FactoryRejectsEmptyPoolCode() public {
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        new PrecisionPoolFactory(address(executor), "");
    }

    /// @dev And the pools it does deploy are still CREATE2-derived from the
    /// market tuple alone, exactly as when the code was embedded.
    /// @dev LP shares grant canonical Permit2 an infinite allowance. That is a
    /// deliberate trust decision rather than an inherited default, so it is
    /// pinned here: a Solady bump that flips the default, or an accidental
    /// override, should fail loudly rather than silently change who can move
    /// every LP's position.
    function test_LpSharesTrustCanonicalPermit2() public {
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        PrecisionPool pool = _seeded();
        assertEq(pool.allowance(lp, permit2), type(uint256).max, "Permit2 allowance is no longer infinite");
        assertEq(pool.allowance(lp, attacker), 0, "a non-Permit2 spender was granted an allowance");
    }

    function test_PoolAddressStillMatchesPoolFor() public {
        PrecisionPoolFactory.Market memory m = _mkt(1e18, 3e18, 1234);
        address predicted = factory.poolFor(m);
        vm.prank(lp);
        (address actual,,,) = factory.createAndSeed(m, 2e18, 1e24, 1e24, 0, lp);
        assertEq(actual, predicted, "deployed address left the tuple-derived slot");
    }

    // ---------------------------------------------------------------- M-02

    /// @dev A seed opens at the price it was given, not merely somewhere inside
    /// the immutable band. The audit's counterexample opened 11.1% below its
    /// own argument while passing every guard.
    function testFuzz_SeedActualPriceRespectsCallerBounds(uint96 amt0, uint96 amt1, uint256 init) public {
        uint256 sl = 1e18;
        uint256 sh = 3e18;
        init = bound(init, sl, sh);

        vm.prank(lp);
        try factory.createAndSeed(_mkt(sl, sh, 3000), init, amt0, amt1, 0, lp) returns (
            address p, uint256, uint256, uint256
        ) {
            uint256 got = PrecisionPool(payable(p)).sqrtPriceCurrent();
            // The pool enforces 1% on the squared price; allow the same slack
            // on the sqrt price it reports.
            assertApproxEqRel(got, init, 0.01e18, "seed opened away from the requested price");
        } catch {}
    }
}
