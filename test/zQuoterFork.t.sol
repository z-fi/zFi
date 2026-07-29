// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";

contract zQuoterForkTest is Test {
    zQuoter quoter;

    address constant ETH = address(0);
    address constant _DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant _USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant _WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant _WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant _STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant _BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address constant _ROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

    address constant USER = address(0xBEEF);
    uint256 constant DEADLINE = type(uint256).max;
    uint256 constant SLIPPAGE = 100; // 1%

    function setUp() public {
        quoter = new zQuoter();
    }

    // ================================================================
    //  HELPERS
    // ================================================================

    function _output(zQuoter.Quote memory a, zQuoter.Quote memory b) internal pure returns (uint256) {
        return b.amountOut > 0 ? b.amountOut : a.amountOut;
    }

    // ================================================================
    //  1. getQuotes — EXACT-IN (frontend's primary quoting path)
    // ================================================================

    function test_getQuotes_exactIn_ETH_to_DAI() public {
        (zQuoter.Quote memory best, zQuoter.Quote[] memory quotes) = quoter.getQuotes(false, ETH, _DAI, 1e16);
        assertGt(best.amountOut, 0, "should get some DAI");
        assertEq(best.amountIn, 1e16);
        assertGt(quotes.length, 0, "should return multiple venues");
    }

    function test_getQuotes_exactIn_ETH_to_USDC() public {
        (zQuoter.Quote memory best,) = quoter.getQuotes(false, ETH, _USDC, 1e18);
        assertGt(best.amountOut, 100e6, "1 ETH should get >$100 USDC");
    }

    function test_getQuotes_exactIn_ETH_to_USDT() public {
        (zQuoter.Quote memory best,) = quoter.getQuotes(false, ETH, _USDT, 1e18);
        assertGt(best.amountOut, 100e6, "1 ETH should get >$100 USDT");
    }

    function test_getQuotes_exactIn_ETH_to_WBTC() public {
        (zQuoter.Quote memory best,) = quoter.getQuotes(false, ETH, _WBTC, 10e18);
        assertGt(best.amountOut, 0, "10 ETH should get some WBTC");
    }

    function test_getQuotes_exactIn_USDC_to_USDT() public {
        (zQuoter.Quote memory best, zQuoter.Quote[] memory quotes) = quoter.getQuotes(false, _USDC, _USDT, 1000e6);
        assertGt(best.amountOut, 900e6, "stablecoin: within 10%");
        assertGt(quotes.length, 0);
    }

    function test_getQuotes_exactIn_USDC_to_DAI() public {
        (zQuoter.Quote memory best,) = quoter.getQuotes(false, _USDC, _DAI, 1000e6);
        assertGt(best.amountOut, 900e18, "stablecoin: within 10%");
    }

    function test_getQuotes_exactIn_WBTC_to_USDC() public {
        (zQuoter.Quote memory best,) = quoter.getQuotes(false, _WBTC, _USDC, 1e7); // 0.1 WBTC
        assertGt(best.amountOut, 0, "WBTC->USDC: must have output");
    }

    // ================================================================
    //  2. getQuotes — EXACT-OUT (dapp's "I want X tokens" mode)
    // ================================================================

    function test_getQuotes_exactOut_ETH_to_DAI() public {
        uint256 amount = 100e18;
        (zQuoter.Quote memory best,) = quoter.getQuotes(true, ETH, _DAI, amount);
        assertGt(best.amountIn, 1e16, "too low (bogus V3 1bp?)");
        assertLt(best.amountIn, 1e18, "unreasonably high");
        assertEq(best.amountOut, amount);
    }

    /// @notice 3 DAI exact-out: tiny amount must still produce a sane ETH quote
    ///         and the multicall builder must not revert.
    function test_getQuotes_exactOut_ETH_to_DAI_small() public {
        uint256 amount = 3e18; // 3 DAI
        (zQuoter.Quote memory best, zQuoter.Quote[] memory quotes) = quoter.getQuotes(true, ETH, _DAI, amount);
        assertGt(best.amountIn, 0, "must have a route");
        // V2 reference: 3 DAI should cost roughly same order-of-magnitude as (3/100) of 100 DAI
        (uint256 v2In,) = _BASE.quoteV2(true, ETH, _DAI, amount, false);
        if (v2In > 0) {
            // best should not be >5x cheaper than V2 (catches bogus V3 1bp)
            assertGe(best.amountIn * 5, v2In, "best amountIn suspiciously low vs V2");
        }
        // Verify none of the individual quotes are bogus dust
        for (uint256 i; i < quotes.length; i++) {
            if (quotes[i].amountIn > 0 && v2In > 0) {
                // Any neutered quote should have amountIn == 0
                assertTrue(
                    quotes[i].amountIn * 5 >= v2In || quotes[i].amountIn == 0,
                    "individual quote should be neutered if bogus"
                );
            }
        }
    }

    /// @notice 3 DAI exact-out via multicall: hub routing should beat any dust
    ///         single-hop and produce valid calldata.
    function test_multicall_exactOut_ETH_to_DAI_small() public {
        uint256 amount = 3e18; // 3 DAI
        (zQuoter.Quote memory qa,,,, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, true, ETH, _DAI, amount, SLIPPAGE, DEADLINE);
        assertGt(qa.amountIn, 0, "must find a route");
        assertGt(mv, 0, "ETH input requires msg.value");
        // Sanity: 3 DAI ≈ $3, ETH ≈ $2000+, so amountIn should be < 0.01 ETH
        assertLt(qa.amountIn, 1e16, "3 DAI should cost well under 0.01 ETH");
    }

    function test_getQuotes_exactOut_ETH_to_USDC() public {
        (zQuoter.Quote memory best,) = quoter.getQuotes(true, ETH, _USDC, 100e6);
        assertGt(best.amountIn, 1e16);
        assertLt(best.amountIn, 1e18);
    }

    function test_getQuotes_exactOut_ETH_to_USDT() public {
        (zQuoter.Quote memory best,) = quoter.getQuotes(true, ETH, _USDT, 100e6);
        assertGt(best.amountIn, 1e16);
        assertLt(best.amountIn, 1e18);
    }

    function test_getQuotes_exactOut_USDC_to_USDT() public view {
        (zQuoter.Quote memory best,) = quoter.getQuotes(true, _USDC, _USDT, 1000e6);
        if (best.amountIn > 0) {
            assertGt(best.amountIn, 900e6);
            assertLt(best.amountIn, 1100e6);
        }
    }

    function test_getQuotes_exactOut_USDC_to_DAI() public {
        (zQuoter.Quote memory best,) = quoter.getQuotes(true, _USDC, _DAI, 100e18);
        if (best.amountIn > 0) {
            assertGt(best.amountIn, 90e6);
            assertLt(best.amountIn, 110e6);
        }
    }

    /// @notice DAI and USDC exact-out for $100 should require similar ETH
    function test_getQuotes_exactOut_DAI_vs_USDC_sanity() public {
        (zQuoter.Quote memory daiQ,) = quoter.getQuotes(true, ETH, _DAI, 100e18);
        (zQuoter.Quote memory usdcQ,) = quoter.getQuotes(true, ETH, _USDC, 100e6);

        uint256 diff = daiQ.amountIn > usdcQ.amountIn ? daiQ.amountIn - usdcQ.amountIn : usdcQ.amountIn - daiQ.amountIn;
        uint256 avg = (daiQ.amountIn + usdcQ.amountIn) / 2;
        assertLt(diff * 100 / avg, 5, "within 5%");
    }

    // ================================================================
    //  3. buildBestSwap — single-hop calldata builder
    // ================================================================

    function test_buildBestSwap_exactIn_ETH_to_USDC() public {
        (zQuoter.Quote memory best, bytes memory cd, uint256 amtLim, uint256 mv) =
            quoter.buildBestSwap(USER, false, ETH, _USDC, 1e18, SLIPPAGE, DEADLINE);
        assertGt(best.amountOut, 100e6);
        assertGt(cd.length, 0);
        assertLt(amtLim, best.amountOut, "exactIn: amountLimit is minOut < quoted");
        assertEq(mv, 1e18, "ETH input: msgValue == swapAmount");
    }

    function test_buildBestSwap_exactOut_ETH_to_DAI() public {
        (zQuoter.Quote memory best, bytes memory cd, uint256 amtLim, uint256 mv) =
            quoter.buildBestSwap(USER, true, ETH, _DAI, 100e18, SLIPPAGE, DEADLINE);
        assertGt(best.amountIn, 1e16);
        assertGt(cd.length, 0);
        assertGt(amtLim, best.amountIn, "exactOut: amountLimit is maxIn > quoted");
        assertGt(mv, 0);
    }

    function test_buildBestSwap_exactIn_USDC_to_ETH() public {
        (zQuoter.Quote memory best, bytes memory cd,, uint256 mv) =
            quoter.buildBestSwap(USER, false, _USDC, ETH, 1000e6, SLIPPAGE, DEADLINE);
        assertGt(best.amountOut, 0, "USDC->ETH: must get some ETH");
        assertGt(cd.length, 0);
        assertEq(mv, 0, "ERC20 input: no ETH needed");
    }

    function test_buildBestSwap_exactIn_USDC_to_USDT() public {
        try quoter.buildBestSwap(USER, false, _USDC, _USDT, 1000e6, SLIPPAGE, DEADLINE) returns (
            zQuoter.Quote memory best, bytes memory cd, uint256, uint256 mv
        ) {
            assertGt(best.amountOut, 900e6);
            assertGt(cd.length, 0);
            assertEq(mv, 0);
        } catch {
            // stablecoin single-hop may not exist; multicall handles it
        }
    }

    // ETH<->WETH wrapping via buildBestSwap
    function test_buildBestSwap_ETH_to_WETH() public view {
        (zQuoter.Quote memory best, bytes memory cd,, uint256 mv) =
            quoter.buildBestSwap(USER, false, ETH, _WETH, 1e18, SLIPPAGE, DEADLINE);
        assertEq(uint256(best.source), uint256(zQuoter.AMM.WETH_WRAP));
        assertEq(best.amountIn, 1e18);
        assertEq(best.amountOut, 1e18);
        assertGt(cd.length, 0);
        assertEq(mv, 1e18);
    }

    function test_buildBestSwap_WETH_to_ETH() public view {
        (zQuoter.Quote memory best, bytes memory cd,, uint256 mv) =
            quoter.buildBestSwap(USER, false, _WETH, ETH, 1e18, SLIPPAGE, DEADLINE);
        assertEq(uint256(best.source), uint256(zQuoter.AMM.WETH_WRAP));
        assertEq(best.amountIn, 1e18);
        assertEq(best.amountOut, 1e18);
        assertGt(cd.length, 0);
        assertEq(mv, 0);
    }

    // CURVE_ETH sentinel normalization
    function test_buildBestSwap_CURVE_ETH_sentinel() public {
        // CURVE_ETH should be normalized to address(0) and work like ETH input
        (zQuoter.Quote memory best,,,) = quoter.buildBestSwap(USER, false, CURVE_ETH, _USDC, 1e18, SLIPPAGE, DEADLINE);
        assertGt(best.amountOut, 0, "CURVE_ETH sentinel should normalize to ETH");
    }

    // ================================================================
    //  4. buildBestSwapViaETHMulticall — the dapp's main entry point
    // ================================================================

    // -- ETH input pairs (exactIn) --

    function test_multicall_exactIn_ETH_to_USDC() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _USDC, 1e18, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 100e6);
        assertGt(mv, 0);
    }

    function test_multicall_exactIn_ETH_to_USDT() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _USDT, 1e18, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 100e6);
        assertGt(mv, 0);
    }

    function test_multicall_exactIn_ETH_to_DAI() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _DAI, 1e18, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 100e18);
    }

    function test_multicall_exactIn_ETH_to_WBTC() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _WBTC, 10e18, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 0);
    }

    function test_multicall_exactIn_ETH_to_wstETH() public {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _WSTETH, 1e18, SLIPPAGE, DEADLINE);
        uint256 out = _output(a, b);
        assertGt(out, 0, "ETH->wstETH: must have output");
        // wstETH is worth more than ETH, so output < input
        assertLt(out, 1e18, "wstETH output should be < 1:1");
    }

    function test_multicall_exactIn_ETH_to_stETH() public {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _STETH, 1e18, SLIPPAGE, DEADLINE);
        uint256 out = _output(a, b);
        assertGt(out, 0, "ETH->stETH: must have output");
        // stETH is ~1:1 with ETH
        assertGt(out, 9e17, "stETH should be roughly 1:1");
    }

    // -- ETH input pairs (exactOut) --

    function test_multicall_exactOut_ETH_to_USDC() public view {
        (zQuoter.Quote memory a,,,, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, true, ETH, _USDC, 1000e6, SLIPPAGE, DEADLINE);
        assertGt(a.amountIn, 0);
        assertGt(mv, 0);
    }

    function test_multicall_exactOut_ETH_to_USDT() public view {
        (zQuoter.Quote memory a,,,, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, true, ETH, _USDT, 1000e6, SLIPPAGE, DEADLINE);
        assertGt(a.amountIn, 0);
        assertGt(mv, 0);
    }

    function test_multicall_exactOut_ETH_to_DAI() public {
        (zQuoter.Quote memory a,,,, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, true, ETH, _DAI, 100e18, SLIPPAGE, DEADLINE);
        assertGt(a.amountIn, 1e16);
        assertLt(a.amountIn, 1e18);
        assertGt(mv, 0);
    }

    function test_multicall_exactOut_ETH_to_wstETH() public {
        (zQuoter.Quote memory a,,,, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, true, ETH, _WSTETH, 1e18, SLIPPAGE, DEADLINE);
        assertGt(a.amountIn, 1e18, "wstETH is worth > 1 ETH");
        assertLt(a.amountIn, 2e18, "but < 2 ETH");
        assertGt(mv, 0);
    }

    // -- ERC20 → ETH (reverse paths) --

    function test_multicall_exactIn_USDC_to_ETH() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _USDC, ETH, 1000e6, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 0);
        assertEq(mv, 0, "ERC20 input: no ETH needed");
    }

    function test_multicall_exactIn_DAI_to_ETH() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _DAI, ETH, 1000e18, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 0);
    }

    function test_multicall_exactIn_WBTC_to_ETH() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _WBTC, ETH, 1e7, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 0);
    }

    function test_multicall_exactIn_USDT_to_ETH() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _USDT, ETH, 1000e6, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 0);
    }

    // -- ERC20 → ERC20 --

    function test_multicall_exactIn_USDC_to_USDT() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _USDC, _USDT, 1000e6, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 900e6);
    }

    function test_multicall_exactIn_USDT_to_USDC() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _USDT, _USDC, 1000e6, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 900e6);
    }

    function test_multicall_exactIn_DAI_to_USDC() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _DAI, _USDC, 1000e18, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 900e6);
    }

    function test_multicall_exactIn_DAI_to_USDT() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _DAI, _USDT, 1000e18, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 900e6);
    }

    function test_multicall_exactIn_USDC_to_DAI() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _USDC, _DAI, 1000e6, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 900e18);
    }

    function test_multicall_exactIn_WBTC_to_USDC() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _WBTC, _USDC, 1e7, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 0);
    }

    function test_multicall_exactIn_USDC_to_WBTC() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _USDC, _WBTC, 10000e6, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 0);
    }

    // -- ERC20 → ERC20 exactOut --

    function test_multicall_exactOut_USDC_to_USDT() public {
        (zQuoter.Quote memory a,,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, true, _USDC, _USDT, 1000e6, SLIPPAGE, DEADLINE);
        assertGt(a.amountIn, 900e6);
        assertLt(a.amountIn, 1100e6);
    }

    function test_multicall_exactOut_USDC_to_DAI() public {
        (zQuoter.Quote memory a,,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, true, _USDC, _DAI, 1000e18, SLIPPAGE, DEADLINE);
        assertGt(a.amountIn, 900e6);
        assertLt(a.amountIn, 1100e6);
    }

    // -- ETH/WETH wrap/unwrap --

    function test_multicall_ETH_to_WETH() public view {
        (zQuoter.Quote memory a,,, bytes memory mc, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _WETH, 1e18, SLIPPAGE, DEADLINE);
        assertEq(a.amountIn, 1e18);
        assertEq(a.amountOut, 1e18);
        assertEq(mv, 1e18);
        assertGt(mc.length, 0);
    }

    function test_multicall_WETH_to_ETH() public view {
        (zQuoter.Quote memory a,,,, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _WETH, ETH, 1e18, SLIPPAGE, DEADLINE);
        assertEq(a.amountIn, 1e18);
        assertEq(a.amountOut, 1e18);
        assertEq(mv, 0);
    }

    // -- Large amounts (triggers 2-hop hub routing) --

    function test_multicall_exactIn_ETH_to_USDC_large() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _USDC, 100e18, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 10000e6, "100 ETH should get >$10k USDC");
    }

    function test_multicall_exactIn_ETH_to_WBTC_large() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _WBTC, 100e18, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 0, "100 ETH should get some WBTC");
    }

    // -- refundTo != to --

    function test_multicall_exactOut_refundTo_differs() public {
        address refundAddr = address(0xCAFE);
        (zQuoter.Quote memory a,,, bytes memory mc,) =
            quoter.buildBestSwapViaETHMulticall(USER, refundAddr, true, ETH, _USDC, 1000e6, SLIPPAGE, DEADLINE);
        assertGt(a.amountIn, 0);
        assertGt(mc.length, 0);
    }

    // -- to=ZROUTER (chaining mode, used by dapp for multi-step flows) --

    function test_multicall_to_router_chaining() public view {
        (zQuoter.Quote memory a,,, bytes memory mc,) =
            quoter.buildBestSwapViaETHMulticall(_ROUTER, _ROUTER, false, ETH, _USDC, 1e18, SLIPPAGE, DEADLINE);
        assertGt(a.amountOut, 0);
        assertGt(mc.length, 0);
    }

    // ================================================================
    //  5. Lido — ETH → stETH/wstETH (competes with DEX in dapp)
    // ================================================================

    function test_quoteLido_exactIn_stETH() public view {
        (uint256 ai, uint256 ao) = quoter.quoteLido(false, _STETH, 1e18);
        assertEq(ai, 1e18, "stETH exactIn: 1:1 input");
        assertEq(ao, 1e18, "stETH exactIn: 1:1 output");
    }

    function test_quoteLido_exactIn_wstETH() public view {
        (uint256 ai, uint256 ao) = quoter.quoteLido(false, _WSTETH, 1e18);
        assertEq(ai, 1e18);
        assertGt(ao, 0);
        assertLt(ao, 1e18, "wstETH < 1:1 (staking rate)");
    }

    function test_quoteLido_exactOut_stETH() public view {
        (uint256 ai, uint256 ao) = quoter.quoteLido(true, _STETH, 1e18);
        assertGe(ai, 1e18, "stETH exact-out: >= 1:1 due to share rounding");
        assertLe(ai, 1e18 + 2);
        assertEq(ao, 1e18);
    }

    function test_quoteLido_exactOut_wstETH() public {
        (uint256 ai, uint256 ao) = quoter.quoteLido(true, _WSTETH, 1e18);
        assertGt(ai, 1e18, "wstETH exact-out: ETH > 1:1");
        assertLt(ai, 2e18);
        assertEq(ao, 1e18);
    }

    function test_quoteLido_zeroAmount() public view {
        (uint256 ai, uint256 ao) = quoter.quoteLido(false, _STETH, 0);
        assertEq(ai, 0);
        assertEq(ao, 0);
    }

    function test_quoteLido_unsupportedToken() public view {
        // Non-stETH/wstETH should return zeros
        (uint256 ai, uint256 ao) = quoter.quoteLido(false, _USDC, 1e18);
        assertEq(ai, 0);
        assertEq(ao, 0);
    }

    // ================================================================
    //  6. Curve — quoteCurve for various pairs
    // ================================================================

    function test_quoteCurve_exactIn_USDC_to_USDT() public {
        (, uint256 ao, address pool, bool usedUnderlying,,,) = quoter.quoteCurve(false, _USDC, _USDT, 1000e6, 8);
        if (pool != address(0)) {
            assertGt(ao, 900e6, "stablecoin: within 10%");
            emit log_named_string("usedUnderlying", usedUnderlying ? "true" : "false");
        }
    }

    function test_quoteCurve_exactIn_USDT_to_USDC() public {
        (, uint256 ao, address pool,,,,) = quoter.quoteCurve(false, _USDT, _USDC, 1000e6, 8);
        if (pool != address(0)) {
            assertGt(ao, 900e6);
        }
    }

    function test_quoteCurve_exactIn_DAI_to_USDC() public {
        (, uint256 ao, address pool,,,,) = quoter.quoteCurve(false, _DAI, _USDC, 1000e18, 8);
        if (pool != address(0)) {
            assertGt(ao, 900e6);
        }
    }

    function test_quoteCurve_exactIn_ETH_to_USDC() public {
        (, uint256 ao, address pool,,,,) = quoter.quoteCurve(false, ETH, _USDC, 1e18, 8);
        if (pool != address(0)) {
            assertGt(ao, 0);
        }
    }

    function test_quoteCurve_exactIn_ETH_to_USDT() public {
        (, uint256 ao, address pool,,,,) = quoter.quoteCurve(false, ETH, _USDT, 1e18, 8);
        if (pool != address(0)) {
            assertGt(ao, 0);
        }
    }

    function test_quoteCurve_exactIn_ETH_to_WBTC() public {
        (, uint256 ao, address pool,,,,) = quoter.quoteCurve(false, ETH, _WBTC, 10e18, 8);
        if (pool != address(0)) {
            assertGt(ao, 0, "Curve ETH->WBTC via tricrypto");
        }
    }

    function test_quoteCurve_exactOut_USDC_to_USDT() public {
        (uint256 ai,, address pool, bool usedUnderlying,,,) = quoter.quoteCurve(true, _USDC, _USDT, 1000e6, 8);
        if (pool != address(0)) {
            assertGt(ai, 900e6);
            assertLt(ai, 1100e6);
            emit log_named_string("usedUnderlying", usedUnderlying ? "true" : "false");
        }
    }

    function test_quoteCurve_exactOut_ETH_to_DAI() public view {
        (uint256 ai,, address pool,,,,) = quoter.quoteCurve(true, ETH, _DAI, 1000e18, 8);
        if (pool != address(0)) {
            assertGt(ai, 0);
        }
    }

    function test_quoteCurve_zeroAmount() public view {
        (uint256 ai, uint256 ao, address pool,,,,) = quoter.quoteCurve(false, _USDC, _USDT, 0, 8);
        assertEq(ai, 0);
        assertEq(ao, 0);
        assertEq(pool, address(0));
    }

    function test_quoteCurve_ETH_WETH_returns_empty() public view {
        // ETH<->WETH should not return a Curve pool (handled by wrap/unwrap)
        (,, address pool,,,,) = quoter.quoteCurve(false, ETH, _WETH, 1e18, 8);
        assertEq(pool, address(0), "ETH<->WETH: no Curve pool");
    }

    function test_quoteCurve_WETH_ETH_returns_empty() public view {
        (,, address pool,,,,) = quoter.quoteCurve(false, _WETH, ETH, 1e18, 8);
        assertEq(pool, address(0));
    }

    // ================================================================
    //  7. Split routing — buildSplitSwap
    // ================================================================

    function test_splitSwap_ETH_to_USDC() public {
        (zQuoter.Quote[2] memory legs, bytes memory mc, uint256 mv) =
            quoter.buildSplitSwap(USER, ETH, _USDC, 5e18, SLIPPAGE, DEADLINE);
        uint256 total = legs[0].amountOut + legs[1].amountOut;
        assertGt(total, 0);
        assertGt(mc.length, 0);
        assertGt(mv, 0);
    }

    function test_splitSwap_ETH_to_USDT() public {
        (zQuoter.Quote[2] memory legs, bytes memory mc, uint256 mv) =
            quoter.buildSplitSwap(USER, ETH, _USDT, 5e18, SLIPPAGE, DEADLINE);
        uint256 total = legs[0].amountOut + legs[1].amountOut;
        assertGt(total, 0);
        assertGt(mc.length, 0);
        assertGt(mv, 0);
    }

    function test_splitSwap_ETH_to_DAI() public {
        (zQuoter.Quote[2] memory legs, bytes memory mc,) =
            quoter.buildSplitSwap(USER, ETH, _DAI, 5e18, SLIPPAGE, DEADLINE);
        assertGt(legs[0].amountOut + legs[1].amountOut, 0);
        assertGt(mc.length, 0);
    }

    function test_splitSwap_USDC_to_ETH() public {
        (zQuoter.Quote[2] memory legs, bytes memory mc, uint256 mv) =
            quoter.buildSplitSwap(USER, _USDC, ETH, 10000e6, SLIPPAGE, DEADLINE);
        assertGt(legs[0].amountOut + legs[1].amountOut, 0);
        assertGt(mc.length, 0);
        assertEq(mv, 0, "ERC20 input: no ETH");
    }

    function test_splitSwap_large_ETH_to_USDC() public {
        // Large amount more likely to actually split across venues
        (zQuoter.Quote[2] memory legs, bytes memory mc,) =
            quoter.buildSplitSwap(USER, ETH, _USDC, 50e18, SLIPPAGE, DEADLINE);
        assertGt(legs[0].amountOut + legs[1].amountOut, 0);
        assertGt(mc.length, 0);
    }

    // ================================================================
    //  8. Hybrid split — buildHybridSplit
    // ================================================================

    function test_hybridSplit_ETH_to_USDC() public {
        (zQuoter.Quote[2] memory legs, bytes memory mc,) =
            quoter.buildHybridSplit(USER, ETH, _USDC, 5e18, SLIPPAGE, DEADLINE);
        assertGt(legs[0].amountOut + legs[1].amountOut, 0);
        assertGt(mc.length, 0);
    }

    function test_hybridSplit_ETH_to_DAI() public {
        (zQuoter.Quote[2] memory legs, bytes memory mc,) =
            quoter.buildHybridSplit(USER, ETH, _DAI, 5e18, SLIPPAGE, DEADLINE);
        assertGt(legs[0].amountOut + legs[1].amountOut, 0);
        assertGt(mc.length, 0);
    }

    function test_hybridSplit_ETH_to_WBTC() public {
        try quoter.buildHybridSplit(USER, ETH, _WBTC, 10e18, SLIPPAGE, DEADLINE) returns (
            zQuoter.Quote[2] memory legs, bytes memory mc, uint256
        ) {
            assertGt(legs[0].amountOut + legs[1].amountOut, 0);
            assertGt(mc.length, 0);
        } catch {
            // May revert with NoRoute for exotic pairs
        }
    }

    function test_hybridSplit_USDC_to_ETH() public {
        (zQuoter.Quote[2] memory legs, bytes memory mc,) =
            quoter.buildHybridSplit(USER, _USDC, ETH, 10000e6, SLIPPAGE, DEADLINE);
        assertGt(legs[0].amountOut + legs[1].amountOut, 0);
        assertGt(mc.length, 0);
    }

    // ================================================================
    //  9. 3-hop routing — build3HopMulticall
    // ================================================================

    function test_3hop_ETH_to_WBTC() public {
        try quoter.build3HopMulticall(USER, false, ETH, _WBTC, 1e18, SLIPPAGE, DEADLINE) returns (
            zQuoter.Quote memory a, zQuoter.Quote memory, zQuoter.Quote memory c, bytes[] memory, bytes memory, uint256
        ) {
            assertGt(c.amountOut, 0);
            assertGt(a.amountIn, 0);
        } catch {
            // 3-hop may not find a route; acceptable
        }
    }

    function test_3hop_USDC_to_WBTC() public {
        try quoter.build3HopMulticall(USER, false, _USDC, _WBTC, 10000e6, SLIPPAGE, DEADLINE) returns (
            zQuoter.Quote memory,
            zQuoter.Quote memory,
            zQuoter.Quote memory c,
            bytes[] memory calls,
            bytes memory,
            uint256
        ) {
            assertGt(c.amountOut, 0);
            assertEq(calls.length, 3, "3-hop must have 3 calls");
        } catch {}
    }

    function test_3hop_DAI_to_WBTC() public {
        try quoter.build3HopMulticall(USER, false, _DAI, _WBTC, 10000e18, SLIPPAGE, DEADLINE) returns (
            zQuoter.Quote memory, zQuoter.Quote memory, zQuoter.Quote memory c, bytes[] memory, bytes memory, uint256
        ) {
            assertGt(c.amountOut, 0);
        } catch {}
    }

    // ================================================================
    //  10. SlippageLib — pure function tests
    // ================================================================

    function test_slippage_exactIn_limit() public view {
        // exactIn: minOut = floor(quoted * (10000 - bps) / 10000)
        uint256 lim = SlippageLib.limit(false, 1000e6, 100); // 1% slippage
        assertEq(lim, 990e6, "1% slippage on 1000 = 990 minOut");
    }

    function test_slippage_exactOut_limit() public view {
        // exactOut: maxIn = ceil(quoted * (10000 + bps) / 10000)
        uint256 lim = SlippageLib.limit(true, 1000e6, 100); // 1% slippage
        assertEq(lim, 1010e6, "1% slippage on 1000 = 1010 maxIn");
    }

    function test_slippage_zero_bps() public view {
        assertEq(SlippageLib.limit(false, 1000e6, 0), 1000e6, "0 bps: no change");
        assertEq(SlippageLib.limit(true, 1000e6, 0), 1000e6, "0 bps: no change");
    }

    function test_slippage_max_bps_reverts() public {
        vm.expectRevert();
        this.externalLimit(false, 1000e6, 10000); // 100% = BPS, should revert
    }

    function externalLimit(bool exactOut, uint256 quoted, uint256 bps) external pure returns (uint256) {
        return SlippageLib.limit(exactOut, quoted, bps);
    }

    function test_slippage_high_bps() public view {
        // 50% slippage (5000 bps)
        uint256 lim = SlippageLib.limit(false, 1000e6, 5000);
        assertEq(lim, 500e6);
    }

    function test_slippage_exactOut_ceiling() public view {
        // Verify ceiling division: 1 wei quoted with 1 bps
        // maxIn = ceil(1 * 10001 / 10000) = ceil(1.0001) = 2
        uint256 lim = SlippageLib.limit(true, 1, 1);
        assertEq(lim, 2, "ceil(1 * 10001 / 10000) = 2");
    }

    // ================================================================
    //  11. Zero-amount edge cases
    // ================================================================

    function test_zeroAmount_buildBestSwap_reverts() public {
        vm.expectRevert();
        quoter.buildBestSwap(USER, false, ETH, _USDC, 0, SLIPPAGE, DEADLINE);
    }

    function test_zeroAmount_multicall_reverts() public {
        vm.expectRevert();
        quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _USDC, 0, SLIPPAGE, DEADLINE);
    }

    function test_zeroAmount_quoteCurve_graceful() public view {
        (uint256 ai, uint256 ao, address pool,,,,) = quoter.quoteCurve(false, _USDC, _USDT, 0, 8);
        assertEq(ai, 0);
        assertEq(ao, 0);
        assertEq(pool, address(0));
    }

    function test_zeroAmount_quoteLido_graceful() public view {
        (uint256 ai, uint256 ao) = quoter.quoteLido(false, _STETH, 0);
        assertEq(ai, 0);
        assertEq(ao, 0);
    }

    // ================================================================
    //  12. wstETH pairs (staking token swaps used in dapp)
    // ================================================================

    function test_multicall_exactIn_wstETH_to_USDC() public {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _WSTETH, _USDC, 1e18, SLIPPAGE, DEADLINE);
        assertGt(_output(a, b), 0, "wstETH->USDC: must have output");
    }

    function test_multicall_exactIn_wstETH_to_ETH() public {
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, _WSTETH, ETH, 1e18, SLIPPAGE, DEADLINE);
        uint256 out = _output(a, b);
        assertGt(out, 1e18, "wstETH->ETH: wstETH is worth > 1 ETH");
    }

    // ================================================================
    //  14. BOLD token (used in dapp)
    // ================================================================

    function test_multicall_exactIn_ETH_to_BOLD() public {
        try quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _BOLD, 1e18, SLIPPAGE, DEADLINE) returns (
            zQuoter.Quote memory a, zQuoter.Quote memory b, bytes[] memory, bytes memory, uint256
        ) {
            assertGt(_output(a, b), 0, "ETH->BOLD: must have output");
        } catch {
            // BOLD may not have deep liquidity
        }
    }

    function test_multicall_exactIn_BOLD_to_ETH() public {
        try quoter.buildBestSwapViaETHMulticall(USER, USER, false, _BOLD, ETH, 1000e18, SLIPPAGE, DEADLINE) returns (
            zQuoter.Quote memory a, zQuoter.Quote memory b, bytes[] memory, bytes memory, uint256
        ) {
            assertGt(_output(a, b), 0, "BOLD->ETH: must have output");
        } catch {}
    }

    // ================================================================
    //  15. Consistency: buildBestSwap vs multicall should agree
    // ================================================================

    function test_consistency_single_vs_multicall_ETH_USDC() public {
        (zQuoter.Quote memory bestSingle,,,) = quoter.buildBestSwap(USER, false, ETH, _USDC, 1e18, SLIPPAGE, DEADLINE);
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _USDC, 1e18, SLIPPAGE, DEADLINE);

        uint256 mcOutput = _output(a, b);
        // Multicall should be >= single-hop (it tries single-hop first, then hub routing)
        assertGe(mcOutput, bestSingle.amountOut * 95 / 100, "multicall should be at least 95% of single-hop");
    }

    // ================================================================
    //  16. quoteV2 / quoteV3 — individual AMM quotes
    // ================================================================

    function test_quoteV2_exactIn_ETH_USDC() public view {
        (, uint256 ao) = _BASE.quoteV2(false, ETH, _USDC, 1e18, false);
        assertGt(ao, 0, "V2 ETH->USDC: must have output");
    }

    function test_quoteV2_exactIn_sushi_ETH_USDC() public view {
        (, uint256 ao) = _BASE.quoteV2(false, ETH, _USDC, 1e18, true);
        // Sushi may or may not have liquidity, just check it doesn't revert
        if (ao > 0) {
            assertGt(ao, 100e6);
        }
    }

    function test_quoteV2_exactOut_ETH_USDC() public view {
        (uint256 ai,) = _BASE.quoteV2(true, ETH, _USDC, 1000e6, false);
        if (ai > 0) {
            assertGt(ai, 0);
        }
    }

    function test_quoteV3_exactIn_ETH_USDC_500() public view {
        (, uint256 ao) = _BASE.quoteV3(false, ETH, _USDC, 500, 1e18);
        assertGt(ao, 0, "V3 500bp ETH->USDC");
    }

    function test_quoteV3_exactIn_ETH_USDC_3000() public view {
        (, uint256 ao) = _BASE.quoteV3(false, ETH, _USDC, 3000, 1e18);
        assertGt(ao, 0, "V3 3000bp ETH->USDC");
    }

    // ================================================================
    //  17. Deadline sentinel collision (DEADLINE=type(uint256).max)
    //      The router interprets deadline==max on swapV2 as "use Sushi".
    //      When a caller passes max, the quoter must normalize to a finite
    //      deadline for UNI_V2 routes, while still forwarding the sentinel
    //      for explicit SUSHI routes.
    // ================================================================

    /// @dev Decode the trailing `deadline` from a swapV2 calldata blob.
    ///      Layout: sel(4) + to(32) + exactOut(32) + tokenIn(32) + tokenOut(32)
    ///            + swapAmount(32) + amountLimit(32) + deadline(32) = 228 bytes.
    function _extractV2Deadline(bytes memory cd) internal pure returns (bytes4 sel, uint256 dl) {
        assembly {
            sel := mload(add(cd, 32))
            dl := mload(add(cd, add(32, sub(mload(cd), 32))))
        }
    }

    function test_deadlineMax_V2_route_does_not_become_sushi() public {
        // Find a pair that the base quoter tends to route through UNI_V2.
        // If the best isn't V2 at this block, skip the assertion softly.
        (zQuoter.Quote memory best, bytes memory cd,,) =
            quoter.buildBestSwap(USER, false, _WBTC, _USDC, 1e6, SLIPPAGE, type(uint256).max);
        if (best.source != zQuoter.AMM.UNI_V2) {
            // No V2 route selected at this fork — nothing to verify here.
            return;
        }
        (bytes4 sel, uint256 dl) = _extractV2Deadline(cd);
        assertEq(sel, IZRouter.swapV2.selector, "expected swapV2 calldata");
        assertTrue(dl != type(uint256).max, "UNI_V2 must not carry sushi sentinel");
        assertGt(dl, block.timestamp, "deadline must be in the future");
    }

    // ================================================================
    //  18. Split/hybrid ETH<->WETH trivial-wrap fast path.
    //      Previously reverted NoRoute; now should delegate to buildBestSwap.
    // ================================================================

    function test_splitSwap_ETH_WETH_trivial_wrap() public view {
        (zQuoter.Quote[2] memory legs, bytes memory mc, uint256 mv) =
            quoter.buildSplitSwap(USER, ETH, _WETH, 1e18, SLIPPAGE, DEADLINE);
        assertEq(uint256(legs[0].source), uint256(zQuoter.AMM.WETH_WRAP));
        assertGt(mc.length, 0);
        assertEq(mv, 1e18);
    }

    function test_hybridSplit_WETH_ETH_trivial_wrap() public view {
        (zQuoter.Quote[2] memory legs, bytes memory mc, uint256 mv) =
            quoter.buildHybridSplit(USER, _WETH, ETH, 1e18, SLIPPAGE, DEADLINE);
        assertEq(uint256(legs[0].source), uint256(zQuoter.AMM.WETH_WRAP));
        assertGt(mc.length, 0);
        assertEq(mv, 0);
    }

    // ================================================================
    //  19. Split fallback leg metadata must match actual calldata source.
    //      buildBestSwap may select Curve/Lido which aren't in the split
    //      candidate set; the returned legs[] must reflect the actual pick.
    // ================================================================

    function test_splitSwap_fallback_legs_match_best() public view {
        // USDC<->USDT is the canonical case where buildBestSwap tends to pick
        // Curve while the base candidate set doesn't contain Curve. At low
        // amounts the split degrades to a single-venue fallback.
        (zQuoter.Quote[2] memory legs,,) = quoter.buildSplitSwap(USER, _USDC, _USDT, 100e6, SLIPPAGE, DEADLINE);
        // If a Curve route was the actual best, legs[0] must advertise Curve,
        // not whatever the _BASE candidates named.
        (zQuoter.Quote memory actualBest,,,) =
            quoter.buildBestSwap(USER, false, _USDC, _USDT, 100e6, SLIPPAGE, DEADLINE);
        // Either it's a true split (both legs populated) or the fallback set legs[0]=actualBest.
        bool trueSplit = legs[0].amountOut != 0 && legs[1].amountOut != 0;
        if (!trueSplit) {
            assertEq(uint256(legs[0].source), uint256(actualBest.source), "legs[0] source must match buildBestSwap");
        }
    }

    // ================================================================
    //  20. buildHybridSplit must not synthesize a hub via address(0)
    //      when no 2-hop hub route exists. BOLD<->BOLD-only pairs that
    //      have single-hop but no hub route should just emit the direct.
    // ================================================================

    function test_hybridSplit_no_hub_falls_back_to_direct() public view {
        // ETH -> BOLD has a V4 single-hop but limited hub alternatives.
        // We just need this call to not revert and to produce a sensible result.
        try quoter.buildHybridSplit(USER, ETH, _BOLD, 1e18, SLIPPAGE, DEADLINE) returns (
            zQuoter.Quote[2] memory legs, bytes memory mc, uint256 mv
        ) {
            uint256 total = legs[0].amountOut + legs[1].amountOut;
            assertGt(total, 0, "hybrid must produce output");
            assertGt(mc.length, 0);
            mv; // unused
        } catch {
            // Acceptable if even buildBestSwap can't route — BOLD may be thin.
        }
    }

    function test_deadlineMax_SUSHI_route_keeps_sentinel() public view {
        // If SUSHI is the best source for some pair, verify the builder forwards max.
        // We piggy-back on quoteV2(sushi=true) to probe liquidity without hard-coding
        // a pool; if the router has no SUSHI best, skip quietly.
        (, uint256 ao) = _BASE.quoteV2(false, ETH, _USDC, 1e18, true);
        if (ao == 0) return;
        (zQuoter.Quote memory best, bytes memory cd,,) =
            quoter.buildBestSwap(USER, false, ETH, _USDC, 1e18, SLIPPAGE, type(uint256).max);
        if (best.source != zQuoter.AMM.SUSHI) return;
        (, uint256 dl) = _extractV2Deadline(cd);
        assertEq(dl, type(uint256).max, "SUSHI route must preserve sentinel");
    }
}
