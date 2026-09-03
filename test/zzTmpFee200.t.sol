// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zRouterLiteBase} from "../src/zRouterLiteBase.sol";
import {zQuoterBase} from "../src/zQuoterBase.sol";

interface IE {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract TmpFee200 is Test {
    address constant U = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ZR = 0x000000000000FB114709235f1ccBFfb925F600e4;
    zRouterLiteBase router;
    zQuoterBase quoter;
    address alice = makeAddr("alice");
    address dep = makeAddr("dep");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        vm.etch(alice, "");
        vm.etch(dep, "");
        vm.prank(dep, dep);
        deployCodeTo("zRouterLiteBase.sol:zRouterLiteBase", ZR);
        router = zRouterLiteBase(payable(ZR));
        quoter = new zQuoterBase();
        vm.deal(alice, 1000000 ether);
    }

    function testScan() public {
        uint256[5] memory amts = [uint256(0.01 ether), 0.1 ether, 1 ether, 10 ether, 100 ether];
        for (uint256 i; i < 5; ++i) {
            uint256 snap = vm.snapshotState();
            (, uint256 q) = quoter.quoteV3(false, address(0), U, 200, amts[i]);
            uint256 got;
            if (q != 0) {
                vm.prank(alice);
                (, got) = router.swapV3{value: amts[i]}(alice, false, 200, address(0), U, amts[i], 0, block.timestamp);
            }
            emit log_named_uint("in", amts[i]);
            emit log_named_uint("  quoted", q);
            emit log_named_uint("  actual", got);
            vm.revertToState(snap);
        }
        uint256[4] memory uamts = [uint256(100e6), 10_000e6, 100_000e6, 1_000_000e6];
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            (, uint256 q) = quoter.quoteV3(false, U, address(0), 200, uamts[i]);
            uint256 got;
            if (q != 0) {
                deal(U, alice, uamts[i]);
                vm.startPrank(alice);
                IE(U).approve(address(router), type(uint256).max);
                (, got) = router.swapV3(alice, false, 200, U, address(0), uamts[i], 0, block.timestamp);
                vm.stopPrank();
            }
            emit log_named_uint("usdc in", uamts[i]);
            emit log_named_uint("  quoted", q);
            emit log_named_uint("  actual", got);
            vm.revertToState(snap);
        }
    }
}
