// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Base58} from "../../lib/solady/src/utils/Base58.sol";
import {Base64} from "../../lib/solady/src/utils/Base64.sol";
import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {TokenList} from "./TokenList.sol";

/// @title TokenListRenderer
/// @notice The card and the compact JSON for a `TokenList` listing.
/// @dev Split out of `TokenList` because the pair could not both fit under EIP-170
///      once the audit fixes landed. Rendering is pure string assembly holding no
///      state, while the registry holds the identities wallets cache forever, so this
///      is the half that had to move. The point was never that it fits: an immutable
///      registry must retain room to ship a security fix, and combined it had almost
///      none. Current sizes and the deterministic deployment targets live in
///      `deploy/TokenList.md` — deliberately not repeated here, because a byte count
///      in a comment goes stale, and editing this file to correct one would change
///      the metadata hash and invalidate the mined salts for this contract AND for
///      the registry, whose creation code carries this address as a constructor
///      argument.
///
///      Every function here is `pure` and takes the listing BY VALUE. The renderer
///      cannot read or write registry state, has no owner, and no call into it can
///      affect what the registry stores — it turns a listing into a string, nothing
///      else. `TokenList.renderer` is governance-settable so the card can improve
///      after deploy, and `TokenList.lockRenderer` makes that choice permanent; a
///      renderer may print anything, so a swap changes what every listing APPEARS to
///      say even though it cannot change what any listing stores.
///
/// @dev SANITISATION IS THIS CONTRACT'S JOB, NOT ONLY ITS CALLER'S. Every function
///      is `public pure` over a caller-supplied struct, so anyone may hand it any
///      bytes at all, and the registry it ships with is not the only contract that
///      may ever point at it. `TokenList._clean` does strip the six characters that
///      break out of a JSON string or an SVG attribute before anything is stored —
///      but relying on that alone made the safety of every card a property of the
///      CALLER, stated in no signature and enforced by nothing. A struct with a
///      `name` of `</text><script>…` produced exactly that markup, and a `symbol`
///      containing a quote produced JSON no parser would accept. Neither was
///      reachable through `TokenList`; both were reachable through this contract.
///      So every free-text field now passes through `_safe` on the way out. Against
///      the registry the filter is a no-op — it removes what `_clean` already
///      removed — and it costs one pass over a few hundred bytes in an `eth_call`.
contract TokenListRenderer {
    using LibString for string;

    /// @notice One open-ended metadata field, as `TokenList` stores it.
    /// @dev The registry's extension mechanism is a `bytes32 => string` mapping, and
    ///      a renderer handed only the fixed struct could never see it — which made
    ///      the escape hatch that exists so a new field costs a transaction instead
    ///      of a redeploy invisible on the very surface it was meant to reach. The
    ///      caller flattens the mapping and passes it; see `TokenList._extrasOf`.
    struct Extra {
        bytes32 key;
        string value;
    }

    /// @dev Card text metrics: how many monospace glyphs fit across the frame at
    ///      12px, and how many description lines the middle band has room for.
    ///      These belong to the layout, so they live with the layout — a future
    ///      renderer with a different frame carries its own.
    uint256 internal constant LINE_CHARS = 84;
    uint256 internal constant DESC_LINES = 3;

    /// @dev The footer holds one link, or two when a listing has an audit. Named
    ///      rather than written twice at the call site: they are layout metrics like
    ///      the two above, and the file's convention is that those live together.
    uint256 internal constant URL_CHARS = 46;
    uint256 internal constant AUDIT_CHARS = 32;

    /// @dev `name` is the only text on the card long enough to leave the frame. At
    ///      16px Helvetica from x=176 a 40-glyph `NAME_MAX` name runs past 720px in
    ///      the uppercase worst case, so it is fitted like the footer links rather
    ///      than trusted to be short.
    uint256 internal constant NAME_CHARS = 34;

    /// @dev How many extension fields the chip row has room for. The rest are still
    ///      in `json` and in the card's attributes; this bounds only what is drawn.
    uint256 internal constant CHIPS_MAX = 4;

    /// @notice One listing as compact JSON.
    /// @dev Keys are short by design: this is read by contracts and by dapps that
    ///      concatenate many entries, so every byte is paid for twice. `c` chain,
    ///      `k` namespace, `p` asset standard, `a` address, `n` name, `s` symbol,
    ///      `d` decimals, `o` onchain-SVG token-art hint, `t` theme, `r` rank, `u`
    ///      url, `au` audit, `l` logo, `i` id, `x` deployment state, `f` frozen,
    ///      `desc` description, `e` extension fields, and `v` — true when
    ///      name/symbol/decimals were READ FROM the token contract, which is a
    ///      statement about provenance, not about the token being trustworthy.
    function json(uint256 id, TokenList.Token memory t, Extra[] memory extras) public pure returns (string memory) {
        return string.concat(
            '{"i":"',
            LibString.toString(id),
            '","c":',
            LibString.toString(t.chainId),
            ',"k":"',
            _namespace(t.kind),
            '","p":"',
            _standard(t.standard),
            '","x":',
            t.deployed ? "true" : "false",
            ',"o":',
            t.onchainSvg ? "true" : "false",
            // A bare boolean is already closed, so the separator after `x` and after
            // `o` is `,"…"` and NOT `","…"`. The extra quote produced
            // `"x":true","o":…`, which is not JSON at all. Every listing rendered by
            // this renderer was unparseable, and the governor dapp's `JSON.parse`
            // fell into its catch and drew the entire TokenList as "TOKEN / Unknown"
            // with no logos. The tests only ever substring-matched the output, so
            // nothing caught it until `testJsonIsParseable` parsed it for real —
            // which then caught the identical fault one field earlier, on `x`.
            ',"f":',
            t.frozen ? "true" : "false",
            // An UNDEPLOYED listing has no account, and `_account` renders that as
            // the zero word — which for an EVM listing is `0x00…00`, the id the
            // registry deliberately gives the NATIVE asset. A consumer keying rows
            // by this field merged every reservation into ETH. The card already said
            // PENDING here; the machine-readable side now agrees, and the empty
            // string cannot collide with any real account in any namespace.
            ',"a":"',
            t.deployed ? _account(t) : "",
            '","n":"',
            _safe(t.name),
            '","s":"',
            // Deliberately NOT the card's `--` placeholder. The card is read by a
            // person, who needs to see something in the symbol slot; this field is
            // read by a program, which needs to be able to tell an absent symbol
            // from a token whose symbol is literally two hyphens.
            _safe(t.symbol),
            '","d":',
            LibString.toString(t.decimals),
            ',"t":"',
            _hexColor(t.color),
            '","r":',
            LibString.toString(t.rank),
            ',"u":"',
            _safe(t.url),
            '","au":"',
            _safe(t.audit),
            '","l":"',
            _uri(t.logo), // `TokenList._uri` forbids quotes, backslashes and control characters
            // Carried here because this is the read a dapp is TOLD to batch through
            // `Multicallable` to build a list. Leaving it out meant the description
            // was only reachable by additionally calling `tokenURI`, base64-decoding
            // it and re-parsing — for a field already sitting in the struct.
            '","desc":"',
            _safe(t.description),
            '","e":',
            _extrasJson(extras),
            ',"v":',
            t.synced ? "true" : "false",
            "}"
        );
    }

    /// @notice The compact JSON for a listing carrying no extension fields.
    function json(uint256 id, TokenList.Token memory t) public pure returns (string memory) {
        return json(id, t, new Extra[](0));
    }

    /// @notice Live, self-contained listing card.
    /// @dev Same 720x420 terminal frame as the position receipts, so a wallet
    ///      showing zFi assets renders one visual family. The theme color is the
    ///      only owner-controlled pigment; the frame stays legible whatever it is.
    ///
    ///      The card says WEIGHT, not RANK, because that is what the number is: a
    ///      sort weight, not a position. "RANK 999000" invites the reader to think
    ///      they are looking at the 999,000th entry. A renderer is handed one listing
    ///      by value and never sees the others, so it cannot know an ordinal even in
    ///      principle — position is `rankedIds()` index, and only a caller holding the
    ///      whole list can compute it.
    /// @dev The id is unused by THIS layout but stays in the signature: it is the
    ///      only handle on the listing a renderer cannot recover from the struct, and
    ///      removing it would make every future renderer a different interface.
    function tokenURI(uint256, TokenList.Token memory t, Extra[] memory extras) public pure returns (string memory) {
        // Two layouts, differing only in what the middle of the card is for. A
        // deployed listing spends it on the account; a reservation has no account, so
        // it spends it on the description and on saying plainly that there is nothing
        // to transact with yet.
        //
        // The banner used to be drawn at y=278 OVER a description band fixed at
        // 300/320/340, so an opaque 54px-tall rect erased the first two lines of every
        // reserved card and left the middle of the sentence showing through the dim
        // wash beneath it. A reservation is precisely the listing whose description
        // carries the most weight — no account, no logo source, no onchain facts —
        // and it was the one listing whose description could not be read.
        string memory theme = _legible(t.color);
        string memory chain = string.concat(_namespace(t.kind), ":", LibString.toString(t.chainId));
        string memory sym = _symbol(t.symbol);
        string memory desc = _safe(t.description);
        // Assembled in bands rather than as one forty-argument concatenation. The
        // shape is the same; keeping each band's operands live only for the length of
        // its own helper is what holds the deployed size down, and this contract is
        // deployed alongside a registry that must fit the same transaction.
        string memory svg = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 720 420' role='img'>"
            // Named for anything reading the document rather than looking at it: a
            // screen reader, a browser tooltip, an indexer sniffing the SVG directly.
            "<title>",
            sym,
            " token listing</title>" "<rect width='720' height='420' fill='#000'/>"
            "<g fill='none' stroke='#fff' stroke-width='2'>" "<rect x='18' y='18' width='684' height='384'/>"
            "<path d='M18 88h684M18 356h684'/></g>",
            _well(theme),
            _logo(t.logo),
            _header(t.rank, chain),
            _identity(t, sym, theme),
            _chips(t.synced, t.frozen, extras),
            _account(t, desc),
            _footer(_safe(t.url), _safe(t.audit)),
            "</g>",
            _reservedBanner(t.deployed),
            "</svg>"
        );
        return _dataURI(
            "application/json",
            string.concat(
                '{"name":"',
                sym,
                " / Token Listing\",\"description\":\"",
                desc,
                '","external_url":"',
                _safe(t.url),
                '","image":"',
                _dataURI("image/svg+xml", svg),
                '","attributes":[{"trait_type":"Symbol","value":"',
                sym,
                '"},{"trait_type":"Decimals","value":',
                LibString.toString(t.decimals),
                '},{"trait_type":"Token Standard","value":"',
                _standard(t.standard),
                '"},{"trait_type":"Per-token Artwork","value":"',
                _artHint(t.standard, t.onchainSvg),
                '"},{"trait_type":"Chain","value":"',
                chain,
                '"},{"trait_type":"Source","value":"',
                t.synced ? "Onchain" : "Attested",
                '"},{"trait_type":"Deployment","value":"',
                t.deployed ? "Deployed" : "Reserved / undeployed",
                // `freeze` is the strongest commitment the registry can make about a
                // listing, and neither the card nor the metadata mentioned it — so a
                // wallet could not tell a sealed listing from an editable one, which
                // is the whole signal freezing exists to broadcast.
                '"},{"trait_type":"Curation","value":"',
                t.frozen ? "Sealed" : "Editable",
                '"},{"trait_type":"Sort Weight","value":',
                LibString.toString(t.rank),
                bytes(t.audit).length == 0
                    ? "}"
                    : string.concat('},{"trait_type":"Audit","value":"', _safe(t.audit), '"}'),
                _extraTraits(extras),
                "]}"
            )
        );
    }

    /// @notice The card for a listing carrying no extension fields.
    function tokenURI(uint256 id, TokenList.Token memory t) public pure returns (string memory) {
        return tokenURI(id, t, new Extra[](0));
    }

    // LAYOUT ---------------------------------------------------------------

    /// @dev The tinted well the logo sits in, drawn whether or not there is a logo:
    ///      an empty well reads as a listing without art, a missing one as a broken
    ///      layout.
    ///
    ///      Deliberately faint. At the original 0.12 fill and 0.5 stroke the well
    ///      read as a coloured BOX behind the logo rather than as a recess it sits
    ///      in — and because the tint is the owner's theme, how loud that box got
    ///      varied per listing: barely visible behind ETH's blue, a solid orange
    ///      square behind WBTC and a red one behind rETH, whose logos are circular
    ///      and left the corners showing. Rounding the corners and dropping both
    ///      opacities lets the artwork sit on the card instead of on a swatch.
    function _well(string memory theme) internal pure returns (string memory) {
        return string.concat(
            "<rect x='32' y='110' width='112' height='112' rx='8' fill='",
            theme,
            "' opacity='0.07'/><rect x='32' y='110' width='112' height='112' rx='8' fill='none' stroke='",
            theme,
            "' stroke-width='1' opacity='0.22'/>"
        );
    }

    /// @dev Title, sort weight and namespace. Opens the `<g>` every text band below
    ///      inherits its fill and face from.
    function _header(uint32 rank, string memory chain) internal pure returns (string memory) {
        return string.concat(
            "<g fill='#fff' font-family='Helvetica,Arial,sans-serif'>"
            "<text x='32' y='55' font-size='25' font-weight='700'>TOKEN LISTING</text>"
            // Neutral for the same reason as the provenance pill: a sort weight is
            // metadata, not identity, and in the theme colour it turned into a red
            // number in the corner of the rETH card.
            "<text x='688' y='55' text-anchor='end' font-size='12' opacity='0.75'>WEIGHT ",
            LibString.toString(rank),
            "</text><text x='688' y='77' text-anchor='end' font-size='12' opacity='0.6'>",
            chain,
            "</text>"
        );
    }

    /// @dev Symbol, name and what the asset is.
    function _identity(TokenList.Token memory t, string memory sym, string memory theme)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            // Sized to what it holds rather than fixed at 40px. A 12-glyph
            // `SYMBOL_MAX` symbol at 40px runs to x=629 and crowds everything to its
            // right; shrinking the long ones keeps the identity band balanced and
            // leaves the lane the name needs.
            "<text x='176' y='158' font-size='",
            LibString.toString(_symbolSize(sym)),
            "' font-weight='700' fill='",
            theme,
            "'>",
            sym,
            "</text><text x='176' y='188' font-size='16'>",
            _fit(_safe(t.name), NAME_CHARS),
            "</text><text x='176' y='212' font-size='13' opacity='0.7'>",
            _assetDetail(t.standard, t.onchainSvg, t.decimals),
            "</text>"
        );
    }

    /// @dev The account and the description. One band, because which of the two the
    ///      middle of the card is for is a single decision: a deployed listing spends
    ///      it on the account, a reservation has no account and spends it on the
    ///      description instead, moving that band up into the space the banner is
    ///      about to occupy.
    ///
    ///      The banner used to be drawn at y=278 OVER a description fixed at
    ///      300/320/340, so an opaque 54px-tall rect erased the first two lines of
    ///      every reserved card and left the middle of the sentence showing through
    ///      the dim wash beneath it. A reservation is precisely the listing whose
    ///      description carries the most weight — no account, no logo source, no
    ///      onchain facts — and it was the one listing whose description could not be
    ///      read.
    function _account(TokenList.Token memory t, string memory desc) internal pure returns (string memory) {
        // Every card now carries a chip row at y=226..244, so both layouts below have
        // to clear it. The reserved variant put its first description line at y=250,
        // whose cap-height ran straight back up into the chip rect the moment
        // provenance moved into that row.
        if (!t.deployed) return _textBlock(desc, 262);
        // CENTRED, NOT TOP-ANCHORED. The band from the chip row to the footer rule is
        // sized for a full-length three-line description; pinning the block to the top
        // of it meant every listing with a one-line description — which is most of
        // them — left a fifty-five pixel slab of empty black above the rule and read
        // as top-heavy. Centring spends the slack on both sides instead, so a short
        // card looks composed rather than unfinished, and a full one is unchanged.
        uint256 lines = _descLines(desc);
        uint256 height = lines == 0 ? 20 : 42 + (lines - 1) * 20;
        uint256 top = 252 + (100 - height) / 2;
        return string.concat(
            "<text x='32' y='",
            LibString.toString(top),
            "' font-size='11' opacity='0.6'>ADDRESS</text><text x='32' y='",
            LibString.toString(top + 20),
            "' font-size='15'>",
            // A NATIVE asset has no contract. Printing `_account` here rendered forty
            // zeros under the word ADDRESS on the highest-ranked card in the list —
            // copyable, and a plausible destination for someone who does not know
            // that address(0) is this registry's id convention rather than somewhere
            // ETH lives. `json` still reports the real word for machines.
            t.standard == TokenList.Standard.NATIVE ? "NONE - NATIVE ASSET" : _account(t),
            "</text>",
            lines == 0 ? "" : _textBlock(desc, top + 42)
        );
    }

    /// @dev One row of metadata chips under the identity band: provenance first,
    ///      then curation state, then extension fields.
    ///
    ///      Provenance used to be a pill at y=64, wedged between the 25px title and
    ///      the header rule at y=88 with four pixels of clearance, and floating a
    ///      whole band away from the fields it describes. It qualifies the symbol,
    ///      the name and the decimals — so it belongs directly beneath them, and the
    ///      card already had a chip row sitting there. Two chip systems doing the
    ///      same visual job in different places is one too many.
    ///
    ///      It is filled rather than outlined so it still leads the row: of the
    ///      things on this card it is the one a reader most needs to weigh. SEALED
    ///      is drawn only when true — an EDITABLE chip on every ordinary listing is
    ///      noise, and its absence is already the ordinary case.
    function _chips(bool synced, bool frozen, Extra[] memory extras) internal pure returns (string memory out) {
        uint256 x = 32;
        string memory provenance = synced ? "METADATA READ ONCHAIN" : "OWNER ATTESTED";
        out = _chip(x, provenance, true);
        x += 14 + bytes(provenance).length * 7 + 8;
        if (frozen) {
            out = string.concat(out, _chip(x, "SEALED", false));
            x += 14 + 6 * 7 + 8;
        }
        uint256 shown;
        for (uint256 i; i < extras.length && shown < CHIPS_MAX; ++i) {
            string memory label = _label(extras[i].key);
            string memory value = _fit(_safe(extras[i].value), 24);
            if (bytes(value).length == 0) continue;
            string memory text = string.concat(label, " ", value);
            uint256 w = 14 + bytes(text).length * 7;
            // Stop at the frame rather than drawing off the edge of the card. What
            // does not fit is still in `json` and in the card's attributes.
            if (x + w > 688) break;
            out = string.concat(out, _chip(x, text, false));
            x += w + 8;
            ++shown;
        }
    }

    function _chip(uint256 x, string memory text, bool filled) internal pure returns (string memory) {
        return string.concat(
            "<g><rect x='",
            LibString.toString(x),
            "' y='226' width='",
            LibString.toString(14 + bytes(text).length * 7),
            "' height='18' rx='3' fill='#fff' fill-opacity='",
            filled ? "0.09" : "0",
            "' stroke='#fff' stroke-opacity='",
            filled ? "0.4" : "0.28",
            "'/><text x='",
            LibString.toString(x + 7),
            "' y='239' font-family='Helvetica,Arial,sans-serif' font-size='11' opacity='",
            filled ? "0.9" : "0.72",
            "'>",
            text,
            "</text></g>"
        );
    }

    /// @dev The reservation banner, drawn last so it sits over everything. Its band
    ///      is placed BELOW the description rather than across it; see `tokenURI`.
    function _reservedBanner(bool deployed) internal pure returns (string memory) {
        if (deployed) return "";
        return "<rect x='18' y='18' width='684' height='384' fill='#000' opacity='0.64'/>"
            "<rect x='32' y='300' width='656' height='52' fill='#d7d7d7'/>"
            "<g fill='#000' font-family='Helvetica,Arial,sans-serif'>"
            "<text x='48' y='322' font-size='15' font-weight='700'>RESERVED TOKEN / NOT DEPLOYED</text>"
            "<text x='48' y='341' font-size='12'>ADDRESS PENDING - NOT AVAILABLE FOR TRANSFERS, QUOTES, OR SWAPS</text>"
            "</g>";
    }

    /// @dev The footer links. Underlined so they read as links rather than as more
    ///      grey text; deliberately NOT wrapped in `<a href>`, because the card is
    ///      consumed as an `<img>` where the anchor is inert anyway, and a sanitiser
    ///      that strips the element would take the visible URL with it.
    function _footer(string memory url, string memory audit) internal pure returns (string memory out) {
        bool hasAudit = bytes(audit).length != 0;
        if (bytes(url).length != 0) {
            out = string.concat(
                "<text x='32' y='382' font-size='12' opacity='0.7' text-decoration='underline'>",
                _fit(url, hasAudit ? URL_CHARS : LINE_CHARS),
                "</text>"
            );
        }
        if (hasAudit) {
            out = string.concat(
                out,
                "<text x='688' y='382' text-anchor='end' font-size='12' opacity='0.7'"
                " text-decoration='underline'>AUDIT ",
                _fit(audit, AUDIT_CHARS),
                "</text>"
            );
        }
    }

    /// @dev SVG `<text>` does not wrap, and the card is only so wide: at 12px in a
    ///      monospace face roughly LINE_CHARS glyphs fit between the rules. A
    ///      description may be up to DESC_MAX, so laying it out as one run would send
    ///      it straight off the edge of every card that used the full length. Break it
    ///      into separate lines instead, on spaces where possible so words stay whole.
    /// @dev How many lines `_textBlock` will draw. Both walk the text with the same
    ///      `_breakAt`, so the count cannot drift from the layout — which matters,
    ///      because the caller positions the whole block from this number.
    function _descLines(string memory text) internal pure returns (uint256 lines) {
        uint256 len = bytes(text).length;
        uint256 start;
        while (lines < DESC_LINES && start < len) {
            (, start) = _breakAt(text, start, len);
            ++lines;
        }
    }

    /// @dev One line's end offset, and where the next line starts. Broken at the last
    ///      space in the window so a word is not split; the space itself is consumed.
    function _breakAt(string memory text, uint256 start, uint256 len)
        internal
        pure
        returns (uint256 end, uint256 next)
    {
        bytes memory raw = bytes(text);
        end = start + LINE_CHARS;
        if (end >= len) return (len, len);
        uint256 brk = end;
        while (brk > start && raw[brk] != " ") --brk;
        if (brk > start) end = brk;
        next = raw[end] == " " ? end + 1 : end;
    }

    function _textBlock(string memory text, uint256 y) internal pure returns (string memory out) {
        uint256 len = bytes(text).length;
        uint256 start;
        for (uint256 line; line < DESC_LINES && start < len; ++line) {
            (uint256 end, uint256 next) = _breakAt(text, start, len);
            string memory lineText = LibString.slice(text, start, end);
            // DESC_MAX is 256 and this band holds DESC_LINES * LINE_CHARS = 252, so a
            // full-length description loses its tail. Say so with an ellipsis rather
            // than stopping mid-word and letting the card read as the whole text.
            if (line + 1 == DESC_LINES && next < len) {
                lineText = string.concat(
                    bytes(lineText).length > LINE_CHARS - 3 ? LibString.slice(lineText, 0, LINE_CHARS - 3) : lineText,
                    "..."
                );
            }
            out = string.concat(
                out,
                // Monospace, because LINE_CHARS is a GLYPH count and only a fixed-width
                // face turns that into a width. The card's Helvetica is proportional:
                // 84 characters of lowercase fit inside the 656px band with room to
                // spare, but 84 of uppercase run to roughly 730px and leave the 720px
                // card entirely. The wrapper cannot measure a proportional face, so
                // give this band the face the metric already assumes.
                "<text x='32' y='",
                LibString.toString(y + line * 20),
                "' font-family='ui-monospace,SFMono-Regular,Menlo,monospace' font-size='12' opacity='0.85'>",
                lineText,
                "</text>"
            );
            start = next;
        }
    }

    /// @dev Truncate to what actually fits on one line, with an ellipsis when cut.
    function _fit(string memory text, uint256 max) internal pure returns (string memory) {
        if (bytes(text).length <= max) return text;
        // The ellipsis needs three of the budget. Below that there is no room to say
        // "cut", and `max - 3` would underflow into a slice of the whole string.
        if (max <= 3) return LibString.slice(text, 0, max);
        return string.concat(LibString.slice(text, 0, max - 3), "...");
    }

    /// @dev A person reading a card needs SOMETHING in the symbol slot, but `???`
    ///      reads as a rendering failure rather than as an absent symbol.
    function _symbol(string memory symbol) internal pure returns (string memory) {
        string memory s = _safe(symbol);
        return bytes(s).length == 0 ? "--" : s;
    }

    function _symbolSize(string memory symbol) internal pure returns (uint256) {
        uint256 n = bytes(symbol).length;
        return n <= 6 ? 40 : n <= 9 ? 32 : 26;
    }

    function _namespace(TokenList.Kind kind) internal pure returns (string memory) {
        return kind == TokenList.Kind.EVM ? "eip155" : kind == TokenList.Kind.SVM ? "solana" : "raw";
    }

    function _standard(TokenList.Standard standard) internal pure returns (string memory) {
        if (standard == TokenList.Standard.NATIVE) return "Native";
        if (standard == TokenList.Standard.ERC20) return "ERC-20";
        if (standard == TokenList.Standard.ERC721) return "ERC-721";
        if (standard == TokenList.Standard.ERC1155) return "ERC-1155";
        return "Unknown";
    }

    function _assetDetail(TokenList.Standard standard, bool onchainSvg, uint8 decimals)
        internal
        pure
        returns (string memory)
    {
        if (standard == TokenList.Standard.ERC721) {
            return onchainSvg ? "ERC-721 / ONCHAIN TOKEN SVG" : "ERC-721 COLLECTION";
        }
        if (standard == TokenList.Standard.ERC1155) {
            return onchainSvg ? "ERC-1155 / ONCHAIN TOKEN SVG" : "ERC-1155 COLLECTION";
        }
        if (standard == TokenList.Standard.NATIVE) {
            return string.concat("NATIVE ASSET / ", LibString.toString(decimals), " DECIMALS");
        }
        if (standard == TokenList.Standard.ERC20) {
            return string.concat("ERC-20 / ", LibString.toString(decimals), " DECIMALS");
        }
        return "TOKEN STANDARD UNVERIFIED";
    }

    function _artHint(TokenList.Standard standard, bool onchainSvg) internal pure returns (string memory) {
        if (onchainSvg && (standard == TokenList.Standard.ERC721 || standard == TokenList.Standard.ERC1155)) {
            return "Onchain SVG";
        }
        return "Not declared";
    }

    /// @dev EVM addresses render as `0x…`, Solana mints as base58; anything else as
    ///      the raw 32-byte word, which any consumer can re-encode for its namespace.
    function _account(TokenList.Token memory t) internal pure returns (string memory) {
        if (t.kind == TokenList.Kind.SVM) return Base58.encodeWord(t.account);
        if (t.kind == TokenList.Kind.EVM) return LibString.toHexString(uint256(t.account), 20);
        return LibString.toHexString(uint256(t.account), 32);
    }

    // EXTENSION FIELDS -----------------------------------------------------

    function _extrasJson(Extra[] memory extras) internal pure returns (string memory out) {
        out = "[";
        for (uint256 i; i < extras.length; ++i) {
            out = string.concat(
                out, i == 0 ? "" : ",", '{"k":"', _label(extras[i].key), '","v":"', _safe(extras[i].value), '"}'
            );
        }
        return string.concat(out, "]");
    }

    function _extraTraits(Extra[] memory extras) internal pure returns (string memory out) {
        for (uint256 i; i < extras.length; ++i) {
            string memory value = _safe(extras[i].value);
            if (bytes(value).length == 0) continue;
            out = string.concat(out, ',{"trait_type":"', _label(extras[i].key), '","value":"', value, '"}');
        }
    }

    /// @dev Extension keys are chosen by the curator, and the useful ones are short
    ///      ASCII labels (`bytes32("coingecko")`) rather than hashes. Print those as
    ///      the word they are, and anything else as the raw word — a key that is a
    ///      hash has no display form better than its hex.
    function _label(bytes32 key) internal pure returns (string memory) {
        bytes memory out = new bytes(32);
        uint256 n;
        for (uint256 i; i < 32; ++i) {
            bytes1 c = key[i];
            if (c == 0) break;
            if (c < 0x20 || c > 0x7E) return LibString.toHexString(uint256(key), 32);
            out[n++] = c;
        }
        if (n == 0) return LibString.toHexString(uint256(key), 32);
        assembly ("memory-safe") {
            mstore(out, n)
        }
        return _safe(string(out));
    }

    // SAFETY ---------------------------------------------------------------

    /// @dev Drop, rather than escape, the characters that would end a JSON string or
    ///      an SVG attribute. Escaping would have to differ between the two documents
    ///      this text lands in — `&amp;` is right for the XML and wrong for the JSON —
    ///      and one filter that is correct for both is worth more here than fidelity
    ///      to a character no display string needs. This mirrors `TokenList._clean`
    ///      exactly, so against the registry it removes nothing.
    function _safe(string memory input) internal pure returns (string memory) {
        return _filter(input, false);
    }

    /// @dev The strict form, for anything interpolated into an SVG ATTRIBUTE. Drops
    ///      the apostrophe as well, because this renderer delimits attributes with
    ///      single quotes. Only the logo reaches an attribute; every other field on
    ///      the card is text-node content, where an apostrophe is legal and wanted.
    ///      A future layout that puts a name or a link into an attribute must use
    ///      THIS and not `_safe`.
    function _safeAttr(string memory input) internal pure returns (string memory) {
        return _filter(input, true);
    }

    function _filter(string memory input, bool alsoApostrophe) internal pure returns (string memory) {
        bytes memory raw = bytes(input);
        bytes memory out = new bytes(raw.length);
        uint256 kept;
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            if (c < 0x20 || c > 0x7E) continue;
            if (c == '"' || c == "\\" || c == "<" || c == ">" || c == "&") continue;
            if (alsoApostrophe && c == "'") continue;
            out[kept++] = c;
        }
        assembly ("memory-safe") {
            mstore(out, kept)
        }
        return string(out);
    }

    /// @dev A logo reaches the card as an `<image href>`. `ipfs://` is accepted by the
    ///      registry and resolved by nothing that renders an SVG, so a listing with an
    ///      IPFS logo drew an empty well on every card, every time. Rewriting it to a
    ///      gateway is a DISPLAY decision and belongs here rather than in storage: the
    ///      registry keeps the canonical URI, and a later renderer may pick a different
    ///      gateway without rewriting a single listing.
    function _logoSrc(string memory logo) internal pure returns (string memory) {
        if (LibString.startsWith(logo, "ipfs://")) {
            return string.concat("https://ipfs.io/ipfs/", LibString.slice(logo, 7));
        }
        return logo;
    }

    /// @dev `TokenList._uri` already rejects everything that could break out of the
    ///      attribute. Re-checked here for the same reason `_safe` exists: this
    ///      contract's output must be well-formed whoever calls it.
    function _uri(string memory logo) internal pure returns (string memory) {
        return _safeAttr(logo);
    }

    function _logo(string memory logo) internal pure returns (string memory) {
        if (bytes(logo).length == 0) return "";
        return string.concat(
            "<image x='40' y='118' width='96' height='96' preserveAspectRatio='xMidYMid meet' href='",
            _logoSrc(_uri(logo)),
            "'/>"
        );
    }

    // COLOR ----------------------------------------------------------------

    function _hexColor(uint24 color) internal pure returns (string memory) {
        return string.concat("#", LibString.slice(LibString.toHexString(uint256(color), 3), 2));
    }

    /// @dev The theme color is owner-chosen and the frame is pure black, so nothing
    ///      stopped a listing from picking one dark enough that its own symbol — the
    ///      40px word the card exists to show — rendered as almost nothing. Lift the
    ///      dark ones toward white until they carry against the background. The stored
    ///      value is untouched; `TokenList.themeOf` still answers what was set, and
    ///      this is only what the card paints with.
    function _legible(uint24 color) internal pure returns (string memory) {
        uint256 r = uint256(color) >> 16;
        uint256 g = (uint256(color) >> 8) & 0xff;
        uint256 b = uint256(color) & 0xff;
        // Rec. 601 luma, the same weighting every contrast heuristic of this shape
        // uses. 72 is roughly where a hue stops reading as a color on black and
        // starts reading as a smudge.
        if ((r * 299 + g * 587 + b * 114) / 1000 < 72) {
            r += ((255 - r) * 55) / 100;
            g += ((255 - g) * 55) / 100;
            b += ((255 - b) * 55) / 100;
        }
        return _hexColor(uint24((r << 16) | (g << 8) | b));
    }

    function _dataURI(string memory mime, string memory body) internal pure returns (string memory) {
        return string.concat("data:", mime, ";base64,", Base64.encode(bytes(body)));
    }
}
