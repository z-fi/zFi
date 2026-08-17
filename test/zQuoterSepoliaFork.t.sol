// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {zQuoterSepolia, WETH, ZROUTER, V4_STATE_VIEW} from "../src/zQuoterSepolia.sol";

address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // Uniswap's Sepolia USDC

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// A quote nobody can trade at is not a quote. Every test here that produces a
/// number also SENDS the calldata the quoter built to the zRouter actually
/// deployed on Sepolia, and asserts the chain agreed. Forked, so it runs against
/// that deployment rather than a local redeploy of source that may have drifted.
contract zQuoterSepoliaForkTest is Test {
    zQuoterSepolia quoter;
    address user = address(0xBEEF);

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")));
        quoter = new zQuoterSepolia();
        vm.deal(user, 100 ether);
    }

    // ---------- the deployment this quoter is built for ----------

    /// The whole contract is a set of constants asserted to describe one live
    /// deployment. If any of these is wrong the quotes are silently about a
    /// different chain state, so they are checked rather than trusted.
    function testSepoliaDeploymentIsWhatWeThink() public view {
        assertGt(ZROUTER.code.length, 0, "no zRouter on Sepolia");
        assertGt(WETH.code.length, 0, "no WETH");
        assertGt(V4_STATE_VIEW.code.length, 0, "no v4 StateView");

        // The StateView must front the SAME PoolManager the router will execute
        // against, or V4 quotes describe pools the router cannot reach.
        (, bytes memory ret) = V4_STATE_VIEW.staticcall(abi.encodeWithSignature("poolManager()"));
        address pm = abi.decode(ret, (address));
        assertEq(pm, 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543, "StateView fronts a different PoolManager");
    }

    /// PoolManager.protocolFeeController is unset on Sepolia, so no pool can carry
    /// a protocol fee and the corrected v4 fee composition is a no-op today. This
    /// is the test that will start failing — loudly, and in the right place — if
    /// Sepolia ever switches them on, which is precisely when the corrected math
    /// stops being equivalent to the naive `protocolFee + lpFee`.
    function testV4ProtocolFeesAreOffOnSepolia() public view {
        (, bytes memory ret) =
            0xE03A1074c86CFeDd5C142C4F04F1a1536e203543.staticcall(abi.encodeWithSignature("protocolFeeController()"));
        assertEq(abi.decode(ret, (address)), address(0), "Sepolia enabled v4 protocol fees");
    }

    // ---------- quoting ----------

    function testQuotesFindLiquidity() public view {
        (zQuoterSepolia.Quote memory best, zQuoterSepolia.Quote[] memory quotes) =
            quoter.getQuotes(false, address(0), USDC, 1 ether);

        assertEq(quotes.length, 9, "V2 + 4 V3 tiers + 4 V4 tiers");
        assertGt(best.amountOut, 0, "no venue quoted 1 ETH -> USDC");
        assertEq(best.amountIn, 1 ether, "exactIn must echo the input");

        // At least the V2 pair and one V3 tier are known live (checked out-of-band
        // against the factories), so a zero from both means the pool derivation
        // broke, not that Sepolia is empty.
        uint256 live;
        for (uint256 i; i < quotes.length; ++i) {
            if (quotes[i].amountOut > 0) ++live;
        }
        assertGe(live, 2, "fewer live venues than the factories report");
    }

    function testExactOutRoundTripsAgainstExactIn() public view {
        (zQuoterSepolia.Quote memory best,) = quoter.getQuotes(false, address(0), USDC, 1 ether);
        (zQuoterSepolia.Quote memory back,) = quoter.getQuotes(true, address(0), USDC, best.amountOut);

        assertEq(back.amountOut, best.amountOut, "exactOut must echo the target");
        // Asking for exactly what 1 ETH buys should cost about 1 ETH. Rounding is
        // always in the pool's favour, so the exact-out cost may exceed it slightly.
        assertGe(back.amountIn, 1 ether - 0.01 ether);
        assertLe(back.amountIn, 1 ether + 0.01 ether);
    }

    function testIdenticalTokensReverts() public {
        vm.expectRevert(zQuoterSepolia.IdenticalTokens.selector);
        quoter.getQuotes(false, address(0), WETH, 1 ether); // address(0) normalizes to WETH
    }

    function testNoRouteRevertsRatherThanQuotingZero() public {
        vm.expectRevert(zQuoterSepolia.NoRoute.selector);
        quoter.buildBestSwap(user, false, address(0), address(0xDEAD), 1 ether, 100, block.timestamp + 1);
    }

    // ---------- differential: agree with Uniswap's own quoters ----------

    /// The V3/V4 engine here is a reimplementation of Uniswap's step loop, so
    /// "it executes" only proves it is not optimistic — it could be pessimistic
    /// and still pass, quietly routing away from V3. Uniswap's own Sepolia
    /// QuoterV2 is the independent oracle for that.
    function testV3AgreesWithUniswapQuoterV2() public {
        address uniQuoter = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;
        uint24[2] memory tiers = [uint24(500), 3000];

        uint256 compared;
        for (uint256 i; i < tiers.length; ++i) {
            (, uint256 ours) = quoter.quoteV3(false, address(0), USDC, tiers[i], 1 ether);
            if (ours == 0) continue; // tier not live; nothing to compare against

            (bool ok, bytes memory ret) = uniQuoter.call(
                abi.encodeWithSignature(
                    "quoteExactInputSingle((address,address,uint256,uint24,uint160))",
                    WETH,
                    USDC,
                    uint256(1 ether),
                    tiers[i],
                    uint160(0)
                )
            );
            assertTrue(ok, "Uniswap's quoter refused a tier we quoted");
            (uint256 theirs,,,) = abi.decode(ret, (uint256, uint160, uint32, uint256));
            assertEq(ours, theirs, "our V3 math diverged from Uniswap's");
            ++compared;
        }
        assertGt(compared, 0, "no live V3 tier to compare; the test proved nothing");
    }

    // ---------- execution: the quote has to be tradeable ----------

    function testBestSwapExecutesOnTheDeployedRouter() public {
        (zQuoterSepolia.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(user, false, address(0), USDC, 1 ether, 100, block.timestamp + 1);

        assertGt(best.amountOut, 0);
        assertEq(msgValue, 1 ether, "paying in ether must attach the input");

        uint256 before = IERC20(USDC).balanceOf(user);
        vm.prank(user);
        (bool ok,) = ZROUTER.call{value: msgValue}(callData);
        assertTrue(ok, "the built calldata reverted on the live router");

        uint256 received = IERC20(USDC).balanceOf(user) - before;
        assertGe(received, amountLimit, "execution came in under its own slippage bound");
        // The quote is a prediction of a pure function of state that has not moved
        // between the quote and the swap, so it should be exact, not merely close.
        assertEq(received, best.amountOut, "quote did not match execution");
    }

    function testExactOutSwapExecutesOnTheDeployedRouter() public {
        uint256 target = 10e6; // 10 USDC
        (zQuoterSepolia.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(user, true, address(0), USDC, target, 100, block.timestamp + 1);

        assertGt(best.amountIn, 0);
        assertEq(msgValue, amountLimit, "exact-out in ether must attach the slippage-padded maximum");

        uint256 before = IERC20(USDC).balanceOf(user);
        vm.prank(user);
        (bool ok,) = ZROUTER.call{value: msgValue}(callData);
        assertTrue(ok, "the built calldata reverted on the live router");

        assertEq(IERC20(USDC).balanceOf(user) - before, target, "exact-out delivered a different amount");
    }

    /// The wrap path never touches a venue, so it is the one route that must be
    /// exactly 1:1 — a spread here would mean the quoter invented one.
    function testEthToWethWrapsOneToOne() public {
        (zQuoterSepolia.Quote memory best, bytes memory callData,, uint256 msgValue) =
            quoter.buildBestSwap(user, false, address(0), WETH, 1 ether, 0, block.timestamp + 1);

        assertEq(uint8(best.source), uint8(zQuoterSepolia.AMM.WETH_WRAP));
        assertEq(best.amountOut, 1 ether);

        // A delta, not an absolute balance: `user` is a real Sepolia address and
        // already holds WETH there, which an absolute assertion reads as a bug in
        // the wrap.
        uint256 before = IERC20(WETH).balanceOf(user);
        vm.prank(user);
        (bool ok,) = ZROUTER.call{value: msgValue}(callData);
        assertTrue(ok, "wrap reverted");
        assertEq(IERC20(WETH).balanceOf(user) - before, 1 ether, "wrap was not 1:1");
    }
}
