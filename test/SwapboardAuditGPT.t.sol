// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// @dev Regressions for the findings raised in `audit/Swapboard/gpt56-sol-pro.md`:
/// the commitment that makes an off-board sale safe (H-02), the ERC-165 type
/// enforcement that stops an ERC-721 resting as a fungible order (M-01), the
/// ETH-trap refusal on the payable receipt methods (L-01), the sender-side
/// debit check on every fungible pull (L-02).
contract SwapboardAuditGPTTest is Test {
    Swapboard sb;
    MockWETH weth;
    MockERC20 tka;
    MockERC20 tkb;

    address maker = address(0xACE);
    address taker = address(0x7AD);
    address buyer = address(0xB0B);

    event OrderCommitmentSet(uint256 indexed orderId, uint64 until);

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        tka = new MockERC20("A", 18);
        tkb = new MockERC20("B", 18);

        tka.mint(maker, 1_000e18);
        tkb.mint(taker, 1_000e18);
        vm.prank(maker);
        tka.approve(address(sb), type(uint256).max);
        vm.prank(taker);
        tkb.approve(address(sb), type(uint256).max);
    }

    function _order() internal returns (uint256 id) {
        vm.prank(maker);
        id = sb.createOrder(address(tka), 100e18, address(tkb), 200e18, true, 0, false, false, address(0));
    }

    // ---------------------------------------------------------------- H-02

    /// The whole point: while committed, the seller cannot empty the claim out
    /// from under a buyer who is mid-purchase on some other venue.
    function test_CommittedPositionCannotBeCancelledOrReduced() public {
        uint256 id = _order();
        uint64 until = uint64(block.timestamp + 1 days);
        vm.prank(maker);
        sb.commitFrozen(id, until);

        assertTrue(sb.frozen(id), "committed reads as frozen");

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.CommitmentActive.selector, id, until));
        sb.cancelOrder(id);

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderFrozen.selector, id));
        sb.replaceOrder(id, 1, 1, 0);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderFrozen.selector, id));
        sb.fillOrder(id, 0, 200e18, 0, taker);

        // Thawing the soft flag does not lift it either.
        vm.prank(maker);
        sb.setFrozen(id, false);
        assertTrue(sb.frozen(id), "commitment outranks the soft flag");
    }

    /// A live commitment is immutable in BOTH directions, so the timestamp a
    /// buyer reads is the exact end of the window rather than a floor the
    /// seller can raise between simulation and settlement.
    function test_LiveCommitmentCannotBeRewritten() public {
        uint256 id = _order();
        uint64 until = uint64(block.timestamp + 1 days);
        vm.startPrank(maker);
        sb.commitFrozen(id, until);

        vm.expectRevert(abi.encodeWithSelector(Swapboard.CommitmentActive.selector, id, until));
        sb.commitFrozen(id, uint64(block.timestamp + 1 hours));
        vm.expectRevert(abi.encodeWithSelector(Swapboard.CommitmentActive.selector, id, until));
        sb.commitFrozen(id, uint64(block.timestamp + 2 days));
        vm.stopPrank();
        assertEq(sb.frozenUntil(id), until);

        // A fresh window may only be opened once the previous one has lapsed.
        vm.warp(uint256(until) + 1);
        vm.prank(maker);
        sb.commitFrozen(id, uint64(block.timestamp + 2 days));
        assertEq(sb.frozenUntil(id), uint64(block.timestamp + 2 days));
    }

    /// It rides with the token. Clearing on sale would let the seller void the
    /// commitment by round-tripping the receipt through a second wallet, which
    /// is the one thing it exists to prevent.
    function test_CommitmentSurvivesTransfer() public {
        uint256 id = _order();
        uint64 until = uint64(block.timestamp + 1 days);
        vm.startPrank(maker);
        sb.commitFrozen(id, until);

        sb.transferFrom(maker, maker, id);
        assertEq(sb.frozenUntil(id), until, "self-transfer clears nothing");

        sb.transferFrom(maker, buyer, id);
        vm.stopPrank();

        assertEq(sb.frozenUntil(id), until, "and neither does a sale");
        assertEq(sb.ownerOf(id), buyer);

        // The buyer holds a bound claim, exactly as advertised...
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.CommitmentActive.selector, id, until));
        sb.cancelOrder(id);

        // ...which lapses on its own timestamp, with the backing intact.
        vm.warp(uint256(until) + 1);
        vm.prank(buyer);
        sb.cancelOrder(id);
        assertEq(tka.balanceOf(buyer), 100e18, "and the full backing was still there");
    }

    /// The window is bounded, so a mistake is a wait rather than a burn.
    function test_CommitmentIsCapped() public {
        uint256 id = _order();
        uint64 max = uint64(block.timestamp) + sb.MAX_COMMITMENT();
        vm.expectRevert(abi.encodeWithSelector(Swapboard.CommitmentTooLong.selector, max + 1, max));
        vm.prank(maker);
        sb.commitFrozen(id, max + 1);

        vm.prank(maker);
        sb.commitFrozen(id, max);
    }

    /// The commitment is not a trap: it lapses on its own timestamp.
    function test_CommitmentLapses() public {
        uint256 id = _order();
        vm.prank(maker);
        sb.commitFrozen(id, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(maker);
        sb.cancelOrder(id);
        assertEq(tka.balanceOf(maker), 1_000e18);
    }

    /// A committed order is not sweepable either.
    function test_CommittedOrderIsNotSweepable() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(
            address(tka),
            100e18,
            address(tkb),
            200e18,
            true,
            uint64(block.timestamp + 1 hours),
            false,
            false,
            address(0)
        );
        vm.prank(maker);
        sb.commitFrozen(id, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 hours);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderFrozen.selector, id));
        sb.cancelExpired(ids);
        bool[] memory swept = sb.trySweepExpired(ids);
        assertFalse(swept[0]);
    }

    function test_OnlyOwnerCommits() public {
        uint256 id = _order();
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotMaker.selector, id, taker, maker));
        sb.commitFrozen(id, uint64(block.timestamp + 1 days));

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.ExpiryInPast.selector, uint64(block.timestamp)));
        sb.commitFrozen(id, uint64(block.timestamp));
    }

    // ---------------------------------------------------------------- M-01

    /// ERC-20 and ERC-721 share `balanceOf` and `transferFrom`, so token id 1
    /// escrowed as a fungible amount of 1 used to pass the exact-delta check
    /// and lock the NFT behind a `transfer` no ERC-721 implements.
    function test_ERC721CannotRestAsAFungibleOrder() public {
        Declaring721 nft = new Declaring721();
        nft.mint(maker, 1);
        vm.startPrank(maker);
        nft.setApprovalForAll(address(sb), true);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.ExpectedERC20.selector, address(nft)));
        sb.createOrder(address(nft), 1, address(tkb), 200e18, false, 0, false, false, address(0));
        vm.stopPrank();
        assertEq(nft.ownerOf(1), maker, "the NFT never moved");
    }

    function test_ERC721CannotBeAskedForAsAFungiblePrice() public {
        Declaring721 nft = new Declaring721();
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.ExpectedERC20.selector, address(nft)));
        sb.createOrder(address(tka), 100e18, address(nft), 1, false, 0, false, false, address(0));
    }

    /// Declared correctly, the same collection trades normally.
    function test_DeclaredNFTStillTrades() public {
        Declaring721 nft = new Declaring721();
        nft.mint(maker, 1);
        vm.startPrank(maker);
        nft.setApprovalForAll(address(sb), true);
        uint256 id = sb.createOrder(address(nft), 1, address(tkb), 5e18, false, 0, true, false, address(0));
        vm.stopPrank();
        vm.prank(taker);
        sb.fillOrder(id, 0, 5e18, 0, taker);
        assertEq(nft.ownerOf(1), taker);
    }

    /// A token that answers ERC-165 with garbage is inert, not refused: the
    /// probe reads the word rather than decoding it, so a noncanonical boolean
    /// cannot revert the whole order.
    function test_MalformedERC165IsInert() public {
        LyingERC165 t = new LyingERC165();
        t.mint(maker, 100e18);
        vm.startPrank(maker);
        t.approve(address(sb), type(uint256).max);
        sb.createOrder(address(t), 100e18, address(tkb), 200e18, false, 0, false, false, address(0));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- L-01

    function test_PayableReceiptMethodsRefuseETH() public {
        uint256 id = _order();
        vm.deal(maker, 3 ether);
        uint256 boardBefore = address(sb).balance;
        vm.startPrank(maker);
        vm.expectRevert(Swapboard.UnexpectedETH.selector);
        sb.transferFrom{value: 1 ether}(maker, buyer, id);
        vm.expectRevert(Swapboard.UnexpectedETH.selector);
        sb.safeTransferFrom{value: 1 ether}(maker, buyer, id);
        vm.expectRevert(Swapboard.UnexpectedETH.selector);
        sb.approve{value: 1 ether}(buyer, id);
        vm.stopPrank();
        assertEq(address(sb).balance, boardBefore, "no ETH is ever trapped here");
    }

    // ---------------------------------------------------------------- L-02

    /// A sender-tax token debits the payer more than the order says. Measuring
    /// only the credit waved that through.
    function test_SenderTaxPaymentIsRefused() public {
        SenderTax tax = new SenderTax();
        tax.mint(taker, 1_000e18);
        vm.prank(maker);
        uint256 id = sb.createOrder(address(tka), 100e18, address(tax), 200e18, false, 0, false, false, address(0));
        vm.startPrank(taker);
        tax.approve(address(sb), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(Swapboard.BalanceDeltaMismatch.selector, address(tax), taker, 200e18, 201e18)
        );
        sb.fillOrder(id, 0, 200e18, 0, taker);
        vm.stopPrank();
    }

    function test_SenderTaxEscrowIsRefused() public {
        SenderTax tax = new SenderTax();
        tax.mint(maker, 1_000e18);
        vm.startPrank(maker);
        tax.approve(address(sb), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(Swapboard.BalanceDeltaMismatch.selector, address(tax), maker, 100e18, 101e18)
        );
        sb.createOrder(address(tax), 100e18, address(tkb), 200e18, false, 0, false, false, address(0));
        vm.stopPrank();
    }
}

/// @dev An ERC-721 that says so through ERC-165, as any real one does.
contract Declaring721 is MockNFT {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x80ac58cd;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Answers ERC-165 with a noncanonical word - `abi.decode` would revert on
///      it, which would turn "malformed" into "refused".
contract LyingERC165 is MockERC20("LIE", 18) {
    function supportsInterface(bytes4) external pure returns (bytes32) {
        return bytes32(uint256(2));
    }
}

/// @dev Debits the sender 1e18 more than it credits the recipient.
contract SenderTax is MockERC20("TAX", 18) {
    function transferFrom(address f, address t, uint256 v) public override returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        balanceOf[f] -= v + 1e18;
        balanceOf[t] += v;
        return true;
    }
}
