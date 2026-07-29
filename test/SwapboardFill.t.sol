// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {SwapboardView} from "../src/SwapboardView.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// Settlement-path regressions. Every case here was a live defect.
contract SwapboardFillTest is Test {
    Swapboard board;
    SwapboardView lens;
    MockWETH weth;
    MockERC20 other;
    MockNFT nft;

    address maker = address(0xA11CE);
    address victim = address(0xBEEF);
    address taker = address(0xCAFE);

    function setUp() public {
        weth = new MockWETH();
        board = new Swapboard(address(weth));
        lens = new SwapboardView();
        other = new MockERC20("OTH", 18);
        nft = new MockNFT();
    }

    /// Parks 100 WETH of unrelated escrow in the board, so a settlement that
    /// overpays has somewhere to steal from instead of simply reverting.
    function _parkVictimEscrow() internal {
        vm.deal(victim, 100 ether);
        vm.startPrank(victim);
        weth.deposit{value: 100 ether}();
        weth.approve(address(board), type(uint256).max);
        board.createOrder(address(weth), 100 ether, address(other), 1e18, false, 0, false, false, address(0));
        vm.stopPrank();
        assertEq(weth.balanceOf(address(board)), 100 ether, "victim escrow parked");
    }

    function _listNFTForEth(uint256 price) internal returns (uint256 id) {
        nft.mint(maker, 1);
        vm.startPrank(maker);
        nft.setApprovalForAll(address(board), true);
        id = board.createOrder(address(nft), 1, address(weth), price, false, 0, true, false, address(0));
        vm.stopPrank();
    }

    /// An NFT order is all-or-nothing, so _fill rounds a short fillAmountB up to
    /// the full amountB. On the ETH path the payment already happened at
    /// msg.value, so that rounding used to settle the difference out of other
    /// makers' escrow: 1 wei bought a 10 ETH NFT and the victim funded it.
    function test_ethUnderpaymentCannotBuyNFT() public {
        _parkVictimEscrow();
        uint256 id = _listNFTForEth(10 ether);

        vm.deal(taker, 100 ether);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.ETHAmountMismatch.selector, 10 ether, 1));
        board.fillOrderWithEth{value: 1}(id, 0, address(0));

        assertEq(weth.balanceOf(address(board)), 100 ether, "victim escrow untouched");
        assertEq(nft.ownerOf(1), address(board), "NFT still escrowed");
    }

    function test_ethExactPaymentBuysNFT() public {
        _parkVictimEscrow();
        uint256 id = _listNFTForEth(10 ether);

        vm.deal(taker, 100 ether);
        vm.prank(taker);
        board.fillOrderWithEth{value: 10 ether}(id, 0, address(0));

        assertEq(nft.ownerOf(1), taker, "taker got the NFT");
        assertEq(weth.balanceOf(maker), 10 ether, "maker paid in full");
        assertEq(weth.balanceOf(address(board)), 100 ether, "paid from the taker, not the escrow");
    }

    /// Same rounding hazard without any NFT: a non-partial order is also
    /// all-or-nothing, so underpaying it must not settle in full.
    function test_ethUnderpaymentCannotFillNonPartialOrder() public {
        _parkVictimEscrow();
        vm.startPrank(maker);
        other.mint(maker, 50e18);
        other.approve(address(board), type(uint256).max);
        uint256 id = board.createOrder(address(other), 50e18, address(weth), 5 ether, false, 0, false, false, address(0));
        vm.stopPrank();

        vm.deal(taker, 100 ether);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.ETHAmountMismatch.selector, 5 ether, 1 ether));
        board.fillOrderWithEth{value: 1 ether}(id, 0, address(0));

        assertEq(weth.balanceOf(address(board)), 100 ether, "victim escrow untouched");
    }

    /// A partial-fillable fungible order is the one case where paying less than
    /// amountB is legitimate: it settles pro rata.
    function test_ethPartialFillStillWorks() public {
        vm.startPrank(maker);
        other.mint(maker, 50e18);
        other.approve(address(board), type(uint256).max);
        uint256 id = board.createOrder(address(other), 50e18, address(weth), 5 ether, true, 0, false, false, address(0));
        vm.stopPrank();

        vm.deal(taker, 100 ether);
        vm.prank(taker);
        board.fillOrderWithEth{value: 1 ether}(id, 0, address(0));

        assertEq(other.balanceOf(taker), 10e18, "pro rata: 1/5 of the ask");
        assertEq(weth.balanceOf(maker), 1 ether, "maker paid what arrived");
    }

    /// amountB is a tokenId when nftB, not a price, so the ETH path must refuse
    /// it outright — otherwise the wrapped value is stranded in the board while
    /// the 721 leg pulls the taker's NFT separately.
    function test_ethFillRefusesNftBOrder() public {
        nft.mint(taker, 7);
        vm.startPrank(maker);
        other.mint(maker, 1e18);
        other.approve(address(board), type(uint256).max);
        uint256 id = board.createOrder(address(other), 1e18, address(weth), 7, false, 0, false, true, address(0));
        vm.stopPrank();

        vm.deal(taker, 10 ether);
        vm.prank(taker);
        vm.expectRevert(Swapboard.NFTNotDivisible.selector);
        board.fillOrderWithEth{value: 7}(id, 0, address(0));
    }
}
