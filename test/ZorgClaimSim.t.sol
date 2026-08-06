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

    /// The name is custody, not a one-way burn: `_execute` protects only the two
    /// escrowed assets by name, so the DAO can move zorg.wei back out whenever it
    /// wants. Worth proving rather than assuming, since "the contract ate our
    /// domain" would be discovered far too late.
    function testMolochCanReclaimTheDomain() public {
        uint256 id = GOV.zorgWeiId();
        vm.startPrank(HOLDER);
        WEI.approve(address(GOV), id);
        GOV.claimZorgWei();
        vm.stopPrank();
        assertEq(WEI.ownerOf(id), address(GOV), "governor holds it");

        // Moloch routes an ordinary transferFrom through the governor's escape hatch.
        vm.prank(GOV.dao());
        GOV.execute(
            address(WEI), 0,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(GOV), HOLDER, id)
        );
        emit log_named_address("owner after DAO reclaim", WEI.ownerOf(id));
        assertEq(WEI.ownerOf(id), HOLDER, "returned to the holder");

        // But the flag is one-way, so the contract cannot re-claim it by itself.
        assertTrue(GOV.domainClaimed(), "domainClaimed stays true");
        vm.startPrank(HOLDER);
        WEI.approve(address(GOV), id);
        vm.expectRevert(ZorgConviction.DomainAlreadyClaimed.selector);
        GOV.claimZorgWei();
        vm.stopPrank();
    }

    /// Ownership is the point: registering `exec.zorg.wei` is a subdomain mint on
    /// the parent name, so the governor has to hold the parent to do it. Pointing
    /// a resolver at the governor would not grant that.
    function testExecRoleNeedsTheNameItself() public {
        uint256 id = GOV.zorgWeiId();

        // Before the claim, the DAO cannot install the role at all.
        vm.prank(GOV.dao());
        vm.expectRevert(ZorgConviction.DomainNotClaimed.selector);
        GOV.installExecRoleName(address(0xE11C));

        vm.startPrank(HOLDER);
        WEI.approve(address(GOV), id);
        GOV.claimZorgWei();
        vm.stopPrank();

        address execHolder = address(0xE11C);
        vm.prank(GOV.dao());
        GOV.installExecRoleName(execHolder);

        uint256 execId = GOV.execZorgWeiId();
        emit log_named_string("subdomain", WEI.getFullName(execId));
        emit log_named_address("exec credential held by", WEI.ownerOf(execId));
        assertEq(WEI.ownerOf(execId), execHolder, "exec.zorg.wei minted to the operator");
        assertTrue(GOV.rolesInstalled(), "roles installed");

        // And the credential is what gates the emergency pause.
        vm.prank(execHolder);
        GOV.emergencyPause();
        assertTrue(GOV.paused(), "exec holder can pause");
        vm.prank(GOV.dao());
        GOV.resume();
        assertFalse(GOV.paused(), "DAO resumes");
    }
}
