# Summoner
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/dao/Moloch.sol)

**Title:**
Moloch (Majeur) Summoner


## State Variables
### daos

```solidity
Moloch[] public daos
```


### implementation

```solidity
Moloch immutable implementation
```


## Functions
### constructor


```solidity
constructor() payable;
```

### summon

Summon new Majeur clone with initialization calls:


```solidity
function summon(
    string calldata orgName,
    string calldata orgSymbol,
    string calldata orgURI,
    uint16 quorumBps, // e.g. 5000 = 50% turnout of snapshot supply
    bool ragequittable,
    address renderer,
    bytes32 salt,
    address[] calldata initHolders,
    uint256[] calldata initShares,
    Call[] calldata initCalls
) public payable returns (Moloch dao);
```

### getDAOCount

Get dao array push count:


```solidity
function getDAOCount() public view returns (uint256);
```

## Events
### NewDAO

```solidity
event NewDAO(address indexed summoner, Moloch indexed dao);
```

