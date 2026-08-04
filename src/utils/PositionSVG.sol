// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

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
        uint256 length;
        assembly ("memory-safe") {
            length := mload(add(response, 0x40))
        }
        if (length == 0 || length > 28 || response.length < 64 + length) return shortAddress(maker);

        string memory name = _safeText(response, 64, length);
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
            if (c >= 0x21 && c <= 0x7e && c != "<" && c != "&") {
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

        // Tiny positive values become scientific notation, avoiding a long run
        // of zeros in marketplace thumbnails (e.g. 1e-8) and keeping a
        // high-decimals token inside the slot.
        if (decimals - n >= 3 || decimals + 2 > MAX_WIDTH) {
            return _scientific(raw, decimals - n + 1, true);
        }

        bytes memory fractionalOut = new bytes(decimals + 2);
        fractionalOut[0] = "0";
        fractionalOut[1] = ".";
        uint256 zeroes = decimals - n;
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
