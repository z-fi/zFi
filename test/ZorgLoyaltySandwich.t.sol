// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction, IERC721Zorgz, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockNFT, MockWeiNames, MockTokenList} from "./ZorgConviction.t.sol";

/// Regression: a tier-0 receipt could top up zOrg immediately before someone
/// else's early exit, capture nearly all of the loyalty half of that exit tax,
/// and withdraw the top-up in the very next call - risk-free, for the cost of
/// gas. `decreaseBond` gated only on the lock tier, never on the ETH maturity
/// that `topUpZorg` resets. It now honours both.
contract ZorgLoyaltySandwichTest is Test {
    address dao = address(0xDA0);
    address honest = address(0xB0B);
    address attacker = address(0xBAD);
    address exiter = address(0xE12C);

    MockShares shares;
    MockNFT zorgz;
    MockWeiNames names;
    MockTokenList tokenList;
    ZorgConviction conviction;

    uint256 constant ETH_BOND = 0.1 ether;

    function setUp() public {
        shares = new MockShares();
        zorgz = new MockNFT();
        names = new MockWeiNames();
        tokenList = new MockTokenList();
        names.mint(address(0xD0A1), "zorg.wei");
        conviction = new ZorgConviction(
            dao, address(shares), zorgz, names, address(tokenList), new ZorgConvictionRenderer(new ZorgPageStyle()), new ZorgReceiptArt(), 7 days
        );
        vm.deal(honest, 10 ether);
        vm.deal(attacker, 10 ether);
        vm.deal(exiter, 10 ether);
    }

    function _bond(address who, uint256 id, uint256 amount) internal {
        zorgz.mint(who, id, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(who, amount);
        vm.startPrank(who);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), id);
        conviction.bondZorgz{value: ETH_BOND}(id, amount);
        vm.stopPrank();
    }

    function testTopUpCannotBeWithdrawnBeforeMaturity() public {
        _bond(honest, 1, 100 ether);
        _bond(attacker, 2, 1 ether);
        _bond(exiter, 3, 100 ether);

        // Front-run the pending early `unbond` with a large top-up.
        shares.mint(attacker, 10_000 ether);
        vm.prank(attacker);
        conviction.topUpZorg(2, 10_000 ether);

        vm.prank(exiter);
        conviction.unbond(3); // 0.02 ETH tax, half to loyalty

        // The weight still captures this round's distribution...
        uint256 captured = conviction.loyaltyOf(2);
        assertGt(captured, conviction.loyaltyOf(1), "weight shares by size, as designed");

        // ...but it cannot be taken straight back out. `topUpZorg` reset the ETH
        // maturity, and `decreaseBond` now honours it, so the capital has to
        // stay bonded and at risk for the full term.
        uint64 maturityAt = _maturityOf(2);
        assertGt(maturityAt, block.timestamp, "top-up renewed maturity");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ZorgConviction.ReceiptLocked.selector, maturityAt));
        conviction.decreaseBond(2, 10_000 ether);

        // A tier-0 receipt is still freely withdrawable once its term is served.
        vm.warp(maturityAt);
        vm.prank(attacker);
        conviction.decreaseBond(2, 10_000 ether);
        assertEq(conviction.bondedWeight(2), 1 ether, "withdrawable after maturity");
    }

    function testHonestDecreaseStillWorksAfterMaturity() public {
        _bond(honest, 1, 100 ether);
        vm.warp(_maturityOf(1));
        vm.prank(honest);
        conviction.decreaseBond(1, 40 ether);
        assertEq(conviction.bondedWeight(1), 60 ether);
        assertEq(shares.balanceOf(honest), 40 ether);
    }

    function _maturityOf(uint256 receiptId) internal view returns (uint64) {
        (,,,, uint64 maturityAt,,,) = conviction.ethBonds(receiptId);
        return maturityAt;
    }
}
