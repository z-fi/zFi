// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListLens} from "../src/utils/TokenListLens.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";
import {PostDeployListings} from "./PostDeployListings.sol";

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function setName(string memory n) public {
        name = n;
    }
}

contract HostileToken {
    function name() public pure returns (string memory) {
        return "'><script>x</script> Ether";
    }

    function symbol() public pure returns (string memory) {
        return "ETH";
    }

    function decimals() public pure returns (uint8) {
        revert("nope");
    }
}

/// @dev A token that answers normally until it is muted, at which point every
///      metadata call reverts — a proxy that got upgraded, a token that revoked its
///      metadata, an implementation that grew past the READ_GAS cap.
contract MuteToken {
    bool public muted;

    function mute() public {
        muted = true;
    }

    function name() public view returns (string memory) {
        require(!muted);
        return "Real Name";
    }

    function symbol() public view returns (string memory) {
        require(!muted);
        return "REAL";
    }

    function decimals() public view returns (uint8) {
        require(!muted);
        return 6;
    }
}

/// @dev Metadata is deliberately ordinary; the interface response alone is what
///      lets TokenList distinguish a collection from the ERC-20 fallback.
contract MockCollection {
    function name() external pure returns (string memory) {
        return "Mock Collection";
    }

    function symbol() external pure returns (string memory) {
        return "MOCK";
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x80ac58cd;
    }
}

/// @dev Returns 274 from `decimals()` as a full 32-byte word. Solady's reader is
///      `uint8(_uint(...))`, so a naive read truncates it to 18 — a token can assert a
///      plausible decimals it never actually returned.
contract SpoofDecimalsToken {
    function name() public pure returns (string memory) {
        return "Spoof";
    }

    function symbol() public pure returns (string memory) {
        return "SPF";
    }

    function decimals() public pure returns (uint256) {
        return 274; // 0x112 -> low byte 0x12 == 18
    }
}

/// @dev A renderer swap has to visibly change the card, or the test proves nothing.
contract StubRenderer {
    function tokenURI(uint256, TokenList.Token memory, TokenListRenderer.Extra[] memory)
        public
        pure
        returns (string memory)
    {
        return "STUB";
    }

    function json(uint256, TokenList.Token memory, TokenListRenderer.Extra[] memory)
        public
        pure
        returns (string memory)
    {
        return "STUB";
    }

    /// @dev ERC-7572. `TokenList.contractURI()` forwards here, so this is now a THIRD
    ///      member of the interface any replacement renderer has to implement —
    ///      a renderer without it leaves the registry's `contractURI()` reverting.
    function contractURI() public pure returns (string memory) {
        return "STUBCOLLECTION";
    }
}

