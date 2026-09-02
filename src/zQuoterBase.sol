// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {TickMath, SwapMath, LiquidityMath, IStateViewV4, _sortTokens, _v4PoolId} from "./zQuoterV4.sol";

// zQuoterBase — quotes Uniswap V2/V3/V4, Aerodrome, Aerodrome Slipstream and
// zAMM for zRouterLiteBase on Base (8453).
//
// A rewrite of the quoter behind 0x772E2810A471dB2CC7ADA0d37D6395476535889a (a
// lens forwarding to 0xa8Cc0177598531eC7D223E9689fdD50E120b946c), fixing three
// things that deployment gets wrong:
//
//  1. It quotes Uniswap v3 by calling Uniswap's own quoter at 0x222cA98F. That is
//     a simulate-and-revert contract; a `try` around it swallows every failure as
//     "no route", and it is one more address that has to stay deployed and
//     correct. This walks the ticks itself, with the same engine v4 uses.
//  2. It sweeps Aerodrome Slipstream at tick spacings 1, 10, 60 and 200, which is
//     Uniswap's fee/spacing pairing. Slipstream's real spacings are 1, 10, 50,
//     100, 200 and 2000, so 60 does not exist and 50, 100 and 2000 — where most
//     of the volume is — were never quoted at all.
//  3. Its AERO_CL quotes label `feeBps` with the Uniswap tier they were never
//     taken at, and the builder then reconstructs a spacing from that label. Here
//     an AERO_CL quote carries its actual tick spacing in `feeBps`, which is the
//     only value that identifies a Slipstream pool.
//
// The AERO convention is kept as-is for compatibility: `feeBps` 2 means the
// stable pool won and 20 means the volatile one. It is a discriminator, not a
// fee, and it is what the front end already decodes.
//
// Pool addresses are derived the same way `zRouterLiteBase` derives them, so a
// quote and the calldata built from it cannot name different pools.
address constant WETH = 0x4200000000000000000000000000000000000006;

address constant V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
bytes32 constant V2_POOL_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

address constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
bytes32 constant V3_POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

// The v4 lens. Its `poolManager()` is the singleton zRouterLiteBase holds — checked.
address constant V4_STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;

address constant ZAMM = 0x000000000000040470635EB91b7CE4D132D616eD;

address constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
address constant AERO_IMPLEMENTATION = 0xA4e46b4f701c62e14DF11B48dCe76A7d793CD6d7;
address constant AERO_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
address constant AERO_CL_IMPLEMENTATION = 0xeC8E5342B19977B4eF8892e02D8DAEcfa1315831;

uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

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

    /// @dev A constructor argument, not a constant: nothing is deployed to 4663
    /// yet, and `buildBestSwap` compares `to` against it to decide whether output
    /// may stay in the router. A wrong constant would take the other branch
    /// silently rather than fail.
    address public immutable ZROUTER;

    constructor(address zRouter) payable {
        ZROUTER = zRouter;
    }

    // ====================== AGGREGATE ======================

    /// @dev zAMM fee tiers, in bps. A pool's fee is part of its key, so these are
    /// separate pools rather than settings on one.
    function _zammFees() internal pure returns (uint256[4] memory) {
        return [uint256(1), 5, 30, 100];
    }

    /// @dev Slipstream's real tick spacings, read off `tickSpacings()`. The
    /// deployed quoter guesses Uniswap's 1/10/60/200 instead and misses three of
    /// these while probing a 60 that has never existed on this factory.
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

        // Aerodrome classic is exact-in only: `swapAero` reads the pool's own
        // `getAmountOut` and spends whatever it is given. An exact-out route
        // through it has to pin the input at a solved number, which leaves the
        // user with no tolerance at all — any reserve movement between quote and
        // block reverts the swap, and `slippageBps` cannot be honoured because
        // there is no input bound to widen. So it does not compete for exact-out;
        // the other five venues do that properly. `quoteAero` still answers an
        // exact-out question for callers who want the number.
        if (!exactOut) {
            uint256 kind;
            (aIn, aOut, kind) = quoteAero(false, tokenIn, tokenOut, swapAmount);
            quotes[1] = Quote(AMM.AERO, kind, aIn, aOut);
        }

        uint256[4] memory zFees = _zammFees();
        for (uint256 i; i < 4; ++i) {
            (aIn, aOut) = quoteZAMM(exactOut, zFees[i], tokenIn, tokenOut, 0, 0, swapAmount);
            quotes[2 + i] = Quote(AMM.ZAMM, zFees[i], aIn, aOut);
        }

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
        if (q.source == AMM.ZAMM) {
            return abi.encodeWithSelector(
                IZRouter.swapVZ.selector,
                to,
                exactOut,
                q.feeBps,
                tokenIn,
                tokenOut,
                uint256(0),
                uint256(0),
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

    // ====================== ZAMM ======================

    /// @dev Constant product with the fee baked into the pool key, so each fee is
    /// a different pool rather than a setting. ERC6909 ids address zAMM's own
    /// coins; zero is the ERC20 side.
    function quoteZAMM(
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        unchecked {
            if (swapAmount == 0 || feeOrHook >= BPS) return (0, 0);
            (address token0, address token1, bool zeroForOne) = _sortTokens(tokenIn, tokenOut);
            if (token0 == token1) return (0, 0);
            (uint256 id0, uint256 id1) = tokenIn == token0 ? (idIn, idOut) : (idOut, idIn);

            uint256 poolId = uint256(keccak256(abi.encode(PoolKey(id0, id1, token0, token1, feeOrHook))));
            (bool ok, bytes memory ret) =
                ZAMM.staticcall(abi.encodeWithSelector(IZAMM.pools.selector, poolId));
            if (!ok || ret.length < 64) return (0, 0);
            (uint112 r0, uint112 r1) = abi.decode(ret, (uint112, uint112));

            (uint256 resIn, uint256 resOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            if (resIn == 0 || resOut == 0) return (0, 0);

            if (exactOut) {
                if (swapAmount >= resOut) return (0, 0);
                amountOut = swapAmount;
                amountIn = (resIn * amountOut * BPS) / ((resOut - amountOut) * (BPS - feeOrHook)) + 1;
            } else {
                amountIn = swapAmount;
                uint256 inWithFee = amountIn * (BPS - feeOrHook);
                amountOut = (inWithFee * resOut) / (resIn * BPS + inWithFee);
            }
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
        d = abi.encodeWithSelector(IZRouter.deposit.selector, WETH, uint256(0), a);
        u = abi.encodeWithSelector(IZRouter.unwrap.selector, a);
    }

    function _sweepAmt(address token, uint256 amount, address to) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IZRouter.sweep.selector, token, uint256(0), amount, to);
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

interface IAeroPool {
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

interface IAeroV3Pool {
    function fee() external view returns (uint24); // micro-pips, per pool
}

struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook;
}

interface IZAMM {
    function pools(uint256 poolId)
        external
        view
        returns (uint112, uint112, uint32, uint256, uint256, uint256, uint256);
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
    function swapVZ(address, bool, uint256, address, address, uint256, uint256, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256);
    function multicall(bytes[] calldata) external payable returns (bytes[] memory);
    function sweep(address, uint256, uint256, address) external payable;
    function deposit(address, uint256, uint256) external payable;
    function wrap(uint256) external payable;
    function unwrap(uint256) external payable;
}
