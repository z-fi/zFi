// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Probes two claims from a third-party audit pass:
///   1. an in-range seed price that passes the guards but leaves the pool
///      priced below its lower bound, bricking both swap directions;
///   2. base/hook fee rounding permitting fee avoidance by splitting an order.
contract AuditClaimsTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPoolLens lens;
    MockERC20 usdc;

    uint256 constant SQRT_LOW = 42426406871192;
    uint256 constant SQRT_HIGH = 46904157598234;
    uint256 constant FEE = 500;

    address lp = address(0xC11);
    address trader = address(0x7AD);

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0));
        lens = new PrecisionPoolLens(factory);
        usdc = new MockERC20("USDC", 6);
        usdc.mint(lp, 100_000_000e6);
        usdc.mint(trader, 100_000_000e6);
        vm.deal(lp, 100_000 ether);
        vm.deal(trader, 100_000 ether);
        vm.prank(lp);
        usdc.approve(address(factory), type(uint256).max);
    }

    function _mkt(uint256 fee_) internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(usdc),
            sqrtPLow: SQRT_LOW,
            sqrtPHigh: SQRT_HIGH,
            fee: fee_,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    /// CLAIM 1: does any in-range seed land the pool below its own floor?
    function testFuzz_Claim_SeedNeverLandsBelowTheFloor(uint256 s, uint256 amt0) public {
        s = bound(s, SQRT_LOW, SQRT_HIGH);
        amt0 = bound(amt0, 1e15, 1_000 ether);

        PrecisionPoolFactory.Market memory m = _mkt(FEE);
        m.fee = uint256(bound(uint256(keccak256(abi.encode(s))) % 3, 0, 2)) * 1000 + 500;

        vm.startPrank(lp);
        try factory.createAndSeed{value: amt0}(m, s, amt0, 50_000_000e6, 0, lp) returns (
            address p, uint256, uint256, uint256
        ) {
            vm.stopPrank();
            PrecisionPool pool = PrecisionPool(payable(p));
            uint256 px = pool.sqrtPriceCurrent();
            assertGe(px, SQRT_LOW, "SEEDED BELOW THE FLOOR");
            assertLe(px, SQRT_HIGH, "SEEDED ABOVE THE CEILING");
        } catch {
            vm.stopPrank();
        }
    }

    /// CLAIM 1, boundary: the tightest in-range price, one wei above the floor.
    function test_Claim_SeedOneWeiAboveTheFloor() public {
        vm.startPrank(lp);
        (address p,,,) = factory.createAndSeed{value: 100 ether}(
            _mkt(FEE), SQRT_LOW + 1, 100 ether, 50_000_000e6, 0, lp
        );
        vm.stopPrank();
        PrecisionPool pool = PrecisionPool(payable(p));

        emit log_named_uint("sqrtPrice ", pool.sqrtPriceCurrent());
        emit log_named_uint("SQRT_LOW  ", SQRT_LOW);
        emit log_named_uint("reserve0  ", pool.reserve0());
        emit log_named_uint("reserve1  ", pool.reserve1());
        assertGe(pool.sqrtPriceCurrent(), SQRT_LOW, "SEEDED BELOW THE FLOOR");

        // And is it actually tradeable in the direction that should work?
        uint256 q = lens.quote(address(pool), address(usdc), 1_000e6);
        emit log_named_uint("quote usdc->eth", q);
    }

    /// CLAIM 1, other half: the fuzz above always let token0 bind. Here token1
    /// is the scarce side, which is the case near the upper bound and exercises
    /// the opposite rounding path.
    function testFuzz_Claim_SeedWithToken1Binding(uint256 s, uint256 amt1) public {
        s = bound(s, SQRT_LOW, SQRT_HIGH);
        amt1 = bound(amt1, 1e3, 10_000_000e6);

        vm.startPrank(lp);
        try factory.createAndSeed{value: 100_000 ether}(
            _mkt(FEE), s, 100_000 ether, amt1, 0, lp
        ) returns (address p, uint256, uint256, uint256) {
            vm.stopPrank();
            PrecisionPool pool = PrecisionPool(payable(p));
            uint256 px = pool.sqrtPriceCurrent();
            assertGe(px, SQRT_LOW, "SEEDED BELOW THE FLOOR");
            assertLe(px, SQRT_HIGH, "SEEDED ABOVE THE CEILING");
        } catch {
            vm.stopPrank();
        }
    }

    /// CLAIM 1, boundary: one wei below the ceiling, where token0 rounds to ~0.
    function test_Claim_SeedOneWeiBelowTheCeiling() public {
        vm.startPrank(lp);
        (address p,,,) = factory.createAndSeed{value: 100 ether}(
            _mkt(FEE), SQRT_HIGH - 1, 100 ether, 50_000_000e6, 0, lp
        );
        vm.stopPrank();
        PrecisionPool pool = PrecisionPool(payable(p));
        emit log_named_uint("sqrtPrice ", pool.sqrtPriceCurrent());
        emit log_named_uint("SQRT_HIGH ", SQRT_HIGH);
        emit log_named_uint("reserve0  ", pool.reserve0());
        assertGe(pool.sqrtPriceCurrent(), SQRT_LOW, "BELOW THE FLOOR");
        assertLe(pool.sqrtPriceCurrent(), SQRT_HIGH, "ABOVE THE CEILING");
    }

    /// CLAIM 2: does splitting an order avoid the fee?
    function test_Claim_SplitOrderFeeAvoidance() public {
        vm.startPrank(lp);
        (address p,,,) = factory.createAndSeed{value: 100 ether}(
            _mkt(FEE), 44721359549995, 100 ether, 50_000_000e6, 0, lp
        );
        vm.stopPrank();
        PrecisionPool pool = PrecisionPool(payable(p));

        // Smallest input whose fee rounds to zero: amountIn * 500 / 1e6 < 1.
        uint256 dust = 1_999;
        uint256 q = lens.quote(address(pool), address(usdc), dust);
        emit log_named_uint("dust in (usdc raw)", dust);
        emit log_named_uint("quoted out (wei) ", q);
        emit log_named_uint("fee charged      ", dust * FEE / 1_000_000);

        // Compare: one big trade vs the same notional split into dust trades.
        uint256 bulk = 100_000e6;
        uint256 bulkOut = lens.quote(address(pool), address(usdc), bulk);
        emit log_named_uint("bulk in          ", bulk);
        emit log_named_uint("bulk out         ", bulkOut);
        emit log_named_uint("dust trades needed", bulk / dust);
    }
}
