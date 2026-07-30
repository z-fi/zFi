// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";

/// @dev Regression test for the *silent* face of the V4 protocol-fee bug.
///
/// Uniswap's 2026-07 protocol-fee activation broke the base quoter's V4 math on
/// fee-bearing pools. On ETH/USDC 3000/60 it reverts (covered by
/// zQuoterV4FeeResilience.t.sol). On WBTC/USDC 3000/60 it instead returns a
/// confident, wildly inflated amountOut — ~49,600 sats (~$30) quoted as 38,385
/// USDC. No try/catch can see that: the hub router picks the fantasy leg and
/// execution reverts with Slippage() because the minimum is unreachable.
///
/// Must run against state AFTER block 25623201, so it forks at a recent block
/// rather than the suite's pinned one (which predates the fee activation).
contract zQuoterV4PhantomTest is Test {
    /// @dev Defaults so the suite runs without tribal knowledge. Both are
    /// overridable by env. The block is chosen to be AFTER the currently
    /// deployed zQuoter/zRouter, so live-address tests are possible here.
    string constant DEFAULT_RPC = "https://gateway.tenderly.co/public/mainnet";
    uint256 constant DEFAULT_FORK_BLOCK = 25_640_000;

    zQuoter quoter;

    address constant BASE = 0x658bF1A6608210FDE7310760f391AD4eC8006A5F;
    address constant ETH = address(0);
    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant _WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USER = address(0xBEEF);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string(DEFAULT_RPC)), vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));
        quoter = new zQuoter();
    }

    /// The base quoter really does return the fantasy number (documents the bug).
    function test_base_returnsInflatedV4Quote() public view {
        (, uint256 bad) = IZQuoterBase(BASE).quoteV4(false, _WBTC, _USDC, 3000, 60, address(0), 49_612);
        (, uint256 sane) = IZQuoterBase(BASE).quoteV3(false, _WBTC, _USDC, 500, 49_612);
        assertGt(sane, 0, "V3 reference quote works");
        // ~$30 of WBTC is ~31 USDC; the V4 tier claims orders of magnitude more.
        assertGt(bad, sane * 100, "V4 tier is wildly inflated");
    }

    /// zQuoter must not surface that tier as best.
    function test_getQuotes_rejectsInflatedV4() public view {
        (zQuoter.Quote memory best,) = quoter.getQuotes(false, _WBTC, _USDC, 49_612);
        (, uint256 sane) = IZQuoterBase(BASE).quoteV3(false, _WBTC, _USDC, 500, 49_612);
        assertGt(best.amountOut, 0, "still routable");
        // Allow generous headroom over the V3 reference, but nothing absurd.
        assertLt(best.amountOut, sane * 3, "best must not be the fantasy V4 quote");
    }

    /// End-to-end: the pair the user hit. 0.0166 ETH is worth ~31 USDC, and the
    /// hub route previously reported ~38,409 USDC via the poisoned V4 leg.
    function test_hubRoute_notPoisoned() public view {
        uint256 amt = 16_649_682_380_507_980;
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _USDC, amt, 50, type(uint256).max);
        uint256 out = b.amountOut > 0 ? b.amountOut : a.amountOut;
        (, uint256 direct) = IZQuoterBase(BASE).quoteV3(false, ETH, _USDC, 500, amt);
        assertGt(out, 0, "route still built");
        assertGt(direct, 0, "direct reference works");
        assertLt(out, direct * 3, "hub route must not exceed sanity vs direct");
    }
}
