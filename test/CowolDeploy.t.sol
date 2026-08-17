// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {Cowol} from "../src/forwarders/Cowol.sol";

interface IFactory {
    function create2Deploy(bytes calldata creationCode, bytes32 salt) external payable returns (address);
}

/// Deploys the EXACT mined initcode through the real factory, so a mismatch
/// between the committed artifact and the compiled source fails here rather
/// than after the address has been published. Same shape as CollectolDeploy.
contract CowolDeployTest is Test {
    address constant FACTORY = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    function setUp() public {
        // Defaulted, not required: an unset ETH_RPC_URL made this suite fail at
        // setUp with "environment variable not found", which reads as a broken
        // test rather than a missing variable. Matches foundry.toml's eth_rpc_url.
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")));
    }

    function testCowolDeploysToMinedAddress() public {
        bytes memory initcode = vm.readFileBinary("deploy/Cowol.initcode.bin");
        bytes32 salt = vm.parseBytes32(vm.trim(vm.readFile("deploy/Cowol.salt.txt")));
        address predicted = vm.parseAddress(vm.trim(vm.readFile("deploy/Cowol.address.txt")));

        address deployed =
            predicted.code.length == 0 ? IFactory(FACTORY).create2Deploy(initcode, salt) : predicted;

        assertEq(deployed, predicted, "address does not match the mined artifact");
        assertGt(deployed.code.length, 0);

        // This must be the ORDER-KEYED revision: `orders` and `committed`
        // present, no token-keyed accessor surviving. Checked by selector so a
        // stale artifact cannot pass this file.
        (bool hasOrders,) = deployed.staticcall(abi.encodeWithSignature("orders(bytes32)", bytes32(0)));
        (bool hasCommitted,) = deployed.staticcall(abi.encodeWithSignature("committed(address)", address(0)));
        assertTrue(hasOrders, "orders(bytes32) missing - stale artifact");
        assertTrue(hasCommitted, "committed(address) missing - stale artifact");

        (bool hasOldExpiry,) = deployed.staticcall(abi.encodeWithSignature("expiry(address)", address(0)));
        (bool hasOldRecipient,) = deployed.staticcall(abi.encodeWithSignature("recipient(address)", address(0)));
        assertFalse(hasOldExpiry, "unexpected token-keyed expiry");
        assertFalse(hasOldRecipient, "unexpected token-keyed recipient");

        // A digest nobody registered is not a signature, and recovering one is
        // not a withdrawal.
        assertEq(Cowol(payable(deployed)).isValidSignature(bytes32(uint256(1)), ""), bytes4(0xffffffff));
        vm.expectRevert();
        Cowol(payable(deployed)).recover(bytes32(uint256(1)));

        // Sanity: the settlement pull target is unchanged.
        assertEq(VAULT_RELAYER, 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110);
    }
}
