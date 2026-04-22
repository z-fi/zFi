# zFi
the first onchain superdapp

[zRouter](https://etherscan.io/address/0x000000000000FB114709235f1ccBFfb925F600e4)
[zQuoter](https://etherscan.io/address/0x9909861aa515afbce9d36c532eae7e0ebf804034)
[zSwap](https://etherscan.io/address/0x000000000A4A4F895734cF70700b6F84AadbcA6C)

## zSwap: permanent onchain HTML dapp

[zSwap.sol](src/zSwap.sol) is a swap dapp whose entire UI — [zSwap.html](zSwap.html) — lives on Ethereum mainnet as contract code. No IPFS pin, no gateway server, no frontend build pipeline. As long as Ethereum produces blocks, the dapp resolves byte-identical forever.

Deployment: [`0x000000000A4A4F895734cF70700b6F84AadbcA6C`](https://etherscan.io/address/0x000000000A4A4F895734cF70700b6F84AadbcA6C)

### The permanent-HTML pattern

The HTML payload (24,549 bytes) is installed as the **runtime bytecode of a separate data contract** created during `zSwap`'s constructor. The wrapper keeps a single `immutable` pointer (`DATA`) to that address. At read time, `html()` copies the payload back with `EXTCODECOPY` into an ABI-encoded `string` return — any RPC client decodes it directly.

- **Why a child contract?** EIP-170 caps deployed code at 24,576 bytes. Storing HTML as runtime bytecode of a dedicated contract gives us the full 24,576-byte budget for payload without fighting the wrapper's own logic for space. zSwap's payload clears the cap with 27 bytes of headroom.
- **Why runtime bytecode instead of `SSTORE`?** Code is cheaper to deploy than equivalent storage, and `EXTCODECOPY` reads the whole blob in one op. Storage-backed HTML would pay 20k gas per 32-byte word at write time and multiple SLOADs on read.
- **Why immutable?** The payload is set once in the constructor via a minimal deploy stub (`PUSH2 <len> DUP1 PUSH1 0x0A PUSH0 CODECOPY PUSH0 RETURN | <payload>`). Nothing in the contract can mutate it. The response is guaranteed byte-identical for the life of the chain, which is why the dapp ships `Cache-Control: public, max-age=31536000, immutable`.

### Browsing it

`zSwap` implements [ERC-5219](https://eips.ethereum.org/EIPS/eip-5219) and advertises resolution mode `"5219"` per [ERC-4804](https://eips.ethereum.org/EIPS/eip-4804), so any `web3://` gateway serves it as a normal web page:

- **HTTP gateway**: `https://0x000000000A4A4F895734cF70700b6F84AadbcA6C.1.w3link.io/`
- **Native `web3://`**: wallets/browsers with web3:// protocol support (e.g. the Web3URL extension).
- **Raw RPC**: `cast call 0x000000000A4A4F895734cF70700b6F84AadbcA6C "html()(string)" --rpc-url <rpc> > zSwap.html` then open the file locally.

Path and query parameters are ignored — the contract is a single-page app served from any URL under its address.

### What the dapp does

Once loaded, `zSwap.html` is a self-contained swap UI that:

- Connects an injected wallet (MetaMask, Rabby, etc.) on Ethereum mainnet.
- Quotes via [zQuoter](https://etherscan.io/address/0x9909861aa515afbce9d36c532eae7e0ebf804034) across Uniswap V2/V3/V4, Sushi, Curve, Lido, and zAMM.
- Routes the swap through [zRouter](https://etherscan.io/address/0x000000000000FB114709235f1ccBFfb925F600e4), handling ERC-20 approvals and native ETH.
- Displays the chosen source DEX, effective rate, and Min received / Max paid under the user's slippage setting.

No JavaScript bundler, no external asset loads at runtime — icons are inlined SVG and the script speaks JSON-RPC directly to the injected provider.

### Regenerating the payload

`zSwap.html` at the repo root is the canonical source. To rebuild the Solidity payload after editing it:

```
node script/build-zSwap.mjs
forge test --match-path test/zSwap.t.sol
```

The builder re-encodes the hex chunks in the constructor and refreshes the embedded source comment at the bottom of `zSwap.sol` so on-chain verification matches the repo byte-for-byte.

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
