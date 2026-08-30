// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSolverList} from "../src/utils/zSolverList.sol";

/// @notice The solver roster: which off-chain endpoints the page may race its
///         own venues against, in what order, under what handicap.
///
///         The properties worth pinning are the curator's, not a trader's -
///         nothing here moves funds. That an invalid lane cannot reach storage
///         by any path; that order survives an edit, because order IS the
///         curation; that a lane can be parked without losing its tuning; and
///         that the whole roster can be rebuilt from the event stream alone,
///         which is the one an earlier version quietly failed.
contract zSolverListTest is Test {
    zSolverList list;
    address internal admin = address(this);
    address internal constant STRANGER = address(0xBEEF);
    address internal constant ADAPTER = address(0xADA9);

    event Reset(uint256 oldLength);
    event Added(
        uint256 indexed index, string name, string endpoint, address adapter, uint16 handicapBps, bool enabled
    );

    function setUp() public {
        list = new zSolverList(new zSolverList.Solver[](0), admin);
    }

    function _lane(string memory name) internal pure returns (zSolverList.Solver memory) {
        return zSolverList.Solver({
            name: name,
            endpoint: string.concat("https://", name, ".example"),
            adapter: ADAPTER,
            handicapBps: 50,
            enabled: true
        });
    }

    function _seed(uint256 n) internal {
        string[5] memory names = ["a", "b", "c", "d", "e"];
        for (uint256 i; i < n; ++i) {
            list.add(_lane(names[i]));
        }
    }

    // ------------------------------------------------------------- BIRTH

    function test_itShipsEmptyOnPurpose() public view {
        // A read endpoint answers the same to everyone; a solver lane is a
        // proxy somebody has to run. Seeding one into immutable source would
        // commit a version to an operator who may not outlive the deploy.
        assertEq(list.count(), 0);
    }

    // -------------------------------------------------------- VALIDATION

    function test_noPathLandsALaneWithoutAnAdapter() public {
        zSolverList.Solver memory bad = _lane("x");
        bad.adapter = address(0);

        vm.expectRevert(zSolverList.NoAdapter.selector);
        list.add(bad);

        zSolverList.Solver[] memory many = new zSolverList.Solver[](1);
        many[0] = bad;
        vm.expectRevert(zSolverList.NoAdapter.selector);
        list.set(many);

        list.add(_lane("a"));
        vm.expectRevert(zSolverList.NoAdapter.selector);
        list.setAt(0, bad);
        vm.expectRevert(zSolverList.NoAdapter.selector);
        list.setEndpoint(0, "https://x.example", address(0));

        vm.expectRevert(zSolverList.NoAdapter.selector);
        new zSolverList(many, admin);
    }

    function test_noPathLandsAnOverCapHandicap() public {
        uint16 over = list.MAX_HANDICAP_BPS() + 1;
        zSolverList.Solver memory bad = _lane("x");
        bad.handicapBps = over;

        vm.expectRevert(zSolverList.BadHandicap.selector);
        list.add(bad);

        list.add(_lane("a"));
        vm.expectRevert(zSolverList.BadHandicap.selector);
        list.setHandicap(0, over);
        vm.expectRevert(zSolverList.BadHandicap.selector);
        list.setAt(0, bad);
    }

    function test_aBadElementAbortsTheWholeReplacement() public {
        _seed(2);
        zSolverList.Solver[] memory next = new zSolverList.Solver[](2);
        next[0] = _lane("x");
        next[1] = _lane("y");
        next[1].adapter = address(0);

        vm.expectRevert(zSolverList.NoAdapter.selector);
        list.set(next);
        // The delete must not survive the revert as a half-written roster.
        assertEq(list.count(), 2, "a failed replacement left the roster torn");
        assertEq(list.get(0).name, "a");
    }

    // ------------------------------------------------------------ RANKING

    function test_orderIsPreservedByRemove() public {
        _seed(3);
        list.remove(0);
        assertEq(list.get(0).name, "b", "remove promoted the tail instead of shifting");
        assertEq(list.get(1).name, "c");
    }

    function test_moveCarriesTheWholeRecord() public {
        _seed(3);
        list.setHandicap(2, 900);
        list.move(2, 0);
        zSolverList.Solver memory moved = list.get(0);
        assertEq(moved.name, "c", "move did not promote");
        assertEq(moved.handicapBps, 900, "move dropped the record's tuning");
        assertEq(moved.endpoint, "https://c.example", "move tore the record");
        assertEq(list.get(1).name, "a", "move disturbed what it passed");
    }

    function test_parkingALaneKeepsItsTuning() public {
        _seed(1);
        list.setHandicap(0, 250);
        list.setEnabled(0, false);
        zSolverList.Solver memory s = list.get(0);
        assertFalse(s.enabled, "the kill switch did not fire");
        assertEq(s.handicapBps, 250, "parking a lane lost its tuning");
        assertEq(s.endpoint, "https://a.example", "parking a lane lost its endpoint");
    }

    function test_setAtRenamesInPlaceKeepingTheRank() public {
        // Without this the only way to rename a lane was remove + add + move.
        _seed(3);
        zSolverList.Solver memory renamed = _lane("b2");
        list.setAt(1, renamed);
        assertEq(list.get(1).name, "b2");
        assertEq(list.get(0).name, "a", "setAt disturbed its neighbours");
        assertEq(list.get(2).name, "c");
        assertEq(list.count(), 3, "setAt changed the roster size");
    }

    function test_disabledLanesStayVisible() public {
        // An index that shifted with the enabled set would make every
        // governance call a race against the page's last read.
        _seed(2);
        list.setEnabled(0, false);
        assertEq(list.solvers().length, 2, "a disabled lane vanished from the roster");
    }

    // ------------------------------------------------------------- EVENTS

    function test_addLogsTheWholeRecordNotJustItsName() public {
        // The endpoint is the field this roster exists to publish. Logging
        // only (index, name, adapter) left a lane that was added and never
        // edited with its endpoint in no log anywhere.
        vm.expectEmit(true, false, false, true);
        emit Added(0, "a", "https://a.example", ADAPTER, 50, true);
        list.add(_lane("a"));
    }

    function test_wholesaleReplacementAnnouncesTheDiscard() public {
        // `delete` emits nothing, so without Reset an indexer replaying logs
        // keeps a lane the curator believes they dropped - still enabled,
        // still carrying an adapter.
        _seed(3);
        zSolverList.Solver[] memory next = new zSolverList.Solver[](1);
        next[0] = _lane("x");

        vm.expectEmit(false, false, false, true);
        emit Reset(3);
        list.set(next);
        assertEq(list.count(), 1);
    }

    // ------------------------------------------------------------- ACCESS

    function test_nobodyElseCanCurate() public {
        _seed(1);
        vm.startPrank(STRANGER);
        vm.expectRevert(zSolverList.NotOwner.selector);
        list.add(_lane("x"));
        vm.expectRevert(zSolverList.NotOwner.selector);
        list.setEnabled(0, false);
        vm.expectRevert(zSolverList.NotOwner.selector);
        list.setHandicap(0, 10);
        vm.expectRevert(zSolverList.NotOwner.selector);
        list.setEndpoint(0, "https://x.example", ADAPTER);
        vm.expectRevert(zSolverList.NotOwner.selector);
        list.setAt(0, _lane("x"));
        vm.stopPrank();
        assertTrue(list.get(0).enabled, "the roster changed without the owner");
    }

    function test_ownershipMovesOnlyOnAcceptance() public {
        list.transferOwnership(STRANGER);
        assertEq(list.owner(), admin, "ownership moved before it was accepted");
        vm.prank(STRANGER);
        list.acceptOwnership();
        assertEq(list.owner(), STRANGER);
        assertEq(list.pendingOwner(), address(0));
    }

    function test_aStaleIndexFailsByName() public {
        vm.expectRevert(zSolverList.BadIndex.selector);
        list.setEnabled(0, false);
        vm.expectRevert(zSolverList.BadIndex.selector);
        list.pop();
    }
}
