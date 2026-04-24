# Bitgetol
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/forwarders/Bitgetol.sol)


## State Variables
### BK_SWAP_ROUTER

```solidity
address constant BK_SWAP_ROUTER = 0xBc1D9760bd6ca468CA9fB5Ff2CFbEAC35d86c973
```


## Functions
### swap


```solidity
function swap(address router, address tokenIn, address tokenOut, address recipient, bytes calldata data)
    public
    payable;
```

### receive


```solidity
receive() external payable;
```

