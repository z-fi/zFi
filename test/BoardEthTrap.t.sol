// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// Solady makes the ERC-721 mutators `payable` for the gas saving. A board's
/// `receive()` is WETH-only, but that rule never runs when calldata selects a
/// payable function - so ETH attached to `transferFrom` or `approve` is simply
/// accepted, and none of these boards has a native-ETH rescue path.
///
/// Swapboard already refused this (its audit's L-01). Dutchboard and Floorboard
/// did not, which is the gap these tests close.
contract BoardEthTrapTest is Test {
    MockWETH weth;
    MockERC20 quoteToken;
    MockERC20 want;
    Floorboard floor;
    Dutchboard dutch;
    Swapboard swap;

    address holder = address(0xB1D);
    address other = address(0x0DE);

    function setUp() public {
        vm.warp(10_000);
        weth = new MockWETH();
        quoteToken = new MockERC20("Q", 18);
        want = new MockERC20("W", 18);
        floor = new Floorboard(address(weth));
        dutch = new Dutchboard(address(weth));
        swap = new Swapboard(address(weth));

        quoteToken.mint(holder, 1_000_000e18);
        want.mint(holder, 1_000_000e18);
        vm.startPrank(holder);
        quoteToken.approve(address(floor), type(uint256).max);
        quoteToken.approve(address(dutch), type(uint256).max);
        want.approve(address(dutch), type(uint256).max);
        want.approve(address(swap), type(uint256).max);
        vm.stopPrank();
        vm.deal(holder, 100 ether);
    }

    function _floorBid() internal returns (uint256 id) {
        Floorboard.Terms memory t = Floorboard.Terms({
            token: address(want),
            quote: address(quoteToken),
            want: 1000e18,
            startPrice: 100e18,
            endPrice: 200e18,
            startTime: 0,
            duration: 1000,
            isNFT: false,
            ids: new uint256[](0)
        });
        vm.prank(holder);
        id = floor.bid(t);
    }

    function _dutchListing() internal returns (uint256 id) {
        vm.prank(holder);
        id = dutch.listERC20(address(want), address(quoteToken), 100e18, 10e18, 5e18, 0, 1000, 0);
    }

    function _swapOrder() internal returns (uint256 id) {
        vm.prank(holder);
        id = swap.createOrder(address(want), 100e18, address(quoteToken), 5e18, false, 0, false, false, address(0));
    }

    // ------------------------------------------------------------- FLOORBOARD

    function test_floorboardTransferFromRefusesETH() public {
        uint256 id = _floorBid();
        uint256 before = address(floor).balance;
        vm.prank(holder);
        vm.expectRevert(Floorboard.Bad.selector);
        floor.transferFrom{value: 1 ether}(holder, other, id);
        assertEq(address(floor).balance, before, "no ETH trapped");
    }

    function test_floorboardApproveRefusesETH() public {
        uint256 id = _floorBid();
        uint256 before = address(floor).balance;
        vm.prank(holder);
        vm.expectRevert(Floorboard.Bad.selector);
        floor.approve{value: 1 ether}(other, id);
        assertEq(address(floor).balance, before, "no ETH trapped");
    }

    /// The guard is a VALUE check, not a reentrancy guard - solady's safe
    /// variants route through `transferFrom` in the same frame, so a guard that
    /// nested would brick every safe transfer.
    function test_floorboardSafeTransferStillWorks() public {
        uint256 id = _floorBid();
        vm.prank(holder);
        floor.safeTransferFrom(holder, other, id);
        assertEq(floor.ownerOf(id), other, "safe transfer unaffected");
        (address bidder,,,,,,) = floor.legOf(id);
        assertEq(bidder, other, "and the bid follows its receipt");
    }

    // ------------------------------------------------------------- DUTCHBOARD

    function test_dutchboardTransferFromRefusesETH() public {
        uint256 id = _dutchListing();
        uint256 before = address(dutch).balance;
        vm.prank(holder);
        vm.expectRevert(Dutchboard.Bad.selector);
        dutch.transferFrom{value: 1 ether}(holder, other, id);
        assertEq(address(dutch).balance, before, "no ETH trapped");
    }

    function test_dutchboardApproveRefusesETH() public {
        uint256 id = _dutchListing();
        uint256 before = address(dutch).balance;
        vm.prank(holder);
        vm.expectRevert(Dutchboard.Bad.selector);
        dutch.approve{value: 1 ether}(other, id);
        assertEq(address(dutch).balance, before, "no ETH trapped");
    }

    function test_dutchboardSafeTransferStillWorks() public {
        uint256 id = _dutchListing();
        vm.prank(holder);
        dutch.safeTransferFrom(holder, other, id);
        assertEq(dutch.ownerOf(id), other, "safe transfer unaffected");
    }

    // -------------------------------------------------------------- SWAPBOARD

    /// Already hardened; kept here so all three boards are asserted together and
    /// the next board added to this family has an obvious template.
    function test_swapboardAlreadyRefusesETH() public {
        uint256 id = _swapOrder();
        vm.prank(holder);
        vm.expectRevert(Swapboard.UnexpectedETH.selector);
        swap.transferFrom{value: 1 ether}(holder, other, id);

        vm.prank(holder);
        vm.expectRevert(Swapboard.UnexpectedETH.selector);
        swap.approve{value: 1 ether}(other, id);
    }

    // ------------------------------------------------------- THE THIRD MUTATOR

    /// `approve` and `transferFrom` are overridden with an explicit value check
    /// on all three boards. `setApprovalForAll` is NOT, and does not need to be
    /// while solady's is non-payable - but that is a property of a pinned
    /// dependency rather than of this repo, and nothing here would notice it
    /// changing. Strandable ETH is not the only cost either: on Swapboard it
    /// would reopen the `multicall` value-reuse path that `_wrapETH`'s real
    /// credit check otherwise closes.
    ///
    /// So assert the behaviour rather than the source. A solady bump that makes
    /// the mutator payable fails here first.
    function test_setApprovalForAllRefusesETHOnEveryBoard() public {
        vm.deal(holder, 100 ether);
        address[3] memory boards = [address(floor), address(dutch), address(swap)];
        for (uint256 i; i < boards.length; ++i) {
            uint256 before = holder.balance;
            vm.prank(holder);
            (bool ok,) = boards[i].call{value: 1 wei}(
                abi.encodeWithSignature("setApprovalForAll(address,bool)", other, true)
            );
            assertFalse(ok, "value must not be accepted on setApprovalForAll");
            assertEq(holder.balance, before, "the caller kept their ETH");
            assertEq(boards[i].balance, 0, "no ETH trapped on the board");
        }
    }

    // ---------------------------------------------------- THE LIVE-CLAIM FLAG

    /// Every board declares `0x28a93a2e` as `LiveOrderPosition()` and every
    /// board REFUSES anything that declares it, on both legs. Both halves rest
    /// on a hand-written constant nobody can verify by eye: if the keccak were
    /// wrong the boards would advertise a garbage id and their sibling checks
    /// would silently protect nothing, while every test that only ever pairs
    /// two of these boards against each other would still pass.
    function test_liveOrderPositionIdIsRealKeccak() public view {
        bytes4 id = bytes4(keccak256("LiveOrderPosition()"));
        assertEq(id, bytes4(0x28a93a2e), "the constant is that keccak");
        assertTrue(floor.supportsInterface(id), "floorboard declares it");
        assertTrue(dutch.supportsInterface(id), "dutchboard declares it");
        assertTrue(swap.supportsInterface(id), "swapboard declares it");
    }
}
