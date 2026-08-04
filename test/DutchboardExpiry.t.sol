// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// @dev Covers the three things Dutchboard gained before deploy: a hard expiry,
///      the permissionless sweep that makes expiry self-clearing, and partial
///      withdrawal.
contract DutchboardExpiryTest is Test {
    Dutchboard board;
    MockWETH weth;
    MockERC20 usdc;
    MockERC20 tkn;
    MockNFT nft;

    address seller = address(0x5E11);
    address buyer = address(0xB0B);

    uint128 constant LOT = 1000e18;
    uint256 constant START = 200e18;
    uint256 constant END = 100e18;
    uint40 constant DUR = 1000;

    function setUp() public {
        vm.warp(10_000);
        weth = new MockWETH();
        usdc = new MockERC20("USDC", 6);
        tkn = new MockERC20("TKN", 18);
        nft = new MockNFT();
        board = new Dutchboard(address(weth));

        tkn.mint(seller, 1_000_000e18);
        usdc.mint(buyer, 1_000_000e18);
        vm.prank(seller);
        tkn.approve(address(board), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(board), type(uint256).max);
    }

    function _list(uint40 expiry) internal returns (uint256 id) {
        vm.prank(seller);
        id = board.listERC20(address(tkn), address(usdc), LOT, START, END, 0, DUR, expiry);
    }

    // ------------------------------------------------------- BACKWARD COMPAT

    /// @dev `expiry == 0` must keep the documented resting-floor behaviour that
    ///      every pre-expiry caller was written against.
    function testZeroExpiryStillRestsAtEndPriceForever() public {
        vm.prank(seller);
        uint256 id = board.listERC20(address(tkn), address(usdc), LOT, START, END, 0, DUR);

        vm.warp(block.timestamp + DUR * 100);
        assertEq(board.priceOf(id), END);
        (bool ok, uint256 cost) = board.quoteFill(id, LOT);
        assertTrue(ok);
        assertEq(cost, END);

        vm.prank(buyer);
        board.fill(id, LOT, buyer, type(uint256).max);
        assertEq(tkn.balanceOf(buyer), LOT);
    }

    function testZeroExpiryCannotBeSwept() public {
        vm.prank(seller);
        uint256 id = board.listERC20(address(tkn), address(usdc), LOT, START, END, 0, DUR);
        vm.warp(block.timestamp + DUR * 100);
        vm.expectRevert(Dutchboard.NotExpired.selector);
        board.sweepExpired(id);
    }

    // ------------------------------------------------------------- EXPIRY

    function testFillRevertsPastExpiry() public {
        uint40 expiry = uint40(block.timestamp + DUR);
        uint256 id = _list(expiry);

        vm.warp(uint256(expiry) + 1);
        vm.prank(buyer);
        vm.expectRevert(Dutchboard.Expired.selector);
        board.fill(id, LOT, buyer, type(uint256).max);
    }

    /// @dev Inclusive, matching Swapboard: a fill landing exactly on `expiry`
    ///      still settles.
    function testExpiryIsInclusive() public {
        uint40 expiry = uint40(block.timestamp + DUR);
        uint256 id = _list(expiry);

        vm.warp(expiry);
        vm.prank(buyer);
        board.fill(id, LOT, buyer, type(uint256).max);
        assertEq(tkn.balanceOf(buyer), LOT);
    }

    function testQuotesReportExpiredAsUnfillable() public {
        uint40 expiry = uint40(block.timestamp + DUR);
        uint256 id = _list(expiry);
        vm.warp(uint256(expiry) + 1);

        (bool ok, uint256 cost) = board.quoteFill(id, LOT);
        assertFalse(ok);
        assertEq(cost, 0);
        assertEq(board.costOf(id, LOT), 0);

        (uint128 take, uint256 spend) = board.takeFor(id, type(uint256).max);
        assertEq(take, 0);
        assertEq(spend, 0);

        (address s,,,,,,) = board.legOf(id);
        assertEq(s, address(0));

        assertFalse(board.getListing(id).takeable);
    }

    function testRejectsAnExpiryInThePastOrBeforeStart() public {
        vm.prank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(address(tkn), address(usdc), LOT, START, END, 0, DUR, uint40(block.timestamp));

        uint40 later = uint40(block.timestamp + 5000);
        vm.prank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(address(tkn), address(usdc), LOT, START, END, later, DUR, later);
    }

    /// @dev A stale leg must be skipped, not abort the batch.
    function testTryFillManySkipsExpiredLegs() public {
        uint40 expiry = uint40(block.timestamp + 10);
        uint256 dying = _list(expiry);
        vm.prank(seller);
        uint256 living = board.listERC20(address(tkn), address(usdc), LOT, START, END, 0, DUR);

        vm.warp(uint256(expiry) + 1);

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (dying, living);
        uint128[] memory takes = new uint128[](2);
        (takes[0], takes[1]) = (LOT, LOT);
        uint256[] memory maxes = new uint256[](2);
        (maxes[0], maxes[1]) = (type(uint256).max, type(uint256).max);

        vm.prank(buyer);
        (bool[] memory filled,) = board.tryFillMany(ids, takes, maxes, buyer);
        assertFalse(filled[0]);
        assertTrue(filled[1]);
        assertEq(tkn.balanceOf(buyer), LOT);
    }

    // -------------------------------------------------------------- SWEEP

    function testAnyoneSweepsExpiredEscrowBackToTheHolder() public {
        uint40 expiry = uint40(block.timestamp + DUR);
        uint256 id = _list(expiry);
        uint256 sellerBefore = tkn.balanceOf(seller);

        vm.warp(uint256(expiry) + 1);
        address keeper = address(0xBEEF);
        vm.prank(keeper);
        board.sweepExpired(id);

        assertEq(tkn.balanceOf(seller) - sellerBefore, LOT);
        assertEq(tkn.balanceOf(keeper), 0);
        assertEq(board.escrowed(address(tkn)), 0);
    }

    function testSweepBeforeExpiryReverts() public {
        uint40 expiry = uint40(block.timestamp + DUR);
        uint256 id = _list(expiry);
        vm.warp(uint256(expiry) - 1);
        vm.expectRevert(Dutchboard.NotExpired.selector);
        board.sweepExpired(id);
    }

    function testSweepReturnsAnExpiredNFTBundle() public {
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (1, 2);
        nft.mint(seller, 1);
        nft.mint(seller, 2);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(board), true);
        uint40 expiry = uint40(block.timestamp + DUR);
        uint256 id = board.listNFT(address(nft), address(usdc), ids, START, END, 0, DUR, expiry);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), address(board));

        vm.warp(uint256(expiry) + 1);
        board.sweepExpired(id);
        assertEq(nft.ownerOf(1), seller);
        assertEq(nft.ownerOf(2), seller);
    }

    /// @dev A sweep after a partial fill returns only the unsold remainder.
    function testSweepAfterPartialFillReturnsTheRemainder() public {
        uint40 expiry = uint40(block.timestamp + DUR);
        uint256 id = _list(expiry);

        vm.prank(buyer);
        board.fill(id, LOT / 4, buyer, type(uint256).max);

        uint256 sellerBefore = tkn.balanceOf(seller);
        vm.warp(uint256(expiry) + 1);
        board.sweepExpired(id);
        assertEq(tkn.balanceOf(seller) - sellerBefore, LOT - LOT / 4);
        assertEq(board.escrowed(address(tkn)), 0);
    }

    // ------------------------------------------------------ PUSH LISTINGS

    function testPushListingAcceptsBothPayloadLengths() public {
        nft.mint(seller, 7);
        vm.prank(seller);
        nft.transferFrom(seller, address(board), 7);

        // 160 bytes: the original terms, no expiry.
        bytes memory legacy = abi.encode(
            Dutchboard.PushTerms({
                quote: address(usdc),
                startPrice: START,
                endPrice: END,
                startTime: 0,
                duration: DUR
            })
        );
        assertEq(legacy.length, 160);
        vm.prank(address(nft));
        board.onERC721Received(address(0), seller, 7, legacy);
        (,,,,,,,,,, uint40 noExpiry) = board.listings(0);
        assertEq(noExpiry, 0);

        // 192 bytes: same terms plus a hard stop.
        nft.mint(seller, 8);
        vm.prank(seller);
        nft.transferFrom(seller, address(board), 8);
        uint40 expiry = uint40(block.timestamp + DUR);
        bytes memory extended = abi.encode(
            Dutchboard.PushTermsExpiring({
                quote: address(usdc),
                startPrice: START,
                endPrice: END,
                startTime: 0,
                duration: DUR,
                expiry: expiry
            })
        );
        assertEq(extended.length, 192);
        vm.prank(address(nft));
        board.onERC721Received(address(0), seller, 8, extended);
        (,,,,,,,,,, uint40 got) = board.listings(1);
        assertEq(got, expiry);
    }

    function testPushListingRejectsAMalformedPayload() public {
        nft.mint(seller, 9);
        vm.prank(seller);
        nft.transferFrom(seller, address(board), 9);
        vm.prank(address(nft));
        vm.expectRevert(Dutchboard.Bad.selector);
        board.onERC721Received(address(0), seller, 9, hex"1234");
    }

    // ----------------------------------------------------------- WITHDRAW

    function testPartialWithdrawKeepsThePerUnitPrice() public {
        uint256 id = _list(0);
        uint256 unitBefore = board.costOf(id, 100e18);
        uint256 sellerBefore = tkn.balanceOf(seller);

        vm.prank(seller);
        board.withdraw(id, 400e18, false);

        assertEq(tkn.balanceOf(seller) - sellerBefore, 400e18);
        assertEq(board.escrowed(address(tkn)), LOT - 400e18);
        assertEq(board.withdrawn(id), 400e18);
        // `initial` is the price denominator and was untouched.
        assertEq(board.costOf(id, 100e18), unitBefore);
    }

    function testWithdrawShrinksWhatCanBeFilled() public {
        uint256 id = _list(0);
        vm.prank(seller);
        board.withdraw(id, 600e18, false);

        (bool ok,) = board.quoteFill(id, LOT);
        assertFalse(ok); // the full original lot is no longer available
        (ok,) = board.quoteFill(id, 400e18);
        assertTrue(ok);

        vm.prank(buyer);
        board.fill(id, 400e18, buyer, type(uint256).max);
        assertEq(tkn.balanceOf(buyer), 400e18);
    }

    function testWithdrawCannotEmptyTheLot() public {
        uint256 id = _list(0);
        vm.prank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.withdraw(id, LOT, false);
    }

    function testOnlySellerWithdraws() public {
        uint256 id = _list(0);
        vm.prank(buyer);
        vm.expectRevert(Dutchboard.NotSeller.selector);
        board.withdraw(id, 1e18, false);
    }

    function testNFTLotsCannotBePartiallyWithdrawn() public {
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (1, 2);
        nft.mint(seller, 1);
        nft.mint(seller, 2);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(usdc), ids, START, END, 0, DUR);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.withdraw(id, 1, false);
        vm.stopPrank();
    }

    function testWithdrawUnwrapsAWETHLot() public {
        vm.deal(seller, 10 ether);
        vm.prank(seller);
        uint256 id = board.listETH{value: 10 ether}(address(usdc), START, END, 0, DUR);

        uint256 before = seller.balance;
        vm.prank(seller);
        board.withdraw(id, 4 ether, true);
        assertEq(seller.balance - before, 4 ether);
        assertEq(board.escrowed(address(weth)), 6 ether);
    }

    function testSolvencyHoldsAcrossWithdrawAndSweep() public {
        uint40 expiry = uint40(block.timestamp + DUR);
        uint256 id = _list(expiry);

        vm.prank(buyer);
        board.fill(id, 250e18, buyer, type(uint256).max);
        vm.prank(seller);
        board.withdraw(id, 250e18, false);
        assertGe(tkn.balanceOf(address(board)), board.escrowed(address(tkn)));

        vm.warp(uint256(expiry) + 1);
        board.sweepExpired(id);
        assertEq(board.escrowed(address(tkn)), 0);
        assertEq(tkn.balanceOf(address(board)), 0);
    }
}
