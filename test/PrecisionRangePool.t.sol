// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import "../src/pools/PrecisionRangePool.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract PrecisionRangePoolTest is Test {
    PrecisionRangePool pool;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address constant USER = address(0xBEEF);
    address constant LP_PROVIDER = address(0xCAFE);

    function setUp() public {
        pool = new PrecisionRangePool();
    }

    // ── SWAP ────────────────────────────────────────────────────────

    function test_swapETHtoUSDC() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);

        uint256 swapAmount = 1e18;
        vm.deal(USER, swapAmount);

        vm.prank(USER);
        uint256 amountOut = pool.swap{value: swapAmount}(address(0), 0, USER);

        emit log_named_uint("1 ETH -> USDC", amountOut);
        assertGt(amountOut, 2000e6, "output too low");
        assertLt(amountOut, 3000e6, "output too high");
        assertEq(IERC20(USDC).balanceOf(USER), amountOut);
    }

    function test_swapUSDCtoETH() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);

        uint256 swapAmount = 2500e6;
        deal(USDC, USER, swapAmount);

        vm.startPrank(USER);
        IERC20(USDC).transfer(address(pool), swapAmount);
        uint256 amountOut = pool.swap(USDC, 0, USER);
        vm.stopPrank();

        emit log_named_uint("2500 USDC -> ETH (wei)", amountOut);
        assertGt(amountOut, 0.5e18, "output too low");
        assertLt(amountOut, 2e18, "output too high");
    }

    function test_swapSlippageProtection() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);

        vm.deal(USER, 1e18);
        vm.prank(USER);
        vm.expectRevert(PrecisionRangePool.InsufficientOutput.selector);
        pool.swap{value: 1e18}(address(0), type(uint256).max, USER);
    }

    function test_swapInvalidToken() public {
        vm.expectRevert(PrecisionRangePool.InvalidToken.selector);
        pool.swap(address(0xDEAD), 0, USER);
    }

    function test_swapZeroAmount() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);
        vm.expectRevert(PrecisionRangePool.ZeroAmount.selector);
        pool.swap(USDC, 0, USER);
    }

    // ── PRICE IMPACT ────────────────────────────────────────────────

    function test_largeSwapPriceImpact() public {
        // Use a small pool so swaps are a meaningful fraction of liquidity.
        _fundAndAddLiquidity(LP_PROVIDER, 1e18, 2_500e6);

        // Swap 90% of ETH reserve — must show price impact.
        vm.deal(USER, 0.9e18);
        vm.prank(USER);
        uint256 out = pool.swap{value: 0.9e18}(address(0), 0, USER);
        uint256 rate = out * 1e18 / 0.9e18;

        // Spot rate is ~$2568. A 90% swap should give meaningfully less per ETH.
        emit log_named_uint("large swap rate (USDC per ETH, scaled)", rate);
        assertLt(rate, 2568e6, "rate should be worse than spot");
    }

    // ── LIQUIDITY ───────────────────────────────────────────────────

    function test_addInitialLiquidity() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);

        assertGt(pool.balanceOf(LP_PROVIDER), 0);
        assertGe(pool.reserve0(), 100e18);
        assertEq(pool.reserve1(), 250_000e6);
        assertEq(pool.balanceOf(address(0)), 1000);
    }

    function test_addLiquidityProportional() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);

        address lp2 = address(0xDEAD);
        _fundAndAddLiquidity(lp2, 50e18, 125_000e6);

        uint256 lp2Balance = pool.balanceOf(lp2);
        uint256 lpFirst = pool.balanceOf(LP_PROVIDER);
        assertGt(lp2Balance, 0);
        assertGt(lp2Balance * 100 / lpFirst, 45);
        assertLt(lp2Balance * 100 / lpFirst, 55);
    }

    function test_addLiquidityMinLP() public {
        deal(USDC, address(pool), 250_000e6);
        vm.deal(address(pool), 100e18);

        vm.expectRevert(PrecisionRangePool.InsufficientLiquidity.selector);
        pool.addLiquidity(type(uint256).max, LP_PROVIDER);
    }

    function test_removeLiquidity() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);
        uint256 lp = pool.balanceOf(LP_PROVIDER);

        uint256 ethBefore = LP_PROVIDER.balance;
        vm.prank(LP_PROVIDER);
        (uint256 out0, uint256 out1) = pool.removeLiquidity(lp, 0, 0, LP_PROVIDER);

        assertGt(out0, 0);
        assertGt(out1, 0);
        assertEq(pool.balanceOf(LP_PROVIDER), 0);
        assertEq(LP_PROVIDER.balance - ethBefore, out0);
    }

    function test_removeLiquidityZero() public {
        vm.expectRevert(PrecisionRangePool.ZeroAmount.selector);
        pool.removeLiquidity(0, 0, 0, USER);
    }

    function test_removeLiquidityInsufficientBalance() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);

        vm.prank(USER);
        vm.expectRevert();
        pool.removeLiquidity(1, 0, 0, USER);
    }

    function test_removeLiquiditySlippage() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);
        uint256 lp = pool.balanceOf(LP_PROVIDER);

        vm.prank(LP_PROVIDER);
        vm.expectRevert(PrecisionRangePool.InsufficientLPBurned.selector);
        pool.removeLiquidity(lp, type(uint256).max, 0, LP_PROVIDER);
    }

    // ── RESERVES ────────────────────────────────────────────────────

    function test_reservesSyncAfterSwap() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);

        vm.deal(USER, 1e18);
        vm.prank(USER);
        pool.swap{value: 1e18}(address(0), 0, USER);

        assertEq(pool.reserve0(), address(pool).balance);
        assertEq(pool.reserve1(), IERC20(USDC).balanceOf(address(pool)));
    }

    // ── RANGE CORRECTNESS ─────────────────────────────────────────

    function test_rangeInvariant() public {
        _fundAndAddLiquidity(LP_PROVIDER, 1e18, 2_500e6);

        uint256 L = pool.totalSupply();
        uint256 v0 = L * 1e18 / 54772255750516;
        uint256 v1 = L * 46904157598234 / 1e18;

        uint256 X = uint256(pool.reserve0()) + v0;
        uint256 Y = uint256(pool.reserve1()) + v1;

        // k/L^2 should be ~1. Use mulDiv-safe ordering.
        // k = X * Y, L2 = L * L. Compute ratio = X * Y / L * 1e18 / L.
        uint256 ratio = X * Y / L * 1e18 / L;
        emit log_named_uint("k/L^2 * 1e18", ratio);
        assertGt(ratio, 0.99e18, "k/L^2 too low");
        assertLt(ratio, 1.01e18, "k/L^2 too high");

        // Price bounds from sqrt constants: these are baked-in mathematical facts.
        // p_upper = SQRT_P_HIGH^2 * 1e12 / 1e36 = SQRT_P_HIGH^2 / 1e24
        uint256 p_upper = uint256(54772255750516) * 54772255750516 / 1e24;
        uint256 p_lower = uint256(46904157598234) * 46904157598234 / 1e24;

        emit log_named_uint("upper price USD", p_upper);
        emit log_named_uint("lower price USD", p_lower);
        assertGe(p_upper, 2999, "upper should be ~$3000");
        assertLe(p_upper, 3001, "upper should be ~$3000");
        assertGe(p_lower, 2199, "lower should be ~$2200");
        assertLe(p_lower, 2201, "lower should be ~$2200");
    }

    // ── DUST SAFETY ─────────────────────────────────────────────────

    function test_dustRoundTripNotProfitable() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);

        vm.deal(USER, 1);
        vm.prank(USER);
        uint256 out1 = pool.swap{value: 1}(address(0), 0, USER);

        emit log_named_uint("1 wei ETH -> USDC", out1);

        if (out1 > 0) {
            vm.prank(USER);
            IERC20(USDC).transfer(address(pool), out1);
            vm.prank(USER);
            uint256 out2 = pool.swap(USDC, 0, USER);
            emit log_named_uint("round trip back ETH", out2);
            assertLe(out2, 1, "dust round-trip should not be profitable");
        }
    }

    // ── GAS BENCHMARKS ──────────────────────────────────────────────

    function test_gasSwapETH() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);

        vm.deal(USER, 1e18);
        vm.prank(USER);

        uint256 gasBefore = gasleft();
        pool.swap{value: 1e18}(address(0), 0, USER);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("PRECISION_RANGE_SWAP_ETH_GAS", gasUsed);
    }

    function test_gasSwapUSDC() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);

        deal(USDC, USER, 2500e6);
        vm.startPrank(USER);
        IERC20(USDC).transfer(address(pool), 2500e6);

        uint256 gasBefore = gasleft();
        pool.swap(USDC, 0, USER);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("PRECISION_RANGE_SWAP_USDC_GAS", gasUsed);
    }

    function test_gasAddLiquidity() public {
        deal(USDC, address(pool), 250_000e6);
        vm.deal(address(pool), 100e18);

        uint256 gasBefore = gasleft();
        pool.addLiquidity(0, LP_PROVIDER);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("ADD_LIQUIDITY_GAS", gasUsed);
    }

    function test_gasRemoveLiquidity() public {
        _fundAndAddLiquidity(LP_PROVIDER, 100e18, 250_000e6);
        uint256 lp = pool.balanceOf(LP_PROVIDER);

        vm.prank(LP_PROVIDER);
        uint256 gasBefore = gasleft();
        pool.removeLiquidity(lp, 0, 0, LP_PROVIDER);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("REMOVE_LIQUIDITY_GAS", gasUsed);
    }

    // ── HELPERS ─────────────────────────────────────────────────────

    function _fundAndAddLiquidity(address provider, uint256 ethAmount, uint256 usdcAmount) internal {
        deal(USDC, address(pool), usdcAmount + IERC20(USDC).balanceOf(address(pool)));
        vm.deal(address(pool), ethAmount + address(pool).balance);

        vm.prank(provider);
        pool.addLiquidity(0, provider);
    }
}
