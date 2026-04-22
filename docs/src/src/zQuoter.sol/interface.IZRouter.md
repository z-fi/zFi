# IZRouter
[Git Source](https://github.com/zammdefi/zFi/blob/a562385b5b1c1f70a26241aeea9f4ab1325a5917/src/zQuoter.sol)


## Functions
### swapV2


```solidity
function swapV2(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) external payable returns (uint256 amountIn, uint256 amountOut);
```

### swapVZ


```solidity
function swapVZ(
    address to,
    bool exactOut,
    uint256 feeOrHook,
    address tokenIn,
    address tokenOut,
    uint256 idIn,
    uint256 idOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) external payable returns (uint256 amountIn, uint256 amountOut);
```

### swapV3


```solidity
function swapV3(
    address to,
    bool exactOut,
    uint24 swapFee,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) external payable returns (uint256 amountIn, uint256 amountOut);
```

### swapV4


```solidity
function swapV4(
    address to,
    bool exactOut,
    uint24 swapFee,
    int24 tickSpace,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) external payable returns (uint256 amountIn, uint256 amountOut);
```

### swapCurve


```solidity
function swapCurve(
    address to,
    bool exactOut,
    address[11] calldata route,
    uint256[4][5] calldata swapParams, // [i, j, swap_type, pool_type]
    address[5] calldata basePools, // for meta pools (only used by type=2 get_dx)
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) external payable returns (uint256 amountIn, uint256 amountOut);
```

### exactETHToSTETH


```solidity
function exactETHToSTETH(address to) external payable returns (uint256 shares);
```

### exactETHToWSTETH


```solidity
function exactETHToWSTETH(address to) external payable returns (uint256 wstOut);
```

### ethToExactSTETH


```solidity
function ethToExactSTETH(address to, uint256 exactOut) external payable;
```

### ethToExactWSTETH


```solidity
function ethToExactWSTETH(address to, uint256 exactOut) external payable;
```

