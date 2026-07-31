// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {FixedPointMathLib} from "../lib/solady/src/utils/FixedPointMathLib.sol";

/// @title SwapboardView
/// @notice Read-only discovery, metadata, and hybrid planning for v1/v2 Swapboard
///         books and Dutchboard listings.
///
/// @dev v1 orders use six static fields and are all-or-nothing. v2 uses eleven
///      fields for partial fills, expiry, NFTs, and private fills. Separate
///      interfaces keep the two encodings from being confused.
///
/// Active v2 orders remain stored after expiry until swept, so active discovery
/// excludes expired orders and `getExpiredOrders` exposes them for cleanup.
/// Either board address may be address(0) to skip it.
///
/// `planHybrid` and `planHybridOut` compare book legs with a caller-supplied AMM
/// baseline. Exact-in maximizes output; exact-out minimizes input. These helpers
/// are intended for `eth_call`; use paged discovery for large books.
contract SwapboardView {
    /// @notice One leg of a hybrid route: take `payIn` of tokenIn to this order
    ///         and receive `getOut` of tokenOut.
    struct Fill {
        uint256 orderId;
        address board;
        uint256 payIn;
        uint256 getOut;
        bool isPartial; // false = the whole order was taken
    }

    /// @dev Ceiling on orders one plan may consider. The matcher is O(n^2) in
    /// this; discovery may scan a deeper book to retain its best candidates.
    uint256 internal constant MAX_CANDIDATES = 256;

    /// @dev Ids per `getOrders` call while walking a book. Display reads use the
    /// caller's `maxScan` directly.
    uint256 internal constant SCAN_WINDOW = 256;

    /// @dev Bound untrusted metadata calls and returned string sizes.
    uint256 internal constant META_GAS = 50_000;
    uint256 internal constant MAX_SYMBOL_BYTES = 64;

    enum Board {
        V1, // all-or-nothing
        V2, // partialFill + expiry, NFTs, counterparty
        DUTCH // Dutchboard: decaying price, partial fills, arbitrary quote asset
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
    /// @param boardV2 Current extended board (partialFill + expiry). address(0) to skip.
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
    /// @param boardV2 v2 ONLY. This decodes 11-field orders; handing it the v1
    ///        board would misread 6-field ones as plausible garbage rather than
    ///        revert. v1 is a closed book with no new orders, so newest-first
    ///        paging is a v2 concern and it is named to say so.
    function getRecentOrders(address boardV2, uint256 cursor, uint256 limit, uint256 maxScan)
        external
        view
        returns (OrderView[] memory orders, uint256 nextCursor)
    {
        return _scanDown(boardV2, Board.V2, cursor, limit, maxScan, address(0), address(0));
    }

    /// @notice Newest-first page from either supported Swapboard generation.
    /// @dev This is the display endpoint for clients, such as zSwap, that show
    ///      both the current board and the still-fillable legacy-v1 book. The
    ///      deprecated intermediate generation is intentionally unsupported.
    function getRecentOrdersFrom(address board, bool isCurrent, uint256 cursor, uint256 limit, uint256 maxScan)
        external
        view
        returns (OrderView[] memory orders, uint256 nextCursor)
    {
        return _scanDown(board, isCurrent ? Board.V2 : Board.V1, cursor, limit, maxScan, address(0), address(0));
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
        return _scanDown(boardV2, Board.V2, cursor, limit, maxScan, tokenA, tokenB);
    }

    /// @notice Plan a book/AMM split for an exact-input swap.
    /// @dev `baselineOut` is a full-size AMM quote. The planner uses its average
    ///      rate as both the floor and the remainder estimate, so `worthwhile` is
    ///      a heuristic screen. Use `previewPlanAtRate` with a remainder quote for
    ///      a second pass.
    ///
    /// @param boardV1 Legacy all-or-nothing board; address(0) to skip.
    /// @param boardV2 Current board; address(0) to skip.
    /// @param tokenIn Asset paid by the taker.
    /// @param tokenOut Asset received by the taker.
    /// @param amountIn Total input budget.
    /// @param taker Address used to filter private orders.
    /// @param baselineOut AMM output for the full input budget.
    /// @param maxScan Maximum ids scanned per board; zero scans the full books.
    /// @return fills Book legs, best rate first.
    /// @return bookIn Input used by the book.
    /// @return bookOut Output from the book.
    /// @return ammIn Input left for the AMM.
    /// @return worthwhile Whether the selected book legs beat the baseline screen.
    function planHybrid(
        address boardV1,
        address boardV2,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address taker,
        uint256 baselineOut,
        uint256 maxScan
    ) external view returns (Fill[] memory fills, uint256 bookIn, uint256 bookOut, uint256 ammIn, bool worthwhile) {
        OrderView[] memory c = _candidates(boardV1, boardV2, tokenIn, tokenOut, taker, maxScan, amountIn, false);
        (fills, bookIn, bookOut) = _plan(c, amountIn, _rate(baselineOut, amountIn));
        ammIn = amountIn - bookIn;
        // This compares the selected book rate with the full-size AMM baseline;
        // callers should treat it as a screen, not a remainder quote.
        worthwhile =
            bookOut != 0 && (bookIn == 0 || FixedPointMathLib.fullMulDiv(bookOut, amountIn, bookIn) > baselineOut);
    }

    /// @notice Plan over a caller-supplied, direction-filtered fillable book.
    /// @dev Does not re-read or validate the supplied rows.
    function previewPlan(OrderView[] calldata book, uint256 amountIn, uint256 baselineOut)
        external
        pure
        returns (Fill[] memory fills, uint256 bookIn, uint256 bookOut)
    {
        return _plan(_copy(book), amountIn, _rate(baselineOut, amountIn));
    }

    /// @notice Plan over a caller-supplied book and explicit AMM floor rate.
    /// @param floorRateWad tokenOut per tokenIn, WAD. Orders at or below this
    ///        are skipped, and the untouched remainder is valued at it.
    function previewPlanAtRate(OrderView[] calldata book, uint256 amountIn, uint256 floorRateWad)
        external
        pure
        returns (Fill[] memory fills, uint256 bookIn, uint256 bookOut)
    {
        return _plan(_copy(book), amountIn, floorRateWad);
    }

    /// @notice Return direction-filtered, fillable candidates from both books.
    /// @dev Scans each book in full; use `candidatesFrom` for bounded pages.
    function candidates(
        address boardV1,
        address boardV2,
        address tokenIn,
        address tokenOut,
        address taker,
        uint256 maxScan
    ) external view returns (OrderView[] memory) {
        return _candidates(boardV1, boardV2, tokenIn, tokenOut, taker, maxScan, type(uint256).max, false);
    }

    /// @notice Return one bounded, newest-first candidate window.
    /// @dev Pass the returned cursor to continue. `isV2` selects the order
    ///      decoder, so it must match the supplied board.
    function candidatesFrom(
        address board,
        bool isV2,
        address tokenIn,
        address tokenOut,
        address taker,
        uint256 cursor,
        uint256 maxScan
    ) external view returns (OrderView[] memory out, uint256 nextCursor) {
        if (board == address(0) || maxScan == 0 || tokenIn == tokenOut) return (new OrderView[](0), 0);
        Board v = isV2 ? Board.V2 : Board.V1;
        uint256 total = _nextOrderId(board, v);
        uint256 hi = cursor == 0 || cursor > total ? total : cursor;
        if (hi == 0) return (new OrderView[](0), 0);
        uint256 lo = hi > maxScan ? hi - maxScan : 0;

        OrderView[] memory buf = new OrderView[](MAX_CANDIDATES);
        uint256 k;
        (k, nextCursor) = _walk(board, v, tokenIn, tokenOut, taker, hi, lo, buf, 0);

        out = new OrderView[](k);
        for (uint256 i; i < k; ++i) {
            out[i] = buf[i];
        }
    }

    // ------------------------------------------------------------- EXACT OUT

    /// @notice Plan a book/AMM split for an exact-output swap.
    /// @dev Orders are ranked by input cost per output unit. All-or-nothing rows
    ///      that overshoot the target are skipped; `baselineIn == 0` means no AMM
    ///      fallback.
    /// @param baselineIn What a pure AMM route COSTS for the whole `amountOut`.
    /// @return fills      Legs to route through the book, cheapest first.
    /// @return bookOut    tokenOut those legs deliver.
    /// @return bookIn     tokenIn they cost.
    /// @return ammOut     tokenOut still to be bought from the AMM.
    /// @return worthwhile True only if the split undercuts `baselineIn`.
    function planHybridOut(
        address boardV1,
        address boardV2,
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        address taker,
        uint256 baselineIn,
        uint256 maxScan
    ) external view returns (Fill[] memory fills, uint256 bookOut, uint256 bookIn, uint256 ammOut, bool worthwhile) {
        OrderView[] memory c = _candidates(boardV1, boardV2, tokenIn, tokenOut, taker, maxScan, amountOut, true);
        uint256 ceilRate = _ceil(baselineIn, amountOut);
        (fills, bookOut, bookIn) = _planOut(c, amountOut, ceilRate);
        // Paying up on the last partial leg can deliver MORE than was asked
        // for (up to one payable input increment), so the remainder saturates
        // rather than wrapping.
        ammOut = bookOut >= amountOut ? 0 : amountOut - bookOut;
        // Compare what the plan actually spends for the requested target. An
        // exact-out partial can over-deliver when one input base unit is the
        // smallest payable increment. Normalising `bookIn` by that larger
        // `bookOut` made an equal-cost fill look cheaper (for example: pay 1,
        // receive 2, when the request and AMM baseline were both 1). Once the
        // target is covered, only the actual input paid can undercut baseline.
        // With a remainder, use the same proportional AMM score that selected
        // the plan. A zero baseline means there is no fallback, so only a
        // completely covered target is actionable.
        worthwhile = bookOut != 0 && (baselineIn == 0 ? ammOut == 0 : _cost(bookIn, ammOut, ceilRate) < baselineIn);
    }

    /// @notice Exact-out plan over a caller-supplied book.
    function previewPlanOut(OrderView[] calldata book, uint256 amountOut, uint256 baselineIn)
        external
        pure
        returns (Fill[] memory fills, uint256 bookOut, uint256 bookIn)
    {
        return _planOut(_copy(book), amountOut, _ceil(baselineIn, amountOut));
    }

    /// @notice Exact-out plan against an explicit AMM cost ceiling.
    /// @param ceilRateWad tokenIn per tokenOut, WAD. Orders at or above this
    ///        cost are skipped. type(uint256).max means no AMM alternative.
    function previewPlanOutAtRate(OrderView[] calldata book, uint256 amountOut, uint256 ceilRateWad)
        external
        pure
        returns (Fill[] memory fills, uint256 bookOut, uint256 bookIn)
    {
        return _planOut(_copy(book), amountOut, ceilRateWad);
    }

    function _ceil(uint256 inAmt, uint256 outAmt) internal pure returns (uint256) {
        if (inAmt == 0 || outAmt == 0) return type(uint256).max; // no alternative
        return FixedPointMathLib.fullMulDiv(inAmt, 1e18, outAmt);
    }

    /// @dev Same best-of-plans search as _plan, scored the other way up.
    function _planOut(OrderView[] memory c, uint256 amountOut, uint256 ceilRate)
        internal
        pure
        returns (Fill[] memory fills, uint256 bookOut, uint256 bookIn)
    {
        uint256 n = c.length;
        if (n == 0 || amountOut == 0) return (new Fill[](0), 0, 0);

        // tokenIn per tokenOut, WAD - a cost, so lower is better. An order too
        // large to express sorts LAST rather than first: on the exact-in side
        // the unrepresentable sentinel is 0 because 0 is the worst rate, and
        // reusing that here would make such an order look free.
        uint256[] memory cost = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 b = c[i].amountB;
            uint256 a = c[i].amountA;
            // Guarded for the same reason as _plan: previewPlanOut accepts an
            // unfiltered book. The max sentinel sorts last and never clears the
            // ceiling, so such a row is skipped rather than reverting the read.
            // `b == 0` is only cost-free when it is a genuine free row; the same
            // zero on an NFT leg is a tokenId and must sort last, not first.
            if (_freeRow(c[i]) && a != 0) {
                cost[i] = 0;
            } else {
                cost[i] = (a != 0 && b != 0 && b <= type(uint256).max / 1e18)
                    ? FixedPointMathLib.fullMulDiv(b, 1e18, a)
                    : type(uint256).max;
            }
        }

        // insertion sort, ascending: cheapest first. Bounded as in _plan.
        for (uint256 i = 1; i < n; ++i) {
            uint256 r = cost[i];
            OrderView memory o = c[i];
            uint256 j = i;
            while (j != 0 && cost[j - 1] > r) {
                cost[j] = cost[j - 1];
                c[j] = c[j - 1];
                --j;
            }
            cost[j] = r;
            c[j] = o;
        }

        uint256 best = type(uint256).max;
        for (uint256 seed; seed <= n; ++seed) {
            if (seed != 0) {
                uint256 x = seed - 1;
                // only worth seeding with an AON block greedy would skip
                if (c[x].partialFill || c[x].amountA > amountOut || (c[x].amountB != 0 && cost[x] >= ceilRate)) {
                    continue;
                }
            }
            (Fill[] memory f, uint256 bo, uint256 bi) = _sweepPlanOut(c, cost, amountOut, ceilRate, seed);
            uint256 score = _cost(bi, bo >= amountOut ? 0 : amountOut - bo, ceilRate);
            if (score < best) {
                best = score;
                fills = f;
                bookOut = bo;
                bookIn = bi;
            }
        }
        if (fills.length == 0) fills = new Fill[](0);
    }

    /// @dev Total input a plan implies: what the book legs cost plus what the
    /// AMM would charge for the output they did not cover. Saturates instead of
    /// reverting, so an unpriceable plan simply loses the comparison.
    function _cost(uint256 bookIn, uint256 rem, uint256 ceilRate) internal pure returns (uint256) {
        if (rem == 0) return bookIn;
        if (ceilRate == type(uint256).max) return type(uint256).max; // uncoverable
        unchecked {
            if (ceilRate != 0 && rem > type(uint256).max / ceilRate) return type(uint256).max;
            uint256 total = bookIn + (rem * ceilRate) / 1e18;
            return total < bookIn ? type(uint256).max : total;
        }
    }

    function _sweepPlanOut(
        OrderView[] memory c,
        uint256[] memory cost,
        uint256 amountOut,
        uint256 ceilRate,
        uint256 seed
    ) internal pure returns (Fill[] memory fills, uint256 bookOut, uint256 bookIn) {
        uint256 n = c.length;
        Fill[] memory tmp = new Fill[](n);
        uint256 k;
        uint256 left = amountOut;

        for (uint256 pass; pass != 2; ++pass) {
            for (uint256 i; i < n && left != 0; ++i) {
                if (seed != 0) {
                    bool seeded = i == seed - 1;
                    if (pass == 0 ? !seeded : seeded) continue;
                }
                bool free = _freeRow(c[i]);
                if (!free && cost[i] >= ceilRate) continue;
                uint256 want = c[i].amountA; // output this order pays in full
                uint256 take;
                if (want <= left) {
                    take = want; // whole order, all-or-nothing included
                } else if (c[i].partialFill) {
                    take = left; // size the shortfall into it
                } else {
                    continue; // would overshoot an exact-out target
                }

                // The board settles from the INPUT leg - outA is derived from
                // fillAmountB - so a payment rounded down lands short of `take`
                // and the plan silently misses its target. Round the payment up,
                // then report the output the board's own arithmetic will give.
                uint256 pay;
                uint256 get;
                if (free) {
                    // A free Dutchboard row is filled by naming output, not
                    // payment. Exact-out should take only the still-needed
                    // amount and bind the board to maxCost == 0.
                    pay = 0;
                    get = take;
                } else if (take == want) {
                    pay = c[i].amountB;
                    get = want;
                } else {
                    pay = FixedPointMathLib.fullMulDivUp(take, c[i].amountB, c[i].amountA);
                    if (pay > c[i].amountB) pay = c[i].amountB;
                    get = FixedPointMathLib.fullMulDiv(pay, c[i].amountA, c[i].amountB);
                }
                if (get == 0) continue; // dust, the board would reject it

                tmp[k++] = Fill(c[i].orderId, c[i].board, pay, get, take != want);
                bookIn += pay;
                bookOut += get;
                left -= get < left ? get : left; // rounding up can overshoot the last leg
            }
            if (seed == 0) break;
        }

        fills = new Fill[](k);
        for (uint256 i; i < k; ++i) {
            fills[i] = tmp[i];
        }
    }

    /// @dev Copy calldata because the planner sorts in place. Drop NFT and zero-A
    /// rows; callers of preview methods must still provide the right direction
    /// and counterparty.
    function _copy(OrderView[] calldata book) internal pure returns (OrderView[] memory c) {
        OrderView[] memory buf = new OrderView[](book.length);
        uint256 k;
        for (uint256 i; i < book.length; ++i) {
            if (book[i].nftA || book[i].nftB) continue; // amount is a tokenId
            if (book[i].amountA == 0) continue; // pays nothing
            buf[k++] = book[i];
        }
        c = new OrderView[](k);
        for (uint256 i; i < k; ++i) {
            c[i] = buf[i];
        }
    }

    /// @dev A zero-price Dutchboard ERC-20 row is free; NFT tokenId 0 is not.
    function _freeRow(OrderView memory o) internal pure returns (bool) {
        return o.amountB == 0 && !o.nftA && !o.nftB;
    }

    function _rate(uint256 out, uint256 inAmt) internal pure returns (uint256) {
        if (out == 0 || inAmt == 0) return 0;
        return FixedPointMathLib.fullMulDiv(out, 1e18, inAmt);
    }

    /// @dev Keep only rows in the requested direction, fillable by `taker`, and
    /// compatible with the planner's fungible-only assumptions.
    function _candidates(
        address boardV1,
        address boardV2,
        address tokenIn,
        address tokenOut,
        address taker,
        uint256 maxScan,
        uint256 capacity,
        bool exactOut
    ) internal view returns (OrderView[] memory out) {
        if (tokenIn == tokenOut) return new OrderView[](0);
        OrderView[] memory buf = new OrderView[](MAX_CANDIDATES);
        uint256[] memory rates = new uint256[](MAX_CANDIDATES);
        // Scan both boards completely (within maxScan) and retain the best
        // MAX_CANDIDATES rates globally. Collecting v2 first and stopping at
        // the cap used to erase v1 liquidity whenever the newer board was deep.
        uint256 k =
            _collectBest(boardV2, Board.V2, tokenIn, tokenOut, taker, maxScan, capacity, exactOut, buf, rates, 0);
        k = _collectBest(boardV1, Board.V1, tokenIn, tokenOut, taker, maxScan, capacity, exactOut, buf, rates, k);

        out = new OrderView[](k);
        for (uint256 i; i < k; ++i) {
            out[i] = buf[i];
        }
    }

    /// @dev Scan one board and retain the best global candidates in `buf`.
    function _collectBest(
        address board,
        Board v,
        address tokenIn,
        address tokenOut,
        address taker,
        uint256 maxScan,
        uint256 capacity,
        bool exactOut,
        OrderView[] memory buf,
        uint256[] memory rates,
        uint256 k
    ) internal view returns (uint256) {
        if (board == address(0)) return k;
        uint256 total = _nextOrderId(board, v);
        if (total == 0) return k;
        uint256 budget = maxScan == 0 || maxScan > total ? total : maxScan;
        uint256 hi = total;
        uint256 lo = total - budget;
        while (hi > lo) {
            uint256 l = hi > lo + SCAN_WINDOW ? hi - SCAN_WINDOW : lo;
            uint256 n = hi - l;
            uint256[] memory ids = new uint256[](n);
            for (uint256 i; i < n; ++i) {
                ids[i] = hi - 1 - i;
            }
            OrderView[] memory got = _fetch(board, v, ids, false, tokenIn, tokenOut);
            for (uint256 i; i < got.length; ++i) {
                if (!_usable(got[i], tokenIn, tokenOut, taker, false)) continue;
                // An all-or-nothing order larger than this request cannot
                // participate in any plan. Letting 256 such high-rate blocks
                // occupy the bounded candidate set can crowd out an older
                // partial (or smaller AON) order that both fits and beats the
                // AMM, causing planHybrid to return no route at all.
                if (!got[i].partialFill && (exactOut ? got[i].amountA > capacity : got[i].amountB > capacity)) {
                    continue;
                }
                uint256 value = _valueOf(got[i], capacity, exactOut);
                if (k < MAX_CANDIDATES) {
                    buf[k++] = got[i];
                    rates[k - 1] = value;
                } else {
                    uint256 worst = _worstRate(rates, k);
                    if (value > rates[worst]) {
                        buf[worst] = got[i];
                        rates[worst] = value;
                    }
                }
            }
            hi = l;
        }
        return k;
    }

    /// @dev Rank a row by its contribution within `capacity`. Saturate
    ///      unrepresentable exact-out values instead of reverting.
    function _valueOf(OrderView memory o, uint256 capacity, bool exactOut) internal pure returns (uint256) {
        uint256 a = o.amountA;
        uint256 b = o.amountB;
        if (b == 0) return a == 0 ? 0 : type(uint256).max; // free row, always worth keeping
        if (a == 0) return 0;
        if (!exactOut) {
            // Coverage is an INPUT amount, so the product is the output this row
            // pays for it and is bounded by `a`. No guard is reachable.
            uint256 cov = b < capacity ? b : capacity;
            return FixedPointMathLib.fullMulDiv(cov, a, b);
        }
        uint256 covOut = a < capacity ? a : capacity;
        if (covOut > type(uint256).max / a) return 0; // unrepresentable
        return FixedPointMathLib.fullMulDiv(covOut, a, b);
    }

    function _worstRate(uint256[] memory rates, uint256 len) internal pure returns (uint256 worst) {
        for (uint256 i = 1; i < len; ++i) {
            if (rates[i] < rates[worst]) worst = i;
        }
    }

    /// @dev Walk ids downward in bounded windows, appending usable orders and
    ///      returning the next cursor when the candidate buffer fills.
    function _walk(
        address board,
        Board v,
        address tokenIn,
        address tokenOut,
        address taker,
        uint256 hi,
        uint256 lo,
        OrderView[] memory buf,
        uint256 k
    ) internal view returns (uint256, uint256) {
        while (hi > lo && k < MAX_CANDIDATES) {
            uint256 l = hi > lo + SCAN_WINDOW ? hi - SCAN_WINDOW : lo;
            uint256 n = hi - l;
            uint256[] memory ids = new uint256[](n);
            for (uint256 i; i < n; ++i) {
                ids[i] = hi - 1 - i; // newest first
            }
            OrderView[] memory got = _fetch(board, v, ids, false, tokenIn, tokenOut);
            for (uint256 i; i < got.length && k < MAX_CANDIDATES; ++i) {
                if (_usable(got[i], tokenIn, tokenOut, taker, v == Board.DUTCH)) {
                    buf[k++] = got[i];
                    // Do not advance beyond entries that this bounded response
                    // did not inspect. `cursor` is exclusive, so the next
                    // call must start one id above the first unseen entry.
                    if (k == MAX_CANDIDATES && i + 1 < got.length) return (k, got[i + 1].orderId + 1);
                }
            }
            hi = l;
        }
        return (k, hi);
    }

    function _usable(OrderView memory o, address tokenIn, address tokenOut, address taker, bool allowFree)
        internal
        pure
        returns (bool)
    {
        if (tokenIn == tokenOut) return false;
        if (o.tokenA != tokenOut || o.tokenB != tokenIn) return false; // direction
        if (o.nftA || o.nftB) return false; // not fungible, cannot be split into a swap
        if (o.amountA == 0 || (!allowFree && o.amountB == 0)) return false;
        return o.counterparty == address(0) || o.counterparty == taker;
    }

    /// @dev Use a rate-greedy plan plus one seeded plan per candidate to account
    ///      for all-or-nothing rows. This is heuristic and O(n^2), bounded by
    ///      `MAX_CANDIDATES`.
    function _plan(OrderView[] memory c, uint256 amountIn, uint256 floorRate)
        internal
        pure
        returns (Fill[] memory fills, uint256 bookIn, uint256 bookOut)
    {
        uint256 n = c.length;
        if (n == 0) return (new Fill[](0), 0, 0);

        // tokenOut per tokenIn, in WAD. fullMulDiv so an adversarially large
        // order cannot overflow the comparison and brick the whole read.
        // An order whose WAD rate cannot be represented is unfillable anyway -
        // no escrow that large exists - and computing it would revert and take
        // the whole read down with it. Rate 0 sorts it below any floor.
        uint256[] memory rate = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 a = c[i].amountA;
            uint256 b = c[i].amountB;
            // amountB of 0 is filtered by _usable on the discovery path, but
            // previewPlan takes the caller's book verbatim, so the divide has to
            // be guarded here too. Rate 0 means unrepresentable, which already
            // sorts below any floor and is skipped.
            if (_freeRow(c[i]) && a != 0) {
                // Dutchboard permits an ERC-20 listing to decay to a zero
                // price. It is real liquidity, not a malformed divide: rank
                // it ahead of every paid row and let the sweep take the whole
                // free remainder without consuming the caller's input.
                rate[i] = type(uint256).max;
            } else if (b != 0 && a <= type(uint256).max / 1e18) {
                rate[i] = FixedPointMathLib.fullMulDiv(a, 1e18, b);
            }
        }
        // insertion sort, descending. n is bounded by MAX_CANDIDATES and this
        // is a view, so the simple sort is not worth replacing.
        for (uint256 i = 1; i < n; ++i) {
            uint256 r = rate[i];
            OrderView memory o = c[i];
            uint256 j = i;
            while (j != 0 && rate[j - 1] < r) {
                rate[j] = rate[j - 1];
                c[j] = c[j - 1];
                --j;
            }
            rate[j] = r;
            c[j] = o;
        }

        // plan 0 is plain greedy; plan i+1 forces candidate i to be taken first
        uint256 best;
        for (uint256 seed; seed <= n; ++seed) {
            if (seed != 0) {
                uint256 x = seed - 1;
                // only worth seeding with an AON block greedy would skip
                if (c[x].partialFill || c[x].amountB > amountIn || (c[x].amountB != 0 && rate[x] <= floorRate)) {
                    continue;
                }
            }
            (Fill[] memory f, uint256 bi, uint256 bo) = _sweepPlan(c, rate, amountIn, floorRate, seed);
            uint256 score = bo + FixedPointMathLib.fullMulDiv(amountIn - bi, floorRate, 1e18);
            if (score > best) {
                best = score;
                fills = f;
                bookIn = bi;
                bookOut = bo;
            }
        }
        if (fills.length == 0) fills = new Fill[](0);
    }

    /// @dev One pass over the sorted candidates. `seed` of 0 is plain greedy;
    /// otherwise candidate `seed - 1` is taken first and the rest follow.
    function _sweepPlan(OrderView[] memory c, uint256[] memory rate, uint256 amountIn, uint256 floorRate, uint256 seed)
        internal
        pure
        returns (Fill[] memory fills, uint256 bookIn, uint256 bookOut)
    {
        uint256 n = c.length;
        Fill[] memory tmp = new Fill[](n);
        uint256 k;
        uint256 left = amountIn;

        for (uint256 pass; pass != 2; ++pass) {
            for (uint256 i; i < n; ++i) {
                // With a seed, the first pass places only that order and the
                // second fills around it. With no seed there is one pass that
                // places everything in rate order.
                if (seed != 0) {
                    bool seeded = i == seed - 1;
                    if (pass == 0 ? !seeded : seeded) continue;
                }
                bool free = _freeRow(c[i]);
                if (!free && rate[i] <= floorRate) continue;
                uint256 want = c[i].amountB;
                uint256 pay;
                if (free) {
                    pay = 0;
                } else if (want <= left) {
                    pay = want; // whole order, all-or-nothing included
                } else if (c[i].partialFill) {
                    pay = left; // size the remainder into it
                } else {
                    continue; // all-or-nothing, does not fit what is left
                }
                if (rate[i] == 0) continue; // unrepresentable, skipped above
                uint256 get = free ? c[i].amountA : FixedPointMathLib.fullMulDiv(pay, c[i].amountA, c[i].amountB);
                if (get == 0) continue; // dust, the board would reject it
                tmp[k++] = Fill(c[i].orderId, c[i].board, pay, get, pay != want);
                bookIn += pay;
                bookOut += get;
                left -= pay;
            }
            if (seed == 0) break; // unseeded: that single pass is the whole plan
        }

        fills = new Fill[](k);
        for (uint256 i; i < k; ++i) {
            fills[i] = tmp[i];
        }
    }

    // ---- Internal ----

    /// @dev Walks ids downward from `cursor` (exclusive). Returns the exclusive
    /// upper bound for the next window, or 0 when id 0 has been reached.
    function _scanDown(address board, Board v, uint256 cursor, uint256 limit, uint256 maxScan, address ta, address tb)
        internal
        view
        returns (OrderView[] memory orders, uint256 nextCursor)
    {
        if (board == address(0) || limit == 0 || maxScan == 0) return (new OrderView[](0), 0);
        uint256 total = _nextOrderId(board, v);
        uint256 hi = cursor == 0 || cursor > total ? total : cursor;
        if (hi == 0) return (new OrderView[](0), 0);

        uint256 lo = hi > maxScan ? hi - maxScan : 0;
        uint256 n = hi - lo;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = hi - 1 - i; // newest first
        }

        OrderView[] memory all = _fetch(board, v, ids, false, ta, tb);
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
        // A codeless address returns empty returndata, which would make the
        // high-level call revert and take the whole multi-board read down with
        // it. Callers already treat 0 as "empty book", so an address with no
        // board deployed at it is simply skipped. This is not hypothetical: the
        // dapp carries a placeholder for the not-yet-deployed extension board.
        if (board.code.length == 0) return 0;
        if (v == Board.V1) return ISwapboardV1(board).nextOrderId();
        if (v == Board.DUTCH) return IDutchboard(board).nextId();
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
        if (limit == 0 || maxScan == 0) return (new OrderView[](0), 0);
        uint256 total = _nextOrderId(board, v);
        if (startId >= total) return (new OrderView[](0), 0);

        uint256 remaining = total - startId;
        uint256 scanLen = maxScan < remaining ? maxScan : remaining;
        uint256 end = startId + scanLen;

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
        if (v == Board.DUTCH) return _fetchDutch(board, ids, wantExpired, ta, tb);

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

    /// @dev Convert Dutchboard rows into the common view shape. `amountB` is the
    /// current cost of the full fungible remainder; the quote is valid only for
    /// the call snapshot because the price decays. NFT bundles are skipped, while
    /// single NFTs and zero-price ERC-20 rows are represented when fillable.
    function _fetchDutch(address board, uint256[] memory ids, bool wantExpired, address ta, address tb)
        internal
        view
        returns (OrderView[] memory out)
    {
        if (wantExpired || ids.length == 0) return new OrderView[](0);

        // Ids arrive contiguous from every caller here (ascending pages, descending
        // walk windows), so one range read replaces one call per id.
        uint256 lo = ids[0];
        uint256 hi = ids[0];
        for (uint256 i = 1; i < ids.length; ++i) {
            if (ids[i] < lo) lo = ids[i];
            if (ids[i] > hi) hi = ids[i];
        }
        IDutchboard.ListingView[] memory raw = IDutchboard(board).getListings(lo, hi + 1);

        OrderView[] memory buf = new OrderView[](ids.length);
        uint256 k;
        for (uint256 i; i < ids.length; ++i) {
            uint256 idx = ids[i] - lo;
            if (idx >= raw.length) continue;
            IDutchboard.ListingView memory l = raw[idx];
            if (l.seller == address(0)) continue; // closed or never listed
            // A scheduled listing is not open yet, and Dutchboard refuses the fill.
            // The schedule still reports startPrice before the window, so without
            // this the lens would quote a row every planner would happily route
            // through and every fill would revert.
            if (block.timestamp < l.startTime) continue;
            if (!_pairMatch(l.token, l.quote, ta, tb)) continue;
            if (l.isNFT && l.ids.length != 1) continue; // bundle: not representable

            buf[k].orderId = l.id;
            buf[k].maker = l.seller;
            buf[k].partialFill = !l.isNFT;
            buf[k].counterparty = address(0); // Dutchboard has no private listings
            buf[k].tokenA = l.token;
            buf[k].tokenB = l.quote;
            buf[k].board = board;

            if (l.isNFT) {
                buf[k].nftA = true;
                buf[k].amountA = l.ids[0];
                buf[k].amountB = l.price;
            } else {
                if (l.remaining == 0 || l.initial == 0) continue;
                buf[k].amountA = l.remaining;
                // ceil(price * remaining / initial) — mirrors Dutchboard.costOf exactly,
                // so a leg quoted here is the leg the board will charge for.
                buf[k].amountB = (uint256(l.price) * l.remaining + l.initial - 1) / l.initial;
            }
            ++k;
        }

        out = new OrderView[](k);
        for (uint256 i; i < k; ++i) {
            out[i] = buf[i];
        }
    }

    /// @notice Fillable Dutchboard candidates, newest id first, in one bounded window.
    function dutchCandidatesFrom(
        address board,
        address tokenIn,
        address tokenOut,
        address taker,
        uint256 cursor,
        uint256 maxScan
    ) external view returns (OrderView[] memory out, uint256 nextCursor) {
        if (board == address(0) || maxScan == 0 || tokenIn == tokenOut) return (new OrderView[](0), 0);
        uint256 total = _nextOrderId(board, Board.DUTCH);
        if (total == 0) return (new OrderView[](0), 0);

        uint256 hi = cursor == 0 || cursor > total ? total : cursor;
        uint256 lo = hi > maxScan ? hi - maxScan : 0;

        OrderView[] memory buf = new OrderView[](MAX_CANDIDATES);
        (uint256 k, uint256 stopped) = _walk(board, Board.DUTCH, tokenIn, tokenOut, taker, hi, lo, buf, 0);

        out = new OrderView[](k);
        for (uint256 i; i < k; ++i) {
            out[i] = buf[i];
        }
        out = _withMeta(out);
        nextCursor = stopped > 0 ? stopped : 0;
    }

    /// @notice All fillable Dutchboard listings, paged. Mirrors getAllActiveOrdersPaged.
    function getActiveDutchListingsPaged(address board, uint256 startId, uint256 limit, uint256 maxScan)
        external
        view
        returns (OrderView[] memory listings, uint256 nextStart)
    {
        return _readBoardPaged(board, Board.DUTCH, startId, limit, maxScan, false);
    }

    /// @notice Newest-first Dutchboard display page, matching
    ///         getRecentOrdersFrom so clients can walk every supported book
    ///         with the same cursor semantics.
    function getRecentDutchListings(address board, uint256 cursor, uint256 limit, uint256 maxScan)
        external
        view
        returns (OrderView[] memory listings, uint256 nextCursor)
    {
        return _scanDown(board, Board.DUTCH, cursor, limit, maxScan, address(0), address(0));
    }

    /// @dev Match Swapboard's inclusive expiry boundary.
    function _isExpired(uint64 expiry) internal view returns (bool) {
        return expiry != 0 && block.timestamp > expiry;
    }

    /// @dev Match either market direction; address(0) is a wildcard.
    function _pairMatch(address oa, address ob, address ta, address tb) internal pure returns (bool) {
        if (ta == address(0) && tb == address(0)) return true;
        if (tb == address(0)) return oa == ta || ob == ta;
        if (ta == address(0)) return oa == tb || ob == tb;
        return (oa == ta && ob == tb) || (oa == tb && ob == ta);
    }

    // ---- Token metadata ----

    /// @dev Read metadata once per distinct token, then apply it to each row.
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
            }
            if (tokens[i] == o.tokenB && found < 2) {
                o.symbolB = symbols[i];
                o.decimalsB = decs[i];
                ++found;
            }
        }
    }

    function _tokenMeta(address token) internal view returns (string memory symbol, uint8 decimals) {
        decimals = 18;
        // Dutchboard prices a listing in `quote`, and quote == address(0) is
        // native ETH rather than a contract. Staticcalling it succeeds with
        // empty returndata, which is indistinguishable from a token that simply
        // has no symbol(), so the row rendered with a blank label. ETH has no
        // metadata to read; it has to be named here.
        if (token == address(0)) return ("ETH", 18);
        (bool ok, bytes memory data) = _boundedStaticcall(token, 0x95d89b41, 128); // symbol()
        if (ok && data.length >= 64) {
            uint256 offset;
            uint256 len;
            assembly ("memory-safe") {
                offset := mload(add(data, 0x20))
                len := mload(add(data, 0x40))
            }
            // Canonical ABI string: [offset=32][length][padded bytes].
            // Validating the complete shape before abi.decode keeps malformed
            // metadata a harmless blank label instead of a page-wide revert.
            if (offset == 32 && len <= MAX_SYMBOL_BYTES) {
                uint256 padded = (len + 31) & ~uint256(31);
                if (data.length >= 64 + padded) {
                    symbol = abi.decode(data, (string));
                }
            }
        }

        (ok, data) = _boundedStaticcall(token, 0x313ce567, 32); // decimals()
        if (ok && data.length == 32) {
            uint256 d;
            assembly ("memory-safe") {
                d := mload(add(data, 0x20))
            }
            if (d <= type(uint8).max) decimals = uint8(d);
        }
    }

    /// @dev Calls one no-argument metadata selector with fixed gas and a hard
    /// returndata ceiling. The EVM may report more bytes than the output area
    /// copied; that case is rejected rather than copying the remainder.
    function _boundedStaticcall(address token, uint32 selector, uint256 maxRet)
        internal
        view
        returns (bool success, bytes memory data)
    {
        data = new bytes(maxRet);
        assembly ("memory-safe") {
            mstore(0x00, shl(224, selector))
            success := staticcall(META_GAS, token, 0x00, 0x04, add(data, 0x20), maxRet)
            let size := returndatasize()
            if gt(size, maxRet) {
                success := 0
                size := 0
            }
            mstore(data, size)
        }
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

/// @dev v2 extension. The field order must match Swapboard.Order exactly.
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

/// @dev Dutchboard. `ListingView` must match Dutchboard.ListingView field-for-field.
interface IDutchboard {
    struct ListingView {
        uint256 id;
        address seller;
        address token;
        address quote;
        bool isNFT;
        uint40 startTime;
        uint40 duration;
        uint96 startPrice;
        uint96 endPrice;
        uint128 initial;
        uint128 remaining;
        uint256[] ids;
        uint256 price;
    }

    function nextId() external view returns (uint256);
    function getListings(uint256 start, uint256 end) external view returns (ListingView[] memory);
}

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}
