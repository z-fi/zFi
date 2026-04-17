# zRouter
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/zRouter.sol)

uniV2 / uniV3 / uniV4 / zAMM
multi-amm multi-call router
optimized with simple abi.
Includes trusted routers,
and a Curve AMM swapper,
as well as Lido staker,
and generic executor.


## State Variables
### safeExecutor

```solidity
SafeExecutor public immutable safeExecutor
```


### _owner

```solidity
address _owner
```


### _isTrustedForCall

```solidity
mapping(address target => bool) _isTrustedForCall
```


## Functions
### checkDeadline


```solidity
modifier checkDeadline(uint256 deadline) ;
```

### constructor


```solidity
constructor() payable;
```

### swapV2


```solidity
function swapV2(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut);
```

### swapV3


```solidity
function swapV3(
    address to,
    bool exactOut,
    uint24 swapFee,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut);
```

### fallback

`uniswapV3SwapCallback`.


```solidity
fallback() external payable;
```

### swapV4


```solidity
function swapV4(
    address to,
    bool exactOut,
    uint24 swapFee,
    int24 tickSpace,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut);
```

### unlockCallback

Handle V4 PoolManager swap callback - hookless default.


```solidity
function unlockCallback(bytes calldata callbackData) public payable returns (bytes memory result);
```

### _swap


```solidity
function _swap(uint256 swapAmount, V4PoolKey memory key, bool zeroForOne, bool exactOut)
    internal
    returns (int256 delta);
```

### swapVZ

Pull in full and refund excess against zAMM.


```solidity
function swapVZ(
    address to,
    bool exactOut,
    uint256 feeOrHook,
    address tokenIn,
    address tokenOut,
    uint256 idIn,
    uint256 idOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut);
```

### swapCurve


```solidity
function swapCurve(
    address to,
    bool exactOut,
    address[11] calldata route,
    uint256[4][5] calldata swapParams, // [i, j, swap_type, pool_type]
    address[5] calldata basePools, // for meta pools (only used by type=2 get_dx)
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline
) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut);
```

### _isETH


```solidity
function _isETH(address a) internal pure returns (bool r);
```

### addLiquidity

To be called for zAMM following deposit() or other swaps in sequence.


```solidity
function addLiquidity(
    PoolKey calldata poolKey,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address to,
    uint256 deadline
) public payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);
```

### ensureAllowance


```solidity
function ensureAllowance(address token, bool is6909, address to) public payable onlyOwner;
```

### permit


```solidity
function permit(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public payable;
```

### permitDAI


```solidity
function permitDAI(uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s) public payable;
```

### permit2TransferFrom


```solidity
function permit2TransferFrom(
    address token,
    uint256 amount,
    uint256 nonce,
    uint256 deadline,
    bytes calldata signature
) public payable;
```

### permit2BatchTransferFrom


```solidity
function permit2BatchTransferFrom(
    IPermit2.TokenPermissions[] calldata permitted,
    uint256 nonce,
    uint256 deadline,
    bytes calldata signature
) public payable;
```

### multicall


```solidity
function multicall(bytes[] calldata data) public payable returns (bytes[] memory results);
```

### deposit


```solidity
function deposit(address token, uint256 id, uint256 amount) public payable;
```

### _useTransientBalance


```solidity
function _useTransientBalance(address user, address token, uint256 id, uint256 amount)
    internal
    returns (bool credited);
```

### _safeTransferETH


```solidity
function _safeTransferETH(address to, uint256 amount) internal;
```

### receive


```solidity
receive() external payable;
```

### sweep


```solidity
function sweep(address token, uint256 id, uint256 amount, address to) public payable;
```

### wrap


```solidity
function wrap(uint256 amount) public payable;
```

### unwrap


```solidity
function unwrap(uint256 amount) public payable;
```

### _v2PoolFor


```solidity
function _v2PoolFor(address tokenA, address tokenB, bool sushi)
    internal
    pure
    returns (address v2pool, bool zeroForOne);
```

### _v3PoolFor


```solidity
function _v3PoolFor(address tokenA, address tokenB, uint24 fee)
    internal
    pure
    returns (address v3pool, bool zeroForOne);
```

### _computeV3pool


```solidity
function _computeV3pool(address token0, address token1, uint24 fee) internal pure returns (address v3pool);
```

### _hash


```solidity
function _hash(address value0, address value1, uint24 value2) internal pure returns (bytes32 result);
```

### _sortTokens


```solidity
function _sortTokens(address tokenA, address tokenB)
    internal
    pure
    returns (address token0, address token1, bool zeroForOne);
```

### onlyOwner


```solidity
modifier onlyOwner() ;
```

### trust


```solidity
function trust(address target, bool ok) public payable onlyOwner;
```

### transferOwnership


```solidity
function transferOwnership(address owner) public payable onlyOwner;
```

### execute


```solidity
function execute(address target, uint256 value, bytes calldata data) public payable returns (bytes memory result);
```

### snwap


```solidity
function snwap(
    address tokenIn,
    uint256 amountIn,
    address recipient,
    address tokenOut,
    uint256 amountOutMin,
    address executor,
    bytes calldata executorData
) public payable returns (uint256 amountOut);
```

### snwapMulti


```solidity
function snwapMulti(
    address tokenIn,
    uint256 amountIn,
    address recipient,
    address[] calldata tokensOut,
    uint256[] calldata amountsOutMin,
    address executor,
    bytes calldata executorData
) public payable returns (uint256[] memory amountsOut);
```

### exactETHToSTETH


```solidity
function exactETHToSTETH(address to) public payable returns (uint256 shares);
```

### exactETHToWSTETH


```solidity
function exactETHToWSTETH(address to) public payable returns (uint256 wstOut);
```

### ethToExactSTETH


```solidity
function ethToExactSTETH(address to, uint256 exactOut) public payable;
```

### ethToExactWSTETH


```solidity
function ethToExactWSTETH(address to, uint256 exactOut) public payable;
```

### onERC721Received


```solidity
function onERC721Received(address, address, uint256, bytes calldata) public pure returns (bytes4);
```

### revealName

Reveal and register a .wei name after commitment.

User must first commit on NameNFT using `makeCommitment(label, routerAddress, derivedSecret)`.
The derived secret is `keccak256(abi.encode(innerSecret, to))`, binding the commitment
to the intended recipient. This prevents mempool front-running of the reveal tx.
Chain with swap via multicall for atomic swap-to-reveal. Excess ETH stays in
router for sweep.


```solidity
function revealName(string calldata label, bytes32 innerSecret, address to)
    public
    payable
    returns (uint256 tokenId);
```

## Events
### OwnershipTransferred

```solidity
event OwnershipTransferred(address indexed from, address indexed to);
```

## Errors
### BadSwap

```solidity
error BadSwap();
```

### Expired

```solidity
error Expired();
```

### Slippage

```solidity
error Slippage();
```

### InvalidId

```solidity
error InvalidId();
```

### Unauthorized

```solidity
error Unauthorized();
```

### InvalidMsgVal

```solidity
error InvalidMsgVal();
```

### SwapExactInFail

```solidity
error SwapExactInFail();
```

### SwapExactOutFail

```solidity
error SwapExactOutFail();
```

### ETHTransferFailed

```solidity
error ETHTransferFailed();
```

### SnwapSlippage

```solidity
error SnwapSlippage(address token, uint256 received, uint256 minimum);
```

