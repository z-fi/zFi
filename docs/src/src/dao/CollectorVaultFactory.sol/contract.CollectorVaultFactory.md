# CollectorVaultFactory
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/dao/CollectorVaultFactory.sol)

**Title:**
CollectorVaultFactory

Deploys CollectorVault clones with ShareBurner permit wiring for DAICO integration.
Usage (two calls, batchable via multicall):
1. factory.deploy(mp, salt, deadline) → vault (CREATE2 clone)
2. DAICO.summonDAICOWithTapCustom(..., tapConfig(vault), [..., factory.permitCall(...)])
Or use deployAndSummon() for opinionated single-tx atomic deploy with DAICO/bare DAO.
Or use deployAndSummonRaw() for custom calldata escape hatch.


## State Variables
### DAICO

```solidity
address public constant DAICO = 0x000000000033e92DB97B4B3beCD2c255126C60aC
```


### SUMMONER

```solidity
address public constant SUMMONER = 0x0000000000330B8df9E3bc5E553074DA58eE9138
```


### MOLOCH_IMPL

```solidity
address public constant MOLOCH_IMPL = 0x643A45B599D81be3f3A68F37EB3De55fF10673C1
```


### SHARES_IMPL

```solidity
address public constant SHARES_IMPL = 0x71E9b38d301b5A58cb998C1295045FE276Acf600
```


### LOOT_IMPL

```solidity
address public constant LOOT_IMPL = 0x6f1f2aF76a3aDD953277e9F369242697C87bc6A5
```


### RENDERER

```solidity
address public constant RENDERER = 0x000000000011C799980827F52d3137b4abD6E654
```


### BURNER

```solidity
address public constant BURNER = 0x000000000040084694F7B6fb2846D067B4c3Aa9f
```


### vaultImpl

```solidity
address public immutable vaultImpl
```


## Functions
### constructor


```solidity
constructor() payable;
```

### deploy

Deploy a CollectorVault clone for a predicted (or existing) DAO.
Caller is responsible for summoning the DAICO with the vault
as tap recipient and including the permit call from permitCall().


```solidity
function deploy(VaultParams calldata vp, bytes32 salt, uint40 deadline) public returns (address vault);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`vp`|`VaultParams`|      Vault configuration|
|`salt`|`bytes32`|    CREATE2 salt (also used as permit nonce). Must match DAICO salt.|
|`deadline`|`uint40`|Sale deadline (uint40 from DAICOConfig, cast to uint256)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`vault`|`address`| The deployed CollectorVault clone|


### deployAndSummon

Deploy vault + summon DAO atomically. Branches on lpBps:
lpBps != 0: Full DAICO sale + LP + tap (vault as tap ops).
lpBps == 0: Bare Moloch DAO, allowance-based sale via vault.buy().


```solidity
function deployAndSummon(VaultParams calldata vp, DAICOParams calldata dp, bytes32 salt)
    public
    returns (address dao, address vault);
```

### deployAndSummonRaw

Deploy vault clone + summon DAICO atomically. Caller provides the
fully-encoded DAICO summon calldata.


```solidity
function deployAndSummonRaw(VaultParams calldata vp, bytes32 salt, uint40 deadline, bytes calldata summonCalldata)
    public
    returns (address dao, address vault);
```

### predictDAO

Predict the DAO address for a given salt.


```solidity
function predictDAO(bytes32 salt) public pure returns (address);
```

### predictShares

Predict the shares token address for a given salt.


```solidity
function predictShares(bytes32 salt) public pure returns (address);
```

### predictVault

Predict the vault clone address for a given salt.


```solidity
function predictVault(bytes32 salt) public view returns (address);
```

### permitCall

Generate the permit Call for inclusion in DAICO customCalls.
Sets up a one-shot permit: ShareBurner singleton is both
delegatecall target and spender. Anyone can trigger burn via
ShareBurner.closeSale(dao, shares, deadline, nonce).


```solidity
function permitCall(bytes32 salt, uint256 deadline)
    public
    pure
    returns (address target, uint256 value, bytes memory data);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`salt`|`bytes32`|    Must match deploy salt (also used as permit nonce)|
|`deadline`|`uint256`|Sale deadline (encoded into burnUnsold data for on-chain enforcement)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`target`|`address`| The DAO address the call targets|
|`value`|`uint256`|  Always 0|
|`data`|`bytes`|   Encoded setPermit call|


### _buildCustomCalls

Build the custom init calls array for DAO setup.


```solidity
function _buildCustomCalls(
    address predictedDAO,
    address predictedShares,
    address vault,
    bytes32 salt,
    DAICOParams calldata dp
) internal pure returns (Call[] memory calls);
```

### _callSummoner

Call the bare Moloch summoner (lpBps == 0 path).


```solidity
function _callSummoner(DAICOParams calldata dp, bytes32 salt, Call[] memory initCalls)
    internal
    returns (bytes memory);
```

### _clone

Deploy a PUSH0 minimal proxy clone via CREATE2.


```solidity
function _clone(address impl, bytes32 salt) internal returns (address clone);
```

### _predictDAO


```solidity
function _predictDAO(bytes32 salt) internal pure returns (address);
```

### _predictShares


```solidity
function _predictShares(address dao_) internal pure returns (address);
```

### _predictClone


```solidity
function _predictClone(address impl, bytes32 salt_, address deployer_) internal pure returns (address);
```

## Events
### Deployed

```solidity
event Deployed(address indexed dao, address indexed vault, uint8 mode);
```

## Structs
### VaultParams

```solidity
struct VaultParams {
    uint8 mode;
    address target;
    uint256 ethPerCall;
    uint256 maxCalls;
    bytes payload;
    address token;
    uint256 minBalance;
    bool specificId;
}
```

### DAICOParams

```solidity
struct DAICOParams {
    // Sale economics
    address tribTkn; // address(0) for ETH
    uint256 tribAmt; // price per share unit
    uint256 saleSupply; // total shares for sale
    uint256 forAmt; // shares per tribAmt
    uint40 deadline; // sale deadline
    bool sellLoot;
    uint16 lpBps; // >0 = DAICO sale + LP, 0 = allowance-based vault sale
    uint16 maxSlipBps;
    uint256 feeOrHook;
    // Tap (ignored when lpBps == 0)
    uint128 ratePerSec;
    uint256 tapAllowance;
    // Governance
    uint16 quorumBps;
    uint64 votingSecs; // 0 = skip
    uint64 timelockSecs; // 0 = skip
    // Org
    string orgName;
    string orgSymbol;
    string orgURI;
}
```

