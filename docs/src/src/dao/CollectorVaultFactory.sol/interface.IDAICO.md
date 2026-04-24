# IDAICO
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/dao/CollectorVaultFactory.sol)


## Functions
### summonDAICOWithTapCustom


```solidity
function summonDAICOWithTapCustom(
    SummonConfig calldata summonConfig,
    string calldata orgName,
    string calldata orgSymbol,
    string calldata orgURI,
    uint16 quorumBps,
    bool ragequittable,
    address renderer,
    bytes32 salt,
    address[] calldata initHolders,
    uint256[] calldata initShares,
    bool sharesLocked,
    bool lootLocked,
    DAICOConfig calldata daicoConfig,
    TapConfig calldata tapConfig,
    Call[] calldata customCalls
) external payable returns (address dao);
```

