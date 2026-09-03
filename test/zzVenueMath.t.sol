// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zRouterLiteBase} from "../src/zRouterLiteBase.sol";
import {zQuoterBase} from "../src/zQuoterBase.sol";

interface IE {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract VenueMath is Test {
    address constant W = 0x4200000000000000000000000000000000000006;
    address constant U = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant A = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant CB = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant ZR = 0x000000000000FB114709235f1ccBFfb925F600e4;

    zRouterLiteBase router;
    zQuoterBase quoter;
    address alice = makeAddr("alice");
    address dep = makeAddr("dep");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")));
        vm.etch(alice, "");
        vm.etch(dep, "");
        vm.prank(dep, dep);
        deployCodeTo("zRouterLiteBase.sol:zRouterLiteBase", ZR);
        router = zRouterLiteBase(payable(ZR));
        quoter = new zQuoterBase();
        vm.deal(alice, 100000 ether);
    }

    // ---- v3 exact-in, both directions, big (multi-tick) ----
    function testV3BigExactInBothWays() public {
        uint24[4] memory tiers = [uint24(100), 500, 3000, 10000];
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            (, uint256 q) = quoter.quoteV3(false, address(0), U, tiers[i], 300 ether);
            if (q != 0) {
                vm.prank(alice);
                (, uint256 got) = router.swapV3{value: 300 ether}(alice, false, tiers[i], address(0), U, 300 ether, 0, block.timestamp);
                assertEq(got, q, string.concat("v3 buy tier ", vm.toString(tiers[i])));
            }
            vm.revertToState(snap);
            snap = vm.snapshotState();
            (, uint256 q2) = quoter.quoteV3(false, U, address(0), tiers[i], 2_000_000e6);
            if (q2 != 0) {
                deal(U, alice, 2_000_000e6);
                vm.startPrank(alice);
                IE(U).approve(address(router), type(uint256).max);
                (, uint256 got2) = router.swapV3(alice, false, tiers[i], U, address(0), 2_000_000e6, 0, block.timestamp);
                vm.stopPrank();
                assertEq(got2, q2, string.concat("v3 sell tier ", vm.toString(tiers[i])));
            }
            vm.revertToState(snap);
        }
    }

    function testV3BigExactOutBothWays() public {
        uint24[4] memory tiers = [uint24(100), 500, 3000, 10000];
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            (uint256 qin,) = quoter.quoteV3(true, address(0), U, tiers[i], 500_000e6);
            if (qin != 0) {
                vm.prank(alice);
                (uint256 gin,) = router.swapV3{value: qin}(alice, true, tiers[i], address(0), U, 500_000e6, 0, block.timestamp);
                assertEq(gin, qin, string.concat("v3 xout buy tier ", vm.toString(tiers[i])));
            }
            vm.revertToState(snap);
            snap = vm.snapshotState();
            (uint256 qin2,) = quoter.quoteV3(true, U, address(0), tiers[i], 100 ether);
            if (qin2 != 0) {
                deal(U, alice, qin2);
                vm.startPrank(alice);
                IE(U).approve(address(router), type(uint256).max);
                (uint256 gin2,) = router.swapV3(alice, true, tiers[i], U, address(0), 100 ether, 0, block.timestamp);
                vm.stopPrank();
                assertEq(gin2, qin2, string.concat("v3 xout sell tier ", vm.toString(tiers[i])));
            }
            vm.revertToState(snap);
        }
    }

    function testAeroCLAllSpacingsBothWays() public {
        int24[6] memory sp = [int24(1), 10, 50, 100, 200, 2000];
        for (uint256 i; i < 6; ++i) {
            uint256 snap = vm.snapshotState();
            (, uint256 q) = quoter.quoteAeroCL(false, address(0), U, sp[i], 200 ether);
            if (q != 0) {
                vm.prank(alice);
                (, uint256 got) = router.swapAeroCL{value: 200 ether}(alice, false, sp[i], address(0), U, 200 ether, 0, block.timestamp);
                assertEq(got, q, string.concat("cl buy sp ", vm.toString(int256(sp[i]))));
            }
            vm.revertToState(snap);
            snap = vm.snapshotState();
            (uint256 qin,) = quoter.quoteAeroCL(true, address(0), U, sp[i], 200_000e6);
            if (qin != 0) {
                vm.prank(alice);
                (uint256 gin,) = router.swapAeroCL{value: qin}(alice, true, sp[i], address(0), U, 200_000e6, 0, block.timestamp);
                assertEq(gin, qin, string.concat("cl xout buy sp ", vm.toString(int256(sp[i]))));
            }
            vm.revertToState(snap);
            snap = vm.snapshotState();
            (uint256 qin2,) = quoter.quoteAeroCL(true, U, address(0), sp[i], 50 ether);
            if (qin2 != 0) {
                deal(U, alice, qin2);
                vm.startPrank(alice);
                IE(U).approve(address(router), type(uint256).max);
                (uint256 gin2,) = router.swapAeroCL(alice, true, sp[i], U, address(0), 50 ether, 0, block.timestamp);
                vm.stopPrank();
                assertEq(gin2, qin2, string.concat("cl xout sell sp ", vm.toString(int256(sp[i]))));
            }
            vm.revertToState(snap);
        }
    }

    function testAeroCLAeroPairs() public {
        int24[6] memory sp = [int24(1), 10, 50, 100, 200, 2000];
        for (uint256 i; i < 6; ++i) {
            uint256 snap = vm.snapshotState();
            (, uint256 q) = quoter.quoteAeroCL(false, U, A, sp[i], 500_000e6);
            if (q != 0) {
                deal(U, alice, 500_000e6);
                vm.startPrank(alice);
                IE(U).approve(address(router), type(uint256).max);
                (, uint256 got) = router.swapAeroCL(alice, false, sp[i], U, A, 500_000e6, 0, block.timestamp);
                vm.stopPrank();
                assertEq(got, q, string.concat("cl U->A sp ", vm.toString(int256(sp[i]))));
            }
            vm.revertToState(snap);
        }
    }

    function testV4BothWaysAllTiers() public {
        uint24[4] memory tiers = [uint24(100), 500, 3000, 10000];
        int24[4] memory sps = [int24(1), 10, 60, 200];
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            (, uint256 q) = quoter.quoteV4(false, address(0), U, tiers[i], 100 ether);
            if (q != 0) {
                vm.prank(alice);
                (, uint256 got) = router.swapV4{value: 100 ether}(alice, false, tiers[i], sps[i], address(0), U, 100 ether, 0, block.timestamp);
                assertEq(got, q, string.concat("v4 buy tier ", vm.toString(tiers[i])));
            }
            vm.revertToState(snap);
            snap = vm.snapshotState();
            (uint256 qin,) = quoter.quoteV4(true, U, address(0), tiers[i], 30 ether);
            if (qin != 0) {
                deal(U, alice, qin);
                vm.startPrank(alice);
                IE(U).approve(address(router), type(uint256).max);
                (uint256 gin,) = router.swapV4(alice, true, tiers[i], sps[i], U, address(0), 30 ether, 0, block.timestamp);
                vm.stopPrank();
                assertEq(gin, qin, string.concat("v4 xout sell tier ", vm.toString(tiers[i])));
            }
            vm.revertToState(snap);
        }
    }

    function testV2ExactOutMatches() public {
        (uint256 qin,) = quoter.quoteV2(true, address(0), U, 50_000e6);
        if (qin == 0) return;
        vm.prank(alice);
        (uint256 gin, uint256 gout) = router.swapV2{value: qin}(alice, true, address(0), U, 50_000e6, 0, block.timestamp);
        assertEq(gin, qin, "v2 exact-out drift");
        assertEq(gout, 50_000e6);
    }
}
