// SPDX-License-Identifier: MIT
// Compile with: solc >= 0.8.34 | via_ir: true | optimizer: true, runs: 20
// Required foundry.toml:
//   [profile.default.optimizer_details]
//   yul = false
// Disabling the Yul optimizer with via_ir keeps contract under EIP-170 (24,576 bytes).
pragma solidity ^0.8.34;

interface IZQuoterBase {
    // Per-source quoters.
    function quoteV2(bool, address, address, uint256, bool) external view returns (uint256, uint256);
    function quoteV3(bool, address, address, uint24, uint256) external view returns (uint256, uint256);
    function quoteV4(bool, address, address, uint24, int24, address, uint256) external view returns (uint256, uint256);
    function quoteZAMM(bool, uint256, address, address, uint256, uint256, uint256)
        external
        view
        returns (uint256, uint256);

    // Aggregated quoting. Mirrors zQuoter.getQuotes shape so the base-quoter
    // cross-call (`zQuoter(address(_BASE)).getQuotes(...)`) is ABI-checked.
    function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        external
        view
        returns (zQuoter.Quote memory best, zQuoter.Quote[] memory quotes);
}

IZQuoterBase constant _BASE = IZQuoterBase(0x658bF1A6608210FDE7310760f391AD4eC8006A5F);

