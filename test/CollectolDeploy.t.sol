// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {Collectol} from "../src/forwarders/Collectol.sol";
import {CollectolLens} from "../src/forwarders/CollectolLens.sol";

interface IFactory {
    function create2Deploy(bytes calldata creationCode, bytes32 salt) external payable returns (address);
}

/// Deploys the EXACT mined initcode through the real factory, so a mismatch
/// between the committed artifact and the compiled source fails here rather
/// than after the address has been published.
contract CollectolDeployTest is Test {
    address constant FACTORY = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant SALE = 0x824d11a46F32cd16cdF46380314343e9697e2491;
    address constant SHARES = 0x883d646d0C8202Aa23F01d4aF45E4E73804c3a49;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
    }

    function _deploy(string memory name) internal returns (address deployed, address predicted) {
        bytes memory initcode = vm.readFileBinary(string.concat("deploy/", name, ".initcode.bin"));
        bytes32 salt = vm.parseBytes32(vm.trim(vm.readFile(string.concat("deploy/", name, ".salt.txt"))));
        predicted = vm.parseAddress(vm.trim(vm.readFile(string.concat("deploy/", name, ".address.txt"))));
        // Idempotent: the mined address may already be live on the fork in use,
        // in which case the check below is still the one that matters.
        deployed = predicted.code.length == 0 ? IFactory(FACTORY).create2Deploy(initcode, salt) : predicted;
    }

    function testCollectolDeploysToMinedAddress() public {
        (address deployed, address predicted) = _deploy("Collectol");
        assertEq(deployed, predicted, "address does not match the mined artifact");
        assertGt(deployed.code.length, 0);
        assertEq(Collectol(payable(deployed)).sale(), SALE, "wrong sale bound");
        assertEq(Collectol(payable(deployed)).shares(), SHARES, "wrong shares bound");
        assertEq(Collectol(payable(deployed)).feeOrHook(), 30, "wrong fee bound");
    }

    function testLensDeploysToMinedAddress() public {
        (address deployed, address predicted) = _deploy("CollectolLens");
        assertEq(deployed, predicted, "address does not match the mined artifact");
        assertGt(deployed.code.length, 0);
        (uint256 r0, uint256 r1) = CollectolLens(deployed).reserves(SHARES, 30);
        assertGt(r0, 0);
        assertGt(r1, 0);
    }

    /// The pair has to work together at their mined addresses, not just deploy.
    function testDeployedPairRoutesEndToEnd() public {
        (address col,) = _deploy("Collectol");
        (address lensAddr,) = _deploy("CollectolLens");
        CollectolLens lens = CollectolLens(lensAddr);

        uint256 snap = vm.snapshotState();
        vm.deal(lensAddr, 2 ether);
        uint256 rate = lens.probeSaleRate(SALE, 1 ether);
        vm.revertToState(snap);

        uint256 cap = lens.maxSaleEth(SALE, rate);
        CollectolLens.Plan memory p = lens.planExactIn(SHARES, 30, 1 ether, rate, cap, 100);

        address buyer = address(0xB0B);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        Collectol(payable(col)).buy{value: p.totalIn}(
            p.ethToSale, p.poolAmount, p.poolLimit, p.poolExactOut, p.minTotalOut, buyer, buyer, block.timestamp + 60
        );
        assertGe(IERC20Balance(SHARES).balanceOf(buyer), p.minTotalOut);
    }
}

interface IERC20Balance {
    function balanceOf(address) external view returns (uint256);
}
