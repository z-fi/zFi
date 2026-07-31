// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/SwapboardView.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH, MockERC721} from "./SwapboardMocks.sol";

contract MockV1Board {
    struct Order {
        address maker;
        bool active;
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
    }

    uint256 public nextOrderId;
    mapping(uint256 => Order) internal orders;

    function add(Order calldata order) external {
        orders[nextOrderId++] = order;
    }

    function getOrders(uint256[] calldata ids) external view returns (Order[] memory out) {
        out = new Order[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            out[i] = orders[ids[i]];
        }
    }
}

/// @dev Burns every unit of gas forwarded to symbol(). A metadata label is
/// presentation-only, so one such listed token must not take down the page.
contract MetadataGasBomb {
    function symbol() external pure returns (string memory) {
        assembly ("memory-safe") {
            for {} 1 {} {}
        }
    }

    function decimals() external pure returns (uint8) {
        return 9;
    }
}

/// The current-v2 path, exercised against a real Swapboard rather than a fork. This is
/// what pins the two hazards the lens exists to handle: the Order struct gained
/// a word, and an expired order stays `active`.
contract SwapboardViewV2Test is Test {
    SwapboardView lens;
    Swapboard board;
    MockERC20 tokenA;
    MockERC20 tokenB;
    address maker = address(0xA11CE);

    function setUp() public {
        lens = new SwapboardView();
        board = new Swapboard(address(new MockWETH()));
        tokenA = new MockERC20("AAA", 18);
        tokenB = new MockERC20("BBB", 6);

        tokenA.mint(maker, 1_000e18);
        vm.prank(maker);
        tokenA.approve(address(board), type(uint256).max);
    }

    function _create(uint256 amtA, uint64 expiry) internal returns (uint256 id) {
        vm.prank(maker);
        id = board.createOrder(address(tokenA), amtA, address(tokenB), 100e6, true, expiry, false, false, address(0));
    }

    function test_readsCurrentV2OrderFieldsCorrectly() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        _create(10e18, exp);

        SwapboardView.OrderView[] memory o = lens.getAllActiveOrders(address(0), address(board));
        assertEq(o.length, 1, "one fillable order");
        assertEq(o[0].maker, maker, "maker");
        assertEq(o[0].tokenA, address(tokenA), "tokenA must not be read out of expiry");
        assertEq(o[0].amountA, 10e18, "amountA");
        assertEq(o[0].tokenB, address(tokenB), "tokenB");
        assertEq(o[0].amountB, 100e6, "amountB");
        assertEq(o[0].expiry, exp, "expiry surfaced");
        assertTrue(o[0].partialFill, "partialFill");
        assertEq(o[0].symbolA, "AAA", "symbolA");
        assertEq(o[0].decimalsB, 6, "decimalsB");
        assertEq(o[0].board, address(board), "board");
    }

    function test_recentDisplayEndpointDecodesCurrentAndLegacyV1() public {
        _create(10e18, 0);
        MockV1Board v1 = new MockV1Board();
        v1.add(
            MockV1Board.Order({
                maker: maker,
                active: true,
                tokenA: address(tokenA),
                amountA: 7e18,
                tokenB: address(tokenB),
                amountB: 70e6
            })
        );

        (SwapboardView.OrderView[] memory current, uint256 currentNext) =
            lens.getRecentOrdersFrom(address(board), true, 0, 10, 10);
        (SwapboardView.OrderView[] memory legacy, uint256 legacyNext) =
            lens.getRecentOrdersFrom(address(v1), false, 0, 10, 10);

        assertEq(current.length, 1, "current row");
        assertEq(current[0].amountA, 10e18, "current decoder");
        assertEq(legacy.length, 1, "legacy row");
        assertEq(legacy[0].amountA, 7e18, "legacy decoder");
        assertEq(currentNext, 0, "current complete");
        assertEq(legacyNext, 0, "legacy complete");
    }

    /// An expired order stays `active` on the board, so a lens that filtered on
    /// `active` alone would list it and the fill would revert.
    function test_expiredOrderIsNotListedAsFillable() public {
        uint64 exp = uint64(block.timestamp + 1 hours);
        uint256 id = _create(10e18, exp);
        _create(5e18, 0); // never expires

        assertTrue(board.isFillableBy(id, address(this)), "fillable before expiry");
        assertEq(lens.getAllActiveOrders(address(0), address(board)).length, 2, "both listed");

        vm.warp(block.timestamp + 2 hours);

        (, bool active,,,,,,,,,) = board.orders(id);
        assertTrue(active, "board still marks the expired order active");
        assertFalse(board.isFillableBy(id, address(this)), "but it is no longer fillable");

        SwapboardView.OrderView[] memory o = lens.getAllActiveOrders(address(0), address(board));
        assertEq(o.length, 1, "expired order dropped from the fillable set");
        assertEq(o[0].amountA, 5e18, "the never-expiring order survives");
    }

    function test_expiredOrdersAreDiscoverableForSweeping() public {
        uint64 exp = uint64(block.timestamp + 1 hours);
        uint256 id = _create(10e18, exp);
        _create(5e18, 0);

        (SwapboardView.OrderView[] memory none,) = lens.getExpiredOrders(address(board), 0, 50, 100);
        assertEq(none.length, 0, "nothing expired yet");

        vm.warp(block.timestamp + 2 hours);

        (SwapboardView.OrderView[] memory gone,) = lens.getExpiredOrders(address(board), 0, 50, 100);
        assertEq(gone.length, 1, "expired order is discoverable");
        assertEq(gone[0].orderId, id, "correct id for cancelExpired");
        assertEq(gone[0].expiry, exp, "expiry surfaced");
    }

    function test_zeroAddressBoardsAreSkipped() public {
        _create(10e18, 0);
        // Both slots empty must not revert on nextOrderId().
        assertEq(lens.getAllActiveOrders(address(0), address(0)).length, 0, "all skipped");
        assertEq(lens.getAllActiveOrders(address(0), address(board)).length, 1, "current v2 only");
    }

    /// A codeless address is not address(0), so it passed the zero check and
    /// then reverted: a high-level call to an address with no code returns empty
    /// returndata, which fails to decode as uint256. That took the whole
    /// multi-board read down, including the live board in the other slot. This
    /// is the address zSwap.html ships as a placeholder for this very board.
    function test_codelessBoardsAreSkipped() public {
        address placeholder = 0x00000000000000000000000000000000000B0a2d;
        assertEq(placeholder.code.length, 0, "fixture must be codeless");
        _create(10e18, 0);

        // The live board must survive a codeless address in the other slot.
        assertEq(lens.getAllActiveOrders(placeholder, address(board)).length, 1, "v1 slot codeless");
        assertEq(lens.getAllActiveOrders(address(0), placeholder).length, 0, "v2 slot codeless");
        assertEq(lens.getAllActiveOrders(placeholder, placeholder).length, 0, "both codeless");

        (,, SwapboardView.OrderView[] memory paged,) =
            lens.getAllActiveOrdersPaged(placeholder, address(board), 0, 0, 10, 100);
        assertEq(paged.length, 1, "paged path skips too");

        // getRecentOrders reaches nextOrderId by a different route (_scanDown).
        (SwapboardView.OrderView[] memory recent, uint256 cursor) = lens.getRecentOrders(placeholder, 0, 10, 100);
        assertEq(recent.length, 0, "recent path skips too");
        assertEq(cursor, 0, "no further pages on a codeless board");
    }

    function test_pagedReadAcceptsZeroLimitAndZeroScan() public {
        _create(1e18, 0);
        (,, SwapboardView.OrderView[] memory noLimit, uint256 noLimitCursor) =
            lens.getAllActiveOrdersPaged(address(0), address(board), 0, 0, 0, 10);
        assertEq(noLimit.length, 0);
        assertEq(noLimitCursor, 0);

        (,, SwapboardView.OrderView[] memory noScan, uint256 noScanCursor) =
            lens.getAllActiveOrdersPaged(address(0), address(board), 0, 0, 10, 0);
        assertEq(noScan.length, 0);
        assertEq(noScanCursor, 0);
    }

    function test_metadataIsAppliedToBothSidesWhenTheyShareAToken() public {
        MockERC721 nft = new MockERC721();
        nft.mint(maker, 1);
        nft.mint(maker, 2);
        vm.prank(maker);
        nft.setApprovalForAll(address(board), true);
        vm.prank(maker);
        board.createOrder(address(nft), 1, address(nft), 2, false, 0, true, true, address(0));

        SwapboardView.OrderView[] memory o = lens.getAllActiveOrders(address(0), address(board));
        assertEq(o.length, 1);
        assertEq(o[0].symbolA, "NFT");
        assertEq(o[0].symbolB, "NFT", "metadata must cover tokenB too");
        assertEq(o[0].decimalsA, 18);
        assertEq(o[0].decimalsB, 18);
    }

    function test_hostileMetadataCannotTakeDownTheOrderPage() public {
        MetadataGasBomb bomb = new MetadataGasBomb();
        vm.prank(maker);
        board.createOrder(address(tokenA), 1e18, address(bomb), 1, false, 0, false, false, address(0));

        SwapboardView.OrderView[] memory o = lens.getAllActiveOrders(address(0), address(board));
        assertEq(o.length, 1, "the order survives broken presentation metadata");
        assertEq(o[0].symbolB, "", "failed symbol falls back to blank");
        assertEq(o[0].decimalsB, 9, "the independent decimals read still succeeds");
    }

    /// A window holding more matches than `limit` must not advance the cursor
    /// past the ones that did not fit — they would never be revisited and the
    /// book would silently lose rows.
    function test_pagingLosesNoOrdersWhenWindowOverflows() public {
        for (uint256 i; i < 10; ++i) {
            _create(1e18, 0);
        }

        // Descending scan: limit 3, window 10 — every page overflows.
        bool[] memory seen = new bool[](10);
        uint256 cursor;
        uint256 rows;
        for (uint256 guard; guard < 20; ++guard) {
            (SwapboardView.OrderView[] memory page, uint256 next) = lens.getRecentOrders(address(board), cursor, 3, 10);
            for (uint256 i; i < page.length; ++i) {
                assertFalse(seen[page[i].orderId], "order returned twice");
                seen[page[i].orderId] = true;
                ++rows;
            }
            if (next == 0) break;
            cursor = next;
        }
        assertEq(rows, 10, "every order surfaced exactly once");

        // Ascending paged scan, same property.
        bool[] memory seen2 = new bool[](10);
        uint256 start;
        uint256 rows2;
        for (uint256 guard; guard < 20; ++guard) {
            (,, SwapboardView.OrderView[] memory page, uint256 next) =
                lens.getAllActiveOrdersPaged(address(0), address(board), 0, start, 3, 10);
            for (uint256 i; i < page.length; ++i) {
                assertFalse(seen2[page[i].orderId], "order returned twice");
                seen2[page[i].orderId] = true;
                ++rows2;
            }
            if (next == 0) break;
            start = next;
        }
        assertEq(rows2, 10, "every order surfaced exactly once");
    }

    function test_pagedCurrentV2RespectsLimitAndCursor() public {
        for (uint256 i; i < 5; ++i) {
            _create(1e18, 0);
        }
        (,, SwapboardView.OrderView[] memory v2, uint256 next) =
            lens.getAllActiveOrdersPaged(address(0), address(board), 0, 0, 2, 3);
        assertEq(v2.length, 2, "limit honoured");
        // The window scanned ids 0-2 and matched all three, but only two fit.
        // The cursor must resume at the unreturned id 2, NOT jump to the end of
        // the scanned window at 3 — that would drop order 2 permanently.
        assertEq(next, 2, "cursor resumes at the first order that did not fit");
    }

    // ---- newest-first scanning ----

    function _createIn(MockERC20 ta, MockERC20 tb, uint256 amtA) internal returns (uint256 id) {
        ta.mint(maker, amtA);
        vm.prank(maker);
        ta.approve(address(board), type(uint256).max);
        vm.prank(maker);
        id = board.createOrder(address(ta), amtA, address(tb), 100e6, true, 0, false, false, address(0));
    }

    function test_recentOrdersComeBackNewestFirst() public {
        _create(1e18, 0);
        _create(2e18, 0);
        uint256 last = _create(3e18, 0);

        (SwapboardView.OrderView[] memory o, uint256 next) = lens.getRecentOrders(address(board), 0, 10, 10);
        assertEq(o.length, 3);
        assertEq(o[0].orderId, last, "newest first");
        assertEq(o[0].amountA, 3e18);
        assertEq(o[2].amountA, 1e18, "oldest last");
        assertEq(next, 0, "cursor exhausted");
    }

    /// A window bounds the ids inspected, not the rows returned. A churned book
    /// yields empty windows, and the cursor must still advance or a scroll stalls.
    function test_emptyWindowStillAdvancesCursor() public {
        uint256 dead1 = _create(1e18, 0);
        uint256 dead2 = _create(2e18, 0);
        _create(3e18, 0); // only this one stays live
        vm.startPrank(maker);
        board.cancelOrder(dead1);
        board.cancelOrder(dead2);
        vm.stopPrank();

        // scan the newest id only -> one row, cursor moves down to 2
        (SwapboardView.OrderView[] memory a, uint256 c1) = lens.getRecentOrders(address(board), 0, 10, 1);
        assertEq(a.length, 1, "newest is live");
        assertEq(c1, 2, "cursor advanced");

        // next window covers the two cancelled ids -> empty, cursor reaches 0
        (SwapboardView.OrderView[] memory b, uint256 c2) = lens.getRecentOrders(address(board), c1, 10, 2);
        assertEq(b.length, 0, "window legitimately empty");
        assertEq(c2, 0, "but the walk completed");
    }

    function test_cursorWalksTheWholeBook() public {
        for (uint256 i; i < 7; ++i) {
            _create((i + 1) * 1e18, 0);
        }
        uint256 cursor;
        uint256 seen;
        for (uint256 pass; pass < 10; ++pass) {
            (SwapboardView.OrderView[] memory o, uint256 next) = lens.getRecentOrders(address(board), cursor, 10, 2);
            seen += o.length;
            cursor = next;
            if (cursor == 0) break;
        }
        assertEq(seen, 7, "every order visited exactly once across windows");
    }

    // ---- pair filtering ----

    function test_pairFilterIsUnorderedAndExcludesOtherMarkets() public {
        MockERC20 tokenC = new MockERC20("CCC", 18);
        _create(1e18, 0); // A -> B
        _createIn(tokenB, tokenA, 5e18); // B -> A, the other side of the market
        _createIn(tokenC, tokenB, 9e18); // C -> B, a different market

        (SwapboardView.OrderView[] memory o,) =
            lens.getOrdersForPair(address(board), address(tokenA), address(tokenB), 0, 10, 10);
        assertEq(o.length, 2, "both sides of A/B, and nothing from C/B");

        (SwapboardView.OrderView[] memory c,) =
            lens.getOrdersForPair(address(board), address(tokenC), address(0), 0, 10, 10);
        assertEq(c.length, 1, "wildcard: every order touching C");
        assertEq(c[0].amountA, 9e18);
    }

    function test_noFilterMatchesEverything() public {
        _create(1e18, 0);
        _create(2e18, 0);
        (SwapboardView.OrderView[] memory o,) = lens.getOrdersForPair(address(board), address(0), address(0), 0, 10, 10);
        assertEq(o.length, 2);
    }

    function test_sameTokenMarketIsNeverAHybridCandidate() public {
        // Live boards reject fungible same-token orders, but the lens accepts a
        // caller-supplied legacy address. Keep that malformed market out at the
        // common candidate gate rather than trusting every decoder target.
        MockV1Board v1 = new MockV1Board();
        v1.add(
            MockV1Board.Order({
                maker: maker,
                active: true,
                tokenA: address(tokenA),
                amountA: 2e18,
                tokenB: address(tokenA),
                amountB: 1e18
            })
        );

        (SwapboardView.OrderView[] memory rows,) =
            lens.candidatesFrom(address(v1), false, address(tokenA), address(tokenA), address(this), 0, 10);
        assertEq(rows.length, 0, "same-token candidate must be rejected");

        (SwapboardView.Fill[] memory fills,,,, bool worthwhile) =
            lens.planHybrid(address(v1), address(0), address(tokenA), address(tokenA), 1e18, address(this), 0, 0);
        assertEq(fills.length, 0, "same-token plan must remain empty");
        assertFalse(worthwhile);
    }

    // ---- the boundary that must match the board exactly ----

    /// The board expires an order strictly AFTER `expiry`, so at exactly that
    /// timestamp it is still fillable. A lens using >= would hide a live order
    /// and offer a sweep that reverts.
    function test_orderIsStillListedAtExactlyItsExpiry() public {
        uint64 exp = uint64(block.timestamp + 1 hours);
        uint256 id = _create(1e18, exp);
        vm.warp(exp);

        assertTrue(board.isFillableBy(id, address(this)), "board says fillable at expiry");
        (SwapboardView.OrderView[] memory o,) = lens.getRecentOrders(address(board), 0, 10, 10);
        assertEq(o.length, 1, "lens must agree with the board");

        (SwapboardView.OrderView[] memory sweepable,) = lens.getExpiredOrders(address(board), 0, 10, 10);
        assertEq(sweepable.length, 0, "and must not offer a sweep that would revert");

        vm.warp(exp + 1);
        (SwapboardView.OrderView[] memory o2,) = lens.getRecentOrders(address(board), 0, 10, 10);
        assertEq(o2.length, 0, "one second later it is gone");
        (SwapboardView.OrderView[] memory s2,) = lens.getExpiredOrders(address(board), 0, 10, 10);
        assertEq(s2.length, 1, "and is now sweepable");
    }

    // ------------------------------------------------------- hybrid scanning

    /// A resting order does not get worse with age. Slicing the scan by id
    /// makes the planner newest-N rather than best-N, so the keenest price in
    /// the book disappears the moment enough orders are placed after it - which
    /// is exactly what a good limit order invites.
    function test_TheBestPriceIsFoundHoweverLongItHasRested() public {
        uint256 buried = _create(200e18, 0); // 2.0 per unit, placed first
        for (uint256 i; i < 40; ++i) {
            _create(10e18, 0); // 0.1 per unit, worse than the AMM
        }

        // AMM pays 0.5 per unit for the whole size, so only `buried` beats it.
        uint256 amountIn = 100e6;
        uint256 baseline = 50e18;

        (SwapboardView.Fill[] memory f,,,, bool worthwhile) = lens.planHybrid(
            address(0), address(board), address(tokenB), address(tokenA), amountIn, address(this), baseline, 0
        );
        assertEq(f.length, 1, "the full scan reaches it");
        assertEq(f[0].orderId, buried);
        assertEq(f[0].board, address(board), "and names the board it settles on");
        assertTrue(worthwhile);

        // Capped to the newest 10 ids, it is invisible: the cap is a work
        // bound, not a free optimisation.
        (SwapboardView.Fill[] memory g,,,, bool w2) = lens.planHybrid(
            address(0), address(board), address(tokenB), address(tokenA), amountIn, address(this), baseline, 10
        );
        assertEq(g.length, 0, "capped scan never sees it");
        assertFalse(w2);
    }

    /// Orders reserved for someone else are not routable, whatever they pay.
    function test_PrivateOrdersForOthersAreNotPlanned() public {
        vm.prank(maker);
        board.createOrder(address(tokenA), 200e18, address(tokenB), 100e6, true, 0, false, false, address(0xDEAD));
        (SwapboardView.Fill[] memory f,,,,) = lens.planHybrid(
            address(0), address(board), address(tokenB), address(tokenA), 100e6, address(this), 50e18, 0
        );
        assertEq(f.length, 0, "not this taker's to fill");
    }

    /// The same order, once it is addressed to the taker asking.
    function test_PrivateOrdersForThisTakerArePlanned() public {
        vm.prank(maker);
        uint256 id =
            board.createOrder(address(tokenA), 200e18, address(tokenB), 100e6, true, 0, false, false, address(this));
        (SwapboardView.Fill[] memory f,,,,) = lens.planHybrid(
            address(0), address(board), address(tokenB), address(tokenA), 100e6, address(this), 50e18, 0
        );
        assertEq(f.length, 1);
        assertEq(f[0].orderId, id);
    }

    function test_candidatesFromResumesAtTheFirstUnseenCandidate() public {
        MockERC20 tokenC = new MockERC20("CCC", 18);
        // Lower ids: 256 usable candidates.
        for (uint256 i; i < 256; ++i) {
            _create(1e18, 0);
        }
        // Higher ids: 255 unrelated entries, then one usable candidate. The
        // 256-entry result fills part-way through the lower scan window.
        for (uint256 i; i < 255; ++i) {
            _createIn(tokenC, tokenB, 1e18);
        }
        _create(1e18, 0);

        (SwapboardView.OrderView[] memory first, uint256 cursor) =
            lens.candidatesFrom(address(board), true, address(tokenB), address(tokenA), address(this), 0, 512);
        assertEq(first.length, 256);
        assertEq(cursor, 1, "id 0 has not been inspected yet");

        (SwapboardView.OrderView[] memory last, uint256 done) =
            lens.candidatesFrom(address(board), true, address(tokenB), address(tokenA), address(this), cursor, 512);
        assertEq(last.length, 1, "the formerly skipped candidate is returned");
        assertEq(last[0].orderId, 0);
        assertEq(done, 0);
    }

    function test_plannerIncludesV1WhenV2HasCandidateDepth() public {
        MockV1Board v1 = new MockV1Board();
        v1.add(
            MockV1Board.Order({
                maker: maker,
                active: true,
                tokenA: address(tokenA),
                amountA: 200e18,
                tokenB: address(tokenB),
                amountB: 100e6
            })
        );
        // These are all fillable but much worse than the V1 order.
        for (uint256 i; i < 256; ++i) {
            _create(1e18, 0);
        }

        SwapboardView.OrderView[] memory c =
            lens.candidates(address(v1), address(board), address(tokenB), address(tokenA), address(this), 0);
        bool foundV1;
        for (uint256 i; i < c.length; ++i) {
            if (c[i].board == address(v1)) foundV1 = true;
        }
        assertTrue(foundV1, "the candidate cap cannot erase V1 liquidity");
    }

    function test_oversizedAonOrdersCannotCrowdAUsableCandidateOutOfAPlan() public {
        tokenA.mint(maker, 60_000e18);

        vm.prank(maker);
        uint256 usable =
            board.createOrder(address(tokenA), 100e18, address(tokenB), 100e6, true, 0, false, false, address(0));
        // All 256 newer orders have a better headline rate, but each asks for
        // more input than this trade contains and is all-or-nothing. Before the
        // fit filter they occupied the entire candidate set and erased `usable`.
        for (uint256 i; i < 256; ++i) {
            vm.prank(maker);
            board.createOrder(address(tokenA), 202e18, address(tokenB), 101e6, false, 0, false, false, address(0));
        }

        (SwapboardView.Fill[] memory fills,,,, bool worthwhile) = lens.planHybrid(
            address(0), address(board), address(tokenB), address(tokenA), 100e6, address(this), 50e18, 0
        );
        assertEq(fills.length, 1, "the fitting order must survive candidate retention");
        assertEq(fills[0].orderId, usable);
        assertTrue(worthwhile);
    }

    function test_exactOutOverdeliveryDoesNotMakeAnEqualCostFillWorthwhile() public {
        vm.prank(maker);
        board.createOrder(address(tokenA), 2, address(tokenB), 1, true, 0, false, false, address(0));

        (SwapboardView.Fill[] memory fills, uint256 bookOut, uint256 bookIn, uint256 ammOut, bool worthwhile) =
            lens.planHybridOut(address(0), address(board), address(tokenB), address(tokenA), 1, address(this), 1, 0);

        assertEq(fills.length, 1);
        assertEq(bookOut, 2, "one payable input unit buys the whole remainder");
        assertEq(bookIn, 1, "actual spend equals the AMM baseline");
        assertEq(ammOut, 0);
        assertFalse(worthwhile, "overdelivery cannot turn equal spend into an undercut");
    }

    function test_plannedSwapboardLegExecutesForTheReportedAmounts() public {
        vm.prank(maker);
        board.createOrder(address(tokenA), 200e18, address(tokenB), 100e6, true, 0, false, false, address(0));

        (SwapboardView.Fill[] memory fills, uint256 bookIn, uint256 bookOut,, bool worthwhile) =
            lens.planHybrid(address(0), address(board), address(tokenB), address(tokenA), 50e6, address(this), 20e18, 0);
        assertEq(fills.length, 1);
        assertTrue(worthwhile);

        tokenB.mint(address(this), fills[0].payIn);
        tokenB.approve(address(board), fills[0].payIn);
        board.fillOrder(fills[0].orderId, block.timestamp, fills[0].payIn, 0, address(this));

        assertEq(tokenB.balanceOf(maker), bookIn, "maker receives the reported input");
        assertEq(tokenA.balanceOf(address(this)), bookOut, "taker receives the reported output");
        assertEq(bookIn, fills[0].payIn);
        assertEq(bookOut, fills[0].getOut);
    }
}

