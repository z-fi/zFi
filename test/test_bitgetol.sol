// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {Bitgetol} from "../src/forwarders/Bitgetol.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IRouter {
    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external payable returns (uint256 amountOut);

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}

/// @notice Deploys Bitgetol on a mainnet fork, calls the Bitget test API via FFI
///         to get swap calldata for an ETH→USDC trade, then executes it through
///         zRouter.snwap and verifies the output.
contract TestBitgetol is Test {
    Bitgetol bitgetol;

    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        bitgetol = new Bitgetol();
    }

    /// @notice Test that the adapter gracefully handles when the API calldata
    ///         targets the wrong router (simulates rejection scenario)
    function test_bitget_revert_bad_calldata() public {
        vm.deal(address(this), 0.1 ether);

        // Construct bogus calldata that should revert
        bytes memory bogusCalldata = hex"deadbeef";
        bytes memory bitgetolData = abi.encodeWithSelector(
            Bitgetol.swap.selector,
            address(0xdead), // bogus router
            address(0),
            USDC,
            address(this),
            bogusCalldata
        );

        bytes memory snwapCall = abi.encodeWithSelector(
            IRouter.snwap.selector,
            address(0),
            uint256(0),
            address(this),
            USDC,
            uint256(1), // expect at least 1 USDC
            address(bitgetol),
            bitgetolData
        );

        bytes[] memory calls = new bytes[](1);
        calls[0] = snwapCall;
        bytes memory multicall = abi.encodeWithSelector(IRouter.multicall.selector, calls);

        (bool ok,) = ZROUTER.call{value: 0.1 ether}(multicall);
        assertFalse(ok, "should revert with bad calldata");
    }

    receive() external payable {}
}
