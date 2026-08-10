// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionRoute} from "../src/pools/PrecisionRoute.sol";
import {PriceTape} from "../src/pools/PriceTape.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev `PriceTape` is a library of `internal` functions, so its codec can only
/// be exercised through a harness. Nothing here is deployed; it exists so the
/// float32 properties the pool's `high`/`low` updates depend on are asserted
/// against the real implementation rather than a restatement of it.
contract TapeHarness {
    function pack(uint256 v) external pure returns (uint32) {
        return PriceTape.pack(v);
    }

    function unpack(uint32 p) external pure returns (uint256) {
        return PriceTape.unpack(p);
    }
}

/// @dev Stands in for zRouter's public `SafeExecutor`: one dispatch function,
/// no caller check, bubbling every downstream revert. `PrecisionRoute` requires
/// its executor to have code, and the checkpoint/fund/spend sequence has to
/// come from a single caller, so the mock performs it the way the real path
/// does rather than the test driving the router directly.
contract MockExec {
    /// @dev Native-funded entry: no checkpoint, value forwarded with the call.
    function send(address target, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) _bubble(ret);
        return ret;
    }

    /// @dev ERC-20-funded entry: checkpoint, then fund, then spend - with the
    /// funding transfer landing in the gap the intent commitment has to cover.
    function fundAndSend(PrecisionRoute r, address token, address payer, uint256 amount, bytes calldata data)
        external
        returns (bytes memory)
    {
        r.checkpoint(token, keccak256(data), payer);
        MockERC20(token).transferFrom(payer, address(r), amount);
        (bool ok, bytes memory ret) = address(r).call(data);
        if (!ok) _bubble(ret);
        return ret;
    }

    function _bubble(bytes memory ret) private pure {
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    receive() external payable {}
}

