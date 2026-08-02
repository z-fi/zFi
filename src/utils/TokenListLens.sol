// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {LibSort} from "../../lib/solady/src/utils/LibSort.sol";
import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {TokenList} from "./TokenList.sol";

/// @title TokenListLens
/// @notice Ranking, rank-paging and search over a `TokenList`.
/// @dev These are pure views over data the registry already exposes. They used to
///      live on the registry itself, and moving them here is not a tidiness
///      exercise — it is the difference between a deployable registry and one that
///      is not.
///
///      `TokenList` sat at 23,939 B against EIP-170's 24,576 when compiled on its
///      own, and at 24,811 B — OVER the limit — when compiled alongside the test
///      suite, because `via_ir` optimises a contract differently depending on which
///      other files share its compilation unit. Two builds of identical source at
///      identical settings, 872 B apart, one of them undeployable. Foundry does not
///      enforce EIP-170 inside tests, so the suite passed against the variant
///      mainnet would have rejected. See `deploy/TokenList.md`.
///
///      The fix is margin, not a build flag: with these three functions moved out
///      the registry fits in every configuration with room to spare. The registry
///      is immutable and must retain space to ship a security fix; a lens can be
///      redeployed at will. So the split follows what can and cannot be replaced.
///
/// @dev STATELESS BY DESIGN. The registry is a parameter rather than an immutable,
///      so this contract has no constructor arguments, no wiring, and no deployment
///      ordering constraint. The renderer's address being baked into the registry's
///      creation code already couples two salts — mine one wrong and both are
///      invalid. Nothing is gained by extending that chain to a third contract, and
///      one lens serves every `TokenList` on every chain.
contract TokenListLens {
    using LibString for string;

    /// @notice Every listing id, highest rank first, ties broken by listing order.
    /// @dev Packs rank and index into one word so a single sort orders both keys —
    ///      the same encoding the registry used, so the ordering is unchanged.
    ///      Intended for `eth_call`; a dapp reads this once and pages the result.
    function rankedIds(TokenList list) public view returns (uint256[] memory out) {
        TokenList.Summary[] memory all = _all(list);
        uint256 n = all.length;
        uint256[] memory keys = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            keys[i] = (uint256(all[i].rank) << 32) | (n - 1 - i);
        }
        LibSort.sort(keys);
        LibSort.reverse(keys);
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = all[n - 1 - (keys[i] & 0xffffffff)].id;
        }
    }

    /// @notice A page of ranked ids alone, highest rank first.
    /// @dev The read a dapp should actually build a list from. A whole-struct page
    ///      would be far worse — a logo can be 24 KB of base64, so a 20-row page of
    ///      those is megabytes of returndata and hits provider `eth_call` limits long
    ///      before the list feels large. Page ids here, then batch `get`/`json`
    ///      through the registry's `Multicallable` for exactly the rows on screen.
    function rankedIdsPaged(TokenList list, uint256 start, uint256 count) public view returns (uint256[] memory out) {
        uint256[] memory ranked = rankedIds(list);
        if (start >= ranked.length) return out;
        uint256 rest = ranked.length - start;
        uint256 n = count < rest ? count : rest;
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = ranked[start + i];
        }
    }

    /// @notice A page of listings WITHOUT the heavy fields, highest rank first.
    /// @dev The rank-ordered counterpart to `TokenList.summariesPaged`, which pages
    ///      in listing order. Sorted here rather than there for the reason in the
    ///      contract header.
    function rankedSummaries(TokenList list, uint256 start, uint256 count)
        public
        view
        returns (TokenList.Summary[] memory out)
    {
        TokenList.Summary[] memory all = _all(list);
        uint256[] memory ranked = rankedIds(list);
        if (start >= ranked.length) return out;
        uint256 rest = ranked.length - start;
        uint256 n = count < rest ? count : rest;
        out = new TokenList.Summary[](n);
        for (uint256 i; i < n; ++i) {
            uint256 id = ranked[start + i];
            for (uint256 j; j < all.length; ++j) {
                if (all[j].id == id) {
                    out[i] = all[j];
                    break;
                }
            }
        }
    }

    /// @notice Case-insensitive substring search over symbol and name.
    /// @dev View-only and linear; the list is curated, so it stays small enough that
    ///      an exact index would cost more to maintain than this costs to run.
    function search(TokenList list, string calldata query, uint256 limit) public view returns (uint256[] memory out) {
        string memory needle = LibString.lower(query);
        TokenList.Summary[] memory all = _all(list);
        uint256 n = all.length;
        // Bounded by the answer the caller asked for, not by the list size.
        uint256[] memory hits = new uint256[](limit < n ? limit : n);
        uint256 found;
        for (uint256 i; i < n && found < limit; ++i) {
            if (LibString.lower(all[i].symbol).contains(needle) || LibString.lower(all[i].name).contains(needle)) {
                hits[found++] = all[i].id;
            }
        }
        out = hits;
        assembly ("memory-safe") {
            mstore(out, found)
        }
    }

    /// @dev One bounded read of the whole list. Every function here needs the same
    ///      rank/name/symbol data for every listing, so fetching it once per call
    ///      keeps this to a single external call rather than one per row. The rows
    ///      carry no logo, description or links, which is what makes reading all of
    ///      them at once reasonable — and is exactly why the registry keeps a
    ///      summary page rather than only a whole-struct getter.
    function _all(TokenList list) internal view returns (TokenList.Summary[] memory) {
        return list.summariesPaged(0, list.total());
    }
}
