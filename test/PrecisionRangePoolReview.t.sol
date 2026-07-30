// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionRangePool} from "../src/pools/PrecisionRangePool.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Demonstrates the deposit-side behaviour of the deployed-shape pool,
/// so the difference from PrecisionPool is measured rather than asserted.
contract PrecisionRangePoolReviewTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    PrecisionRangePool pool;

    address seeder = address(0xC11);
    address depositor = address(0xD09);

    function setUp() public {
        pool = new PrecisionRangePool();
        deal(USDC, address(pool), 250_000e6);
        vm.deal(address(pool), 100 ether);
        pool.addLiquidity(0, seeder);
    }

    /// @dev An unbalanced deposit mints LP for the binding side only, but the
    /// pool keeps BOTH balances in full: `reserve1 = bal1` regardless of what
    /// was credited. The oversupply becomes a gift to existing holders.
    function test_OversuppliedSideIsAbsorbedNotRefunded() public {
        uint256 seederShares = pool.balanceOf(seeder);
        uint256 r1Before = pool.reserve1();

        // 1 ETH is worth far less than 100,000 USDC in this band, so ETH binds.
        vm.deal(depositor, 1 ether);
        deal(USDC, depositor, 100_000e6);

        vm.startPrank(depositor);
        (bool ok,) = address(pool).call{value: 1 ether}("");
        require(ok, "eth");
        IERC20(USDC).transfer(address(pool), 100_000e6);
        uint256 lp = pool.addLiquidity(0, depositor);
        vm.stopPrank();

        assertGt(lp, 0, "depositor got shares for the ETH side");
        assertEq(IERC20(USDC).balanceOf(depositor), 0, "every USDC stayed in the pool");
        assertEq(pool.reserve1() - r1Before, 100_000e6, "including the oversupply");

        // The seeder's claim on USDC rose without them depositing anything.
        uint256 supply = pool.totalSupply();
        uint256 seederUsdcAfter = uint256(pool.reserve1()) * seederShares / supply;
        uint256 seederUsdcBefore = r1Before * seederShares / (supply - lp);
        assertGt(seederUsdcAfter, seederUsdcBefore, "existing holders were paid the excess");
    }
}
