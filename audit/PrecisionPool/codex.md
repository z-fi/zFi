# PrecisionPool Mainnet Security and Production-Readiness Review

**Date:** 2026-07-31  
**Reviewer:** OpenAI Codex  
**Repository base:** `e8dce80` on `precision-pools`, plus the reviewed working-tree changes
**Solidity:** 0.8.36, via IR, optimizer enabled  
**Production compiler unit:** 200 runs for `PrecisionPoolFactory.sol` and its
embedded `PrecisionPool` creation code; 9,999,999 runs by default  
**EVM target:** Prague

## Scope

Primary scope:

- `src/pools/PrecisionPool.sol`
- `src/pools/PrecisionPoolFactory.sol`
- `src/pools/PrecisionPoolLens.sol`
- `src/pools/PrecisionPoolPolicy.sol`

Integration and regression scope:

- `test/PrecisionPool.t.sol`
- `test/PrecisionPoolSnwap.t.sol`
- `test/ConstantSurchargeHook.t.sol`
- Architecture review of `src/pools/PrecisionZap.sol` for LP redemption and
  future cross-range migration
- The deployed mainnet zRouter at
  `0x000000000000FB114709235f1ccBFfb925F600e4`
- The deployed zRouter SafeExecutor at
  `0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db`
- Static inspection of `zSwap.html` for PrecisionPool integration

Source hashes for the reviewed contracts:

| File | SHA-256 |
| --- | --- |
| `PrecisionPool.sol` | `494423f52de6e0f8aa4a70a9d5ae9c04d205dee4c926c687403735be53b88e7e` |
| `PrecisionPoolFactory.sol` | `e82e0eaac58216cecb367dd3bdaa57de345b6e35b64641016459980c25bd315b` |
| `PrecisionPoolLens.sol` | `7bc4ffe56f703a6d24e69b90498f0a23d30ccc7473de688071971725a0877c2f` |
| `PrecisionZap.sol` | `08e750d06860d32d4f26086828ebdaf8cf5acd4d4e782ce545d1205bf8ede52c` |
| `PrecisionPoolPolicy.sol` | `5219610ffc2e40178a0fdd3b223d21eb0080f3e9ff3d39ebdfce1bf50de42888` |

The source was not committed at the time of review. A deployment must be built
from a clean, tagged commit that reproduces these hashes, compiler units, and
artifact sizes. Changing optimizer runs changes the embedded init-code hash
and therefore every deterministic pool address.

## Executive Verdict

**Conditional approval for a curated Ethereum mainnet deployment of the exact
reviewed contract artifacts.** No unresolved Critical, High, or Medium contract
finding remains in scope after the mitigations below.

This is not an unconditional approval of the entire user-facing launch:

1. `zSwap.html` currently contains no PrecisionPool factory, lens, quote, or
   execution integration. Contract-level zRouter composition is verified, but
   the current zSwap dapp does not discover or construct these routes.
2. The deployed zQuoter is also unaware of PrecisionPool. Until it is replaced
   or the dapp explicitly compares PrecisionPoolLens results, PrecisionPool
   cannot participate in automatic multi-venue splitting.
3. Hook review, routing-policy operations, deployment verification,
   monitoring, incident response, and a staged value-at-risk rollout remain
   operational requirements.

Do not advertise PrecisionPool support in zSwap until item 1 is implemented
and exercised with end-to-end transaction-construction tests.

The policy-specific threat model, truth table, governance requirements, and
zRouter enforcement boundary are in `audit/PrecisionPool/PrecisionPoolPolicy.md`.

## Finding Summary

| Severity | Found | Unresolved |
| --- | ---: | ---: |
| Critical | 0 | 0 |
| High | 0 | 0 |
| Medium | 4 | 0 |
| Low | 5 | 0 |
| Informational / optimization | 4 | 0 |

## Remediated Findings

### PP-01: Public SafeExecutor could authenticate old factory dust

**Severity:** Medium  
**Status:** Fixed

