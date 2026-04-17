# Bebop
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/forwarders/Bebop.sol)


## State Variables
### JAM_BALANCE_MGR

```solidity
address constant JAM_BALANCE_MGR = 0xC5a350853E4e36b73EB0C24aaA4b8816C9A3579a
```


### BEBOP_BLEND

```solidity
address constant BEBOP_BLEND = 0xbbbbbBB520d69a9775E85b458C58c648259FAD5F
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

