// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {OrderbolL2} from "../src/forwarders/OrderbolL2.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @notice `placeFloor`, plus enough of the inherited two to show the third
///         board did not disturb them.
contract OrderbolL2FloorTest is Test {
    address constant WETH = 0x4200000000000000000000000000000000000006;

    OrderbolL2 executor;
    Swapboard swapboard;
    Dutchboard dutchboard;
    Floorboard floorboard;
    MockERC20 lot;
    MockERC20 quote;

    address maker = address(0xA11CE);
    address sponsor = address(0x5A0);
    address seller = address(0x5E11);

    uint128 constant WANT = 100e18;
    uint256 constant START = 150e18;
    uint256 constant END = 200e18;

    function setUp() public {
        vm.warp(10_000);
        MockWETH wethImpl = new MockWETH();
        vm.etch(WETH, address(wethImpl).code);
        vm.deal(WETH, 1_000 ether);

        swapboard = new Swapboard(WETH);
        dutchboard = new Dutchboard(WETH);
        floorboard = new Floorboard(WETH);
        executor = new OrderbolL2(address(swapboard), address(dutchboard), address(floorboard), WETH);
        // Deterministic CREATE addresses on the pinned fork can already hold
        // dust; the refundless-funding assertions read balances as absolutes.
        vm.deal(address(executor), 0);
        vm.deal(address(swapboard), 0);
        vm.deal(address(dutchboard), 0);
        vm.deal(address(floorboard), 0);

        lot = new MockERC20("LOT", 18);
        quote = new MockERC20("QUOTE", 18);
    }

    // ----------------------------------------------------------- placeFloor

    function test_routedFloorBidCreditsBidderNotFunder() public {
        vm.prank(sponsor);
        executor.checkpoint(address(quote));
        quote.mint(address(executor), END);

        vm.prank(sponsor);
        uint256 bidId = executor.placeFloor(
            address(floorboard), maker, sponsor, address(lot), address(quote), WANT, START, END, 0, 1 hours, 0
        );
        assertEq(bidId, 0);

        Floorboard.BidView memory b = floorboard.getBid(bidId);
        assertEq(b.bidder, maker, "routed executor became the bidder");
        assertEq(b.token, address(lot));
        assertEq(b.quote, address(quote));
        assertEq(b.initial, WANT);
        // The ceiling, not the start, and not a function of `want`.
        assertEq(quote.balanceOf(address(floorboard)), END, "escrow is not the ceiling");
        assertEq(quote.balanceOf(address(executor)), 0, "executor retained the escrow");
        assertEq(quote.allowance(address(executor), address(floorboard)), 0, "approval survived");

        // Cancellation rights went with the receipt, not with the funder.
        vm.prank(sponsor);
        vm.expectRevert();
        floorboard.cancel(bidId);

        vm.prank(maker);
        floorboard.cancel(bidId);
        assertEq(quote.balanceOf(maker), END, "bidder could not reclaim sponsored escrow");
    }

    /// The bid has to actually be hittable afterwards - a placement that
    /// verifies but cannot be sold into is not a placement.
    function test_routedFloorBidIsHittable() public {
        executor.checkpoint(address(quote));
        quote.mint(address(executor), END);
        uint256 bidId = executor.placeFloor(
            address(floorboard), maker, sponsor, address(lot), address(quote), WANT, START, END, 0, 1 hours, 0
        );

        lot.mint(seller, WANT);
        vm.startPrank(seller);
        lot.approve(address(floorboard), type(uint256).max);
        uint256 proceeds = floorboard.hit(bidId, WANT, 0, false);
        vm.stopPrank();

        assertGt(proceeds, 0, "bid paid nothing");
        assertEq(lot.balanceOf(maker), WANT, "bidder did not receive the asset");
        assertEq(quote.balanceOf(seller), proceeds, "seller was not paid");
        assertEq(quote.balanceOf(address(executor)), 0, "executor captured proceeds");
    }

    function test_nativeQuotedFloorBidEscrowsCanonicalWethAndIsRefundless() public {
        vm.deal(address(this), 1_000e18);

        uint256 bidId = executor.placeFloor{value: END}(
            address(floorboard), maker, address(this), address(lot), address(0), WANT, START, END, 0, 1 days, 0
        );

        Floorboard.BidView memory b = floorboard.getBid(bidId);
        assertEq(b.bidder, maker);
        // An ETH-funded bid is WETH-quoted from the moment it opens.
        assertEq(b.quote, WETH, "native bid was not wrapped into a WETH escrow");
        assertEq(MockWETH(payable(WETH)).balanceOf(address(floorboard)), END);
        assertEq(address(executor).balance, 0, "value stranded in the executor");
    }

    /// The board demands the exact ceiling as value. Funding it off `startPrice`
    /// or off `want` is the mistake this entry point exists to catch early.
    function test_nativeFloorBidRejectsAnythingButTheCeiling() public {
        vm.deal(address(this), 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(OrderbolL2.InputMismatch.selector, END, START));
        executor.placeFloor{value: START}(
            address(floorboard), maker, address(this), address(lot), address(0), WANT, START, END, 0, 1 days, 0
        );
    }

    function test_erc20FloorBidRejectsAShortCheckpointedTransfer() public {
        executor.checkpoint(address(quote));
        quote.mint(address(executor), START); // short of the ceiling

        vm.expectRevert(abi.encodeWithSelector(OrderbolL2.InputMismatch.selector, END, START));
        executor.placeFloor(
            address(floorboard), maker, sponsor, address(lot), address(quote), WANT, START, END, 0, 1 hours, 0
        );
    }

    /// The mirror of `placeDutch`: that schedule must not rise, this one must
    /// not fall. Getting the comparison the wrong way round is the single most
    /// likely copy-paste error between the two.
    function test_floorBidRejectsADescendingSchedule() public {
        executor.checkpoint(address(quote));
        quote.mint(address(executor), END);

        vm.expectRevert(OrderbolL2.BadOrder.selector);
        executor.placeFloor(
            address(floorboard), maker, sponsor, address(lot), address(quote), WANT, END, START, 0, 1 hours, 0
        );
    }

    function test_floorBidRejectsBadShapes() public {
        // Arbitrary board.
        vm.expectRevert(OrderbolL2.BadOrder.selector);
        executor.placeFloor(
            address(swapboard), maker, sponsor, address(lot), address(quote), WANT, START, END, 0, 1 hours, 0
        );

        // The executor may be neither the bidder nor the refund recipient.
        vm.expectRevert(OrderbolL2.BadOrder.selector);
        executor.placeFloor(
            address(floorboard),
            address(executor),
            sponsor,
            address(lot),
            address(quote),
            WANT,
            START,
            END,
            0,
            1 hours,
            0
        );
        vm.expectRevert(OrderbolL2.BadOrder.selector);
        executor.placeFloor(
            address(floorboard),
            maker,
            address(executor),
            address(lot),
            address(quote),
            WANT,
            START,
            END,
            0,
            1 hours,
            0
        );

        // A refund recipient that is one of the boards.
        vm.expectRevert(OrderbolL2.BadOrder.selector);
        executor.placeFloor(
            address(floorboard),
            maker,
            address(floorboard),
            address(lot),
            address(quote),
            WANT,
            START,
            END,
            0,
            1 hours,
            0
        );

        // Buying the same asset that pays for it.
        vm.expectRevert(OrderbolL2.BadOrder.selector);
        executor.placeFloor(
            address(floorboard), maker, sponsor, address(quote), address(quote), WANT, START, END, 0, 1 hours, 0
        );

        // Zero size, and a zero duration - a bid with no window is dead on open.
        vm.expectRevert(OrderbolL2.BadOrder.selector);
        executor.placeFloor(
            address(floorboard), maker, sponsor, address(lot), address(quote), 0, START, END, 0, 1 hours, 0
        );
        vm.expectRevert(OrderbolL2.BadOrder.selector);
        executor.placeFloor(
            address(floorboard), maker, sponsor, address(lot), address(quote), WANT, START, END, 0, 0, 0
        );
    }

    function test_floorBidRejectsAnExpiredPlacementDeadline() public {
        vm.expectRevert(OrderbolL2.DeadlineExpired.selector);
        executor.placeFloor(
            address(floorboard), maker, sponsor, address(lot), address(quote), WANT, START, END, 0, 1 hours, 1
        );
    }

    function test_donatedQuoteCannotBecomeSomeonesFloorBid() public {
        vm.deal(address(executor), 1 ether);
        quote.mint(address(executor), END);

        executor.checkpoint(address(quote));
        vm.expectRevert(abi.encodeWithSelector(OrderbolL2.InputMismatch.selector, END, 0));
        executor.placeFloor(
            address(floorboard), maker, sponsor, address(lot), address(quote), WANT, START, END, 0, 1 hours, 0
        );

        assertEq(address(executor).balance, 1 ether, "pre-existing ETH was swept");
        assertEq(quote.balanceOf(address(executor)), END, "pre-existing token was consumed");
    }

    // --------------------------------------------- the inherited two, intact

    function test_swapboardPlacementStillCreditsMaker() public {
        executor.checkpoint(address(lot));
        lot.mint(address(executor), 10e18);

        uint256 orderId = executor.placeSwapboard(
            address(swapboard), maker, sponsor, address(lot), 10e18, address(quote), 25e18, true, 0, address(0), 0
        );

        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        assertEq(swapboard.getOrders(ids)[0].maker, maker);
        assertEq(lot.balanceOf(address(swapboard)), 10e18);
    }

    function test_dutchPlacementStillCreditsSeller() public {
        executor.checkpoint(address(lot));
        lot.mint(address(executor), 10e18);

        uint256 listingId = executor.placeDutch(
            address(dutchboard), maker, sponsor, address(lot), address(quote), 10e18, 25e18, 20e18, 0, 1 hours, 0, 0
        );

        assertEq(dutchboard.getListing(listingId).seller, maker);
        assertEq(lot.balanceOf(address(dutchboard)), 10e18);
    }

    function test_constructorRejectsARepeatedOrMissingBoard() public {
        vm.expectRevert(OrderbolL2.BadOrder.selector);
        new OrderbolL2(address(swapboard), address(swapboard), address(floorboard), WETH);

        vm.expectRevert(OrderbolL2.BadOrder.selector);
        new OrderbolL2(address(swapboard), address(dutchboard), address(0), WETH);
    }
}
