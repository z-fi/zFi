# Curve on Base — measured, and what is worth pinning

Measured 2026-09-20 against Base mainnet at head. Every number below came from
`get_dy` on the pool itself and from the live `zQuoterBase`
(`0x000000bd2DB80567c23E353ca95a251c573cBf9B`, `getQuotes`), same size, same block.

## The registry is not the thing to use

Curve's legacy AddressProvider (`0x0000000022D53366457F9d5E68Ec105046FC4383`) IS deployed
on Base but answers `address(0)` for both the MetaRegistry (id 7) and the main registry
(id 0) — so checking only that says "Curve is not on Base", which is wrong. Base's
MetaRegistry is reached through the newer AddressProviderNG
(`0x5ffe7FB82894076ECB99A30D6A32e969e6e35E98`, id 7) and lives at
**`0x87DD13Dd25a1DBde0E1EdcF5B8Fa6cfff7eABCaD`** — ~7.0 KB of code, `pool_count()` 1,147.

`zQuoter.sol`'s `CURVE_METAREGISTRY = 0xF98B45FA…` is mainnet-only; it has no code on Base.

**Do not port the discovery loop.** `find_pools_for_coins(WETH, USDC)` returns **292** pools
on Base against **51** on mainnet, and roughly nine in ten of them do not answer `get_dy` at
all — Base's registry is full of abandoned pools. Iterating that inside an `eth_call` on the
chain's most common pair, to find nothing, is the opposite of what the venue is worth.

## Head to head, Curve best vs zQuoterBase best

| pair | size | Curve | zQuoterBase | edge |
|---|---|---|---|---|
| WETH/USDC | 0.3 WETH | 789.55 | 786.85 | **+34 bps** |
| WETH/crvUSD | 0.3 WETH | 775.70 | ~0 | **unroutable without it** |
| USDC/crvUSD | 10,000 | 10,009.17 | ~22 | **unroutable without it** |
| USDC/USDbC | 10,000 | 9,992.81 | 9,999.42 | −7 bps |
| cbBTC/tBTC | 0.1 cbBTC | 0.09998 | 0.10000 | −2 bps |
| WETH/cbBTC | 0.3 WETH | 0.00966 | 0.00971 | −52 bps |
| USDC/cbBTC | 10,000 | 0.06629 | 0.12339 | −4,628 bps |

That +34 bps reads like a strong result and is not one, because of depth. The pool behind it
holds **2.43 WETH and 13,003 USDC — about $19.4k of TVL**, and it is the ONLY Curve WETH/USDC
pool on Base with anything in it: scanning all 292 at a 10 WETH size, the best Curve answer is
still that pool, returning 12,318 USDC against Uniswap's 26,201. So the edge is real but it
lives on a pool a single ~4 WETH trade empties:

| size | Curve | zQuoterBase | edge |
|---|---|---|---|
| 0.1 WETH | 263.04 | 262.15 | +34 bps |
| 1 WETH | 2,629.94 | 2,620.25 | +37 bps |
| 3 WETH | 7,887.47 | 7,860.67 | +34 bps |
| 10 WETH | 12,318.71 | 26,201.36 | −5,298 bps |
| 30 WETH | 12,319.29 | 78,596.71 | −8,433 bps |

The crvUSD pools are the same scale, and crvUSD is not in the page's Base token list, so that
"unroutable without it" line only becomes a real capability if crvUSD is listed too.

## The set worth hardcoding — three pools

| pool | serves | `get_dy` signature |
|---|---|---|
| `0xb9f3725202eec10b2a126d1245182b25f6ed3795` | WETH/USDC | `get_dy(int128,int128,uint256)` |
| `0x6e53131f68a034873b6bfa15502af094ef0c5854` | WETH/crvUSD, crvUSD/tBTC | `get_dy(uint256,uint256,uint256)` |
| `0xf6c5f01c7f3148891ad0e19df78743d31e390d1f` | USDC/crvUSD, USDbC/crvUSD, USDC/USDbC | `get_dy(int128,int128,uint256)` |

Coin indices come from `get_coin_indices(pool, from, to, 0)` on the MetaRegistry and are NOT
guessable from token ordering — for the WETH/USDC pool above it is `(0, 1)`, and passing them
reversed reverts rather than returning a wrong number, which is the safe direction.

Note the WETH/USDC pool answers the **stable** signature, not the crypto one. `zQuoter`'s
existing classification tries crypto first and falls through to stable, so it handles this
already; a port must keep that fallback rather than assuming a crypto pool.

## Recommendation: do not integrate this

Measured, the whole prize is ~35 bps on WETH/USDC trades small enough not to move a $19.4k
pool — call it sub-$5k — and nothing anywhere else. Against that, on Base the price is
structural and permanent:

- `zRouterLiteBase` has no Curve path at all (`swapV2/V3/V4/Aero/AeroCL` only), so a Curve leg
  cannot go through the router. It would have to be a direct `exchange(...)` call on the pool.
- That means a NEW APPROVAL SPENDER — the pool itself, not `ZROUTER` — on a page whose
  allowance handling is built around the router.
- It cannot join the router's multicall, so it can never combine with the orderbook, the
  via-ETH hop or the 3-hop builder, and nothing sweeps a remainder.
- On the page it would be a new fund-moving branch with no patch path after the chunks ship.

The pool does support `exchange(int128,int128,uint256,uint256,address)`, so a direct call
could pay the recipient with on-chain `min_dy` protection — it is implementable. It is just
not worth it at this depth. Revisit if a real Curve pool ever lands on Base.

## Why this is not in the shipped quoter

`zQuoterBase` is immutable and the v0.3 page hardcodes the quoter address, so adding Curve
means a new contract, a freshly mined CREATE3 salt, a page repoint and therefore a re-chunk
and a DAO vote. The measured gain — 34 bps on one pair plus crvUSD coverage — is real but
does not pay for holding the freeze. This file exists so the work is a small, specified job
whenever the next quoter set is cut, rather than a re-derivation.