/// @dev Follow-up coverage for the second audit pass over `PrecisionPool`, its
/// factory and `PrecisionRoute`. Each test pins a property the review had to
/// reason about from the source because nothing asserted it:
///
///   - a pool cannot be endowed with native value at deployment, which was the
///     one hole in its no-unaccounted-balance policy the contract can close;
///   - `PriceTape`'s packed integers are order-isomorphic to the values they
///     encode, which is what makes the `high`/`low` updates correct while
///     skipping the unpack/compare/repack round trip;
///   - a route naming the same pool twice - explicitly tolerated rather than
///     screened for - loses the caller money but strands nothing in the router;
///   - `zapIn` leaves no residual allowance on either side of the pair.
contract PrecisionAuditFollowupTest is Test {
    PrecisionPoolFactory factory;
    TapeHarness tape;
    MockExec exec;
    PrecisionRoute router;

    MockERC20 a;
    MockERC20 b;

    /// @dev Native token0 against `b`; used for the duplicate-hop route, which
    /// needs no checkpoint and so isolates the router's own accounting.
    PrecisionPool ethPool;
    /// @dev `a`/`b`, for the ERC-20-funded zap.
    PrecisionPool tokenPool;

    address lp = address(0xC11);
    address user = address(0xBEEF);

    function setUp() public {
        exec = new MockExec();
        factory = new PrecisionPoolFactory(address(exec), type(PrecisionPool).creationCode);
        tape = new TapeHarness();
        router = new PrecisionRoute(factory, address(exec));

        a = new MockERC20("A", 18);
        b = new MockERC20("B", 18);
        if (address(a) > address(b)) (a, b) = (b, a);

        a.mint(lp, 1e30);
        b.mint(lp, 1e30);
        a.mint(user, 1e24);
        b.mint(user, 1e24);
        vm.deal(lp, 1e24);
        vm.deal(user, 1e24);

        vm.startPrank(lp);
        a.approve(address(factory), type(uint256).max);
        b.approve(address(factory), type(uint256).max);

        // Price 1 token1 per token0, band [0.25, 4].
        (address p0,,,) = factory.createAndSeed{value: 1e21}(
            _mkt(address(0), address(b), 0.5e18, 2e18, 3000), 1e18, 1e21, 1e21, 0, lp
        );
        ethPool = PrecisionPool(payable(p0));

        (address p1,,,) =
            factory.createAndSeed(_mkt(address(a), address(b), 0.5e18, 2e18, 3000), 1e18, 1e21, 1e21, 0, lp);
        tokenPool = PrecisionPool(payable(p1));
        vm.stopPrank();

        vm.prank(user);
        a.approve(address(exec), type(uint256).max);
    }

    function _mkt(address t0, address t1, uint256 sl, uint256 sh, uint256 fee)
        internal
        pure
        returns (PrecisionPoolFactory.Market memory)
    {
        return PrecisionPoolFactory.Market({
            token0: t0,
            token1: t1,
            sqrtPLow: sl,
            sqrtPHigh: sh,
            fee: fee,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    // ------------------------------------------------- NO ENDOWED DEPLOYMENT

    /// @dev The pool refuses naked value everywhere else - `receive()` reverts,
    /// and every entry point credits only what it pulled or was sent as
    /// `msg.value`. A payable constructor would have been the exception: a
    /// deployment could hand a native-token0 pool ETH before any entry point
    /// existed to account for it, and the no-sweep policy means that ETH is then
    /// stranded forever. `CREATE` with value must fail outright.
    ///
    /// This is asserted against the POOL rather than the factory on purpose.
    /// "It is only ever deployed by the factory, which sends no value" is not an
    /// invariant: the constructor is public and direct deployment is a supported
    /// path - see `test_ADirectlyDeployedPoolIsAWorkingPool` below. The
    /// guarantee has to hold here.
    function test_PoolCannotBeEndowedAtDeployment() public {
        bytes memory initCode = abi.encodePacked(
            type(PrecisionPool).creationCode,
            abi.encode(address(factory), address(0), address(b), uint256(0.5e18), uint256(2e18), uint256(3000),
                address(0), address(0), uint256(0))
        );

        address deployed;
        assembly ("memory-safe") {
            deployed := create(1, add(initCode, 0x20), mload(initCode))
        }
        assertEq(deployed, address(0), "a constructor that accepts value strands it permanently");

        // The same initcode with no value deploys, so the failure above is the
        // endowment and not a malformed argument list.
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertTrue(deployed != address(0), "zero-value deployment must still work");
        assertEq(deployed.balance, 0, "a fresh pool holds nothing");
    }

    /// @dev The premise the test above refuses to lean on, stated outright: a
    /// pool deployed WITHOUT the factory is a real, seedable, tradeable pool.
    /// The constructor documents itself as repeating the factory's checks for
    /// exactly this case, and `_addLiquidity` admits a non-factory seeder when
    /// there is no `feeRecipient` to protect.
    ///
    /// It matters because it is the reason a constructor-level guarantee cannot
    /// be delegated upstream to `createPool`. If this ever stops being true, the
    /// endowment argument changes and that test's reasoning should be revisited
    /// rather than merely re-run.
    function test_ADirectlyDeployedPoolIsAWorkingPool() public {
        PrecisionPool pool = new PrecisionPool(
            address(factory), address(a), address(b), 0.5e18, 2e18, 3000, address(0), address(0), 0
        );
        assertFalse(factory.isPool(address(pool)), "a direct deployment is not indexed by the factory");

        vm.startPrank(lp);
        a.approve(address(pool), type(uint256).max);
        b.approve(address(pool), type(uint256).max);
        (uint256 lpOut,,) = pool.addLiquidityExact(1e18, 1e21, 1e21, 0, lp);
        vm.stopPrank();
        assertGt(lpOut, 0, "a factory-less pool must still be seedable");

        vm.startPrank(user);
        a.approve(address(pool), type(uint256).max);
        uint256 out = pool.swapExactIn(address(a), 1e18, 0, user);
        vm.stopPrank();
        assertGt(out, 0, "a factory-less pool must still trade");
    }

    // ------------------------------------------------------- PRICE TAPE CODEC

    /// @dev The property `print` and `fold` both rely on: they compare `high`
    /// and `low` in PACKED space to avoid an unpack/compare/repack round trip
    /// on every trade. That is only sound if the packed integer is monotonic in
    /// the value it encodes. Exponent-zero values occupy `[0, 2**24)` and
    /// exponent-`e` values occupy `[e*2**24 + 2**23, (e+1)*2**24)`, so the
    /// ranges never overlap - but nothing asserted it.
    function testFuzz_PackedOrderMatchesEncodedOrder(uint256 x, uint256 y) public view {
        uint32 px = tape.pack(x);
        uint32 py = tape.pack(y);
        uint256 ux = tape.unpack(px);
        uint256 uy = tape.unpack(py);

        assertEq(px < py, ux < uy, "packed comparison must agree with the values encoded");
        assertEq(px == py, ux == uy, "equal packings must encode equal values");
    }

    /// @dev A bar's `low` is seeded from its `open` and only ever moved down by
    /// the packed comparison above, so this is the same property stated the way
    /// the caller uses it.
    function testFuzz_PackIsMonotoneInItsInput(uint256 x, uint256 y) public view {
        vm.assume(x <= y);
        assertLe(tape.pack(x), tape.pack(y), "a larger value can never pack smaller");
    }

    /// @dev The documented guarantee: 24 significant bits, so the round trip
    /// truncates downward by strictly less than 2**-23 relative. Charts read
    /// these, and a decoder that assumed exactness would drift.
    function testFuzz_RoundTripTruncatesDownwardWithinTolerance(uint256 v) public view {
        uint256 back = tape.unpack(tape.pack(v));
        assertLe(back, v, "the codec must never round up into value that never traded");
        // Error is bounded by one unit in the last place of a 24-bit mantissa.
        assertLe(v - back, v / (1 << 23) + 1, "relative error must stay under 2**-23");
    }

    /// @dev The exponent field is eight bits. A 256-bit input takes the largest
    /// shift the codec can produce, so this is where it would overflow into the
    /// mantissa if the 24-significant-bit choice and the field width disagreed.
    function test_PackHandlesTheTopOfTheRange() public view {
        uint32 packed = tape.pack(type(uint256).max);
        assertEq(uint256(packed) >> 24, 232, "exponent must be msb - 23 and fit eight bits");
        assertEq(uint256(packed) & 0xffffff, 0xffffff, "mantissa must saturate, not wrap");
        assertLe(tape.unpack(packed), type(uint256).max, "unpack must not wrap around");
    }

    /// @dev Bucket zero marks an empty ring slot, so a zero price has to encode
    /// as zero without being mistaken for one.
    function test_ZeroPacksToZeroAndBack() public view {
        assertEq(tape.pack(0), 0);
        assertEq(tape.unpack(0), 0);
    }

    /// @dev The pool records two timeframes and says every other one is an
    /// exact client-side aggregation. Asking for a third must return nothing
    /// rather than the nearest tape, which a client would silently mislabel.
    function test_AnUnrecordedPeriodReturnsNothing() public view {
        assertEq(ethPool.tape(1 hours, 4).length, 0, "an unrecorded period must not guess");
        assertEq(ethPool.tape(ethPool.FINE_PERIOD(), 4).length, 4);
        assertEq(ethPool.tape(ethPool.COARSE_PERIOD(), 4).length, 4);
    }

    // ------------------------------------------------------- DUPLICATE HOPS

    /// @dev `PrecisionRoute._routeOut` quotes every hop against PRE-ROUTE state,
    /// which is exact only because distinct pools do not move each other. A path
    /// naming the same pool twice breaks that assumption, and the contract
    /// deliberately does not screen for it - a duplicate hop is a strictly worse
    /// route that pays two fees to move one price back and forth, and screening
    /// would charge every honest route a quadratic scan.
    ///
    /// What must hold is that tolerating it is safe: the caller loses the two
    /// fees, `minOut` still binds, and NOTHING is left resting in the router for
    /// the next caller to sweep.
    function test_ADuplicateHopCostsTheCallerButStrandsNothing() public {
        address[] memory pools = new address[](2);
        (pools[0], pools[1]) = (address(ethPool), address(ethPool));

        uint256 before = user.balance;
        bytes memory ret = exec.send{value: 10e18}(
            address(router), abi.encodeCall(PrecisionRoute.route, (pools, address(0), address(0), 10e18, 0, user))
        );
        uint256 out = abi.decode(ret, (uint256));

        assertGt(out, 0, "the round trip still settles");
        assertLt(out, 10e18, "two fees and two price moves must cost the caller");
        // The route is funded by this test through the executor, so `user` is
        // the recipient only: it is credited the output and nothing else.
        assertEq(user.balance, before + out, "the recipient is paid exactly what the route produced");

        assertEq(address(router).balance, 0, "no native intermediate may rest in the router");
        assertEq(b.balanceOf(address(router)), 0, "no token intermediate may rest in the router");
        assertEq(b.allowance(address(router), address(ethPool)), 0, "the hop must not leave an allowance behind");
    }

    /// @dev The same path with a `minOut` the round trip cannot clear. The
    /// stale-quote risk a duplicate hop introduces is caught by slippage, which
    /// is where the contract says it is caught.
    function test_ADuplicateHopIsStillCaughtByMinOut() public {
        address[] memory pools = new address[](2);
        (pools[0], pools[1]) = (address(ethPool), address(ethPool));

        vm.expectRevert(PrecisionRoute.InsufficientOutput.selector);
        exec.send{value: 10e18}(
            address(router), abi.encodeCall(PrecisionRoute.route, (pools, address(0), address(0), 10e18, 10e18, user))
        );
    }

    /// @dev `routeUpTo` sizes the route from a search that quotes both visits
    /// against pre-route state, so a duplicate hop can make it pick a size the
    /// execution then rejects. Either outcome is acceptable - a clean revert or
    /// a settled fill - but the router must never end up holding the difference.
    function test_ADuplicateHopUnderPartialFillLeavesTheRouterEmpty() public {
        address[] memory pools = new address[](2);
        (pools[0], pools[1]) = (address(ethPool), address(ethPool));

        uint256 before = user.balance;
        bool settled;
        try exec.send{value: 10e18}(
            address(router),
            abi.encodeCall(PrecisionRoute.routeUpTo, (pools, address(0), address(0), 10e18, 0, user, user))
        ) returns (bytes memory ret) {
            (uint256 out, uint256 consumed) = abi.decode(ret, (uint256, uint256));
            settled = true;
            // Whatever the search picked, the recipient is credited the output
            // plus any unconsumed head - and the head is the INPUT token, never
            // the intermediate.
            assertEq(user.balance, before + out + (10e18 - consumed), "output and remainder must both land");
        } catch {}

        // The search quotes both visits against pre-route state, so it may pick
        // a size execution rejects. Either outcome is fine; leaving value here
        // is not. This asserts which branch ran so the test cannot go vacuous.
        assertTrue(settled, "the duplicate route settled; update this test if the search changes");
        assertEq(address(router).balance, 0, "a clamped duplicate route must not strand ETH");
        assertEq(b.balanceOf(address(router)), 0, "a clamped duplicate route must not strand the intermediate");
    }

    // ---------------------------------------------------------------- ZAP IN

    /// @dev Canonical ordering puts `address(0)` first, so `token1` is always an
    /// ERC-20 and both approvals in `zapIn` are unconditional on that side. The
    /// property worth pinning is the outcome: whatever the split, the router
    /// ends the call with no allowance and no balance on either token.
    function test_ZapInLeavesNoAllowanceOrResidueOnEitherSide() public {
        uint256 amountIn = 100e18;
        bytes memory data =
            abi.encodeCall(PrecisionRoute.zapIn, (address(tokenPool), address(a), amountIn, 45e18, 0, user));

        vm.prank(user);
        exec.fundAndSend(router, address(a), user, amountIn, data);

        assertGt(tokenPool.balanceOf(user), 0, "the zap must mint the caller a position");

        assertEq(a.allowance(address(router), address(tokenPool)), 0, "token0 allowance must be cleared");
        assertEq(b.allowance(address(router), address(tokenPool)), 0, "token1 allowance must be cleared");
        assertEq(a.balanceOf(address(router)), 0, "no token0 may rest in the router");
        assertEq(b.balanceOf(address(router)), 0, "no token1 may rest in the router");
    }

    /// @dev The native side of the same claim: `token0` is ETH, so only the
    /// `token1` approval is taken, and the unused portion of both sides comes
    /// back to the recipient rather than accumulating here.
    function test_NativeZapInLeavesNoAllowanceOrResidue() public {
        bytes memory data =
            abi.encodeCall(PrecisionRoute.zapIn, (address(ethPool), address(0), 100e18, 45e18, 0, user));

        exec.send{value: 100e18}(address(router), data);

        assertGt(ethPool.balanceOf(user), 0, "the zap must mint the caller a position");
        assertEq(b.allowance(address(router), address(ethPool)), 0, "token1 allowance must be cleared");
        assertEq(address(router).balance, 0, "no ETH may rest in the router");
        assertEq(b.balanceOf(address(router)), 0, "no token1 may rest in the router");
    }
}
