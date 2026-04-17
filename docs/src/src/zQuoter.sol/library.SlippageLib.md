# SlippageLib
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/zQuoter.sol)


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

