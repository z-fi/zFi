// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";

/// @notice Renderer audit follow-ups. These exercise the renderer DIRECTLY rather
///         than through the registry, because the renderer is `public pure` over a
///         caller-supplied struct: anyone may call it with anything, and the
///         registry's `_clean` is not in the path when they do.
contract TokenListRendererTest is Test {
    TokenListRenderer r;

    function setUp() public {
        r = new TokenListRenderer();
    }

    function _token() internal pure returns (TokenList.Token memory t) {
        t.account = bytes32(uint256(uint160(0x1111111111111111111111111111111111111111)));
        t.chainId = 1;
        t.decimals = 18;
        t.kind = TokenList.Kind.EVM;
        t.standard = TokenList.Standard.ERC20;
        t.deployed = true;
        t.synced = true;
        t.color = 0x627EEA;
        t.rank = 1000;
        t.name = "Mock Token";
        t.symbol = "MOCK";
        t.url = "https://mock.xyz";
        t.description = "A token used in tests.";
    }

    /// @dev The metadata document, decoded out of the `data:application/json` URI.
    function _meta(string memory uri) internal pure returns (string memory) {
        return string(Base64.decode(LibString.slice(uri, bytes("data:application/json;base64,").length)));
    }

    function _svg(string memory uri) internal pure returns (string memory) {
        string memory json = _meta(uri);
        uint256 at = LibString.indexOf(json, '"image":"data:image/svg+xml;base64,');
        string memory tail = LibString.slice(json, at + bytes('"image":"data:image/svg+xml;base64,').length);
        return string(Base64.decode(LibString.slice(tail, 0, LibString.indexOf(tail, '"'))));
    }

    /// @dev y of the reserved banner's opaque bar. Keyed off its width, which is the
    ///      only rect on the card 656 wide — matching on `<rect x='32'` alone finds
    ///      the logo well at y=110 first.
    function _bannerTop(string memory svg) internal pure returns (uint256) {
        uint256 at = LibString.indexOf(svg, "width='656'");
        require(at != LibString.NOT_FOUND, "no banner");
        string memory head = LibString.slice(svg, 0, at);
        uint256 y = LibString.lastIndexOf(head, "y='");
        require(y != LibString.NOT_FOUND, "banner has no y");
        return _uintAt(svg, y + 3);
    }

    /// @dev Baselines of the monospace description lines, in document order.
    function _descBaselines(string memory svg) internal pure returns (uint256[] memory out) {
        string memory needle = "<text x='32' y='";
        uint256[] memory found = new uint256[](8);
        uint256 n;
        uint256 at;
        while (n < 8) {
            at = LibString.indexOf(svg, needle, at);
            if (at == LibString.NOT_FOUND) break;
            uint256 v = _uintAt(svg, at + bytes(needle).length);
            // Only the wrapped description band uses the monospace stack.
            uint256 tagEnd = LibString.indexOf(svg, ">", at);
            if (LibString.contains(LibString.slice(svg, at, tagEnd), "ui-monospace")) found[n++] = v;
            ++at;
        }
        out = found;
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _uintAt(string memory s, uint256 i) internal pure returns (uint256 v) {
        bytes memory raw = bytes(s);
        while (i < raw.length && raw[i] >= 0x30 && raw[i] <= 0x39) {
            v = v * 10 + (uint8(raw[i]) - 48);
            ++i;
        }
    }

    function _quotes(string memory s) internal pure returns (uint256 n) {
        bytes memory raw = bytes(s);
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] == '"') ++n;
        }
    }

    function _count(string memory haystack, string memory needle) internal pure returns (uint256 n) {
        uint256 at;
        while (true) {
            at = LibString.indexOf(haystack, needle, at);
            if (at == LibString.NOT_FOUND) return n;
            ++n;
            ++at;
        }
    }

    /// @dev The reservation banner was an opaque 54px band at y=278 drawn over a
    ///      description band fixed at 300/320/340, so the first two lines of every
    ///      reserved card were erased and the middle of the sentence showed through
    ///      the dim wash. A reservation is the listing whose description carries the
    ///      most weight — no account, no logo source, no onchain facts — and it was
    ///      the one listing whose description could not be read.
    function testReservedBannerDoesNotCoverTheDescription() public view {
        TokenList.Token memory t = _token();
        t.deployed = false;
        t.account = bytes32(0);
        string memory svg = _svg(r.tokenURI(1, t));
        // The property, not the coordinates: every description baseline sits above
        // the banner's top edge, and the banner clears the chip row above it. Asserted
        // by reading the numbers out of the markup so a layout tweak that preserves
        // the ordering does not fail this test, and one that breaks it does.
        uint256 bannerTop = _bannerTop(svg);
        uint256[] memory baselines = _descBaselines(svg);
        assertGt(baselines.length, 0, "description is drawn at all");
        for (uint256 i; i < baselines.length; ++i) {
            assertLt(baselines[i], bannerTop, "description line sits above the banner");
        }
        assertGt(baselines[0], 244, "first line clears the chip row");
        // And the ADDRESS block is dropped rather than printed under the banner that
        // already says the address is pending.
        assertFalse(LibString.contains(svg, ">ADDRESS<"));
        assertTrue(LibString.contains(svg, "RESERVED TOKEN / NOT DEPLOYED"));
    }

    function testDeployedCardStillShowsItsAddress() public view {
        string memory svg = _svg(r.tokenURI(1, _token()));
        assertTrue(LibString.contains(svg, ">ADDRESS<"));
        assertTrue(LibString.contains(svg, "0x1111111111111111111111111111111111111111"));
        assertFalse(LibString.contains(svg, "RESERVED TOKEN"));
    }

    /// @dev `name` was the only text on the card with no width bound. At 16px from
    ///      x=176 a 40-glyph `NAME_MAX` name runs past the 720px frame in the
    ///      uppercase worst case.
    function testLongNameIsFittedToTheFrame() public view {
        TokenList.Token memory t = _token();
        t.name = "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW"; // NAME_MAX
        string memory svg = _svg(r.tokenURI(1, t));
        assertTrue(LibString.contains(svg, "..."), "name truncated with an ellipsis");
        assertFalse(LibString.contains(svg, t.name), "the full 40-glyph run never reaches the card");
    }

    /// @dev A 12-glyph symbol at a fixed 40px ran to x=629 and crowded the band.
    function testSymbolShrinksAsItLengthens() public view {
        TokenList.Token memory t = _token();
        assertTrue(LibString.contains(_svg(r.tokenURI(1, t)), "font-size='40'"));
        t.symbol = "LONGSYMBOL12";
        assertTrue(LibString.contains(_svg(r.tokenURI(1, t)), "font-size='26'"));
    }

    /// @dev An absent symbol rendered as `???`, which reads as a broken renderer
    ///      rather than as a missing field. The card gets a placeholder; `json` does
    ///      NOT, because a program has to be able to tell absent from literal.
    function testAbsentSymbolPlaceholderIsCardOnly() public view {
        TokenList.Token memory t = _token();
        t.symbol = "";
        assertTrue(LibString.contains(_svg(r.tokenURI(1, t)), ">--<"));
        assertTrue(LibString.contains(r.json(1, t), '"s":"'));
        assertFalse(LibString.contains(r.json(1, t), '"s":"--"'));
    }

    /// @dev An undeployed listing has no account, and rendering that as the zero word
    ///      gave every reservation `0x00…00` — the id the registry deliberately gives
    ///      the NATIVE asset. Consumers keying rows by this field merged the two.
    function testUndeployedListingReportsNoAccount() public view {
        TokenList.Token memory t = _token();
        t.deployed = false;
        t.account = bytes32(0);
        assertTrue(LibString.contains(r.json(1, t), '"a":""'));
        assertFalse(LibString.contains(r.json(1, t), "0x0000000000000000000000000000000000000000"));
    }

    /// @dev `freeze` is the strongest commitment the registry makes about a listing
    ///      and neither output mentioned it, so a wallet could not tell a sealed
    ///      listing from an editable one.
    function testFrozenStateIsVisible() public view {
        TokenList.Token memory t = _token();
        assertTrue(LibString.contains(r.json(1, t), '"f":false'));
        assertFalse(LibString.contains(_svg(r.tokenURI(1, t)), ">SEALED<"));
        t.frozen = true;
        assertTrue(LibString.contains(r.json(1, t), '"f":true'));
        assertTrue(LibString.contains(_svg(r.tokenURI(1, t)), ">SEALED<"));
        assertTrue(LibString.contains(_meta(r.tokenURI(1, t)), '{"trait_type":"Curation","value":"Sealed"}'));
    }

    /// @dev The description was in the card but not in the compact JSON, so a dapp
    ///      batching `json` through `Multicallable` had to additionally fetch
    ///      `tokenURI`, base64-decode it and re-parse to reach a field already in the
    ///      struct it was reading.
    function testDescriptionIsInTheCompactJson() public view {
        assertTrue(LibString.contains(r.json(1, _token()), '"desc":"A token used in tests."'));
    }

    /// @dev `ipfs://` is accepted by the registry and resolved by nothing that renders
    ///      an SVG, so an IPFS logo drew an empty well on every card, every time.
    function testIpfsLogoIsGatewayedForDisplayOnly() public view {
        TokenList.Token memory t = _token();
        t.logo = "ipfs://QmSomeCid";
        string memory svg = _svg(r.tokenURI(1, t));
        assertTrue(LibString.contains(svg, "href='https://ipfs.io/ipfs/QmSomeCid'"));
        // Storage is untouched: the canonical URI is what `json` reports.
        assertTrue(LibString.contains(r.json(1, t), '"l":"ipfs://QmSomeCid"'));
    }

    function testDataUriLogoIsPassedThroughUnchanged() public view {
        TokenList.Token memory t = _token();
        t.logo = "data:image/svg+xml;base64,AAAA";
        assertTrue(LibString.contains(_svg(r.tokenURI(1, t)), "href='data:image/svg+xml;base64,AAAA'"));
    }

    /// @dev The renderer is `public pure` over a caller-supplied struct. Its safety
    ///      used to be entirely a property of `TokenList._clean` — a precondition
    ///      stated in no signature and enforced by nothing, on a contract the header
    ///      presents as standalone and reusable.
    function testHostileStructCannotInjectMarkupOrBreakTheJson() public view {
        TokenList.Token memory t = _token();
        t.name = "</text><script>alert(1)</script><text>";
        t.symbol = '"};alert(1);//';
        t.description = "<svg onload='x'>";
        t.url = 'https://evil"';
        string memory uri = r.tokenURI(1, t);
        string memory svg = _svg(uri);
        assertFalse(LibString.contains(svg, "<script"), "no element the caller did not get to open");
        // The payload survives as INERT TEXT and that is the point: the filter drops
        // the characters that would let it become markup, not the words. A reader
        // sees the mangled string; a parser sees one text node.
        assertTrue(LibString.contains(svg, "/textscriptalert(1)/script"), "defanged, not deleted");
        assertTrue(LibString.contains(svg, "svg onload=x"), "an attribute with no tag to attach to");
        // Every `<` and `>` in the output is one this contract wrote: the filter drops
        // them, so the tag count is a property of the layout, not of the input.
        assertEq(_count(svg, "<"), _count(svg, ">"), "balanced angle brackets");
        // And both documents stay parseable.
        assertEq(_quotes(_meta(uri)) % 2, 0, "unbalanced quotes in the metadata document");
        assertEq(_quotes(r.json(1, t)) % 2, 0, "unbalanced quotes in the compact json");
        assertTrue(LibString.contains(r.json(1, t), '"u":"https://evil"'), "the quote is dropped, not escaped");
    }

    /// @dev The theme colour is owner-chosen and the frame is pure black, so nothing
    ///      stopped a listing from picking one dark enough that its own 40px symbol
    ///      rendered as almost nothing.
    function testVeryDarkThemeIsLiftedForLegibility() public view {
        TokenList.Token memory t = _token();
        t.color = 0x050505;
        string memory svg = _svg(r.tokenURI(1, t));
        assertFalse(LibString.contains(svg, "#050505"), "the card does not paint with an unreadable hue");
        // Storage is untouched — `json` still reports what the owner set.
        assertTrue(LibString.contains(r.json(1, t), '"t":"#050505"'));
    }

    function testOrdinaryThemeIsNotAltered() public view {
        assertTrue(LibString.contains(_svg(r.tokenURI(1, _token())), "#627eea"));
    }

    /// @dev The registry's extension mapping existed so a new field cost a
    ///      transaction rather than a redeploy, but a renderer handed only the fixed
    ///      struct could never see it — so no renderer, present or future, could put
    ///      one on a card.
    function testExtrasReachTheCardTheJsonAndTheAttributes() public view {
        TokenListRenderer.Extra[] memory e = new TokenListRenderer.Extra[](2);
        e[0] = TokenListRenderer.Extra(bytes32("coingecko"), "mock-token");
        e[1] = TokenListRenderer.Extra(bytes32("x"), "@mock");
        string memory uri = r.tokenURI(1, _token(), e);
        string memory svg = _svg(uri);
        assertTrue(LibString.contains(svg, ">coingecko mock-token<"));
        assertTrue(LibString.contains(svg, ">x @mock<"));
        string memory j = r.json(1, _token(), e);
        assertTrue(LibString.contains(j, '"e":[{"k":"coingecko","v":"mock-token"},{"k":"x","v":"@mock"}]'));
        assertTrue(LibString.contains(_meta(uri), '{"trait_type":"coingecko","value":"mock-token"}'));
    }

    /// @dev A hash-shaped key has no display form better than its hex.
    function testHashKeyRendersAsHex() public view {
        TokenListRenderer.Extra[] memory e = new TokenListRenderer.Extra[](1);
        e[0] = TokenListRenderer.Extra(keccak256("category"), "stablecoin");
        assertTrue(LibString.contains(r.json(1, _token(), e), '"k":"0x'));
    }

    /// @dev The chip row stops at the frame rather than drawing off the edge.
    function testChipRowStopsAtTheFrame() public view {
        TokenListRenderer.Extra[] memory e = new TokenListRenderer.Extra[](8);
        for (uint256 i; i < 8; ++i) {
            e[i] = TokenListRenderer.Extra(bytes32("keykeykey"), "a value that is fairly long");
        }
        string memory svg = _svg(r.tokenURI(1, _token(), e));
        // Two of these fit before the row would cross x=688. The rest are dropped
        // from the DRAWING only — they are still in `json` and in the attributes.
        assertEq(_count(svg, "y='226'"), 2, "the row stops at the frame");
        assertEq(_count(r.json(1, _token(), e), '{"k":"'), 8, "every extra is still reported");
    }

    /// @dev The overloads without extras must stay byte-identical to passing none, so
    ///      a caller that has no extension fields is not rendering a different card.
    function testEmptyExtrasMatchTheShortOverload() public view {
        assertEq(r.tokenURI(1, _token()), r.tokenURI(1, _token(), new TokenListRenderer.Extra[](0)));
        assertEq(r.json(1, _token()), r.json(1, _token(), new TokenListRenderer.Extra[](0)));
    }

    /// @dev Every card is named for anything reading the document rather than looking
    ///      at it: a screen reader, a browser tooltip, an indexer.
    function testCardCarriesAnAccessibleTitle() public view {
        string memory svg = _svg(r.tokenURI(1, _token()));
        assertTrue(LibString.contains(svg, "<title>MOCK token listing</title>"));
        assertTrue(LibString.contains(svg, "role='img'"));
    }

    /// @dev The address/description cluster is centred in the band between the chip
    ///      row and the footer rule, which means the renderer positions it from a
    ///      line count computed BEFORE the lines are drawn. If `_descLines` and
    ///      `_textBlock` ever disagree the card silently mis-centres, so assert the
    ///      count they actually produce and that the block stays inside its band at
    ///      every length.
    function testDescriptionBlockIsCentredAndStaysInItsBand() public view {
        string[4] memory descs = [
            "",
            "One short line.",
            "A description long enough to need a second line once it is wrapped at the band width of the card.",
            "Every text field at its schema maximum at once: a forty glyph name, a twelve glyph symbol, a two "
            "hundred and fifty six character description that runs past the three lines this band has room for."
        ];
        uint256[4] memory expected = [uint256(0), 1, 2, 3];

        uint256 previousTop;
        for (uint256 i; i < descs.length; ++i) {
            TokenList.Token memory t = _token();
            t.description = descs[i];
            string memory svg = _svg(r.tokenURI(1, t));
            uint256[] memory lines = _descBaselines(svg);
            assertEq(lines.length, expected[i], "line count the layout was positioned from");

            if (lines.length != 0) {
                assertGt(lines[0], 244, "first line clears the chip row");
                assertLt(lines[lines.length - 1], 356, "last line stays above the footer rule");
            }
            // More lines must push the block UP, never down past its band.
            uint256 top = _addressLabelY(svg);
            if (i != 0) assertLt(top, previousTop + 1, "a longer description raises the block");
            previousTop = top;
            assertGt(top, 244, "ADDRESS clears the chip row");
        }
    }

    /// @dev y of the ADDRESS label. Found by walking the `<text x='32' y='` runs
    ///      forward and taking the one whose element is the label, rather than
    ///      scanning backwards from the word — the same approach `_descBaselines`
    ///      uses, and for the same reason.
    function _addressLabelY(string memory svg) internal pure returns (uint256) {
        string memory needle = "<text x='32' y='";
        uint256 at;
        while (true) {
            at = LibString.indexOf(svg, needle, at);
            require(at != LibString.NOT_FOUND, "no address label");
            uint256 tagEnd = LibString.indexOf(svg, "</text>", at);
            if (LibString.contains(LibString.slice(svg, at, tagEnd), ">ADDRESS")) {
                return _uintAt(svg, at + bytes(needle).length);
            }
            ++at;
        }
    }
}
