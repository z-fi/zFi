# Precision DeFi: Asset-Specific Pools with Generalized Routing

**z0r0z** | April 2026

---

## Abstract

Generalized AMMs abstract away token-specific properties to support arbitrary pairs. We invert this: push generalization to the router and smart account layer, apply asset-specific optimization at the pool. Token addresses, decimals, fees, and curve parameters become compile-time constants -- no storage reads, no factory overhead, no hook dispatch. A generalized router and EIP-7702 smart accounts provide composability. We demonstrate three pool archetypes -- stableswap, concentrated range, and oracle-priced -- achieving 1.4--3$\times$ gas reduction over comparable AMMs while enabling designs that generalized architectures can only express with significant overhead.

## 1. Motivation

Generalized AMMs pay a per-swap tax for their generality. Uniswap V4 and Ekubo require storage reads for token addresses, fee tiers, and pool configuration on every interaction. V3 uses immutables for some parameters but still pays for tick traversal, bitmap lookups, and sqrtPrice math. Hook systems add extensibility at the cost of external calls and validation logic. All of these costs exist because the pool does not know its pair at compile time.

Meanwhile, the asset landscape of DeFi has matured. The pairs that dominate volume -- ETH/USDC, USDT/USDC, ETH/USDT -- are stable in their composition. Their token addresses, decimal representations, and behavioral properties do not change. Designing pool contracts around these known properties, rather than abstracting them away, is an optimization that generalized architectures can only approximate through storage and runtime dispatch.

Concurrently, account abstraction standards (EIP-7702, ERC-4337) shift composability from the protocol layer to the account layer. When a user's account can atomically batch a token transfer and a pool call in a single transaction, the pool no longer needs to internalize routing, approval management, or multi-hop logic. The pool can be minimal; the account provides the glue.

## 2. Architecture

Precision DeFi separates concerns along a clear boundary:

$$\text{Generalization} \rightarrow \text{Router / Smart Account} \qquad \text{Precision} \rightarrow \text{Pool}$$

**Pools** are deployed per-pair with all parameters as Solidity `constant` declarations. No `SLOAD` is required for token addresses, fees, or curve parameters. Each pool implements only the swap, liquidity, and ERC-20 LP token logic relevant to its specific pair and pricing model. Pools use the balance-delta pattern (transfer-then-call) common to Uniswap V2 pair contracts, requiring atomic integration.

**zRouter** handles token approvals, multi-hop routing, and output validation. It queries zQuoter to find optimal routes across precision pools, Uniswap, Curve, and other venues.

**Smart accounts** (EIP-7702 delegated EOAs, Safe multisigs, ERC-4337 wallets) batch the transfer and swap atomically, eliminating the need for pool-level `transferFrom` or approval state. This is where composability lives -- not in the pool.

## 3. Pool Archetypes

### 3.1 PrecisionStablePool

A stableswap pool for pegged pairs (USDT/USDC) using Curve's invariant with $A = 2000$, simplified for exactly two tokens with identical decimals. Fee is 0.5 bps, undercutting Uniswap V3 (1 bps) by 2$\times$ and Curve (4 bps) by 8$\times$. All fee revenue accrues to LPs with no protocol take.

### 3.2 PrecisionRangePool

A concentrated constant-product pool for volatile pairs (ETH/USDC) with a hardcoded price range. Virtual reserve offsets concentrate liquidity into the range -- the core AMM step is a single multiplication and division. No ticks, no bitmaps, no traversal loops. Separate deployments cover adjacent ranges; the router selects the active pool. Uses native ETH rather than WETH, eliminating wrap/unwrap overhead.

### 3.3 PrecisionOraclePool

An oracle-priced pool that replaces the bonding curve with a Chainlink price feed. Swaps execute at the oracle price $\pm$ a dynamic fee, producing no curve-induced price impact for trades within available inventory. The fee ramps from 1 bps (fresh oracle) to 50 bps (at the heartbeat limit), calibrated to Chainlink ETH/USD's 0.5\% deviation threshold. A sandwich protection mechanism detects oracle price changes and charges max fee on the first swap after a change, neutralizing front-running of oracle update transactions.

