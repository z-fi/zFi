// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {TickMath, SwapMath, LiquidityMath, IStateViewV4, _sortTokens, _v4PoolId} from "./zQuoterV4.sol";

// zQuoterBase — quotes Uniswap V2/V3/V4, Aerodrome and Slipstream, and builds the
// calldata for zRouterLiteBase, on Base (8453).
//
// Pool addresses are derived exactly as the router derives them, so a quote and
// the calldata built from it cannot name different pools. That is the invariant
// the fork tests check by asserting quote == execution to the wei.
//
// `feeBps` is overloaded per venue, deliberately: for AERO_CL it is the TICK
// SPACING, the only value that names a Slipstream pool; for AERO it is a
// discriminator, 2 for stable and 20 for volatile; elsewhere it is the fee tier.
//
address constant WETH = 0x4200000000000000000000000000000000000006;

address constant V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
bytes32 constant V2_POOL_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

address constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
bytes32 constant V3_POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

// The v4 lens. Its `poolManager()` is the singleton zRouterLiteBase holds — checked.
address constant V4_STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;

// Hub tokens for two-hop routing: where Base depth actually is.
address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
address constant DAI = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

address constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
address constant AERO_IMPLEMENTATION = 0xA4e46b4f701c62e14DF11B48dCe76A7d793CD6d7;
address constant AERO_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
address constant AERO_CL_IMPLEMENTATION = 0xeC8E5342B19977B4eF8892e02D8DAEcfa1315831;

uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

/// @dev The canonical zRouter address, the same on every chain this family
/// targets. `buildBestSwap` compares `to` against it to decide whether output may
/// stay in the router for a following leg, so it has to be the address the built
/// calldata is actually sent to.
address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

uint256 constant BPS = 10_000;

