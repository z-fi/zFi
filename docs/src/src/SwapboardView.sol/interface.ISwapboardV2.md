# ISwapboardV2
[Git Source](https://github.com/zammdefi/zFi/blob/a562385b5b1c1f70a26241aeea9f4ab1325a5917/src/SwapboardView.sol)

New Swapboard — Order struct includes partialFill.


## Functions
### nextOrderId


```solidity
function nextOrderId() external view returns (uint256);
```

### getOrders


```solidity
function getOrders(uint256[] calldata orderIds) external view returns (Order[] memory);
```

## Structs
### Order

```solidity
struct Order {
    address maker;
    bool active;
    bool partialFill;
    address tokenA;
    uint256 amountA;
    address tokenB;
    uint256 amountB;
}
```

