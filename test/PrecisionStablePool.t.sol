// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import "../src/pools/PrecisionStablePool.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract PrecisionStablePoolTest is Test {
    PrecisionStablePool pool;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address constant USER = address(0xBEEF);
    address constant LP_PROVIDER = address(0xCAFE);

    function setUp() public {
        pool = new PrecisionStablePool();
    }

    // ── SWAP ────────────────────────────────────────────────────────

    function test_swapUSDCtoUSDT() public {
        _fundAndAddLiquidity(LP_PROVIDER, 10_000_000e6, 10_000_000e6);

        uint256 swapAmount = 10_000e6;
        deal(USDC, USER, swapAmount);

        vm.startPrank(USER);
        IERC20(USDC).transfer(address(pool), swapAmount);
        uint256 amountOut = pool.swap(USDC, 0, USER);
        vm.stopPrank();

        assertGt(amountOut, 9_990e6, "output too low");
        assertLe(amountOut, swapAmount, "output exceeds input");
        assertEq(IERC20(USDT).balanceOf(USER), amountOut);
    }

    function test_swapUSDTtoUSDC() public {
        _fundAndAddLiquidity(LP_PROVIDER, 10_000_000e6, 10_000_000e6);

        uint256 swapAmount = 50_000e6;
        deal(USDT, USER, swapAmount);

        vm.startPrank(USER);
        _transferUSDT(address(pool), swapAmount);
        uint256 amountOut = pool.swap(USDT, 0, USER);
        vm.stopPrank();

        assertGt(amountOut, 49_900e6, "output too low for 50k swap");
        assertLe(amountOut, swapAmount);
        assertEq(IERC20(USDC).balanceOf(USER), amountOut);
    }

    function test_swapSlippageProtection() public {
        _fundAndAddLiquidity(LP_PROVIDER, 10_000_000e6, 10_000_000e6);

        deal(USDC, USER, 10_000e6);
        vm.startPrank(USER);
        IERC20(USDC).transfer(address(pool), 10_000e6);
        vm.expectRevert(PrecisionStablePool.InsufficientOutput.selector);
        pool.swap(USDC, 10_000e6 + 1, USER);
        vm.stopPrank();
    }

    function test_swapInvalidToken() public {
        vm.expectRevert(PrecisionStablePool.InvalidToken.selector);
        pool.swap(address(0xDEAD), 0, USER);
    }

    function test_swapZeroAmount() public {
        _fundAndAddLiquidity(LP_PROVIDER, 1_000_000e6, 1_000_000e6);
        vm.expectRevert(PrecisionStablePool.ZeroAmount.selector);
        pool.swap(USDC, 0, USER);
    }

    function test_swapLargeImbalance() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e6, 100e6);

        // Swap 10x the output reserve — curve prevents draining.
        deal(USDC, USER, 1_000e6);
        vm.startPrank(USER);
        IERC20(USDC).transfer(address(pool), 1_000e6);
        uint256 amountOut = pool.swap(USDC, 0, USER);
        vm.stopPrank();

        // Curve should return less than the full output reserve.
        assertLt(amountOut, 100e6, "curve should not drain entire reserve");
        assertGt(amountOut, 0);
    }

    // ── CURVE BEHAVIOR ──────────────────────────────────────────────

    function test_curveResistsImbalance() public {
        _fundAndAddLiquidity(LP_PROVIDER, 10_000_000e6, 10_000_000e6);

        // Small swap — near 1:1.
        deal(USDC, USER, 1_000e6);
        vm.prank(USER);
        IERC20(USDC).transfer(address(pool), 1_000e6);
        vm.prank(USER);
        uint256 smallOut = pool.swap(USDC, 0, USER);

        // Large swap on same pool — curve should give worse rate per unit.
        deal(USDC, USER, 5_000_000e6);
        vm.prank(USER);
        IERC20(USDC).transfer(address(pool), 5_000_000e6);
        vm.prank(USER);
        uint256 largeOut = pool.swap(USDC, 0, USER);

        uint256 smallRate = smallOut * 1e18 / 1_000e6;
        uint256 largeRate = largeOut * 1e18 / 5_000_000e6;
        assertLt(largeRate, smallRate, "curve should penalize large swaps");
    }

    function test_largeSwapPrecision() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100_000_000e6, 100_000_000e6);

        uint256 swapAmount = 1_000_000e6;
        deal(USDC, USER, swapAmount);

        vm.startPrank(USER);
        IERC20(USDC).transfer(address(pool), swapAmount);
        uint256 amountOut = pool.swap(USDC, 0, USER);
        vm.stopPrank();

        // 1M on 200M pool — slippage should be minimal with A=2000.
        uint256 slippageBps = (swapAmount - amountOut) * 10000 / swapAmount;
        assertLe(slippageBps, 2, "slippage > 0.02% on 0.5% of pool");

        emit log_named_uint("swap_in ", swapAmount);
        emit log_named_uint("swap_out", amountOut);
        emit log_named_uint("slippage_bps", slippageBps);
    }

    // ── LIQUIDITY ───────────────────────────────────────────────────

    function test_addInitialLiquidity() public {
        _fundAndAddLiquidity(LP_PROVIDER, 1_000_000e6, 1_000_000e6);

        assertGt(pool.balanceOf(LP_PROVIDER), 0);
        assertEq(pool.reserve0(), 1_000_000e6);
        assertEq(pool.reserve1(), 1_000_000e6);
        assertEq(pool.balanceOf(address(0)), 1000);
    }

    function test_addLiquidityProportional() public {
        _fundAndAddLiquidity(LP_PROVIDER, 1_000_000e6, 1_000_000e6);
        uint256 supplyBefore = pool.totalSupply();

        address lp2 = address(0xDEAD);
        _fundAndAddLiquidity(lp2, 500_000e6, 500_000e6);

        uint256 lp2Balance = pool.balanceOf(lp2);
        uint256 expected = 1_000_000e6 * supplyBefore / 2_000_000e6;
        assertEq(lp2Balance, expected, "proportional LP mismatch");
    }

    function test_addLiquidityImbalanced() public {
        _fundAndAddLiquidity(LP_PROVIDER, 1_000_000e6, 1_000_000e6);
        uint256 lpFirst = pool.balanceOf(LP_PROVIDER);

        address lp2 = address(0xDEAD);
        _fundAndAddLiquidity(lp2, 500_000e6, 200_000e6);

        assertGt(pool.balanceOf(lp2), 0);
        assertLt(pool.balanceOf(lp2), lpFirst, "imbalanced deposit should give less LP per dollar");
    }

    function test_addLiquiditySingleSided() public {
        _fundAndAddLiquidity(LP_PROVIDER, 1_000_000e6, 1_000_000e6);

        address lp2 = address(0xDEAD);
        deal(USDC, address(pool), 1_500_000e6);
        vm.prank(lp2);
        uint256 lp = pool.addLiquidity(0, lp2);

        assertGt(lp, 0);
    }

    function test_addLiquidityMinLP() public {
        deal(USDC, address(pool), 1_000e6);
        deal(USDT, address(pool), 1_000e6);

        vm.expectRevert(PrecisionStablePool.InsufficientLiquidity.selector);
        pool.addLiquidity(type(uint256).max, LP_PROVIDER);
    }

    function test_removeLiquidity() public {
        _fundAndAddLiquidity(LP_PROVIDER, 1_000_000e6, 1_000_000e6);
        uint256 lp = pool.balanceOf(LP_PROVIDER);

        vm.prank(LP_PROVIDER);
        (uint256 out0, uint256 out1) = pool.removeLiquidity(lp, 0, 0, LP_PROVIDER);

        assertGt(out0, 0);
        assertGt(out1, 0);
        assertEq(pool.balanceOf(LP_PROVIDER), 0);
        assertGt(pool.totalSupply(), 0);
    }

    function test_removeLiquidityZero() public {
        vm.expectRevert(PrecisionStablePool.ZeroAmount.selector);
        pool.removeLiquidity(0, 0, 0, USER);
    }

    function test_removeLiquidityInsufficientBalance() public {
        _fundAndAddLiquidity(LP_PROVIDER, 1_000_000e6, 1_000_000e6);

        vm.prank(USER);
        vm.expectRevert();
        pool.removeLiquidity(1, 0, 0, USER);
    }

    function test_removeLiquiditySlippage() public {
        _fundAndAddLiquidity(LP_PROVIDER, 1_000_000e6, 1_000_000e6);
        uint256 lp = pool.balanceOf(LP_PROVIDER);

        vm.prank(LP_PROVIDER);
        vm.expectRevert(PrecisionStablePool.InsufficientLPBurned.selector);
        pool.removeLiquidity(lp, type(uint256).max, 0, LP_PROVIDER);
    }

    // ── RESERVES ────────────────────────────────────────────────────

    function test_reservesSyncAfterSwap() public {
        _fundAndAddLiquidity(LP_PROVIDER, 10_000_000e6, 10_000_000e6);

        deal(USDC, USER, 1_000e6);
        vm.startPrank(USER);
        IERC20(USDC).transfer(address(pool), 1_000e6);
        pool.swap(USDC, 0, USER);
        vm.stopPrank();

        assertEq(pool.reserve0(), IERC20(USDC).balanceOf(address(pool)));
        assertEq(pool.reserve1(), IERC20(USDT).balanceOf(address(pool)));
    }

    // ── FEE ACCUMULATION ────────────────────────────────────────────

    function test_feeAccumulation() public {
        _fundAndAddLiquidity(LP_PROVIDER, 10_000_000e6, 10_000_000e6);

        for (uint256 i; i < 10; i++) {
            deal(USDC, USER, 100_000e6);
            vm.prank(USER);
            IERC20(USDC).transfer(address(pool), 100_000e6);
            vm.prank(USER);
            pool.swap(USDC, 0, USER);

            uint256 usdtBal = IERC20(USDT).balanceOf(USER);
            vm.prank(USER);
            _transferUSDT(address(pool), usdtBal);
            vm.prank(USER);
            pool.swap(USDT, 0, USER);
        }

        uint256 totalReserves = uint256(pool.reserve0()) + uint256(pool.reserve1());
        assertGt(totalReserves, 20_000_000e6, "fees should grow reserves");
    }

    // ── GAS BENCHMARKS ──────────────────────────────────────────────

    function test_gasSwap() public {
        _fundAndAddLiquidity(LP_PROVIDER, 10_000_000e6, 10_000_000e6);

        deal(USDC, USER, 10_000e6);
        vm.startPrank(USER);
        IERC20(USDC).transfer(address(pool), 10_000e6);

        uint256 gasBefore = gasleft();
        pool.swap(USDC, 0, USER);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("PRECISION_POOL_SWAP_GAS", gasUsed);
    }

    function test_gasAddLiquidity() public {
        deal(USDC, address(pool), 1_000_000e6);
        deal(USDT, address(pool), 1_000_000e6);

        uint256 gasBefore = gasleft();
        pool.addLiquidity(0, LP_PROVIDER);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("ADD_LIQUIDITY_GAS", gasUsed);
    }

    function test_gasRemoveLiquidity() public {
        _fundAndAddLiquidity(LP_PROVIDER, 1_000_000e6, 1_000_000e6);
        uint256 lp = pool.balanceOf(LP_PROVIDER);

        vm.prank(LP_PROVIDER);
        uint256 gasBefore = gasleft();
        pool.removeLiquidity(lp, 0, 0, LP_PROVIDER);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("REMOVE_LIQUIDITY_GAS", gasUsed);
    }

    // ── HELPERS ─────────────────────────────────────────────────────

    function _fundAndAddLiquidity(address provider, uint256 amount0, uint256 amount1) internal {
        deal(USDC, address(pool), amount0 + IERC20(USDC).balanceOf(address(pool)));
        deal(USDT, address(pool), amount1 + IERC20(USDT).balanceOf(address(pool)));

        vm.prank(provider);
        pool.addLiquidity(0, provider);
    }

    function _transferUSDT(address to, uint256 amount) internal {
        (bool ok,) = USDT.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        require(ok, "USDT transfer failed");
    }
}
