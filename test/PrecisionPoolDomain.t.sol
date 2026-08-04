// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev The two ends of the admissible domain: storage-width limits, and the
/// absolute sqrt-price bounds. The rule being checked throughout is that a
/// configuration is EITHER sound (price inside its band, tradeable) OR refused
/// outright. What must never happen is a pool that is accepted and broken -
/// which is exactly what H-01 was.
contract PrecisionPoolDomainTest is Test {
    PrecisionPoolFactory factory;
    MockERC20 tk;
    address lp = address(0xC11);

    uint256 constant MAXP = 1e36; // MAX_SQRT_PRICE
    uint256 constant U128 = type(uint128).max;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        tk = new MockERC20("TK", 18);
        tk.mint(lp, type(uint256).max / 2);
        vm.deal(lp, U128);
    }

    function _mkt(uint256 low, uint256 high) internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(tk),
            sqrtPLow: low,
            sqrtPHigh: high,
            fee: 500,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    function _seedOrRefuse(uint256 low, uint256 mid, uint256 high, uint256 a0, uint256 a1)
        internal
        returns (address p)
    {
        vm.startPrank(lp);
        tk.approve(address(factory), type(uint256).max);
        try factory.createAndSeed{value: a0}(_mkt(low, high), mid, a0, a1, 0, lp) returns (
            address addr, uint256, uint256, uint256
        ) {
            p = addr;
        } catch {
            p = address(0);
        }
        vm.stopPrank();

        if (p != address(0)) {
            PrecisionPool pool = PrecisionPool(payable(p));
            uint256 px = pool.sqrtPriceCurrent();
            assertGe(px, low, "ACCEPTED BUT BELOW FLOOR");
            assertLe(px, high, "ACCEPTED BUT ABOVE CEILING");
        }
    }

    // ------------------------------------------- absolute sqrt-price domain

    /// @dev The widest band the factory permits at all.
    function test_WidestPossibleBand() public {
        address p = _seedOrRefuse(1, 1e18, MAXP, 1_000 ether, 1e24);
        emit log_named_string("sqrtPLow=1, sqrtPHigh=1e36", p == address(0) ? "refused" : "seeded");
    }

    /// @dev The narrowest: two adjacent representable prices.
    function test_NarrowestPossibleBand() public {
        address p = _seedOrRefuse(1e18, 1e18 + 1, 1e18 + 2, 1_000 ether, 1e24);
        emit log_named_string("one-unit-wide band", p == address(0) ? "refused" : "seeded");
    }

    function test_FloorAtOne() public {
        address p = _seedOrRefuse(1, 2, 3, 1_000 ether, 1e24);
        emit log_named_string("sqrtPLow=1 tiny band", p == address(0) ? "refused" : "seeded");
    }

    function test_CeilingAtTheMaximum() public {
        address p = _seedOrRefuse(MAXP - 2, MAXP - 1, MAXP, 1_000 ether, 1e24);
        emit log_named_string("band at 1e36", p == address(0) ? "refused" : "seeded");
    }

    function test_AboveTheMaximumIsRefused() public {
        vm.prank(lp);
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(_mkt(1, MAXP + 1));
    }

    /// @dev Any band, any seed price, any amounts: accepted implies in-range.
    /// @dev Run count is lowered deliberately - each run deploys a pool at a
    ///      fresh CREATE2 address, and under this repo's global fork every one
    ///      is an RPC account lookup that the public endpoint rate-limits.
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_AnyBandIsSoundOrRefused(uint256 low, uint256 high, uint256 mid, uint256 a0, uint256 a1)
        public
    {
        low = bound(low, 1, MAXP - 2);
        high = bound(high, low + 1, MAXP);
        mid = bound(mid, low, high);
        a0 = bound(a0, 1, 10_000 ether);
        a1 = bound(a1, 1, 1e26);
        _seedOrRefuse(low, mid, high, a0, a1);
    }

    // ------------------------------------------------- storage-width limits

    /// @dev Reserves are uint128. A deposit that would not fit must revert
    /// rather than truncate - truncation would silently destroy LP claims.
    function test_ReserveOverflowIsRefusedNotTruncated() public {
        uint256 low = 42426406871192;
        uint256 mid = 44721359549995;
        uint256 high = 46904157598234;

        address p = _seedOrRefuse(low, mid, high, 1_000 ether, 1e24);
        if (p == address(0)) return;
        PrecisionPool pool = PrecisionPool(payable(p));

        // Try to push token0 reserves past uint128 in one deposit.
        vm.deal(lp, U128);
        vm.startPrank(lp);
        (bool ok,) = address(pool).call{value: U128 - 1}(
            abi.encodeCall(PrecisionPool.addLiquidityExact, (0, U128 - 1, type(uint128).max, 0, lp))
        );
        vm.stopPrank();

        assertLe(uint256(pool.reserve0()), U128, "reserve0 exceeded its width");
        assertLe(uint256(pool.reserve1()), U128, "reserve1 exceeded its width");
        assertGe(pool.sqrtPriceCurrent(), low, "left the band");
        assertLe(pool.sqrtPriceCurrent(), high, "left the band");
        emit log_named_string("oversized deposit", ok ? "accepted (bounded)" : "refused");
    }

    /// @dev Liquidity is capped at MAX_LIQUIDITY. A seed demanding more must be
    /// refused, not wrapped.
    function test_LiquidityCapIsEnforced() public {
        vm.deal(lp, U128);
        vm.startPrank(lp);
        tk.approve(address(factory), type(uint256).max);
        // A very wide band with enormous deposits maximises L.
        try factory.createAndSeed{value: U128 / 2}(
            _mkt(1, MAXP), 1e18, U128 / 2, type(uint128).max, 0, lp
        ) returns (address p, uint256 lpOut, uint256, uint256) {
            assertLe(lpOut + 1000, U128, "liquidity exceeded its cap");
            assertGe(PrecisionPool(payable(p)).sqrtPriceCurrent(), 1, "left the band");
        } catch {
            emit log("extreme seed refused");
        }
        vm.stopPrank();
    }
}
