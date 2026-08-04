// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {PriceTape} from "../src/pools/PriceTape.sol";

/// @dev The library is the part other protocols would adopt, so it is tested
///      standalone rather than only through a pool.
contract TapeHarness {
    using PriceTape for PriceTape.Tape;

    PriceTape.Tape internal fine;
    PriceTape.Tape internal coarse;

    /// @dev Ring depth is fixed by the library now, so the old per-fixture
    ///      bar counts are gone. The constructor is kept so existing call sites
    ///      still compile; the arguments are accepted and ignored.
    constructor(uint256, uint256) {}

    function print(uint256 price, uint256 volume, uint256 period) external returns (uint256) {
        return fine.print(price, volume, period);
    }

    function printCascade(uint256 price, uint256 volume, uint256 srcPeriod, uint256 dstPeriod) external {
        uint256 done = fine.print(price, volume, srcPeriod);
        if (done != 0) coarse.fold(done, srcPeriod, dstPeriod);
    }

    function recent(uint256 period, uint256 count) external view returns (uint256[] memory) {
        return fine.recent(period, count);
    }

    function recentCoarse(uint256 period, uint256 count) external view returns (uint256[] memory) {
        return coarse.recent(period, count);
    }

    function live() external view returns (uint256) {
        return fine.live;
    }
}