zRouter dispatches through a public SafeExecutor. Checking only
`msg.sender == trustedExecutor` did not prove that an ERC-20 input was freshly
funded for the current route. Anyone able to make the public executor call the
factory could otherwise consume a pre-existing factory balance.

The factory now requires a same-transaction ERC-20 balance checkpoint before
settlement. The checkpoint is keyed collision-free by token in transient
storage; both checkpoint and consumption independently authenticate the one
immutable executor. The exact post-checkpoint delta must equal `amountIn`, and
the checkpoint is cleared before the token receives control. Native ETH
remains authenticated by exact `msg.value`.

This use matches EIP-1153's transaction lifetime, shared contract frames, and
revert behavior. Ethereum mainnet has supported EIP-1153 since Dencun:

- https://eips.ethereum.org/EIPS/eip-1153
- https://blog.ethereum.org/2024/02/27/dencun-mainnet-announcement

Regression coverage proves that a public executor cannot spend old dust, while
a checkpointed fresh delta succeeds and leaves the old balance untouched.

### PP-02: Fee retention could move the post-swap price outside the band

**Severity:** Medium  
**Status:** Fixed

Swap output is priced using input after fees, while the reserve retains the LP
fee. Near a range endpoint, checking only `amountOut <= reserveOut` allowed the
retained fee to produce a discrete post-state marginal price below
`sqrtPLow` or above `sqrtPHigh`.

The pool now computes the exact post-fee reserves and rejects any swap whose
derived post-state price is outside the immutable band. The lens mirrors the
same creator cut, reserve-capacity check, post-state price, and zero-output
refusal. Boundary searches in both directions prove that the largest quoted
fill remains in range and executes exactly.

### PP-03: Branded empty pool could bypass creator initialization

**Severity:** Medium  
**Status:** Fixed

The factory required a nonzero `feeRecipient` to create and initialize its own
market. After the creator deployed an empty pool, however, another address
could call `addLiquidityExact` directly on the pool and choose the immutable
initial price without passing the factory check.

A pool with a nonzero `feeRecipient` now permits its first deposit only from
its immutable factory. The factory authenticates the creator before forwarding
initial liquidity. Later liquidity remains permissionless. A regression test
covers both the rejected bypass and the valid creator path.

`createAndSeed` remains the recommended deployment method because it removes
the empty-pool interval entirely.

### PP-04: Price and liquidity domains were not fully bounded

**Severity:** Medium  
**Status:** Fixed

Parameterized ranges can produce very large virtual reserves, especially for
extremely narrow bands. Without explicit limits, a seed could create an
arithmetic domain in which virtual-reserve or price calculations overflow or a
pool is permanently unusable.

The implementation now:

- caps `sqrtPHigh` at `1e36`;
- caps total curve liquidity at `uint128.max`;
- rejects the cap before seed requirement arithmetic continues;
- requires both initial virtual reserves to be nonzero;
- checks reserve and accrued-fee capacity before narrowing to `uint128`; and
- mirrors swap reserve-capacity refusal in the lens.

These constraints leave raw-price coverage far beyond practical mainnet pairs
while making the arithmetic domain explicit and auditable.

### PP-05: Rounded-zero swap accepted input for no output

**Severity:** Low  
**Status:** Fixed

A sufficiently small exact input could round `amountOut` to zero. Accepting it
would retain the input as a donation while the lens represented the trade as
unfillable.

The pool now rejects zero output and the lens returns zero. The test verifies
that neither reserve changes after the rejected dust swap.

### PP-06: One-sided seed rounding could start outside its endpoint

**Severity:** Low  
**Status:** Fixed

At a one-sided bound, rounding seed requirements up while virtual reserves
round down could place the actual discrete marginal price just outside the
requested immutable endpoint.

Seed calculation now refunds only the rounding excess required to keep the
real virtual-reserve ratio inside both bounds. Tests cover both one-sided
endpoints, refund conservation, later one-sided deposits, and 256 fuzzed
initial prices across the full band.

### PP-07: Invalid contract dependencies were accepted

**Severity:** Low  
**Status:** Fixed

