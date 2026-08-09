// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {FloorboardView} from "../src/FloorboardView.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// @notice The lens over Floorboard's standing bids.
///
/// Two properties matter more than the rest, because both fail QUIETLY:
///
///   1. Direction. Every other book on this stack reads from the buyer's side.
///      A bid is the mirror - whoever acts on it is selling. If `token` and
///      `quote` are swapped anywhere, each row becomes its own reflection,
///      which decodes cleanly and prices the wrong asset in both directions.
///
///   2. `anyId`. An NFT bid with no ids accepts ANY id from the collection.
///      That is the whole point of a floor bid and the reason this lens exists
///      instead of a `SwapboardView` row, which has nowhere to put "any" -
///      id `0` is an ordinary token, so there is no free sentinel.
contract FloorboardViewTest is Test {
    Floorboard board;
    FloorboardView lens;
    MockWETH weth;
    MockERC20 usdc;
    MockERC20 tkn;
    MockNFT nft;

    address bidder = makeAddr("bidder");
    address seller = makeAddr("seller");

    function setUp() public {
        vm.warp(1_800_000_000);
        weth = new MockWETH();
        board = new Floorboard(address(weth));
        usdc = new MockERC20("USDC", 6);
        tkn = new MockERC20("TKN", 18);
        nft = new MockNFT();
        lens = new FloorboardView();

        usdc.mint(bidder, 10_000_000e6);
        vm.prank(bidder);
        usdc.approve(address(board), type(uint256).max);
    }

    function _terms(address token, uint128 want, uint256 start, uint256 end, bool isNFT, uint256[] memory ids)
        internal
        view
        returns (Floorboard.Terms memory)
    {
        return Floorboard.Terms({
            token: token,
            quote: address(usdc),
            want: want,
            startPrice: start,
            endPrice: end,
            startTime: 0,
            duration: 7 days,
            isNFT: isNFT,
            ids: ids
        });
    }

    function _bid(address token, uint128 want, uint256 start, uint256 end, bool isNFT, uint256[] memory ids)
        internal
        returns (uint256 id)
    {
        vm.prank(bidder);
        id = board.bid(_terms(token, want, start, end, isNFT, ids));
    }

    // ------------------------------------------------------------ DIRECTION

    function test_rowReadsFromTheSellersSide() public {
        _bid(address(tkn), 100e18, 1_000e6, 2_000e6, false, new uint256[](0));
        (FloorboardView.BidRow[] memory rows,) = lens.getRecentFloorBids(address(board), 0, 10, 64);

        assertEq(rows.length, 1);
        assertEq(rows[0].token, address(tkn), "token is what the SELLER delivers");
        assertEq(rows[0].quote, address(usdc), "quote is what the SELLER receives");
        assertEq(rows[0].bidder, bidder);
        assertFalse(rows[0].isNFT);
        assertFalse(rows[0].anyId, "a fungible bid is never an any-id bid");
    }

    function test_candidateFilterTakesTokenInAsTheDeliveredAsset() public {
        _bid(address(tkn), 100e18, 1_000e6, 2_000e6, false, new uint256[](0));

        // Selling TKN for USDC: matches.
        (FloorboardView.BidRow[] memory hit,) =
            lens.floorCandidatesFrom(address(board), address(tkn), address(usdc), 0, 10, 64);
        assertEq(hit.length, 1, "seller of TKN finds the bid");

        // The mirror must NOT match: nobody here is bidding for USDC.
        (FloorboardView.BidRow[] memory miss,) =
            lens.floorCandidatesFrom(address(board), address(usdc), address(tkn), 0, 10, 64);
        assertEq(miss.length, 0, "reading the bid backwards must find nothing");
    }

    // ---------------------------------------------------------------- ANY ID

    function test_collectionBidIsMarkedAnyId() public {
        _bid(address(nft), 3, 5_000e6, 9_000e6, true, new uint256[](0));
        (FloorboardView.BidRow[] memory rows,) = lens.getRecentFloorBids(address(board), 0, 10, 64);

        assertTrue(rows[0].isNFT);
        assertTrue(rows[0].anyId, "empty ids means ANY id from the collection");
        assertEq(rows[0].ids.length, 0);
        assertEq(rows[0].remaining, 3, "want is a COUNT on an NFT bid, not an id");
    }

    function test_narrowedBidIsNotAnyIdAndKeepsItsSet() public {
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (7, 9);
        _bid(address(nft), 1, 5_000e6, 9_000e6, true, ids);

        (FloorboardView.BidRow[] memory rows,) = lens.getRecentFloorBids(address(board), 0, 10, 64);
        assertFalse(rows[0].anyId, "a named set is not a collection bid");
        assertEq(rows[0].ids.length, 2);
        assertEq(rows[0].ids[0], 7);
        assertEq(rows[0].ids[1], 9);
        assertEq(rows[0].remaining, 1, "any ONE of the two");
    }

    /// Token id zero is an ordinary id, which is exactly why `anyId` has to be
    /// its own field rather than a sentinel value in an amount.
    function test_idZeroIsNotMistakenForAnyId() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        _bid(address(nft), 1, 5_000e6, 9_000e6, true, ids);

        (FloorboardView.BidRow[] memory rows,) = lens.getRecentFloorBids(address(board), 0, 10, 64);
        assertFalse(rows[0].anyId, "a bid on id 0 is a bid on ONE id");
        assertEq(rows[0].ids.length, 1);
        assertEq(rows[0].ids[0], 0);
    }

    function test_collectionBidsReturnsOnlyAnyIdRows() public {
        uint256[] memory one = new uint256[](1);
        one[0] = 4;
        _bid(address(nft), 1, 5_000e6, 9_000e6, true, one); // narrowed
        uint256 wide = _bid(address(nft), 2, 6_000e6, 9_000e6, true, new uint256[](0)); // collection

        (FloorboardView.BidRow[] memory rows,) =
            lens.collectionBids(address(board), address(nft), address(usdc), 0, 10, 64);
        assertEq(rows.length, 1, "only the collection-wide bid");
        assertEq(rows[0].bidId, wide);
        assertTrue(rows[0].anyId);
    }

    // -------------------------------------------------------------- PRICING

    /// The row must never promise more than the board will pay.
    function test_proceedsMatchWhatTheBoardWouldPay() public {
        uint256 id = _bid(address(tkn), 100e18, 1_000e6, 2_000e6, false, new uint256[](0));
        vm.warp(block.timestamp + 3 days);

        (FloorboardView.BidRow[] memory rows,) = lens.getRecentFloorBids(address(board), 0, 10, 64);
        (, uint256 quoted) = board.quoteHit(id, rows[0].remaining);
        assertEq(rows[0].proceedsForRemaining, quoted, "lens and board agree to the wei");
    }

    function test_bestBidRanksByUnitPriceNotBySize() public {
        // A large bid at a poor unit price, and a small one at a better price.
        _bid(address(tkn), 1_000e18, 1_000e6, 1_000e6, false, new uint256[](0)); // 1 USDC / TKN
        uint256 rich = _bid(address(tkn), 10e18, 500e6, 500e6, false, new uint256[](0)); // 50 USDC / TKN

        FloorboardView.BidRow memory best =
            lens.bestFloorBid(address(board), address(tkn), address(usdc), 64);
        assertEq(best.bidId, rich, "the better unit price wins, not the bigger total");
    }

    // ---------------------------------------------------------- ROBUSTNESS

    function test_closedAndUnopenedBidsAreNotListed() public {
        uint256 open = _bid(address(tkn), 100e18, 1_000e6, 2_000e6, false, new uint256[](0));
        uint256 pulled = _bid(address(tkn), 100e18, 1_000e6, 2_000e6, false, new uint256[](0));
        vm.prank(bidder);
        board.cancel(pulled);

        Floorboard.Terms memory later = _terms(address(tkn), 50e18, 1_000e6, 2_000e6, false, new uint256[](0));
        later.startTime = uint40(block.timestamp + 1 days);
        vm.prank(bidder);
        board.bid(later);

        (FloorboardView.BidRow[] memory rows,) = lens.getRecentFloorBids(address(board), 0, 10, 64);
        assertEq(rows.length, 1, "cancelled and not-yet-open are both excluded");
        assertEq(rows[0].bidId, open);
    }

    function test_codelessBoardReadsAsAnEmptyBookRatherThanReverting() public view {
        (FloorboardView.BidRow[] memory rows, uint256 next) =
            lens.getRecentFloorBids(address(0xdead), 0, 10, 64);
        assertEq(rows.length, 0);
        assertEq(next, 0);
    }

    function test_emptyBoardIsEmpty() public view {
        (FloorboardView.BidRow[] memory rows,) = lens.getRecentFloorBids(address(board), 0, 10, 64);
        assertEq(rows.length, 0);
    }

    function test_metadataComesFromTheBoardSnapshot() public {
        _bid(address(tkn), 100e18, 1_000e6, 2_000e6, false, new uint256[](0));
        (FloorboardView.BidRow[] memory rows,) = lens.getRecentFloorBids(address(board), 0, 10, 64);
        // The board stores decimals + 1, with 0 meaning "never read". Passed
        // through as-is rather than defaulted to 18.
        assertEq(rows[0].tokenDecimals, 19, "TKN: 18 decimals, stored as 19");
        assertEq(rows[0].quoteDecimals, 7, "USDC: 6 decimals, stored as 7");
        assertEq(rows[0].tokenSymbol, "TKN");
        assertEq(rows[0].quoteSymbol, "USDC");
    }
}
