// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zQuoter3HopL2, IL2Quoter, Quote} from "../src/zQuoter3HopL2.sol";

interface IERC20T {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev The three-hop companion against the live quoter and router on each L2.
/// FORKED, and EXECUTED: a route that quotes but does not settle through the real
/// router is worse than no route, so every answer here is sent through the
/// router's multicall and the output is checked against the bound it promised.
contract zQuoter3HopL2Test is Test {
    address quoter;
    address router;
    address user = address(0xA11CE);

    function setUp() public {
        quoter = vm.parseAddress("0x000000bd2db80567c23e353ca95a251c573cbf9b");
        router = vm.parseAddress("0x000000000000FB114709235f1ccBFfb925F600e4");
    }

    // ------------------------------------------------------------------ BASE

    function _base() internal returns (zQuoter3HopL2 z) {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        // The deployed hub list (script/l2-mirror.mjs).
        address[] memory h = new address[](2);
        h[0] = vm.parseAddress("0x4200000000000000000000000000000000000006"); // WETH
        h[1] = vm.parseAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"); // USDC
        z = new zQuoter3HopL2(IL2Quoter(quoter), router, h[0], h);
    }

    function testBaseExactIn() public {
        zQuoter3HopL2 z = _base();
        address wstETH = vm.parseAddress("0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452");
        address usdt = vm.parseAddress("0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2");
        _exactIn(z, wstETH, usdt, 1 ether);
    }

    /// An ether end stands for WETH, which is one of the two hubs, so only one hub
    /// is left to pass through and no three-hop route exists. The quoter's own
    /// two-hop builder already covers ether -> hub -> token.
    function testBaseEtherEndHasNoThreeHopRoute() public {
        zQuoter3HopL2 z = _base();
        address usdt = vm.parseAddress("0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2");
        vm.expectRevert(zQuoter3HopL2.NoRoute.selector);
        z.build3HopMulticall(user, false, address(0), usdt, 1 ether, 50, block.timestamp + 600);
    }

    function testBaseExactOut() public {
        zQuoter3HopL2 z = _base();
        address wstETH = vm.parseAddress("0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452");
        address usdt = vm.parseAddress("0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2");
        _exactOut(z, wstETH, usdt, 100e6, 1 ether);
    }

    // ------------------------------------------------------------- ROBINHOOD

    function _robinhood() internal returns (zQuoter3HopL2 z) {
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        address[] memory h = new address[](2);
        h[0] = vm.parseAddress("0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73"); // WETH
        h[1] = vm.parseAddress("0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"); // USDG
        z = new zQuoter3HopL2(IL2Quoter(quoter), router, h[0], h);
    }

    function testRobinhoodExactIn() public {
        zQuoter3HopL2 z = _robinhood();
        // Both ends have Uniswap pools against both hubs. DEEP does not, since it
        // trades only on the Deepstate book, so it has no three-hop route here.
        address nvda = vm.parseAddress("0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC");
        address marian = vm.parseAddress("0x01637b14B7378B99dE75A64d50656d98488D9a4d");
        _exactIn(z, nvda, marian, 1 ether);
    }

    // ---------------------------------------------------------------- GUARDS

    function testRejectsOneHubAndACodelessQuoter() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        address[] memory one = new address[](1);
        one[0] = vm.parseAddress("0x4200000000000000000000000000000000000006");
        vm.expectRevert(zQuoter3HopL2.BadConfig.selector);
        new zQuoter3HopL2(IL2Quoter(quoter), router, one[0], one);

        address[] memory two = new address[](2);
        two[0] = one[0];
        two[1] = vm.parseAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");
        vm.expectRevert(zQuoter3HopL2.BadConfig.selector);
        new zQuoter3HopL2(IL2Quoter(address(0xBEEF)), router, two[0], two);
    }

    // --------------------------------------------------------------- HELPERS

    function _exactIn(zQuoter3HopL2 z, address tokenIn, address tokenOut, uint256 amount) internal {
        uint256 g = gasleft();
        (,, Quote memory c,, bytes memory mc, uint256 mv) =
            z.build3HopMulticall(user, false, tokenIn, tokenOut, amount, 50, block.timestamp + 600);
        console2.log("exact-in build gas:", g - gasleft());
        uint256 minOut = z.limit(false, c.amountOut, 50);
        assertGt(minOut, 0, "no output promised");

        _fund(tokenIn, amount);
        uint256 before = _bal(tokenOut, user);
        vm.prank(user);
        (bool ok, bytes memory ret) = router.call{value: mv}(mc);
        assertTrue(ok, _why(ret));
        assertGe(_bal(tokenOut, user) - before, minOut, "delivered less than the promised minimum");
    }

    function _exactOut(zQuoter3HopL2 z, address tokenIn, address tokenOut, uint256 want, uint256 budget) internal {
        uint256 g = gasleft();
        (Quote memory a,,,, bytes memory mc, uint256 mv) =
            z.build3HopMulticall(user, true, tokenIn, tokenOut, want, 50, block.timestamp + 600);
        console2.log("exact-out build gas:", g - gasleft());
        uint256 inMax = z.limit(true, a.amountIn, 50);
        assertLe(inMax, budget, "the route needs more than the test funds");

        _fund(tokenIn, budget);
        uint256 inBefore = _bal(tokenIn, user);
        uint256 outBefore = _bal(tokenOut, user);
        vm.prank(user);
        (bool ok, bytes memory ret) = router.call{value: mv}(mc);
        assertTrue(ok, _why(ret));
        assertEq(_bal(tokenOut, user) - outBefore, want, "exact-out did not deliver the exact amount");
        assertLe(inBefore - _bal(tokenIn, user), inMax, "spent more than the embedded maximum");
        assertEq(_bal(tokenIn, router), 0, "input stranded on the router");
    }

    function _fund(address token, uint256 amount) internal {
        if (token == address(0)) {
            vm.deal(user, amount);
        } else {
            deal(token, user, amount);
            vm.prank(user);
            IERC20T(token).approve(router, type(uint256).max);
        }
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return token == address(0) ? who.balance : IERC20T(token).balanceOf(who);
    }

    function _why(bytes memory ret) internal pure returns (string memory) {
        return ret.length == 0 ? "router reverted without data" : string.concat("router reverted: ", vm.toString(ret));
    }
}
