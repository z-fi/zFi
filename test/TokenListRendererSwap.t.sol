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
    /// @dev Read from the registry rather than pinned. The constant here named the
    ///      renderer that was live when this was written; the registry has since been
    ///      pointed at a newer one, and a hardcoded address turns "the swap is safe"
    ///      into "the swap was safe once".
    address internal liveRenderer;

    function setUp() public {
        // Self-pin. The repo-wide fork_block_number predates the registry's own
        // deployment, so LIST has no code there and every read here reverts inside
        // setUp - which reads as a broken contract rather than a stale pin.
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_697_000);
        vm.skip(block.chainid != 1 || address(LIST).code.length == 0);
        liveRenderer = address(LIST.renderer());
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
        uint256 regressedDisplayType;
        for (uint256 i; i != ids.length; ++i) {
            string memory now_ = _decode(LIST.tokenURI(ids[i]));

            // Numeric traits must declare themselves numeric on every listing.
            assertTrue(_has(now_, "display_type"), "numeric display_type missing");
            if (!_has(before_[i], "display_type")) gainedDisplayType++;
            if (_has(before_[i], "display_type") && !_has(now_, "display_type")) regressedDisplayType++;

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
        // These were migration assertions: they asserted the swap ADDS display_type
        // and STRIPS the artwork trait from fungibles. That swap has since shipped -
        // the live renderer already emits display_type on every listing and no
        // longer tags fungibles - so "gained" and "lost" are now correctly zero and
        // can never be positive again. Asserting a one-time delta permanently fails
        // once it is done. The durable property is the invariant the migration
        // established, which the loop above already checks on every listing:
        // display_type is always present, and the artwork trait only ever appears
        // on a collection. Keep the counts as diagnostics, and guard the direction
        // that would be a regression.
        assertEq(regressedDisplayType, 0, "no listing may lose display_type");
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
        assertEq(address(LIST.renderer()), liveRenderer, "renderer moved mid-test");
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
