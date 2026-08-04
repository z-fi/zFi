// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {LibSort} from "../../lib/solady/src/utils/LibSort.sol";

/// @notice Read surface shared by `ZorgConviction` and a dynamic TokenList view.
interface IConvictionScores {
    function supportOf(uint256 listingId) external view returns (uint256);
}

/// @notice ABI-compatible read surface of the existing TokenList contract.
interface ITokenListSource {
    struct Token {
        bytes32 account;
        uint64 chainId;
        uint8 decimals;
        uint8 kind;
        uint8 standard;
        bool deployed;
        bool onchainSvg;
        bool synced;
        uint24 color;
        uint32 rank;
        bool frozen;
        string name;
        string symbol;
        string logo;
        string url;
        string audit;
        string description;
    }

    struct Summary {
        uint256 id;
        bytes32 account;
        uint64 chainId;
        uint8 decimals;
        uint8 kind;
        uint8 standard;
        bool deployed;
        bool onchainSvg;
        bool synced;
        uint24 color;
        uint32 rank;
        bool frozen;
        string name;
        string symbol;
    }

    function rankedIds() external view returns (uint256[] memory);
    function isListed(uint256 id) external view returns (bool);
    function get(uint256 id) external view returns (Token memory);
    function json(uint256 id) external view returns (string memory);
    function tokenURI(uint256 id) external view returns (string memory);
}

/// @title ZorgTokenListLens
/// @notice A drop-in, read-only TokenList view ordered by direct zOrg conviction.
/// @dev It owns no registry state and has no writer. Moloch remains the owner of
///      TokenList; token picker UIs read this lens instead of the base list. Equal
///      conviction preserves the base list's current ordering.
contract ZorgTokenListLens {
    ITokenListSource public immutable tokenList;
    IConvictionScores public immutable conviction;

    constructor(ITokenListSource tokenList_, IConvictionScores conviction_) {
        if (address(tokenList_).code.length == 0 || address(conviction_).code.length == 0) revert();
        tokenList = tokenList_;
        conviction = conviction_;
    }

    function rankedIds() public view returns (uint256[] memory out) {
        uint256[] memory sourceIds = tokenList.rankedIds();
        uint256 n = sourceIds.length;
        uint256[] memory keys = new uint256[](n);

        for (uint256 i; i < n; ++i) {
            // 224 bits are ample for an ERC-20 voting supply. Clamping avoids a
            // malformed score ever overflowing the 32-bit stable tie-breaker.
            uint256 score = conviction.supportOf(sourceIds[i]);
            if (score > type(uint224).max) score = type(uint224).max;
            keys[i] = (score << 32) | (n - 1 - i);
        }
        LibSort.sort(keys);
        LibSort.reverse(keys);

        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = sourceIds[n - 1 - (keys[i] & type(uint32).max)];
        }
    }

    function rankedIdsPaged(uint256 start, uint256 count) external view returns (uint256[] memory out) {
        uint256[] memory ranked = rankedIds();
        if (start >= ranked.length) return out;
        uint256 rest = ranked.length - start;
        uint256 n = count < rest ? count : rest;
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = ranked[start + i];
        }
    }

    /// @notice The same compact shape as `TokenList.summariesPaged`, but in live
    ///         conviction order so existing picker UIs can read this lens directly.
    function summariesPaged(uint256 start, uint256 count)
        external
        view
        returns (ITokenListSource.Summary[] memory out)
    {
        uint256[] memory ranked = rankedIds();
        if (start >= ranked.length) return out;
        uint256 rest = ranked.length - start;
        uint256 n = count < rest ? count : rest;
        out = new ITokenListSource.Summary[](n);
        for (uint256 i; i < n; ++i) {
            uint256 id = ranked[start + i];
            ITokenListSource.Token memory t = tokenList.get(id);
            out[i] = ITokenListSource.Summary(
                id,
                t.account,
                t.chainId,
                t.decimals,
                t.kind,
                t.standard,
                t.deployed,
                t.onchainSvg,
                t.synced,
                t.color,
                t.rank,
                t.frozen,
                t.name,
                t.symbol
            );
        }
    }

    function isListed(uint256 id) external view returns (bool) {
        return tokenList.isListed(id);
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        return tokenList.tokenURI(id);
    }

    function json(uint256 id) external view returns (string memory) {
        return tokenList.json(id);
    }

    function get(uint256 id) external view returns (ITokenListSource.Token memory) {
        return tokenList.get(id);
    }
}
