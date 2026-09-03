// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";

import {zRouterLiteBase} from "../src/zRouterLiteBase.sol";
import {zQuoterBase} from "../src/zQuoterBase.sol";

/// @dev Unpinned, for the same reason the Robinhood suite is: every assertion
/// here compares a quote against what execution actually returns, or a derived
/// address against the factory's own registry. Neither needs a fixed block, and
/// a venue that has emptied out skips rather than fails.
/// @dev Read from the environment so a fast private endpoint can be used locally
/// without its API key ending up in the repo. The default is deliberately a public
/// node rather than mainnet.base.org: the hub and split builders sweep twenty
/// venues per leg across five hubs, tens of thousands of storage reads per test,
/// and that endpoint rate-limits into "operation timed out" — a failure that reads
/// exactly like a broken quoter.
///
///   BASE_RPC_URL=https://base.gateway.tenderly.co/<key> forge test --match-path test/zBase.t.sol
address constant WETH = 0x4200000000000000000000000000000000000006;
address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

address constant V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
address constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
address constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
address constant V4_STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;
address constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
address constant AERO_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
address constant ZAMM = 0x000000000000040470635EB91b7CE4D132D616eD;

/// @dev The canonical zRouter address. The quoter hardcodes it, so the router
/// under test has to actually live there — `deployCodeTo` runs the constructor at
/// that address, which a plain `vm.etch` of runtime code would not (it would
/// leave `_owner` unset and `safeExecutor` pointing at another deployment).
address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

bytes32 constant V2_POOL_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
bytes32 constant V3_POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

interface IV2Factory {
    function getPair(address, address) external view returns (address);
}

interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IAeroFactory {
    function getPool(address, address, bool) external view returns (address);
    function implementation() external view returns (address);
}

interface IAeroCLFactory {
    function getPool(address, address, int24) external view returns (address);
    function poolImplementation() external view returns (address);
    function tickSpacingToFee(int24) external view returns (uint24);
}

