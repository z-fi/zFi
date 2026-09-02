// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";

// Selective imports on purpose: both files declare file-scope constants named
// WETH, V2_FACTORY and so on, and a plain `import "..."` of both would collide.
import {zRouterLite} from "../src/zRouterLite.sol";
import {zQuoterRobinhood} from "../src/zQuoterRobinhood.sol";

/// @dev Robinhood Chain (id 4663), pinned so the reserves the assertions are
/// written against cannot move underneath them.
uint256 constant FORK_BLOCK = 52_784_331;

address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
address constant V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
address constant V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
address constant V2_ROUTER_02 = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;

/// @dev MARIAN. Chosen because at this block it is the one token on the chain
/// with live liquidity in all three venues the router can execute: a V2 pair
/// against WETH, a V3 1% pool, and V4 pools at 0.3% and 1% against native ETH.
/// One token therefore exercises every branch.
address constant TKN = 0x01637b14B7378B99dE75A64d50656d98488D9a4d;

interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IStateView {
    function poolManager() external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract RobinhoodTest is Test {
    zRouterLite router;
    zQuoterRobinhood quoter;

    address alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork("https://rpc.mainnet.chain.robinhood.com", FORK_BLOCK);
        router = new zRouterLite();
        quoter = new zQuoterRobinhood(address(router));
        vm.deal(alice, 100 ether);
    }

    // ── the constants, checked against the chain rather than a docs page ──

    function testChainIsRobinhood() public view {
        assertEq(block.chainid, 4663);
    }

    /// @dev Called by signature rather than through an interface: a method named
    /// `WETH()` would shadow the file-scope constant it is being checked against.
    function testWethAgreesAcrossBothUniswapRouters() public view {
        assertEq(_addrCall(SWAP_ROUTER_02, "WETH9()"), WETH);
        assertEq(_addrCall(V2_ROUTER_02, "WETH()"), WETH);
    }

    function _addrCall(address target, string memory sig) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        assertTrue(ok && ret.length == 32, "call failed");
        return abi.decode(ret, (address));
    }

    /// @dev The load-bearing one. If the quoter's CREATE2 derivation and the
    /// factory's registry ever disagreed, every quote would be for a pool the
    /// built calldata cannot reach.
    function testV3DerivationMatchesFactoryRegistry() public view {
        address registered = IV3Factory(V3_FACTORY).getPool(WETH, TKN, 10_000);
        assertTrue(registered != address(0), "no 1% pool at this block");
        // Reached only through a quote that must have found the same address.
        (, uint256 out) = quoter.quoteV3(false, WETH, TKN, 10_000, 1 ether);
        assertGt(out, 0, "derivation missed the registered pool");
    }

    function testV2FactoryIsLive() public view {
        assertGt(V2_FACTORY.code.length, 0);
        (, uint256 out) = quoter.quoteV2(false, address(0), TKN, 0.01 ether);
        assertGt(out, 0, "no V2 route for the test token");
    }

    function testStateViewPointsAtTheRoutersPoolManager() public view {
        assertEq(IStateView(V4_STATE_VIEW).poolManager(), V4_POOL_MANAGER);
    }

    // ── quote == execution, per venue ──

    function testV2QuoteMatchesExecution() public {
        uint256 amountIn = 0.01 ether;
        (, uint256 quoted) = quoter.quoteV2(false, address(0), TKN, amountIn);
        assertGt(quoted, 0);

        vm.prank(alice);
        (, uint256 amountOut) = router.swapV2{value: amountIn}(
            alice, false, address(0), TKN, amountIn, 0, block.timestamp
        );
        assertEq(amountOut, quoted, "V2 quote drifted from execution");
        assertEq(IERC20(TKN).balanceOf(alice), amountOut);
    }

    function testV3QuoteMatchesExecution() public {
        uint256 amountIn = 0.01 ether;
        (, uint256 quoted) = quoter.quoteV3(false, address(0), TKN, 10_000, amountIn);
        assertGt(quoted, 0);

        vm.prank(alice);
        (, uint256 amountOut) = router.swapV3{value: amountIn}(
            alice, false, 10_000, address(0), TKN, amountIn, 0, block.timestamp
        );
        assertEq(amountOut, quoted, "V3 quote drifted from execution");
    }

    function testV4QuoteMatchesExecution() public {
        uint256 amountIn = 0.01 ether;
        (, uint256 quoted) = quoter.quoteV4(false, address(0), TKN, 10_000, amountIn);
        assertGt(quoted, 0);

        vm.prank(alice);
        (, uint256 amountOut) = router.swapV4{value: amountIn}(
            alice, false, 10_000, 200, address(0), TKN, amountIn, 0, block.timestamp
        );
        assertEq(amountOut, quoted, "V4 quote drifted from execution");
    }

    // ── the front end's actual entry point ──

    function testBuildBestSwapIsExecutableAsIs() public {
        uint256 amountIn = 0.01 ether;
        (zQuoterRobinhood.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(alice, false, address(0), TKN, amountIn, 100, block.timestamp);

        assertGt(best.amountOut, 0, "no route");
        assertEq(msgValue, amountIn);

        vm.prank(alice);
        (bool ok,) = address(router).call{value: msgValue}(callData);
        assertTrue(ok, "quoter-built calldata reverted");
        assertGe(IERC20(TKN).balanceOf(alice), amountLimit, "landed under the embedded slippage bound");
    }

    function testBestBeatsOrTiesEveryVenue() public view {
        (zQuoterRobinhood.Quote memory best, zQuoterRobinhood.Quote[] memory quotes) =
            quoter.getQuotes(false, address(0), TKN, 0.01 ether);
        assertEq(quotes.length, 9);
        for (uint256 i; i < quotes.length; ++i) {
            assertGe(best.amountOut, quotes[i].amountOut);
        }
    }

    /// @dev ETH -> WETH is not a swap; the quoter must say so 1:1 rather than
    /// route it through a pool and invent a spread.
    function testWrapIsQuotedOneToOneAndExecutes() public {
        uint256 amount = 1 ether;
        (zQuoterRobinhood.Quote memory best, bytes memory callData,, uint256 msgValue) =
            quoter.buildBestSwap(alice, false, address(0), WETH, amount, 50, block.timestamp);

        assertEq(best.amountOut, amount);
        assertEq(msgValue, amount);

        vm.prank(alice);
        (bool ok,) = address(router).call{value: msgValue}(callData);
        assertTrue(ok, "wrap multicall reverted");
        assertEq(IERC20(WETH).balanceOf(alice), amount);
    }

    function testUnwrapRoundTrips() public {
        // Fund alice with WETH by wrapping first.
        vm.prank(alice);
        (bool wrapped,) = WETH.call{value: 1 ether}("");
        assertTrue(wrapped);

        (,bytes memory callData,,) = quoter.buildBestSwap(alice, false, WETH, address(0), 1 ether, 50, block.timestamp);

        vm.startPrank(alice);
        IERC20(WETH).approve(address(router), 1 ether);
        uint256 before = alice.balance;
        (bool ok,) = address(router).call(callData);
        vm.stopPrank();

        assertTrue(ok, "unwrap multicall reverted");
        assertEq(alice.balance, before + 1 ether);
    }

    /// @dev The V2 pair is thin at this block (about 0.37 MARIAN against 2.2e11
    /// wei), so the target is sized well inside the reserve. An exact-out at or
    /// above the reserve is not expensive, it is impossible, and the quoter is
    /// expected to answer zero rather than a nonsense price.
    function testExactOutV2() public {
        uint256 want = 1e15;
        (uint256 quotedIn,) = quoter.quoteV2(true, address(0), TKN, want);
        assertGt(quotedIn, 0);

        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut) = router.swapV2{value: quotedIn}(
            alice, true, address(0), TKN, want, quotedIn, block.timestamp
        );
        assertEq(amountOut, want);
        assertEq(amountIn, quotedIn, "V2 exact-out quote drifted from execution");
    }

    function testExactOutBeyondV2ReserveQuotesZero() public view {
        (uint256 quotedIn,) = quoter.quoteV2(true, address(0), TKN, 1e18);
        assertEq(quotedIn, 0, "quoted a trade larger than the pair holds");
    }

    function testIdenticalTokensReverts() public {
        vm.expectRevert(zQuoterRobinhood.IdenticalTokens.selector);
        quoter.getQuotes(false, address(0), WETH, 1 ether);
    }
}
