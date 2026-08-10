// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";
import {PrecisionRoute} from "../src/pools/PrecisionRoute.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ISnwap {
    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external payable returns (uint256 amountOut);
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}

/// @dev Two factory pools sharing an intermediate asset, chained in one
/// transaction through the LIVE router. zQuoter does not model precision pools
/// yet, so zSwap will compose routes like this itself - which makes it worth
/// pinning that the router's own chaining actually carries an intermediate
/// between two of our pools.
contract PrecisionPoolMultihopTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant EXEC = 0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db;

    PrecisionPoolFactory factory;
    PrecisionPoolLens lens;
    PrecisionPool ethUsdc; // ETH  <-> USDC
    PrecisionPool usdcWbtc; // USDC <-> WBTC

    address lp = address(0xC11);
    address user = address(0xBEEF);

    function setUp() public {
        factory = new PrecisionPoolFactory(EXEC, type(PrecisionPool).creationCode);
        lens = new PrecisionPoolLens(factory);

        deal(USDC, lp, 50_000_000e6);
        deal(WBTC, lp, 1_000e8);
        deal(USDC, user, 1_000_000e6);
        vm.deal(lp, 10_000 ether);
        vm.deal(user, 1_000 ether);

        vm.startPrank(lp);
        IERC20(USDC).approve(address(factory), type(uint256).max);
        IERC20(WBTC).approve(address(factory), type(uint256).max);

        // ETH/USDC around $2000, decimals folded in.
        (address a,,,) = factory.createAndSeed{value: 1_000 ether}(
            _mkt(address(0), USDC, 42426406871192, 46904157598234),
            44721359549995, 1_000 ether, 10_000_000e6, 0, lp
        );
        ethUsdc = PrecisionPool(payable(a));

        // WBTC sorts BELOW USDC, so WBTC is token0 here. Raw price is USDC
        // (6dec) per WBTC (8dec): ~60,000e6 / 1e8 = 6e2, sqrt ~ 24.5, scaled
        // 1e18. Band kept wide so the hop always has depth.
        (address b,,,) = factory.createAndSeed(
            _mkt(WBTC, USDC, 20_000_000_000_000_000_000, 30_000_000_000_000_000_000),
            24_494_897_427_831_780_982, 100e8, 10_000_000e6, 0, lp
        );
        usdcWbtc = PrecisionPool(payable(b));
        vm.stopPrank();

        vm.startPrank(user);
        IERC20(USDC).approve(ZROUTER, type(uint256).max);
        vm.stopPrank();
    }

    function _mkt(address t0, address t1, uint256 low, uint256 high)
        internal
        pure
        returns (PrecisionPoolFactory.Market memory)
    {
        return PrecisionPoolFactory.Market({
            token0: t0,
            token1: t1,
            sqrtPLow: low,
            sqrtPHigh: high,
            fee: 3000,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    function test_SeedsBothLegsOfTheRoute() public view {
        assertGt(ethUsdc.totalSupply(), 0, "leg 1 seeded");
        assertGt(usdcWbtc.totalSupply(), 0, "leg 2 seeded");
        assertEq(usdcWbtc.token1(), USDC, "shared intermediate is token1 of leg 2");
    }

    function _swapData(address pool, address tokenIn, uint256 amountIn, address to)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(PrecisionPoolFactory.executePrefundedSwap, (_route(pool, tokenIn, amountIn, to)));
    }

    /// @dev The settlement a prefunded route commits to at checkpoint.
    function _route(address pool, address tokenIn, uint256 amountIn, address to)
        internal
        pure
        returns (PrecisionPoolFactory.Route memory)
    {
        return PrecisionPoolFactory.Route({
            pool: pool,
            originator: to,
            tokenIn: tokenIn,
            amountIn: amountIn,
            minOut: 0,
            to: to,
            refundTo: to
        });
    }

    /// @dev WBTC -> USDC -> ETH across two factory pools in ONE transaction.
    ///
    /// Deliberately all-ERC-20 on the way in. zRouter's multicall forwards the
    /// SAME msg.value to every leg, so a value-bearing entry alongside any
    /// other snwap entry double-spends and reverts OutOfFunds. Routes that
    /// start in native ETH must therefore either be single-leg or wrap first -
    /// worth knowing before zSwap composes these.
    ///
    /// The intermediate settles to the ROUTER, and the next leg spends the
    /// router's own balance by passing amountIn = 0, which is snwap's chaining
    /// path.
    function test_MultihopWbtcToUsdcToEth() public {
        deal(WBTC, user, 10e8);
        vm.prank(user);
        IERC20(WBTC).approve(ZROUTER, type(uint256).max);

        uint256 amountIn = 1e8; // 1 WBTC
        uint256 leg1 = lens.quoteFor(address(usdcWbtc), address(factory), WBTC, amountIn);
        assertGt(leg1, 0, "leg 1 must quote");

        uint256 before = user.balance;

        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(
            ISnwap.snwap,
            (
                address(0), uint256(0), user, address(0), uint256(0), address(factory),
                abi.encodeCall(
                    PrecisionPoolFactory.checkpoint, (_route(address(usdcWbtc), WBTC, amountIn, ZROUTER))
                )
            )
        );
        // Leg 1: WBTC in, USDC parked at the router.
        calls[1] = abi.encodeCall(
            ISnwap.snwap,
            (
                WBTC, amountIn, ZROUTER, USDC, uint256(0), address(factory),
                _swapData(address(usdcWbtc), WBTC, amountIn, ZROUTER)
            )
        );
        calls[2] = abi.encodeCall(
            ISnwap.snwap,
            (
                address(0), uint256(0), user, address(0), uint256(0), address(factory),
                abi.encodeCall(
                    PrecisionPoolFactory.checkpoint, (_route(address(ethUsdc), USDC, leg1 - 1, user))
                )
            )
        );
        // Leg 2: spend the router's USDC, deliver ETH to the user.
        calls[3] = abi.encodeCall(
            ISnwap.snwap,
            (
                USDC, uint256(0), user, address(0), uint256(0), address(factory),
                // snwap's chaining path forwards `balance - 1`, retaining a
                // wei to keep the slot warm. The factory settles an EXACT
                // declared amount, so the two only agree if the caller
                // subtracts that wei. Getting it wrong reverts BadCheckpoint
                // rather than silently mis-settling.
                _swapData(address(ethUsdc), USDC, leg1 - 1, user)
            )
        );

        vm.prank(user);
        ISnwap(ZROUTER).multicall(calls);

        uint256 got = user.balance - before;
        emit log_named_uint("leg1 USDC", leg1);
        emit log_named_uint("ETH out  ", got);
        assertGt(got, 0, "multihop delivered nothing");
        // snwap leaves exactly one wei behind on purpose, to keep the storage
        // slot warm for the next route. Anything above that would be a genuinely
        // stranded intermediate.
        assertLe(IERC20(USDC).balanceOf(ZROUTER), 1, "intermediate stranded at the router");
    }

    /// @dev The lens must predict the whole route, including the retained-wei
    /// offset on every chained leg. If it cannot, zSwap has to rederive that
    /// rule itself and will eventually get it wrong.
    function test_QuoteRoutePredictsTheChainedFillExactly() public {
        deal(WBTC, user, 10e8);
        vm.prank(user);
        IERC20(WBTC).approve(ZROUTER, type(uint256).max);

        address[] memory route = new address[](2);
        route[0] = address(usdcWbtc);
        route[1] = address(ethUsdc);

        (PrecisionPoolLens.Leg[] memory legs, uint256 predicted) =
            lens.quoteRoute(route, address(factory), WBTC, 1e8);

        assertEq(legs.length, 2, "both hops quoted");
        assertEq(legs[0].tokenOut, USDC, "intermediate identified");
        assertEq(legs[1].tokenOut, address(0), "terminal asset identified");
        // The second leg is funded from the router, so its declared input is
        // the first leg's output less the retained wei.
        assertEq(legs[1].amountIn, legs[0].amountOut - 1, "chained offset applied");

        uint256 before = user.balance;
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(
            ISnwap.snwap,
            (address(0), uint256(0), user, address(0), uint256(0), address(factory),
             abi.encodeCall(
                 PrecisionPoolFactory.checkpoint, (_route(legs[0].pool, WBTC, legs[0].amountIn, ZROUTER))
             ))
        );
        calls[1] = abi.encodeCall(
            ISnwap.snwap,
            (WBTC, legs[0].amountIn, ZROUTER, USDC, uint256(0), address(factory),
             _swapData(legs[0].pool, WBTC, legs[0].amountIn, ZROUTER))
        );
        calls[2] = abi.encodeCall(
            ISnwap.snwap,
            (address(0), uint256(0), user, address(0), uint256(0), address(factory),
             abi.encodeCall(
                 PrecisionPoolFactory.checkpoint, (_route(legs[1].pool, USDC, legs[1].amountIn, user))
             ))
        );
        calls[3] = abi.encodeCall(
            ISnwap.snwap,
            (USDC, uint256(0), user, address(0), uint256(0), address(factory),
             _swapData(legs[1].pool, USDC, legs[1].amountIn, user))
        );

        vm.prank(user);
        ISnwap(ZROUTER).multicall(calls);

        assertEq(user.balance - before, predicted, "route quote was exact end to end");
    }

    /// @dev The whole point of the route executor: ONE snwap leg, so the
    /// value-forwarding limitation never applies and no off-by-one has to be
    /// predicted. This exact trade - native ETH in, two hops - could not be
    /// expressed as multiple snwap legs at all.
    function test_RouteExecutorDoesEthInMultihopInOneLeg() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);

        address[] memory pools = new address[](2);
        pools[0] = address(ethUsdc);   // ETH  -> USDC
        pools[1] = address(usdcWbtc);  // USDC -> WBTC

        uint256 before = IERC20(WBTC).balanceOf(user);

        vm.prank(user);
        uint256 out = ISnwap(ZROUTER).snwap{value: 1 ether}(
            address(0), 1 ether, user, WBTC, 0, address(router),
            abi.encodeCall(PrecisionRoute.route, (pools, address(0), WBTC, 1 ether, 0, user))
        );

        emit log_named_uint("WBTC out", out);
        assertGt(out, 0, "route delivered nothing");
        assertEq(IERC20(WBTC).balanceOf(user) - before, out, "recipient got the output");
        // The executor must never retain value between routes.
        assertEq(address(router).balance, 0, "kept ETH");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "kept the intermediate");
        assertEq(IERC20(WBTC).balanceOf(address(router)), 0, "kept the output");
    }

    /// @dev The ERC-20 side of the route executor, which native input never
    /// exercises: checkpoint, fund, walk the hops. The checkpoint commits to
    /// the exact call that will spend it, so the funding cannot be diverted by
    /// anything that gets control while it is in flight - the executor is
    /// public and holds no lock across that gap.
    function test_RouteExecutorRunsACheckpointedErc20Route() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);
        deal(WBTC, user, 10e8);

        address[] memory pools = new address[](2);
        pools[0] = address(usdcWbtc); // WBTC -> USDC
        pools[1] = address(ethUsdc);  // USDC -> ETH

        uint256 amountIn = 1e8;
        bytes memory call_ = abi.encodeCall(PrecisionRoute.route, (pools, WBTC, address(0), amountIn, 0, user));
        uint256 before = user.balance;

        vm.prank(EXEC);
        router.checkpoint(WBTC, keccak256(call_), address(this));

        vm.prank(user);
        IERC20(WBTC).transfer(address(router), amountIn);

        // A different route over the same funding is refused outright.
        address[] memory theirs = new address[](1);
        theirs[0] = address(usdcWbtc);
        vm.prank(EXEC);
        (bool ok, bytes memory err) = address(router).call(
            abi.encodeCall(PrecisionRoute.route, (theirs, WBTC, USDC, amountIn, 0, address(0xBAD)))
        );
        assertFalse(ok, "an uncommitted route spent the funding");
        assertEq(bytes4(err), PrecisionRoute.IntentMismatch.selector, "wrong rejection");

        vm.prank(EXEC);
        (ok,) = address(router).call(call_);
        assertTrue(ok, "the committed route was refused");

        assertGt(user.balance - before, 0, "route delivered nothing");
        assertEq(IERC20(WBTC).balanceOf(address(router)), 0, "kept the input");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "kept the intermediate");
        assertEq(address(router).balance, 0, "kept the output");
    }

    /// @dev Calldata cannot point a hop at something the factory never made.
    function test_RouteExecutorRejectsUnknownPools() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);
        address[] memory pools = new address[](1);
        pools[0] = address(0xDEAD);

        // Low-level so the revert is observed below the cheatcode's depth.
        vm.deal(EXEC, 2 ether);
        vm.prank(EXEC);
        (bool ok, bytes memory err) = address(router).call{value: 1 ether}(
            abi.encodeCall(PrecisionRoute.route, (pools, address(0), USDC, 1 ether, 0, user))
        );
        assertFalse(ok, "unknown pool was accepted");
        assertEq(bytes4(err), PrecisionRoute.NoPool.selector, "wrong rejection");
    }

    function test_RouteExecutorRefusesUntrustedCallers() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);
        address[] memory pools = new address[](1);
        pools[0] = address(ethUsdc);

        vm.deal(user, 2 ether);
        vm.prank(user);
        (bool ok, bytes memory err) = address(router).call{value: 1 ether}(
            abi.encodeCall(PrecisionRoute.route, (pools, address(0), USDC, 1 ether, 0, user))
        );
        assertFalse(ok, "untrusted caller was accepted");
        assertEq(bytes4(err), PrecisionRoute.NotExecutor.selector, "wrong rejection");
    }

    /// @dev One-sided entry: arrive holding only ETH, leave holding LP shares,
    /// in a single transaction. Without this a user swaps, reads what they got,
    /// and deposits separately - with the price moving in between.
    function test_ZapInFromOneAssetMintsLpSharesInOneTransaction() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);

        uint256 before = ethUsdc.balanceOf(user);
        uint256 ethBefore = user.balance;

        // Roughly half swapped; the split need not be exact because whatever
        // the pool cannot take at its ratio comes back.
        vm.prank(user);
        ISnwap(ZROUTER).snwap{value: 2 ether}(
            address(0), 2 ether, user, address(ethUsdc), 0, address(router),
            abi.encodeCall(PrecisionRoute.zapIn, (address(ethUsdc), address(0), 2 ether, 1 ether, 0, user))
        );

        assertGt(ethUsdc.balanceOf(user) - before, 0, "no LP shares minted");
        assertLt(user.balance, ethBefore, "input was consumed");
        // Nothing may be retained between routes.
        assertEq(address(router).balance, 0, "kept ETH");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "kept USDC");
        assertEq(ethUsdc.balanceOf(address(router)), 0, "kept LP shares");
    }

    /// @dev A route sized past what the tightest band on the path can take.
    /// `route` refuses it outright - correct, but it is the stale-quote failure
    /// `swapUpTo` exists to remove, and it is worse over a path because any one
    /// of N hops can trigger it. `routeUpTo` clamps instead, and the remainder
    /// comes back as the INPUT token: the search runs over the whole route, so
    /// no hop is ever partially filled and no intermediate is ever stranded.
    function test_RouteUpToClampsAtTheFrontAndRefundsTheInputToken() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);
        vm.deal(EXEC, 20_000 ether);

        address[] memory pools = new address[](2);
        pools[0] = address(ethUsdc);
        pools[1] = address(usdcWbtc);

        uint256 huge = 5_000 ether;

        // All-or-nothing refuses the whole size.
        vm.prank(EXEC);
        vm.expectRevert();
        router.route{value: huge}(pools, address(0), WBTC, huge, 0, user);

        uint256 wbtcBefore = IERC20(WBTC).balanceOf(user);
        uint256 refundBefore = address(0xFEE1).balance;

        vm.prank(EXEC);
        (uint256 out, uint256 consumed) =
            router.routeUpTo{value: huge}(pools, address(0), WBTC, huge, 0, user, address(0xFEE1));

        assertGt(out, 0, "delivered nothing");
        assertGt(consumed, 0, "clamped to nothing");
        assertLt(consumed, huge, "did not clamp at all");
        assertEq(IERC20(WBTC).balanceOf(user) - wbtcBefore, out, "recipient got the output");

        // The remainder is the caller's own input token, never an intermediate.
        assertEq(address(0xFEE1).balance - refundBefore, huge - consumed, "remainder not refunded");
        assertEq(IERC20(USDC).balanceOf(address(0xFEE1)), 0, "refunded an intermediate");

        assertEq(address(router).balance, 0, "kept ETH");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "kept the intermediate");
        assertEq(IERC20(WBTC).balanceOf(address(router)), 0, "kept the output");
    }

    /// @dev The clamp must be MAXIMAL, not merely safe - a search that is
    /// conservative by even one unit silently underfills every route. Replay
    /// the same state: the size it chose must execute all-or-nothing, and one
    /// unit more must not.
    function test_RouteUpToFindsTheLargestSizeThatFits() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);
        vm.deal(EXEC, 20_000 ether);

        address[] memory pools = new address[](2);
        pools[0] = address(ethUsdc);
        pools[1] = address(usdcWbtc);

        uint256 huge = 5_000 ether;
        uint256 snap = vm.snapshotState();

        vm.prank(EXEC);
        (, uint256 consumed) = router.routeUpTo{value: huge}(pools, address(0), WBTC, huge, 0, user, address(0xFEE1));
        assertLt(consumed, huge, "nothing to prove: it fit whole");

        vm.revertToState(snap);

        // Exactly the chosen size clears the path as a plain all-or-nothing route.
        vm.prank(EXEC);
        uint256 out = router.route{value: consumed}(pools, address(0), WBTC, consumed, 0, user);
        assertGt(out, 0, "the chosen size did not execute");

        vm.revertToState(snap);

        // One unit more does not.
        vm.prank(EXEC);
        vm.expectRevert();
        router.route{value: consumed + 1}(pools, address(0), WBTC, consumed + 1, 0, user);
    }

    /// @dev A route that fits whole must not be clamped, and must cost only the
    /// one probe that establishes it - no refund, no search.
    function test_RouteUpToConsumesEverythingWhenTheRouteFits() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);
        vm.deal(EXEC, 100 ether);

        address[] memory pools = new address[](2);
        pools[0] = address(ethUsdc);
        pools[1] = address(usdcWbtc);

        uint256 refundBefore = address(0xFEE1).balance;

        vm.prank(EXEC);
        (uint256 out, uint256 consumed) =
            router.routeUpTo{value: 1 ether}(pools, address(0), WBTC, 1 ether, 0, user, address(0xFEE1));

        assertEq(consumed, 1 ether, "clamped a route that fits");
        assertGt(out, 0, "delivered nothing");
        assertEq(address(0xFEE1).balance, refundBefore, "refunded from a full fill");
    }

    /// @dev `zapIn` returns what its own deposit could not take at the pool's
    /// ratio - NOT whatever happens to be sitting here. The trailing sweep used
    /// to send the raw balance, which is outside the checkpoint entirely: the
    /// checkpoint bounds what may be SPENT, so an unbounded sweep hands a caller
    /// any in-flight funding or mid-route intermediate belonging to somebody
    /// else. The executor is public, so "somebody else's zap" is a call anyone
    /// can make. Anything resting must still be resting afterwards.
    function test_ZapInSweepsOnlyItsOwnLeftoversNotRestingBalances() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);

        // Stand in for a victim's funding in flight, or an intermediate resting
        // between two hops of a route that is still running.
        deal(USDC, address(router), 1_000e6);
        vm.deal(address(router), 5 ether);

        // A perfectly ordinary zap, by an unrelated caller, to their own address.
        // It legitimately receives its OWN leftovers, so the invariant that
        // matters is on the other side: what was resting is still resting.
        vm.prank(user);
        ISnwap(ZROUTER).snwap{value: 2 ether}(
            address(0), 2 ether, user, address(ethUsdc), 0, address(router),
            abi.encodeCall(PrecisionRoute.zapIn, (address(ethUsdc), address(0), 2 ether, 1 ether, 0, address(0xDEAD)))
        );

        assertGt(ethUsdc.balanceOf(address(0xDEAD)), 0, "zap did not run");
        assertEq(IERC20(USDC).balanceOf(address(router)), 1_000e6, "swept resting USDC");
        assertEq(address(router).balance, 5 ether, "swept resting ETH");
    }

    /// @dev The gap between `checkpoint` and the call that spends it is the
    /// dangerous one: the input arrives there, and a callback-capable token gets
    /// control while it is resting. A native-funded entry consumes no checkpoint,
    /// so nothing in its own arguments constrains it - the route lock is what
    /// keeps it from running during someone else's funding.
    function test_NativeEntryIsRefusedWhileAnotherRouteIsOpen() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);
        vm.deal(EXEC, 10 ether);

        address[] memory pools = new address[](1);
        pools[0] = address(ethUsdc);
        bytes memory call_ = abi.encodeCall(PrecisionRoute.route, (pools, WBTC, USDC, 1e8, 0, user));

        vm.prank(EXEC);
        router.checkpoint(WBTC, keccak256(call_), address(this));

        // The victim's funding is now in flight. Anyone can reach these through
        // the public executor.
        vm.prank(EXEC);
        vm.expectRevert(PrecisionRoute.Reentrancy.selector);
        router.zapIn{value: 1 ether}(address(ethUsdc), address(0), 1 ether, 0, 0, address(0xDEAD));

        vm.prank(EXEC);
        vm.expectRevert(PrecisionRoute.Reentrancy.selector);
        router.route{value: 1 ether}(pools, address(0), USDC, 1 ether, 0, address(0xDEAD));

        // And a second checkpoint cannot be opened alongside the first.
        vm.prank(EXEC);
        vm.expectRevert(PrecisionRoute.Reentrancy.selector);
        router.checkpoint(USDC, keccak256("whatever"), address(this));
    }

    function test_ZapInRefusesUnknownPools() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);
        vm.deal(EXEC, 2 ether);
        vm.prank(EXEC);
        (bool ok, bytes memory err) = address(router).call{value: 1 ether}(
            abi.encodeCall(PrecisionRoute.zapIn, (address(0xDEAD), address(0), 1 ether, 0, 0, user))
        );
        assertFalse(ok);
        assertEq(bytes4(err), PrecisionRoute.NoPool.selector);
    }

    /// @dev `minOut` is denominated in the output token, but before `tokenOut`
    /// existed the output token was IMPLICIT in `pools` - so a reordered or
    /// off-by-one path delivered a different asset and the slippage check
    /// silently compared the wrong units. Here the path ends in WBTC (8
    /// decimals) while the caller believes it ends in USDC (6): a `minOut` sized
    /// for USDC clears trivially against a WBTC amount, and without the check
    /// the trade settles. Naming the output is what turns that into a revert.
    function test_RouteRejectsAPathThatEndsInADifferentTokenThanNamed() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);
        vm.deal(EXEC, 10 ether);

        address[] memory pools = new address[](2);
        pools[0] = address(ethUsdc); // ETH  -> USDC
        pools[1] = address(usdcWbtc); // USDC -> WBTC

        // The honest call: the path really does end in WBTC.
        uint256 snap = vm.snapshotState();
        vm.prank(EXEC);
        uint256 out = router.route{value: 1 ether}(pools, address(0), WBTC, 1 ether, 0, user);
        assertGt(out, 0, "the correct declaration must still route");
        vm.revertToState(snap);

        // The same path declared as ending in USDC. `minOut` is set to a figure
        // that is real slippage protection in USDC units and no protection at
        // all against a WBTC amount, which is the whole failure mode.
        vm.prank(EXEC);
        vm.expectRevert(PrecisionRoute.WrongTokenOut.selector);
        router.route{value: 1 ether}(pools, address(0), USDC, 1 ether, 1_000e6, user);

        assertEq(address(router).balance, 0, "kept ETH");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "kept the intermediate");
    }

    /// @dev Same guard on the clamping entry point, which needs it more: a
    /// partial fill already returns less than asked, so a wrong-asset delivery
    /// is even easier to mistake for ordinary slippage.
    function test_RouteUpToRejectsAPathThatEndsInADifferentTokenThanNamed() public {
        PrecisionRoute router = new PrecisionRoute(factory, EXEC);
        vm.deal(EXEC, 10 ether);

        address[] memory pools = new address[](2);
        pools[0] = address(ethUsdc);
        pools[1] = address(usdcWbtc);

        vm.prank(EXEC);
        vm.expectRevert(PrecisionRoute.WrongTokenOut.selector);
        router.routeUpTo{value: 1 ether}(pools, address(0), USDC, 1 ether, 0, user, user);
    }
}
