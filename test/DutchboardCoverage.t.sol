// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// Gaps left by the existing Dutchboard suites: the exact-input primitive
/// `takeFor` (2 call sites), `tryFillMany`'s ETH budget accounting (2), and the
/// payout guards on `claimSurplus`.
contract DutchboardCoverageTest is Test {
    Dutchboard board;
    MockWETH weth;
    MockERC20 sell;
    MockERC20 pay;

    address seller = address(0x5E11);
    address buyer = address(0xB0B);

    uint128 constant LOT = 1000e18;
    uint256 constant START = 200e18;
    uint256 constant END = 100e18;
    uint40 constant DUR = 1000;

    function setUp() public {
        vm.warp(10_000);
        weth = new MockWETH();
        sell = new MockERC20("S", 18);
        pay = new MockERC20("P", 18);
        board = new Dutchboard(address(weth));

        sell.mint(seller, 1_000_000e18);
        pay.mint(buyer, 1_000_000e18);
        vm.prank(seller);
        sell.approve(address(board), type(uint256).max);
        vm.prank(buyer);
        pay.approve(address(board), type(uint256).max);
    }

    function _list() internal returns (uint256 id) {
        vm.prank(seller);
        id = board.listERC20(address(sell), address(pay), LOT, START, END, 0, DUR, 0);
    }

    function _listETHQuoted() internal returns (uint256 id) {
        vm.prank(seller);
        id = board.listERC20(address(sell), address(0), LOT, START, END, 0, DUR, 0);
    }

    // ------------------------------------------------------- takeFor

    /// The contract it advertises: whatever `takeFor` returns is affordable at
    /// the budget, and feeding it back into `fill` never trips `CostExceeded`.
    function testFuzz_takeForIsAffordableByConstruction(uint256 budget, uint40 elapsed) public {
        budget = bound(budget, 0, 500e18);
        elapsed = uint40(bound(elapsed, 0, DUR - 1));
        uint256 id = _list();
        skip(elapsed);

        (uint128 take, uint256 cost) = board.takeFor(id, budget);
        if (take == 0) return;

        assertLe(cost, budget, "never quotes above the budget");
        (bool ok, uint256 quoted) = board.quoteFill(id, take);
        assertTrue(ok, "the quantity it returns is fillable");
        assertEq(quoted, cost, "and agrees with the board's own quote");

        vm.prank(buyer);
        board.fill(id, take, buyer, cost); // exact maxCost: must not revert
        assertEq(sell.balanceOf(buyer), take);
    }

    /// The whole remainder is the first branch, so a budget that covers the lot
    /// buys all of it rather than a rounded-down slice.
    function test_takeForBuysTheWholeLotWhenAffordable() public {
        uint256 id = _list();
        (uint128 take, uint256 cost) = board.takeFor(id, type(uint256).max);
        assertEq(take, LOT, "the entire remainder");
        assertEq(cost, START, "at the opening price");
    }

    function test_takeForReportsNothingForAClosedListing() public {
        uint256 id = _list();
        vm.prank(seller);
        board.cancel(id);
        (uint128 take, uint256 cost) = board.takeFor(id, type(uint256).max);
        assertEq(take, 0);
        assertEq(cost, 0);
    }

    // --------------------------------------------------- tryFillMany budget

    /// The batch spends against a running remainder, not the original
    /// `msg.value`: once the budget is exhausted later ETH legs are skipped
    /// rather than reverting, and the unspent balance goes back.
    function test_tryFillManyStopsAtTheEthBudgetAndRefundsTheRest() public {
        uint256 a = _listETHQuoted();
        uint256 b = _listETHQuoted();

        uint256[] memory ids = new uint256[](2);
        uint128[] memory takes = new uint128[](2);
        uint256[] memory maxCosts = new uint256[](2);
        (ids[0], takes[0], maxCosts[0]) = (a, LOT, type(uint256).max);
        (ids[1], takes[1], maxCosts[1]) = (b, LOT, type(uint256).max);

        // Enough for exactly one leg at the opening price.
        vm.deal(buyer, START);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        (bool[] memory filled, uint256 spent) = board.tryFillMany{value: START}(ids, takes, maxCosts, buyer);

        assertTrue(filled[0], "first leg affordable");
        assertFalse(filled[1], "second leg skipped, not reverted");
        assertEq(spent, START, "spent exactly the budget");
        assertEq(before - buyer.balance, START, "and nothing was stranded");
        assertEq(sell.balanceOf(buyer), LOT);
    }

    function test_tryFillManySkipsClosedAndOverpricedLegs() public {
        uint256 live = _list();
        uint256 closed = _list();
        uint256 overpriced = _list();
        vm.prank(seller);
        board.cancel(closed);

        uint256[] memory ids = new uint256[](3);
        uint128[] memory takes = new uint128[](3);
        uint256[] memory maxCosts = new uint256[](3);
        (ids[0], takes[0], maxCosts[0]) = (live, 100e18, type(uint256).max);
        (ids[1], takes[1], maxCosts[1]) = (closed, 100e18, type(uint256).max);
        (ids[2], takes[2], maxCosts[2]) = (overpriced, 100e18, 1); // below its cost

        vm.prank(buyer);
        (bool[] memory filled,) = board.tryFillMany(ids, takes, maxCosts, buyer);
        assertTrue(filled[0]);
        assertFalse(filled[1], "closed listing skipped");
        assertFalse(filled[2], "maxCost miss skipped");
    }

    /// A bad recipient is the caller's own error, so it must fail loudly rather
    /// than silently reporting an all-skipped batch as a success.
    function test_tryFillManyRejectsABadRecipientLoudly() public {
        uint256 id = _list();
        uint256[] memory ids = new uint256[](1);
        uint128[] memory takes = new uint128[](1);
        uint256[] memory maxCosts = new uint256[](1);
        (ids[0], takes[0], maxCosts[0]) = (id, 100e18, type(uint256).max);

        vm.prank(buyer);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.tryFillMany(ids, takes, maxCosts, address(board));

        vm.prank(buyer);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.tryFillMany(ids, takes, maxCosts, address(weth));
    }

    // ------------------------------------------------------ payout guards

    /// `claimSurplus` used to accept `weth` as a destination while every sibling
    /// payout path refused it. A payout to the wrapper credits the wrapper's own
    /// balance, which nobody can ever withdraw.
    function test_claimSurplusRefusesTheWrapperAndTheBoard() public {
        uint256 id = _list();
        vm.startPrank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.claimSurplus(id, address(pay), address(weth));
        vm.expectRevert(Dutchboard.Bad.selector);
        board.claimSurplus(id, address(pay), address(board));
        vm.expectRevert(Dutchboard.Bad.selector);
        board.claimSurplus(id, address(pay), address(0));
        vm.stopPrank();
    }

    function test_claimSurplusIsOwnerOnly() public {
        uint256 id = _list();
        vm.prank(buyer);
        vm.expectRevert(Dutchboard.NotSeller.selector);
        board.claimSurplus(id, address(pay), buyer);
    }

    // ---------------------------------------------------------- self-fill

    /// The listing holder buying their own lot moves their own escrow and pays
    /// nothing - `_payQuoteToken` short-circuits when payer and payee match.
    /// It is equivalent to cancelling, and indexers should not read the `Filled`
    /// event as an arm's-length sale.
    function test_holderCanTakeTheirOwnLotWithoutPaying() public {
        uint256 id = _list();
        uint256 before = pay.balanceOf(seller);

        vm.prank(seller);
        board.fill(id, LOT, seller, type(uint256).max);

        assertEq(pay.balanceOf(seller), before, "no quote changed hands");
        assertEq(sell.balanceOf(seller), 1_000_000e18, "the lot came back whole");
        assertEq(board.escrowed(address(sell)), 0, "escrow released");
    }

    /// ...but a third party filling into the seller still pays in full.
    function test_thirdPartyFillingToTheSellerStillPays() public {
        uint256 id = _list();
        uint256 cost = board.costOf(id, LOT);

        vm.prank(buyer);
        board.fill(id, LOT, seller, type(uint256).max);

        assertEq(pay.balanceOf(seller), cost, "seller was paid");
        assertEq(sell.balanceOf(seller), 1_000_000e18 - LOT + LOT, "and delivery went where asked");
    }
}
