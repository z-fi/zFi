# ISummoner
[Git Source](https://github.com/zammdefi/zFi/blob/a562385b5b1c1f70a26241aeea9f4ab1325a5917/src/dao/SafeSummoner.sol)


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

