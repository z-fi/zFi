// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";
import {zRpcList} from "../src/utils/zRpcList.sol";

/// @notice The curated RPC list: the one mutable surface the walletless read
///         path depends on, and the reason the page works before a wallet does.
///
///         The tests pin the facts the page's fallback logic leans on - the
///         satellite is born WITH the version that creates it (so `RPCS()`
///         never dangles), and the seeds are exactly what the page merges
///         ahead of its baked-in endpoints - and the facts the CURATOR leans
///         on: that order is preference and survives an edit, that dropping
///         one endpoint does not silently promote the last one, and that
///         handing the keys on takes two steps so a typo cannot freeze the
///         roster forever.
contract zRpcListTest is Test {
    /// The seed curation this version ships, pinned here rather than imported:
    /// the strings live in zSwap's source as private constants, and the pin is
    /// what makes changing them a conscious, page-visible act.
    string constant SEED_1 = "https://ethereum-rpc.publicnode.com";
    string constant SEED_2 = "https://eth-mainnet.public.blastapi.io";

    /// @dev The admin this test's zSwap is deployed with. Ownership is no
    ///      longer a constant on the satellite, so it is whatever the parent
    ///      version passed in - which is the property being tested.
    address internal admin = address(this);
    address internal constant STRANGER = address(0xBEEF);

    /// @dev Deploys `data` as a contract whose runtime bytecode IS that data,
    ///      mirroring how the chunks are deployed on-chain.
    function _writeChunk(bytes memory data) internal returns (address p) {
        bytes memory initcode = bytes.concat(hex"61", bytes2(uint16(data.length)), hex"80600a5f395ff3", data);
        assembly ("memory-safe") {
            p := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(p != address(0), "chunk deploy failed");
    }

    function _newZSwap() internal returns (zSwap) {
        address[16] memory p;
        for (uint256 k; k < 16; ++k) {
            p[k] = _writeChunk(bytes.concat(bytes32(uint256(k))));
        }
        return new zSwap(admin, address(0), p);
    }

    function _list() internal returns (zRpcList) {
        string[] memory seeds = new string[](2);
        seeds[0] = SEED_1;
        seeds[1] = SEED_2;
        return new zRpcList(seeds, admin);
    }

    // --------------------------------------------------------------- BIRTH

    /// The version names a roster it did not create, so the pin is the thing
    /// worth testing: `RPCS()` must be the address that was deployed, verified
    /// and audited, and it must not be something a deployer could vary.
    function test_theVersionPinsTheDeployedSatellites() public {
        zSwap z = _newZSwap();
        assertEq(
            z.RPCS(),
            0x8C7348D039f58C4e9cfA936EF410eec759213b12,
            "the version points at a different RPC roster than the deployed one"
        );
        assertEq(
            z.SOLVERS(),
            0x1Dfbb2f41B596F72187370469074C46de60dA2e3,
            "the version points at a different solver roster than the deployed one"
        );
        // The pin that matters most: the page must refuse any lane whose
        // adapter is not this, or the roster gets to choose what code runs.
        assertEq(
            z.SOLVER_FILL(),
            0x7A2f21e476cA2ADde027BC868c5a083338EEfE54,
            "the version pins a different adapter than the deployed one"
        );
    }

    function test_theRosterShipsItsSeeds() public {
        zRpcList l = _list();
        string[] memory r = l.rpcs();
        assertEq(r.length, 2, "the shipped roster is not the pinned size");
        assertEq(r[0], SEED_1, "the shipped seed is not the pinned one");
        assertEq(r[1], SEED_2, "the shipped seed is not the pinned one");
    }

    function test_theRosterHasItsOwnAdmin() public {
        // Governance is not a constant here, and it is deliberately NOT the
        // lineage DAO: the address is pinned, the contents are curated by
        // whoever holds this owner, and that is a two-step transferable role.
        assertEq(_list().owner(), admin, "the roster is not owned by its deployer's choice");
    }

    // ---------------------------------------------------------- CURATION

    function test_theOwnerCanAppendAndTheOrderIsPreference() public {
        zRpcList l = _list();
        l.add("https://c.example");
        string[] memory r = l.rpcs();
        assertEq(r.length, 3);
        assertEq(r[2], "https://c.example", "append did not land last");
    }

    function test_removePreservesOrderRatherThanSwappingTheTailIn() public {
        // Order IS the curation. A swap-and-pop would silently promote the
        // last endpoint into the hole, which is a re-rank nobody asked for.
        zRpcList l = _list();
        l.add("https://c.example");
        l.remove(0);
        string[] memory r = l.rpcs();
        assertEq(r.length, 2);
        assertEq(r[0], SEED_2, "remove promoted the tail instead of shifting");
        assertEq(r[1], "https://c.example");
    }

    function test_moveRanksWithoutRewritingAnythingElse() public {
        zRpcList l = _list();
        l.add("https://c.example");
        l.move(2, 0);
        string[] memory r = l.rpcs();
        assertEq(r[0], "https://c.example", "move did not promote");
        assertEq(r[1], SEED_1, "move disturbed what it passed");
        assertEq(r[2], SEED_2, "move disturbed what it passed");
    }

    function test_popUndoesAnAdd() public {
        zRpcList l = _list();
        l.add("https://c.example");
        l.pop();
        assertEq(l.count(), 2, "pop did not undo the add");
        assertEq(l.rpcs()[1], SEED_2, "pop took the wrong entry");
    }

    function test_setAtReplacesInPlaceAndKeepsTheRank() public {
        zRpcList l = _list();
        l.setAt(0, "https://replaced.example");
        string[] memory r = l.rpcs();
        assertEq(r.length, 2, "in-place replacement changed the size");
        assertEq(r[0], "https://replaced.example");
        assertEq(r[1], SEED_2, "in-place replacement disturbed its neighbour");
    }

    function test_setIsFullReplacementNotAppend() public {
        // The page merges its own seeds back in, so replacement must not
        // append: a dropped endpoint has to actually be droppable.
        zRpcList l = _list();
        string[] memory next = new string[](1);
        next[0] = "https://only.example";
        l.set(next);
        assertEq(l.count(), 1, "set appended instead of overwriting");
        assertEq(l.rpcs()[0], "https://only.example");
    }

    function test_aStaleIndexFailsByNameNotByPanic() public {
        // A UI built against an older roster will send one of these. It should
        // read as a bad index, not as an array panic.
        zRpcList l = _list();
        vm.expectRevert(zRpcList.BadIndex.selector);
        l.remove(2);
    }

    // ------------------------------------------------------------- ACCESS

    function test_nobodyElseCanCurate() public {
        zRpcList l = _list();
        vm.startPrank(STRANGER);
        vm.expectRevert(zRpcList.NotOwner.selector);
        l.add("https://rpc.attacker");
        vm.expectRevert(zRpcList.NotOwner.selector);
        l.setAt(0, "https://rpc.attacker");
        vm.expectRevert(zRpcList.NotOwner.selector);
        l.remove(0);
        vm.expectRevert(zRpcList.NotOwner.selector);
        l.move(0, 1);
        vm.stopPrank();
        assertEq(l.rpcs()[0], SEED_1, "the roster changed without the owner");
    }

    // ---------------------------------------------------------- HANDOFF

    function test_ownershipMovesOnlyWhenTheRecipientAcceptsIt() public {
        // Two steps, because a one-step transfer to a typo'd address freezes
        // the roster at whatever it held, with no way to ever drop a hostile
        // endpoint from it.
        zRpcList l = _list();
        l.transferOwnership(STRANGER);
        assertEq(l.owner(), admin, "ownership moved before it was accepted");
        assertEq(l.pendingOwner(), STRANGER);

        // The old owner still governs in the meantime.
        l.add("https://still-mine.example");
        assertEq(l.count(), 3);

        vm.prank(STRANGER);
        l.acceptOwnership();
        assertEq(l.owner(), STRANGER, "acceptance did not move ownership");
        assertEq(l.pendingOwner(), address(0), "the offer was not cleared");

        vm.expectRevert(zRpcList.NotOwner.selector);
        l.add("https://not-mine-anymore.example");
    }

    function test_onlyTheNamedRecipientCanAccept() public {
        zRpcList l = _list();
        l.transferOwnership(STRANGER);
        vm.prank(address(0xDEAD));
        vm.expectRevert(zRpcList.NotOwner.selector);
        l.acceptOwnership();
        assertEq(l.owner(), admin);
    }

    function test_anOfferCanBeWithdrawn() public {
        zRpcList l = _list();
        l.transferOwnership(STRANGER);
        l.transferOwnership(address(0));
        vm.prank(STRANGER);
        vm.expectRevert(zRpcList.NotOwner.selector);
        l.acceptOwnership();
        assertEq(l.owner(), admin, "a withdrawn offer still transferred");
    }

    function test_curationStaysCheapEnoughToMaintain() public {
        // The property that makes maintaining a roster realistic at all: the
        // routine acts are one write, not a rewrite of everything.
        zRpcList l = _list();
        uint256 g = gasleft();
        l.setAt(0, "https://a.example");
        assertLt(g - gasleft(), 60_000, "an in-place edit is too expensive");
    }
}
