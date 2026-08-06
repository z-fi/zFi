// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction, IERC721Zorgz, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockNFT, MockWeiNames, MockTokenList} from "./ZorgConviction.t.sol";

/// A receipt holder that fights back on the way out: every ERC-721 callback the
/// governor makes during redemption is an opportunity to re-enter.
contract HostileHolder {
    ZorgConviction public gov;
    uint256 public id;
    bool public attack;
    string public lastError;

    function arm(ZorgConviction g, uint256 i) external {
        gov = g;
        id = i;
        attack = true;
    }

    function bond(MockShares s, MockNFT z, uint256 weight) external payable {
        s.approve(address(gov), type(uint256).max);
        z.approve(address(gov), id);
        gov.bondZorgz{value: msg.value}(id, weight);
    }

    function redeem() external {
        gov.unbond(id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (attack) {
            attack = false;
            // Re-enter the moment the zOrgz lands, while redemption is mid-flight.
            try gov.withdrawEthCredit(payable(address(this))) {
                lastError = "REENTERED";
            } catch {
                lastError = "blocked";
            }
        }
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// Adversarial review of the paths that take custody of assets and give them
/// back. The invariant suite proves the accounting balances; these ask whether a
/// determined counterparty can bend the ORDER of operations.
contract ZorgConvictionAdversarialTest is Test {
    ZorgConviction conviction;
    MockShares shares;
    MockNFT zorgz;

    address dao = address(0xDA0);
    address holder = address(0xB0B);
    uint256 constant ID = 9;

    function setUp() public {
        shares = new MockShares();
        zorgz = new MockNFT();
        MockWeiNames names = new MockWeiNames();
        names.mint(address(0xD0A1), "zorg.wei");
        MockTokenList list = new MockTokenList();
        list.setListed(123, true);
        conviction = new ZorgConviction(
            dao,
            address(shares),
            zorgz,
            names,
            address(list),
            new ZorgConvictionRenderer(new ZorgPageStyle()),
            new ZorgReceiptArt(),
            7 days
        );
    }

    function _bond(address who, uint256 id, uint256 amount) internal {
        zorgz.mint(who, id, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(who, amount);
        vm.deal(who, 10 ether);
        vm.startPrank(who);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), id);
        conviction.bondZorgz{value: 0.1 ether}(id, amount);
        vm.stopPrank();
    }

    /// Redemption hands the zOrgz back with `safeTransferFrom`, which calls the
    /// recipient. At that point the receipt is burned and the shares are already
    /// out, so a re-entrant call is the last chance to double-spend.
    function testReentrantHolderCannotDoubleSpendDuringRedemption() public {
        HostileHolder h = new HostileHolder();
        zorgz.mint(address(h), ID, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(address(h), 100 ether);
        vm.deal(address(h), 1 ether);
        h.arm(conviction, ID);
        h.bond{value: 0.1 ether}(shares, zorgz, 100 ether);

        (,,,, uint64 maturityAt,,,) = conviction.ethBonds(ID);
        vm.warp(maturityAt);
        h.redeem();

        assertEq(h.lastError(), "blocked", "re-entry during redemption must revert");
        // The exit still completed correctly, exactly once.
        assertEq(shares.balanceOf(address(h)), 100 ether, "shares returned once");
        assertEq(zorgz.ownerOf(ID), address(h), "zOrgz returned");
        assertEq(conviction.ethCredits(address(h)), 0.1 ether, "principal credited once");
        assertEq(conviction.bondedWeight(ID), 0, "bond cleared");
    }

    /// THE risk worth naming: redemption is atomic across two different assets.
    /// If the DAO makes the SHARE token non-transferable, `unbond` reverts on the
    /// share leg - and the zOrgz, which has nothing to do with the share token
    /// and would transfer perfectly well, is stranded with it. There is no
    /// separate path to recover the NFT alone.
    function testShareLockAlsoStrandsTheUnrelatedZorgz() public {
        _bond(holder, ID, 100 ether);
        (,,,, uint64 maturityAt,,,) = conviction.ethBonds(ID);
        vm.warp(maturityAt);

        // Simulate Moloch flipping the share token's transfer gate: the share
        // leg reverts, everything else is untouched.
        vm.mockCallRevert(
            address(shares),
            abi.encodeWithSignature("transfer(address,uint256)", holder, uint256(100 ether)),
            "Locked"
        );

        vm.prank(holder);
        vm.expectRevert();
        conviction.unbond(ID);

        // The NFT is still in escrow purely because the share leg failed.
        assertEq(zorgz.ownerOf(ID), address(conviction), "zOrgz stranded by a share-token lock");
        // And there is no alternative exit: the holder owns the receipt and the
        // zOrgz transfer itself would succeed, but no function offers it alone.
        assertEq(conviction.ownerOf(ID), holder, "receipt still held");

        // Unlocking restores both.
        vm.clearMockedCalls();
        vm.prank(holder);
        conviction.unbond(ID);
        assertEq(zorgz.ownerOf(ID), holder, "recovered once unlocked");
    }

    /// A tiny remaining bond becomes the sole beneficiary of a large exit tax.
    /// That is correct by design, but it must not corrupt the index for anyone
    /// who bonds afterwards.
    function testDustWeightCannotCorruptTheRewardIndex() public {
        _bond(holder, ID, 1); // one wei of zOrg
        address exiter = address(0xE1);
        _bond(exiter, 42, 1000 ether);

        vm.prank(exiter);
        conviction.unbond(42); // early: 0.02 ETH tax, half to loyalty

        uint256 dustClaim = conviction.loyaltyOf(ID);
        assertLe(dustClaim, conviction.loyaltyRewardReserve(), "claim cannot exceed reserve");

        // Someone bonding after the distribution must not inherit any of it.
        address late = address(0xE2);
        _bond(late, 77, 500 ether);
        assertEq(conviction.loyaltyOf(77), 0, "late bond earns nothing retroactively");

        // And the dust holder can actually take what it is owed.
        vm.prank(holder);
        conviction.claimLoyalty(ID);
        assertEq(conviction.ethCredits(holder), dustClaim, "dust holder paid exactly");
        assertGe(address(conviction).balance, conviction.totalEthPrincipal()
            + conviction.loyaltyRewardReserve() + conviction.treasuryEth() + conviction.totalEthCredits(),
            "still solvent");
    }

    /// Redemption must return the exact deposit, never less, regardless of what
    /// happened to the reward index in between.
    function testRedemptionReturnsTheExactDepositAfterManyDistributions() public {
        _bond(holder, ID, 1_000 ether);
        for (uint160 i = 1; i <= 5; ++i) {
            address e = address(0xE000 + i);
            _bond(e, 100 + i, 200 ether);
            vm.prank(e);
            conviction.unbond(100 + i); // early exit, taxed, feeds loyalty
        }
        (,,,, uint64 maturityAt,,,) = conviction.ethBonds(ID);
        vm.warp(maturityAt);
        vm.prank(holder);
        conviction.unbond(ID);
        assertEq(shares.balanceOf(holder), 1_000 ether, "exact share deposit returned");
        assertEq(zorgz.ownerOf(ID), holder, "zOrgz returned");
    }
}
