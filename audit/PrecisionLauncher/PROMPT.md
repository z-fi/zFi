# PrecisionLauncher — security review brief

Hand this to a reviewer verbatim. It states what the code claims, what is
already proven, and where the author believes the remaining risk is. It is
deliberately adversarial about its own subject: the fastest way to waste a
review is to have it rediscover what the test suite already asserts.

**Base:** `precision-audit-fixes` @ `df135af` plus uncommitted working tree
**Solidity:** 0.8.36, via IR, optimizer on, EVM target Prague
**Production compiler unit:** 200 runs for `PrecisionLauncher.sol` and
`PrecisionLauncherLens.sol` (pinned in `foundry.toml`; the pin is load-bearing —
see "Build" below)

**REVISION 2.** The first review (`REVIEW.md`) was performed against
`1af8a64b…4066406` / `43f41eb0…dfaa1524`. Acting on its findings changed both
files, so those hashes no longer resolve and the review below them describes
code that no longer exists. A delta review should cover exactly:

- `_tithe` now caps its outward call at `TITHE_GAS` (L-1). **This is a fix for a
  fix** — the previous wedge was itself the mitigation for an earlier one — and
  is the change most deserving of a second look.
- `setCreator` is now a two-step offer/`acceptCreator` handoff (L-2). New state
  (`pendingCreatorOf`), new external function.
- `MIN_POOLED` added; `launch` rejects an under-floor pooled remainder (I-1).
- `allocBpsOf` stored, added to `Launched`, surfaced with `fullyDilutedWei` on
  `LaunchInfo` (I-2).
- `collectFees` returns four values, not three; `Launched` carries `allocBps`.

New coverage since: `test/PrecisionLauncherReviewFixes.t.sol` (11 tests over
exactly the above), `test/PrecisionLauncherGuards.t.sol` (10),
`test/PrecisionLauncherInvariant.t.sol` (9 invariants, 128k calls each),
`test/PrecisionLauncherTithe.t.sol` (7, forked, incl. the gas-burner
regression), `test/PrecisionLauncherLiveFactory.t.sol` (6, forked). 87 tests
total, all passing.

| File | SHA-256 |
| --- | --- |
| `src/pools/PrecisionLauncher.sol` | `664a2d65ec475bb65ab63a0a71d119a310194d1f3b34ba49855f7c25161fa749` |
| `src/pools/PrecisionLauncherLens.sol` | `42b7164225338025887da28678d33fd93530fb2b803ba4bccadcc432298ab6f6` |

---

## 1. What this is

A one-transaction token launcher on top of the already-deployed Precision pool
suite. `launch()` mints a fixed-supply ERC-20, pays the creator an optional
allocation (capped at 20%), and seeds **the entire remainder one-sided** into a
fresh ETH/token `PrecisionPool` — no ETH required. The launcher keeps the LP
position **permanently** and has no path to spend it.

Holders exit through `redeem()`, which burns tokens for a pro-rata share of the
ETH inside that locked position. That is the "floor". A 1% swap fee splits: half
stays in the pool (accruing to the floor), half is swept by `collectFees()` and
divided 80% creator / 10% treasury / 10% burned to Ethereum via the canonical
BETH burner, with the token side of the fee burned entirely.

**The threat model is unusual and should shape the review.** There is no owner,
no pause, no upgrade, and no admin key. Every launch's liquidity is locked in
this contract forever. A bug is therefore *unrecoverable for every token ever
launched*, not just the next one. Assume no operator can intervene.

## 2. Scope

Primary:

- `src/pools/PrecisionLauncher.sol` — contains both `LaunchToken` and
  `PrecisionLauncher`
- `src/pools/PrecisionLauncherLens.sol` — read-only, `eth_call` only

Integration scope (deployed, already audited, **not** in scope to re-review, but
in scope for how the launcher uses them):