EOA token, hook, executor, factory, or lens dependencies create broken or
misleading deployments. Factory and pool constructors now validate required
code, optional hooks are either zero or contracts, and the lens refuses a zero
or code-less factory.

Code existence is not a behavioral allowlist. Proxy and malicious contracts
remain an operational trust decision.

### PP-08: Lens effective fee was ambiguous and slightly overstated

**Severity:** Low  
**Status:** Fixed

The hook surcharge is removed first, then the base fee is charged on the
remainder. Adding the two pip rates double-counted their overlap. A single
headline was also ambiguous because a hook may vary by sender, token
direction, and amount.

The lens now reports the compounded rate, names the bulk field
`effectiveFee0`, and exposes `effectiveFeeFor(pool, sender, tokenIn, amountIn)`
for a concrete trade. This is an intentional pre-launch ABI change.

### PP-09: Obsolete prefund ABI and redundant factory swap surface

**Severity:** Low  
**Status:** Fixed / hardened

Disabled legacy balance-delta entry points still occupied bytecode and ABI
surface, and the factory exposed a redundant direct-swap forwarder even though
the pool already atomically pulls exact input.

The obsolete pool selectors and redundant factory forwarder were removed.
Direct users call `PrecisionPool.swapExactIn`; routed users call the
checkpointed factory settlement through zRouter.

## Additional Hardening and Optimization

- Exact transfer deltas reject fee-on-transfer, sender-tax, recipient-tax, and
  other balance-changing token behavior on funding and payout.
- `_assertBacked` now reads each asset balance once and returns both available
  balances, removing redundant balance calls from swaps and liquidity adds.
- Forced or mistaken balance surplus is never credited as swap input or LP
  principal.
- Hook and creator accruals are excluded from pool reserves and from later
  input recognition.
- Hook fee callbacks and post-swap callbacks are gas-capped, reentrancy-guarded,
  and failure-tolerant.
- Hook documentation now accurately states the hook's bounded economic
  authority instead of describing it as observer-only.
- The factory runtime was reduced to preserve meaningful EIP-170 deployment
  headroom.

## Gas-Optimization Round

The post-audit gas pass retained every exact-delta, backing, price-boundary,
and authorization check. The principal changes were:

- replace the swap's floored square-root boundary calculation with the exactly
  equivalent squared-ratio check;
- use bounded native multiplication for virtual reserves after proving the
  `uint128` liquidity and `1e36` price domain;
- skip hook and creator accounting reads and writes when their immutable
  configuration makes them impossible;
- reuse the pool's already-read output balance in exact payout verification;
- encode both hook callbacks directly into scratch memory while preserving
  every argument, gas cap, return-size check, and failure behavior;
- encode a checkpoint as `balance + 1` in one transient slot;
- reuse the consumed checkpoint balance in the factory's exact transfer check;
- remove redundant pool token getter calls from authenticated factory
  settlement; and
- build pool init code once, then reuse it for prediction and manual `CREATE2`,
  while bubbling constructor errors and preserving `Exists()` on collisions.

Measured hot-path gas:

| Operation | Audit baseline, 9,999,999 runs | Final, 9,999,999 runs | Checked-in factory unit, 200 runs |
| --- | ---: | ---: | ---: |
| ETH -> ERC-20 direct swap | 57,140 | 51,039 | 51,482 |
| ERC-20 -> ETH direct swap | 65,087 | 59,644 | 60,099 |
| Remove liquidity | 71,627 | 66,185 | 66,518 |
| Live zRouter ETH -> USDC | 133,097 | not remeasured | 126,259 |
| Live checkpointed USDC -> ETH | 139,680 | not remeasured | 131,919 |

The checked-in 200-run factory unit deploys for 3,992,557 gas in the benchmark
harness and `createAndSeed` costs 2,745,215 gas. The same final source at
9,999,999 runs saves another 443-455 gas per direct swap, but deploying each
larger pool costs about 636,836 more gas. Excluding the one-time factory cost,
the high-run pool crosses over at approximately 1,420 swaps per pool. The
high-run factory now fits EIP-170, so the 200-run setting is an economic choice,
not a deployability requirement.

