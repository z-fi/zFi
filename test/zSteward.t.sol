// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSteward} from "../src/utils/zSteward.sol";
import {zRpcList} from "../src/utils/zRpcList.sol";
import {zEndpoints} from "../src/utils/zEndpoints.sol";
import {zSolverList} from "../src/utils/zSolverList.sol";
import {zSwapFlags} from "../src/utils/zSwapFlags.sol";

/// @notice The delayed owner of the four curated lists, run against the real
///         list contracts so every narrowing shape is checked against the ABI
///         it claims to match.
///
///         Two properties carry the weight: nothing that widens a list lands
///         before DELAY, and everything that only narrows one lands at once.
contract zStewardTest is Test {
    zSteward st;
    zRpcList rpcs;
    zEndpoints eps;
    zSolverList solvers;
    zSwapFlags flags;

    address steward = makeAddr("steward");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");

    uint256 constant DELAY = 3 days;
    bytes32 constant RPC = "rpc";
    bytes32 constant BRIDGE = "bridge";
    uint256 constant BASE = 8453;

    function setUp() public {
        st = new zSteward(steward, guardian, DELAY);

        string[] memory seeds = new string[](3);
        seeds[0] = "https://a";
        seeds[1] = "https://b";
        seeds[2] = "https://c";
        rpcs = new zRpcList(seeds, address(this));

        zEndpoints.Seed[] memory s = new zEndpoints.Seed[](1);
        s[0] = zEndpoints.Seed(RPC, BASE, seeds);
        eps = new zEndpoints(address(this), s);

        zSolverList.Solver[] memory lanes = new zSolverList.Solver[](2);
        lanes[0] = zSolverList.Solver("kyber", "https://k", address(0x1234), 0, true);
        lanes[1] = zSolverList.Solver("0x", "https://z", address(0x1234), 0, true);
        solvers = new zSolverList(lanes, address(this));

        flags = new zSwapFlags(address(this));

        rpcs.transferOwnership(address(st));
        eps.transferOwnership(address(st));
        solvers.transferOwnership(address(st));
        flags.transferOwnership(address(st));
        st.accept(address(rpcs));
        st.accept(address(eps));
        st.accept(address(solvers));
        st.accept(address(flags));
    }

    // ------------------------------------------------------------- helpers

    function _queue(address target, bytes memory data) internal returns (uint256 n) {
        n = st.nonce();
        vm.prank(steward);
        st.queue(target, data);
    }

    function _narrow(address target, bytes memory data) internal {
        vm.prank(steward);
        st.narrow(target, data);
    }

    // ------------------------------------------------------------ handover

    function test_theListsEndUpOwnedByTheSteward() public view {
        assertEq(rpcs.owner(), address(st));
        assertEq(eps.owner(), address(st));
        assertEq(solvers.owner(), address(st));
        assertEq(flags.owner(), address(st));
    }

    function test_anOfferedListIsReceivedAtOnceByAnyone() public {
        string[] memory none = new string[](0);
        zRpcList fresh = new zRpcList(none, address(this));
        fresh.transferOwnership(address(st));
        vm.prank(stranger);
        st.accept(address(fresh));
        assertEq(fresh.owner(), address(st));
    }

    function test_aListNotOfferedCannotBeTaken() public {
        string[] memory none = new string[](0);
        zRpcList fresh = new zRpcList(none, address(this));
        vm.expectRevert(zRpcList.NotOwner.selector);
        st.accept(address(fresh));
        assertEq(fresh.owner(), address(this));
    }

    function test_aListLeavesOnlyThroughTheQueue() public {
        bytes memory data = abi.encodeCall(zRpcList.transferOwnership, (stranger));
        vm.prank(steward);
        vm.expectRevert(zSteward.NotNarrowing.selector);
        st.narrow(address(rpcs), data);
        uint256 n = _queue(address(rpcs), data);
        skip(DELAY);
        st.execute(address(rpcs), data, n);
        vm.prank(stranger);
        rpcs.acceptOwnership();
        assertEq(rpcs.owner(), stranger);
    }

    function test_aDelayUnderADayIsRefused() public {
        vm.expectRevert(zSteward.TooShort.selector);
        new zSteward(steward, guardian, 1 days - 1);
    }

    // --------------------------------------------------------------- queue

    function test_anAdditionLandsOnlyAfterTheDelay() public {
        bytes memory data = abi.encodeCall(zRpcList.add, ("https://new"));
        uint256 n = _queue(address(rpcs), data);
        bytes32 id = st.opId(address(rpcs), data, n);
        assertEq(st.eta(id), block.timestamp + DELAY);

        skip(DELAY - 1);
        vm.expectRevert(zSteward.NotDue.selector);
        st.execute(address(rpcs), data, n);
        assertEq(rpcs.count(), 3);

        skip(1);
        vm.prank(stranger);
        st.execute(address(rpcs), data, n);
        assertEq(rpcs.count(), 4);
        assertEq(rpcs.get(3), "https://new");
        assertEq(st.eta(id), 0);
    }

    function test_anOperationRunsOnce() public {
        bytes memory data = abi.encodeCall(zRpcList.add, ("https://new"));
        uint256 n = _queue(address(rpcs), data);
        skip(DELAY);
        st.execute(address(rpcs), data, n);
        vm.expectRevert(zSteward.NotQueued.selector);
        st.execute(address(rpcs), data, n);
    }

    function test_theSameCallCanBeQueuedTwice() public {
        bytes memory data = abi.encodeCall(zRpcList.add, ("https://new"));
        uint256 a = _queue(address(rpcs), data);
        uint256 b = _queue(address(rpcs), data);
        assertTrue(st.opId(address(rpcs), data, a) != st.opId(address(rpcs), data, b));
        skip(DELAY);
        st.execute(address(rpcs), data, b);
        st.execute(address(rpcs), data, a);
        assertEq(rpcs.count(), 5);
    }

    function test_anOperationLapsesAfterTheGrace() public {
        bytes memory data = abi.encodeCall(zRpcList.add, ("https://new"));
        uint256 n = _queue(address(rpcs), data);
        skip(DELAY + st.GRACE());
        st.execute(address(rpcs), data, n);
        assertEq(rpcs.count(), 4, "the last second of the grace still counts");

        n = _queue(address(rpcs), data);
        skip(DELAY + st.GRACE() + 1);
        vm.expectRevert(zSteward.Expired.selector);
        st.execute(address(rpcs), data, n);
    }

    function test_onlyTheStewardQueues() public {
        bytes memory data = abi.encodeCall(zRpcList.add, ("https://new"));
        vm.prank(guardian);
        vm.expectRevert(zSteward.Unauthorized.selector);
        st.queue(address(rpcs), data);
        vm.prank(stranger);
        vm.expectRevert(zSteward.Unauthorized.selector);
        st.queue(address(rpcs), data);
    }

    function test_aFailedCallStaysQueued() public {
        bytes memory data = abi.encodeCall(zRpcList.remove, (7));
        uint256 n = _queue(address(rpcs), data);
        skip(DELAY);
        vm.expectRevert(zRpcList.BadIndex.selector);
        st.execute(address(rpcs), data, n);
        assertTrue(st.eta(st.opId(address(rpcs), data, n)) != 0);
    }

    function test_aTargetWithNoCodeIsRefused() public {
        bytes memory data = abi.encodeCall(zRpcList.add, ("https://new"));
        uint256 n = _queue(stranger, data);
        skip(DELAY);
        vm.expectRevert(zSteward.NoCode.selector);
        st.execute(stranger, data, n);
    }

    // -------------------------------------------------------------- cancel

    function test_eitherRoleCancels() public {
        bytes memory data = abi.encodeCall(zRpcList.add, ("https://new"));
        uint256 n = _queue(address(rpcs), data);
        bytes32 id = st.opId(address(rpcs), data, n);

        vm.prank(stranger);
        vm.expectRevert(zSteward.Unauthorized.selector);
        st.cancel(id);

        vm.prank(guardian);
        st.cancel(id);
        skip(DELAY);
        vm.expectRevert(zSteward.NotQueued.selector);
        st.execute(address(rpcs), data, n);

        n = _queue(address(rpcs), data);
        id = st.opId(address(rpcs), data, n);
        vm.prank(steward);
        st.cancel(id);
        vm.prank(steward);
        vm.expectRevert(zSteward.NotQueued.selector);
        st.cancel(id);
    }

    // -------------------------------------------------------------- narrow

    function test_rpcEntriesDropAtOnce() public {
        _narrow(address(rpcs), abi.encodeCall(zRpcList.remove, (0)));
        assertEq(rpcs.count(), 2);
        assertEq(rpcs.get(0), "https://b");
        _narrow(address(rpcs), abi.encodeCall(zRpcList.pop, ()));
        assertEq(rpcs.count(), 1);
    }

    function test_endpointEntriesDropAtOnce() public {
        _narrow(address(eps), abi.encodeCall(zEndpoints.remove, (RPC, BASE, 1)));
        assertEq(eps.count(RPC, BASE), 2);
        assertEq(eps.get(RPC, BASE, 1), "https://c");
        _narrow(address(eps), abi.encodeCall(zEndpoints.pop, (RPC, BASE)));
        assertEq(eps.count(RPC, BASE), 1);
    }

    function test_solversDropOrDisableAtOnce() public {
        _narrow(address(solvers), abi.encodeCall(zSolverList.setEnabled, (1, false)));
        assertFalse(solvers.get(1).enabled);
        _narrow(address(solvers), abi.encodeCall(zSolverList.remove, (0)));
        assertEq(solvers.count(), 1);
        _narrow(address(solvers), abi.encodeCall(zSolverList.pop, ()));
        assertEq(solvers.count(), 0);
    }

    function test_aLaneSwitchesOffAtOnce() public {
        _narrow(address(flags), abi.encodeCall(zSwapFlags.set, (BRIDGE, BASE, 2)));
        assertEq(flags.stateOf(BRIDGE, BASE), 2);
    }

    function test_theGuardianNarrowsToo() public {
        vm.prank(guardian);
        st.narrow(address(rpcs), abi.encodeCall(zRpcList.pop, ()));
        assertEq(rpcs.count(), 2);
        vm.prank(stranger);
        vm.expectRevert(zSteward.Unauthorized.selector);
        st.narrow(address(rpcs), abi.encodeCall(zRpcList.pop, ()));
    }

    function test_wideningCallsCannotNarrow() public {
        bytes[] memory w = new bytes[](13);
        w[0] = abi.encodeCall(zRpcList.add, ("https://x"));
        w[1] = abi.encodeCall(zRpcList.move, (2, 0));
        w[2] = abi.encodeCall(zRpcList.setAt, (0, "https://x"));
        w[3] = abi.encodeCall(zEndpoints.add, (RPC, BASE, "https://x"));
        w[4] = abi.encodeCall(zEndpoints.move, (RPC, BASE, 2, 0));
        w[5] = abi.encodeCall(zSolverList.setEnabled, (0, true));
        w[6] = abi.encodeCall(zSolverList.setHandicap, (0, 0));
        w[7] = abi.encodeCall(zSwapFlags.set, (BRIDGE, BASE, 1));
        w[8] = abi.encodeCall(zSwapFlags.set, (BRIDGE, BASE, 0));
        w[9] = abi.encodeCall(zRpcList.transferOwnership, (stranger));
        w[10] = abi.encodeCall(zSteward.setSteward, (stranger));
        w[11] = bytes.concat(abi.encodeCall(zRpcList.pop, ()), bytes1(0));
        w[12] = hex"4cc822";
        for (uint256 i; i != w.length; ++i) {
            assertFalse(st.narrows(w[i]));
            vm.prank(steward);
            vm.expectRevert(zSteward.NotNarrowing.selector);
            st.narrow(address(rpcs), w[i]);
        }
    }

    function testFuzz_onlyStateTwoNarrowsAFlag(uint8 state) public view {
        assertEq(st.narrows(abi.encodeCall(zSwapFlags.set, (BRIDGE, BASE, state))), state == 2);
    }

    function testFuzz_onlyFalseNarrowsASolverToggle(uint256 word) public view {
        bytes memory data = abi.encodePacked(zSolverList.setEnabled.selector, uint256(0), word);
        assertEq(st.narrows(data), word == 0);
    }

    // --------------------------------------------------------------- roles

    function test_theGuardianReplacesTheStewardAtOnce() public {
        vm.prank(steward);
        vm.expectRevert(zSteward.Unauthorized.selector);
        st.setSteward(stranger);

        vm.prank(guardian);
        st.setSteward(stranger);
        assertEq(st.steward(), stranger);

        vm.prank(steward);
        vm.expectRevert(zSteward.Unauthorized.selector);
        st.queue(address(rpcs), abi.encodeCall(zRpcList.add, ("https://x")));
    }

    function test_theStewardReplacesItselfThroughTheQueue() public {
        bytes memory data = abi.encodeCall(zSteward.setSteward, (stranger));
        uint256 n = _queue(address(st), data);
        skip(DELAY);
        st.execute(address(st), data, n);
        assertEq(st.steward(), stranger);
    }

    function test_theGuardianCanStopItsOwnReplacement() public {
        bytes memory data = abi.encodeCall(zSteward.setGuardian, (stranger));
        uint256 n = _queue(address(st), data);
        bytes32 id = st.opId(address(st), data, n);
        vm.prank(guardian);
        st.cancel(id);
        skip(DELAY);
        vm.expectRevert(zSteward.NotQueued.selector);
        st.execute(address(st), data, n);
        assertEq(st.guardian(), guardian);
    }

    function test_theGuardianHandsItsRoleOn() public {
        vm.prank(steward);
        vm.expectRevert(zSteward.Unauthorized.selector);
        st.setGuardian(stranger);
        vm.prank(guardian);
        st.setGuardian(stranger);
        assertEq(st.guardian(), stranger);
    }
}
