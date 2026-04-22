# IMoloch
[Git Source](https://github.com/zammdefi/zFi/blob/a562385b5b1c1f70a26241aeea9f4ab1325a5917/src/dao/CollectorVaultFactory.sol)


## Functions
### setPermit


```solidity
function setPermit(
    uint8 op,
    address to,
    uint256 value,
    bytes calldata data,
    bytes32 nonce,
    address spender,
    uint256 count
) external;
```

### setAllowance


```solidity
function setAllowance(address who, address token, uint256 amount) external;
```

### setProposalTTL


```solidity
function setProposalTTL(uint64 secs) external;
```

### setTimelockDelay


```solidity
function setTimelockDelay(uint64 secs) external;
```