For a few deep, long-lived mainnet pools, expected lifetime flow will likely
exceed that crossover. The release owner must choose the optimizer policy
before publishing predicted addresses, build every artifact with that policy,
and record it in the deployment manifest. Do not mix a high-run standalone
pool artifact with the 200-run creation code embedded in the checked-in factory.

## Accounting Model

PrecisionPool should use **pull accounting for ordinary user input**:

- `swapExactIn` pulls the exact declared ERC-20 amount in the same call;
- `addLiquidityExact` pulls exact declared liquidity in the same call; and
- native input is bound to exact `msg.value`.

This prevents a transfer-first balance from becoming a claimable public good.
The only retained push path is the factory's zRouter adapter, where a trusted
executor takes a same-transaction transient checkpoint and settlement consumes
exactly the fresh balance delta. Outputs, withdrawals, and refunds are pushed
to an explicit caller-selected recipient after state is updated and while the
reentrancy lock remains held.

Do not restore a generic `transfer(pool); pool.swap(...)` entry point. If a new
router cannot use pull accounting, it needs the same atomic checkpoint and
single-use authentication properties as the factory path.

## Cross-Range Liquidity Migration

The pool and factory should remain unchanged for migration. Both
`addLiquidityExact` and `factory.seed` already mint LP shares to an arbitrary
`to` address, so the requested mint-to-another-address convenience exists.
Adding migration code to every pool would also enlarge the factory because it
embeds `PrecisionPool.creationCode`, and would add cross-pool calls to the
irreducible custody core.

The recommended implementation is an extension of the singleton,
replaceable `PrecisionZap`:

1. authenticate both source and target with `factory.isPool`;
2. require distinct pools, identical `token0`/`token1`, and a seeded target;
3. exact-pull source LP from a direct caller, or consume the existing
   same-transaction zRouter checkpoint;
4. redeem the source shares to the zap with `min0` and `min1`;
5. exact-approve only the redeemed ERC-20 amounts to the target;
6. call `target.addLiquidityExact(..., minLP, lpTo)`; and
7. forward only `redeemed - used` refunds to `refundTo`, never pre-existing
   zap dust.

Use a shared transient reentrancy guard, restrict ETH reception to the
currently expected registered source or target, and clear approvals after any
nonstandard token path. A migration is a proportional redeposit, not a
rebalance: different ranges normally require different asset ratios, so one
side may be refunded, and a one-sided source cannot fund an interior target.
A full rebalance remains an atomic zRouter sequence of exit, swap, and add.

No migration selector was added during this round. The current zap supports
checkpointed exit; the design above is the reviewed boundary for a separately
tested migration enhancement.

## Security Invariants

The reviewed implementation enforces the following core properties:

1. **Custody backing:** for each token,
   `balance >= reserve + hookOwed + creatorOwed` before stateful operations.
2. **Authenticated input:** direct calls pull an exact amount atomically;
   factory ERC-20 routes consume an exact fresh checkpoint delta; native routes
   require exact `msg.value`.
3. **No surplus capture:** unaccounted donations do not move the curve or mint
   LP shares.
4. **Bounded curve state:** total liquidity and real reserves fit `uint128`,
   virtual reserves are nonzero at inception, and the post-state price remains
   inside the immutable band.
5. **Fee conservation:** input is split among reserve growth, hook accrual, and
   creator accrual without double counting. The creator share comes from the
   base fee and does not change the taker's quoted curve input.
6. **Exact quote parity:** for supported tokens and unchanged state, a nonzero
   `quoteFor` result matches pool execution to the wei.
7. **Reentrancy containment:** pool swap, liquidity, refund, payout, and fee
   collection paths share a transient lock.
8. **Creator initialization:** a branded market can be created and initially
   priced only through its named creator's factory path.

## zRouter and zSwap Integration

### Verified onchain path

The pinned mainnet-fork suite executed against the live zRouter and
SafeExecutor. Six swap-path tests passed for:

