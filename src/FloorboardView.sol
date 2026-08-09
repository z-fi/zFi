// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title FloorboardView
/// @notice Read-only discovery for Floorboard standing bids.
///
/// @dev A SIBLING OF `SwapboardView`, NOT AN EXTENSION OF IT. That contract
///      normalises Swapboard v1/v2 and Dutchboard into one `OrderView`, and it
///      is full: 24,110 bytes against EIP-170's 24,576. Adding Floorboard to it
///      measured 24,793 - over - and only came in under by dropping a function.
///
///      Size is the smaller reason. `OrderView` encodes an NFT leg as a flag
///      plus an amount holding a SPECIFIC TOKEN ID, and a Floorboard bid with an
///      empty `ids` set is a bid on ANY id from the collection. There is no
///      sentinel available: id `0` is a perfectly ordinary token. So the row
///      type cannot say the one thing a floor bid most needs to say, which is
///      why `_fetchDutch` skips NFT bundles outright rather than mis-stating
///      them. `BidRow` below carries `anyId` explicitly instead.
///
/// @dev DIRECTION. Every other book on this stack is read from the buyer's
///      side: a Swapboard order or a Dutch listing offers `token` and asks for
///      `quote`, and the reader is the one paying. A Floorboard bid is the
///      mirror - the BIDDER is buying, so whoever acts on it is SELLING. They
///      deliver `token` and receive `quote`. Every pair filter here is written
///      from that side, and `tokenIn`/`tokenOut` below mean what the SELLER
///      hands over and takes away. Reading a bid the other way round makes
///      every row its own reflection, which looks plausible in both directions
///      and is wrong in both.
contract FloorboardView {
    /// @dev Ceiling on rows one call may return, and on ids read per window.
    uint256 internal constant MAX_ROWS = 256;

    /// @dev Bound untrusted metadata calls and the strings they return.
    uint256 internal constant META_GAS = 50_000;
    uint256 internal constant MAX_SYMBOL_BYTES = 64;

    /// @notice One live bid, from the perspective of somebody selling into it.
    struct BidRow {
        uint256 bidId;
        address bidder;
        address token; // what the bid buys - what a seller delivers
        address quote; // what the bid pays in - what a seller receives
        bool isNFT;
        /// @dev True when an NFT bid names no ids: it accepts ANY id from the
        ///      collection. This is the floor bid proper. When false, `ids`
        ///      lists the only ids this bid will take.
        bool anyId;
        uint256[] ids;
        uint128 remaining; // units still wanted (NFT: a count)
        uint128 initial; // units wanted at creation; the basis `price` quotes
        uint256 price; // total for the FULL INITIAL size, in `quote`
        uint256 proceedsForRemaining; // what delivering `remaining` pays, right now
        uint40 startTime;
        uint40 expiry; // startTime + duration; a closed window ends the bid
        uint8 tokenDecimals; // 0 when the board never snapshotted one
        uint8 quoteDecimals;
        string tokenSymbol;
        string quoteSymbol;
    }

    /// @notice Newest-first page of live bids. Cursor semantics match
    ///         `SwapboardView.getRecentDutchListings` so a client can walk every
    ///         book on the stack with one loop.
    function getRecentFloorBids(address board, uint256 cursor, uint256 limit, uint256 maxScan)
        external
        view
        returns (BidRow[] memory rows, uint256 nextCursor)
    {
        return _scanDown(board, cursor, limit, maxScan, address(0), address(0), address(0), false);
    }

    /// @notice Live bids a seller of `tokenIn` could hit, newest first.
    /// @param tokenIn  What the seller delivers. Matched against the bid's `token`.
    /// @param tokenOut What the seller wants paid in. Matched against `quote`;
    ///                 `address(0)` accepts any quote asset.
    function floorCandidatesFrom(
        address board,
        address tokenIn,
        address tokenOut,
        uint256 cursor,
        uint256 limit,
        uint256 maxScan
    ) external view returns (BidRow[] memory rows, uint256 nextCursor) {
        if (tokenIn == address(0)) return (new BidRow[](0), 0);
        return _scanDown(board, cursor, limit, maxScan, tokenIn, tokenOut, address(0), false);
    }

    /// @notice Live COLLECTION-WIDE bids on `collection` - the ones that will
    ///         take any id. This is what backs "sell whatever I hold from this
    ///         collection", and the reason this contract exists apart from
    ///         `SwapboardView`: these rows cannot be expressed as an `OrderView`
    ///         at all, because that struct has nowhere to put "any".
    function collectionBids(address board, address collection, address quote, uint256 cursor, uint256 limit, uint256 maxScan)
        external
        view
        returns (BidRow[] memory rows, uint256 nextCursor)
    {
        if (collection == address(0)) return (new BidRow[](0), 0);
        return _scanDown(board, cursor, limit, maxScan, collection, quote, address(0), true);
    }

    /// @notice The single best live bid for a seller of `tokenIn`, by unit price.
    /// @dev Ranked by unit price, so a large bid does not beat a better-priced
    ///      small one purely on total size. Returns a zero row when nothing
    ///      matches; `bidder == address(0)` marks that.
    function bestFloorBid(address board, address tokenIn, address tokenOut, uint256 maxScan)
        external
        view
        returns (BidRow memory best)
    {
        (BidRow[] memory rows,) = _scanDown(board, 0, MAX_ROWS, maxScan, tokenIn, tokenOut, address(0), false);
        // Cross-multiplied rather than divided. `proceeds / remaining` is an
        // integer division between a quote amount and a token amount that are
        // routinely six and eighteen decimals apart, so it truncates to zero
        // for EVERY row and the comparison silently picks nothing - which is
        // what the first version of this did.
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].remaining == 0) continue;
            if (best.bidder == address(0)) {
                best = rows[i];
                continue;
            }
            if (rows[i].proceedsForRemaining * best.remaining > best.proceedsForRemaining * rows[i].remaining) {
                best = rows[i];
            }
        }
    }

    // ------------------------------------------------------------------ SCAN

    /// @dev One bounded, newest-first window. `onlyAnyId` narrows to
    ///      collection-wide bids. A codeless address answers as an empty book
    ///      rather than reverting, so a client holding a placeholder address
    ///      degrades to "no liquidity" instead of taking the whole read down.
    function _scanDown(
        address board,
        uint256 cursor,
        uint256 limit,
        uint256 maxScan,
        address tokenIn,
        address tokenOut,
        address,
        bool onlyAnyId
    ) internal view returns (BidRow[] memory rows, uint256 nextCursor) {
        if (board.code.length == 0 || limit == 0 || maxScan == 0) return (new BidRow[](0), 0);
        uint256 total = IFloorboard(board).nextId();
        if (total == 0) return (new BidRow[](0), 0);

        if (limit > MAX_ROWS) limit = MAX_ROWS;
        uint256 hi = cursor == 0 || cursor > total ? total : cursor;
        uint256 lo = hi > maxScan ? hi - maxScan : 0;
        if (hi == 0) return (new BidRow[](0), 0);

        IFloorboard.BidView[] memory raw = IFloorboard(board).getBids(lo, hi);
        BidRow[] memory buf = new BidRow[](limit);
        uint256 k;
        uint256 i = raw.length;
        while (i != 0) {
            --i;
            IFloorboard.BidView memory b = raw[i];
            if (b.bidder == address(0)) continue; // never existed, or closed
            // The board's own answer to "would a hit succeed right now": it
            // folds in the start window and the close. Testing startTime by
            // hand here would surface unopened bids as actionable rows.
            if (!b.takeable) continue;
            if (tokenIn != address(0) && b.token != tokenIn) continue;
            if (tokenOut != address(0) && b.quote != tokenOut) continue;
            bool any = b.isNFT && b.ids.length == 0;
            if (onlyAnyId && !any) continue;
            if (b.remaining == 0 || b.initial == 0) continue;

            buf[k] = BidRow({
                bidId: b.id,
                bidder: b.bidder,
                token: b.token,
                quote: b.quote,
                isNFT: b.isNFT,
                anyId: any,
                ids: b.ids,
                remaining: b.remaining,
                initial: b.initial,
                price: b.price,
                // Rounds DOWN, exactly as `Floorboard._proceeds` does, so a row
                // never promises a seller more than the board will pay.
                proceedsForRemaining: (b.price * b.remaining) / b.initial,
                startTime: b.startTime,
                expiry: uint40(uint256(b.startTime) + b.duration),
                tokenDecimals: 0,
                quoteDecimals: 0,
                tokenSymbol: "",
                quoteSymbol: ""
            });
            if (++k == limit) break;
        }

        rows = new BidRow[](k);
        for (uint256 j; j < k; ++j) {
            rows[j] = buf[j];
        }
        rows = _withMeta(board, rows);
        // Where the next page starts. Zero means the scan reached the bottom.
        nextCursor = lo == 0 ? 0 : lo;
    }

    /// @dev Symbols and decimals come from the BOARD's own snapshots, taken when
    ///      the bid was created, not from the token contract. A collection is
    ///      attacker-chosen and this is a read every client renders; the board
    ///      already sanitised these once and there is no reason to trust the
    ///      token a second time at display speed.
    function _withMeta(address board, BidRow[] memory rows) internal view returns (BidRow[] memory) {
        for (uint256 i; i < rows.length; ++i) {
            rows[i].tokenDecimals = _decimals(board, rows[i].token);
            rows[i].quoteDecimals = _decimals(board, rows[i].quote);
            rows[i].tokenSymbol = _symbol(board, rows[i].token);
            rows[i].quoteSymbol = _symbol(board, rows[i].quote);
        }
        return rows;
    }

    /// @dev The board stores `decimals + 1`, with zero meaning "never read".
    ///      Pass that convention through untouched rather than inventing 18.
    function _decimals(address board, address token) internal view returns (uint8) {
        (bool ok, bytes memory ret) =
            board.staticcall(abi.encodeWithSelector(IFloorboard.tokenDecimals.selector, token));
        if (!ok || ret.length != 32) return 0;
        return abi.decode(ret, (uint8));
    }

    /// @dev Floorboard keeps its symbol snapshots in an INTERNAL mapping, so
    ///      unlike `tokenDecimals` there is no getter to read them back. The
    ///      symbol therefore comes from the token itself - which is untrusted,
    ///      so the call is gas-bounded and the answer length-bounded, the same
    ///      treatment `SwapboardView._withMeta` gives its metadata reads. A
    ///      token that reverts, runs long, or returns something enormous costs
    ///      the row its symbol and nothing else.
    function _symbol(address, address token) internal view returns (string memory) {
        if (token.code.length == 0) return "";
        (bool ok, bytes memory ret) = token.staticcall{gas: META_GAS}(abi.encodeWithSignature("symbol()"));
        if (!ok || ret.length < 64) return "";
        string memory s = abi.decode(ret, (string));
        if (bytes(s).length > MAX_SYMBOL_BYTES) return "";
        return s;
    }
}

interface IFloorboard {
    /// @dev MUST match `Floorboard.BidView` field for field. `ids` is dynamic,
    ///      so the struct is ABI-encoded with an offset head: a missing field
    ///      does not read as zero, it shifts every later field by one word and
    ///      `price` comes back holding an ABI offset. `SwapboardView`'s copy of
    ///      Dutchboard's equivalent struct lost two fields exactly that way.
    struct BidView {
        uint256 id;
        address bidder;
        address token;
        address quote;
        bool isNFT;
        uint40 startTime;
        uint40 duration;
        uint96 startPrice;
        uint96 endPrice;
        uint96 locked;
        uint128 initial;
        uint128 remaining;
        uint256[] ids;
        uint256 price;
        bool takeable;
    }

    function nextId() external view returns (uint256);
    function getBids(uint256 start, uint256 end) external view returns (BidView[] memory);
    function tokenDecimals(address token) external view returns (uint8);
}
