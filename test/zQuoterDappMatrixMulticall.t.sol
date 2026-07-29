// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";

/// @notice Full matrix test of buildBestSwapViaETHMulticall for every pair the
///         zSwap.html dapp exposes. Mirrors the dapp's call shape:
///         - slippage = 50 bps, deadline = now + 1800, to = user, refundTo = user.
///
///         This is the "upgrade path" for the dapp — switching its primary call
///         from buildBestSwap to buildBestSwapViaETHMulticall should recover the
///         "No route" gaps found by zQuoterDappMatrix.t.sol.
contract zQuoterDappMatrixMulticallTest is Test {
    zQuoter quoter;

    address constant USER = address(0xBEEF);
    uint256 constant SLIPPAGE_BPS = 50;

    address constant ETH = address(0);
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    uint256 constant N = 6;
    address[N] tokens;
    string[N] syms;
    uint256[N] amts;

    function setUp() public {
        quoter = new zQuoter();
        tokens[0] = ETH;
        syms[0] = "ETH";
        amts[0] = 1e18;
        tokens[1] = WSTETH;
        syms[1] = "wstETH";
        amts[1] = 1e18;
        tokens[2] = WBTC;
        syms[2] = "WBTC";
        amts[2] = 1e7;
        tokens[3] = USDC;
        syms[3] = "USDC";
        amts[3] = 1000e6;
        tokens[4] = USDT;
        syms[4] = "USDT";
        amts[4] = 1000e6;
        tokens[5] = BOLD;
        syms[5] = "BOLD";
        amts[5] = 1000e18;
    }

    // ---------- probe ----------

    /// @dev Returns:
    ///   ok        — the builder produced non-empty multicall and non-zero quote
    ///   hop       — 1 if single-hop only (b is empty), 2 if two-hop hub route
    ///   amountIn  — end-to-end input (a.amountIn when two-hop, a.amountIn otherwise)
    ///   amountOut — end-to-end output (b.amountOut when two-hop, a.amountOut otherwise)
    ///   mv        — msg.value
    ///   srcA,srcB — AMM source ids for each leg (srcB=255 when single-hop)
    function _probe(bool exactOut, uint256 i, uint256 j)
        internal
        returns (bool ok, uint8 hop, uint256 amountIn, uint256 amountOut, uint256 mv, uint8 srcA, uint8 srcB)
    {
        uint256 swapAmount = exactOut ? amts[j] : amts[i];
        uint256 deadline = block.timestamp + 1800;

        try quoter.buildBestSwapViaETHMulticall(
            USER, USER, exactOut, tokens[i], tokens[j], swapAmount, SLIPPAGE_BPS, deadline
        ) returns (
            zQuoter.Quote memory a,
            zQuoter.Quote memory b,
            bytes[] memory, /*calls*/
            bytes memory multicall,
            uint256 msgVal
        ) {
            if (multicall.length == 0) return (false, 0, 0, 0, 0, 0, 0);
            bool twoHop = (b.amountIn != 0 || b.amountOut != 0);
            uint256 _in = a.amountIn;
            uint256 _out = twoHop ? b.amountOut : a.amountOut;
            if (exactOut) {
                if (a.amountIn == 0) return (false, 0, 0, 0, 0, 0, 0);
            } else {
                if (_out == 0) return (false, 0, 0, 0, 0, 0, 0);
            }
            return (true, twoHop ? 2 : 1, _in, _out, msgVal, uint8(a.source), twoHop ? uint8(b.source) : uint8(255));
        } catch {
            return (false, 0, 0, 0, 0, 0, 0);
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
        if (s == 255) return "-";
        return "?";
    }

    function _logResult(
        string memory mode,
        uint256 i,
        uint256 j,
        bool ok,
        uint8 hop,
        uint256 ai,
        uint256 ao,
        uint256 mv,
        uint8 srcA,
        uint8 srcB
    ) internal {
        string memory pair = string.concat(syms[i], " -> ", syms[j]);
        if (ok) {
            emit log_named_string(
                string.concat(mode, " OK   ", pair),
                string.concat(
                    "hops=",
                    vm.toString(uint256(hop)),
                    " legA=",
                    _sourceName(srcA),
                    " legB=",
                    _sourceName(srcB),
                    " in=",
                    vm.toString(ai),
                    " out=",
                    vm.toString(ao),
                    " mv=",
                    vm.toString(mv)
                )
            );
        } else {
            emit log_named_string(string.concat(mode, " MISS ", pair), "NoRoute / revert / zero");
        }
    }

    function _runRow(bool exactOut, uint256 i) internal {
        for (uint256 j; j < N; ++j) {
            if (i == j) continue;
            (bool ok, uint8 hop, uint256 ai, uint256 ao, uint256 mv, uint8 srcA, uint8 srcB) = _probe(exactOut, i, j);
            _logResult(exactOut ? "exactOut" : "exactIn ", i, j, ok, hop, ai, ao, mv, srcA, srcB);
        }
    }

    // --- exactIn rows ---
    function test_mc_exactIn_from_ETH() public {
        _runRow(false, 0);
    }

    function test_mc_exactIn_from_wstETH() public {
        _runRow(false, 1);
    }

    function test_mc_exactIn_from_WBTC() public {
        _runRow(false, 2);
    }

    function test_mc_exactIn_from_USDC() public {
        _runRow(false, 3);
    }

    function test_mc_exactIn_from_USDT() public {
        _runRow(false, 4);
    }

    function test_mc_exactIn_from_BOLD() public {
        _runRow(false, 5);
    }

    // --- exactOut rows, split-per-target for USDT to isolate the known 1rpc.io pruning ---
    function test_mc_exactOut_from_ETH() public {
        _runRow(true, 0);
    }

    function test_mc_exactOut_from_wstETH() public {
        _runRow(true, 1);
    }

    function test_mc_exactOut_from_WBTC() public {
        _runRow(true, 2);
    }

    function test_mc_exactOut_from_USDC() public {
        _runRow(true, 3);
    }

    function test_mc_exactOut_from_BOLD() public {
        _runRow(true, 5);
    }

    function test_mc_exactOut_USDT_to_ETH() public {
        (bool ok, uint8 h, uint256 ai, uint256 ao, uint256 mv, uint8 sA, uint8 sB) = _probe(true, 4, 0);
        _logResult("exactOut", 4, 0, ok, h, ai, ao, mv, sA, sB);
    }

    function test_mc_exactOut_USDT_to_wstETH() public {
        (bool ok, uint8 h, uint256 ai, uint256 ao, uint256 mv, uint8 sA, uint8 sB) = _probe(true, 4, 1);
        _logResult("exactOut", 4, 1, ok, h, ai, ao, mv, sA, sB);
    }

    function test_mc_exactOut_USDT_to_WBTC() public {
        (bool ok, uint8 h, uint256 ai, uint256 ao, uint256 mv, uint8 sA, uint8 sB) = _probe(true, 4, 2);
        _logResult("exactOut", 4, 2, ok, h, ai, ao, mv, sA, sB);
    }

    function test_mc_exactOut_USDT_to_USDC() public {
        (bool ok, uint8 h, uint256 ai, uint256 ao, uint256 mv, uint8 sA, uint8 sB) = _probe(true, 4, 3);
        _logResult("exactOut", 4, 3, ok, h, ai, ao, mv, sA, sB);
    }

    function test_mc_exactOut_USDT_to_BOLD() public {
        (bool ok, uint8 h, uint256 ai, uint256 ao, uint256 mv, uint8 sA, uint8 sB) = _probe(true, 4, 5);
        _logResult("exactOut", 4, 5, ok, h, ai, ao, mv, sA, sB);
    }

    // -----------------------------------------------------------
    // Critical-pair assertions — for pairs that FAILED single-hop,
    // verify the multicall builder recovers them via hub routing.
    // If any of these revert, the dapp upgrade path is broken.
    // -----------------------------------------------------------

    function test_recovers_wstETH_BOLD_exactIn() public {
        (bool ok,,, uint256 ao,,,) = _probe(false, 1, 5);
        assertTrue(ok, "wstETH -> BOLD exactIn must hub-route");
        assertGt(ao, 0);
    }

    function test_recovers_BOLD_wstETH_exactIn() public {
        (bool ok,,, uint256 ao,,,) = _probe(false, 5, 1);
        assertTrue(ok, "BOLD -> wstETH exactIn must hub-route");
        assertGt(ao, 0);
    }

    function test_recovers_WBTC_BOLD_exactIn() public {
        (bool ok,,, uint256 ao,,,) = _probe(false, 2, 5);
        assertTrue(ok, "WBTC -> BOLD exactIn must hub-route");
        assertGt(ao, 0);
    }

    function test_recovers_BOLD_WBTC_exactIn() public {
        (bool ok,,, uint256 ao,,,) = _probe(false, 5, 2);
        assertTrue(ok, "BOLD -> WBTC exactIn must hub-route");
        assertGt(ao, 0);
    }

    function test_recovers_USDT_BOLD_exactIn() public {
        (bool ok,,, uint256 ao,,,) = _probe(false, 4, 5);
        assertTrue(ok, "USDT -> BOLD exactIn must hub-route");
        assertGt(ao, 0);
    }

    function test_recovers_BOLD_USDT_exactIn() public {
        (bool ok,,, uint256 ao,,,) = _probe(false, 5, 4);
        assertTrue(ok, "BOLD -> USDT exactIn must hub-route");
        assertGt(ao, 0);
    }

    function test_recovers_wstETH_WBTC_exactOut() public {
        (bool ok,, uint256 ai,,,,) = _probe(true, 1, 2);
        assertTrue(ok, "wstETH -> WBTC exactOut must hub-route");
        assertGt(ai, 0);
    }

    function test_recovers_WBTC_wstETH_exactOut() public {
        (bool ok,, uint256 ai,,,,) = _probe(true, 2, 1);
        assertTrue(ok, "WBTC -> wstETH exactOut must hub-route");
        assertGt(ai, 0);
    }

    function test_recovers_wstETH_USDT_exactOut() public {
        (bool ok,, uint256 ai,,,,) = _probe(true, 1, 4);
        assertTrue(ok, "wstETH -> USDT exactOut must hub-route");
        assertGt(ai, 0);
    }

    function test_recovers_USDT_wstETH_exactOut() public {
        (bool ok,, uint256 ai,,,,) = _probe(true, 4, 1);
        assertTrue(ok, "USDT -> wstETH exactOut must hub-route");
        assertGt(ai, 0);
    }
}
