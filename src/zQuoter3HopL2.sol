// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @dev The L2 quoters' `Quote`. `source` is their AMM enum, a uint8 on the wire,
/// so this is the same four words mainnet zQuoter returns and zSwap decodes.
struct Quote {
    uint8 source;
    uint256 feeBps;
    uint256 amountIn;
    uint256 amountOut;
}

interface IL2Quoter {
    function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        external
        view
        returns (Quote memory best, Quote[] memory quotes);
}

interface IZRouterL2 {
    function swapV2(address, bool, address, address, uint256, uint256, uint256) external payable;
    function swapV3(address, bool, uint24, address, address, uint256, uint256, uint256) external payable;
    function swapV4(address, bool, uint24, int24, address, address, uint256, uint256, uint256) external payable;
    function swapAero(address, bool, address, address, uint256, uint256, uint256) external payable;
    function swapAeroCL(address, bool, int24, address, address, uint256, uint256, uint256) external payable;
    function sweep(address, uint256, address) external payable;
    function multicall(bytes[] calldata) external payable returns (bytes[] memory);
}

/// @title zQuoter3HopL2
/// @notice Three-hop routes on Base and Robinhood Chain, whose quoters have no
///         builder of their own. zSwap asks this where it asks mainnet zQuoter's
///         `build3HopMulticall`, with the same arguments, and decodes the same answer.
///
/// @dev A COMPANION, NOT A QUOTER. Every price comes from the chain's deployed
///      quoter through its public `getQuotes`, so this contract adds routing and
///      calldata and never a venue or a price model: a hop here reaches exactly
///      what that quoter reaches.
///
///      THE ROUTE is tokenIn -> MID1 -> MID2 -> tokenOut, over every ordered pair
///      of distinct hubs. Exact-in keeps the largest output and passes 0 as the
///      amount of legs 2 and 3, which the router reads as "spend what the previous
///      leg left here". Exact-out keeps the smallest input, gives every leg an
///      explicit target worked back from the output, and sweeps what is left of
///      the output, both hubs, the input and ether to `to`. Both mirror mainnet
///      zQuoter's builder, so zSwap executes either answer the same way.
///
///      ONE SOURCE FOR BOTH CHAINS. The two quoters' AMM ordinals agree on V2 (0),
///      v3 (3) and v4 (4). Aerodrome (1) and Slipstream (5) exist only on Base; the
///      Robinhood quoter never produces them. Quoter, router, WETH and hubs are
///      constructor arguments, so each chain's build sits at one CREATE3 address.
///
///      ETHER as `address(0)` passes through to the router, which wraps and
///      unwraps. Hubs are compared against the WETH it stands for, so an ether leg
///      never names WETH as its own hub.
contract zQuoter3HopL2 {
    error NoRoute();
    error BadConfig();
    error IdenticalTokens();
    error SlippageBpsTooHigh();

    uint256 constant BPS = 10_000;
    uint8 constant UNI_V2 = 0;
    uint8 constant AERO = 1;
    uint8 constant UNI_V3 = 3;
    uint8 constant UNI_V4 = 4;
    uint8 constant AERO_CL = 5;

    struct Route3 {
        bool found;
        address mid1;
        address mid2;
        uint256 score;
        Quote a;
        Quote b;
        Quote c;
    }

    IL2Quoter public immutable quoter;
    address public immutable router;
    address public immutable weth;
    uint256 public immutable hubCount;

    address immutable h0;
    address immutable h1;
    address immutable h2;
    address immutable h3;
    address immutable h4;
    address immutable h5;

    /// @param hubs_ Two to six liquidity centres, in the order they are tried.
    /// @dev Rejects a quoter or router with no code, so a build pointed at the
    ///      wrong chain fails at deployment rather than answering "no route" forever.
    ///
    ///      HUBS COST GAS QUADRATICALLY. A route asks the quoter once per first hub
    ///      and twice per ordered hub pair, and every ask scans each venue the
    ///      quoter knows. Measured on Base: two hubs build in 4-6M gas, three in
    ///      35-75M, five in 100-350M, while many nodes cap `eth_call` at 50M. A
    ///      build the page's node refuses is a route the page never sees, so deploy
    ///      the fewest hubs that carry the chain's depth.
    constructor(IL2Quoter quoter_, address router_, address weth_, address[] memory hubs_) {
        uint256 n = hubs_.length;
        if (n < 2 || n > 6 || weth_ == address(0)) revert BadConfig();
        if (address(quoter_).code.length == 0 || router_.code.length == 0) revert BadConfig();
        address[6] memory h;
        for (uint256 i; i < n; ++i) {
            if (hubs_[i] == address(0)) revert BadConfig();
            for (uint256 j; j < i; ++j) {
                if (hubs_[j] == hubs_[i]) revert BadConfig();
            }
            h[i] = hubs_[i];
        }
        (quoter, router, weth, hubCount) = (quoter_, router_, weth_, n);
        (h0, h1, h2, h3, h4, h5) = (h[0], h[1], h[2], h[3], h[4], h[5]);
    }

    /// @notice The hubs, in the order they are tried.
    function hubs() public view returns (address[] memory out) {
        address[6] memory h = [h0, h1, h2, h3, h4, h5];
        out = new address[](hubCount);
        for (uint256 i; i < out.length; ++i) {
            out[i] = h[i];
        }
    }

    /// @notice The slippage bound embedded in every leg. Same shape as the
    ///         quoters' `limit`: floor for exact-in, ceiling for exact-out.
    function limit(bool exactOut, uint256 quoted, uint256 bps) public pure returns (uint256) {
        if (bps >= BPS) revert SlippageBpsTooHigh();
        return exactOut ? (quoted * (BPS + bps) + BPS - 1) / BPS : (quoted * (BPS - bps)) / BPS;
    }

    /// @notice Build a three-hop multicall through two hubs:
    ///           tokenIn -[leg 1]-> MID1 -[leg 2]-> MID2 -[leg 3]-> tokenOut
    /// @dev Same signature and return shape as mainnet zQuoter's
    ///      `build3HopMulticall` (selector 0x4c464f59). Send `multicall` to the
    ///      router with `msgValue` attached.
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
        returns (Quote memory a, Quote memory b, Quote memory c, bytes[] memory calls, bytes memory multicall, uint256 msgValue)
    {
        if (_norm(tokenIn) == _norm(tokenOut)) revert IdenticalTokens();
        if (slippageBps >= BPS) revert SlippageBpsTooHigh();

        Route3 memory r = exactOut
            ? _backward(tokenIn, tokenOut, swapAmount, slippageBps)
            : _forward(tokenIn, tokenOut, swapAmount, slippageBps);
        if (!r.found) revert NoRoute();
        (a, b, c) = (r.a, r.b, r.c);

        if (!exactOut) {
            calls = new bytes[](3);
            calls[0] = _leg(
                router, false, tokenIn, r.mid1, swapAmount, limit(false, a.amountOut, slippageBps), deadline, a
            );
            calls[1] = _leg(router, false, r.mid1, r.mid2, 0, limit(false, b.amountOut, slippageBps), deadline, b);
            calls[2] = _leg(to, false, r.mid2, tokenOut, 0, limit(false, c.amountOut, slippageBps), deadline, c);
            msgValue = tokenIn == address(0) ? swapAmount : 0;
        } else {
            bool chaining = to == router;
            bool ethIn = tokenIn == address(0);
            calls = new bytes[](chaining ? 3 : (ethIn ? 7 : 8));

            uint256 mid1Target = limit(true, b.amountIn, slippageBps);
            uint256 mid2Target = limit(true, c.amountIn, slippageBps);
            uint256 inMax = limit(true, a.amountIn, slippageBps);

            calls[0] = _leg(router, true, tokenIn, r.mid1, mid1Target, inMax, deadline, a);
            calls[1] = _leg(router, true, r.mid1, r.mid2, mid2Target, mid1Target, deadline, b);
            // Lands on the router, so the sweep below hands `to` exactly `swapAmount`.
            calls[2] = _leg(router, true, r.mid2, tokenOut, swapAmount, mid2Target, deadline, c);
            msgValue = ethIn ? inMax : 0;

            if (!chaining) {
                uint256 k = 3;
                calls[k++] = _sweep(tokenOut, swapAmount, to);
                calls[k++] = _sweep(r.mid1, 0, to);
                calls[k++] = _sweep(r.mid2, 0, to);
                if (!ethIn) calls[k++] = _sweep(tokenIn, 0, to);
                calls[k++] = _sweep(address(0), 0, to);
            }
        }
        multicall = abi.encodeWithSelector(IZRouterL2.multicall.selector, calls);
    }

    /// @dev Every ordered (MID1, MID2) for exact-in. Leg 1 depends only on MID1,
    ///      so it is quoted once per hub rather than once per pair.
    function _forward(address tokenIn, address tokenOut, uint256 amount, uint256 bps)
        internal
        view
        returns (Route3 memory r)
    {
        address[] memory hs = hubs();
        (address nIn, address nOut) = (_norm(tokenIn), _norm(tokenOut));
        for (uint256 i; i < hs.length; ++i) {
            address m1 = hs[i];
            if (m1 == nIn || m1 == nOut) continue;
            Quote memory qa = _best(false, tokenIn, m1, amount);
            if (qa.amountOut == 0) continue;
            uint256 in2 = limit(false, qa.amountOut, bps);
            for (uint256 j; j < hs.length; ++j) {
                address m2 = hs[j];
                if (m2 == nIn || m2 == nOut || m2 == m1) continue;
                Quote memory qb = _best(false, m1, m2, in2);
                if (qb.amountOut == 0) continue;
                Quote memory qc = _best(false, m2, tokenOut, limit(false, qb.amountOut, bps));
                if (qc.amountOut > r.score) r = Route3(true, m1, m2, qc.amountOut, qa, qb, qc);
            }
        }
    }

    /// @dev Every ordered (MID1, MID2) for exact-out, worked back from the output.
    ///      Leg 3 depends only on MID2, so MID2 is the outer loop.
    function _backward(address tokenIn, address tokenOut, uint256 amount, uint256 bps)
        internal
        view
        returns (Route3 memory r)
    {
        address[] memory hs = hubs();
        (address nIn, address nOut) = (_norm(tokenIn), _norm(tokenOut));
        r.score = type(uint256).max;
        for (uint256 j; j < hs.length; ++j) {
            address m2 = hs[j];
            if (m2 == nIn || m2 == nOut) continue;
            Quote memory qc = _best(true, m2, tokenOut, amount);
            if (qc.amountIn == 0) continue;
            uint256 out2 = limit(true, qc.amountIn, bps);
            for (uint256 i; i < hs.length; ++i) {
                address m1 = hs[i];
                if (m1 == nIn || m1 == nOut || m1 == m2) continue;
                Quote memory qb = _best(true, m1, m2, out2);
                if (qb.amountIn == 0) continue;
                Quote memory qa = _best(true, tokenIn, m1, limit(true, qb.amountIn, bps));
                if (qa.amountIn == 0) continue;
                if (qa.amountIn < r.score) r = Route3(true, m1, m2, qa.amountIn, qa, qb, qc);
            }
        }
    }

    /// @dev The quoter's best venue for one leg, or a zero quote. A leg the quoter
    ///      cannot price reverts inside it, and one bad pair must not end the search.
    function _best(bool exactOut, address tokenIn, address tokenOut, uint256 amount)
        internal
        view
        returns (Quote memory q)
    {
        if (amount == 0) return q;
        try quoter.getQuotes(exactOut, tokenIn, tokenOut, amount) returns (Quote memory best, Quote[] memory) {
            if (exactOut ? best.amountIn != 0 : best.amountOut != 0) q = best;
        } catch {}
    }

    /// @dev One leg as router calldata, encoded the way the chain's quoter
    ///      encodes the same venue in `buildBestSwap`.
    function _leg(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 amountLimit,
        uint256 deadline,
        Quote memory q
    ) internal pure returns (bytes memory) {
        uint8 s = q.source;
        if (s == UNI_V2) {
            return abi.encodeWithSelector(
                IZRouterL2.swapV2.selector, to, exactOut, tokenIn, tokenOut, amount, amountLimit, deadline
            );
        }
        if (s == UNI_V3) {
            return abi.encodeWithSelector(
                IZRouterL2.swapV3.selector,
                to,
                exactOut,
                uint24(q.feeBps * 100),
                tokenIn,
                tokenOut,
                amount,
                amountLimit,
                deadline
            );
        }
        if (s == UNI_V4) {
            return abi.encodeWithSelector(
                IZRouterL2.swapV4.selector,
                to,
                exactOut,
                uint24(q.feeBps * 100),
                _spacing(uint16(q.feeBps)),
                tokenIn,
                tokenOut,
                amount,
                amountLimit,
                deadline
            );
        }
        // Aerodrome classic is exact-in only; the Base quoter never offers it for exact-out.
        if (s == AERO && !exactOut) {
            return abi.encodeWithSelector(
                IZRouterL2.swapAero.selector, to, q.feeBps <= 2, tokenIn, tokenOut, amount, amountLimit, deadline
            );
        }
        if (s == AERO_CL) {
            return abi.encodeWithSelector(
                IZRouterL2.swapAeroCL.selector,
                to,
                exactOut,
                int24(uint24(q.feeBps)),
                tokenIn,
                tokenOut,
                amount,
                amountLimit,
                deadline
            );
        }
        revert NoRoute();
    }

    function _sweep(address token, uint256 amount, address to) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IZRouterL2.sweep.selector, token, amount, to);
    }

    /// @dev Uniswap's canonical tier-to-spacing pairing, as the quoters and router use it.
    function _spacing(uint16 bps) internal pure returns (int24) {
        if (bps == 1) return 1;
        if (bps == 5) return 10;
        if (bps == 30) return 60;
        if (bps == 100) return 200;
        return int24(uint24(bps));
    }

    function _norm(address token) internal view returns (address) {
        return token == address(0) ? weth : token;
    }
}
