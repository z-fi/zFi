# ICurveMetaRegistry
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/zQuoter.sol)


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

