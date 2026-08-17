// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";

/// @dev Regression suite for the one defect this design walked into on its own.
///
/// `collectFees` is the ONLY way to clear `creatorOwed`, the pool pays both
/// sides of it or neither, and the token burn depends on the token side
/// arriving. So an address that reverts on receipt does not merely miss a
/// payment - it wedges the fee stream and the burn permanently, and the accrued
/// value is then neither in the floor nor collectable by anyone.
///
/// PrecisionPool sidesteps this by taking the payee as an argument. This
/// contract cannot: it must BE the pool's `feeRecipient` for the factory to
/// admit a named market. Forcing the transfer restores the guarantee instead.
contract Hostile {
    receive() external payable {
        revert("no");
    }
}

contract Gasless {
    // Accepts, but leaves nothing for a stipend-limited send to work with.
    uint256 public x;

    receive() external payable {
        x = block.number;
    }
}

contract LauncherBrickTest is Test {
    PrecisionPoolFactory factory;
    PrecisionLauncher launcher;
    address alice = address(0xA11CE);
    address treasury = address(0x7EA);

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        launcher = new PrecisionLauncher(factory, treasury);
        vm.deal(alice, 1000 ether);
    }

    function _launchAndTrade(address creator) internal returns (LaunchToken token, PrecisionPool pool) {
        (address t, address p) = launcher.launch("H", "H", "", 1e9 ether, 0, 3 ether, creator);
        (token, pool) = (LaunchToken(t), PrecisionPool(payable(p)));
        vm.startPrank(alice);
        pool.swapExactIn{value: 10 ether}(address(0), 10 ether, 0, alice);
        // Sell as well as buy: the creator fee accrues on the INPUT token, so a
        // buy-only history leaves `creatorOwed1` at zero and there is nothing
        // for the burn to retire.
        token.approve(address(pool), type(uint256).max);
        pool.swapExactIn(address(token), token.balanceOf(alice) / 2, 0, alice);
        vm.stopPrank();
    }

    /// A creator that reverts on receipt must not be able to wedge the stream.
    function testCreatorThatCannotReceiveDoesNotBrickTheFeeStream() public {
        address hostile = address(new Hostile());
        (LaunchToken token,) = _launchAndTrade(hostile);

        uint256 supplyBefore = token.totalSupply();

        (uint256 creatorEth, uint256 protocolEth,, uint256 burned,) = launcher.collectFees(address(token));

        assertGt(creatorEth, 0, "creator fee vanished");
        assertEq(hostile.balance, creatorEth, "force-send did not land");
        assertEq(treasury.balance, protocolEth, "treasury underpaid");
        assertGt(burned, 0, "burn was held hostage");
        assertEq(token.totalSupply(), supplyBefore - burned);
    }

    /// Same for a recipient that accepts but spends more gas than a stipend.
    function testGasHungryCreatorDoesNotBrickTheFeeStream() public {
        address gasless = address(new Gasless());
        (LaunchToken token,) = _launchAndTrade(gasless);

        (uint256 creatorEth,,, uint256 burned,) = launcher.collectFees(address(token));
        assertEq(gasless.balance, creatorEth);
        assertGt(burned, 0);
    }

    /// And once unwedged, the stream stays sweepable rather than being a
    /// one-off rescue.
    function testStreamKeepsWorkingAfterAForcedPayment() public {
        address hostile = address(new Hostile());
        (LaunchToken token, PrecisionPool pool) = _launchAndTrade(hostile);
        launcher.collectFees(address(token));

        vm.prank(alice);
        pool.swapExactIn{value: 5 ether}(address(0), 5 ether, 0, alice);

        (uint256 creatorEth,,,,) = launcher.collectFees(address(token));
        assertGt(creatorEth, 0, "second sweep failed");
    }

    // ------------------------------------------------------- REASSIGNMENT

    function testCreatorMayReassignTheStream() public {
        address creator = address(0xC0FFEE);
        (LaunchToken token,) = _launchAndTrade(creator);

        address next = address(0xBEEF);
        vm.prank(creator);
        launcher.setCreator(address(token), next);
        // Offered, not yet transferred - the stream is permanent, so the
        // destination has to prove it can transact before it inherits one.
        assertEq(launcher.creatorOf(address(token)), creator, "handoff took effect unaccepted");
        assertEq(launcher.pendingCreatorOf(address(token)), next);

        vm.prank(next);
        launcher.acceptCreator(address(token));
        assertEq(launcher.creatorOf(address(token)), next);
        assertEq(launcher.pendingCreatorOf(address(token)), address(0), "pending survived acceptance");

        uint256 nextBefore = next.balance;
        (uint256 creatorEth,,,,) = launcher.collectFees(address(token));
        assertEq(next.balance - nextBefore, creatorEth, "fees did not follow the reassignment");
    }

    function testOnlyTheCurrentHolderMayReassign() public {
        address creator = address(0xC0FFEE);
        (LaunchToken token,) = _launchAndTrade(creator);

        vm.prank(alice);
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.setCreator(address(token), alice);

        // Only the named destination may accept.
        vm.prank(creator);
        launcher.setCreator(address(token), address(0xBEEF));
        vm.prank(alice);
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.acceptCreator(address(token));

        // Zero cancels a pending handoff rather than burning the stream.
        vm.prank(creator);
        launcher.setCreator(address(token), address(0));
        assertEq(launcher.pendingCreatorOf(address(token)), address(0), "handoff not cancellable");
        vm.prank(address(0xBEEF));
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.acceptCreator(address(token));

        // And an unlaunched token has no holder to impersonate.
        vm.prank(address(0));
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.setCreator(address(0xDEAD), alice);
    }

    /// Reassignment must confer nothing over holders: not the LP, not supply,
    /// not the fee rate.
    function testReassignmentGrantsNoPowerOverHolders() public {
        address creator = address(0xC0FFEE);
        (LaunchToken token, PrecisionPool pool) = _launchAndTrade(creator);

        uint256 lp = pool.balanceOf(address(launcher));
        uint256 supply = token.totalSupply();
        uint256 fee = pool.fee();

        vm.prank(creator);
        launcher.setCreator(address(token), address(0xBEEF));
        vm.prank(address(0xBEEF));
        launcher.acceptCreator(address(token));

        assertEq(pool.balanceOf(address(launcher)), lp, "position moved");
        assertEq(token.totalSupply(), supply, "supply moved");
        assertEq(pool.fee(), fee, "fee moved");

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        pool.removeLiquidity(lp, 0, 0, address(0xBEEF));
    }
}
