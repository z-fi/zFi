# Parasol
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/forwarders/Parasol.sol)


## State Variables
### AUGUSTUS

```solidity
address constant AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068
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

