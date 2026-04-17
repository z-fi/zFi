# zQuoter
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/zQuoter.sol)


## Functions
### constructor


```solidity
constructor() payable;
```

### getQuotes


```solidity
function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
    public
    view
    returns (Quote memory best, Quote[] memory quotes);
```

### _asQuote


```solidity
function _asQuote(AMM source, uint256 amountIn, uint256 amountOut) internal pure returns (Quote memory q);
```

### _quoteBestSingleHop

Unified single-hop quoting across all AMMs.


```solidity
function _quoteBestSingleHop(bool exactOut, address tokenIn, address tokenOut, uint256 amount)
    internal
    view
    returns (Quote memory best);
```

### _normalizeETH

Normalize CURVE_ETH sentinel to address(0) so all ETH logic is consistent.


```solidity
function _normalizeETH(address token) internal pure returns (address);
```

### _hubs


```solidity
function _hubs() internal pure returns (address[6] memory);
```

### _sweepTo


```solidity
function _sweepTo(address token, address to) internal pure returns (bytes memory);
```

### _mc


```solidity
function _mc(bytes[] memory c) internal pure returns (bytes memory);
```

### _mc1


```solidity
function _mc1(bytes memory cd) internal pure returns (bytes memory);
```

### _wrap


```solidity
function _wrap(uint256 a) internal pure returns (bytes memory);
```

### _depUnwrap


```solidity
function _depUnwrap(uint256 a) internal pure returns (bytes memory d, bytes memory u);
```

### _i8


```solidity
function _i8(int128 x) internal pure returns (uint8);
```

### _isBetter


```solidity
function _isBetter(bool exactOut, uint256 newIn, uint256 newOut, uint256 bestIn, uint256 bestOut)
    internal
    pure
    returns (bool);
```

### quoteCurve


```solidity
function quoteCurve(
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 maxCandidates // e.g. 8, 0 = unlimited
)
    public
    view
    returns (
        uint256 amountIn,
        uint256 amountOut,
        address bestPool,
        bool usedUnderlying,
        bool usedStable,
        uint8 iIndex,
        uint8 jIndex
    );
```

### _tryCoinIndices

Try to get coin indices from the MetaRegistry; returns (ok, i, j, underlying).
Wraps the external call in a try/catch so reverts don't propagate.


```solidity
function _tryCoinIndices(address pool, address a, address b)
    internal
    view
    returns (bool ok, int128 i, int128 j, bool underlying);
```

### _curveTryQuoteOne


```solidity
function _curveTryQuoteOne(address pool, bool exactOut, int128 i, int128 j, bool underlying, uint256 amt)
    internal
    view
    returns (bool ok, uint256 amountIn, uint256 amountOut, bool usedStable, bool usedUnderlying);
```

### _buildCurveSwapCalldata


```solidity
function _buildCurveSwapCalldata(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 slippageBps,
    uint256 deadline,
    address pool,
    bool useUnderlying,
    bool isStable,
    uint8 iIndex,
    uint8 jIndex,
    uint256 amountIn,
    uint256 amountOut
) internal pure returns (bytes memory callData, uint256 amountLimit, uint256 msgValue);
```

### quoteLido

Quote ETH → stETH or ETH → wstETH via Lido staking (1:1 for stETH, rate-based for wstETH).


```solidity
function quoteLido(bool exactOut, address tokenOut, uint256 swapAmount)
    public
    view
    returns (uint256 amountIn, uint256 amountOut);
```

### _buildLidoSwap

Build router calldata for a Lido swap (ETH → stETH or ETH → wstETH).


```solidity
function _buildLidoSwap(address to, bool exactOut, address tokenOut, uint256 swapAmount)
    internal
    pure
    returns (bytes memory callData);
```

### buildBestSwap


```solidity
function buildBestSwap(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 slippageBps,
    uint256 deadline
) public view returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue);
```

### _spacingFromBps


```solidity
function _spacingFromBps(uint16 bps) internal pure returns (int24);
```

### _requiredMsgValue


```solidity
function _requiredMsgValue(bool exactOut, address tokenIn, uint256 swapAmount, uint256 amountLimit)
    internal
    pure
    returns (uint256);
```

### _bestSingleHop


```solidity
function _bestSingleHop(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 amount,
    uint256 slippageBps,
    uint256 deadline
) internal view returns (bool ok, Quote memory q, bytes memory data, uint256 amountLimit, uint256 msgValue);
```

### buildBestSwapViaETHMulticall


```solidity
function buildBestSwapViaETHMulticall(
    address to,
    address refundTo,
    bool exactOut, // false = exactIn, true = exactOut (on tokenOut)
    address tokenIn, // ERC20 or address(0) for ETH
    address tokenOut, // ERC20 or address(0) for ETH
    uint256 swapAmount, // exactIn: amount of tokenIn; exactOut: desired tokenOut
    uint256 slippageBps, // per-leg bound
    uint256 deadline,
    uint24 hookPoolFee,
    int24 hookTickSpacing,
    address hookAddress
)
    public
    view
    returns (Quote memory a, Quote memory b, bytes[] memory calls, bytes memory multicall, uint256 msgValue);
```

### _buildSwapFromQuote

