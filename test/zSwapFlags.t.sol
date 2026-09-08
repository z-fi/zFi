// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwapFlags} from "../src/utils/zSwapFlags.sol";

/// @notice The one switch an immutable page has for a lane it does not control
///         the other half of.
///
///         The tests are mostly about the difference between "unset" and
///         "off". A reader that conflates them cannot bootstrap (because unset
///         would hide the lane from everyone forever) or cannot withdraw
///         (because off would read as merely absent). Both directions are
///         pinned here, along with the precedence that lets one chain be
///         carved out of a decision made for all of them.
contract zSwapFlagsTest is Test {
    zSwapFlags flags;

    address owner = address(this);
    address stranger = address(0xBAD);
    address next = address(0xACE);

    bytes32 constant RELAY = "relay";
    uint256 constant BASE = 8453;
    uint256 constant RH = 4663;

    uint8 constant UNSET = 0;
    uint8 constant ON = 1;
    uint8 constant OFF = 2;

    function setUp() public {
        flags = new zSwapFlags(owner);
    }

    // ------------------------------------------------------------- the states

    function test_anUnknownLaneIsUnsetRatherThanOff() public view {
        // The page must be able to tell "nobody has decided" from "withdrawn",
        // because only the first one leaves the choice to the viewer.
        assertEq(flags.stateOf(RELAY, BASE), UNSET);
        assertEq(flags.stateOf("never-heard-of-it", 1), UNSET);
    }

    function test_theFallbackCoversEveryChainAtOnce() public {
        flags.set(RELAY, 0, ON);
        assertEq(flags.stateOf(RELAY, BASE), ON);
        assertEq(flags.stateOf(RELAY, RH), ON);
        assertEq(flags.stateOf(RELAY, 1), ON, "chain 1 reads the fallback like any other");
    }

    function test_aChainCarvesItselfOutOfTheFallback() public {
        flags.set(RELAY, 0, ON);
        flags.set(RELAY, RH, OFF);
        assertEq(flags.stateOf(RELAY, BASE), ON, "the blanket still applies where nothing overrides");
        assertEq(flags.stateOf(RELAY, RH), OFF, "specific beats general");
    }

    function test_andTheOtherWayRound() public {
        // The direction that matters operationally: everything off, one chain
        // brought back up because that is where a relayer is actually running.
        flags.set(RELAY, 0, OFF);
        flags.set(RELAY, BASE, ON);
        assertEq(flags.stateOf(RELAY, RH), OFF);
        assertEq(flags.stateOf(RELAY, BASE), ON);
    }

    function test_clearingAChainReturnsItToTheFallback() public {
        flags.set(RELAY, 0, ON);
        flags.set(RELAY, RH, OFF);
        flags.set(RELAY, RH, UNSET);
        assertEq(flags.stateOf(RELAY, RH), ON, "unset is a hole, not a value");
    }

    function test_lanesDoNotBleedIntoEachOther() public {
        flags.set(RELAY, 0, OFF);
        assertEq(flags.stateOf("something-else", BASE), UNSET);
    }

    function test_aStateOutsideTheThreeIsRefused() public {
        vm.expectRevert(zSwapFlags.BadState.selector);
        flags.set(RELAY, BASE, 3);
    }

    function test_setManyAppliesEveryChainInOneTransaction() public {
        uint256[] memory ids = new uint256[](3);
        uint8[] memory st = new uint8[](3);
        (ids[0], ids[1], ids[2]) = (1, BASE, RH);
        (st[0], st[1], st[2]) = (OFF, ON, OFF);
        flags.setMany(RELAY, ids, st);
        assertEq(flags.stateOf(RELAY, 1), OFF);
        assertEq(flags.stateOf(RELAY, BASE), ON);
        assertEq(flags.stateOf(RELAY, RH), OFF);
    }

    function test_setManyRefusesRaggedInput() public {
        uint256[] memory ids = new uint256[](2);
        uint8[] memory st = new uint8[](1);
        vm.expectRevert(zSwapFlags.LengthMismatch.selector);
        flags.setMany(RELAY, ids, st);
    }

    function test_theEventCarriesTheDecision() public {
        vm.expectEmit(true, true, false, true);
        emit zSwapFlags.Set(RELAY, RH, OFF);
        flags.set(RELAY, RH, OFF);
    }

    // ------------------------------------------------------------- who decides

    function test_nobodyElseCanFlipALane() public {
        vm.prank(stranger);
        vm.expectRevert(zSwapFlags.NotOwner.selector);
        flags.set(RELAY, BASE, ON);
    }

    function test_nobodyElseCanBatchEither() public {
        uint256[] memory ids = new uint256[](1);
        uint8[] memory st = new uint8[](1);
        vm.prank(stranger);
        vm.expectRevert(zSwapFlags.NotOwner.selector);
        flags.setMany(RELAY, ids, st);
    }

    function test_theHandoffTakesTwoSteps() public {
        flags.transferOwnership(next);
        assertEq(flags.owner(), owner, "proposing changes nothing on its own");
        assertEq(flags.pendingOwner(), next);

        vm.prank(next);
        flags.acceptOwnership();
        assertEq(flags.owner(), next);
        assertEq(flags.pendingOwner(), address(0), "the offer is spent");
    }

    function test_onlyTheNamedPartyCanAccept() public {
        flags.transferOwnership(next);
        vm.prank(stranger);
        vm.expectRevert(zSwapFlags.NotOwner.selector);
        flags.acceptOwnership();
        assertEq(flags.owner(), owner);
    }

    function test_anOfferCanBeWithdrawn() public {
        // A mistyped owner is the failure this contract cannot recover from,
        // so cancelling before acceptance has to work.
        flags.transferOwnership(next);
        flags.transferOwnership(address(0));
        vm.prank(next);
        vm.expectRevert(zSwapFlags.NotOwner.selector);
        flags.acceptOwnership();
        assertEq(flags.owner(), owner);
    }

    function test_theOldOwnerStopsWhenTheNewOneStarts() public {
        flags.transferOwnership(next);
        vm.prank(next);
        flags.acceptOwnership();

        vm.expectRevert(zSwapFlags.NotOwner.selector);
        flags.set(RELAY, BASE, ON);

        vm.prank(next);
        flags.set(RELAY, BASE, ON);
        assertEq(flags.stateOf(RELAY, BASE), ON);
    }
}
