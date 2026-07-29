// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";

/// @notice Full matrix test of buildBestSwap for every pair the zSwap.html dapp
///         exposes as a preset token. Mirrors the dapp's exact call shape:
///         - buildBestSwap (single-hop only; not multicall/split/hybrid)
///         - slippage = 50 bps (0.5%)
///         - deadline = block.timestamp + 1800 (finite, not type(uint256).max)
///         - to = caller (not ZROUTER)
///
///         For each ordered pair (tokenIn, tokenOut), we run exactIn + exactOut.
///         The test summary logs every pair's outcome so we can see the exact
///         "No route" set the dapp surfaces at the current fork block.
contract zQuoterDappMatrixTest is Test {
    zQuoter quoter;

    address constant USER = address(0xBEEF);
    uint256 constant SLIPPAGE_BPS = 50; // 0.5%, matches zSwap.html default

    // Exact token set from zSwap.html TOKENS[]
    address constant ETH = address(0);
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    uint256 constant N = 6;
    address[N] tokens;
    string[N] syms;
    uint256[N] amts; // "1 unit" amount per token, used for both exactIn tokenIn size and exactOut tokenOut size

    // Accumulated results for the summary log.
    uint256 okExactIn;
    uint256 okExactOut;
    uint256 revertExactIn;
    uint256 revertExactOut;

    function setUp() public {
        quoter = new zQuoter();
        tokens[0] = ETH; // 1 ETH
        syms[0] = "ETH";
        amts[0] = 1e18;
        tokens[1] = WSTETH; // 1 wstETH
        syms[1] = "wstETH";
        amts[1] = 1e18;
        tokens[2] = WBTC; // 0.1 WBTC
        syms[2] = "WBTC";
        amts[2] = 1e7;
        tokens[3] = USDC; // 1000 USDC
        syms[3] = "USDC";
        amts[3] = 1000e6;
        tokens[4] = USDT; // 1000 USDT
        syms[4] = "USDT";
        amts[4] = 1000e6;
        tokens[5] = BOLD; // 1000 BOLD
        syms[5] = "BOLD";
        amts[5] = 1000e18;
    }

    // ----------------------------------------------------------------
    //  Core probe. Returns true if buildBestSwap produces a usable quote.
    // ----------------------------------------------------------------

    function _probe(bool exactOut, uint256 i, uint256 j)
        internal
        returns (bool ok, uint256 amountIn, uint256 amountOut, uint256 mv, uint8 source)
    {
        address tIn = tokens[i];
        address tOut = tokens[j];
        // exactIn: swapAmount = "1 unit" of tokenIn
        // exactOut: swapAmount = "1 unit" of tokenOut (the desired output)
        uint256 swapAmount = exactOut ? amts[j] : amts[i];
        uint256 deadline = block.timestamp + 1800;

        try quoter.buildBestSwap(USER, exactOut, tIn, tOut, swapAmount, SLIPPAGE_BPS, deadline) returns (
            zQuoter.Quote memory best, bytes memory cd, uint256, /*amtLim*/ uint256 msgVal
        ) {
            if (cd.length == 0) return (false, 0, 0, 0, 0);
            if (exactOut) {
                if (best.amountIn == 0) return (false, 0, 0, 0, 0);
            } else {
                if (best.amountOut == 0) return (false, 0, 0, 0, 0);
            }
            return (true, best.amountIn, best.amountOut, msgVal, uint8(best.source));
        } catch {
            return (false, 0, 0, 0, 0);
        }
    }

    function _sourceName(uint8 s) internal pure returns (string memory) {
        if (s == 0) return "UNI_V2";
        if (s == 1) return "SUSHI";
        if (s == 2) return "ZAMM";
        if (s == 3) return "UNI_V3";
        if (s == 4) return "UNI_V4";
        if (s == 5) return "CURVE";
        if (s == 6) return "LIDO";
        if (s == 7) return "WETH_WRAP";
        return "?";
    }

    function _logResult(
        string memory mode,
        uint256 i,
        uint256 j,
        bool ok,
        uint256 ai,
        uint256 ao,
        uint256 mv,
        uint8 src
    ) internal {
        string memory pair = string.concat(syms[i], " -> ", syms[j]);
        if (ok) {
            emit log_named_string(
                string.concat(mode, " OK   ", pair),
                string.concat(
                    "src=", _sourceName(src), " in=", vm.toString(ai), " out=", vm.toString(ao), " mv=", vm.toString(mv)
                )
            );
        } else {
            emit log_named_string(string.concat(mode, " MISS ", pair), "NoRoute / revert / zero");
        }
    }

    // ----------------------------------------------------------------
    //  exactIn matrix — one test per source token, 5 target tokens each
    //  (30 combinations). Structured as separate tests so one failure
    //  doesn't hide the others.
    // ----------------------------------------------------------------

    function _runRow(bool exactOut, uint256 i) internal {
        for (uint256 j; j < N; ++j) {
            if (i == j) continue;
            (bool ok, uint256 ai, uint256 ao, uint256 mv, uint8 src) = _probe(exactOut, i, j);
            _logResult(exactOut ? "exactOut" : "exactIn ", i, j, ok, ai, ao, mv, src);
            if (ok) {
                if (exactOut) okExactOut++;
                else okExactIn++;
            } else {
                if (exactOut) revertExactOut++;
                else revertExactIn++;
            }
        }
    }

    function test_matrix_exactIn_from_ETH() public {
        _runRow(false, 0);
    }

    function test_matrix_exactIn_from_wstETH() public {
        _runRow(false, 1);
    }

    function test_matrix_exactIn_from_WBTC() public {
        _runRow(false, 2);
    }

    function test_matrix_exactIn_from_USDC() public {
        _runRow(false, 3);
    }

    function test_matrix_exactIn_from_USDT() public {
        _runRow(false, 4);
    }

    function test_matrix_exactIn_from_BOLD() public {
        _runRow(false, 5);
    }

    function test_matrix_exactOut_from_ETH() public {
        _runRow(true, 0);
    }

    function test_matrix_exactOut_from_wstETH() public {
        _runRow(true, 1);
    }

    function test_matrix_exactOut_from_WBTC() public {
        _runRow(true, 2);
    }

    function test_matrix_exactOut_from_USDC() public {
        _runRow(true, 3);
    }

    // exactOut from USDT — split per-target because one RPC node prunes
    // storage for an exotic pool, causing a noisy failure that hides the rest.
    function test_matrix_exactOut_USDT_to_ETH() public {
        (bool ok, uint256 ai, uint256 ao, uint256 mv, uint8 src) = _probe(true, 4, 0);
        _logResult("exactOut", 4, 0, ok, ai, ao, mv, src);
    }

    function test_matrix_exactOut_USDT_to_wstETH() public {
        (bool ok, uint256 ai, uint256 ao, uint256 mv, uint8 src) = _probe(true, 4, 1);
        _logResult("exactOut", 4, 1, ok, ai, ao, mv, src);
    }

    function test_matrix_exactOut_USDT_to_WBTC() public {
        (bool ok, uint256 ai, uint256 ao, uint256 mv, uint8 src) = _probe(true, 4, 2);
        _logResult("exactOut", 4, 2, ok, ai, ao, mv, src);
    }

    function test_matrix_exactOut_USDT_to_USDC() public {
        (bool ok, uint256 ai, uint256 ao, uint256 mv, uint8 src) = _probe(true, 4, 3);
        _logResult("exactOut", 4, 3, ok, ai, ao, mv, src);
    }

    function test_matrix_exactOut_USDT_to_BOLD() public {
        (bool ok, uint256 ai, uint256 ao, uint256 mv, uint8 src) = _probe(true, 4, 5);
        _logResult("exactOut", 4, 5, ok, ai, ao, mv, src);
    }

    function test_matrix_exactOut_from_BOLD() public {
        _runRow(true, 5);
    }

    // ----------------------------------------------------------------
    //  Sanity assertions: the core ETH<->major pairs MUST always work.
    //  These are the paths the dapp is most exercised on; if any of
    //  these revert, the dapp is broken for real users.
    // ----------------------------------------------------------------

    function test_critical_ETH_USDC_both_modes() public {
        (bool okIn,, uint256 ao,,) = _probe(false, 0, 3);
        assertTrue(okIn, "ETH -> USDC exactIn must route");
        assertGt(ao, 100e6, "1 ETH should get >$100");
        (bool okOut, uint256 ai,,,) = _probe(true, 0, 3);
        assertTrue(okOut, "ETH -> USDC exactOut must route");
        assertGt(ai, 1e14, "non-trivial ETH cost");
    }

    function test_critical_USDC_ETH_both_modes() public {
        (bool okIn,, uint256 ao,,) = _probe(false, 3, 0);
        assertTrue(okIn, "USDC -> ETH exactIn must route");
        assertGt(ao, 0);
        (bool okOut, uint256 ai,,,) = _probe(true, 3, 0);
        assertTrue(okOut, "USDC -> ETH exactOut must route");
        assertGt(ai, 0);
    }

    function test_critical_ETH_USDT_both_modes() public {
        (bool okIn,, uint256 ao,,) = _probe(false, 0, 4);
        assertTrue(okIn, "ETH -> USDT exactIn must route");
        assertGt(ao, 100e6);
        (bool okOut, uint256 ai,,,) = _probe(true, 0, 4);
        assertTrue(okOut, "ETH -> USDT exactOut must route");
        assertGt(ai, 1e14);
    }

    function test_critical_ETH_WBTC_both_modes() public {
        (bool okIn,, uint256 ao,,) = _probe(false, 0, 2);
        assertTrue(okIn, "ETH -> WBTC exactIn must route");
        assertGt(ao, 0);
        (bool okOut, uint256 ai,,,) = _probe(true, 0, 2);
        assertTrue(okOut, "ETH -> WBTC exactOut must route");
        assertGt(ai, 0);
    }

    function test_critical_ETH_wstETH_both_modes() public {
        (bool okIn,, uint256 ao,,) = _probe(false, 0, 1);
        assertTrue(okIn, "ETH -> wstETH exactIn must route");
        assertGt(ao, 0);
        assertLt(ao, 1e18, "wstETH < 1:1 to ETH");
        (bool okOut, uint256 ai,,,) = _probe(true, 0, 1);
        assertTrue(okOut, "ETH -> wstETH exactOut must route");
        assertGt(ai, 1e18, "wstETH is worth > 1 ETH");
    }

    function test_critical_wstETH_USDC() public {
        (bool okIn,, uint256 ao,,) = _probe(false, 1, 3);
        assertTrue(okIn, "wstETH -> USDC exactIn must route");
        assertGt(ao, 0);
    }

    function test_critical_wstETH_ETH() public {
        (bool okIn,, uint256 ao,,) = _probe(false, 1, 0);
        assertTrue(okIn, "wstETH -> ETH exactIn must route");
        assertGt(ao, 1e18, "1 wstETH > 1 ETH");
    }

    function test_critical_USDC_USDT_both_modes() public {
        // Stablecoin pair. Curve is the expected route. If this reverts
        // the dapp shows "No route" — acceptable UX but worth tracking.
        (bool okIn,, uint256 ao,,) = _probe(false, 3, 4);
        if (okIn) assertGt(ao, 900e6, "USDC->USDT within 10%");
        (bool okOut, uint256 ai,,,) = _probe(true, 3, 4);
        if (okOut) {
            assertGt(ai, 900e6);
            assertLt(ai, 1100e6);
        }
        emit log_named_string("USDC<->USDT exactIn ", okIn ? "routed" : "no single-hop");
        emit log_named_string("USDC<->USDT exactOut", okOut ? "routed" : "no single-hop");
    }

    function test_critical_WBTC_USDC() public {
        (bool okIn,, uint256 ao,,) = _probe(false, 2, 3);
        assertTrue(okIn, "WBTC -> USDC exactIn must route");
        assertGt(ao, 0);
    }

    // BOLD is best-effort — liquidity may be shallow for exotic pairs.
    function test_best_effort_ETH_BOLD() public {
        (bool okIn,,,, uint8 src) = _probe(false, 0, 5);
        emit log_named_string("ETH->BOLD exactIn", okIn ? _sourceName(src) : "no route");
        (bool okOut,,,, uint8 src2) = _probe(true, 0, 5);
        emit log_named_string("ETH->BOLD exactOut", okOut ? _sourceName(src2) : "no route");
    }

    function test_best_effort_BOLD_ETH() public {
        (bool okIn,,,, uint8 src) = _probe(false, 5, 0);
        emit log_named_string("BOLD->ETH exactIn", okIn ? _sourceName(src) : "no route");
    }
}
