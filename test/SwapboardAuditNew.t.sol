// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// Regressions for the maker-as-payout-address audit finding, plus the
/// same-collection NFT carve-out that was probed and found already safe.
contract SwapboardAuditNew is Test {
    Swapboard board;
    MockWETH weth;
    MockERC20 a;
    MockERC20 b;
    MockNFT nft;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        board = new Swapboard(address(weth));
        a = new MockERC20("A", 18);
        b = new MockERC20("B", 18);
        nft = new MockNFT();
        a.mint(alice, 1e24);
        b.mint(bob, 1e24);
        vm.prank(alice);
        a.approve(address(board), type(uint256).max);
        vm.prank(bob);
        b.approve(address(board), type(uint256).max);
    }

    /// The board as maker used to be accepted. Its escrow could then never be
    /// cancelled or swept, and a fill still succeeded — burning the taker's
    /// tokenB into untracked inventory through the unmeasured payment leg.
    function test_createOrderFor_refusesBoardAsMaker() public {
        vm.prank(alice);
        vm.expectRevert(Swapboard.BadMaker.selector);
        board.createOrderFor(address(board), address(a), 1e18, address(b), 1e18, false, 0, false, false, address(0));
    }

    /// WETH as maker: an unwrapped payout there would be re-wrapped to the
    /// board and lost. `_to` already refused it as a recipient.
    function test_createOrderFor_refusesWethAsMaker() public {
        vm.prank(alice);
        vm.expectRevert(Swapboard.BadMaker.selector);
        board.createOrderFor(address(weth), address(a), 1e18, address(b), 1e18, false, 0, false, false, address(0));
    }

    function test_createOrderWithEthFor_refusesBoardAndWethAsMaker() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(Swapboard.BadMaker.selector);
        board.createOrderWithEthFor{value: 1 ether}(address(board), address(b), 1e18, false, 0, false, address(0));

        vm.prank(alice);
        vm.expectRevert(Swapboard.BadMaker.selector);
        board.createOrderWithEthFor{value: 1 ether}(address(weth), address(b), 1e18, false, 0, false, address(0));
    }

    /// The zero-address maker check must survive the refactor into _checkMaker.
    function test_createOrderFor_stillRefusesZeroMaker() public {
        vm.prank(alice);
        vm.expectRevert(Swapboard.ZeroAddress.selector);
        board.createOrderFor(address(0), address(a), 1e18, address(b), 1e18, false, 0, false, false, address(0));

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Swapboard.ZeroAddress.selector);
        board.createOrderWithEthFor{value: 1 ether}(address(0), address(b), 1e18, false, 0, false, address(0));
    }

    /// _to refuses the same two addresses on the delivery side. Kept alongside
    /// the maker cases so the symmetry is visible if either side is edited.
    function test_recipientGuardMatchesMakerGuard() public {
        vm.prank(alice);
        uint256 id = board.createOrder(address(a), 1e18, address(b), 1e18, false, 0, false, false, address(0));

        vm.prank(bob);
        vm.expectRevert(Swapboard.BadRecipient.selector);
        board.fillOrder(id, 0, 0, address(board));

        vm.prank(bob);
        vm.expectRevert(Swapboard.BadRecipient.selector);
        board.fillOrder(id, 0, 0, address(weth));
    }

    /// Ordinary sponsorship still works, and cannot debit the named maker.
    function test_createOrderFor_cannotDebitNamedMaker() public {
        uint256 aliceBefore = a.balanceOf(alice);
        b.mint(address(this), 1e18);
        b.approve(address(board), type(uint256).max);
        uint256 id = board.createOrderFor(alice, address(b), 1e18, address(a), 1e18, false, 0, false, false, address(0));

        assertEq(a.balanceOf(alice), aliceBefore);
        (address maker,,,,,,,,,,) = board.orders(id);
        assertEq(maker, alice);

        // And the named maker owns the cancellation right.
        vm.prank(alice);
        board.cancelOrder(id);
        assertEq(b.balanceOf(alice), 1e18);
    }

    /// tokenA == tokenB is refused for fungible pairs but allowed when a side
    /// is NFT-flagged. The same-tokenId degenerate case cannot double-spend the
    /// escrow: the payment leg's ownerOf preflight refuses it.
    function test_sameCollectionNftSelfSwapCannotDoubleSpend() public {
        nft.mint(alice, 7);
        vm.prank(alice);
        nft.setApprovalForAll(address(board), true);
        vm.prank(alice);
        uint256 id = board.createOrder(address(nft), 7, address(nft), 7, false, 0, true, true, address(0));
        assertEq(nft.ownerOf(7), address(board));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NFTTransferFailed.selector, address(nft), uint256(7)));
        board.fillOrder(id, 0, 0, bob);

        // Still cancellable — the escrow was never at risk.
        vm.prank(alice);
        board.cancelOrder(id);
        assertEq(nft.ownerOf(7), alice);
    }
}
