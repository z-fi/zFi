// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapbol} from "../src/forwarders/Swapbol.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

contract SwapbolVenueStub {
    receive() external payable {}
}

/// @notice Regression coverage for the selector firewall, current Swapboard ABI,
///         and live order-pair binding.
contract SwapbolAuditNewTest is Test {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    Swapboard internal board;
    Swapbol internal forwarder;
    MockERC20 internal input;
    MockERC20 internal output;
    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");

    function setUp() public {
        MockWETH implementation = new MockWETH();
        vm.etch(WETH, address(implementation).code);
        vm.deal(WETH, 0);

        board = new Swapboard(WETH);
        forwarder = new Swapbol(address(new SwapbolVenueStub()), address(board), address(new SwapbolVenueStub()));
        input = new MockERC20("INPUT", 18);
        output = new MockERC20("OUTPUT", 18);
    }

    function _order(uint256 amountA, uint256 amountB) internal returns (uint256 id) {
        output.mint(maker, amountA);
        vm.startPrank(maker);
        output.approve(address(board), amountA);
        id = board.createOrder(address(output), amountA, address(input), amountB, true, 0, false, false, address(0));
        vm.stopPrank();
    }

    function _fills(uint256 id, uint256 payIn, uint256 getOut) internal pure returns (Swapbol.Fill[] memory fills) {
        fills = new Swapbol.Fill[](1);
        fills[0] = Swapbol.Fill({orderId: id, board: address(0), payIn: payIn, getOut: getOut, isPartial: false});
    }

    function test_genericCreationCalldataIsRejectedBeforeApproval() public {
        uint256 id = _order(100e18, 200e18);
        bytes memory malicious = abi.encodeCall(
            board.createOrderFor,
            (taker, address(input), 200e18, address(output), 100e18, false, 0, false, false, address(0))
        );

        vm.expectRevert(Swapbol.BadPlan.selector);
        forwarder.fill(address(board), address(input), address(output), taker, taker, malicious);
        assertEq(input.allowance(address(forwarder), address(board)), 0, "no board allowance was planted");
        assertEq(id, 0, "fixture order exists only to make the board realistic");
    }

    function test_currentPlanUsesFiveArgumentFillAndMinimumOutput() public {
        uint256 id = _order(100e18, 200e18);
        Swapbol.Fill[] memory fills = _fills(id, 200e18, 100e18);
        fills[0].board = address(board);

        forwarder.checkpoint(address(input));
        input.mint(address(forwarder), 200e18);
        forwarder.fillPlan(address(input), address(output), taker, taker, block.timestamp + 1, fills);

        assertEq(output.balanceOf(taker), 100e18, "current Swapboard output arrived");
        assertEq(input.balanceOf(address(forwarder)), 0, "input was fully consumed");
    }

    function test_planRejectsWrongLiveOrderPairBeforeFunding() public {
        uint256 id = _order(100e18, 200e18);
        Swapbol.Fill[] memory fills = _fills(id, 200e18, 100e18);
        fills[0].board = address(board);

        vm.expectRevert(Swapbol.BadPlan.selector);
        forwarder.fillPlan(address(output), address(input), taker, taker, 0, fills);
    }

    function test_currentPlanBindsGetOutAsSlippageFloor() public {
        uint256 id = _order(100e18, 200e18);
        vm.prank(maker);
        board.replaceOrder(id, 1e18, 200e18, 0);

        Swapbol.Fill[] memory fills = _fills(id, 200e18, 100e18);
        fills[0].board = address(board);
        forwarder.checkpoint(address(input));
        input.mint(address(forwarder), 200e18);

        vm.expectRevert(abi.encodeWithSelector(Swapboard.InsufficientOutput.selector, 100e18, 1e18));
        forwarder.fillPlan(address(input), address(output), taker, taker, 0, fills);
    }

    function test_ammBlobCannotUseGenericZRouterExecutor() public {
        uint256 id = _order(100e18, 200e18);
        Swapbol.Fill[] memory fills = _fills(id, 200e18, 100e18);
        fills[0].board = address(board);

        bytes memory generic = abi.encodeWithSignature("execute(address,uint256,bytes)", address(0), 0, bytes(""));
        vm.expectRevert(Swapbol.BadPlan.selector);
        forwarder.fillPlanAndSwap(address(input), address(output), taker, taker, 0, fills, 1, generic);
    }
}
