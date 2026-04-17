# ICurveMetaRegistry
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/zQuoter.sol)


## Functions
### find_pools_for_coins


```solidity
function find_pools_for_coins(address from, address to) external view returns (address[] memory);
```

### get_coin_indices


```solidity
function get_coin_indices(address pool, address from, address to, uint256 handler_id)
    external
    view
    returns (int128 i, int128 j, bool isUnderlying);
```

