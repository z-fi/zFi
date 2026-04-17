// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import "../src/pools/PrecisionStablePool.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract AuditCheck2Test is Test {
    PrecisionStablePool pool;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function setUp() public {
        pool = new PrecisionStablePool();
    }

    function test_audit_oneSidedInitBlocked() public {
        deal(USDC, address(pool), 1_000_000e6);
        // No USDT — must revert.
        vm.expectRevert(PrecisionStablePool.ZeroAmount.selector);
        pool.addLiquidity(0, address(this));
    }

    function test_audit_oneSidedInitBlockedReverse() public {
        deal(USDT, address(pool), 1_000_000e6);
        // No USDC — must revert.
        vm.expectRevert(PrecisionStablePool.ZeroAmount.selector);
        pool.addLiquidity(0, address(this));
    }

    function test_audit_swapGuardsDegenerate() public {
        // Even if pool somehow ended up one-sided (can't happen via addLiquidity now),
        // swap guards against _computeY returning > rOut.
        deal(USDC, address(pool), 1_000_000e6);
        deal(USDT, address(pool), 1_000_000e6);
        pool.addLiquidity(0, address(this));

        // Verify normal swap works.
        deal(USDC, address(0xBEEF), 1000e6);
        vm.prank(address(0xBEEF));
        IERC20(USDC).transfer(address(pool), 1000e6);
        vm.prank(address(0xBEEF));
        uint256 out = pool.swap(USDC, 0, address(0xBEEF));
        assertGt(out, 0);
    }
}
