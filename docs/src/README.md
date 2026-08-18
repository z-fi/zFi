# zFi
the first onchain superdapp

[zRouter](https://etherscan.io/address/0x000000000000FB114709235f1ccBFfb925F600e4)
[zQuoter](https://etherscan.io/address/0xc7a03f9ed2be5feea18ce93e12f4f05c98287c16)
[zSwap source](src/zSwap.sol)

## zSwap: permanent onchain HTML dapp

[zSwap.sol](src/zSwap.sol) is a swap dapp whose entire UI — [zSwap.html](zSwap.html) — is designed to live on Ethereum mainnet as contract code. No IPFS pin, no gateway server, no frontend build pipeline. As long as Ethereum produces blocks, the dapp resolves byte-identical forever.

Deployment flow: deploy the FOURTEEN generated chunk contracts (`out/zSwap.chunk1..14.creation.txt`), then deploy `zSwap(dao, previous, chunk1, ..., chunk14)` with those addresses. The count is not decorative - the constructor reverts `InvalidData` unless all fourteen are present, non-empty and distinct, and `script/check-zSwap.mjs` fails the build if the source and the Solidity disagree about it. Record the final wrapper address here after deployment.

`html()` is IMMUTABLE, so a page fix is never an update in place: it is a new set of chunks and a new wrapper, deployed by the DAO through `deployNext`, with the naming layer repointed at it. That is the whole design - an address whose bytes cannot move under an auditor or a bookmark - and it means an edit to `zSwap.html` is not live until that has happened.

### The permanent-HTML pattern

The HTML payload is installed as the **runtime bytecode of six data contracts** created before the wrapper. The wrapper keeps six `immutable` pointers (`DATA1`…`DATA6`). At read time, `html()` copies all six chunks back with `EXTCODECOPY` into one ABI-encoded `string` return — any RPC client decodes it directly.

- **Why multiple data contracts?** EIP-170 caps deployed code at 24,576 bytes. Splitting the page makes that limit apply per chunk instead of to the full dapp. The current payload is 287,734 bytes across 12 data contracts (23,978 / 23,978 / 23,978 / 23,978 / 23,978 / 23,978 / 23,978 / 23,978 / 23,978 / 23,978 / 23,978 / 23,976 bytes), with 7,178 bytes of 12-chunk headroom.
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
- Quotes via [zQuoter](https://etherscan.io/address/0xc7a03f9ed2be5feea18ce93e12f4f05c98287c16) across Uniswap V2/V3/V4, Sushi, Curve, Lido, and zAMM.
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

`build-zSwap.mjs` refreshes the size natspec in `zSwap.sol`, the payload sentence in both READMEs, and the length + keccak pins in `test/zSwap.t.sol`; the page itself is no longer copied into the contract, because that copy could only ever drift and did. `build-zSwap-chunks.mjs` writes `out/zSwap.chunk1.creation.txt` through `out/zSwap.chunk14.creation.txt`; deploy those creation payloads first, then deploy `zSwap` with the resulting chunk addresses as constructor args.

Compiler pin: Foundry uses Solidity `0.8.36` with `via_ir = true` and optimizer runs `9_999_999`. The zQuoter extraction script also uses `0.8.36`, but keeps the low-runs/yul-disabled recipe needed to stay under EIP-170.

## Precision DeFi

Instead of building a generalized AMM that handles arbitrary token pairs — a singleton (Uniswap V4, Ekubo) or a factory (Uniswap V2/V3, Curve) — we build custom pool contracts for specific pairs. Everything the pool will ever need is known at compile time: token addresses, decimals, fee, and curve parameters are constants, not storage. No tick math, no bitmap traversal, no pool key lookups, no hook dispatch, no factory overhead.

Three pool archetypes:

### PrecisionStablePool (USDT/USDC)

Hardcoded stableswap using Curve's invariant (A=2000), simplified for exactly 2 tokens with identical decimals. The curve keeps reserves balanced under arbitrage pressure while remaining nearly flat for normal-sized trades.

- **Fee**: 50 pips (0.005% / 0.5 bps) — undercuts [Ekubo](https://docs.ekubo.org/about-ekubo/features) and [Uniswap V3](https://docs.uniswap.org/concepts/protocol/fees) (1 bps) by 2x, [Curve 3pool](https://curve.readthedocs.io/exchange-pools.html) (4 bps) by 8x
- **LP revenue**: 100% to LPs, no protocol fee
- **Integration**: EIP-7702 batch wallet, zRouter `snwap`, or [multisig executeBatch](https://etherscan.io/address/0xd54cb65224410f3ff97a8e72f363f224419f4fb0)

### PrecisionRangePool (ETH/USDC $2200-$3000)

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
