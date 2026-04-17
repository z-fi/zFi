// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import "../src/pools/PrecisionStablePool.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract AuditCheckTest is Test {
    PrecisionStablePool pool;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USER = address(0xBEEF);

    function setUp() public {
        pool = new PrecisionStablePool();
    }

    // ── CRITICAL: dust round-trip profit claim ──────────────────────

    function test_audit_dustRoundTrip_smallPool() public {
        // Auditor's scenario: 1000 USDC / 1000 USDT pool (1e9 raw units each).
        deal(USDC, address(pool), 1_000e6);
        deal(USDT, address(pool), 1_000e6);
        pool.addLiquidity(0, address(this));

        // Swap 1 raw unit USDC → USDT.
        deal(USDC, USER, 1);
        vm.prank(USER);
        IERC20(USDC).transfer(address(pool), 1);
        vm.prank(USER);
        uint256 out1 = pool.swap(USDC, 0, USER);

        emit log_named_uint("1 raw USDC -> USDT", out1);

        // Swap result back USDT → USDC.
        vm.prank(USER);
        _transferUSDT(address(pool), out1);
        vm.prank(USER);
        uint256 out2 = pool.swap(USDT, 0, USER);

        emit log_named_uint("round trip back USDC", out2);
        emit log_named_uint("net profit raw units", out2 > 1 ? out2 - 1 : 0);

        // Auditor claims net profit of 31. Let's see.
        if (out2 > 1) {
            emit log("VULNERABLE: dust round-trip is profitable");
        } else {
            emit log("SAFE: no dust profit");
        }
    }

    function test_audit_dustRoundTrip_largePool() public {
        // Same test with realistic pool size (10M each side).
        deal(USDC, address(pool), 10_000_000e6);
        deal(USDT, address(pool), 10_000_000e6);
        pool.addLiquidity(0, address(this));

        deal(USDC, USER, 1);
        vm.prank(USER);
        IERC20(USDC).transfer(address(pool), 1);
        vm.prank(USER);
        uint256 out1 = pool.swap(USDC, 0, USER);

        emit log_named_uint("1 raw USDC -> USDT (large pool)", out1);

        if (out1 > 0) {
            vm.prank(USER);
            _transferUSDT(address(pool), out1);
            vm.prank(USER);
            uint256 out2 = pool.swap(USDT, 0, USER);
            emit log_named_uint("round trip back USDC", out2);
        }
    }

    function test_audit_dustRoundTrip_loop() public {
        // Try to extract value via repeated dust swaps.
        deal(USDC, address(pool), 10_000_000e6);
        deal(USDT, address(pool), 10_000_000e6);
        pool.addLiquidity(0, address(this));

        uint256 startUSDC = 100; // 100 raw units = 0.0001 USDC.
        deal(USDC, USER, startUSDC);

        for (uint256 i; i < 20; i++) {
            uint256 usdcBal = IERC20(USDC).balanceOf(USER);
            if (usdcBal == 0) break;

            vm.prank(USER);
            IERC20(USDC).transfer(address(pool), usdcBal);
            vm.prank(USER);
            uint256 usdtOut = pool.swap(USDC, 0, USER);
            if (usdtOut == 0) break;

            vm.prank(USER);
            _transferUSDT(address(pool), usdtOut);
            vm.prank(USER);
            uint256 usdcOut = pool.swap(USDT, 0, USER);
            if (usdcOut == 0) break;
        }

        uint256 endUSDC = IERC20(USDC).balanceOf(USER);
        uint256 endUSDT = IERC20(USDT).balanceOf(USER);

        emit log_named_uint("start USDC", startUSDC);
        emit log_named_uint("end USDC", endUSDC);
        emit log_named_uint("end USDT", endUSDT);

        if (endUSDC + endUSDT > startUSDC) {
            emit log("VULNERABLE: dust loop extracted value");
        } else {
            emit log("SAFE: no value extracted");
        }
    }

    // ── MEDIUM: Newton convergence at extreme imbalance ─────────────

    function test_audit_extremeImbalance_convergence() public {
        // Pool seeded balanced, then massively imbalanced.
        deal(USDC, address(pool), 10_000_000e6);
        deal(USDT, address(pool), 10_000_000e6);
        pool.addLiquidity(0, address(this));

        // Push 9M USDC into pool (creating 19M/10M ratio).
        deal(USDC, USER, 9_000_000e6);
        vm.prank(USER);
        IERC20(USDC).transfer(address(pool), 9_000_000e6);
        vm.prank(USER);
        uint256 out = pool.swap(USDC, 0, USER);

        emit log_named_uint("9M USDC swap output USDT", out);
        emit log_named_uint("reserve0 after", pool.reserve0());
        emit log_named_uint("reserve1 after", pool.reserve1());

        // Pool should not be drained — curve protects.
        assertGt(pool.reserve1(), 0, "pool drained");
        assertLt(out, 10_000_000e6, "curve didn't limit output");
    }

    // ── HELPERS ─────────────────────────────────────────────────────

    function _transferUSDT(address to, uint256 amount) internal {
        (bool ok,) = USDT.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        require(ok);
    }
}
