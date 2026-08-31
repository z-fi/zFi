# Security Review: zswap-audit

## Scope

Static audit of the live-configured Precision Pools AMM, factory, route/zap, launcher/token, chart tape, policy, and deployed lenses requested in SCOPE.md.

- Scan mode: scoped_path
- Target kind: directory_snapshot
- Target ID: target_sha256_371df6d449d98af237d40979d8498eb4f2cf8f2b7799664c80d2dd0e145e1c2c
- Snapshot digest: codex-security-snapshot/v1:sha256:371df6d449d98af237d40979d8498eb4f2cf8f2b7799664c80d2dd0e145e1c2c
- Inventory strategy: scoped_path
- Included paths: src/pools/PrecisionPool.sol, src/pools/PrecisionPoolFactory.sol, src/pools/PrecisionRoute.sol, src/pools/PrecisionLauncher.sol, src/pools/PriceTape.sol, src/pools/PrecisionPoolPolicy.sol, src/pools/PrecisionPoolLens.sol, src/pools/PrecisionLiquidityLens.sol, src/pools/PrecisionLauncherLens.sol
- Excluded paths: src/pools/PrecisionOraclePool.sol, src/pools/PrecisionRangePool.sol, src/pools/PrecisionStablePool.sol, src/zPool.sol, src/pools/PrecisionZap.sol, src/pools/ConstantSurchargeHook.sol, src/pools/FeeSplitter.sol, lib/, test/
- Runtime or test status: Static validation complete; targeted Foundry execution was unavailable because the pinned solc was not installed and offline mode prevented download.
- Artifacts reviewed: SCOPE.md, HASHES.txt, bytecode-verification.json, foundry.toml
- Scan context: User requests a go/no-go for a live, unpaused Ethereum mainnet deployment and prioritizes custody, supply, liveness, route checkpoints, launch seeding, hostile-token callbacks, PriceTape, and trustedExecutor.

Limitations and exclusions:
- No chain or network reads were performed; live addresses, runtime bytecode, immutable values, pool state, and adoption are accepted only as supplied context.
- The compiler was unavailable offline, so no new executable proof-of-concept or regression test was run.
- The dapp and unrelated router source are outside audit scope; supporting SafeExecutor source was consulted only to resolve the trustedExecutor boundary.
- Excluded src/pools/PrecisionOraclePool.sol: Explicitly marked out of scope and not for deployment in SCOPE.md.
- Excluded src/pools/PrecisionRangePool.sol: Explicitly marked out of scope and not for deployment in SCOPE.md.
- Excluded src/pools/PrecisionStablePool.sol: Explicitly marked out of scope and not for deployment in SCOPE.md.
- Excluded src/zPool.sol: Separate older pool explicitly excluded by SCOPE.md.
- Excluded src/pools/PrecisionZap.sol: Reference-only; deployed zapIn is inside PrecisionRoute.
- Excluded src/pools/ConstantSurchargeHook.sol: Not deployed and no intent to ship was supplied.
- Excluded src/pools/FeeSplitter.sol: Not deployed and no intent to ship was supplied.
- Excluded lib/\*\*: Vendored dependencies were consulted only where needed to explain in-scope behavior, not audited as product scope.
- Excluded test/\*\*: Tests were supporting evidence rather than requested source scope.

### Scan Summary

| Field | Value |
| --- | --- |
| Scan outcome | completed |
| Reportable findings | 2 |
| Severity mix | high: 1, medium: 1 |
| Confidence mix | high: 2 |
| Coverage | complete |
| Validation mode | Independent baseline, architecture review, focused accounting investigation, and parent source-to-sink validation. |

Canonical artifacts: `scan-manifest.json`, `findings.json`, and `coverage.json`. This report is a deterministic projection of those files.

## Threat Model

Precision Pools is an immutable Ethereum AMM and token-launch system. PrecisionPoolFactory reconstructs audited pool creation code from an SSTORE2 blob and deploys one CREATE2 pool per full market tuple. PrecisionPool holds reserves, accounts for LP and fee claims, and supports direct pull-based and factory-prefunded settlement. PrecisionRoute authenticates ERC-20 funding with transaction-scoped balance checkpoints and exact calldata intent hashes before multi-hop routes and zapIn. PrecisionLauncher atomically clones and initializes a fixed-supply LaunchToken, transfers a bounded creator allocation, opens a named unhooked ETH/token market, and permanently holds its LP position for holder redemption. PriceTape is chart-only; the three lenses are off-chain presentation and sizing consumers; PrecisionPoolPolicy is advisory rather than an on-chain route control.

### Assets

