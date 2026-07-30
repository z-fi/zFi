// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";

/// @dev Regression test for the 2026-07-27 Uniswap V4 protocol-fee activation
/// (mainnet block 25623201).
///
/// The base quoter's V4 math reverts once a pool's protocol fee for the swap
/// direction exceeds ~240 pips, and it iterates fee tiers with no per-tier error
/// handling — so one fee-bearing pool reverted `getQuotes` and every builder
/// layered on top, for any pair touching that pool.
///
/// The fault is synthesized via `vm.store` rather than read from live state, so
/// this stays deterministic, runs at the fork block this suite pins itself, and
/// keeps reproducing the bug after Uniswap changes these fees again.
contract zQuoterV4FeeResilienceTest is Test {
    zQuoter quoter;

    address constant BASE = 0x658bF1A6608210FDE7310760f391AD4eC8006A5F;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    address constant ETH = address(0);
    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USER = address(0xBEEF);

    /// @dev slot0 layout, high→low: lpFee(24) | protocolFee(24) | tick(24) | sqrtPriceX96(160)
    uint256 constant PROTOCOL_FEE_SHIFT = 184;
    /// @dev 500 pips both directions — what governance actually set on ETH/USDC 3000/60.
    uint256 constant FEE_500_BOTH = 0x1f41f4;

    /// @dev This suite must NOT ride foundry.toml's global pin (24,880,000):
    /// the `_V4` tier-quoting helper this quoter delegates to has no code that
    /// far back, so every per-tier staticcall returns empty, every V4 tier zeros
    /// out, and the healthy-path comparison against BASE fails for a reason that
    /// has nothing to do with protocol fees. 25,640,000 is the first pin where
    /// the helper, BASE and the PoolManager all exist - the same block the other
    /// repaired zQuoter suites use.
    string constant DEFAULT_RPC = "https://gateway.tenderly.co/public/mainnet";
    uint256 constant DEFAULT_FORK_BLOCK = 25_640_000;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string(DEFAULT_RPC)), vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));
        quoter = new zQuoter();

        // Establish a known-good baseline. Depending on the fork block these pools
        // may already carry live protocol fees (they have on mainnet since block
        // 25623201), so zero them first; each test then sets exactly the fee it
        // means to exercise. This keeps the suite valid at any fork block.
        _setProtocolFee(ETH, _USDC, 3000, 60, 0);
        _setProtocolFee(ETH, _USDC, 500, 10, 0);
        _setProtocolFee(ETH, _USDC, 100, 1, 0);
        _setProtocolFee(ETH, _USDC, 10000, 200, 0);
    }

    // ** THE BUG (unfixed base quoter)

    function test_base_revertsOnceProtocolFeeSet() public {
        // Healthy beforehand.
        (, uint256 out) = IZQuoterBase(BASE).quoteV4(false, ETH, _USDC, 3000, 60, address(0), 1 ether);
        assertGt(out, 0, "tier quotes before the fee is set");

        _setProtocolFee(ETH, _USDC, 3000, 60, FEE_500_BOTH);

        vm.expectRevert();
        IZQuoterBase(BASE).quoteV4(false, ETH, _USDC, 3000, 60, address(0), 1 ether);

        // ...and one poisoned tier takes down the base's whole aggregate.
        vm.expectRevert();
        IZQuoterBase(BASE).getQuotes(false, ETH, _USDC, 1 ether);
    }

    // ** THE FIX (zQuoter survives it)

    function test_getQuotes_survivesPoisonedTier() public {
        (, zQuoter.Quote[] memory healthy) = quoter.getQuotes(false, ETH, _USDC, 1 ether);
        uint256 healthyV4 = healthy[12].amountOut;
        assertGt(healthyV4, 0, "fixture: the tier must quote before it is poisoned");

        _setProtocolFee(ETH, _USDC, 3000, 60, FEE_500_BOTH);

        (zQuoter.Quote memory best, zQuoter.Quote[] memory quotes) = quoter.getQuotes(false, ETH, _USDC, 1 ether);

        assertEq(quotes.length, 14, "grid shape preserved");
        assertGt(best.amountOut, 0, "still finds a best route");

        // A fee-bearing tier is PRICED, not discarded. An earlier fix zeroed it
        // to dodge the revert, which threw away real liquidity; the tier quoter
        // now applies the protocol fee properly. 500 pips is 0.05%, so the tier
        // comes back ~5bps below its healthy value instead of dropping to zero.
        assertTrue(quotes[12].source == zQuoter.AMM.UNI_V4, "index 12 is the V4 30bps tier");
        assertGt(quotes[12].amountOut, 0, "poisoned tier still quotes");
        assertApproxEqRel(
            quotes[12].amountOut, healthyV4 * 999_500 / 1_000_000, 1e15, "protocol fee not applied as 500 pips"
        );

        // The liquidity that actually matters survives.
        uint256 v3Live;
        for (uint256 i = 6; i < 10; ++i) {
            if (quotes[i].amountOut > 0) v3Live++;
        }
        assertGt(v3Live, 0, "V3 tiers still quote");
        assertGt(quotes[0].amountOut, 0, "V2 still quotes");
    }

    /// End-to-end: the builder the dapp and API actually call still works.
    function test_builder_survivesPoisonedTier() public {
        _setProtocolFee(ETH, _USDC, 3000, 60, FEE_500_BOTH);

        (zQuoter.Quote memory a, zQuoter.Quote memory b,, bytes memory mc, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(USER, USER, false, ETH, _USDC, 1 ether, 100, type(uint256).max);

        uint256 out = b.amountOut > 0 ? b.amountOut : a.amountOut;
        assertGt(out, 0, "route still built");
        assertGt(mc.length, 0, "calldata still produced");
        assertEq(mv, 1 ether, "ETH input still attached as msg.value");
    }

    /// Forward-looking: holds up even if every ETH/USDC V4 tier gets a fee.
    function test_survivesFullV4FeeRollout() public {
        _setProtocolFee(ETH, _USDC, 3000, 60, FEE_500_BOTH);
        _setProtocolFee(ETH, _USDC, 500, 10, FEE_500_BOTH);
        _setProtocolFee(ETH, _USDC, 100, 1, FEE_500_BOTH);
        _setProtocolFee(ETH, _USDC, 10000, 200, FEE_500_BOTH);

        (zQuoter.Quote memory best,) = quoter.getQuotes(false, ETH, _USDC, 1 ether);
        assertGt(best.amountOut, 0, "still routable with all V4 tiers poisoned");
        assertTrue(best.source != zQuoter.AMM.UNI_V4, "best is not a dead V4 tier");
    }

    // ** TRANSPARENCY: healthy pairs are untouched by the guard

    function test_healthyPath_matchesBaseExactly() public view {
        (zQuoter.Quote memory bBest, zQuoter.Quote[] memory bQuotes) =
            IZQuoterBase(BASE).getQuotes(false, ETH, _USDC, 1 ether);
        (zQuoter.Quote memory sBest, zQuoter.Quote[] memory sQuotes) = quoter.getQuotes(false, ETH, _USDC, 1 ether);

        assertEq(sQuotes.length, bQuotes.length, "same length");
        assertEq(sBest.amountOut, bBest.amountOut, "same best");
        for (uint256 i; i < bQuotes.length; ++i) {
            assertEq(sQuotes[i].amountOut, bQuotes[i].amountOut, "identical entry");
            assertEq(uint8(sQuotes[i].source), uint8(bQuotes[i].source), "identical source");
        }
    }

    /// @dev Write a protocol fee into a V4 pool's slot0, exactly as governance did.
    function _setProtocolFee(address c0, address c1, uint24 fee, int24 spacing, uint256 pips) internal {
        bytes32 poolId = keccak256(abi.encode(c0, c1, fee, spacing, address(0)));
        bytes32 slot = keccak256(abi.encode(poolId, uint256(6)));
        uint256 v = uint256(vm.load(POOL_MANAGER, slot));
        v &= ~(uint256(0xffffff) << PROTOCOL_FEE_SHIFT);
        v |= (pips << PROTOCOL_FEE_SHIFT);
        vm.store(POOL_MANAGER, slot, bytes32(v));
    }

}
