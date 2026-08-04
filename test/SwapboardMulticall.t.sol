// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @dev multicall composes the typed entry points into one transaction. The
/// case that matters is repricing, which no single entry point expresses, and
/// the property that matters is that nonReentrant does not block the sequence.
contract SwapboardMulticallTest is Test {
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
        A.mint(maker, 1000e18);
        B.mint(taker, 1000e6);
        vm.prank(maker);
        A.approve(address(sb), type(uint256).max);
        vm.prank(taker);
        B.approve(address(sb), type(uint256).max);
    }

    function _create(uint256 amtA, uint256 amtB) internal returns (bytes memory) {
        return abi.encodeWithSignature(
            "createOrder(address,uint256,address,uint256,bool,uint64,bool,bool,address)",
            address(A),
            amtA,
            address(B),
            amtB,
            false,
            uint64(0),
            false,
            false,
            address(0)
        );
    }

    /// Every entry point is nonReentrant and multicall delegatecalls into them
    /// in sequence. If the guard did not clear between sub-calls the second
    /// would revert with Reentrancy(), making the whole feature useless.
    function test_RepriceInOneTransaction() public {
        vm.startPrank(maker);
        uint256 id = sb.createOrder(address(A), 10e18, address(B), 20e6, false, 0, false, false, address(0));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(sb.cancelOrder, (id));
        calls[1] = _create(10e18, 15e6); // same size, lower ask
        sb.multicall(calls);
        vm.stopPrank();

        (, bool oldActive,,,,,,,,,) = sb.orders(id);
        assertFalse(oldActive, "old order closed");
        (, bool newActive,,,,,,, uint256 amtA,, uint256 amtB) = sb.orders(1);
        assertTrue(newActive, "replacement live");
        assertEq(amtA, 10e18);
        assertEq(amtB, 15e6, "repriced");
        assertEq(A.balanceOf(address(sb)), 10e18, "one escrow held, not two");
    }

    function test_MulticallIsAtomic() public {
        vm.startPrank(maker);
        uint256 id = sb.createOrder(address(A), 10e18, address(B), 20e6, false, 0, false, false, address(0));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(sb.cancelOrder, (id));
        calls[1] = _create(0, 15e6); // invalid: zero amount
        vm.expectRevert(Swapboard.ZeroAmount.selector);
        sb.multicall(calls);
        vm.stopPrank();
        (, bool active,,,,,,,,,) = sb.orders(id);
        assertTrue(active, "cancel rolled back with the failed create");
    }

    /// Forwarding one msg.value to several sub-calls would let it be spent more
    /// than once, so any value at all is refused.
    function test_MulticallRefusesValue() public {
        vm.deal(maker, 1 ether);
        bytes[] memory calls = new bytes[](0);
        vm.prank(maker);
        (bool ok,) = address(sb).call{value: 1 ether}(abi.encodeWithSignature("multicall(bytes[])", calls));
        assertFalse(ok, "non-zero msg.value refused");
    }

    function test_MulticallCannotForgeCaller() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 10e18, address(B), 20e6, false, 0, false, false, address(0));
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(sb.cancelOrder, (id));
        vm.prank(taker); // not the maker
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotMaker.selector, id, taker, maker));
        sb.multicall(calls);
    }
}
