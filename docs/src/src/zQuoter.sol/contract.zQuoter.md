# zQuoter
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/zQuoter.sol)


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

### _bestDirectExcludingLido

Best exactIn direct quote, excluding LIDO and WETH_WRAP. Used by split
builders that can't safely use LIDO (callvalue semantics) or WETH_WRAP
(trivial 1:1, not a real route). Considers all base-quoter sources + Curve.


```solidity
function _bestDirectExcludingLido(address tokenIn, address tokenOut, uint256 swapAmount)
    internal
    view
    returns (Quote memory best);
```

### _normalizeETH

Normalize CURVE_ETH sentinel to address(0) so all ETH logic is consistent.


```solidity
function _normalizeETH(address token) internal pure returns (address);
```

### _v2Deadline

zRouter treats `deadline == type(uint256).max` on swapV2 as a sentinel that
routes execution to the Sushi factory. Callers who pass max (e.g. "no expiry")
would therefore silently get a Sushi pool for a quote the base quoter gave
for the Uniswap V2 pool. Use this only on the UNI_V2 encode path — do NOT
apply globally, because swapVZ also uses max as a sentinel (ZAMM_0 vs ZAMM)
and the base quoter's zAMM source may depend on the caller-supplied deadline.


```solidity
function _v2Deadline(bool isSushi, uint256 deadline) internal view returns (uint256);
```

### _hubs


```solidity
function _hubs() internal pure returns (address[6] memory);
```

### _sweepTo


```solidity
function _sweepTo(address token, address to) internal pure returns (bytes memory);
```

### _sweepAmt

Assembly-built sweep(token, 0, amount, to) calldata. Replaces four scattered
abi.encodeWithSelector sites with one shared encoder to shrink bytecode.


```solidity
function _sweepAmt(address token, uint256 amount, address to) internal pure returns (bytes memory data);
```

### _mc


```solidity
function _mc(bytes[] memory c) internal pure returns (bytes memory);
```

### _mc1


```solidity
function _mc1(bytes memory cd) internal pure returns (bytes memory);
```

### _fallbackBest

Shared exactIn fallback used by split/hybrid edge cases (trivial wrap,
no split, 100/0 or 0/100 split, 100% direct hybrid). Returns the best
exactIn quote for the full pair, its calldata wrapped in a 1-element
multicall envelope, and msgValue — so call sites become one expression.


```solidity
function _fallbackBest(address to, address tokenIn, address tokenOut, uint256 amount, uint256 bps, uint256 dl)
    internal
    view
    returns (Quote memory q, bytes memory multicall, uint256 msgValue);
```

### _appendLegMaybeWrap

Append a (optionally pre-wrapped) leg to calls_. Used by split/hybrid paths
when a Curve leg with ETH input needs a WETH pre-wrap plus route[0] rewrite.
Deduplicates 4 copies of `if (wrap) { _wrap + mstore(cd,100,WETH) } append(cd)`.


```solidity
function _appendLegMaybeWrap(bytes[] memory calls_, uint256 ci, bytes memory cd, bool needsWrap, uint256 amt)
    internal
    pure
    returns (uint256);
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

### _inPoolsPrefix


```solidity
function _inPoolsPrefix(address[] memory pools, uint256 prefixLen, address pool) internal pure returns (bool);
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
    bool, /* useUnderlying — always false; filtered in _curveTryQuoteOne */
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
    returns (bytes memory);
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

### buildSwapAuto

One-call quote+build that returns the same shape as buildBestSwap.
Cascade (NOT a head-to-head comparison across depths): single/2-hop
first, 3-hop only as a fallback for pairs that can't build at shallower
depth. Frontends can use this as a drop-in for buildBestSwap — no
decoder changes — and recover every pair that has *any* on-chain path.
Cascade:
1. buildBestSwapViaETHMulticall — internally picks best of {single-hop, 2-hop hub}
2. build3HopMulticall           — last-resort for exotic tokens (exactIn + exactOut)
Note: step 1 wraps single-hop results in a 1-element multicall envelope
(~2–3k extra gas), but guarantees we never miss a strictly-better hub
route just because a marginal single-hop pool also happened to quote.
For custom tokens this matters: a user's exotic token may have a
stale V3 1bp pool that buildBestSwap would prefer, while the deep
liquidity actually lives on a WETH-hub 2-hop path.
The returned `best` aggregates multi-hop plans into a single Quote
with end-to-end amounts (source = final leg's source).


```solidity
function buildSwapAuto(
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
    uint256 deadline
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
) internal view returns (bytes memory);
```

### _discover3HopForward

Enumerate every ordered (MID1, MID2) hub pair for exactIn — maximize output.
Split from exactOut into its own helper so each version fits via-ir's stack.


```solidity
function _discover3HopForward(address tokenIn, address tokenOut, uint256 swapAmount, uint256 slippageBps)
    internal
    view
    returns (Route3 memory r);
```

### _discover3HopBackward

Enumerate every ordered (MID1, MID2) hub pair for exactOut — minimize input
via a backward pass from `swapAmount` of tokenOut.


```solidity
function _discover3HopBackward(address tokenIn, address tokenOut, uint256 swapAmount, uint256 slippageBps)
    internal
    view
    returns (Route3 memory r);
```

### build3HopMulticall

Build a 3-hop multicall through two hub intermediates:
tokenIn ─[Leg1]→ MID1 ─[Leg2]→ MID2 ─[Leg3]→ tokenOut
exactIn:  legs 2 & 3 pass swapAmount=0 so each router leg
auto-consumes the previous leg's transient balance.
exactOut: each leg has an explicit target (backward-calc'd from
`swapAmount` of tokenOut). Hub leftovers + ETH dust
are swept to `to` in the envelope to avoid stranding
funds in the router.
Discovery: tries every ordered pair (MID1, MID2) from the hub
list. exactIn maximizes final output; exactOut minimizes required
input. All AMMs (V2/Sushi/V3/V4/zAMM/Curve) compete per leg.


```solidity
function build3HopMulticall(
    address to,
    bool exactOut,
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
    WETH_WRAP
}
```

