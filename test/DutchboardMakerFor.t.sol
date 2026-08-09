// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @notice Pins the unsigned funded-gift boundary of `listERC20For`.
/// @dev Naming a seller assigns ownership and settlement rights, but never
///      makes that seller the source of escrow. The immediate caller funds it.
contract DutchboardMakerForTest is Test {
    Dutchboard board;
    MockERC20 lot;
    MockERC20 quote;

    address sponsor = address(0x5D0);
    address seller = address(0xA11CE);
    address buyer = address(0xB0B);

    uint128 constant LOT = 10 ether;
    uint256 constant PRICE = 100e6;

    function setUp() public {
        board = new Dutchboard(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        lot = new MockERC20("LOT", 18);
        quote = new MockERC20("USD", 6);

        lot.mint(sponsor, 100 ether);
        vm.prank(sponsor);
        lot.approve(address(board), type(uint256).max);

        // A standing seller allowance is deliberately present: an unsafe
        // implementation that pulled from `seller` would silently succeed.
        lot.mint(seller, 50 ether);
        vm.prank(seller);
        lot.approve(address(board), type(uint256).max);

        quote.mint(buyer, 1_000e6);
        vm.prank(buyer);
        quote.approve(address(board), type(uint256).max);
    }

    function _sponsorListing() internal returns (uint256 id) {
        vm.prank(sponsor);
        id = board.listERC20For(seller, address(lot), address(quote), LOT, PRICE, PRICE, 0, 1 days, 0);
    }

    function test_namedSellerIsNotDebitedAndCallerFundsEscrow() public {
        uint256 sellerBalanceBefore = lot.balanceOf(seller);
        uint256 sellerAllowanceBefore = lot.allowance(seller, address(board));
        uint256 sponsorBalanceBefore = lot.balanceOf(sponsor);

        uint256 id = _sponsorListing();
        Dutchboard.ListingView memory listing = board.getListing(id);

        assertEq(lot.balanceOf(seller), sellerBalanceBefore, "named seller was debited");
        assertEq(lot.allowance(seller, address(board)), sellerAllowanceBefore, "named seller allowance was consumed");
        assertEq(lot.balanceOf(sponsor), sponsorBalanceBefore - LOT, "caller did not fund escrow");
        assertEq(lot.balanceOf(address(board)), LOT, "listing is not fully escrowed");
        assertEq(listing.seller, seller, "listing ownership was not assigned");
        assertEq(listing.remaining, LOT, "wrong resting amount");
    }

    function test_onlyNamedSellerCancelsAndReceivesProceedsAndRemainder() public {
        uint256 id = _sponsorListing();
        uint128 take = 4 ether;
        uint256 cost = board.costOf(id, take);

        uint256 sellerQuoteBefore = quote.balanceOf(seller);
        vm.prank(buyer);
        board.fill(id, take, buyer, cost);

        assertEq(quote.balanceOf(seller) - sellerQuoteBefore, cost, "fill proceeds missed seller");
        assertEq(lot.balanceOf(buyer), take, "buyer missed filled lot");

        vm.prank(sponsor);
        vm.expectRevert(Dutchboard.NotSeller.selector);
        board.cancel(id);

        uint256 sellerLotBefore = lot.balanceOf(seller);
        vm.prank(seller);
        board.cancel(id);

        assertEq(lot.balanceOf(seller) - sellerLotBefore, LOT - take, "remainder missed seller");
        assertEq(lot.balanceOf(address(board)), 0, "escrow remained after cancellation");
        assertEq(board.getListing(id).seller, address(0), "listing remained live");
    }

    function test_zeroSellerRejected() public {
        vm.prank(sponsor);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20For(address(0), address(lot), address(quote), LOT, PRICE, PRICE, 0, 1 days, 0);
    }

    function test_unreachableSellerAndZeroTokenRejected() public {
        vm.startPrank(sponsor);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20For(address(board), address(lot), address(quote), LOT, PRICE, PRICE, 0, 1 days, 0);

        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20For(
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, address(lot), address(quote), LOT, PRICE, PRICE, 0, 1 days
        , 0);

        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20For(seller, address(0), address(quote), LOT, PRICE, PRICE, 0, 1 days, 0);
        vm.stopPrank();
    }
}
