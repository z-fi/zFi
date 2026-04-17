# OKXol
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/forwarders/OKXol.sol)


## State Variables
### OKX_TOKEN_APPROVE

```solidity
address constant OKX_TOKEN_APPROVE = 0x40aA958dd87FC8305b97f2BA922CDdCa374bcD7f
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

