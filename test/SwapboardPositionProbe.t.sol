// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @dev A live position must never become escrow. Dutchboard already refused
/// one as a lot; these cover the symmetric hole on Swapboard, where tokenA is
/// escrowed between creation and settlement.
contract SwapboardPositionProbe is Test {
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
        tkb.mint(buyer, 1_000e18);

        vm.prank(maker);
        tka.approve(address(sb), type(uint256).max);
        vm.prank(taker);
        tkb.approve(address(sb), type(uint256).max);
        vm.prank(buyer);
        tkb.approve(address(dutch), type(uint256).max);
    }

    function _order() internal returns (uint256 id) {
        vm.prank(maker);
        id = sb.createOrder(address(tka), 100e18, address(tkb), 200e18, true, 0, false, false, address(0));
    }

    function _dutchLot() internal returns (uint256 lot) {
        vm.startPrank(maker);
        tka.approve(address(dutch), type(uint256).max);
        lot = dutch.listERC20(address(tka), address(tkb), 10e18, 100e18, 50e18, 0, uint40(1 days), 0);
        vm.stopPrank();
    }

    /// A Dutchboard lot receipt cannot be escrowed as Swapboard's tokenA. Were
    /// it allowed, anyone could fill the lot while it sat in escrow: proceeds
    /// would land on a board with no accounting for them and the receipt would
    /// burn, leaving an order backed by a token that no longer exists.
    function test_DutchPositionCannotBeEscrowedByApproval() public {
        uint256 lot = _dutchLot();
        vm.startPrank(maker);
        dutch.approve(address(sb), lot);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.LiveClaimNotEscrowable.selector, address(dutch)));
        sb.createOrder(address(dutch), lot, address(tkb), 200e18, false, 0, true, false, address(0));
        vm.stopPrank();

        assertEq(dutch.ownerOf(lot), maker, "lot receipt never left the seller");
    }

    /// The push path is the same escrow, so it is refused the same way.
    function test_DutchPositionCannotBeEscrowedByPush() public {
        uint256 lot = _dutchLot();
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.LiveClaimNotEscrowable.selector, address(dutch)));
        dutch.safeTransferFrom(
            maker, address(sb), lot, abi.encode(keccak256("Swapboard.PushOrder.v1"), Swapboard.PushOrder(address(tkb), 200e18, uint64(0), false, address(0)))
        );
    }

    /// Swapboard's own receipt is refused too, and now with the reason rather
    /// than the incidental BadMaker it used to hit inside the transfer hook.
    function test_OwnPositionCannotBeEscrowed() public {
        uint256 id = _order();
        vm.startPrank(maker);
        sb.approve(address(sb), id);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.LiveClaimNotEscrowable.selector, address(sb)));
        sb.createOrder(address(sb), id, address(tkb), 5e18, false, 0, true, false, address(0));
        vm.stopPrank();
    }

    /// The guard is not a blanket refusal: ordinary assets still escrow, and a
    /// token that does not answer ERC-165 at all reads as inert.
    function test_OrdinaryAssetsStillEscrow() public {
        uint256 id = _order();
        vm.prank(taker);
        sb.fillOrder(id, 0, 200e18, 0, taker);
        assertEq(tka.balanceOf(taker), 100e18, "escrow settled normally");
        assertEq(tkb.balanceOf(maker), 200e18, "maker paid");
    }

    /// A live claim is no longer acceptable as PAYMENT either. tokenB is never
    /// escrowed, which is why this was once allowed, but settlement can only
    /// check that the id moved - not what claim was left inside it. The seller
    /// empties the position in the same transaction and hands over a spent
    /// ticket for real escrow, so the trade is refused at creation.
    function test_PositionIsRefusedAsPayment() public {
        uint256 lot = _dutchLot();
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.LiveClaimNotEscrowable.selector, address(dutch)));
        sb.createOrder(address(tka), 1e18, address(dutch), lot, false, 0, false, true, address(0));
    }

    /// Same refusal on the ETH creation path.
    function test_PositionIsRefusedAsPaymentForEth() public {
        uint256 lot = _dutchLot();
        vm.deal(maker, 1 ether);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.LiveClaimNotEscrowable.selector, address(dutch)));
        sb.createOrderWithEth{value: 1 ether}(address(dutch), lot, false, 0, true, address(0));
    }

    /// And on the pushed-NFT path, where tokenB is caller-supplied data.
    function test_PositionIsRefusedAsPaymentOnPush() public {
        ProbeNFT art = new ProbeNFT();
        art.mint(maker, 7);
        uint256 lot = _dutchLot();
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.LiveClaimNotEscrowable.selector, address(dutch)));
        art.safeTransferFrom(
            maker, address(sb), 7, abi.encode(keccak256("Swapboard.PushOrder.v1"), Swapboard.PushOrder(address(dutch), lot, uint64(0), true, address(0)))
        );
    }

    /// The exploit the refusal exists for, run against the refusal: an order
    /// asking for a position cannot even be created, so there is nothing to
    /// settle a cancelled position against.
    function test_SpentPositionCannotBuyEscrow() public {
        uint256 lot = _dutchLot();
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.LiveClaimNotEscrowable.selector, address(dutch)));
        sb.createOrder(address(tka), 100e18, address(dutch), lot, false, 0, false, true, address(0));

        // The seller can still empty the claim at will - which is exactly why
        // no order was allowed to price it.
        vm.prank(maker);
        dutch.cancel(lot);
        assertEq(dutch.ownerOf(lot), maker, "spent ticket survives, worth nothing");
    }
}

contract ProbeNFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address, address to, uint256 id) public {
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data) external {
        transferFrom(from, to, id);
        require(
            IERC721Receiver(to).onERC721Received(msg.sender, from, id, data)
                == IERC721Receiver.onERC721Received.selector,
            "bad receiver"
        );
    }
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}
