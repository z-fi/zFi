# OKXol
[Git Source](https://github.com/zammdefi/zFi/blob/a562385b5b1c1f70a26241aeea9f4ab1325a5917/src/forwarders/OKXol.sol)


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

