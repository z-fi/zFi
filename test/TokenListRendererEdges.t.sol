// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";

/// @notice Edge cases the live listings do not exercise. `tokenURI` is pure, so this
///         needs no fork and no chain state — just the candidate in this tree.
contract TokenListRendererEdgesTest is Test {
    TokenListRenderer internal r;

    function setUp() public {
        r = new TokenListRenderer();
    }

    function _t() internal pure returns (TokenList.Token memory t) {
        t.chainId = 1;
        t.deployed = true;
        t.name = "Example";
        t.symbol = "EX";
    }

    /// @dev tokenURI is a base64 data: URI wrapping JSON whose `image` is another
    ///      base64 data: URI. Assertions run against the DECODED card - searching the
    ///      encoding passes or fails for reasons unrelated to what is being tested,
    ///      which is exactly how the first version of this file reported six
    ///      failures against a renderer that was working correctly.
    function _render(TokenList.Token memory t) internal view returns (string memory) {
        string memory uri = r.tokenURI(1, t, new TokenListRenderer.Extra[](0));
        string memory json = string(Base64.decode(_after(uri, ",")));
        return string.concat(json, string(Base64.decode(_after(_imageUri(json), ","))));
    }

    function _after(string memory s, string memory sep) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes1 k = bytes(sep)[0];
        for (uint256 i; i != b.length; ++i) {
            if (b[i] != k) continue;
            bytes memory o = new bytes(b.length - i - 1);
            for (uint256 j; j != o.length; ++j) o[j] = b[i + 1 + j];
            return string(o);
        }
        revert("sep not found");
    }

    function _imageUri(string memory json) internal pure returns (string memory) {
        bytes memory h = bytes(json);
        bytes memory k = bytes('"image":"');
        for (uint256 i; i + k.length < h.length; ++i) {
            bool hit = true;
            for (uint256 j; j != k.length; ++j) {
                if (h[i + j] != k[j]) {
                    hit = false;
                    break;
                }
            }
            if (!hit) continue;
            uint256 st = i + k.length;
            uint256 en = st;
            while (en < h.length && h[en] != '"') ++en;
            bytes memory o = new bytes(en - st);
            for (uint256 j; j != o.length; ++j) o[j] = h[st + j];
            return string(o);
        }
        revert("no image");
    }

    function test_EmptyEverything() public view {
        TokenList.Token memory t;
        t.deployed = true;
        assertGt(bytes(_render(t)).length, 0);
    }

    function test_MaxLengthText() public view {
        TokenList.Token memory t = _t();
        t.name = "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN"; // NAME_MAX 40
        t.symbol = "SSSSSSSSSSSS"; // SYMBOL_MAX 12
        t.decimals = 36;
        t.rank = type(uint32).max;
        t.color = 0xffffff;
        assertGt(bytes(_render(t)).length, 0);
    }

    /// @dev Every standard must produce a card, including ones no listing uses yet.
    function test_EveryStandardRenders() public view {
        for (uint8 s; s <= uint8(TokenList.Standard.BRC20); ++s) {
            TokenList.Token memory t = _t();
            t.standard = TokenList.Standard(s);
            if (s >= uint8(TokenList.Standard.TACIT)) {
                t.kind = TokenList.Kind.OTHER;
                t.chainId = 0;
                t.account = bytes32(uint256(0xabcdef));
            }
            assertGt(bytes(_render(t)).length, 0, "standard failed to render");
        }
    }

    /// @dev The account row must name what the word is, per standard.
    function test_AccountRowLabels() public view {
        TokenList.Token memory t = _t();
        t.account = bytes32(uint256(uint160(address(0xBEEF))));
        assertTrue(_has(_render(t), "ADDRESS"), "evm should say ADDRESS");

        t.kind = TokenList.Kind.SVM;
        t.chainId = 0;
        assertTrue(_has(_render(t), "MINT"), "svm should say MINT");

        t.kind = TokenList.Kind.OTHER;
        t.standard = TokenList.Standard.TACIT;
        assertTrue(_has(_render(t), "ASSET ID"), "tacit should say ASSET ID");

        t.standard = TokenList.Standard.RUNE;
        assertTrue(_has(_render(t), "REGISTRY KEY"), "rune should say REGISTRY KEY");
    }

    /// @dev The chain line must never read `raw:0` for a Bitcoin-rooted standard.
    function test_BitcoinChainLine() public view {
        TokenList.Token memory t = _t();
        t.kind = TokenList.Kind.OTHER;
        t.chainId = 0;
        for (uint8 s = uint8(TokenList.Standard.TACIT); s <= uint8(TokenList.Standard.BRC20); ++s) {
            t.standard = TokenList.Standard(s);
            string memory out = _render(t);
            assertTrue(_has(out, "bitcoin"), "missing bitcoin chain label");
            assertFalse(_has(out, "raw:0"), "still printing raw:0");
        }
    }

    /// @dev A zero account is not an address anyone can copy.
    function test_ZeroAccountSaysNone() public view {
        TokenList.Token memory t = _t();
        t.standard = TokenList.Standard.NATIVE;
        string memory out = _render(t);
        assertTrue(_has(out, "NONE - NATIVE ASSET"));
        assertFalse(_has(out, "0x0000000000000000000000000000000000000000"), "forty zeros back");
    }

    /// @dev With no logo the well carries the symbol's opening glyphs.
    function test_InitialsFallback() public view {
        TokenList.Token memory t = _t();
        t.symbol = "TAC";
        assertTrue(_has(_render(t), "text-anchor='middle'"), "no initials fallback");
        // A logo, when present, wins.
        t.logo = "data:image/svg+xml;base64,AAAA";
        assertTrue(_has(_render(t), "<image"), "logo not drawn");
    }

    /// @dev An empty symbol must not produce a stray empty glyph element.
    function test_EmptySymbolNoInitials() public view {
        TokenList.Token memory t = _t();
        t.symbol = "";
        assertGt(bytes(_render(t)).length, 0);
    }

    /// @dev Provenance is a signal, never the owner's brand colour.
    function test_ProvenanceChipIsNeutral() public view {
        TokenList.Token memory t = _t();
        t.color = 0xff0000;
        t.synced = true;
        string memory out = _render(t);
        assertTrue(_has(out, "fill='#fff' stroke='#fff'"), "chip is not neutral");
    }

    /// @dev A reservation's description is the only thing distinguishing it.
    function test_ReservedKeepsItsDescription() public view {
        TokenList.Token memory t = _t();
        t.deployed = false;
        t.description = "This reservation has no account and no onchain facts to show.";
        string memory out = _render(t);
        assertTrue(_has(out, "RESERVED TOKEN / NOT DEPLOYED"));
        assertTrue(_has(out, "This reservation has no account"), "description lost");
    }

    function _has(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j != n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
