// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockNFT, MockWeiNames, MockTokenList} from "./ZorgConviction.t.sol";

/// `_effectiveWeight` reads `receiptLocks[id].boostBps` and never consults
/// `unlockAt`, which is only ever used to gate withdrawal. These pin down what
/// that actually means for a holder, in both directions.
contract ZorgEternalBoostRetentionTest is Test {
    ZorgConviction conviction;
    MockShares shares;
    MockNFT zorgz;
    MockTokenList list;

    uint256 constant LISTING = 123;

    function setUp() public {
        shares = new MockShares();
        zorgz = new MockNFT();
        MockWeiNames names = new MockWeiNames();
        names.mint(address(0xD0A1), "zorg.wei");
        list = new MockTokenList();
        list.setListed(LISTING, true);
        conviction = new ZorgConviction(
            address(0xDA0),
            address(shares),
            zorgz,
            names,
            address(list),
            new ZorgConvictionRenderer(new ZorgPageStyle()),
            new ZorgReceiptArt(),
            7 days
        );
    }

    function _bond(address who, uint256 id, uint256 amount, uint8 tier) internal {
        zorgz.mint(who, id, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(who, amount);
        vm.deal(who, 10 ether);
        vm.startPrank(who);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), id);
        conviction.bondZorgz{value: 0.1 ether}(id, amount, tier);
        vm.stopPrank();
    }

    /// The good path: pick the tier at bond time, THEN eternalize. The 1.50x
    /// survives, because eternalize never touches `receiptLocks`.
    function testTierSetAtBondSurvivesEternalize() public {
        address holder = address(0xB0B);
        _bond(holder, 1, 10_000 ether, 3);

        vm.startPrank(holder);
        conviction.eternalize(1);
        conviction.allocate(1, LISTING, 1_000 ether);
        vm.stopPrank();

        assertTrue(conviction.eternalBonds(1), "receipt is eternal");
        assertEq(conviction.supportOf(LISTING), 1_500 ether, "1000 zOrg directs 1500 at 1.50x");
    }

    /// The path that cost receipt #9953: eternalize from tier 0 and the boost is
    /// unrecoverable, because `selectLockTier` rejects an eternal receipt.
    function testEternalizingFromTierZeroLocksInOneX() public {
        address holder = address(0xB0B);
        _bond(holder, 2, 10_000 ether, 0);

        vm.startPrank(holder);
        conviction.eternalize(2);
        vm.expectRevert(ZorgConviction.PermanentBond.selector);
        conviction.selectLockTier(2, 3);
        conviction.allocate(2, LISTING, 1_000 ether);
        vm.stopPrank();

        assertEq(conviction.supportOf(LISTING), 1_000 ether, "stuck at 1.00x forever");
    }

    /// The mirror image, which is NOT about eternal bonds at all: a tier-3 lock
    /// buys a boost that outlives the lock. Once `unlockAt` passes the holder is
    /// free to leave, yet keeps directing 1.50x for as long as they stay.
    /// Commitment and boost are decoupled after the term.
    function testBoostOutlivesTheLockOnAnOrdinaryBond() public {
        address holder = address(0xB0B);
        _bond(holder, 3, 10_000 ether, 3);

        (, uint64 unlockAt,,) = conviction.receiptLocks(3);
        vm.warp(uint256(unlockAt) + 1); // the 365-day commitment has fully expired

        vm.startPrank(holder);
        conviction.allocate(3, LISTING, 1_000 ether);
        assertEq(conviction.supportOf(LISTING), 1_500 ether, "still 1.50x with no commitment left");

        // And the position is fully liquid at this point.
        conviction.allocate(3, LISTING, 0);
        conviction.unbond(3);
        vm.stopPrank();
        assertEq(shares.balanceOf(holder), 10_000 ether, "walked away with everything");
    }
}