- ETH to ERC-20;
- ERC-20 to ETH with a transient checkpoint;
- recipient-delta slippage enforcement;
- delivery to a third-party recipient;
- sequential state-dependent legs; and
- factory discovery, lens quoting, then crossing discovered bands.

Three additional tests cover checkpointed LP redemption through
`PrecisionZap`, refusal of uncheckpointed shares, and caller/pool
authentication.

For routed quoting, the pool sees the factory as `msg.sender`, so use:

`lens.quoteFor(pool, address(factory), tokenIn, amountIn)`.

For ERC-20 input, zRouter must execute one atomic multicall containing:

1. a zero-input `snwap` leg that calls `factory.checkpoint(tokenIn)` through
   SafeExecutor; then
2. the funded `snwap` leg targeting the factory with calldata for
   `executePrefundedSwap(pool, tokenIn, amountIn, poolMinOut, recipient)`.

For native input, one funded `snwap` leg is sufficient because exact
`msg.value` authenticates the amount.

The zRouter `recipient` and factory calldata `recipient` must be identical.
Production calldata should set both zRouter's recipient-delta minimum and the
pool's `minOut`; a deadline or equivalent submission expiry belongs in the
calling wallet/application layer.

### Hooked-pool routing policy

`PrecisionPoolPolicy` keeps factory deployment permissionless while giving
zSwap one exact per-pool decision:

- unknown addresses are denied;
- unhooked factory pools are allowed by default;
- hooked pools require explicit `Approved`; and
- `Blocked` denies either kind and erases prior approval.

The registry uses Solady `Ownable`, requires an explicit nonzero initial owner,
and disables renunciation. The owner should be a threshold Safe. zSwap must
fail closed on `isRoutable` before quoting and immediately before submission.
The policy is advisory unless `requireRoutable` is included atomically.

ERC-20 zRouter routes can prepend a zero-input `snwap` policy preflight before
the existing checkpoint and settlement legs. Native zRouter multicalls cannot
use that shape because delegatecalled `snwap` entries each see and forward the
full `msg.value`; strict native enforcement needs a policy-aware gateway or a
separately reviewed factory integration.

### Unimplemented dapp path

`zSwap.html` has no PrecisionPool reference, ABI, configured factory/lens
or policy address, discovery call, quote comparison, checkpoint construction,
or settlement encoding. The live contract path is compatible, but the current
dapp cannot use it.

Before calling zSwap integration production-ready:

1. deploy and verify the factory, replaceable lens, and routing policy;
2. add their chain-specific addresses and ABIs to zSwap;
3. enumerate bounded factory pages and filter every pool through
   `policy.isRoutable`;
4. compare `quoteFor(..., address(factory), ...)` with existing venue quotes;
5. construct the exact checkpointed ERC-20 multicall described above;
6. use the same recipient and nonzero slippage floors at both layers; and
7. add browser and fork tests from displayed quote through signed calldata and
   final recipient balance.

## Token and Hook Assumptions

Only standard, non-rebasing ERC-20 pools should be exposed by the production
dapp. There is no token-wide allowlist: unsafe or misconfigured markets are
blocked at the exact pool address. Factory permissionlessness is not token
endorsement.

Unsupported or unsafe token characteristics include:

- fee-on-transfer, sender-tax, or recipient-tax behavior;
- negative or positive rebasing;
- dishonest or stateful `balanceOf`;
- transfer side effects that change balances by a different amount;
- upgradeable token behavior that can later violate these assumptions; and
- tokens whose transfer or balance calls can be administratively blocked.

The exact-delta checks reject many such behaviors, but a dishonest token can
lie consistently. Curate by verified address and behavior, not by
`code.length`.

PrecisionPool LP shares inherit Solady ERC20's default fixed infinite allowance
to the canonical Permit2 contract. Permit2 must still authenticate transfers
under its own signature or allowance rules, but this makes canonical Permit2 an
explicit dependency of the LP token. An integration must not call `approve` or
ERC-2612 `permit` for a finite allowance to Permit2 because Solady deliberately
reverts those operations. Use Permit2's own authorization flow. If this trust
model is not desired, override `_givePermit2InfiniteAllowance()` to return
`false` before deployment and repeat this review and its integration tests.

