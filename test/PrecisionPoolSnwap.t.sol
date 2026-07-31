// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";
import {PrecisionZap} from "../src/pools/PrecisionZap.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ISnwap {
    function snwapMulti(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address[] calldata tokensOut,
        uint256[] calldata amountsOutMin,
        address executor,
        bytes calldata executorData
    ) external payable returns (uint256[] memory amountsOut);

    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external payable returns (uint256 amountOut);

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}

/// @dev The assumption the whole composition story rests on: that the LIVE
/// zRouter can drive a precision pool with no adapter and no changes to it.
/// Everything else - routing beside the metadex, sequencing with orderbooks -
/// is built on this working, so it is worth pinning against the deployed
/// router rather than a mock.
///
/// The factory is the executor: snwap funds it and calls its exact-settlement
/// entry point, which forwards only the stated amount to the pool. The pool
/// never treats an arbitrary balance surplus as a trade.
contract PrecisionPoolSnwapTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

    /// @dev snwap dispatches through zRouter's SafeExecutor, which holds no
    ///      approvals, so THAT is the address a pool factory sees as its
    ///      caller. Binding the factory to zRouter itself would compile, pass
    ///      an interface review, and then fail every routed swap.
    address constant ZROUTER_SAFE_EXECUTOR = 0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db;

    // $1800-$2200, seeded at $2000, decimals already folded in.
    uint256 constant SQRT_LOW = 42426406871192;
    uint256 constant SQRT_MID = 44721359549995;
    uint256 constant SQRT_HIGH = 46904157598234;
    uint256 constant FEE = 500; // 0.05% in pips

    PrecisionPoolFactory factory;
    PrecisionPoolLens lens;
    PrecisionPool pool;

    address lp = address(0xC11);
    address user = address(0xBEEF);

    function _mkt(uint256 fee_, address hook_) internal pure returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(0),
            token1: USDC,
            sqrtPLow: SQRT_LOW,
            sqrtPHigh: SQRT_HIGH,
            fee: fee_,
            hook: hook_,
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    function setUp() public {
        factory = new PrecisionPoolFactory(ZROUTER_SAFE_EXECUTOR);
        lens = new PrecisionPoolLens(factory);

        deal(USDC, lp, 1_000_000e6);
        vm.deal(lp, 100 ether);
        vm.deal(user, 100 ether);
        deal(USDC, user, 100_000e6);

        vm.startPrank(lp);
        IERC20(USDC).approve(address(factory), type(uint256).max);
        (address p,,,) =
            factory.createAndSeed{value: 20 ether}(_mkt(FEE, address(0)), SQRT_MID, 20 ether, 60_000e6, 0, lp);
        vm.stopPrank();
        pool = PrecisionPool(payable(p));

        vm.prank(user);
        IERC20(USDC).approve(ZROUTER, type(uint256).max);
    }

    function _swapData(address tokenIn, uint256 amountIn, address to) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            PrecisionPoolFactory.executePrefundedSwap.selector, address(pool), tokenIn, amountIn, uint256(0), to
        );
    }

    /// @dev zRouter's SafeExecutor is public, so an ERC-20 precision route
    /// checkpoints the factory in an earlier entry of the same multicall. The
    /// second entry then transfers the input and consumes exactly that delta.
    function _checkpointedErc20Snwap(address tokenIn, uint256 amountIn, address to, address tokenOut)
        internal
        returns (uint256 amountOut)
    {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            ISnwap.snwap,
            (
                address(0),
                uint256(0),
                to,
                address(0),
                uint256(0),
                address(factory),
                abi.encodeCall(PrecisionPoolFactory.checkpoint, (tokenIn))
            )
        );
        calls[1] = abi.encodeCall(
            ISnwap.snwap,
            (tokenIn, amountIn, to, tokenOut, uint256(0), address(factory), _swapData(tokenIn, amountIn, to))
        );
        bytes[] memory results = ISnwap(ZROUTER).multicall(calls);
        amountOut = abi.decode(results[1], (uint256));
    }

    /// @dev ETH in. snwap forwards msg.value to the executor, which passes
    /// the declared exact amount on to the pool.
    function test_LiveRouterSwapsEthForUsdc() public {
        uint256 predicted = lens.quoteFor(address(pool), address(factory), address(0), 1 ether);
        assertGt(predicted, 0, "lens must have a quote to compare against");

        uint256 before = IERC20(USDC).balanceOf(user);

        vm.prank(user);
        uint256 out = ISnwap(ZROUTER).snwap{value: 1 ether}(
            address(0), 1 ether, user, USDC, 0, address(factory), _swapData(address(0), 1 ether, user)
        );

        assertEq(out, predicted, "router-reported output matches the lens exactly");
        assertEq(IERC20(USDC).balanceOf(user) - before, predicted, "and the user actually got it");
    }

    /// @dev ERC-20 in. Here the router transfers to the executor first, which
    /// forwards the declared exact amount to the pool in the same call.
    function test_LiveRouterSwapsUsdcForEth() public {
        uint256 amountIn = 5_000e6;
        uint256 predicted = lens.quoteFor(address(pool), address(factory), USDC, amountIn);
        assertGt(predicted, 0);

        uint256 before = user.balance;

        vm.prank(user);
        uint256 out = _checkpointedErc20Snwap(USDC, amountIn, user, address(0));

        assertEq(out, predicted, "quote held through the router");
        assertEq(user.balance - before, predicted, "ETH delivered to the recipient");
    }

    /// @dev The router's own guard, measured at the recipient, is what makes
    /// the pool safe to call without trusting it: an output that never arrives
    /// is caught one contract away.
    function test_RouterSlippageGuardBinds() public {
        uint256 predicted = lens.quoteFor(address(pool), address(factory), address(0), 1 ether);

        vm.prank(user);
        vm.expectRevert();
        ISnwap(ZROUTER).snwap{value: 1 ether}(
            address(0), 1 ether, user, USDC, predicted + 1, address(factory), _swapData(address(0), 1 ether, user)
        );
    }

    /// @dev Routing to a third party: the pool pays whoever the calldata names
    /// and the router measures the delta there, so a relayed fill needs no
    /// sweep afterwards.
    function test_OutputCanBeDeliveredToSomeoneElse() public {
        address dst = address(0xD57);
        uint256 predicted = lens.quoteFor(address(pool), address(factory), address(0), 1 ether);

        vm.prank(user);
        uint256 out = ISnwap(ZROUTER).snwap{value: 1 ether}(
            address(0), 1 ether, dst, USDC, predicted, address(factory), _swapData(address(0), 1 ether, dst)
        );

        assertEq(out, predicted);
        assertEq(IERC20(USDC).balanceOf(dst), predicted, "paid straight to the recipient");
        assertEq(IERC20(USDC).balanceOf(user), 100_000e6, "payer untouched");
    }

    /// @dev Two hops in sequence over the same pool, which is the shape a
    /// multicall route would take. The second leg must see the price the first
    /// leg moved it to, or sequencing is unsound.
    function test_SequentialLegsSeeTheUpdatedPrice() public {
        uint256 first = lens.quoteFor(address(pool), address(factory), address(0), 1 ether);
        vm.prank(user);
        ISnwap(ZROUTER).snwap{value: 1 ether}(
            address(0), 1 ether, user, USDC, 0, address(factory), _swapData(address(0), 1 ether, user)
        );

        uint256 second = lens.quoteFor(address(pool), address(factory), address(0), 1 ether);
        assertLt(second, first, "the first leg moved the price against the second");

        vm.prank(user);
        uint256 out = ISnwap(ZROUTER).snwap{value: 1 ether}(
            address(0), 1 ether, user, USDC, 0, address(factory), _swapData(address(0), 1 ether, user)
        );
        assertEq(out, second, "the lens tracked the move exactly");
    }

    /// @dev The discovery-to-execution path zSwap will actually walk, with no
    /// indexer and no event parsing anywhere in it:
    ///   1. the user picks a pair;
    ///   2. bands are enumerated from the registry, or derived outright;
    ///   3. the lens reports which are populated and what each would fill at;
    ///   4. the live router crosses the chosen ones in sequence.
    function test_DiscoverBandsThenCrossThemInOneRoute() public {
        // A second, wider band on the same pair, so there is a real choice.
        PrecisionPoolFactory.Market memory wide = _mkt(3000, address(0));
        wide.sqrtPHigh = SQRT_HIGH + 4_000_000_000_000;
        vm.startPrank(lp);
        (address p2,,,) = factory.createAndSeed{value: 10 ether}(wide, SQRT_MID, 10 ether, 40_000e6, 0, lp);
        vm.stopPrank();

        // 2. Enumerated from the registry by pair - no logs read anywhere.
        address[] memory bands = factory.poolsForPairSlice(address(0), USDC, 0, 16);
        assertEq(bands.length, 2, "both bands discoverable");
        // And derivable with no registry at all, for a pair the user typed.
        assertEq(factory.poolFor(_mkt(FEE, address(0))), address(pool), "address is derived");

        // 3. Which are populated, and what each would fill at.
        PrecisionPoolLens.PoolInfo[] memory info =
            lens.marketsForPair(address(0), USDC, address(factory), 0, 16, 1 ether);
        assertEq(info.length, 2);
        assertGt(info[0].liquidity, 0, "band is populated");
        assertGt(info[1].liquidity, 0);

        PrecisionPoolLens.Quoted[] memory qs =
            lens.quoteAllFor(address(0), USDC, address(factory), address(0), 1 ether, 0, 16);
        assertEq(qs.length, 2);
        assertGt(qs[0].amountOut, 0);
        assertGt(qs[1].amountOut, 0);

        // 4. Cross both.
        uint256 before = IERC20(USDC).balanceOf(user);
        vm.startPrank(user);
        uint256 a = ISnwap(ZROUTER).snwap{value: 1 ether}(
            address(0), 1 ether, user, USDC, 0, address(factory), _swapData(address(0), 1 ether, user)
        );
        uint256 b = ISnwap(ZROUTER).snwap{value: 1 ether}(
            address(0), 1 ether, user, USDC, 0, address(factory), _swapData(address(0), 1 ether, user)
        );
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(user) - before, a + b, "both legs delivered");
        assertTrue(p2 == bands[0] || p2 == bands[1]);
    }

    /// @dev Exiting a band inside a route: the router funds the zap with LP
    /// shares, the zap burns them, and snwapMulti measures BOTH sides landing
    /// on the recipient. Whichever leg the user did not want would be an
    /// ordinary swap in the next multicall entry - not this contract's job.
    function test_ExitAPositionThroughTheLiveRouter() public {
        PrecisionZap zap = new PrecisionZap(factory, ZROUTER_SAFE_EXECUTOR);

        uint256 shares = pool.balanceOf(lp) / 2;
        uint256 supply = pool.totalSupply();
        // Redemption is exact and knowable in advance - no quoting needed.
        uint256 expect0 = uint256(pool.reserve0()) * shares / supply;
        uint256 expect1 = uint256(pool.reserve1()) * shares / supply;

        vm.prank(lp);
        pool.approve(ZROUTER, type(uint256).max);

        address[] memory tokensOut = new address[](2);
        tokensOut[0] = address(0);
        tokensOut[1] = USDC;
        uint256[] memory mins = new uint256[](2);

        uint256 eth0 = lp.balance;
        uint256 usdc0 = IERC20(USDC).balanceOf(lp);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            ISnwap.snwap,
            (
                address(0),
                uint256(0),
                lp,
                address(0),
                uint256(0),
                address(zap),
                abi.encodeCall(PrecisionZap.checkpoint, (address(pool)))
            )
        );
        calls[1] = abi.encodeCall(
            ISnwap.snwapMulti,
            (
                address(pool),
                shares,
                lp,
                tokensOut,
                mins,
                address(zap),
                abi.encodeCall(PrecisionZap.exit, (address(pool), shares, 0, 0, lp))
            )
        );

        vm.prank(lp);
        ISnwap(ZROUTER).multicall(calls);

        assertEq(lp.balance - eth0, expect0, "ETH leg exact");
        assertEq(IERC20(USDC).balanceOf(lp) - usdc0, expect1, "USDC leg exact");
        assertEq(pool.balanceOf(lp), supply - 1000 - shares, "shares burned");
        assertEq(pool.balanceOf(address(zap)), 0, "zap keeps nothing");
    }

    /// @dev Without a fresh checkpoint the zap will not spend a balance it
    /// finds lying around, so a stray transfer cannot be redeemed by whoever
    /// calls next.
    function test_ZapRefusesUncheckpointedShares() public {
        PrecisionZap zap = new PrecisionZap(factory, ZROUTER_SAFE_EXECUTOR);

        vm.prank(lp);
        pool.transfer(address(zap), 1e6);

        vm.prank(ZROUTER_SAFE_EXECUTOR);
        vm.expectRevert(PrecisionZap.BadCheckpoint.selector);
        zap.exit(address(pool), 1e6, 0, 0, lp);
    }

    function test_ZapRefusesUntrustedCallersAndUnknownPools() public {
        PrecisionZap zap = new PrecisionZap(factory, ZROUTER_SAFE_EXECUTOR);

        vm.expectRevert(PrecisionZap.NotExecutor.selector);
        zap.exit(address(pool), 1, 0, 0, lp);

        vm.prank(ZROUTER_SAFE_EXECUTOR);
        vm.expectRevert(PrecisionZap.NoPool.selector);
        zap.exit(address(0xDEAD), 1, 0, 0, lp);
    }
}
