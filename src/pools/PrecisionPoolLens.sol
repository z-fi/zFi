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
        // Only quote pools registered by the factory.
        if (amountIn == 0 || !factory.isPool(pool)) return 0;

        PrecisionPool p = PrecisionPool(payable(pool));
        address token0 = p.token0();
        address token1 = p.token1();

        bool zeroForOne = tokenIn == token0;
        if (!zeroForOne && tokenIn != token1) return 0;

        uint256 supply = p.totalSupply();
        if (supply == 0) return 0;

        uint256 r0 = p.reserve0();
        uint256 r1 = p.reserve1();
        uint256 sl = p.sqrtPLow();
        uint256 sh = p.sqrtPHigh();
        uint256 v0 = FixedPointMathLib.fullMulDiv(supply, WAD, sh);
        uint256 v1 = FixedPointMathLib.fullMulDiv(supply, sl, WAD);

        (uint256 rIn, uint256 rOut, uint256 vIn, uint256 vOut) = zeroForOne ? (r0, r1, v0, v1) : (r1, r0, v1, v0);

        // The surcharge is taken first; the base fee applies to the remainder.
        // MUST mirror the pool byte for byte. Both fees are derived as a
        // DIFFERENCE from a rounded-down remainder, not floored directly -
        // flooring rounds toward the trader and lets a split order avoid the
        // fee entirely. Computing them the old way here still quotes, just
        // slightly high, and the drift only surfaces as a failed amountOutMin
        // at submission.
        uint256 hookCut = amountIn
            - FixedPointMathLib.fullMulDiv(
                amountIn, FEE_DENOM - p.extraFee(sender, tokenIn, amountIn), FEE_DENOM
            );
        uint256 net = amountIn - hookCut;

        uint256 feeAmount = net - FixedPointMathLib.fullMulDiv(net, FEE_DENOM - p.fee(), FEE_DENOM);
        uint256 creatorCut = FixedPointMathLib.fullMulDiv(feeAmount, p.creatorFeeBps(), BPS);
        uint256 kept = net - creatorCut;
        if (kept > type(uint128).max - rIn) return 0;

        uint256 inAfterFee = net - feeAmount;
        amountOut = FixedPointMathLib.fullMulDiv(inAfterFee, rOut + vOut, rIn + vIn + inAfterFee);

        // The pool refuses trades that leave the configured range.
        if (amountOut == 0 || amountOut > rOut) return 0;

        uint256 next0 = zeroForOne ? rIn + kept : rOut - amountOut;
        uint256 next1 = zeroForOne ? rOut - amountOut : rIn + kept;
        uint256 nextPrice = _sqrtPrice(supply, next0, next1, sl, sh);
        if (nextPrice < sl || nextPrice > sh) return 0;
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
