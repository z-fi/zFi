# Quoting notes

Findings from probing the deployed quoter against mainnet. Recorded because
none of it is visible from the code alone, and two items are live decisions.

zQuoter `0xc7a03f9ed2be5feea18ce93e12f4f05c98287c16`
zRouter `0x000000000000FB114709235f1ccBFfb925F600e4`

## V4 is fixed, and here is how to tell

The protocol-fee misread produced output that did not respond to trade size.
That is the signature to check for, not just implausible numbers:

| fee tier | 0.1 ETH | 1 ETH | 20 ETH |
|---|---|---|---|
| 0.01% | 1,896.14 | 1,895.47 | 1,881.43 |
| 0.05% | 1,895.07 | 1,894.37 | 1,877.74 |
| 0.30% | 1,885.92 | 1,885.89 | 1,885.21 |
| 1.00% | 1,838.16 | 1,539.36 | 1,417.95 |

All four tiers now degrade with size, steeply for the thin 1% pool. V2, V3 and
Sushi are likewise sane; Sushi's ETH/USDC is genuinely thin and the quoter is
right to say so (1,442/ETH at 20 ETH).

## `getQuotes` and the builders disagree about Lido

Lido lives in `_quoteBestSingleHop`, which the **builders** use. `getQuotes`
does not carry the overlay:

| call | ETH -> stETH, 10 ETH |
|---|---|
| `getQuotes` | `best = UNI_V3`, 9.891567 |
| `buildBestSwapViaETHMulticall` | `LIDO`, 10.000000, emits `exactETHToSTETH` |

The builder is right and executes the better route, so this is a display risk
rather than a routing bug: anything showing a `getQuotes` figure for that pair
understates by ~1.1%. zSwap's cascade calls builders only and is unaffected.
`server/quote.js` calls both; its reported best for ETH->stETH currently comes
from the aggregator leg and matches, but the mismatch is latent.

## Curve's legacy stETH/ETH pool is trusted by the router

`0xDC24316b9AE028F1497c275EB9192a3Ea0f67022` needs `msg.value` on `exchange()`,
so `swapCurve` (which pre-funds with WETH) cannot drive it, and zQuoter skips it
at discovery. But it **is** in the router's `_isTrustedForCall`, so it is
reachable through `execute(pool, value, ...)`. Confirmed by differential probe:

    Curve legacy pool  -> revert 0x          (past the allowlist)
    random address     -> revert 0x82b42900  (Unauthorized)
    USDC               -> revert 0x82b42900  (Unauthorized)

Capturing it would mean quoting the pool and emitting an `execute` leg instead
of the normal Curve leg - a new shape in the builder, not a flag.

Worth is currently negligible in the ETH -> stETH direction:

| size | pool | vs Lido 1:1 |
|---|---|---|
| 1 ETH | 1.000001 | +0.0001% |
| 100 ETH | 99.999536 | -0.0005% |
| 1000 ETH | 999.946305 | -0.005% |

The case for wiring it is **stETH -> ETH** (0.9998), which Lido cannot do at
all, and the depeg scenario: the pool only pays meaningfully above 1:1 when
stETH is off peg, which is exactly when a spot check will not show it.

## rETH direct staking is not worth adding

There is no Rocket Pool path in zRouter or zQuoter. Adding one would not help:

| size | AMM | direct (`getRethValue`) | |
|---|---|---|---|
| 1 ETH | 0.856074 | 0.855846 | AMM +0.03% |
| 10 ETH | 0.856029 | 0.855846 | AMM +0.02% |
| 100 ETH | 0.855834 | 0.855846 | AMM -0.00% |

The direct column excludes Rocket Pool's ~0.05% deposit fee, so direct is worse
at every size once applied. rETH's AMM liquidity tracks the exchange rate
closely, unlike stETH where pools sit at a persistent discount and the 1:1 stake
is worth ~1.1%. Rocket Pool deposits can also be capacity-closed, which a direct
path would have to handle.

## Method

Every figure above came from `eth_call` against the deployed contracts on
mainnet. `getQuotes` returns `(Quote best, Quote[] quotes)`, so the array is
behind the offset at word 4 - decoding from word 0 silently yields the head as
if it were the first quote. `quoteCurve` returns `amountIn` first, so the output
is word 1.
