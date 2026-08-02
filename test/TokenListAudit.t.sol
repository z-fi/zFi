// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListLens} from "../src/utils/TokenListLens.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";

contract MockERC20 {
    function name() public pure returns (string memory) {
        return "Mock Token";
    }

    function symbol() public pure returns (string memory) {
        return "MOCK";
    }

    function decimals() public pure returns (uint8) {
        return 6;
    }
}

contract MockERC721 {
    function name() public pure returns (string memory) {
        return "Mock Collection";
    }

    function symbol() public pure returns (string memory) {
        return "MOCKN";
    }

    function supportsInterface(bytes4 id) public pure returns (bool) {
        return id == 0x80ac58cd;
    }
}

/// @notice Audit follow-ups. Deployed off mainnet so the constructor seeds nothing and
///         each case starts from an empty, fork-free list.
contract TokenListAuditTest is Test {
    address owner = address(0xA11CE);
    TokenList list;
    TokenListLens lens;
    MockERC20 erc20;
    MockERC721 erc721;

    bytes32 constant SOL_MINT = bytes32(uint256(0xBEEF));

    event ExtraSet(uint256 indexed id, bytes32 indexed key, string value);

    function setUp() public {
        vm.chainId(8453);
        list = new TokenList(owner, new TokenListRenderer());
        lens = new TokenListLens();
        erc20 = new MockERC20();
        erc721 = new MockERC721();
    }

    function _listErc20() internal returns (uint256 id) {
        vm.prank(owner);
        id = list.list(address(erc20), 0x112233, 1000, "", "https://mock.xyz", "A mock token.");
    }

    function _listForeign() internal returns (uint256 id) {
        vm.prank(owner);
        id = list.listForeign(TokenList.Kind.SVM, 0, SOL_MINT, "Solana Thing", "SOL", 9, 0x000000, 500, "");
    }

    /// @dev `json()` emitted `"o":false","a":"` — a stray quote after a bare boolean,
    ///      which made every listing's document unparseable. The existing tests only
    ///      substring-matched fields, so each one passed against broken JSON. Assert
    ///      the property those checks cannot see: no literal is followed by a quote.
    function testJsonIsParseable() public {
        uint256 id = _listErc20();
        string memory j = list.json(id);
        assertTrue(LibString.startsWith(j, "{"));
        assertTrue(LibString.endsWith(j, "}"));
        // The exact defect, and its twin on the other boolean field.
        assertTrue(LibString.contains(j, '"f":false,"a":"'));
        assertTrue(LibString.contains(j, '"x":true,"o":false,"f":false,'));
        assertFalse(LibString.contains(j, 'true"'));
        assertFalse(LibString.contains(j, 'false"'));
        // Structural: quotes must pair, and no field may be left open.
        bytes memory raw = bytes(j);
        uint256 quotes;
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] == '"') ++quotes;
        }
        assertEq(quotes % 2, 0, "unbalanced quotes");
        // 19 keys plus the 11 fields whose values are strings; the other eight
        // (c, x, o, f, d, r, e, v) are bare and must carry no quotes at all — `e`
        // because a listing with no extension fields renders it as `[]`.
        assertEq(quotes, 2 * (19 + 11), "every quote paired and accounted for");
    }

    function testReservationActivatesWithoutChangingItsListingId() public {
        bytes32 key = keccak256("zUSD");
        vm.prank(owner);
        uint256 id = list.reserve(
            key,
            "zUSD",
            "zUSD",
            18,
            0x9A9A9A,
            900,
            "",
            "https://zusd.example",
            "Reserved for a future stablecoin deployment."
        );

        assertEq(id, list.reservationId(key));
        assertEq(list.ownerOf(id), address(list));
        TokenList.Token memory reserved = list.get(id);
        assertFalse(reserved.deployed);
        assertEq(uint8(reserved.standard), uint8(TokenList.Standard.ERC20));
        assertEq(reserved.account, bytes32(0));
        assertTrue(LibString.contains(list.json(id), '"x":false'));
        assertFalse(list.summariesPaged(0, 1)[0].deployed);

        vm.prank(owner);
        list.activateReserved(id, address(erc20));

        TokenList.Token memory active = list.get(id);
        assertTrue(active.deployed);
        assertTrue(active.synced);
        assertEq(active.symbol, "MOCK"); // facts now come from the deployed contract
        assertEq(list.ownerOf(id), address(erc20));
        assertEq(list.get(address(erc20)).symbol, "MOCK");
        assertTrue(LibString.contains(list.json(id), '"x":true'));
        assertEq(list.idOf(address(erc20)), uint256(uint160(address(erc20))));
        assertFalse(list.isListed(list.idOf(address(erc20)))); // the reserved id is stable
    }

    function testReservationRejectsACollectionAndClearsItsAddressBindingOnDelist() public {
        vm.prank(owner);
        uint256 id = list.reserve(keccak256("zUSD"), "zUSD", "zUSD", 18, 0, 1, "", "", "");

        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.activateReserved(id, address(erc721));

        vm.prank(owner);
        list.activateReserved(id, address(erc20));
        vm.prank(owner);
        list.delist(id);
        vm.expectRevert(TokenList.Unknown.selector);
        list.get(address(erc20));
    }

    /// @dev `sync` is permissionless. Once a listed token has no code every read below
    ///      answers empty, so the call would re-assert `synced = true` on a card whose
    ///      subject is gone. `list` already refuses a codeless address; `sync` must too.
    function testSyncRefusesACodelessToken() public {
        uint256 id = _listErc20();
        vm.etch(address(erc20), "");
        vm.expectRevert(TokenList.NotSyncable.selector);
        list.sync(id);
    }

    /// @dev The ERC-20 fallback in `_standardOf` is a reading when the probes were
    ///      answered and a guess when there was nothing to answer them. A collection
    ///      listing must not be demoted to ERC-20 by a probe that found no code — that
    ///      would also void `onchainSvg` in the renderer and lock `setOnchainSvg` out
    ///      of restoring it.
    function testCodelessProbeDoesNotDemoteACollection() public {
        vm.prank(owner);
        uint256 id = list.list(address(erc721), 0x112233, 1000, "", "", "");
        assertTrue(list.get(id).standard == TokenList.Standard.ERC721);

        vm.etch(address(erc721), "");
        vm.expectRevert(TokenList.NotSyncable.selector);
        list.sync(id);
        assertTrue(list.get(id).standard == TokenList.Standard.ERC721);
    }

    /// @dev Freezing twice is a no-op that used to still emit `Froze` and
    ///      `MetadataUpdate`, telling every indexer to re-read an unchanged listing.
    function testFreezeIsNotIdempotent() public {
        uint256 id = _listErc20();
        vm.prank(owner);
        list.freeze(id);
        vm.prank(owner);
        vm.expectRevert(TokenList.NotEditable.selector);
        list.freeze(id);
    }

    /// @dev Clearing a key that was never set changes nothing, so it must not announce
    ///      a write. The listing's key set stays untouched either way.
    function testClearingAnUnsetExtraIsSilent() public {
        uint256 id = _listErc20();
        vm.recordLogs();
        vm.prank(owner);
        list.setExtra(id, "cg", "");
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(list.extraKeys(id).length, 0);

        // The real set/clear round trip still emits and still tidies the key set.
        vm.prank(owner);
        list.setExtra(id, "cg", "mock-token");
        assertEq(list.extraKeys(id).length, 1);
        vm.prank(owner);
        list.setExtra(id, "cg", "");
        assertEq(list.extraKeys(id).length, 0);
        assertEq(list.getExtra(id, "cg"), "");
    }

    /// @dev A foreign listing has no onchain source here, so `standard` was stuck at
    ///      UNKNOWN forever: the card could not say what the asset was, and
    ///      `setOnchainSvg` — which requires a collection standard — could never apply
    ///      to an offchain NFT collection.
    function testForeignStandardIsAuthorable() public {
        uint256 id = _listForeign();
        assertTrue(list.get(id).standard == TokenList.Standard.UNKNOWN);

        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.setOnchainSvg(id, true);

        vm.prank(owner);
        list.setStandard(id, TokenList.Standard.ERC721);
        assertTrue(list.get(id).standard == TokenList.Standard.ERC721);

        vm.prank(owner);
        list.setOnchainSvg(id, true);
        assertTrue(list.get(id).onchainSvg);
    }

    /// @dev The counterpart guarantee to `setForeignText`: a local listing's standard
    ///      is derived from the token and the owner cannot overwrite it.
    function testSyncedStandardIsNotAuthorable() public {
        uint256 id = _listErc20();
        vm.prank(owner);
        vm.expectRevert(TokenList.NotEditable.selector);
        list.setStandard(id, TokenList.Standard.ERC721);
    }

    /// @dev A frozen listing seals owner-authored fields, and the standard of a foreign
    ///      listing is one of them.
    function testFrozenStandardIsSealed() public {
        uint256 id = _listForeign();
        vm.prank(owner);
        list.freeze(id);
        vm.prank(owner);
        vm.expectRevert(TokenList.NotEditable.selector);
        list.setStandard(id, TokenList.Standard.ERC721);
    }

    /// @dev `search` allocated one word per listing regardless of the cap the caller
    ///      asked for. The results themselves must not change.
    function testSearchHonoursItsLimit() public {
        _listErc20();
        _listForeign();
        assertEq(lens.search(list, "mock", 10).length, 1);
        assertEq(lens.search(list, "o", 10).length, 2); // "Mock Token" and "Solana Thing"
        assertEq(lens.search(list, "o", 1).length, 1);
        assertEq(lens.search(list, "o", 0).length, 0);
        assertEq(lens.search(list, "nothinghere", 10).length, 0);
    }

    /// @dev An index past the end is an unknown listing, not a panic.
    function testIdAtRevertsPastTheEnd() public {
        _listErc20();
        assertEq(list.idAt(0), list.idOf(address(erc20)));
        vm.expectRevert(TokenList.Unknown.selector);
        list.idAt(1);
    }
}
