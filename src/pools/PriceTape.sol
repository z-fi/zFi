// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title PriceTape
/// @notice Compressed on-chain OHLCV history: a chart any client can read with
///         `eth_call`, with no indexer, no subgraph and no trusted server.
/// @dev A public good, not a private feature. Any contract that knows the price
///      of something can adopt this by holding a `Tape` and calling `print` —
///      AMM pools, orderbooks, auctions, oracles. Readers only need
///      `IPriceTape` (below) and the pure decoders here, so one chart client
///      works against every adopter.
///
///      DESIGN
///      Logs are the usual home for trade history, but reading them requires an
///      indexer, which is exactly the centralised dependency a decentralised
///      exchange should not have. Storage is readable by anyone with an RPC
///      forever, so this pays gas to keep the data reachable from chain state.
///
///      The cost floor is one `SSTORE` per trade. Everything here exists to
///      avoid exceeding it:
///
///      - A bar is ONE slot, so a trade writes once and never grows.
///      - Prices are 4-byte floats (24-bit mantissa, 8-bit binary exponent):
///        ~7 significant digits over any range a real pair reaches, where
///        fixed-point would spend most of its bits on magnitudes that never
///        occur.
///      - The ring is indexed by `bucket % length`, so a bucket in which nobody
///        traded costs nothing and leaves a hole rather than a write.
///      - Ring slots are rewritten every lap, so after the first lap every
///        store is the 5,000-gas non-zero case, never the 22,100-gas init.
///
///      Coarse candles are exact aggregations of fine ones, so adopters should
///      keep one fine tape plus one coarse tape and let clients roll up the
///      rest. Storing a ring per timeframe would multiply the per-trade write,
///      which is the one number worth protecting.
library PriceTape {
    /// @dev A bar occupies a single 256-bit slot:
    ///
    ///      bits   0..31    bucket   uint32   unix / period, 0 means empty
    ///      bits  32..63    open     float32
    ///      bits  64..95    high     float32
    ///      bits  96..127   low      float32
    ///      bits 128..159   close    float32
    ///      bits 160..191   volume   float32  base-token volume in this bar
    ///      bits 192..207   count    uint16   trades, saturating
    ///      bits 208..255   unused
    ///
    ///      `open` is stored rather than inferred from the previous bar's close
    ///      because a ring with holes has no reliable previous bar.
    ///
    ///      The ring is a FIXED 256 entries rather than a dynamic array. A
    ///      dynamic ring costs a cold `SLOAD` of its length plus a bounds check
    ///      on every rollover, and buys nothing an adopter wants: the period is
    ///      still theirs to choose, and 256 bars is the useful depth at any of
    ///      them - 21 hours at five minutes, 42 days at four hours. Fixing it
    ///      also makes `bucket % 256` a mask, computes the slot without a
    ///      length read, and removes the two length stores from construction.
    /// @dev Ring depth. A power of two so the index is a mask, not a division.
    uint256 internal constant BARS = 256;

    struct Tape {
        /// @dev Bar currently accumulating; also the newest bar.
        uint256 live;
        /// @dev Finalised bars, indexed by `bucket % BARS`.
        uint256[BARS] ring;
    }

    /// @dev Trade counter saturates rather than wrapping into the volume field.
    uint256 internal constant MAX_COUNT = type(uint16).max;

    /// @notice Compress a value to a 4-byte float: `mantissa << exponent`.
    /// @dev Relative error is below 2**-23 (~1.2e-7), which is far finer than
    ///      any chart pixel, and the representable range covers every price a
    ///      1e18-scaled pair can produce.
    ///
    ///      IT TRUNCATES RATHER THAN ROUNDS, so the error is one-sided: every
    ///      packed value is at or below the real one, `high` included, where a
    ///      bias upward would be the conservative direction. Immaterial at
    ///      chart resolution and not worth the branch, but it is a bias and not
    ///      the symmetric error the bound above sounds like.
    ///
    ///      `pack(0) == 0`, and that interacts with `low`. A bar whose `low`
    ///      takes a zero can never be raised again - `if (p < lowP)` will not
    ///      lift it - so a single trade whose price underflows the 1e18 scale
    ///      pins the bar's low at zero for its whole life and `fold` carries it
    ///      into the coarse candle. On an adopter whose prices can legitimately
    ///      round to zero that turns "charts flat" into "charts a spike to
    ///      zero".
    function pack(uint256 v) internal pure returns (uint32) {
        if (v == 0) return 0;
        uint256 msb = _msb(v);
        if (msb < 24) return uint32(v); // exponent 0, exact
        uint256 shift;
        unchecked {
            shift = msb - 23; // keep 24 significant bits
        }
        return uint32((shift << 24) | (v >> shift));
    }

    /// @notice Expand a 4-byte float back to an integer.
    /// @dev Lossy in the low bits by construction; never reverts.
    ///
    ///      TOTAL ONLY BECAUSE `pack` IS ITS SOLE PRODUCER. The shift is
    ///      unchecked, and `pack` can never emit an exponent above 232 - the
    ///      msb of a uint256 is at most 255 and it keeps 23 - so the worst case
    ///      is `(2**24 - 1) << 232`, just under 2**256. `decode` is advertised
    ///      as a reader for ANY adopter's bars, so a client feeding it a
    ///      hand-built word rather than one this library produced is outside
    ///      that argument and can wrap.
    function unpack(uint32 p) internal pure returns (uint256) {
        unchecked {
            return uint256(p & 0xffffff) << (p >> 24);
        }
    }

    /// @notice Index of the highest set bit of a non-zero value.
    function _msb(uint256 x) private pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            r := or(r, shl(2, lt(0xf, shr(r, x))))
            r := or(r, shl(1, lt(0x3, shr(r, x))))
            r := or(r, lt(0x1, shr(r, x)))
        }
    }

    // ------------------------------------------------------------------ codec

    function encode(uint32 bucket, uint32 open, uint32 high, uint32 low, uint32 close, uint32 volume, uint16 count)
        internal
        pure
        returns (uint256 bar)
    {
        unchecked {
            bar = uint256(bucket) | (uint256(open) << 32) | (uint256(high) << 64) | (uint256(low) << 96)
                | (uint256(close) << 128) | (uint256(volume) << 160) | (uint256(count) << 192);
        }
    }

    function bucketOf(uint256 bar) internal pure returns (uint32) {
        return uint32(bar);
    }

    /// @notice Decode a bar into chart-ready integers.
    /// @dev `bucket == 0` marks an empty slot; the other fields are then zero.
    function decode(uint256 bar)
        internal
        pure
        returns (uint32 bucket, uint256 open, uint256 high, uint256 low, uint256 close, uint256 volume, uint16 count)
    {
        bucket = uint32(bar);
        open = unpack(uint32(bar >> 32));
        high = unpack(uint32(bar >> 64));
        low = unpack(uint32(bar >> 96));
        close = unpack(uint32(bar >> 128));
        volume = unpack(uint32(bar >> 160));
        count = uint16(bar >> 192);
    }

    // ------------------------------------------------------------------ write

    /// @notice Record a trade at `price` for `volume` of the base token.
    /// @dev Exactly one storage write in the common case, plus one more on the
    ///      first trade of a new bucket. `price` is the EXECUTED price — what
    ///      actually traded, including fee and slippage — which is what a tape
    ///      should show, rather than an untradeable mid.
    /// @param period Bar width in seconds; must be non-zero.
    ///
    ///        THE BUCKET IS A uint32 OF `block.timestamp / period`, so the
    ///        period an adopter picks decides when the tape wraps. At five
    ///        minutes that is somewhere past the year 40,000; at `period = 1`
    ///        it is 2106. This is a public-good library and the choice is the
    ///        adopter's, so it is stated here rather than assumed away.
    ///        `fold` casts to `uint32` on the same arithmetic and truncates
    ///        silently if anyone ever folds with `srcPeriod > period`.
    /// @return finalised The bar just closed and moved to the ring, or zero if
    ///         this trade landed in the bar already open. Adopters cascade this
    ///         into a coarser tape with `fold`, which is what keeps a trade at
    ///         one write no matter how many timeframes are kept.
    function print(Tape storage self, uint256 price, uint256 volume, uint256 period)
        internal
        returns (uint256 finalised)
    {
        uint32 bucket = uint32(block.timestamp / period);
        // Bucket 0 marks an empty slot, so never write one. Only reachable in
        // the first `period` seconds of 1970, i.e. tests with a zeroed clock.
        if (bucket == 0) return 0;

        uint256 live = self.live;
        uint32 p = pack(price);

        if (bucketOf(live) != bucket) {
            // Roll the finished bar into the ring, then open a fresh one. A
            // ring position is reused every lap, so this store is the cheap
            // non-zero case once the tape has run for one full lap.
            if (live != 0) {
                self.ring[bucketOf(live) & (BARS - 1)] = live;
                finalised = live;
            }
            self.live = encode(bucket, p, p, p, p, pack(volume), 1);
            return finalised;
        }

        // Update the extremes IN PACKED SPACE. The float format is
        // `exponent << 24 | mantissa` with the mantissa normalised to 24 bits,
        // which makes the packed integer MONOTONIC in the value it encodes: a
        // larger exponent always outranks a smaller one, equal exponents
        // compare by mantissa, and any value below 2**24 encodes with exponent
        // zero and so sorts below every value above it. Comparing packed
        // therefore gives exactly the same answer as comparing unpacked, while
        // avoiding the unpack-compare-repack round trip for open, high, and
        // low. Only volume needs real arithmetic, so only volume is expanded.
        uint32 openP = uint32(live >> 32);
        uint32 highP = uint32(live >> 64);
        uint32 lowP = uint32(live >> 96);
        if (p > highP) highP = p;
        // `low` starts at the bar's open, so it is only zero for a zero price.
        if (p < lowP) lowP = p;

        uint256 vol = unpack(uint32(live >> 160));
        uint16 count = uint16(live >> 192);
        unchecked {
            self.live = encode(
                bucket, openP, highP, lowP, p, pack(vol + volume), count < MAX_COUNT ? count + 1 : uint16(MAX_COUNT)
            );
        }
    }

    /// @notice Merge a finished bar from a finer tape into this coarser one.
    /// @dev Aggregating is exact: a four-hour candle built from forty-eight
    ///      five-minute candles is the same candle the trades would have
    ///      produced directly. So a coarse tape costs one write per FINE bar,
    ///      not one per trade, and keeping several timeframes stays affordable.
    /// @param bar A bar returned by `print` on the finer tape.
    /// @param srcPeriod The finer tape's bar width, to recover the wall clock.
    /// @param period This tape's bar width.
    /// @return finalised The coarse bar just closed, for cascading further.
    function fold(Tape storage self, uint256 bar, uint256 srcPeriod, uint256 period)
        internal
        returns (uint256 finalised)
    {
        if (bar == 0 || period == 0 || srcPeriod == 0) return 0;
        uint32 bucket = uint32((uint256(bucketOf(bar)) * srcPeriod) / period);
        if (bucket == 0) return 0;

        // Same packed-space treatment as `print`: the source bar's fields are
        // already in this format, so a fold is masks and comparisons rather
        // than a decode and a re-encode. Volume alone is expanded, because
        // summing it is real arithmetic.
        uint32 oP = uint32(bar >> 32);
        uint32 hP = uint32(bar >> 64);
        uint32 lP = uint32(bar >> 96);
        uint32 cP = uint32(bar >> 128);
        uint256 v = unpack(uint32(bar >> 160));
        uint16 n = uint16(bar >> 192);

        uint256 live = self.live;
        if (bucketOf(live) != bucket) {
            if (live != 0) {
                self.ring[bucketOf(live) & (BARS - 1)] = live;
                finalised = live;
            }
            self.live = encode(bucket, oP, hP, lP, cP, pack(v), n);
            return finalised;
        }

        uint32 openP = uint32(live >> 32);
        uint32 highP = uint32(live >> 64);
        uint32 lowP = uint32(live >> 96);
        if (hP > highP) highP = hP;
        if (lP < lowP) lowP = lP;

        uint256 vol = unpack(uint32(live >> 160));
        uint16 count = uint16(live >> 192);
        unchecked {
            uint256 total = uint256(count) + n;
            self.live = encode(
                bucket, openP, highP, lowP, cP, pack(vol + v), total < MAX_COUNT ? uint16(total) : uint16(MAX_COUNT)
            );
        }
    }

    // ------------------------------------------------------------------- read

    /// @notice The newest `count` bars, newest first, as raw packed slots.
    /// @dev Buckets with no trades are returned as zero, so a caller can tell a
    ///      flat market from an idle one. Callers decode with `decode`.
    function recent(Tape storage self, uint256 period, uint256 count) internal view returns (uint256[] memory bars) {
        // Bounded before allocating. `count` arrives from the caller through
        // `IPriceTape.tape`, and a large one blows memory before the loop even
        // starts. Nothing above the ring depth can be anything but zero, so the
        // excess was never information - it was only a way to make a `view`
        // that other contracts read run out of gas.
        if (count > BARS) count = BARS;
        bars = new uint256[](count);
        if (count == 0 || period == 0) return bars;

        uint256 live = self.live;
        uint256 newest = uint256(uint32(block.timestamp / period));

        // A DORMANT POOL'S LAST BAR IS IN NEITHER PLACE, so return it here or
        // it is unreachable. The live bar only reaches the ring when the NEXT
        // trade finalises it, and the walk below matches buckets against the
        // wall clock - so once trading stops and `newest` advances past it, the
        // final bar is not in the window and not in the ring. Past `BARS`
        // periods of quiet its slot has been lapped or never written, and no
        // value of `count` recovers it.
        //
        // That is exactly the case the zero-encoding exists to distinguish: a
        // reader could not tell "never traded" from "traded, then went quiet",
        // which is the one question a chart of a dormant market has to answer.
        //
        // Placing it at index 0 does not corrupt the time axis, because every
        // bar carries its own `bucket` and a client reads position from that
        // rather than from the array index. The index is newest-first ordering,
        // not a timestamp.
        if (live != 0 && bucketOf(live) < newest - (newest < count ? newest : count - 1)) {
            bars[0] = live;
            return bars;
        }

        for (uint256 i; i != count; ++i) {
            if (i > newest) break; // before the epoch of this period
            uint256 bucket = newest - i;
            if (bucket == bucketOf(live) && live != 0) {
                bars[i] = live;
                continue;
            }
            // Bucket zero is never written, so it can never match a slot.
            if (bucket == 0) continue;
            uint256 bar = self.ring[bucket & (BARS - 1)];
            // A ring slot holds whatever bucket last mapped to it, which may be
            // a full lap old. Only accept it if it is the bucket asked for.
            if (bucketOf(bar) == bucket) bars[i] = bar;
        }
    }
}

