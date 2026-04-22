# Parasol
[Git Source](https://github.com/zammdefi/zFi/blob/a562385b5b1c1f70a26241aeea9f4ab1325a5917/src/forwarders/Parasol.sol)


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

