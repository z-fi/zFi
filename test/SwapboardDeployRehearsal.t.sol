// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";

/// Deployment rehearsal against the real mainnet address set, on the pinned
/// fork. Every other Swapboard suite runs on MockWETH and hand-written ERC-20s,
/// so nothing had exercised the contract against the wrapper it will actually be
/// constructed with - and `weth` is a deployment trust root whose exact deposit,
/// withdraw and transfer deltas the settlement code now asserts on.
///
/// The sharpest thing here is the unwrap path. WETH9 pays out with `.transfer`,
/// which forwards a 2300 gas stipend, and Swapboard's `receive()` has to do a
/// comparison and return inside it. A mock that uses `.call` would hide a
/// permanently bricked fillOrderUnwrap / cancelOrderUnwrap behind a green suite.
contract SwapboardDeployRehearsalTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    Swapboard sb;
    address maker = address(0xA11CE);
    address taker = address(0xB0B);
    address keeper = address(0xCAFE);

    function setUp() public {
        sb = new Swapboard(WETH);
        deal(USDC, taker, 1_000_000e6);
        deal(USDC, maker, 1_000_000e6);
        deal(DAI, maker, 1_000_000e18);
        vm.prank(taker);
        IERC20(USDC).approve(address(sb), type(uint256).max);
        vm.prank(maker);
        IERC20(USDC).approve(address(sb), type(uint256).max);
        vm.prank(maker);
        IERC20(DAI).approve(address(sb), type(uint256).max);
        vm.deal(maker, 100 ether);
        vm.deal(taker, 100 ether);
        // The address Forge derives for the board already holds ~0.000577 ETH on
        // the pinned fork. Harmless to the contract - every ETH check below is a
        // delta - but it would make the absolute assertions measure mainnet.
        // test_ForcedEthDoesNotCorruptUnwrapAccounting covers it deliberately.
        vm.deal(address(sb), 0);
    }

    function test_ConstructsAgainstCanonicalWeth() public view {
        assertEq(sb.weth(), WETH, "trust root is canonical WETH");
        assertGt(WETH.code.length, 0);
    }

    // ------------------------------------------------------------ ETH in

    /// createOrderWithEth wraps through the real WETH9 and the exact-mint delta
    /// check has to agree with it.
    function test_CreateOrderWithRealEthWrapsExactly() public {
        vm.prank(maker);
        uint256 id = sb.createOrderWithEth{value: 3 ether}(USDC, 9000e6, false, 0, false, address(0));

        assertEq(IERC20(WETH).balanceOf(address(sb)), 3 ether, "board holds real WETH");
        (,,,,,,, address tokenA, uint256 amountA,,) = sb.orders(id);
        assertEq(tokenA, WETH);
        assertEq(amountA, 3 ether);
    }

    /// The full round trip a user actually performs: list ETH, someone pays USDC.
    function test_EthForUsdcRoundTrip() public {
        vm.prank(maker);
        uint256 id = sb.createOrderWithEth{value: 2 ether}(USDC, 6000e6, false, 0, false, address(0));

        uint256 takerUsdc = IERC20(USDC).balanceOf(taker);
        vm.prank(taker);
        sb.fillOrder(id, 0, 6000e6, 0, address(0));

        assertEq(IERC20(WETH).balanceOf(taker), 2 ether, "taker paid in real WETH");
        assertEq(takerUsdc - IERC20(USDC).balanceOf(taker), 6000e6, "charged the ask exactly");
        assertEq(IERC20(USDC).balanceOf(maker) - 1_000_000e6, 6000e6, "maker paid in real USDC");
        assertEq(IERC20(WETH).balanceOf(address(sb)), 0, "no escrow retained");
    }

    // ---------------------------------------------------- unwrap (the stipend)

    /// WETH9.withdraw forwards 2300 gas to receive(). If the guard there did not
    /// fit, this path would be permanently bricked on mainnet while every mock
    /// suite stayed green.
    function test_FillUnwrapDeliversRealEthUnderTheStipend() public {
        vm.prank(maker);
        uint256 id = sb.createOrderWithEth{value: 5 ether}(USDC, 15_000e6, false, 0, false, address(0));

        uint256 before = taker.balance;
        vm.prank(taker);
        sb.fillOrderUnwrap(id, 0, 15_000e6, 0, address(0));

        assertEq(taker.balance - before, 5 ether, "taker received real ETH");
        assertEq(address(sb).balance, 0, "board retains no ETH");
        assertEq(IERC20(WETH).balanceOf(address(sb)), 0, "and no WETH");
    }

    function test_CancelUnwrapReturnsRealEthUnderTheStipend() public {
        vm.prank(maker);
        uint256 id = sb.createOrderWithEth{value: 4 ether}(USDC, 12_000e6, false, 0, false, address(0));

        uint256 before = maker.balance;
        vm.prank(maker);
        sb.cancelOrderUnwrap(id);

        assertEq(maker.balance - before, 4 ether, "escrow came back as real ETH");
        assertEq(address(sb).balance, 0);
    }

    /// A partial unwrap exercises _unwrapETH on a value the order did not wrap in
    /// one piece, with the remainder still resting as WETH escrow.
    function test_PartialFillUnwrapLeavesTheRemainderIntact() public {
        vm.prank(maker);
        uint256 id = sb.createOrderWithEth{value: 10 ether}(USDC, 30_000e6, true, 0, false, address(0));

        uint256 before = taker.balance;
        vm.prank(taker);
        sb.fillOrderUnwrap(id, 0, 9000e6, 0, address(0)); // 30% of the ask

        assertEq(taker.balance - before, 3 ether, "pro rata, unwrapped");
        assertEq(IERC20(WETH).balanceOf(address(sb)), 7 ether, "remainder still escrowed as WETH");
        assertEq(address(sb).balance, 0, "nothing stranded mid-unwrap");
    }

    // ---------------------------------------------------------------- ETH out

    /// fillOrderWithEth wraps the taker's ETH and hands it on as WETH under the
    /// prepaid exact-transfer check, with unrelated WETH escrow parked alongside.
    function test_FillWithRealEthDoesNotTouchOtherEscrow() public {
        // unrelated maker parks 20 WETH of escrow
        vm.startPrank(maker);
        uint256 parked = sb.createOrderWithEth{value: 20 ether}(DAI, 50_000e18, false, 0, false, address(0));
        uint256 id = sb.createOrder(USDC, 50_000e6, WETH, 6 ether, false, 0, false, false, address(0));
        vm.stopPrank();

        uint256 boardWeth = IERC20(WETH).balanceOf(address(sb));
        assertEq(boardWeth, 20 ether + 0, "parked escrow present");

        vm.prank(taker);
        sb.fillOrderWithEth{value: 6 ether}(id, 0, 0, address(0));

        assertEq(IERC20(USDC).balanceOf(taker) - 1_000_000e6, 50_000e6, "taker got the USDC");
        assertEq(IERC20(WETH).balanceOf(maker), 6 ether, "maker paid from the taker's ETH");
        assertEq(IERC20(WETH).balanceOf(address(sb)), 20 ether, "parked escrow untouched");

        // and the parked order is still fully backed afterwards
        vm.prank(maker);
        sb.cancelOrderUnwrap(parked);
        assertEq(IERC20(WETH).balanceOf(address(sb)), 0, "parked escrow redeemed in full");
    }

    /// The board's deployment address can already hold ETH - the one this suite
    /// lands on does - and ETH can be forced in at any time. Neither can be
    /// refused or rescued, so what matters is that it does not corrupt the
    /// unwrap accounting, which measures a delta rather than a balance.
    function test_ForcedEthDoesNotCorruptUnwrapAccounting() public {
        vm.prank(maker);
        uint256 id = sb.createOrderWithEth{value: 4 ether}(USDC, 12_000e6, false, 0, false, address(0));

        vm.deal(address(sb), address(sb).balance + 1.5 ether); // forced in

        uint256 before = maker.balance;
        vm.prank(maker);
        sb.cancelOrderUnwrap(id);

        assertEq(maker.balance - before, 4 ether, "redeemed exactly the escrow, not the windfall");
        assertEq(address(sb).balance, 1.5 ether, "stuck ETH stays stuck, and stays out of the books");
    }

    // -------------------------------------------------------- real ERC-20 legs

    /// USDC is a proxy with a blocklist and 6 decimals - a better exercise of the
    /// exact debit/credit checks than any mock.
    function test_RealUsdcEscrowSettlesExactly() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(USDC, 25_000e6, DAI, 25_000e18, true, 0, false, false, address(0));
        assertEq(IERC20(USDC).balanceOf(address(sb)), 25_000e6, "escrowed exactly");

        deal(DAI, taker, 100_000e18);
        vm.prank(taker);
        IERC20(DAI).approve(address(sb), type(uint256).max);

        vm.prank(taker);
        sb.fillOrder(id, 0, 10_000e18, 0, address(0)); // 40%

        assertEq(IERC20(USDC).balanceOf(taker) - 1_000_000e6, 10_000e6, "pro rata out");
        assertEq(IERC20(USDC).balanceOf(address(sb)), 15_000e6, "remainder still escrowed");

        vm.prank(maker);
        sb.cancelOrder(id);
        assertEq(IERC20(USDC).balanceOf(address(sb)), 0, "cancel returned the rest");
    }

    /// The permissionless sweep, on real tokens, by someone who is not the maker.
    function test_RealTokenSweepReturnsToMaker() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(DAI, 1000e18, USDC, 1000e6, false, uint64(block.timestamp + 1 days), false, false, address(0));
        vm.warp(block.timestamp + 2 days);

        uint256 before = IERC20(DAI).balanceOf(maker);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeper);
        sb.trySweepExpired(ids);

        assertEq(IERC20(DAI).balanceOf(maker) - before, 1000e18, "escrow home");
        assertEq(IERC20(DAI).balanceOf(keeper), 0, "keeper took nothing");
    }

    /// Direct safeTransferFrom deposits are refused; confirm the selector a real
    /// collection would call actually reverts rather than silently accepting.
    function test_DirectNftDepositIsRefused() public {
        vm.expectRevert(Swapboard.DirectNFTTransfer.selector);
        sb.onERC721Received(address(0), maker, 1, "");
    }
}

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
