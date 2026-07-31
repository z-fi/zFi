// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";
import {PrecisionPool} from "./PrecisionPool.sol";
import {PrecisionPoolFactory} from "./PrecisionPoolFactory.sol";

/// @title PrecisionPoolLens
/// @notice Read-only quoting and discovery over the precision pools, for a
///         frontend deciding whether one belongs in a route.
///
/// @dev    WHY THIS IS NOT IN THE FACTORY. The factory carries the registry,
///         so it is the one contract here that must never be redeployed - a
///         new one starts with an empty list and every existing market falls
///         out of discovery. Quoting is the part most likely to need revision.
///         Keeping them apart means the lens can be replaced freely while the
///         registry stays put, which is the same division Swapboard and
///         SwapboardView already use.
///
///         WHY THIS IS NOT IN zQUOTER. It could be, and eventually should be:
///         zQuoter's builders are what emit executable legs, and a venue it
///         cannot see is a venue it cannot split across or route through in a
///         multi-hop. But zQuoter is deployed and immutable, and repointing it
///         means a new address plus every consumer updated. This lens buys
///         comparison without that, and precision pools can be folded into
///         zQuoter whenever it is next redeployed for its own reasons.
///
///         WHAT A QUOTE FROM HERE IS, AND IS NOT. It is exact for a single hop
///         against one pool: the arithmetic below is the pool's own swap math,
///         so a quote and the fill it predicts agree to the wei. It is NOT a
///         route. Deciding to split across bands, or to hop through a pool on
///         the way somewhere else, stays with the caller, which for now means
///         zSwap composing a multicall from this and from zQuoter's builders.
///
///         ZERO MEANS UNFILLABLE, NOT FREE. A size that would run past the end
///         of the band, an empty pool, or a token that is not in the pair all
///         quote zero. The pool refuses those rather than clamping, so a lens
///         that returned a partial number would promise a fill that reverts.
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
        // Fee configuration and what it has earned but not yet paid out. Read
        // here so a frontend never has to infer a pool's terms from events.
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

    /// @notice Exact output for `amountIn` of `tokenIn` against one pool.
    /// @dev Mirrors PrecisionPool.swap step for step, including the boundary
    ///      refusal, so callers can size a leg without simulating.
    function quote(address pool, address tokenIn, uint256 amountIn) public view returns (uint256 amountOut) {
        return quoteFor(pool, msg.sender, tokenIn, amountIn);
    }

    /// @notice The same quote, for a named sender.
    /// @dev A hook may price by who is trading, and on a routed swap the pool
    ///      sees the router rather than the user. Callers that intend to route
    ///      should quote for the address that will actually arrive, or the
    ///      figure they compare against other venues is not the one they will
    ///      be filled at.
    function quoteFor(address pool, address sender, address tokenIn, uint256 amountIn)
        public
        view
        returns (uint256 amountOut)
    {
        // The factory is the registry of canonical pool bytecode. Restricting
        // quotes to it keeps a user-supplied arbitrary contract from being
        // invoked as though it implemented the pool interface.
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

        // Mirrors the pool exactly, hook included: the surcharge comes off the
        // top, the pool's own fee applies to what is left.
        uint256 hookCut = FixedPointMathLib.fullMulDiv(amountIn, p.extraFee(sender, tokenIn, amountIn), FEE_DENOM);
        uint256 net = amountIn - hookCut;

        uint256 feeAmount = FixedPointMathLib.fullMulDiv(net, p.fee(), FEE_DENOM);
        uint256 creatorCut = FixedPointMathLib.fullMulDiv(feeAmount, p.creatorFeeBps(), BPS);
        uint256 kept = net - creatorCut;
        if (kept > type(uint128).max - rIn) return 0;

        uint256 inAfterFee = net - feeAmount;
        amountOut = FixedPointMathLib.fullMulDiv(inAfterFee, rOut + vOut, rIn + vIn + inAfterFee);

        // The pool refuses past the edge of its band rather than clamping, so
        // reporting a capped figure here would quote a fill that cannot happen.
        if (amountOut == 0 || amountOut > rOut) return 0;

        uint256 next0 = zeroForOne ? rIn + kept : rOut - amountOut;
        uint256 next1 = zeroForOne ? rOut - amountOut : rIn + kept;
        uint256 nextPrice = _sqrtPrice(supply, next0, next1, sl, sh);
        if (nextPrice < sl || nextPrice > sh) return 0;
    }

    /// @notice Effective total fee in pips for one direction, sender and size.
    /// @dev A surcharge is taken first and the base fee applies to the
    ///      remainder, so their overlap must not be counted twice.
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

    /// @notice Best single band in one bounded page of a pair.
    /// @dev Bands do not share depth, so the right one genuinely depends on
    ///      size: a tight band may beat a wide one on a small trade and run out
    ///      of range on a large one. `sender` must be the address the pool will
    ///      see at execution time, such as the factory executor.
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

    /// @notice Every band in one bounded page of a pair, quoted at this size.
    /// @dev Returned unsorted and including zeros: a caller comparing against
    ///      the metadex wants to see which bands declined and why, and sorting
    ///      on-chain would only be undone by the caller's own ranking.
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

    /// @notice Full detail for a set of pools, in one call.
    /// @dev The frontend's bulk read: addresses come from the factory, details
    ///      from each pool, so nothing here can drift from what the pool
    ///      actually holds.
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

    /// @notice One market, fully described.
    /// @dev Its own frame rather than an inline literal: the struct carries
    ///      enough fields that building it inside the loop runs the stack out.
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
        // Token0-input headline at `probe`, surcharge included. A concrete
        // token1 trade uses `effectiveFeeFor`, which is direction-aware.
        o.effectiveFee0 = effectiveFeeFor(pool, sender, o.token0, probe);
        o.hookOwed0 = p.hookOwed0();
        o.hookOwed1 = p.hookOwed1();
        o.creatorOwed0 = p.creatorOwed0();
        o.creatorOwed1 = p.creatorOwed1();
    }

    function marketsForPair(address token0, address token1, address sender, uint256 start, uint256 count, uint256 probe)
        external
        view
        returns (PoolInfo[] memory)
    {
        return describeFor(factory.poolsForPairSlice(token0, token1, start, count), sender, probe);
    }

    /// @notice A page of every market, for a search index.
    /// @dev Argument order matches its siblings deliberately - subject, then
    ///      `sender`, then the page, then `probe`. It has no subject, so
    ///      `sender` leads. Solidity would catch a transposition here, but a
    ///      frontend encoding calldata positionally would not: it would simply
    ///      quote a surcharge for the wrong trader.
    function markets(address sender, uint256 start, uint256 count, uint256 probe)
        external
        view
        returns (PoolInfo[] memory)
    {
        return describeFor(factory.poolsSlice(start, count), sender, probe);
    }

    /// @notice Every market touching a token, for search-by-ticker.
    function marketsForToken(address token, address sender, uint256 start, uint256 count, uint256 probe)
        external
        view
        returns (PoolInfo[] memory)
    {
        return describeFor(factory.poolsForTokenSlice(token, start, count), sender, probe);
    }

    /// @notice Every market a creator is named on, for a creator dashboard.
    function marketsForCreator(address creator, address sender, uint256 start, uint256 count, uint256 probe)
        external
        view
        returns (PoolInfo[] memory)
    {
        return describeFor(factory.poolsForCreatorSlice(creator, start, count), sender, probe);
    }

    // --------------------------------------------------------------- HOLDINGS

    /// @notice Every band in this window where `user` holds shares, with the
    ///         underlying each would return today.
    /// @dev The portfolio read. Without it a frontend has to call `balanceOf`
    ///      on every pool in existence to answer "what do I own", which is one
    ///      request per market and gets worse as the protocol succeeds.
    ///
    ///      Amounts mirror `removeLiquidity` exactly - `shares * reserve /
    ///      supply`, rounded down - so what is displayed is what redeeming
    ///      would actually pay, not an estimate. Accrued hook and creator fees
    ///      are excluded from reserves by the pool itself, so they cannot
    ///      inflate a holder's apparent claim.
    ///
    ///      Paginated over the global list, and empty holdings are dropped, so
    ///      the result is usually far shorter than the window scanned.
    function positionsOf(address user, uint256 start, uint256 count)
        external
        view
        returns (Position[] memory out)
    {
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
        // Shrink to what was actually found; the scan window is an upper bound.
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }
}
