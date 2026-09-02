// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {TickMath, SwapMath, LiquidityMath, IStateViewV4, _sortTokens, _v4PoolId} from "./zQuoterV4.sol";

// zQuoterSepolia
// A minimal, self-contained quoter for the zRouter deployed to Sepolia.
//
// WHY THIS IS NOT src/zQuoter.sol
// The mainnet quoter cannot run here for three independent reasons, and each one
// argues for a smaller contract rather than a ported one:
//
//  1. It is a THIN SHELL over a base quoter at 0x658bF1A6608210FDE7310760f391AD4eC8006A5F.
//     That address has no code on Sepolia, and a staticcall to a codeless address
//     succeeds with empty returndata — so a port would not revert, it would quote
//     zeros. This contract does its own math and calls nothing it does not name.
//  2. It quotes Curve, Lido, Sushi and zAMM. None of that infrastructure is on
//     Sepolia in a usable form, and — decisively — the zRouter actually deployed to
//     Sepolia at 0x000000000000FB114709235f1ccBFfb925F600e4 does not carry
//     `swapVZ` at all. Quoting a venue the router cannot execute produces a
//     "best" route that reverts, which is worse than no route.
//  3. It sits 138 bytes under EIP-170 and only builds under `FOUNDRY_PROFILE=zquoter`
//     with `yul = false`. That build fragility is a mainnet tax paid for mainnet
//     venue coverage; there is no reason to inherit it on a testnet.
//
// WHAT IT COVERS: exactly the three venues the Sepolia zRouter can execute —
// Uniswap V2, V3 and V4 — verified against that deployment's own runtime code
// rather than assumed. The constants below were read out of it.
//
// ABI COMPATIBILITY: `AMM`, `Quote`, `getQuotes` and `buildBestSwap` keep the
// mainnet zQuoter's exact shapes, including the unused enum ordinals. Integrator
// code written against Sepolia therefore moves to mainnet without an edit; the
// venues it never sees here simply start appearing.
address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

address constant V2_FACTORY = 0xF62c03E08ada871A0bEb309762E260a7a6a880E6;
bytes32 constant V2_POOL_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

address constant V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
bytes32 constant V3_POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

// @dev The v4 lens. `StateView.poolManager()` returns 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543,
// which is the same PoolManager the deployed Sepolia zRouter holds — checked, not assumed.
address constant V4_STATE_VIEW = 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C;

uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

uint256 constant BPS = 10_000;

