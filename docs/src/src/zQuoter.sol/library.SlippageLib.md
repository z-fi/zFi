# SlippageLib
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/zQuoter.sol)


## State Variables
### BPS

```solidity
uint256 constant BPS = 10_000
```


## Functions
### limit


```solidity
function limit(bool exactOut, uint256 quoted, uint256 bps) internal pure returns (uint256);
```

## Errors
### SlippageBpsTooHigh

```solidity
error SlippageBpsTooHigh();
```

