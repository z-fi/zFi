// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {zQuoterRobinhood} from "../src/zQuoterRobinhood.sol";

address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
address constant TKN = 0x01637b14B7378B99dE75A64d50656d98488D9a4d;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

/// @dev Against the REAL deployed router on 4663 — no `deployCodeTo`, no etched
/// copy. This is the last thing an etched test cannot tell us: that calldata the
/// quoter builds actually executes on the contract that is really there.
contract RHLiveTest is Test {
    zQuoterRobinhood quoter;
    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork("https://rpc.mainnet.chain.robinhood.com");
        quoter = new zQuoterRobinhood();
        vm.deal(alice, 100 ether);
    }

    function testLiveRouterIsTheOneTheQuoterNames() public view {
        assertGt(ZROUTER.code.length, 0, "router must be deployed");
        assertEq(ZROUTER.code.length, 14084, "unexpected router runtime");
    }

    function testQuoterBuiltSwapExecutesOnTheLiveRouter() public {
        (zQuoterRobinhood.Quote memory best, bytes memory callData,, uint256 msgValue) =
            quoter.buildBestSwap(alice, false, address(0), TKN, 1 ether, 200, block.timestamp + 300);

        assertGt(best.amountOut, 0, "quoter found no route");

        uint256 before = IERC20(TKN).balanceOf(alice);
        vm.prank(alice);
        (bool ok,) = ZROUTER.call{value: msgValue}(callData);
        assertTrue(ok, "quoter calldata reverted on the live router");

        uint256 got = IERC20(TKN).balanceOf(alice) - before;
        assertGt(got, 0, "nothing delivered");
        // Quote and execution must agree within the slippage the quoter embedded.
        assertApproxEqRel(got, best.amountOut, 0.02e18, "quote diverged from execution");
        assertEq(ZROUTER.balance, 0, "ether stranded in the live router");
        emit log_named_uint("quoted", best.amountOut);
        emit log_named_uint("received", got);
    }
}
