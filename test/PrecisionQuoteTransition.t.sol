// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev `quoteTransition` is the searchable half of `quoteExactIn`: it reports
/// the band condition alone and leaves the zero-output refusal to the caller.
/// `PrecisionRoute._maxRouteIn` bisects it, so the route's clamp is only correct
/// while three things hold, and none of them was pinned by a test.
///
///   1. It agrees with `quoteExactIn`, which is the function integrators use -
///      `fits` must be exactly `hasRoom && amountOut != 0`, and the output must
///      be the same number where it fits.
///   2. `hasRoom` is MONOTONE DECREASING in size. This is the whole premise of
///      bisecting it, and the reason bisecting `fits` was wrong.
///   3. It predicts execution. A quote that drifts from the swap hands back a
///      size that reverts, which is the exact failure a partial fill exists to
///      remove.
contract PrecisionQuoteTransitionTest is Test {
    PrecisionPoolFactory factory;
    MockERC20 usdc;
    PrecisionPool pool;

    address lp = address(0xA11CE);
    address trader = address(0xB0B);

    uint256 constant LO = 42426406871192; // $1800
    uint256 constant MID = 44721359549995; // $2000
    uint256 constant HI = 46904157598234; // $2200

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        usdc = new MockERC20("USDC", 6);
        usdc.mint(lp, 1e15);
        usdc.mint(trader, 1e15);
        vm.deal(lp, 1e23);
        vm.deal(trader, 1e23);

        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 10 ether}(
            PrecisionPoolFactory.Market(address(0), address(usdc), LO, HI, 3000, address(0), address(0), 0),
            MID,
            10 ether,
            30_000e6,
            0,
            lp
        );
        vm.stopPrank();
        pool = PrecisionPool(payable(p));

        vm.prank(trader);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _tok(bool dir) internal view returns (address) {
        return dir ? address(0) : address(usdc);
    }

    /// @dev Moves the pool off its seed price so the band is not sampled only at
    ///      the midpoint, where both edges are equidistant and bugs hide.
    function _warm(uint96 w) internal {
        uint256 amt = bound(uint256(w), 0, 3 ether);
        if (amt == 0) return;
        vm.prank(trader);
        try pool.swapExactIn{value: amt}(address(0), amt, 0, trader) {} catch {}
    }

    /// @dev Property 1: the two quotes are the same computation, differing only
    ///      in that `quoteExactIn` folds in the zero-output refusal and masks
    ///      the output when it does not fit.
    function testFuzz_TransitionAgreesWithQuoteExactIn(uint96 warm, uint256 amt, bool dir) public {
        _warm(warm);
        amt = bound(amt, 0, dir ? 1_000 ether : 1e12);
        address tin = _tok(dir);

        (uint256 out, bool fits) = pool.quoteExactIn(trader, tin, amt);
        (uint256 rawOut, bool hasRoom) = pool.quoteTransition(trader, tin, amt);

        assertEq(fits, hasRoom && rawOut != 0, "fits must be the conjunction");
        if (fits) assertEq(out, rawOut, "fitting output must match");
        else assertEq(out, 0, "quoteExactIn must mask a non-fitting output");
    }

    /// @dev Property 2, and the one the route's clamp depends on: if a larger
    ///      size has room, so does every smaller one. Bisection is only valid
    ///      over a predicate with this shape - which `fits` does NOT have.
    function testFuzz_RoomIsMonotoneDecreasingInSize(uint96 warm, uint256 a, uint256 b, bool dir) public {
        _warm(warm);
        uint256 cap = dir ? 1_000 ether : 1e12;
        a = bound(a, 0, cap);
        b = bound(b, 0, cap);
        if (a > b) (a, b) = (b, a);
        address tin = _tok(dir);

        (, bool roomSmall) = pool.quoteTransition(trader, tin, a);
        (, bool roomLarge) = pool.quoteTransition(trader, tin, b);
        if (roomLarge) assertTrue(roomSmall, "room at a larger size implies room at a smaller one");
    }

    /// @dev The invariant a search starting from a zero lower bound relies on.
    function test_ZeroHasRoomAndProducesNothing() public view {
        (uint256 out, bool hasRoom) = pool.quoteTransition(trader, address(0), 0);
        assertTrue(hasRoom, "an empty trade moves no price");
        assertEq(out, 0);
        (, bool fits) = pool.quoteExactIn(trader, address(0), 0);
        assertFalse(fits, "and is still not fillable");
    }

    /// @dev Property 3: the quote is the swap. Where it says a size fills, the
    ///      swap must succeed and pay exactly the quoted amount; where it says
    ///      it does not, the swap must revert.
    function testFuzz_TransitionPredictsExecution(uint96 warm, uint256 amt, bool dir) public {
        _warm(warm);
        amt = bound(amt, 1, dir ? 1_000 ether : 1e12);
        address tin = _tok(dir);

        (uint256 rawOut, bool hasRoom) = pool.quoteTransition(trader, tin, amt);
        bool shouldFill = hasRoom && rawOut != 0;

        vm.prank(trader);
        if (dir) {
            try pool.swapExactIn{value: amt}(address(0), amt, 0, trader) returns (uint256 got) {
                assertTrue(shouldFill, "swap filled where the quote refused");
                assertEq(got, rawOut, "filled amount must equal the quote");
            } catch {
                assertFalse(shouldFill, "swap reverted where the quote promised a fill");
            }
        } else {
            try pool.swapExactIn(tin, amt, 0, trader) returns (uint256 got) {
                assertTrue(shouldFill, "swap filled where the quote refused");
                assertEq(got, rawOut, "filled amount must equal the quote");
            } catch {
                assertFalse(shouldFill, "swap reverted where the quote promised a fill");
            }
        }
    }

    /// @dev An unseeded pool quotes nothing rather than reverting, in both
    ///      halves. The route walks caller-supplied paths, so a pool with no
    ///      supply has to answer rather than take the whole route down.
    function test_UnseededPoolReportsNoRoom() public {
        PrecisionPoolFactory.Market memory m =
            PrecisionPoolFactory.Market(address(0), address(usdc), LO, HI, 500, address(0), address(0), 0);
        address empty = factory.createPool(m);
        (uint256 out, bool hasRoom) = PrecisionPool(payable(empty)).quoteTransition(trader, address(0), 1 ether);
        assertEq(out, 0);
        assertFalse(hasRoom);
        (, bool fits) = PrecisionPool(payable(empty)).quoteExactIn(trader, address(0), 1 ether);
        assertFalse(fits);
    }

    /// @dev Both quotes reject a token that is not in the pair, rather than
    ///      silently quoting a direction that does not exist.
    function test_BothQuotesRejectAForeignToken() public {
        MockERC20 other = new MockERC20("OTHER", 18);
        vm.expectRevert(PrecisionPool.InvalidToken.selector);
        pool.quoteTransition(trader, address(other), 1e18);
        vm.expectRevert(PrecisionPool.InvalidToken.selector);
        pool.quoteExactIn(trader, address(other), 1e18);
    }
}
