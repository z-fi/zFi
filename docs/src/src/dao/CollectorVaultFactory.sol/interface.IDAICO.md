# IDAICO
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/dao/CollectorVaultFactory.sol)


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

