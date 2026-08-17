// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";
import {PrecisionPoolFactory} from "./PrecisionPoolFactory.sol";
import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PrecisionLiquidityLens
/// @notice Read-only previews for the LP side: seeding, adding, removing, and
///         choosing a zap split.
///
/// @dev WHY A SECOND LENS RATHER THAN MORE OF THE FIRST. `PrecisionPoolLens` is
///      deployed and verified against its exact source; extending that file
///      would leave a live address no longer reproducing from the repo. Views
///      hold nothing and are referenced by no contract, so a second one costs a
///      deployment and nothing else.
///
///      WHY THESE EXIST AT ALL. The swap side was already answerable - `quote`,
///      `maxAmountIn`, `quoteRoute` - but every question an add/remove screen
///      asks was not, and answering them off-chain means reimplementing the
///      most rounding-sensitive arithmetic in the pool. `_seed` alone floors the
///      liquidity, ceils the requirement through a fused division, and then
///      applies two bound corrections that can each move the result. A frontend
///      that gets it wrong does not get a warning; it gets a revert, or an
///      opening price nobody chose.
///
///      NOTHING HERE REVERTS ON A REFUSAL. Each preview returns `ok = false`
///      with zeroed amounts where the pool would reject, so a UI can grey a
///      button out instead of discovering the problem in a simulation. They do
///      still revert on genuinely malformed input - an address that is not a
///      pool of this factory - because that is a bug in the caller, not a
///      condition to render.
///
///      THESE MIRROR THE POOL, THEY DO NOT APPROXIMATE IT. Same rounding
///      directions, same order of operations, same guards. A preview that is
///      even one unit off on `used0` is worse than no preview, because it will
///      be believed. Where the pool's arithmetic is subtle the comment here
///      says which line it is mirroring.
contract PrecisionLiquidityLens {
    uint256 constant WAD = 1e18;
    uint256 constant MIN_LIQUIDITY = 1000;
    uint256 constant MIN_RESOLUTION = 1e6;
    uint256 constant MAX_LIQUIDITY = type(uint128).max;
    uint256 constant SEED_PRICE_TOLERANCE = 100;

    PrecisionPoolFactory public immutable factory;

    error BadFactory();
    error NoPool();

    constructor(PrecisionPoolFactory factory_) {
        if (address(factory_) == address(0) || address(factory_).code.length == 0) revert BadFactory();
        factory = factory_;
    }

    /// @dev Loaded pool state, read once per preview.
    struct Band {
        uint256 supply;
        uint256 r0;
        uint256 r1;
        uint256 sl;
        uint256 sh;
    }

    function _band(address pool) internal view returns (Band memory b) {
        if (!factory.isPool(pool)) revert NoPool();
        PrecisionPool p = PrecisionPool(payable(pool));
        b.supply = p.totalSupply();
        (b.r0, b.r1) = (p.reserve0(), p.reserve1());
        (b.sl, b.sh) = (p.sqrtPLow(), p.sqrtPHigh());
    }

    function _virtual0(uint256 liquidity, uint256 hi) internal pure returns (uint256) {
        unchecked {
            return liquidity * WAD / hi;
        }
    }

    function _virtual1(uint256 liquidity, uint256 lo) internal pure returns (uint256) {
        unchecked {
            return liquidity * lo / WAD;
        }
    }

    // ------------------------------------------------------------------ SEED

    /// @notice What an initial deposit would mint and consume.
    /// @dev Mirrors `PrecisionPool._seed` line for line, including the fused
    ///      single ceiling on `used0` and both bound corrections, then applies
    ///      the caller-facing guards `_addLiquidity` imposes on a seed: the
    ///      resolution floor and the seed-price tolerance.
    /// @return ok False when the pool would refuse this seed.
    /// @return lp Shares minted to the depositor, already net of the permanent
    ///         `MIN_LIQUIDITY` burned to the dead address.
    function previewSeed(address pool, uint256 sqrtPriceInit, uint256 amount0, uint256 amount1)
        public
        view
        returns (bool ok, uint256 lp, uint256 used0, uint256 used1)
    {
        Band memory b = _band(pool);
        if (b.supply != 0) return (false, 0, 0, 0);
        if (sqrtPriceInit < b.sl || sqrtPriceInit > b.sh) return (false, 0, 0, 0);

        uint256 s = sqrtPriceInit;
        uint256 total;
        if (s == b.sl) {
            total = FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(amount0, s, b.sh - s), b.sh, WAD);
        } else if (s == b.sh) {
            total = FixedPointMathLib.fullMulDiv(amount1, WAD, s - b.sl);
        } else {
            uint256 f0 = FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(amount0, s, b.sh - s), b.sh, WAD);
            uint256 f1 = FixedPointMathLib.fullMulDiv(amount1, WAD, s - b.sl);
            total = FixedPointMathLib.min(f0, f1);
        }
        if (total == 0 || total > MAX_LIQUIDITY) return (false, 0, 0, 0);

        // One fused ceiling, as the pool does. Two nested ones overshoot by up
        // to `WAD / s` and would report a requirement the pool will not ask for.
        used0 = FixedPointMathLib.fullMulDivUp(total, (b.sh - s) * WAD, b.sh * s);
        used1 = FixedPointMathLib.fullMulDivUp(total, s - b.sl, WAD);

        uint256 v0 = _virtual0(total, b.sh);
        uint256 v1 = _virtual1(total, b.sl);
        if (v0 < MIN_RESOLUTION || v1 < MIN_RESOLUTION) return (false, 0, 0, 0);

        uint256 x = v0 + used0;
        uint256 y = v1 + used1;
        uint256 maxX = FixedPointMathLib.fullMulDiv(y, WAD * WAD, b.sl * b.sl);
        if (x > maxX) {
            used0 = maxX > v0 ? maxX - v0 : 0;
            x = v0 + used0;
        }
        uint256 maxY = FixedPointMathLib.fullMulDiv(x, b.sh * b.sh, WAD * WAD);
        if (y > maxY) {
            used1 = maxY > v1 ? maxY - v1 : 0;
            y = v1 + used1;
        }
        if (used0 > amount0 || used1 > amount1) return (false, 0, 0, 0);
        if (total <= MIN_LIQUIDITY) return (false, 0, 0, 0);

        // The opening price the pool will actually land on, against the same
        // tolerance `_addLiquidity` enforces. A seed can clear every other
        // guard and still open several percent from the requested price.
        unchecked {
            uint256 wantSq = s * s;
            uint256 gotSq = x == 0 ? 0 : FixedPointMathLib.fullMulDiv(y, WAD * WAD, x);
            uint256 slack = wantSq / SEED_PRICE_TOLERANCE;
            if (gotSq < wantSq - slack || gotSq > wantSq + slack) return (false, 0, 0, 0);
            lp = total - MIN_LIQUIDITY;
        }
        ok = true;
    }

    /// @notice How much of the other token a seed at `sqrtPriceInit` needs.
    ///
    /// @dev THE QUESTION A SEEDING FORM ACTUALLY ASKS. A user picks a price and
    ///      types one amount; this returns the counterpart. Deriving it off
    ///      chain means reproducing the seed's rounding, and being one unit
    ///      short is a revert rather than a smaller deposit.
    ///
    ///      Returns the EXACT requirement. Supplying more is harmless - the
    ///      pool refunds the difference - so a frontend wanting to absorb a
    ///      price move between quote and submit should pad this and rely on the
    ///      refund rather than trying to be precise.
    /// @param tokenIn The side the caller is specifying.
    /// @return ok False when the pool would refuse a seed at this price.
    /// @return other Amount of the opposite token required.
    function seedCounterpart(address pool, uint256 sqrtPriceInit, address tokenIn, uint256 amountIn)
        external
        view
        returns (bool ok, uint256 other)
    {
        Band memory b = _band(pool);
        PrecisionPool p = PrecisionPool(payable(pool));
        bool isToken0 = tokenIn == p.token0();
        if (!isToken0 && tokenIn != p.token1()) return (false, 0);
        if (sqrtPriceInit < b.sl || sqrtPriceInit > b.sh) return (false, 0);

        uint256 s = sqrtPriceInit;
        uint256 total;
        if (isToken0) {
            if (s == b.sh) return (false, 0); // at the ceiling token0 is unused
            total = FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(amountIn, s, b.sh - s), b.sh, WAD);
        } else {
            if (s == b.sl) return (false, 0); // at the floor token1 is unused
            total = FixedPointMathLib.fullMulDiv(amountIn, WAD, s - b.sl);
        }
        if (total == 0 || total > MAX_LIQUIDITY) return (false, 0);

        other = isToken0
            ? FixedPointMathLib.fullMulDivUp(total, s - b.sl, WAD)
            : FixedPointMathLib.fullMulDivUp(total, (b.sh - s) * WAD, b.sh * s);
        ok = true;
    }

    // ------------------------------------------------------------------- ADD

    /// @notice What a proportional deposit into a live pool would mint.
    /// @dev Mirrors `PrecisionPool._proportional`, which floors the shares and
    ///      ceils each side's contribution. The refunds are the part a UI needs
    ///      and cannot guess: a deposit at the wrong ratio silently returns the
    ///      excess rather than failing, so "you will actually deposit X and get
    ///      Y back" is the honest thing to show.
    function previewAdd(address pool, uint256 amount0, uint256 amount1)
        public
        view
        returns (bool ok, uint256 lp, uint256 used0, uint256 used1, uint256 refund0, uint256 refund1)
    {
        Band memory b = _band(pool);
        if (b.supply == 0) return (false, 0, 0, 0, 0, 0);

        uint256 f0 = b.r0 == 0 ? type(uint256).max : FixedPointMathLib.fullMulDiv(amount0, b.supply, b.r0);
        uint256 f1 = b.r1 == 0 ? type(uint256).max : FixedPointMathLib.fullMulDiv(amount1, b.supply, b.r1);
        lp = FixedPointMathLib.min(f0, f1);
        if (lp == 0 || lp == type(uint256).max) return (false, 0, 0, 0, 0, 0);
        if (lp > MAX_LIQUIDITY - b.supply) return (false, 0, 0, 0, 0, 0);

        used0 = b.r0 == 0 ? 0 : FixedPointMathLib.fullMulDivUp(lp, b.r0, b.supply);
        used1 = b.r1 == 0 ? 0 : FixedPointMathLib.fullMulDivUp(lp, b.r1, b.supply);
        if (used0 > amount0 || used1 > amount1) return (false, 0, 0, 0, 0, 0);

        unchecked {
            (refund0, refund1) = (amount0 - used0, amount1 - used1);
        }
        ok = true;
    }

    // ---------------------------------------------------------------- REMOVE

    /// @notice What burning `shares` pays out today.
    /// @dev `PrecisionPoolLens.positionsOf` answers this for a holder's whole
    ///      balance; a withdraw slider needs it for an arbitrary amount.
    ///
    ///      `ok` is false for a burn the pool refuses, which includes the case
    ///      both sides floor to zero - a real position that cannot be exited
    ///      because it is worth less than one raw unit of either token. Showing
    ///      that as a disabled control is much better than a revert.
    function previewRemove(address pool, uint256 shares)
        public
        view
        returns (bool ok, uint256 amount0, uint256 amount1)
    {
        Band memory b = _band(pool);
        if (shares == 0 || b.supply == 0 || shares > b.supply) return (false, 0, 0);
        amount0 = FixedPointMathLib.fullMulDiv(shares, b.r0, b.supply);
        amount1 = FixedPointMathLib.fullMulDiv(shares, b.r1, b.supply);
        if (amount0 == 0 && amount1 == 0) return (false, 0, 0);
        ok = true;
    }

    // ------------------------------------------------------------------- ZAP

    /// @notice The `swapPortion` to hand `PrecisionRoute.zapIn`, and the shares
    ///         it should mint.
    ///
    /// @dev THE ONE ARGUMENT `zapIn` CANNOT DEFAULT. The pool's NatSpec declines
    ///      to compute this on-chain, and is right to: it would charge every
    ///      swapper gas for arithmetic only a depositor needs. That argument
    ///      does not apply to a `view`, which costs a frontend nothing, and the
    ///      alternative is every integrator inventing their own split.
    ///
    ///      NOT A CLOSED FORM. Swapping moves the price, so the ratio the
    ///      deposit must match is the ratio AFTER the swap, which depends on the
    ///      swap size. What is monotone is the comparison: as the portion grows,
    ///      the leftover input side shrinks while the received side grows, so
    ///      "which side of the deposit binds" flips exactly once. That is
    ///      bisectable, and this bisects it - about 60 iterations of pure view
    ///      arithmetic against the pool's own quoter, so the model cannot drift
    ///      from what the swap will do.
    ///
    ///      The result is the largest portion that still leaves the token being
    ///      swapped as the binding side, which is the last size before the
    ///      deposit starts refunding the swapped-for token. Sizes either side of
    ///      it mint marginally fewer shares, so a caller wanting slack can move
    ///      a little in either direction and lose only the fee on the difference.
    ///
    ///      `expectedLp` is what the split should mint at CURRENT state. Size
    ///      `minLP` below it - the pool refuses a zap into an unseeded band, and
    ///      any price move between quote and submit lands here rather than in
    ///      the swap, since `zapIn` runs its swap leg at `minOut = 0`.
    function previewZap(address pool, address tokenIn, uint256 amountIn)
        external
        view
        returns (bool ok, uint256 swapPortion, uint256 expectedLp)
    {
        Band memory b = _band(pool);
        if (b.supply == 0 || amountIn < 2) return (false, 0, 0);
        PrecisionPool p = PrecisionPool(payable(pool));
        bool zeroForOne = tokenIn == p.token0();
        if (!zeroForOne && tokenIn != p.token1()) return (false, 0, 0);

        // THE PREDICATE RUNS FALSE -> TRUE, not the other way round, and
        // getting that backwards is how the first version of this returned a
        // one-share split. At `portion == 0` nothing has been swapped, so the
        // RECEIVED side is empty and binds; as the portion grows the leftover
        // input shrinks while the received side grows, so the binding side
        // flips exactly once and never flips back.
        //
        // So bisect for the crossing rather than for an endpoint: `lo` is the
        // largest portion where the received side still binds, `hi` the
        // smallest where the input side does. The optimum is one of the two -
        // they straddle the point where the deposit needs neither refunded -
        // and which one wins depends on rounding, so both are priced.
        uint256 lo;
        uint256 hi = amountIn;
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_inputSideBinds(p, b, zeroForOne, amountIn, mid)) hi = mid;
            else lo = mid;
        }

        (bool okLo, uint256 lpLo) = lo == 0 ? (false, uint256(0)) : _zapShares(p, b, zeroForOne, amountIn, lo);
        (bool okHi, uint256 lpHi) = hi >= amountIn ? (false, uint256(0)) : _zapShares(p, b, zeroForOne, amountIn, hi);

        if (okHi && lpHi >= lpLo) return (true, hi, lpHi);
        if (okLo && lpLo != 0) return (true, lo, lpLo);
        return (false, 0, 0);
    }

    /// @dev True while the token being swapped is still the side that limits
    ///      the deposit. Monotone decreasing in `portion`, which is what makes
    ///      the search above valid.
    function _inputSideBinds(
        PrecisionPool p,
        Band memory b,
        bool zeroForOne,
        uint256 amountIn,
        uint256 portion
    ) internal view returns (bool) {
        (uint256 received, bool fits) = p.quoteExactIn(msg.sender, zeroForOne ? p.token0() : p.token1(), portion);
        if (!fits) return false;
        uint256 keep = amountIn - portion;

        // Reserves as the deposit will see them, after the swap has moved them.
        (uint256 r0, uint256 r1) = _postSwapReserves(b, zeroForOne, portion, received);
        if (r0 == 0 || r1 == 0) return false;

        (uint256 haveIn, uint256 haveOut) = zeroForOne ? (keep, received) : (received, keep);
        // Binding side is whichever yields less liquidity.
        uint256 fromIn = FixedPointMathLib.fullMulDiv(haveIn, b.supply, r0);
        uint256 fromOut = FixedPointMathLib.fullMulDiv(haveOut, b.supply, r1);
        return zeroForOne ? fromIn <= fromOut : fromOut <= fromIn;
    }

    function _postSwapReserves(Band memory b, bool zeroForOne, uint256 portion, uint256 received)
        internal
        pure
        returns (uint256 r0, uint256 r1)
    {
        // The input stays in the reserves less the fee cuts the pool routes
        // elsewhere; using the gross input overstates it by at most the hook
        // and creator shares, which is immaterial to a ratio at deposit sizes.
        unchecked {
            r0 = zeroForOne ? b.r0 + portion : b.r0 - (received > b.r0 ? b.r0 : received);
            r1 = zeroForOne ? b.r1 - (received > b.r1 ? b.r1 : received) : b.r1 + portion;
        }
    }

    function _zapShares(
        PrecisionPool p,
        Band memory b,
        bool zeroForOne,
        uint256 amountIn,
        uint256 portion
    ) internal view returns (bool ok, uint256 lp) {
        (uint256 received, bool fits) = p.quoteExactIn(msg.sender, zeroForOne ? p.token0() : p.token1(), portion);
        if (!fits) return (false, 0);
        uint256 keep = amountIn - portion;
        (uint256 r0, uint256 r1) = _postSwapReserves(b, zeroForOne, portion, received);
        if (r0 == 0 || r1 == 0) return (false, 0);

        (uint256 have0, uint256 have1) = zeroForOne ? (keep, received) : (received, keep);
        uint256 f0 = FixedPointMathLib.fullMulDiv(have0, b.supply, r0);
        uint256 f1 = FixedPointMathLib.fullMulDiv(have1, b.supply, r1);
        lp = FixedPointMathLib.min(f0, f1);
        ok = lp != 0;
    }
}
