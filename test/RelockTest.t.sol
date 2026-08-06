// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockNFT, MockWeiNames, MockTokenList} from "./ZorgConviction.t.sol";

contract RelockTest is Test {
    ZorgConviction c; MockShares s; MockNFT z;
    address h = address(0xB0B);
    uint256 constant ID = 9953;

    function setUp() public {
        s = new MockShares(); z = new MockNFT();
        MockWeiNames n = new MockWeiNames(); n.mint(address(0xD0A1), "zorg.wei");
        MockTokenList l = new MockTokenList(); l.setListed(123, true);
        c = new ZorgConviction(address(0xDA0), address(s), z, n, address(l),
            new ZorgConvictionRenderer(new ZorgPageStyle()), new ZorgReceiptArt(), 3 days);
        z.mint(h, ID, "data:image/svg+xml;base64,PHN2Zy8+");
        s.mint(h, 10_000 ether); vm.deal(h, 1 ether);
        vm.startPrank(h);
        s.approve(address(c), type(uint256).max); z.approve(address(c), ID);
        c.bondZorgz{value: 0.01 ether}(ID, 10_000 ether, 0);
        vm.stopPrank();
    }

    function testLockAfterAllocatingRequiresZeroingFirst() public {
        vm.prank(h); c.allocate(ID, 123, 10_000 ether);
        skip(9 days); // let conviction build at 1.00x

        (uint256 scoreBefore, uint256 weightBefore) = c.listingState(123);
        emit log_named_decimal_uint("after 9d at 1.00x  score ", scoreBefore, 18);
        emit log_named_decimal_uint("                   weight", weightBefore, 18);

        // Locking while allocated is refused outright.
        vm.prank(h);
        vm.expectRevert(ZorgConviction.BondHasActiveAllocations.selector);
        c.selectLockTier(ID, 3);

        // The only route: zero, lock, re-allocate.
        vm.startPrank(h);
        c.allocate(ID, 123, 0);
        c.selectLockTier(ID, 3);
        c.allocate(ID, 123, 10_000 ether);
        vm.stopPrank();

        (uint256 scoreAfter, uint256 weightAfter) = c.listingState(123);
        emit log_named_decimal_uint("after relock       score ", scoreAfter, 18);
        emit log_named_decimal_uint("                   weight", weightAfter, 18);
        emit log_named_decimal_uint("conviction retained     ", scoreAfter - weightAfter, 18);

        assertEq(weightAfter, 15_000 ether, "boost applied to the re-allocation");
        assertApproxEqAbs(scoreAfter - weightAfter, scoreBefore - weightBefore, 1e12,
            "accrued conviction survives the cycle");
    }
}
