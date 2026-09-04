// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zQuoterV4} from "../src/zQuoterV4.sol";

interface IBaseQuoter {
    function quoteV4(bool, address, address, uint24, int24, address, uint256) external view returns (uint256, uint256);
}

interface IV4Quoter {
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

    function quoteExactInputSingle(QuoteExactSingleParams memory) external returns (uint256, uint256);
    function quoteExactOutputSingle(QuoteExactSingleParams memory) external returns (uint256, uint256);
}

/// @dev Differential test: our corrected V4 quoter vs Uniswap's canonical
/// periphery quoter (the reference), and vs the broken base quoter (the bug).
///
/// The base quoter passes `protocolFee + lpFee` to computeSwapStep. protocolFee
/// is a packed uint24 (two 12-bit halves), not a rate, so once Uniswap enabled
/// protocol fees at block 25623201 every V4 quote went wrong. Run against state
/// AFTER that block.
contract zQuoterV4FixTest is Test {
    /// @dev Defaults so the suite runs without tribal knowledge. Both are
    /// overridable by env. The block is chosen to be AFTER the currently
    /// deployed zQuoter/zRouter, so live-address tests are possible here.
    string constant DEFAULT_RPC = "https://gateway.tenderly.co/public/mainnet";
    uint256 constant DEFAULT_FORK_BLOCK = 25_906_900;

    zQuoterV4 q;

    address constant BASE = 0x658bF1A6608210FDE7310760f391AD4eC8006A5F;
    IV4Quoter constant CANON = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);

    address constant ETH = address(0);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string(DEFAULT_RPC)), vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));
        q = new zQuoterV4();
    }

    function _canon(address a, address b, uint24 fee, int24 sp, uint128 amt) internal returns (uint256) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        try CANON.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams(IV4Quoter.PoolKey(c0, c1, fee, sp, address(0)), a < b, amt, "")
        ) returns (
            uint256 out, uint256
        ) {
            return out;
        } catch {
            return 0;
        }
    }

    function _canonExactOut(address a, address b, uint24 fee, int24 sp, uint128 amt) internal returns (uint256) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        try CANON.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams(IV4Quoter.PoolKey(c0, c1, fee, sp, address(0)), a < b, amt, "")
        ) returns (
            uint256 input, uint256
        ) {
            return input;
        } catch {
            return 0;
        }
    }

    /// Core assertion: ours must match Uniswap's own quoter within 0.5%.
    function _diff(address a, address b, uint24 fee, int24 sp, uint128 amt, string memory label) internal {
        uint256 ref = _canon(a, b, fee, sp, amt);
        if (ref == 0) return; // pool not usable at this size; nothing to compare
        (, uint256 ours) = q.quoteV4(false, a, b, fee, sp, address(0), amt);
        assertGt(ours, 0, string.concat(label, ": ours returned 0"));
        uint256 hi = ref > ours ? ref : ours;
        uint256 lo = ref > ours ? ours : ref;
        assertLe((hi - lo) * 1000 / hi, 5, string.concat(label, ": >0.5% off canonical"));
    }

    /// @dev Exact-output is a separate code path: it reverses the amount sign,
    ///      accumulates input rather than output, and must reject unfillable targets.
    function _diffExactOut(address a, address b, uint24 fee, int24 sp, uint128 amt, string memory label) internal {
        uint256 ref = _canonExactOut(a, b, fee, sp, amt);
        if (ref == 0) return; // target is unavailable at this fork state
        (uint256 ours, uint256 out) = q.quoteV4(true, a, b, fee, sp, address(0), amt);
        assertEq(out, amt, string.concat(label, ": returned the wrong output amount"));
        assertGt(ours, 0, string.concat(label, ": ours returned 0"));
        uint256 hi = ref > ours ? ref : ours;
        uint256 lo = ref > ours ? ours : ref;
        assertLe((hi - lo) * 1000 / hi, 5, string.concat(label, ": >0.5% off canonical"));
    }

    function test_matchesCanonical_ethUsdc() public {
        _diff(ETH, USDC, 500, 10, 1e16, "ETH/USDC 500/10");
        _diff(ETH, USDC, 3000, 60, 1e16, "ETH/USDC 3000/60");
        _diff(ETH, USDC, 10000, 200, 1e16, "ETH/USDC 10000/200");
    }

    function test_matchesCanonical_wbtcUsdc() public {
        _diff(WBTC, USDC, 500, 10, 30000, "WBTC/USDC 500/10");
        _diff(WBTC, USDC, 3000, 60, 30000, "WBTC/USDC 3000/60");
    }

    function test_matchesCanonical_stables_and_lst() public {
        _diff(USDC, USDT, 100, 1, 20e6, "USDC/USDT 100/1");
        _diff(ETH, WSTETH, 100, 1, 1e16, "ETH/wstETH 100/1");
    }

    function test_matchesCanonical_acrossSizes() public {
        _diff(WBTC, USDC, 3000, 60, 100, "WBTC/USDC tiny");
        _diff(WBTC, USDC, 3000, 60, 10000, "WBTC/USDC small");
        _diff(WBTC, USDC, 3000, 60, 49612, "WBTC/USDC mid");
        _diff(WBTC, USDC, 3000, 60, 1000000, "WBTC/USDC large");
    }

    function test_exactOut_matchesCanonical_bothDirectionsAndTiers() public {
        _diffExactOut(ETH, USDC, 500, 10, 10e6, "ETH/USDC 500/10");
        _diffExactOut(ETH, USDC, 3000, 60, 10e6, "ETH/USDC 3000/60");
        _diffExactOut(USDC, ETH, 500, 10, 1e16, "USDC/ETH 500/10");
        _diffExactOut(WBTC, USDC, 500, 10, 20e6, "WBTC/USDC 500/10");
        _diffExactOut(USDC, WBTC, 3000, 60, 10_000, "USDC/WBTC 3000/60");
        _diffExactOut(USDC, USDT, 100, 1, 20e6, "USDC/USDT 100/1");
    }

    /// The headline case: base returns a constant ~2013x too high; we must not.
    function test_fixesTheInflatedPool() public {
        uint128 amt = 49612;
        (, uint256 bad) = IBaseQuoter(BASE).quoteV4(false, WBTC, USDC, 3000, 60, address(0), amt);
        (, uint256 ours) = q.quoteV4(false, WBTC, USDC, 3000, 60, address(0), amt);
        uint256 ref = _canon(WBTC, USDC, 3000, 60, amt);
        emit log_named_uint("base (broken)", bad);
        emit log_named_uint("ours  (fixed)", ours);
        emit log_named_uint("canonical     ", ref);
        assertGt(bad, ref * 100, "base really is wildly inflated");
        assertApproxEqRel(ours, ref, 0.005e18, "ours tracks canonical");
    }

    /// Base under-quotes ~0.49x here because packed pf 0x07d07d reads as a 51% fee.
    function test_fixesTheUnderQuote() public {
        uint128 amt = 30000;
        (, uint256 bad) = IBaseQuoter(BASE).quoteV4(false, WBTC, USDC, 500, 10, address(0), amt);
        (, uint256 ours) = q.quoteV4(false, WBTC, USDC, 500, 10, address(0), amt);
        uint256 ref = _canon(WBTC, USDC, 500, 10, amt);
        emit log_named_uint("base (broken)", bad);
        emit log_named_uint("ours  (fixed)", ours);
        emit log_named_uint("canonical     ", ref);
        assertLt(bad * 100 / ref, 60, "base really does under-quote");
        assertApproxEqRel(ours, ref, 0.005e18, "ours tracks canonical");
    }

    /// Degenerate inputs must return (0,0), never revert.
    function test_degenerateInputsAreSafe() public view {
        (uint256 a1, uint256 b1) = q.quoteV4(false, WBTC, USDC, 777, 7, address(0), 1000);
        assertEq(a1 + b1, 0, "nonexistent tier -> 0");
        (uint256 a2, uint256 b2) = q.quoteV4(false, WBTC, USDC, 3000, 60, address(0), 0);
        assertEq(a2 + b2, 0, "zero amount -> 0");
    }

    address constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;

    /// A pool that cannot absorb the trade must quote 0, not a partial fill.
    /// rETH/USDC 3000/60 holds ~1.2e14 liquidity; Uniswap's quoter reverts
    /// NotEnoughLiquidity(poolId) for ~$40 of rETH. We previously returned 122
    /// units (~$0.0001), which then won `best` and produced a dust rETH->BOLD
    /// route while a valid 3-hop route worth ~$40 existed.
    function test_partialFillIsNotAQuote() public view {
        uint128 amt = 18_604_651_162_790_697; // ~$40 of rETH
        (, uint256 ours) = q.quoteV4(false, RETH, USDC, 3000, 60, address(0), amt);
        assertEq(ours, 0, "unfillable pool must quote 0, not a partial fill");
    }

    function test_exactOut_partialFillIsNotAQuote() public {
        uint128 want = 20e6; // far beyond the thin rETH/USDC pool's available USDC
        uint256 ref = _canonExactOut(RETH, USDC, 3000, 60, want);
        assertEq(ref, 0, "canonical quoter must reject the unfillable output target");
        (uint256 amountIn, uint256 amountOut) = q.quoteV4(true, RETH, USDC, 3000, 60, address(0), want);
        assertEq(amountIn, 0, "unfillable exact-out input must be zero");
        assertEq(amountOut, 0, "unfillable exact-out output must be zero");
    }

    /// The same pool must still quote a size it CAN fill.
    function test_smallTradeInThinPoolStillQuotes() public {
        uint128 small = 1e12;
        uint256 ref = _canon(RETH, USDC, 3000, 60, small);
        if (ref == 0) return;
        (, uint256 ours) = q.quoteV4(false, RETH, USDC, 3000, 60, address(0), small);
        assertApproxEqRel(ours, ref, 0.005e18, "fillable size still quotes");
    }
}
