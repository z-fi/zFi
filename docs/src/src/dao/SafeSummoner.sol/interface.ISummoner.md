# ISummoner
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/dao/SafeSummoner.sol)


## Functions
### summon


```solidity
function summon(
    string calldata orgName,
    string calldata orgSymbol,
    string calldata orgURI,
    uint16 quorumBps,
    bool ragequittable,
    address renderer,
    bytes32 salt,
    address[] calldata initHolders,
    uint256[] calldata initShares,
    Call[] calldata initCalls
) external payable returns (address);
```

