# On-chain price tape — design exploration

Goal: charts and trading data for any asset priced in any other asset, served
from chain state via `eth_call` only. No log indexing, no subgraph, no server.

## 1. What exists today

**Nothing stores observations.** I searched the whole tree: there is no
observation array, no cumulative-price accumulator, no TWAP anywhere in `src/`.
Every price the dapp shows today is computed live from reserves at read time and
thrown away.

What we do have, and what each part gives us:

| Component | Trade data | Readable on-chain today |
|---|---|---|
| `PrecisionPool` | `Swap(tokenIn, amountIn, amountOut, to)` — log only | reserves only (spot, now) |
| `PrecisionPoolFactory` | `allPools`, `_byPair`, `_byToken`, `_byCreator` | **yes** — full pool discovery |
| `Swapboard` | `OrderFilled` / `OrderPartiallyFilled` — log only | **resting orders** (live depth) |
| `Dutchboard` | `Filled` — log only | **live listings + decayed price** |

Two things fall out of that table immediately:

- **Depth charts are already free.** The boards keep resting orders in storage,
  and `SwapboardView` already pages them. A live bid/ask depth panel needs no new
  storage and no new gas — it is a read we are not yet making.
- **Only trade *history* is missing.** Everything historical currently exists
  solely as logs, which is exactly the source we are ruling out.

### Constraints found in `PrecisionPool` that shape the design

1. **`hook` is immutable, set at construction.** A pool deployed without a hook
   can never gain one. If the tape lives in a hook, every pool that should be
   chartable must be created with it from day one.
2. **The hook slot is single-occupancy.** A pool cannot have both a surcharge
   hook and a separate tape hook; they must be one contract.
