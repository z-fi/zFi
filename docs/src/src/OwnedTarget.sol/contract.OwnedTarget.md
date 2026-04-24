# OwnedTarget
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/OwnedTarget.sol)

**Title:**
OwnedTarget

Minimal ERC-173 owner stub. Pair with HTMLRegistry as a target
whose owner() returns your EOA, so the EOA can publish HTML for it.
Transfer to address(0) to renounce.


## State Variables
### owner

```solidity
address public owner
```


## Functions
### constructor


```solidity
constructor() ;
```

### transferOwnership


```solidity
function transferOwnership(address newOwner) external;
```

## Events
### OwnershipTransferred

```solidity
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
```

## Errors
### NotOwner

```solidity
error NotOwner();
```