/// v1, read live. It holds real escrow and stays fillable, so the lens must keep
/// decoding it alongside v2.
contract SwapboardViewLegacyTest is Test {
    SwapboardView lens;
    address constant SWAPBOARD_V1 = 0x000000fF3D7A2d373615141d7489Ca66683DbecF;

    function setUp() public {
        // Latest-block reads, so no archive node needed. These scan whole books
        // and issue thousands of storage reads, which the archive gateway used
        // elsewhere resets the connection on.
        vm.createSelectFork(vm.envOr("MAINNET_RPC", string("https://ethereum.publicnode.com")));
        lens = new SwapboardView();
    }

    function test_getAllActiveOrders() public {
        // Explicit gas to mirror a real eth_call budget (30M+).
        (bool ok, bytes memory data) = address(lens).staticcall{gas: 20_000_000}(
            abi.encodeCall(lens.getAllActiveOrders, (SWAPBOARD_V1, address(0)))
        );
        assertTrue(ok, "staticcall should succeed");
        SwapboardView.OrderView[] memory orders = abi.decode(data, (SwapboardView.OrderView[]));
        for (uint256 i; i < orders.length; ++i) {
            assertTrue(orders[i].maker != address(0));
            assertTrue(orders[i].tokenA != address(0));
            assertTrue(orders[i].tokenB != address(0));
            assertTrue(orders[i].decimalsA > 0);
            assertTrue(orders[i].decimalsB > 0);
            // v1 has no expiry field to read.
            assertEq(orders[i].expiry, 0, "v1 orders never carry an expiry");
            if (orders[i].board == SWAPBOARD_V1) assertFalse(orders[i].partialFill);
        }
    }

    function test_getAllActiveOrdersPaged() public {
        (bool ok, bytes memory data) = address(lens).staticcall{gas: 20_000_000}(
            abi.encodeCall(lens.getAllActiveOrdersPaged, (SWAPBOARD_V1, address(0), 0, 0, 5, 100))
        );
        assertTrue(ok, "staticcall should succeed");
        (SwapboardView.OrderView[] memory v1Orders,, SwapboardView.OrderView[] memory v2Orders,) =
            abi.decode(data, (SwapboardView.OrderView[], uint256, SwapboardView.OrderView[], uint256));
        assertTrue(v1Orders.length <= 5);
        assertEq(v2Orders.length, 0, "no v2 board passed");
        for (uint256 i; i < v1Orders.length; ++i) {
            assertEq(v1Orders[i].board, SWAPBOARD_V1);
            assertFalse(v1Orders[i].partialFill);
            assertTrue(bytes(v1Orders[i].symbolA).length > 0);
        }
    }
}
