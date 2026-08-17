// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "../lib/solady/src/utils/FixedPointMathLib.sol";
import {PriceTape} from "../src/pools/PrecisionPool.sol";

/// @dev Direct unit test of the `_seed` token0 rounding, isolated from the
/// pool. Going through `createAndSeed` cannot pin this: the overshoot surfaced
/// as `InsufficientLiquidity`, which is also what a legitimately unseedable
/// configuration returns, so an end-to-end test cannot tell the bug from a
/// correct refusal. Replicating the two lines here can.
///
/// The property: `_seed` derives `lp` by flooring from `in0`, then recomputes
/// what that `lp` requires. That requirement must never exceed `in0`, or a
/// seeder who sized their deposit from the same formula is refused for
/// arithmetic that was correct.
contract PrecisionSeedRoundingTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant MAX_SQRT_PRICE = 1e36;

    /// @dev How `_seed` derives liquidity from the token0 side (the `s == sl`
    ///      branch and the `lpFrom0` term are the same expression).
    function _lpFrom0(uint256 in0, uint256 s, uint256 sh) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(in0, s, sh - s), sh, WAD);
    }

    /// @dev The shipped requirement: one fused ceiling.
    function _used0Fused(uint256 lp, uint256 s, uint256 sh) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(lp, (sh - s) * WAD, sh * s);
    }

    /// @dev What it used to be: two nested ceilings.
    function _used0Nested(uint256 lp, uint256 s, uint256 sh) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(FixedPointMathLib.fullMulDivUp(lp, sh - s, sh), WAD, s);
    }

    /// @dev The fix, stated as the property it guarantees. `lp` floors down
    ///      from `in0`, so the exact requirement `lp*(sh-s)*WAD/(sh*s)` is at
    ///      most `in0`; `in0` is an integer, so its ceiling is at most `in0`
    ///      too. One ceiling preserves that. Two do not.
    function testFuzz_FusedRequirementNeverExceedsWhatDerivedIt(uint96 rawIn0, uint64 rawS, uint64 rawSpan)
        public
        pure
    {
        uint256 s = bound(uint256(rawS), 1, 1e18);
        uint256 sh = s + bound(uint256(rawSpan), 1, 1e18);
        if (sh > MAX_SQRT_PRICE) return;
        uint256 in0 = bound(uint256(rawIn0), 1, type(uint96).max);

        uint256 lp = _lpFrom0(in0, s, sh);
        if (lp == 0) return;

        uint256 fused = _used0Fused(lp, s, sh);
        assertLe(fused, in0, "fused requirement outgrew the amount it was derived from");
    }

    /// @dev The bug is real, not theoretical: the old expression exceeds `in0`
    ///      at concrete, ordinary-looking parameters. Without this the fix
    ///      above would be unfalsifiable - a test that only ever confirms the
    ///      new code proves nothing about what it replaced.
    ///      Found by search, not by hand: round parameters divide evenly and
    ///      hide it. Across 400k sampled configurations the old expression
    ///      demanded more than it was given in roughly a THIRD of them, with a
    ///      worst observed overshoot near 2e15 raw units. The fused form
    ///      overshot in none.
    function test_TheNestedRoundingActuallyOvershot() public {
        uint256 in0 = 9_640_902_090_728_406_646_457;
        uint256 s = 10_120_968_492;
        uint256 sh = 578_223_503_975;

        uint256 lp = _lpFrom0(in0, s, sh);
        assertGt(lp, 0, "no liquidity to test with");

        uint256 nested = _used0Nested(lp, s, sh);
        uint256 fused = _used0Fused(lp, s, sh);

        assertGt(nested, in0, "expected the old rounding to demand more than was offered");
        assertLe(fused, in0, "the fused rounding must stay within it");
        emit log_named_uint("overshoot in raw units", nested - in0);
    }

    /// @dev The fused value must still be an upper bound on the true
    ///      requirement - tightening it must not underfund the pool. Ceiling
    ///      means `fused * sh * s >= lp * (sh - s) * WAD`.
    function testFuzz_FusedRequirementStillCoversTheCurve(uint96 rawLp, uint64 rawS, uint64 rawSpan) public pure {
        uint256 s = bound(uint256(rawS), 1, 1e18);
        uint256 sh = s + bound(uint256(rawSpan), 1, 1e18);
        if (sh > MAX_SQRT_PRICE) return;
        uint256 lp = bound(uint256(rawLp), 1, type(uint96).max);

        uint256 fused = _used0Fused(lp, s, sh);
        // Recompute the exact requirement as a floor and require the ceiling to
        // sit at or above it.
        uint256 floored = FixedPointMathLib.fullMulDiv(lp, (sh - s) * WAD, sh * s);
        assertGe(fused, floored, "ceiling fell below the floor");
        // And it must never be more than one raw unit above it.
        assertLe(fused - floored, 1, "not a ceiling");
    }

    // ---------------------------------------------------------- PRICE TAPE

    /// @dev A reviewer flagged that `_record` is NOT wrapped the way
    ///      `_afterSwap` is, so anything in the tape that reverts brings the
    ///      swap down with it - permanently, on an immutable pool. The specific
    ///      worry was the printed price: raw `token1/token0 * 1e18` reaches
    ///      `sqrtPHigh^2` = 1e72 for a legal band, about 239 bits, which a
    ///      narrower packed field would truncate or reject.
    ///
    ///      It holds, but by a margin worth pinning rather than reasoning
    ///      about. `pack` is a 24-bit mantissa with an 8-bit exponent: the
    ///      shift is `msb - 23`, and `msb <= 255` for any uint256, so the
    ///      exponent never exceeds 232 and always fits its field. There is no
    ///      input on which it reverts or wraps.
    function testFuzz_PackNeverRevertsOrWrapsForAnyPrice(uint256 v) public pure {
        uint32 packed = PriceTape.pack(v);
        uint256 back = PriceTape.unpack(packed);
        // Lossy downward by construction, never upward: a bar must not claim a
        // price above the one that traded.
        assertLe(back, v, "unpack exceeded the value packed");
        if (v < 1 << 24) assertEq(back, v, "small values must be exact");
        else assertGe(back, v - (v >> 23), "relative error worse than 2^-23");
    }

    /// @dev The specific magnitudes the band permits, including the extreme.
    function test_PackHandlesTheWholeLegalPriceRange() public pure {
        uint256[5] memory prices = [uint256(1), 1e18, 1e30, 1e72, type(uint256).max];
        for (uint256 i; i < prices.length; ++i) {
            uint256 back = PriceTape.unpack(PriceTape.pack(prices[i]));
            assertLe(back, prices[i], "overstated the price");
            assertGt(PriceTape.pack(prices[i]), 0, "packed a nonzero price to zero");
        }
        // 1e72 is the squared ceiling of a maximal band; confirm it round-trips
        // to within the mantissa's precision rather than saturating.
        uint256 big = PriceTape.unpack(PriceTape.pack(1e72));
        assertGt(big, 1e72 - (1e72 >> 23), "1e72 lost more than the mantissa allows");
    }
}
