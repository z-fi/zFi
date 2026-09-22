// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {PM} from "../src/PM.sol";

interface IFactory {
    function create2Deploy(bytes calldata creationCode, bytes32 salt) external payable returns (address);
}

interface IWstETH {
    function balanceOf(address) external view returns (uint256);
    function getWstETHByStETH(uint256) external view returns (uint256);
}

/// Deploys the EXACT mined initcode (solc 0.8.37, `FOUNDRY_PROFILE=pm`) through the real
/// factory, so a mismatch between the committed artifact and the published address fails here.
contract PMDeployTest is Test {
    address constant FACTORY = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
    }

    function testPMDeploysToMinedAddressAndWorks() public {
        bytes memory initcode = vm.readFileBinary("deploy/PM.initcode.bin");
        bytes32 salt = vm.parseBytes32(vm.trim(vm.readFile("deploy/PM.salt.txt")));
        address predicted = vm.parseAddress(vm.trim(vm.readFile("deploy/PM.address.txt")));

        address deployed = predicted.code.length == 0 ? IFactory(FACTORY).create2Deploy(initcode, salt) : predicted;
        assertEq(deployed, predicted, "address does not match the mined artifact");
        assertLe(deployed.code.length, 24_576);

        PM pm = PM(payable(deployed));
        vm.deal(deployed, 0);
        address resolver = address(0xA11CE);
        address yes = address(0xB0B);
        address no = address(0xCA7);
        vm.etch(resolver, "");
        vm.etch(yes, "");
        vm.etch(no, "");
        vm.deal(yes, 10 ether);
        vm.deal(no, 10 ether);

        vm.prank(resolver);
        pm.setResolverFeeBps(100);
        uint48 close = uint48(block.timestamp + 1 days);
        uint256 id = pm.createMarket("deploy smoke", resolver, WSTETH, close, true, 200, 1_000);

        uint256 expected = IWstETH(WSTETH).getWstETHByStETH(1 ether);
        vm.prank(yes);
        uint256 y = pm.betETH{value: 1 ether}(id, true, yes, 0, "");
        assertApproxEqAbs(y, expected, 2);
        vm.prank(no);
        pm.betETH{value: 1 ether}(id, false, no, 0, "");

        vm.warp(close);
        vm.prank(resolver);
        pm.resolve(id, true);
        vm.prank(yes);
        uint256 paid = pm.claim(id, yes);
        assertEq(IWstETH(WSTETH).balanceOf(yes), paid);
        vm.prank(resolver);
        pm.withdrawFees(WSTETH, resolver);
        assertLe(IWstETH(WSTETH).balanceOf(deployed), 1);
    }
}
