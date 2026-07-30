// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {
    MockERC20,
    FeeToken,
    SloppyERC721,
    NoOpTransferERC20,
    SenderFeeERC20,
    RecipientTaxERC20,
    StickyStrictERC721
} from "./SwapboardMocks.sol";

/// @notice Security regressions for transfer boundaries that cannot safely trust a
///         successful external call alone. Dutchboard pools sold assets by token, so
///         every escrow movement must prove its exact balance delta; ERC-721 transfers
///         have no return value and must prove ownership before and after the call.
contract DutchboardAuditTest is Test {
    Dutchboard board;
    MockERC20 lot;
    MockERC20 quote;

    address maker = address(0xA11CE);
    address victim = address(0xBEEF);
    address taker = address(0xB0B);
    address attacker = address(0xBAD);

    function setUp() public {
        board = new Dutchboard();
        lot = new MockERC20("LOT", 18);
        quote = new MockERC20("QUOTE", 18);
        quote.mint(taker, 1_000_000e18);
        vm.prank(taker);
        quote.approve(address(board), type(uint256).max);
    }

    function _listLot(address token, uint128 amount) internal returns (uint256 id) {
        vm.startPrank(maker);
        MockERC20(token).approve(address(board), type(uint256).max);
        id = board.listERC20(token, address(quote), amount, 100e18, 100e18, 0, 1 hours);
        vm.stopPrank();
    }

    // --------------------------------------------------------------- ERC-721

    /// A quiet no-op must not let an attacker create a second listing for an NFT the
    /// board already holds, then cancel their listing and steal the victim's escrow.
    function test_CannotDuplicateAnotherListingsNftEscrow() public {
        SloppyERC721 nft = new SloppyERC721();
        nft.mint(victim, 1);
        uint256[] memory ids = _one(1);

        vm.startPrank(victim);
        nft.setApprovalForAll(address(board), true);
        uint256 victimListing = board.listNFT(address(nft), address(quote), ids, 100e18, 100e18, 0, 1 hours);
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Dutchboard.NFTTransferFailed.selector, address(nft), 1));
        board.listNFT(address(nft), address(quote), ids, 1, 1, 0, 1 hours);

        assertEq(nft.ownerOf(1), address(board), "victim escrow moved");
        assertEq(board.getListing(victimListing).seller, victim, "victim listing changed");
        assertEq(board.nextId(), 1, "reverting duplicate consumed an id");
    }

    /// Sticky approval can let a broken collection's NFT escape after listing. A fill
    /// must retain the taker's payment unless the board still owns and delivers it.
    function test_FillRejectsNftThatEscapedEscrow() public {
        SloppyERC721 nft = new SloppyERC721();
        nft.mint(maker, 2);

        vm.startPrank(maker);
        nft.approve(maker, 2);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(quote), _one(2), 100e18, 100e18, 0, 1 hours);
        nft.transferFrom(address(board), maker, 2);
        vm.stopPrank();

        uint256 takerBefore = quote.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Dutchboard.NFTTransferFailed.selector, address(nft), 2));
        board.fill(id, 0, taker, 100e18);

        assertEq(quote.balanceOf(taker), takerBefore, "taker was charged");
        assertEq(board.getListing(id).seller, maker, "failed fill closed listing");
    }

    /// If a sticky approval already returned the NFT to its maker, cancellation should
    /// close the stale claim without making a strict collection revert on a stale from.
    function test_CancelClosesWhenNftAlreadyReturnedToMaker() public {
        StickyStrictERC721 nft = new StickyStrictERC721();
        nft.mint(maker, 3);

        vm.startPrank(maker);
        nft.approve(maker, 3);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(quote), _one(3), 100e18, 100e18, 0, 1 hours);
        nft.transferFrom(address(board), maker, 3);
        board.cancel(id);
        vm.stopPrank();

        assertEq(nft.ownerOf(3), maker);
        assertEq(board.getListing(id).seller, address(0), "listing remained live");
    }

    /// If the NFT escaped to somebody else, cancellation must preserve the maker's
    /// live claim rather than deleting the listing after a quietly failing return.
    function test_CancelDoesNotDiscardClaimWhenNftWasStolen() public {
        SloppyERC721 nft = new SloppyERC721();
        nft.mint(maker, 4);

        vm.startPrank(maker);
        nft.approve(attacker, 4);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(quote), _one(4), 100e18, 100e18, 0, 1 hours);
        vm.stopPrank();
        vm.prank(attacker);
        nft.transferFrom(address(board), attacker, 4);

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Dutchboard.NFTTransferFailed.selector, address(nft), 4));
        board.cancel(id);

        assertEq(nft.ownerOf(4), attacker);
        assertEq(board.getListing(id).seller, maker, "maker's claim was discarded");
    }

    // --------------------------------------------------------------- ERC-20

    /// A short transferFrom cannot create a nominally full listing backed by less
    /// escrow, even when the board already holds the same token for another maker.
    function test_ShortEscrowDepositIsRejected() public {
        FeeToken fee = new FeeToken();
        fee.mint(maker, 100e18);

        vm.startPrank(maker);
        fee.approve(address(board), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                Dutchboard.BalanceDeltaMismatch.selector, address(fee), address(board), 100e18, 99e18
            )
        );
        board.listERC20(address(fee), address(quote), 100e18, 100e18, 100e18, 0, 1 hours);
        vm.stopPrank();

        assertEq(fee.balanceOf(address(board)), 0, "failed listing left escrow");
        assertEq(board.nextId(), 0, "failed listing consumed an id");
    }

    /// A token that returns true without paying out cannot close the listing or charge
    /// the taker for output that never arrived.
    function test_TrueReturningNoOpPayoutIsRejected() public {
        NoOpTransferERC20 bad = new NoOpTransferERC20();
        bad.mint(maker, 100e18);
        uint256 id = _listLot(address(bad), 100e18);

        uint256 takerQuoteBefore = quote.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                Dutchboard.BalanceDeltaMismatch.selector, address(bad), address(board), 100e18, 0
            )
        );
        board.fill(id, 100e18, taker, 100e18);

        assertEq(quote.balanceOf(taker), takerQuoteBefore, "taker was charged");
        assertEq(bad.balanceOf(address(board)), 100e18, "escrow changed");
        assertEq(board.getListing(id).remaining, 100e18, "failed fill changed remainder");
    }

    /// Cancellation uses the same exact payout proof. A successful-looking no-op must
    /// leave the listing live so the maker's only accounting claim is not discarded.
    function test_CancelNoOpPayoutDoesNotDiscardClaim() public {
        NoOpTransferERC20 bad = new NoOpTransferERC20();
        bad.mint(maker, 100e18);
        uint256 id = _listLot(address(bad), 100e18);

        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(
                Dutchboard.BalanceDeltaMismatch.selector, address(bad), address(board), 100e18, 0
            )
        );
        board.cancel(id);

        assertEq(bad.balanceOf(address(board)), 100e18, "escrow changed");
        assertEq(board.getListing(id).remaining, 100e18, "maker's claim was discarded");
    }

    /// An over-debit on one payout must not consume the fungible escrow that backs a
    /// second listing of the same token.
    function test_SenderFeeCannotConsumeAnotherListingsEscrow() public {
        SenderFeeERC20 bad = new SenderFeeERC20();
        bad.mint(maker, 100e18);
        bad.mint(victim, 100e18);
        uint256 id = _listLot(address(bad), 100e18);

        vm.startPrank(victim);
        bad.approve(address(board), type(uint256).max);
        uint256 victimId = board.listERC20(address(bad), address(quote), 100e18, 100e18, 100e18, 0, 1 hours);
        vm.stopPrank();

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                Dutchboard.BalanceDeltaMismatch.selector, address(bad), address(board), 100e18, 100e18 + 1
            )
        );
        board.fill(id, 100e18, taker, 100e18);

        assertEq(bad.balanceOf(address(board)), 200e18, "pooled escrow was consumed");
        assertEq(board.getListing(id).remaining, 100e18, "attacked listing changed");
        assertEq(board.getListing(victimId).remaining, 100e18, "victim listing changed");
    }

    /// A recipient-side tax is also a settlement failure: exact board debit alone does
    /// not prove the taker received the amount they agreed to buy.
    function test_RecipientTaxCannotUnderDeliver() public {
        RecipientTaxERC20 bad = new RecipientTaxERC20();
        bad.mint(maker, 100e18);
        uint256 id = _listLot(address(bad), 100e18);

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(Dutchboard.BalanceDeltaMismatch.selector, address(bad), taker, 100e18, 100e18 - 1)
        );
        board.fill(id, 100e18, taker, 100e18);

        assertEq(bad.balanceOf(taker), 0, "taker received a partial payout");
        assertEq(board.getListing(id).remaining, 100e18, "failed fill changed listing");
    }

    /// Quote tokens are verified too; otherwise a transfer-tax token releases the lot
    /// while silently paying the maker less than the scheduled cost.
    function test_QuoteTokenMustPaySellerExactly() public {
        FeeToken feeQuote = new FeeToken();
        lot.mint(maker, 100e18);
        feeQuote.mint(taker, 100e18);

        vm.startPrank(maker);
        lot.approve(address(board), type(uint256).max);
        uint256 id = board.listERC20(address(lot), address(feeQuote), 100e18, 100e18, 100e18, 0, 1 hours);
        vm.stopPrank();
        vm.prank(taker);
        feeQuote.approve(address(board), type(uint256).max);

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                Dutchboard.BalanceDeltaMismatch.selector, address(feeQuote), maker, 100e18, 99e18
            )
        );
        board.fill(id, 100e18, taker, 100e18);

        assertEq(lot.balanceOf(taker), 0, "lot escaped");
        assertEq(feeQuote.balanceOf(taker), 100e18, "failed payment was not rolled back");
        assertEq(board.getListing(id).remaining, 100e18, "failed fill changed listing");
    }

    /// Sending escrow to the board itself closes the accounting claim but leaves the
    /// asset pooled and unrecoverable. Refuse that recipient before settlement.
    function test_BoardCannotBeTheFillRecipient() public {
        lot.mint(maker, 100e18);
        uint256 id = _listLot(address(lot), 100e18);

        vm.prank(taker);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill(id, 100e18, address(board), 100e18);

        assertEq(lot.balanceOf(address(board)), 100e18, "escrow changed");
        assertEq(board.getListing(id).remaining, 100e18, "listing changed");
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
