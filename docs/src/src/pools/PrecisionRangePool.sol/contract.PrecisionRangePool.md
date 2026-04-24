# PrecisionRangePool
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/pools/PrecisionRangePool.sol)

**Title:**
PrecisionRangePool (ETH/USDC $2200-$3000)

Concentrated constant-product pool for a single pair and fixed price range.

Integrates with zRouter via snwap. Uses native ETH (not WETH).
Virtual reserves concentrate liquidity into the hardcoded range.
Real reserves: x (ETH), y (USDC)
Virtual reserves: X = x + L/sqrt(pHigh), Y = y + L*sqrt(pLow)
Invariant: X * Y = L^2


## State Variables
### TOKEN1

```solidity
address constant TOKEN1 = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```


### SWAP_FEE

```solidity
uint256 constant SWAP_FEE = 500
```


### SQRT_P_LOW

```solidity
uint256 constant SQRT_P_LOW = 46904157598234
```


### SQRT_P_HIGH

```solidity
uint256 constant SQRT_P_HIGH = 54772255750516
```


### ONE_MINUS_AB

```solidity
uint256 constant ONE_MINUS_AB = 143651161422320512
```


### name

```solidity
string public constant name = "Precision Range LP (ETH/USDC 2200-3000)"
```


### symbol

```solidity
string public constant symbol = "prLP-ETH-USDC-2200-3000"
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


### totalSupply

```solidity
uint256 public totalSupply
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

### _virtualReserve0


```solidity
function _virtualReserve0() internal view returns (uint256);
```

### _virtualReserve1


```solidity
function _virtualReserve1() internal view returns (uint256);
```

### _sqrt


```solidity
function _sqrt(uint256 x) internal pure returns (uint256 z);
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

