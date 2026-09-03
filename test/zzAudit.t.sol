// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zRouterLiteBase} from "../src/zRouterLiteBase.sol";
import {zQuoterBase} from "../src/zQuoterBase.sol";

interface IErc20Aud {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract BaseAudit is Test {
    address constant W = 0x4200000000000000000000000000000000000006;
    address constant U = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant A = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant CB = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant ZR = 0x000000000000FB114709235f1ccBFfb925F600e4;

    zRouterLiteBase router;
    zQuoterBase quoter;
    address alice = makeAddr("alice");
    address deployer = makeAddr("deployer");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")));
        vm.etch(alice, "");
        vm.etch(deployer, "");
        vm.prank(deployer, deployer);
        deployCodeTo("zRouterLiteBase.sol:zRouterLiteBase", ZR);
        router = zRouterLiteBase(payable(ZR));
        quoter = new zQuoterBase();
        vm.deal(alice, 1000 ether);
    }

    function _need(uint256 q) internal { if (q == 0) vm.skip(true); }

    function testExactOutDirectEthIn() public {
        (zQuoterBase.Quote memory best, bytes memory cd,, uint256 mv) =
            quoter.buildBestSwap(alice, true, address(0), U, 1000e6, 100, block.timestamp);
        _need(best.amountIn);
        emit log_named_uint("venue", uint256(best.source));
        vm.prank(alice);
        (bool ok, bytes memory e) = address(router).call{value: mv}(cd);
        if (!ok) emit log_named_bytes("revert", e);
        assertTrue(ok, "exact-out direct reverted");
        assertEq(IErc20Aud(U).balanceOf(alice), 1000e6, "not exact output");
        assertEq(address(router).balance, 0, "ETH stranded");
        assertEq(IErc20Aud(W).balanceOf(address(router)), 0, "WETH stranded");
    }

    function testExactOutMulticallEthIn() public {
        (zQuoterBase.Quote memory a,,, bytes memory mc, uint256 mv) =
            quoter.buildBestSwapViaETHMulticall(alice, alice, true, address(0), CB, 1e6, 200, block.timestamp);
        _need(a.amountIn);
        vm.prank(alice);
        (bool ok, bytes memory e) = address(router).call{value: mv}(mc);
        if (!ok) emit log_named_bytes("revert", e);
        assertTrue(ok, "exact-out multicall reverted");
        assertEq(IErc20Aud(CB).balanceOf(alice), 1e6, "wrong output");
        assertEq(address(router).balance, 0, "ETH stranded");
        assertEq(IErc20Aud(CB).balanceOf(address(router)), 0, "out stranded");
        assertEq(IErc20Aud(W).balanceOf(address(router)), 0, "WETH stranded");
    }

    function testExactOutTokenIn() public {
        (zQuoterBase.Quote memory best, bytes memory cd,,) =
            quoter.buildBestSwap(alice, true, U, A, 100e18, 200, block.timestamp);
        _need(best.amountIn);
        deal(U, alice, quoter.limit(true, best.amountIn, 200));
        vm.startPrank(alice);
        IErc20Aud(U).approve(address(router), type(uint256).max);
        (bool ok, bytes memory e) = address(router).call(cd);
        vm.stopPrank();
        if (!ok) emit log_named_bytes("revert", e);
        assertTrue(ok, "exact-out token-in reverted");
        assertEq(IErc20Aud(A).balanceOf(alice), 100e18, "wrong output");
        assertEq(IErc20Aud(U).balanceOf(address(router)), 0, "USDC stranded");
        assertEq(IErc20Aud(A).balanceOf(address(router)), 0, "AERO stranded");
    }

    function testSplitTokenIn() public {
        (zQuoterBase.Quote[2] memory legs, bytes memory mc, uint256 mv) =
            quoter.buildSplitSwap(alice, U, A, 10_000e6, 200, block.timestamp);
        _need(legs[0].amountOut + legs[1].amountOut);
        assertEq(mv, 0);
        deal(U, alice, 10_000e6);
        vm.startPrank(alice);
        IErc20Aud(U).approve(address(router), type(uint256).max);
        (bool ok, bytes memory e) = address(router).call(mc);
        vm.stopPrank();
        if (!ok) emit log_named_bytes("revert", e);
        assertTrue(ok, "split token-in reverted");
        assertGt(IErc20Aud(A).balanceOf(alice), 0);
        assertEq(IErc20Aud(A).balanceOf(address(router)), 0, "AERO stranded");
    }

    function testHybridTokenIn() public {
        (zQuoterBase.Quote[2] memory legs, bytes memory mc, uint256 mv) =
            quoter.buildHybridSplit(alice, U, A, 10_000e6, 200, block.timestamp);
        _need(legs[0].amountOut + legs[1].amountOut);
        assertEq(mv, 0);
        deal(U, alice, 10_000e6);
        vm.startPrank(alice);
        IErc20Aud(U).approve(address(router), type(uint256).max);
        (bool ok, bytes memory e) = address(router).call(mc);
        vm.stopPrank();
        if (!ok) emit log_named_bytes("revert", e);
        assertTrue(ok, "hybrid token-in reverted");
        assertGt(IErc20Aud(A).balanceOf(alice), 0);
        assertEq(IErc20Aud(W).balanceOf(address(router)), 0, "WETH stranded");
    }

    function testHubExactInTokenIn() public {
        (zQuoterBase.Quote memory a, zQuoterBase.Quote memory b,, bytes memory mc,) =
            quoter.buildBestSwapViaETHMulticall(alice, alice, false, U, A, 50_000e6, 200, block.timestamp);
        _need(a.amountOut);
        emit log_named_uint("b.out", b.amountOut);
        deal(U, alice, 50_000e6);
        vm.startPrank(alice);
        IErc20Aud(U).approve(address(router), type(uint256).max);
        (bool ok, bytes memory e) = address(router).call(mc);
        vm.stopPrank();
        if (!ok) emit log_named_bytes("revert", e);
        assertTrue(ok, "hub exact-in reverted");
        assertGt(IErc20Aud(A).balanceOf(alice), 0);
    }
}
