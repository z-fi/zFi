# SwapboardView
[Git Source](https://github.com/zammdefi/zFi/blob/a562385b5b1c1f70a26241aeea9f4ab1325a5917/src/SwapboardView.sol)

**Title:**
SwapboardView

Read-only helper that returns active orders from both Swapboard contracts
(v1 all-or-nothing + v2 partial-fill) with token metadata in a single call.

Intended for `eth_call` only — not meant to be called on-chain in transactions.


## Functions
### getAllActiveOrders

Returns all active orders from both Swapboards merged into one array.


```solidity
function getAllActiveOrders(address boardV1, address boardV2) external view returns (OrderView[] memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`boardV1`|`address`|The original Swapboard (all-or-nothing, no partialFill field).|
|`boardV2`|`address`|The new Swapboard (supports partialFill).|


### getAllActiveOrdersPaged

Paginated read merging both Swapboards. Scans each board independently.


```solidity
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
    returns (OrderView[] memory ordersV1, uint256 nextStartV1, OrderView[] memory ordersV2, uint256 nextStartV2);
```

### _readBoard


```solidity
function _readBoard(address board, bool isV1) internal view returns (OrderView[] memory);
```

### _readBoardPaged


```solidity
function _readBoardPaged(address board, uint256 startId, uint256 limit, uint256 maxScan, bool isV1)
    internal
    view
    returns (OrderView[] memory orders, uint256 nextStart);
```

### _buildFromV1


```solidity
function _buildFromV1(ISwapboardV1.Order[] memory raw, uint256 startId, address board)
    internal
    view
    returns (OrderView[] memory);
```

### _buildFromV2


```solidity
function _buildFromV2(ISwapboardV2.Order[] memory raw, uint256 startId, address board)
    internal
    view
    returns (OrderView[] memory);
```

### _collectUniqueTokensV1


```solidity
function _collectUniqueTokensV1(ISwapboardV1.Order[] memory raw)
    internal
    pure
    returns (address[] memory tokens, uint256 count);
```

### _collectUniqueTokensV2


```solidity
function _collectUniqueTokensV2(ISwapboardV2.Order[] memory raw)
    internal
    pure
    returns (address[] memory tokens, uint256 count);
```

### _contains


```solidity
function _contains(address[] memory arr, uint256 len, address val) internal pure returns (bool);
```

### _batchMeta


```solidity
function _batchMeta(address[] memory tokens, uint256 count)
    internal
    view
    returns (string[] memory symbols, uint8[] memory decs);
```

### _applyMeta


```solidity
function _applyMeta(
    OrderView memory o,
    address[] memory tokens,
    string[] memory symbols,
    uint8[] memory decs,
    uint256 count
) internal pure;
```

### _tokenMeta


```solidity
function _tokenMeta(address token) internal view returns (string memory symbol, uint8 decimals);
```

## Structs
### OrderView

```solidity
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
```

