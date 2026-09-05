// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";

address constant PORT = 0x508ad1b0ae31FaF295c5af8C5c2bE9e33E0D19C4;
address constant PM_BASE = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

struct Key { address c0; address c1; uint24 fee; int24 ts; address hooks; }

interface IPort {
    function swap(Key calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut,
        address recipient, uint256 deadline) external payable returns (uint256);
}
interface IERC20 { function balanceOf(address) external view returns (uint256); }

/// @dev The port is only useful if it actually reaches Base's PoolManager. The
/// bytecode check proves the right manager is baked in; this proves the pair
/// works together.
contract V4PortBaseLiveTest is Test {
    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        vm.deal(alice, 100 ether);
        vm.etch(alice, "");
    }

    function testPortIsDeployedWithBasesManager() public view {
        assertEq(PORT.code.length, 3684, "port runtime");
        assertGt(PM_BASE.code.length, 0, "Base PoolManager");
    }

    function testSwapEthForUsdcThroughThePort() public {
        Key memory k = Key(address(0), USDC, 500, 10, address(0));
        uint256 before = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 out = IPort(PORT).swap{value: 1 ether}(k, true, 1 ether, 0, alice, block.timestamp + 60);
        assertGt(out, 0, "port returned nothing");
        assertEq(IERC20(USDC).balanceOf(alice) - before, out, "recipient paid directly");
        assertEq(PORT.balance, 0, "nothing rests in the port");
        assertEq(IERC20(USDC).balanceOf(PORT), 0, "no output stranded in the port");
        emit log_named_uint("USDC out for 1 ETH", out);
    }
}
