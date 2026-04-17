# PrecisionOraclePool
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/pools/PrecisionOraclePool.sol)

**Title:**
PrecisionOraclePool (ETH/USDC)

Oracle-priced pool — Chainlink sets the price, not a bonding curve.

Swaps execute at oracle price ± dynamic fee. No AMM curve.
Eliminates curve-based LVR; residual adverse selection is bounded
by Chainlink's deviation threshold and mitigated by sandwich protection.
Fee ramps from BASE_FEE (1 bps, fresh oracle) to 50 bps (at heartbeat).
First swap after an oracle price change pays max fee to block sandwich attacks.
Prior art: DODO's PMM uses oracle-priced pools with configurable
parameters stored in contract storage. This takes the precision approach:
- Oracle address, deviation threshold, heartbeat are compile-time constants
- Dynamic fee is calibrated to the specific feed's deviation threshold
- Price math uses compile-time-known decimals (ETH 18, oracle 8, USDC 6)
- No factory, no adapter, no storage reads for pool configuration
Designed for atomic integration: EIP-7702 batch, zRouter snwap, or
multisig executeBatch. Uses the balance-delta pattern (transfer-then-call)
common to Uniswap V2 pair contracts — not safe for non-atomic direct calls.


## State Variables
### TOKEN1

```solidity
address constant TOKEN1 = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```


### ORACLE

```solidity
address constant ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
```


### BASE_FEE

```solidity
uint256 constant BASE_FEE = 100
```


### STALENESS_PREMIUM

```solidity
uint256 constant STALENESS_PREMIUM = 4900
```


### HEARTBEAT

```solidity
uint256 constant HEARTBEAT = 3600
```


### PRICE_SCALE

```solidity
uint256 constant PRICE_SCALE = 1e20
```


### name

```solidity
string public constant name = "Precision Oracle LP (ETH/USDC)"
```


### symbol

```solidity
string public constant symbol = "poLP-ETH-USDC"
```


### decimals

```solidity
uint8 public constant decimals = 18
```


### reserve0

```solidity
uint128 public reserve0
```


### reserve1

```solidity
uint128 public reserve1
```


### lastPrice

```solidity
uint128 public lastPrice
```


### totalSupply

```solidity
uint128 public totalSupply
```


### balanceOf

```solidity
mapping(address => uint256) public balanceOf
```


### allowance

```solidity
mapping(address => mapping(address => uint256)) public allowance
```


## Functions
### nonReentrant


```solidity
modifier nonReentrant() ;
```

### receive


```solidity
receive() external payable;
```

### swap


```solidity
function swap(address tokenIn, uint256 minOut, address to) public payable nonReentrant returns (uint256 amountOut);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`tokenIn`|`address`|address(0) for ETH, TOKEN1 for USDC.|
|`minOut`|`uint256`||
|`to`|`address`||


### addLiquidity


```solidity
function addLiquidity(uint256 minLP, address to) public payable nonReentrant returns (uint256 lp);
```

### removeLiquidity

Withdraw proportional reserves. No oracle needed — always available.


```solidity
function removeLiquidity(uint256 lp, uint256 minAmount0, uint256 minAmount1, address to)
    public
    nonReentrant
    returns (uint256 amount0, uint256 amount1);
```

### transfer


```solidity
function transfer(address to, uint256 value) public returns (bool);
```

### approve


```solidity
function approve(address spender, uint256 value) public returns (bool);
```

### transferFrom


```solidity
function transferFrom(address from, address to, uint256 value) public returns (bool);
```

### _oraclePriceAndElapsed

Read Chainlink latestRoundData. Returns price (8 dec) and seconds since update.
Reverts StaleOracle on: failed call, zero/negative price, or elapsed > HEARTBEAT.


```solidity
function _oraclePriceAndElapsed() internal view returns (uint256 price, uint256 elapsed);
```

### _transferETH


```solidity
function _transferETH(address to, uint256 amount) internal;
```

### _transfer


```solidity
function _transfer(address token, address to, uint256 amount) internal;
```

### _balanceOf


```solidity
function _balanceOf(address token) internal view returns (uint256 amount);
```

## Events
### Transfer

```solidity
event Transfer(address indexed from, address indexed to, uint256 value);
```

### Approval

```solidity
event Approval(address indexed owner, address indexed spender, uint256 value);
```

### Swap

```solidity
event Swap(address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to);
```

### AddLiquidity

```solidity
event AddLiquidity(address indexed provider, uint256 amount0, uint256 amount1, uint256 lp);
```

### RemoveLiquidity

```solidity
event RemoveLiquidity(address indexed provider, uint256 lp, uint256 amount0, uint256 amount1);
```

## Errors
### Reentrancy

```solidity
error Reentrancy();
```

### ZeroAmount

```solidity
error ZeroAmount();
```

### StaleOracle

```solidity
error StaleOracle();
```

### InvalidToken

```solidity
error InvalidToken();
```

### ETHTransferFailed

```solidity
error ETHTransferFailed();
```

### InsufficientOutput

```solidity
error InsufficientOutput();
```

### InsufficientLPBurned

```solidity
error InsufficientLPBurned();
```

### InsufficientLiquidity

```solidity
error InsufficientLiquidity();
```

