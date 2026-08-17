// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {PrecisionRoute} from "../src/pools/PrecisionRoute.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";

/// @notice `routeFromWETH`: one signature for a WETH holder buying from a
///         market that holds ether.
///
///         Before this, that trade was two transactions - unwrap, then swap -
///         and zRouter could not bridge the gap even though it has an
///         `unwrap(uint256)` of its own: `snwap` forwards `msg.value` to the
///         executor and nothing else, so ether the router holds after an
///         in-multicall unwrap never arrives. What `snwap` DOES do is deliver an
///         ERC-20 to the executor it was told to call, which is the opening this
///         uses.
contract PrecisionRouteWethTest is Test {
    address constant FACTORY = 0x000000Eb27B557aB426d9E99cFd54EC455799e81;
    address constant EXECUTOR = 0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db;
    address constant POOL = 0xc37F8c7E9Afe897893952ABa7fD91E0AB947837d;
    address constant ZORG = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant PROUTE = 0x0000007Be74558A1F8c9045301c6F44C8eD0c9eB;

    PrecisionRoute r;
    address trader = makeAddr("trader");
    address friend = makeAddr("friend");

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_745_140
        );
        r = new PrecisionRoute(PrecisionPoolFactory(payable(FACTORY)), EXECUTOR);
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        (bool ok,) = WETH.call{value: 5 ether}(abi.encodeWithSignature("deposit()"));
        require(ok, "wrap");
    }

    function _zorg(address who) internal view returns (uint256) {
        (bool ok, bytes memory d) = ZORG.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return ok ? abi.decode(d, (uint256)) : 0;
    }

    function _calldata(uint256 amt, uint256 minOut, address to) internal pure returns (bytes memory) {
        address[] memory pools = new address[](1);
        pools[0] = POOL;
        return abi.encodeCall(PrecisionRoute.routeFromWETH, (pools, ZORG, amt, minOut, to));
    }

    /// The whole point: WETH in, ZORG out, in ONE call by the executor - which
    /// is exactly what `snwap` performs after delivering the WETH.
    function test_wethInBuysFromANativeMarketInOneCall() public {
        uint256 amt = 0.01 ether;
        bytes memory data = _calldata(amt, 1, trader);

        // Executor snapshots, funds, then spends - the order `snwap` uses.
        vm.prank(EXECUTOR);
        r.checkpoint(WETH, keccak256(data), trader);
        vm.prank(trader);
        (bool okT,) = WETH.call(abi.encodeWithSignature("transfer(address,uint256)", address(r), amt));
        require(okT, "fund");

        uint256 before = _zorg(trader);
        uint256 etherBefore = address(r).balance;
        vm.prank(EXECUTOR);
        (bool ok, bytes memory ret) = address(r).call(data);
        assertTrue(ok, "routeFromWETH reverted");

        uint256 got = _zorg(trader) - before;
        emit log_named_uint("ZORG for 0.01 WETH", got);
        assertGt(got, 0, "the trader received nothing");
        assertEq(abi.decode(ret, (uint256)), got, "the return value must be what landed");
        // Measured as a DELTA, not against zero. `new` lands this on a fork
        // address that already holds ether, and asserting a bare zero here
        // reported a 5.8%-of-input leak that predated the call entirely - a
        // fixture artifact wearing the costume of a fund bug. The pool takes
        // the whole input and refunds nothing; what matters is that this call
        // adds nothing to whatever was already sitting there.
        assertEq(address(r).balance, etherBefore, "the route kept ether");
        assertEq(_zorg(address(r)), 0, "no output may rest here");
    }

    // --------------------------------------------------- end to end, for real
    //
    // The tests above call this contract directly, which proves the function
    // but not the path a user takes to reach it. The claim `routeFromWETH`
    // rests on is specifically about `snwap`: that it delivers an ERC-20 to the
    // executor it was told to call, so WETH can arrive here as an ordinary
    // token input. Nothing short of the real router demonstrates that.
    //
    // So: etch the new build over the live address and drive the whole stack -
    // real zRouter, real SafeExecutor, real market, the page's own two-call
    // multicall with the checkpoint riding in front. One user transaction, and
    // no ether left anywhere along it.

    /// @dev Nothing to etch any more: the block above is after the deploy, so
    ///      `PROUTE` IS the contract this file describes. Kept as a named
    ///      assertion rather than deleted, because "the live address answers to
    ///      `routeFromWETH`" is the fact the end-to-end test silently assumes.
    function test_theLiveRouteCarriesRouteFromWeth() public view {
        assertGt(PROUTE.code.length, 0, "no code at the route");
        (bool ok, bytes memory d) = PROUTE.staticcall(abi.encodeWithSignature("trustedExecutor()"));
        assertTrue(ok && abi.decode(d, (address)) == EXECUTOR, "wrong executor");
    }

    /// @dev `snwap(address,uint256,address,address,uint256,address,bytes)`.
    function _snwap(address tokenIn, uint256 amountIn, address recipient, address tokenOut, uint256 minOut, bytes memory data)
        internal pure returns (bytes memory)
    {
        return abi.encodeWithSelector(0x5f3bd1c8, tokenIn, amountIn, recipient, tokenOut, minOut, PROUTE, data);
    }

    /// WETH in, ZORG out, ONE user transaction, through the deployed router -
    /// and the unspent remainder comes back rather than resting anywhere.
    function test_endToEnd_wethBuysFromANativeMarketInOneTransaction() public {
        uint256 amt = 0.01 ether;

        bytes memory routeData = _calldata(amt, 1, trader);
        bytes[] memory calls = new bytes[](2);
        calls[0] = _snwap(
            address(0), 0, trader, address(0), 0,
            abi.encodeWithSelector(bytes4(0x0b7c6c6c), WETH, keccak256(routeData), trader)
        );
        calls[1] = _snwap(WETH, amt, trader, ZORG, 1, routeData);

        vm.startPrank(trader);
        (bool okA,) = WETH.call(abi.encodeWithSignature("approve(address,uint256)", ZROUTER, amt));
        require(okA, "approve");
        uint256 ethBefore = trader.balance;
        (bool ok,) = ZROUTER.call(abi.encodeWithSignature("multicall(bytes[])", calls));
        vm.stopPrank();

        assertTrue(ok, "the one-transaction WETH path reverted");
        assertGt(_zorg(trader), 0, "the trader received no ZORG");
        emit log_named_uint("ZORG for 0.01 WETH", _zorg(trader));
        assertEq(trader.balance, ethBefore, "a WETH-funded trade must not move the trader's ether");
        assertEq(PROUTE.balance, 0, "ether rested in the route");
        assertEq(ZROUTER.balance, 0, "ether rested in the router");
        assertEq(EXECUTOR.balance, 0, "ether rested in the executor");
        assertEq(address(PROUTE).balance, 0, "the unspent remainder rested in the route");
        assertEq(_zorg(PROUTE), 0, "output rested in the route");
    }

    /// Control: the SAME locally-built contract on the plain native `route`.
    /// If dust rests here too, it belongs to `_walk` and not to the new entry.
    function test_control_nativeRouteOnTheSameBuild() public {
        address[] memory pools = new address[](1);
        pools[0] = POOL;
        uint256 amt = 0.01 ether;
        uint256 pre = address(r).balance;
        vm.deal(EXECUTOR, amt);
        vm.prank(EXECUTOR);
        uint256 out = r.route{value: amt}(pools, address(0), ZORG, amt, 1, trader);
        assertGt(out, 0, "the control route delivered nothing");
        assertEq(address(r).balance, pre, "the native route left ether behind");
    }

    /// Recipients survive, as on every other path.
    function test_itPaysANamedRecipient() public {
        uint256 amt = 0.01 ether;
        bytes memory data = _calldata(amt, 1, friend);
        vm.prank(EXECUTOR);
        r.checkpoint(WETH, keccak256(data), trader);
        vm.prank(trader);
        (bool okT,) = WETH.call(abi.encodeWithSignature("transfer(address,uint256)", address(r), amt));
        require(okT, "fund");
        vm.prank(EXECUTOR);
        (bool ok,) = address(r).call(data);
        assertTrue(ok, "reverted");
        assertGt(_zorg(friend), 0, "the named recipient got nothing");
        assertEq(_zorg(trader), 0, "the payer must not receive the output");
    }

    /// The checkpoint still covers the exact call. Unwrapping happens AFTER the
    /// snapshot is consumed, so a claim that does not match cannot get as far as
    /// holding ether.
    function test_aMismatchedIntentCannotSpendTheCheckpoint() public {
        uint256 amt = 0.01 ether;
        bytes memory committed = _calldata(amt, 1, trader);
        bytes memory swapped = _calldata(amt, 1, friend);

        vm.prank(EXECUTOR);
        r.checkpoint(WETH, keccak256(committed), trader);
        vm.prank(trader);
        (bool okT,) = WETH.call(abi.encodeWithSignature("transfer(address,uint256)", address(r), amt));
        require(okT, "fund");

        vm.prank(EXECUTOR);
        (bool ok,) = address(r).call(swapped);
        assertFalse(ok, "a redirected route must not spend a checkpoint");
    }

    /// Only the executor, as everywhere else in this contract.
    function test_aStrangerCannotCallIt() public {
        vm.prank(trader);
        (bool ok,) = address(r).call(_calldata(0.01 ether, 1, trader));
        assertFalse(ok, "routeFromWETH must be executor-only");
    }

    /// A floor denominated in the OUTPUT still bites.
    function test_anUnreachableFloorReverts() public {
        uint256 amt = 0.01 ether;
        bytes memory data = _calldata(amt, type(uint128).max, trader);
        vm.prank(EXECUTOR);
        r.checkpoint(WETH, keccak256(data), trader);
        vm.prank(trader);
        (bool okT,) = WETH.call(abi.encodeWithSignature("transfer(address,uint256)", address(r), amt));
        require(okT, "fund");
        vm.prank(EXECUTOR);
        (bool ok,) = address(r).call(data);
        assertFalse(ok, "an impossible floor must not settle");
    }
}
