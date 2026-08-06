// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction, IERC721Zorgz, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockNFT, MockWeiNames, MockTokenList} from "./ZorgConviction.t.sol";

/// Drives the governor through randomised sequences of every state-changing
/// action a depositor can reach, and asserts after each that the contract can
/// still pay everyone back.
///
/// The unit tests cover named attacks. These cover the thing no named attack
/// can: that the ETH and share accounting stay consistent under an ordering
/// nobody thought of. Three invariants, each of which failing means real losses.
contract SolvencyHandler is Test {
    ZorgConviction public conviction;
    MockShares public shares;
    MockNFT public zorgz;

    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];
    uint256[3] public ids = [11, 22, 33];
    uint256 public ghostCredits;

    constructor(ZorgConviction c, MockShares s, MockNFT z) {
        conviction = c;
        shares = s;
        zorgz = z;
        for (uint256 i; i < 3; ++i) {
            zorgz.mint(actors[i], ids[i], "data:image/svg+xml;base64,PHN2Zy8+");
            shares.mint(actors[i], 100_000 ether);
            vm.deal(actors[i], 100 ether);
            vm.startPrank(actors[i]);
            shares.approve(address(conviction), type(uint256).max);
            zorgz.approve(address(conviction), ids[i]);
            vm.stopPrank();
        }
    }

    function _actor(uint256 s) internal view returns (address, uint256) {
        uint256 i = s % 3;
        return (actors[i], ids[i]);
    }

    function bond(uint256 seed, uint256 weight, uint8 tier) external {
        (address a, uint256 id) = _actor(seed);
        weight = bound(weight, 1, 50_000 ether);
        tier = uint8(bound(tier, 0, 3));
        if (conviction.bondedWeight(id) != 0) return;
        vm.prank(a);
        try conviction.bondZorgz{value: 0.05 ether}(id, weight, tier) {} catch {}
    }

    function topUp(uint256 seed, uint256 amount) external {
        (address a, uint256 id) = _actor(seed);
        amount = bound(amount, 1, 20_000 ether);
        vm.prank(a);
        try conviction.topUpZorg(id, amount) {} catch {}
    }

    function decrease(uint256 seed, uint256 amount) external {
        (address a, uint256 id) = _actor(seed);
        amount = bound(amount, 1, 20_000 ether);
        vm.prank(a);
        try conviction.decreaseBond(id, amount) {} catch {}
    }

    function allocate(uint256 seed, uint256 listing, uint256 amount) external {
        (address a, uint256 id) = _actor(seed);
        listing = bound(listing, 1, 2) == 1 ? 123 : 456;
        amount = bound(amount, 0, 60_000 ether);
        vm.prank(a);
        try conviction.allocate(id, listing, amount) {} catch {}
    }

    function unbond(uint256 seed) external {
        (address a, uint256 id) = _actor(seed);
        vm.prank(a);
        try conviction.unbond(id) {} catch {}
    }

    function eternalize(uint256 seed) external {
        (address a, uint256 id) = _actor(seed);
        vm.prank(a);
        try conviction.eternalize(id) {} catch {}
    }

    function claimLoyalty(uint256 seed) external {
        (address a, uint256 id) = _actor(seed);
        vm.prank(a);
        try conviction.claimLoyalty(id) {} catch {}
    }

    function withdrawCredit(uint256 seed) external {
        (address a,) = _actor(seed);
        vm.prank(a);
        try conviction.withdrawEthCredit(payable(a)) {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 400 days));
    }

    function liveWeight() external view returns (uint256 total) {
        for (uint256 i; i < 3; ++i) total += conviction.bondedWeight(ids[i]);
    }

    function liveAllocationsExceedBond() external view returns (bool) {
        for (uint256 i; i < 3; ++i) {
            if (conviction.allocatedByBond(ids[i]) > conviction.bondedWeight(ids[i])) return true;
        }
        return false;
    }
}

contract ZorgConvictionSolvencyTest is Test {
    ZorgConviction conviction;
    MockShares shares;
    MockNFT zorgz;
    SolvencyHandler handler;

    function setUp() public {
        shares = new MockShares();
        zorgz = new MockNFT();
        MockWeiNames names = new MockWeiNames();
        names.mint(address(0xD0A1), "zorg.wei");
        MockTokenList list = new MockTokenList();
        list.setListed(123, true);
        list.setListed(456, true);
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
        handler = new SolvencyHandler(conviction, shares, zorgz);
        targetContract(address(handler));
    }

    /// Every wei the contract owes must be backed by a wei it holds. If this
    /// breaks, some depositor's principal, loyalty or credit cannot be paid.
    function invariant_ethIsFullyBacked() public view {
        uint256 owed = conviction.totalEthPrincipal() + conviction.loyaltyRewardReserve()
            + conviction.treasuryEth() + conviction.totalEthCredits();
        assertGe(address(conviction).balance, owed, "ETH liabilities exceed balance");
    }

    /// Every bonded share must still be held in escrow, or some receipt cannot
    /// be redeemed for what it deposited.
    function invariant_sharesAreFullyBacked() public view {
        assertGe(shares.balanceOf(address(conviction)), handler.liveWeight(), "share escrow short");
    }

    /// A receipt can never direct more support than it has actually bonded.
    function invariant_allocationNeverExceedsBond() public view {
        assertFalse(handler.liveAllocationsExceedBond(), "allocation exceeds bond");
    }
}
