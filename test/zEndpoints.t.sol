// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zEndpoints} from "../src/utils/zEndpoints.sol";

/// @notice The curated off-chain endpoints, one list per (service, chain).
///
///         Most of what is pinned here is the fallback rule, because it is the
///         part a reader gets wrong silently: an empty chain list must inherit
///         rather than hide, one chain must be able to carve itself out, and
///         two services must never read each other's lists. The curation ops
///         follow zRpcList and are pinned per list.
contract zEndpointsTest is Test {
    zEndpoints ep;

    address owner = address(this);
    address stranger = address(0xBAD);
    address next = address(0xACE);

    bytes32 constant RPC = "rpc";
    bytes32 constant BTC = "btc";
    bytes32 constant TACIT = "tacit";
    uint256 constant BASE = 8453;
    uint256 constant RH = 4663;

    function setUp() public {
        zEndpoints.Seed[] memory s = new zEndpoints.Seed[](2);
        s[0] = zEndpoints.Seed(RPC, BASE, _l("https://a", "https://b"));
        s[1] = zEndpoints.Seed(BTC, 0, _l("https://m/api"));
        ep = new zEndpoints(owner, s);
    }

    function _l(string memory a) internal pure returns (string[] memory l) {
        l = new string[](1);
        l[0] = a;
    }

    function _l(string memory a, string memory b) internal pure returns (string[] memory l) {
        l = new string[](2);
        (l[0], l[1]) = (a, b);
    }

    function _l(string memory a, string memory b, string memory c) internal pure returns (string[] memory l) {
        l = new string[](3);
        (l[0], l[1], l[2]) = (a, b, c);
    }

    function _eq(string[] memory got, string[] memory want) internal pure {
        _eq(got, want, "entry");
    }

    function _eq(string[] memory got, string[] memory want, string memory why) internal pure {
        assertEq(got.length, want.length, why);
        for (uint256 i; i < got.length; ++i) {
            assertEq(got[i], want[i], why);
        }
    }

    // ------------------------------------------------------------- seeds

    function test_theSeedsLandInOrderUnderTheirOwnKeys() public view {
        _eq(ep.listOf(RPC, BASE), _l("https://a", "https://b"));
        _eq(ep.listOf(BTC, 0), _l("https://m/api"));
        assertEq(ep.owner(), owner);
    }

    function test_keysListsEveryPairWrittenOnce() public {
        ep.add(RPC, BASE, "https://c");
        ep.set(RPC, RH, _l("https://r"));
        (bytes32[] memory s, uint256[] memory c) = ep.keys();
        assertEq(s.length, 3);
        assertEq(s[0], RPC);
        assertEq(c[0], BASE);
        assertEq(s[1], BTC);
        assertEq(c[1], 0);
        assertEq(s[2], RPC);
        assertEq(c[2], RH);
    }

    function test_aClearedListStaysKnown() public {
        ep.set(RPC, BASE, new string[](0));
        (bytes32[] memory s,) = ep.keys();
        assertEq(s.length, 2, "cleared, not forgotten");
        assertTrue(ep.known(RPC, BASE));
        assertEq(ep.count(RPC, BASE), 0);
    }

    // ------------------------------------------------------------- fallback

    function test_aChainWithNoListReadsTheFallback() public view {
        // Bitcoin lives at chain 0, so every chain that asks gets it.
        _eq(ep.listOf(BTC, 1), _l("https://m/api"));
        _eq(ep.listOf(BTC, RH), _l("https://m/api"));
    }

    function test_aChainListOverridesTheFallback() public {
        ep.set(RPC, 0, _l("https://any"));
        _eq(ep.listOf(RPC, BASE), _l("https://a", "https://b"), "specific beats general");
        _eq(ep.listOf(RPC, RH), _l("https://any"));
    }

    function test_clearingAChainReturnsItToTheFallback() public {
        ep.set(RPC, 0, _l("https://any"));
        ep.set(RPC, BASE, new string[](0));
        _eq(ep.listOf(RPC, BASE), _l("https://any"), "empty inherits, it does not hide");
        assertEq(ep.listAt(RPC, BASE).length, 0, "listAt has no fallback");
    }

    function test_servicesDoNotBleedIntoEachOther() public view {
        assertEq(ep.listOf(TACIT, BASE).length, 0);
        assertEq(ep.listOf(TACIT, 0).length, 0);
        assertEq(ep.listOf("rpc2", BASE).length, 0);
    }

    function test_listsOfResolvesEachPairInOneCall() public {
        ep.set(TACIT, 1, _l("https://relay"));
        bytes32[] memory s = new bytes32[](4);
        uint256[] memory c = new uint256[](4);
        (s[0], s[1], s[2], s[3]) = (RPC, TACIT, BTC, RPC);
        (c[0], c[1], c[2], c[3]) = (BASE, 1, 0, RH);
        string[][] memory out = ep.listsOf(s, c);
        assertEq(out.length, 4);
        _eq(out[0], _l("https://a", "https://b"));
        _eq(out[1], _l("https://relay"));
        _eq(out[2], _l("https://m/api"));
        assertEq(out[3].length, 0, "nothing for Robinhood and no fallback");
    }

    function test_listsOfRefusesRaggedInput() public {
        vm.expectRevert(zEndpoints.LengthMismatch.selector);
        ep.listsOf(new bytes32[](2), new uint256[](1));
    }

    function test_listsOfEncodesAsStringArrayArray() public view {
        // The page decodes this by hand, so pin the ABI shape rather than
        // trusting a round trip through Solidity's own decoder.
        bytes32[] memory s = new bytes32[](1);
        uint256[] memory c = new uint256[](1);
        (s[0], c[0]) = (RPC, BASE);
        bytes memory raw = abi.encode(ep.listsOf(s, c));
        (uint256 outer, uint256 n, uint256 inner, uint256 m) = abi.decode(raw, (uint256, uint256, uint256, uint256));
        assertEq(outer, 0x20);
        assertEq(n, 1);
        assertEq(inner, 0x20, "first inner array starts right after the offsets");
        assertEq(m, 2);
    }

    // ------------------------------------------------------------- curation

    function test_addAppends() public {
        ep.add(RPC, BASE, "https://c");
        _eq(ep.listAt(RPC, BASE), _l("https://a", "https://b", "https://c"));
    }

    function test_removePreservesOrder() public {
        ep.add(RPC, BASE, "https://c");
        ep.remove(RPC, BASE, 0);
        _eq(ep.listAt(RPC, BASE), _l("https://b", "https://c"));
    }

    function test_popUndoesAnAdd() public {
        ep.add(RPC, BASE, "https://c");
        ep.pop(RPC, BASE);
        _eq(ep.listAt(RPC, BASE), _l("https://a", "https://b"));
    }

    function test_popOnAnEmptyListIsRefused() public {
        vm.expectRevert(zEndpoints.BadIndex.selector);
        ep.pop(TACIT, 1);
    }

    function test_moveShiftsBothWays() public {
        ep.add(RPC, BASE, "https://c");
        ep.move(RPC, BASE, 0, 2);
        _eq(ep.listAt(RPC, BASE), _l("https://b", "https://c", "https://a"));
        ep.move(RPC, BASE, 2, 0);
        _eq(ep.listAt(RPC, BASE), _l("https://a", "https://b", "https://c"));
        ep.move(RPC, BASE, 1, 1);
        _eq(ep.listAt(RPC, BASE), _l("https://a", "https://b", "https://c"));
    }

    function test_setAtReplacesInPlace() public {
        ep.setAt(RPC, BASE, 1, "https://z");
        _eq(ep.listAt(RPC, BASE), _l("https://a", "https://z"));
        assertEq(ep.get(RPC, BASE, 1), "https://z");
    }

    function test_opsAreScopedToOneList() public {
        ep.set(RPC, RH, _l("https://r"));
        ep.remove(RPC, BASE, 0);
        _eq(ep.listAt(RPC, RH), _l("https://r"), "a Base edit leaves Robinhood alone");
    }

    function test_aStaleIndexFailsLegibly() public {
        vm.expectRevert(zEndpoints.BadIndex.selector);
        ep.remove(RPC, BASE, 2);
        vm.expectRevert(zEndpoints.BadIndex.selector);
        ep.move(RPC, BASE, 0, 2);
        vm.expectRevert(zEndpoints.BadIndex.selector);
        ep.setAt(RPC, RH, 0, "https://x");
        vm.expectRevert(zEndpoints.BadIndex.selector);
        ep.get(RPC, BASE, 5);
    }

    function test_setAnnouncesWhatItDiscards() public {
        vm.expectEmit(true, true, false, true);
        emit zEndpoints.Reset(RPC, BASE, 2);
        vm.expectEmit(true, true, false, true);
        emit zEndpoints.Added(RPC, BASE, 0, "https://x");
        ep.set(RPC, BASE, _l("https://x"));
    }

    function test_removeAnnouncesTheEntry() public {
        vm.expectEmit(true, true, false, true);
        emit zEndpoints.Removed(RPC, BASE, 0, "https://a");
        ep.remove(RPC, BASE, 0);
    }

    // ------------------------------------------------------------- who curates

    function test_nobodyElseCanCurate() public {
        vm.startPrank(stranger);
        vm.expectRevert(zEndpoints.NotOwner.selector);
        ep.add(RPC, BASE, "https://evil");
        vm.expectRevert(zEndpoints.NotOwner.selector);
        ep.remove(RPC, BASE, 0);
        vm.expectRevert(zEndpoints.NotOwner.selector);
        ep.pop(RPC, BASE);
        vm.expectRevert(zEndpoints.NotOwner.selector);
        ep.move(RPC, BASE, 0, 1);
        vm.expectRevert(zEndpoints.NotOwner.selector);
        ep.setAt(RPC, BASE, 0, "https://evil");
        vm.expectRevert(zEndpoints.NotOwner.selector);
        ep.set(RPC, BASE, _l("https://evil"));
        vm.expectRevert(zEndpoints.NotOwner.selector);
        ep.transferOwnership(stranger);
        vm.stopPrank();
    }

    function test_ownershipMovesInTwoSteps() public {
        ep.transferOwnership(next);
        assertEq(ep.owner(), owner, "an offer changes nothing");
        assertEq(ep.pendingOwner(), next);
        vm.prank(stranger);
        vm.expectRevert(zEndpoints.NotOwner.selector);
        ep.acceptOwnership();
        vm.prank(next);
        ep.acceptOwnership();
        assertEq(ep.owner(), next);
        assertEq(ep.pendingOwner(), address(0));
        vm.expectRevert(zEndpoints.NotOwner.selector);
        ep.add(RPC, BASE, "https://late");
    }

    function test_anOfferCanBeWithdrawn() public {
        ep.transferOwnership(next);
        ep.transferOwnership(address(0));
        vm.prank(next);
        vm.expectRevert(zEndpoints.NotOwner.selector);
        ep.acceptOwnership();
    }
}