contract zQuoterBase {
    error NoRoute();
    error IdenticalTokens();
    error SlippageBpsTooHigh();

    /// @dev Base ordinals, unchanged from the deployed quoter so a `source`
    /// crossing the wire keeps its meaning. Note these are NOT mainnet's: AERO
    /// sits where SUSHI does there.
    enum AMM {
        UNI_V2,
        AERO,
        ZAMM,
        UNI_V3,
        UNI_V4,
        AERO_CL,
        WETH_WRAP
    }

    struct Quote {
        AMM source;
        uint256 feeBps;
        uint256 amountIn;
        uint256 amountOut;
    }

    /// @dev Tiers to sweep, in hundredths of a bip. Spacings are Uniswap's
    /// canonical pairing, which is what the router re-derives when it executes.
    function _tiers() internal pure returns (uint24[4] memory) {
        return [uint24(100), 500, 3000, 10_000];
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

    // ====================== AGGREGATE ======================

    /// @dev Read off `tickSpacings()`. Not Uniswap's pairing — see the header.
    function _clSpacings() internal pure returns (int24[6] memory) {
        return [int24(1), 10, 50, 100, 200, 2000];
    }

    /// @notice Quote every venue zRouterLiteBase can execute, and pick the best.
    /// @param exactOut false = `swapAmount` is the input; true = it is the desired output.
    /// @return best The winning quote, zeroed if nothing quoted.
    /// @return quotes Twenty candidates in a stable order: V2, AERO, four zAMM
    ///         tiers, four v3 tiers, four v4 tiers, six Slipstream spacings.
    ///         Entries that did not quote stay at zero so callers can index by venue.
    function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (Quote memory best, Quote[] memory quotes)
    {
        require(_normalizeETH(tokenIn) != _normalizeETH(tokenOut), IdenticalTokens());

        uint24[4] memory tiers = _tiers();
        quotes = new Quote[](20);

        (uint256 aIn, uint256 aOut) = quoteV2(exactOut, tokenIn, tokenOut, swapAmount);
        quotes[0] = Quote(AMM.UNI_V2, 30, aIn, aOut);

        // Aerodrome classic is exact-in only, so an exact-out route through it
        // would have to pin the input and could honour no slippage at all. It does
        // not compete for exact-out; `quoteAero` still answers one directly.
        if (!exactOut) {
            uint256 kind;
            (aIn, aOut, kind) = quoteAero(false, tokenIn, tokenOut, swapAmount);
            quotes[1] = Quote(AMM.AERO, kind, aIn, aOut);
        }

        // Slots 2..5 are zAMM's and stay zeroed: nothing is deployed into zAMM on
        // Base — every pair and fee tier reads empty — so quoting it is four
        // guaranteed-empty staticcalls per request. The slots and the enum ordinal
        // stay so a `source` keeps its meaning across chains.

        for (uint256 i; i < 4; ++i) {
            (aIn, aOut) = quoteV3(exactOut, tokenIn, tokenOut, tiers[i], swapAmount);
            quotes[6 + i] = Quote(AMM.UNI_V3, tiers[i] / 100, aIn, aOut);

            (aIn, aOut) = quoteV4(exactOut, tokenIn, tokenOut, tiers[i], swapAmount);
            quotes[10 + i] = Quote(AMM.UNI_V4, tiers[i] / 100, aIn, aOut);
        }

        int24[6] memory spacings = _clSpacings();
        for (uint256 i; i < 6; ++i) {
            (aIn, aOut) = quoteAeroCL(exactOut, tokenIn, tokenOut, spacings[i], swapAmount);
            // The spacing, not a fee: it is what names a Slipstream pool.
            quotes[14 + i] = Quote(AMM.AERO_CL, uint256(uint24(spacings[i])), aIn, aOut);
        }

        best = Quote(AMM.UNI_V2, 0, 0, 0);
        for (uint256 i; i < quotes.length; ++i) {
            Quote memory c = quotes[i];
            if (exactOut) {
                if (c.amountIn != 0 && (best.amountIn == 0 || c.amountIn < best.amountIn)) best = c;
            } else if (c.amountOut > best.amountOut) {
                best = c;
            }
        }
    }

    /// @notice Quote, then hand back calldata sendable to the router as-is.
    /// @param to Recipient. Pass ZROUTER to leave funds in the router for a
    ///        following call.
    /// @return best The venue that won.
    /// @return callData Send to ZROUTER with `msgValue` attached.
    /// @return amountLimit The bound already embedded in `callData` — minimum out
    ///         for exactIn, maximum in for exactOut.
    /// @return msgValue Ether to attach. Non-zero only when paying in ether.
    function buildBestSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) public view returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) {
        require(slippageBps < BPS, SlippageBpsTooHigh());

        // ETH <-> WETH is 1:1, not a swap: quoting a venue would invent a spread.
        if ((tokenIn == address(0) && tokenOut == WETH) || (tokenIn == WETH && tokenOut == address(0))) {
            best = Quote(AMM.WETH_WRAP, 0, swapAmount, swapAmount);
            amountLimit = swapAmount;
            if (tokenIn == address(0)) {
                msgValue = swapAmount;
                callData = to == ZROUTER
                    ? _wrap(swapAmount)
                    : _mc2(_wrap(swapAmount), _sweepAmt(WETH, swapAmount, to));
            } else {
                (bytes memory dep, bytes memory unw) = _depUnwrap(swapAmount);
                callData = to == ZROUTER
                    ? _mc2(dep, unw)
                    : _mc3(dep, unw, _sweepAmt(address(0), swapAmount, to));
            }
            return (best, callData, amountLimit, msgValue);
        }

        (best,) = getQuotes(exactOut, tokenIn, tokenOut, swapAmount);
        if (exactOut ? best.amountIn == 0 : best.amountOut == 0) revert NoRoute();

        uint256 quoted = exactOut ? best.amountIn : best.amountOut;
        unchecked {
            amountLimit = exactOut
                ? (quoted * (BPS + slippageBps) + BPS - 1) / BPS // ceil
                : (quoted * (BPS - slippageBps)) / BPS; // floor
        }

        callData = _buildSwap(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, deadline, best);
        msgValue = tokenIn == address(0) ? (exactOut ? amountLimit : swapAmount) : 0;
    }

    function _buildSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline,
        Quote memory q
    ) internal pure returns (bytes memory) {
        if (q.source == AMM.UNI_V2) {
            return abi.encodeWithSelector(
                IZRouter.swapV2.selector, to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, deadline
            );
        }
        if (q.source == AMM.UNI_V3) {
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
        }
        if (q.source == AMM.UNI_V4) {
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
        if (q.source == AMM.AERO) {
            // Exact-in only; `getQuotes` never offers this venue for exact-out.
            if (exactOut) revert NoRoute();
            return abi.encodeWithSelector(
                IZRouter.swapAero.selector,
                to,
                q.feeBps <= 2, // stable discriminator, not a fee
                tokenIn,
                tokenOut,
                swapAmount,
                amountLimit,
                deadline
            );
        }
        if (q.source == AMM.AERO_CL) {
            return abi.encodeWithSelector(
                IZRouter.swapAeroCL.selector,
                to,
                exactOut,
                int24(uint24(q.feeBps)), // the spacing itself
                tokenIn,
                tokenOut,
                swapAmount,
                amountLimit,
                deadline
            );
        }
        revert NoRoute();
    }

    // ====================== AERODROME ======================

    /// @dev Quotes both pool kinds and returns the winner. The third return is a
    /// discriminator, not a fee: 2 means the stable pool won, 20 the volatile
    /// one. That is the convention the deployed quoter set and the Base front end
    /// decodes, so it is kept.
    function quoteAero(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut, uint256 kind)
    {
        unchecked {
            if (swapAmount == 0) return (0, 0, 0);
            address tIn = _normalizeETH(tokenIn);
            address tOut = _normalizeETH(tokenOut);
            if (tIn == tOut) return (0, 0, 0);

            (uint256 vIn, uint256 vOut) = _quoteAeroPool(exactOut, false, tIn, tOut, swapAmount);
            (uint256 sIn, uint256 sOut) = _quoteAeroPool(exactOut, true, tIn, tOut, swapAmount);

            if (exactOut) {
                if (vIn != 0 && (sIn == 0 || vIn <= sIn)) return (vIn, vOut, 20);
                if (sIn != 0) return (sIn, sOut, 2);
            } else {
                if (vOut != 0 && vOut >= sOut) return (vIn, vOut, 20);
                if (sOut != 0) return (sIn, sOut, 2);
            }
            return (0, 0, 0);
        }
    }

    function _quoteAeroPool(bool exactOut, bool stable, address tokenIn, address tokenOut, uint256 swapAmount)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        unchecked {
            address pool = _aeroPoolFor(tokenIn, tokenOut, stable);
            if (pool.code.length == 0) return (0, 0);

            if (!exactOut) {
                amountOut = _aeroOut(pool, tokenIn, swapAmount);
                return amountOut == 0 ? (0, 0) : (swapAmount, amountOut);
            }
            amountIn = _aeroSolveExactOut(pool, tokenIn, swapAmount);
            return amountIn == 0 ? (0, 0) : (amountIn, swapAmount);
        }
    }

    /// @dev `getAmountOut` reverts on some inputs rather than returning zero, so
    /// it is called through a guard: the search below must be able to probe.
    function _aeroOut(address pool, address tokenIn, uint256 amountIn) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            pool.staticcall(abi.encodeWithSelector(IAeroPool.getAmountOut.selector, amountIn, tokenIn));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev The stable curve x3y+y3x has no closed-form inverse, so exact-out is
    /// solved by search. `getAmountOut` is monotone in the input, which is what
    /// makes this exact rather than approximate: it returns the least input whose
    /// output reaches the target.
    ///
    /// The deployed quoter runs a fixed 64-step doubling and then a fixed 32-step
    /// bisection whatever the interval, and re-probes the bound after the loop.
    /// This bounds the doubling by the pool's own reserve and bisects only the
    /// interval it actually found.
    function _aeroSolveExactOut(address pool, address tokenIn, uint256 targetOut)
        internal
        view
        returns (uint256)
    {
        unchecked {
            if (targetOut == 0) return 0;

            uint256 hi = 1;
            uint256 lo;
            bool bounded;
            for (uint256 i; i != 128; ++i) {
                if (_aeroOut(pool, tokenIn, hi) >= targetOut) {
                    bounded = true;
                    break;
                }
                lo = hi;
                hi <<= 1;
                if (hi == 0) return 0; // overflowed without reaching the target
            }
            if (!bounded) return 0;

            ++lo; // lo is known too small, hi known sufficient
            while (lo < hi) {
                uint256 mid = lo + ((hi - lo) >> 1);
                if (_aeroOut(pool, tokenIn, mid) >= targetOut) hi = mid;
                else lo = mid + 1;
            }
            return lo;
        }
    }

    /// @dev Aerodrome pools are minimal-proxy clones; this hashes the clone
    /// initcode, matching what the router derives.
    function _aeroPoolFor(address tokenA, address tokenB, bool stable) internal pure returns (address pool) {
        (address token0, address token1,) = _sortTokens(tokenA, tokenB);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, stable));
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x38), AERO_FACTORY)
            mstore(add(ptr, 0x24), 0x5af43d82803e903d91602b57fd5bf3ff)
            mstore(add(ptr, 0x14), AERO_IMPLEMENTATION)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73)
            mstore(add(ptr, 0x58), salt)
            mstore(add(ptr, 0x78), keccak256(add(ptr, 0x0c), 0x37))
            pool := keccak256(add(ptr, 0x43), 0x55)
        }
    }

    function _aeroCLPoolFor(address tokenA, address tokenB, int24 tickSpacing)
        internal
        pure
        returns (address pool)
    {
        (address token0, address token1,) = _sortTokens(tokenA, tokenB);
        bytes32 salt = keccak256(abi.encode(token0, token1, tickSpacing));
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, AERO_CL_IMPLEMENTATION))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf3ff00000000000000000000000000000000)
            mstore(add(ptr, 0x38), shl(0x60, AERO_CL_FACTORY))
            mstore(add(ptr, 0x4c), salt)
            mstore(add(ptr, 0x6c), keccak256(ptr, 0x37))
            pool := keccak256(add(ptr, 0x37), 0x55)
        }
    }

    /// @notice Aerodrome Slipstream: a v3 fork keyed by tick spacing.
    /// @dev Same tick walk as v3 and v4; only where the fee comes from differs.
    /// The fee is micro-pips, which is what `SwapMath` already expects.
    function quoteAeroCL(bool exactOut, address tokenIn, address tokenOut, int24 spacing, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        (address token0, address token1, bool zeroForOne) =
            _sortTokens(_normalizeETH(tokenIn), _normalizeETH(tokenOut));
        if (token0 == token1) return (0, 0);

        address pool = _aeroCLPoolFor(token0, token1, spacing);
        if (pool.code.length == 0) return (0, 0);

        // The pool's own fee, not the factory's default for the spacing.
        // Slipstream fees are per-pool and move: the WETH/USDC spacing-100 pool
        // charges 573 micro-pips where `tickSpacingToFee(100)` still says 500.
        // Quoting the default is quoting a pool that does not exist.
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSelector(IAeroV3Pool.fee.selector));
        if (!ok || ret.length < 32) return (0, 0);
        uint24 fee = uint24(abi.decode(ret, (uint256)));
        if (fee == 0 || fee >= 1_000_000) return (0, 0);

        return _quoteCL(Pool(false, pool, bytes32(0), spacing, fee), exactOut, zeroForOne, swapAmount);
    }


    // ====================== MULTI-HOP (zSwap compatibility) ======================

    /// @notice The slippage bound this quoter embeds, exposed so callers can
    /// reproduce it. Same shape as mainnet zQuoter's `limit`.
    function limit(bool exactOut, uint256 quoted, uint256 bps) public pure returns (uint256) {
        require(bps < BPS, SlippageBpsTooHigh());
        unchecked {
            return exactOut ? (quoted * (BPS + bps) + BPS - 1) / BPS : (quoted * (BPS - bps)) / BPS;
        }
    }

    /// @dev Base's liquidity centres, not mainnet's. USDT and wstETH are not where
    /// Base depth lives; cbBTC and AERO are.
    function _hubs() internal pure returns (address[5] memory) {
        return [WETH, USDC, CBBTC, DAI, AERO];
    }

    function _sweepTo(address token, address to) internal pure returns (bytes memory) {
        return _sweepAmt(token, 0, to);
    }

    function _mc(bytes[] memory c) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IZRouter.multicall.selector, c);
    }

    /// @dev `buildBestSwap` reverts when there is no route; this turns that into a
    /// flag so the hub search can keep going.
    function _bestSingleHop(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 slippageBps,
        uint256 deadline
    ) internal view returns (bool ok, Quote memory q, bytes memory data, uint256 msgValue) {
        try this.buildBestSwap(to, exactOut, tokenIn, tokenOut, amount, slippageBps, deadline) returns (
            Quote memory q_, bytes memory d_, uint256, uint256 v_
        ) {
            return (true, q_, d_, v_);
        } catch {
            return (false, q, bytes(""), 0);
        }
    }

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

    /// @notice zSwap's hub-routing entry point, selector 0xe453166e. Tries the
    /// direct route and every hub route, and returns whichever is better as a
    /// ready-to-send multicall.
    /// @param refundTo Where leftovers go. Coerced to `to` if it would be the
    ///        router, whose `sweep` is public and would leave them stealable.
    function buildBestSwapViaETHMulticall(
        address to,
        address refundTo,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    )
        public
        view
        returns (Quote memory a, Quote memory b, bytes[] memory calls, bytes memory multicall, uint256 msgValue)
    {
        unchecked {
            if (refundTo == ZROUTER && to != ZROUTER) refundTo = to;

            // Wrap check BEFORE distinctness: mainnet normalizes ETH to WETH
            // first, making its own fast path unreachable.
            if ((tokenIn == address(0) && tokenOut == WETH) || (tokenIn == WETH && tokenOut == address(0))) {
                a = Quote(AMM.WETH_WRAP, 0, swapAmount, swapAmount);
                if (tokenIn == address(0)) {
                    calls = new bytes[](2);
                    calls[0] = _wrap(swapAmount);
                    calls[1] = _sweepTo(WETH, to);
                    msgValue = swapAmount;
                } else {
                    calls = new bytes[](3);
                    (calls[0], calls[1]) = _depUnwrap(swapAmount);
                    calls[2] = _sweepTo(address(0), to);
                }
                return (a, b, calls, _mc(calls), msgValue);
            }

            require(_normalizeETH(tokenIn) != _normalizeETH(tokenOut), IdenticalTokens());

            (bool directOk, Quote memory directQ, bytes memory directCd, uint256 directVal) =
                _bestSingleHop(to, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline);

            HubPlan memory plan;
            plan.isExactOut = exactOut;
            address[5] memory hubs = _hubs();

            for (uint256 h; h < hubs.length; ++h) {
                address mid = hubs[h];
                if (mid == _normalizeETH(tokenIn) || mid == _normalizeETH(tokenOut)) continue;

                if (!exactOut) {
                    (bool okA, Quote memory qa, bytes memory ca,) =
                        _bestSingleHop(ZROUTER, false, tokenIn, mid, swapAmount, slippageBps, deadline);
                    if (!okA || qa.amountOut == 0) continue;

                    (bool okB, Quote memory qb, bytes memory cb,) = _bestSingleHop(
                        to, false, mid, tokenOut, limit(false, qa.amountOut, slippageBps), slippageBps, deadline
                    );
                    if (!okB || qb.amountOut == 0) continue;

                    if (!plan.found || qb.amountOut > plan.scoreOut) {
                        plan = HubPlan(true, false, mid, qa, qb, ca, cb, 0, qb.amountOut);
                    }
                } else {
                    (bool okB, Quote memory qb, bytes memory cb,) =
                        _bestSingleHop(ZROUTER, true, mid, tokenOut, swapAmount, slippageBps, deadline);
                    if (!okB || qb.amountIn == 0) continue;

                    (bool okA, Quote memory qa, bytes memory ca,) = _bestSingleHop(
                        ZROUTER, true, tokenIn, mid, limit(true, qb.amountIn, slippageBps), slippageBps, deadline
                    );
                    if (!okA || qa.amountIn == 0) continue;

                    if (!plan.found || qa.amountIn < plan.scoreIn) {
                        plan = HubPlan(true, true, mid, qa, qb, ca, cb, qa.amountIn, 0);
                    }
                }
            }

            // Exact-out prefers the direct route outright: two legs are two chances
            // to revert, and the saving is marginal. Exact-in needs the hub to be
            // more than 2% better to be worth the extra leg.
            if (plan.found) {
                bool hubBetter = exactOut ? !directOk : (!directOk || plan.scoreOut * 49 > directQ.amountOut * 50);
                if (!hubBetter) plan.found = false;
            }

            if (!plan.found) {
                if (!directOk) revert NoRoute();
                calls = new bytes[](1);
                calls[0] = directCd;
                return (directQ, b, calls, _mc(calls), directVal);
            }

            if (!plan.isExactOut) {
                // A first leg that stops at the price limit leaves ether here, and
                // hop one targets ZROUTER so the router's own refund is suppressed.
                bool ethInput = tokenIn == address(0);
                bool chaining = to == ZROUTER;
                calls = new bytes[]((ethInput && !chaining) ? 3 : 2);
                calls[0] = plan.ca;
                // swapAmount 0: the router spends what leg one credited.
                calls[1] = _buildSwap(
                    to, false, plan.mid, tokenOut, 0, limit(false, plan.b.amountOut, slippageBps), deadline, plan.b
                );
                if (ethInput && !chaining) calls[2] = _sweepTo(address(0), refundTo);
                msgValue = ethInput ? swapAmount : 0;
            } else {
                bool chaining = to == ZROUTER;
                bool ethInput = tokenIn == address(0);
                uint256 extra = chaining ? 0 : (ethInput ? 3 : 4);

                calls = new bytes[](2 + extra);
                uint256 k;
                calls[k++] = plan.ca;
                calls[k++] = plan.cb;
                if (!chaining) {
                    calls[k++] = _sweepAmt(tokenOut, swapAmount, to);
                    calls[k++] = _sweepTo(plan.mid, refundTo);
                    if (!ethInput) calls[k++] = _sweepTo(tokenIn, refundTo);
                    calls[k++] = _sweepTo(address(0), refundTo);
                }
                msgValue = ethInput ? limit(true, plan.a.amountIn, slippageBps) : 0;
            }

            a = plan.a;
            b = plan.b;
            return (a, b, calls, _mc(calls), msgValue);
        }
    }

    // ====================== SPLIT ROUTING ======================

    /// @dev Re-price one specific venue at a partial amount.
    function _requoteForSource(address tokenIn, address tokenOut, uint256 amount, Quote memory src)
        internal
        view
        returns (Quote memory)
    {
        uint256 ai;
        uint256 ao;
        uint256 fee = src.feeBps;
        if (src.source == AMM.UNI_V2) {
            (ai, ao) = quoteV2(false, tokenIn, tokenOut, amount);
        } else if (src.source == AMM.UNI_V3) {
            (ai, ao) = quoteV3(false, tokenIn, tokenOut, uint24(fee * 100), amount);
        } else if (src.source == AMM.UNI_V4) {
            (ai, ao) = quoteV4(false, tokenIn, tokenOut, uint24(fee * 100), amount);
        } else if (src.source == AMM.AERO_CL) {
            (ai, ao) = quoteAeroCL(false, tokenIn, tokenOut, int24(uint24(fee)), amount);
        } else if (src.source == AMM.AERO) {
            (ai, ao, fee) = quoteAero(false, tokenIn, tokenOut, amount);
        }
        return Quote(src.source, fee, ai, ao);
    }

    /// @dev The best single venue, wrapped in a one-element multicall so callers
    /// get the same shape back whether or not a split was worth it.
    function _fallbackBest(address to, address tokenIn, address tokenOut, uint256 amount, uint256 bps, uint256 dl)
        internal
        view
        returns (Quote memory q, bytes memory mc, uint256 mv)
    {
        bytes memory cd;
        (q, cd,, mv) = buildBestSwap(to, false, tokenIn, tokenOut, amount, bps, dl);
        bytes[] memory c = new bytes[](1);
        c[0] = cd;
        mc = _mc(c);
    }

    /// @notice Split one exact-in trade across the two best venues, at whichever of
    /// 100/0, 75/25, 50/50, 25/75 or 0/100 prices best.
    /// @dev Exact-in only. An exact-out split would need each leg's input solved
    /// against a moving total, and the halves cannot both be exact.
    function buildSplitSwap(
        address to,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) public view returns (Quote[2] memory legs, bytes memory multicall, uint256 msgValue) {
        unchecked {
            if ((tokenIn == address(0) && tokenOut == WETH) || (tokenIn == WETH && tokenOut == address(0))) {
                (legs[0], multicall, msgValue) = _fallbackBest(to, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
                return (legs, multicall, msgValue);
            }
            require(_normalizeETH(tokenIn) != _normalizeETH(tokenOut), IdenticalTokens());

            (, Quote[] memory cands) = getQuotes(false, tokenIn, tokenOut, swapAmount);

            uint256 i1;
            uint256 i2;
            uint256 out1;
            uint256 out2;
            for (uint256 i; i < cands.length; ++i) {
                uint256 o = cands[i].amountOut;
                if (o > out1) {
                    (out2, i2) = (out1, i1);
                    (out1, i1) = (o, i);
                } else if (o > out2) {
                    (out2, i2) = (o, i);
                }
            }
            if (out1 == 0) revert NoRoute();
            if (out2 == 0) {
                (legs[0], multicall, msgValue) = _fallbackBest(to, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
                return (legs, multicall, msgValue);
            }

            Quote memory v1 = cands[i1];
            Quote memory v2 = cands[i2];

            uint256[5] memory pcts = [uint256(100), 75, 50, 25, 0];
            uint256 bestTotal;
            uint256 bestS;
            for (uint256 s; s < 5; ++s) {
                uint256 a1 = (swapAmount * pcts[s]) / 100;
                uint256 t;
                if (a1 != 0) t += _requoteForSource(tokenIn, tokenOut, a1, v1).amountOut;
                if (swapAmount - a1 != 0) t += _requoteForSource(tokenIn, tokenOut, swapAmount - a1, v2).amountOut;
                if (t > bestTotal) (bestTotal, bestS) = (t, s);
            }

            uint256 fa1 = (swapAmount * pcts[bestS]) / 100;
            uint256 fa2 = swapAmount - fa1;

            // A one-sided winner is not a split.
            if (fa1 == 0 || fa2 == 0) {
                (legs[fa1 == 0 ? 1 : 0], multicall, msgValue) =
                    _fallbackBest(to, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
                return (legs, multicall, msgValue);
            }

            legs[0] = _requoteForSource(tokenIn, tokenOut, fa1, v1);
            legs[1] = _requoteForSource(tokenIn, tokenOut, fa2, v2);
            if (legs[0].amountOut == 0 || legs[1].amountOut == 0) revert NoRoute();

            bool ethIn = tokenIn == address(0);
            address legTo = ethIn ? ZROUTER : to;

            bytes[] memory c = new bytes[](ethIn ? 4 : 2);
            c[0] = _buildSwap(
                legTo, false, tokenIn, tokenOut, fa1, limit(false, legs[0].amountOut, slippageBps), deadline, legs[0]
            );
            c[1] = _buildSwap(
                legTo, false, tokenIn, tokenOut, fa2, limit(false, legs[1].amountOut, slippageBps), deadline, legs[1]
            );
            if (ethIn) {
                c[2] = _sweepTo(tokenOut, to);
                c[3] = _sweepTo(address(0), to);
            }

            multicall = _mc(c);
            msgValue = ethIn ? swapAmount : 0;
        }
    }

    /// @notice Split one exact-in trade between the best direct venue and the best
    /// hub route. Same return shape as `buildSplitSwap`.
    function buildHybridSplit(
        address to,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) public view returns (Quote[2] memory legs, bytes memory multicall, uint256 msgValue) {
        unchecked {
            if ((tokenIn == address(0) && tokenOut == WETH) || (tokenIn == WETH && tokenOut == address(0))) {
                (legs[0], multicall, msgValue) = _fallbackBest(to, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
                return (legs, multicall, msgValue);
            }
            require(_normalizeETH(tokenIn) != _normalizeETH(tokenOut), IdenticalTokens());

            bool ethIn = tokenIn == address(0);
            address legTo = ethIn ? ZROUTER : to;
            uint256 bestTotal;
            uint256 bestPct;
            bytes memory bestHubCd;
            address bestMid;

            uint256[3] memory pcts = [uint256(25), 50, 75];
            for (uint256 i; i < 3; ++i) {
                uint256 a1 = (swapAmount * pcts[i]) / 100;
                (bool okD, Quote memory qd,,) =
                    _bestSingleHop(legTo, false, tokenIn, tokenOut, a1, slippageBps, deadline);
                if (!okD || qd.amountOut == 0) continue;

                (Quote memory hb, bytes memory hcd, address hmid) =
                    _hubLeg(legTo, tokenIn, tokenOut, swapAmount - a1, slippageBps, deadline);
                if (hb.amountOut == 0) continue;

                if (qd.amountOut + hb.amountOut > bestTotal) {
                    bestTotal = qd.amountOut + hb.amountOut;
                    bestPct = pcts[i];
                    legs[0] = qd;
                    legs[1] = hb;
                    bestHubCd = hcd;
                    bestMid = hmid;
                }
            }

            if (bestTotal == 0) {
                // No direct pool at any partial amount. The hub can still route
                // the whole trade, so try that before `_fallbackBest`, whose
                // `buildBestSwap` reverts NoRoute — leaving this branch to
                // inherit the failure it exists to absorb.
                (Quote memory hb, bytes memory hmc, uint256 hmv) =
                    _hubOnly(to, ethIn, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
                if (hb.amountOut != 0) {
                    legs[1] = hb;
                    return (legs, hmc, hmv);
                }
                (legs[0], multicall, msgValue) = _fallbackBest(to, tokenIn, tokenOut, swapAmount, slippageBps, deadline);
                legs[1] = Quote(AMM.UNI_V2, 0, 0, 0);
                return (legs, multicall, msgValue);
            }

            uint256 direct = (swapAmount * bestPct) / 100;
            bytes[] memory c = new bytes[](ethIn ? 5 : 3);
            uint256 k;
            c[k++] = _buildSwap(
                legTo, false, tokenIn, tokenOut, direct, limit(false, legs[0].amountOut, slippageBps), deadline, legs[0]
            );
            c[k++] = bestHubCd; // hop 1 of the hub route
            c[k++] = _buildSwap(
                legTo, false, bestMid, tokenOut, 0, limit(false, legs[1].amountOut, slippageBps), deadline, legs[1]
            );
            if (ethIn) {
                c[k++] = _sweepTo(tokenOut, to);
                c[k++] = _sweepTo(address(0), to);
            }

            multicall = _mc(c);
            msgValue = ethIn ? swapAmount : 0;
        }
    }

    /// @dev The whole trade through the hub, for when no direct pool exists at
    /// any split. Empty quote back if the hub cannot route it either.
    function _hubOnly(
        address to,
        bool ethIn,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 bps,
        uint256 dl
    ) internal view returns (Quote memory hb, bytes memory mc, uint256 mv) {
        address legTo = ethIn ? ZROUTER : to;
        bytes memory hcd;
        address hmid;
        (hb, hcd, hmid) = _hubLeg(legTo, tokenIn, tokenOut, amount, bps, dl);
        if (hb.amountOut == 0) return (hb, mc, mv);

        bytes[] memory h = new bytes[](ethIn ? 4 : 2);
        uint256 j;
        h[j++] = hcd;
        h[j++] = _buildSwap(legTo, false, hmid, tokenOut, 0, limit(false, hb.amountOut, bps), dl, hb);
        if (ethIn) {
            h[j++] = _sweepTo(tokenOut, to);
            h[j++] = _sweepTo(address(0), to);
        }
        mc = _mc(h);
        mv = ethIn ? amount : 0;
    }

    /// @dev The best hub route for one amount: the landing quote, hop-1 calldata,
    /// and the hub it went through — which the caller needs as hop-2's tokenIn and
    /// cannot re-derive, since it is whichever hub won rather than the first one.
    function _hubLeg(address to, address tokenIn, address tokenOut, uint256 amount, uint256 bps, uint256 dl)
        internal
        view
        returns (Quote memory b, bytes memory ca, address mid_)
    {
        address[5] memory hubs = _hubs();
        for (uint256 h; h < hubs.length; ++h) {
            address mid = hubs[h];
            if (mid == _normalizeETH(tokenIn) || mid == _normalizeETH(tokenOut)) continue;
            (bool okA, Quote memory qa, bytes memory cda,) = _bestSingleHop(ZROUTER, false, tokenIn, mid, amount, bps, dl);
            if (!okA || qa.amountOut == 0) continue;
            (bool okB, Quote memory qb,,) =
                _bestSingleHop(to, false, mid, tokenOut, limit(false, qa.amountOut, bps), bps, dl);
            if (!okB || qb.amountOut == 0) continue;
            if (qb.amountOut > b.amountOut) (b, ca, mid_) = (qb, cda, mid);
        }
    }

    // ====================== UNISWAP V2 ======================

    /// @dev Constant product at 0.30%. Cannot revert: a missing pair has no code
    /// and the staticcall guard reports (0, 0) rather than propagating.
    function quoteV2(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        unchecked {
            if (swapAmount == 0) return (0, 0);
            (address token0, address token1, bool zeroForOne) =
                _sortTokens(_normalizeETH(tokenIn), _normalizeETH(tokenOut));
            if (token0 == token1) return (0, 0);

            address pool = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                V2_FACTORY,
                                keccak256(abi.encodePacked(token0, token1)),
                                V2_POOL_INIT_CODE_HASH
                            )
                        )
                    )
                )
            );
            if (pool.code.length == 0) return (0, 0);

            (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSelector(IV2Pool.getReserves.selector));
            if (!ok || ret.length < 96) return (0, 0);
            (uint112 r0, uint112 r1,) = abi.decode(ret, (uint112, uint112, uint32));
            (uint256 resIn, uint256 resOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            if (resIn == 0 || resOut == 0) return (0, 0);

            if (exactOut) {
                // Larger than the reserve is impossible, not expensive: the
                // denominator would underflow into a nonsense price.
                if (swapAmount >= resOut) return (0, 0);
                amountOut = swapAmount;
                amountIn = (resIn * amountOut * 1000 + (resOut - amountOut) * 997 - 1) / ((resOut - amountOut) * 997);
            } else {
                amountIn = swapAmount;
                amountOut = (amountIn * 997 * resOut) / (resIn * 1000 + amountIn * 997);
            }
        }
    }

    // ====================== UNISWAP V3 / V4 ======================

    /// @dev Where the state lives: V3 on the pool, V4 in the singleton behind
    /// StateView. The step math is identical, so this struct is the only fork.
    struct Pool {
        bool isV4;
        address pool; // v3 only
        bytes32 id; // v4 only
        int24 spacing;
        uint24 fee;
    }

    function quoteV3(bool exactOut, address tokenIn, address tokenOut, uint24 fee, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        (address token0, address token1, bool zeroForOne) =
            _sortTokens(_normalizeETH(tokenIn), _normalizeETH(tokenOut));
        if (token0 == token1) return (0, 0);

        address pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            V3_FACTORY,
                            keccak256(abi.encode(token0, token1, fee)),
                            V3_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
        if (pool.code.length == 0) return (0, 0);

        // Spacing comes from the pool. Deriving it is wrong on Base: the factory
        // enables 200->4 and 400->8, which no bps table here maps, and v3 pools are
        // addressed by fee alone so a bad spacing still reaches a real pool and
        // walks the wrong bitmap. v4 must keep deriving it — there it is part of
        // the pool id, so a wrong guess names a pool that does not exist.
        return _quoteCL(
            Pool(false, pool, bytes32(0), IV3Pool(pool).tickSpacing(), fee), exactOut, zeroForOne, swapAmount
        );
    }

    /// @dev Hookless pools only: a hook can rewrite the swap, so a quote from
    /// pool state alone would be a guess, and `swapV4` takes no hook anyway.
    function quoteV4(bool exactOut, address tokenIn, address tokenOut, uint24 fee, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        // Ether is a first-class currency in v4, so unlike V2/V3 it is NOT
        // normalized to WETH — that would quote a different pool.
        if (tokenIn == tokenOut) return (0, 0);
        int24 spacing = _spacingFromBps(uint16(fee / 100));
        (bytes32 id, bool zeroForOne) = _v4PoolId(tokenIn, tokenOut, fee, spacing, address(0));
        return _quoteCL(Pool(true, address(0), id, spacing, fee), exactOut, zeroForOne, swapAmount);
    }

    /// @dev Uniswap's own step loop, shared by V3 and V4. Sign convention is v4's:
    /// exact-in negative, exact-out positive.
    function _quoteCL(Pool memory p, bool exactOut, bool zeroForOne, uint256 swapAmount)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        unchecked {
            if (swapAmount == 0 || swapAmount > uint256(type(int256).max)) return (0, 0);

            (uint160 sqrtPriceX96, int24 tick, uint128 liquidity, uint24 swapFee) = _slot0(p, zeroForOne);
            if (sqrtPriceX96 == 0 || liquidity == 0 || swapFee >= 1_000_000) return (0, 0);

            uint160 limitX96 = zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE;
            int256 amountRemaining = exactOut ? int256(swapAmount) : -int256(swapAmount);
            int256 amountCalculated;

            while (amountRemaining != 0 && sqrtPriceX96 != limitX96) {
                (int24 tickNext, bool initialized) = _nextTick(p, tick, zeroForOne);

                if (tickNext < TickMath.MIN_TICK) tickNext = TickMath.MIN_TICK;
                else if (tickNext > TickMath.MAX_TICK) tickNext = TickMath.MAX_TICK;

                uint160 sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(tickNext);

                // `stepIn` includes the fee. Folding them in `_step` is not
                // cosmetic: a fifth live local puts this loop over via-ir's stack.
                (uint160 sqrtPriceNext, uint256 stepIn, uint256 stepOut) = _step(
                    sqrtPriceX96,
                    (zeroForOne ? (sqrtPriceNextX96 < limitX96) : (sqrtPriceNextX96 > limitX96))
                        ? limitX96
                        : sqrtPriceNextX96,
                    liquidity,
                    amountRemaining,
                    swapFee
                );

                if (amountRemaining < 0) {
                    amountRemaining += int256(stepIn);
                    amountCalculated -= int256(stepOut);
                } else {
                    amountRemaining -= int256(stepOut);
                    amountCalculated += int256(stepIn);
                }

                if (sqrtPriceNext == sqrtPriceNextX96) {
                    if (initialized) {
                        int128 liqNet = _liquidityNet(p, tickNext);
                        if (zeroForOne) liqNet = -liqNet;
                        liquidity = LiquidityMath.addDelta(liquidity, liqNet);
                    }
                    tick = zeroForOne ? (tickNext - 1) : tickNext;
                } else if (sqrtPriceNext != sqrtPriceX96) {
                    tick = TickMath.getTickAtSqrtPrice(sqrtPriceNext);
                }

                sqrtPriceX96 = sqrtPriceNext;
            }

            // A partial fill is not a price — reporting the dribble would let a
            // near-empty pool win `best` with a number nobody can trade at.
            if (amountRemaining != 0) return (0, 0);

            if (exactOut) (amountIn, amountOut) = (uint256(amountCalculated), swapAmount);
            else (amountIn, amountOut) = (swapAmount, uint256(-amountCalculated));
        }
    }

    function _step(uint160 sqrtP, uint160 target, uint128 liquidity, int256 amountRemaining, uint24 swapFee)
        internal
        pure
        returns (uint160 sqrtPriceNext, uint256 stepInWithFee, uint256 stepOut)
    {
        uint256 feeAmt;
        (sqrtPriceNext, stepInWithFee, stepOut, feeAmt) =
            SwapMath.computeSwapStep(sqrtP, target, liquidity, amountRemaining, swapFee);
        unchecked {
            stepInWithFee += feeAmt;
        }
    }

    function _slot0(Pool memory p, bool zeroForOne)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity, uint24 swapFee)
    {
        unchecked {
            if (p.isV4) {
                (bool ok, bytes memory ret) = V4_STATE_VIEW.staticcall(
                    abi.encodeWithSelector(IStateViewV4.getSlot0.selector, p.id)
                );
                if (!ok || ret.length < 128) return (0, 0, 0, 0);
                uint24 protocolFee;
                uint24 lpFee;
                (sqrtPriceX96, tick, protocolFee, lpFee) = abi.decode(ret, (uint160, int24, uint24, uint24));
                liquidity = IStateViewV4(V4_STATE_VIEW).getLiquidity(p.id);

                // protocolFee is a PACKED uint24 — low 12 bits zeroForOne, high
                // 12 oneForZero — not a rate. Composing it the way v4-core does
                // stays correct if 4663 ever sets a protocolFeeController; see
                // src/zQuoterV4.sol for what the naive sum did to mainnet quotes.
                uint24 pf = zeroForOne ? (protocolFee & 0xfff) : (protocolFee >> 12);
                swapFee = pf == 0 ? lpFee : uint24(pf + lpFee - (uint256(pf) * uint256(lpFee)) / 1_000_000);
            } else {
                // Uniswap's slot0 returns seven words and Slipstream's six, so
                // only the two this needs are required to be there.
                (bool ok, bytes memory ret) = p.pool.staticcall(abi.encodeWithSelector(IV3Pool.slot0.selector));
                if (!ok || ret.length < 64) return (0, 0, 0, 0);
                (sqrtPriceX96, tick) = abi.decode(ret, (uint160, int24));
                liquidity = IV3Pool(p.pool).liquidity();
                // v3 takes its protocol fee from the LP's share, not the
                // swapper's, so the tier fee is the whole story.
                swapFee = p.fee;
            }
        }
    }

    /// @dev Uniswap's `ticks` returns eight values and Slipstream's two. Decoding
    /// the two-word prefix by hand covers both; the generated decoder would insist
    /// on the full Uniswap tuple and revert on a Slipstream pool.
    function _liquidityNet(Pool memory p, int24 tick) internal view returns (int128 liqNet) {
        if (p.isV4) {
            (, liqNet) = IStateViewV4(V4_STATE_VIEW).getTickLiquidity(p.id, tick);
        } else {
            (bool ok, bytes memory ret) =
                p.pool.staticcall(abi.encodeWithSelector(IV3Pool.ticks.selector, tick));
            if (!ok || ret.length < 64) return 0;
            (, liqNet) = abi.decode(ret, (uint128, int128));
        }
    }

    function _bitmapWord(Pool memory p, int16 wordPos) internal view returns (uint256) {
        return p.isV4 ? IStateViewV4(V4_STATE_VIEW).getTickBitmap(p.id, wordPos) : IV3Pool(p.pool).tickBitmap(wordPos);
    }

    /// @dev v3's `nextInitializedTickWithinOneWord`, reading its one word from
    /// whichever state layout this pool uses.
    function _nextTick(Pool memory p, int24 tick, bool zeroForOne)
        internal
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 spacing = p.spacing;
            int24 compressed = tick / spacing;
            if (tick < 0 && (tick % spacing != 0)) compressed--; // round toward -inf

            if (zeroForOne) {
                (int16 wordPos, uint8 bitPos) = _position(compressed);
                // Two terms, as Uniswap writes it: `(1 << (bitPos + 1)) - 1`
                // wraps to 0 at bitPos 255 because bitPos is a uint8 and this
                // block is unchecked, making the whole word read as empty.
                uint256 mask = ((uint256(1) << bitPos) - 1) + (uint256(1) << bitPos);
                uint256 masked = _bitmapWord(p, wordPos) & mask;
                initialized = masked != 0;
                // Stops at bit 0 of this word: a further spacing would enter the
                // next word without ever reading its bitmap.
                next = initialized
                    ? (compressed - int24(uint24(bitPos) - uint24(_msb(masked)))) * spacing
                    : (compressed - int24(uint24(bitPos))) * spacing;
            } else {
                (int16 wordPos, uint8 bitPos) = _position(compressed + 1);
                uint256 masked = _bitmapWord(p, wordPos) & ~((uint256(1) << bitPos) - 1);
                initialized = masked != 0;
                next = initialized
                    ? (compressed + 1 + int24(int256(uint256(_msb(masked & (~masked + 1)))) - int24(uint24(bitPos))))
                        * spacing
                    : (compressed + 1 + int24(uint24(255) - uint24(bitPos))) * spacing;
            }
        }
    }

    function _position(int24 tickCompressed) internal pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tickCompressed >> 8);
        bitPos = uint8(uint24(tickCompressed & 255));
    }

    function _msb(uint256 x) internal pure returns (uint8 r) {
        unchecked {
            if (x >= 2 ** 128) {
                x >>= 128;
                r += 128;
            }
            if (x >= 2 ** 64) {
                x >>= 64;
                r += 64;
            }
            if (x >= 2 ** 32) {
                x >>= 32;
                r += 32;
            }
            if (x >= 2 ** 16) {
                x >>= 16;
                r += 16;
            }
            if (x >= 2 ** 8) {
                x >>= 8;
                r += 8;
            }
            if (x >= 2 ** 4) {
                x >>= 4;
                r += 4;
            }
            if (x >= 2 ** 2) {
                x >>= 2;
                r += 2;
            }
            if (x >= 2 ** 1) r += 1;
        }
    }

    // ====================== HELPERS ======================

    function _normalizeETH(address token) internal pure returns (address) {
        return token == address(0) ? WETH : token;
    }

    function _wrap(uint256 a) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IZRouter.wrap.selector, a);
    }

    function _depUnwrap(uint256 a) internal pure returns (bytes memory d, bytes memory u) {
        d = abi.encodeWithSelector(IZRouter.deposit.selector, WETH, a);
        u = abi.encodeWithSelector(IZRouter.unwrap.selector, a);
    }

    function _sweepAmt(address token, uint256 amount, address to) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IZRouter.sweep.selector, token, amount, to);
    }

    function _mc2(bytes memory a, bytes memory b) internal pure returns (bytes memory) {
        bytes[] memory c = new bytes[](2);
        (c[0], c[1]) = (a, b);
        return abi.encodeWithSelector(IZRouter.multicall.selector, c);
    }

    function _mc3(bytes memory a, bytes memory b, bytes memory c_) internal pure returns (bytes memory) {
        bytes[] memory c = new bytes[](3);
        (c[0], c[1], c[2]) = (a, b, c_);
        return abi.encodeWithSelector(IZRouter.multicall.selector, c);
    }
}

interface IV2Pool {
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IV3Pool {
    function tickSpacing() external view returns (int24);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function liquidity() external view returns (uint128);
    function tickBitmap(int16) external view returns (uint256);
    function ticks(int24)
        external
        view
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool);
}

interface IAeroPool {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

interface IAeroV3Pool {
    function fee() external view returns (uint24); // micro-pips, per pool
}

interface IZRouter {
    function swapV2(address, bool, address, address, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256);
    function swapV3(address, bool, uint24, address, address, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256);
    function swapV4(address, bool, uint24, int24, address, address, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256);
    function swapAero(address, bool, address, address, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256);
    function swapAeroCL(address, bool, int24, address, address, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256);
    function multicall(bytes[] calldata) external payable returns (bytes[] memory);
    function sweep(address, uint256, address) external payable;
    function deposit(address, uint256) external payable;
    function wrap(uint256) external payable;
    function unwrap(uint256) external payable;
}
