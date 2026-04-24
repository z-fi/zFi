# IZQuoterBase
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/zQuoter.sol)


## Functions
### quoteV2


```solidity
function quoteV2(bool, address, address, uint256, bool) external view returns (uint256, uint256);
```

### quoteV3


```solidity
function quoteV3(bool, address, address, uint24, uint256) external view returns (uint256, uint256);
```

### quoteV4


```solidity
function quoteV4(bool, address, address, uint24, int24, address, uint256) external view returns (uint256, uint256);
```

### quoteZAMM


```solidity
function quoteZAMM(bool, uint256, address, address, uint256, uint256, uint256)
    external
    view
    returns (uint256, uint256);
```

### getQuotes


```solidity
function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
    external
    view
    returns (zQuoter.Quote memory best, zQuoter.Quote[] memory quotes);
```