- Pool reserves, accrued creator/hook fee liabilities, LP supply, and the invariant that actual balances cover every claim (src/pools/PrecisionPool.sol:202-220, 850-927, 1624-1775).
- LP withdrawal and launcher redemption rights, including the permanently launcher-held position (src/pools/PrecisionPool.sol:1160-1688; src/pools/PrecisionLauncher.sol:653-701).
- LaunchToken one-time initialization and fixed-supply integrity; metadata authority must remain separate from balances and fee-stream authority (src/pools/PrecisionLauncher.sol:16-25, 51-95, 170-223).
- Factory registry integrity, market-to-address determinism, and the SSTORE2 pool creation-code identity (src/pools/PrecisionPoolFactory.sol:82-110, 217-301, 765-810).
- Checkpointed route funds and their committed pool/path, amount, recipient, refund destination, token identity, and slippage limits (src/pools/PrecisionPoolFactory.sol:499-739; src/pools/PrecisionRoute.sol:151-249, 314-767).
- Accuracy of liquidity/zap previews used to choose swapPortion and minLP (src/pools/PrecisionLiquidityLens.sol:251-377).
- Creator fee-stream ownership, immutable treasury and tithe destinations, and payout liveness (src/pools/PrecisionLauncher.sol:341-357, 704-925).
- Chart storage integrity and explicit non-oracle semantics (src/pools/PrecisionPool.sol:930-1004; src/pools/PriceTape.sol:165-387).

### Trust Boundaries

- Public users select pool tuples, opening prices, assets, amounts, recipients, and slippage. Direct pool paths authenticate exact msg.value or in-call token deltas; factory paths validate market shape and named-market creator authority (src/pools/PrecisionPool.sol:509-610, 1167-1220; src/pools/PrecisionPoolFactory.sol:238-477, 795-810).
- Factory-created pools immutably trust their factory for prefunded swap and forwarded-liquidity declarations; the factory must maintain fresh-delta and initialization invariants before entering a pool (src/pools/PrecisionPool.sol:561-610, 1183-1202; src/pools/PrecisionPoolFactory.sol:383-477, 499-762).
- Callback-capable tokens and recipients execute adversarial code during funding or settlement. Pool, route, and factory use independent transient locks, which must protect the actual state owner across every external-call interval (src/pools/PrecisionPool.sol:248-260; src/pools/PrecisionPoolFactory.sol:123-209; src/pools/PrecisionRoute.sol:135-249).
- The immutable trustedExecutor gates factory and route calls, but the configured SafeExecutor is publicly callable in supporting source. Safety therefore depends on local intent/delta controls, not caller secrecy (src/pools/PrecisionPoolFactory.sol:123-169, 507-639; src/pools/PrecisionRoute.sol:151-190).
- A pool hook may set a sender-sensitive bounded surcharge, receive accrued fees, and receive a best-effort afterSwap callback; it has no LP or reserve administration authority (src/pools/PrecisionPool.sol:9-34, 1012-1155).
- A nonzero feeRecipient exclusively initializes a named market and collects its creator-fee share. An unnamed market is public and permits direct pool initialization (src/pools/PrecisionPoolFactory.sol:238-255, 421-452, 809-810; src/pools/PrecisionPool.sol:1222-1228).
- Launch callers choose supply, allocation, valuation, owner, and metadata; the launcher atomically creates the token-dependent named pool and retains LP (src/pools/PrecisionLauncher.sol:520-639).
- Lens outputs cross into off-chain clients and must model the execution sender and arithmetic actually used. They are state snapshots, not reservations, so execution minOut/minLP remains mandatory (src/pools/PrecisionPoolLens.sol:8-12; src/pools/PrecisionLiquidityLens.sol:251-377).
- PrecisionPoolPolicy owner controls advisory curation only; neither route nor factory enforces its answers (src/pools/PrecisionPoolPolicy.sol:14-35).

### Attacker Capabilities

- Any caller may create and seed unnamed pools, trade, add/remove liquidity, launch a token, redeem owned launched tokens, and invoke public routing paths with their own authorized funding.
- A malicious ERC-20 can run callbacks during transfer, control its reported balances/credits, and supply capital to initialize or trade its own market. Strict settlement rejects non-exact deltas, but callback ordering remains security-sensitive.
- A hook operator controls surcharge answers up to the combined 10% fee ceiling and can key them on sender, amount, block state, or other view-readable context.
- Anyone can drive the public SafeExecutor call path, but local factory/route controls require same-transaction fresh funding and bind settlement fields. A separate upstream allowance or permit path would be required to move another user's funds.
- A metadata owner can edit URI/image only; a creator fee holder can transfer only its future fee stream via two-step handoff; a policy owner changes only advisory responses.
- A trader can manipulate chart extrema with executed trades, but no in-scope economic settlement consumes PriceTape.
- No general pool owner, pause key, reserve sweep, launcher LP withdrawal administrator, or post-initialization token minter exists in the reviewed source.

