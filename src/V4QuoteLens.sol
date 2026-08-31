// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title V4QuoteLens
/// @notice Quotes for Uniswap V4 pools whose price is set by a hook.
///
/// @dev WHY THE LOCAL MATH CANNOT COVER THESE POOLS. `zQuoterV4` reimplements
///      V4's concentrated-liquidity step function against StateView. That is
///      exact for an ordinary pool and structurally wrong for a hooked one: a
///      hook may return a BeforeSwapDelta that replaces the curve outright, take
///      an afterSwap delta out of the swapper's output, or set the fee per swap.
///      None of that is visible in slot0 and liquidity. On the live ETH/FWA pool
///      (hook 0x2C67...6444) the hook prices the trade itself, so no amount of
///      correcting the tick math gets the answer.
///
///      The only thing that quotes a hook correctly is running it. Uniswap's
///      canonical V4Quoter does exactly that - it calls PoolManager.unlock,
///      performs the real swap, and reverts with the resulting delta, which it
///      catches and decodes. Hook logic, hook deltas and dynamic fees are then
///      correct by construction rather than by reimplementation.
///
/// @dev WHY THIS IS NOT `view`. `unlock` writes transient storage, and TSTORE is
///      forbidden under STATICCALL, so V4Quoter and everything wrapping it must
///      be `nonpayable`. Off-chain callers lose nothing - `eth_call` simulates a
///      nonpayable function fine. On-chain callers cannot use it from a `view`
///      context; that is the price of quoting a hook honestly, and it is why
///      this is a separate contract rather than a branch inside `zQuoterV4`.
///
/// @dev USE. Route a pool here when its `hooks` address is non-zero, and to
///      `zQuoterV4` otherwise. Nothing here knows about any particular pool or
///      token; a hooked pool is a hooked pool.
///
///      WHICH HOOKED POOLS. Quoting one is not endorsing one. The page routes
///      through a hooked pool only when the curated token list carries that
///      pool's spec - the list is the trust decision, made by the same DAO
///      that curates the tokens themselves. Execution adds its own bound: the
///      router re-checks the user's minimum at settlement, so a hook that
///      turns hostile between quote and swap can waste a transaction but
///      cannot push a fill past the bound it was quoted against.
contract V4QuoteLens {
    /// @dev Uniswap's canonical V4Quoter on Ethereum mainnet. Confirmed rather
    ///      than assumed: its `poolManager()` returns 0x0000...4444c5dc75cB35
    ///      8380D2e3dE08A90, the mainnet PoolManager the pools actually live in.
    address public constant V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;

    /// @notice Quote one hooked V4 hop, in the same shape `zQuoterV4.quoteV4`
    ///         returns, so a caller can pick between them on `hooks != 0` alone.
    /// @param exactOut  `swapAmount` is the desired output rather than the input.
    /// @param swapAmount Input when `exactOut` is false, output when it is true.
    /// @return amountIn  What must be paid.
    /// @return amountOut What is received.
    ///
    /// @dev A pool that cannot serve the quote - not initialised, a hook that
    ///      reverts, liquidity exhausted before the exact-out target - returns
    ///      (0, 0) rather than reverting, so one dead pool cannot take down a
    ///      multi-venue quote sweep. Callers must treat a zero leg as "no route",
    ///      not as "free". `exactOut` is the common casualty: a custom-curve
    ///      hook often implements only the exact-in direction and reverts on the
    ///      other, so a pool can quote exact-in and still return zero here -
    ///      that is the hook's answer, not a bug in the lens.
    function quoteV4Hooked(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint256 swapAmount,
        bytes calldata hookData
    ) public returns (uint256 amountIn, uint256 amountOut) {
        return _quote(exactOut, tokenIn, tokenOut, fee, tickSpacing, hooks, swapAmount, hookData);
    }

    function _quote(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint256 swapAmount,
        bytes memory hookData
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        if (swapAmount == 0 || swapAmount > type(uint128).max) return (0, 0);

        bool zeroForOne = uint160(tokenIn) < uint160(tokenOut);
        PoolKey memory key = zeroForOne
            ? PoolKey(tokenIn, tokenOut, fee, tickSpacing, hooks)
            : PoolKey(tokenOut, tokenIn, fee, tickSpacing, hooks);

        QuoteExactSingleParams memory params =
            QuoteExactSingleParams(key, zeroForOne, uint128(swapAmount), hookData);

        if (exactOut) {
            try IV4Quoter(V4_QUOTER).quoteExactOutputSingle(params) returns (uint256 got, uint256) {
                return (got, swapAmount);
            } catch {
                return (0, 0);
            }
        }
        try IV4Quoter(V4_QUOTER).quoteExactInputSingle(params) returns (uint256 got, uint256) {
            return (swapAmount, got);
        } catch {
            return (0, 0);
        }
    }

    /// @notice `quoteV4Hooked` with no hook data, the common case.
    function quoteV4Hooked(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint256 swapAmount
    ) public returns (uint256 amountIn, uint256 amountOut) {
        return _quote(exactOut, tokenIn, tokenOut, fee, tickSpacing, hooks, swapAmount, "");
    }

    /// @notice "I want at least `targetOut`" for a pool that has no exact-out.
    ///
    /// @dev THE ETH/FWA HOOK IS ONE OF THESE. Its `afterSwap` reverts on any
    ///      positive `amountSpecified` - proven directly against PoolManager.swap
    ///      in `FwaHookExactOutTest`, with an exact-in control through the same
    ///      path - so `quoteV4Hooked(exactOut: true, ...)` returns no route and
    ///      an exact-output field would have nothing to show. A custom-curve
    ///      hook implementing only one direction is a normal thing to be; the
    ///      way around it is to search the direction that does work.
    ///
    ///      Bisects exact-in quotes for the smallest input whose output clears
    ///      `targetOut`. Each step runs the hook for real, so the answer is the
    ///      hook's own pricing rather than an inversion of a formula it does not
    ///      follow.
    ///
    /// @dev ASSUMES OUTPUT RISES WITH INPUT. True of any sane pool and of this
    ///      hook, but a hook is arbitrary code and could break it; the result is
    ///      then merely a worse input, never an unsafe one, because the returned
    ///      `amountOut` is a real quote that the caller still checks.
    ///
    /// @dev SIMULATION ONLY. Every step is a full `unlock` and swap, so this
    ///      costs roughly `maxIters` times a quote. That is fine in `eth_call`
    ///      and wrong in a transaction.
    ///
    /// @param maxIn    Ceiling on what the caller will spend - their balance, or
    ///                 the target scaled up by a generous factor.
    /// @param maxIters Bisection steps; 60 resolves a full uint128 range, ~40 is
    ///                 ample for any realistic bound. Clamped to 128.
    /// @return amountIn  Smallest input found that clears the target.
    /// @return amountOut What that input actually returns - always >= targetOut,
    ///                   or (0, 0) if `maxIn` itself cannot reach the target.
    function solveExactOut(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint256 targetOut,
        uint256 maxIn,
        uint256 maxIters
    ) public returns (uint256 amountIn, uint256 amountOut) {
        if (targetOut == 0 || maxIn == 0) return (0, 0);
        if (maxIters == 0 || maxIters > 128) maxIters = 128;

        // The ceiling has to clear the target, or there is nothing to search.
        (, uint256 hiOut) = _quote(false, tokenIn, tokenOut, fee, tickSpacing, hooks, maxIn, "");
        if (hiOut < targetOut) return (0, 0);

        uint256 lo; // known short
        uint256 hi = maxIn; // known sufficient
        amountIn = maxIn;
        amountOut = hiOut;

        for (uint256 i; i < maxIters && hi - lo > 1; ++i) {
            uint256 mid = lo + (hi - lo) / 2;
            (, uint256 midOut) = _quote(false, tokenIn, tokenOut, fee, tickSpacing, hooks, mid, "");
            if (midOut >= targetOut) {
                hi = mid;
                amountIn = mid;
                amountOut = midOut;
            } else {
                lo = mid;
            }
        }
    }

    /// @notice Quote one input against several candidate amounts in a single
    ///         call, so a page sizing a trade pays one round trip, not N.
    /// @dev Each entry is quoted independently; a failing one is (0, 0) and does
    ///      not disturb its neighbours. Note that hooked pools are not
    ///      necessarily linear, so a quote for 2x the input is not 2x the
    ///      output - which is precisely why each amount needs its own quote.
    function quoteV4HookedBatch(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint256[] calldata swapAmounts
    ) public returns (uint256[] memory amountsIn, uint256[] memory amountsOut) {
        amountsIn = new uint256[](swapAmounts.length);
        amountsOut = new uint256[](swapAmounts.length);
        for (uint256 i; i < swapAmounts.length; ++i) {
            (amountsIn[i], amountsOut[i]) =
                quoteV4Hooked(exactOut, tokenIn, tokenOut, fee, tickSpacing, hooks, swapAmounts[i]);
        }
    }
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct QuoteExactSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 exactAmount;
    bytes hookData;
}

interface IV4Quoter {
    function quoteExactInputSingle(QuoteExactSingleParams memory)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
    function quoteExactOutputSingle(QuoteExactSingleParams memory)
        external
        returns (uint256 amountIn, uint256 gasEstimate);
}
