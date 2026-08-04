// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Base64} from "../../lib/solady/src/utils/Base64.sol";
import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";
import {IZorgReceiptArt} from "./IZorgReceiptArt.sol";

interface IERC721Art {
    function tokenURI(uint256 id) external view returns (string memory);
}

/// @notice The governor state a receipt's metadata is derived from. Every member
///         is a public getter on `ZorgConviction`, so this contract reads the
///         live position rather than being handed a snapshot it cannot verify.
interface IZorgGov {
    function bondedWeight(uint256 receiptId) external view returns (uint256);
    function allocatedByBond(uint256 receiptId) external view returns (uint256);
    function eternalBonds(uint256 receiptId) external view returns (bool);
    function loyaltyOf(uint256 receiptId) external view returns (uint256);
    function zorgz() external view returns (address);
    function receiptLocks(uint256 receiptId)
        external
        view
        returns (uint64 exitDelay, uint64 unlockAt, uint16 boostBps, uint8 tier);
    function ethBonds(uint256 receiptId)
        external
        view
        returns (
            uint256 principal,
            uint256 accruedLoyalty,
            uint256 rewardIndex,
            uint64 bondedAt,
            uint64 maturityAt,
            uint64 maturity,
            uint16 earlyExitTaxBps,
            uint16 treasuryShareBps
        );
}

