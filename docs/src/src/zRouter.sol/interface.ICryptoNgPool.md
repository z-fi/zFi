# ICryptoNgPool
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/zRouter.sol)


## Functions
### get_dx


```solidity
function get_dx(uint256 i, uint256 j, uint256 out_amount) external view returns (uint256);
```

### exchange


```solidity
function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external;
```

### calc_withdraw_one_coin


```solidity
function calc_withdraw_one_coin(uint256 token_amount, uint256 i) external view returns (uint256);
```

### remove_liquidity_one_coin


```solidity
function remove_liquidity_one_coin(uint256 token_amount, uint256 i, uint256 min_amount) external;
```

