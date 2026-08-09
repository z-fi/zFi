// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Base64} from "../../lib/solady/src/utils/Base64.sol";
import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {MetadataReaderLib} from "../../lib/solady/src/utils/MetadataReaderLib.sol";

/// @notice Small helpers for self-contained live-position metadata.
/// @dev The WNS answer is deliberately treated as untrusted display text. SVG
///      metadata is consumed by wallets and marketplaces, so only a compact
///      ASCII subset is admitted rather than interpolating arbitrary XML.
library PositionSVG {
    address internal constant WNS = 0x0000000000696760E15f265e828DB644A0c242EB;
    bytes4 internal constant REVERSE_RESOLVE = 0x9af8b7aa; // reverseResolve(address)

    function dataURI(string memory mime, string memory body) internal pure returns (string memory) {
        return string.concat("data:", mime, ";base64,", Base64.encode(bytes(body)));
    }

    /// @dev The shared card chrome. Every board renders into the same 720x420
    ///      frame so a wallet showing positions from all three reads as one
    ///      family, and so the geometry is fixed once rather than three times.
    ///      No width or height attribute: the card scales to whatever box it is
    ///      given, from a list thumbnail up to a full screen.
    string internal constant OPEN =
        "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' viewBox='0 0 720 420'><rect width='720' height='420' fill='#000'/>";

    /// @dev The frame and its two rules. Callers open their own stroked group so
    ///      board-specific geometry (a curve, a fill bar) joins the same group.
    string internal constant FRAME =
        "<g fill='none' stroke='#fff' stroke-width='2'><rect x='18' y='18' width='684' height='384'/><path d='M18 88h684M18 326h684";

    string internal constant TEXT = "</g><g fill='#fff' font-family='Helvetica,Arial,sans-serif'>";

    /// @dev Every label on a card is drawn in this grey and every value in white.
    ///      The cards used to separate the two with a double space, which SVG's
    ///      default whitespace handling COLLAPSES - so "MAKER  0x12..." shipped
    ///      as "MAKER 0x12..." and a row of same-size, same-colour text ran
    ///      together with nothing marking where the question ended and the
    ///      answer began. Colour does that job in a way whitespace cannot.
    string internal constant MUTED = "#8b939e";

    /// @dev Column headings. Smaller, tracked out and muted, so the 22px figure
    ///      under a heading is unmistakably the subject and the heading is
    ///      unmistakably a label - at 12px against a 13px value line they
    ///      competed.
    string internal constant LABEL =
        "<text font-size='11' letter-spacing='.09em' fill='#8b939e' ";

    /// @dev Axis captions sitting either side of the schedule curve. The left one
    ///      opens at the margin, the right one is anchored to it, so a wide
    ///      number grows inward instead of off the card.
    string internal constant AXIS_L = "<text font-size='12' x='32' ";
    string internal constant AXIS_R = "<text font-size='12' text-anchor='end' x='688' ";

    /// @dev An inline label preceding a value on the same line. See `MUTED`.
    function key(string memory label) internal pure returns (string memory) {
        return string.concat("<tspan fill='", MUTED, "'>", label, "</tspan> ");
    }

    string internal constant CLOSE = "</g></svg>";

    /// @dev The full schedule, drawn faint, with the shape itself put in
    ///      `<defs>` so the trace can be drawn over it.
    ///
    ///      The shape used to be a rendered `<path opacity='.3'>` that the
    ///      trace referenced with `<use opacity='1'>`. A `<use>` clones the
    ///      referenced element WITH its own presentation attributes, and those
    ///      win over the ones on the `<use>` - so the accent trace inherited
    ///      the .3 and every card drew the elapsed part of its schedule at the
    ///      same weight as the part still to come. The state colour was there;
    ///      it was three-tenths visible. Defining the geometry unstyled and
    ///      giving each instance its own weight is what the two-`<use>` shape
    ///      was for in the first place.
    ///      The id carries the position number because a card is not always
    ///      rendered alone. As an `<img src=data:...>` - what a wallet does -
    ///      each SVG is its own document and any id is safe; inlined into a
    ///      marketplace's page, two cards sharing `id='c'` mean the second
    ///      one's `<use>` resolves to the FIRST one's geometry and draws
    ///      somebody else's schedule.
    function baseline(string memory path, uint256 curveEnd, string memory id)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "<defs><path id='",
            id,
            "' d='",
            path,
            LibString.toString(curveEnd),
            "' pathLength='100'/></defs>",
            use_(id, "opacity='.3'")
        );
    }

    /// @dev One instance of the shared geometry. Both `href` and the legacy
    ///      `xlink:href` are written because renderers in the wild honour
    ///      different ones.
    function use_(string memory id, string memory attrs) internal pure returns (string memory) {
        return string.concat("<use href='#", id, "' xlink:href='#", id, "' ", attrs, "/>");
    }

    /// @dev The point the traced schedule has reached, marked on the curve.
    ///      The curve's whole job is to say where the listing is in its
    ///      schedule, and until now it said it only as a length of coloured
    ///      line - readable next to the baseline it is drawn over, and at a
    ///      thumbnail's size not readable at all. A filled head reads as a
    ///      position at any scale, which is what a percentage in the row above
    ///      already gives a reader who is willing to stop and parse it.
    ///
    ///      Both boards' control point sits at the midpoint's x, so the head's
    ///      x is exactly `32 + 656t` on either curve and only the y differs.
    function head(uint256 y, uint256 progress, string memory accent)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "<circle r='4' stroke='none' fill='",
            accent,
            "' cx='",
            LibString.toString(32 + (656 * progress) / 10_000),
            "' cy='",
            LibString.toString(y),
            "'/>"
        );
    }

    /// @dev The status palette, defined once for the whole family. These strings
    ///      are read at a thumbnail's size, where the colour lands before the
    ///      word does, so the same state must be the same colour on all three
    ///      boards - EXPIRED was previously amber on two of them and red on the
    ///      third, while that same amber meant FLOOR on the third.
    string internal constant LIVE = "#43d69b"; // still actionable
    string internal constant FILLED = "#6fa8ff"; // completed in full
    string internal constant CLOSED = "#969da7"; // ended without settling
    string internal constant FROZEN = "#c69cff"; // claim suspended
    string internal constant EXPIRED = "#ff8f8f"; // deadline passed
    string internal constant RESTING = "#ffb55b"; // schedule exhausted, still takeable
    string internal constant FREE = "#5ee6d2"; // decayed to nothing
    /// @dev Deliberately a muted blue rather than `FILLED`'s saturated one. The
    ///      two were the same value, so "has not started" and "completely done"
    ///      - the two states furthest apart in meaning - were indistinguishable
    ///      until you read the word.
    string internal constant PENDING = "#8fa4c4"; // window has not opened

    /// @dev The identity line under a leg's amount. A symbol alone is
    ///      attacker-chosen and a bare address is unreadable, so the card
    ///      carries both: the ticker to recognise, the address to verify.
    ///      Written `SYM / 0x1234...cdef / 18 DEC` - the standard's name is
    ///      dropped because the decimal basis already implies fungibility and
    ///      the token's own traits state it exactly.
    function legLabel(address token, string memory symbol, uint8 snapshot, bool isNFT)
        internal
        pure
        returns (string memory line)
    {
        line = shortAddress(token);
        // A fungible leg needs its scale stated or the amount above it cannot be
        // read. An NFT leg does not: the figure above it already reads "TOKEN
        // #1" / "BUNDLE 3" / "NFT x2", so a trailing "/ NFT" only repeats it -
        // and repeated it twice over for a collection whose ticker is "NFT".
        if (!isNFT) line = string.concat(line, " / ", decimalsLabel(snapshot));
        else if (bytes(symbol).length == 0) line = string.concat(line, " / NFT");
        if (bytes(symbol).length != 0) line = string.concat(symbol, " / ", line);
    }

    /// @dev The quote leg of a priced board. Native ETH is its own identity and
    ///      needs no address or scale beside it; anything else is a token and is
    ///      written exactly like a lot leg.
    function quoteLine(address quote, string memory symbol, uint8 snapshot)
        internal
        pure
        returns (string memory)
    {
        if (quote == address(0)) return "ETH";
        return legLabel(quote, symbol, snapshot, false);
    }

    /// @dev Basis points as a percentage with the hundredths padded: 1005 is
    ///      10.05%, not 10.5%. Shared because an unpadded split is wrong twice
    ///      over - it misreports the number and, where the same value drives a
    ///      `stroke-dasharray`, it draws the wrong length of curve.
    function percent(uint256 bps) internal pure returns (string memory) {
        uint256 fraction = bps % 100;
        return string.concat(
            LibString.toString(bps / 100), ".", fraction < 10 ? "0" : "", LibString.toString(fraction)
        );
    }

    /// @dev Timestamps are shown as raw unix seconds on purpose: they are exact,
    ///      chain-native, locale-free, and need no calendar arithmetic onchain.
    function timestamp(uint256 unixTime) internal pure returns (string memory) {
        return unixTime == 0 ? "NEVER" : string.concat("UNIX ", LibString.toString(unixTime));
    }

    /// @dev The decimal basis on its own, for a quote leg. `assetType` asserts a
    ///      token standard as well, which is wrong for a quote: what a reader
    ///      needs there is only the scale the price is written in.
    function decimalsLabel(uint8 snapshot) internal pure returns (string memory) {
        return snapshot == 0 ? "RAW" : string.concat(LibString.toString(snapshot - 1), " DEC");
    }

    /// @dev The zero address is native ETH on every board that accepts it.
    function quoteLabel(address quote) internal pure returns (string memory) {
        return quote == address(0) ? "ETH" : shortAddress(quote);
    }

    function shortAddress(address account) internal pure returns (string memory) {
        bytes memory full = bytes(LibString.toHexString(account));
        bytes memory result = new bytes(13); // 0x1234...cdef
        result[0] = full[0];
        result[1] = full[1];
        for (uint256 i; i < 4; ++i) {
            result[2 + i] = full[2 + i];
            result[9 + i] = full[38 + i];
        }
        result[6] = ".";
        result[7] = ".";
        result[8] = ".";
        return string(result);
    }

    /// @notice A WNS name when configured, otherwise a stable short address.
    /// @dev Bound both gas and returned bytes so tokenURI remains reliable even
    ///      when queried on a chain where WNS is unavailable.
    function makerLabel(address maker) internal view returns (string memory) {
        (bool ok, bytes memory response) = WNS.staticcall{gas: 35_000}(
            abi.encodeWithSelector(REVERSE_RESOLVE, maker)
        );
        if (!ok || response.length < 96) return shortAddress(maker);
        // Follow the ABI head rather than assuming it sits at 0x20. A
        // conformant encoder is free to pad it, and reading the length from a
        // fixed word then misparses a perfectly valid answer as garbage.
        uint256 offset;
        assembly ("memory-safe") {
            offset := mload(add(response, 0x20))
        }
        if (offset > response.length - 64) return shortAddress(maker);
        uint256 length;
        assembly ("memory-safe") {
            length := mload(add(add(response, 0x20), offset))
        }
        if (length == 0 || length > 28 || response.length - 32 - offset < length) {
            return shortAddress(maker);
        }

        // `offset` counts from the start of the returndata to the LENGTH word,
        // so the characters begin one word after it.
        string memory name = _safeText(response, offset + 32, length);
        if (bytes(name).length == 0) return shortAddress(maker);
        return name;
    }

    /// @dev Best-effort ERC-20/721 `symbol()` snapshot. The same strict text
    ///      policy as reverse WNS keeps a nonstandard collection from adding
    ///      markup to a card, and no read is made while metadata is rendered.
    function readSymbol(address token) internal view returns (string memory) {
        bytes memory symbol = bytes(MetadataReaderLib.readSymbol(token, 12, 15_000));
        return _safeText(symbol, 0, symbol.length);
    }

    function _safeText(bytes memory source, uint256 start, uint256 length) private pure returns (string memory) {
        bytes memory text = new bytes(length);
        uint256 kept;
        for (uint256 i; i < length; ++i) {
            bytes1 c = source[start + i];
            // Names are labels, not markup. Keep the terminal card legible and
            // XML-safe even if a resolver returns an unexpected value.
            // `<` and `&` are the only printable ASCII characters that can
            // create XML markup/entities in element text.
            // A space is not markup, and excluding it turned "Wrapped Ether"
            // into "WrappedEther". The range starts at 0x20 rather than 0x21
            // for that one character; the guard is otherwise unchanged, and
            // deliberately no wider, because this runs inside the boards - both
            // of which are within a few hundred bytes of EIP-170.
            if (c >= 0x20 && c <= 0x7e && c != "<" && c != "&") {
                text[kept++] = c;
            }
        }
        assembly ("memory-safe") {
            mstore(text, kept)
        }
        return string(text);
    }

    /// @dev Read a conventional ERC-20 decimals value without ever making a
    ///      position renderer depend on an untrusted token at display time.
    ///      The caller snapshots the result at creation; 36 is deliberately
    ///      conservative for a compact, exact decimal display.
    function readDecimals(address token) internal view returns (bool known, uint8 decimals) {
        (bool ok, bytes memory response) = token.staticcall{gas: 15_000}(abi.encodeWithSelector(0x313ce567));
        if (!ok || response.length != 32) return (false, 0);
        uint256 value;
        assembly ("memory-safe") {
            value := mload(add(response, 0x20))
        }
        if (value > 36) return (false, 0);
        return (true, uint8(value));
    }

    /// @dev The widest number an amount slot can hold at its display size.
    ///      Anything longer is compacted rather than allowed to run off the
    ///      edge of the image, which is what keeps a card readable at any
    ///      scale for tokens of any denomination.
    uint256 internal constant MAX_WIDTH = 18;

    /// @dev `snapshot` is `decimals + 1`; zero is the explicit raw fallback.
    ///      Magnitude is never sacrificed: a number too wide for the slot is
    ///      shown in scientific notation rather than cut short.
    function amount(uint256 value, uint8 snapshot, bool isNFT) internal pure returns (string memory) {
        if (isNFT) return string.concat("TOKEN #", _shortId(value));
        // Zero is zero at every scale. Without this an emptied leg on a filled
        // order renders through the tiny-value path as "0e-18".
        if (value == 0) return "0";

        bytes memory raw = bytes(LibString.toString(value));
        uint256 decimals = snapshot == 0 ? 0 : snapshot - 1;
        uint256 n = raw.length;

        if (n > decimals) {
            uint256 whole = n - decimals;
            if (whole > MAX_WIDTH) return _scientific(raw, whole - 1, false);
            uint256 end = n;
            while (end > whole && raw[end - 1] == "0") --end;
            // The whole part is kept intact and whatever the slot has left over
            // is spent on the fraction, so a wide number loses precision rather
            // than magnitude. The second strip removes zeros the cut exposed.
            if (end + 1 > MAX_WIDTH) end = MAX_WIDTH - 1;
            while (end > whole && raw[end - 1] == "0") --end;
            if (end <= whole) return string(_copy(raw, 0, whole));

            bytes memory decimalOut = new bytes(end + 1);
            for (uint256 i; i < whole; ++i) decimalOut[i] = raw[i];
            decimalOut[whole] = ".";
            for (uint256 i = whole; i < end; ++i) decimalOut[i + 1] = raw[i];
            return string(decimalOut);
        }

        uint256 zeroes = decimals - n;
        // Write the value out whenever five significant places survive the
        // leading zeros, and state it in scientific notation when they do not -
        // below that, `d.ddddeK` carries strictly more of the number than a
        // string of zeros with two digits on the end.
        //
        // The test used to be `decimals + 2 > MAX_WIDTH`, which asks about the
        // TOKEN's scale and never about the value: on any token with seventeen
        // decimals or more it was true unconditionally, so half an ETH rendered
        // "5e-1" in the largest slot on the card.
        if (zeroes + 7 > MAX_WIDTH) return _scientific(raw, zeroes + 1, true);

        // The leading zeros of the fraction, written out. A fresh `bytes` is
        // zero-BYTES, not zero-DIGITS: skipping straight to the significant
        // digits left NUL bytes in the gap, which is not a character XML admits
        // at all - so the whole card stopped being a well-formed document - and
        // read as though the zeros were not there, printing 0.012345 as
        // "0.<NUL>12345". Ten times the real value, on any token with sixteen
        // decimals or fewer holding a value one or two places below its first
        // significant digit. 0.012345 USDC is exactly that.
        // Trailing zeros carry no information and the whole-number branch above
        // already drops them, so a card could otherwise show "1.5" beside
        // "0.010000" for the same reason. The LEADING count is fixed by the
        // original digit count and does not move; only the tail shrinks, and
        // never past the last significant digit.
        while (n > 1 && raw[n - 1] == "0") --n;
        // Whatever the slot has left after the leading zeros is spent on
        // significant digits - the same trade the whole-number branch makes,
        // losing precision rather than magnitude. The second strip removes
        // zeros the cut exposed.
        uint256 room = MAX_WIDTH - 2 - zeroes;
        if (n > room) n = room;
        while (n > 1 && raw[n - 1] == "0") --n;
        bytes memory fractionalOut = new bytes(2 + zeroes + n);
        fractionalOut[0] = "0";
        fractionalOut[1] = ".";
        for (uint256 i; i < zeroes; ++i) fractionalOut[2 + i] = "0";
        for (uint256 i; i < n; ++i) fractionalOut[2 + zeroes + i] = raw[i];
        return string(fractionalOut);
    }

    /// @dev `d.dddde±K` from the decimal digits of `raw`, to at most five
    ///      significant figures. Used at both ends of the range: values too
    ///      wide for the slot and values too small to write out in full.
    function _scientific(bytes memory raw, uint256 exponent, bool negative)
        private
        pure
        returns (string memory)
    {
        uint256 significant = raw.length;
        while (significant > 1 && raw[significant - 1] == "0") --significant;
        if (significant > 5) significant = 5;
        while (significant > 1 && raw[significant - 1] == "0") --significant;

        bytes memory exp = bytes(LibString.toString(exponent));
        bytes memory out = new bytes(significant + (significant > 1 ? 3 : 2) + exp.length);
        out[0] = raw[0];
        uint256 cursor = 1;
        if (significant > 1) {
            out[cursor++] = ".";
            for (uint256 i = 1; i < significant; ++i) out[cursor++] = raw[i];
        }
        out[cursor++] = "e";
        out[cursor++] = negative ? bytes1("-") : bytes1("+");
        for (uint256 i; i < exp.length; ++i) out[cursor++] = exp[i];
        return string(out);
    }

    /// @dev Token ids are arbitrary 256-bit words and are routinely hashes, so
    ///      a long one is elided in the middle the way an address is rather
    ///      than left to overrun the card.
    function _shortId(uint256 id) internal pure returns (string memory) {
        bytes memory raw = bytes(LibString.toString(id));
        if (raw.length <= 12) return string(raw);
        bytes memory out = new bytes(12);
        for (uint256 i; i < 6; ++i) out[i] = raw[i];
        out[6] = ".";
        out[7] = ".";
        for (uint256 i; i < 4; ++i) out[8 + i] = raw[raw.length - 4 + i];
        return string(out);
    }

    function assetType(uint8 snapshot, bool isNFT) internal pure returns (string memory) {
        if (isNFT) return "NFT";
        if (snapshot == 0) return "ERC20 / RAW";
        return string.concat("ERC20 / ", LibString.toString(snapshot - 1), " DEC");
    }

    function _copy(bytes memory input, uint256 start, uint256 end) private pure returns (bytes memory out) {
        out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) out[i] = input[start + i];
    }

}