/// @title ZorgReceiptArt
/// @notice Receipt metadata and artwork for `ZorgConviction`, in its own contract.
/// @dev `ZorgConviction` is 13.5 KB over EIP-170 and cannot be deployed. Almost
///      all of that excess is this: string building, SVG rewriting and a small
///      JSON scanner, none of which touches escrow. Moving it out is the same
///      seam `ZorgPageStyle` uses for the dashboard, and it is replaceable for
///      the same reason - art is the one part of the system that will want to
///      change without migrating anybody's bond.
///
///      Metadata failures only ever affect the cosmetic fallback mask; they can
///      never affect a receipt's allocation or redemption rights.
contract ZorgReceiptArt is IZorgReceiptArt {
    using LibString for uint256;

    uint16 internal constant BPS = 10_000;

    struct ReceiptLock {
        uint64 exitDelay;
        uint64 unlockAt;
        uint16 boostBps;
        uint8 tier;
    }

    struct EthBond {
        uint256 principal;
        uint256 accruedLoyalty;
        uint256 rewardIndex;
        uint64 bondedAt;
        uint64 maturityAt;
        uint64 maturity;
        uint16 earlyExitTaxBps;
        uint16 treasuryShareBps;
    }

    /// @notice The receipt image is the inverse of its escrowed zOrgz SVG.
    function tokenURI(address governor, uint256 receiptId) external view override returns (string memory) {
        IZorgGov gov = IZorgGov(governor);
        ReceiptLock memory terms;
        (terms.exitDelay, terms.unlockAt, terms.boostBps, terms.tier) = gov.receiptLocks(receiptId);
        EthBond memory ethBond;
        (
            ethBond.principal,
            ethBond.accruedLoyalty,
            ethBond.rewardIndex,
            ethBond.bondedAt,
            ethBond.maturityAt,
            ethBond.maturity,
            ethBond.earlyExitTaxBps,
            ethBond.treasuryShareBps
        ) = gov.ethBonds(receiptId);
        string memory image = _invertedImage(_receiptArtwork(gov, receiptId));
        string memory json = string.concat(
            _metadataHead(receiptId, image),
            _metadataWeightAttributes(gov, receiptId, terms),
            _metadataEthAttributes(gov, receiptId, ethBond),
            _metadataCommitmentAttributes(gov, receiptId, terms)
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _metadataHead(uint256 receiptId, string memory image) internal pure returns (string memory) {
        return string.concat(
            '{"name":"zOrgz Bond #',
            receiptId.toString(),
            '","description":"Transferable custody receipt for one escrowed zOrgz, bonded zOrg shares, and refundable ETH loyalty principal.","image":"',
            image,
            '","attributes":['
        );
    }

    function _metadataWeightAttributes(IZorgGov gov, uint256 receiptId, ReceiptLock memory terms)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            '{"trait_type":"Underlying zOrgz","value":"',
            receiptId.toString(),
            '"},{"trait_type":"Bonded zOrg","value":"',
            gov.bondedWeight(receiptId).toString(),
            '"},{"trait_type":"Allocated zOrg","value":"',
            gov.allocatedByBond(receiptId).toString(),
            '"},{"trait_type":"Effective active support","value":"',
            _effectiveWeight(gov.allocatedByBond(receiptId), terms.boostBps).toString(),
            '"},'
        );
    }

    function _metadataEthAttributes(IZorgGov gov, uint256 receiptId, EthBond memory ethBond)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            '{"trait_type":"ETH principal","value":"',
            ethBond.principal.toString(),
            ' wei"},{"trait_type":"ETH loyalty accrued","value":"',
            gov.loyaltyOf(receiptId).toString(),
            ' wei"},{"trait_type":"ETH maturity","value":"',
            uint256(ethBond.maturityAt).toString(),
            '"},{"trait_type":"Early exit tax","value":"',
            uint256(ethBond.earlyExitTaxBps).toString(),
            ' bps"},{"trait_type":"Treasury tax share","value":"',
            uint256(ethBond.treasuryShareBps).toString(),
            ' bps"},{"trait_type":"Bond age","value":"',
            uint256(block.timestamp - ethBond.bondedAt).toString(),
            ' seconds"},'
        );
    }

    function _metadataCommitmentAttributes(IZorgGov gov, uint256 receiptId, ReceiptLock memory terms)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            '{"trait_type":"Commitment","value":"',
            _commitmentStatus(gov, receiptId, terms),
            '"},{"trait_type":"Lock tier","value":"',
            uint256(terms.tier).toString(),
            '"},{"trait_type":"Support boost","value":"',
            uint256(terms.boostBps).toString(),
            ' bps"},{"trait_type":"Exit delay","value":"',
            uint256(terms.exitDelay / 1 days).toString(),
            ' days"},{"trait_type":"Redeemable","value":"',
            _redemptionStatus(gov, receiptId, terms),
            '"}]}'
        );
    }

    function _commitmentStatus(IZorgGov gov, uint256 receiptId, ReceiptLock memory terms) internal view returns (string memory) {
        if (gov.eternalBonds(receiptId)) return "eternal";
        if (terms.tier == 0) return "open";
        if (block.timestamp >= terms.unlockAt) return "hard lock satisfied";
        return string.concat("hard locked until ", uint256(terms.unlockAt).toString());
    }

    function _redemptionStatus(IZorgGov gov, uint256 receiptId, ReceiptLock memory terms) internal view returns (string memory) {
        if (gov.eternalBonds(receiptId)) return "never (eternal)";
        if (gov.allocatedByBond(receiptId) != 0) return "clear allocations first";
        if (terms.unlockAt == 0 || block.timestamp >= terms.unlockAt) return "yes";
        return string.concat("hard locked until ", uint256(terms.unlockAt).toString());
    }

    function _effectiveWeight(uint256 rawWeight, uint16 boostBps) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(rawWeight, boostBps, BPS);
    }

    function _underlyingImage(IZorgGov gov, uint256 tokenId) internal view returns (string memory) {
        try IERC721Art(gov.zorgz()).tokenURI(tokenId) returns (string memory uri) {
            bytes memory data = bytes(uri);
            bytes memory imagePrefix = bytes("data:image/svg+xml;base64,");
            if (_hasPrefix(data, imagePrefix)) return _isSafeSvgDataUri(data) ? uri : _fallbackImage(tokenId);

            bytes memory metadataPrefix = bytes("data:application/json;base64,");
            if (!_hasPrefix(data, metadataPrefix)) return _fallbackImage(tokenId);
            return _imageFromJson(Base64.decode(string(_slice(data, metadataPrefix.length, data.length))), tokenId);
        } catch {
            return _fallbackImage(tokenId);
        }
    }

    /// @dev Eternal receipts use the same deterministic inverse mask, with a
    ///      deep-blue source glyph inserted immediately after zOrgz's opaque
    ///      64px background. The inversion turns it gold; later zOrgz layers
    ///      remain above it, so traits such as a third eye are never covered.
    function _receiptArtwork(IZorgGov gov, uint256 receiptId) internal view returns (string memory) {
        string memory underlying = _underlyingImage(gov, receiptId);
        if (!gov.eternalBonds(receiptId)) return underlying;
        bytes memory uri = bytes(underlying);
        bytes memory prefix = bytes("data:image/svg+xml;base64,");
        if (!_hasPrefix(uri, prefix)) return underlying;
        bytes memory source = Base64.decode(string(_slice(uri, prefix.length, uri.length)));
        bytes memory anchor = bytes('<rect width="64" height="64"');
        bytes memory close = bytes("/>");
        uint256 at = type(uint256).max;
        for (uint256 i; i + anchor.length <= source.length; ++i) {
            if (_matchesAt(source, anchor, i)) {
                at = i;
                break;
            }
        }
        if (at == type(uint256).max) return underlying;
        uint256 end = at + anchor.length;
        while (end + close.length <= source.length && !_matchesAt(source, close, end)) ++end;
        if (end + close.length > source.length) return underlying;
        end += close.length;
        bytes memory glyph = bytes(
            '<svg width="64" height="64" viewBox="8 8 16 16" opacity=".29"><path d="M10 10h12l-12 12h12M10 14h12M10 18h12" fill="none" stroke="#264cb5" stroke-width="1.6" stroke-linecap="square" stroke-linejoin="round"/></svg>'
        );
        bytes memory out = new bytes(source.length + glyph.length);
        uint256 cursor;
        for (uint256 i; i < end; ++i) out[cursor++] = source[i];
        for (uint256 i; i < glyph.length; ++i) out[cursor++] = glyph[i];
        for (uint256 i = end; i < source.length; ++i) out[cursor++] = source[i];
        return string.concat("data:image/svg+xml;base64,", Base64.encode(out));
    }

    function _imageFromJson(bytes memory json, uint256 tokenId) internal pure returns (string memory) {
        bytes memory needle = bytes('"image"');
        uint256 n = json.length;
        if (n < needle.length) return _fallbackImage(tokenId);
        for (uint256 i; i <= n - needle.length; ++i) {
            if (!_matchesAt(json, needle, i)) continue;
            uint256 cursor = _skipWhitespace(json, i + needle.length);
            if (cursor == n || json[cursor] != ":") continue;
            cursor = _skipWhitespace(json, cursor + 1);
            if (cursor == n || json[cursor] != '"') continue;
            uint256 start = cursor + 1;
            for (uint256 end = start; end < n; ++end) {
                if (json[end] == "\\") return _fallbackImage(tokenId);
                if (json[end] == '"') {
                    bytes memory image = _slice(json, start, end);
                    return _isSafeSvgDataUri(image) ? string(image) : _fallbackImage(tokenId);
                }
            }
            break;
        }
        return _fallbackImage(tokenId);
    }

    /// @dev The inversion is an SVG `<filter>` primitive, not the CSS `filter:invert(1)`
    ///      shorthand this used to carry. The shorthand is CSS Filter Effects, which
    ///      browsers implement but standalone SVG rasterizers — the ones marketplaces
    ///      and wallets run server-side — variously do not. Where it is dropped the
    ///      filter silently does nothing and the receipt renders IDENTICAL to the
    ///      unstaked zOrgz it escrows, which is the one thing this image exists to
    ///      distinguish: a custody receipt that cannot be told apart from the asset is
    ///      worse than no art at all. `feComponentTransfer` with a two-entry table is
    ///      core SVG 1.1 and needs no CSS engine to be honoured.
    function _invertedImage(string memory underlying) internal pure returns (string memory) {
        string memory svg = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'>",
            "<filter id='i' color-interpolation-filters='sRGB'><feComponentTransfer>",
            "<feFuncR type='table' tableValues='1 0'/><feFuncG type='table' tableValues='1 0'/>",
            "<feFuncB type='table' tableValues='1 0'/></feComponentTransfer></filter>",
            "<rect width='64' height='64' fill='#fff'/>",
            "<image href='",
            underlying,
            "' width='64' height='64' preserveAspectRatio='xMidYMid meet' filter='url(#i)'/>",
            "</svg>"
        );
        return string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));
    }

    function _fallbackImage(uint256 tokenId) internal pure returns (string memory) {
        string memory svg = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'><rect width='64' height='64' fill='#fff'/>",
            "<rect x='4' y='4' width='56' height='56' fill='#000'/><text x='32' y='37' text-anchor='middle' ",
            "font-family='monospace' font-size='11' fill='#fff'>",
            tokenId.toString(),
            "</text></svg>"
        );
        return string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));
    }

    function _hasPrefix(bytes memory value, bytes memory prefix) internal pure returns (bool) {
        if (value.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (value[i] != prefix[i]) return false;
        }
        return true;
    }

    function _matchesAt(bytes memory value, bytes memory needle, uint256 offset) internal pure returns (bool) {
        if (offset > value.length || needle.length > value.length - offset) return false;
        for (uint256 i; i < needle.length; ++i) {
            if (value[offset + i] != needle[i]) return false;
        }
        return true;
    }

    function _skipWhitespace(bytes memory value, uint256 cursor) internal pure returns (uint256) {
        while (cursor < value.length) {
            bytes1 char = value[cursor];
            if (char != 0x20 && char != 0x09 && char != 0x0a && char != 0x0d) break;
            ++cursor;
        }
        return cursor;
    }

    /// @dev Restricting the embedded URI to base64 SVG makes it safe to place
    ///      in the single-quoted `href` attribute in `_invertedImage`.
    function _isSafeSvgDataUri(bytes memory value) internal pure returns (bool) {
        bytes memory prefix = bytes("data:image/svg+xml;base64,");
        if (value.length <= prefix.length || !_hasPrefix(value, prefix)) return false;
        for (uint256 i = prefix.length; i < value.length; ++i) {
            bytes1 char = value[i];
            bool valid = (char >= "A" && char <= "Z") || (char >= "a" && char <= "z") || (char >= "0" && char <= "9")
                || char == "+" || char == "/" || char == "=";
            if (!valid) return false;
        }
        return true;
    }

    function _slice(bytes memory value, uint256 start, uint256 end) internal pure returns (bytes memory out) {
        if (start > end || end > value.length) return out;
        out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = value[start + i];
        }
    }
}
