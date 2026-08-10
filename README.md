# zFi
the first onchain superdapp

[zRouter](https://etherscan.io/address/0x000000000000FB114709235f1ccBFfb925F600e4)
[zQuoter](https://etherscan.io/address/0x0000002d9a651b729e3aFBE57Fc84FFDa4a98a13)
[zSwap source](src/zSwap.sol)

## Canonical deployments

Ethereum mainnet, all Etherscan-verified. Every address below was placed by
SafeSummoner CREATE2 at [`0x00000000004473e1f31C8266612e7FD5504e6f2a`](https://etherscan.io/address/0x00000000004473e1f31C8266612e7FD5504e6f2a);
salts and creation payloads live in [`deploy/`](deploy/), and
`node script/check-create2-artifacts.mjs` reproduces each address from the
committed source.

### Orderbooks

| | address | |
|---|---|---|
| Swapboard | [`0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b`](https://etherscan.io/address/0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b) | escrowed peer-to-peer orders |
| Dutchboard | [`0x000000a213b430D14Bae6062c176289B05e04489`](https://etherscan.io/address/0x000000a213b430D14Bae6062c176289B05e04489) | descending-price lots |
| Floorboard | [`0x00000080198137F790DA4C52bb902cf87c276748`](https://etherscan.io/address/0x00000080198137F790DA4C52bb902cf87c276748) | ascending-price standing bids |
| SwapboardView | [`0x000000E0b25449F32f7D9259aC449bA88E78dFCE`](https://etherscan.io/address/0x000000E0b25449F32f7D9259aC449bA88E78dFCE) | read-only lens over Swapboard v1/v2 + Dutchboard |
| FloorboardView | [`0x0000004E376e9dB5D9EC28E6711E1a64997C6ba7`](https://etherscan.io/address/0x0000004E376e9dB5D9EC28E6711E1a64997C6ba7) | read-only lens over Floorboard bids |

A position on any board is an ERC-721 whose `tokenURI` is a self-contained SVG
card, rendered onchain by an immutable contract the board deploys in its own
constructor. Those renderers are `CREATE`-derived at nonce 1 of each board, so
they carry no vanity prefix and are not deployed separately:

| | address |
|---|---|
| SwapboardMetadata | [`0xA94786d3Dfb08a661C28F00517c0cf98EfA93b9e`](https://etherscan.io/address/0xA94786d3Dfb08a661C28F00517c0cf98EfA93b9e) |
| DutchboardMetadata | [`0xeC6d97A413f1e7268AeC383F501d6F9a7134176A`](https://etherscan.io/address/0xeC6d97A413f1e7268AeC383F501d6F9a7134176A) |
| FloorboardMetadata | [`0x65c85E0ACfb3E1F3CF90F46b1155F24c8c509Bc8`](https://etherscan.io/address/0x65c85E0ACfb3E1F3CF90F46b1155F24c8c509Bc8) |

### Forwarders

| | address | |
|---|---|---|
| Orderbol | [`0x000000fADa565c5608570a4F66Fb5E0bD08ef91B`](https://etherscan.io/address/0x000000fADa565c5608570a4F66Fb5E0bD08ef91B) | zRouter → Swapboard / Dutchboard |
| Swapbol | [`0x0000003069053df109F47acac630e03C77804AD8`](https://etherscan.io/address/0x0000003069053df109F47acac630e03C77804AD8) | zRouter → board fills, legacy and current |
| Cowol | [`0x0000003B59007E8aa43B0e508AfF8a304438333B`](https://etherscan.io/address/0x0000003B59007E8aa43B0e508AfF8a304438333B) | CoW Protocol, ERC-1271 |
| Swapbatch | [`0x0000005471EEF58dD16Aeccda21C37758E36a0b6`](https://etherscan.io/address/0x0000005471EEF58dD16Aeccda21C37758E36a0b6) | batch board fills paying native ETH |
| Fwabol | [`0x000000798397834de6a60d9CCBfde0536A2699d9`](https://etherscan.io/address/0x000000798397834de6a60d9CCBfde0536A2699d9) | FWA both ways, straight to the v4 PoolManager |
| Fwabol (superseded) | [`0x000000F2303C64Ad38956B38917Ade68b7a604FE`](https://etherscan.io/address/0x000000F2303C64Ad38956B38917Ade68b7a604FE) | buy-side only, via the Universal Router |

Fwabol is the one forwarder that never takes delivery of its own output.
FWAToken reverts every transfer that does not touch the PoolManager, its owner
or a distributor, so an adapter that received FWA could never pass it on - the
funds would be stuck at its address permanently. Fwabol therefore has the
PoolManager pay the recipient directly on a buy, and the seller pay the
PoolManager directly on a sell. FWA is never owed to it at any point.

The superseded version routed buys through the Universal Router, and its every
awkward feature was a workaround for that: `TAKE` hand-built because `TAKE_ALL`
infers the router's caller, a `SWEEP` command because unspent input would
otherwise rest in the router, a balance snapshot and a refund hop because the
router pays change to its own caller. It could not sell at all, because the
router's `SETTLE` pays from `_msgSender()` - the adapter - which would have had
to hold FWA first.

None of that is v4's rule. Settling in v4 is `sync()`, get the tokens to the
PoolManager by any means, `settle()`; the credit is the measured balance change
and the payer need not be the locker. Unlocking the PoolManager directly drops
the router and every workaround with it, and the sell direction falls out.

The seller is always `msg.sender`, never a parameter - otherwise an allowance to
this contract would become a standing option any caller could exercise against
the holder. A sell therefore cannot be wrapped in `snwap`, whose executor sees
`SafeExecutor` as its caller; routing one wants a per-trade Permit2 signature.

### Quoting

| | address | |
|---|---|---|
| zQuoterV4 | [`0x000000DcF8245bdC84fc5018F7825aB029C82845`](https://etherscan.io/address/0x000000DcF8245bdC84fc5018F7825aB029C82845) | ordinary V4 pools, `view`, correct fee math |
| V4QuoteLens | [`0x000000c3aE1692983941495162A4AAB40660E65F`](https://etherscan.io/address/0x000000c3aE1692983941495162A4AAB40660E65F) | V4 pools priced by a hook |
| V4Port | [`0x000000dfb53Fa7f1c486470034741d5BCBE14BE9`](https://etherscan.io/address/0x000000dfb53Fa7f1c486470034741d5BCBE14BE9) | executes any V4 pool, either direction |

The base quoter at [`0x658bF1A6608210FDE7310760f391AD4eC8006A5F`](https://etherscan.io/address/0x658bF1A6608210FDE7310760f391AD4eC8006A5F)
computes the V4 swap fee as `protocolFee + lpFee`. In V4 `protocolFee` is not a
rate - it is a packed uint24 holding two 12-bit values - so while Uniswap left
protocol fees at zero the sum happened to be right. They were switched on at
block 25623201, and every V4 quote has been wrong since. Measured live at block
25721569 on the deepest ETH/USDC V4 pool, 0.1 ETH in:

| | USDC out |
|---|---|
| base quoter | 93,281,193 |
| zQuoterV4 | 191,274,994 |
| canonical V4Quoter | 191,274,994 |

Under-quoting by 51%, and on other pools over-quoting by 2054x - which routes a
trade to a leg that then reverts. `zQuoterV4` is the base quoter's own V4 code
with the fee rule corrected, and it reads through StateView so it stays `view`.

Route a pool here when its `hooks` address is non-zero and to `zQuoterV4`
otherwise. Local tick math cannot quote a hooked pool - a hook may replace the
curve, take a delta out of the output, or set the fee per swap, none of which
is visible in slot0. This wraps Uniswap's canonical V4Quoter, which runs the
hook for real through `PoolManager.unlock`. Not `view`, because `unlock` writes
transient storage; `eth_call` simulates it fine. `solveExactOut` bisects
exact-in quotes for hooks that implement only one direction, as the ETH/FWA
hook does.

Swapbatch binds `legacyBoard = address(0)`: no legacy board is reachable through
it, so `tokensOut` must be empty and `legacyBoardMode` false on every call.


### Reproducing an address

Every board pins `max_optimizer_runs` in
[foundry.toml](foundry.toml) — Dutchboard at 20, Swapboard, Floorboard and
SwapboardView at 200 — because they do not otherwise fit EIP-170. A salt is only
valid for initcode built at the pinned setting, so `forge verify-contract` needs
`--num-of-optimizations` set to it explicitly; the default profile's 9,999,999
produces bytecode Etherscan will reject. The same applies to the metadata
renderers, which compile at their **parent board's** setting rather than their
own, because the board embeds their creation code.

## zSwap: permanent onchain HTML dapp

[zSwap.sol](src/zSwap.sol) is a swap dapp whose entire UI — [zSwap.html](zSwap.html) — is designed to live on Ethereum mainnet as contract code. No IPFS pin, no gateway server, no frontend build pipeline. As long as Ethereum produces blocks, the dapp resolves byte-identical forever.

Current v0.1 deployment flow: deploy the six generated HTML data contracts, then deploy `zSwap(data1, data2, data3, data4)` with those addresses. Record the final wrapper address here after deployment.

### The permanent-HTML pattern

The HTML payload is installed as the **runtime bytecode of six data contracts** created before the wrapper. The wrapper keeps six `immutable` pointers (`DATA1`…`DATA6`). At read time, `html()` copies all six chunks back with `EXTCODECOPY` into one ABI-encoded `string` return — any RPC client decodes it directly.

- **Why multiple data contracts?** EIP-170 caps deployed code at 24,576 bytes. Splitting the page makes that limit apply per chunk instead of to the full dapp. The current payload is 127,705 bytes across 6 data contracts (21,285 / 21,285 / 21,285 / 21,285 / 21,285 / 21,280 bytes), with 19,751 bytes of 6-chunk headroom.
- **Why runtime bytecode instead of `SSTORE`?** Code is cheaper to deploy than equivalent storage, and `EXTCODECOPY` reads the blob directly. Storage-backed HTML would pay 20k gas per 32-byte word at write time and multiple SLOADs on read.
- **Why immutable?** Each chunk is deployed with a minimal data-contract init stub (`PUSH2 <len> DUP1 PUSH1 0x0A PUSH0 CODECOPY PUSH0 RETURN | <payload>`). The wrapper constructor rejects missing or duplicated chunks, then stores the addresses immutably. Nothing in the wrapper can mutate the response, which is why the dapp ships `Cache-Control: public, max-age=31536000, immutable`.

### Browsing it

`zSwap` implements [ERC-5219](https://eips.ethereum.org/EIPS/eip-5219) and advertises resolution mode `"5219"` per [ERC-4804](https://eips.ethereum.org/EIPS/eip-4804), so any `web3://` gateway serves it as a normal web page:

- **HTTP gateway**: `https://<zswap-address>.1.w3link.io/`
- **Native `web3://`**: wallets/browsers with web3:// protocol support (e.g. the Web3URL extension).
- **Raw RPC**: `cast call <zswap-address> "html()(string)" --rpc-url <rpc> > zSwap.html` then open the file locally.

Path and query parameters are ignored — the contract is a single-page app served from any URL under its address.

### What the dapp does

Once loaded, `zSwap.html` is a self-contained swap UI that:

- Connects an injected wallet (MetaMask, Rabby, etc.) on Ethereum mainnet.
- Quotes via [zQuoter](https://etherscan.io/address/0x0000002d9a651b729e3aFBE57Fc84FFDa4a98a13) across Uniswap V2/V3/V4, Sushi, Curve, Lido, and zAMM.
- Compares those AMM routes with live current Swapboard, legacy Swapboard v1, and Dutchboard liquidity, then composes a better exact-in or exact-out split when one exists.
- Routes the swap through [zRouter](https://etherscan.io/address/0x000000000000FB114709235f1ccBFfb925F600e4), handling ERC-20 approvals and native ETH.
- Keeps split routes atomic for ETH and ERC-20 input, with EIP-2612, Permit2, and EIP-5792 wallet batching available through the same swap button.
- Places fixed-price or linearly decaying Dutch orders, and fills public fungible orders, through the same permit → Permit2 → existing allowance → atomic wallet batch → legacy approval funding paths.
- Pins AMM and book reads to one block, re-quotes the AMM remainder after allocating book liquidity, and accepts a hybrid only when its expected improvement clears a gas-aware threshold.
- Bounds order discovery and planning work, and discloses `Book scan capped` or `Planner heuristic/capped` whenever the displayed result may omit a better combination.
- Displays the chosen source DEX, effective rate, and Min received / Max paid under the user's slippage setting.
- Sends native ETH or ERC-20s directly, with recipient resolution for `0x`, `.eth`, `.wei`, and `.gwei`.
- Manages SLOW time-locked sends: deposit with a delay, reverse before maturity, and claim when ready.

No JavaScript bundler, no external asset loads at runtime — icons are inlined SVG and the script speaks JSON-RPC directly to the injected provider.

### Routed order ownership

Swapboard and Dutchboard each expose a regular creation function that delegates to an internal helper with `msg.sender`, plus a `...For(maker)` variant. The `For` caller supplies the complete escrow, while the named maker owns cancellation, returned escrow, and fill proceeds. No EIP-712/ERC-1271 maker authorization or nonce is needed for that boundary: naming another address cannot debit it and can only give it a funded order. A signature becomes necessary if a future path pulls the named maker's assets, reimburses a sponsor, or executes reusable offchain instructions. Accordingly, an indexed `maker` field proves who owns the funded order, not that the address requested or endorsed it; unsolicited sponsored orders are possible but cannot cost the named maker assets.

Dutchboard adds a third creation route for a single NFT: `safeTransferFrom` the token into the board with an ABI-encoded `PushTerms` — quote asset and decay curve — as the transfer's `data`. This exists to eliminate an authorization rather than a transaction. `listNFT` needs a per-id `approve` or, in practice, a blanket `setApprovalForAll` that leaves the board holding standing authority over every token in the collection long after the listing closes; a push grants nothing and hands over exactly one token. It is a `...For`-shaped route in that the seller can differ from the caller, but safely so: `from` has provably parted with the token by the time the hook runs, so naming them seller is the only non-lossy choice. Because the hook can be called directly by anything claiming to be a collection, the board treats `msg.sender` as the only trustworthy source of the collection address and re-verifies that it actually holds the token before opening a listing — otherwise a caller transferring nothing could mint a listing against escrow already backing someone else's. Bundles still require `listNFT`, since `safeTransferFrom` delivers one token per call.

Orderbol connects that primitive to zRouter. Its deployment binds the reviewed current Swapboard and Dutchboard immutably; the ABI-compatible board argument must select one of those bindings. For ERC-20 orders, zRouter first calls `checkpoint(token)`, then funds Orderbol and places the order through the same immediate executor. The transient, single-use checkpoint accepts exactly the post-checkpoint balance increase, so a later caller cannot convert donated or stranded tokens into an order they own. Orderbol returns and validates the created order/listing ID, rejects unrecoverable WETH refund destinations, and accepts an optional placement deadline. Native Swapboard orders instead bind the escrow to the exact `msg.value`; native Dutch sell orders are wrapped into canonical WETH before listing because Dutchboard escrows ERC-20 lots.

Swapbol applies the same checkpoint and per-call delta isolation to composed public fills. It grants each board or zRouter only an exact, call-scoped allowance, revokes it before returning, keeps output `recipient` separate from `refundTo`, and rejects zero/self destinations and ambiguous same-asset ETH/WETH routes. Private orders and NFTs remain direct-wallet fills because pretending that a router is an arbitrary taker would weaken Swapboard's `counterparty == msg.sender` authorization.

### Native ETH, WETH, and Dutch liquidity

The UI presents ETH consistently while preserving each venue's settlement asset. Swapboard resting ETH is canonical WETH. For native input, Swapbol wraps only the exact amount consumed by each Swapboard leg; a Dutch leg is paid as literal ETH when its quote is `address(0)`, or with freshly wrapped WETH when its quote is WETH. This makes WETH-quoted Dutch liquidity composable with an ETH-input route instead of silently dropping it. For native output, book legs deliver WETH to Swapbol, which unwraps only the current call's aggregate WETH increase and sends the resulting ETH to the recipient. Pre-existing WETH and forced ETH stay outside the route.

Makers can cancel a Swapboard WETH order or a fungible Dutchboard WETH listing back to native ETH through `cancelOrderUnwrap` and `cancelUnwrap`. Both redemption paths delete order state before external calls and verify exact WETH debit and ETH credit so one order cannot consume pooled wrapper escrow. Swapboard also refuses its own address or WETH as a maker/recipient; Dutchboard refuses zero/self fill recipients and exact-checks fungible transfers, while native-ETH sellers must accept ETH.

Dutchboard is intended for reviewed, standard ERC-20s and ERC-721s. Rebasing, reflection, taxed, upgradeable-with-confiscation, callback-dependent, and otherwise non-standard token contracts are unsupported: exact transfer deltas cannot protect pooled escrow from a later balance or ownership change. Partial fills round each `costOf` result upward independently, so splitting a low-decimal lot can cost more than one larger fill; `endPrice == 0` is an intentional free terminal price, and listings remain live there until cancelled.

### Bounded book planning and display safety

SwapboardView caps planning at 256 candidates, removes all-or-nothing rows that cannot fit the current request before that cap, and bounds token metadata calls by gas and returndata size. Invalid or hostile `symbol()` / `decimals()` responses fall back to a blank symbol and 18 decimals. The browser decoder independently validates every dynamic offset and string length, then strips markup-sensitive characters before order metadata reaches HTML.

The in-page planner compares rate-greedy execution, every single all-or-nothing seed, and every pair among the first 24 all-or-nothing candidates. It returns at most 32 book legs and re-quotes the remaining AMM amount for up to two rounds. This materially improves mixed AON selection without pretending to solve an unbounded knapsack: candidate, leg, or higher-order AON limits set the visible `Planner heuristic/capped` warning.

### Regenerating the payload

`zSwap.html` at the repo root is the canonical source. To rebuild the Solidity payload after editing it:

```
node script/build-zSwap.mjs
node script/build-zSwap-chunks.mjs
forge test --match-path test/zSwap.t.sol
```

`build-zSwap.mjs` refreshes size natspec and the canonical source comment at the bottom of `zSwap.sol`. `build-zSwap-chunks.mjs` writes `out/zSwap.chunk1.creation.txt` through `out/zSwap.chunk4.creation.txt`; deploy those creation payloads first, then deploy `zSwap` with the resulting chunk addresses as constructor args.

Compiler pin: Foundry uses Solidity `0.8.36` with `via_ir = true` and optimizer runs `9_999_999`. The zQuoter extraction script also uses `0.8.36`, but keeps the low-runs/yul-disabled recipe needed to stay under EIP-170.

## TokenList: the token registry as an NFT collection

[TokenList](https://etherscan.io/address/0x0000006013dF75A31678B786061C2B54bf531524) ·
[TokenListRenderer](https://etherscan.io/address/0x000000d595e36Dd0228c4040D981A01A59DbbE87) ·
[source](src/utils/TokenList.sol)

An onchain token list where each listing **is** an ERC-721. The card for a token on
this chain is minted to the token's own address, so anyone looking at that contract
on Etherscan sees a listing carrying its logo, symbol, decimals and links. Minting
lists, burning delists, re-minting relists. Eleven entries are live.

Curation is the only power the owner holds over *facts*. For local tokens
`name`/`symbol`/`decimals` are read from the token contract itself and can never be
typed in by the owner; `sync` is permissionless, so the owner is never the reason a
stale name persists. The owner authors only what has no onchain source — logo, theme,
links, and a sort weight.

### Weight is a sort key, not a position

`rank` is a weight: higher sorts first, `0` is unranked. The card prints `WEIGHT`, not
`RANK`, because a renderer is handed one listing and cannot know an ordinal even in
principle — position is the `rankedIds()` index. Seeded weights step by 1,000 so a
token can be placed *between* two existing ones by picking a number in the gap,
instead of renumbering everything below it.

### Two orderings, chosen by the reader

[ZorgConviction](src/dao/ZorgConviction.sol) layers conviction voting on top: zOrg
holders bond shares to a listing id and support accrues on an exponential half-life.
It **never writes to the registry** — no `setRank`, no permission over it — and
`ZorgTokenListLens` can only ever return ids the registry already lists. Conviction
permutes the curated set; it cannot add to it or surface something delisted.

So the same registry serves both, and each consumer picks: `tokenList.rankedIds()`
for the curator's order, or the lens for the earned order with the curator's as the
tie-break. On an unvoted list the two are identical.

### Why display text loses its apostrophes

Text sourced from third-party token contracts is sanitised at the storage boundary
with an allowlist: printable ASCII minus the characters that can terminate a string
or an element in the two documents the registry emits.

The filter **drops rather than escapes**, because the same text is rendered into both
XML and JSON and correct escaping differs between them — `&amp;` is right for the
SVG and wrong for the JSON, so no single escaping pass is correct for both. Dropping
produces one output valid in both, unconditionally.

Because the registry is immutable and its renderer is replaceable, sanitisation is
deliberately stricter than any single renderer requires: the guarantee has to hold
for renderers that do not exist yet. The current renderer puts curated text only in
text nodes, where an apostrophe is legal — but it delimits its attributes with single
quotes, and storage outlives renderers.

The cost is typographic. `Circle's stablecoin` stores and renders as
`Circles stablecoin`, and the same applies to a token whose own `name()` contains one.
We took that over carrying an escaping bug we could never fix. It is deterministic,
identical for every reader, and there is no ambiguity or collision — only missing
punctuation.

## Precision DeFi

Instead of building a generalized AMM that handles arbitrary token pairs — a singleton (Uniswap V4, Ekubo) or a factory (Uniswap V2/V3, Curve) — we build custom pool contracts for specific pairs. Everything the pool will ever need is known at compile time: token addresses, decimals, fee, and curve parameters are constants, not storage. No tick math, no bitmap traversal, no pool key lookups, no hook dispatch, no factory overhead.

Three pool archetypes:

### PrecisionStablePool (USDT/USDC)

Hardcoded stableswap using Curve's invariant (A=2000), simplified for exactly 2 tokens with identical decimals. The curve keeps reserves balanced under arbitrage pressure while remaining nearly flat for normal-sized trades.

- **Fee**: 50 pips (0.005% / 0.5 bps) — undercuts [Ekubo](https://docs.ekubo.org/about-ekubo/features) and [Uniswap V3](https://docs.uniswap.org/concepts/protocol/fees) (1 bps) by 2x, [Curve 3pool](https://curve.readthedocs.io/exchange-pools.html) (4 bps) by 8x
- **LP revenue**: 100% to LPs, no protocol fee
- **Integration**: EIP-7702 batch wallet, zRouter `snwap`, or [multisig executeBatch](https://etherscan.io/address/0xd54cb65224410f3ff97a8e72f363f224419f4fb0)

### PrecisionRangePool (ETH/USDC $2200-$3000) — deprecated

> Superseded by **PrecisionPool**, which is this design with the pair, band and
> fee as constructor parameters, behind a CREATE2 factory with an on-chain
> registry and a lens. The AMM step is unchanged. Retained as a gas baseline;
> not for deployment. See the contract header for the two behavioural
> differences and the overflow bound that motivated generalising it.

Concentrated constant-product pool with a hardcoded price range. The range is baked in as virtual reserve offsets — the core AMM step is a single multiplication and division, with no traversal loops, ticks, or bitmaps. Uses native ETH (not WETH).

Separate pools cover different ranges. zRouter/zQuoter queries all and routes to whichever covers the current price:

```
PrecisionRangePool_2200_3000  ← active when ETH is $2200-$3000
PrecisionRangePool_3000_4000  ← active when ETH is $3000-$4000
```

- **Fee**: 500 pips (0.05% / 5 bps) — matches Uniswap V3's most popular ETH/USDC tier
- **LP revenue**: 100% to LPs, no protocol fee
- **Integration**: EIP-7702 batch wallet, zRouter `snwap`, or [multisig executeBatch](https://etherscan.io/address/0xd54cb65224410f3ff97a8e72f363f224419f4fb0)
- **Note**: retained swap fees cause gradual range drift — redeploy fresh pools to recalibrate

### PrecisionOraclePool (ETH/USDC)

No AMM curve. [Chainlink ETH/USD](https://data.chain.link/feeds/ethereum/mainnet/eth-usd) sets the price directly — swaps execute at the oracle price ± a dynamic fee. Zero price impact at any size: a $10M swap gets the same rate per unit as a $100 swap.

The dynamic fee ramps linearly from 1 bps (oracle just updated) to 50 bps (at the 1-hour heartbeat limit), matching Chainlink's 0.5% deviation threshold. When the oracle price changes, the first swap pays max fee — blocking sandwich attacks around oracle update transactions. Uses native ETH.

This design eliminates curve-based [LVR](https://a16zcrypto.com/posts/article/lvr-quantifying-the-cost-of-providing-liquidity-to-automated-market-makers/) (loss-versus-rebalancing), the dominant source of LP loss on Uniswap V3 ETH/USDC. Residual adverse selection from oracle lag is bounded by the deviation threshold and mitigated by the dynamic fee. LPs earn fee revenue on every trade without being systematically arbed through a bonding curve. Prior art: [DODO's PMM](https://docs.dodoex.io/en/product/how-to-use-pools/pool-type/pegged-pool) uses oracle-priced pools with configurable parameters in storage.

Why this only works as a precision pool: the oracle address, deviation threshold, heartbeat, and decimal conversion (ETH 18 / oracle 8 / USDC 6) are all compile-time constants. The dynamic fee is calibrated to the specific feed's parameters. A generalized AMM can't embed feed-specific risk parameters per pair.

- **Fee**: 100–5000 pips (1–50 bps) — dynamic, based on oracle freshness
- **LP revenue**: 100% to LPs, no protocol fee
- **Integration**: EIP-7702 batch wallet, zRouter `snwap`, or [multisig executeBatch](https://etherscan.io/address/0xd54cb65224410f3ff97a8e72f363f224419f4fb0)

### Gas Benchmarks

All numbers measured via Foundry fork tests on Ethereum mainnet.

**Pool-level gas** (swap function only, warm storage):

| Pool | Direction | Gas |
|------|-----------|-----|
| PrecisionRangePool | USDC→ETH | 12,821 |
| PrecisionRangePool | ETH→USDC | 40,667 |
| PrecisionOraclePool | USDC→ETH | 40,626 |
| PrecisionOraclePool | ETH→USDC | 84,227* |
| PrecisionStablePool | USDC→USDT | 42,841 |

*Oracle pool ETH→USDC includes a cold Chainlink staticcall (~2,600 gas). When the oracle is warm (multiple swaps per block), both directions are ~40k.

**End-to-end via EIP-7702** (transfer + swap, measured):

| Swap | Gas |
|------|-----|
| USDC→ETH | **36,922** |
| ETH→USDC | **65,748** |
| USDC→USDT | **74,254** |
| USDT→USDC | **78,425** |

**End-to-end via zRouter snwap** (measured):

| Swap | Gas |
|------|-----|
| USDC→ETH | 52,172 |
| USDC→USDT | 91,750 |
| USDT→USDC | 90,896 |

**Competitors** (router-inclusive, all from official snapshots):

| Swap type | Us (7702) | Ekubo | V3 | V4 | Curve |
|-----------|----------|-------|-----|-----|-------|
| ERC-20→ERC-20 | **74,254** | 85,675 | ~105k | ~117k | ~120-150k |
| ERC-20→ETH | **36,922** | 75,644 | ~105k | ~117k | — |
| ETH→ERC-20 | **65,748** | 69,243 | ~105k | ~117k | — |

Competitor numbers are from standard swap benchmarks (not necessarily identical pairs); gas cost is pair-independent in generalized AMMs. Sources: [Ekubo](https://github.com/EkuboProtocol/evm-contracts/blob/main/snapshots/RouterTest.json), [Uniswap V3](https://github.com/Uniswap/v3-core/blob/main/test/__snapshots__/UniswapV3Pool.gas.spec.ts.snap), [Uniswap V4](https://github.com/Uniswap/v4-core/blob/main/snapshots/PoolManagerTest.json). Ekubo's specialized MEVCaptureRouter achieves ~30-41k ([snapshot](https://github.com/EkuboProtocol/evm-contracts/blob/main/snapshots/MEVCaptureRouterTest.json)) but is not the standard user path.

### Why it's cheaper

Every generalized AMM pays a "generality tax" per swap:

| Operation | Generalized AMM | Precision Pool |
|-----------|----------------|----------------|
| Token address lookup | SLOAD (2100 gas cold) | Constant (0 gas) |
| Fee tier lookup | SLOAD or pool key param | Constant (0 gas) |
| Price curve math | Tick traversal loop, sqrtRatio | Stableswap, single mul/div, or oracle read |
| Pool key hashing | keccak256 | N/A |
| Hook/extension dispatch | External call | N/A |
| Flash accounting / till | Transient storage bookkeeping | N/A |
| Decimal normalization | Runtime math | Compile-time known |
| Transfer safety | Generic safeTransfer with return check | Minimal (trusted tokens) |
| ETH handling | WETH wrap/unwrap overhead | Native ETH (range pool) |

Precision pools eliminate every row except the curve math and the transfer itself — and for the range pool, the curve math reduces to a single xy=k step. The oracle pool goes further: it replaces the curve entirely with a Chainlink read, enabling zero-price-impact execution that generalized AMMs can't offer at any gas cost.
