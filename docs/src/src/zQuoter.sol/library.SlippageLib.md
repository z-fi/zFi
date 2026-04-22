# SlippageLib
[Git Source](https://github.com/zammdefi/zFi/blob/a562385b5b1c1f70a26241aeea9f4ab1325a5917/src/zQuoter.sol)


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

