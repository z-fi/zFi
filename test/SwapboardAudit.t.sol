// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {
    MockERC20,
    MockWETH,
    MockNFT,
    LyingERC721,
    SloppyERC721,
    SoftFailERC20,
    NoOpTransferERC20,
    SenderFeeERC20,
    RecipientTaxERC20,
    NoMintWETH,
    OverburnWETH,
    StickyStrictERC721
} from "./SwapboardMocks.sol";

/// Security-audit regressions. Every test here failed against the pre-audit
/// contract; each one is a settlement leg that trusted a transfer instead of
/// confirming it, or a bid the board silently rounded up.
///
/// The threat model is the one the contract already adopted when it confirmed
/// escrow with `ownerOf` rather than trusting `transferFrom`: an ERC-721 whose
/// `transferFrom` returns without moving anything, because it was written with
/// an `if` where the standard requires a `require`. Such collections exist, and
/// the board is escrowing on behalf of whoever lists one.
contract SwapboardAuditTest is Test {
    Swapboard sb;
    MockWETH weth;
    MockERC20 A;
    MockERC20 B;

    address maker = address(0xA11CE);
    address taker = address(0xB0B);
    address attacker = address(0xBAD);

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        A = new MockERC20("AAA", 18);
        B = new MockERC20("BBB", 6);
        A.mint(maker, 1_000e18);
        B.mint(taker, 1_000_000e6);
        B.mint(attacker, 1_000_000e6);
        vm.prank(maker);
        A.approve(address(sb), type(uint256).max);
        vm.prank(taker);
        B.approve(address(sb), type(uint256).max);
        vm.prank(attacker);
        B.approve(address(sb), type(uint256).max);
    }

    // ------------------------------------------------- escrow custody (create)

    /// The escrow check asked whether the board owns the NFT, not whether this
    /// maker's transfer is what put it there. Against a 721 that no-ops an
    /// unauthorised transfer, anyone could point a fresh order at an NFT already
    /// escrowed by someone else, and then cancel that order to walk off with it.
    function test_CannotEscrowAnNftTheBoardAlreadyHolds() public {
        SloppyERC721 n = new SloppyERC721();
        n.mint(maker, 1);

        vm.startPrank(maker);
        n.setApprovalForAll(address(sb), true);
        sb.createOrder(address(n), 1, address(B), 500e6, false, 0, true, false, address(0));
        vm.stopPrank();
        assertEq(n.ownerOf(1), address(sb), "victim escrow parked");

        // The attacker never owned token 1, so nothing moves - but the board
        // does hold it, which is all the old check looked at.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NFTTransferFailed.selector, address(n), 1));
        sb.createOrder(address(n), 1, address(B), 1, false, 0, true, false, address(0));

        assertEq(n.ownerOf(1), address(sb), "victim escrow untouched");
    }

    /// Same hole reached through an operator approval instead of a prior escrow:
    /// the board is an approved operator for the victim, so a 721 that ignores
    /// `from` would move the victim's NFT into escrow for the attacker's order.
    function test_CannotEscrowAnNftOwnedBySomeoneElse() public {
        SloppyERC721 n = new SloppyERC721();
        n.mint(maker, 2);
        vm.prank(maker);
        n.setApprovalForAll(address(sb), true);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NFTTransferFailed.selector, address(n), 2));
        sb.createOrder(address(n), 2, address(B), 1, false, 0, true, false, address(0));

        assertEq(n.ownerOf(2), maker, "still the victim's");
    }

    // -------------------------------------------------- payout custody (fill)

    /// ERC-721 requires a transfer to clear the per-token approval; collections
    /// have shipped without it. A maker who approved themselves before listing
    /// can then pull the NFT back out of escrow while the order stays live. The
    /// fill must not hand the taker's payment over for an NFT that no longer
    /// moves.
    function test_FillRevertsWhenEscrowedNftNoLongerMoves() public {
        SloppyERC721 n = new SloppyERC721();
        n.mint(maker, 3);

        vm.startPrank(maker);
        n.approve(maker, 3); // survives the transfer on this collection
        n.setApprovalForAll(address(sb), true);
        uint256 id = sb.createOrder(address(n), 3, address(B), 500e6, false, 0, true, false, address(0));
        n.transferFrom(address(sb), maker, 3); // reclaimed; order still active
        vm.stopPrank();
        assertEq(n.ownerOf(3), maker, "escrow drained behind the board's back");

        uint256 paid = B.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NFTTransferFailed.selector, address(n), 3));
        sb.fillOrder(id, 0, 500e6, 0, address(0));

        assertEq(B.balanceOf(taker), paid, "taker keeps their money");
    }

    /// Cancelling into a transfer that silently does nothing used to close the
    /// order and hand back nothing, discarding the maker's only claim on an
    /// escrow that had been lifted out from under the board. The return leg now
    /// confirms the NFT arrived, so the cancel reverts and the order stays live.
    function test_CancelRevertsRatherThanDiscardingTheClaim() public {
        SloppyERC721 n = new SloppyERC721();
        n.mint(maker, 4);

        vm.startPrank(maker);
        n.approve(attacker, 4); // sticky: survives the transfer into escrow
        n.setApprovalForAll(address(sb), true);
        uint256 id = sb.createOrder(address(n), 4, address(B), 500e6, false, 0, true, false, address(0));
        vm.stopPrank();

        vm.prank(attacker);
        n.transferFrom(address(sb), attacker, 4);

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NFTTransferFailed.selector, address(n), 4));
        sb.cancelOrder(id);

        (, bool active,,,,,,,,,) = sb.orders(id);
        assertTrue(active, "order survives so the claim is not lost");
    }

    /// The mirror case: an NFT that has already found its way back to the maker
    /// still lets them close the listing. An unconditional source check would
    /// strand them with a dead order they could never cancel.
    function test_CancelClosesWhenTheNftIsAlreadyHome() public {
        SloppyERC721 n = new SloppyERC721();
        n.mint(maker, 15);

        vm.startPrank(maker);
        n.approve(maker, 15);
        n.setApprovalForAll(address(sb), true);
        uint256 id = sb.createOrder(address(n), 15, address(B), 500e6, false, 0, true, false, address(0));
        n.transferFrom(address(sb), maker, 15); // reclaimed by the maker
        sb.cancelOrder(id);
        vm.stopPrank();

        (, bool active,,,,,,,,,) = sb.orders(id);
        assertFalse(active, "dead listing can still be closed");
        assertEq(n.ownerOf(15), maker);
    }

    /// A destination-only post-check is not enough when transferFrom correctly
    /// reverts on a stale `from`. Check that an NFT already home is detected
    /// before making that call.
    function test_CancelSkipsTransferWhenStrictNftIsAlreadyHome() public {
        StickyStrictERC721 n = new StickyStrictERC721();
        n.mint(maker, 16);

        vm.startPrank(maker);
        n.approve(maker, 16); // deliberately survives the transfer into escrow
        n.setApprovalForAll(address(sb), true);
        uint256 id = sb.createOrder(address(n), 16, address(B), 500e6, false, 0, true, false, address(0));
        n.transferFrom(address(sb), maker, 16);
        sb.cancelOrder(id);
        vm.stopPrank();

        (, bool active,,,,,,,,,) = sb.orders(id);
        assertFalse(active, "already-returned listing closes");
        assertEq(n.ownerOf(16), maker);
    }

    // ------------------------------------------------- payment leg (nftB fill)

    /// The tokenB leg is where the maker actually gets paid, and it took the
    /// 721's word for it. A collection that no-ops handed the taker the whole
    /// escrow for nothing.
    function test_NftPaymentThatNeverArrivesIsCaught() public {
        LyingERC721 bad = new LyingERC721();
        bad.mint(taker, 5);

        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 100e18, address(bad), 5, false, 0, false, true, address(0));

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NFTTransferFailed.selector, address(bad), 5));
        sb.fillOrder(id, 0, 0, 0, address(0));

        assertEq(A.balanceOf(taker), 0, "no escrow released");
        assertEq(A.balanceOf(address(sb)), 100e18, "escrow intact");
    }

    /// A taker cannot pay with an NFT they do not hold, even on a collection
    /// that would let the call through.
    function test_NftPaymentFromANonOwnerIsCaught() public {
        SloppyERC721 n = new SloppyERC721();
        n.mint(attacker, 6); // the taker owns nothing

        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 100e18, address(n), 6, false, 0, false, true, address(0));

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NFTTransferFailed.selector, address(n), 6));
        sb.fillOrder(id, 0, 0, 0, address(0));

        assertEq(A.balanceOf(taker), 0, "no escrow released");
    }

    /// Ticking the NFT box on a plain ERC-20 sent the payment through an
    /// interface with no return value, so a token that reports failure by
    /// returning false was read as success. ownerOf does not exist on an ERC-20,
    /// so the misconfiguration now fails closed.
    function test_Erc20MarkedAsAnNftCannotSilentlyFailToPay() public {
        SoftFailERC20 soft = new SoftFailERC20();

        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 100e18, address(soft), 100e18, false, 0, false, true, address(0));

        vm.prank(taker); // no balance, no allowance: transferFrom returns false
        vm.expectRevert();
        sb.fillOrder(id, 0, 0, 0, address(0));

        assertEq(A.balanceOf(taker), 0, "no escrow released");
    }

    // ---------------------------------------------- fungible escrow settlement

    /// SafeTransferLib validates the return value, but a broken token can return
    /// true without moving. A fill must not close or charge the taker unless the
    /// escrow balance actually leaves and the recipient receives it.
    function test_TrueReturningNoOpTokenCannotCloseFilledOrder() public {
        NoOpTransferERC20 bad = new NoOpTransferERC20();
        bad.mint(maker, 100e18);
        vm.startPrank(maker);
        bad.approve(address(sb), type(uint256).max);
        uint256 id = sb.createOrder(address(bad), 100e18, address(B), 500e6, false, 0, false, false, address(0));
        vm.stopPrank();

        uint256 takerBefore = B.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(Swapboard.BalanceDeltaMismatch.selector, address(bad), address(sb), 100e18, 0)
        );
        sb.fillOrder(id, 0, 500e6, 0, address(0));

        (, bool active,,,,,,,,,) = sb.orders(id);
        assertTrue(active, "failed payout preserves the claim");
        assertEq(bad.balanceOf(address(sb)), 100e18, "escrow stays backed");
        assertEq(B.balanceOf(taker), takerBefore, "payment rolled back");
    }

    /// A sender-paid transfer fee must not be allowed to take the fee from the
    /// next maker's pooled escrow.
    function test_SenderFeeCannotConsumeAnotherOrder() public {
        SenderFeeERC20 bad = new SenderFeeERC20();
        bad.mint(maker, 100e18);
        bad.mint(attacker, 100e18);

        vm.startPrank(maker);
        bad.approve(address(sb), type(uint256).max);
        uint256 first = sb.createOrder(address(bad), 100e18, address(B), 500e6, false, 0, false, false, address(0));
        vm.stopPrank();

        vm.startPrank(attacker);
        bad.approve(address(sb), type(uint256).max);
        uint256 second = sb.createOrder(address(bad), 100e18, address(B), 500e6, false, 0, false, false, address(0));
        vm.stopPrank();

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                Swapboard.BalanceDeltaMismatch.selector, address(bad), address(sb), 100e18, 100e18 + 1
            )
        );
        sb.fillOrder(first, 0, 500e6, 0, address(0));

        assertEq(bad.balanceOf(address(sb)), 200e18, "both orders remain fully backed");
        (, bool firstActive,,,,,,,,,) = sb.orders(first);
        (, bool secondActive,,,,,,,,,) = sb.orders(second);
        assertTrue(firstActive);
        assertTrue(secondActive);
    }

    /// Exact board debit alone is insufficient: an outbound-only recipient tax
    /// can debit the nominal amount yet deliver less than OrderFilled reports.
    function test_RecipientTaxCannotShortTheTaker() public {
        RecipientTaxERC20 bad = new RecipientTaxERC20();
        bad.mint(maker, 100e18);
        vm.startPrank(maker);
        bad.approve(address(sb), type(uint256).max);
        uint256 id = sb.createOrder(address(bad), 100e18, address(B), 500e6, false, 0, false, false, address(0));
        vm.stopPrank();

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(Swapboard.BalanceDeltaMismatch.selector, address(bad), taker, 100e18, 100e18 - 1)
        );
        sb.fillOrder(id, 0, 500e6, 0, address(0));

        assertEq(bad.balanceOf(taker), 0);
        assertEq(bad.balanceOf(address(sb)), 100e18);
    }

    // --------------------------------------------------------- WETH isolation

    /// A configured wrapper that accepts ETH but mints nothing must not let an
    /// ETH fill pay its maker from WETH backing a different order.
    function test_ShortMintingWethCannotSpendUnrelatedEscrow() public {
        NoMintWETH bad = new NoMintWETH();
        Swapboard board = new Swapboard(address(bad));

        bad.mint(maker, 100 ether);
        vm.startPrank(maker);
        bad.approve(address(board), type(uint256).max);
        board.createOrder(address(bad), 100 ether, address(B), 1e6, false, 0, false, false, address(0));
        vm.stopPrank();

        A.mint(attacker, 1e18);
        vm.startPrank(attacker);
        A.approve(address(board), type(uint256).max);
        uint256 id = board.createOrder(address(A), 1e18, address(bad), 10 ether, false, 0, false, false, address(0));
        vm.stopPrank();

        vm.deal(attacker, 10 ether);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Swapboard.BalanceDeltaMismatch.selector, address(bad), address(board), 10 ether, 0)
        );
        board.fillOrderWithEth{value: 10 ether}(id, 0, 0, address(0));

        assertEq(bad.balanceOf(address(board)), 100 ether, "victim escrow untouched");
        assertEq(bad.balanceOf(attacker), 0, "no unrelated WETH paid out");
        (, bool active,,,,,,,,,) = board.orders(id);
        assertTrue(active);
    }

    /// The inverse wrapper failure is also isolated: redeeming one order may
    /// not burn more WETH than that order owns.
    function test_OverburningWethCannotConsumeUnrelatedEscrow() public {
        OverburnWETH bad = new OverburnWETH();
        Swapboard board = new Swapboard(address(bad));

        bad.mint(maker, 100 ether);
        vm.startPrank(maker);
        bad.approve(address(board), type(uint256).max);
        board.createOrder(address(bad), 100 ether, address(B), 1e6, false, 0, false, false, address(0));
        vm.stopPrank();

        bad.mint(attacker, 10 ether);
        vm.startPrank(attacker);
        bad.approve(address(board), type(uint256).max);
        uint256 id = board.createOrder(address(bad), 10 ether, address(B), 1e6, false, 0, false, false, address(0));
        vm.stopPrank();
        vm.deal(address(bad), 10 ether);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                Swapboard.BalanceDeltaMismatch.selector, address(bad), address(board), 10 ether, 10 ether + 1
            )
        );
        board.cancelOrderUnwrap(id);

        assertEq(bad.balanceOf(address(board)), 110 ether, "both escrows remain backed");
        (, bool active,,,,,,,,,) = board.orders(id);
        assertTrue(active);
    }

    /// The ownerless board cannot recover constructor funding. A nonpayable
    /// constructor rejects it before it becomes irretrievable.
    function test_ConstructorRejectsDeploymentValue() public {
        bytes memory creation = abi.encodePacked(type(Swapboard).creationCode, abi.encode(address(weth)));
        vm.deal(address(this), 1);
        address deployed;
        assembly {
            deployed := create(1, add(creation, 0x20), mload(creation))
        }
        assertEq(deployed, address(0));
        assertEq(address(this).balance, 1);
    }

    // ------------------------------------------------------- short NFT bids

    /// An NFT order settles in full, so _fill rewrites a short fillAmountB up to
    /// the whole ask. On the ETH path that is refused outright; on the ERC-20
    /// path it used to go through, billing a taker who offered 1 unit the entire
    /// price. fillAmountB is a bound everywhere else and must be one here too.
    function test_ShortBidOnAnNftOrderIsRefusedNotBilledInFull() public {
        MockNFT n = new MockNFT();
        n.mint(maker, 7);
        vm.startPrank(maker);
        n.setApprovalForAll(address(sb), true);
        uint256 id = sb.createOrder(address(n), 7, address(B), 1000e6, false, 0, true, false, address(0));
        vm.stopPrank();

        uint256 held = B.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.PartialFillNotAllowed.selector, id));
        sb.fillOrder(id, 0, 1, 0, address(0)); // offering 1 unit, ask is 1000e6

        assertEq(B.balanceOf(taker), held, "not charged the full ask against a 1-unit bid");
        assertEq(n.ownerOf(7), address(sb), "NFT still escrowed");
    }

    /// The 0 sentinel and an overbid both still settle at the ask, so the fix
    /// does not cost the two ways an NFT order was always fillable.
    function test_NftOrderStillTakesTheSentinelAndAnOverbid() public {
        MockNFT n = new MockNFT();
        n.mint(maker, 8);
        n.mint(maker, 9);
        vm.startPrank(maker);
        n.setApprovalForAll(address(sb), true);
        uint256 sentinel = sb.createOrder(address(n), 8, address(B), 1000e6, false, 0, true, false, address(0));
        uint256 overbid = sb.createOrder(address(n), 9, address(B), 1000e6, false, 0, true, false, address(0));
        vm.stopPrank();

        uint256 held = B.balanceOf(taker);
        vm.startPrank(taker);
        sb.fillOrder(sentinel, 0, 0, 0, address(0));
        sb.fillOrder(overbid, 0, 9999e6, 0, address(0));
        vm.stopPrank();

        assertEq(n.ownerOf(8), taker);
        assertEq(n.ownerOf(9), taker);
        assertEq(held - B.balanceOf(taker), 2000e6, "each billed at the ask, not the bid");
    }

    // ------------------------------------------------------ honest collections

    /// The confirmations must be invisible to a well-behaved ERC-721 on every
    /// leg: escrow in, pay in, pay out, cancel out, sweep out.
    function test_HonestNftRoundTripsUnaffected() public {
        MockNFT n = new MockNFT();
        n.mint(maker, 10);
        n.mint(maker, 11);
        n.mint(taker, 12);
        vm.prank(maker);
        n.setApprovalForAll(address(sb), true);
        vm.prank(taker);
        n.setApprovalForAll(address(sb), true);

        vm.startPrank(maker);
        uint256 sell = sb.createOrder(address(n), 10, address(B), 500e6, false, 0, true, false, address(0));
        uint256 cancelled = sb.createOrder(address(n), 11, address(B), 500e6, false, 0, true, false, address(0));
        uint256 buy = sb.createOrder(address(A), 50e18, address(n), 12, false, 0, false, true, address(0));
        vm.stopPrank();

        vm.startPrank(taker);
        sb.fillOrder(sell, 0, 0, 0, address(0)); // NFT out of escrow
        sb.fillOrder(buy, 0, 0, 0, address(0)); // NFT in as payment
        vm.stopPrank();
        vm.prank(maker);
        sb.cancelOrder(cancelled); // NFT back to the maker

        assertEq(n.ownerOf(10), taker);
        assertEq(n.ownerOf(11), maker);
        assertEq(n.ownerOf(12), maker);
        assertEq(A.balanceOf(taker), 50e18);
    }

    function test_HonestNftSweepUnaffected() public {
        MockNFT n = new MockNFT();
        n.mint(maker, 13);
        vm.startPrank(maker);
        n.setApprovalForAll(address(sb), true);
        uint256 id = sb.createOrder(
            address(n), 13, address(B), 500e6, false, uint64(block.timestamp + 1), true, false, address(0)
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 2);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        bool[] memory swept = sb.trySweepExpired(ids);
        assertTrue(swept[0]);
        assertEq(n.ownerOf(13), maker, "sweep returned it");
    }
}
