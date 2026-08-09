// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapbatch} from "../src/forwarders/Swapbatch.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @notice The one legacy shape `Swapbatch.t.sol` never builds: an order whose
///         tokenA IS WETH. Its `LegacyBoard` mock only ever quotes tokenA as one
///         of two plain ERC-20s, so `_deliverLegacy`'s WETH branch and the
///         `purchasedWeth` accumulator that feeds it are reached by no test.
///
///         A WETH-for-WETH order is degenerate but constructible, and the helper
///         has explicit code for it, so that code should work or not exist.
contract SwapbatchWethLegProbeTest is Test {
    MockWETH weth;
    Swapbatch batch;
    WethOutLegacyBoard board;

    address taker = makeAddr("taker");

    function setUp() public {
        weth = new MockWETH();
        board = new WethOutLegacyBoard(address(weth));
        // `modernBoard` only has to be a distinct contract with code here; this
        // probe never routes to it.
        batch = new Swapbatch(address(weth), address(board), address(new Dummy()));
        vm.deal(address(board), 500 ether);
        vm.prank(address(board));
        weth.deposit{value: 400 ether}();
        vm.deal(taker, 100 ether);
    }

    function _call(uint256 pay, uint256 deliver) internal {
        board.setDelivery(deliver);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory pays = new uint256[](1);
        uint256[] memory mins = new uint256[](1);
        address[] memory outs = new address[](1);
        (ids[0], pays[0], mins[0], outs[0]) = (0, pay, 0, address(weth));
        vm.prank(taker);
        batch.fillOrdersWithEth{value: pay}(
            address(board), ids, pays, mins, outs, block.timestamp + 1, taker, false, true
        );
    }

    /// The order is quoted at amountA = 10 WETH out for amountB = 1 ETH in, and
    /// the board delivers exactly that. Nothing is partial, nothing is skipped.
    function test_fullyFilledWethOutputLeg() public {
        uint256 before = weth.balanceOf(taker);
        _call(1 ether, 10 ether);
        assertEq(weth.balanceOf(taker) - before, 10 ether, "taker receives the WETH it bought");
    }

    /// Half paid, half delivered - the ordinary partial fill the legacy board's
    /// per-order `fillAmountsB` exists to express.
    function test_partiallyFilledWethOutputLeg() public {
        uint256 before = weth.balanceOf(taker);
        _call(0.5 ether, 5 ether);
        assertEq(weth.balanceOf(taker) - before, 5 ether, "taker receives the WETH it bought");
    }
}

contract Dummy {}

/// A legacy board whose single order pays out WETH.
contract WethOutLegacyBoard {
    address public immutable weth;
    uint256 public delivery;

    struct Order {
        address maker;
        bool active;
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
    }

    constructor(address _weth) {
        weth = _weth;
    }

    function setDelivery(uint256 amount) external {
        delivery = amount;
    }

    function fillOrders(uint256[] calldata, uint256, uint256[] calldata fillAmountsB) external {
        uint256 paid;
        for (uint256 i; i < fillAmountsB.length; ++i) paid += fillAmountsB[i];
        IERC20(weth).transferFrom(msg.sender, address(this), paid);
        IERC20(weth).transfer(msg.sender, delivery);
    }

    function getOrders(uint256[] calldata orderIds) external view returns (Order[] memory out) {
        out = new Order[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            out[i] = Order(address(1), true, weth, 10 ether, weth, 1 ether);
        }
    }
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}
