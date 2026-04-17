// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title SwapboardView
/// @notice Read-only helper that returns active orders from both Swapboard contracts
///         (v1 all-or-nothing + v2 partial-fill) with token metadata in a single call.
/// @dev Intended for `eth_call` only — not meant to be called on-chain in transactions.
contract SwapboardView {
    struct OrderView {
        uint256 orderId;
        address maker;
        bool partialFill;
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

    /// @notice Returns all active orders from both Swapboards merged into one array.
    /// @param boardV1 The original Swapboard (all-or-nothing, no partialFill field).
    /// @param boardV2 The new Swapboard (supports partialFill).
    function getAllActiveOrders(address boardV1, address boardV2) external view returns (OrderView[] memory) {
        OrderView[] memory a = _readBoard(boardV1, true);
        OrderView[] memory b = _readBoard(boardV2, false);

        OrderView[] memory merged = new OrderView[](a.length + b.length);
        for (uint256 i; i < a.length; i++) {
            merged[i] = a[i];
        }
        for (uint256 i; i < b.length; i++) {
            merged[a.length + i] = b[i];
        }
        return merged;
    }

    /// @notice Paginated read merging both Swapboards. Scans each board independently.
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
        (ordersV1, nextStartV1) = _readBoardPaged(boardV1, startIdV1, limit, maxScan, true);
        (ordersV2, nextStartV2) = _readBoardPaged(boardV2, startIdV2, limit, maxScan, false);
    }

    // ---- Internal ----

    function _readBoard(address board, bool isV1) internal view returns (OrderView[] memory) {
        uint256 total = isV1 ? ISwapboardV1(board).nextOrderId() : ISwapboardV2(board).nextOrderId();
        if (total == 0) return new OrderView[](0);

        uint256[] memory allIds = new uint256[](total);
        for (uint256 i; i < total; i++) {
            allIds[i] = i;
        }

        if (isV1) {
            return _buildFromV1(ISwapboardV1(board).getOrders(allIds), 0, board);
        } else {
            return _buildFromV2(ISwapboardV2(board).getOrders(allIds), 0, board);
        }
    }

    function _readBoardPaged(address board, uint256 startId, uint256 limit, uint256 maxScan, bool isV1)
        internal
        view
        returns (OrderView[] memory orders, uint256 nextStart)
    {
        uint256 total = isV1 ? ISwapboardV1(board).nextOrderId() : ISwapboardV2(board).nextOrderId();
        if (startId >= total) return (new OrderView[](0), 0);

        uint256 end = startId + maxScan;
        if (end > total) end = total;
        uint256 scanLen = end - startId;

        uint256[] memory ids = new uint256[](scanLen);
        for (uint256 i; i < scanLen; i++) {
            ids[i] = startId + i;
        }

        OrderView[] memory all;
        if (isV1) {
            all = _buildFromV1(ISwapboardV1(board).getOrders(ids), startId, board);
        } else {
            all = _buildFromV2(ISwapboardV2(board).getOrders(ids), startId, board);
        }

        if (all.length > limit) {
            orders = new OrderView[](limit);
            for (uint256 i; i < limit; i++) {
                orders[i] = all[i];
            }
        } else {
            orders = all;
        }

        nextStart = end < total ? end : 0;
    }

    function _buildFromV1(ISwapboardV1.Order[] memory raw, uint256 startId, address board)
        internal
        view
        returns (OrderView[] memory)
    {
        (address[] memory tokens, uint256 tokenCount) = _collectUniqueTokensV1(raw);
        (string[] memory symbols, uint8[] memory decs) = _batchMeta(tokens, tokenCount);

        uint256 count;
        for (uint256 i; i < raw.length; i++) {
            if (raw[i].active) count++;
        }

        OrderView[] memory result = new OrderView[](count);
        uint256 idx;
        for (uint256 i; i < raw.length; i++) {
            if (!raw[i].active) continue;
            result[idx].orderId = startId + i;
            result[idx].maker = raw[i].maker;
            result[idx].tokenA = raw[i].tokenA;
            result[idx].amountA = raw[i].amountA;
            result[idx].tokenB = raw[i].tokenB;
            result[idx].amountB = raw[i].amountB;
            result[idx].board = board;
            _applyMeta(result[idx], tokens, symbols, decs, tokenCount);
            idx++;
        }
        return result;
    }

    function _buildFromV2(ISwapboardV2.Order[] memory raw, uint256 startId, address board)
        internal
        view
        returns (OrderView[] memory)
    {
        (address[] memory tokens, uint256 tokenCount) = _collectUniqueTokensV2(raw);
        (string[] memory symbols, uint8[] memory decs) = _batchMeta(tokens, tokenCount);

        uint256 count;
        for (uint256 i; i < raw.length; i++) {
            if (raw[i].active) count++;
        }

        OrderView[] memory result = new OrderView[](count);
        uint256 idx;
        for (uint256 i; i < raw.length; i++) {
            if (!raw[i].active) continue;
            result[idx].orderId = startId + i;
            result[idx].maker = raw[i].maker;
            result[idx].partialFill = raw[i].partialFill;
            result[idx].tokenA = raw[i].tokenA;
            result[idx].amountA = raw[i].amountA;
            result[idx].tokenB = raw[i].tokenB;
            result[idx].amountB = raw[i].amountB;
            result[idx].board = board;
            _applyMeta(result[idx], tokens, symbols, decs, tokenCount);
            idx++;
        }
        return result;
    }

    // ---- Token metadata helpers ----

    function _collectUniqueTokensV1(ISwapboardV1.Order[] memory raw)
        internal
        pure
        returns (address[] memory tokens, uint256 count)
    {
        tokens = new address[](raw.length * 2);
        for (uint256 i; i < raw.length; i++) {
            if (!raw[i].active) continue;
            if (!_contains(tokens, count, raw[i].tokenA)) tokens[count++] = raw[i].tokenA;
            if (!_contains(tokens, count, raw[i].tokenB)) tokens[count++] = raw[i].tokenB;
        }
    }

    function _collectUniqueTokensV2(ISwapboardV2.Order[] memory raw)
        internal
        pure
        returns (address[] memory tokens, uint256 count)
    {
        tokens = new address[](raw.length * 2);
        for (uint256 i; i < raw.length; i++) {
            if (!raw[i].active) continue;
            if (!_contains(tokens, count, raw[i].tokenA)) tokens[count++] = raw[i].tokenA;
            if (!_contains(tokens, count, raw[i].tokenB)) tokens[count++] = raw[i].tokenB;
        }
    }

    function _contains(address[] memory arr, uint256 len, address val) internal pure returns (bool) {
        for (uint256 i; i < len; i++) {
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
        for (uint256 i; i < count; i++) {
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
        for (uint256 i; i < count && found < 2; i++) {
            if (tokens[i] == o.tokenA) {
                o.symbolA = symbols[i];
                o.decimalsA = decs[i];
                found++;
            } else if (tokens[i] == o.tokenB) {
                o.symbolB = symbols[i];
                o.decimalsB = decs[i];
                found++;
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

/// @dev Old Swapboard — Order struct has no partialFill field.
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

/// @dev New Swapboard — Order struct includes partialFill.
interface ISwapboardV2 {
    struct Order {
        address maker;
        bool active;
        bool partialFill;
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
    }

    function nextOrderId() external view returns (uint256);
    function getOrders(uint256[] calldata orderIds) external view returns (Order[] memory);
}

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}
