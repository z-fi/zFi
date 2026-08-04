// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PriceTape, IPriceTape} from "../src/pools/PriceTape.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev The price tape as a pool actually experiences it: real swaps, real
///      reserves, real fees. The library tests cover the codec; these cover the
///      thing a chart client will call, and the gas the tape costs a trader.
contract PrecisionPoolTapeTest is Test {
    PrecisionPoolFactory factory;
    MockERC20 a;
    MockERC20 b;
    PrecisionPool pool;

    address lp = address(0xC11);
    address trader = address(0x7AD);

    /// @dev Tracked explicitly: the optimiser folds repeated `block.timestamp`
    ///      reads into one, so `vm.warp(block.timestamp + d)` twice would warp
    ///      to the same instant and no bucket would ever roll.
    uint256 internal t;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        a = new MockERC20("A", 18);
        b = new MockERC20("B", 18);
        if (address(a) > address(b)) (a, b) = (b, a);
        a.mint(lp, 1e30);
        b.mint(lp, 1e30);
        a.mint(trader, 1e30);
        b.mint(trader, 1e30);

        vm.startPrank(lp);
        a.approve(address(factory), type(uint256).max);
        b.approve(address(factory), type(uint256).max);
        vm.stopPrank();

        PrecisionPoolFactory.Market memory m = PrecisionPoolFactory.Market({
            token0: address(a),
            token1: address(b),
            sqrtPLow: 1e18,
            sqrtPHigh: 3e18,
            fee: 3000,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
        vm.prank(lp);
        (address p,,,) = factory.createAndSeed(m, 2e18, 1_000_000e18, 4_000_000e18, 0, lp);
        pool = PrecisionPool(payable(p));

        vm.startPrank(trader);
        a.approve(address(pool), type(uint256).max);
        b.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        t = 1_700_000_000;
        vm.warp(t);
    }

    function _warp(uint256 dt) internal {
        t += dt;
        vm.warp(t);
    }

    function _swapA(uint256 amount) internal returns (uint256) {
        vm.prank(trader);
        return pool.swapExactIn(address(a), amount, 0, trader);
    }

    function _swapB(uint256 amount) internal returns (uint256) {
        vm.prank(trader);
        return pool.swapExactIn(address(b), amount, 0, trader);
    }

    function _fine(uint256 count) internal view returns (uint256[] memory) {
        return pool.tape(pool.FINE_PERIOD(), count);
    }

    // ------------------------------------------------------------- interface

    function test_PoolAdvertisesItsTape() public view {
        uint256[] memory periods = pool.tapePeriods();
        assertEq(periods.length, 2);
        assertEq(periods[0], 5 minutes);
        assertEq(periods[1], 4 hours);

        (address base, address quote) = pool.tapePair();
        assertEq(base, address(a), "base is token0");
        assertEq(quote, address(b), "quote is token1");
    }

    function test_UnknownPeriodReturnsNothingRatherThanGuessing() public view {
        assertEq(pool.tape(1 hours, 10).length, 0, "an unrecorded timeframe must not be invented");
    }

    function test_TapeIsEmptyBeforeAnyTrade() public view {
        uint256[] memory bars = _fine(4);
        for (uint256 i; i < bars.length; ++i) {
            assertEq(bars[i], 0, "seeding liquidity is not a trade and must not print");
        }
    }

    // ----------------------------------------------------------- recording

    function test_ASwapPrintsTheExecutedPrice() public {
        uint256 amountIn = 1000e18;
        uint256 out = _swapA(amountIn);

        uint256[] memory bars = _fine(1);
        (, uint256 o,,, uint256 c, uint256 v, uint16 n) = PriceTape.decode(bars[0]);

        uint256 executed = (out * 1e18) / amountIn;
        assertApproxEqRel(o, executed, 1.2e11, "open is the executed price, fee included");
        assertApproxEqRel(c, executed, 1.2e11, "close matches on a single-trade bar");
        assertApproxEqRel(v, amountIn, 1.2e11, "volume is denominated in token0");
        assertEq(n, 1);
    }

    function test_BothDirectionsShareOneOrientation() public {
        // A buy and a sell must land on the same price scale, or the chart
        // would zig-zag between a rate and its reciprocal.
        _swapA(1000e18);
        uint256[] memory afterBuy = _fine(1);
        (,,,, uint256 c1,,) = PriceTape.decode(afterBuy[0]);

        _swapB(1000e18);
        uint256[] memory afterSell = _fine(1);
        (,,,, uint256 c2,,) = PriceTape.decode(afterSell[0]);

        // Same order of magnitude: token1 per token0 both times.
        assertApproxEqRel(c2, c1, 0.05e18, "a sell must not invert the quote");
    }

    function test_VolumeFromBothDirectionsAccumulatesInToken0() public {
        uint256 outB = _swapA(1000e18); // pays 1000 token0
        uint256 outA = _swapB(outB); // receives outA token0
        uint256[] memory bars = _fine(1);
        (,,,,, uint256 v, uint16 n) = PriceTape.decode(bars[0]);
        assertEq(n, 2);
        assertApproxEqRel(v, 1000e18 + outA, 1.2e11, "both legs counted in token0 terms");
    }

    function test_HighAndLowTrackTheSessionRange() public {
        _swapA(1000e18); // pushes price one way
        _swapA(50_000e18); // further
        _swapB(200_000e18); // back the other way

        uint256[] memory bars = _fine(1);
        (, uint256 o, uint256 h, uint256 l, uint256 c,, uint16 n) = PriceTape.decode(bars[0]);
        assertEq(n, 3);
        assertGe(h, o, "high covers the open");
        assertGe(h, c, "high covers the close");
        assertLe(l, o, "low covers the open");
        assertLe(l, c, "low covers the close");
        assertGt(h, l, "three trades that moved the pool cannot be flat");
    }

    function test_BarsRollOverWithTheClock() public {
        _swapA(1000e18);
        _warp(5 minutes);
        _swapA(1000e18);
        _warp(5 minutes);
        _swapA(1000e18);

        uint256[] memory bars = _fine(3);
        assertTrue(bars[0] != 0 && bars[1] != 0 && bars[2] != 0, "three buckets, three bars");
        assertEq(uint256(PriceTape.bucketOf(bars[0])), t / 5 minutes, "newest first");
        assertEq(uint256(PriceTape.bucketOf(bars[1])), t / 5 minutes - 1);
        assertEq(uint256(PriceTape.bucketOf(bars[2])), t / 5 minutes - 2);
    }

    function test_QuietBucketsAreHoles() public {
        _swapA(1000e18);
        _warp(20 minutes);
        _swapA(1000e18);

        uint256[] memory bars = _fine(5);
        assertTrue(bars[0] != 0, "newest");
        assertEq(bars[1], 0, "nobody traded");
        assertEq(bars[2], 0, "nobody traded");
        assertEq(bars[3], 0, "nobody traded");
        assertTrue(bars[4] != 0, "the earlier trade is still readable");
    }

    function test_CoarseTapeAggregatesWithoutExtraSwapCost() public {
        // Several fine buckets inside one four-hour bucket.
        for (uint256 i; i < 6; ++i) {
            _swapA(1000e18);
            _warp(5 minutes);
        }
        _swapA(1000e18);

        uint256[] memory coarse = pool.tape(pool.COARSE_PERIOD(), 1);
        (, uint256 o, uint256 h, uint256 l,,, uint16 n) = PriceTape.decode(coarse[0]);
        assertTrue(coarse[0] != 0, "the coarse tape must fill itself from finished fine bars");
        assertGe(h, o);
        assertLe(l, o);
        assertGe(n, 5, "the coarse bar counts the trades of every folded fine bar");
    }

    function test_HistorySurvivesAFullRingLap() public {
        // Older than the ring must read empty rather than as a stale lap.
        for (uint256 i; i < 260; ++i) {
            _swapA(100e18);
            _warp(5 minutes);
        }
        uint256[] memory bars = _fine(300);
        uint256 newest = t / 5 minutes;
        for (uint256 i; i < bars.length; ++i) {
            if (bars[i] == 0) continue;
            assertEq(uint256(PriceTape.bucketOf(bars[i])), newest - i, "a stale lap must never be served as current");
        }
    }

    // ------------------------------------------------------------------- gas

    /// @dev The number the whole design protects: what the tape adds to a swap.
    function test_Gas_TapeCostPerSwap() public {
        _swapA(1000e18); // open the bar so this is the steady-state case

        uint256 before = gasleft();
        _swapA(1000e18);
        uint256 withTape = before - gasleft();

        emit log_named_uint("swap gas with tape (steady state)", withTape);
        // One non-zero SSTORE is 5,000; the assertion is a ceiling on the whole
        // swap, so a regression that adds a second write is caught here.
        assertLt(withTape, 120_000, "a swap must not balloon because of the tape");
    }

    function test_Gas_RolloverSwapIsBounded() public {
        _swapA(1000e18);
        _warp(5 minutes);

        uint256 before = gasleft();
        _swapA(1000e18);
        uint256 rollover = before - gasleft();

        emit log_named_uint("swap gas on bucket rollover (ring + coarse fold)", rollover);
        assertLt(rollover, 200_000, "rollover is once per period but must stay bounded");
    }

    /// @dev The first lap writes each ring slot from zero (22,100); every lap
    ///      after reuses it (5,000). This measures the steady state, which is
    ///      what a pool actually lives in.
    function test_Gas_RolloverIsCheaperOnceTheRingHasLapped() public {
        for (uint256 i; i < 258; ++i) {
            _swapA(100e18);
            _warp(5 minutes);
        }
        uint256 before = gasleft();
        _swapA(100e18);
        uint256 lapped = before - gasleft();
        emit log_named_uint("rollover gas after the ring has lapped", lapped);
        assertLt(lapped, 60_000, "a reused ring slot must cost less than a fresh one");
    }

    function test_Gas_ReadingAChartIsFree() public {
        for (uint256 i; i < 12; ++i) {
            _swapA(1000e18);
            _warp(5 minutes);
        }
        uint256 before = gasleft();
        pool.tape(pool.FINE_PERIOD(), 96);
        uint256 used = before - gasleft();
        emit log_named_uint("gas to read 96 bars (eth_call, paid by nobody)", used);
    }
}
