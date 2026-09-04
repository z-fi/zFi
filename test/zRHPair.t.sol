// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {zQuoterRobinhood} from "../src/zQuoterRobinhood.sol";

address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
address constant ZQUOTER = 0x000000bd2DB80567c23E353ca95a251c573cBf9B;
address constant TKN = 0x01637b14B7378B99dE75A64d50656d98488D9a4d;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

/// @dev Both halves as really deployed — nothing etched, nothing constructed
/// here. The quoter at its own address builds calldata; the router at its own
/// address executes it.
contract RHPairTest is Test {
    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork("https://rpc.mainnet.chain.robinhood.com");
        vm.deal(alice, 100 ether);
    }

    function testBothHalvesAreDeployed() public view {
        assertEq(ZROUTER.code.length, 14084, "router");
        assertEq(ZQUOTER.code.length, 19712, "quoter");
    }

    function testDeployedQuoterDrivesDeployedRouter() public {
        (zQuoterRobinhood.Quote memory best, bytes memory cd,, uint256 mv) = zQuoterRobinhood(ZQUOTER)
            .buildBestSwap(alice, false, address(0), TKN, 1 ether, 200, block.timestamp + 300);
        assertGt(best.amountOut, 0, "no route");

        uint256 before = IERC20(TKN).balanceOf(alice);
        vm.prank(alice);
        (bool ok,) = ZROUTER.call{value: mv}(cd);
        assertTrue(ok, "reverted on the live router");

        uint256 got = IERC20(TKN).balanceOf(alice) - before;
        assertEq(got, best.amountOut, "quote must equal execution");
        assertEq(ZROUTER.balance, 0, "ether stranded");
        emit log_named_uint("delivered", got);
    }

    /// @dev The ETH hub path, which is where stranded-funds bugs surface.
    function testDeployedPairViaEthMulticall() public {
        (,, , bytes memory mc, uint256 mv) = zQuoterRobinhood(ZQUOTER)
            .buildBestSwapViaETHMulticall(alice, alice, false, address(0), TKN, 1 ether, 200, block.timestamp + 300);
        vm.prank(alice);
        (bool ok,) = ZROUTER.call{value: mv}(mc);
        assertTrue(ok, "multicall reverted");
        assertGt(IERC20(TKN).balanceOf(alice), 0, "nothing delivered");
        assertEq(ZROUTER.balance, 0, "ether stranded in router");
    }
}
