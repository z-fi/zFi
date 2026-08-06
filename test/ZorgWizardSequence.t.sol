// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction} from "../src/dao/ZorgConviction.sol";

interface IERC721Min {
    function ownerOf(uint256) external view returns (address);
    function approve(address, uint256) external;
}
interface IERC20Min {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// Replays the EXACT call sequence dapp/zlist's onboarding wizard composes,
/// pranked as a real holder against live mainnet state.
///
/// The wizard moves other people's money and had never been executed anywhere,
/// so "the calldata decodes correctly" is not enough. This runs the sequence end
/// to end and asserts the property it exists to guarantee: a bond opened at
/// tier 3 and then eternalized keeps the 1.50x rate permanently.
contract ZorgWizardSequenceTest is Test {
    ZorgConviction constant GOV = ZorgConviction(payable(0x0000006D936bA3653b8854490E16E782cd32a9a8));
    IERC721Min constant ZORGZ = IERC721Min(0x00000000008835ceF3E0D2333695f288Ee6b63A6);
    IERC20Min constant SHARES = IERC20Min(0x00a6bA94BBb5474725515De88fE04F854f2dCb12);
    address constant HOLDER = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;
    uint256 constant ID = 344; // held by HOLDER on mainnet

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_698_200);
    }

    function testWizardSequenceKeepsTheBoostThroughEternalize() public {
        assertEq(ZORGZ.ownerOf(ID), HOLDER, "test id must still be held");
        (uint256 minEth,,,) = GOV.ethBondTerms();
        uint256 amount = GOV.ETERNAL_MIN_ZORG(); // 10,000 zOrg, the eternalize floor
        assertGe(SHARES.balanceOf(HOLDER), amount, "holder must have the shares");
        vm.deal(HOLDER, minEth + 1 ether);

        vm.startPrank(HOLDER);
        // 1 & 2 - the approvals the wizard emits
        ZORGZ.approve(address(GOV), ID);
        SHARES.approve(address(GOV), amount);
        // 3 - bond WITH the tier, which is the whole point: the lock is set here
        GOV.bondZorgz{value: minEth}(ID, amount, 3);
        // 4 - eternalize, which inherits whatever rate the receipt already holds
        GOV.eternalize(ID);
        vm.stopPrank();

        (,, uint16 boost, uint8 tier) = GOV.receiptLocks(ID);
        assertTrue(GOV.eternalBonds(ID), "eternal");
        assertEq(tier, 3, "tier survived eternalize");
        assertEq(boost, 15_000, "1.50x kept permanently");
        assertEq(GOV.bondedWeight(ID), amount, "shares escrowed");
        assertEq(ZORGZ.ownerOf(ID), address(GOV), "zOrgz escrowed");

        // And the boost is real where it counts: allocation.
        uint256 listing = 0; // ETH
        vm.prank(HOLDER);
        GOV.allocate(ID, listing, 1_000 ether);
        (, uint256 weight) = GOV.listingState(listing);
        emit log_named_decimal_uint("support from 1,000 zOrg at 1.50x", weight, 18);
        assertGe(weight, 1_500 ether, "1,000 zOrg directs 1,500 of support");
    }

    /// The order the wizard cannot express, kept here so the difference is
    /// measured rather than argued.
    function testTheOrderTheWizardPreventsWouldHaveCost() public {
        uint256 other = 8344; // also held by HOLDER
        assertEq(ZORGZ.ownerOf(other), HOLDER, "second id must still be held");
        (uint256 minEth,,,) = GOV.ethBondTerms();
        uint256 amount = GOV.ETERNAL_MIN_ZORG();
        vm.deal(HOLDER, minEth + 1 ether);

        vm.startPrank(HOLDER);
        ZORGZ.approve(address(GOV), other);
        SHARES.approve(address(GOV), amount);
        GOV.bondZorgz{value: minEth}(other, amount, 0); // open, the tempting default
        GOV.eternalize(other);
        vm.expectRevert(ZorgConviction.PermanentBond.selector);
        GOV.selectLockTier(other, 3); // too late, forever
        vm.stopPrank();

        (,, uint16 boost,) = GOV.receiptLocks(other);
        assertEq(boost, 10_000, "frozen at 1.00x");
        emit log_named_uint("rate via the wizard   (bps)", 15_000);
        emit log_named_uint("rate via the old path (bps)", boost);
    }
}
