// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @dev Orders are ERC-721 positions. The immediate value is a receipt: a
/// wallet simulating an order now shows an asset arriving, which is what makes
/// a bare NFT push safe to sign. The second-order value is that a position is
/// an asset, so it composes with everything that takes assets.
contract SwapboardPositionTest is Test {
    Swapboard sb;
    Dutchboard dutch;
    MockWETH weth;
    MockERC20 tka;
    MockERC20 tkb;

    address maker = address(0xACE);
    address buyer = address(0xB0B);
    address taker = address(0x7AD);

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        dutch = new Dutchboard(address(weth));
        tka = new MockERC20("A", 18);
        tkb = new MockERC20("B", 18);

        tka.mint(maker, 1_000e18);
        tkb.mint(taker, 1_000e18);

        vm.prank(maker);
        tka.approve(address(sb), type(uint256).max);
        vm.prank(taker);
        tkb.approve(address(sb), type(uint256).max);
    }

    function _order(bool allowPartial) internal returns (uint256 id) {
        vm.prank(maker);
        id = sb.createOrder(address(tka), 100e18, address(tkb), 200e18, allowPartial, 0, false, false, address(0));
    }

    // ------------------------------------------------------------ the receipt

    function test_CreatingAnOrderMintsAPositionToTheMaker() public {
        uint256 id = _order(true);
        assertEq(sb.ownerOf(id), maker, "maker holds the position");
        assertEq(sb.balanceOf(maker), 1, "and it is visible as a balance");
        assertEq(sb.name(), "Swapboard Position");
    }

    // ------------------------------------------------ ownership is makership

    /// @dev The property everything else rests on: moving the position moves
    /// the claim, with no change to settlement logic.
    function test_TransferringThePositionTransfersTheClaim() public {
        uint256 id = _order(true);

        vm.prank(maker);
        sb.transferFrom(maker, buyer, id);

        (address m,,,,,,,,,,) = sb.orders(id);
        assertEq(m, buyer, "stored maker followed the position");

        // The new owner can cancel and receives the escrow.
        vm.prank(buyer);
        sb.cancelOrder(id);
        assertEq(tka.balanceOf(buyer), 100e18, "escrow paid to the new owner");
        assertEq(tka.balanceOf(maker), 900e18, "original maker got nothing back");
    }

    function test_OldOwnerLosesAuthorityAfterTransfer() public {
        uint256 id = _order(true);
        vm.prank(maker);
        sb.transferFrom(maker, buyer, id);

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotMaker.selector, id, maker, buyer));
        sb.cancelOrder(id);
    }

    /// @dev A position sent somewhere it could never be paid out is refused,
    /// the same rule ordinary makers are held to.
    function test_PositionCannotBeTransferredToAnUnpayableAddress() public {
        uint256 id = _order(true);
        vm.prank(maker);
        vm.expectRevert(Swapboard.BadMaker.selector);
        sb.transferFrom(maker, address(sb), id);

        vm.prank(maker);
        vm.expectRevert(Swapboard.BadMaker.selector);
        sb.transferFrom(maker, address(weth), id);
    }

    // ------------------------------------------------------- lifecycle burns

    /// @dev A partial fill leaves the order live, so the receipt survives and
    /// its claim simply shrinks.
    function test_PartialFillLeavesThePositionAlive() public {
        uint256 id = _order(true);

        vm.prank(taker);
        sb.fillOrder(id, block.timestamp, 100e18, 0, taker);

        assertEq(sb.ownerOf(id), maker, "position still exists");
        (,,,,,,,, uint256 remaining,,) = sb.orders(id);
        assertEq(remaining, 50e18, "and its claim shrank");
    }

    function test_ClosingFillBurnsThePosition() public {
        uint256 id = _order(true);

        vm.prank(taker);
        sb.fillOrder(id, block.timestamp, 200e18, 0, taker);

        vm.expectRevert();
        sb.ownerOf(id);
        assertEq(sb.balanceOf(maker), 0, "receipt gone once the order closed");
    }

    function test_CancelBurnsThePosition() public {
        uint256 id = _order(true);
        vm.prank(maker);
        sb.cancelOrder(id);

        vm.expectRevert();
        sb.ownerOf(id);
    }

    // ------------------------------------------------------- composability

    /// @dev The payoff: a resting order is now an asset, so it can be
    /// auctioned. Dutchboard takes it through the same push path any NFT uses.
    function test_APositionCanBeAuctionedOnDutchboard() public {
        uint256 id = _order(true);

        vm.prank(maker);
        sb.safeTransferFrom(
            maker,
            address(dutch),
            id,
            abi.encode(Dutchboard.PushTerms(address(tkb), 300e18, 100e18, uint40(0), uint40(1 days)))
        );

        assertEq(sb.ownerOf(id), address(dutch), "the auction now holds the position");
        (address m,,,,,,,,,,) = sb.orders(id);
        assertEq(m, address(dutch), "and therefore the claim");
    }
}
