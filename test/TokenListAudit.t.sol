// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
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
/// @dev A renderer that implements the card but not the collection metadata.
contract NoContractUriRenderer {
    fallback() external {
        revert("no contractURI");
    }
}

contract TokenListAuditTest is Test {
    address owner = address(0xA11CE);
    TokenList list;
    TokenListRenderer renderer;
    TokenListLens lens;
    MockERC20 erc20;
    MockERC721 erc721;
    MockERC20 erc20b;
    NoContractUriRenderer badRenderer;

    bytes32 constant SOL_MINT = bytes32(uint256(0xBEEF));

    event ExtraSet(uint256 indexed id, bytes32 indexed key, string value);

    function setUp() public {
        vm.chainId(8453);
        renderer = new TokenListRenderer();
        lens = new TokenListLens();
        list = new TokenList(owner, renderer);
        erc20 = new MockERC20();
        erc721 = new MockERC721();
        erc20b = new MockERC20();
        badRenderer = new NoContractUriRenderer();
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

    /// @dev A reservation is unsynced, so `setStandard` accepts ERC721 on it and
    ///      `setOnchainSvg` sticks. Activation then pulls the real ERC-20 standard back
    ///      over it, and the flag used to survive — a fungible listing claiming
    ///      per-token onchain art, irreversibly, since clearing it re-runs the same
    ///      collection gate and reverts.
    function testActivationClearsAStrandedOnchainSvgFlag() public {
        vm.prank(owner);
        uint256 id = list.reserve(keccak256("zUSD"), "zUSD", "zUSD", 18, 0, 1, "", "", "");

        vm.prank(owner);
        list.setStandard(id, TokenList.Standard.ERC721);
        vm.prank(owner);
        list.setOnchainSvg(id, true);
        assertTrue(list.get(id).onchainSvg);

        vm.prank(owner);
        list.activateReserved(id, address(erc20));

        TokenList.Token memory t = list.get(id);
        assertTrue(t.standard == TokenList.Standard.ERC20);
        assertFalse(t.onchainSvg, "a fungible listing must not claim per-token art");

        // And the flag is not merely stale: the setter still refuses to restore it.
        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.setOnchainSvg(id, true);
    }

    /// @dev A codeless probe reports UNKNOWN, which leaves the stored standard alone —
    ///      so it must leave `onchainSvg` alone too. Clearing the flag is tied to
    ///      observing a non-collection standard, never to the absence of an answer.
    function testCodelessProbeDoesNotClearOnchainSvg() public {
        vm.prank(owner);
        uint256 id = list.list(address(erc721), 0, 1, "", "", "");
        vm.prank(owner);
        list.setOnchainSvg(id, true);

        vm.etch(address(erc721), "");
        vm.expectRevert(TokenList.NotSyncable.selector);
        list.sync(id);
        assertTrue(list.get(id).onchainSvg);
    }

    /// @dev Freezing seals what governance authored. Whether the subject shipped is not
    ///      one of those things: under `_mustEdit` a frozen reservation could never be
    ///      bound to its deployed token, and the only exit was `delist`, which destroys
    ///      the stable id the reservation exists to preserve.
    function testFrozenReservationStillActivates() public {
        vm.prank(owner);
        uint256 id = list.reserve(keccak256("zUSD"), "zUSD", "zUSD", 18, 0, 1, "", "", "");
        vm.prank(owner);
        list.freeze(id);

        // Authoring is sealed, exactly as freeze promises.
        vm.prank(owner);
        vm.expectRevert(TokenList.NotEditable.selector);
        list.setArt(id, 0, 2, "", "", "");

        vm.prank(owner);
        list.activateReserved(id, address(erc20));
        assertTrue(list.get(id).deployed);
        assertEq(list.ownerOf(id), address(erc20));
        assertEq(list.get(address(erc20)).symbol, "MOCK");
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

    /// @dev The `activateReserved` twin of the case above, reached without activating:
    ///      `setStandard` walking a listing back from a collection to a fungible
    ///      standard used to leave `onchainSvg` set, and `setOnchainSvg` re-runs the
    ///      collection gate, so nothing could clear it again.
    function testSetStandardClearsOnchainSvgOnAFungibleStandard() public {
        vm.prank(owner);
        uint256 id = list.reserve(keccak256("zPOC"), "zPOC", "zPOC", 18, 0, 1, "", "", "");
        vm.prank(owner);
        list.setStandard(id, TokenList.Standard.ERC721);
        vm.prank(owner);
        list.setOnchainSvg(id, true);
        assertTrue(list.get(id).onchainSvg);

        // Owner walks the standard back to a fungible one.
        vm.prank(owner);
        list.setStandard(id, TokenList.Standard.ERC20);
        assertFalse(list.get(id).onchainSvg, "flag stranded on a fungible listing");

        // And it stays clearable rather than being sealed in the "on" position.
        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.setOnchainSvg(id, true);
    }

    /// @dev Delisting burns the card from the token contract and drops the entry
    ///      whole — rank included. No other listing's stored rank moves.
    function testDelistBurnsTheCardAndDropsTheRank() public {
        vm.startPrank(owner);
        uint256 a = list.list(address(erc20), 0, 500, "", "", "");
        uint256 b = list.list(address(erc721), 0, 400, "", "", "");
        vm.stopPrank();

        assertEq(list.ownerOf(a), address(erc20));
        assertEq(list.get(a).rank, 500);

        vm.prank(owner);
        list.delist(a);

        // The NFT is burned from the token contract.
        vm.expectRevert();
        list.ownerOf(a);
        assertEq(list.balanceOf(address(erc20)), 0);
        // The whole entry is gone, rank included.
        vm.expectRevert(TokenList.Unknown.selector);
        list.get(a);
        // Nobody else's stored rank moved.
        assertEq(list.get(b).rank, 400);
        assertEq(list.total(), 1);
    }

    /// @dev Delisting swap-pops `_ids`, and `rankedIds` breaks ties by position in
    ///      that array, so EQUAL-RANK listings can change order when an unrelated
    ///      listing is delisted — no stored rank moves, but the last entry takes the
    ///      removed one's slot and inherits its place in the tie-break. Pinned here
    ///      because it is the one ordering property `rankedIds` does not promise:
    ///      give listings distinct ranks (the seeds leave 1,000-wide gaps) when the
    ///      order between them matters.
    function testDelistReordersEqualRanks() public {
        vm.startPrank(owner);
        uint256 a = list.list(address(erc20), 0, 7, "", "", "");
        uint256 b = list.list(address(erc721), 0, 7, "", "", "");
        uint256 c = list.listForeign(TokenList.Kind.SVM, 0, bytes32(uint256(9)), "C", "C", 9, 0, 7, "");
        vm.stopPrank();

        uint256[] memory before = lens.rankedIds(list);
        assertEq(before[0], a);
        assertEq(before[1], b);
        assertEq(before[2], c);

        vm.prank(owner);
        list.delist(a);

        // `c` was listed last, so the swap-pop moved it into `a`'s slot and it now
        // wins the tie it previously lost.
        uint256[] memory afterIds = lens.rankedIds(list);
        assertEq(afterIds[0], c);
        assertEq(afterIds[1], b);
    }

    /// @dev The registry advertises ERC-5192 through `supportsInterface`, but that id
    ///      is the `locked` selector alone — it was never evidence the event half
    ///      existed, and it did not. An indexer classifying soulbound collections from
    ///      logs saw an ordinary transferable collection.
    function testEveryMintEmitsTheErc5192Lock() public {
        vm.expectEmit(true, true, true, true);
        emit TokenList.Locked(uint256(uint160(address(erc20))));
        vm.prank(owner);
        uint256 id = list.list(address(erc20), 0, 1, "", "", "");
        assertTrue(list.locked(id));

        // Reservations and their activation mint too, and both are locked from birth.
        vm.prank(owner);
        uint256 r = list.reserve(keccak256("zLOCK"), "zLOCK", "zLOCK", 18, 0, 1, "", "", "");
        vm.expectEmit(true, true, true, true);
        emit TokenList.Locked(r);
        vm.prank(owner);
        list.activateReserved(r, address(erc20b));
    }

    /// @dev ERC-7572. Forwarded from the renderer in assembly, so the returndata must
    ///      decode as an ordinary string at the registry's ABI boundary.
    function testContractUriForwardsFromTheRenderer() public view {
        string memory uri = list.contractURI();
        assertEq(uri, renderer.contractURI());
        assertTrue(LibString.startsWith(uri, "data:application/json;base64,"));
        assertGt(bytes(uri).length, 100);
    }

    /// @dev A renderer without `contractURI` leaves the registry's forwarder reverting
    ///      rather than returning empty — the callee's failure bubbles, it is not
    ///      swallowed. Pinned because it is the cost of routing collection metadata
    ///      through a replaceable contract.
    function testContractUriRevertsOnARendererWithoutIt() public {
        vm.prank(owner);
        list.setRenderer(TokenListRenderer(address(badRenderer)));
        vm.expectRevert();
        list.contractURI();
    }

    /// @dev The Bitcoin-rooted formats. All four list under `Kind.OTHER` with a
    ///      32-byte account word and are never `synced` — no Bitcoin state is readable
    ///      from here, so the card must say OWNER ATTESTED rather than claim a read it
    ///      cannot perform. The enum members exist because `setStandard` takes the enum
    ///      by ABI: an out-of-range value reverts at decode, so a format not named at
    ///      deploy can never be flagged afterwards.
    function testBitcoinStandardsListAndFlag() public {
        // Tacit keys by its 32-byte asset_id, which drops into `account` verbatim.
        bytes32 assetId = keccak256("TAC");
        vm.startPrank(owner);
        uint256 tac = l_listOther(assetId, "Tacit", "TAC", 8);
        list.setStandard(tac, TokenList.Standard.TACIT);

        // A Rune's canonical id is `block:tx` text, so the word carries an encoding of
        // it and the human form goes in an extension field.
        uint256 rune = l_listOther(bytes32(uint256(keccak256("runes:840000:1"))), "Uncommon Goods", "GOODS", 0);
        list.setStandard(rune, TokenList.Standard.RUNE);
        list.setExtra(rune, "runeId", "840000:1");

        uint256 ord = l_listOther(bytes32(uint256(keccak256("ordinals:x"))), "Ordinal Thing", "ORD", 0);
        list.setStandard(ord, TokenList.Standard.ORDINAL);
        uint256 brc = l_listOther(bytes32(uint256(keccak256("brc20:ordi"))), "Ordi", "ORDI", 18);
        list.setStandard(brc, TokenList.Standard.BRC20);
        vm.stopPrank();

        assertTrue(list.get(tac).standard == TokenList.Standard.TACIT);
        assertTrue(list.get(rune).standard == TokenList.Standard.RUNE);
        assertTrue(list.get(ord).standard == TokenList.Standard.ORDINAL);
        assertTrue(list.get(brc).standard == TokenList.Standard.BRC20);

        // `account` is the origin id in the asset's own namespace, echoed verbatim.
        assertEq(list.get(tac).account, assetId);

        // None of them may ever claim an onchain read.
        assertFalse(list.get(tac).synced);
        assertTrue(LibString.contains(list.json(tac), '"p":"Tacit"'));
        assertTrue(LibString.contains(list.json(rune), '"p":"Rune"'));
        assertTrue(LibString.contains(list.json(ord), '"p":"Ordinal"'));
        assertTrue(LibString.contains(list.json(brc), '"p":"BRC-20"'));
        assertTrue(LibString.contains(list.json(tac), '"v":false'));

        // The card names the format instead of reading TOKEN STANDARD UNVERIFIED.
        string memory card = _svgOf(tac);
        assertTrue(LibString.contains(card, "TACIT CONFIDENTIAL / 8 DECIMALS"));
        assertTrue(LibString.contains(card, "OWNER ATTESTED"));
        assertTrue(LibString.contains(_svgOf(rune), "BITCOIN RUNE"));
    }

    /// @dev `sync` must stay refused for every non-EVM listing: there is no Bitcoin
    ///      state readable here, so a successful sync could only ever be a lie.
    function testBitcoinListingsCanNeverBeSynced() public {
        vm.prank(owner);
        uint256 tac = l_listOther(keccak256("TAC"), "Tacit", "TAC", 8);
        vm.expectRevert(TokenList.NotSyncable.selector);
        list.sync(tac);
    }

    function l_listOther(bytes32 account, string memory n, string memory sym, uint8 dec) internal returns (uint256) {
        return list.listForeign(TokenList.Kind.OTHER, 0, account, n, sym, dec, 0xF7931A, 900, "");
    }

    /// @dev The card SVG, decoded out of the nested `data:` URIs `tokenURI` returns.
    function _svgOf(uint256 id) internal view returns (string memory) {
        string memory meta =
            string(Base64.decode(LibString.slice(list.tokenURI(id), bytes("data:application/json;base64,").length)));
        uint256 at = LibString.indexOf(meta, '"image":"data:image/svg+xml;base64,');
        string memory tail = LibString.slice(meta, at + bytes('"image":"data:image/svg+xml;base64,').length);
        return string(Base64.decode(LibString.slice(tail, 0, LibString.indexOf(tail, '"'))));
    }

    /// @dev The real flagship Tacit asset id, pinned. Tacit is the clean case for this
    ///      schema: a 32-byte `asset_id` is exactly the width of `account`, so it is
    ///      stored and rendered verbatim with no encoding convention to agree on —
    ///      unlike Runes (`block:tx` text) or Ordinals (`<txid>i<index>`, too long).
    ///
    ///      The listing id is asserted because it is PERMANENT and chain-independent:
    ///      `idOf` hashes the chainId ARGUMENT (0 for non-EVM), not `block.chainid`, so
    ///      TAC has the same listing id on every chain this registry is deployed to.
    ///      Governance calldata can be written against it before anything is listed.
    function testRealTacAssetIdRoundTrips() public {
        bytes32 tacAssetId = 0xf0bbe868af10c6c67652a99709bf32048d1aa7194efe3e9a1ef1bde43f94762b;
        vm.startPrank(owner);
        uint256 id = list.listForeign(TokenList.Kind.OTHER, 0, tacAssetId, "Tacit", "TAC", 8, 0xF7931A, 900, "");
        list.setStandard(id, TokenList.Standard.TACIT);
        vm.stopPrank();

        assertEq(id, 0xe64b4fb0dbc77241a053efc73e6e9fa65d5d15c48f4e018aa9d8fb0957086ae8);
        assertEq(list.get(id).account, tacAssetId, "asset_id must echo back verbatim");
        assertTrue(
            LibString.contains(list.json(id), "0xf0bbe868af10c6c67652a99709bf32048d1aa7194efe3e9a1ef1bde43f94762b")
        );

        // Same id whatever chain the registry sits on.
        vm.chainId(1);
        assertEq(list.idOf(TokenList.Kind.OTHER, 0, tacAssetId), id);
    }

    // ACCOUNT CONVENTION FOR BITCOIN-ROOTED FORMATS ------------------------
    //
    // The registry cannot validate a Bitcoin identifier — it has no way to see that
    // chain — so this is a convention the curator must apply, not a rule the contract
    // enforces. It is pinned here because listing ids are `keccak256(kind, chainId,
    // account)` and therefore PERMANENT: the scheme cannot be revised after the first
    // listing without orphaning every card minted under the old one.
    //
    // RULE: `account` holds the protocol's own canonical 32-byte id when it has one,
    // and otherwise a domain-separated keccak of its canonical STRING form. Only
    // Tacit has a native 32-byte id, so only Tacit is stored verbatim.
    //
    // Hashing rather than bit-packing, even for Runes where `block:tx` is 96 bits and
    // would fit: packing needs a bespoke per-format layout that only this project
    // would know, still needs a domain tag to stay collision-free, and cannot be done
    // at all for an inscription id. One rule that covers all four is worth more to an
    // indexer than a reversible layout for the two shortest — especially since the
    // human-readable form travels in the `ref` extra either way, because the renderer
    // shows a non-EVM account as raw hex that no reader can parse.

    /// @dev Rune ID, not rune name: names carry display-only `•` spacers, so the same
    ///      rune has several equally valid spellings and no single canonical string.
    function _runeAccount(uint64 blockHeight, uint32 tx_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("rune:", LibString.toString(blockHeight), ":", LibString.toString(tx_)));
    }

    /// @dev The full inscription id including `i<index>`, which is present even at 0.
    ///      For a COLLECTION use its parent inscription id, per ordinals provenance.
    function _ordAccount(string memory inscriptionId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("ord:", inscriptionId));
    }

    /// @dev LOWERCASED. BRC-20 tickers are case-insensitive and first-deploy-wins, so
    ///      `CAT` and `cat` are one token. Hashing them unnormalised would mint two
    ///      listings with two ids for one asset — the duplicate-identity failure this
    ///      schema already refuses for the native asset and for Solana mints.
    function _brc20Account(string memory ticker) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("brc20:", LibString.lower(ticker)));
    }

    function testBitcoinAccountConventionIsCollisionFree() public {
        bytes32 tac = 0xf0bbe868af10c6c67652a99709bf32048d1aa7194efe3e9a1ef1bde43f94762b;
        bytes32 rune = _runeAccount(840000, 1);
        bytes32 ord = _ordAccount("521f8eccffa4c41a3a7728dd012ea5a4a02feed81f41159231251ecf1e5c79dai0");
        bytes32 brc = _brc20Account("ordi");

        assertTrue(tac != rune && tac != ord && tac != brc);
        assertTrue(rune != ord && rune != brc && ord != brc);

        // Case folding: the three spellings of one BRC-20 ticker are one account.
        assertEq(_brc20Account("CAT"), _brc20Account("cat"));
        assertEq(_brc20Account("Cat"), _brc20Account("cat"));

        // Domain separation: a rune and an inscription cannot collide even if their
        // underlying strings were identical.
        assertTrue(_runeAccount(840000, 1) != _ordAccount("840000:1"));

        // All four list, under distinct permanent ids, in the one shared namespace.
        vm.startPrank(owner);
        uint256 a = l_listOther(tac, "Tacit", "TAC", 8);
        uint256 b = l_listOther(rune, "Uncommon Goods", "GOODS", 0);
        uint256 c = l_listOther(ord, "An Inscription", "ORD", 0);
        uint256 d = l_listOther(brc, "Ordi", "ORDI", 18);
        list.setExtra(b, "ref", "840000:1");
        list.setExtra(c, "ref", "521f8eccffa4c41a3a7728dd012ea5a4a02feed81f41159231251ecf1e5c79dai0");
        list.setExtra(d, "ref", "ordi");
        vm.stopPrank();
        assertEq(list.total(), 4);
        assertTrue(a != b && b != c && c != d);
    }

    /// @dev A Bitcoin-native asset that expects an EVM version later — an ordinals
    ///      collection with a bridged ERC-20 coming — is TWO listings, not one that
    ///      migrates. A listing's `Kind` is fixed: `reserve` hardcodes `Kind.EVM` and
    ///      `activateReserved` requires it, so a `Kind.OTHER` card can never become an
    ///      EVM card. That is the right shape anyway: the Bitcoin-native collection and
    ///      a bridged ERC-20 have different custody and different risk, and a swap UI
    ///      must not conflate them.
    ///
    ///      Pinned here because the two halves say different things about existence and
    ///      both need to stay true: the Bitcoin card is `deployed` (the asset is live,
    ///      just not here), while the reservation is not (no EVM address yet, so the
    ///      card carries the NOT DEPLOYED banner). Marking the live Bitcoin asset as
    ///      undeployed to get one card instead of two would tell every reader that a
    ///      collection trading on Bitcoin today does not exist.
    function testBitcoinAssetPlusReservedEvmAddress() public {
        bytes32 ordAccount = _ordAccount("abc123i0");
        vm.startPrank(owner);

        // 1. The live Bitcoin collection.
        uint256 btc = l_listOther(ordAccount, "Bitcoin Puppets", "PUPPETS", 0);
        list.setStandard(btc, TokenList.Standard.ORDINAL);
        list.setExtra(btc, "ref", "abc123i0");

        // 2. The EVM address it has not shipped yet.
        uint256 evm =
            list.reserve(keccak256("bitcoin-puppets"), "Bitcoin Puppets", "PUPPETS", 18, 0xF7931A, 799, "", "", "");
        list.setExtra(evm, "origin", "ordinals:abc123i0");
        vm.stopPrank();

        assertTrue(list.get(btc).deployed, "the Bitcoin asset exists, it is just not here");
        assertFalse(list.get(evm).deployed, "the EVM address does not exist yet");
        assertTrue(list.get(btc).standard == TokenList.Standard.ORDINAL);

        // 3. The ERC-20 ships and binds to the reservation, keeping its id and extras.
        vm.prank(owner);
        list.activateReserved(evm, address(erc20b));

        TokenList.Token memory t = list.get(evm);
        assertTrue(t.deployed && t.synced, "now a real, onchain-read listing");
        assertEq(list.getExtra(evm, "origin"), "ordinals:abc123i0", "provenance survives activation");
        assertEq(list.get(address(erc20b)).symbol, t.symbol, "address now resolves to the reserved card");
        // `_pull` copies what the token actually reports, so the stored standard
        // becomes ERC20. The Bitcoin origin lives in extras precisely because this
        // field cannot hold it once the subject is a real ERC-20.
        assertTrue(t.standard == TokenList.Standard.ERC20);
        // And the Bitcoin card is untouched: two assets, two cards, both still true.
        assertTrue(list.get(btc).standard == TokenList.Standard.ORDINAL);
        assertTrue(list.isListed(btc) && list.isListed(evm));
    }

    /// @dev The registry stores the apostrophe; see `_clean`. Asserted here because
    ///      storage is what every other consumer reads, and the two have to agree.
    function testCuratedTextKeepsItsApostrophes() public {
        vm.prank(owner);
        uint256 id = list.list(
            address(erc20), 0, 1, "", "https://circle.com", "Circle's dollar, and it doesn't lose punctuation."
        );
        assertEq(list.get(id).description, "Circle's dollar, and it doesn't lose punctuation.");
        assertTrue(LibString.contains(list.json(id), "Circle's dollar"));
    }

    /// @dev But the characters that genuinely break out of a JSON string or an SVG
    ///      text node are still dropped on the way in.
    function testMarkupCharactersAreStillStripped() public {
        vm.prank(owner);
        uint256 id = list.list(address(erc20), 0, 1, "", "", "<script>x</script> & \"quoted\" \\ end");
        string memory d = list.get(id).description;
        assertFalse(LibString.contains(d, "<"));
        assertFalse(LibString.contains(d, ">"));
        assertFalse(LibString.contains(d, "&"));
        assertFalse(LibString.contains(d, '"'));
        assertFalse(LibString.contains(d, "\\"));
    }
}