contract PriceTapeTest is Test {
    uint256 constant PERIOD = 5 minutes;
    uint256 constant COARSE = 4 hours;
    uint256 constant BARS = 256;

    TapeHarness tape;

    /// @dev Time is tracked explicitly rather than read back from
    ///      `block.timestamp`. The optimiser treats TIMESTAMP as constant within
    ///      a call and common-subexpression-eliminates repeated reads, so
    ///      `vm.warp(block.timestamp + P)` twice warps to the SAME instant and
    ///      the clock silently stops. That made bucket rollovers never happen.
    uint256 internal t;

    function setUp() public {
        tape = new TapeHarness(BARS, BARS);
        t = 1_700_000_000; // a realistic clock; bucket 0 is a sentinel
        vm.warp(t);
    }

    function _warp(uint256 dt) internal {
        t += dt;
        vm.warp(t);
    }

    // ------------------------------------------------------------ float codec

    function test_PackRoundTripsWithinTolerance() public pure {
        uint256[7] memory vs = [
            uint256(1),
            12345,
            1e18,
            3000e18,
            1e36,
            type(uint128).max,
            123456789012345678901234567890
        ];
        for (uint256 i; i < vs.length; ++i) {
            uint256 got = PriceTape.unpack(PriceTape.pack(vs[i]));
            // Relative error must stay under 2**-23.
            uint256 diff = vs[i] > got ? vs[i] - got : got - vs[i];
            assertLe(diff * (1 << 23), vs[i], "relative error above 2**-23");
            assertLe(got, vs[i], "packing must never round a price up");
        }
    }

    function test_PackIsExactForSmallValues() public pure {
        for (uint256 v; v < 1 << 24; v += 7919) {
            assertEq(PriceTape.unpack(PriceTape.pack(v)), v, "values under 2**24 must be exact");
        }
    }

    function test_PackZero() public pure {
        assertEq(PriceTape.pack(0), 0);
        assertEq(PriceTape.unpack(0), 0);
    }

    function testFuzz_PackNeverOverflowsAndKeepsPrecision(uint256 v) public pure {
        uint32 p = PriceTape.pack(v);
        uint256 got = PriceTape.unpack(p);
        if (v == 0) {
            assertEq(got, 0);
            return;
        }
        assertLe(got, v, "must round down, never up");
        uint256 diff = v - got;
        assertLe(diff * (1 << 23), v, "relative error above 2**-23");
    }

    function testFuzz_PackIsMonotonic(uint256 a, uint256 b) public pure {
        // A chart that inverts two prices is worse than one that rounds them.
        if (a > b) (a, b) = (b, a);
        assertLe(PriceTape.unpack(PriceTape.pack(a)), PriceTape.unpack(PriceTape.pack(b)));
    }

    // ------------------------------------------------------------- bar codec

    function test_EncodeDecodeRoundTrip() public pure {
        uint256 bar = PriceTape.encode(
            uint32(123), PriceTape.pack(10e18), PriceTape.pack(30e18), PriceTape.pack(5e18), PriceTape.pack(20e18), PriceTape.pack(7e18), 42
        );
        (uint32 bucket, uint256 o, uint256 h, uint256 l, uint256 c, uint256 v, uint16 n) = PriceTape.decode(bar);
        assertEq(bucket, 123);
        assertApproxEqRel(o, 10e18, 1.2e11);
        assertApproxEqRel(h, 30e18, 1.2e11);
        assertApproxEqRel(l, 5e18, 1.2e11);
        assertApproxEqRel(c, 20e18, 1.2e11);
        assertApproxEqRel(v, 7e18, 1.2e11);
        assertEq(n, 42);
    }

    function test_FieldsDoNotBleedIntoEachOther() public pure {
        // Every field at its maximum at once: no field may corrupt a neighbour.
        uint256 bar = PriceTape.encode(
            type(uint32).max, type(uint32).max, type(uint32).max, type(uint32).max, type(uint32).max, type(uint32).max, type(uint16).max
        );
        (uint32 bucket,,,,,, uint16 n) = PriceTape.decode(bar);
        assertEq(bucket, type(uint32).max);
        assertEq(n, type(uint16).max);
    }

    // ----------------------------------------------------------------- prints

    function test_FirstPrintOpensABar() public {
        tape.print(100e18, 5e18, PERIOD);
        uint256[] memory bars = tape.recent(PERIOD, 1);
        (uint32 bucket, uint256 o, uint256 h, uint256 l, uint256 c, uint256 v, uint16 n) = PriceTape.decode(bars[0]);
        assertEq(bucket, uint32(t / PERIOD));
        assertApproxEqRel(o, 100e18, 1.2e11);
        assertApproxEqRel(h, 100e18, 1.2e11);
        assertApproxEqRel(l, 100e18, 1.2e11);
        assertApproxEqRel(c, 100e18, 1.2e11);
        assertApproxEqRel(v, 5e18, 1.2e11);
        assertEq(n, 1);
    }

    function test_BarTracksHighLowCloseAndVolume() public {
        tape.print(100e18, 1e18, PERIOD);
        tape.print(150e18, 2e18, PERIOD);
        tape.print(50e18, 3e18, PERIOD);
        tape.print(120e18, 4e18, PERIOD);

        uint256[] memory bars = tape.recent(PERIOD, 1);
        (, uint256 o, uint256 h, uint256 l, uint256 c, uint256 v, uint16 n) = PriceTape.decode(bars[0]);
        assertApproxEqRel(o, 100e18, 1.2e11, "open is the first trade");
        assertApproxEqRel(h, 150e18, 1.2e11, "high");
        assertApproxEqRel(l, 50e18, 1.2e11, "low");
        assertApproxEqRel(c, 120e18, 1.2e11, "close is the last trade");
        assertApproxEqRel(v, 10e18, 1.2e11, "volume sums");
        assertEq(n, 4, "trade count");
    }

    function test_RolloverMovesTheBarIntoTheRing() public {
        tape.print(100e18, 1e18, PERIOD);
        _warp(PERIOD);
        tape.print(200e18, 2e18, PERIOD);

        uint256[] memory bars = tape.recent(PERIOD, 2);
        (,,,, uint256 newClose,,) = PriceTape.decode(bars[0]);
        (,,,, uint256 oldClose,,) = PriceTape.decode(bars[1]);
        assertApproxEqRel(newClose, 200e18, 1.2e11, "newest first");
        assertApproxEqRel(oldClose, 100e18, 1.2e11, "the finished bar is retrievable");
    }

    function test_IdleBucketsAreHolesNotWrites() public {
        tape.print(100e18, 1e18, PERIOD);
        _warp(PERIOD * 3);
        tape.print(200e18, 1e18, PERIOD);

        uint256[] memory bars = tape.recent(PERIOD, 4);
        assertTrue(bars[0] != 0, "newest bar");
        assertEq(bars[1], 0, "no trades, no bar");
        assertEq(bars[2], 0, "no trades, no bar");
        assertTrue(bars[3] != 0, "the older bar is still there");
    }

    function test_RingWrapsAndDiscardsStaleBars() public {
        // Fill the ring exactly once, one bar per bucket.
        for (uint256 i; i <= BARS; ++i) {
            tape.print((i + 1) * 1e18, 1e18, PERIOD);
            _warp(PERIOD);
        }
        tape.print(9999e18, 1e18, PERIOD);

        // Ask for more than the ring holds: entries older than one lap must read
        // as empty rather than as a bar from the previous lap.
        uint256[] memory bars = tape.recent(PERIOD, BARS + 8);
        for (uint256 i; i < bars.length; ++i) {
            if (bars[i] == 0) continue;
            uint32 bucket = PriceTape.bucketOf(bars[i]);
            uint256 expected = (t / PERIOD) - i;
            assertEq(uint256(bucket), expected, "a stale lap must never be served as current");
        }
    }

    function test_RecentIsNewestFirstAndBucketAligned() public {
        for (uint256 i; i < 5; ++i) {
            tape.print((i + 1) * 10e18, 1e18, PERIOD);
            _warp(PERIOD);
        }
        uint256[] memory bars = tape.recent(PERIOD, 5);
        uint256 newest = t / PERIOD;
        for (uint256 i; i < bars.length; ++i) {
            if (bars[i] == 0) continue;
            assertEq(uint256(PriceTape.bucketOf(bars[i])), newest - i, "bucket must match its position");
        }
    }

    // ------------------------------------------------------------------ folds

    function test_CoarseBarAggregatesFineBarsExactly() public {
        // Three fine bars inside one coarse bucket.
        tape.printCascade(100e18, 1e18, PERIOD, COARSE);
        tape.printCascade(300e18, 1e18, PERIOD, COARSE);
        _warp(PERIOD);
        tape.printCascade(50e18, 2e18, PERIOD, COARSE);
        _warp(PERIOD);
        tape.printCascade(120e18, 3e18, PERIOD, COARSE);
        _warp(PERIOD);
        tape.printCascade(130e18, 4e18, PERIOD, COARSE);

        uint256[] memory bars = tape.recentCoarse(COARSE, 1);
        (, uint256 o, uint256 h, uint256 l,, uint256 v, uint16 n) = PriceTape.decode(bars[0]);
        // The last fine bar is still live, so the coarse bar covers the first three.
        assertApproxEqRel(o, 100e18, 1.2e11, "coarse open is the first fine open");
        assertApproxEqRel(h, 300e18, 1.2e11, "coarse high is the max fine high");
        assertApproxEqRel(l, 50e18, 1.2e11, "coarse low is the min fine low");
        assertApproxEqRel(v, 7e18, 1.2e11, "coarse volume sums the folded fine volume");
        assertEq(n, 4, "counts sum");
    }

    function test_FoldIgnoresAnEmptyBar() public {
        tape.printCascade(100e18, 1e18, PERIOD, COARSE);
        uint256[] memory bars = tape.recentCoarse(COARSE, 1);
        assertEq(bars[0], 0, "nothing has been folded yet, so no coarse bar exists");
    }

    // ------------------------------------------------------------------- gas

    /// @dev The number this whole design exists to protect. A steady-state
    ///      print must be one non-zero storage write and nothing more.
    function test_Gas_SteadyStatePrintIsOneStore() public {
        tape.print(100e18, 1e18, PERIOD); // open the bar

        uint256 before = gasleft();
        tape.print(101e18, 1e18, PERIOD);
        uint256 used = before - gasleft();

        emit log_named_uint("steady-state print gas (incl. external call)", used);
        assertLt(used, 12_000, "a print must stay near the one-SSTORE floor");
    }

    function test_Gas_RolloverStaysBounded() public {
        tape.print(100e18, 1e18, PERIOD);
        _warp(PERIOD);

        uint256 before = gasleft();
        tape.printCascade(101e18, 1e18, PERIOD, COARSE);
        uint256 used = before - gasleft();

        emit log_named_uint("rollover + coarse fold gas", used);
        assertLt(used, 90_000, "rollover happens once per period, but must not be unbounded");
    }
}
