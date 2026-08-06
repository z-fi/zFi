// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction} from "../src/dao/ZorgConviction.sol";

interface IWei {
    function ownerOf(uint256) external view returns (address);
    function approve(address, uint256) external;
    function getFullName(uint256) external view returns (string memory);
    function computeId(string calldata) external pure returns (uint256);
}

/// Dry-runs claimZorgWei() as the actual zorg.wei holder, on live state, so the
/// consequences are visible before anyone signs.
contract ZorgClaimSimTest is Test {
    ZorgConviction constant GOV = ZorgConviction(payable(0x0000006D936bA3653b8854490E16E782cd32a9a8));
    IWei constant WEI = IWei(0x0000000000696760E15f265e828DB644A0c242EB);
    address constant HOLDER = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_698_200);
    }

    function testClaimZorgWeiAsHolder() public {
        uint256 id = GOV.zorgWeiId();
        emit log_named_string("name", WEI.getFullName(id));
        emit log_named_address("owner before", WEI.ownerOf(id));
        emit log_named_string("domainClaimed before", GOV.domainClaimed() ? "true" : "false");

        // The governor pulls the name with transferFrom, so it must be approved.
        vm.startPrank(HOLDER);
        WEI.approve(address(GOV), id);
        GOV.claimZorgWei();
        vm.stopPrank();

        emit log_named_address("owner after", WEI.ownerOf(id));
        emit log_named_string("domainClaimed after", GOV.domainClaimed() ? "true" : "false");

        assertEq(WEI.ownerOf(id), address(GOV), "name now held by the governor");
        assertTrue(GOV.domainClaimed(), "claimed");

        // It is one-way from the holder's side: no function hands it back.
        vm.prank(HOLDER);
        vm.expectRevert();
        WEI.approve(HOLDER, id);
    }
}
