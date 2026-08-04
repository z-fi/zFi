// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @dev What actually happens when the order underlying an auctioned position
/// is filled while the auction is still running.
contract PositionAuctionHazardTest is Test {
    Swapboard sb;
    Dutchboard db;
    MockWETH weth;
    MockERC20 tka;
    MockERC20 tkb;

    address maker = address(0xACE);
    address taker = address(0x7AD);

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        db = new Dutchboard(address(weth));
        tka = new MockERC20("A", 18);
        tkb = new MockERC20("B", 18);

        tka.mint(maker, 1_000e18);
        tkb.mint(taker, 1_000e18);
        vm.prank(maker);
        tka.approve(address(sb), type(uint256).max);
        vm.prank(taker);
        tkb.approve(address(sb), type(uint256).max);
    }

    /// @dev The full feature, end to end. A FROZEN position is inert, so it
    /// can be auctioned safely: no taker can shrink or close it while the sale
    /// is in flight, and the buyer thaws it once they hold it.
    function test_AFrozenPositionAuctionsSafely() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(address(tka), 100e18, address(tkb), 200e18, true, 0, false, false, address(0));

        // Freeze BEFORE listing, so what a bidder simulates is what they get.
        vm.prank(maker);
        sb.setFrozen(id, true);

        vm.prank(maker);
        sb.safeTransferFrom(
            maker, address(db), id,
            abi.encode(Dutchboard.PushTerms(address(tkb), 300e18, 100e18, uint40(0), uint40(1 days)))
        );

        // A taker cannot touch the claim while it is escrowed.
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderFrozen.selector, id));
        sb.fillOrder(id, block.timestamp, 200e18, 0, taker);

        // The claim is exactly what it was when listed.
        (,,,,,,,, uint256 amountA,,) = sb.orders(id);
        assertEq(amountA, 100e18, "claim unchanged during the auction");
        assertEq(sb.ownerOf(id), address(db), "and the auction still holds it");
    }

    /// @dev And an UNFROZEN position filled mid-auction no longer bricks
    /// anything: the receipt survives, so the listing can still be cancelled,
    /// and the proceeds that landed here can be claimed by the seller.
    function test_UnfrozenPositionFilledMidAuctionIsStillRecoverable() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(address(tka), 100e18, address(tkb), 200e18, true, 0, false, false, address(0));

        vm.prank(maker);
        sb.safeTransferFrom(
            maker, address(db), id,
            abi.encode(Dutchboard.PushTerms(address(tkb), 300e18, 100e18, uint40(0), uint40(1 days)))
        );

        vm.prank(taker);
        sb.fillOrder(id, block.timestamp, 200e18, 0, taker);

        // Previously: ownerOf reverted, cancel bricked, 200 tokenB stranded.
        assertEq(sb.ownerOf(id), address(db), "receipt survived the close");

        vm.prank(maker);
        db.cancel(0);
        assertEq(sb.ownerOf(id), maker, "listing cancelled, spent ticket returned");

        vm.prank(maker);
        uint256 swept = db.claimSurplus(0, address(tkb), maker);
        assertEq(swept, 200e18, "proceeds recovered rather than stranded");
        assertEq(tkb.balanceOf(maker), 200e18);
    }

    function _owns(uint256 id, address who) internal view returns (bool) {
        try sb.ownerOf(id) returns (address o) { return o == who; } catch { return false; }
    }
}