3. **A hook makes the pool quote conservatively.** `_tradeable` uses
   `MAX_TOTAL_FEE` (10%) instead of `fee` whenever `hook != address(0)`
   ([PrecisionPool.sol:280](../src/pools/PrecisionPool.sol#L280)). Attaching a
   *pure observer* therefore makes small trades look untradeable and can push
   routing away from the pool — a real cost paid for zero surcharge. See §7.
4. **`afterSwap` is best-effort**, called with a 150k gas budget and its revert
   swallowed into `HookCallFailed`. A tape behind it may silently miss prints.
5. `afterSwap` receives `(sender, tokenIn, amountIn, amountOut, to)` — enough to
   compute the executed price with no extra reads.

## 2. Cost floor: what a print actually costs

There is no trick that makes persistent storage free. The relevant EVM prices:

| Operation | Gas |
|---|---|
| `SSTORE` non-zero → non-zero, slot cold in this tx | 2,900 + 2,100 = **5,000** |
| `SSTORE` zero → non-zero, cold | 20,000 + 2,100 = **22,100** |
| `SLOAD`, cold | 2,100 |
| External call to a warm hook contract | ~700 |
| External call to a cold hook contract | ~2,600 |

So the design target is: **exactly one `SSTORE` per swap, into one slot that is
never zero after the first print.** A ring buffer that has lapped once is all
non-zero, so every write is the 5,000 case, never the 22,100 case. That is the
floor for full-fidelity OHLCV, and everything below is about not exceeding it.

## 3. Encoding

### 3.1 Price as a 4-byte float

Prices span many orders of magnitude, so fixed-point wastes most of its bits.
A 24-bit mantissa with an 8-bit binary exponent gives ~7 significant digits
(relative error < 2⁻²³ ≈ 1.2e-7) over a range far wider than any real pair, in
**4 bytes**:

```solidity
/// value ≈ mantissa << exponent
function pack(uint256 v) internal pure returns (uint32) {
    if (v == 0) return 0;
    uint256 msb = _msb(v);                     // index of the highest set bit
    if (msb < 24) return uint32(v);            // exponent 0, exact
    uint256 shift = msb - 23;                  // keep 24 significant bits
    return uint32((shift << 24) | (v >> shift));
}

function unpack(uint32 p) internal pure returns (uint256) {
    return uint256(p & 0xffffff) << (p >> 24);
}
```

`_msb` is a branchless bit-scan in assembly. Encoding a print is a few hundred
gas of arithmetic — noise next to the 5,000-gas store. Packing always rounds
**down** and is monotonic, both fuzzed: a chart may lose a hair of precision but
must never invert two prices.

Price is canonicalised as **token1 per token0, 1e18-scaled**, in the same raw
convention as the pool's own `sqrtPLow`/`sqrtPHigh` — token decimals are not
normalised here, and a reader applies them alongside the pair from `tapePair()`.
A bar is therefore direction-free:

```
tokenIn == token0:  p = amountOut * 1e18 / amountIn
tokenIn == token1:  p = amountIn  * 1e18 / amountOut
```

Volume is always denominated in **token0**, so both directions sum into one bar.

This is the **executed** price, including fee and slippage — a real tape, which
is what a trader wants to see, rather than the untradeable mid.

### 3.2 Bar layout

One bar is one slot, live and finalised alike, so both share a codec:

| field | type | bytes | bits |
|---|---|---|---|
| `bucket` (unix / period) | uint32 | 4 | 0–31 |
| `open` | float32 | 4 | 32–63 |
| `high` | float32 | 4 | 64–95 |
| `low` | float32 | 4 | 96–127 |
| `close` | float32 | 4 | 128–159 |
| `volume0` | float32 | 4 | 160–191 |
| `count` | uint16 | 2 | 192–207 |
| unused | — | 6 | 208–255 |

An earlier draft dropped `bucket` and `open` to fit two bars per slot. Keeping
them is what makes **holes** work: the ring is indexed by `bucket % length`, so a
five-minute window in which nobody traded costs nothing and simply stays zero.
The reader then checks that a slot's stored `bucket` is the one it asked for,
which is also what stops a bar from the *previous* lap being served as current.
With no reliable previous bar, `open` cannot be inferred and has to be stored.

### 3.3 Period ladder

Do not keep a ring per timeframe; that multiplies the per-swap write. Keep
**two** rings and aggregate the rest client-side:

| ring | bars | span | written by |
|---|---|---|---|
| 5-minute | 256 | ~21 hours | trades |
| 4-hour | 256 | ~42 days | folding finished 5-minute bars |

Coarser candles (15m, 1h, 1d) are exact aggregations of the 5-minute ring, done
in the client for free. The 4-hour tape is never written by a trade: when a
five-minute bar closes it is *folded* into the coarse bar, so a second timeframe
costs one extra store per five minutes rather than one per swap. Aggregation is
exact — a four-hour candle built from forty-eight five-minute candles is the
candle the trades would have produced directly.

## 4. Gas — measured

Built and measured, not estimated. `test/PrecisionPoolTape.t.sol` A/B's the same
swap with `_record` enabled and disabled:

| | gas | marginal |
|---|---|---|
| Swap, no tape (baseline) | 16,340 | — |
| Swap, tape, same bucket | 18,980 | **+2,640** |
| Swap, bucket rollover, ring lapped | 21,289 | +4,949 |
| Swap, bucket rollover, first lap | 66,808 | +50,468 |

Two things to read carefully:

- Foundry runs a test as one transaction, so the live slot stays **warm** between
  swaps and the +2,640 is the warm `SSTORE` (2,900 class). In production every
  swap is its own transaction, so the slot is cold and the honest per-swap figure
  is **~5,000**.
- The first lap is expensive because each ring slot is written from zero
  (22,100). Once the ring has lapped, the same rollover costs 4,949 — the
  measurement above confirms the reuse argument rather than assuming it.

So a tape costs a trader roughly **+5,000 gas per swap**, plus about 5,000 once
per five-minute bucket, and about 50,000 on each of the first 256 rollovers
while the ring fills. Reading a chart — 96 bars in one call — costs the reader
nothing, because it is an `eth_call`.

### The cheap mode: deviation-triggered prints

If that is too much for high-frequency pools, skip the store when the price has
not moved materially:

```solidity
if (bucket != live.bucket || absDeviationBps(p, live.close) >= threshold) { ...store... }
```

A quiet swap then costs one cold `SLOAD` (2,100) and nothing else. Charts are
visually identical, because a flat stretch needs no prints. **The cost is
volume**: skipped swaps are not counted, so `volume0` becomes a lower bound and
`count` stops being a trade count. Full OHLC**V** requires the write every swap.
This is the real tradeoff and it should be a per-pool choice, not a global one.

## 5. Where the tape should live

**Recommendation: native in `PrecisionPool`, not in a hook.**

- It is ~3,300 gas per swap cheaper (no external call).
- It avoids the `_tradeable`/`MAX_TOTAL_FEE` quoting penalty entirely.
- It leaves the hook slot free for its intended purpose (surcharges).
- It cannot silently fail the way a swallowed `afterSwap` can.
- `PrecisionPool` is pre-launch on this branch, so the storage layout is still ours.

The hook variant stays useful for **pools already deployed** and for
third-party pools — same encoder, same read API, worse gas.

For the boards there is no hook, so a tape means writing in the fill path of
`Swapboard`/`Dutchboard`, keyed by `(tokenA, tokenB)` rather than by pool.
Note `Dutchboard`'s own warning that not every `Filled` is arm's-length — a tape
there should be treated as lower-quality data than a pool's, or gated.

## 6. Read path — charts with no indexer

1. **Discover** pools from the factory: `allPools`, or `_byToken` for one asset.
2. **Batch-read** every tape in one `eth_call` via Multicall3 `aggregate3` — the
   dapp already has this plumbing (`mc3()` in `zSwap.html`) and already pins reads
   to a single block, which matters here so all series share one chain state.
3. **Decode** float32s client-side and aggregate 5-minute bars into whatever
   timeframe the UI shows.

### Pricing an asset in terms of any other asset

Do not store every pair. Store each pool's own token1/token0 series and
**compose paths in the client**: the factory's `_byToken` index is a graph, so
`TOKEN/WETH × WETH/USDC` gives `TOKEN/USDC` by multiplying two series bar-for-bar.
Choose the path by liquidity depth, exactly the way the router chooses a route.
This is what makes it "any asset in terms of any asset" without O(n²) storage.

### Chainlink as the canonical spine

For majors, the quote leg does not need our storage at all. Chainlink
aggregators are pure on-chain reads:

- `latestRoundData()` for the current anchor.
- `getRoundData(roundId)` walked backwards for history — round ids encode
  `(phaseId << 64) | aggregatorRoundId`, so walking across a phase boundary means
  decrementing the phase and picking up its last round.

Two caveats worth stating up front: rounds are **deviation-triggered, so they are
sparse and unevenly spaced** (they interpolate into candles poorly), and walking
history costs one `eth_call` per round unless batched through Multicall3. Used as
the USD anchor for ETH/BTC — not as the chart itself — it is close to free and
gives our charts a real fiat axis.

## 7. Recommended change to `PrecisionPool` regardless of tape

`_tradeable` currently assumes any hook may charge `MAX_TOTAL_FEE`. Declaring the
ceiling at construction — `uint256 immutable maxSurcharge`, clamped in
`extraFee` — lets an observer hook declare `0` and be quoted at the true `fee`.
That removes the main disincentive to attaching hooks at all, and is worth doing
independently of this design.

## 8. What is built

- **[`src/pools/PriceTape.sol`](../src/pools/PriceTape.sol)** — the library and
  the `IPriceTape` read interface. Written to be adopted by anyone, not just by
  these pools: hold a `Tape`, call `print`, and every client that speaks
  `IPriceTape` can chart you.
- **`PrecisionPool`** implements `IPriceTape` natively: one `_record` call in
  the swap path, `tape()` / `tapePeriods()` / `tapePair()` for readers.
- **[`test/PriceTape.t.sol`](../test/PriceTape.t.sol)** — codec, fuzzed
  round-trip and monotonicity, ring wrap, holes, folds, gas.
- **[`test/PrecisionPoolTape.t.sol`](../test/PrecisionPoolTape.t.sol)** — real
  swaps through a real pool, both directions, ring lap, and the gas A/B above.

A trap worth recording, because it silently voided several tests before it was
caught: the optimiser treats `TIMESTAMP` as constant within a call and folds
repeated reads, so `vm.warp(block.timestamp + P)` twice warps to the **same**
instant and no bucket ever rolls. Both suites track time in an explicit variable.

## 9. Does it actually fill a chart? — measured

Estimating this would have been worthless, so it was run: a real pool, real
swaps at a plausible cadence, and the raw `tape()` return decoded by the
*shipped* client (`test/TapeRealism.t.sol` + `script/check-tape-realism.mjs`).

| scenario | 5m bars | 1h | 4h | 1d |
|---|---|---|---|---|
| 273 swaps over 24h | **112** (draws 98, clipped) | 22 | 6 | 1 |
| 3 weeks, moderate flow | 61 | 21 | **126** | **21** |
| ~10 swaps a day | 10 | 6 | 5 | 1 |

Three things this settled:

- **The five-minute view fills within a day** on an active pair — 112 bars, more
  than the drawer can draw.
- **The coarse ring does its job.** In the three-week run the fine ring held 61
  trades and the coarse ring held 1,834: it is genuinely carrying the history
  the fine ring drops, at one write per five minutes rather than one per swap.
- **A quiet pool gets a sparse chart**, and should. Ten trades a day is ten bars.
  The drawer renders what exists rather than interpolating a line through
  nothing.

Two limits worth stating plainly:

- **Daily candles need days.** The coarse ring gains one bar per four hours, so a
  pool's first weeks show `1d` as a single candle. Inherent, not fixable.
- **The fine ring is a 21-hour *window*, not the last 256 trades.** Buckets
  advance whether or not anyone trades, so a pair doing five trades a day will
  never hold more than about five fine bars however large the ring is.

This exercise also caught the dapp requesting only 128 of the 256 coarse bars it
had paid to store — half the daily history, silently discarded. No fixture would
have found it, because it only appears once a pool is older than three weeks.

## 10. Suggested phasing

1. **Done:** native 5-minute + 4-hour tapes in `PrecisionPool`, full OHLCV,
   ~5k gas per swap, with the library and read interface open for anyone to adopt.
2. **Next:** the chart client — pool discovery from the factory, one batched
   `aggregate3` read, client-side roll-up and path composition. This is where the
   public good becomes visible, and it needs no further contract work.
3. **Free whenever wanted:** live depth from the boards' existing storage.
4. **After:** hook-based tape for foreign pools; board tapes if the orderbook
   tape proves worth its gas; Chainlink spine for the USD axis; the
   `maxSurcharge` fix in §7.

## 11. Open questions

- Is +5k gas per swap acceptable at launch, or should the first pools ship
  deviation-triggered (price-only) and add volume later? The storage layout is
  the same either way, so this can be a per-pool flag rather than a fork.
- Ring size 256 slots per pool is ~8k gas amortised of first-lap cost per pool
  and permanent state growth. Is 42h of 5-minute history the right depth?
- Should the tape record `sender`/`to` at all? It doubles the slot cost and the
  chart never uses it.
