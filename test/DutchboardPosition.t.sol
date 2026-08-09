// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @dev Listings are ERC-721 positions, matching Swapboard. The receipt is the
/// point: a wallet simulating a listing now shows an asset arriving.
contract DutchboardPositionTest is Test {
    Dutchboard db;
    Swapboard sb;
    MockWETH weth;
    MockERC20 lot;
    MockERC20 quote;

    address seller = address(0xACE);
    address buyer = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        db = new Dutchboard(address(weth));
        sb = new Swapboard(address(weth));
        lot = new MockERC20("LOT", 18);
        quote = new MockERC20("Q", 18);

        lot.mint(seller, 1_000e18);
        quote.mint(buyer, 1_000_000e18);

        vm.prank(seller);
        lot.approve(address(db), type(uint256).max);
        vm.prank(buyer);
        quote.approve(address(db), type(uint256).max);
    }

    function _list() internal returns (uint256 id) {
        vm.prank(seller);
        id = db.listERC20(address(lot), address(quote), 100e18, 1_000e18, 500e18, 0, uint40(1 days), 0);
    }

    function test_ListingMintsAPositionToTheSeller() public {
        uint256 id = _list();
        assertEq(db.ownerOf(id), seller, "seller holds the position");
        assertEq(db.name(), "Dutchboard Position");
    }

    /// @dev Ownership is sellership: moving the position moves the proceeds.
    function test_TransferringThePositionMovesTheProceeds() public {
        uint256 id = _list();

        vm.prank(seller);
        db.transferFrom(seller, buyer, id);
        (address s,,,,,,,,,,) = db.listings(id);
        assertEq(s, buyer, "stored seller followed the position");

        // And the new owner can cancel to reclaim the unsold lot.
        vm.prank(buyer);
        db.cancel(id);
        assertEq(lot.balanceOf(buyer), 100e18, "unsold lot went to the new owner");
    }

    function test_OldOwnerLosesAuthority() public {
        uint256 id = _list();
        vm.prank(seller);
        db.transferFrom(seller, buyer, id);

        vm.prank(seller);
        vm.expectRevert(Dutchboard.NotSeller.selector);
        db.cancel(id);
    }

    function test_PositionCannotGoSomewhereUnpayable() public {
        uint256 id = _list();
        vm.prank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        db.transferFrom(seller, address(db), id);
    }

    /// @dev Partial fills leave the listing live, so the receipt survives.
    function test_PartialFillKeepsThePositionAndExhaustionSpendsIt() public {
        uint256 id = _list();

        vm.prank(buyer);
        db.fill(id, 40e18, buyer, type(uint256).max);
        assertEq(db.ownerOf(id), seller, "still live after a partial fill");

        vm.prank(buyer);
        db.fill(id, 60e18, buyer, type(uint256).max);
        assertEq(db.ownerOf(id), seller, "receipt survives exhaustion as a spent ticket");
        (address s2,,,,,,,,,,) = db.listings(id);
        assertEq(s2, address(0), "but the listing itself is closed");
    }

    function test_CancelLeavesASpentReceipt() public {
        uint256 id = _list();
        vm.prank(seller);
        db.cancel(id);
        assertEq(db.ownerOf(id), seller, "receipt survives cancellation");
    }
}
