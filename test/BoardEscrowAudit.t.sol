// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// @dev Regressions for the escrow-integrity holes found auditing the position
/// receipts: a surplus sweep that reached into pooled collateral, a freeze that
/// permissionless sweeps ignored, and a spent receipt that resurrected the
/// listing it belonged to.
contract BoardEscrowAuditTest is Test {
    Swapboard sb;
    Dutchboard db;
    MockWETH weth;
    MockERC20 tka;
    MockERC20 tkb;

    address alice = address(0xA11CE); // honest seller
    address mallory = address(0xBAD); // holds a position of her own
    address taker = address(0x7AD);

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        db = new Dutchboard(address(weth));
        tka = new MockERC20("A", 18);
        tkb = new MockERC20("B", 18);

        for (uint256 i; i < 3; ++i) {
            address who = [alice, mallory, taker][i];
            tka.mint(who, 1_000e18);
            tkb.mint(who, 1_000e18);
            vm.startPrank(who);
            tka.approve(address(db), type(uint256).max);
            tkb.approve(address(db), type(uint256).max);
            tka.approve(address(sb), type(uint256).max);
            tkb.approve(address(sb), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------ DUTCHBOARD claimSurplus

    /// Escrow is pooled in one board balance per token, so netting a sweep
    /// against a single listing's `remaining` guarded nothing: the holder of
    /// ANY other position could name someone else's token and walk off with
    /// the collateral backing it.
    function test_SurplusSweepCannotTakeAnotherListingsEscrow() public {
        vm.prank(alice);
        db.listERC20(address(tka), address(tkb), 500e18, 100e18, 50e18, 0, uint40(1 days), 0);
        assertEq(tka.balanceOf(address(db)), 500e18, "alice's escrow is here");

        // Mallory's own listing is in a DIFFERENT token, so the old per-listing
        // subtraction never applied to tka at all.
        vm.prank(mallory);
        uint256 evil = db.listERC20(address(tkb), address(tka), 1e18, 100e18, 50e18, 0, uint40(1 days), 0);

        vm.prank(mallory);
        vm.expectRevert(Dutchboard.NoClaimableProceeds.selector);
        db.claimSurplus(evil, address(tka), mallory);

        assertEq(tka.balanceOf(address(db)), 500e18, "escrow untouched");
        assertEq(tka.balanceOf(mallory), 1_000e18, "nothing extracted");
    }

    /// The same hole via an NFT lot, where no subtraction applied either.
    function test_SurplusSweepCannotTakeEscrowViaAnUnrelatedLot() public {
        vm.prank(alice);
        uint256 lot = db.listERC20(address(tka), address(tkb), 500e18, 100e18, 50e18, 0, uint40(1 days), 0);

        // Mallory holds a position in the very same token.
        vm.prank(mallory);
        uint256 evil = db.listERC20(address(tka), address(tkb), 1e18, 100e18, 50e18, 0, uint40(1 days), 0);

        vm.prank(mallory);
        vm.expectRevert(Dutchboard.NoClaimableProceeds.selector);
        db.claimSurplus(evil, address(tka), mallory);

        // Alice's lot still settles in full.
        vm.prank(taker);
        db.fill(lot, 500e18, taker, type(uint256).max);
        assertEq(tka.balanceOf(taker), 1_500e18, "buyer got the whole lot");
    }

    /// Unattributed arrivals cannot be assigned to the first receipt holder to
    /// ask. Only Swapboard's settlement callbacks create a claimable balance.
    function test_UnattributedSurplusIsNotClaimable() public {
        vm.prank(alice);
        uint256 lot = db.listERC20(address(tka), address(tkb), 500e18, 100e18, 50e18, 0, uint40(1 days), 0);

        // Something pays the board in the escrowed token.
        tka.mint(address(db), 7e18);

        vm.prank(alice);
        vm.expectRevert(Dutchboard.NoClaimableProceeds.selector);
        db.claimSurplus(lot, address(tka), alice);
        assertEq(tka.balanceOf(address(db)), 507e18, "unattributed balance remains untouched");
    }

    function test_ProceedsAreBoundToTheEscrowedSwapboardPosition() public {
        vm.prank(mallory);
        uint256 unrelated = db.listERC20(address(tka), address(tkb), 1e18, 100e18, 50e18, 0, uint40(1 days), 0);

        vm.prank(alice);
        uint256 order = sb.createOrder(address(tka), 100e18, address(tkb), 200e18, false, 0, false, false, address(0));
        uint256 auction = db.nextId();
        vm.prank(alice);
        sb.safeTransferFrom(
            alice,
            address(db),
            order,
            abi.encode(keccak256("Dutchboard.PushTerms.v1"), Dutchboard.PushTerms(address(tkb), 300e18, 100e18, uint40(0), uint40(1 days)))
        );

        vm.prank(taker);
        sb.fillOrder(order, block.timestamp, 200e18, 0, taker);

        vm.prank(mallory);
        vm.expectRevert(Dutchboard.NoClaimableProceeds.selector);
        db.claimSurplus(unrelated, address(tkb), mallory);

        vm.prank(alice);
        assertEq(db.claimSurplus(auction, address(tkb), alice), 200e18, "only the matching receipt may recover it");
    }

    function test_NFTProceedsOfAnEscrowedSwapboardPositionAreRecoverable() public {
        MockNFT payment = new MockNFT();
        payment.mint(taker, 7);
        vm.prank(taker);
        payment.setApprovalForAll(address(sb), true);

        vm.prank(alice);
        uint256 order = sb.createOrder(address(tka), 100e18, address(payment), 7, false, 0, false, true, address(0));
        uint256 auction = db.nextId();
        vm.prank(alice);
        sb.safeTransferFrom(
            alice,
            address(db),
            order,
            abi.encode(keccak256("Dutchboard.PushTerms.v1"), Dutchboard.PushTerms(address(tkb), 300e18, 100e18, uint40(0), uint40(1 days)))
        );

        vm.prank(taker);
        sb.fillOrder(order, block.timestamp, 0, 0, taker);
        assertTrue(db.claimableNFTProceeds(auction, address(payment), 7), "NFT payment was credited");

        vm.prank(alice);
        db.claimNFTProceeds(auction, address(payment), 7, alice);
        assertEq(payment.ownerOf(7), alice, "seller recovered the NFT payment");
    }

    /// Accounting has to survive partial fills and cancellation, or the surplus
    /// line drifts away from the truth in one direction or the other.
    function test_EscrowAccountingTracksFillsAndCancels() public {
        vm.prank(alice);
        uint256 lot = db.listERC20(address(tka), address(tkb), 500e18, 100e18, 50e18, 0, uint40(1 days), 0);
        assertEq(db.escrowed(address(tka)), 500e18);

        vm.prank(taker);
        db.fill(lot, 200e18, taker, type(uint256).max);
        assertEq(db.escrowed(address(tka)), 300e18, "fill released its share");

        vm.prank(alice);
        db.cancel(lot);
        assertEq(db.escrowed(address(tka)), 0, "cancel released the rest");
        assertEq(tka.balanceOf(address(db)), 0, "and the board is empty");
    }

    // ------------------------------------------- DUTCHBOARD spent-ticket state

    /// Receipts outlive their listings now, so transferring a spent one must
    /// not write a seller back into a deleted record and put a phantom listing
    /// in front of takers.
    function test_SpentReceiptDoesNotResurrectItsListing() public {
        vm.prank(alice);
        uint256 lot = db.listERC20(address(tka), address(tkb), 10e18, 100e18, 50e18, 0, uint40(1 days), 0);
        vm.prank(taker);
        db.fill(lot, 10e18, taker, type(uint256).max);

        vm.prank(alice);
        db.transferFrom(alice, mallory, lot);

        Dutchboard.ListingView memory v = db.getListing(lot);
        assertEq(v.seller, address(0), "closed slot stays closed");
        assertEq(db.priceOf(lot), 0, "and quotes nothing");
    }

    // ------------------------------------------------- ERC-721 ENTRY POINTS

    /// Solady reaches the transfer through the PUBLIC, VIRTUAL `transferFrom`,
    /// so guarding both entry points made every safe transfer nest its own
    /// guard and revert as reentrancy - bricking push listings and every
    /// ERC-721-safe integration on both boards.
    function test_SafeTransferOfAPositionIsNotSelfReentrant() public {
        vm.prank(alice);
        uint256 order = sb.createOrder(address(tka), 1e18, address(tkb), 2e18, true, 0, false, false, address(0));
        vm.prank(alice);
        sb.safeTransferFrom(alice, mallory, order);
        assertEq(sb.ownerOf(order), mallory, "swapboard safe transfer works");

        vm.prank(alice);
        uint256 lot = db.listERC20(address(tka), address(tkb), 1e18, 100e18, 50e18, 0, uint40(1 days), 0);
        vm.prank(alice);
        db.safeTransferFrom(alice, mallory, lot);
        assertEq(db.ownerOf(lot), mallory, "dutchboard safe transfer works");
    }

    // ----------------------------------------------------- SWAPBOARD freezing

    function _frozenOrder() internal returns (uint256 id) {
        vm.startPrank(alice);
        id = sb.createOrder(
            address(tka), 100e18, address(tkb), 200e18, true, uint64(block.timestamp + 1 days), false, false, address(0)
        );
        sb.setFrozen(id, true);
        vm.stopPrank();
    }

    /// The freeze is what makes an escrowed position safe to sell, so it has to
    /// hold against every permissionless path. A sweep would have closed the
    /// order under its holder and left a buyer paying for a spent ticket.
    function test_FrozenOrderSurvivesPermissionlessSweep() public {
        uint256 id = _frozenOrder();
        vm.warp(block.timestamp + 2 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderFrozen.selector, id));
        sb.cancelExpired(ids);

        vm.prank(mallory);
        bool[] memory swept = sb.trySweepExpired(ids);
        assertFalse(swept[0], "soft sweep skipped it too");

        (, bool active,,,,,,, uint256 amountA,,) = sb.orders(id);
        assertTrue(active, "claim intact");
        assertEq(amountA, 100e18, "backing intact");
    }

    /// The owner froze it and the owner can still get out; nothing is stranded.
    function test_OwnerCanStillCancelWhileFrozen() public {
        uint256 id = _frozenOrder();
        vm.prank(alice);
        sb.cancelOrder(id);
        assertEq(tka.balanceOf(alice), 1_000e18, "escrow returned");
    }

    /// Frozen belongs with the other not-right-now states in the soft batch,
    /// rather than aborting a keeper's whole page.
    function test_TryFillSkipsFrozenRatherThanReverting() public {
        uint256 frozenId = _frozenOrder();
        vm.prank(alice);
        uint256 openId =
            sb.createOrder(address(tka), 10e18, address(tkb), 20e18, true, 0, false, false, address(0));

        uint256[] memory ids = new uint256[](2);
        uint256[] memory pay = new uint256[](2);
        uint256[] memory floors = new uint256[](2);
        (ids[0], ids[1]) = (frozenId, openId);
        (pay[0], pay[1]) = (200e18, 20e18);

        vm.prank(taker);
        bool[] memory filled = sb.tryFillOrders(ids, 0, pay, floors, taker);
        assertFalse(filled[0], "frozen skipped");
        assertTrue(filled[1], "the rest of the page still filled");
    }
}