A nonzero hook is trusted economic policy:

- it can vary the surcharge by sender, direction, size, and current state;
- it can charge up to the pool-wide 10% total-fee ceiling;
- failure means zero surcharge, so it cannot implement mandatory access
  control;
- `afterSwap` is advisory and may fail;
- a mutable proxy hook can change economics after LPs deposit; and
- a lost or unusable hook can strand its accrued share, although that share is
  excluded from LP reserves.

Use `hook = address(0)` for the lowest-risk base pool. Separately audit and
operationally monitor every approved hook implementation and upgrade authority.

## Residual Risks

- **No pause or upgrade:** the contracts are immutable. This removes admin
  seizure and upgrade risk, but incident response is dapp/router delisting and
  LP withdrawal, not an onchain pause.
- **Market configuration:** raw decimal-adjusted price bounds cannot be
  validated onchain. A units or token-order mistake creates a valid but
  economically wrong market. Peer-review every market tuple before funding.
- **Permissionless fragmentation:** anyone may create arbitrary bands. The
  dapp must apply `PrecisionPoolPolicy`; hooked pools are denied by default and
  a problematic unhooked pool must be explicitly blocked.
- **MEV and AMM economics:** sandwiching, arbitrage, loss-versus-rebalancing,
  inventory concentration, and adverse selection are inherent and not removed
  by these fixes.
- **Spot-price manipulation:** `sqrtPriceCurrent` is a pool spot price, not a
  manipulation-resistant oracle. Do not use it as collateral valuation.
- **Surplus is unrecoverable:** deliberate safety against prefund theft means
  forced or mistaken donations are not claimable.
- **Payable deployment constructor:** the pool constructor is payable to avoid
  a generated value guard, but the factory always deploys it with zero value.
  A direct deployment that includes ETH permanently leaves that ETH as
  unaccounted surplus. Deployment tooling must send zero value.
- **Liveness depends on token behavior:** a negative rebase or blocked transfer
  can make swaps and withdrawals revert.
- **Factory size:** every pool's creation code is embedded in the factory.
  Future edits must preserve the checked EIP-170 margin under every supported
  optimizer policy or split deployment into a separately reviewed deployer.

## Build, Size, and Test Results

Targeted build:

`forge build --offline src/pools/PrecisionPool.sol src/pools/PrecisionPoolFactory.sol src/pools/PrecisionPoolLens.sol src/pools/PrecisionPoolPolicy.sol`

Result: success under Solidity 0.8.36. Compiler warnings were from upstream
Solady memory-safe annotation deprecations. Forge lint reported no high- or
medium-severity issue. Its narrowing-cast warnings are guarded by explicit
upper-bound checks immediately before each cast.

Checked-in production artifact sizes:

| Contract/compiler unit | Runtime bytes | EIP-170 margin | Artifact initcode bytes |
| --- | ---: | ---: | ---: |
| PrecisionPool deployed by the 200-run factory | 11,578 | 12,998 | 12,490 |
| PrecisionPool standalone default artifact | 14,715 | 9,861 | 15,627 |
| PrecisionPoolFactory, 200 runs | 18,312 | 6,264 | 18,494 |
| PrecisionPoolLens in the factory compiler unit | 9,227 | 15,349 | 9,461 |
| PrecisionZap in the factory compiler unit | 1,390 | 23,186 | 1,617 |
| PrecisionPoolPolicy, default runs | 2,790 | 21,786 | 3,047 |

The pool artifact initcode excludes its 288 bytes of ABI-encoded constructor
arguments. The factory's actual pool initcode is therefore 12,778 bytes.
Policy artifact initcode excludes its 64 bytes of constructor arguments.

For comparison, compiling the final pool and factory together at 9,999,999
runs produces:

| Contract | Runtime bytes | EIP-170 margin | Artifact initcode bytes |
| --- | ---: | ---: | ---: |
| PrecisionPool | 14,715 | 9,861 | 15,627 |
| PrecisionPoolFactory | 23,406 | 1,170 | 23,588 |

