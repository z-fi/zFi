// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionRoute} from "../src/pools/PrecisionRoute.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Whether a swap fills is the conjunction of two conditions running in
/// OPPOSITE directions: the band closes as size grows, and the zero-output
/// refusal opens as size grows. The fillable set is therefore an INTERVAL, and
/// halving against the conjunction can step over it - probing above the top,
/// then below the bottom, and concluding nothing fills while every size between
/// would have.
///
/// `PrecisionPool` documents this on `_transitionAt` and bisects `hasRoom`
/// alone. `PrecisionRoute._maxRouteIn` used to bisect the conjunction, via
/// `quoteExactIn`'s `fits`, on the stated premise that it was monotone and that
/// "Zero trivially fits" - neither of which held.
///
/// These tests pin the shape of the predicate that makes the naive search wrong,
/// and pin that the search now returns the true maximum regardless.
contract PrecisionRouteSearchPredicateTest is Test {
    PrecisionPoolFactory factory;
    PrecisionRoute router;
    MockERC20 x;
    MockERC20 y;
    PrecisionPool pool;

    address lp = address(0xA11CE);
    address user = address(0xB0B);

    receive() external payable {}

    function _fits(uint256 amt) internal view returns (bool f) {
        (, f) = pool.quoteExactIn(address(router), address(x), amt);
    }

    function _room(uint256 amt) internal view returns (bool r) {
        (, r) = pool.quoteTransition(address(router), address(x), amt);
    }

    function setUp() public {
        // An 18-decimal token against a 2-decimal one, priced so a raw unit of
        // output costs many raw units of input. That is what lifts the window's
        // lower edge well above zero and makes the interval visible.
        x = new MockERC20("X", 18);
        y = new MockERC20("Y", 2);
        while (address(x) >= address(y)) {
            y = new MockERC20("Y", 2);
        }
        factory = new PrecisionPoolFactory(address(this), type(PrecisionPool).creationCode);
        router = new PrecisionRoute(factory, address(this));

        x.mint(lp, type(uint128).max);
        y.mint(lp, type(uint128).max);
        vm.startPrank(lp);
        x.approve(address(factory), type(uint256).max);
        y.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed(
            PrecisionPoolFactory.Market(address(x), address(y), 1e10, 1e10 + 30_000, 3000, address(0), address(0), 0),
            1e10 + 15_000,
            1e24,
            1e12,
            0,
            lp
        );
        vm.stopPrank();
        pool = PrecisionPool(payable(p));

        // Thin the pool so the fillable window is small enough to sweep
        // exhaustively. The seed guards refuse to CREATE a pool this thin, but
        // `removeLiquidity` is deliberately unguarded, so it is reachable.
        for (uint256 i; i < 40; ++i) {
            uint256 burn = pool.balanceOf(lp) / 4;
            if (burn == 0) break;
            vm.prank(lp);
            pool.removeLiquidity(burn, 0, 0, lp);
        }
    }

    /// @dev The invariant the bisection now relies on, and which the old one
    ///      asserted of the wrong predicate: an empty trade moves no price, so
    ///      the band admits it.
    function test_ZeroHasRoomButDoesNotFit() public view {
        assertTrue(_room(0), "band should admit an empty trade");
        assertFalse(_fits(0), "an empty trade still produces nothing");
    }

    /// @dev The two conditions are genuinely separable, which is what makes a
    ///      correct search possible: below the window the band is fine and only
    ///      the output rounds away.
    function test_RoomAndFitsDivergeBelowTheWindow() public view {
        assertTrue(_room(1), "one raw unit is well inside the band");
        assertFalse(_fits(1), "one raw unit produces no output");
    }

    /// @dev The predicate is an INTERVAL, not a prefix: false below, true
    ///      inside, false above.
    function test_FitsIsNotMonotoneInSize() public {
        (uint256 a, uint256 b) = _edges();
        assertTrue(a != 0, "expected a fillable window");
        assertTrue(a > 1, "expected the window to start above one raw unit");
        assertTrue(_fits(a) && _fits(b), "edges must fit");
        assertFalse(_fits(a - 1), "expected the size below the window to miss");
        assertFalse(_fits(b + 1), "expected the size above the window to miss");
        emit log_named_uint("window lower edge a", a);
        emit log_named_uint("window upper edge b", b);
        emit log_named_uint("window ratio x100", (b * 100) / a);
    }

    /// @dev The property the fix buys: for ANY requested size above the window,
    ///      the clamp returns the window's true upper edge - it never reports
    ///      that nothing fills while something does. Swept across many requested
    ///      sizes, each against a fresh copy of the pool.
    function test_ClampAlwaysReturnsTheTrueMaximum() public {
        (uint256 a, uint256 b) = _edges();
        assertTrue(a != 0 && b >= a, "expected a fillable window");

        for (uint256 k; k < 24; ++k) {
            // Requested sizes strung across and beyond the window.
            uint256 ask = b + 1 + (b / 8) * k;
            uint256 snap = vm.snapshotState();
            assertEq(_clamp(ask), b, "clamp missed the true maximum");
            vm.revertToState(snap);
        }

        // A request INSIDE the window is not clamped at all.
        for (uint256 k; k < 8; ++k) {
            uint256 ask = a + ((b - a) / 8) * k;
            if (ask > b) break;
            uint256 snap = vm.snapshotState();
            assertEq(_clamp(ask), ask, "clamped a size that fit");
            vm.revertToState(snap);
        }

        // A request BELOW the window fills nothing, and says so by reverting
        // rather than by silently consuming a size that cannot produce output.
        // Driven through a raw call: `vm.expectRevert` binds to the next call,
        // which would be the funding transfer rather than the route.
        uint256 snapLow = vm.snapshotState();
        (bool ok, bytes memory err) = _clampRaw(a - 1);
        assertFalse(ok, "a size below the window should not fill");
        assertEq(bytes4(err), PrecisionRoute.InsufficientOutput.selector, "expected InsufficientOutput");
        vm.revertToState(snapLow);
    }

    /// @dev Drives the real `routeUpTo` and reports what it consumed.
    function _clamp(uint256 ask) internal returns (uint256 consumed) {
        (bool ok, bytes memory ret) = _clampRaw(ask);
        assertTrue(ok, "route reverted unexpectedly");
        (, consumed) = abi.decode(ret, (uint256, uint256));
    }

    /// @dev Funds and settles a route, returning the raw call result so a
    ///      failure can be asserted on without a cheatcode binding to the wrong
    ///      call in the sequence.
    function _clampRaw(uint256 ask) internal returns (bool ok, bytes memory ret) {
        x.mint(address(this), ask);
        bytes memory data = abi.encodeCall(PrecisionRoute.routeUpTo, (_pools(), address(x), address(y), ask, 0, user, user));
        router.checkpoint(address(x), keccak256(data), address(this));
        x.transfer(address(router), ask);
        (ok, ret) = address(router).call(data);
    }

    /// @dev Exact window edges [a,b], or (0,0). Cannot be one binary search:
    ///      `fits` is false at BOTH ends. Brackets by powers of ten first, then
    ///      bisects each edge inside a range where only one condition is active.
    function _edges() internal view returns (uint256 a, uint256 b) {
        uint256 seed;
        uint256 e;
        for (; e < 78; ++e) {
            if (_fits(10 ** e)) {
                seed = 10 ** e;
                break;
            }
        }
        if (seed == 0) return (0, 0);

        uint256 l = e == 0 ? 0 : 10 ** (e - 1);
        uint256 h = seed;
        while (h - l > 1) {
            uint256 m = l + (h - l) / 2;
            if (_fits(m)) h = m;
            else l = m;
        }
        a = h;

        l = seed;
        while (l < type(uint128).max / 2 && _fits(l * 2)) {
            l *= 2;
        }
        h = l * 2;
        while (h - l > 1) {
            uint256 m = l + (h - l) / 2;
            if (_fits(m)) l = m;
            else h = m;
        }
        b = l;
    }

    function _pools() internal view returns (address[] memory p) {
        p = new address[](1);
        p[0] = address(pool);
    }

    // ------------------------------------------------------------------ ABORT

    /// @dev This test contract is the router's `trustedExecutor`, so it can
    ///      drive the whole checkpoint lifecycle directly.
    function _openAndFund(uint256 amountIn, address refundTo) internal returns (bytes memory call_) {
        call_ = abi.encodeCall(PrecisionRoute.route, (_pools(), address(x), address(y), amountIn, 0, user));
        router.checkpoint(address(x), keccak256(call_), refundTo);
        vm.prank(lp);
        x.transfer(address(router), amountIn);
    }

    /// @dev The gap `abortCheckpoint` closes. An executor that checkpoints and
    ///      funds the router, then finds it cannot route - a clamp that came
    ///      back zero, a hop that would revert - previously had no way to hand
    ///      the input back. It stayed here permanently: inert, because every
    ///      later checkpoint bases on the raised balance, but unrecoverable.
    function test_AbortReturnsTheFundingToTheCommittedAddress() public {
        uint256 amountIn = 1e18;
        _openAndFund(amountIn, user);
        assertEq(x.balanceOf(address(router)), amountIn, "router holds the funding");

        uint256 refunded = router.abortCheckpoint(address(x));

        assertEq(refunded, amountIn, "abort returns the whole funding");
        assertEq(x.balanceOf(address(router)), 0, "nothing left stranded");
        assertEq(x.balanceOf(user), amountIn, "refund went to the committed address");
    }

    /// @dev It refunds the DELTA since the checkpoint, so a balance that was
    ///      already resting here - stranded by an earlier bug, or donated - is
    ///      not reachable through it.
    function test_AbortCannotReachAPreExistingBalance() public {
        uint256 stranded = 5e17;
        vm.prank(lp);
        x.transfer(address(router), stranded);

        uint256 amountIn = 1e18;
        _openAndFund(amountIn, user);

        uint256 refunded = router.abortCheckpoint(address(x));

        assertEq(refunded, amountIn, "only this route's funding is refundable");
        assertEq(x.balanceOf(address(router)), stranded, "the pre-existing balance stays put");
    }

    /// @dev Abort releases the route lock, so the executor can open a fresh one
    ///      in the same transaction rather than being wedged until it ends.
    function test_AbortReopensTheRoute() public {
        uint256 amountIn = 1e18;
        _openAndFund(amountIn, user);
        router.abortCheckpoint(address(x));

        bytes memory call_ = _openAndFund(amountIn, user);
        (bool ok,) = address(router).call(call_);
        assertTrue(ok, "a fresh route was refused after an abort");
        assertEq(x.balanceOf(address(router)), 0, "kept the input");
    }

    function test_AbortRequiresTheExecutorAndAnOpenRoute() public {
        vm.prank(user);
        vm.expectRevert(PrecisionRoute.NotExecutor.selector);
        router.abortCheckpoint(address(x));

        vm.expectRevert(PrecisionRoute.BadCheckpoint.selector);
        router.abortCheckpoint(address(x));
    }

    /// @dev Naming a token other than the one checkpointed cannot drain a
    ///      balance: the route is open, but that token's slot is not.
    function test_AbortRejectsAnUnrelatedToken() public {
        _openAndFund(1e18, user);
        vm.expectRevert(PrecisionRoute.BadCheckpoint.selector);
        router.abortCheckpoint(address(y));
    }

    /// @dev The funding is spendable exactly once. A route that already
    ///      consumed the checkpoint leaves nothing for an abort to pay out, and
    ///      an aborted checkpoint leaves nothing for a route to spend.
    function test_AbortAfterARouteIsRefused() public {
        bytes memory call_ = _openAndFund(1e18, user);
        (bool ok,) = address(router).call(call_);
        assertTrue(ok, "the committed route was refused");

        vm.expectRevert(PrecisionRoute.BadCheckpoint.selector);
        router.abortCheckpoint(address(x));
    }

    function test_RouteAfterAnAbortIsRefused() public {
        bytes memory call_ = _openAndFund(1e18, user);
        router.abortCheckpoint(address(x));

        (bool ok, bytes memory err) = address(router).call(call_);
        assertFalse(ok, "an aborted checkpoint was spent");
        assertEq(bytes4(err), PrecisionRoute.Reentrancy.selector, "wrong rejection");
    }

    function test_CheckpointRejectsAnUnusableRefundAddress() public {
        bytes32 intent = keccak256("anything");
        vm.expectRevert(PrecisionRoute.Bad.selector);
        router.checkpoint(address(x), intent, address(0));

        vm.expectRevert(PrecisionRoute.Bad.selector);
        router.checkpoint(address(x), intent, address(router));
    }
}