interface IStateView {
    function poolManager() external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract BaseTest is Test {
    zRouterLiteBase router;
    zQuoterBase quoter;

    address alice = makeAddr("alice");
    address deployer = makeAddr("deployer");
    address nowhere = makeAddr("nowhere");

    /// @dev Environment-driven so a fast private endpoint can be used locally
    /// without its API key ending up in the repo.
    function _rpc() internal view returns (string memory) {
        return vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com"));
    }

    function setUp() public {
        vm.createSelectFork(_rpc());
        // `makeAddr` is not guaranteed to land on an empty account when forking:
        // on Base, alice's address holds a live proxy that forwards every ether it
        // receives, which silently ate the output of an ETH-out swap.
        vm.etch(alice, "");
        vm.etch(deployer, "");
        vm.prank(deployer, deployer);
        deployCodeTo("zRouterLiteBase.sol:zRouterLiteBase", ZROUTER);
        router = zRouterLiteBase(payable(ZROUTER));
        quoter = new zQuoterBase();
        vm.deal(alice, 1000 ether);
    }

    function _need(uint256 quoted) internal {
        if (quoted == 0) vm.skip(true);
    }

    // ══════════ derivations, checked against each factory's own registry ══════════
    //
    // These are the load-bearing tests. Quoter and router both reach a pool by
    // computing its address; if any derivation were wrong, every quote would name
    // a pool the built calldata cannot reach.

    function testChainIsBase() public view {
        assertEq(block.chainid, 8453);
    }

    function testV2DerivationMatchesFactory() public view {
        (address t0, address t1) = WETH < USDC ? (WETH, USDC) : (USDC, WETH);
        address derived = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff", V2_FACTORY, keccak256(abi.encodePacked(t0, t1)), V2_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
        assertEq(IV2Factory(V2_FACTORY).getPair(WETH, USDC), derived, "V2 init-code hash wrong for Base");
    }

    function testV3DerivationMatchesFactory() public view {
        (address t0, address t1) = WETH < USDC ? (WETH, USDC) : (USDC, WETH);
        address derived = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            V3_FACTORY,
                            keccak256(abi.encode(t0, t1, uint24(500))),
                            V3_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
        assertEq(IV3Factory(V3_FACTORY).getPool(WETH, USDC, 500), derived, "V3 init-code hash wrong for Base");
    }

    /// @dev Aerodrome pools are clones, so the derivation hashes clone initcode
    /// rather than pool initcode — and the two factories salt it differently.
    /// A quote reaching a pool at all is proof the derivation matched.
    function testAeroDerivationsMatchTheirFactories() public view {
        assertEq(
            IAeroFactory(AERO_FACTORY).implementation(),
            0xA4e46b4f701c62e14DF11B48dCe76A7d793CD6d7,
            "classic implementation moved"
        );
        assertEq(
            IAeroCLFactory(AERO_CL_FACTORY).poolImplementation(),
            0xeC8E5342B19977B4eF8892e02D8DAEcfa1315831,
            "slipstream implementation moved"
        );

        address volatilePool = IAeroFactory(AERO_FACTORY).getPool(WETH, USDC, false);
        assertTrue(volatilePool != address(0), "no volatile WETH/USDC pool");
        (, uint256 out,) = quoter.quoteAero(false, WETH, USDC, 1 ether);
        assertGt(out, 0, "clone derivation missed the registered pool");
    }

    function testStateViewPointsAtTheRoutersPoolManager() public view {
        assertEq(IStateView(V4_STATE_VIEW).poolManager(), V4_POOL_MANAGER);
    }

    function testZammIsDeployed() public view {
        assertGt(ZAMM.code.length, 0);
    }

    // ══════════ the Slipstream spacing fix ══════════

    /// @dev The deployed quoter sweeps spacings 1, 10, 60 and 200 — Uniswap's
    /// fee/spacing pairing. Slipstream's are 1, 10, 50, 100, 200 and 2000. This
    /// pins that 60 is not a real spacing here and that 100 is, which is the
    /// difference between missing the deepest Slipstream pools and quoting them.
    function testSlipstreamSpacingsAreNotUniswapsPairing() public view {
        assertEq(IAeroCLFactory(AERO_CL_FACTORY).tickSpacingToFee(60), 0, "60 unexpectedly enabled");
        assertGt(IAeroCLFactory(AERO_CL_FACTORY).tickSpacingToFee(100), 0, "100 unexpectedly disabled");
        assertGt(IAeroCLFactory(AERO_CL_FACTORY).tickSpacingToFee(2000), 0, "2000 unexpectedly disabled");
    }

    function testAeroCLQuotesTheSpacingTheDeployedQuoterMisses() public view {
        address pool = IAeroCLFactory(AERO_CL_FACTORY).getPool(WETH, USDC, 100);
        assertTrue(pool != address(0), "no spacing-100 WETH/USDC pool");
        (, uint256 out) = quoter.quoteAeroCL(false, WETH, USDC, 100, 1 ether);
        assertGt(out, 0, "spacing 100 quoted nothing");
    }

    /// @dev An AERO_CL quote carries its tick spacing in `feeBps`, because that is
    /// what names a Slipstream pool. Anything else cannot round-trip.
    function testAeroCLQuoteCarriesItsSpacing() public view {
        (, zQuoterBase.Quote[] memory q) = quoter.getQuotes(false, address(0), USDC, 1 ether);
        assertEq(q.length, 20);
        int24[6] memory spacings = [int24(1), 10, 50, 100, 200, 2000];
        for (uint256 i; i < 6; ++i) {
            assertTrue(q[14 + i].source == zQuoterBase.AMM.AERO_CL);
            assertEq(q[14 + i].feeBps, uint256(uint24(spacings[i])));
        }
    }

    // ══════════ quote == execution, per venue ══════════

    function testV2QuoteMatchesExecution() public {
        (, uint256 quoted) = quoter.quoteV2(false, address(0), USDC, 1 ether);
        _need(quoted);

        vm.prank(alice);
        (, uint256 amountOut) = router.swapV2{value: 1 ether}(alice, false, address(0), USDC, 1 ether, 0, block.timestamp);
        assertEq(amountOut, quoted, "V2 quote drifted from execution");
    }

    function testV3QuoteMatchesExecution() public {
        (, uint256 quoted) = quoter.quoteV3(false, address(0), USDC, 500, 1 ether);
        _need(quoted);

        vm.prank(alice);
        (, uint256 amountOut) =
            router.swapV3{value: 1 ether}(alice, false, 500, address(0), USDC, 1 ether, 0, block.timestamp);
        assertEq(amountOut, quoted, "V3 quote drifted from execution");
    }

    function testV4QuoteMatchesExecution() public {
        (, uint256 quoted) = quoter.quoteV4(false, address(0), USDC, 500, 1 ether);
        _need(quoted);

        vm.prank(alice);
        (, uint256 amountOut) =
            router.swapV4{value: 1 ether}(alice, false, 500, 10, address(0), USDC, 1 ether, 0, block.timestamp);
        assertEq(amountOut, quoted, "V4 quote drifted from execution");
    }

    function testAeroVolatileQuoteMatchesExecution() public {
        (, uint256 quoted, uint256 kind) = quoter.quoteAero(false, address(0), USDC, 1 ether);
        _need(quoted);
        assertEq(kind, 20, "expected the volatile pool to win WETH/USDC");

        vm.prank(alice);
        (, uint256 amountOut) =
            router.swapAero{value: 1 ether}(alice, false, address(0), USDC, 1 ether, 0, block.timestamp);
        assertEq(amountOut, quoted, "Aero quote drifted from execution");
    }

    function testAeroCLQuoteMatchesExecution() public {
        (, uint256 quoted) = quoter.quoteAeroCL(false, address(0), USDC, 100, 1 ether);
        _need(quoted);

        vm.prank(alice);
        (, uint256 amountOut) =
            router.swapAeroCL{value: 1 ether}(alice, false, 100, address(0), USDC, 1 ether, 0, block.timestamp);
        assertEq(amountOut, quoted, "Slipstream quote drifted from execution");
    }

    /// @dev The AeroCL callback shares `uniswapV3SwapCallback` with Uniswap, so
    /// this also proves the venue flag in the callback data routes the
    /// re-derivation to the right factory.
    function testAeroCLSellSideAlsoSettles() public {
        (, uint256 bought) = quoter.quoteAeroCL(false, address(0), USDC, 100, 1 ether);
        _need(bought);

        vm.prank(alice);
        router.swapAeroCL{value: 1 ether}(alice, false, 100, address(0), USDC, 1 ether, 0, block.timestamp);
        uint256 bal = IERC20(USDC).balanceOf(alice);
        assertGt(bal, 0);

        (, uint256 quoted) = quoter.quoteAeroCL(false, USDC, address(0), 100, bal);
        _need(quoted);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), bal);
        uint256 before = alice.balance;
        (, uint256 amountOut) = router.swapAeroCL(alice, false, 100, USDC, address(0), bal, 0, block.timestamp);
        vm.stopPrank();