EIP-170 limits runtime code to 24,576 bytes:
https://eips.ethereum.org/EIPS/eip-170

Test results:

| Suite | Result |
| --- | --- |
| `test/PrecisionPool.t.sol` | 75 passed, 0 failed |
| `test/PrecisionPoolPolicy.t.sol` | 15 passed, 0 failed |
| Price and seed fuzzing | 512 combined runs passed |
| `test/ConstantSurchargeHook.t.sol` | 9 passed, 0 failed |
| `test/PrecisionPoolSnwap.t.sol` on pinned mainnet fork | 9 passed, 0 failed |
| `forge fmt --check` on target contracts and zRouter integration test | passed |
| `git diff --check` | passed |

The mainnet tests used archive block `25,640,000`. They cover live zRouter
swaps, checkpoint settlement, discovery, multi-leg state updates, third-party
recipients, and checkpointed LP exit through `PrecisionZap`. Prague bytecode
is compatible with Ethereum mainnet following Pectra:
https://blog.ethereum.org/2025/04/23/pectra-mainnet

Slither, Aderyn, and Solhint were not installed in this environment. This
review used manual line-by-line analysis, Foundry lint, deterministic tests,
fuzzing, adversarial mocks, exact artifact inspection, and a live-contract
mainnet fork.

Foundry 1.5.1's broad `--gas-report` instrumentation reproducibly makes one
transient checkpoint regression report `BadCheckpoint`. The same test passes
under normal execution, focused traces, snapshots, and the live-fork suite.
Gas figures above came from focused gas reports that do not trigger that
instrumentation defect.

## Mainnet Release Checklist

- [ ] Commit and tag the exact reviewed source; reproduce all SHA-256
      hashes and artifact sizes above from a clean checkout.
- [ ] Choose 200-run deployment optimization or 9,999,999-run lifetime
      optimization before publishing addresses; record the exact compiler unit,
      via-IR, and Prague settings in the deployment manifest.
- [ ] Deploy the factory with the exact live SafeExecutor as
      `trustedExecutor`, not the zRouter address itself.
- [ ] Deploy `PrecisionPoolPolicy` for that exact factory with a threshold Safe
      as `initialOwner`; verify an emergency `Blocked` update before launch.
- [ ] Send zero ETH while deploying the payable pool constructor directly;
      normal factory deployment already does this.
- [ ] Verify zRouter and SafeExecutor code hashes immediately before deployment.
- [ ] Verify factory, lens, and every created pool source on a public explorer.
- [ ] Use `createAndSeed` for all launch markets.
- [ ] Independently review token order, decimals, raw sqrt bounds, fee, creator
      share, hook, and recipient for every launch tuple.
- [ ] Review every hooked pool before approval and publish the policy address;
      filter every discovered pool through it in zSwap.
- [ ] Accept and document the canonical Permit2 dependency for LP shares, or
      disable Solady's automatic Permit2 allowance before the release review.
- [ ] Complete and test the zSwap integration described above.
- [ ] Set nonzero pool and router slippage bounds and a transaction expiry.
- [ ] Stage the launch with conservative liquidity and volume caps.
- [ ] Monitor `HookCallFailed`, reserve backing, quote/fill parity, price
      endpoints, fee accrual, and failed checkpoint settlements.
- [ ] Document delisting and LP communication procedures because no pause or
      upgrade key exists.
- [ ] Obtain an independent second review before materially increasing value at
      risk.

## Final Assessment

The reviewed pool, factory, and lens are suitable for a carefully curated,
staged Ethereum mainnet deployment after the release checklist is satisfied.
The accounting, boundary, authorization, prefund, fee, reentrancy, and quote
paths are materially hardened and covered by adversarial and live-router
tests. `PrecisionPoolPolicy` is suitable as the minimal Solady-owned zSwap
routing registry under its separate security reference.

The current repository is **not yet ready to claim end-to-end zSwap support**
because the dapp and aggregate quoter do not contain PrecisionPool integration.
That is a launch integration blocker, not an unresolved flaw in the reviewed
contract settlement path.
