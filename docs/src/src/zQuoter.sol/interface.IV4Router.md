# IV4Router
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/zQuoter.sol)


## Functions
### swapExactTokensForTokens


```solidity
function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    bool zeroForOne,
    IV4PoolKey calldata poolKey,
    bytes calldata hookData,
    address to,
    uint256 deadline
) external payable returns (int256);
```

