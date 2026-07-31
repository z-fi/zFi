// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @notice Probes whether Solady's `payable` multicall lets `msg.value` be reused across
///         delegatecalls into `fillOrderWithEth`.
///
///         Swapboard inherits Multicallable, whose `multicall` is `payable`, and each
///         delegatecall observes the SAME `msg.value`. `fillOrderWithEth` treats
///         `msg.value` as the amount paid and wraps it via `_wrapETH`, which spends the
///         CONTRACT's ETH balance rather than anything bound to this caller.
///
///         The answer is that it does NOT compose: Solady's `multicall` reverts outright
///         on a non-zero `msg.value`, citing the Paradigm double-spend note, so the
///         reuse never begins. These tests pin that guard, because the day someone
///         overrides `multicall` to accept value — which is the documented way to make
///         ETH batching work — the guard disappears and the reuse becomes real.
///
///         That is precisely why batching ETH fills belongs in a dedicated function with
///         explicit per-leg value accounting (see `fillOrdersWithEth`) rather than in an
///         overridden `multicall`.
contract SwapboardMulticallValueTest is Test {
    Swapboard sb;
    MockWETH weth;
    MockERC20 A;

    address maker1 = makeAddr("maker1");
    address maker2 = makeAddr("maker2");
    address attacker = makeAddr("attacker");
    address donor = makeAddr("donor");

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        A = new MockERC20("AAA", 18);
        // The fork's CREATE address carries real mainnet dust; normalise so these
        // tests measure only the ETH they place deliberately.
        vm.deal(address(sb), 0);
    }

    /// @dev Swapboard's `receive()` is gated to WETH, so ETH cannot be donated. It can
    ///      still arrive without consent: `selfdestruct` bypasses `receive()` entirely,
    ///      and a counterfactual deployment address may already hold a balance — the
    ///      mainnet fork address for this contract holds 1 wei today. `vm.deal` models
    ///      that arrival, which is the only way stray ETH gets here.
    function _forceFeed(uint256 amount) internal {
        vm.deal(address(sb), amount);
    }

    /// Maker escrows tokenA and asks for WETH.
    function _makeOrder(address maker, uint256 amountA, uint256 amountB) internal returns (uint256 id) {
        A.mint(maker, amountA);
        vm.startPrank(maker);
        A.approve(address(sb), amountA);
        id = sb.createOrder(address(A), amountA, address(weth), amountB, false, 0, false, false, address(0));
        vm.stopPrank();
    }

    /// The guard itself: any value at all is refused, before a single leg runs.
    function test_multicallRefusesValueOutright() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether);
        uint256 id2 = _makeOrder(maker2, 100e18, 1 ether);
        assertEq(address(sb).balance, 0, "board should start empty");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Swapboard.fillOrderWithEth, (id1, type(uint256).max, 0, attacker));
        calls[1] = abi.encodeCall(Swapboard.fillOrderWithEth, (id2, type(uint256).max, 0, attacker));

        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(); // Multicallable: `if (msg.value != 0) revert()`
        sb.multicall{value: 1 ether}(calls);

        // Nothing settled, and the caller kept their ETH.
        assertEq(A.balanceOf(attacker), 0, "no lot delivered");
        assertEq(attacker.balance, 1 ether, "value untouched");
    }

    /// Value-free multicall still works, so batching the ERC20 path is unaffected.
    function test_multicallWithoutValueStillBatches() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether);
        uint256 id2 = _makeOrder(maker2, 100e18, 1 ether);

        weth.mint(attacker, 2 ether);
        vm.startPrank(attacker);
        weth.approve(address(sb), 2 ether);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Swapboard.fillOrder, (id1, type(uint256).max, 1 ether, 0, attacker));
        calls[1] = abi.encodeCall(Swapboard.fillOrder, (id2, type(uint256).max, 1 ether, 0, attacker));
        sb.multicall(calls);
        vm.stopPrank();

        assertEq(A.balanceOf(attacker), 200e18, "both lots delivered");
        assertEq(weth.balanceOf(attacker), 0, "paid for both");
    }

    /// Even with stray ETH resting in the board — which is what would have underwritten
    /// a reuse — the guard fires first. Worth pinning both halves: the board CAN hold
    /// unbound ETH, and the only reason that is harmless is the value check.
    function test_guardHoldsEvenWithRestingEth() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether);
        uint256 id2 = _makeOrder(maker2, 100e18, 1 ether);

        // Voluntary donation is refused — receive() is gated to WETH.
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        (bool ok,) = address(sb).call{value: 1 ether}("");
        assertFalse(ok, "gated receive() should refuse a donation");

        // Force-fed ETH still lands: selfdestruct bypasses receive(), and a
        // counterfactual address can be pre-funded. Nothing binds it to a caller.
        _forceFeed(1 ether);
        assertEq(address(sb).balance, 1 ether, "stray ETH resting");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Swapboard.fillOrderWithEth, (id1, type(uint256).max, 0, attacker));
        calls[1] = abi.encodeCall(Swapboard.fillOrderWithEth, (id2, type(uint256).max, 0, attacker));

        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        sb.multicall{value: 1 ether}(calls);

        assertEq(A.balanceOf(attacker), 0, "nothing settled");
        assertEq(address(sb).balance, 1 ether, "resting ETH untouched");
    }

    /// A single ETH fill is unaffected — it is only the batching that is refused.
    function test_singleEthFillStillWorks() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether);
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        sb.fillOrderWithEth{value: 1 ether}(id1, type(uint256).max, 0, attacker);
        assertEq(A.balanceOf(attacker), 100e18, "lot delivered");
        assertEq(weth.balanceOf(maker1), 1 ether, "maker paid");
    }
}