contract zQuoter {
    enum AMM {
        UNI_V2,
        SUSHI,
        ZAMM,
        UNI_V3,
        UNI_V4,
        CURVE,
        LIDO,
        WETH_WRAP
    }

    struct Quote {
        AMM source;
        uint256 feeBps;
        uint256 amountIn;
        uint256 amountOut;
    }

    constructor() payable {}

    function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (Quote memory best, Quote[] memory quotes)
    {
        (best, quotes) = zQuoter(address(_BASE)).getQuotes(exactOut, tokenIn, tokenOut, swapAmount);
        // Reject exact-out V3 phantom-liquidity picks. Only the specific failing fee
        // tier is zeroed — other V3 tiers may be healthy — then we re-pick best.
        while (exactOut && best.source == AMM.UNI_V3 && best.amountIn > 0) {
            (, uint256 rt) = _BASE.quoteV3(false, tokenIn, tokenOut, uint24(best.feeBps * 100), best.amountIn);
            if (rt * 10 >= swapAmount * 9) break;
            uint256 badFee = best.feeBps;
            best = Quote(AMM.UNI_V2, 0, 0, 0);
            for (uint256 i; i < quotes.length; ++i) {
                if (quotes[i].source == AMM.UNI_V3 && quotes[i].feeBps == badFee) {
                    quotes[i].amountIn = 0;
                    quotes[i].amountOut = 0;
                    continue;
                }
                if (quotes[i].amountIn > 0 && (best.amountIn == 0 || quotes[i].amountIn < best.amountIn)) {
                    best = quotes[i];
                }
            }
        }
    }

    function _asQuote(AMM source, uint256 amountIn, uint256 amountOut) internal pure returns (Quote memory q) {
        q.source = source;
        q.amountIn = amountIn;
        q.amountOut = amountOut;
    }

    /// @notice Unified single-hop quoting across all AMMs.
    function _quoteBestSingleHop(bool exactOut, address tokenIn, address tokenOut, uint256 amount)
        internal
        view
        returns (Quote memory best)
    {
        // 1. Base quoter: V2/Sushi/ZAMM/V3/V4 (getQuotes already filters exact-out outliers)
        (best,) = getQuotes(exactOut, tokenIn, tokenOut, amount);
        if (best.source == AMM.WETH_WRAP) best = Quote(AMM.UNI_V2, 0, 0, 0);

        // 2. Curve (unbuildable cases already filtered inside quoteCurve).
        {
            (uint256 cin, uint256 cout, address pool,,,,) = quoteCurve(exactOut, tokenIn, tokenOut, amount, 8);
            if (pool != address(0)) {
                if (_isBetter(exactOut, cin, cout, best.amountIn, best.amountOut)) {
                    best = _asQuote(AMM.CURVE, cin, cout);
                }
            }
        }

        // 3. Lido (ETH→stETH/wstETH direct stake — competes on rate like any other AMM)
        if (tokenIn == address(0) && (tokenOut == STETH || tokenOut == WSTETH)) {
            (uint256 lin, uint256 lout) = quoteLido(exactOut, tokenOut, amount);
            if (lin != 0 || lout != 0) {
                if (_isBetter(exactOut, lin, lout, best.amountIn, best.amountOut)) {
                    best = _asQuote(AMM.LIDO, lin, lout);
                }
            }
        }
    }

    /// @dev Best exactIn direct quote, excluding LIDO and WETH_WRAP. Used by split
    ///      builders that can't safely use LIDO (callvalue semantics) or WETH_WRAP
    ///      (trivial 1:1, not a real route). Considers all base-quoter sources + Curve.
    function _bestDirectExcludingLido(address tokenIn, address tokenOut, uint256 swapAmount)
        internal
        view
        returns (Quote memory best)
    {
        (, Quote[] memory quotes) = getQuotes(false, tokenIn, tokenOut, swapAmount);
        for (uint256 i; i < quotes.length; ++i) {
            if (quotes[i].source == AMM.LIDO || quotes[i].source == AMM.WETH_WRAP) continue;
            if (quotes[i].amountOut > best.amountOut) best = quotes[i];
        }
        (uint256 cin, uint256 cout, address pool,,,,) = quoteCurve(false, tokenIn, tokenOut, swapAmount, 8);
        if (pool != address(0) && cout > best.amountOut) best = _asQuote(AMM.CURVE, cin, cout);
    }

    // zRouter calldata builders:

    error NoRoute();

    /// @dev Normalize CURVE_ETH sentinel to address(0) so all ETH logic is consistent.
    function _normalizeETH(address token) internal pure returns (address) {
        return token == CURVE_ETH ? address(0) : token;
    }

    /// @dev zRouter treats `deadline == type(uint256).max` on swapV2 as a sentinel that
    ///      routes execution to the Sushi factory. Callers who pass max (e.g. "no expiry")
    ///      would therefore silently get a Sushi pool for a quote the base quoter gave
    ///      for the Uniswap V2 pool. Use this only on the UNI_V2 encode path — do NOT
    ///      apply globally, because swapVZ also uses max as a sentinel (ZAMM_0 vs ZAMM)
    ///      and the base quoter's zAMM source may depend on the caller-supplied deadline.
    function _v2Deadline(bool isSushi, uint256 deadline) internal view returns (uint256) {
        if (isSushi) return type(uint256).max; // sentinel: router selects SUSHI_FACTORY
        return deadline == type(uint256).max ? block.timestamp + 30 minutes : deadline;
    }

    function _hubs() internal pure returns (address[6] memory) {
        return [WETH, USDC, USDT, DAI, WBTC, WSTETH];
    }

    function _sweepTo(address token, address to) internal pure returns (bytes memory) {
        return _sweepAmt(token, 0, to);
    }

    /// @dev Assembly-built sweep(token, 0, amount, to) calldata. Replaces four scattered
    ///      abi.encodeWithSelector sites with one shared encoder to shrink bytecode.
    function _sweepAmt(address token, uint256 amount, address to) internal pure returns (bytes memory data) {
        bytes4 sel = IRouterExt.sweep.selector;
        data = new bytes(0x84);
        assembly ("memory-safe") {
            let p := add(data, 0x20)
            mstore(p, sel)
            mstore(add(p, 0x04), token)
            mstore(add(p, 0x24), 0)
            mstore(add(p, 0x44), amount)
            mstore(add(p, 0x64), to)
        }
    }

    function _mc(bytes[] memory c) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IRouterExt.multicall.selector, c);
    }

    function _mc1(bytes memory cd) internal pure returns (bytes memory) {
        bytes[] memory c = new bytes[](1);
        c[0] = cd;
        return _mc(c);
    }

    /// @dev Shared exactIn fallback used by split/hybrid edge cases (trivial wrap,
    ///     no split, 100/0 or 0/100 split, 100% direct hybrid). Returns the best
    ///     exactIn quote for the full pair, its calldata wrapped in a 1-element
    ///     multicall envelope, and msgValue — so call sites become one expression.
    function _fallbackBest(address to, address tokenIn, address tokenOut, uint256 amount, uint256 bps, uint256 dl)
        internal
        view
        returns (Quote memory q, bytes memory multicall, uint256 msgValue)
    {
        bytes memory cd;
        (q, cd,, msgValue) = buildBestSwap(to, false, tokenIn, tokenOut, amount, bps, dl);
        multicall = _mc1(cd);
    }

    /// @dev Append a (optionally pre-wrapped) leg to calls_. Used by split/hybrid paths
    ///     when a Curve leg with ETH input needs a WETH pre-wrap plus route[0] rewrite.
    ///     Deduplicates 4 copies of `if (wrap) { _wrap + mstore(cd,100,WETH) } append(cd)`.
    function _appendLegMaybeWrap(bytes[] memory calls_, uint256 ci, bytes memory cd, bool needsWrap, uint256 amt)
        internal
        pure
        returns (uint256)
    {
        if (needsWrap) {
            calls_[ci++] = _wrap(amt);
            assembly ("memory-safe") { mstore(add(cd, 100), WETH) }
        }
        calls_[ci++] = cd;
        return ci;
    }

    function _wrap(uint256 a) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IRouterExt.wrap.selector, a);
    }

    function _depUnwrap(uint256 a) internal pure returns (bytes memory d, bytes memory u) {
        d = abi.encodeWithSelector(IRouterExt.deposit.selector, WETH, uint256(0), a);
        u = abi.encodeWithSelector(IRouterExt.unwrap.selector, a);
    }

    function _i8(int128 x) internal pure returns (uint8) {
        return uint8(uint256(int256(x)));
    }

    function _isBetter(bool exactOut, uint256 newIn, uint256 newOut, uint256 bestIn, uint256 bestOut)
        internal
        pure
        returns (bool)
    {
        return exactOut ? (newIn > 0 && (newIn < bestIn || bestIn == 0)) : (newOut > bestOut);
    }

    // ** CURVE

    // ====================== QUOTE (auto-discover via MetaRegistry) ======================

    // Accumulator for 2-hop hub routing
    struct HubPlan {
        bool found;
        bool isExactOut;
        address mid;
        Quote a;
        Quote b;
        bytes ca;
        bytes cb;
        uint256 scoreIn;
        uint256 scoreOut;
    }

    // Accumulator for 3-hop route discovery
    struct Route3 {
        bool found;
        Quote a;
        Quote b;
        Quote c;
        address mid1;
        address mid2;
        uint256 score;
    }

    // Accumulator to keep best candidate off the stack
    struct CurveAcc {
        uint256 bestOut;
        uint256 bestIn;
        address bestPool;
        bool usedUnderlying;
        bool usedStable;
        uint8 iIdx;
        uint8 jIdx;
    }

    // Single-hop Curve quote with deterministic discovery, returns coin indices too
    function quoteCurve(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 maxCandidates // e.g. 8, 0 = unlimited
    )
        public
        view
        returns (
            uint256 amountIn,
            uint256 amountOut,
            address bestPool,
            bool usedUnderlying,
            bool usedStable,
            uint8 iIndex,
            uint8 jIndex
        )
    {
        if (swapAmount == 0) return (0, 0, address(0), false, true, 0, 0);

        // trivial ETH<->WETH (1:1) — let base path handle; we won't override with Curve
        if ((tokenIn == address(0) && tokenOut == WETH) || (tokenIn == WETH && tokenOut == address(0))) {
            return (0, 0, address(0), false, true, 0, 0);
        }

        // MetaRegistry discovery: crypto pools (e.g. tricrypto) register coins as
        // WETH, not the ETH sentinel. Query both representations and merge results
        // so we find all pools regardless of how they store their ETH-like coin.
        bool ethIn = tokenIn == address(0);
        bool ethOut = tokenOut == address(0);
        address aEth = ethIn ? CURVE_ETH : tokenIn;
        address bEth = ethOut ? CURVE_ETH : tokenOut;
        address aWeth = ethIn ? WETH : tokenIn;
        address bWeth = ethOut ? WETH : tokenOut;

        address[] memory pools1 = ICurveMetaRegistry(CURVE_METAREGISTRY).find_pools_for_coins(aEth, bEth);
        address[] memory pools2;
        if (ethIn || ethOut) {
            pools2 = ICurveMetaRegistry(CURVE_METAREGISTRY).find_pools_for_coins(aWeth, bWeth);
        }
        // Apply maxCandidates per-set so the WETH representation pool set (pools2)
        // isn't starved when pools1 alone has >= maxCandidates entries. Without this,
        // ETH pair quoting can miss tricrypto-style WETH-registered crypto pools.
        uint256 cap1 = (maxCandidates == 0 || maxCandidates > pools1.length) ? pools1.length : maxCandidates;
        uint256 cap2 = (maxCandidates == 0 || maxCandidates > pools2.length) ? pools2.length : maxCandidates;
        uint256 limit_ = cap1 + cap2;

        CurveAcc memory acc;
        acc.bestIn = type(uint256).max;

        for (uint256 k; k < limit_; ++k) {
            // Walk pools1 first, then pools2
            bool fromSet2 = k >= cap1;
            address pool = fromSet2 ? pools2[k - cap1] : pools1[k];
            if (pool.code.length == 0) continue;

            // Skip duplicates: only within the *quoted* prefix of pools1. Searching
            // all of pools1 would drop a pool that's in pools2 and also in the
            // capped-out tail of pools1 (which was never actually quoted).
            if (fromSet2 && _inPoolsPrefix(pools1, cap1, pool)) continue;

            // Try coin indices with both address representations
            address qa = fromSet2 ? aWeth : aEth;
            address qb = fromSet2 ? bWeth : bEth;

            (bool idxOk, int128 i, int128 j, bool underlying) = _tryCoinIndices(pool, qa, qb);
            bool primaryHit = idxOk;
            // If the primary representation failed and this is an ETH pair, try the other
            if (!idxOk && (ethIn || ethOut)) {
                address altA = fromSet2 ? aEth : aWeth;
                address altB = fromSet2 ? bEth : bWeth;
                (idxOk, i, j, underlying) = _tryCoinIndices(pool, altA, altB);
            }
            if (!idxOk) continue;
            // For ETH pairs, zRouter's swapCurve always pre-funds the pool with WETH
            // and calls exchange() without msg.value (see zRouter.sol:504-517, 558-563).
            // Pools whose ETH-side coin is the CURVE_ETH sentinel (e.g. Curve's legacy
            // stETH/ETH 0xDC24...7022) require msg.value on exchange() and so cannot be
            // executed by the router — skip them at discovery time.
            //   - fromSet2=false + primary hit: queried with CURVE_ETH → sentinel pool.
            //   - fromSet2=true  + alt hit:     fallback used CURVE_ETH → sentinel pool.
            if ((ethIn || ethOut) && (primaryHit ? !fromSet2 : fromSet2)) continue;

            (bool ok, uint256 qIn, uint256 qOut, bool isStable, bool actuallyUnderlying) =
                _curveTryQuoteOne(pool, exactOut, i, j, underlying, swapAmount);
            if (!ok) continue;

            // Skip unbuildable exactOut stable-underlying when both indices are base coins
            uint8 ci_ = _i8(i);
            uint8 cj_ = _i8(j);
            if (exactOut && actuallyUnderlying && isStable && ci_ > 0 && cj_ > 0) continue;

            bool better = exactOut ? qIn < acc.bestIn : qOut > acc.bestOut;
            if (better) {
                acc.bestIn = exactOut ? qIn : swapAmount;
                acc.bestOut = exactOut ? swapAmount : qOut;
                acc.bestPool = pool;
                acc.usedUnderlying = actuallyUnderlying;
                acc.usedStable = isStable;
                acc.iIdx = ci_;
                acc.jIdx = cj_;
            }
        }

        if (acc.bestPool == address(0)) return (0, 0, address(0), false, true, 0, 0);

        amountIn = exactOut ? acc.bestIn : swapAmount;
        amountOut = exactOut ? swapAmount : acc.bestOut;
        bestPool = acc.bestPool;
        usedUnderlying = acc.usedUnderlying;
        usedStable = acc.usedStable;
        iIndex = acc.iIdx;
        jIndex = acc.jIdx;
    }

    function _inPoolsPrefix(address[] memory pools, uint256 prefixLen, address pool) internal pure returns (bool) {
        for (uint256 i; i < prefixLen; ++i) {
            if (pools[i] == pool) return true;
        }
        return false;
    }

    /// @dev Try to get coin indices from the MetaRegistry; returns (ok, i, j, underlying).
    ///      Wraps the external call in a try/catch so reverts don't propagate.
    function _tryCoinIndices(address pool, address a, address b)
        internal
        view
        returns (bool ok, int128 i, int128 j, bool underlying)
    {
        try ICurveMetaRegistry(CURVE_METAREGISTRY).get_coin_indices(pool, a, b, 0) returns (
            int128 i_, int128 j_, bool u_
        ) {
            if (i_ < 0 || j_ < 0) return (false, 0, 0, false);
            if (uint256(int256(i_)) > type(uint8).max) return (false, 0, 0, false);
            if (uint256(int256(j_)) > type(uint8).max) return (false, 0, 0, false);
            return (true, i_, j_, u_);
        } catch {
            return (false, 0, 0, false);
        }
    }

    // Single-pool quote with ABI autodetect (crypto uint256 indices vs stable int128).
    // Underlying (meta) pools are filtered out by this helper, so usedUnderlying is
    // always false in the returned tuple.
    function _curveTryQuoteOne(address pool, bool exactOut, int128 i, int128 j, bool underlying, uint256 amt)
        internal
        view
        returns (bool ok, uint256 amountIn, uint256 amountOut, bool usedStable, bool usedUnderlying)
    {
        // underlying=true means pool coins are wrapped (aTokens, cTokens, etc.).
        // Skip: exchange() expects wrapped tokens the user doesn't have, and the
        // quoter doesn't populate basePools[] needed for the st=2 exactOut
        // backward pass. The direct-coin pool (e.g. 3pool) will be found instead.
        if (underlying) return (false, 0, 0, false, false);
        bytes4 selD = exactOut ? ICurveStableLike.get_dx.selector : ICurveStableLike.get_dy.selector;
        // Try crypto (uint256) first — pools that support both get_dy signatures
        // may only have exchange(uint256,...), so crypto classification is safer.
        uint256 ui = uint256(int256(i));
        uint256 uj = uint256(int256(j));
        bytes4 sel2 = exactOut ? ICurveCryptoLike.get_dx.selector : ICurveCryptoLike.get_dy.selector;
        (bool s2, bytes memory r2) = pool.staticcall(abi.encodeWithSelector(sel2, ui, uj, amt));
        if (s2 && r2.length >= 32) {
            uint256 q2 = abi.decode(r2, (uint256));
            // Router adds +1 to every get_dx result; mirror it or exactOut reverts at tight slippage.
            return exactOut ? (true, q2 + 1, amt, false, false) : (true, amt, q2, false, false);
        }
        // Fall back to stable (int128)
        (bool sd, bytes memory rd) = pool.staticcall(abi.encodeWithSelector(selD, i, j, amt));
        if (!sd || rd.length < 32) return (false, 0, 0, false, false);
        uint256 q = abi.decode(rd, (uint256));
        return exactOut ? (true, q + 1, amt, true, false) : (true, amt, q, true, false);
    }

    // ====================== BUILD CALLDATA (single-hop) ======================

    function _buildCurveSwapCalldata(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline,
        address pool,
        bool, /* useUnderlying — always false; filtered in _curveTryQuoteOne */
        bool isStable,
        uint8 iIndex,
        uint8 jIndex,
        uint256 amountIn,
        uint256 amountOut
    ) internal pure returns (bytes memory callData, uint256 amountLimit, uint256 msgValue) {
        uint256 pt = isStable ? 10 : 20;
        uint256 quoted = exactOut ? amountIn : amountOut;
        amountLimit = SlippageLib.limit(exactOut, quoted, slippageBps);

        // Build calldata with assembly: avoids allocating address[11] + uint256[4][5] + address[5]
        // Layout: sel(4) + to,exactOut(64) + route[11](352) + swapParams[5][4](640)
        //       + basePools[5](160) + swapAmount,amountLimit,deadline(96) = 1316 bytes
        //
        // ETH-output case: Curve WETH-representation pools output WETH, but zRouter's
        // outBal tracking uses address(this).balance when nextToken==ETH, which doesn't
        // update on a WETH payout and triggers BadSwap() at zRouter.sol:594. Fix: build
        // a 2-hop route [tokenIn, pool, WETH, WETH_dummy, 0(ETH)] with swapParams[1][2]=8
        // (st=8 unwrap hop). Done branchlessly in Yul below to keep bytecode lean.
        bytes4 sel = IZRouter.swapCurve.selector;
        callData = new bytes(1316);
        assembly ("memory-safe") {
            let p := add(callData, 32)
            mstore(p, sel)
            let s := add(p, 4)
            mstore(s, to)
            mstore(add(s, 0x20), exactOut)
            mstore(add(s, 0x40), tokenIn)
            mstore(add(s, 0x60), pool)
            // e = 1 when tokenOut == 0 (ETH output), else 0
            let e := iszero(tokenOut)
            // route[2] = e ? WETH : tokenOut  (tokenOut is 0 when e=1, so OR is clean)
            mstore(add(s, 0x80), or(tokenOut, mul(e, WETH)))
            // route[3] = e ? WETH : 0  (non-zero sentinel so outer loop enters the unwrap hop)
            mstore(add(s, 0xa0), mul(e, WETH))
            // swapParams[0] = [iIndex, jIndex, 1, pt]
            mstore(add(s, 0x1a0), iIndex)
            mstore(add(s, 0x1c0), jIndex)
            mstore(add(s, 0x1e0), 1)
            mstore(add(s, 0x200), pt)
            // swapParams[1][2] = e ? 8 : 0 (st=8 WETH→ETH unwrap)
            mstore(add(s, 0x260), mul(e, 8))
            mstore(add(s, 0x4c0), swapAmount)
            mstore(add(s, 0x4e0), amountLimit)
            mstore(add(s, 0x500), deadline)
        }

        msgValue = (tokenIn == address(0)) ? (exactOut ? amountLimit : swapAmount) : 0;
    }

    // ====================== LIDO QUOTE & BUILDER ======================

    /// @notice Quote ETH → stETH or ETH → wstETH via Lido staking (1:1 for stETH, rate-based for wstETH).
    function quoteLido(bool exactOut, address tokenOut, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (swapAmount == 0) return (0, 0);

        uint256 totalShares = IStETH(STETH).getTotalShares();
        uint256 totalPooled = IStETH(STETH).getTotalPooledEther();
        if (totalShares == 0 || totalPooled == 0) return (0, 0);

        if (tokenOut == STETH) {
            if (!exactOut) {
                // ETH → stETH is 1:1
                return (swapAmount, swapAmount);
            } else {
                // Match router's ethToExactSTETH double-ceil math:
                // sharesNeeded = ceil(exactOut * totalShares / totalPooled)
                // ethIn        = ceil(sharesNeeded * totalPooled / totalShares)
                uint256 sharesNeeded = (swapAmount * totalShares + totalPooled - 1) / totalPooled;
                uint256 ethIn = (sharesNeeded * totalPooled + totalShares - 1) / totalShares;
                if (ethIn == 0) return (0, 0);
                return (ethIn, swapAmount);
            }
        } else if (tokenOut == WSTETH) {
            if (!exactOut) {
                // exactIn: swapAmount ETH → stETH (1:1) → wstETH
                // wstETH = stETH * totalShares / totalPooled
                uint256 wstOut = (swapAmount * totalShares) / totalPooled;
                if (wstOut == 0) return (0, 0);
                return (swapAmount, wstOut);
            } else {
                // exactOut: need swapAmount wstETH
                // ethIn = ceil(swapAmount * totalPooled / totalShares)
                uint256 ethIn = (swapAmount * totalPooled + totalShares - 1) / totalShares;
                if (ethIn == 0) return (0, 0);
                return (ethIn, swapAmount);
            }
        }

        return (0, 0);
    }

    /// @notice Build router calldata for a Lido swap (ETH → stETH or ETH → wstETH).
    function _buildLidoSwap(address to, bool exactOut, address tokenOut, uint256 swapAmount)
        internal
        pure
        returns (bytes memory)
    {
        // Pick the selector from a 2x2 (token × exactOut) table, then encode once.
        // Halves the number of distinct abi.encodeWithSelector sites (4 → 2).
        bytes4 sel;
        if (tokenOut == STETH) {
            sel = exactOut ? IZRouter.ethToExactSTETH.selector : IZRouter.exactETHToSTETH.selector;
        } else if (tokenOut == WSTETH) {
            sel = exactOut ? IZRouter.ethToExactWSTETH.selector : IZRouter.exactETHToWSTETH.selector;
        } else {
            revert NoRoute();
        }
        return exactOut ? abi.encodeWithSelector(sel, to, swapAmount) : abi.encodeWithSelector(sel, to);
    }

    // ====================== TOP-LEVEL BUILDER (with Curve override) ======================

    function buildBestSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) public view returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) {
        tokenIn = _normalizeETH(tokenIn);
        tokenOut = _normalizeETH(tokenOut);

        // ---------- ETH <-> WETH (1:1, no slippage) ----------
        if ((tokenIn == address(0) && tokenOut == WETH) || (tokenIn == WETH && tokenOut == address(0))) {
            best = _asQuote(AMM.WETH_WRAP, swapAmount, swapAmount);
            amountLimit = swapAmount; // 1:1, no slippage

            if (tokenIn == address(0)) {
                // ETH -> WETH
                msgValue = swapAmount;
                if (to == ZROUTER) {
                    callData = _wrap(swapAmount);
                } else {
                    bytes[] memory c = new bytes[](2);
                    c[0] = _wrap(swapAmount);
                    c[1] = _sweepAmt(WETH, swapAmount, to);
                    callData = _mc(c);
                }
            } else {
                // WETH -> ETH
                msgValue = 0;
                (bytes memory dep, bytes memory unw) = _depUnwrap(swapAmount);
                if (to == ZROUTER) {
                    bytes[] memory c = new bytes[](2);
                    c[0] = dep;
                    c[1] = unw;
                    callData = _mc(c);
                } else {
                    bytes[] memory c = new bytes[](3);
                    c[0] = dep;
                    c[1] = unw;
                    c[2] = _sweepAmt(address(0), swapAmount, to);
                    callData = _mc(c);
                }
            }
            return (best, callData, amountLimit, msgValue);
        }

        // ---------- Normal path ----------
        // Single unified quote across all sources (V2/Sushi/V3/V4/ZAMM/Curve/Lido)
        best = _quoteBestSingleHop(exactOut, tokenIn, tokenOut, swapAmount);
        if (exactOut ? best.amountIn == 0 : best.amountOut == 0) revert NoRoute();

        uint256 quoted = exactOut ? best.amountIn : best.amountOut;
        amountLimit = SlippageLib.limit(exactOut, quoted, slippageBps);

        callData = _buildCalldataFromBest(
            to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, slippageBps, deadline, best
        );

        msgValue = tokenIn == address(0) ? (exactOut ? amountLimit : swapAmount) : 0;
    }

    /// @notice One-call quote+build that returns the same shape as buildBestSwap.
    ///         Cascade (NOT a head-to-head comparison across depths): single/2-hop
    ///         first, 3-hop only as a fallback for pairs that can't build at shallower
    ///         depth. Frontends can use this as a drop-in for buildBestSwap — no
    ///         decoder changes — and recover every pair that has *any* on-chain path.
    ///
    ///         Cascade:
    ///           1. buildBestSwapViaETHMulticall — internally picks best of {single-hop, 2-hop hub}
    ///           2. build3HopMulticall           — last-resort for exotic tokens (exactIn + exactOut)
    ///
    ///         Note: step 1 wraps single-hop results in a 1-element multicall envelope
    ///         (~2–3k extra gas), but guarantees we never miss a strictly-better hub
    ///         route just because a marginal single-hop pool also happened to quote.
    ///         For custom tokens this matters: a user's exotic token may have a
    ///         stale V3 1bp pool that buildBestSwap would prefer, while the deep
    ///         liquidity actually lives on a WETH-hub 2-hop path.
    ///
    ///         The returned `best` aggregates multi-hop plans into a single Quote
    ///         with end-to-end amounts (source = final leg's source).
    function buildSwapAuto(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) public view returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) {
        // Defensive: no-op swap (tokenIn == tokenOut after ETH/WETH normalization).
        // Without this, inner builders produce nonsense quotes or revert with an
        // opaque error depending on which code path gets hit first.
        if (_normalizeETH(tokenIn) == _normalizeETH(tokenOut)) revert NoRoute();

        // 1. Best of {single-hop, 2-hop hub}. buildBestSwapViaETHMulticall's
        //    internal logic only prefers hub if it's strictly better (>2% for
        //    exactIn, or single-hop unavailable for exactOut), so this gives
        //    optimal quote across both depths in one pass.
        try this.buildBestSwapViaETHMulticall(
            to, to, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline
        ) returns (
            Quote memory a, Quote memory b, bytes[] memory, bytes memory mc, uint256 mv
        ) {
            bool twoHop = (b.amountIn != 0 || b.amountOut != 0);
            best.source = twoHop ? b.source : a.source;
            best.feeBps = twoHop ? b.feeBps : a.feeBps;
            best.amountIn = a.amountIn;
            best.amountOut = twoHop ? b.amountOut : a.amountOut;
            callData = mc;
            amountLimit = SlippageLib.limit(exactOut, exactOut ? best.amountIn : best.amountOut, slippageBps);
            msgValue = mv;
            return (best, callData, amountLimit, msgValue);
        } catch {}

        // 2. 3-hop last resort for exotic custom tokens with no direct or 2-hop-via-hub pool.
        //    Supported for both exactIn and exactOut after the exactOut extension to
        //    build3HopMulticall.
        try this.build3HopMulticall(to, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline) returns (
            Quote memory a_, Quote memory, Quote memory c_, bytes[] memory, bytes memory mc, uint256 mv
        ) {
            if (exactOut) {
                // leg-1's amountIn is the end-to-end input; tokenOut amount is the user's target.
                best.source = c_.source;
                best.feeBps = c_.feeBps;
                best.amountIn = a_.amountIn;
                best.amountOut = swapAmount;
                amountLimit = SlippageLib.limit(true, best.amountIn, slippageBps);
            } else {
                best.source = c_.source;
                best.feeBps = c_.feeBps;
                best.amountIn = swapAmount;
                best.amountOut = c_.amountOut;
                amountLimit = SlippageLib.limit(false, best.amountOut, slippageBps);
            }
            callData = mc;
            msgValue = mv;
            return (best, callData, amountLimit, msgValue);
        } catch {}

        revert NoRoute();
    }

    function _spacingFromBps(uint16 bps) internal pure returns (int24) {
        unchecked {
            if (bps == 1) return 1;
            if (bps == 5) return 10;
            if (bps == 30) return 60;
            if (bps == 100) return 200;
            return int24(uint24(bps));
        }
    }

    function _bestSingleHop(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 slippageBps,
        uint256 deadline
    ) internal view returns (bool ok, Quote memory q, bytes memory data, uint256 amountLimit, uint256 msgValue) {
        try this.buildBestSwap(to, exactOut, tokenIn, tokenOut, amount, slippageBps, deadline) returns (
            Quote memory q_, bytes memory d_, uint256 l_, uint256 v_
        ) {
            return (true, q_, d_, l_, v_);
        } catch {
            return (false, q, bytes(""), 0, 0);
        }
    }

    // ** MULTIHOP HELPER

    function buildBestSwapViaETHMulticall(
        address to,
        address refundTo,
        bool exactOut, // false = exactIn, true = exactOut (on tokenOut)
        address tokenIn, // ERC20 or address(0) for ETH
        address tokenOut, // ERC20 or address(0) for ETH
        uint256 swapAmount, // exactIn: amount of tokenIn; exactOut: desired tokenOut
        uint256 slippageBps, // per-leg bound
        uint256 deadline
    )
        public
        view
        returns (Quote memory a, Quote memory b, bytes[] memory calls, bytes memory multicall, uint256 msgValue)
    {
        unchecked {
            tokenIn = _normalizeETH(tokenIn);
            tokenOut = _normalizeETH(tokenOut);

            // Prevent stealable leftovers: if refundTo is the router itself, coerce to `to`.
            if (refundTo == ZROUTER && to != ZROUTER) refundTo = to;

            // ---------- FAST PATH #1: pure ETH<->WETH wrap/unwrap ----------
            bool trivialWrap =
                (tokenIn == address(0) && tokenOut == WETH) || (tokenIn == WETH && tokenOut == address(0));
            if (trivialWrap) {
                a = _asQuote(AMM.WETH_WRAP, swapAmount, swapAmount);
                b = Quote(AMM.UNI_V2, 0, 0, 0);

                if (tokenIn == address(0)) {
                    // ETH -> WETH: wrap exact amount then sweep WETH to recipient
                    calls = new bytes[](2);
                    calls[0] = _wrap(swapAmount);
                    calls[1] = _sweepTo(WETH, to);
                    msgValue = swapAmount;
                } else {
                    // WETH -> ETH: deposit WETH, unwrap exact amount, sweep ETH to recipient
                    calls = new bytes[](3);
                    (calls[0], calls[1]) = _depUnwrap(swapAmount);
                    calls[2] = _sweepTo(address(0), to);
                    msgValue = 0;
                }

                multicall = _mc(calls);
                return (a, b, calls, multicall, msgValue);
            }

            // ---------- FAST PATH #2: direct single-hop (may be Curve/V2/V3/V4/zAMM) ----------
            // We always try hub routing too and compare, because low-liquidity pools
            // (e.g. V3 1bp) can return tiny dust outputs that technically "succeed" but
            // produce reverts at execution or give users effectively nothing.
            bool _singleOk;
            Quote memory _singleBest;
            bytes memory _singleCallData;
            uint256 _singleMsgValue;
            {
                (bool ok, Quote memory best, bytes memory callData,, uint256 val) =
                    _bestSingleHop(to, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline);

                if (ok) {
                    _singleOk = true;
                    _singleBest = best;
                    _singleCallData = callData;
                    _singleMsgValue = val;
                }
            }

            // ---------- HUB LIST (majors) ----------
            address[6] memory HUBS = _hubs();

            // Track the best hub plan we can actually build
            HubPlan memory plan;
            plan.isExactOut = exactOut;

            for (uint256 h; h < HUBS.length; ++h) {
                address MID = HUBS[h];
                if (MID == tokenIn || MID == tokenOut) continue;

                if (!exactOut) {
                    // ---- overall exactIn: maximize final output ----
                    (bool okA, Quote memory qa, bytes memory ca,,) =
                        _bestSingleHop(ZROUTER, false, tokenIn, MID, swapAmount, slippageBps, deadline);
                    // Skip Lido for intermediate hops: Lido functions don't depositFor,
                    // so the next leg can't find the tokens via transient storage.
                    if (!okA || qa.amountOut == 0 || qa.source == AMM.LIDO) continue;

                    uint256 midAmtForLeg2 = SlippageLib.limit(false, qa.amountOut, slippageBps);
                    (bool okB, Quote memory qb, bytes memory cb,,) =
                        _bestSingleHop(to, false, MID, tokenOut, midAmtForLeg2, slippageBps, deadline);
                    if (!okB || qb.amountOut == 0) continue;

                    uint256 scoreOut = qb.amountOut; // maximize

                    if (!plan.found || scoreOut > plan.scoreOut) {
                        plan.found = true;
                        plan.mid = MID;
                        plan.isExactOut = false;
                        plan.a = qa;
                        plan.b = qb;
                        plan.ca = ca;
                        plan.cb = cb;
                        plan.scoreOut = scoreOut;
                    }
                } else {
                    // ---- overall exactOut: minimize total input ----
                    // Always route both legs through ZROUTER to avoid correctness issues
                    // with prefunding V2 pools (Curve/zAMM don't mark transient for the pair,
                    // and exactOut prefund risks donating excess to LPs).
                    (bool okB, Quote memory qb, bytes memory cb,,) =
                        _bestSingleHop(ZROUTER, true, MID, tokenOut, swapAmount, slippageBps, deadline);
                    if (!okB || qb.amountIn == 0 || qb.source == AMM.LIDO) continue;

                    uint256 midRequired = qb.amountIn;
                    uint256 midLimit = SlippageLib.limit(true, midRequired, slippageBps);

                    (bool okA, Quote memory qa, bytes memory ca,,) =
                        _bestSingleHop(ZROUTER, true, tokenIn, MID, midLimit, slippageBps, deadline);
                    if (!okA || qa.amountIn == 0 || qa.source == AMM.LIDO) continue;

                    uint256 scoreIn = qa.amountIn; // minimize

                    if (!plan.found || scoreIn < plan.scoreIn) {
                        plan.found = true;
                        plan.mid = MID;
                        plan.isExactOut = true;
                        plan.a = qa;
                        plan.b = qb;
                        plan.ca = ca;
                        plan.cb = cb;
                        plan.scoreIn = scoreIn;
                    }
                }
            }

            // ---------- pick winner: single-hop vs hub routing ----------
            // exactOut: prefer direct (reliability > marginal savings). Hub only if no direct.
            // exactIn: hub must be >2% better to justify multi-leg complexity.
            if (plan.found) {
                bool hubBetter;
                if (exactOut) {
                    hubBetter = !_singleOk;
                } else {
                    hubBetter = !_singleOk || plan.scoreOut * 49 > _singleBest.amountOut * 50;
                }
                if (!hubBetter) plan.found = false;
            }

            if (!plan.found) {
                // Use single-hop (or revert if neither worked)
                if (!_singleOk) revert NoRoute();
                calls = new bytes[](1);
                calls[0] = _singleCallData;
                a = _singleBest;
                b = Quote(AMM.UNI_V2, 0, 0, 0);
                msgValue = _singleMsgValue;
                multicall = _mc(calls);
                return (a, b, calls, multicall, msgValue);
            }

            // ---------- materialize the chosen hub plan into calls ----------
            if (!plan.isExactOut) {
                // exactIn path: two calls, no sweeps
                calls = new bytes[](2);
                calls[0] = plan.ca; // hop-1 tokenIn -> MID (exactIn)
                // hop-2: swapAmount=0 so router auto-consumes full MID balance
                calls[1] = _buildCalldataFromBest(
                    to,
                    false,
                    plan.mid,
                    tokenOut,
                    0,
                    SlippageLib.limit(false, plan.b.amountOut, slippageBps),
                    slippageBps,
                    deadline,
                    plan.b
                );
                a = plan.a;
                b = plan.b;
                // If tokenIn is ETH, hop-1 needs ETH for exactIn
                msgValue = (tokenIn == address(0)) ? swapAmount : 0;
            } else {
                // exactOut path: both legs route to ZROUTER, then explicit sweeps.
                // Unconditionally sweep all possible leftover tokens to avoid stranding
                // funds in the router (where sweep() is public).
                bool chaining = (to == ZROUTER);
                bool ethInput = (tokenIn == address(0));

                // Count finalization calls (when not chaining, sweep everything out):
                //   1) tokenOut delivery (exact swapAmount)
                //   2) MID leftover refund (over-production from slippage buffer)
                //   3) tokenIn leftover refund (any venue can leave dust in exactOut)
                //   4) ETH dust refund (when tokenIn is ETH)
                uint256 extra;
                if (!chaining) {
                    extra++; // tokenOut delivery
                    extra++; // MID leftover
                    if (!ethInput) extra++; // tokenIn leftover (ERC20)
                    extra++; // ETH dust (always: even non-ETH input can have ETH from unwraps)
                }

                calls = new bytes[](2 + extra);
                uint256 k;
                calls[k++] = plan.ca; // hop-1 tokenIn -> MID (exactOut, to=ZROUTER)
                calls[k++] = plan.cb; // hop-2 MID -> tokenOut (exactOut, to=ZROUTER)

                if (!chaining) {
                    // Deliver exact output amount to recipient
                    calls[k++] = _sweepAmt(tokenOut, swapAmount, to);
                    // Refund leftover MID (as-is, WETH stays as WETH)
                    calls[k++] = _sweepTo(plan.mid, refundTo);
                    // Refund leftover tokenIn (ERC20 only; ETH covered by ETH dust sweep)
                    if (!ethInput) {
                        calls[k++] = _sweepTo(tokenIn, refundTo);
                    }
                    // Refund any ETH dust
                    calls[k++] = _sweepTo(address(0), refundTo);
                }

                a = plan.a;
                b = plan.b;
                // If tokenIn is ETH, hop-1 exactOut needs ETH equal to its maxIn limit
                msgValue = ethInput ? SlippageLib.limit(true, plan.a.amountIn, slippageBps) : 0;
            }

            multicall = _mc(calls);
            return (a, b, calls, multicall, msgValue);
        }
    }

    // ** 3-HOP MULTIHOP BUILDER

    /// @notice Encode a non-Curve single-hop swap from a Quote with an arbitrary
    ///         swapAmount.  Pass swapAmount = 0 so the router auto-reads its own
    ///         token balance as the input amount (exactIn only).
    function _buildSwapFromQuote(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline,
        Quote memory q
    ) internal view returns (bytes memory) {
        if (q.source == AMM.UNI_V2 || q.source == AMM.SUSHI) {
            return abi.encodeWithSelector(
                IZRouter.swapV2.selector,
                to,
                exactOut,
                tokenIn,
                tokenOut,
                swapAmount,
                amountLimit,
                _v2Deadline(q.source == AMM.SUSHI, deadline)
            );
        } else if (q.source == AMM.ZAMM) {
            return abi.encodeWithSelector(
                IZRouter.swapVZ.selector,
                to,
                exactOut,
                q.feeBps,
                tokenIn,
                tokenOut,
                0,
                0,
                swapAmount,
                amountLimit,
                deadline
            );
        } else if (q.source == AMM.UNI_V3) {
            return abi.encodeWithSelector(
                IZRouter.swapV3.selector,
                to,
                exactOut,
                uint24(q.feeBps * 100),
                tokenIn,
                tokenOut,
                swapAmount,
                amountLimit,
                deadline
            );
        } else if (q.source == AMM.UNI_V4) {
            return abi.encodeWithSelector(
                IZRouter.swapV4.selector,
                to,
                exactOut,
                uint24(q.feeBps * 100),
                _spacingFromBps(uint16(q.feeBps)),
                tokenIn,
                tokenOut,
                swapAmount,
                amountLimit,
                deadline
            );
        }
        revert NoRoute();
    }

    /// @dev Enumerate every ordered (MID1, MID2) hub pair for exactIn — maximize output.
    ///      Split from exactOut into its own helper so each version fits via-ir's stack.
    function _discover3HopForward(address tokenIn, address tokenOut, uint256 swapAmount, uint256 slippageBps)
        internal
        view
        returns (Route3 memory r)
    {
        address[6] memory HUBS = _hubs();
        unchecked {
            for (uint256 i; i < HUBS.length; ++i) {
                address MID1 = HUBS[i];
                if (MID1 == tokenIn || MID1 == tokenOut) continue;

                Quote memory qa = _quoteBestSingleHop(false, tokenIn, MID1, swapAmount);
                if (qa.amountOut == 0 || qa.source == AMM.LIDO) continue;
                uint256 mid1Amt = SlippageLib.limit(false, qa.amountOut, slippageBps);

                for (uint256 j; j < HUBS.length; ++j) {
                    address MID2 = HUBS[j];
                    if (MID2 == tokenIn || MID2 == tokenOut || MID2 == MID1) continue;
                    uint256 mid2Amt;
                    Quote memory qb = _quoteBestSingleHop(false, MID1, MID2, mid1Amt);
                    if (qb.amountOut == 0) continue;
                    mid2Amt = SlippageLib.limit(false, qb.amountOut, slippageBps);
                    Quote memory qc = _quoteBestSingleHop(false, MID2, tokenOut, mid2Amt);
                    if (qc.amountOut == 0) continue;

                    if (!r.found || qc.amountOut > r.score) {
                        r.found = true;
                        r.a = qa;
                        r.b = qb;
                        r.c = qc;
                        r.mid1 = MID1;
                        r.mid2 = MID2;
                        r.score = qc.amountOut;
                    }
                }
            }
        }
    }

    /// @dev Enumerate every ordered (MID1, MID2) hub pair for exactOut — minimize input
    ///      via a backward pass from `swapAmount` of tokenOut.
    function _discover3HopBackward(address tokenIn, address tokenOut, uint256 swapAmount, uint256 slippageBps)
        internal
        view
        returns (Route3 memory r)
    {
        address[6] memory HUBS = _hubs();
        r.score = type(uint256).max;
        unchecked {
            for (uint256 i; i < HUBS.length; ++i) {
                address MID1 = HUBS[i];
                if (MID1 == tokenIn || MID1 == tokenOut) continue;

                for (uint256 j; j < HUBS.length; ++j) {
                    address MID2 = HUBS[j];
                    if (MID2 == tokenIn || MID2 == tokenOut || MID2 == MID1) continue;

                    Quote memory qc = _quoteBestSingleHop(true, MID2, tokenOut, swapAmount);
                    if (qc.amountIn == 0 || qc.source == AMM.LIDO) continue;

                    Quote memory qb =
                        _quoteBestSingleHop(true, MID1, MID2, SlippageLib.limit(true, qc.amountIn, slippageBps));
                    if (qb.amountIn == 0 || qb.source == AMM.LIDO) continue;

                    Quote memory qa =
                        _quoteBestSingleHop(true, tokenIn, MID1, SlippageLib.limit(true, qb.amountIn, slippageBps));
                    if (qa.amountIn == 0 || qa.source == AMM.LIDO) continue;

                    if (qa.amountIn < r.score) {
                        r.found = true;
                        r.a = qa;
                        r.b = qb;
                        r.c = qc;
                        r.mid1 = MID1;
                        r.mid2 = MID2;
                        r.score = qa.amountIn;
                    }
                }
            }
        }
    }

    /// @notice Build a 3-hop multicall through two hub intermediates:
    ///           tokenIn ─[Leg1]→ MID1 ─[Leg2]→ MID2 ─[Leg3]→ tokenOut
    ///
    ///         exactIn:  legs 2 & 3 pass swapAmount=0 so each router leg
    ///                   auto-consumes the previous leg's transient balance.
    ///         exactOut: each leg has an explicit target (backward-calc'd from
    ///                   `swapAmount` of tokenOut). Hub leftovers + ETH dust
    ///                   are swept to `to` in the envelope to avoid stranding
    ///                   funds in the router.
    ///
    ///         Discovery: tries every ordered pair (MID1, MID2) from the hub
    ///         list. exactIn maximizes final output; exactOut minimizes required
    ///         input. All AMMs (V2/Sushi/V3/V4/zAMM/Curve) compete per leg.
    function build3HopMulticall(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    )
        public
        view
        returns (
            Quote memory a,
            Quote memory b,
            Quote memory c,
            bytes[] memory calls,
            bytes memory multicall,
            uint256 msgValue
        )
    {
        unchecked {
            tokenIn = _normalizeETH(tokenIn);
            tokenOut = _normalizeETH(tokenOut);

            Route3 memory r = exactOut
                ? _discover3HopBackward(tokenIn, tokenOut, swapAmount, slippageBps)
                : _discover3HopForward(tokenIn, tokenOut, swapAmount, slippageBps);
            if (!r.found) revert NoRoute();

            if (!exactOut) {
                calls = new bytes[](3);

                // Leg 1: pin to the discovered quote (r.a) rather than re-querying via
                // buildBestSwap. Discovery filtered LIDO for hub legs, but buildBestSwap
                // considers LIDO and could re-select it for e.g. ETH→WSTETH, making the
                // executed path diverge from the scored one.
                a = r.a;
                calls[0] = _buildCalldataFromBest(
                    ZROUTER,
                    false,
                    tokenIn,
                    r.mid1,
                    swapAmount,
                    SlippageLib.limit(false, r.a.amountOut, slippageBps),
                    slippageBps,
                    deadline,
                    r.a
                );
                msgValue = tokenIn == address(0) ? swapAmount : 0;

                // Legs 2 & 3: swapAmount=0 → router auto-consumes previous leg's transient balance
                calls[1] = _buildCalldataFromBest(
                    ZROUTER,
                    false,
                    r.mid1,
                    r.mid2,
                    0,
                    SlippageLib.limit(false, r.b.amountOut, slippageBps),
                    slippageBps,
                    deadline,
                    r.b
                );
                calls[2] = _buildCalldataFromBest(
                    to,
                    false,
                    r.mid2,
                    tokenOut,
                    0,
                    SlippageLib.limit(false, r.c.amountOut, slippageBps),
                    slippageBps,
                    deadline,
                    r.c
                );

                b = r.b;
                c = r.c;
                multicall = _mc(calls);
            } else {
                // exactOut: each leg has an explicit target, and we sweep MID1/MID2/tokenIn/ETH
                // leftovers to `to` so no funds are stranded on the router.
                bool chaining = (to == ZROUTER);
                bool ethInput = (tokenIn == address(0));
                uint256 extra = chaining ? 0 : (3 + (ethInput ? 1 : 2)); // tokenOut, mid1, mid2, [tokenIn?], ETH
                calls = new bytes[](3 + extra);

                uint256 mid1Target = SlippageLib.limit(true, r.b.amountIn, slippageBps);
                uint256 mid2Target = SlippageLib.limit(true, r.c.amountIn, slippageBps);

                // Leg 1: pin to discovered r.a (discovery filtered LIDO for hub legs;
                // buildBestSwap would re-query and might re-select it).
                a = r.a;
                calls[0] = _buildCalldataFromBest(
                    ZROUTER,
                    true,
                    tokenIn,
                    r.mid1,
                    mid1Target,
                    SlippageLib.limit(true, r.a.amountIn, slippageBps),
                    slippageBps,
                    deadline,
                    r.a
                );
                msgValue = ethInput ? SlippageLib.limit(true, r.a.amountIn, slippageBps) : 0;
                // Leg 2: MID1 -> MID2, exactOut target=mid2Target
                calls[1] = _buildCalldataFromBest(
                    ZROUTER, true, r.mid1, r.mid2, mid2Target, mid1Target, slippageBps, deadline, r.b
                );
                // Leg 3: MID2 -> tokenOut. Route to ZROUTER so the tokenOut sweep below
                // delivers exactly `swapAmount` to `to`. Without this, leg-3 would send
                // directly to `to` and the subsequent sweep (which transfers `swapAmount`
                // from the router) would revert on a 0 router balance.
                calls[2] = _buildCalldataFromBest(
                    ZROUTER, true, r.mid2, tokenOut, swapAmount, mid2Target, slippageBps, deadline, r.c
                );

                if (!chaining) {
                    uint256 k = 3;
                    calls[k++] = _sweepAmt(tokenOut, swapAmount, to);
                    calls[k++] = _sweepTo(r.mid1, to);
                    calls[k++] = _sweepTo(r.mid2, to);
                    if (!ethInput) calls[k++] = _sweepTo(tokenIn, to);
                    calls[k++] = _sweepTo(address(0), to);
                }

                b = r.b;
                c = r.c;
                multicall = _mc(calls);
            }
        }
    }

    /// @dev Build calldata for any AMM type including Curve, using a pre-computed quote.
    function _buildCalldataFromBest(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 slippageBps,
        uint256 deadline,
        Quote memory q
    ) internal view returns (bytes memory) {
        if (q.source == AMM.CURVE) {
            (,, address pool, bool useUnd, bool isStab, uint8 ci, uint8 cj) =
                quoteCurve(exactOut, tokenIn, tokenOut, swapAmount == 0 ? q.amountIn : swapAmount, 8);
            if (pool != address(0)) {
                (bytes memory cd,,) = _buildCurveSwapCalldata(
                    to,
                    exactOut,
                    tokenIn,
                    tokenOut,
                    swapAmount,
                    slippageBps,
                    deadline,
                    pool,
                    useUnd,
                    isStab,
                    ci,
                    cj,
                    q.amountIn,
                    q.amountOut
                );
                if (cd.length > 0) return cd;
            }
        }
        if (q.source == AMM.LIDO) {
            return _buildLidoSwap(to, exactOut, tokenOut, swapAmount);
        }
        // Default: V2/Sushi/V3/V4/ZAMM
        return _buildSwapFromQuote(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, deadline, q);
    }

    // ====================== SPLIT ROUTING ======================

    /// @notice Build a split swap that divides the input across 2 venues for better execution.
    ///         ExactIn only. Tries splits [100/0, 75/25, 50/50, 25/75, 0/100] across the
    ///         top 2 venues and picks the best total output.
    function buildSplitSwap(
        address to,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) public view returns (Quote[2] memory legs, bytes memory multicall, uint256 msgValue) {
        unchecked {
            tokenIn = _normalizeETH(tokenIn);
            tokenOut = _normalizeETH(tokenOut);

            // ---- ETH <-> WETH trivial wrap: splitting makes no sense; delegate to buildBestSwap ----
            if ((tokenIn == address(0) && tokenOut == WETH) || (tokenIn == WETH && tokenOut == address(0))) {
                (legs[0], multicall, msgValue) = _fallbackBest(to, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
                return (legs, multicall, msgValue);
            }

            // ---- Gather candidates ----
            // Filter out LIDO (uses callvalue(), unsafe in multicall splits) and WETH_WRAP.
            (, Quote[] memory baseQuotes) = getQuotes(false, tokenIn, tokenOut, swapAmount);
            uint256 n;
            Quote[] memory cands = new Quote[](baseQuotes.length + 1);
            for (uint256 i; i < baseQuotes.length; ++i) {
                if (baseQuotes[i].source == AMM.LIDO || baseQuotes[i].source == AMM.WETH_WRAP) {
                    continue;
                }
                cands[n++] = baseQuotes[i];
            }

            // Curve
            {
                (uint256 ci_, uint256 co_, address p_,,,,) = quoteCurve(false, tokenIn, tokenOut, swapAmount, 8);
                if (p_ != address(0) && co_ > 0) {
                    cands[n] = _asQuote(AMM.CURVE, ci_, co_);
                    n++;
                }
            }

            // ---- Top 2 ----
            uint256 idx1;
            uint256 idx2;
            uint256 out1;
            uint256 out2;
            for (uint256 i; i < n; ++i) {
                if (cands[i].amountOut > out1) {
                    out2 = out1;
                    idx2 = idx1;
                    out1 = cands[i].amountOut;
                    idx1 = i;
                } else if (cands[i].amountOut > out2) {
                    out2 = cands[i].amountOut;
                    idx2 = i;
                }
            }
            if (out1 == 0) revert NoRoute();

            bool ethIn = tokenIn == address(0);

            // ---- Single venue fallback ----
            // buildBestSwap may pick Curve/Lido which aren't in `cands`, so surface its
            // actual best in legs[0] to keep the returned metadata consistent with calldata.
            if (out2 == 0 || idx1 == idx2) {
                (legs[0], multicall, msgValue) = _fallbackBest(to, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
                return (legs, multicall, msgValue);
            }

            // ---- Try splits ----
            Quote memory venue1 = cands[idx1];
            Quote memory venue2 = cands[idx2];

            uint256[5] memory pcts = [uint256(100), 75, 50, 25, 0];
            uint256 bestTotal;
            uint256 bestS;

            for (uint256 s; s < 5; ++s) {
                uint256 a1 = (swapAmount * pcts[s]) / 100;
                uint256 a2 = swapAmount - a1;
                uint256 o1_;
                uint256 o2_;

                if (a1 > 0) o1_ = _requoteForSource(false, tokenIn, tokenOut, a1, venue1).amountOut;
                if (a2 > 0) o2_ = _requoteForSource(false, tokenIn, tokenOut, a2, venue2).amountOut;

                uint256 t = o1_ + o2_;
                if (t > bestTotal) {
                    bestTotal = t;
                    bestS = s;
                }
            }

            // ---- Build winning split ----
            uint256 fa1 = (swapAmount * pcts[bestS]) / 100;
            uint256 fa2 = swapAmount - fa1;

            if (fa1 == 0 || fa2 == 0) {
                // 100/0 or 0/100 — single venue. buildBestSwap may pick Curve/Lido
                // which aren't in `cands`; surface its actual best in the winning slot
                // so returned metadata matches the generated calldata.
                (legs[fa1 == 0 ? 1 : 0], multicall, msgValue) =
                    _fallbackBest(to, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
                return (legs, multicall, msgValue);
            }

            // ---- True split: build both legs ----
            legs[0] = _requoteForSource(false, tokenIn, tokenOut, fa1, venue1);
            legs[1] = _requoteForSource(false, tokenIn, tokenOut, fa2, venue2);

            // Guard: if re-quote at partial amount returns zero, revert so frontend
            // falls through to a non-split strategy instead of building bad calldata.
            if (legs[0].amountOut == 0 || legs[1].amountOut == 0) revert NoRoute();

            uint256 lim1 = SlippageLib.limit(false, legs[0].amountOut, slippageBps);
            uint256 lim2 = SlippageLib.limit(false, legs[1].amountOut, slippageBps);

            address legTo = ethIn ? ZROUTER : to;

            // Curve legs with ETH input need a pre-wrap
            bool wrapLeg1 = ethIn && legs[0].source == AMM.CURVE;
            bool wrapLeg2 = ethIn && legs[1].source == AMM.CURVE;
            uint256 nc = 2 + (ethIn ? 2 : 0) + (wrapLeg1 ? 1 : 0) + (wrapLeg2 ? 1 : 0);
            bytes[] memory calls_ = new bytes[](nc);
            uint256 ci;

            ci = _appendLegMaybeWrap(
                calls_,
                ci,
                _buildCalldataFromBest(legTo, false, tokenIn, tokenOut, fa1, lim1, slippageBps, deadline, legs[0]),
                wrapLeg1,
                fa1
            );
            ci = _appendLegMaybeWrap(
                calls_,
                ci,
                _buildCalldataFromBest(legTo, false, tokenIn, tokenOut, fa2, lim2, slippageBps, deadline, legs[1]),
                wrapLeg2,
                fa2
            );

            // Final sweeps for ETH input
            if (ethIn) {
                calls_[ci++] = _sweepTo(tokenOut, to);
                // Sweep any leftover ETH dust (prevents stealable balance in router)
                calls_[ci++] = _sweepTo(address(0), to);
            }

            multicall = _mc(calls_);
            msgValue = ethIn ? swapAmount : 0;
        }
    }

    // ====================== HYBRID SPLIT (single-hop + 2-hop) ======================

    /// @notice Build a hybrid split that routes part of the input through the best
    ///         single-hop venue and the remainder through the best 2-hop route (via a
    ///         hub token). This captures cases where splitting across route depths
    ///         beats any single strategy.
    ///         Returns the same shape as buildSplitSwap for frontend compatibility.
    function buildHybridSplit(
        address to,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) public view returns (Quote[2] memory legs, bytes memory multicall, uint256 msgValue) {
        unchecked {
            tokenIn = _normalizeETH(tokenIn);
            tokenOut = _normalizeETH(tokenOut);

            // ---- ETH <-> WETH trivial wrap: no split, delegate to buildBestSwap ----
            if ((tokenIn == address(0) && tokenOut == WETH) || (tokenIn == WETH && tokenOut == address(0))) {
                (legs[0], multicall, msgValue) = _fallbackBest(to, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
                return (legs, multicall, msgValue);
            }

            // --- 1. Best single-hop at full amount ---
            Quote memory directFull = _quoteBestSingleHop(false, tokenIn, tokenOut, swapAmount);
            // Filter LIDO (uses callvalue(), unsafe in multicall splits). When Lido was
            // best, pick the true next-best non-Lido direct route — NOT a default-zero
            // Quote, whose enum default is UNI_V2 and would silently mis-route partial
            // splits through V2 when the real next-best was V3/V4/ZAMM/Curve.
            if (directFull.source == AMM.LIDO) {
                directFull = _bestDirectExcludingLido(tokenIn, tokenOut, swapAmount);
            }

            // --- 2. Best 2-hop hub route at full amount ---
            address[6] memory HUBS = _hubs();
            address bestHub;
            Quote memory hop1Full;
            Quote memory hop2Full;
            uint256 bestTwoHopOut;

            for (uint256 i; i < HUBS.length; ++i) {
                address mid = HUBS[i];
                if (mid == tokenIn || mid == tokenOut) continue;

                Quote memory qa = _quoteBestSingleHop(false, tokenIn, mid, swapAmount);
                if (qa.amountOut == 0 || qa.source == AMM.LIDO) continue;

                uint256 midAmt = SlippageLib.limit(false, qa.amountOut, slippageBps);
                Quote memory qb = _quoteBestSingleHop(false, mid, tokenOut, midAmt);
                if (qb.amountOut == 0) continue;

                if (qb.amountOut > bestTwoHopOut) {
                    bestTwoHopOut = qb.amountOut;
                    bestHub = mid;
                    hop1Full = qa;
                    hop2Full = qb;
                }
            }

            // Need at least one strategy
            if (directFull.amountOut == 0 && bestTwoHopOut == 0) revert NoRoute();

            // If no 2-hop route was found, skip the hybrid split loop entirely.
            // Without this guard, the split loop would call _requoteForSource with
            // bestHub=address(0) — forging an unrelated tokenIn->ETH quote through a
            // default-zero Quote (source=UNI_V2) and synthesizing calldata for a route
            // that was never actually validated by the hub-discovery pass.
            if (bestTwoHopOut == 0) {
                (legs[0], multicall, msgValue) = _fallbackBest(to, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
                return (legs, multicall, msgValue);
            }

            // --- 3. Try hybrid splits [75/25, 50/50, 25/75] in both directions ---
            uint256[3] memory directPcts = [uint256(75), 50, 25];
            uint256 bestTotalOut;
            uint256 bestSplitIdx; // 0-2 = directPcts[i], 3-5 = (100-directPcts[i])
            // Also compare pure strategies
            if (directFull.amountOut >= bestTwoHopOut) {
                bestTotalOut = directFull.amountOut;
                bestSplitIdx = 6; // sentinel: 100% direct
            } else {
                bestTotalOut = bestTwoHopOut;
                bestSplitIdx = 7; // sentinel: 100% 2-hop
            }

            for (uint256 s; s < 3; ++s) {
                uint256 directAmt = (swapAmount * directPcts[s]) / 100;
                uint256 twoHopAmt = swapAmount - directAmt;

                // Re-quote direct leg at partial amount
                Quote memory qd = _requoteForSource(false, tokenIn, tokenOut, directAmt, directFull);
                if (qd.amountOut == 0) continue;

                // Re-quote 2-hop: leg1 at partial, leg2 on leg1's output
                Quote memory qh1 = _requoteForSource(false, tokenIn, bestHub, twoHopAmt, hop1Full);
                if (qh1.amountOut == 0) continue;
                uint256 midAmt = SlippageLib.limit(false, qh1.amountOut, slippageBps);
                Quote memory qh2 = _quoteBestSingleHop(false, bestHub, tokenOut, midAmt);
                if (qh2.amountOut == 0) continue;

                uint256 total = qd.amountOut + qh2.amountOut;
                if (total > bestTotalOut) {
                    bestTotalOut = total;
                    bestSplitIdx = s;
                }
            }

            // --- 4. Build the winning multicall ---
            if (bestSplitIdx == 6) {
                // 100% direct wins. `directFull` was zeroed if LIDO was best — but
                // buildBestSwap still considers LIDO and may emit LIDO calldata, so
                // surface its actual best to keep legs[0] consistent with calldata.
                (legs[0], multicall, msgValue) = _fallbackBest(to, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
            } else if (bestSplitIdx == 7) {
                // 100% 2-hop wins. Pin hop-1 to the discovered `hop1Full` quote —
                // buildBestSwap would re-query and could re-select LIDO for e.g.
                // ETH→WSTETH, which discovery deliberately filtered out of hub legs.
                legs[1] = _asQuote(hop2Full.source, swapAmount, bestTwoHopOut);
                Quote memory qh1Full = _requoteForSource(false, tokenIn, bestHub, swapAmount, hop1Full);
                if (qh1Full.amountOut == 0) revert NoRoute();
                bytes memory cd1 = _buildCalldataFromBest(
                    ZROUTER,
                    false,
                    tokenIn,
                    bestHub,
                    swapAmount,
                    SlippageLib.limit(false, qh1Full.amountOut, slippageBps),
                    slippageBps,
                    deadline,
                    qh1Full
                );
                // hop 2 re-quotes from the ACTUAL hop-1 output (qh1Full) — not the
                // discovery-time estimate (hop1Full), which can diverge from qh1Full.
                Quote memory qb2 = _quoteBestSingleHop(
                    false, bestHub, tokenOut, SlippageLib.limit(false, qh1Full.amountOut, slippageBps)
                );
                if (qb2.amountOut == 0) revert NoRoute();
                bytes memory cd2 = _buildCalldataFromBest(
                    to,
                    false,
                    bestHub,
                    tokenOut,
                    0,
                    SlippageLib.limit(false, qb2.amountOut, slippageBps),
                    slippageBps,
                    deadline,
                    qb2
                );
                bytes[] memory calls_ = new bytes[](2);
                calls_[0] = cd1;
                calls_[1] = cd2;
                multicall = _mc(calls_);
                msgValue = tokenIn == address(0) ? swapAmount : 0;
            } else {
                // True hybrid split
                uint256 directAmt = (swapAmount * directPcts[bestSplitIdx]) / 100;
                uint256 twoHopAmt = swapAmount - directAmt;

                // Re-quote final amounts for both strategies
                Quote memory qd = _requoteForSource(false, tokenIn, tokenOut, directAmt, directFull);
                Quote memory qh1 = _requoteForSource(false, tokenIn, bestHub, twoHopAmt, hop1Full);
                if (qd.amountOut == 0 || qh1.amountOut == 0) revert NoRoute();
                uint256 midAmt = SlippageLib.limit(false, qh1.amountOut, slippageBps);
                Quote memory qh2 = _quoteBestSingleHop(false, bestHub, tokenOut, midAmt);
                if (qh2.amountOut == 0) revert NoRoute();

                legs[0] = qd;
                legs[1] = _asQuote(qh2.source, twoHopAmt, qh2.amountOut);

                bool ethIn = tokenIn == address(0);
                address legTo = ethIn ? ZROUTER : to;

                // Direct leg calldata
                uint256 directLimit = SlippageLib.limit(false, qd.amountOut, slippageBps);
                bool wrapDirect = ethIn && qd.source == AMM.CURVE;
                bytes memory cdDirect = _buildCalldataFromBest(
                    legTo, false, tokenIn, tokenOut, directAmt, directLimit, slippageBps, deadline, qd
                );

                // 2-hop leg calldata: hop1 to ZROUTER, hop2 reads balance (swapAmount=0)
                uint256 hop1Limit = SlippageLib.limit(false, qh1.amountOut, slippageBps);
                bool wrapHop1 = ethIn && qh1.source == AMM.CURVE;
                bytes memory cdHop1 = _buildCalldataFromBest(
                    ZROUTER, false, tokenIn, bestHub, twoHopAmt, hop1Limit, slippageBps, deadline, qh1
                );
                uint256 hop2Limit = SlippageLib.limit(false, qh2.amountOut, slippageBps);
                bytes memory cdHop2 =
                    _buildCalldataFromBest(legTo, false, bestHub, tokenOut, 0, hop2Limit, slippageBps, deadline, qh2);

                // Assemble multicall
                // Calls: [wrap?] direct [wrap?] hop1 hop2 [sweep tokenOut] [sweep ETH]
                uint256 numCalls = 3 + (ethIn ? 2 : 0) + (wrapDirect ? 1 : 0) + (wrapHop1 ? 1 : 0);
                bytes[] memory calls_ = new bytes[](numCalls);
                uint256 ci;

                ci = _appendLegMaybeWrap(calls_, ci, cdDirect, wrapDirect, directAmt);
                ci = _appendLegMaybeWrap(calls_, ci, cdHop1, wrapHop1, twoHopAmt);

                calls_[ci++] = cdHop2;

                if (ethIn) {
                    calls_[ci++] = _sweepTo(tokenOut, to);
                    calls_[ci++] = _sweepTo(address(0), to);
                }

                multicall = _mc(calls_);
                msgValue = ethIn ? swapAmount : 0;
            }
        }
    }

    /// @dev Re-quote for a specific AMM source at a given amount.
    function _requoteForSource(bool exactOut, address tokenIn, address tokenOut, uint256 amount, Quote memory source)
        internal
        view
        returns (Quote memory q)
    {
        AMM src = source.source;
        uint256 fee = source.feeBps;
        uint256 ai;
        uint256 ao;
        if (src == AMM.UNI_V2 || src == AMM.SUSHI) {
            (ai, ao) = _BASE.quoteV2(exactOut, tokenIn, tokenOut, amount, src == AMM.SUSHI);
            fee = 30;
        } else if (src == AMM.UNI_V3) {
            (ai, ao) = _BASE.quoteV3(exactOut, tokenIn, tokenOut, uint24(fee * 100), amount);
        } else if (src == AMM.UNI_V4) {
            (ai, ao) = _BASE.quoteV4(
                exactOut, tokenIn, tokenOut, uint24(fee * 100), _spacingFromBps(uint16(fee)), address(0), amount
            );
        } else if (src == AMM.ZAMM) {
            (ai, ao) = _BASE.quoteZAMM(exactOut, fee, tokenIn, tokenOut, 0, 0, amount);
        } else if (src == AMM.CURVE) {
            (uint256 cin, uint256 cout, address pool,,,,) = quoteCurve(exactOut, tokenIn, tokenOut, amount, 8);
            if (pool == address(0)) return q;
            return _asQuote(AMM.CURVE, cin, cout);
        } else {
            (q,) = getQuotes(exactOut, tokenIn, tokenOut, amount);
            return q;
        }
        return Quote(src, fee, ai, ao);
    }
}

address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

interface IStETH {
    function getTotalShares() external view returns (uint256);
    function getTotalPooledEther() external view returns (uint256);
}

address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

interface IRouterExt {
    function unwrap(uint256 amount) external payable;
    function wrap(uint256 amount) external payable;
    function deposit(address token, uint256 id, uint256 amount) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
    function sweep(address token, uint256 id, uint256 amount, address to) external payable;
}

// ** CURVE

// ---- MetaRegistry (mainnet) ----
address constant CURVE_METAREGISTRY = 0xF98B45FA17DE75FB1aD0e7aFD971b0ca00e379fC;
address constant CURVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

// ---- Curve interfaces ----
interface ICurveMetaRegistry {
    function find_pools_for_coins(address from, address to) external view returns (address[] memory);
    function get_coin_indices(address pool, address from, address to, uint256 handler_id)
        external
        view
        returns (int128 i, int128 j, bool isUnderlying);
}

interface ICurveStableLike {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function get_dx(int128 i, int128 j, uint256 dy) external view returns (uint256);
}

interface ICurveCryptoLike {
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
    function get_dx(uint256 i, uint256 j, uint256 dy) external view returns (uint256);
}

library SlippageLib {
    uint256 constant BPS = 10_000;

    error SlippageBpsTooHigh();

    function limit(bool exactOut, uint256 quoted, uint256 bps) internal pure returns (uint256) {
        require(bps < BPS, SlippageBpsTooHigh());
        unchecked {
            if (exactOut) {
                // maxIn = ceil(quotedIn * (1 + bps/BPS))
                return (quoted * (BPS + bps) + BPS - 1) / BPS;
            } else {
                // minOut = floor(quotedOut * (1 - bps/BPS))
                return (quoted * (BPS - bps)) / BPS;
            }
        }
    }
}

interface IZRouter {
    function swapV2(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapVZ(
        address to,
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapV3(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapCurve(
        address to,
        bool exactOut,
        address[11] calldata route,
        uint256[4][5] calldata swapParams, // [i, j, swap_type, pool_type]
        address[5] calldata basePools, // for meta pools (only used by type=2 get_dx)
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function exactETHToSTETH(address to) external payable returns (uint256 shares);
    function exactETHToWSTETH(address to) external payable returns (uint256 wstOut);
    function ethToExactSTETH(address to, uint256 exactOut) external payable;
    function ethToExactWSTETH(address to, uint256 exactOut) external payable;
}
