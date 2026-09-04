// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {V4PortL2} from "../src/forwarders/V4PortL2.sol";

address constant LIVE_PORT = 0x000000dfb53Fa7f1c486470034741d5BCBE14BE9;
address constant PM_MAINNET = 0x000000000004444c5dc75cB358380D2e3dE08A90;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

interface IERC20 { function balanceOf(address) external view returns (uint256); }

struct Key { address c0; address c1; uint24 fee; int24 ts; address hooks; }

interface IPort {
    function swap(Key calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut,
        address recipient, uint256 deadline) external payable returns (uint256);
}

/// @dev The L2 variant only moves the PoolManager from a constant to a
/// constructor immutable. Given the same manager it must be the same contract,
/// so prove it against the one that is actually live rather than assume.
contract V4PortL2EquivTest is Test {
    V4PortL2 port;
    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        port = new V4PortL2(PM_MAINNET);
        vm.deal(alice, 100 ether);
    }

    function testLiveOriginalIsStillThere() public view {
        assertEq(LIVE_PORT.code.length, 3553, "the deployed V4Port");
    }

    function testSameSwapThroughBoth() public {
        Key memory k = Key(address(0), USDC, 500, 10, address(0));

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 outNew = IPort(address(port)).swap{value: 1 ether}(k, true, 1 ether, 0, alice, block.timestamp + 60);
        vm.revertToState(snap);

        vm.prank(alice);
        uint256 outOld = IPort(LIVE_PORT).swap{value: 1 ether}(k, true, 1 ether, 0, alice, block.timestamp + 60);

        assertGt(outOld, 0, "live port produced nothing");
        assertEq(outNew, outOld, "L2 variant must match the live port exactly");
        emit log_named_uint("USDC out (both)", outNew);
    }
}
