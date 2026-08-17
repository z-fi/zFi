// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Orderbol} from "../src/forwarders/Orderbol.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

contract OrderbolTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    Orderbol executor;
    Swapboard swapboard;
    Dutchboard dutchboard;
    MockERC20 lot;
    MockERC20 quote;

    address maker = address(0xA11CE);
    address sponsor = address(0x5A0);
    address taker = address(0xB0B);

    function setUp() public {
        MockWETH wethImpl = new MockWETH();
        vm.etch(WETH, address(wethImpl).code);
        vm.deal(WETH, 1_000 ether);

        swapboard = new Swapboard(WETH);
        dutchboard = new Dutchboard(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        executor = new Orderbol(address(swapboard), address(dutchboard), address(new Floorboard(WETH)));
        // A new contract inherits whatever balance already sits at its address,
        // and these forked tests deploy to deterministic CREATE addresses - one
        // of which (0x2e23...470b) holds 1 wei on mainnet at the pinned block.
        // The refundless-funding assertions read those balances as absolutes.
        vm.deal(address(executor), 0);
        vm.deal(address(swapboard), 0);
        vm.deal(address(dutchboard), 0);
        lot = new MockERC20("LOT", 18);
        quote = new MockERC20("QUOTE", 18);
    }

    function test_routedSwapboardOrderCreditsMakerNotFunder() public {
        vm.prank(sponsor);
        executor.checkpoint(address(lot));
        lot.mint(address(executor), 10e18);

        vm.prank(sponsor);
        uint256 orderId = executor.placeSwapboard(
            address(swapboard), maker, sponsor, address(lot), 10e18, address(quote), 25e18, true, 0, address(0), 0
        );
        assertEq(orderId, 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        Swapboard.Order memory o = swapboard.getOrders(ids)[0];
        assertEq(o.maker, maker, "routed executor became maker");
        assertEq(lot.balanceOf(address(swapboard)), 10e18, "escrow missing");
        assertEq(lot.balanceOf(address(executor)), 0, "executor retained input");
        assertEq(lot.allowance(address(executor), address(swapboard)), 0, "approval survived");

        vm.prank(sponsor);
        vm.expectRevert();
        swapboard.cancelOrder(0);

        vm.prank(maker);
        swapboard.cancelOrder(0);
        assertEq(lot.balanceOf(maker), 10e18, "maker could not reclaim sponsored escrow");
    }

    /// A Dutch lot can be given an END, which is the whole point of this change.
    ///
    /// `placeDutch` hardcoded the board's `expiry` argument to zero, and its own
    /// post-check asserted `l.expiry != 0` - so the adapter enforced the limit it
    /// created, and every test that placed a lot and inspected it passed for the
    /// same reason the bug survived. Dutchboard always took the parameter: the
    /// struct stores it, `_checkExpiry` validates it, `_isExpired` enforces it.
    ///
    /// The asymmetry it left is the part worth pinning. A fixed Swapboard order,
    /// which commits to ONE price forever, could be given an expiry. A Dutch
    /// lot - the one order whose premise is that time changes what the seller
    /// will accept - could not, and rested at its floor indefinitely whether or
    /// not that was meant.
    function test_aRoutedDutchLotCanBeGivenAnExpiry() public {
        executor.checkpoint(address(lot));
        lot.mint(address(executor), 10e18);

        uint40 ends = uint40(block.timestamp + 2 days);
        uint256 listingId = executor.placeDutch(
            address(dutchboard), maker, sponsor, address(lot), address(quote), 10e18, 25e18, 20e18, 0, 1 hours, ends, 0
        );

        assertEq(dutchboard.getListing(listingId).expiry, ends, "the expiry never reached the board");

        // And it BITES: past it the lot is closed to fills, rather than resting
        // at its floor for whoever turns up.
        quote.mint(taker, 100e18);
        vm.warp(uint256(ends) + 1);
        vm.startPrank(taker);
        quote.approve(address(dutchboard), type(uint256).max);
        vm.expectRevert(Dutchboard.Expired.selector);
        dutchboard.fill(listingId, 10e18, taker, 25e18);
        vm.stopPrank();
    }

    /// Zero still means rest forever, so the old behaviour is a choice now
    /// rather than the only option.
    function test_zeroExpiryStillRestsAtTheFloor() public {
        executor.checkpoint(address(lot));
        lot.mint(address(executor), 10e18);
        quote.mint(taker, 100e18);

        uint256 listingId = executor.placeDutch(
            address(dutchboard), maker, sponsor, address(lot), address(quote), 10e18, 25e18, 20e18, 0, 1 hours, 0, 0
        );
        assertEq(dutchboard.getListing(listingId).expiry, 0);

        vm.warp(block.timestamp + 30 days);        // long past the decay window
        vm.startPrank(taker);
        quote.approve(address(dutchboard), type(uint256).max);
        dutchboard.fill(listingId, 10e18, taker, 25e18);   // still fillable, at the floor
        vm.stopPrank();
        assertEq(lot.balanceOf(taker), 10e18, "a zero expiry must still rest, not close");
    }

    function test_routedDutchOrderCreditsSellerAndPaysThem() public {
        executor.checkpoint(address(lot));
        lot.mint(address(executor), 10e18);
        quote.mint(taker, 100e18);

        uint256 listingId = executor.placeDutch(
            address(dutchboard), maker, sponsor, address(lot), address(quote), 10e18, 25e18, 20e18, 0, 1 hours, 0, 0
        );
        assertEq(listingId, 0);

        Dutchboard.ListingView memory l = dutchboard.getListing(0);
        assertEq(l.seller, maker, "routed executor became seller");
        assertEq(lot.balanceOf(address(dutchboard)), 10e18, "escrow missing");
        assertEq(lot.allowance(address(executor), address(dutchboard)), 0, "approval survived");

        vm.startPrank(taker);
        quote.approve(address(dutchboard), type(uint256).max);
        dutchboard.fill(0, 10e18, taker, 25e18);
        vm.stopPrank();

        assertEq(quote.balanceOf(maker), 25e18, "seller did not receive proceeds");
        assertEq(quote.balanceOf(address(executor)), 0, "executor captured proceeds");
    }

    function test_nativeSwapboardFundingStillCreditsMaker() public {
        vm.deal(address(this), 10 ether);

        executor.placeSwapboard{value: 2 ether}(
            address(swapboard), maker, address(this), address(0), 2 ether, address(quote), 5e18, true, 0, address(0), 0
        );

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        Swapboard.Order memory o = swapboard.getOrders(ids)[0];
        assertEq(o.maker, maker);
        assertEq(o.tokenA, WETH);
        assertEq(o.amountA, 2 ether);
        assertEq(MockWETH(payable(WETH)).balanceOf(address(swapboard)), 2 ether);
        assertEq(address(executor).balance, 0);
    }

    function test_nativeDutchFundingIsCanonicalWethAndRefundless() public {
        vm.deal(address(this), 10 ether);

        executor.placeDutch{value: 3 ether}(
            address(dutchboard), maker, address(this), address(0), address(quote), 3 ether, 9e18, 6e18, 0, 1 days, 0, 0
        );

        Dutchboard.ListingView memory l = dutchboard.getListing(0);
        assertEq(l.seller, maker);
        assertEq(l.token, WETH);
        assertEq(l.initial, 3 ether);
        assertEq(MockWETH(payable(WETH)).balanceOf(address(dutchboard)), 3 ether);
        assertEq(address(executor).balance, 0);
    }

    function test_forcedEthAndDonatedTokensAreNotGiftedToNextMaker() public {
        vm.deal(address(executor), 1 ether);
        lot.mint(address(executor), 1e18);
        executor.checkpoint(address(lot));
        lot.mint(address(executor), 10e18);

        executor.placeSwapboard(
            address(swapboard), maker, sponsor, address(lot), 10e18, address(quote), 25e18, true, 0, address(0), 0
        );

        assertEq(address(executor).balance, 1 ether, "pre-existing ETH was swept");
        assertEq(lot.balanceOf(address(executor)), 1e18, "pre-existing token was swept");
        assertEq(lot.balanceOf(sponsor), 0, "caller captured donated assets");

        // A fresh transaction could checkpoint the donation, but without a
        // balance increase after that checkpoint it still cannot consume it.
        executor.checkpoint(address(lot));
        vm.expectRevert(abi.encodeWithSelector(Orderbol.InputMismatch.selector, 1e18, 0));
        executor.placeSwapboard(
            address(swapboard),
            address(this),
            address(this),
            address(lot),
            1e18,
            address(quote),
            1e18,
            true,
            0,
            address(0),
            0
        );
    }

    function test_executorCannotBecomeOwnerOrRefundRecipient() public {
        vm.expectRevert(Orderbol.BadOrder.selector);
        executor.placeSwapboard(
            address(swapboard),
            address(executor),
            sponsor,
            address(0),
            1 ether,
            address(quote),
            1e18,
            true,
            0,
            address(0),
            0
        );

        vm.expectRevert(Orderbol.BadOrder.selector);
        executor.placeSwapboard(
            address(swapboard), maker, address(executor), address(0), 1 ether, address(quote), 1e18, true, 0, address(0), 0
        );

        vm.expectRevert(Orderbol.BadOrder.selector);
        executor.placeDutch(
            address(dutchboard), address(executor), sponsor, address(0), address(quote), 1 ether, 1e18, 1e18, 0, 1 days, 0, 0
        );
    }

    function test_rejectsArbitraryBoardAndWethRefundRecipient() public {
        MockERC20 fake = new MockERC20("FAKE", 18);
        vm.expectRevert(Orderbol.BadOrder.selector);
        executor.placeSwapboard(
            address(fake), maker, sponsor, address(lot), 1e18, address(quote), 1e18, true, 0, address(0), 0
        );

        vm.expectRevert(Orderbol.BadOrder.selector);
        executor.placeSwapboard(
            address(swapboard), maker, WETH, address(lot), 1e18, address(quote), 1e18, true, 0, address(0), 0
        );
    }

    function test_rejectsExpiredPlacementDeadline() public {
        vm.expectRevert(Orderbol.DeadlineExpired.selector);
        executor.placeSwapboard(
            address(swapboard), maker, sponsor, address(lot), 1e18, address(quote), 1e18, true, 0, address(0), 1
        );
    }
}
