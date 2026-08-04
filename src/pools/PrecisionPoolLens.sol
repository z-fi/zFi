// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";
import {PrecisionPoolFactory} from "./PrecisionPoolFactory.sol";
import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PrecisionPoolLens
/// @notice Read-only quoting, discovery, and position data for precision pools.
/// @dev Quotes mirror the pool's single-hop pricing and return zero for an
///      invalid or unfillable trade. They assume the pool remains backed and
///      are not reservations; state may change before execution.
contract PrecisionPoolLens {
    uint256 constant FEE_DENOM = 1_000_000;
    uint256 constant BPS = 10_000;
    uint256 constant WAD = 1e18;

    PrecisionPoolFactory public immutable factory;

    error BadFactory();

    /// @notice Everything a frontend needs to render and price one market.
    struct PoolInfo {
        address pool;
        address token0;
        address token1;
        uint256 sqrtPLow;
        uint256 sqrtPHigh;
        uint256 fee;
        uint256 reserve0;
        uint256 reserve1;
        uint256 sqrtPriceCurrent;
        uint256 liquidity;
        // Fee configuration and accrued fees.
        address hook;
        address feeRecipient;
        uint256 creatorFeeBps;
        /// @notice Effective fee for `token0` input at the supplied probe size.
        /// @dev Use `effectiveFeeFor` for token1 or a trade-specific amount.
        uint256 effectiveFee0;
        uint256 hookOwed0;
        uint256 hookOwed1;
        uint256 creatorOwed0;
        uint256 creatorOwed1;
    }

    /// @notice One holding, with what it would redeem for right now.
    struct Position {
        address pool;
        uint256 shares;
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Single-pool quote and its immutable base fee.
    struct Quoted {
        address pool;
        uint256 amountOut;
        uint256 fee;
    }

    constructor(PrecisionPoolFactory factory_) {
        if (address(factory_) == address(0) || address(factory_).code.length == 0) revert BadFactory();
        factory = factory_;
    }

    // ------------------------------------------------------------------ QUOTE

    /// @notice Quote the output for `amountIn` of `tokenIn` against one pool.
    /// @dev Mirrors the pool's swap math, including its range-boundary refusal.
    function quote(address pool, address tokenIn, uint256 amountIn) public view returns (uint256 amountOut) {
        return quoteFor(pool, msg.sender, tokenIn, amountIn);
    }

    /// @notice Quote for a specific sender.
    /// @dev Use the address the pool will see at execution, such as a router,
    ///      because hooks may vary their surcharge by sender.
    function quoteFor(address pool, address sender, address tokenIn, uint256 amountIn)
        public
        view
        returns (uint256 amountOut)
    {
        (amountOut,) = _transition(pool, sender, tokenIn, amountIn);
    }

    /// @dev The pool's swap state, read once so a search can replay the
    ///      transition many times without repeating the storage reads.
    struct Book {
        bool ok;
        bool zeroForOne;
        uint256 supply;
        uint256 rIn;
        uint256 rOut;
        uint256 vIn;
        uint256 vOut;
        uint256 sl;
        uint256 sh;
        uint256 fee;
        uint256 creatorFeeBps;
        address hook;
    }

    /// @dev Load everything `_step` needs. `ok` is false when the pool is not
    ///      quotable at all, which is distinct from a trade that cannot fill.
    function _book(address pool, address tokenIn) internal view returns (Book memory b) {
        if (!factory.isPool(pool)) return b;
        PrecisionPool p = PrecisionPool(payable(pool));

        b.zeroForOne = tokenIn == p.token0();
        if (!b.zeroForOne && tokenIn != p.token1()) return b;

        b.supply = p.totalSupply();
        if (b.supply == 0) return b;

        (b.sl, b.sh) = (p.sqrtPLow(), p.sqrtPHigh());
        uint256 r0 = p.reserve0();
        uint256 r1 = p.reserve1();
        uint256 v0 = FixedPointMathLib.fullMulDiv(b.supply, WAD, b.sh);
        uint256 v1 = FixedPointMathLib.fullMulDiv(b.supply, b.sl, WAD);
        (b.rIn, b.rOut, b.vIn, b.vOut) = b.zeroForOne ? (r0, r1, v0, v1) : (r1, r0, v1, v0);

        (b.fee, b.creatorFeeBps, b.hook) = (p.fee(), p.creatorFeeBps(), p.hook());
        b.ok = true;
    }

    /// @dev Replay one swap against a loaded book.
    ///
    ///      MUST MIRROR `PrecisionPool._swapExact` EXACTLY. Two things that a
    ///      reimplementation gets wrong by default, and both matter here
    ///      because `maxAmountIn` bisects on this predicate and therefore
    ///      lives entirely on the boundary where the approximations diverge:
    ///
    ///        - the fees and the creator cut round the way the pool rounds.
    ///          Both fees are a DIFFERENCE from a floored remainder rather than
    ///          a floored product, because flooring rounds toward the trader
    ///          and lets a split order pay nothing; the creator cut rounds UP
    ///          for the mirror-image reason. Rounding the creator cut down here
    ///          overstates `kept` by a unit and quotes trades the pool refuses.
    ///
    ///        - the range test compares the SQUARED ratio, as the pool does,
    ///          not a square root of it. `sqrt` floors, so a state fractionally
    ///          outside the band reads as exactly on it and quotes as fillable.
    ///
    ///      FILLABILITY IS NOT MONOTONE IN SIZE, so it is returned in two
    ///      pieces. `hasRoom` covers the reserve, overflow, and band checks,
    ///      all of which turn OFF as size grows. `amountOut != 0` is the
    ///      opposite: a trade too small to round to one output unit is refused,
    ///      and that turns ON as size grows. The fillable set is therefore an
    ///      INTERVAL, not a prefix or a suffix, and any search over it has to
    ///      bisect the monotone half and check the other half at the end.
    ///      Bisecting the conjunction directly finds nothing.
    function _step(Book memory b, uint256 amountIn, uint256 surcharge)
        internal
        pure
        returns (uint256 amountOut, bool hasRoom)
    {
        if (amountIn == 0) return (0, false);

        uint256 hookCut =
            b.hook == address(0) ? 0 : amountIn - FixedPointMathLib.fullMulDiv(amountIn, FEE_DENOM - surcharge, FEE_DENOM);
        uint256 net = amountIn - hookCut;

        uint256 feeAmount = net - FixedPointMathLib.fullMulDiv(net, FEE_DENOM - b.fee, FEE_DENOM);
        uint256 creatorCut =
            b.creatorFeeBps == 0 ? 0 : FixedPointMathLib.fullMulDivUp(feeAmount, b.creatorFeeBps, BPS);
        uint256 kept = net - creatorCut;
        if (kept > type(uint128).max - b.rIn) return (0, false);

        uint256 inAfterFee = net - feeAmount;
        amountOut = FixedPointMathLib.fullMulDiv(inAfterFee, b.rOut + b.vOut, b.rIn + b.vIn + inAfterFee);
        if (amountOut > b.rOut) return (0, false);

        uint256 nextIn = b.rIn + b.vIn + kept;
        uint256 nextOut = b.rOut + b.vOut - amountOut;
        (uint256 nextX, uint256 nextY) = b.zeroForOne ? (nextIn, nextOut) : (nextOut, nextIn);
        if (!_inRange(nextX, nextY, b.sl, b.sh)) return (0, false);
        hasRoom = true;
    }

    /// @dev The pool's own band test: compare the squared price directly.
    function _inRange(uint256 vX, uint256 vY, uint256 sl, uint256 sh) internal pure returns (bool) {
        if (vX == 0) return false;
        uint256 ratio = FixedPointMathLib.fullMulDiv(vY, WAD * WAD, vX);
        unchecked {
            return ratio >= sl * sl && ratio < (sh + 1) * (sh + 1);
        }
    }

    function _transition(address pool, address sender, address tokenIn, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, bool fillable)
    {
        Book memory b = _book(pool, tokenIn);
        if (!b.ok || amountIn == 0) return (0, false);
        uint256 surcharge =
            b.hook == address(0) ? 0 : PrecisionPool(payable(pool)).extraFee(sender, tokenIn, amountIn);
        bool hasRoom;
        (amountOut, hasRoom) = _step(b, amountIn, surcharge);
        // The pool refuses a trade whose output rounds to zero.
        if (!hasRoom || amountOut == 0) return (0, false);
        fillable = true;
    }

    // ------------------------------------------------------- ROUTING PRIMITIVES

    /// @notice The largest input this pool can absorb in one swap, and what it
    ///         pays out.
    /// @dev A band fills to its boundary and then refuses - it does not clamp -
    ///      so a router that sizes a leg past this point gets a revert rather
    ///      than a partial fill. This is the number that makes a leg safe to
    ///      size, and the unit a split or a multi-pool route is built from.
    ///
    ///      Found by bisection rather than in closed form. The obvious
    ///      algebraic solve - reserve room to the bound - is WRONG, because the
    ///      input side grows by `kept`, which retains the LP fee, while the
    ///      output is priced on `inAfterFee`, which does not. The two sides of
    ///      the post-swap ratio therefore move under different quantities and
    ///      the boundary condition does not separate. Bisection sidesteps that
    ///      entirely and is exact: it replays the pool's own transition, so it
    ///      agrees with execution by construction rather than by derivation.
    ///
    ///      This is a view call, so the ~128 iterations are free off-chain. Do
    ///      not call it on-chain in a swap path.
    ///
    ///      ON A HOOKED POOL THE RESULT IS BEST-EFFORT. Bisection assumes
    ///      fillability is monotone in size, which holds for the pool's own
    ///      math but not for an arbitrary hook: a surcharge that varies
    ///      non-monotonically with `amountIn` can make a larger trade fillable
    ///      where a smaller one is not, and the search may then return a
    ///      conservative answer. It never returns an unfillable one - every
    ///      candidate it settles on has been replayed and accepted.
    function maxAmountIn(address pool, address sender, address tokenIn)
        public
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        Book memory b = _book(pool, tokenIn);
        if (!b.ok) return (0, 0);

        // Bisect the MONOTONE half only - the reserve, overflow, and band
        // checks, which hold for small inputs and fail for large ones. The
        // rounds-to-zero-output condition runs the other way and is applied
        // once at the end; see `_step`.
        (uint256 outLo, bool roomAt1) = _probe(b, pool, sender, tokenIn, 1);
        if (!roomAt1) return (0, 0);

        uint256 hi = type(uint128).max;
        (uint256 outHi, bool roomAtHi) = _probe(b, pool, sender, tokenIn, hi);
        if (roomAtHi) {
            // The band cannot be exhausted within the pool's own input ceiling.
            return outHi == 0 ? (0, 0) : (hi, outHi);
        }

        // Invariant: `lo` has room, `hi` does not.
        uint256 lo = 1;
        amountOut = outLo;
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            (uint256 outMid, bool roomMid) = _probe(b, pool, sender, tokenIn, mid);
            if (roomMid) {
                lo = mid;
                amountOut = outMid;
            } else {
                hi = mid;
            }
        }

        // `lo` is the largest input the band admits. If even that rounds its
        // output to zero then no size fills at all, because output is
        // nondecreasing in input - the interval is empty rather than merely
        // missed by the search.
        if (amountOut == 0) return (0, 0);
        amountIn = lo;
    }

    /// @notice `maxAmountIn` for the caller as sender.
    function maxAmountInFor(address pool, address tokenIn) external view returns (uint256, uint256) {
        return maxAmountIn(pool, msg.sender, tokenIn);
    }

    function _probe(Book memory b, address pool, address sender, address tokenIn, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, bool fillable)
    {
        uint256 surcharge =
            b.hook == address(0) ? 0 : PrecisionPool(payable(pool)).extraFee(sender, tokenIn, amountIn);
        return _step(b, amountIn, surcharge);
    }

    /// @notice Marginal output per 1e18 of input, net of fees, at current state.
    /// @dev The price of the NEXT infinitesimal unit, not the average price of
    ///      any particular trade. This is what a split-route solver compares
    ///      across pools: sizing legs to equalise marginal price is what makes
    ///      a split beat filling the best pool alone, and average prices cannot
    ///      express that because each fill moves the pool it lands in.
    ///
    ///      Raw token1-per-token0 scaled by 1e18, decimals NOT normalised - the
    ///      same convention as the pool's own bounds and tape. Returns zero for
    ///      a pool that cannot quote this direction. `probe` is the size at
    ///      which any hook surcharge is sampled; it does not otherwise affect
    ///      the result.
    function marginalOutPerIn(address pool, address sender, address tokenIn, uint256 probe)
        public
        view
        returns (uint256)
    {
        Book memory b = _book(pool, tokenIn);
        if (!b.ok) return 0;
        uint256 denom = b.rIn + b.vIn;
        if (denom == 0) return 0;
        uint256 gross = FixedPointMathLib.fullMulDiv(b.rOut + b.vOut, WAD, denom);
        uint256 surcharge =
            b.hook == address(0) ? 0 : PrecisionPool(payable(pool)).extraFee(sender, tokenIn, probe);
        uint256 effFee = b.fee + surcharge - FixedPointMathLib.fullMulDiv(b.fee, surcharge, FEE_DENOM);
        return FixedPointMathLib.fullMulDiv(gross, FEE_DENOM - effFee, FEE_DENOM);
    }

    /// @notice Effective total fee in pips for a direction, sender, and size.
    /// @dev Includes the surcharge-first ordering used by the pool.
    function effectiveFeeFor(address pool, address sender, address tokenIn, uint256 amountIn)
        public
        view
        returns (uint256 effectiveFee)
    {
        if (!factory.isPool(pool)) return 0;
        PrecisionPool p = PrecisionPool(payable(pool));
        if (tokenIn != p.token0() && tokenIn != p.token1()) return 0;
        uint256 base = p.fee();
        uint256 surcharge = p.extraFee(sender, tokenIn, amountIn);
        effectiveFee = base + surcharge - FixedPointMathLib.fullMulDiv(base, surcharge, FEE_DENOM);
    }

    function _sqrtPrice(uint256 supply, uint256 r0, uint256 r1, uint256 sl, uint256 sh)
        internal
        pure
        returns (uint256)
    {
        uint256 vX = FixedPointMathLib.fullMulDiv(supply, WAD, sh) + r0;
        if (vX == 0) return 0;
        uint256 vY = FixedPointMathLib.fullMulDiv(supply, sl, WAD) + r1;
        return FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(vY, WAD * WAD, vX));
    }

    /// @notice Return the best single pool in a bounded pair page.
    /// @dev `sender` must be the address the pool will see at execution time.
    function quoteBestFor(
        address token0,
        address token1,
        address sender,
        address tokenIn,
        uint256 amountIn,
        uint256 start,
        uint256 count
    ) external view returns (address bestPool, uint256 bestOut) {
        address[] memory pools = factory.poolsForPairSlice(token0, token1, start, count);
        for (uint256 i; i < pools.length; ++i) {
            uint256 out = quoteFor(pools[i], sender, tokenIn, amountIn);
            if (out > bestOut) (bestPool, bestOut) = (pools[i], out);
        }
    }

    /// @notice Quote every pool in a bounded pair page.
    /// @dev Results retain factory order and include zero-output quotes.
    function quoteAllFor(
        address token0,
        address token1,
        address sender,
        address tokenIn,
        uint256 amountIn,
        uint256 start,
        uint256 count
    ) external view returns (Quoted[] memory out) {
        address[] memory pools = factory.poolsForPairSlice(token0, token1, start, count);
        out = new Quoted[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            out[i] = Quoted({
                pool: pools[i],
                amountOut: quoteFor(pools[i], sender, tokenIn, amountIn),
                fee: PrecisionPool(payable(pools[i])).fee()
            });
        }
    }

    // -------------------------------------------------------------- DISCOVERY

    /// @notice Return full details for a set of pools.
    /// @param probe Size used to evaluate a size-dependent surcharge. Pass the
    ///        trade being considered, or 1e18 for an indicative headline rate.
    function describeFor(address[] memory pools, address sender, uint256 probe)
        public
        view
        returns (PoolInfo[] memory out)
    {
        out = new PoolInfo[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            out[i] = infoFor(pools[i], sender, probe);
        }
    }

    /// @notice Return full details for one registered pool.
    /// @dev Returns an empty struct for an unregistered address.
    function infoFor(address pool, address sender, uint256 probe) public view returns (PoolInfo memory o) {
        if (!factory.isPool(pool)) return o;
        PrecisionPool p = PrecisionPool(payable(pool));
        o.pool = pool;
        o.token0 = p.token0();
        o.token1 = p.token1();
        o.sqrtPLow = p.sqrtPLow();
        o.sqrtPHigh = p.sqrtPHigh();
        o.fee = p.fee();
        o.reserve0 = p.reserve0();
        o.reserve1 = p.reserve1();
        o.sqrtPriceCurrent = p.sqrtPriceCurrent();
        o.liquidity = p.totalSupply();
        o.hook = p.hook();
        o.feeRecipient = p.feeRecipient();
        o.creatorFeeBps = p.creatorFeeBps();
        // Headline fee for token0 input at the supplied probe size.
        o.effectiveFee0 = effectiveFeeFor(pool, sender, o.token0, probe);
        o.hookOwed0 = p.hookOwed0();
        o.hookOwed1 = p.hookOwed1();
        o.creatorOwed0 = p.creatorOwed0();
        o.creatorOwed1 = p.creatorOwed1();
    }

    /// @notice Return details for a page of pools for a pair.
    function marketsForPair(address token0, address token1, address sender, uint256 start, uint256 count, uint256 probe)
        external
        view
        returns (PoolInfo[] memory)
    {
        return describeFor(factory.poolsForPairSlice(token0, token1, start, count), sender, probe);
    }

    /// @notice Return a page of all registered pools.
    function markets(address sender, uint256 start, uint256 count, uint256 probe)
        external
        view
        returns (PoolInfo[] memory)
    {
        return describeFor(factory.poolsSlice(start, count), sender, probe);
    }

    /// @notice Return a page of pools containing `token`.
    function marketsForToken(address token, address sender, uint256 start, uint256 count, uint256 probe)
        external
        view
        returns (PoolInfo[] memory)
    {
        return describeFor(factory.poolsForTokenSlice(token, start, count), sender, probe);
    }

    /// @notice Return a page of pools indexed for `creator`.
    function marketsForCreator(address creator, address sender, uint256 start, uint256 count, uint256 probe)
        external
        view
        returns (PoolInfo[] memory)
    {
        return describeFor(factory.poolsForCreatorSlice(creator, start, count), sender, probe);
    }

    // --------------------------------------------------------------- HOLDINGS

    /// @notice Return pools in a page where `user` holds LP shares.
    /// @dev Amounts are the rounded-down pro-rata reserves redeemable today;
    ///      accrued hook and creator fees are excluded.
    function positionsOf(address user, uint256 start, uint256 count) external view returns (Position[] memory out) {
        address[] memory pools = factory.poolsSlice(start, count);
        out = new Position[](pools.length);
        uint256 n;
        for (uint256 i; i < pools.length; ++i) {
            PrecisionPool p = PrecisionPool(payable(pools[i]));
            uint256 shares = p.balanceOf(user);
            if (shares == 0) continue;
            uint256 supply = p.totalSupply();
            out[n++] = Position({
                pool: pools[i],
                shares: shares,
                amount0: FixedPointMathLib.fullMulDiv(shares, p.reserve0(), supply),
                amount1: FixedPointMathLib.fullMulDiv(shares, p.reserve1(), supply)
            });
        }
        // Drop empty entries from the result.
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    // ------------------------------------------------------------------ ROUTE

    /// @notice One hop of a chained route, as it must be encoded.
    struct Leg {
        address pool;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
    }

    /// @notice Quote a multi-pool route and return the EXACT per-leg amounts to
    ///         encode into the router calldata.
    ///
    /// @dev Chained legs are funded from the router's own balance, and snwap
    ///      forwards `balance - 1` there - it retains a wei to keep the slot
    ///      warm. The factory's executor settles an exact declared amount, so a
    ///      caller that declares the previous leg's full output reverts
    ///      BadCheckpoint. Deriving that offset in the frontend is easy to get
    ///      wrong and only fails at submission, so it is computed here and the
    ///      quote is chained through the reduced amount rather than the raw one.
    ///
    ///      The first leg is funded directly and is therefore exact.
    ///
    ///      Returns an empty array if any hop cannot fill, so a zero
    ///      `amountOut` means the route is not executable rather than free.
    function quoteRoute(address[] calldata pools, address sender, address tokenIn, uint256 amountIn)
        external
        view
        returns (Leg[] memory legs, uint256 amountOut)
    {
        legs = new Leg[](pools.length);
        address tin = tokenIn;
        uint256 amt = amountIn;

        for (uint256 i; i < pools.length; ++i) {
            PrecisionPool p = PrecisionPool(payable(pools[i]));
            address t0 = p.token0();
            address tout = tin == t0 ? p.token1() : t0;

            uint256 out = quoteFor(pools[i], sender, tin, amt);
            if (out == 0) return (new Leg[](0), 0);

            legs[i] = Leg({pool: pools[i], tokenIn: tin, tokenOut: tout, amountIn: amt, amountOut: out});

            // The next hop spends what the router holds, less the retained wei.
            tin = tout;
            amt = out == 0 ? 0 : out - 1;
        }
        amountOut = legs[pools.length - 1].amountOut;
    }
}