### Security Objectives

- Only exact msg.value, an exact in-call token pull, or a same-transaction committed fresh balance delta may be credited or spent; unrelated surplus must remain unreachable.
- A seed request with nonzero sqrtPriceInit must either initialize at that requested price or revert, even if a token callback changes pool state during factory funding.
- Pool balances must cover reserves plus accrued creator/hook liabilities before ordinary operations, and exits must not let early LPs consume later LPs' backing.
- Transient locks must span token, recipient, hook, and factory-to-pool callbacks across the component that owns the sensitive state.
- Checkpoint intent must bind complete sensitive actions and permit only one funded route per component per transaction.
- Swap and deposit transitions must preserve reserve width, range, resolution, and minOut/minLP constraints.
- Launch initialization and mint must be atomic and one-time; launch pool identity, opening valuation, allocation, LP recipient, and registries must be transactionally bound.
- previewZap must use the same hook-visible sender, fee cuts, reserve transition, and LP arithmetic as PrecisionRoute.zapIn.
- PriceTape and lens values must not be treated as execution commitments or manipulation-resistant oracle data.

### Assumptions

- All nine authorized source hashes match HASHES.txt and its stated tree. The supplied bytecode-verification artifact reports deployed runtime identity outside immutable slots; no chain read independently verified that claim.
- Supplied live factory, route, launcher, policy, pool-lens, liquidity-lens, trustedExecutor, poolCode, tokenImplementation, and treasury addresses are treated as deployment context, not independently established facts.
- The live poolInitCodeHash and actual SSTORE2 blob content were not supplied or read from chain; their match to compiled PrecisionPool creation code remains a deployment prerequisite.
- SCOPE.md briefly describes PrecisionPoolPolicy as consulted by the route, while source explicitly makes it advisory and PrecisionRoute has no policy dependency.
- SCOPE.md reports the executor runtime as 252 bytes while a PrecisionPoolFactory source comment reports 206 bytes. Supporting source shows a public stateless SafeExecutor shape, but the deployed runtime discrepancy remains unresolved.
- PrecisionLauncher creates named markets with hook zero and a plain LaunchToken, so the unnamed-market callback seed race and malicious-hook preview variant do not reach launcher-created pools.
- PrecisionLiquidityLens.previewZap quotes for its external caller and approximates post-swap input reserves with gross input, while route execution presents PrecisionRoute and the pool retains net input.
- The excluded dapp may or may not filter hooked pools, simulate exact route context, normalize PriceTape units, or enforce policy recommendations; these client behaviors were not reviewed.
- No live PrecisionLauncherLens address or PrecisionPoolPolicy owner was supplied.
- Static coverage is complete for the authorized source, but runtime regression testing and live-state verification were unavailable offline.

## Findings