contract zQuoterSepolia {
    error NoRoute();
    error IdenticalTokens();
    error SlippageBpsTooHigh();

    /// @dev Ordinals are load-bearing: they match src/zQuoter.sol so a `source`
    /// value crossing the wire means the same thing on both chains. SUSHI, ZAMM,
    /// CURVE and LIDO are never produced here — they are placeholders that keep
    /// UNI_V3 at 3 and UNI_V4 at 4.
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

    /// @dev The V3/V4 tiers to sweep, in hundredths of a bip. The tick spacings are
    /// Uniswap's canonical pairing and are the ones the router will re-derive from
    /// `feeBps` when it executes, so quoting any other spacing would quote a pool
    /// the built calldata cannot reach.
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

    constructor() payable {}

    // ====================== AGGREGATE ======================

    /// @notice Quote every venue the Sepolia zRouter can execute, and pick the best.
    /// @param exactOut false = `swapAmount` is the input; true = it is the desired output.
    /// @return best The winning quote, zeroed if nothing quoted.
    /// @return quotes All nine candidates, in a stable order: V2, then V3 by tier,
    ///         then V4 by tier. Entries that did not quote are left at zero rather
    ///         than dropped, so a caller can index by venue.
    function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (Quote memory best, Quote[] memory quotes)
    {
        require(_normalizeETH(tokenIn) != _normalizeETH(tokenOut), IdenticalTokens());

        uint24[4] memory tiers = _tiers();
        quotes = new Quote[](9);

        (uint256 aIn, uint256 aOut) = quoteV2(exactOut, tokenIn, tokenOut, swapAmount);
        quotes[0] = Quote(AMM.UNI_V2, 30, aIn, aOut);

        for (uint256 i; i < 4; ++i) {
            (aIn, aOut) = quoteV3(exactOut, tokenIn, tokenOut, tiers[i], swapAmount);
            quotes[1 + i] = Quote(AMM.UNI_V3, tiers[i] / 100, aIn, aOut);

            (aIn, aOut) = quoteV4(exactOut, tokenIn, tokenOut, tiers[i], swapAmount);
            quotes[5 + i] = Quote(AMM.UNI_V4, tiers[i] / 100, aIn, aOut);
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

    /// @notice Quote, then hand back calldata that can be sent to zRouter as-is.
    /// @param to Recipient of the output. Pass ZROUTER to leave funds in the router
    ///        for a following call.
    /// @return best The venue that won.
    /// @return callData Send this to ZROUTER with `msgValue` attached.
    /// @return amountLimit The slippage bound already embedded in `callData` —
    ///         minimum out for exactIn, maximum in for exactOut.
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

        // ETH <-> WETH is 1:1 and is not a swap. The router wraps and unwraps
        // directly, so quoting a venue for it would only invent a spread.
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
        revert NoRoute();
    }

    // ====================== UNISWAP V2 ======================

    /// @dev Constant product at the canonical 0.30% fee. Reverts are impossible
    /// here — a missing pair has no code, `getReserves` returns nothing, and the
    /// staticcall guard below reports (0, 0) rather than propagating.
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
                // An exact-out larger than the reserve is not expensive, it is
                // impossible: the denominator would underflow into a nonsense price.
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

    /// @dev Where the concentrated-liquidity state lives. V3 keeps it on the pool
    /// contract; V4 keeps it in the singleton and is read through StateView. The
    /// step math downstream is identical, so this struct is the only fork.
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

        return _quoteCL(
            Pool(false, pool, bytes32(0), _spacingFromBps(uint16(fee / 100)), fee), exactOut, zeroForOne, swapAmount
        );
    }

    /// @dev Hookless pools only. A hook can rewrite the swap arbitrarily, so a
    /// quote computed from pool state alone would be a guess — and the router's
    /// `swapV4` has no hook argument to execute against in any case.
    function quoteV4(bool exactOut, address tokenIn, address tokenOut, uint24 fee, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        // Native ether is a first-class currency in v4 (address(0)), so unlike V2/V3
        // it is NOT normalized to WETH here — that would quote a different pool.
        if (tokenIn == tokenOut) return (0, 0);
        int24 spacing = _spacingFromBps(uint16(fee / 100));
        (bytes32 id, bool zeroForOne) = _v4PoolId(tokenIn, tokenOut, fee, spacing, address(0));
        return _quoteCL(Pool(true, address(0), id, spacing, fee), exactOut, zeroForOne, swapAmount);
    }

    /// @dev The shared concentrated-liquidity engine. This is Uniswap's own step
    /// loop; the sign convention is v4's (exact-in negative, exact-out positive),
    /// which v3 shares.
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

                // `stepIn` here is input INCLUSIVE of the fee. Folding the two
                // together at the call site is not cosmetic: keeping `feeAmt` as a
                // fifth live local puts this loop one slot over via-ir's stack.
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

            // A partial fill is not a price. Uniswap's own quoter reverts with
            // NotEnoughLiquidity here; reporting the dribble instead would let a
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

                // protocolFee is a PACKED uint24 — low 12 bits zeroForOne, high 12
                // oneForZero — not a rate. Composing it the way v4-core does is
                // currently a no-op on Sepolia (PoolManager.protocolFeeController is
                // unset, so no pool can carry one) and stays correct if that changes.
                // See src/zQuoterV4.sol for what the naive `protocolFee + lpFee`
                // did to mainnet quotes once Uniswap switched protocol fees on.
                uint24 pf = zeroForOne ? (protocolFee & 0xfff) : (protocolFee >> 12);
                swapFee = pf == 0 ? lpFee : uint24(pf + lpFee - (uint256(pf) * uint256(lpFee)) / 1_000_000);
            } else {
                (bool ok, bytes memory ret) = p.pool.staticcall(abi.encodeWithSelector(IV3Pool.slot0.selector));
                if (!ok || ret.length < 224) return (0, 0, 0, 0);
                (sqrtPriceX96, tick) = abi.decode(ret, (uint160, int24));
                liquidity = IV3Pool(p.pool).liquidity();
                // v3's protocol fee is taken out of the LP's share, not the swapper's,
                // so the tier fee is the whole story for a quote.
                swapFee = p.fee;
            }
        }
    }

    function _liquidityNet(Pool memory p, int24 tick) internal view returns (int128 liqNet) {
        if (p.isV4) {
            (, liqNet) = IStateViewV4(V4_STATE_VIEW).getTickLiquidity(p.id, tick);
        } else {
            (, liqNet,,,,,,) = IV3Pool(p.pool).ticks(tick);
        }
    }

    function _bitmapWord(Pool memory p, int16 wordPos) internal view returns (uint256) {
        return p.isV4 ? IStateViewV4(V4_STATE_VIEW).getTickBitmap(p.id, wordPos) : IV3Pool(p.pool).tickBitmap(wordPos);
    }

    /// @dev v3's `nextInitializedTickWithinOneWord`, with the one word it needs
    /// fetched from whichever of the two state layouts this pool uses.
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
                // Uniswap writes the mask as two terms and it is not stylistic:
                // `(1 << (bitPos + 1)) - 1` looks equivalent but `bitPos` is a
                // uint8, so at 255 the increment wraps to zero inside this
                // unchecked block and the mask becomes 0 — the word then reads as
                // empty and every initialized tick in it is skipped.
                uint256 mask = ((uint256(1) << bitPos) - 1) + (uint256(1) << bitPos);
                uint256 masked = _bitmapWord(p, wordPos) & mask;
                initialized = masked != 0;
                // The uninitialized case stops at bit 0 of this word. Stepping a
                // further spacing past it would enter the next word without ever
                // reading its bitmap, so bit 255 down there could be crossed
                // without picking up its liquidityNet.
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
        d = abi.encodeWithSelector(IZRouter.deposit.selector, WETH, 0, a);
        u = abi.encodeWithSelector(IZRouter.unwrap.selector, a);
    }

    function _sweepAmt(address token, uint256 amount, address to) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IZRouter.sweep.selector, token, 0, amount, to);
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
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function liquidity() external view returns (uint128);
    function tickBitmap(int16) external view returns (uint256);
    function ticks(int24)
        external
        view
        returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool);
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
    function multicall(bytes[] calldata) external payable returns (bytes[] memory);
    function sweep(address, uint256, uint256, address) external payable;
    function deposit(address, uint256, uint256) external payable;
    function wrap(uint256) external payable;
    function unwrap(uint256) external payable;
}
