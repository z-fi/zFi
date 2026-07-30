// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {SwapboardView} from "../src/SwapboardView.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockERC721} from "./SwapboardMocks.sol";

/// @notice SwapboardView reading Dutchboard as a third board generation.
///
///         The point of the integration is that a Dutchboard row converts into the same
///         OrderView the matcher already consumes, so `previewPlan*` — which takes the
///         book as calldata — plans across a merged Swapboard + Dutchboard book with no
///         change to the matcher itself.
contract SwapboardViewDutchTest is Test {
    SwapboardView view_;
    Dutchboard board;
    MockERC20 SELL; // the lot
    MockERC20 PAY; // the quote

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");

    uint128 constant LOT = 100e18;

    function setUp() public {
        view_ = new SwapboardView();
        board = new Dutchboard();
        SELL = new MockERC20("SELL", 18);
        PAY = new MockERC20("PAY", 18);
    }

    function _list(uint256 startPrice, uint256 endPrice) internal returns (uint256 id) {
        SELL.mint(maker, LOT);
        vm.startPrank(maker);
        SELL.approve(address(board), LOT);
        id = board.listERC20(address(SELL), address(PAY), LOT, startPrice, endPrice, 0, 1 hours);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- CONVERSION

    /// A live listing surfaces with the pair the right way round and a rate that matches
    /// what the board will actually charge.
    function test_listingConvertsWithLiveCost() public {
        uint256 id = _list(200e18, 100e18);
        skip(30 minutes);

        (SwapboardView.OrderView[] memory rows,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);

        assertEq(rows.length, 1, "listing not surfaced");
        assertEq(rows[0].orderId, id, "wrong id");
        assertEq(rows[0].maker, maker, "wrong maker");
        assertEq(rows[0].tokenA, address(SELL), "tokenA is what the taker receives");
        assertEq(rows[0].tokenB, address(PAY), "tokenB is what the taker pays");
        assertEq(rows[0].amountA, LOT, "amountA is the remainder");
        assertTrue(rows[0].partialFill, "ERC20 lots are partially fillable");
        assertEq(rows[0].expiry, 0, "Dutchboard listings never expire");
        assertEq(rows[0].board, address(board), "board not stamped");

        // The quoted cost must equal the board's own costOf for the same size.
        assertEq(rows[0].amountB, board.costOf(id, LOT), "quoted cost disagrees with the board");
    }

    /// The row is a quote with the lifetime of the call: it decays with the schedule.
    function test_quotedCostDecaysBetweenCalls() public {
        _list(200e18, 100e18);

        (SwapboardView.OrderView[] memory early,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);
        skip(30 minutes);
        (SwapboardView.OrderView[] memory late,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);

        assertLt(late[0].amountB, early[0].amountB, "cost did not decay");
        assertEq(late[0].amountA, early[0].amountA, "remainder should be unchanged");
    }

    /// A partially filled listing reports the remainder, and its unit rate is unchanged —
    /// the property that lets the matcher treat it like any constant-rate order.
    function test_partialFillLeavesUnitRateIntact() public {
        uint256 id = _list(200e18, 100e18);
        skip(30 minutes);

        (SwapboardView.OrderView[] memory before,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);
        uint256 rateBefore = before[0].amountA * 1e18 / before[0].amountB;

        PAY.mint(taker, type(uint128).max);
        vm.startPrank(taker);
        PAY.approve(address(board), type(uint256).max);
        board.fill(id, LOT / 4, taker, type(uint256).max);
        vm.stopPrank();

        (SwapboardView.OrderView[] memory afterFill,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);

        assertEq(afterFill[0].amountA, LOT - LOT / 4, "remainder not reported");
        uint256 rateAfter = afterFill[0].amountA * 1e18 / afterFill[0].amountB;
        assertApproxEqRel(rateAfter, rateBefore, 1e12, "unit rate moved on a partial fill");
    }

    /// The matcher's proportional leg must be payable at the board. This is the claim
    /// that `maxCost = payIn` is always sufficient.
    function test_plannedLegIsPayableAtTheBoard() public {
        uint256 id = _list(200e18, 100e18);
        skip(20 minutes);

        (SwapboardView.OrderView[] memory rows,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);

        // What the matcher does: floor getOut from a payIn budget.
        uint256 payIn = rows[0].amountB / 3;
        uint256 getOut = payIn * rows[0].amountA / rows[0].amountB;
        assertGt(getOut, 0, "degenerate leg");

        PAY.mint(taker, payIn);
        vm.startPrank(taker);
        PAY.approve(address(board), payIn);
        // maxCost = payIn, exactly as the encoding rule prescribes.
        board.fill(id, uint128(getOut), taker, payIn);
        vm.stopPrank();

        assertEq(SELL.balanceOf(taker), getOut, "leg did not deliver the planned output");
        assertLe(PAY.balanceOf(maker), payIn, "board charged more than the planned payIn");
    }

    // ---------------------------------------------------------------- FILTERING

    function test_closedListingsAreNotSurfaced() public {
        uint256 id = _list(200e18, 100e18);
        vm.prank(maker);
        board.cancel(id);

        (SwapboardView.OrderView[] memory rows,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);
        assertEq(rows.length, 0, "cancelled listing surfaced");
    }

    function test_wrongDirectionIsFiltered() public {
        _list(200e18, 100e18);
        // Asking for the reverse pair: nothing sells PAY for SELL.
        (SwapboardView.OrderView[] memory rows,) =
            view_.dutchCandidatesFrom(address(board), address(SELL), address(PAY), taker, 0, 100);
        assertEq(rows.length, 0, "matched the wrong direction");
    }

    /// NFT bundles have no faithful single-tokenId representation, so they are skipped;
    /// a one-NFT lot converts exactly.
    function test_nftBundleSkippedSingleSurfaced() public {
        MockERC721 nft = new MockERC721();
        uint256[] memory two = new uint256[](2);
        (two[0], two[1]) = (1, 2);
        uint256[] memory one = new uint256[](1);
        one[0] = 3;

        vm.startPrank(maker);
        nft.mint(maker, 1);
        nft.mint(maker, 2);
        nft.mint(maker, 3);
        nft.setApprovalForAll(address(board), true);
        board.listNFT(address(nft), address(PAY), two, 50e18, 10e18, 0, 1 hours);
        board.listNFT(address(nft), address(PAY), one, 50e18, 10e18, 0, 1 hours);
        vm.stopPrank();

        (SwapboardView.OrderView[] memory rows,) = view_.getActiveDutchListingsPaged(address(board), 0, 100, 100);
        assertEq(rows.length, 1, "expected only the single-NFT lot");
        assertTrue(rows[0].nftA, "not flagged as an NFT lot");
        assertEq(rows[0].amountA, 3, "amountA must be the tokenId");
    }

    function test_pagedListingReadsEverything() public {
        for (uint256 i; i < 5; ++i) {
            _list(200e18, 100e18);
        }
        (SwapboardView.OrderView[] memory rows, uint256 next) =
            view_.getActiveDutchListingsPaged(address(board), 0, 100, 100);
        assertEq(rows.length, 5, "not all listings paged");
        assertEq(next, 0, "should report no further pages");
    }

    function test_recentDutchDisplayPagesNewestFirst() public {
        _list(200e18, 100e18);
        _list(160e18, 80e18);

        (SwapboardView.OrderView[] memory rows, uint256 next) = view_.getRecentDutchListings(address(board), 0, 1, 100);
        assertEq(rows.length, 1, "one display row");
        assertEq(rows[0].orderId, 1, "newest first");
        assertEq(next, 1, "resume below returned row");

        (rows, next) = view_.getRecentDutchListings(address(board), next, 10, 100);
        assertEq(rows.length, 1, "remaining display row");
        assertEq(rows[0].orderId, 0, "oldest row");
        assertEq(next, 0, "complete");
    }

    function test_emptyBoardIsSafe() public {
        (SwapboardView.OrderView[] memory rows, uint256 next) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);
        assertEq(rows.length, 0, "rows from an empty board");
        assertEq(next, 0, "cursor from an empty board");
    }

    // ------------------------------------------------------------- MERGED PLAN

    function test_freeFloorListingIsDiscoveredAndPlannedExactIn() public {
        uint256 id = _list(1, 0);
        skip(1 hours);
        assertEq(board.costOf(id, LOT), 0, "listing has reached its free floor");

        (SwapboardView.OrderView[] memory rows,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);
        assertEq(rows.length, 1, "free listing must remain discoverable");
        assertEq(rows[0].amountB, 0, "free cost must be represented exactly");

        (SwapboardView.Fill[] memory fills, uint256 bookIn, uint256 bookOut) =
            view_.previewPlanAtRate(rows, 0, type(uint256).max);
        assertEq(fills.length, 1, "free row must clear any paid AMM floor");
        assertEq(fills[0].payIn, 0, "free row consumes no input");
        assertEq(fills[0].getOut, LOT, "exact-in takes the whole free remainder");
        assertFalse(fills[0].isPartial, "the whole free row is taken");
        assertEq(bookIn, 0);
        assertEq(bookOut, LOT);

        vm.prank(taker);
        board.fill(id, uint128(fills[0].getOut), taker, fills[0].payIn);
        assertEq(SELL.balanceOf(taker), LOT, "zero-pay plan executes at Dutchboard");
        assertEq(PAY.balanceOf(maker), 0, "maker is not charged a phantom payment");
    }

    function test_freeFloorListingIsPlannedExactOutWithoutOverbuying() public {
        uint256 id = _list(1, 0);
        skip(1 hours);

        (SwapboardView.OrderView[] memory rows,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);
        uint256 wanted = LOT / 3;
        (SwapboardView.Fill[] memory fills, uint256 bookOut, uint256 bookIn) =
            view_.previewPlanOutAtRate(rows, wanted, 0);

        assertEq(fills.length, 1, "free row must clear a zero cost ceiling");
        assertEq(fills[0].payIn, 0, "free row has maxCost zero");
        assertEq(fills[0].getOut, wanted, "exact-out names only the requested output");
        assertTrue(fills[0].isPartial, "the free remainder stays listed");
        assertEq(bookIn, 0);
        assertEq(bookOut, wanted);

        vm.prank(taker);
        board.fill(id, uint128(fills[0].getOut), taker, fills[0].payIn);
        assertEq(SELL.balanceOf(taker), wanted, "zero-pay exact-out plan executes");
        (SwapboardView.OrderView[] memory afterFill,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);
        assertEq(afterFill.length, 1, "unbought free remainder remains discoverable");
        assertEq(afterFill[0].amountA, LOT - wanted);
        assertEq(afterFill[0].amountB, 0);
    }

    /// The payoff: rows from Dutchboard feed the existing matcher unchanged, because
    /// previewPlan takes the book as calldata and never asks which board a row is from.
    function test_previewPlanAcceptsDutchRows() public {
        _list(200e18, 100e18);
        _list(160e18, 80e18);
        skip(30 minutes);

        (SwapboardView.OrderView[] memory rows,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);
        assertEq(rows.length, 2, "expected both listings");

        // Budget enough to clear the cheaper listing, with a floor rate that both beat.
        uint256 amountIn = rows[0].amountB + rows[1].amountB;
        (SwapboardView.Fill[] memory fills, uint256 bookIn, uint256 bookOut) =
            view_.previewPlanAtRate(rows, amountIn, 1);

        assertGt(fills.length, 0, "matcher produced no legs");
        assertGt(bookOut, 0, "matcher claimed no output");
        assertLe(bookIn, amountIn, "matcher overspent the budget");
        for (uint256 i; i < fills.length; ++i) {
            assertEq(fills[i].board, address(board), "leg not attributed to Dutchboard");
        }
    }

    /// previewPlan* take the caller's book verbatim - no _usable filter runs on
    /// them - so a zero-output row reaches the rate/cost divides directly. It
    /// must remain an unrepresentable row that is skipped rather than reverting
    /// the whole preview. A zero INPUT amount is different: that is the valid
    /// free-Dutch sentinel covered above.
    function test_previewPlanSurvivesZeroOutputRows() public {
        _list(200e18, 100e18);
        skip(30 minutes);

        (SwapboardView.OrderView[] memory good,) =
            view_.dutchCandidatesFrom(address(board), address(PAY), address(SELL), taker, 0, 100);
        assertEq(good.length, 1, "expected one listing");

        uint256 amountIn = good[0].amountB;
        uint256 amountOut = good[0].amountA;

        SwapboardView.OrderView[] memory rows = new SwapboardView.OrderView[](2);
        rows[0] = good[0];
        // Memory structs are reference types, so this has to be a deep copy or
        // zeroing one field would zero it on the good row too.
        rows[1] = _clone(good[0]);
        rows[1].amountA = 0;
        (SwapboardView.Fill[] memory fills,, uint256 bookOut) = view_.previewPlanAtRate(rows, amountIn, 1);
        assertGt(fills.length, 0, "exact-in must still match the good row");
        assertGt(bookOut, 0, "exact-in produced no output");

        (SwapboardView.Fill[] memory outFills,,) = view_.previewPlanOutAtRate(rows, amountOut, type(uint256).max);
        assertGt(outFills.length, 0, "exact-out must still match the good row");

        // And a book made only of degenerate rows must come back empty, not revert.
        SwapboardView.OrderView[] memory onlyBad = new SwapboardView.OrderView[](1);
        onlyBad[0] = rows[1];
        (SwapboardView.Fill[] memory none,, uint256 zero) = view_.previewPlanAtRate(onlyBad, amountIn, 1);
        assertEq(none.length, 0, "no legs from a degenerate book");
        assertEq(zero, 0, "no output from a degenerate book");
    }

    /// Deep copy - memory structs alias on assignment.
    function _clone(SwapboardView.OrderView memory o) internal pure returns (SwapboardView.OrderView memory) {
        return abi.decode(abi.encode(o), (SwapboardView.OrderView));
    }
}
