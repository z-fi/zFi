// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockNFT, MockWeiNames, MockTokenList} from "./ZorgConviction.t.sol";

/// An eternal bond CAN carry the maximum support rate - the rate just has to be
/// set before the bond becomes eternal, because `eternalize` never touches
/// `receiptLocks` and `selectLockTier` refuses to run once it has.
contract ZorgEternalMaxWeightTest is Test {
    ZorgConviction c; MockShares s; MockNFT z;
    address h = address(0xB0B);
    uint256 constant A = 111; // right order
    uint256 constant B = 222; // wrong order

    function setUp() public {
        s = new MockShares(); z = new MockNFT();
        MockWeiNames n = new MockWeiNames(); n.mint(address(0xD0A1), "zorg.wei");
        MockTokenList l = new MockTokenList(); l.setListed(123, true); l.setListed(456, true);
        c = new ZorgConviction(address(0xDA0), address(s), z, n, address(l),
            new ZorgConvictionRenderer(new ZorgPageStyle()), new ZorgReceiptArt(), 3 days);
        vm.deal(h, 5 ether);
    }

    function _bond(uint256 id) internal {
        z.mint(h, id, "data:image/svg+xml;base64,PHN2Zy8+");
        s.mint(h, 10_000 ether);
        vm.startPrank(h);
        s.approve(address(c), type(uint256).max); z.approve(address(c), id);
        c.bondZorgz{value: 0.01 ether}(id, 10_000 ether, 0);
        vm.stopPrank();
    }

    function testEternalCanHoldTheMaximumRateIfLockedFirst() public {
        // RIGHT ORDER: hard lock tier 3, then eternalize.
        _bond(A);
        vm.startPrank(h);
        c.selectLockTier(A, 3);
        c.eternalize(A);
        c.allocate(A, 123, 10_000 ether);
        vm.stopPrank();

        (,, uint16 boostA,) = c.receiptLocks(A);
        (, uint256 weightA) = c.listingState(123);
        assertTrue(c.eternalBonds(A), "eternal");
        assertEq(boostA, 15_000, "keeps the 1.50x rate through eternalize");
        assertEq(weightA, 15_000 ether, "10,000 zOrg directs 15,000 of support, permanently");

        // WRONG ORDER: eternalize first - the rate is frozen at 1.00x.
        _bond(B);
        vm.startPrank(h);
        c.eternalize(B);
        vm.expectRevert(ZorgConviction.PermanentBond.selector);
        c.selectLockTier(B, 3);
        c.allocate(B, 456, 10_000 ether);
        vm.stopPrank();

        (,, uint16 boostB,) = c.receiptLocks(B);
        (, uint256 weightB) = c.listingState(456);
        assertEq(boostB, 10_000, "frozen at 1.00x");
        assertEq(weightB, 10_000 ether, "same zOrg, two thirds the weight");

        emit log_named_decimal_uint("locked-then-eternal  support", weightA, 18);
        emit log_named_decimal_uint("eternal-then-blocked support", weightB, 18);
    }

    /// And the maximum is a real ceiling: 1.50x is MAX_BOOST_BPS.
    function testFiftyPercentIsTheCeiling() public view {
        assertEq(c.MAX_BOOST_BPS(), 15_000, "1.50x is the most any receipt can carry");
    }
}
