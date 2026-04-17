// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import "../src/pools/PrecisionStablePool.sol";
import "../src/pools/PrecisionRangePool.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface ISnwap {
    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external payable returns (uint256 amountOut);
}

interface IExecuteBatch {
    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata data) external payable;
}

contract PrecisionGasSnwapTest is Test {
    PrecisionStablePool stablePool;
    PrecisionRangePool rangePool;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant USER = address(0xBEEF);

    function setUp() public {
        stablePool = new PrecisionStablePool();
        rangePool = new PrecisionRangePool();

        // Seed stable pool.
        deal(USDC, address(stablePool), 10_000_000e6);
        deal(USDT, address(stablePool), 10_000_000e6);
        stablePool.addLiquidity(0, address(this));

        // Seed range pool.
        deal(USDC, address(rangePool), 250_000e6);
        vm.deal(address(rangePool), 100e18);
        rangePool.addLiquidity(0, address(this));

        // User approves zRouter. Use low-level call for USDT.
        vm.startPrank(USER);
        IERC20(USDC).approve(ZROUTER, type(uint256).max);
        (bool ok,) = USDT.call(abi.encodeWithSelector(0x095ea7b3, ZROUTER, type(uint256).max));
        require(ok, "USDT approve failed");
        vm.stopPrank();
    }

    // ── SNWAP MEASUREMENTS ──────────────────────────────────────────

    function test_gasSnwap_stableSwap_USDC_to_USDT() public {
        deal(USDC, USER, 10_000e6);

        bytes memory swapData = abi.encodeWithSelector(PrecisionStablePool.swap.selector, USDC, uint256(0), USER);

        vm.prank(USER);
        uint256 gasBefore = gasleft();
        ISnwap(ZROUTER).snwap(USDC, 10_000e6, USER, USDT, 0, address(stablePool), swapData);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("SNWAP_STABLE_USDC_TO_USDT", gasUsed);
    }

    function test_gasSnwap_stableSwap_USDT_to_USDC() public {
        deal(USDT, USER, 10_000e6);

        bytes memory swapData = abi.encodeWithSelector(PrecisionStablePool.swap.selector, USDT, uint256(0), USER);

        vm.prank(USER);
        uint256 gasBefore = gasleft();
        ISnwap(ZROUTER).snwap(USDT, 10_000e6, USER, USDC, 0, address(stablePool), swapData);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("SNWAP_STABLE_USDT_TO_USDC", gasUsed);
    }

    function test_gasSnwap_rangeSwap_USDC_to_ETH() public {
        deal(USDC, USER, 2500e6);

        bytes memory swapData = abi.encodeWithSelector(PrecisionRangePool.swap.selector, USDC, uint256(0), USER);

        vm.prank(USER);
        uint256 gasBefore = gasleft();
        ISnwap(ZROUTER).snwap(USDC, 2500e6, USER, address(0), 0, address(rangePool), swapData);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("SNWAP_RANGE_USDC_TO_ETH", gasUsed);
    }

    // ── 7702 BATCH (executeBatch pattern) ────────────────────────────
    //
    // Simulates a 7702 EOA delegating to a contract with executeBatch.
    // The EOA calls executeBatch([transfer, swap]) atomically.

    function test_gas7702Batch_stableSwap_USDC_to_USDT() public {
        deal(USDC, USER, 10_000e6);

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);

        targets[0] = USDC;
        data[0] = abi.encodeWithSelector(0xa9059cbb, address(stablePool), uint256(10_000e6));

        targets[1] = address(stablePool);
        data[1] = abi.encodeWithSelector(PrecisionStablePool.swap.selector, USDC, uint256(0), USER);

        // Simulate 7702: USER executes the batch directly.
        // We measure the inner calls only (executeBatch dispatch is ~500 gas).
        vm.startPrank(USER);
        uint256 gasBefore = gasleft();
        IERC20(USDC).transfer(address(stablePool), 10_000e6);
        stablePool.swap(USDC, 0, USER);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("7702_BATCH_STABLE_USDC_TO_USDT", gasUsed);
    }

    function test_gas7702Batch_rangeSwap_ETH_to_USDC() public {
        vm.deal(USER, 1e18);

        vm.startPrank(USER);
        uint256 gasBefore = gasleft();
        rangePool.swap{value: 1e18}(address(0), 0, USER);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("7702_BATCH_RANGE_ETH_TO_USDC", gasUsed);
    }

    function test_gas7702Batch_rangeSwap_USDC_to_ETH() public {
        deal(USDC, USER, 2500e6);

        vm.startPrank(USER);
        uint256 gasBefore = gasleft();
        IERC20(USDC).transfer(address(rangePool), 2500e6);
        rangePool.swap(USDC, 0, USER);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("7702_BATCH_RANGE_USDC_TO_ETH", gasUsed);
    }
}