This eliminates curve-based loss-versus-rebalancing (LVR), the dominant source of LP loss on concentrated liquidity AMMs. Residual adverse selection from oracle lag remains, limited in practice by the feed's deviation threshold and the dynamic fee. The oracle address, deviation threshold, heartbeat, and decimal conversion are all compile-time constants -- a generalized AMM can only implement this by reintroducing per-pool configuration storage or hook dispatch overhead.

## 4. Gas Results

All measurements from Foundry fork tests on Ethereum mainnet (internal gas via `gasleft()` delta, excluding 21k base transaction cost -- same basis as competitor snapshots). End-to-end numbers include token transfer and swap via EIP-7702 batch execution. Tests are reproducible from the repository.

| Swap | Pool | Pool-level | 7702 end-to-end | Uniswap V3 | Uniswap V4 |
|------|------|-----------|----------------|------------|------------|
| USDC $\rightarrow$ ETH | Range | 12,821 | **36,922** | $\sim$105k | $\sim$117k |
| ETH $\rightarrow$ USDC | Range | 40,667 | **65,748** | $\sim$105k | $\sim$117k |
| USDC $\rightarrow$ USDT | Stable | 42,841 | **74,254** | $\sim$105k | $\sim$117k |

The gap is the generality tax: storage lookups for token addresses and fees ($\sim$2,100 gas per cold `SLOAD`), pool key hashing, hook dispatch, flash accounting, decimal normalization, and WETH wrap/unwrap. Precision pools eliminate all of these. The dominant remaining costs are the pricing math and the token transfer.

## 5. Discussion

**Trade-offs.** Precision pools sacrifice generality for efficiency. Each new pair requires a new deployment, liquidity must be bootstrapped per pool, and parameter changes require redeployment rather than governance calls. Complexity is redistributed, not removed: routing logic moves to zRouter, liquidity discovery moves to zQuoter, and atomic execution depends on smart account or router support. We view pool-level immutability as a feature: auditable, single-purpose contracts with no admin keys and no upgrade path to introduce risk.

**Relationship to hooks.** Uniswap V4 hooks can express custom per-pool logic, including oracle-based pricing. But hooks inherit the singleton's dispatch loop, storage layout, flash accounting, and pool key overhead. Hooks add flexibility to a generalized base; precision pools remove the generalized base.

**Relationship to solvers.** Intent-based systems (CoW Protocol, UniswapX) use off-chain solvers to optimize execution across venues. Precision pools are complementary -- a solver will route to whichever venue offers the best fill, and an oracle-priced pool quoting without curve traversal for trades within available inventory at ~40k gas competes well against generalized AMMs at 105k+.

**LP experience.** There is no position manager, no NFT tokenization of ranges, no tick-space fragmentation. LP tokens are standard ERC-20s representing a proportional claim on pool reserves. For the oracle pool, LPs additionally benefit from the elimination of curve-based LVR.

**Extensibility.** The three archetypes presented here are not exhaustive. Because each pool is a standalone contract with no shared base, new archetypes can embed arbitrary asset-specific logic without affecting existing deployments. Possible directions include: time-dependent pricing for token launches or fixed-maturity yield tokens, where start/end timestamps and prices are compile-time constants; yield-bearing stableswaps that hardcode lending protocol addresses and deposit idle reserves directly; pools for rebasing tokens that track shares rather than balances using the issuer's canonical interface; or pools with inventory-sensitive curves (similar to DODO's PMM) where the curve shape and oracle parameters are hardcoded rather than stored. Each new pair or pricing model is a fresh contract -- the router integrates it alongside existing pools without migration or upgrade.

## 6. Conclusion

The highest-volume pairs are known, their properties are stable, and account abstraction now provides the composability that generalized pools previously had to internalize. By moving generalization to the router and smart account while applying asset-specific optimization at the pool, Precision DeFi achieves lower gas costs, simpler LP mechanics, and new pool designs -- such as oracle-priced execution without curve-induced slippage for trades within available inventory -- that generalized architectures can only achieve with higher overhead.

---

*Contracts: [github.com/z-fi/zFi/src/pools](https://github.com/z-fi/zFi/tree/main/src/pools)*
