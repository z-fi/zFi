// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListLens} from "../src/utils/TokenListLens.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";

contract LensMockToken {
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }
}

/// @notice The lens owns ranking, rank-paging and search after they moved off the
///         registry for EIP-170 headroom. The ordering it produces must be exactly
///         what the registry used to produce, or the move changed behaviour rather
///         than just location.
contract TokenListLensTest is Test {
    address owner = address(0xA11CE);
    TokenList list;
    TokenListLens lens;

    function setUp() public {
        vm.chainId(8453); // off mainnet: constructor seeds nothing, so order is ours
        list = new TokenList(owner, new TokenListRenderer());
        lens = new TokenListLens();
    }

    function _list(string memory name_, string memory sym, uint32 rank) internal returns (uint256) {
        LensMockToken t = new LensMockToken(name_, sym, 18);
        vm.prank(owner);
        return list.list(address(t), 0x112233, rank, "", "", "");
    }

    function testEmptyListIsHandled() public view {
        assertEq(lens.rankedIds(list).length, 0);
        assertEq(lens.rankedIdsPaged(list, 0, 10).length, 0);
        assertEq(lens.rankedSummaries(list, 0, 10).length, 0);
        assertEq(lens.search(list, "anything", 10).length, 0);
    }

    function testRanksDescendingAndTiesKeepListingOrder() public {
        uint256 a = _list("Alpha", "AAA", 10);
        uint256 b = _list("Beta", "BBB", 30);
        uint256 c = _list("Gamma", "CCC", 20);
        // Two more at an identical rank: the tie must resolve to listing order, which
        // is the property the packed sort key exists to preserve.
        uint256 d = _list("Delta", "DDD", 20);

        uint256[] memory ranked = lens.rankedIds(list);
        assertEq(ranked.length, 4);
        assertEq(ranked[0], b, "highest rank first");
        assertEq(ranked[1], c, "tie: listed first wins");
        assertEq(ranked[2], d, "tie: listed second follows");
        assertEq(ranked[3], a, "lowest rank last");
    }

    function testUnrankedSortLast() public {
        uint256 zero = _list("Zero", "ZZZ", 0);
        uint256 one = _list("One", "ONE", 1);
        assertEq(lens.rankedIds(list)[0], one);
        assertEq(lens.rankedIds(list)[1], zero);
    }

    function testPagingMatchesTheFullRanking() public {
        for (uint256 i; i < 6; ++i) {
            _list(string.concat("Token", vm.toString(i)), string.concat("T", vm.toString(i)), uint32(i * 10));
        }
        uint256[] memory all = lens.rankedIds(list);
        uint256[] memory page = lens.rankedIdsPaged(list, 2, 3);
        assertEq(page.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(page[i], all[2 + i], "page is a slice of the ranking");
        }
        // Clamped, not reverting, at and past the end.
        assertEq(lens.rankedIdsPaged(list, 4, 100).length, 2);
        assertEq(lens.rankedIdsPaged(list, 6, 1).length, 0);
        assertEq(lens.rankedIdsPaged(list, 999, 1).length, 0);
    }

    function testRankedSummariesCarryTheRowAndTheOrder() public {
        _list("Alpha", "AAA", 10);
        uint256 b = _list("Beta", "BBB", 30);
        TokenList.Summary[] memory page = lens.rankedSummaries(list, 0, 2);
        assertEq(page.length, 2);
        assertEq(page[0].id, b);
        assertEq(page[0].symbol, "BBB");
        assertEq(page[0].name, "Beta");
        assertEq(page[0].rank, 30);
        assertEq(page[1].symbol, "AAA");
    }

    /// @dev The registry pages in listing order and the lens sorts. Asserted together
    ///      so the split cannot be silently undone on one side.
    function testRegistryPagesInListingOrderAndLensSorts() public {
        _list("Alpha", "AAA", 1);
        _list("Beta", "BBB", 999);
        assertEq(list.summariesPaged(0, 1)[0].symbol, "AAA", "registry: listing order");
        assertEq(lens.rankedSummaries(list, 0, 1)[0].symbol, "BBB", "lens: rank order");
    }

    function testSearchIsCaseInsensitiveOverNameAndSymbol() public {
        uint256 a = _list("Wrapped Ether", "WETH", 10);
        _list("Dollar Coin", "USDC", 20);
        assertEq(lens.search(list, "weth", 10).length, 1);
        assertEq(lens.search(list, "WETH", 10).length, 1);
        assertEq(lens.search(list, "wrapped", 10)[0], a, "matches name too");
        assertEq(lens.search(list, "ETHER", 10)[0], a);
        assertEq(lens.search(list, "nothinghere", 10).length, 0);
    }

    function testSearchHonoursItsLimit() public {
        _list("Coin One", "CONE", 1);
        _list("Coin Two", "CTWO", 2);
        _list("Coin Three", "CTHREE", 3);
        assertEq(lens.search(list, "coin", 10).length, 3);
        assertEq(lens.search(list, "coin", 2).length, 2);
        assertEq(lens.search(list, "coin", 0).length, 0);
    }

    /// @dev The lens takes the registry as a parameter rather than an immutable, so
    ///      one deployment serves every list and it has no deploy-ordering
    ///      constraint. Worth an assertion: it is the reason there is no third salt.
    function testOneLensServesMoreThanOneRegistry() public {
        TokenList other = new TokenList(owner, new TokenListRenderer());
        _list("Alpha", "AAA", 10);
        LensMockToken t = new LensMockToken("Other", "OTH", 18);
        vm.prank(owner);
        other.list(address(t), 0, 5, "", "", "");

        assertEq(lens.rankedIds(list).length, 1);
        assertEq(lens.rankedIds(other).length, 1);
        assertEq(lens.search(list, "alpha", 5).length, 1);
        assertEq(lens.search(other, "alpha", 5).length, 0);
    }

    function testDelistingDropsTheRowFromEveryLensRead() public {
        uint256 a = _list("Alpha", "AAA", 10);
        _list("Beta", "BBB", 30);
        vm.prank(owner);
        list.delist(a);
        assertEq(lens.rankedIds(list).length, 1);
        assertEq(lens.search(list, "alpha", 10).length, 0);
        assertEq(lens.rankedSummaries(list, 0, 10).length, 1);
    }
}
