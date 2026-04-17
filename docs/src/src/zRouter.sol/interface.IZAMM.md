# IZAMM
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/zRouter.sol)


## Functions
### addLiquidity


```solidity
function addLiquidity(
    PoolKey calldata poolKey,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address to,
    uint256 deadline
) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);
```

