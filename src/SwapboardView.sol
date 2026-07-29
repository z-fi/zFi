// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title SwapboardView
/// @notice Read-only helper that merges active orders from both Swapboard
///         contracts into one array, with token metadata, in a single call.
///
/// THE TWO BOARDS
///   v1 — the original board. All-or-nothing fills. Order is 6 static fields.
///   v2 — the current board: partial fills plus a maker-side expiry. This is the
///        only board the UI creates orders on. Order is 8 static fields.
///
/// WHY ONE INTERFACE PER BOARD
///   v2 appended fields to Order, and every field is static, so getOrders returns
///   a flat sequence of words whose width differs per board — 6 against 8 per
///   order. Decoding one with the other's struct does not fail loudly: it shifts
///   every field, so tokenA would be read out of an adjacent word and the caller
///   gets plausible-looking garbage. Each board therefore gets its own interface
///   and its own converter, and the caller states which address is which rather
///   than the lens guessing.
///
/// ACTIVE IS NOT FILLABLE
///   On v2 an order stays `active` after it expires, until someone sweeps it with
///   cancelExpired. Filtering on `active` alone would list orders whose fills
///   revert with OrderExpired. getAllActiveOrders therefore returns only fillable
///   orders — active and not expired — while getExpiredOrders returns the
///   sweepable ones, so escrow sitting behind an absent maker stays discoverable
///   instead of being hidden by the same filter that protects takers.
///
/// COMPOSING WITH v1
///   v1 is not migrated. Its resting orders are real escrow that anyone can still
///   take and its makers can still cancel, so the UI routes all creation to v2
///   while continuing to discover and fill everything already resting on v1.
///   Dropping v1 from the lens would not retire it, it would only hide it from
///   the one UI positioned to clear it.
///
///   Either board may be passed as address(0) to skip it, which lets a caller
///   that wants only the current book ask for exactly that.
///
/// @dev Intended for `eth_call` only — not meant to be called on-chain in
///      transactions. The unpaged scans are unbounded by design; use the paged
///      variants against large books.
contract SwapboardView {
    enum Board {
        V1, // all-or-nothing
        V2 // partialFill + expiry
    }

    struct OrderView {
        uint256 orderId;
        address maker;
        bool partialFill; // always false on v1
        uint64 expiry; // 0 = never expires; always 0 on v1
        bool nftA; // amountA is a tokenId; always false on v1
        bool nftB; // amountB is a tokenId; always false on v1
        address counterparty; // 0 = public; always 0 on v1
        address tokenA;
        uint256 amountA;
        string symbolA;
        uint8 decimalsA;
        address tokenB;
        uint256 amountB;
        string symbolB;
        uint8 decimalsB;
        address board;
    }

    /// @notice All fillable orders across both boards, merged.
    /// @param boardV1 Original all-or-nothing board. address(0) to skip.
    /// @param boardV2 Current board (partialFill + expiry). address(0) to skip.
    function getAllActiveOrders(address boardV1, address boardV2) external view returns (OrderView[] memory) {
        OrderView[] memory a = _readBoard(boardV1, Board.V1);
        OrderView[] memory b = _readBoard(boardV2, Board.V2);

        OrderView[] memory merged = new OrderView[](a.length + b.length);
        uint256 k;
        for (uint256 i; i < a.length; ++i) {
            merged[k++] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            merged[k++] = b[i];
        }
        return merged;
    }

    /// @notice Paginated read across both boards. Each is scanned independently,
    ///         so each carries its own cursor.
    function getAllActiveOrdersPaged(
        address boardV1,
        address boardV2,
        uint256 startIdV1,
        uint256 startIdV2,
        uint256 limit,
        uint256 maxScan
    )
        external
        view
        returns (OrderView[] memory ordersV1, uint256 nextStartV1, OrderView[] memory ordersV2, uint256 nextStartV2)
    {
        (ordersV1, nextStartV1) = _readBoardPaged(boardV1, Board.V1, startIdV1, limit, maxScan, false);
        (ordersV2, nextStartV2) = _readBoardPaged(boardV2, Board.V2, startIdV2, limit, maxScan, false);
    }

    /// @notice Expired-but-unswept orders on v2 — the set cancelExpired can
    ///         clear. Deliberately absent from getAllActiveOrders because
    ///         filling one reverts.
    function getExpiredOrders(address boardV2, uint256 startId, uint256 limit, uint256 maxScan)
        external
        view
        returns (OrderView[] memory orders, uint256 nextStart)
    {
        (orders, nextStart) = _readBoardPaged(boardV2, Board.V2, startId, limit, maxScan, true);
    }

    /// @notice Newest-first page of fillable orders. Pass cursor 0 to start at
    ///         the newest order; keep passing the returned cursor until it comes
    ///         back 0. Low ids are overwhelmingly filled or cancelled, so an
    ///         ascending scan spends its first pages on dead weight - this puts
    ///         live orders on the first screen.
    /// @dev `maxScan` bounds the ids inspected, NOT the rows returned: a window
    ///      can legitimately come back empty while the cursor advances. Callers
    ///      driving an infinite scroll should keep fetching until they have
    ///      enough rows or the cursor reaches 0, rather than one call per
    ///      scroll event. Windows are independent, so they can run concurrently.
    /// @param boardV2 v2 ONLY. This decodes 8-field orders; handing it the v1
    ///        board would misread 6-field ones as plausible garbage rather than
    ///        revert. v1 is a closed book with no new orders, so newest-first
    ///        paging is a v2 concern and it is named to say so.
    function getRecentOrders(address boardV2, uint256 cursor, uint256 limit, uint256 maxScan)
        external
        view
        returns (OrderView[] memory orders, uint256 nextCursor)
    {
        return _scanDown(boardV2, cursor, limit, maxScan, address(0), address(0));
    }

    /// @notice Newest-first page restricted to one market. The scan still walks
    ///         the same ids - reads are free - but only matches are returned, so
    ///         the payload stays small on a crowded book. Unordered: both sides
    ///         of the market come back. Pass tokenB = address(0) for every order
    ///         touching tokenA.
    /// @param boardV2 v2 ONLY, for the same decoding reason as getRecentOrders.
    function getOrdersForPair(
        address boardV2,
        address tokenA,
        address tokenB,
        uint256 cursor,
        uint256 limit,
        uint256 maxScan
    ) external view returns (OrderView[] memory orders, uint256 nextCursor) {
        return _scanDown(boardV2, cursor, limit, maxScan, tokenA, tokenB);
    }

    // ---- Internal ----

    /// @dev Walks ids downward from `cursor` (exclusive). Returns the exclusive
    /// upper bound for the next window, or 0 when id 0 has been reached.
    function _scanDown(address board, uint256 cursor, uint256 limit, uint256 maxScan, address ta, address tb)
        internal
        view
        returns (OrderView[] memory orders, uint256 nextCursor)
    {
        if (board == address(0) || limit == 0 || maxScan == 0) return (new OrderView[](0), 0);
        uint256 total = ISwapboardV2(board).nextOrderId();
        uint256 hi = cursor == 0 || cursor > total ? total : cursor;
        if (hi == 0) return (new OrderView[](0), 0);

        uint256 lo = hi > maxScan ? hi - maxScan : 0;
        uint256 n = hi - lo;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = hi - 1 - i; // newest first
        }

        OrderView[] memory all = _fetch(board, Board.V2, ids, false, ta, tb);
        if (all.length > limit) {
            orders = new OrderView[](limit);
            for (uint256 i; i < limit; ++i) {
                orders[i] = all[i];
            }
            // The window held more matches than fit. Resuming at `lo` would step
            // over the ones that did not fit and lose them for good, so resume
            // just below the last row actually returned. Ids descend, so that id
            // is the next exclusive upper bound.
            nextCursor = orders[limit - 1].orderId;
        } else {
            orders = all;
            nextCursor = lo;
        }
        orders = _withMeta(orders);
    }

    function _nextOrderId(address board, Board v) internal view returns (uint256) {
        if (v == Board.V1) return ISwapboardV1(board).nextOrderId();
        return ISwapboardV2(board).nextOrderId();
    }

    function _readBoard(address board, Board v) internal view returns (OrderView[] memory) {
        if (board == address(0)) return new OrderView[](0);
        uint256 total = _nextOrderId(board, v);
        if (total == 0) return new OrderView[](0);

        uint256[] memory allIds = new uint256[](total);
        for (uint256 i; i < total; ++i) {
            allIds[i] = i;
        }
        return _withMeta(_fetch(board, v, allIds, false, address(0), address(0)));
    }

    function _readBoardPaged(address board, Board v, uint256 startId, uint256 limit, uint256 maxScan, bool wantExpired)
        internal
        view
        returns (OrderView[] memory orders, uint256 nextStart)
    {
        if (board == address(0)) return (new OrderView[](0), 0);
        uint256 total = _nextOrderId(board, v);
        if (startId >= total) return (new OrderView[](0), 0);

        uint256 end = startId + maxScan;
        if (end > total) end = total;
        uint256 scanLen = end - startId;

        uint256[] memory ids = new uint256[](scanLen);
        for (uint256 i; i < scanLen; ++i) {
            ids[i] = startId + i;
        }

        OrderView[] memory all = _fetch(board, v, ids, wantExpired, address(0), address(0));
        if (all.length > limit) {
            orders = new OrderView[](limit);
            for (uint256 i; i < limit; ++i) {
                orders[i] = all[i];
            }
            // Truncated: resume at the id after the last row returned, or the
            // matches that did not fit in this window would never be revisited.
            // Ids ascend here, so this is always non-zero and cannot be mistaken
            // for the "no more pages" sentinel.
            nextStart = orders[limit - 1].orderId + 1;
        } else {
            orders = all;
            nextStart = end < total ? end : 0;
        }
        orders = _withMeta(orders);
    }

    /// @dev Reads one board with the interface matching its Order width and
    /// converts to the common view shape. `wantExpired` selects between the
    /// fillable set and the sweepable set; only v2 has the latter.
    function _fetch(address board, Board v, uint256[] memory ids, bool wantExpired, address ta, address tb)
        internal
        view
        returns (OrderView[] memory out)
    {
        if (v == Board.V1) {
            if (wantExpired) return new OrderView[](0); // no expiry on v1
            ISwapboardV1.Order[] memory raw = ISwapboardV1(board).getOrders(ids);
            uint256 n;
            for (uint256 i; i < raw.length; ++i) {
                if (raw[i].active && _pairMatch(raw[i].tokenA, raw[i].tokenB, ta, tb)) ++n;
            }
            out = new OrderView[](n);
            uint256 k;
            for (uint256 i; i < raw.length; ++i) {
                if (!raw[i].active) continue;
                if (!_pairMatch(raw[i].tokenA, raw[i].tokenB, ta, tb)) continue;
                out[k].orderId = ids[i];
                out[k].maker = raw[i].maker;
                out[k].tokenA = raw[i].tokenA;
                out[k].amountA = raw[i].amountA;
                out[k].tokenB = raw[i].tokenB;
                out[k].amountB = raw[i].amountB;
                out[k].board = board;
                ++k;
            }
        } else {
            ISwapboardV2.Order[] memory raw = ISwapboardV2(board).getOrders(ids);
            uint256 n;
            for (uint256 i; i < raw.length; ++i) {
                if (
                    raw[i].active && _isExpired(raw[i].expiry) == wantExpired
                        && _pairMatch(raw[i].tokenA, raw[i].tokenB, ta, tb)
                ) ++n;
            }
            out = new OrderView[](n);
            uint256 k;
            for (uint256 i; i < raw.length; ++i) {
                if (!raw[i].active) continue;
                if (_isExpired(raw[i].expiry) != wantExpired) continue;
                if (!_pairMatch(raw[i].tokenA, raw[i].tokenB, ta, tb)) continue;
                out[k].orderId = ids[i];
                out[k].maker = raw[i].maker;
                out[k].partialFill = raw[i].partialFill;
                out[k].expiry = raw[i].expiry;
                out[k].nftA = raw[i].nftA;
                out[k].nftB = raw[i].nftB;
                out[k].counterparty = raw[i].counterparty;
                out[k].tokenA = raw[i].tokenA;
                out[k].amountA = raw[i].amountA;
                out[k].tokenB = raw[i].tokenB;
                out[k].amountB = raw[i].amountB;
                out[k].board = board;
                ++k;
            }
        }
    }

    /// @dev Must mirror Swapboard exactly: 0 never expires, and an order is
    /// live AT its expiry (strictly greater, not >=). A mismatch here would
    /// hide a fillable order, or offer a sweep that reverts.
    function _isExpired(uint64 expiry) internal view returns (bool) {
        return expiry != 0 && block.timestamp > expiry;
    }

    /// @dev Unordered match, so one query returns both sides of a market: an
    /// order selling A for B and one selling B for A both count. A zero token
    /// is a wildcard, so (A, 0) means "every order touching A" and (0, 0) is
    /// no filter at all.
    function _pairMatch(address oa, address ob, address ta, address tb) internal pure returns (bool) {
        if (ta == address(0) && tb == address(0)) return true;
        if (tb == address(0)) return oa == ta || ob == ta;
        if (ta == address(0)) return oa == tb || ob == tb;
        return (oa == ta && ob == tb) || (oa == tb && ob == ta);
    }

    // ---- Token metadata ----

    /// @dev One metadata read per distinct token rather than per order leg, then
    /// applied back. Books concentrate in a handful of tokens, so this is what
    /// keeps the single-call read affordable.
    function _withMeta(OrderView[] memory views) internal view returns (OrderView[] memory) {
        (address[] memory tokens, uint256 count) = _uniqueTokens(views);
        (string[] memory symbols, uint8[] memory decs) = _batchMeta(tokens, count);
        for (uint256 i; i < views.length; ++i) {
            _applyMeta(views[i], tokens, symbols, decs, count);
        }
        return views;
    }

    function _uniqueTokens(OrderView[] memory views) internal pure returns (address[] memory tokens, uint256 count) {
        tokens = new address[](views.length * 2);
        for (uint256 i; i < views.length; ++i) {
            if (!_contains(tokens, count, views[i].tokenA)) tokens[count++] = views[i].tokenA;
            if (!_contains(tokens, count, views[i].tokenB)) tokens[count++] = views[i].tokenB;
        }
    }

    function _contains(address[] memory arr, uint256 len, address val) internal pure returns (bool) {
        for (uint256 i; i < len; ++i) {
            if (arr[i] == val) return true;
        }
        return false;
    }

    function _batchMeta(address[] memory tokens, uint256 count)
        internal
        view
        returns (string[] memory symbols, uint8[] memory decs)
    {
        symbols = new string[](count);
        decs = new uint8[](count);
        for (uint256 i; i < count; ++i) {
            (symbols[i], decs[i]) = _tokenMeta(tokens[i]);
        }
    }

    function _applyMeta(
        OrderView memory o,
        address[] memory tokens,
        string[] memory symbols,
        uint8[] memory decs,
        uint256 count
    ) internal pure {
        uint256 found;
        for (uint256 i; i < count && found < 2; ++i) {
            if (tokens[i] == o.tokenA) {
                o.symbolA = symbols[i];
                o.decimalsA = decs[i];
                ++found;
            } else if (tokens[i] == o.tokenB) {
                o.symbolB = symbols[i];
                o.decimalsB = decs[i];
                ++found;
            }
        }
    }

    function _tokenMeta(address token) internal view returns (string memory symbol, uint8 decimals) {
        decimals = 18;
        try IERC20Meta(token).symbol() returns (string memory s) {
            symbol = s;
        } catch {}
        try IERC20Meta(token).decimals() returns (uint8 d) {
            decimals = d;
        } catch {}
    }
}

/// @dev v1 — all-or-nothing. Order is 6 static fields.
interface ISwapboardV1 {
    struct Order {
        address maker;
        bool active;
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
    }

    function nextOrderId() external view returns (uint256);
    function getOrders(uint256[] calldata orderIds) external view returns (Order[] memory);
}

/// @dev v2 — partialFill + expiry. Order is 8 static fields, and the field order
/// must match Swapboard.Order exactly.
interface ISwapboardV2 {
    struct Order {
        address maker;
        bool active;
        bool partialFill;
        uint64 expiry;
        bool nftA;
        bool nftB;
        address counterparty;
        address tokenA;
        uint256 amountA; // tokenId when nftA
        address tokenB;
        uint256 amountB; // tokenId when nftB
    }

    function nextOrderId() external view returns (uint256);
    function getOrders(uint256[] calldata orderIds) external view returns (Order[] memory);
}

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}
