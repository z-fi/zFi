// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {SwapboardView} from "../src/SwapboardView.sol";

/// @dev Exercises the split matcher directly, with no board or quoter, so it
/// stays runnable while those are being revised. Numbers are chosen so the
/// right answer can be worked out by hand.
contract SwapboardPlanTest is Test {
    SwapboardView lens;
    address IN = address(0xAAA1);
    address OUT = address(0xBBB2);

    function setUp() public {
        lens = new SwapboardView();
    }

    /// wants `amountB` of tokenIn, pays `amountA` of tokenOut
    function _o(uint256 id, uint256 amountA, uint256 amountB, bool partialFill)
        internal
        view
        returns (SwapboardView.OrderView memory v)
    {
        v.orderId = id;
        v.tokenA = OUT;
        v.amountA = amountA;
        v.tokenB = IN;
        v.amountB = amountB;
        v.partialFill = partialFill;
    }

    function _plan(SwapboardView.OrderView[] memory c, uint256 amountIn, uint256 baseline)
        internal
        view
        returns (SwapboardView.Fill[] memory f, uint256 bin, uint256 bout)
    {
        return lens.previewPlan(c, amountIn, baseline);
    }

    // ---------------------------------------------------------------- basics

    function test_TakesNothingWhenTheBookIsWorseThanTheAmm() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 90e18, 100e18, true); // 0.90 per unit
        (SwapboardView.Fill[] memory f,, uint256 bout) = _plan(c, 100e18, 100e18); // AMM 1.00
        assertEq(f.length, 0, "nothing beats the AMM");
        assertEq(bout, 0);
    }

    function test_TakesTheWholeOrderWhenItFits() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 110e18, 100e18, false); // AON, 1.10
        (SwapboardView.Fill[] memory f, uint256 bin, uint256 bout) = _plan(c, 100e18, 100e18);
        assertEq(f.length, 1, "AON filled whole");
        assertEq(bin, 100e18);
        assertEq(bout, 110e18);
        assertFalse(f[0].isPartial);
    }

    function test_SizesAPartialOrderToTheRemainder() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 220e18, 200e18, true); // 1.10, bigger than the trade
        (SwapboardView.Fill[] memory f, uint256 bin, uint256 bout) = _plan(c, 100e18, 100e18);
        assertEq(f.length, 1);
        assertEq(bin, 100e18, "only what was being swapped");
        assertEq(bout, 110e18, "pro rata");
        assertTrue(f[0].isPartial);
    }

    function test_AonTooLargeIsSkippedButSmallerOnesStillFill() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        c[0] = _o(1, 500e18, 400e18, false); // AON 1.25, too big for a 100 trade
        c[1] = _o(2, 60e18, 50e18, false); // AON 1.20, fits
        (SwapboardView.Fill[] memory f, uint256 bin, uint256 bout) = _plan(c, 100e18, 100e18);
        assertEq(f.length, 1, "the oversized block is passed over, not fatal");
        assertEq(f[0].orderId, 2, "the smaller AON still fills");
        assertEq(bin, 50e18);
        assertEq(bout, 60e18);
    }

    // ------------------------------------------------- waterfall across many

    function test_WaterfallsAcrossOrdersBestRateFirst() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](3);
        c[0] = _o(1, 105e18, 100e18, true); // 1.05
        c[1] = _o(2, 60e18, 50e18, false); // 1.20  AON
        c[2] = _o(3, 33e18, 30e18, true); // 1.10
        (SwapboardView.Fill[] memory f, uint256 bin, uint256 bout) = _plan(c, 100e18, 100e18);
        assertEq(f.length, 3, "all three used");
        assertEq(f[0].orderId, 2, "best rate first");
        assertEq(f[1].orderId, 3);
        assertEq(f[2].orderId, 1, "worst rate last, sized to what is left");
        assertEq(bin, 100e18, "the whole trade was placed");
        // 50 at 1.20, 30 at 1.10, 20 at 1.05 -> 60 + 33 + 21
        assertEq(bout, 114e18);
    }

    function test_StopsAtTheAmmRateAndLeavesTheRestToTheAmm() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        c[0] = _o(1, 60e18, 50e18, true); // 1.20, worth taking
        c[1] = _o(2, 49e18, 50e18, true); // 0.98, worse than the AMM
        (SwapboardView.Fill[] memory f, uint256 bin, uint256 bout) = _plan(c, 100e18, 100e18);
        assertEq(f.length, 1, "only the order that beats the AMM");
        assertEq(bin, 50e18, "half left for the AMM");
        assertEq(bout, 60e18);
    }

    // ------------------------------- the case rate-greedy alone gets wrong

    /// Remainder 100, AMM paying 0.95. Rate-greedy takes the 1.10 partial for
    /// 50, which leaves too little for the 1.05 AON block:
    ///     greedy : 50 at 1.10 plus 50 to the AMM at 0.95 = 55.0 + 47.5 = 102.5
    ///     better : 100 at 1.05 entirely on the book        = 105.0
    /// Scoring whole plans on total value has to pick the second.
    function test_PrefersALargeAonBlockOverABetterPricedPartial() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        c[0] = _o(1, 55e18, 50e18, true); // 1.10 partial
        c[1] = _o(2, 105e18, 100e18, false); // 1.05 AON, needs the whole trade
        (SwapboardView.Fill[] memory f, uint256 bin, uint256 bout) = _plan(c, 100e18, 95e18);
        assertEq(f.length, 1, "the AON block alone");
        assertEq(f[0].orderId, 2);
        assertEq(bin, 100e18);
        assertEq(bout, 105e18, "105 beats greedy's 102.5");
    }

    /// The same shape, but with the AMM paying well enough that greedy wins.
    /// 50 at 1.10 plus 50 at 1.09 = 55 + 54.5 = 109.5, against the AON block's 105.
    function test_KeepsTheGreedyPlanWhenTheAmmIsStrong() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        c[0] = _o(1, 55e18, 50e18, true); // 1.10 partial
        c[1] = _o(2, 105e18, 100e18, false); // 1.05 AON
        (SwapboardView.Fill[] memory f, uint256 bin, uint256 bout) = _plan(c, 100e18, 109e18);
        assertEq(f.length, 1, "only the partial clears a 1.09 AMM");
        assertEq(f[0].orderId, 1);
        assertEq(bin, 50e18, "the rest is better off at the AMM");
        assertEq(bout, 55e18);
    }

    // ------------------------------------------------------------- hardening

    function test_DustFillsAreDropped() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 1, 1000e18, true); // rounds to zero out for any small input
        (SwapboardView.Fill[] memory f,, uint256 bout) = _plan(c, 1, 0);
        assertEq(f.length, 0, "a fill paying nothing is not a fill");
        assertEq(bout, 0);
    }

    /// Anyone can rest an order, so the rate arithmetic is attacker-influenced.
    /// It must not overflow and brick the read for everyone else.
    function test_AbsurdAmountsDoNotRevert() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        c[0] = _o(1, type(uint256).max, 1, true); // rate cannot be represented
        c[1] = _o(2, 110e18, 100e18, true); // a real order behind it
        (SwapboardView.Fill[] memory f,, uint256 bout) = _plan(c, 100e18, 100e18);
        assertEq(f.length, 1, "the absurd order is dropped, not fatal");
        assertEq(f[0].orderId, 2, "the real order still routes");
        assertEq(bout, 110e18);
    }

    function test_EmptyBookAndZeroAmount() public view {
        SwapboardView.OrderView[] memory none = new SwapboardView.OrderView[](0);
        (SwapboardView.Fill[] memory a,,) = _plan(none, 100e18, 100e18);
        assertEq(a.length, 0);
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 110e18, 100e18, true);
        (SwapboardView.Fill[] memory b,,) = _plan(c, 0, 0);
        assertEq(b.length, 0, "nothing to route");
    }

    /// The plan must never claim more input than the user is spending.
    function testFuzz_NeverOverspends(uint96 amountIn, uint96 a1, uint96 b1, uint96 a2, uint96 b2) public view {
        vm.assume(amountIn > 0 && a1 > 0 && b1 > 0 && a2 > 0 && b2 > 0);
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        c[0] = _o(1, a1, b1, true);
        c[1] = _o(2, a2, b2, false);
        (, uint256 bin,) = _plan(c, amountIn, 0);
        assertLe(bin, amountIn, "never routes more than the user has");
    }
    // ------------------------------------------------- board attribution

    /// Each leg has to name the board it settles against, or a caller planning
    /// across v1 and v2 cannot build the calldata. This was previously stamped
    /// from a single argument, so previewPlan returned address(0) on every leg.
    function test_EachFillNamesItsOwnBoard() public view {
        address bV1 = address(0xB1);
        address bV2 = address(0xB2);
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        c[0] = _o(1, 120e18, 100e18, true);
        c[0].board = bV2;
        c[1] = _o(2, 110e18, 100e18, true);
        c[1].board = bV1;

        (SwapboardView.Fill[] memory f,,) = _plan(c, 200e18, 100e18);
        assertEq(f.length, 2, "both legs taken");
        assertEq(f[0].board, bV2, "best-priced leg keeps its board");
        assertEq(f[1].board, bV1, "so does the other, on the other board");
    }

    // ------------------------------------------------ pricing the remainder

    /// The floor is what makes an order worth taking. Priced off a full-size
    /// AMM average it is too strict, because the real cost of one more book leg
    /// is the AMM's marginal rate at the tail. previewPlanAtRate lets the
    /// caller supply that rate once the remainder is known.
    function test_ARateBetweenMarginalAndAverageIsSkippedByTheAverage() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 98e18, 100e18, true); // 0.98

        // AMM averages 1.00 over the full size, so 0.98 looks unprofitable.
        (SwapboardView.Fill[] memory f,, uint256 bout) = _plan(c, 100e18, 100e18);
        assertEq(f.length, 0, "skipped against the average");
        assertEq(bout, 0);

        // But the remainder only fetches 0.95, so 0.98 is worth taking.
        (SwapboardView.Fill[] memory g, uint256 bin2, uint256 bout2) =
            lens.previewPlanAtRate(c, 100e18, 0.95e18);
        assertEq(g.length, 1, "taken against the marginal rate");
        assertEq(bin2, 100e18);
        assertEq(bout2, 98e18);
    }

    /// The mirror case: a floor rate is still a floor. Nothing below it is
    /// taken however the caller arrived at the number.
    function test_TheExplicitRateStillRefusesWorseOrders() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 94e18, 100e18, true); // 0.94, below the 0.95 floor
        (SwapboardView.Fill[] memory f,,) = lens.previewPlanAtRate(c, 100e18, 0.95e18);
        assertEq(f.length, 0, "below the floor is still below the floor");
    }

    /// A zero floor means the caller has no AMM to fall back on, so anything
    /// that pays at all beats the alternative of not trading.
    function test_AZeroFloorTakesWhateverTheBookOffers() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 1e18, 100e18, true); // dreadful, but better than nothing
        (SwapboardView.Fill[] memory f,, uint256 bout) = lens.previewPlanAtRate(c, 100e18, 0);
        assertEq(f.length, 1);
        assertEq(bout, 1e18);
    }
    // -------------------------------------------------------------- exact out

    function _planOut(SwapboardView.OrderView[] memory c, uint256 amountOut, uint256 baselineIn)
        internal
        view
        returns (SwapboardView.Fill[] memory f, uint256 bout, uint256 bin)
    {
        return lens.previewPlanOut(c, amountOut, baselineIn);
    }

    function test_OutBuysTheWholeOrderWhenItIsCheaperThanTheAmm() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 100e18, 90e18, false); // 100 out for 90 in
        (SwapboardView.Fill[] memory f, uint256 bout, uint256 bin) = _planOut(c, 100e18, 100e18);
        assertEq(f.length, 1);
        assertEq(bout, 100e18, "exactly what was asked for");
        assertEq(bin, 90e18, "for less than the AMM wanted");
    }

    function test_OutIgnoresOrdersDearerThanTheAmm() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 100e18, 110e18, true); // costs 1.10 against the AMM's 1.00
        (SwapboardView.Fill[] memory f,, uint256 bin) = _planOut(c, 100e18, 100e18);
        assertEq(f.length, 0);
        assertEq(bin, 0);
    }

    /// Cheapest cost per unit out first, which is the opposite ordering to the
    /// exact-in matcher rather than the same one read backwards.
    function test_OutTakesTheCheapestOrdersFirst() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](3);
        c[0] = _o(1, 50e18, 45e18, true); // 0.90
        c[1] = _o(2, 50e18, 40e18, true); // 0.80  <- cheapest
        c[2] = _o(3, 50e18, 60e18, true); // 1.20, dearer than the AMM
        (SwapboardView.Fill[] memory f, uint256 bout, uint256 bin) = _planOut(c, 100e18, 100e18);
        assertEq(f.length, 2, "the dear one is left to the AMM");
        assertEq(f[0].orderId, 2, "cheapest first");
        assertEq(f[1].orderId, 1);
        assertEq(bout, 100e18);
        assertEq(bin, 85e18);
    }

    /// The board derives output from the INPUT leg, so a payment rounded down
    /// lands short of the target and the plan quietly misses. Paying up is what
    /// makes exact-out actually exact.
    function test_OutRoundsThePaymentUpSoItNeverLandsShort() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 3e18, 1e18, true); // 3 out per 1 in - does not divide evenly
        (SwapboardView.Fill[] memory f, uint256 bout, uint256 bin) = _planOut(c, 1e18, 2e18);
        assertEq(f.length, 1);
        // Rounding down would pay 333333333333333333 and deliver 1 wei short.
        assertEq(bin, 333333333333333334, "paid up, not down");
        assertGe(bout, 1e18, "target met, never undershot");
        // And the reported output is what the board's own arithmetic gives.
        assertEq(bout, (bin * 3e18) / 1e18);
        assertTrue(f[0].isPartial);
    }

    /// An all-or-nothing block that pays more than is still wanted is skipped.
    /// The caller named an exact amount out; taking it would bill them for the
    /// excess they did not ask for.
    function test_OutSkipsAnAonBlockThatWouldOvershoot() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 100e18, 10e18, false); // AON, very cheap, but twice the size
        (SwapboardView.Fill[] memory f,, uint256 bin) = _planOut(c, 50e18, 60e18);
        assertEq(f.length, 0, "no overshoot on an exact-out request");
        assertEq(bin, 0);
    }

    /// Mirror of the exact-in seeding case: cheapest-first alone is not optimal,
    /// because a cheap partial taken early can leave too little room for an AON
    /// block that would have cost less in total.
    function test_OutPrefersALargeAonBlockOverACheaperPartial() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        c[0] = _o(1, 50e18, 40e18, true); // 0.80, but only covers half
        c[1] = _o(2, 100e18, 90e18, false); // 0.90 AON, covers the lot
        // AMM would charge 120 for the whole 100 out.
        (SwapboardView.Fill[] memory f, uint256 bout, uint256 bin) = _planOut(c, 100e18, 120e18);
        // Greedy: 40 for 50 out, then 50 out from the AMM at 1.20 = 60. Total 100.
        // Seeded: the AON alone, 90 for all 100 out. Total 90.
        assertEq(f.length, 1, "the AON block wins on total cost");
        assertEq(f[0].orderId, 2);
        assertEq(bout, 100e18);
        assertEq(bin, 90e18);
    }

    /// No AMM to fall back on opens the ceiling rather than closing it - the
    /// opposite of what a zero floor means on the exact-in side.
    function test_OutWithNoAmmAlternativeTakesWhatTheBookOffers() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 100e18, 500e18, true); // dreadful, but it is the only bid
        (SwapboardView.Fill[] memory f,, uint256 bin) = _planOut(c, 100e18, 0);
        assertEq(f.length, 1, "no alternative means no ceiling");
        assertEq(bin, 500e18);
    }

    function test_OutHandlesAnEmptyBookAndZeroTarget() public view {
        SwapboardView.OrderView[] memory none = new SwapboardView.OrderView[](0);
        (SwapboardView.Fill[] memory a,,) = _planOut(none, 100e18, 100e18);
        assertEq(a.length, 0);
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 100e18, 90e18, true);
        (SwapboardView.Fill[] memory b,,) = _planOut(c, 0, 100e18);
        assertEq(b.length, 0);
    }

    /// An order too large to price must not look free. The exact-in matcher
    /// sentinels the unrepresentable rate to 0 because 0 is its worst value;
    /// reusing that here would sort such an order to the front as costless.
    function test_OutDoesNotTreatAnUnpriceableOrderAsFree() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        c[0] = _o(1, 1, type(uint256).max, true); // cost cannot be expressed
        c[1] = _o(2, 100e18, 90e18, true);
        (SwapboardView.Fill[] memory f,, uint256 bin) = _planOut(c, 100e18, 100e18);
        assertEq(f.length, 1, "only the priceable one is taken");
        assertEq(f[0].orderId, 2);
        assertEq(bin, 90e18);
    }
}