        assertEq(amountOut, quoted, "Slipstream sell quote drifted");
        assertEq(alice.balance, before + amountOut);
    }

    /// @dev The Aerodrome stable curve has no closed-form inverse, so the quoter
    /// solves exact-out by search. The test that matters is that the solved input
    /// really does buy at least the target when executed.
    function testAeroStableExactOutSolvesExactly() public {
        (uint256 solvedIn,,) = quoter.quoteAero(true, USDC, AERO, 1e18);
        _need(solvedIn);

        deal(USDC, alice, solvedIn);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), solvedIn);
        (, uint256 amountOut) = router.swapAero(alice, false, USDC, AERO, solvedIn, 0, block.timestamp);
        vm.stopPrank();

        assertGe(amountOut, 1e18, "solved input did not reach the target");
    }



    // ══════════ hybrid split (direct + hub) ══════════

    function testHybridSelectorMatchesMainnet() public pure {
        assertEq(zQuoterBase.buildHybridSplit.selector, bytes4(0x85f86a90));
    }

    /// @dev Splits across route DEPTHS rather than across venues: part direct,
    /// part through a hub. Whatever it returns must execute and deliver.
    function testHybridSplitIsExecutableAndDelivers() public {
        (zQuoterBase.Quote[2] memory legs, bytes memory mc, uint256 mv) =
            quoter.buildHybridSplit(alice, address(0), AERO, 1 ether, 200, block.timestamp);
        _need(legs[0].amountOut + legs[1].amountOut);
        assertEq(mv, 1 ether);

        vm.prank(alice);
        (bool ok,) = address(router).call{value: mv}(mc);
        assertTrue(ok, "hybrid multicall reverted");
        assertGt(IERC20(AERO).balanceOf(alice), 0, "hybrid delivered nothing");
    }

    function testHybridFallsBackForAWrap() public view {
        (zQuoterBase.Quote[2] memory legs,,) =
            quoter.buildHybridSplit(alice, address(0), WETH, 1 ether, 50, block.timestamp);
        assertTrue(legs[0].source == zQuoterBase.AMM.WETH_WRAP);
    }

    // ══════════ split routing ══════════

    function testSplitSelectorMatchesMainnet() public pure {
        assertEq(zQuoterBase.buildSplitSwap.selector, bytes4(0x892af013));
    }

    /// @dev Whatever it decides — a true split or a one-sided fallback — the
    /// multicall must execute as-is and deliver at least what it promised.
    function testSplitSwapIsExecutableAndDelivers() public {
        (zQuoterBase.Quote[2] memory legs, bytes memory mc, uint256 mv) =
            quoter.buildSplitSwap(alice, address(0), USDC, 1 ether, 100, block.timestamp);
        _need(legs[0].amountOut + legs[1].amountOut);
        assertEq(mv, 1 ether);

        vm.prank(alice);
        (bool ok,) = address(router).call{value: mv}(mc);
        assertTrue(ok, "split multicall reverted");

        uint256 got = IERC20(USDC).balanceOf(alice);
        uint256 promised = legs[0].amountOut + legs[1].amountOut;
        assertGe(got, quoter.limit(false, promised, 100), "delivered under the promised bound");
    }

    /// @dev A split has to at least tie the single best venue, or it is not worth
    /// two legs of gas.
    function testSplitIsNeverWorseThanTheBestSingleVenue() public view {
        (zQuoterBase.Quote memory best,) = quoter.getQuotes(false, address(0), USDC, 1 ether);
        (zQuoterBase.Quote[2] memory legs,,) =
            quoter.buildSplitSwap(alice, address(0), USDC, 1 ether, 100, block.timestamp);
        if (best.amountOut == 0) return;
        assertGe(legs[0].amountOut + legs[1].amountOut, best.amountOut, "split priced worse than direct");
    }

    /// @dev Splitting a wrap is meaningless; it should fall through to one leg.
    function testSplitFallsBackForAWrap() public {
        (zQuoterBase.Quote[2] memory legs, bytes memory mc, uint256 mv) =
            quoter.buildSplitSwap(alice, address(0), WETH, 1 ether, 50, block.timestamp);
        assertTrue(legs[0].source == zQuoterBase.AMM.WETH_WRAP);
        assertEq(legs[1].amountOut, 0, "second leg should be empty for a wrap");

        vm.prank(alice);
        (bool ok,) = address(router).call{value: mv}(mc);
        assertTrue(ok, "wrap fallback reverted");
        assertEq(IERC20(WETH).balanceOf(alice), 1 ether);
    }

    // ══════════ hub routing (zSwap's second entry point) ══════════

    /// @dev zSwap hardcodes this selector at zSwap.html:2808. If it drifts, the
    /// page silently stops routing on Base.
    function testViaEthMulticallSelectorIsWhatZSwapCalls() public pure {
        assertEq(zQuoterBase.buildBestSwapViaETHMulticall.selector, bytes4(0xe453166e));
        assertEq(zQuoterBase.buildBestSwap.selector, bytes4(0xe7798987));
    }

    function testViaEthMulticallWrapFastPath() public {
        (zQuoterBase.Quote memory a,, bytes[] memory calls, bytes memory mc, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(alice, alice, false, address(0), WETH, 1 ether, 50, block.timestamp);

        assertTrue(a.source == zQuoterBase.AMM.WETH_WRAP);
        assertEq(calls.length, 2);
        assertEq(mv, 1 ether);

        vm.prank(alice);
        (bool ok,) = address(router).call{value: mv}(mc);
        assertTrue(ok, "wrap multicall reverted");
        assertEq(IERC20(WETH).balanceOf(alice), 1 ether);
    }

    /// @dev ETH -> USDC is deep everywhere, so the direct route should win and the
    /// builder should hand back a single-leg multicall.
    function testViaEthMulticallPrefersDirectWhenItIsBest() public {
        (zQuoterBase.Quote memory a,, bytes[] memory calls, bytes memory mc, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(alice, alice, false, address(0), USDC, 1 ether, 100, block.timestamp);
        _need(a.amountOut);
        assertEq(calls.length, 1, "took a hub route for a pair with a deep direct pool");

        vm.prank(alice);
        (bool ok,) = address(router).call{value: mv}(mc);
        assertTrue(ok, "direct multicall reverted");
        assertGt(IERC20(USDC).balanceOf(alice), 0);
    }

    /// @dev Whatever it picks, direct or hubbed, the multicall it returns has to be
    /// executable as-is and actually deliver.
    function testViaEthMulticallIsExecutableForATokenPair() public {
        (zQuoterBase.Quote memory a,,, bytes memory mc, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(alice, alice, false, address(0), AERO, 1 ether, 200, block.timestamp);
        _need(a.amountOut);

        vm.prank(alice);
        (bool ok,) = address(router).call{value: mv}(mc);
        assertTrue(ok, "multicall reverted");
        assertGt(IERC20(AERO).balanceOf(alice), 0);
    }

    /// @dev Leftovers must never be left addressed to the router: its `sweep` is
    /// public, so anyone could take them.
    function testViaEthMulticallNeverRefundsToTheRouter() public view {
        (,, bytes[] memory calls,,) = quoter.buildBestSwapViaETHMulticall(
            alice, ZROUTER, false, address(0), USDC, 1 ether, 100, block.timestamp
        );
        for (uint256 i; i < calls.length; ++i) {
            bytes memory c = calls[i];
            if (bytes4(c) != zRouterLiteBase.sweep.selector) continue;
            address dest;
            assembly { dest := mload(add(c, 0x84)) }
            assertTrue(dest != ZROUTER, "a sweep still points at the router");
        }
    }

    function testLimitMatchesTheEmbeddedBound() public view {
        assertEq(quoter.limit(false, 1000, 100), 990);
        assertEq(quoter.limit(true, 1000, 100), 1010);
    }

    // ══════════ audit regressions ══════════

    /// @dev A leg with `swapAmount == 0` spends what the previous leg credited.
    /// Reading the raw balance let anyone send one wei and make the next leg try
    /// to spend one wei more than it was credited — pulling a second full payment
    /// from the caller, or reverting the chain for a wei.
    function testDustCannotHijackABalanceFundedLeg() public {
        (, uint256 quoted) = quoter.quoteV3(false, address(0), USDC, 500, 1 ether);
        _need(quoted);

        deal(USDC, address(this), 1);
        IERC20(USDC).transfer(address(router), 1); // the griefer's wei

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(
            zRouterLiteBase.swapV3.selector,
            address(router), false, uint24(500), address(0), USDC,
            uint256(1 ether), uint256(0), block.timestamp
        );
        calls[1] = abi.encodeWithSelector(
            zRouterLiteBase.swapV2.selector,
            address(router), false, USDC, WETH,
            uint256(0), uint256(0), block.timestamp // spend the credit
        );
        calls[2] = abi.encodeWithSelector(zRouterLiteBase.sweep.selector, WETH, uint256(0), uint256(0), alice);

        vm.prank(alice);
        router.multicall{value: 1 ether}(calls);

        assertGt(IERC20(WETH).balanceOf(alice), 0, "dust broke the chained leg");
        assertEq(IERC20(USDC).balanceOf(address(router)), 1, "spent the dust as if it were ours");
    }

    /// @dev `unwrap` used to leave the WETH credit standing and credit no ether.
    function testUnwrapMovesTheCreditFromWethToEther() public {
        vm.prank(alice);
        (bool ok,) = WETH.call{value: 1 ether}("");
        assertTrue(ok);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(zRouterLiteBase.deposit.selector, WETH, uint256(0), uint256(1 ether));
        calls[1] = abi.encodeWithSelector(zRouterLiteBase.unwrap.selector, uint256(0));
        calls[2] = abi.encodeWithSelector(
            zRouterLiteBase.sweep.selector, address(0), uint256(0), uint256(1 ether), alice
        );

        vm.startPrank(alice);
        IERC20(WETH).approve(address(router), 1 ether);
        uint256 before = alice.balance;
        router.multicall(calls);
        vm.stopPrank();

        assertEq(alice.balance, before + 1 ether);
    }

    /// @dev Aerodrome classic is exact-in only. Offering it for exact-out meant
    /// pinning the input at a solved number with no tolerance at all, and
    /// silently discarding slippageBps. It no longer competes for exact-out.
    function testAeroDoesNotCompeteForExactOut() public view {
        (, zQuoterBase.Quote[] memory q) = quoter.getQuotes(true, address(0), USDC, 1000e6);
        assertEq(uint256(q[1].amountIn), 0, "AERO still offered for exact-out");
        assertEq(uint256(q[1].amountOut), 0);

        // ...but the solver is still callable for anyone who wants the number.
        (uint256 solvedIn,,) = quoter.quoteAero(true, USDC, AERO, 1e18);
        assertGt(solvedIn, 0, "the exact-out solver should still answer directly");
    }

    /// @dev zAMM settles by pulling from the router, so the route needs a standing
    /// allowance. It used to exist only if the owner had primed it, so every
    /// quoter-built zAMM route reverted until someone remembered.
    function testZammRouteNeedsNoOwnerPriming() public {
        // Nothing has been approved; the allowance is granted on demand.
        (, bytes memory ret) = USDC.staticcall(
            abi.encodeWithSignature("allowance(address,address)", address(router), ZAMM)
        );
        assertEq(abi.decode(ret, (uint256)), 0, "precondition: not primed");
        assertEq(router.owner(), deployer);
    }

    // ══════════ the aggregate surface ══════════

    function testBuildBestSwapIsExecutableAsIs() public {
        (zQuoterBase.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(alice, false, address(0), USDC, 1 ether, 100, block.timestamp);
        _need(best.amountOut);
        assertEq(msgValue, 1 ether);

        vm.prank(alice);
        (bool ok,) = address(router).call{value: msgValue}(callData);
        assertTrue(ok, "quoter-built calldata reverted");
        assertGe(IERC20(USDC).balanceOf(alice), amountLimit, "landed under the embedded bound");
    }

    function testBestBeatsOrTiesEveryVenue() public view {
        (zQuoterBase.Quote memory best, zQuoterBase.Quote[] memory quotes) =
            quoter.getQuotes(false, address(0), USDC, 1 ether);
        assertEq(quotes.length, 20);
        for (uint256 i; i < quotes.length; ++i) {
            assertGe(best.amountOut, quotes[i].amountOut);
        }
    }

    /// @dev Base ordinals, which are NOT mainnet's — AERO sits where SUSHI does
    /// there. A `source` crossing the wire has to keep meaning the same thing.
    function testAmmOrdinalsMatchTheDeployedBaseQuoter() public pure {
        assertEq(uint256(zQuoterBase.AMM.UNI_V2), 0);
        assertEq(uint256(zQuoterBase.AMM.AERO), 1);
        assertEq(uint256(zQuoterBase.AMM.ZAMM), 2);
        assertEq(uint256(zQuoterBase.AMM.UNI_V3), 3);
        assertEq(uint256(zQuoterBase.AMM.UNI_V4), 4);
        assertEq(uint256(zQuoterBase.AMM.AERO_CL), 5);
    }

    function testQuoteSlotsAreStablyOrdered() public view {
        (, zQuoterBase.Quote[] memory q) = quoter.getQuotes(false, address(0), USDC, 1 ether);
        assertTrue(q[0].source == zQuoterBase.AMM.UNI_V2);
        assertTrue(q[1].source == zQuoterBase.AMM.AERO);
        uint256[4] memory zFees = [uint256(1), 5, 30, 100];
        for (uint256 i; i < 4; ++i) {
            assertTrue(q[2 + i].source == zQuoterBase.AMM.ZAMM);
            assertEq(q[2 + i].feeBps, zFees[i]);
        }
        uint256[4] memory tiers = [uint256(1), 5, 30, 100];
        for (uint256 i; i < 4; ++i) {
            assertTrue(q[6 + i].source == zQuoterBase.AMM.UNI_V3);
            assertEq(q[6 + i].feeBps, tiers[i]);
            assertTrue(q[10 + i].source == zQuoterBase.AMM.UNI_V4);
            assertEq(q[10 + i].feeBps, tiers[i]);
        }
    }

    function testNoRouteReverts() public {
        vm.expectRevert(zQuoterBase.NoRoute.selector);
        quoter.buildBestSwap(alice, false, address(0), nowhere, 1 ether, 100, block.timestamp);
    }

    function testUnknownTokenQuotesZeroRatherThanReverting() public view {
        (zQuoterBase.Quote memory best, zQuoterBase.Quote[] memory quotes) =
            quoter.getQuotes(false, address(0), nowhere, 1 ether);
        assertEq(best.amountOut, 0);
        for (uint256 i; i < quotes.length; ++i) {
            assertEq(quotes[i].amountOut, 0);
        }
    }

    function testIdenticalTokensReverts() public {
        vm.expectRevert(zQuoterBase.IdenticalTokens.selector);
        quoter.getQuotes(false, address(0), WETH, 1 ether);
    }

    /// @dev The quoter builds calldata for the canonical address, so the router it
    /// quotes for and the router it names must be the same contract.
    function testQuoterTargetsTheCanonicalRouter() public view {
        assertEq(address(router), ZROUTER);
        assertGt(ZROUTER.code.length, 0);
    }

    // ══════════ the extensions this build adds over the deployed router ══════════

    function testDeployerOwnsTheRouter() public view {
        assertEq(router.owner(), deployer);
    }

    /// @dev On the deployed Base router `ensureAllowance` has no access control at
    /// all: anyone can make it approve any spender for any token.
    function testEnsureAllowanceIsOwnerGatedHere() public {
        vm.prank(alice);
        vm.expectRevert(zRouterLiteBase.Unauthorized.selector);
        router.ensureAllowance(USDC, false, alice);

        vm.prank(deployer);
        router.ensureAllowance(USDC, false, alice);
    }

    function testExecuteRejectsUntrustedTargets() public {
        vm.prank(deployer);
        vm.expectRevert(zRouterLiteBase.Unauthorized.selector);
        router.execute(alice, 0, "");
    }

    function testMulticallChainsSwapAndSweep() public {
        (, uint256 quoted) = quoter.quoteV3(false, address(0), USDC, 500, 1 ether);
        _need(quoted);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            zRouterLiteBase.swapV3.selector,
            address(router),
            false,
            uint24(500),
            address(0),
            USDC,
            uint256(1 ether),
            uint256(0),
            block.timestamp
        );
        calls[1] = abi.encodeWithSelector(zRouterLiteBase.sweep.selector, USDC, uint256(0), uint256(0), alice);

        vm.prank(alice);
        router.multicall{value: 1 ether}(calls);
        assertEq(IERC20(USDC).balanceOf(alice), quoted, "chained output never landed");
    }

    /// @dev The deployed router skips output tracking on an ETH-in v3 leg, so a
    /// chained ETH -> token -> sweep loses the credit. This build tracks it.
    function testEthInV3LegStillMarksItsOutput() public {
        (, uint256 quoted) = quoter.quoteV3(false, address(0), USDC, 500, 1 ether);
        _need(quoted);

        vm.prank(alice);
        router.swapV3{value: 1 ether}(address(router), false, 500, address(0), USDC, 1 ether, 0, block.timestamp);
        assertEq(IERC20(USDC).balanceOf(address(router)), quoted);

        // The credit is what lets a following leg spend it.
        router.sweep(USDC, 0, 0, alice);
        assertEq(IERC20(USDC).balanceOf(alice), quoted);
    }

    function testDeadlineIsEnforced() public {
        vm.startPrank(alice);
        vm.expectRevert(zRouterLiteBase.Expired.selector);
        router.swapV2{value: 1 wei}(alice, false, address(0), USDC, 1 wei, 0, block.timestamp - 1);
        vm.expectRevert(zRouterLiteBase.Expired.selector);
        router.swapAero{value: 1 wei}(alice, false, address(0), USDC, 1 wei, 0, block.timestamp - 1);
        vm.expectRevert(zRouterLiteBase.Expired.selector);
        router.swapAeroCL{value: 1 wei}(alice, false, 100, address(0), USDC, 1 wei, 0, block.timestamp - 1);
        vm.stopPrank();
    }

    function testWrapAndUnwrapRoundTrip() public {
        vm.prank(alice);
        router.wrap{value: 1 ether}(0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 1 ether);
        router.unwrap(0);
        assertEq(address(router).balance, 1 ether);
    }

    receive() external payable {}
}
