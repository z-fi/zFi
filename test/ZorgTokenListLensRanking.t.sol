// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgTokenListLens, ITokenListSource, IConvictionScores} from "../src/dao/ZorgTokenListLens.sol";

/// A TokenList stand-in whose base order and membership we control exactly.
contract FakeList {
    uint256[] public ids;

    function setIds(uint256[] memory ids_) external {
        ids = ids_;
    }

    function rankedIds() external view returns (uint256[] memory) {
        return ids;
    }

    function isListed(uint256) external pure returns (bool) {
        return true;
    }

    function get(uint256 id) external pure returns (ITokenListSource.Token memory t) {
        t.account = bytes32(id);
        t.name = "n";
        t.symbol = "s";
    }

    function json(uint256) external pure returns (string memory) {
        return "{}";
    }

    function tokenURI(uint256) external pure returns (string memory) {
        return "u";
    }
}

contract FakeScores {
    mapping(uint256 => uint256) public score;

    function set(uint256 id, uint256 v) external {
        score[id] = v;
    }

    function supportOf(uint256 id) external view returns (uint256) {
        return score[id];
    }
}

/// The lens packs `(score << 32) | (n-1-i)` into one word and sorts that, which
/// is the only non-obvious thing it does. These drive the cases the live list
/// cannot: a smaller-but-older allocation overtaking a larger-but-newer one,
/// exact ties, and the clamp that stops a malformed score from corrupting the
/// tie-breaker.
contract ZorgTokenListLensRankingTest is Test {
    FakeList list;
    FakeScores scores;
    ZorgTokenListLens lens;

    function setUp() public {
        list = new FakeList();
        scores = new FakeScores();
        uint256[] memory ids = new uint256[](4);
        ids[0] = 11;
        ids[1] = 22;
        ids[2] = 33;
        ids[3] = 44;
        list.setIds(ids);
        lens = new ZorgTokenListLens(ITokenListSource(address(list)), IConvictionScores(address(scores)));
    }

    /// With no conviction anywhere, the lens must be a pass-through. A curated
    /// list that reorders itself the moment the lens is installed would be a
    /// worse outcome than not installing it.
    function testUnvotedListIsUnchanged() public view {
        uint256[] memory out = lens.rankedIds();
        assertEq(out.length, 4);
        assertEq(out[0], 11);
        assertEq(out[1], 22);
        assertEq(out[2], 33);
        assertEq(out[3], 44);
    }

    /// The case the live data cannot show: conviction reorders the base list.
    function testConvictionReordersTheBaseList() public {
        scores.set(44, 900);
        scores.set(22, 500);
        scores.set(11, 100);
        uint256[] memory out = lens.rankedIds();
        assertEq(out[0], 44, "highest score first");
        assertEq(out[1], 22);
        assertEq(out[2], 11);
        assertEq(out[3], 33, "zero score sinks to the bottom");
    }

    /// Equal scores must keep the base list's order rather than shuffling by
    /// whatever the sort happens to do with duplicate keys.
    function testEqualScoresPreserveBaseOrder() public {
        scores.set(11, 700);
        scores.set(22, 700);
        scores.set(33, 700);
        scores.set(44, 700);
        uint256[] memory out = lens.rankedIds();
        assertEq(out[0], 11, "tie keeps source order");
        assertEq(out[1], 22);
        assertEq(out[2], 33);
        assertEq(out[3], 44);
    }

    /// A partial tie must break on source order only among the tied entries.
    function testPartialTieBreaksOnSourceOrder() public {
        scores.set(33, 500);
        scores.set(11, 500);
        scores.set(44, 900);
        uint256[] memory out = lens.rankedIds();
        assertEq(out[0], 44, "clear winner first");
        assertEq(out[1], 11, "tied pair in source order: 11 precedes 33");
        assertEq(out[2], 33);
        assertEq(out[3], 22, "unscored last");
    }

    /// The clamp exists so a malformed score cannot overflow into the 32-bit
    /// tie-breaker and scramble the mapping back to source ids.
    function testAbsurdScoreIsClampedAndStillMapsToTheRightId() public {
        scores.set(22, type(uint256).max);
        scores.set(33, type(uint224).max);
        uint256[] memory out = lens.rankedIds();
        assertEq(out.length, 4, "no entry lost");
        assertEq(out[0], 22, "clamped max still ranks first, source order breaks the tie");
        assertEq(out[1], 33);
        assertEq(out[2], 11);
        assertEq(out[3], 44);
    }

    /// Paging must not revert past the end, and must agree with rankedIds.
    function testPagingBoundsAgreeWithRankedIds() public {
        scores.set(44, 900);
        scores.set(22, 500);
        uint256[] memory all_ = lens.rankedIds();

        uint256[] memory page = lens.rankedIdsPaged(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], all_[0]);
        assertEq(page[1], all_[1]);

        page = lens.rankedIdsPaged(2, 99);
        assertEq(page.length, 2, "count past the end is clipped, not reverted");
        assertEq(page[0], all_[2]);
        assertEq(page[1], all_[3]);

        assertEq(lens.rankedIdsPaged(4, 1).length, 0, "start at the end is empty");
        assertEq(lens.rankedIdsPaged(999, 1).length, 0, "start past the end is empty");
    }

    /// summariesPaged must carry the SAME order, since picker UIs read it
    /// directly instead of rankedIds.
    function testSummariesFollowTheSameOrder() public {
        scores.set(44, 900);
        scores.set(22, 500);
        uint256[] memory ranked = lens.rankedIds();
        ITokenListSource.Summary[] memory s = lens.summariesPaged(0, 4);
        assertEq(s.length, 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(s[i].id, ranked[i], "summary order matches ranked order");
            assertEq(s[i].account, bytes32(ranked[i]), "and carries that id's data");
        }
    }

    /// An empty base list must not revert.
    function testEmptyListIsSafe() public {
        list.setIds(new uint256[](0));
        assertEq(lens.rankedIds().length, 0);
        assertEq(lens.rankedIdsPaged(0, 10).length, 0);
        assertEq(lens.summariesPaged(0, 10).length, 0);
    }

    /// The constructor must refuse addresses with no code, or the lens would
    /// deploy fine and revert on every read.
    function testConstructorRejectsCodelessDependencies() public {
        vm.expectRevert();
        new ZorgTokenListLens(ITokenListSource(address(0xdead)), IConvictionScores(address(scores)));
        vm.expectRevert();
        new ZorgTokenListLens(ITokenListSource(address(list)), IConvictionScores(address(0xdead)));
    }
}
