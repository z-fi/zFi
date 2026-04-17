# Bitgetol
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/forwarders/Bitgetol.sol)


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

