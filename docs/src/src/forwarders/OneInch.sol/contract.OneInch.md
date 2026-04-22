# OneInch
[Git Source](https://github.com/zammdefi/zFi/blob/a562385b5b1c1f70a26241aeea9f4ab1325a5917/src/forwarders/OneInch.sol)


## State Variables
### ROUTER

```solidity
address constant ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65
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

