// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/SwapboardView.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

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
