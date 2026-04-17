# IStableNgPool
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/zRouter.sol)


## Functions
### get_dx


```solidity
function get_dx(int128 i, int128 j, uint256 out_amount) external view returns (uint256);
```

### exchange


```solidity
function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
```

### calc_token_amount


```solidity
function calc_token_amount(uint256[8] calldata _amounts, bool _is_deposit) external view returns (uint256);
```

### add_liquidity


```solidity
function add_liquidity(uint256[8] calldata _amounts, uint256 _min_mint_amount) external returns (uint256);
```

### calc_withdraw_one_coin


```solidity
function calc_withdraw_one_coin(uint256 token_amount, int128 i) external view returns (uint256);
```

### remove_liquidity_one_coin


```solidity
function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount) external;
```

