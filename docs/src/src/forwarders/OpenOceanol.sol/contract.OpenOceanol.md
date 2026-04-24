# OpenOceanol
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/forwarders/OpenOceanol.sol)


## State Variables
### OO_ROUTER

```solidity
address constant OO_ROUTER = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64
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

