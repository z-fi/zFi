// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH, MockERC721, FeeToken, LyingERC721} from "./SwapboardMocks.sol";

/// @dev Covers the entry points and revert paths the behavioural suite does not
/// reach: batch operations, the ETH create path, unwrap-on-cancel, and every
/// error the contract can raise.
contract SwapboardCoverageTest is Test {
    Swapboard sb;
    MockWETH weth;
    MockERC20 A;
    MockERC20 B;

    address maker = address(0xA11CE);
    address taker = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        A = new MockERC20("AAA", 18);
        B = new MockERC20("BBB", 6);
        A.mint(maker, 1_000e18);
        B.mint(taker, 1_000_000e6);
        vm.prank(maker);
        A.approve(address(sb), type(uint256).max);
        vm.prank(taker);
        B.approve(address(sb), type(uint256).max);
        vm.deal(maker, 100 ether);
        vm.deal(taker, 100 ether);
    }

    function _mk(uint256 amtA, uint256 amtB) internal returns (uint256 id) {
        vm.prank(maker);
        id = sb.createOrder(address(A), amtA, address(B), amtB, true, 0, false, false, address(0));
    }

    // ---------------------------------------------------------- constructor

    function test_ConstructorRejectsZeroWeth() public {
        vm.expectRevert(Swapboard.ZeroAddress.selector);
        new Swapboard(address(0));
    }

    function test_ConstructorRejectsEoaWeth() public {
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotAContract.selector, address(0xdead)));
        new Swapboard(address(0xdead));
    }

    // ------------------------------------------------------------- creation

    function test_CreateOrderWithEthWrapsAndEscrows() public {
        vm.prank(maker);
        uint256 id = sb.createOrderWithEth{value: 2 ether}(address(B), 4000e6, false, 0, false, address(0));
        (,,,,,,, address tokenA, uint256 amountA,,) = sb.orders(id);
        assertEq(tokenA, address(weth), "tokenA is WETH");
        assertEq(amountA, 2 ether, "msg.value became the escrow");
        assertEq(weth.balanceOf(address(sb)), 2 ether, "board holds the wrapped ETH");
    }

    function test_CreateOrderWithEthRejectsZeroValue() public {
        vm.prank(maker);
        vm.expectRevert(Swapboard.ZeroETH.selector);
        sb.createOrderWithEth{value: 0}(address(B), 1e6, false, 0, false, address(0));
    }

    function test_CreateOrderWithEthRejectsWethAsTokenB() public {
        vm.prank(maker);
        vm.expectRevert(Swapboard.SameToken.selector);
        sb.createOrderWithEth{value: 1 ether}(address(weth), 1e6, false, 0, false, address(0));
    }

    function test_CreateOrdersBatch() public {
        Swapboard.CreateOrderParams[] memory p = new Swapboard.CreateOrderParams[](2);
        p[0] = Swapboard.CreateOrderParams(address(A), 10e18, address(B), 20e6, true, 0, false, false, address(0));
        p[1] = Swapboard.CreateOrderParams(address(A), 30e18, address(B), 60e6, false, 0, false, false, taker);
        vm.prank(maker);
        uint256[] memory ids = sb.createOrders(p);
        assertEq(ids.length, 2);
        assertEq(sb.nextOrderId(), 2);
        assertEq(A.balanceOf(address(sb)), 40e18, "both escrows taken");
        (,,,,,, address cp,,,,) = sb.orders(ids[1]);
        assertEq(cp, taker, "per-order counterparty preserved through the batch");
    }

    function test_CreateOrdersIsAtomic() public {
        Swapboard.CreateOrderParams[] memory p = new Swapboard.CreateOrderParams[](2);
        p[0] = Swapboard.CreateOrderParams(address(A), 10e18, address(B), 20e6, true, 0, false, false, address(0));
        p[1] = Swapboard.CreateOrderParams(address(A), 0, address(B), 60e6, false, 0, false, false, address(0));
        vm.prank(maker);
        vm.expectRevert(Swapboard.ZeroAmount.selector);
        sb.createOrders(p);
        assertEq(sb.nextOrderId(), 0, "nothing created");
        assertEq(A.balanceOf(address(sb)), 0, "no escrow taken");
    }

    // -------------------------------------------------- creation validation

    function test_RejectsZeroTokenAddress() public {
        vm.prank(maker);
        vm.expectRevert(Swapboard.ZeroAddress.selector);
        sb.createOrder(address(0), 1e18, address(B), 1e6, false, 0, false, false, address(0));
    }

    function test_RejectsZeroAmount() public {
        vm.prank(maker);
        vm.expectRevert(Swapboard.ZeroAmount.selector);
        sb.createOrder(address(A), 0, address(B), 1e6, false, 0, false, false, address(0));
    }

    function test_RejectsSameToken() public {
        vm.prank(maker);
        vm.expectRevert(Swapboard.SameToken.selector);
        sb.createOrder(address(A), 1e18, address(A), 1e6, false, 0, false, false, address(0));
    }

    function test_RejectsEoaAsToken() public {
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotAContract.selector, address(0xbeef)));
        sb.createOrder(address(0xbeef), 1e18, address(B), 1e6, false, 0, false, false, address(0));
    }

    /// A fee-on-transfer token would leave the escrow short of what the order
    /// promises, so the shortfall is detected rather than silently accepted.
    function test_FeeOnTransferTokenIsRejected() public {
        FeeToken fee = new FeeToken();
        fee.mint(maker, 100e18);
        vm.prank(maker);
        fee.approve(address(sb), type(uint256).max);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.BalanceMismatch.selector, 100e18, 99e18));
        sb.createOrder(address(fee), 100e18, address(B), 1e6, false, 0, false, false, address(0));
    }

    /// An ERC-721 that no-ops transferFrom would leave an order backed by
    /// nothing; ownerOf is checked afterwards rather than trusting the call.
    function test_LyingNftEscrowIsCaught() public {
        LyingERC721 bad = new LyingERC721();
        bad.mint(maker, 3);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NFTTransferFailed.selector, address(bad), 3));
        sb.createOrder(address(bad), 3, address(B), 1e6, false, 0, true, false, address(0));
    }

    // ------------------------------------------------------------- batching

    function test_FillOrdersBatch() public {
        uint256 a = _mk(10e18, 20e6);
        uint256 b = _mk(30e18, 60e6);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        uint256[] memory amts = new uint256[](2);
        vm.prank(taker);
        sb.fillOrders(ids, 0, amts, address(0));
        assertEq(A.balanceOf(taker), 40e18, "both filled");
    }

    function test_FillOrdersIsAtomic() public {
        uint256 a = _mk(10e18, 20e6);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = 999; // does not exist
        uint256[] memory amts = new uint256[](2);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderNotFound.selector, 999));
        sb.fillOrders(ids, 0, amts, address(0));
        assertEq(A.balanceOf(taker), 0, "first fill rolled back too");
    }

    function test_FillOrdersRejectsMismatchedLengths() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amts = new uint256[](1);
        vm.prank(taker);
        vm.expectRevert(Swapboard.LengthMismatch.selector);
        sb.fillOrders(ids, 0, amts, address(0));
    }

    function test_TryFillOrdersRejectsMismatchedLengths() public {
        uint256[] memory ids = new uint256[](3);
        uint256[] memory amts = new uint256[](2);
        vm.prank(taker);
        vm.expectRevert(Swapboard.LengthMismatch.selector);
        sb.tryFillOrders(ids, 0, amts, address(0));
    }

    function test_CancelOrdersBatch() public {
        uint256 a = _mk(10e18, 20e6);
        uint256 b = _mk(30e18, 60e6);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        uint256 before = A.balanceOf(maker);
        vm.prank(maker);
        sb.cancelOrders(ids);
        assertEq(A.balanceOf(maker) - before, 40e18, "both escrows returned");
    }

    function test_CancelOrdersIsAtomic() public {
        uint256 a = _mk(10e18, 20e6);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = a; // second pass sees it already inactive
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderNotActive.selector, a));
        sb.cancelOrders(ids);
        (, bool active,,,,,,,,,) = sb.orders(a);
        assertTrue(active, "rolled back, still live");
    }

    // -------------------------------------------------------------- unwrap

    function test_CancelOrderUnwrapReturnsEth() public {
        vm.prank(maker);
        uint256 id = sb.createOrderWithEth{value: 3 ether}(address(B), 6000e6, false, 0, false, address(0));
        uint256 before = maker.balance;
        vm.prank(maker);
        sb.cancelOrderUnwrap(id);
        assertEq(maker.balance - before, 3 ether, "escrow came back as ETH");
    }

    function test_CancelUnwrapRejectsNonWethOrder() public {
        uint256 id = _mk(10e18, 20e6); // tokenA is AAA, not WETH
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotWETH.selector, address(weth), address(A)));
        sb.cancelOrderUnwrap(id);
    }

    function test_FillUnwrapRejectsNonWethOrder() public {
        uint256 id = _mk(10e18, 20e6);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotWETH.selector, address(weth), address(A)));
        sb.fillOrderUnwrap(id, 0, 0, address(0));
    }

    function test_FillWithEthRejectsNonWethTokenB() public {
        uint256 id = _mk(10e18, 20e6); // tokenB is BBB, not WETH
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotWETH.selector, address(weth), address(B)));
        sb.fillOrderWithEth{value: 1 ether}(id, 0, address(0));
    }

    function test_FillWithEthRejectsZeroValue() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 10e18, address(weth), 1 ether, false, 0, false, false, address(0));
        vm.prank(taker);
        vm.expectRevert(Swapboard.ZeroETH.selector);
        sb.fillOrderWithEth{value: 0}(id, 0, address(0));
    }

    // --------------------------------------------------------- fill guards

    function test_FillRejectsUnknownOrder() public {
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderNotFound.selector, 42));
        sb.fillOrder(42, 0, 0, address(0));
    }

    function test_FillRejectsSettledOrder() public {
        uint256 id = _mk(10e18, 20e6);
        vm.prank(maker);
        sb.cancelOrder(id);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderNotActive.selector, id));
        sb.fillOrder(id, 0, 0, address(0));
    }

    function test_CancelRejectsUnknownOrder() public {
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderNotFound.selector, 7));
        sb.cancelOrder(7);
    }

    // ----------------------------------------------------------- view reads

    function test_GetOrdersReturnsZeroedEntriesForUnknownIds() public {
        uint256 id = _mk(10e18, 20e6);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = 12345;
        Swapboard.Order[] memory o = sb.getOrders(ids);
        assertEq(o[0].maker, maker, "known id populated");
        assertEq(o[1].maker, address(0), "unknown id zeroed, not reverted");
        assertFalse(o[1].active);
    }

    function test_IsFillableByOnUnknownOrder() public view {
        assertFalse(sb.isFillableBy(999, address(this)));
    }

    function test_DirectSafeNftTransfersAreRejected() public {
        vm.expectRevert(Swapboard.DirectNFTTransfer.selector);
        sb.onERC721Received(address(0), address(0), 0, "");
    }

    // ------------------------------------------------------------- receive

    function test_OnlyWethMaySendEthDirectly() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(sb).call{value: 1 ether}("");
        assertFalse(ok, "arbitrary ETH is refused");
    }
}