Encode a non-Curve single-hop swap from a Quote with an arbitrary
swapAmount.  Pass swapAmount = 0 so the router auto-reads its own
token balance as the input amount (exactIn only).


```solidity
function _buildSwapFromQuote(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline,
    Quote memory q
) internal pure returns (bytes memory);
```

### build3HopMulticall

Build a 3-hop exactIn multicall:
tokenIn ─[Leg1]→ MID1 ─[Leg2]→ MID2 ─[Leg3]→ tokenOut
Legs 2 & 3 use swapAmount = 0 so the router auto-consumes the
previous leg's output via balanceOf().
Route discovery: tries every ordered pair (MID1, MID2) from the
hub list and picks the path that maximizes final output.
All AMMs (V2/Sushi/V3/V4/zAMM/Curve) are considered for each leg.


```solidity
function build3HopMulticall(
    address to,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 slippageBps,
    uint256 deadline
)
    public
    view
    returns (
        Quote memory a,
        Quote memory b,
        Quote memory c,
        bytes[] memory calls,
        bytes memory multicall,
        uint256 msgValue
    );
```

### _buildCalldataFromBest

Build calldata for any AMM type including Curve, using a pre-computed quote.


```solidity
function _buildCalldataFromBest(
    address to,
    bool exactOut,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 slippageBps,
    uint256 deadline,
    Quote memory q
) internal view returns (bytes memory);
```

### buildSplitSwap

Build a split swap that divides the input across 2 venues for better execution.
ExactIn only. Tries splits [100/0, 75/25, 50/50, 25/75, 0/100] across the
top 2 venues and picks the best total output.


```solidity
function buildSplitSwap(
    address to,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 slippageBps,
    uint256 deadline
) public view returns (Quote[2] memory legs, bytes memory multicall, uint256 msgValue);
```

### buildHybridSplit

Build a hybrid split that routes part of the input through the best
single-hop venue and the remainder through the best 2-hop route (via a
hub token). This captures cases where splitting across route depths
beats any single strategy.
Returns the same shape as buildSplitSwap for frontend compatibility.


```solidity
function buildHybridSplit(
    address to,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 slippageBps,
    uint256 deadline
) public view returns (Quote[2] memory legs, bytes memory multicall, uint256 msgValue);
```

### _tryQuoteV4Hooked

Quote V4 hooked pool, returning 0 on failure.
quoteV4 simulates raw AMM math only — it does NOT simulate the hook's
afterSwap callback which can modify the swap delta (e.g. protocol fees).
We reduce the output by the hook's afterSwap fee so that slippage limits
and venue comparisons reflect the real post-fee amount.


```solidity
function _tryQuoteV4Hooked(address tokenIn, address tokenOut, uint256 amount, uint24 fee, int24 tick, address hook)
    internal
    view
    returns (uint256 out);
```

### _buildV4HookedCalldata

Build execute(V4_ROUTER) calldata for a V4 hooked pool swap (ETH input only).


```solidity
function _buildV4HookedCalldata(
    address to,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 amountLimit,
    uint256 deadline,
    uint24 hookPoolFee,
    int24 hookTickSpacing,
    address hookAddress
) internal pure returns (bytes memory);
```

### buildSplitSwapHooked

Build a split swap that includes a V4 hooked pool as a candidate.
ExactIn only. Gathers standard venues + Curve + the hooked pool,
finds the top 2, tries splits [100/0, 75/25, 50/50, 25/75, 0/100],
and returns the optimal multicall.


```solidity
function buildSplitSwapHooked(
    address to,
    address tokenIn,
    address tokenOut,
    uint256 swapAmount,
    uint256 slippageBps,
    uint256 deadline,
    uint24 hookPoolFee,
    int24 hookTickSpacing,
    address hookAddress
) public view returns (Quote[2] memory legs, bytes memory multicall, uint256 msgValue);
```

### _requoteForSource

Re-quote for a specific AMM source at a given amount.


```solidity
function _requoteForSource(bool exactOut, address tokenIn, address tokenOut, uint256 amount, Quote memory source)
    internal
    view
    returns (Quote memory q);
```

## Errors
### NoRoute

```solidity
error NoRoute();
```

## Structs
### Quote

```solidity
struct Quote {
    AMM source;
    uint256 feeBps;
    uint256 amountIn;
    uint256 amountOut;
}
```

### HubPlan

```solidity
struct HubPlan {
    bool found;
    bool isExactOut;
    address mid;
    Quote a;
    Quote b;
    bytes ca;
    bytes cb;
    uint256 scoreIn;
    uint256 scoreOut;
}
```

### Route3

```solidity
struct Route3 {
    bool found;
    Quote a;
    Quote b;
    Quote c;
    address mid1;
    address mid2;
    uint256 score;
}
```

### CurveAcc

```solidity
struct CurveAcc {
    uint256 bestOut;
    uint256 bestIn;
    address bestPool;
    bool usedUnderlying;
    bool usedStable;
    uint8 iIdx;
    uint8 jIdx;
}
```

## Enums
### AMM

```solidity
enum AMM {
    UNI_V2,
    SUSHI,
    ZAMM,
    UNI_V3,
    UNI_V4,
    CURVE,
    LIDO,
    WETH_WRAP,
    V4_HOOKED
}
```