| Finding | Severity | Confidence | Detailed write-up |
| --- | --- | --- | --- |
| [Callback token can replace an unnamed pool's initialization intent during factory funding](#finding-1) | high | high | inline below |
| [previewZap models a different hook caller and reserve transition than zapIn executes](#finding-2) | medium | high | inline below |

> ### Maintainer response — summary
>
> We accept both findings as accurate readings of the contracts, and we thank
> the reviewer: finding 2 lands on the exact seam we flagged in our own scope
> note (`previewZap` versus `PrecisionRoute.zapIn`), which is a good sign about
> where the review spent its attention.
>
> Our position is that **neither finding is reachable for the assets zSwap
> launches or lists**, for reasons the report itself already establishes, and
> that the residual paths are closed at the frontend. Three things carry that:
>
> 1. **Launched markets are structurally excluded, not merely mitigated.**
>    `PrecisionLauncher` sets `hook: address(0)` and `feeRecipient:
>    address(this)` (`src/pools/PrecisionLauncher.sol:616,621`), so every coin
>    launched on zSwap is a *named*, *unhooked* market. The report agrees: "Named markets, including all PrecisionLauncher
>    markets, reject direct non-factory initialization and are not exposed."
> 2. **The listed universe has no callback surface.** The default token set is
>    zList, curated on chain by conviction staking. We checked the ERC-1820
>    registry for every major on it — WETH, USDC, USDT, DAI, WBTC, wstETH,
>    stETH, rETH — and none registers an ERC-777 implementer. `LaunchToken` is
>    a bare Solady ERC-20 with no transfer hook of any kind. Reaching either
>    finding requires a token that is neither launched by us nor listed by
>    the DAO.
> 3. **The frontend closes the residual.** zSwap is the canonical onchain
>    frontend, and it now refuses the preconditions outright (see the per-
>    finding responses below).
>
> **What we are not claiming.** These mitigations are frontend and
> configuration properties, not contract fixes. A direct caller of
> `createAndSeed`, or a third-party integrator, receives none of them. We are
> recording both findings as *mitigated at the frontend, unfixed in the
> contract*, and treating the remediations below as the correct long-term fix
> rather than as closed items. The deployed contracts are unchanged
> deliberately: they hold real value, have run without incident, and accrued
> operating time is itself a safety property we are not willing to reset for a
> path that is unreachable in our deployment.

### Confidence Scale

| Label | Meaning |
| --- | --- |
| high | Direct evidence supports the finding with no material unresolved blocker. |
| medium | Evidence supports a plausible issue, but material runtime or reachability proof remains. |
| low | Evidence is incomplete and the item is retained only for explicit follow-up. |

<a id="finding-1"></a>

### [1] Callback token can replace an unnamed pool's initialization intent during factory funding

| Field | Value |
| --- | --- |
| Severity | high |
| Confidence | high |
| Confidence rationale | The source directly exposes the time-of-check/time-of-use gap, public pool initializer, one-sided boundary seeds, and silent proportional branch. Exact transfer-delta checks do not cover changes in the opposite token. |
| Category | business-logic-race |
| CWE | CWE-841, CWE-367 |
| Affected lines | src/pools/PrecisionPoolFactory.sol:390-409, src/pools/PrecisionPoolFactory.sol:421-452, src/pools/PrecisionPoolFactory.sol:457-477, src/pools/PrecisionPool.sol:1167-1180, src/pools/PrecisionPool.sol:1186-1201, src/pools/PrecisionPool.sol:1222-1237, src/pools/PrecisionPool.sol:1357-1393 |

#### Summary

The factory decides that a pool is empty before calling attacker-controlled token code, but the factory's transient lock does not lock the independently callable pool. A callback token can initialize the pool at a one-sided boundary before the factory enters it, causing the victim's nonzero opening-price intent to be ignored and their assets to be deposited proportionally at the attacker's price.

#### Root Cause

The initialization decision and the token-funding calls are protected by a transient lock in the factory, while the sensitive state being initialized belongs to a separately callable pool with an independent lock. No expected-empty condition is carried into addLiquidityFromFactory.

**Factory checks supply before external token calls** — `src/pools/PrecisionPoolFactory.sol:403-409`

The empty-pool decision precedes token transfers in _fund.

```solidity
if (isPool[existing] && PrecisionPool(payable(existing)).totalSupply() == 0) { ... } ... (lp, used0, used1) = _fund(...);
```

**Factory calls token code before entering the pool** — `src/pools/PrecisionPoolFactory.sol:467-476`

A token callback runs while only the factory is locked; the pool guard has not been acquired.

```solidity
_pullExact(token0, msg.sender, pool, amount0); ... _pullExact(token1, msg.sender, pool, amount1); return PrecisionPool(payable(pool)).addLiquidityFromFactory(...);
```

**Pool ignores sqrtPriceInit once supply exists** — `src/pools/PrecisionPool.sol:1222-1237`

Callback initialization switches the later factory call to a branch that does not enforce the victim's nonzero opening price.

```solidity
uint256 supply = totalSupply(); if (supply == 0) { ... _seed(..., sqrtPriceInit); ... } else { (lp, used0, used1) = _proportional(...); }
```

#### Validation

A callback during either factory token pull can call the pool directly because the pool lock is idle. For an unnamed market, the direct call may seed one-sided at a boundary. The outer exact-delta check observes only the token currently being transferred and does not prevent the opposite-token seed. The subsequent factory pool call sees nonzero supply and silently deposits proportionally.

Validation method: Independent static source-to-sink validation

- **Status:** validated

Assertions:
- Factory seed/createAndSeed observe totalSupply before _fund.
- _fund invokes token contracts before pool.addLiquidityFromFactory.
- Unnamed pools allow direct initialization.
- Boundary initialization can declare zero of the token whose outer transfer is being measured.
- The nonzero factory sqrtPriceInit is ignored when the callback has made supply nonzero.

Counterevidence and remaining uncertainty:
- Named markets require factory initialization and are not exposed.
- Exact token deltas constrain, but do not eliminate, the one-sided callback construction.
- MIN_RESOLUTION forces the attacker to provide real seed capital.
- A sufficiently restrictive minLP can cause an atomic revert.

Limitations:
- The pinned compiler was unavailable offline, so an executable regression was not run during this scan.

#### Dataflow

Victim initialization parameters reach the factory; an asset callback crosses into the unlocked pool and initializes it first; the factory later forwards the victim's declared amounts; the pool switches from seed to proportional mode and drops the requested price.

- **Source:** PrecisionPoolFactory.seed/createAndSeed

- **Sink:** PrecisionPool._proportional followed by reserve and LP updates

- **Outcome:** Victim receives LP exposure at the attacker-selected boundary, after which the malicious asset can be traded against the paired reserve.

Transformations:
- empty-pool check
- external token transfer
- callback boundary seed
- factory forwarded-liquidity call
- silent proportional branch

**Factory checks supply before external token calls** — `src/pools/PrecisionPoolFactory.sol:403-409`

The empty-pool decision precedes token transfers in _fund.

```solidity
if (isPool[existing] && PrecisionPool(payable(existing)).totalSupply() == 0) { ... } ... (lp, used0, used1) = _fund(...);
```

**Factory calls token code before entering the pool** — `src/pools/PrecisionPoolFactory.sol:467-476`

A token callback runs while only the factory is locked; the pool guard has not been acquired.

```solidity
_pullExact(token0, msg.sender, pool, amount0); ... _pullExact(token1, msg.sender, pool, amount1); return PrecisionPool(payable(pool)).addLiquidityFromFactory(...);
```

**Pool ignores sqrtPriceInit once supply exists** — `src/pools/PrecisionPool.sol:1222-1237`

Callback initialization switches the later factory call to a branch that does not enforce the victim's nonzero opening price.

```solidity
uint256 supply = totalSupply(); if (supply == 0) { ... _seed(..., sqrtPriceInit); ... } else { (lp, used0, used1) = _proportional(...); }
```

#### Reachability

The malicious token deterministically receives execution during the victim's factory funding transfer and can call the public pool initializer before the factory enters the pool.

- **Attacker:** Operator of a callback-capable market token

- **Entry point:** PrecisionPoolFactory.seed or createAndSeed

- **Sink:** PrecisionPool proportional deposit at substituted state

- **Outcome:** Attacker-selected opening state and potential extraction of the victim's paired asset

Preconditions:
- The market is unnamed and empty.
- One asset is attacker-controlled and executes a callback during transferFrom.
- The attacker can supply enough of the opposite asset for a valid one-sided boundary seed.
- The victim's minLP does not reject the substituted proportional position.

Existing controls:
- Factory transient lock
- Pool transient lock
- exact transfer deltas
- named-market feeRecipient gate
- minLP
- minimum seed resolution

#### Severity

**High** — A malicious asset can deterministically trigger the callback when an honest user initializes its unnamed market and can place that user's paired asset into an attacker-priced pool, enabling extraction through subsequent swaps. The path requires an unnamed market, a callback-capable token, attacker seed capital, and a minLP that does not reject the substituted position.

Named markets, including all PrecisionLauncher markets, reject direct non-factory initialization and are not exposed. A pool-side expected-empty assertion before accepting factory-forwarded funds would close the path.

Impact assessment:
- **Level:** high
- **Rationale:** The victim can supply real paired liquidity into an attacker-priced market.

Likelihood assessment:
- **Level:** high
- **Rationale:** Once a victim attempts to initialize the attacker's unnamed token market, the callback is deterministic; deployment adoption is the principal prerequisite.

#### Remediation

Carry the initialization intent into the pool and enforce it after acquiring the pool's own guard. In particular, make addLiquidityFromFactory revert if sqrtPriceInit is nonzero and totalSupply is already nonzero, or redesign the factory-only initialization path so funding happens while the pool guard is held. Add callback-token regressions for both token positions and one-sided boundary seeds.

> #### Maintainer response — accepted, not reachable in this deployment
>
> We reproduced the mechanism from source and agree with all three steps: the
> factory decides emptiness before `_fund`, `_pullExact` verifies only the
> delta of the token it is moving and so cannot observe an opposite-token seed,
> and the later factory call silently takes `_proportional`, dropping
> `sqrtPriceInit`. The write-up is correct.
>
> **Not reachable for launched coins.** Launcher pools are named
> (`feeRecipient: address(this)`), and the pool enforces
> `if (feeRecipient != address(0) && msg.sender != factory) revert NotFactory();`
> (`src/pools/PrecisionPool.sol:1225`). There is nowhere for a callback to seed. This covers every token launched on
> zSwap.
>
> **Not reachable for listed tokens.** The attack needs a callback-capable
> asset. No major on zList registers an ERC-777 implementer, and `LaunchToken`
> has no transfer hook. A user must paste a hostile token address by hand to
> construct the precondition at all.
>
> **Frontend hardening for the residual path.** The dapp does create unnamed
> markets, so `minLP` is the guard, and we have tightened it twice:
> - It now **refuses to submit a zero bound**. Previously `minLP` fell back to
>   `0` when no preview estimate existed. That state was unreachable — the
>   create button is disabled until a preview stores an estimate — but the
>   guarantee depended on control flow rather than on the submitting line, so
>   it is now checked where it is used.
> - The seed bound **no longer inherits the swap slippage setting**, which
>   allowed up to 10%. A seed's LP is a pure function of band, price and
>   amounts — no chain state enters it — so the preview is exact but for
>   integer rounding, and there is no drift to tolerate as there is on a swap.
>   Capped at 0.5%, which an attacker-priced boundary substitution cannot
>   satisfy.
>
> **Residual risk we accept.** A direct caller of `createAndSeed` passing
> `minLP = 0` with a callback-capable token remains exposed. We consider the
> reviewer's remediation correct and will treat it as the fix if this path ever
> becomes reachable through an SDK or third-party integration.

<a id="finding-2"></a>

### [2] previewZap models a different hook caller and reserve transition than zapIn executes

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | Both sender identities and both reserve formulas are explicit in source; the lens itself acknowledges that gross input overstates retained reserves. |
| Category | incorrect-calculation |
| CWE | CWE-682 |
| Affected lines | src/pools/PrecisionLiquidityLens.sol:281-317, src/pools/PrecisionLiquidityLens.sol:323-355, src/pools/PrecisionLiquidityLens.sol:359-376, src/pools/PrecisionRoute.sol:640-703, src/pools/PrecisionPool.sol:672-704 |

#### Summary

The deployed liquidity lens quotes hook-sensitive swaps using the eth_call caller, while zap execution makes PrecisionRoute the pool-visible sender. It also adds the gross swap portion to reserves although the pool removes hook and creator cuts. A malicious hooked pool can advertise a favorable split and then charge the route up to the combined fee ceiling, yielding fewer LP shares than previewed or forcing an unexpected revert.

#### Root Cause

previewZap reimplements rather than reuses the execution transition and does not bind the preview to the sender address observed by hooks during PrecisionRoute execution.

**Lens uses its external caller as hook sender** — `src/pools/PrecisionLiquidityLens.sol:330`

A normal eth_call presents a user or RPC-selected sender, not PrecisionRoute.

```solidity
p.quoteExactIn(msg.sender, zeroForOne ? p.token0() : p.token1(), portion)
```

**Lens treats gross input as retained reserves** — `src/pools/PrecisionLiquidityLens.sol:345-355`

The pool actually retains amountIn minus hookCut and creatorCut.

```solidity
r0 = zeroForOne ? b.r0 + portion : ...; r1 = zeroForOne ? ... : b.r1 + portion;
```

**Route is the actual pool caller** — `src/pools/PrecisionRoute.sol:696-703`

The pool sees PrecisionRoute as sender and samples a sender-sensitive hook against that address.

```solidity
received = p.swapExactIn(...);
```

**Canonical transition removes fee liabilities** — `src/pools/PrecisionPool.sol:679-687`

The post-swap reserve grows by kept, not by the gross portion used by the lens.

```solidity
hookCut = amountIn - ...; uint256 net = amountIn - hookCut; ... creatorCut = ...; kept = net - creatorCut;
```

#### Validation

The preview sender differs from the execution sender, and the preview reserve update differs from PrecisionPool._transitionAt. zapIn executes its swap with minOut zero and depends on minLP as the final user protection.

Validation method: Independent static differential trace

- **Status:** validated

Counterevidence and remaining uncertainty:
- Combined base fee and surcharge are capped at 10%.
- A sufficiently tight minLP reverts the entire transaction.
- PrecisionPoolPolicy denies hooked pools by default but is advisory only.
- PrecisionLauncher always creates unhooked pools.

Limitations:
- Live UI filtering and minLP policy are outside the authorized source.

#### Dataflow

Hook-controlled quote input enters previewZap under the wrong sender, an approximate reserve transition produces split and LP output, and the user submits those values to zapIn where the hook sees PrecisionRoute and the pool retains a different input amount.

- **Source:** Hook feeFor response and previewZap eth_call sender

- **Sink:** PrecisionRoute.zapIn swap and LP mint

- **Outcome:** Fewer LP shares than previewed or an unexpected atomic revert

Transformations:
- sender-sensitive quote
- gross reserve approximation
- binary split search
- minLP submission
- route-context execution

**Lens uses its external caller as hook sender** — `src/pools/PrecisionLiquidityLens.sol:330`

A normal eth_call presents a user or RPC-selected sender, not PrecisionRoute.

```solidity
p.quoteExactIn(msg.sender, zeroForOne ? p.token0() : p.token1(), portion)
```

**Lens treats gross input as retained reserves** — `src/pools/PrecisionLiquidityLens.sol:345-355`

The pool actually retains amountIn minus hookCut and creatorCut.

```solidity
r0 = zeroForOne ? b.r0 + portion : ...; r1 = zeroForOne ? ... : b.r1 + portion;
```

**Route is the actual pool caller** — `src/pools/PrecisionRoute.sol:696-703`

The pool sees PrecisionRoute as sender and samples a sender-sensitive hook against that address.

```solidity
received = p.swapExactIn(...);
```

**Canonical transition removes fee liabilities** — `src/pools/PrecisionPool.sol:679-687`

The post-swap reserve grows by kept, not by the gross portion used by the lens.

```solidity
hookCut = amountIn - ...; uint256 net = amountIn - hookCut; ... creatorCut = ...; kept = net - creatorCut;
```

#### Reachability

Any factory pool may have an immutable hook, and PrecisionRoute.zapIn does not consult the advisory policy or reject hooked pools.

- **Attacker:** Hook operator

- **Entry point:** PrecisionLiquidityLens.previewZap followed by PrecisionRoute.zapIn

- **Sink:** Hook fee accrual and LP mint

- **Outcome:** Bounded value extraction through the unmodeled surcharge or transaction denial

Preconditions:
- A user zaps into a factory-registered hooked pool.
- The user or integrator sizes swapPortion/minLP from previewZap.
- The hook distinguishes the lens caller from PrecisionRoute or fee cuts materially alter the reserve ratio.

Existing controls:
- 10% combined fee cap
- minLP
- advisory PrecisionPoolPolicy
- factory membership

#### Severity

**Medium** — A hooked-pool operator can cause users relying on previewZap to accept a worse zap and collect the unmodeled surcharge. The combined fee is capped at 10%, minLP can force an atomic revert, and PrecisionLauncher pools are unhooked, limiting scope.

Additional runtime or deployment evidence could raise or lower this severity.

Impact assessment:
- **Level:** high
- **Rationale:** The hook can collect a material unpreviewed surcharge from a user's swap leg.

Likelihood assessment:
- **Level:** medium
- **Rationale:** The path requires a hooked pool and an integration that trusts the deployed preview without exact route simulation.

#### Remediation

Reject hooked pools in previewZap/zapIn or quote explicitly for the deployed PrecisionRoute address. Reproduce the pool's hookCut, base fee, creatorCut, and kept arithmetic exactly when deriving post-swap reserves. Add differential tests with a sender-dependent hook and nonzero creatorFeeBps.

> #### Maintainer response — accepted, first remediation adopted at the frontend
>
> Agreed on the mechanism: the lens quotes with the `eth_call` sender and adds
> the gross swap portion to reserves, while execution makes `PrecisionRoute`
> the sender the hook observes and the pool retains only the net. On a hooked
> pool the preview is therefore not the trade.
>
> **Not reachable for launched coins.** `PrecisionLauncher` sets
> `hook: address(0)` (`src/pools/PrecisionLauncher.sol:616`); there is no
> hooked launcher pool to quote.
>
> **The swap path already implemented the reviewer's recommendation.** The
> report advises quoting "explicitly for the deployed PrecisionRoute address".
> zSwap's swap path has always done exactly that: `quotePrecision` is called
> with `PROUTE` as the sender at both of its call sites, and the trade is then
> executed through `PROUTE` via `encSnwap(..., PROUTE, routeData)`. The hook is
> therefore asked the same question by the quote and by the trade, and the
> divergence this finding describes does not arise on a swap. We confirmed the
> page never calls a pool's `swapExactIn`/`swapExactOut` directly — those
> selectors appear nowhere in it — so `PROUTE` is the only swap sender any pool
> sees from this frontend.
>
> The zap was the single place the same discipline had not been applied: it
> quoted as the caller and executed as the route.
>
> **We have adopted the reviewer's first remediation there too.** The
> dapp now **refuses to zap into a hooked pool**, reading `hook()` from the
> pool itself rather than trusting a cached row, and failing closed — a pool
> that will not answer is treated as hooked. The user is told the quote cannot
> be made honestly and is directed to a two-sided add, which does not carry the
> modelled swap leg. Hooked pools were already excluded from the chart's market
> discovery and labelled in the liquidity panel as "may add a surcharge, and
> cannot be used in a clamped route"; the zap path was the remaining gap and is
> now closed.
>
> **Scope of the hook, as we verified it.** `hook != address(0)` appears at
> seven sites in `PrecisionPool`, across six functions: `_tradeable` (416),
> `_transitionAt` (679), `_quote` (845), `_swapExact` (878, 888), `_owed0`
> (1630) and `_owed1` (1635). All are swap-side — the last two account fees
> already accrued on swaps. Proportional adds and removes never reach the hook.
> So the frontend's exposure to this finding is exactly two paths, swap and
> zap, and both are now sound.
>
> **Residual risk we accept.** `previewZap` still models a different transition
> than `zapIn` executes for any caller who uses the lens directly. `minLP`
> continues to bound the outcome to an atomic revert rather than a silent loss.
> We regard the reviewer's second remediation — reproducing the pool's
> `hookCut`/`creatorCut`/`kept` arithmetic in the lens — as the correct fix,
> and have recorded it for the next contract revision.

## Reviewed Surfaces

| Surface | Risk Area | Outcome | Notes |
| --- | --- | --- | --- |
| Factory deployment and pool initialization | Business logic and callback reentrancy | Reported | The factory-to-pool initialization time-of-check/time-of-use gap is reported. CREATE2 salt, constructor encoding, market validation, registry indexing, and named-market creator binding were also reviewed; no pool-address substitution was found. |
| Pool swaps, reserves, liquidity, and fee liabilities | Custody and accounting | No issue found | Exact pulls and settlements, backed-reserve checks, owed-fee exclusion, partial fills, strict and lossy exits, reserve width, band enforcement, rounding, and hostile-token behavior were traced. No independent reserve theft, fee-claim spend, donation credit, or first-exiter advantage was validated. |
| Factory checkpoint and prefunded settlement | Authentication and transient state | No issue found | The single-live-route lifecycle, full Route intent hash, exact fresh balance delta, committed abort/refund destination, native msg.value binding, pool membership, and checkpoint consumption order prevent ordinary callers from redirecting or double-spending routed funds. |
| Multi-hop route and zap custody | Transient custody and reentrancy | No issue found | ERC-20 checkpoints commit exact spending calldata, route state spans the funding interval, native entries cannot run while a route is open, every hop is factory-registered, output token and minOut are checked, and zap sweeps are floored at pre-call balances. No cross-user sweep or stranded-intermediate theft was found. |
| Liquidity preview and zap sizing | Quote-to-execution consistency | Reported | previewZap uses a different hook sender and a different retained-input reserve model from PrecisionRoute.zapIn. previewSeed and previewAdd also omit some pool refusal postconditions, but those omissions were only shown to cause optimistic previews followed by atomic reverts. |
| Launcher and LaunchToken lifecycle | Supply, launch pricing, and redemption | No issue found | Clone initialization and mint are atomic and one-time; launch pools are fresh token-dependent named markets with hook zero; allocation and seed bounds are enforced; launcher-held LP redemption burns both circulating input and returned noncirculating tokens. The factory seed callback finding does not reach named launcher markets. |
| Launcher fees and creator handoff | Authorization and payout liveness | No issue found | Creator fee collection is fixed through the launcher, ETH is split among creator, immutable treasury, and tithe, token fees burn, transfers are forced for payout liveness, and creator reassignment is two-step. No unauthorized fee redirection was found. |
| PriceTape storage and chart integrity | Storage integrity and manipulation | No issue found | Fixed ring indices and typed storage prevent adjacent-state corruption. Trading can cheaply influence OHLC extrema and very small raw prices can chart at zero, but the implementation explicitly disclaims oracle use and no in-scope settlement consumes the tape. |
| Pool and launcher read-only lenses | Off-chain presentation | No issue found | Factory provenance, page bounds, route-quote semantics, launch registry round trips, floor-price delegation, URI omission from pages, and marginal price calculations were reviewed. PrecisionPoolLens.quoteRoute intentionally models multi-leg snwap rather than PrecisionRoute. |
| PrecisionPoolPolicy authority | Advisory curation | No issue found | The policy is an off-chain advisory oracle, not an on-chain route control. This differs from SCOPE.md's brief role description but is explicit in source; consumers must not interpret approval as enforced safety. |
| Trusted executor boundary | External call path | No issue found | Supporting source shows the configured SafeExecutor shape is public and stateless, so the immutable address is a call-path label rather than user authentication. Local checkpoint and intent controls do not rely on executor secrecy. SCOPE.md reports 252 runtime bytes while an in-source comment reports 206; the supplied bytecode verification confirms the immutable address but not executor runtime semantics. |

## Open Questions And Follow Up

- Does the live SSTORE2 poolCode blob hash to the published compiled PrecisionPool creation code and poolInitCodeHash?
  - Follow-up prompt: Read poolCode and poolInitCodeHash from the live factory and compare the blob against the compiled creation code.
- Why does SCOPE.md report a 252-byte trustedExecutor runtime while PrecisionPoolFactory source commentary reports 206 bytes?
  - Follow-up prompt: Retrieve and disassemble runtime at 0x25fc36455aa30d012bbfb86f283975440d7ee8db, then compare it with the scoped zRouter SafeExecutor source.
- Does the production UI exclude hooked pools from previewZap or simulate zapIn with PrecisionRoute as sender?
  - Follow-up prompt: Review the excluded dapp integration and exact minLP derivation for hooked pools.
