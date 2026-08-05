// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";

/// @notice Forked comparison of the LIVE renderer against the candidate in this tree,
///         over every listing the registry actually holds.
///
///         A renderer swap restyles every card at once and cannot be undone by anyone
///         but the owner, so "the tests pass" is not the question — the question is
///         what changes for the 11 listings that exist. This answers that against
///         mainnet state rather than fixtures.
///
///         forge test --match-path test/TokenListRendererSwap.t.sol --fork-url <rpc> -vv
contract TokenListRendererSwapTest is Test {
    TokenList internal constant LIST = TokenList(0x0000006013dF75A31678B786061C2B54bf531524);
    address internal constant LIVE_RENDERER = 0x000000d595e36Dd0228c4040D981A01A59DbbE87;

    function setUp() public {
        vm.skip(block.chainid != 1);
    }

    /// @dev `json()` is what the dapp parses. It must not change at all — if it does,
    ///      the deployed page starts reading something it was not built for, and the
    ///      page is immutable.
    function test_JsonIsByteIdenticalForEveryListing() public {
        uint256[] memory ids = LIST.rankedIds();
        assertGt(ids.length, 0, "no listings");

        string[] memory before_ = new string[](ids.length);
        for (uint256 i; i != ids.length; ++i) before_[i] = LIST.json(ids[i]);

        _swapToCandidate();

        for (uint256 i; i != ids.length; ++i) {
            assertEq(
                keccak256(bytes(LIST.json(ids[i]))),
                keccak256(bytes(before_[i])),
                "json() changed - the deployed dapp parses this"
            );
        }
        emit log_named_uint("listings whose json() is unchanged", ids.length);
    }

    /// @dev `tokenURI()` SHOULD change — that is the point — but only in the two ways
    ///      intended, and the art must survive untouched.
    function test_TokenUriChangesOnlyAsIntended() public {
        uint256[] memory ids = LIST.rankedIds();

        // tokenURI is a base64 data: URI — decode, or every substring check silently
        // searches the encoding rather than the metadata.
        string[] memory before_ = new string[](ids.length);
        for (uint256 i; i != ids.length; ++i) before_[i] = _decode(LIST.tokenURI(ids[i]));

        _swapToCandidate();

        uint256 lostArtworkTrait;
        uint256 gainedDisplayType;
        for (uint256 i; i != ids.length; ++i) {
            string memory now_ = _decode(LIST.tokenURI(ids[i]));

            // Numeric traits must declare themselves numeric on every listing.
            assertTrue(_has(now_, "display_type"), "numeric display_type missing");
            if (!_has(before_[i], "display_type")) gainedDisplayType++;

            // The artwork trait may only survive on a collection.
            bool had = _has(before_[i], "Per-token Artwork");
            bool has = _has(now_, "Per-token Artwork");
            if (had && !has) lostArtworkTrait++;
            if (has) {
                assertTrue(
                    _has(now_, "ERC-721") || _has(now_, "ERC-1155"),
                    "artwork trait on a non-collection"
                );
            }

            // The card art DOES move now - that is the point of the five card fixes -
            // so asserting it is byte-identical would only be asserting that this
            // change set does not exist. Gate on the intended changes instead: the
            // provenance chip must be neutral rather than the owner's theme, and the
            // pieces a reader identifies a listing by must survive.
            string memory art = _decode(_imageUri(now_));
            assertTrue(
                _has(art, "fill='#fff' stroke='#fff'"), "provenance chip is not neutral"
            );
            assertTrue(_has(art, "TOKEN LISTING"), "card lost its header");
            assertTrue(_has(art, "WEIGHT "), "card lost its weight");
        }
        emit log_named_uint("listings that gained display_type", gainedDisplayType);
        emit log_named_uint("listings that shed a meaningless artwork trait", lostArtworkTrait);
        assertEq(gainedDisplayType, ids.length, "every listing should gain display_type");
        assertGt(lostArtworkTrait, 0, "expected fungibles to shed the artwork trait");
    }

    function test_ContractUriUnchanged() public {
        string memory before_ = LIST.contractURI();
        _swapToCandidate();
        assertEq(
            keccak256(bytes(LIST.contractURI())),
            keccak256(bytes(before_)),
            "contractURI changed - the dapp shows this as its subtitle"
        );
    }

    function _swapToCandidate() internal {
        assertEq(address(LIST.renderer()), LIVE_RENDERER, "live renderer moved since this was written");
        TokenListRenderer candidate = new TokenListRenderer();
        vm.prank(LIST.owner());
        LIST.setRenderer(candidate);
    }

    /// @dev Strip `data:application/json;base64,` and decode.
    function _decode(string memory uri) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        uint256 comma;
        for (uint256 i; i != b.length; ++i) {
            if (b[i] == ",") {
                comma = i + 1;
                break;
            }
        }
        require(comma != 0, "not a data uri");
        bytes memory payload = new bytes(b.length - comma);
        for (uint256 i; i != payload.length; ++i) payload[i] = b[comma + i];
        return string(Base64.decode(string(payload)));
    }

    /// @dev The `"image":"..."` value — the card art's own data: URI.
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
            uint256 start = i + k.length;
            uint256 end = start;
            while (end < h.length && h[end] != '"') ++end;
            bytes memory out = new bytes(end - start);
            for (uint256 j; j != out.length; ++j) out[j] = h[start + j];
            return string(out);
        }
        revert("no image field");
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