contract TokenListTest is Test, PostDeployListings {
    using LibString for string;

    TokenList list;
    TokenListLens lens;
    address owner = address(0xA11CE);
    address stranger = address(0xB0B);

    string constant LOGO = "data:image/svg+xml;base64,PHN2Zy8+";

    event Locked(uint256 tokenId);
    event ContractURIUpdated();

    /// @dev ETH plus WETH, USDC and USDT. The other seven of the original eleven are
    ///      applied after deployment — see `PostDeployListings`.
    uint256 constant SEEDED = 4;

    /// @dev Every test in this repo runs against the mainnet fork pinned in
    ///      `foundry.toml`, which is what makes the seeded set exist: seeding is
    ///      chain-id-1 only and each seed is skipped where the address has no
    ///      code. On a bare local chain the registry deploys empty and every
    ///      seed-dependent assertion here fails for a reason that has nothing to
    ///      do with the contract.
    function setUp() public {
        list = new TokenList(owner, new TokenListRenderer());
        lens = new TokenListLens();
    }

    function _list(address token, uint32 rank) internal returns (uint256) {
        vm.prank(owner);
        return list.list(token, 0x627EEA, rank, LOGO, "https://example.com", "A test token.");
    }

    // LISTING AS AN NFT ----------------------------------------------------

    function testListMintsToTokenItself() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        uint256 id = _list(address(token), 10);

        assertEq(id, uint256(uint160(address(token))));
        assertEq(list.ownerOf(id), address(token)); // the subject holds its own card
        assertEq(list.balanceOf(address(token)), 1);
        assertEq(list.name(), "Token Listing");
        assertEq(list.symbol(), "TKLIST");

        TokenList.Token memory t = list.get(address(token));
        assertEq(t.name, "Wrapped Ether");
        assertEq(t.symbol, "WETH");
        assertEq(t.decimals, 18);
        assertTrue(t.synced);
    }

    function testListingIsSoulbound() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        uint256 id = _list(address(token), 0);

        vm.prank(address(token));
        vm.expectRevert(TokenList.Soulbound.selector);
        list.transferFrom(address(token), stranger, id);
    }

    function testDelistBurnsAndRelistMints() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        uint256 id = _list(address(token), 0);

        vm.prank(owner);
        list.delist(id);
        assertEq(list.total(), SEEDED); // the seeded defaults remain
        assertFalse(list.isListed(id));
        assertEq(list.balanceOf(address(token)), 0);
        vm.expectRevert(); // ERC721: token does not exist
        list.ownerOf(id);

        uint256 again = _list(address(token), 5);
        assertEq(again, id);
        assertEq(list.ownerOf(id), address(token));
        assertEq(list.get(id).rank, 5);
    }

    function testOnlyOwnerCanListAndDelist() public {
        MockToken token = new MockToken("A", "A", 18);
        vm.prank(stranger);
        vm.expectRevert();
        list.list(address(token), 0, 0, LOGO, "", "");

        uint256 id = _list(address(token), 0);
        vm.prank(stranger);
        vm.expectRevert();
        list.delist(id);
    }

    // OWNER CANNOT FORGE FACTS ---------------------------------------------

    function testOwnerCannotForgeLocalText() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        uint256 id = _list(address(token), 0);
        vm.prank(owner);
        vm.expectRevert(TokenList.NotSyncable.selector);
        list.setForeignText(id, "Definitely USDC", "USDC", 6);
    }

    function testOwnerCannotListLocalTokenAsForeign() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        vm.prank(owner);
        vm.expectRevert(TokenList.NotSyncable.selector);
        list.listForeign(
            TokenList.Kind.EVM,
            uint64(block.chainid),
            bytes32(uint256(uint160(address(token)))),
            "USDC",
            "USDC",
            6,
            0,
            0,
            LOGO
        );
    }

    function testSyncIsPermissionless() public {
        MockToken token = new MockToken("Old Name", "OLD", 18);
        uint256 id = _list(address(token), 0);

        token.setName("New Name");
        vm.prank(stranger);
        list.sync(id);
        assertEq(list.get(id).name, "New Name");
    }

    /// @dev `sync` is permissionless, so a token that stops answering must not become
    ///      a way for anyone to blank a good listing — least of all its decimals,
    ///      which is the one field consumers compute amounts with.
    function testSyncCannotBlankALiveListing() public {
        MuteToken token = new MuteToken();
        uint256 id = _list(address(token), 0);
        assertEq(list.get(id).symbol, "REAL");
        assertEq(list.get(id).decimals, 6);

        token.mute();
        vm.prank(stranger);
        list.sync(id);

        TokenList.Token memory t = list.get(id);
        assertEq(t.name, "Real Name");
        assertEq(t.symbol, "REAL");
        assertEq(t.decimals, 6);
    }

    function testNftStandardAndArtworkHintAreExplicit() public {
        MockCollection collection = new MockCollection();
        uint256 id = _list(address(collection), 0);

        assertEq(uint8(list.get(id).standard), uint8(TokenList.Standard.ERC721));
        assertFalse(list.get(id).onchainSvg);

        vm.prank(owner);
        list.setOnchainSvg(id, true);
        assertTrue(list.get(id).onchainSvg);
        assertTrue(list.json(id).contains('"p":"ERC-721"'));
        assertTrue(list.json(id).contains('"o":true'));
        assertTrue(_decodeJSON(list.tokenURI(id)).contains('"trait_type":"Per-token Artwork","value":"Onchain SVG"}'));

        MockToken fungible = new MockToken("Fungible", "FNG", 18);
        uint256 fungibleId = _list(address(fungible), 0);
        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.setOnchainSvg(fungibleId, true);
    }

    /// @dev "the rest of the list" is naturally spelled `type(uint256).max`, and it
    ///      must page rather than panic on the overflowed `start + count`.
    function testPagingAcceptsAnUnboundedCount() public view {
        TokenList.Summary[] memory all = list.summariesPaged(0, type(uint256).max);
        assertEq(all.length, SEEDED);
        assertEq(list.summariesPaged(2, type(uint256).max).length, SEEDED - 2);
        assertEq(list.summariesPaged(SEEDED, type(uint256).max).length, 0);
        assertEq(lens.rankedIdsPaged(list, 0, type(uint256).max).length, SEEDED);
    }

    function testHostileMetadataIsSanitized() public {
        HostileToken token = new HostileToken();
        uint256 id = _list(address(token), 0);

        TokenList.Token memory t = list.get(id);
        assertFalse(t.name.contains("<"));
        assertFalse(t.name.contains(">"));
        // The apostrophe now survives — it is legal in a text node and in a JSON
        // string, and dropping it cost every possessive a curator writes. What made
        // this token hostile was the angle brackets, and those are still gone.
        assertTrue(t.name.contains("'"), "an apostrophe is text, not markup");
        assertEq(t.decimals, 0); // reverting decimals() does not brick the listing
        // The card still renders, and nothing escaped into it.
        string memory uri = list.tokenURI(id);
        assertTrue(bytes(uri).length > 0);
    }

    /// @dev A standalone SVG without its namespace is a broken image everywhere, so
    ///      the setter must refuse it rather than store art that silently never draws.
    function testLogoSVGRequiresNamespace() public {
        MockToken token = new MockToken("A", "A", 18);
        uint256 id = _list(address(token), 0);
        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.setLogoSVG(id, "<svg viewBox='0 0 32 32'><circle r='8'/></svg>");
    }

    /// @dev Every seeded logo must be a self-contained, namespaced SVG document.
    function testSeededLogosAreStandaloneSVGs() public view {
        uint256[] memory ids = lens.rankedIds(list);
        for (uint256 i; i < ids.length; ++i) {
            string memory logo = list.logoOf(ids[i]);
            assertTrue(logo.startsWith("data:image/svg+xml;base64,"));
            string memory svg = string(Base64.decode(logo.slice(26)));
            assertTrue(svg.contains("http://www.w3.org/2000/svg"));
            assertTrue(svg.startsWith("<svg"));
        }
    }

    function testLogoMustBeAURI() public {
        MockToken token = new MockToken("A", "A", 18);
        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.list(address(token), 0, 0, "javascript:alert(1)", "", "");

        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.list(address(token), 0, 0, "data:image/svg+xml,<svg onload='x'/>", "", "");
    }

    /// @dev A logo is the one display string that never passes through `_clean`, and
    ///      it is interpolated raw into `"l":"…"` and `"image":"…"`. A trailing
    ///      backslash escapes the closing quote and takes the whole JSON document
    ///      with it, so `_uri` has to reject it the way it rejects a quote.
    function testLogoCannotEscapeTheJSONString() public {
        MockToken token = new MockToken("A", "A", 18);
        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.list(address(token), 0, 0, "https://evil.example/a\\", "", "");

        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.list(address(token), 0, 0, "https://evil.example/\\\",\"v\":true", "", "");
    }

    /// @dev `setLogoSVG` and `setArt` write the same field, so they must agree on how
    ///      big it may get. Bounding the raw markup rather than the stored URI would
    ///      let this path store a third more than `setArt` accepts.
    function testLogoSVGSizeIsBoundedAfterEncoding() public {
        MockToken token = new MockToken("A", "A", 18);
        uint256 id = _list(address(token), 1);

        // Raw markup under LOGO_MAX (24,576) whose base64 form is over it.
        string memory head = "<svg xmlns='http://www.w3.org/2000/svg'><!--";
        bytes memory svg = new bytes(20_000);
        for (uint256 i; i < svg.length; ++i) {
            svg[i] = "x";
        }
        string memory big = string.concat(head, string(svg), "--></svg>");
        assertLt(bytes(big).length, 24_576);

        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.setLogoSVG(id, big);

        // The same markup at a size whose encoded form fits is accepted.
        vm.prank(owner);
        list.setLogoSVG(id, string.concat(head, "--></svg>"));
        assertTrue(bytes(list.logoOf(id)).length <= 24_576);
    }

    // PRESENTATION ---------------------------------------------------------

    function testEditableLinksAndArt() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        uint256 id = _list(address(token), 1);

        vm.prank(owner);
        list.setArt(id, 0x14F195, 9, LOGO, "https://new.example", "Updated copy.");
        TokenList.Token memory t = list.get(id);
        assertEq(t.url, "https://new.example");
        assertEq(t.description, "Updated copy.");
        assertEq(t.rank, 9);
        assertEq(t.color, 0x14F195);

        vm.prank(owner);
        list.setLogoSVG(id, "<svg xmlns='http://www.w3.org/2000/svg'/>");
        assertTrue(list.logoOf(id).startsWith("data:image/svg+xml;base64,"));

        (uint24 color, string memory hexColor) = list.themeOf(address(token));
        assertEq(color, 0x14F195);
        assertEq(hexColor, "#14f195");
    }

    /// @dev The audit link is optional: absent by default, and absent from the card
    ///      and the trait list rather than rendered as an empty line.
    function testAuditLinkIsOptional() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        uint256 id = _list(address(token), 0);

        assertEq(list.get(id).audit, "");
        string memory before = _decodeJSON(list.tokenURI(id));
        assertFalse(before.contains("AUDIT"));
        assertFalse(before.contains('"trait_type":"Audit"'));

        vm.prank(owner);
        list.setAudit(id, "https://audit.example/report");
        assertEq(list.get(id).audit, "https://audit.example/report");

        string memory later = _decodeJSON(list.tokenURI(id));
        assertTrue(later.contains('"trait_type":"Audit"'));
        assertTrue(list.json(id).contains('"au":"https://audit.example/report"'));

        vm.prank(stranger);
        vm.expectRevert();
        list.setAudit(id, "https://evil.example");
    }

    /// @dev A description at DESC_MAX must stay inside the frame: SVG text does not
    ///      wrap, so an unbroken run would print straight off the edge of the card.
    function testLongDescriptionWrapsInsideTheCard() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        vm.prank(owner);
        string memory long_ = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor"
            " incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis"
            " nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat";
        uint256 id = list.list(address(token), 0, 0, LOGO, "https://example.com", long_);

        string memory svg =
            string(Base64.decode(_imageOf(list.tokenURI(id)).slice(bytes("data:image/svg+xml;base64,").length)));
        // Rendered as several bounded lines rather than one overflowing run. The
        // band's exact y moves with the layout — the block is centred on its line
        // count — so pin the property, not the coordinates: the description is drawn
        // as multiple monospace runs, each within the glyph budget.
        uint256 runs;
        uint256 at;
        while (true) {
            at = LibString.indexOf(svg, "ui-monospace", at);
            if (at == LibString.NOT_FOUND) break;
            ++runs;
            ++at;
        }
        assertGt(runs, 1, "a long description wraps onto more than one line");
        for (uint256 i; i < 3; ++i) {
            assertTrue(bytes(_lineAt(svg, i)).length <= 84);
        }
    }

    function testTokenURICarriesLogoAndData() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        uint256 id = _list(address(token), 7);

        string memory decoded = _decodeJSON(list.tokenURI(id));
        assertTrue(decoded.contains('"name":"WETH / Token Listing"'));
        assertTrue(decoded.contains('"external_url":"https://example.com"'));
        assertTrue(decoded.contains('"trait_type":"Sort Weight","value":7'));
        assertTrue(decoded.contains('"trait_type":"Source","value":"Onchain"'));
    }

    // RANKING AND SEARCH ---------------------------------------------------

    function testRankedOrder() public {
        MockToken a = new MockToken("Alpha", "AAA", 18);
        MockToken b = new MockToken("Beta", "BBB", 18);
        MockToken c = new MockToken("Gamma", "CCC", 18);
        uint256 idA = _list(address(a), 5);
        uint256 idB = _list(address(b), 100);
        uint256 idC = _list(address(c), 50);

        // The seeded defaults rank far above these, so they occupy the head; the
        // three added tokens must still sort among themselves by descending rank.
        uint256[] memory ranked = lens.rankedIds(list);
        assertEq(ranked.length, SEEDED + 3);
        assertEq(ranked[SEEDED], idB);
        assertEq(ranked[SEEDED + 1], idC);
        assertEq(ranked[SEEDED + 2], idA);

        vm.prank(owner);
        list.setRank(idA, type(uint32).max);
        assertEq(lens.rankedIds(list)[0], idA);

        // The two pages differ deliberately: the registry pages in LISTING order and
        // the lens sorts. Ranking left the registry to buy EIP-170 headroom — see
        // the header on `TokenListLens`.
        assertEq(lens.rankedSummaries(list, 0, 1)[0].symbol, "AAA", "lens pages by rank");
        assertEq(list.summariesPaged(0, 1)[0].symbol, "ETH", "registry pages in listing order");
    }

    function testSearchIsCaseInsensitive() public {
        MockToken a = new MockToken("Zebra Coin", "ZEBRA", 18);
        uint256 idA = _list(address(a), 0);

        uint256[] memory hits = lens.search(list, "zebra", 10);
        assertEq(hits.length, 1);
        assertEq(hits[0], idA);

        hits = lens.search(list, "ZEBRA COIN", 10);
        assertEq(hits.length, 1);

        // The seeded set is searchable straight out of the constructor.
        hits = lens.search(list, "usdt", 10);
        assertEq(hits.length, 1);
        assertEq(hits[0], list.idOf(0xdAC17F958D2ee523a2206206994597C13D831ec7));

        // ...and so is a post-deploy listing, through the same index.
        _applyPostDeployListings();
        hits = lens.search(list, "wbtc", 10);
        assertEq(hits.length, 1);
        assertEq(hits[0], list.idOf(WBTC));

        assertTrue(lens.search(list, "usd", 10).length >= 2); // USDC and USDT
        assertEq(lens.search(list, "usd", 1).length, 1); // limit is respected
        assertEq(lens.search(list, "nothinghere", 10).length, 0);
    }

    // OPEN-ENDED METADATA --------------------------------------------------

    /// @dev The escape hatch that should keep new fields from ever needing a
    ///      redeploy: arbitrary keys, discoverable, sanitised, and clearable.
    function testExtraFieldsRoundTrip() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        uint256 id = _list(address(token), 0);

        vm.startPrank(owner);
        list.setExtra(id, "coingecko", "weth");
        list.setExtra(id, "twitter", "@weth");
        vm.stopPrank();

        assertEq(list.getExtra(id, "coingecko"), "weth");
        bytes32[] memory keys = list.extraKeys(id);
        assertEq(keys.length, 2);
        assertEq(list.getExtra(id, keys[0]), "weth");

        // Overwriting does not duplicate the key.
        vm.prank(owner);
        list.setExtra(id, "coingecko", "wrapped-ether");
        assertEq(list.extraKeys(id).length, 2);
        assertEq(list.getExtra(id, "coingecko"), "wrapped-ether");

        // An empty value clears the field outright rather than leaving a key that
        // reads back empty.
        vm.prank(owner);
        list.setExtra(id, "twitter", "");
        assertEq(list.extraKeys(id).length, 1);
        assertEq(list.getExtra(id, "twitter"), "");
    }

    function testExtraIsSanitizedAndOwnerOnly() public {
        MockToken token = new MockToken("A", "A", 18);
        uint256 id = _list(address(token), 0);

        vm.prank(stranger);
        vm.expectRevert();
        list.setExtra(id, "k", "v");

        vm.prank(owner);
        list.setExtra(id, "note", '"><script>x</script>');
        assertFalse(list.getExtra(id, "note").contains("<"));
        assertFalse(list.getExtra(id, "note").contains('"'));

        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.setExtra(id, bytes32(0), "v");
    }

    /// @dev A relisted token must not inherit the previous listing's fields.
    function testDelistClearsExtras() public {
        MockToken token = new MockToken("A", "A", 18);
        uint256 id = _list(address(token), 0);
        vm.startPrank(owner);
        list.setExtra(id, "coingecko", "old");
        list.delist(id);
        vm.stopPrank();

        _list(address(token), 0);
        assertEq(list.getExtra(id, "coingecko"), "");
        assertEq(list.extraKeys(id).length, 0);
    }

    // EVENTS ---------------------------------------------------------------

    /// @dev Event signatures are the one thing here that cannot be changed after
    ///      deploy, so assert the whole payload an indexer will build the list from.
    function testListedEventCarriesTheListing() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        uint256 id = list.idOf(address(token));

        vm.expectEmit(true, true, true, true);
        emit TokenList.Listed(
            id, bytes32(uint256(uint160(address(token)))), uint64(block.chainid), "WETH", "Wrapped Ether", 18, true
        );
        vm.prank(owner);
        list.list(address(token), 0x627EEA, 3, LOGO, "https://example.com", "A test token.");
    }

    function testUpdatedEventNamesTheChangedField() public {
        MockToken token = new MockToken("A", "A", 18);
        uint256 id = _list(address(token), 0);

        vm.expectEmit(true, true, false, false);
        emit TokenList.Updated(id, "rank");
        vm.prank(owner);
        list.setRank(id, 5);

        vm.expectEmit(true, true, false, false);
        emit TokenList.Updated(id, "sync");
        list.sync(id);

        vm.expectEmit(true, true, false, false);
        emit TokenList.Updated(id, "audit");
        vm.prank(owner);
        list.setAudit(id, "https://audit.example");
    }

    function testDelistedEventCarriesTheAccount() public {
        MockToken token = new MockToken("A", "A", 18);
        uint256 id = _list(address(token), 0);

        vm.expectEmit(true, true, false, false);
        emit TokenList.Delisted(id, bytes32(uint256(uint160(address(token)))));
        vm.prank(owner);
        list.delist(id);
    }

    // TYPED READS ----------------------------------------------------------

    function testStructReads() public {
        MockToken a = new MockToken("Alpha", "AAA", 18);
        uint256 idA = _list(address(a), 7);

        // An arbitrary set is fetched by batching `get(id)` through Multicallable,
        // which is what stands in for a dedicated getMany.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature("get(uint256)", idA);
        calls[1] = abi.encodeWithSignature("get(uint256)", list.idOf(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
        bytes[] memory res = list.multicall(calls);
        assertEq(abi.decode(res[0], (TokenList.Token)).symbol, "AAA");
        assertEq(abi.decode(res[1], (TokenList.Token)).symbol, "USDC");

        // Paging is rank-ordered and clamps past the end rather than reverting.
        TokenList.Summary[] memory head = list.summariesPaged(0, 3);
        assertEq(head.length, 3);
        assertEq(head[0].symbol, "ETH");
        assertEq(list.summariesPaged(0, 500).length, SEEDED + 1);
        assertEq(list.summariesPaged(500, 10).length, 0);
    }

    /// @dev Multicallable is what replaces the removed JSON `page()`: any set of ids
    ///      in one eth_call, which is strictly more flexible than a fixed window.
    function testMulticallBatchesReads() public {
        MockToken a = new MockToken("Alpha", "AAA", 18);
        uint256 idA = _list(address(a), 0);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(TokenList.json, (idA));
        calls[1] = abi.encodeCall(TokenList.total, ());
        bytes[] memory res = list.multicall(calls);

        assertTrue(abi.decode(res[0], (string)).contains('"s":"AAA"'));
        assertEq(abi.decode(res[1], (uint256)), SEEDED + 1);
    }

    // FOREIGN CHAINS -------------------------------------------------------

    function testForeignSolanaListing() public {
        bytes32 mint = bytes32(uint256(1));
        vm.prank(owner);
        uint256 id = list.listForeign(TokenList.Kind.SVM, 0, mint, "Solana Thing", "SOLT", 9, 0x14F195, 3, LOGO);

        assertEq(list.ownerOf(id), address(list)); // no local address to hold it, so the registry does
        assertTrue(id > (1 << 255)); // foreign ids never collide with addresses

        TokenList.Token memory t = list.get(id);
        assertEq(t.symbol, "SOLT");
        assertFalse(t.synced);

        string memory j = list.json(id);
        assertTrue(j.contains('"k":"solana"'));
        assertTrue(j.contains('"t":"#14f195"'));
        assertTrue(j.contains('"v":false'));

        vm.prank(owner);
        list.setForeignText(id, "Renamed", "SOLT2", 6);
        assertEq(list.get(id).name, "Renamed");
    }

    function testForeignSyncReverts() public {
        vm.prank(owner);
        uint256 id = list.listForeign(TokenList.Kind.SVM, 0, bytes32(uint256(2)), "X", "X", 9, 0, 0, "");
        vm.expectRevert(TokenList.NotSyncable.selector);
        list.sync(id);
    }

    function testDuplicateListingReverts() public {
        MockToken token = new MockToken("A", "A", 18);
        _list(address(token), 0);
        vm.prank(owner);
        vm.expectRevert(TokenList.Exists.selector);
        list.list(address(token), 0, 0, LOGO, "", "");
    }

    function testUnknownReverts() public {
        vm.expectRevert(TokenList.Unknown.selector);
        list.get(uint256(1234));
        vm.expectRevert(TokenList.Unknown.selector);
        list.tokenURI(uint256(1234));
    }

    // SEEDED DEFAULTS ------------------------------------------------------

    /// @dev This repo's tests run against a mainnet fork (see foundry.toml), so every
    ///      canonical token has code and the whole default set seeds.
    ///
    ///      FOUR entries, not eleven: the rest no longer fit under EIP-7825's
    ///      per-transaction gas cap and are listed by the owner after deployment.
    ///      The seeded ranks keep the original gaps, so wstETH (998_000), rETH
    ///      (997_000) and WBTC (996_000) drop back between WETH and USDC when they
    ///      are added, with no renumbering.
    function testSeedsFullDefaultSet() public view {
        assertEq(list.total(), SEEDED);
        uint256 ethId = list.idOf(TokenList.Kind.EVM, uint64(block.chainid), bytes32(0));
        assertEq(list.idAt(0), ethId);

        string[4] memory expected = ["ETH", "WETH", "USDC", "USDT"];
        uint256[] memory ranked = lens.rankedIds(list);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(list.get(ranked[i]).symbol, expected[i]);
        }

        TokenList.Token memory eth = list.get(ethId);
        assertEq(eth.symbol, "ETH");
        assertEq(eth.name, "Ether");
        assertEq(eth.decimals, 18);
        assertEq(eth.color, 0x627EEA);
        assertFalse(eth.synced); // no contract to read: attested, not verified
        assertTrue(eth.logo.startsWith("data:image/svg+xml;base64,"));
        assertEq(list.ownerOf(ethId), address(list)); // held by the registry, not the curator
    }

    function testSeededETHIsEditableByOwner() public {
        uint256 ethId = list.idOf(TokenList.Kind.EVM, uint64(block.chainid), bytes32(0));
        vm.prank(owner);
        list.setForeignText(ethId, "Ethereum", "ETH", 18);
        assertEq(list.get(ethId).name, "Ethereum");

        vm.prank(owner);
        list.setArt(ethId, 0x123456, 42, LOGO, "https://ethereum.foundation", "Edited.");
        assertEq(list.get(ethId).url, "https://ethereum.foundation");
        assertEq(list.get(ethId).rank, 42);
    }

    function testSeededTextComesFromTheTokens() public view {
        TokenList.Token memory usdt = list.get(0xdAC17F958D2ee523a2206206994597C13D831ec7);
        assertEq(usdt.symbol, "USDT");
        assertEq(usdt.decimals, 6); // read from the token, not written by the seed
        assertTrue(usdt.synced);

        TokenList.Token memory usdc = list.get(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(usdc.decimals, 6);
        assertTrue(usdc.synced);
    }

    /// @dev ZORG is no longer seeded — it is one of the seven the owner lists after
    ///      deployment — so this exercises the real post-deploy path and asserts the
    ///      same facts the constructor used to guarantee: text pulled from the shares
    ///      contract rather than authored, and the original rank slot.
    function testZorgPostDeployListingUsesPulledMetadata() public {
        _applyPostDeployListings();
        TokenList.Token memory t = list.get(ZORG);

        // These are pulled from the shares contract, not curator-authored text.
        assertEq(t.name, "zOrg Shares");
        assertEq(t.symbol, "ZORG");
        assertEq(t.decimals, 18);
        assertTrue(t.synced);
        assertEq(t.rank, 992_000);
        assertEq(t.url, "https://zorg.wei.domains");
        assertEq(lens.rankedIds(list)[8], list.idOf(ZORG));

        string memory svg = string(Base64.decode(t.logo.slice(26)));
        assertTrue(svg.contains("zorg-clip"));
        assertTrue(svg.contains("zorg-bg"));
        assertTrue(svg.contains("zorg-fg"));
    }

    /// @dev Same for the two NFT collections: listed after deployment, and the
    ///      ERC-721 detection plus the onchain-SVG hint must survive that route.
    function testNftCollectionsArePostDeployListedAndMarkedERC721() public {
        _applyPostDeployListings();
        TokenList.Token memory z = list.get(ZORGZ);
        TokenList.Token memory w = list.get(WNS);

        assertEq(z.name, "zOrgz");
        assertEq(z.symbol, "zzz");
        assertEq(uint8(z.standard), uint8(TokenList.Standard.ERC721));
        assertTrue(z.onchainSvg);
        assertEq(z.decimals, 0, "NFT collections do not pretend to have fungible decimals");
        assertEq(z.url, "https://opensea.io/collection/zorgz");
        assertTrue(z.synced);

        assertEq(w.name, "Wei Name Service");
        assertEq(w.symbol, "WEI");
        assertEq(uint8(w.standard), uint8(TokenList.Standard.ERC721));
        assertTrue(w.onchainSvg);
        assertEq(w.decimals, 0);
        assertEq(w.url, "https://opensea.io/collection/wei-name-service");
        assertTrue(w.synced);
        assertEq(lens.rankedIds(list)[9], list.idOf(ZORGZ));
        assertEq(lens.rankedIds(list)[10], list.idOf(WNS));

        assertTrue(list.json(list.idOf(ZORGZ)).contains('"p":"ERC-721"'));
        assertTrue(list.json(list.idOf(WNS)).contains('"p":"ERC-721"'));
        // The mark, not the placeholder. This used to assert `wns.wei`, which was the
        // text of a 400x400 white rect with 24px type in it — at the 96px the card
        // draws a logo that renders under six pixels tall, so the listing showed a
        // blank white square.
        string memory wnsSvg = string(Base64.decode(w.logo.slice(26)));
        assertTrue(wnsSvg.contains(".wei"), "carries the wordmark");
        assertFalse(wnsSvg.contains('<rect width="400" height="400" fill="#fff"/>'), "not the blank placeholder");
    }

    /// @dev The whole point of the split: applying the seven reproduces exactly the
    ///      eleven-entry list the old constructor produced, in the same order.
    function testPostDeployListingsRestoreTheOriginalEleven() public {
        _applyPostDeployListings();
        assertEq(list.total(), 11);
        string[11] memory expected =
            ["ETH", "WETH", "wstETH", "rETH", "WBTC", "USDC", "USDT", "BOLD", "ZORG", "zzz", "WEI"];
        uint256[] memory ranked = lens.rankedIds(list);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(list.get(ranked[i]).symbol, expected[i]);
            assertTrue(list.tokenURI(ranked[i]).startsWith("data:application/json;base64,"));
            assertTrue(bytes(list.logoOf(ranked[i])).length > 100, "real art, not a stub");
        }
    }

    /// @dev Each post-deploy listing must fit a transaction on its own, the same
    ///      ceiling that forced them out of the constructor.
    function _applyPostDeployListings() internal {
        Listing[] memory l = _postDeployListings();
        vm.startPrank(owner);
        for (uint256 i; i < l.length; ++i) {
            uint256 id = list.list(l[i].token, l[i].color, l[i].rank, "", l[i].url, l[i].description);
            list.setLogoSVG(id, l[i].logo);
            if (l[i].onchainSvg) list.setOnchainSvg(id, true);
            assertEq(uint8(list.get(id).standard), uint8(l[i].expectedStandard));
        }
        vm.stopPrank();
    }

    function testSeededCardsAreHeldByTheirTokens() public view {
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        assertEq(list.ownerOf(list.idOf(weth)), weth);
        assertEq(list.balanceOf(weth), 1);
    }

    function testEverySeededCardRenders() public view {
        uint256[] memory ids = lens.rankedIds(list);
        for (uint256 i; i < ids.length; ++i) {
            assertTrue(list.tokenURI(ids[i]).startsWith("data:application/json;base64,"));
            assertTrue(bytes(list.logoOf(ids[i])).length > 100); // real art, not a stub
        }
    }

    /// @dev Pull the `image` data URI out of the decoded metadata.
    function _imageOf(string memory uri) internal pure returns (string memory) {
        string memory j = _decodeJSON(uri);
        uint256 start = j.indexOf('"image":"') + 9;
        uint256 end = j.indexOf('"', start);
        return j.slice(start, end);
    }

    /// @dev The text content of the nth description line in the card.
    function _lineAt(string memory svg, uint256 n) internal pure returns (string memory) {
        string memory marker = string.concat("y='", LibString.toString(300 + n * 20), "' font-size='12'");
        uint256 at = svg.indexOf(marker);
        if (at == type(uint256).max) return "";
        uint256 open_ = svg.indexOf(">", at) + 1;
        return svg.slice(open_, svg.indexOf("<", open_));
    }

    /// @dev Decode the `data:application/json;base64,` payload so the assertions
    ///      read against the real JSON a wallet would parse.
    function _decodeJSON(string memory uri) internal pure returns (string memory) {
        // "data:application/json;base64," is 29 bytes.
        return string(Base64.decode(uri.slice(29)));
    }

    // AUDIT REGRESSIONS ----------------------------------------------------

    /// @dev M-01. Wallets spell the native asset `address(0)`. It previously got a
    ///      hashed foreign id from the namespaced overload while `idOf(address(0))`
    ///      still answered 0, so the address API could not reach a listing that
    ///      plainly existed. An identity rule cannot be migrated once cached.
    function testNativeAssetHasExactlyOneId() public view {
        uint256 viaAddress = list.idOf(address(0));
        uint256 viaTuple = list.idOf(TokenList.Kind.EVM, uint64(block.chainid), bytes32(0));
        assertEq(viaAddress, viaTuple);
        assertEq(viaAddress, 0);
        assertTrue(list.isListed(viaAddress));
        assertEq(list.get(address(0)).symbol, "ETH");
        assertEq(list.logoOf(address(0)), list.logoOf(viaTuple));
    }

    /// @dev M-02. `readDecimals` truncates the word, so 274 reads back as 18 and any
    ///      `<= 36` check waves it through. The value must be range-checked at full
    ///      width, before the cast.
    function testDecimalsCannotBeSpoofedByTruncation() public {
        SpoofDecimalsToken token = new SpoofDecimalsToken();
        uint256 id = _list(address(token), 0);
        assertEq(list.get(id).decimals, 0, "274 must not be accepted as 18");
    }

    /// @dev M-04. An EVM account with dirty upper bits renders through a fixed 20-byte
    ///      hex conversion that reverts, leaving a listing `get` returns but `json`,
    ///      `tokenURI` and every batched read revert on.
    function testForeignEVMAccountMustFitIn160Bits() public {
        bytes32 dirty = bytes32(uint256(1) << 200 | uint256(uint160(address(0xBEEF))));
        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.listForeign(TokenList.Kind.EVM, 8453, dirty, "X", "X", 18, 0, 0, LOGO);
    }

    /// @dev L-02. `delist` walks every extra key, so an unbounded key set is an
    ///      unbounded loop in the only path that can remove a listing.
    function testExtraKeysAreBounded() public {
        MockToken token = new MockToken("A", "A", 18);
        uint256 id = _list(address(token), 0);
        vm.startPrank(owner);
        for (uint256 i; i < 32; ++i) {
            list.setExtra(id, bytes32(i + 1), "v");
        }
        vm.expectRevert(TokenList.BadInput.selector);
        list.setExtra(id, bytes32(uint256(999)), "v");
        vm.stopPrank();
        assertEq(list.extraKeys(id).length, 32);

        // Clearing frees a slot, and delist still succeeds at the cap.
        vm.prank(owner);
        list.delist(id);
        assertEq(list.extraKeys(id).length, 0);
    }

    /// @dev L-05. Mutable metadata that no marketplace knows to refresh is stale
    ///      metadata; a lock no wallet can detect is a transfer button that reverts.
    function testAdvertisesMetadataUpdateAndLockInterfaces() public view {
        assertTrue(list.supportsInterface(0x49064906), "ERC-4906");
        assertTrue(list.supportsInterface(0xb45a3c0e), "ERC-5192");
        assertTrue(list.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(list.locked(list.idOf(address(0))));
    }

    /// @dev The renderer is governance-settable so the card can improve after deploy.
    ///      It must stay owner-only and code-checked: an EOA renderer would make every
    ///      `tokenURI` return empty rather than revert.
    function testRendererIsGovernedAndCodeChecked() public {
        StubRenderer stub = new StubRenderer();

        vm.prank(stranger);
        vm.expectRevert();
        list.setRenderer(TokenListRenderer(address(stub)));

        vm.prank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.setRenderer(TokenListRenderer(address(0xDEAD)));

        vm.prank(owner);
        list.setRenderer(TokenListRenderer(address(stub)));
        assertEq(list.tokenURI(list.idOf(address(0))), "STUB");
        assertEq(address(list.renderer()), address(stub));
    }

    /// @dev L-03. A whole-struct read carries the base64 logo, so a page of those is
    ///      megabytes. The reads a list UI should use must be bounded. There is no
    ///      struct-page function any more — it was removed to buy EIP-170 headroom,
    ///      and `get(id)` batched through `Multicallable` covers the case — so the
    ///      unbounded side is measured against `get` itself.
    function testPagedReadsAreBoundedAndRanked() public {
        uint256[] memory ids = lens.rankedIdsPaged(list, 0, 3);
        assertEq(ids.length, 3);
        uint256[] memory all = lens.rankedIds(list);
        assertEq(ids[0], all[0]);
        assertEq(ids[2], all[2]);
        assertEq(lens.rankedIdsPaged(list, SEEDED, 5).length, 0);
        assertEq(lens.rankedIdsPaged(list, 0, type(uint256).max).length, SEEDED);

        TokenList.Summary[] memory page = list.summariesPaged(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0].symbol, "WETH"); // rank order, ETH first
        assertEq(page[0].id, all[1]);
        assertEq(page[1].symbol, "USDC");

        // The invariant that matters is not a constant, it is that a summary row does
        // not carry the logo: growing the art must not grow the summary page at all,
        // while it grows an unbounded whole-struct read without bound.
        uint256 summaryBefore = abi.encode(list.summariesPaged(0, SEEDED)).length;

        MockToken fat = new MockToken("Fat Logo", "FAT", 18);
        bytes memory art = new bytes(12_000);
        for (uint256 i; i < art.length; ++i) {
            art[i] = "A";
        }
        vm.prank(owner);
        list.list(address(fat), 0, 1, string.concat("https://x.example/", string(art)), "", "");

        // One 12 KB logo: the struct read absorbs all of it, the summary page none.
        // The summary page still grows by exactly one row's worth of bounded fields,
        // which is the property that makes its size predictable from the row count.
        uint256 structRow = abi.encode(list.get(list.idOf(address(fat)))).length;
        uint256 summaryGrowth = abi.encode(list.summariesPaged(0, SEEDED + 1)).length - summaryBefore;
        assertGt(structRow, 12_000, "a whole-struct read carries the logo");
        assertLt(summaryGrowth, 1_024, "summary page carries one bounded row");
        assertGt(structRow, summaryGrowth * 20);
    }

    /// @dev A freeze that governance can lift is not a commitment. Every owner-authored
    ///      field must be sealed, and the seal must be permanent.
    function testFreezeSealsEveryOwnerAuthoredField() public {
        MockToken token = new MockToken("Wrapped Ether", "WETH", 18);
        uint256 id = _list(address(token), 7);

        vm.prank(owner);
        list.freeze(id);
        assertTrue(list.get(id).frozen);

        vm.startPrank(owner);
        vm.expectRevert(TokenList.NotEditable.selector);
        list.setArt(id, 1, 1, LOGO, "https://x.example", "d");
        vm.expectRevert(TokenList.NotEditable.selector);
        list.setRank(id, 99);
        vm.expectRevert(TokenList.NotEditable.selector);
        list.setAudit(id, "https://audit.example");
        vm.expectRevert(TokenList.NotEditable.selector);
        list.setLogoSVG(id, "<svg xmlns='http://www.w3.org/2000/svg'/>");
        vm.expectRevert(TokenList.NotEditable.selector);
        list.setExtra(id, "cg", "weth");
        vm.stopPrank();

        assertEq(list.get(id).rank, 7, "nothing moved");
    }

    /// @dev Freezing seals what GOVERNANCE authored, not what the token says, and must
    ///      not turn a listing into a billboard that can never be taken down.
    function testFreezeLeavesSyncAndDelistWorking() public {
        MockToken token = new MockToken("Old Name", "OLD", 18);
        uint256 id = _list(address(token), 0);
        vm.prank(owner);
        list.freeze(id);

        token.setName("New Name");
        vm.prank(stranger);
        list.sync(id); // facts still refresh from the source
        assertEq(list.get(id).name, "New Name");

        vm.prank(owner);
        list.delist(id); // a rugged project can still be removed
        assertFalse(list.isListed(id));
    }

    /// @dev A frozen listing is only sealed end-to-end once the renderer is too: a
    ///      renderer may print anything regardless of what storage holds.
    function testRendererLockIsPermanent() public {
        StubRenderer stub = new StubRenderer();

        vm.prank(stranger);
        vm.expectRevert();
        list.lockRenderer();

        vm.prank(owner);
        list.lockRenderer();
        assertTrue(list.rendererLocked());

        vm.prank(owner);
        vm.expectRevert(TokenList.NotEditable.selector);
        list.setRenderer(TokenListRenderer(address(stub)));

        // Still renders through the renderer it was locked to.
        assertTrue(bytes(list.tokenURI(list.idOf(address(0)))).length > 0);
    }

    /// @dev Freeze is not a way to relist under fresh terms: a delisted-then-relisted
    ///      id starts editable again, which is correct, but the frozen flag must not
    ///      survive as stale state on the wiped entry.
    function testFreezeDoesNotSurviveDelist() public {
        MockToken token = new MockToken("A", "A", 18);
        uint256 id = _list(address(token), 1);
        vm.startPrank(owner);
        list.freeze(id);
        list.delist(id);
        vm.stopPrank();

        uint256 again = _list(address(token), 2);
        assertEq(again, id);
        assertFalse(list.get(id).frozen);
        vm.prank(owner);
        list.setRank(id, 42);
        assertEq(list.get(id).rank, 42);
    }

    /// @dev ERC-5192 was advertised through `supportsInterface(0xb45a3c0e)` but the
    ///      event half did not exist, so an indexer classifying soulbound collections
    ///      from logs saw an ordinary transferable one and would offer listings for
    ///      sale on cards whose transfer always reverts. Every listing is born locked
    ///      and stays locked, so `Locked` is emitted on mint and `Unlocked` is
    ///      deliberately absent.
    function testEveryListingEmitsLockedOnMint() public {
        MockToken token = new MockToken("Locked Token", "LOCK", 18);
        vm.expectEmit(true, true, true, true);
        emit Locked(uint256(uint160(address(token))));
        vm.prank(owner);
        list.list(address(token), 0, 1, "", "", "");
        assertTrue(list.locked(uint256(uint160(address(token)))));
    }

    /// @dev ERC-7572. Nothing described the COLLECTION before, so a marketplace showing
    ///      the registry itself fell back to the bare ERC-721 name beside a blank tile.
    function testContractURIDescribesTheCollection() public view {
        string memory uri = list.contractURI();
        assertTrue(LibString.startsWith(uri, "data:application/json;base64,"));
        string memory decoded = string(Base64.decode(uri.slice(bytes("data:application/json;base64,").length)));
        assertTrue(decoded.contains('"name":"Token Listing"'), "names the collection");
        assertTrue(decoded.contains('"image":"data:image/svg+xml;base64,'), "carries a mark");
    }

    /// @dev It is forwarded to the renderer, so a swap restates the collection too —
    ///      and a renderer that does not implement it leaves this reverting, which is
    ///      why the stub had to grow a third function.
    function testContractURIFollowsTheRenderer() public {
        StubRenderer stub = new StubRenderer();
        vm.prank(owner);
        list.setRenderer(TokenListRenderer(address(stub)));
        assertEq(list.contractURI(), "STUBCOLLECTION");
    }

    function testRendererSwapSignalsTheCollectionRefresh() public {
        StubRenderer stub = new StubRenderer();
        vm.expectEmit(false, false, false, false);
        emit ContractURIUpdated();
        vm.prank(owner);
        list.setRenderer(TokenListRenderer(address(stub)));
    }
}
