// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction, IERC721Zorgz, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockNFT, MockWeiNames, MockTokenList} from "./ZorgConviction.t.sol";

/// A contract the DAO might route `execute` through to reach the escrowed
/// assets indirectly.
contract Relay {
    function pull(address token, address from, address to, uint256 amount) external {
        (bool ok,) = token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        require(ok, "pull failed");
    }

    function approveOut(address token, address spender) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        ok;
    }
}

/// Depositor-safety cases the invariant run cannot reach, because they need the
/// DAO's privileged `execute` or a specific adversarial ordering.
contract ZorgConvictionDepositorSafetyTest is Test {
    ZorgConviction conviction;
    MockShares shares;
    MockNFT zorgz;

    address dao = address(0xDA0);
    address holder = address(0xB0B);
    address attacker = address(0xBAD);
    uint256 constant ID = 5;

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
        vm.deal(holder, 10 ether);
        zorgz.mint(holder, ID, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(holder, 1_000 ether);
        vm.startPrank(holder);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), ID);
        conviction.bondZorgz{value: 0.1 ether}(ID, 1_000 ether, 0);
        vm.stopPrank();
    }

    /// The escrow denylist names two targets, but the real protection is the
    /// balance assertion. Granting an allowance would sidestep it entirely: the
    /// balance is unchanged at the end of the call, and the spender drains in a
    /// LATER transaction that `_execute` never sees. It must be impossible for
    /// the governor to become the granter of such an allowance.
    function testDaoCannotGrantAnAllowanceOnEscrowedShares() public {
        Relay relay = new Relay();

        // Direct: the share token is a forbidden target.
        vm.prank(dao);
        vm.expectRevert(ZorgConviction.ProtectedAsset.selector);
        conviction.execute(address(shares), 0, abi.encodeWithSignature("approve(address,uint256)", attacker, 1e30));

        // Indirect: routing through a relay makes the RELAY the granter, not the
        // governor, so no allowance over the escrow is ever created.
        vm.prank(dao);
        conviction.execute(address(relay), 0, abi.encodeCall(Relay.approveOut, (address(shares), attacker)));
        assertEq(shares.allowance(address(conviction), attacker), 0, "no allowance over escrow");

        // And a pull attempt fails on its own, leaving escrow intact.
        vm.prank(attacker);
        vm.expectRevert();
        shares.transferFrom(address(conviction), attacker, 1 ether);
        assertEq(shares.balanceOf(address(conviction)), 1_000 ether, "escrow intact");
    }

    /// A relay that DOES move escrow must be caught by the balance assertion,
    /// whatever route it takes.
    function testEscrowReductionThroughARelayReverts() public {
        Relay relay = new Relay();
        // Give the relay an allowance the only way it could exist: it cannot.
        // So instead prove the assertion fires when the balance actually drops.
        vm.prank(address(conviction));
        shares.approve(address(relay), type(uint256).max);

        vm.prank(dao);
        vm.expectRevert(ZorgConviction.EscrowReduced.selector);
        conviction.execute(
            address(relay), 0, abi.encodeCall(Relay.pull, (address(shares), address(conviction), attacker, 1 ether))
        );
        assertEq(shares.balanceOf(address(conviction)), 1_000 ether, "escrow intact");
    }

    /// The zOrgz itself must be unreachable by the DAO.
    function testDaoCannotMoveTheEscrowedZorgz() public {
        vm.prank(dao);
        vm.expectRevert(ZorgConviction.ProtectedAsset.selector);
        conviction.execute(
            address(zorgz), 0, abi.encodeWithSignature("approve(address,uint256)", attacker, ID)
        );
        assertEq(zorgz.ownerOf(ID), address(conviction), "zOrgz still escrowed");
    }

    /// `execute` targeting the governor itself must not become a way to re-enter
    /// a guarded path.
    function testExecuteCannotReenterThroughSelfCall() public {
        vm.prank(dao);
        vm.expectRevert(ZorgConviction.Reentrancy.selector);
        conviction.execute(address(conviction), 0, abi.encodeCall(ZorgConviction.unbond, (ID)));
    }

    /// THE property protecting my `decreaseBond` change from becoming a trap:
    /// the maturity gate restricts PARTIAL withdrawal only. A full exit stays
    /// available at all times, at the documented early-exit tax. Funds are
    /// never locked in, only taxed.
    function testMaturityGateNeverTrapsFundsBecauseFullExitStaysOpen() public {
        (,,,, uint64 maturityAt,,,) = conviction.ethBonds(ID);
        assertGt(maturityAt, block.timestamp, "still immature");

        // Partial withdrawal is gated...
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(ZorgConviction.ReceiptLocked.selector, maturityAt));
        conviction.decreaseBond(ID, 100 ether);

        // ...but the full exit is not. The holder recovers every share and the
        // zOrgz immediately, paying only the ETH early-exit tax.
        uint256 before = shares.balanceOf(holder);
        vm.prank(holder);
        conviction.unbond(ID);
        assertEq(shares.balanceOf(holder) - before, 1_000 ether, "all shares returned");
        assertEq(zorgz.ownerOf(ID), holder, "zOrgz returned");
        assertEq(conviction.ethCredits(holder), 0.08 ether, "principal less the 20% tax");
    }

    /// A tier-0 receipt must not be able to extend anyone else's lock, or a
    /// griefer could pin a holder's capital in place.
    function testOnlyTheHolderCanRenewTheirOwnMaturity() public {
        (,,,, uint64 before,,,) = conviction.ethBonds(ID);
        shares.mint(attacker, 100 ether);
        vm.startPrank(attacker);
        shares.approve(address(conviction), type(uint256).max);
        vm.expectRevert(ZorgConviction.Unauthorized.selector);
        conviction.topUpZorg(ID, 100 ether);
        vm.stopPrank();
        (,,,, uint64 after_,,,) = conviction.ethBonds(ID);
        assertEq(after_, before, "maturity untouched by a stranger");
    }

    /// Every right the receipt carries must move with it, including redemption.
    function testTransferMovesRedemptionRightEntirely() public {
        vm.prank(holder);
        conviction.transferFrom(holder, attacker, ID);

        // The old holder keeps nothing.
        vm.prank(holder);
        vm.expectRevert(ZorgConviction.Unauthorized.selector);
        conviction.unbond(ID);

        (,,,, uint64 maturityAt,,,) = conviction.ethBonds(ID);
        vm.warp(maturityAt);
        vm.prank(attacker);
        conviction.unbond(ID);
        assertEq(shares.balanceOf(attacker), 1_000 ether, "new holder redeems the bond");
        assertEq(zorgz.ownerOf(ID), attacker, "new holder receives the zOrgz");
    }

    /// The final exit must drain the loyalty reserve rather than stranding dust
    /// that no receipt can ever claim.
    function testLastExitLeavesNoUnclaimableEth() public {
        (,,,, uint64 maturityAt,,,) = conviction.ethBonds(ID);
        vm.warp(maturityAt);
        vm.prank(holder);
        conviction.unbond(ID);

        assertEq(conviction.totalEthPrincipal(), 0, "no principal outstanding");
        assertEq(conviction.loyaltyRewardReserve(), 0, "reserve swept");
        uint256 owed = conviction.treasuryEth() + conviction.totalEthCredits();
        assertEq(address(conviction).balance, owed, "balance exactly matches what is owed");
    }
}
