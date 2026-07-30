// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";
import {zQuoterV4} from "../src/zQuoterV4.sol";

/// @dev End-to-end: zQuoter wired to the corrected V4 helper must stop surfacing
/// the poisoned V4 legs that produced the user-reported 2.3M USDC/ETH quote and
/// the rETH Slippage() revert.
///
/// zQuoter hardcodes _V4, so the helper is etched at that address to match the
/// deployed layout. Run against state AFTER block 25623201.
contract zQuoterV4WiredTest is Test {
    /// @dev Defaults so the suite runs without tribal knowledge. Both are
    /// overridable by env. The block is chosen to be AFTER the currently
    /// deployed zQuoter/zRouter, so live-address tests are possible here.
    string constant DEFAULT_RPC = "https://gateway.tenderly.co/public/mainnet";
    uint256 constant DEFAULT_FORK_BLOCK = 25_640_000;

    zQuoter q;

    address constant V4_HELPER = 0x00005d8a3675b7b00BA172Aa85485Fc5D23121B6;
    address constant BASE = 0x658bF1A6608210FDE7310760f391AD4eC8006A5F;

    address constant ETH = address(0);
    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant _WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address constant USER = address(0xBEEF);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string(DEFAULT_RPC)), vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));
        vm.etch(V4_HELPER, address(new zQuoterV4()).code);
        q = new zQuoter();
    }

    /// The grid's V4 entries must be the corrected ones, not the base's.
    function test_gridV4EntriesAreCorrected() public view {
        (, zQuoter.Quote[] memory qs) = q.getQuotes(false, _WBTC, _USDC, 49_612);
        (, uint256 v3ref) = IZQuoterBase(BASE).quoteV3(false, _WBTC, _USDC, 500, 49_612);
        for (uint256 i; i < qs.length; ++i) {
            if (qs[i].source == zQuoter.AMM.UNI_V4 && qs[i].amountOut > 0) {
                assertLt(qs[i].amountOut, v3ref * 3, "a V4 grid entry is still inflated");
            }
        }
    }

    /// The exact trade the user reported: 0.01664968238050798 ETH -> USDC.
    /// Previously quoted ~38,409 USDC (~2.3M USDC/ETH) via a poisoned WBTC hub leg.
    function test_userReportedTrade_isSane() public view {
        uint256 amt = 16_649_682_380_507_980;
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            q.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _USDC, amt, 50, type(uint256).max);
        uint256 out = b.amountOut > 0 ? b.amountOut : a.amountOut;
        (, uint256 direct) = IZQuoterBase(BASE).quoteV3(false, ETH, _USDC, 500, amt);
        assertGt(out, 0, "route built");
        // ~31.7 USDC expected; the bug produced ~38,409e6.
        assertLt(out, direct * 2, "hub route must be sane vs direct V3");
        assertGt(out, direct / 2, "and not absurdly low");
    }

    /// The rETH pair the user reported reverting.
    function test_rethRoute_isSane() public view {
        uint256 amt = 16_649_682_380_507_980;
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            q.buildBestSwapViaETHMulticall(USER, USER, false, ETH, RETH, amt, 50, type(uint256).max);
        uint256 out = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(out, 0, "rETH route built");
        // rETH trades near ETH parity; 0.0166 ETH must not yield ~0.26 rETH.
        assertLt(out, amt * 2, "rETH output must be near parity, not 15x");
    }

    /// Split path reads the same grid, so it must be clean too.
    function test_splitUsesCorrectedGrid() public view {
        uint256 amt = 16_649_682_380_507_980;
        (zQuoter.Quote[2] memory legs,,) = q.buildSplitSwap(USER, ETH, _USDC, amt, 150, type(uint256).max);
        (, uint256 direct) = IZQuoterBase(BASE).quoteV3(false, ETH, _USDC, 500, amt);
        uint256 total = legs[0].amountOut + legs[1].amountOut;
        assertGt(total, 0, "split built");
        assertLt(total, direct * 2, "split must be sane");
    }
}
