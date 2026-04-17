# PrecisionStablePool
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/pools/PrecisionStablePool.sol)

**Title:**
PrecisionStablePool (USDT/USDC)

Stableswap pool for a single pair. Curve math, no generality.

Integrates with zRouter via snwap (SafeExecutor calls `swap`).
Invariant (n=2): 4A(x + y) + D = 4AD + D^3 / (4xy)


## State Variables
### TOKEN0

```solidity
address constant TOKEN0 = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```


### TOKEN1

```solidity
address constant TOKEN1 = 0xdAC17F958D2ee523a2206206994597C13D831ec7
```


### ANN

```solidity
uint256 constant ANN = 8000
```


### SWAP_FEE

```solidity
uint256 constant SWAP_FEE = 50
```


### name

```solidity
string public constant name = "Precision Stable LP (USDT/USDC)"
```


### symbol

```solidity
string public constant symbol = "psLP-USDT-USDC"
```


### decimals

```solidity
uint8 public constant decimals = 6
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

### swap


```solidity
function swap(address tokenIn, uint256 minOut, address to) public nonReentrant returns (uint256 amountOut);
```

### addLiquidity


```solidity
function addLiquidity(uint256 minLP, address to) public nonReentrant returns (uint256 lp);
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

### _computeD

Compute invariant D. Newton: D = (ANN*S + 2*Dp) * D / ((ANN-1)*D + 3*Dp)


```solidity
function _computeD(uint256 x, uint256 y) internal pure returns (uint256 d);
```

### _computeY

Compute reserve y given reserve x and invariant D.
Newton: y = (y^2 + c) / (2y + b - D)


```solidity
function _computeY(uint256 xKnown, uint256 d) internal pure returns (uint256 y);
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