- `PrecisionPoolFactory` @ `0x000000Eb27B557aB426d9E99cFd54EC455799e81`
- `PrecisionPool` (CREATE2 per market from the factory's SSTORE2 blob)
- BETH burner @ `0x2cb662Ec360C34a45d7cA0126BCd53C9a1fd48F9`
- Prior review: `audit/PrecisionPool/*.md`

Existing tests (read these before hunting — they define what is already covered):

| File | Tests | Covers |
| --- | --- | --- |
| `test/PrecisionLauncher.t.sol` | 23 | floor mechanics; 2 fuzzed invariants @256 runs |
| `test/PrecisionLauncherLifecycle.t.sol` | 12 | template conformance (fuzzed), launch validation, cradle-to-grave |
| `test/PrecisionLauncherLens.t.sol` | 13 | lens agreement with settlement |
| `test/LauncherBrick.t.sol` | 6 | hostile/gas-hungry fee recipients, stream reassignment |
| `test/PrecisionLauncherTithe.t.sol` | 6 | forked; real BETH burner, seized-burner fallback |
| `test/PrecisionLauncherLiveFactory.t.sol` | 6 | forked against the LIVE factory |

## 3. The claims to attack

Each is asserted in tests. The review's value is in finding the case the tests
do not generate, so treat these as hypotheses, not as given.

**C1 — Redemption is floor-neutral.** With `ethClaim = lpHeld·r0/lpTotal`,
`tokClaim = lpHeld·r1/lpTotal`, `C = totalSupply − tokClaim`, `F = ethClaim/C`,
burning `b` tokens burns `lpHeld·b/C` LP shares and retires both the caller's
tokens and those released from the position. Claim: `C' = C − b` and `F' = F`
exactly, so no holder is harmed by another's exit and there is no race to the
door.

**C2 — Buy-and-redeem is not profitable *from trading alone*.** The floor is the
average price paid by circulating supply; the market quotes the marginal price.
Fuzzed over supply `1e3..1e12` tokens, valuation `0.01..500 ETH`, allocation
`0..20%`, and trade ordering.

**The qualifier is not decoration.** The unconditional claim is FALSE and was
falsified by `test/PrecisionLauncherInvariant.t.sol` in three calls on its first
run — `buy`, `burnVoluntarily(99%)`, `sell`. Burning collapses `circulating`
without touching the pool, so the floor jumps while the market does not, and a
sell then crashes the market underneath it; a round trip profits in that state.
It is *not* an attack — the profit is the burner's forfeited backing, an
attacker running the sequence spent 240 ETH to recover 0.39, and an uninvolved
holder's redeemable value rose from 99.5 to 332 ETH. Pinned in
`testExternalBurnLiftsFloorOverMarket`.

**Reviewers: this is the shape of finding we want more of.** The stateless fuzz
tests missed it because none of them burn. Ask what else gifts supply or value
into the system without moving the pool — `LaunchToken.burn` is permissionless,
`collectFees` burns the fee's token side on every sweep, and tokens can be sent
to unspendable addresses. Confirm none of those can be made to harm a holder
rather than benefit one.

**C3 — Outside LPs are floor-neutral.** A proportional deposit scales `r0` and
`lpTotal` together, leaving `lpHeld·r0/lpTotal` fixed. Third-party liquidity is
therefore permitted rather than blocked.

**C4 — Rounding always favours the position.** `tokClaim` floors → `C` rounds up
→ `lpBurn` floors. A stream of dust redemptions must not ratchet the floor down.

**C5 — The template is inescapable.** Every launched market has `token0 == ETH`,
`fee == 1%`, `creatorFeeBps == 5000`, `hook == 0`,
`feeRecipient == launcher`, `sqrtPLow == sqrtPHigh/1e6`. These are the CREATE2
preimage, so they are the address, not merely current values.

**C6 — `collectFees` cannot be wedged.** It is the only way to clear
`creatorOwed`, and the pool pays both sides or neither, so a recipient that
reverts would freeze the fee stream *and* the token burn. Forced transfers and a
tithe fallback are the mitigations. **This was a real bug found late in
development** — see §5.

**C7 — Nothing can withdraw the locked LP.** No owner, no transfer, no approval,
no path.

**NOT a claim, and please do not report it as a finding:** the floor is *not*
monotonic. A sell above it lowers it — measured at 57% in a lifecycle selloff.
This is inherent to pro-rata backing and is documented in the contract header
and asserted in `testSellingAboveTheFloorDilutesIt`. What *is* claimed is that
each move scales with `p − F`, so the floor converges onto the market from below
and never crosses it.

## 4. Where the author thinks the risk is

Ranked by the author's own uncertainty. Reviewers should not feel bound by this
ordering, but these are the places least covered by tests.

1. **Band excursion under extreme redemption.** `PrecisionPool._removeLiquidity`
   is *deliberately* not guarded by the range postcondition that guards
   deposits — an exit that can revert on price was judged worse than the state
   it would prevent. Both virtual reserves are floored functions of LP supply,
   so a large redemption near the dead-share minimum can in principle leave the
   pool outside its own band. Redemption is proportional and therefore
   price-neutral in the normal case (tested), but the pathological tail is not.
   **Can a sequence of redemptions brick a pool, or strand the remaining
   backing?**
2. **`circulating` as an accounting fiction.** `C = totalSupply − tokClaim`
   treats every token not inside the launcher's own LP as redeemable. Tokens in
   a *third-party* pool, in another launcher-created market, or sent to an
   unspendable address are all counted. Is there a state where `C` understates
   real claims — which would let the last redeemers drain more than their share?
3. **Multiple markets on one launched token.** Anyone may open further Precision
   markets on a launched token; `poolOf[token]` names only the launch market.
   Arbitrage links prices, and the floor math treats the other pool's tokens as
   circulating (believed correct). **Confirm.** Also confirm that a second
   market cannot be made to look like a launch to the lens.
4. **Seed dust and the `_seed` bound corrections.** `launch` burns whatever the
   seed refunds. Measured worst case is ~1e-6 of one token, but the amount is a
   function of the factory's clamp arithmetic rather than anything the launcher
   controls. Is there a parameter choice where the refund is material, or where
   `used1` lands somewhere that breaks the initial floor?
5. **`sqrtPHigh` derivation.** `1e18·sqrt(pooled·1e36/startMcapWei)` with
   `sqrtPLow = sqrtPHigh/1e6`. Verified to 0.01% across three orders of
   magnitude of both inputs. Look for overflow, precision collapse at the
   extremes of the admitted range, and whether `MIN_START_MCAP = 1e12` is
   actually sufficient to keep the pool's `MIN_RESOLUTION` satisfied for every
   admissible supply.
6. **Reentrancy across the launcher/pool/token boundary.** `LaunchToken` is a
   plain Solady ERC-20 with no callbacks, and the launcher is `nonReentrant`,
   but `redeem` calls out to `to` and `collectFees` force-sends to three
   addresses. Confirm no ordering issue, particularly around the forced
   transfers, which execute arbitrary receiver code by design.
7. **The tithe.** `_tithe` low-level-calls `depositTo(address)` on a hardcoded
   mainnet address and force-sends on failure. Confirm the fallback cannot be
   used to grief, and that the hardcoding is acceptable (this contract is
   explicitly not portable off mainnet).

## 5. Known history — two defects found during development

Stated so the review can judge the code's maturity honestly rather than
inferring it.

- **`collectFees` could be permanently wedged.** It push-paid with
  `safeTransferETH` to a hardcoded creator address. A creator that reverts on
  receipt froze the fee stream *and* the token burn forever. Fixed with
  `forceSafeTransferETH` plus `setCreator`. Regression: `test/LauncherBrick.t.sol`.
  Note the irony worth generalising from: `PrecisionPool` had avoided this
  exact failure by taking the payee as an argument, and the launcher
  reintroduced it because it *must* be the pool's `feeRecipient` and so cannot
  offer that lever.
- **The floor's downward mobility was mischaracterised** in comments and in the
  test assertions as "slight". It is not. Corrected in the header and pinned by
  a test.

Both were found by re-reading, not by the test suite. Weight accordingly.

## 6. Build and reproduction

```
forge build --force --sizes
forge test --match-path 'test/PrecisionLauncher*.t.sol'
forge test --match-path 'test/LauncherBrick.t.sol'
```

Three things that will waste your time if not known up front:

- **This repo forks mainnet by default.** `eth_rpc_url` + `fork_block_number` in
  `[profile.default]`. Freshly created contracts therefore inherit real dust at
  forge's deterministic CREATE addresses — the launcher lands on
  `0x2e234DAe…`, which holds 1 wei on mainnet. Balance assertions must be
  deltas, not absolutes.
- **Public RPCs rate-limit.** A 429 surfaces as a test FAILURE with a plausible
  EVM error. Re-run before believing any fork failure. See the `eth_rpc_url`
  note in `foundry.toml`.
- **`test/PrecisionLauncherLiveFactory.t.sol` self-pins to block 25,745,000**,
  because the live factory did not exist at the repo's default pin of
  25,640,000. At the default pin the address is codeless and every test there
  fails for an unrelated reason.

The 200-run pins matter: `PrecisionLauncher` embeds `LaunchToken`'s creation
code, so a differently-optimized `LaunchToken` moves the launcher's initcode and
therefore any mined CREATE2 address.

## 7. Deliverable

Findings by severity, each with a concrete failure scenario — inputs and state
in, wrong output or stuck funds out. Given §1, please classify anything that
permanently locks liquidity or freezes the fee stream as **critical regardless
of the difficulty of reaching it**, since no operator can intervene.

Also wanted, separately from findings:

- Whether the 20% allocation cap is the right bound, given that the allocation
  dilutes every buyer's floor one-for-one.
- Whether the immutable, unconfigurable tithe is defensible, or whether it
  should be a constructor parameter.
- Anything in §3 that is asserted in the tests but is not actually true in
  general — a test that passes for the wrong reason is worse than a missing one.
