// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zQuoterBase} from "../src/zQuoterBase.sol";

contract BaseGas is Test {
    address constant U = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant A = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    zQuoterBase quoter;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")), 50830000);
        quoter = new zQuoterBase();
    }

    function testGasOfBuilders() public {
        uint256 g = gasleft();
        quoter.getQuotes(false, address(0), U, 1 ether);
        emit log_named_uint("getQuotes", g - gasleft());

        g = gasleft();
        quoter.buildBestSwapViaETHMulticall(address(1), address(1), false, U, A, 50_000e6, 100, block.timestamp);
        emit log_named_uint("viaETHMulticall", g - gasleft());

        g = gasleft();
        quoter.buildHybridSplit(address(1), U, A, 50_000e6, 100, block.timestamp);
        emit log_named_uint("hybridSplit", g - gasleft());

        g = gasleft();
        quoter.buildSplitSwap(address(1), U, A, 50_000e6, 100, block.timestamp);
        emit log_named_uint("splitSwap", g - gasleft());
    }
}
