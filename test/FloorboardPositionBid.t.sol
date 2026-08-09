// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// @dev Floorboard DECLARED `LiveOrderPosition()` so its siblings would refuse
/// its receipts, but never checked for one on the asset it bids for. That is
/// the one place the check is load-bearing rather than courteous: a bid escrows
/// the quote and the asset is delivered BY THE SELLER, seller to holder in one
/// hop, with no custody step. So the seller still controls what the position is
/// worth at the moment of delivery - empty it, hand over the spent ticket, take
/// the escrow.
///
/// Dutchboard is the deliberate contrast: listing a position there moves it
/// into escrow FIRST, which is what makes auctioning one safe.
contract FloorboardPositionBidTest is Test {
    Floorboard floor;
    Swapboard swap;
    Dutchboard dutch;
    MockWETH weth;
    MockERC20 quote;
    MockERC20 tka;
    MockNFT plain;

    address bidder = address(0xB1D);
    address maker = address(0xACE);

    function setUp() public {
        vm.warp(10_000);
        weth = new MockWETH();
        floor = new Floorboard(address(weth));
        swap = new Swapboard(address(weth));
        dutch = new Dutchboard(address(weth));
        quote = new MockERC20("Q", 18);
        tka = new MockERC20("A", 18);
        plain = new MockNFT();

        quote.mint(bidder, 1_000_000e18);
        tka.mint(maker, 1_000e18);
        vm.prank(bidder);
        quote.approve(address(floor), type(uint256).max);
    }

    function _terms(address token, uint256[] memory ids) internal view returns (Floorboard.Terms memory) {
        return Floorboard.Terms({
            token: token,
            quote: address(quote),
            want: 1,
            startPrice: 100e18,
            endPrice: 200e18,
            startTime: 0,
            duration: 1000,
            isNFT: true,
            ids: ids
        });
    }

    /// A Swapboard order receipt cannot be bid for: its maker can cancel or
    /// reprice the order to dust in the same transaction that delivers it.
    function test_CannotBidForASwapboardPosition() public {
        vm.prank(maker);
        tka.approve(address(swap), type(uint256).max);
        vm.prank(maker);
        swap.createOrder(address(tka), 100e18, address(quote), 200e18, true, 0, false, false, address(0));

        vm.prank(bidder);
        vm.expectRevert(Floorboard.Bad.selector);
        floor.bid(_terms(address(swap), new uint256[](0)));
    }

    /// The same for a Dutchboard listing receipt, and for this board's own.
    function test_CannotBidForASiblingOrOwnPosition() public {
        vm.prank(bidder);
        vm.expectRevert(Floorboard.Bad.selector);
        floor.bid(_terms(address(dutch), new uint256[](0)));

        vm.prank(bidder);
        vm.expectRevert(Floorboard.Bad.selector);
        floor.bid(_terms(address(floor), new uint256[](0)));
    }

    /// An ordinary collectible is unaffected - the probe rejects, it does not
    /// gate, so a collection that never heard of ERC-165 still bids fine.
    function test_OrdinaryNFTStillBids() public {
        vm.prank(bidder);
        uint256 id = floor.bid(_terms(address(plain), new uint256[](0)));
        (address who, address token,,,,,) = floor.legOf(id);
        assertEq(who, bidder, "bid opened");
        assertEq(token, address(plain), "for the ordinary collection");
    }

    /// And the contrast case still works: Dutchboard takes CUSTODY of a
    /// position before auctioning it, so it is not refused there.
    function test_DutchboardStillTakesCustodyOfAPosition() public {
        vm.prank(maker);
        tka.approve(address(swap), type(uint256).max);
        vm.prank(maker);
        uint256 pos = swap.createOrder(address(tka), 100e18, address(quote), 200e18, true, 0, false, false, address(0));

        uint256[] memory ids = new uint256[](1);
        ids[0] = pos;
        vm.startPrank(maker);
        swap.setApprovalForAll(address(dutch), true);
        dutch.listNFT(address(swap), address(quote), ids, 100e18, 50e18, 0, uint40(1 days));
        vm.stopPrank();

        assertEq(swap.ownerOf(pos), address(dutch), "custody moved to the auction");
    }
}
