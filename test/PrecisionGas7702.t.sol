// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import "../src/pools/PrecisionStablePool.sol";
import "../src/pools/PrecisionRangePool.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Measures the actual gas cost of a 7702-style swap:
///      direct transfer + pool.swap from the user's own context.
///      No router, no transferFrom, no intermediary.
contract PrecisionGas7702Test is Test {
    PrecisionStablePool stablePool;
    PrecisionRangePool rangePool;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USER = address(0xBEEF);

    function setUp() public {
        stablePool = new PrecisionStablePool();
        rangePool = new PrecisionRangePool();

        deal(USDC, address(stablePool), 10_000_000e6);
        deal(USDT, address(stablePool), 10_000_000e6);
        stablePool.addLiquidity(0, address(this));

        deal(USDC, address(rangePool), 250_000e6);
        vm.deal(address(rangePool), 100e18);
        rangePool.addLiquidity(0, address(this));
    }

    /// @dev 7702: user calls transfer + swap directly. Measured as two calls
    ///      from the user's context (prank simulates 7702 delegation).
    function test_gas7702_stableSwap_USDC_to_USDT() public {
        deal(USDC, USER, 10_000e6);

        vm.startPrank(USER);
        uint256 gasBefore = gasleft();
        IERC20(USDC).transfer(address(stablePool), 10_000e6);
        stablePool.swap(USDC, 0, USER);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("7702_STABLE_USDC_TO_USDT", gasUsed);
    }

    function test_gas7702_stableSwap_USDT_to_USDC() public {
        deal(USDT, USER, 10_000e6);

        vm.startPrank(USER);
        uint256 gasBefore = gasleft();
        // USDT non-standard transfer.
        (bool ok,) = USDT.call(abi.encodeWithSelector(0xa9059cbb, address(stablePool), uint256(10_000e6)));
        require(ok);
        stablePool.swap(USDT, 0, USER);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("7702_STABLE_USDT_TO_USDC", gasUsed);
    }

    function test_gas7702_rangeSwap_ETH_to_USDC() public {
        vm.deal(USER, 1e18);

        vm.startPrank(USER);
        uint256 gasBefore = gasleft();
        // Native ETH — just send value with swap call. No transfer step needed.
        rangePool.swap{value: 1e18}(address(0), 0, USER);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("7702_RANGE_ETH_TO_USDC", gasUsed);
    }

    function test_gas7702_rangeSwap_USDC_to_ETH() public {
        deal(USDC, USER, 2500e6);

        vm.startPrank(USER);
        uint256 gasBefore = gasleft();
        IERC20(USDC).transfer(address(rangePool), 2500e6);
        rangePool.swap(USDC, 0, USER);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("7702_RANGE_USDC_TO_ETH", gasUsed);
    }
}
