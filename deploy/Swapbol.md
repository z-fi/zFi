# Swapbol

zRouter `snwap` forwarder for the whole book: Swapboard (legacy v1 and current),
Dutchboard, and now Floorboard.

## Addresses

| | |
|---|---|
| deployer | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| Swapbol | [`0x00000087A6dc5071779Ed1F8274A39230768B976`](https://etherscan.io/address/0x00000087A6dc5071779Ed1F8274A39230768B976) |
| salt | `0x00000000000000000000000000000000000000000000000000000000001e6221` |
| initcode hash | `0x86a997e7f3bb5c8ff69360c500ea941b88d76d88832a83c8cc679553d2fedb25` |
| creation size | 16,161 B |
| runtime size | 15,366 B |
| optimizer runs | 9,999,999 (unpinned) |
| supersedes | `0x0000003069053df109F47acac630e03C77804AD8` |
| deploy tx | [`0xdbca3f2e…6582a2`](https://etherscan.io/tx/0xdbca3f2ea167bbc981ca21e71bc4bf161c769d8dbb0b296ce6cd0b47ab6582a2) — block 25,722,177, 3,382,270 gas |

Constructor arguments, in order:

| | |
|---|---|
| `boardV1_` | `0x000000fF3D7A2d373615141d7489Ca66683DbecF` |
| `boardCurrent_` | `0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b` |
| `dutchboard_` | `0x000000a213b430D14Bae6062c176289B05e04489` |
| `floorboard_` | `0x00000080198137F790DA4C52bb902cf87c276748` |

## What changed

The fourth binding. Everything else — the checkpoint, the scoped-and-revoked
allowances, the reentrancy guard, the `recipient`/`refundTo` split, the AMM
calldata firewall — is unchanged, and so is `Fill`.

Floorboard is the BID side. It needs an adapter for a shape reason, not a
missing feature: `hit` pulls the asset with `transferFrom(msg.sender)` and pays
`msg.sender`, while `zRouter.snwap` transfers `tokenIn` **to** the executor
before calling it. Floorboard can therefore never be an snwap executor itself —
it would be pulling from, and paying, `SafeExecutor`.

It lives here rather than in a sibling forwarder because delegatecalled zRouter
`multicall` entries all observe the same `msg.value`, so two forwarders would be
two sibling snwaps each seeing the whole ETH value. A route that is part ask,
part bid, part AMM is only expressible inside one executor call — and for a user
selling ETH for USDC, an ask selling USDC for ETH and a bid buying ETH paying
USDC are the same trade, so splitting across them is the ordinary case.

No new leg type. `Fill` already means "pay `payIn` of tokenIn, get `getOut` of
tokenOut at `orderId` on `board`", which on a bid reads as "deliver `payIn`
units, be paid at least `getOut`" — `hit(id, give, minProceeds, ...)` field for
field.

Two things about a bid leg differ from every ask leg, and both are load-bearing:

- **The asset bindings are mirrored.** `token` is what the bid buys, so it binds
  to `tokenIn`; `quote` is what it pays, so it binds to `tokenOut`. That is the
  opposite way round from `_validateV1Order` and its siblings.
  `_validateFloorBid` re-checks it on chain because the board cannot: from its
  side, any seller delivering the asset is a valid seller.
- **`hit` takes no recipient.** Like the legacy v1 board, it pays `msg.sender`,
  so the sweep is the delivery path rather than a fallback. `unwrap` is left
  false on every leg, so a mixed plan has one conversion point instead of one
  per leg — and the generic `fill` entry point rejects an unwrapping hit, which
  would otherwise leave ETH here while `_sweep` measures a token delta and pay
  the proceeds out as change to `refundTo`.

The constructor's distinctness check is now a pairwise loop. Four venues is six
comparisons, which is where a hand-written conjunction starts silently missing
one.

Covered by `test/SwapbolFloor.t.sol` against the real Floorboard — a stub shaped
like the ask boards would agree with a forwarder that had the mirror backwards.
