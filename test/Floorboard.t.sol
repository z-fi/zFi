// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

contract FloorboardTest is Test {
    Floorboard board;
    MockWETH weth;
    MockERC20 usdc; // quote
    MockERC20 tkn; // what the bidder wants
    MockNFT nft;

    address bidder = address(0xB1D);
    address seller = address(0x5E11);

    uint128 constant WANT = 1000e18;
    uint256 constant START = 100e18;
    uint256 constant END = 200e18;
    uint40 constant DUR = 1000;

    function setUp() public {
        vm.warp(10_000);
        weth = new MockWETH();
        usdc = new MockERC20("USDC", 6);
        tkn = new MockERC20("TKN", 18);
        nft = new MockNFT();
        board = new Floorboard(address(weth));

        usdc.mint(bidder, 1_000_000e18);
        tkn.mint(seller, 1_000_000e18);
        vm.prank(bidder);
        usdc.approve(address(board), type(uint256).max);
        vm.prank(seller);
        tkn.approve(address(board), type(uint256).max);
    }

    function _terms() internal view returns (Floorboard.Terms memory t) {
        t = Floorboard.Terms({
            token: address(tkn),
            quote: address(usdc),
            want: WANT,
            startPrice: START,
            endPrice: END,
            startTime: 0,
            duration: DUR,
            isNFT: false,
            ids: new uint256[](0)
        });
    }

    function _open() internal returns (uint256 id) {
        vm.prank(bidder);
        id = board.bid(_terms());
    }

    // ------------------------------------------------------------- CREATION

    function testEscrowsTheCeilingNotTheStart() public {
        uint256 before = usdc.balanceOf(bidder);
        uint256 id = _open();
        // The bid can never owe more than `endPrice`, and it escrows exactly that.
        assertEq(before - usdc.balanceOf(bidder), END);
        assertEq(usdc.balanceOf(address(board)), END);
        assertEq(board.escrowed(address(usdc)), END);
        (,,,,,,,, uint96 locked,,) = board.bids(id);
        assertEq(locked, uint96(END));
        assertEq(board.ownerOf(id), bidder);
    }

    function testRejectsADescendingSchedule() public {
        Floorboard.Terms memory t = _terms();
        (t.startPrice, t.endPrice) = (END, START);
        vm.prank(bidder);
        vm.expectRevert(Floorboard.Bad.selector);
        board.bid(t);
    }

    function testFlatScheduleIsALimitBid() public {
        Floorboard.Terms memory t = _terms();
        t.endPrice = t.startPrice;
        vm.prank(bidder);
        uint256 id = board.bid(t);
        assertEq(board.priceOf(id), START);
        vm.warp(block.timestamp + DUR - 1);
        assertEq(board.priceOf(id), START);
    }

    // ---------------------------------------------------------------- CLIMB

    function testBidClimbsLinearly() public {
        uint256 id = _open();
        assertEq(board.priceOf(id), START);
        vm.warp(block.timestamp + DUR / 2);
        assertEq(board.priceOf(id), START + (END - START) / 2);
        vm.warp(block.timestamp + DUR / 2);
        assertEq(board.priceOf(id), END);
    }

    // ----------------------------------------------------------------- HITS

    function testPartialHitPaysProRata() public {
        uint256 id = _open();
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(seller);
        uint256 paid = board.hit(id, WANT / 2, 0, false);

        assertEq(paid, START / 2); // half the lot at the opening price
        assertEq(usdc.balanceOf(seller) - sellerBefore, paid);
        assertEq(tkn.balanceOf(bidder), WANT / 2);
        (,,,,,,,, uint96 locked,, uint128 remaining) = board.bids(id);
        assertEq(remaining, WANT / 2);
        assertEq(locked, uint96(END - paid));
        assertEq(board.escrowed(address(usdc)), END - paid);
    }

    function testFullBuyoutRefundsTheUnspentCeiling() public {
        uint256 id = _open();
        uint256 bidderBefore = usdc.balanceOf(bidder);

        vm.prank(seller);
        uint256 paid = board.hit(id, WANT, 0, false);

        assertEq(paid, START);
        // Escrow was END; the bid was taken at START, so the difference comes back.
        assertEq(usdc.balanceOf(bidder) - bidderBefore, END - START);
        assertEq(board.escrowed(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(board)), 0);
        assertTrue(board.settled(id));
        (address b,,,,,,,,,,) = board.bids(id);
        assertEq(b, address(0));
    }

    function testProceedsRoundDownAndZeroIsRejected() public {
        uint256 id = _open();
        // One wei of a 1000e18 lot priced at 100e18 floors to zero.
        vm.prank(seller);
        vm.expectRevert(Floorboard.ZeroProceeds.selector);
        board.hit(id, 1, 0, false);
    }

    function testMinProceedsBound() public {
        uint256 id = _open();
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(Floorboard.ProceedsBelowMin.selector, START / 2, START)
        );
        board.hit(id, WANT / 2, START, false);
    }

    /// @dev The whole point of the climb: a seller who waits is paid more.
    function testWaitingPaysMore() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DUR / 2);
        vm.prank(seller);
        uint256 paid = board.hit(id, WANT / 2, 0, false);
        assertEq(paid, (START + (END - START) / 2) / 2);
        assertGt(paid, START / 2);
    }

    // -------------------------------------------------------------- EXPIRY

    function testHitRevertsAfterExpiry() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DUR);
        vm.prank(seller);
        vm.expectRevert(Floorboard.Expired.selector);
        board.hit(id, WANT, 0, false);
    }

    function testQuoteHitReportsExpiredAsUntakeable() public {
        uint256 id = _open();
        (bool ok,) = board.quoteHit(id, WANT);
        assertTrue(ok);
        vm.warp(block.timestamp + DUR);
        (ok,) = board.quoteHit(id, WANT);
        assertFalse(ok);
    }

    function testAnyoneCanSweepAnExpiredBidBackToItsHolder() public {
        uint256 id = _open();
        uint256 bidderBefore = usdc.balanceOf(bidder);
        vm.warp(block.timestamp + DUR);

        // A stranger sweeps; the escrow goes to the holder, never the caller.
        address keeper = address(0xBEEF);
        vm.prank(keeper);
        board.sweep(id);

        assertEq(usdc.balanceOf(bidder) - bidderBefore, END);
        assertEq(usdc.balanceOf(keeper), 0);
        assertEq(board.escrowed(address(usdc)), 0);
    }

    function testSweepBeforeExpiryReverts() public {
        uint256 id = _open();
        vm.warp(block.timestamp + DUR - 1);
        vm.expectRevert(Floorboard.Bad.selector);
        board.sweep(id);
    }

    // ------------------------------------------------------------- CANCEL

    function testCancelRefundsRemainingEscrow() public {
        uint256 id = _open();
        vm.prank(seller);
        uint256 paid = board.hit(id, WANT / 2, 0, false);

        uint256 bidderBefore = usdc.balanceOf(bidder);
        vm.prank(bidder);
        board.cancel(id);
        assertEq(usdc.balanceOf(bidder) - bidderBefore, END - paid);
        assertEq(board.escrowed(address(usdc)), 0);
    }

    function testOnlyBidderCancels() public {
        uint256 id = _open();
        vm.prank(seller);
        vm.expectRevert(Floorboard.NotBidder.selector);
        board.cancel(id);
    }

    // ----------------------------------------------------------- WITHDRAW

    function testPartialWithdrawRefundsProRataAndKeepsUnitPrice() public {
        uint256 id = _open();
        (, uint256 unitBefore) = board.quoteHit(id, 100e18);

        uint256 bidderBefore = usdc.balanceOf(bidder);
        vm.prank(bidder);
        board.withdraw(id, 400e18, false);

        // Reserve for what is still wanted: END * 600/1000 = 120e18.
        (,,,,,,,, uint96 locked,, uint128 remaining) = board.bids(id);
        assertEq(remaining, 600e18);
        assertEq(locked, uint96(120e18));
        assertEq(usdc.balanceOf(bidder) - bidderBefore, END - 120e18);
        assertEq(board.escrowed(address(usdc)), 120e18);

        // The denominator never moved, so the per-unit bid is untouched.
        (, uint256 unitAfter) = board.quoteHit(id, 100e18);
        assertEq(unitAfter, unitBefore);
    }

    function testWithdrawCannotEmptyTheBid() public {
        uint256 id = _open();
        vm.prank(bidder);
        vm.expectRevert(Floorboard.Bad.selector);
        board.withdraw(id, WANT, false);
    }

    function testWithdrawLeavesEnoughEscrowForTheWorstCase() public {
        uint256 id = _open();
        vm.prank(bidder);
        board.withdraw(id, 400e18, false);

        // Let it climb to the ceiling and take the rest: escrow must cover it.
        vm.warp(block.timestamp + DUR - 1);
        vm.prank(seller);
        uint256 paid = board.hit(id, 600e18, 0, false);
        assertLe(paid, 120e18);
        assertEq(board.escrowed(address(usdc)), 0);
    }

    function testOnlyBidderWithdraws() public {
        uint256 id = _open();
        vm.prank(seller);
        vm.expectRevert(Floorboard.NotBidder.selector);
        board.withdraw(id, 1e18, false);
    }

    // ---------------------------------------------------------------- NFTs

    function _nftTerms(uint128 want, uint256[] memory ids)
        internal
        view
        returns (Floorboard.Terms memory t)
    {
        t = Floorboard.Terms({
            token: address(nft),
            quote: address(usdc),
            want: want,
            startPrice: START,
            endPrice: END,
            startTime: 0,
            duration: DUR,
            isNFT: true,
            ids: ids
        });
    }

    function testFloorBidAcceptsAnyTokenId() public {
        vm.prank(bidder);
        uint256 id = board.bid(_nftTerms(1, new uint256[](0)));

        nft.mint(seller, 777);
        vm.prank(seller);
        nft.setApprovalForAll(address(board), true);

        uint256[] memory give = new uint256[](1);
        give[0] = 777;
        vm.prank(seller);
        uint256 paid = board.hitNFT(id, give, 0, false);

        assertEq(paid, START);
        assertEq(nft.ownerOf(777), bidder);
    }

    function testTargetedBidRejectsAnUnlistedId() public {
        uint256[] memory allow = new uint256[](3);
        (allow[0], allow[1], allow[2]) = (1, 2, 3);
        vm.prank(bidder);
        uint256 id = board.bid(_nftTerms(1, allow));

        nft.mint(seller, 9);
        vm.prank(seller);
        nft.setApprovalForAll(address(board), true);

        uint256[] memory give = new uint256[](1);
        give[0] = 9;
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Floorboard.NotTargeted.selector, address(nft), 9));
        board.hitNFT(id, give, 0, false);
    }

    function testTargetedBidAcceptsAListedId() public {
        uint256[] memory allow = new uint256[](3);
        (allow[0], allow[1], allow[2]) = (1, 2, 3);
        vm.prank(bidder);
        uint256 id = board.bid(_nftTerms(1, allow));

        nft.mint(seller, 2);
        vm.prank(seller);
        nft.setApprovalForAll(address(board), true);

        uint256[] memory give = new uint256[](1);
        give[0] = 2;
        vm.prank(seller);
        board.hitNFT(id, give, 0, false);
        assertEq(nft.ownerOf(2), bidder);
    }

    /// @dev `want` stays a quantity while `ids` narrows the set — "any two of these five".
    function testAnyTwoOfFive() public {
        uint256[] memory allow = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            allow[i] = i + 1;
            nft.mint(seller, i + 1);
        }
        vm.prank(bidder);
        uint256 id = board.bid(_nftTerms(2, allow));
        vm.prank(seller);
        nft.setApprovalForAll(address(board), true);

        uint256[] memory give = new uint256[](2);
        (give[0], give[1]) = (1, 4);
        vm.prank(seller);
        uint256 paid = board.hitNFT(id, give, 0, false);

        assertEq(paid, START); // both units of a two-unit bid
        assertEq(nft.ownerOf(1), bidder);
        assertEq(nft.ownerOf(4), bidder);
        assertTrue(board.settled(id));
    }

    function testWantCannotExceedTheAllowList() public {
        uint256[] memory allow = new uint256[](2);
        (allow[0], allow[1]) = (1, 2);
        vm.prank(bidder);
        vm.expectRevert(Floorboard.Bad.selector);
        board.bid(_nftTerms(3, allow));
    }

    /// @dev Value attached to a token-quoted bid is a mistake, not a tip.
    function testValueOnATokenQuotedBidReverts() public {
        vm.deal(bidder, 1 ether);
        vm.prank(bidder);
        vm.expectRevert(Floorboard.Bad.selector);
        board.bid{value: 1}(_terms());
    }

    function testERC20BidRejectsAnIdSet() public {
        Floorboard.Terms memory t = _terms();
        t.ids = new uint256[](1);
        vm.prank(bidder);
        vm.expectRevert(Floorboard.Bad.selector);
        board.bid(t);
    }

    // ----------------------------------------------------------------- ETH

    function testBidWithETHWrapsExactlyTheCeiling() public {
        Floorboard.Terms memory t = _terms();
        t.quote = address(0); // native ETH, wrapped into a WETH escrow
        vm.deal(bidder, END);
        vm.prank(bidder);
        uint256 id = board.bid{value: END}(t);

        assertEq(weth.balanceOf(address(board)), END);
        assertEq(board.escrowed(address(weth)), END);
        assertEq(board.quoteOf(id), address(weth));
    }

    function testBidWithETHRequiresExactValue() public {
        Floorboard.Terms memory t = _terms();
        t.quote = address(0);
        vm.deal(bidder, END);
        vm.prank(bidder);
        vm.expectRevert(Floorboard.Bad.selector);
        board.bid{value: END - 1}(t);
    }

    function testSellerCanTakeProceedsAsNativeETH() public {
        Floorboard.Terms memory t = _terms();
        t.quote = address(0);
        vm.deal(bidder, END);
        vm.prank(bidder);
        uint256 id = board.bid{value: END}(t);

        vm.prank(seller);
        board.hit(id, WANT / 2, 0, true);
        assertEq(seller.balance, START / 2);
    }

    // ------------------------------------------------------------ RECEIPTS

    /// @dev Ownership IS bidder-ship: the asset follows the receipt.
    function testTransferringTheReceiptMovesDelivery() public {
        uint256 id = _open();
        address heir = address(0xE1);
        vm.prank(bidder);
        board.transferFrom(bidder, heir, id);

        vm.prank(seller);
        board.hit(id, WANT, 0, false);
        assertEq(tkn.balanceOf(heir), WANT);
        assertEq(tkn.balanceOf(bidder), 0);
    }

    // -------------------------------------------------------------- QUOTES

    function testGiveForIsAffordableByConstruction() public {
        uint256 id = _open();
        (uint128 give, uint256 proceeds) = board.giveFor(id, 30e18);
        assertGt(give, 0);
        assertGe(proceeds, 30e18);

        vm.prank(seller);
        uint256 paid = board.hit(id, give, 30e18, false);
        assertEq(paid, proceeds);
    }

    function testGiveForRefusesAnUnreachableTarget() public {
        uint256 id = _open();
        (uint128 give, uint256 proceeds) = board.giveFor(id, START + 1);
        assertEq(give, 0);
        assertEq(proceeds, 0);
    }

    function testSolvencyHoldsAcrossTheLifecycle() public {
        uint256 id = _open();
        vm.prank(seller);
        board.hit(id, WANT / 4, 0, false);
        vm.prank(bidder);
        board.withdraw(id, WANT / 4, false);
        assertGe(usdc.balanceOf(address(board)), board.escrowed(address(usdc)));

        vm.prank(bidder);
        board.cancel(id);
        assertEq(board.escrowed(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(board)), 0);
    }
}
