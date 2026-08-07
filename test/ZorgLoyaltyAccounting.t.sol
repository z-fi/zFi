// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockNFT, MockWeiNames, MockTokenList} from "./ZorgConviction.t.sol";

/// The loyalty split described to depositors, asserted in exact wei rather than
/// in proportions: an early exit forfeits 20% of its ETH principal, half of
/// which goes to the treasury and half to the receipts still bonded, pro-rata
/// by RAW weight.
contract ZorgLoyaltyAccountingTest is Test {
    ZorgConviction conviction;
    MockShares shares;
    MockNFT zorgz;

    address alice = address(0xA11CE);   // stays
    address bob = address(0xB0B);       // leaves early
    address carol = address(0xCA401);   // arrives after the tax

    function setUp() public {
        shares = new MockShares();
        zorgz = new MockNFT();
        MockWeiNames names = new MockWeiNames();
        names.mint(address(0xD0A1), "zorg.wei");
        conviction = new ZorgConviction(
            address(0xDA0), address(shares), zorgz, names, address(new MockTokenList()),
            new ZorgConvictionRenderer(new ZorgPageStyle()), new ZorgReceiptArt(), 7 days
        );
    }

    function _bond(address who, uint256 id, uint256 weight, uint256 eth, uint8 tier) internal {
        zorgz.mint(who, id, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(who, weight);
        vm.deal(who, eth);
        vm.startPrank(who);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), id);
        conviction.bondZorgz{value: eth}(id, weight, tier);
        vm.stopPrank();
    }

    /// 0.01 ETH is a hard floor enforced onchain, not a UI suggestion.
    function testMinimumBondIsEnforcedNotAdvisory() public {
        zorgz.mint(alice, 1, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(alice, 100 ether);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), 1);
        vm.expectRevert(
            abi.encodeWithSelector(ZorgConviction.EthBondTooSmall.selector, 0.009 ether, 0.01 ether)
        );
        conviction.bondZorgz{value: 0.009 ether}(1, 100 ether, 0);
        // and paying MORE is accepted, with no cap
        conviction.bondZorgz{value: 0.5 ether}(1, 100 ether, 0);
        vm.stopPrank();
        (uint256 principal,,,,,,,) = conviction.ethBonds(1);
        assertEq(principal, 0.5 ether, "the full overpayment is held as principal");
    }

    /// The headline arithmetic, in wei.
    function testEarlyExitTaxSplitsExactlyAndOnlyToWhoRemains() public {
        _bond(alice, 1, 10_000 ether, 0.1 ether, 0);
        _bond(bob, 2, 5_000 ether, 0.1 ether, 0);

        vm.prank(bob);
        conviction.unbond(2);                       // day 0: fully early

        // Bob: 20% of 0.1 = 0.02 forfeited, 0.08 returned.
        assertEq(conviction.ethCredits(bob), 0.08 ether, "leaver keeps 80% of principal");
        assertEq(shares.balanceOf(bob), 5_000 ether, "all shares returned regardless");
        assertEq(zorgz.ownerOf(2), bob, "zOrgz returned regardless");

        // The tax: 0.02 total, split 50/50.
        assertEq(conviction.loyaltyRewardReserve(), 0.01 ether, "half to bonded receipts");

        // Alice was the only one left, so she gets ALL of the depositor half -
        // Bob's weight is removed before distribution, so he funds none of his own.
        assertEq(conviction.loyaltyOf(1), 0.01 ether, "stayer takes the whole depositor half");
        assertEq(conviction.loyaltyOf(2), 0, "leaver shares in nothing");
    }

    /// Pro-rata by RAW weight, and the boost is deliberately not involved.
    function testSplitIsProRataOnRawWeightAndIgnoresTheBoost() public {
        _bond(alice, 1, 10_000 ether, 0.1 ether, 3);   // 1.50x boost
        _bond(carol, 3, 30_000 ether, 0.1 ether, 0);   // 1.00x, three times the stake
        _bond(bob, 2, 1_000 ether, 0.1 ether, 0);

        vm.prank(bob);
        conviction.unbond(2);

        // 0.01 ETH split across 40,000 raw zOrg: Alice 1/4, Carol 3/4.
        // If the 1.50x boost counted, Alice would take 15/45 instead of 10/40.
        assertEq(conviction.loyaltyOf(1), 0.0025 ether, "alice: 10k/40k, boost ignored");
        assertEq(conviction.loyaltyOf(3), 0.0075 ether, "carol: 30k/40k");
        assertEq(
            conviction.loyaltyOf(1) + conviction.loyaltyOf(3),
            conviction.loyaltyRewardReserve(),
            "the whole depositor half is claimable, none stranded"
        );
    }

    /// The only route by which anyone - the DAO or a stranger - can push ETH to
    /// bonded receipts from outside the tax: bond a throwaway position and exit
    /// it immediately on purpose. Worth pinning because it is the sole path,
    /// `loyaltyRewardPerWeight` having exactly one writer, and because the cost
    /// is not what it looks like: most of the ETH comes straight back.
    function testDeliberateSelfExitIsTheOnlyWayToFundLoyaltyFromOutside() public {
        _bond(alice, 1, 10_000 ether, 0.1 ether, 0);      // the audience
        uint256 before = conviction.loyaltyOf(1);

        // A donor needs a zOrgz, ONE WEI of zOrg, and the ETH it wants to move.
        address donor = address(0xD0);
        zorgz.mint(donor, 9, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(donor, 1);
        vm.deal(donor, 1 ether);
        vm.startPrank(donor);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), 9);
        conviction.bondZorgz{value: 1 ether}(9, 1, 0);    // tier 0, so no lock blocks the exit
        conviction.unbond(9);                             // same block
        vm.stopPrank();

        // 1 ETH in: 20% tax = 0.2, split 0.1 treasury / 0.1 to bonded receipts.
        assertEq(conviction.ethCredits(donor), 0.8 ether, "80% comes straight back");
        assertEq(conviction.loyaltyOf(1) - before, 0.1 ether, "0.1 reaches the audience");
        assertEq(conviction.treasuryEth(), 0.1 ether, "0.1 to the treasury");

        // Everything except the ETH is recycled, so the rig is reusable forever.
        assertEq(zorgz.ownerOf(9), donor, "the zOrgz comes back");
        assertEq(shares.balanceOf(donor), 1, "the one wei of zOrg comes back");
        assertEq(conviction.bondedWeight(9), 0, "and the receipt id is free to bond again");

        // The donor funds none of its own gift: its weight leaves before the split.
        assertEq(conviction.loyaltyOf(9), 0, "donor claws nothing back");
    }

    /// Arriving after the tax earns none of it, and claiming keeps the bond.
    function testNoRetroactiveEarningAndClaimingDoesNotExit() public {
        _bond(alice, 1, 10_000 ether, 0.1 ether, 0);
        _bond(bob, 2, 5_000 ether, 0.1 ether, 0);
        vm.prank(bob);
        conviction.unbond(2);

        _bond(carol, 3, 10_000 ether, 0.1 ether, 0);   // same stake as alice, arrives late
        assertEq(conviction.loyaltyOf(3), 0, "late bond earns nothing retroactively");

        vm.prank(alice);
        conviction.claimLoyalty(1);
        assertEq(conviction.ethCredits(alice), 0.01 ether, "claimed into credits");
        assertEq(conviction.bondedWeight(1), 10_000 ether, "still bonded after claiming");
        assertEq(zorgz.ownerOf(1), address(conviction), "zOrgz still escrowed");

        // Solvency survives the whole sequence.
        assertGe(
            address(conviction).balance,
            conviction.totalEthPrincipal() + conviction.loyaltyRewardReserve()
                + conviction.treasuryEth() + conviction.totalEthCredits(),
            "still fully backed"
        );
    }

}
