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
        factory = new PrecisionPoolFactory(EXEC);
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
        return abi.encodeCall(
            PrecisionPoolFactory.executePrefundedSwap, (pool, to, tokenIn, amountIn, uint256(0), to)
        );
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
                abi.encodeCall(PrecisionPoolFactory.checkpoint, (WBTC))
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
                abi.encodeCall(PrecisionPoolFactory.checkpoint, (USDC))
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
             abi.encodeCall(PrecisionPoolFactory.checkpoint, (WBTC)))
        );
        calls[1] = abi.encodeCall(
            ISnwap.snwap,
            (WBTC, legs[0].amountIn, ZROUTER, USDC, uint256(0), address(factory),
             _swapData(legs[0].pool, WBTC, legs[0].amountIn, ZROUTER))
        );
        calls[2] = abi.encodeCall(
            ISnwap.snwap,
            (address(0), uint256(0), user, address(0), uint256(0), address(factory),
             abi.encodeCall(PrecisionPoolFactory.checkpoint, (USDC)))
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
            abi.encodeCall(PrecisionRoute.route, (pools, address(0), 1 ether, 0, user))
        );

        emit log_named_uint("WBTC out", out);
        assertGt(out, 0, "route delivered nothing");
        assertEq(IERC20(WBTC).balanceOf(user) - before, out, "recipient got the output");
        // The executor must never retain value between routes.
        assertEq(address(router).balance, 0, "kept ETH");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "kept the intermediate");
        assertEq(IERC20(WBTC).balanceOf(address(router)), 0, "kept the output");
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
            abi.encodeCall(PrecisionRoute.route, (pools, address(0), 1 ether, 0, user))
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
            abi.encodeCall(PrecisionRoute.route, (pools, address(0), 1 ether, 0, user))
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
}
