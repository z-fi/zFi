// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";

/// @notice The routed Precision path, against the REAL contracts.
///
///         zSwap stopped sending Precision swaps straight at the pool and now
///         builds them as an ordinary leg: zRouter -> snwap -> SafeExecutor ->
///         PrecisionRoute -> the pool. That is a rewrite of a live path, and
///         every check on it so far has been against mocks - which this session
///         has twice watched agree with a defect, because a fixture built to the
///         shape of the bug agrees with the bug.
///
///         So this builds THE SAME CALLDATA the page builds, byte for byte, and
///         sends it to the deployed router at a pinned block. Nothing is
///         stubbed: real zRouter, real SafeExecutor, real PrecisionRoute, the
///         real ETH/ZORG market.
///
///         Written in Solidity rather than driven through the page because the
///         JSDOM fork harness has been the least reliable thing in the room -
///         anvil wedges on uncached reads and a single stall has eaten whole
///         suites. Forge forks once, caches, and answers in seconds.
contract PrecisionRoutedForkTest is Test {
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant PROUTE = 0x000000384711c65f633Aa4487b968ecb7956DB0F;
    address constant EXECUTOR = 0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db;
    address constant POOL = 0xc37F8c7E9Afe897893952ABa7fD91E0AB947837d;
    address constant ZORG = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12;
    address constant ETH = address(0);
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address trader = makeAddr("trader");
    address friend = makeAddr("friend");
    /// @dev A real ZORG holder, impersonated. `deal` cannot be used for this
    ///      token: it is share-based - `shares()`, `onSharesChanged` - so
    ///      writing `balanceOf` directly leaves the internal accounting
    ///      inconsistent and the very next transfer reverts `Overflow()`. The
    ///      balance looks right and the token does not work, which is a
    ///      convincing way to fail a test for a reason the product does not have.
    address constant WHALE = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;

    function _fundZorg(address who, uint256 amount) internal {
        vm.prank(WHALE);
        (bool ok,) = ZORG.call(abi.encodeWithSignature("transfer(address,uint256)", who, amount));
        require(ok, "could not source ZORG from the holder");
    }

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_739_900
        );
        vm.deal(trader, 100 ether);
    }

    function _bal(address token, address who) internal view returns (uint256) {
        if (token == ETH) return who.balance;
        (bool ok, bytes memory d) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return ok ? abi.decode(d, (uint256)) : 0;
    }

    /// @dev `route(address[],address,address,uint256,uint256,address)`, encoded
    ///      exactly as `encPRoute` does in the page: the array rides behind an
    ///      offset of 192, being the sixth word.
    function _routeData(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        internal
        pure
        returns (bytes memory)
    {
        address[] memory pools = new address[](1);
        pools[0] = POOL;
        return abi.encodeWithSelector(0x5d6498e1, pools, tokenIn, tokenOut, amountIn, minOut, to);
    }

    /// @dev `snwap(address,uint256,address,address,uint256,address,bytes)` - the
    ///      page's `encSnwap`, same argument order.
    function _snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 minOut,
        bytes memory data
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(0x5f3bd1c8, tokenIn, amountIn, recipient, tokenOut, minOut, PROUTE, data);
    }

    // ------------------------------------------------------------ the wiring

    /// The claim the whole rewrite rests on: PrecisionRoute trusts the executor
    /// that `snwap` delegates to. If this were any other address, a Precision
    /// leg could not be routed at all and the page would be building calldata
    /// nothing can run.
    function test_precisionRouteTrustsTheSnwapExecutor() public view {
        (bool ok, bytes memory d) = PROUTE.staticcall(abi.encodeWithSignature("trustedExecutor()"));
        assertTrue(ok, "PrecisionRoute did not answer");
        assertEq(abi.decode(d, (address)), EXECUTOR, "the routed path is aimed at the wrong executor");
        assertGt(ZROUTER.code.length, 0, "zRouter");
        assertGt(POOL.code.length, 0, "the market");
    }

    // ------------------------------------------------------------ native in

    /// ETH -> ZORG through the router, paid as value. The shape a user gets
    /// today when they swap ether into a native market.
    function test_nativeInRoutesThroughTheRouterAndPaysTheTrader() public {
        uint256 amountIn = 0.01 ether;
        bytes memory call = _snwap(ETH, amountIn, trader, ZORG, 1, _routeData(ETH, ZORG, amountIn, 1, trader));

        uint256 zorgBefore = _bal(ZORG, trader);
        vm.prank(trader);
        (bool ok,) = ZROUTER.call{value: amountIn}(call);
        assertTrue(ok, "the routed swap reverted");

        uint256 got = _bal(ZORG, trader) - zorgBefore;
        emit log_named_uint("ZORG received", got);
        assertGt(got, 0, "the trader received nothing");
    }

    /// The same trade paid to SOMEONE ELSE. Custom recipients have to survive
    /// the routing rather than quietly reverting to the payer - the recipient
    /// is an argument of the inner `route`, two encodings deep.
    function test_nativeInPaysANamedRecipient() public {
        uint256 amountIn = 0.01 ether;
        bytes memory call = _snwap(ETH, amountIn, friend, ZORG, 1, _routeData(ETH, ZORG, amountIn, 1, friend));

        uint256 friendBefore = _bal(ZORG, friend);
        uint256 traderBefore = _bal(ZORG, trader);
        vm.prank(trader);
        (bool ok,) = ZROUTER.call{value: amountIn}(call);
        assertTrue(ok, "the routed swap reverted");

        assertGt(_bal(ZORG, friend) - friendBefore, 0, "the named recipient got nothing");
        assertEq(_bal(ZORG, trader), traderBefore, "the payer must not receive the output");
    }

    /// The floor is enforced where it is denominated. An unreachable `minOut`
    /// must revert rather than deliver less, and it must do so without leaving
    /// the input behind.
    function test_anUnreachableFloorRevertsAndKeepsTheInput() public {
        uint256 amountIn = 0.01 ether;
        uint256 absurd = type(uint128).max;
        bytes memory call =
            _snwap(ETH, amountIn, trader, ZORG, absurd, _routeData(ETH, ZORG, amountIn, absurd, trader));

        uint256 ethBefore = trader.balance;
        vm.prank(trader);
        (bool ok,) = ZROUTER.call{value: amountIn}(call);
        assertFalse(ok, "an impossible floor must not settle");
        assertEq(trader.balance, ethBefore, "a reverted route must not keep the ether");
    }

    /// `route` names `tokenOut` for a reason the contract spells out: the output
    /// is otherwise implicit in the path, so a wrong one would measure `minOut`
    /// in the wrong units - a 1e18 threshold against a 6-decimal token passes
    /// trivially. Naming a token this path does not deliver must revert.
    function test_aTokenOutThePathCannotDeliverIsRefused() public {
        uint256 amountIn = 0.01 ether;
        bytes memory call = _snwap(ETH, amountIn, trader, WETH, 1, _routeData(ETH, WETH, amountIn, 1, trader));

        vm.prank(trader);
        (bool ok,) = ZROUTER.call{value: amountIn}(call);
        assertFalse(ok, "the route delivered ZORG while claiming WETH");
    }

    // ------------------------------------------------------------- ERC-20 in

    /// ZORG -> ETH, which is the checkpointed half: the input is snapshotted,
    /// funded, and only then spent, and the snapshot commits to the keccak of
    /// the exact call that may spend it.
    ///
    /// Built as the page builds it - a multicall of two snwaps, the first
    /// carrying the checkpoint - so what is being tested is the page's own
    /// sequencing rather than a convenient re-arrangement of it.
    function test_erc20InIsCheckpointedThenSpent() public {
        uint256 amountIn = 500e18;
        _fundZorg(trader, amountIn);

        bytes memory routeData = _routeData(ZORG, ETH, amountIn, 1, trader);
        bytes memory checkpointCall = abi.encodeWithSelector(
            bytes4(0x0b7c6c6c), ZORG, keccak256(routeData), trader
        );

        bytes[] memory calls = new bytes[](2);
        calls[0] = _snwap(ETH, 0, trader, ETH, 0, checkpointCall);
        calls[1] = _snwap(ZORG, amountIn, trader, ETH, 1, routeData);

        vm.startPrank(trader);
        (bool okA,) = ZORG.call(abi.encodeWithSignature("approve(address,uint256)", ZROUTER, amountIn));
        require(okA, "approve failed");
        uint256 ethBefore = trader.balance;
        (bool ok,) = ZROUTER.call(abi.encodeWithSignature("multicall(bytes[])", calls));
        vm.stopPrank();

        assertTrue(ok, "the checkpointed route reverted");
        assertGt(trader.balance, ethBefore, "the trader received no ether");
    }

    /// The checkpoint commits to the CALL, not merely to a balance. A route that
    /// does not match the committed keccak must be refused, which is what stops
    /// a funding transfer from being consumed by a different call with pools,
    /// slippage and a recipient of its own choosing.
    function test_aRouteThatDoesNotMatchTheCheckpointIsRefused() public {
        uint256 amountIn = 500e18;
        _fundZorg(trader, amountIn);

        // Committed to paying the trader; the route that follows pays `friend`.
        bytes memory committed = _routeData(ZORG, ETH, amountIn, 1, trader);
        bytes memory swapped = _routeData(ZORG, ETH, amountIn, 1, friend);

        bytes[] memory calls = new bytes[](2);
        calls[0] = _snwap(
            ETH, 0, trader, ETH, 0,
            abi.encodeWithSelector(bytes4(0x0b7c6c6c), ZORG, keccak256(committed), trader)
        );
        calls[1] = _snwap(ZORG, amountIn, friend, ETH, 1, swapped);

        vm.startPrank(trader);
        (bool okA,) = ZORG.call(abi.encodeWithSignature("approve(address,uint256)", ZROUTER, amountIn));
        require(okA, "approve failed");
        (bool ok,) = ZROUTER.call(abi.encodeWithSignature("multicall(bytes[])", calls));
        vm.stopPrank();

        assertFalse(ok, "a redirected route must not be able to spend a checkpoint");
    }
}
