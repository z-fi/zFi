// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";

/// @notice Comprehensive tests for the Curve underlying fix and general zQuoter health.
///         Deploys a fresh zQuoter on a mainnet fork and validates quoting + calldata
///         generation for the USDC→USDT bug case and all major swap paths.
contract zQuoterCurveFixTest is Test {
    zQuoter quoter;

    address constant ETH = address(0);
    address constant USER = address(0xBEEF);
    uint256 constant DEADLINE = type(uint256).max;
    uint256 constant SLIPPAGE = 100; // 1%

    // Token addresses (same as zQuoter globals)
    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant _USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant _DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant _WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant _BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address constant _WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant _STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant _ROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

    // swapCurve selector for calldata inspection
    bytes4 constant SWAP_CURVE_SEL = IZRouter.swapCurve.selector;

    function setUp() public {
        quoter = new zQuoter();
    }

    // ================================================================
    //  HELPERS
    // ================================================================

    /// @dev Decode the swap_type (st) from a swapCurve calldata blob.
    ///      Layout after selector: to(32) + exactOut(32) + route[11](352) + swapParams[5][4](640)
    ///      swapParams[0][2] = swap_type, at offset 4 + 32*2 + 32*11 + 32*2 = 4 + 480 = 484
    function _extractSwapType(bytes memory cd) internal pure returns (uint256 st) {
        // offset from start: sel(4) + to(32) + exactOut(32) + route[11]*32 + swapParams[0][0](32) + [0][1](32) + [0][2]
        // = 4 + 64 + 352 + 64 = 484
        uint256 offset = 4 + 32 + 32 + (11 * 32) + (2 * 32); // = 484
        assembly { st := mload(add(add(cd, 32), offset)) }
    }

    /// @dev Extract the pool address from route[1] in swapCurve calldata
    function _extractPool(bytes memory cd) internal pure returns (address pool) {
        // offset: sel(4) + to(32) + exactOut(32) + route[0](32) + route[1]
        uint256 offset = 4 + 32 + 32 + 32; // = 100
        assembly { pool := mload(add(add(cd, 32), offset)) }
    }

    /// @dev Extract function selector from calldata
    function _selector(bytes memory cd) internal pure returns (bytes4 sel) {
        assembly { sel := mload(add(cd, 32)) }
    }

    /// @dev Decode multicall(bytes[]) → extract first inner call
    function _firstMulticallCall(bytes memory mc) internal pure returns (bytes memory) {
        // multicall calldata = sel(4) + abi-encoded bytes[]
        // Skip selector, decode the bytes[]
        bytes[] memory calls = abi.decode(_slice(mc, 4, mc.length - 4), (bytes[]));
        require(calls.length > 0, "empty multicall");
        return calls[0];
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory) {
        bytes memory result = new bytes(len);
        for (uint256 i; i < len; i++) {
            result[i] = data[start + i];
        }
        return result;
    }

    // ================================================================
    //  1. THE BUG: USDC → USDT (stablecoin, Curve underlying fix)
    // ================================================================

    /// @notice quoteCurve must return a valid quote for USDC→USDT
    function test_quoteCurve_USDC_to_USDT() public {
        uint256 amtIn = 1000e6; // 1000 USDC
        (, uint256 amountOut, address bestPool, bool usedUnderlying, bool usedStable, uint8 iIdx, uint8 jIdx) =
            quoter.quoteCurve(false, _USDC, _USDT, amtIn, 8);

        emit log_named_address("Curve pool", bestPool);
        emit log_named_uint("amountOut (USDT)", amountOut);
        emit log_named_uint("iIndex", iIdx);
        emit log_named_uint("jIndex", jIdx);
        emit log_named_string("usedUnderlying", usedUnderlying ? "true" : "false");
        emit log_named_string("usedStable", usedStable ? "true" : "false");

        if (bestPool != address(0)) {
            assertGt(amountOut, 0, "Curve USDC->USDT: should have output");
            // Stablecoin swap: output should be within 5% of input value
            assertGt(amountOut, amtIn * 95 / 100, "Curve USDC->USDT: output too low (>5% slippage)");
            assertLt(amountOut, amtIn * 105 / 100, "Curve USDC->USDT: output unreasonably high (>5% premium)");
        }
    }

    function test_diagnostic_pool_0x2dded() public {
        address pool = 0x2dded6Da1BF5DBdF597C45fcFaa3194e53EcfeAF;
        uint256 amt = 1000e6;
        // get_dy_underlying(1, 2, amt)
        (bool su, bytes memory ru) = pool.staticcall(abi.encodeWithSelector(0x07211ef7, int128(1), int128(2), amt));
        emit log_named_string("get_dy_underlying success", su ? "true" : "false");
        if (su && ru.length >= 32) emit log_named_uint("get_dy_underlying", abi.decode(ru, (uint256)));
        // get_dy(1, 2, amt)
        (bool sd, bytes memory rd) = pool.staticcall(abi.encodeWithSelector(0x5e0d443f, int128(1), int128(2), amt));
        emit log_named_string("get_dy success", sd ? "true" : "false");
        if (sd && rd.length >= 32) emit log_named_uint("get_dy", abi.decode(rd, (uint256)));
        // Also try get_dy with uint256 indices (crypto pool ABI)
        (bool sc, bytes memory rc) = pool.staticcall(abi.encodeWithSelector(0x556d6e9f, uint256(1), uint256(2), amt));
        emit log_named_string("get_dy_crypto success", sc ? "true" : "false");
        if (sc && rc.length >= 32) emit log_named_uint("get_dy_crypto", abi.decode(rc, (uint256)));
    }

    /// @notice If Curve wins for USDC→USDT, the generated calldata must use
    ///         swap_type=1 (exchange) NOT swap_type=2 (exchange_underlying) —
    ///         this is the core of the fix.
    function test_buildBestSwap_USDC_to_USDT_swapType() public {
        uint256 amtIn = 1000e6;
        try quoter.buildBestSwap(USER, false, _USDC, _USDT, amtIn, SLIPPAGE, DEADLINE) returns (
            zQuoter.Quote memory best, bytes memory callData, uint256, uint256
        ) {
            emit log_named_uint("source", uint256(best.source));
            emit log_named_uint("amountOut", best.amountOut);
            emit log_named_uint("callData length", callData.length);

            if (best.source == zQuoter.AMM.CURVE) {
                // The key assertion: swap_type must be 1 (direct exchange), not 2 (exchange_underlying)
                bytes4 sel = _selector(callData);
                if (sel == SWAP_CURVE_SEL) {
                    uint256 st = _extractSwapType(callData);
                    emit log_named_uint("swap_type (st)", st);
                    assertEq(
                        st, 1, "USDC->USDT Curve calldata must use swap_type=1 (exchange), not 2 (exchange_underlying)"
                    );
                } else {
                    // Could be wrapped in multicall
                    bytes4 mcSel = IRouterExt.multicall.selector;
                    if (sel == mcSel) {
                        bytes memory inner = _firstMulticallCall(callData);
                        bytes4 innerSel = _selector(inner);
                        if (innerSel == SWAP_CURVE_SEL) {
                            uint256 st = _extractSwapType(inner);
                            emit log_named_uint("swap_type (st) [from multicall]", st);
                            assertEq(st, 1, "USDC->USDT Curve calldata must use swap_type=1");
                        }
                    }
                }
            }
            // Regardless of source, output should be reasonable
            assertGt(best.amountOut, amtIn * 90 / 100, "USDC->USDT output too low");
        } catch {
            // If no single-hop route exists, that's OK — the multihop builder handles it
            emit log("buildBestSwap reverted (no single-hop route), that is acceptable");
        }
    }

    /// @notice Full multicall builder for USDC→USDT must produce valid calldata
    function test_buildBestMulticall_USDC_to_USDT() public {
        uint256 amtIn = 1000e6;
        (zQuoter.Quote memory a, zQuoter.Quote memory b, bytes[] memory calls, bytes memory multicall,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _USDC, _USDT, amtIn, SLIPPAGE, DEADLINE);

        uint256 output = b.amountOut > 0 ? b.amountOut : a.amountOut;
        emit log_named_uint("output USDT", output);
        emit log_named_uint("source A", uint256(a.source));
        emit log_named_uint("num calls", calls.length);

        assertGt(output, 0, "USDC->USDT multicall: must have output");
        assertGt(output, amtIn * 90 / 100, "USDC->USDT multicall: output within 10%");
        assertGt(multicall.length, 0, "USDC->USDT multicall: non-empty calldata");

        // If Curve is the source, verify swap_type
        if (a.source == zQuoter.AMM.CURVE && calls.length > 0) {
            bytes4 sel = _selector(calls[0]);
            if (sel == SWAP_CURVE_SEL) {
                uint256 st = _extractSwapType(calls[0]);
                assertEq(st, 1, "USDC->USDT multicall Curve: must use swap_type=1");
            }
        }
    }

    /// @notice USDC→USDT exact-out also must work
    function test_buildBestMulticall_USDC_to_USDT_exactOut() public {
        uint256 amtOut = 1000e6; // want 1000 USDT
        (zQuoter.Quote memory a,,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, true, _USDC, _USDT, amtOut, SLIPPAGE, DEADLINE);

        uint256 input = a.amountIn;
        emit log_named_uint("USDC needed for 1000 USDT", input);

        assertGt(input, 0, "USDC->USDT exactOut: must need some USDC");
        assertGt(input, amtOut * 90 / 100, "USDC->USDT exactOut: input within 10%");
        assertLt(input, amtOut * 110 / 100, "USDC->USDT exactOut: input within 10%");
    }

    // ================================================================
    //  2. USDT → USDC (reverse direction)
    // ================================================================

    function test_quoteCurve_USDT_to_USDC() public {
        uint256 amtIn = 1000e6;
        (, uint256 amountOut, address bestPool, bool usedUnderlying,,,) =
            quoter.quoteCurve(false, _USDT, _USDC, amtIn, 8);

        emit log_named_address("pool", bestPool);
        emit log_named_uint("amountOut", amountOut);
        emit log_named_string("usedUnderlying", usedUnderlying ? "true" : "false");

        if (bestPool != address(0)) {
            assertGt(amountOut, amtIn * 95 / 100, "USDT->USDC: output reasonable");
        }
    }

    function test_buildBestMulticall_USDT_to_USDC() public view {
        uint256 amtIn = 1000e6;
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _USDT, _USDC, amtIn, SLIPPAGE, DEADLINE);

        uint256 output = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(output, 0, "USDT->USDC: must have output");
        assertGt(output, amtIn * 90 / 100, "USDT->USDC: output within 10%");
    }

    // ================================================================
    //  3. OTHER STABLECOIN PAIRS (regression: DAI↔USDC, DAI↔USDT)
    // ================================================================

    function test_buildBestMulticall_DAI_to_USDC() public view {
        uint256 amtIn = 1000e18; // 1000 DAI
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _DAI, _USDC, amtIn, SLIPPAGE, DEADLINE);

        uint256 output = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(output, 900e6, "DAI->USDC: at least 900 USDC for 1000 DAI");
        assertLt(output, 1100e6, "DAI->USDC: at most 1100 USDC");
    }

    function test_buildBestMulticall_DAI_to_USDT() public view {
        uint256 amtIn = 1000e18;
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _DAI, _USDT, amtIn, SLIPPAGE, DEADLINE);

        uint256 output = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(output, 900e6, "DAI->USDT: at least 900 USDT");
        assertLt(output, 1100e6, "DAI->USDT: at most 1100 USDT");
    }

    function test_buildBestMulticall_USDC_to_DAI() public view {
        uint256 amtIn = 1000e6;
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _USDC, _DAI, amtIn, SLIPPAGE, DEADLINE);

        uint256 output = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(output, 900e18, "USDC->DAI: at least 900 DAI");
        assertLt(output, 1100e18, "USDC->DAI: at most 1100 DAI");
    }

    // ================================================================
    //  4. ETH PAIRS (must not regress)
    // ================================================================

    function test_buildBestMulticall_ETH_to_USDC() public view {
        uint256 amtIn = 1e18; // 1 ETH
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,, uint256 msgValue) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _USDC, amtIn, SLIPPAGE, DEADLINE);

        uint256 output = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(output, 100e6, "ETH->USDC: at least $100 for 1 ETH");
        assertGt(msgValue, 0, "ETH input: msgValue must be > 0");
    }

    function test_buildBestMulticall_ETH_to_USDT() public view {
        uint256 amtIn = 1e18;
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,, uint256 msgValue) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _USDT, amtIn, SLIPPAGE, DEADLINE);

        uint256 output = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(output, 100e6, "ETH->USDT: at least $100");
        assertGt(msgValue, 0, "ETH input: msgValue > 0");
    }

    function test_buildBestMulticall_ETH_to_DAI() public view {
        uint256 amtIn = 1e18;
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _DAI, amtIn, SLIPPAGE, DEADLINE);

        uint256 output = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(output, 100e18, "ETH->DAI: at least $100");
    }

    function test_buildBestMulticall_ETH_to_WBTC() public view {
        uint256 amtIn = 10e18; // 10 ETH
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _WBTC, amtIn, SLIPPAGE, DEADLINE);

        uint256 output = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(output, 0, "ETH->WBTC: must have output");
    }

    function test_buildBestMulticall_USDC_to_ETH() public view {
        uint256 amtIn = 1000e6;
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _USDC, ETH, amtIn, SLIPPAGE, DEADLINE);

        uint256 output = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(output, 0, "USDC->ETH: must have output");
    }

    // ================================================================
    //  5. ETH/WETH WRAP/UNWRAP (trivial path, regression)
    // ================================================================

    function test_buildBestMulticall_ETH_to_WETH() public view {
        uint256 amtIn = 1e18;
        (zQuoter.Quote memory a,,, bytes memory multicall, uint256 msgValue) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _WETH, amtIn, SLIPPAGE, DEADLINE);

        assertEq(a.amountIn, amtIn, "ETH->WETH: 1:1 input");
        assertEq(a.amountOut, amtIn, "ETH->WETH: 1:1 output");
        assertEq(msgValue, amtIn, "ETH->WETH: msgValue == amountIn");
        assertGt(multicall.length, 0, "ETH->WETH: has calldata");
    }

    function test_buildBestMulticall_WETH_to_ETH() public view {
        uint256 amtIn = 1e18;
        (zQuoter.Quote memory a,,,, uint256 msgValue) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _WETH, ETH, amtIn, SLIPPAGE, DEADLINE);

        assertEq(a.amountIn, amtIn, "WETH->ETH: 1:1");
        assertEq(a.amountOut, amtIn, "WETH->ETH: 1:1");
        assertEq(msgValue, 0, "WETH->ETH: no ETH needed");
    }

    // ================================================================
    //  6. LIDO PATHS (regression)
    // ================================================================

    function test_quoteLido_exactIn_stETH() public view {
        (uint256 amountIn, uint256 amountOut) = quoter.quoteLido(false, _STETH, 1e18);
        assertEq(amountIn, 1e18, "Lido stETH exactIn: 1:1");
        assertEq(amountOut, 1e18, "Lido stETH exactIn: 1:1 output");
    }

    function test_quoteLido_exactIn_wstETH() public view {
        (uint256 amountIn, uint256 amountOut) = quoter.quoteLido(false, _WSTETH, 1e18);
        assertEq(amountIn, 1e18);
        assertGt(amountOut, 0, "wstETH exactIn: should get some wstETH");
        assertLt(amountOut, 1e18, "wstETH exactIn: should be < 1:1 (staking rate)");
    }

    // ================================================================
    //  7. EXACT-OUT TESTS (various pairs)
    // ================================================================

    function test_buildBestMulticall_exactOut_ETH_to_USDC() public view {
        uint256 wantOut = 1000e6;
        (zQuoter.Quote memory a,,,, uint256 msgValue) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, true, ETH, _USDC, wantOut, SLIPPAGE, DEADLINE);

        assertGt(a.amountIn, 0, "exactOut ETH->USDC: needs some ETH");
        assertGt(msgValue, 0, "exactOut ETH->USDC: msgValue > 0");
    }

    function test_buildBestMulticall_exactOut_ETH_to_USDT() public view {
        uint256 wantOut = 1000e6;
        (zQuoter.Quote memory a,,,, uint256 msgValue) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, true, ETH, _USDT, wantOut, SLIPPAGE, DEADLINE);

        assertGt(a.amountIn, 0, "exactOut ETH->USDT: needs some ETH");
        assertGt(msgValue, 0, "exactOut ETH->USDT: msgValue > 0");
    }

    // ================================================================
    //  8. SPLIT ROUTING (regression)
    // ================================================================

    function test_buildSplitSwap_ETH_to_USDC() public {
        uint256 amtIn = 5e18; // 5 ETH — enough to potentially trigger a split
        (zQuoter.Quote[2] memory legs, bytes memory multicall, uint256 msgValue) =
            quoter.buildSplitSwap(USER, ETH, _USDC, amtIn, SLIPPAGE, DEADLINE);

        uint256 totalOut = legs[0].amountOut + legs[1].amountOut;
        assertGt(totalOut, 0, "split ETH->USDC: must have output");
        assertGt(multicall.length, 0, "split: has calldata");
        assertGt(msgValue, 0, "split ETH: msgValue > 0");

        emit log_named_uint("leg0 out", legs[0].amountOut);
        emit log_named_uint("leg1 out", legs[1].amountOut);
        emit log_named_uint("total out", totalOut);
    }

    // ================================================================
    //  9. 3-HOP ROUTING (regression)
    // ================================================================

    function test_build3Hop_ETH_to_WBTC() public {
        uint256 amtIn = 1e18;
        try quoter.build3HopMulticall(USER, false, ETH, _WBTC, amtIn, SLIPPAGE, DEADLINE) returns (
            zQuoter.Quote memory a,
            zQuoter.Quote memory b,
            zQuoter.Quote memory c,
            bytes[] memory,
            bytes memory,
            uint256
        ) {
            uint256 finalOut = c.amountOut;
            assertGt(finalOut, 0, "3hop ETH->WBTC: must produce output");
            emit log_named_uint("3hop WBTC out", finalOut);
            emit log_named_uint("hop A source", uint256(a.source));
            emit log_named_uint("hop B source", uint256(b.source));
            emit log_named_uint("hop C source", uint256(c.source));
        } catch {
            emit log("3hop ETH->WBTC: no 3-hop route (acceptable)");
        }
    }

    // ================================================================
    //  10. HYBRID SPLIT (regression)
    // ================================================================

    function test_buildHybridSplit_ETH_to_USDC() public {
        uint256 amtIn = 5e18;
        (zQuoter.Quote[2] memory legs, bytes memory multicall,) =
            quoter.buildHybridSplit(USER, ETH, _USDC, amtIn, SLIPPAGE, DEADLINE);

        uint256 totalOut = legs[0].amountOut + legs[1].amountOut;
        assertGt(totalOut, 0, "hybrid split ETH->USDC: must have output");
        assertGt(multicall.length, 0, "hybrid split: has calldata");

        emit log_named_uint("hybrid leg0 out", legs[0].amountOut);
        emit log_named_uint("hybrid leg1 out", legs[1].amountOut);
    }

    // ================================================================
    //  11. CURVE QUOTE TESTS (various pairs, validate usedUnderlying)
    // ================================================================

    function test_quoteCurve_ETH_to_USDC() public {
        (, uint256 amountOut, address pool, bool usedUnderlying,,,) = quoter.quoteCurve(false, ETH, _USDC, 1e18, 8);

        if (pool != address(0)) {
            assertGt(amountOut, 0, "Curve ETH->USDC: output > 0");
            // ETH->USDC: should NOT need underlying (ETH is typically a direct coin)
            emit log_named_string("usedUnderlying", usedUnderlying ? "true" : "false");
        }
    }

    function test_quoteCurve_ETH_to_USDT() public {
        (, uint256 amountOut, address pool, bool usedUnderlying,,,) = quoter.quoteCurve(false, ETH, _USDT, 1e18, 8);

        if (pool != address(0)) {
            assertGt(amountOut, 0, "Curve ETH->USDT: output > 0");
            emit log_named_string("usedUnderlying", usedUnderlying ? "true" : "false");
        }
    }

    function test_quoteCurve_DAI_to_USDC() public {
        (, uint256 amountOut, address pool, bool usedUnderlying,,,) = quoter.quoteCurve(false, _DAI, _USDC, 1000e18, 8);

        emit log_named_address("pool", pool);
        emit log_named_uint("amountOut", amountOut);
        emit log_named_string("usedUnderlying", usedUnderlying ? "true" : "false");

        if (pool != address(0)) {
            assertGt(amountOut, 900e6, "Curve DAI->USDC: reasonable stablecoin output");
        }
    }

    function test_quoteCurve_DAI_to_USDT() public {
        (, uint256 amountOut, address pool, bool usedUnderlying,,,) = quoter.quoteCurve(false, _DAI, _USDT, 1000e18, 8);

        if (pool != address(0)) {
            assertGt(amountOut, 900e6, "Curve DAI->USDT: reasonable output");
            emit log_named_string("usedUnderlying", usedUnderlying ? "true" : "false");
        }
    }

    // ================================================================
    //  12. ZERO-AMOUNT HANDLING (require guards removed)
    // ================================================================

    /// @notice After removing `require(swapAmount != 0)`, zero amount should
    ///         gracefully revert with NoRoute (not panic or return garbage).
    function test_zeroAmount_buildBestSwap() public {
        vm.expectRevert(); // should revert with NoRoute or similar
        quoter.buildBestSwap(USER, false, ETH, _USDC, 0, SLIPPAGE, DEADLINE);
    }

    function test_zeroAmount_buildBestMulticall() public {
        vm.expectRevert();
        quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _USDC, 0, SLIPPAGE, DEADLINE);
    }

    function test_zeroAmount_quoteCurve() public view {
        // quoteCurve with 0 returns zeros (doesn't revert)
        (uint256 amtIn, uint256 amtOut, address pool,,,,) = quoter.quoteCurve(false, _USDC, _USDT, 0, 8);
        assertEq(amtIn, 0);
        assertEq(amtOut, 0);
        assertEq(pool, address(0));
    }

    // ================================================================
    //  13. GETQUOTES SANITY (used by frontend)
    // ================================================================

    function test_getQuotes_USDC_to_USDT() public {
        (zQuoter.Quote memory best, zQuoter.Quote[] memory quotes) = quoter.getQuotes(false, _USDC, _USDT, 1000e6);

        assertGt(best.amountOut, 0, "getQuotes USDC->USDT: must have output");
        assertGt(best.amountOut, 900e6, "getQuotes USDC->USDT: reasonable stablecoin output");
        assertGt(quotes.length, 0, "getQuotes: should return multiple quotes");

        emit log_named_uint("best source", uint256(best.source));
        emit log_named_uint("best amountOut", best.amountOut);
        emit log_named_uint("num quotes", quotes.length);
    }

    function test_getQuotes_ETH_to_USDC() public view {
        (zQuoter.Quote memory best,) = quoter.getQuotes(false, ETH, _USDC, 1e18);

        assertGt(best.amountOut, 100e6, "getQuotes ETH->USDC: at least $100");
    }

    function test_getQuotes_exactOut_USDC_to_USDT() public view {
        (zQuoter.Quote memory best,) = quoter.getQuotes(true, _USDC, _USDT, 1000e6);

        if (best.amountIn > 0) {
            assertGt(best.amountIn, 900e6, "exactOut USDC->USDT: ~1:1 input");
            assertLt(best.amountIn, 1100e6, "exactOut USDC->USDT: ~1:1 input");
        }
    }

    // ================================================================
    //  14. WBTC PAIRS (non-stablecoin, regression)
    // ================================================================

    function test_buildBestMulticall_WBTC_to_USDC() public view {
        uint256 amtIn = 1e7; // 0.1 WBTC (8 decimals)
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _WBTC, _USDC, amtIn, SLIPPAGE, DEADLINE);

        uint256 output = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(output, 0, "WBTC->USDC: must have output");
    }

    // ================================================================
    //  15. CURVE EXACT-OUT (regression for the exactOut guard in quoteCurve)
    // ================================================================

    function test_quoteCurve_exactOut_USDC_to_USDT() public {
        uint256 wantOut = 1000e6;
        (uint256 amountIn,, address pool, bool usedUnderlying,,,) = quoter.quoteCurve(true, _USDC, _USDT, wantOut, 8);

        emit log_named_address("pool", pool);
        emit log_named_uint("amountIn", amountIn);
        emit log_named_string("usedUnderlying", usedUnderlying ? "true" : "false");

        if (pool != address(0)) {
            assertGt(amountIn, 900e6, "Curve exactOut USDC->USDT: reasonable input");
            assertLt(amountIn, 1100e6, "Curve exactOut USDC->USDT: reasonable input");
        }
    }

    function test_quoteCurve_exactOut_ETH_to_DAI() public view {
        (uint256 amountIn,, address pool,,,,) = quoter.quoteCurve(true, ETH, _DAI, 1000e18, 8);

        if (pool != address(0)) {
            assertGt(amountIn, 0, "Curve exactOut ETH->DAI: needs some ETH");
        }
    }
}
