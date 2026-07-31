// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Swapbol} from "../src/forwarders/Swapbol.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
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

/// @dev The metadex thesis in one transaction: take resting orderbook
/// liquidity AND a precision pool in the same route. Neither venue knows about
/// the other; the router sequences them and measures the delta at the
/// recipient, so a leg that under-delivers is caught one contract away.
contract BookAndPoolComposeTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant EXEC = 0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db;

    Swapboard board;
    Swapbol bol;
    Dutchboard dutch;
    PrecisionPoolFactory factory;
    PrecisionPoolLens lens;
    PrecisionPool pool;

    address maker = address(0xACE);
    address lp = address(0xC11);
    address user = address(0xBEEF);

    function setUp() public {
        board = new Swapboard(WETH);
        Swapboard legacy = new Swapboard(WETH);
        dutch = new Dutchboard(WETH);
        bol = new Swapbol(address(legacy), address(board), address(dutch));

        factory = new PrecisionPoolFactory(EXEC);
        lens = new PrecisionPoolLens(factory);

        deal(USDC, maker, 10_000_000e6);
        deal(USDC, lp, 10_000_000e6);
        deal(WBTC, lp, 100e8);
        deal(WBTC, user, 10e8);
        vm.deal(lp, 1_000 ether);

        // A resting book order: maker sells USDC, wants WBTC.
        vm.startPrank(maker);
        IERC20(USDC).approve(address(board), type(uint256).max);
        board.createOrder(USDC, 60_000e6, WBTC, 1e8, true, 0, false, false, address(0));
        vm.stopPrank();

        // And a precision pool for the second hop: WBTC <-> USDC.
        vm.startPrank(lp);
        IERC20(USDC).approve(address(factory), type(uint256).max);
        IERC20(WBTC).approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed(
            PrecisionPoolFactory.Market({
                token0: WBTC,
                token1: USDC,
                sqrtPLow: 20_000_000_000_000_000_000,
                sqrtPHigh: 30_000_000_000_000_000_000,
                fee: 3000,
                hook: address(0),
                feeRecipient: address(0),
                creatorFeeBps: 0
            }),
            24_494_897_427_831_780_982, 50e8, 5_000_000e6, 0, lp
        );
        pool = PrecisionPool(payable(p));
        vm.stopPrank();

        vm.prank(user);
        IERC20(WBTC).approve(ZROUTER, type(uint256).max);
    }

    /// @dev Split one WBTC sale across BOTH venues in a single transaction:
    /// half hits the resting order at its fixed price, half sweeps the pool.
    /// This is the composition zSwap exists to express.
    function test_SplitOneSaleAcrossBookAndPool() public {
        uint256 half = 0.5e8;

        uint256 poolLeg = lens.quoteFor(address(pool), address(factory), WBTC, half);
        assertGt(poolLeg, 0, "pool must quote");
        // The book order is 60,000 USDC for 1 WBTC, so half buys 30,000.
        uint256 bookLeg = 30_000e6;

        uint256 before = IERC20(USDC).balanceOf(user);

        // BOTH executors checkpoint their own funding, so each needs its own
        // snapshot leg immediately before it is funded. Swapbol's requirement
        // is easy to miss when composing with the factory's.
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(
            ISnwap.snwap,
            (
                address(0), uint256(0), user, address(0), uint256(0), address(bol),
                abi.encodeWithSignature("checkpoint(address)", WBTC)
            )
        );
        // Leg A: take the resting order through Swapbol.
        calls[1] = abi.encodeCall(
            ISnwap.snwap,
            (
                WBTC, half, user, USDC, uint256(0), address(bol),
                abi.encodeCall(
                    Swapbol.fill,
                    (
                        address(board), WBTC, USDC, user, user,
                        abi.encodeWithSignature(
                            "fillOrder(uint256,uint256,uint256,uint256,address)",
                            uint256(0), block.timestamp, half, uint256(0), user
                        )
                    )
                )
            )
        );
        // Leg B: sweep the precision pool with the other half.
        calls[2] = abi.encodeCall(
            ISnwap.snwap,
            (
                address(0), uint256(0), user, address(0), uint256(0), address(factory),
                abi.encodeCall(PrecisionPoolFactory.checkpoint, (WBTC))
            )
        );
        calls[3] = abi.encodeCall(
            ISnwap.snwap,
            (
                WBTC, half, user, USDC, uint256(0), address(factory),
                abi.encodeCall(
                    PrecisionPoolFactory.executePrefundedSwap,
                    (address(pool), user, WBTC, half, uint256(0), user)
                )
            )
        );
        vm.prank(user);
        ISnwap(ZROUTER).multicall(calls);

        uint256 got = IERC20(USDC).balanceOf(user) - before;
        emit log_named_uint("book leg USDC", bookLeg);
        emit log_named_uint("pool leg USDC", poolLeg);
        emit log_named_uint("total received", got);

        assertEq(got, bookLeg + poolLeg, "both venues settled into one balance");
        assertGt(bookLeg, poolLeg, "the resting order was the better half here");
    }
}
