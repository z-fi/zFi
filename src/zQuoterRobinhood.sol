// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {TickMath, SwapMath, LiquidityMath, IStateViewV4, _sortTokens, _v4PoolId} from "./zQuoterV4.sol";

// zQuoterRobinhood — quotes Uniswap V2/V3/V4 for zRouterLiteRobinhood on Robinhood Chain.
//
// Not a port of src/zQuoter.sol: that one is a shell over a base quoter with no
// code on 4663, and a staticcall to a codeless address returns empty rather than
// reverting, so a port would quote zeros instead of failing. This does its own
// math and calls nothing it does not name.
//
// The init-code hashes below are the canonical Uniswap ones, which is the fact
// the whole design rests on: quoter and router derive pool addresses the same
// way, so a quote and the calldata built from it cannot name different pools.
//
// `AMM`, `Quote`, `getQuotes` and `buildBestSwap` keep mainnet zQuoter's shapes,
// so front-end code moves between chains unedited. The calldata it BUILDS
// targets zRouterLiteRobinhood, whose `deposit` and `sweep` drop mainnet's ERC6909 id —
// the two contracts ship as a pair.
address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

address constant V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
bytes32 constant V2_POOL_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
bytes32 constant V3_POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

// The v4 lens. Its `poolManager()` is the singleton zRouterLiteRobinhood holds — checked.
address constant V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;

uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

uint256 constant BPS = 10_000;

contract zQuoterRobinhood {
    error NoRoute();
    error IdenticalTokens();
    error SlippageBpsTooHigh();

    /// @dev Ordinals match src/zQuoter.sol so a `source` means the same thing on
    /// both chains. The four venues that do not exist here are never produced;
    /// they hold UNI_V3 at 3 and UNI_V4 at 4.
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

    /// @dev A constructor argument, not a constant: nothing is deployed to 4663
    /// yet, and `buildBestSwap` compares `to` against it to decide whether output
    /// may stay in the router. A wrong constant would take the other branch
    /// silently rather than fail.
    address public immutable ZROUTER;

    constructor(address zRouter) payable {
        ZROUTER = zRouter;
    }

    // ====================== AGGREGATE ======================

    /// @notice Quote every venue zRouterLiteRobinhood can execute, and pick the best.
    /// @param exactOut false = `swapAmount` is the input; true = it is the desired output.
    /// @return best The winning quote, zeroed if nothing quoted.
    /// @return quotes All nine candidates: V2, then V3 by tier, then V4 by tier.
    ///         Entries that did not quote stay at zero so callers can index by venue.
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
        revert NoRoute();
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

        return _quoteCL(
            Pool(false, pool, bytes32(0), _spacingFromBps(uint16(fee / 100)), fee), exactOut, zeroForOne, swapAmount
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
                (bool ok, bytes memory ret) = p.pool.staticcall(abi.encodeWithSelector(IV3Pool.slot0.selector));
                if (!ok || ret.length < 224) return (0, 0, 0, 0);
                (sqrtPriceX96, tick) = abi.decode(ret, (uint160, int24));
                liquidity = IV3Pool(p.pool).liquidity();
                // v3 takes its protocol fee from the LP's share, not the
                // swapper's, so the tier fee is the whole story.
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
    function sweep(address, uint256, address) external payable;
    function deposit(address, uint256) external payable;
    function wrap(uint256) external payable;
    function unwrap(uint256) external payable;
}
