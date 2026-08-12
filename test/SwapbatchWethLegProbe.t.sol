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

    /// v1 CANNOT partially fill: `fillOrder(id, deadline)` has nowhere to put a
    /// smaller number, so a leg is taken whole or not at all. Asking for half
    /// used to be expressible only because the helper was addressing a different
    /// board's ABI. It must now be refused BEFORE any value is wrapped - a
    /// silent acceptance would approve 0.5 and have the board pull the full 1,
    /// or wrap 0.5 against an order that never settles.
    function test_partialFillAgainstV1IsRefused() public {
        board.setDelivery(10 ether);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory pays = new uint256[](1);
        uint256[] memory mins = new uint256[](1);
        address[] memory outs = new address[](1);
        (ids[0], pays[0], mins[0], outs[0]) = (0, 0.5 ether, 0, address(weth));
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(Swapbatch.PartialFillUnsupported.selector, 0, 1 ether, 0.5 ether)
        );
        batch.fillOrdersWithEth{value: 0.5 ether}(
            address(board), ids, pays, mins, outs, block.timestamp + 1, taker, false, true
        );
        assertEq(taker.balance, 100 ether, "nothing was spent");
    }
}

contract Dummy {}

/// A legacy board whose single order pays out WETH.
contract WethOutLegacyBoard {
    address public immutable weth;
    uint256 public delivery;

    // Six words, matching v1 - the board Swapbatch binds as `legacyBoard`.
    // Decoded from mainnet, not inferred; see the note on Swapbatch's
    // `ILegacyBatchOrderView.Order` for why every shape here is measured.
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

    /// @dev v1's single-order fill. The order is quoted at 1 ether, and that is
    ///      the only amount it can be taken at.
    function fillOrder(uint256, uint256) external {
        IERC20(weth).transferFrom(msg.sender, address(this), 1 ether);
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