/// @title IPriceTape
/// @notice Minimal read interface for charting any adopting contract.
///
/// @dev NOT AN ORACLE. A tape records what an adopter printed, and an adopter
///      prints executed trades - so a bar costs whatever the smallest trade on
///      that venue costs, and `high`/`low` are extrema that one such trade
///      fixes for the life of the bar. Nothing here is time-weighted, nothing
///      is manipulation-resistant, and an adopter is free to print whatever it
///      likes. Read it to draw a candlestick. Do not settle, liquidate,
///      collateralise, or price anything against it.
/// @dev Deliberately tiny: one call returns everything a candlestick chart
///      needs. A client that speaks this interface can chart every adopter
///      without knowing anything else about them, which is what makes this a
///      standard rather than one protocol's feature.
interface IPriceTape {
    /// @notice Bar widths this contract records, in seconds, finest first.
    function tapePeriods() external view returns (uint256[] memory);

    /// @notice The newest `count` bars for `period`, newest first, packed.
    /// @dev Zero entries are buckets in which nothing traded. Decode with
    ///      `PriceTape.decode`: (bucket, open, high, low, close, volume, count).
    ///
    ///      Prices are RAW `token1` per RAW `token0`, scaled by 1e18, so a bar
    ///      is direction-free. Token decimals are NOT normalised: a client
    ///      charting a non-18-decimal pair must apply the decimal difference
    ///      itself, from `tapePair()`. (An earlier version of this line claimed
    ///      the opposite; the adopters never did it, and the doc is the spec for
    ///      an interface whose whole point is that one client reads every
    ///      implementation, so it is the doc that was wrong.)
    ///
    ///      Volume is in `token0` units, and it is a LOWER BOUND rather than a
    ///      measurement. Each accumulation re-packs the running total into the
    ///      24-bit mantissa of a float32, so once a bar's total passes 2**n an
    ///      individual trade below 2**(n-24) adds exactly zero, and `fold`
    ///      compounds the same truncation into the coarse bar. The relative
    ///      error is under ~1.2e-7 per accumulation and invisible on a chart,
    ///      which is what this field is for; do not settle anything against it.
    ///
    ///      A COARSE BAR LAGS BY ONE FINE BAR. Coarse bars are folded from fine
    ///      bars only as those finish, so the live fine bar - up to one fine
    ///      period of the most recent trading - is never included in the coarse
    ///      tape. Read the fine tape for the leading edge.
    function tape(uint256 period, uint256 count) external view returns (uint256[] memory);

    /// @notice The pair a tape prices, as (base, quote). Native asset is address(0).
    function tapePair() external view returns (address base, address quote);
}
