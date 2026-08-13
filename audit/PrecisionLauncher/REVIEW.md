# PrecisionLauncher — security review

**Reviewed:** `src/pools/PrecisionLauncher.sol`, `src/pools/PrecisionLauncherLens.sol`
**Base:** `precision-audit-fixes` @ `df135af` + working tree
**Hashes verified against the brief:**

| File | SHA-256 | Match |
| --- | --- | --- |
| `PrecisionLauncher.sol` | `1af8a64b…4066406` | ✓ |
| `PrecisionLauncherLens.sol` | `43f41eb0…7343dfaa1524` | ✓ |

Method: source review of the launcher and the lens, plus the parts of
`PrecisionPool` and `PrecisionPoolFactory` the launcher depends on
(`_seed`, `_addLiquidity`, `_removeLiquidity`, `removeLiquidityLossy`,
`_accrueFees`, `collectCreatorFees`, `_assertBacked`, `_settle`,
`_check`/`_checkCreator`/`_marketSalt`/`_index`). Existing tests were read.
See "Reproduction" at the end for what was and was not executed.

**No critical or high finding.** The floor algebra in C1/C3/C4 was re-derived
independently, including with third-party LPs present, and holds exactly.
The findings below are low and informational.

---

## Findings

### L-1 — `_tithe`'s fallback is not gas-isolated, so a gas-consuming burner wedges `collectFees` permanently

`src/pools/PrecisionLauncher.sol:440`

```solidity
(bool ok,) = BETH_BURNER.call{value: amount}(abi.encodeWithSelector(0xb760faf9, TITHE_RECORD));
if (!ok) BETH_BURNER.forceSafeTransferETH(amount);
```

The `depositTo` call forwards **all** remaining gas. The fallback is written for
a burner that *reverts*, and `testASeizedBurnerCannotWedgeTheSweep` etches
exactly that: `60006000fd`, five bytes that revert immediately and leave the gas
untouched. It does not cover a burner that *consumes* gas.

Failure scenario: `BETH_BURNER`'s code at `0x2cb662Ec…` becomes something that
spins to out-of-gas — a `SELFDESTRUCT`-and-redeploy at the same address, a
proxy repointed, or a state-dependent loop. `call` returns `ok == false` with
1/64 of the original gas left. `forceSafeTransferETH` then has to `CREATE` a
self-destructing contract (~32k gas) and cannot; `collectFees` reverts out of
gas at any gas limit, because raising the limit raises the callee's consumption
proportionally. `collectFees` is the only way to clear `creatorOwed0/1`, and the
pool pays both sides or neither, so this freezes the fee stream *and* the token
burn for **every token this launcher has ever launched**, permanently. That is
the §5 defect class exactly, one layer down.

This is rated low only because `BETH_BURNER` is a known immutable mainnet
contract, so the trigger is not reachable today. Given §1 ("assume no operator
can intervene") it is worth closing anyway, at a cost of one word:

```solidity
(bool ok,) = BETH_BURNER.call{value: amount, gas: 100_000}(...);
```

A stipend also makes the fallback's promise true rather than
conditional-on-the-callee, which is the same argument that justified
`forceSafeTransferETH` two lines earlier. Add a regression with a
gas-burning etch (`5b600056`, `JUMPDEST PUSH1 0 JUMP`) alongside the reverting
one.

### L-2 — `setCreator` is a one-step, irreversible handoff of a permanent income stream

`src/pools/PrecisionLauncher.sol:455`

Every other unrecoverable action in this system is either impossible or
defended. This one is a single `external` call with no confirmation from the
destination, transferring an income stream that has no expiry and no owner
above it. A fat-fingered `newCreator` — a typo, an exchange deposit address, a
contract that cannot call `setCreator` — permanently redirects all future fees
for that token, and nothing in the design can reverse it. The token's own
`Ownable` is Solady's, which *does* offer a two-step handover; the more
consequential of the two roles has the weaker mechanism.

Suggest a two-step `setCreator`/`acceptCreator`, or at minimum documenting the
asymmetry.

### I-1 — `MIN_START_MCAP` guards the wrong side of the resolution constraint

`src/pools/PrecisionLauncher.sol:200`, answering §4.5 directly.

The comment states that `MIN_START_MCAP` keeps the pool's `MIN_RESOLUTION`
satisfied. It only satisfies *one* of the two checks. Working the seed through
for the launcher's own template (`s == sh`, `sl == sh/1e6`):

```
sh  = 1e18·sqrt(pooled/mcap)
lp  = pooled·1e18/(sh − sl)
v0  = lp·1e18/sh ≈ mcap            ← guarded by MIN_START_MCAP = 1e12
v1  = lp·sl/1e18 ≈ pooled/BAND     ← NOT guarded by anything in the launcher
```

`_seed` requires `v0 >= 1e6 && v1 >= 1e6` (`PrecisionPool.sol:1427`). So the
binding constraint is **`pooled >= 1e12` raw units**, a property of *supply*,
and the launcher has no floor on supply at all — only `pooled != 0`.

Failure scenario: `launch("A","A","", 5e11, 0, 1e12, owner)` passes every
launcher check and reverts inside `_seed` with `InsufficientLiquidity()`. Not a
fund risk — the launch simply fails — but it is the exact legibility gap the
`sqrtPHigh > MAX_SQRT_PRICE || sqrtPLow == 0` check at line 281 exists to
close, and it is the one the comment claims is already closed. Add
`if (pooled < 1e12) revert Bad();` and correct the comment, which currently
tells a reader the wrong thing about which parameter is load-bearing.

### I-2 — the creator allocation is not observable on-chain after the launch transaction

`allocBps` appears in no event and no view. `Launched` carries
`supply` and `startMcapWei` but not the allocation; `LaunchInfo` carries
fifteen fields and not this one. It is recoverable only by replaying the launch
trace or diffing the creator's balance at the launch block.

The header calls the allocation "THE ONE DILUTION" and the single reason
`MAX_ALLOC_BPS` exists — it is the only lever a creator has over every buyer's
floor. A contract that is otherwise this deliberate about being self-describing
should not require an archive node to answer "how much did the creator take."
Recommend adding `allocBps` (or `alloc`) to `Launched`, and a
`fullyDilutedMcap`/`allocBps` field to `LaunchInfo` — note that `startMcapWei`
values the *pooled* supply, so a reader who assumes it is FDV understates
dilution by exactly the allocation.

### I-5 — C2 and "the floor never crosses the market" are false in the unconditional form the brief states them in

`src/pools/PrecisionLauncher.sol:104-128` (header points 1 and 2), and §3 C2 /
the "NOT a claim" paragraph.

Burning supply *outside* redemption collapses `circulating` without touching the
position, so `F = E/C` jumps while the pool's marginal price does not move at
all. The two prices are decoupled by that operation, and afterwards
`floor > market` — at which point buy-and-redeem is *profitable*, which is the
exact negation of C2 and of the header's point 1.

Concretely: buy, burn 99% of a holder's balance, sell the rest.

Two things make this a documentation finding rather than a vulnerability, and
both should be stated rather than left implied:

- **No holder is harmed, and the reason is C1, not C2.** The arbitrageur's
  redemption is floor-neutral by the derivation above, and their buy raises the
  floor. The profit they collect is precisely the backing the burner forfeited.
  So the safety property the product actually needs survives; only the ordering
  claim fails.
- **The mechanism is not confined to self-harming voluntary burns.**
  `collectFees` burns the entire token side of every sweep
  (`PrecisionLauncher.sol:394`), and `launch` burns the seed refund
  (`:311`) — both are burns outside redemption, both permissionless, both
  push the floor up against a stationary market. Their magnitude is
  negligible (the fee burn is 0.5% of sell volume in tokens against the whole
  circulating supply, versus the 99% the invariant runner needed), so they
  cannot cross the market on their own. But the header presents the burn-side
  of the fee as an unambiguous good, and it is the same lever, just small. The
  distance `p − F` is what the whole "attractor, not a ratchet" argument rests
  on, and nothing bounds it from the *floor* side.

Recommend rewriting header point 1 to the conditional form — round trips are
lossy for any sequence of buys, sells, redemptions, sweeps and outside
liquidity, and can profit only after supply is burned outside redemption, where
the profit is the burner's own forfeited backing — and adding the same
qualifier to §3 C2.

Credit where due: this was found by the stateful invariant runner in
`test/PrecisionLauncherInvariant.t.sol`, on its first run, in three calls
(`buy` → `burnVoluntarily` → `sell`), and is already pinned in
`test/PrecisionLauncherGuards.t.sol:testExternalBurnLiftsFloorOverMarket`. Both
files postdate the brief and are not in its coverage table. **This is the direct
answer to §7's "anything asserted in the tests but not actually true in
general"** — the stateless fuzzers appeared to establish C2 unconditionally and
missed it because none of them burns.

### I-3 — `redeem` reads pool state before pulling tokens, which is safe only because `LaunchToken` has no transfer hooks

`src/pools/PrecisionLauncher.sol:339-353`

`lpHeld`, `lpTotal`, `reserve1`, and `totalSupply` are all read before
`token.safeTransferFrom(msg.sender, ...)`. Correct today: `LaunchToken` is a
plain Solady ERC-20 the launcher itself deploys, so no code runs during the
pull. Worth a one-line comment, because it is the kind of ordering that survives
review by accident and would be silently wrong if `LaunchToken` ever gained a
hook (e.g. an ERC-1363 or ERC-777-style variant).

### I-4 — creator payments to addresses that cannot spend ETH are silently stranded

If `setCreator` points at an address with no way to move ETH — including the
launcher itself, whose `receive()` rejects everything but a pool —
`forceSafeTransferETH` still lands the payment, by `SELFDESTRUCT` if needed.
The stream keeps working (correct, and the point of forcing), but the ETH is
gone. This is the creator's own decision and their own loss; noted so it is a
known consequence rather than a surprise. No change recommended.

---

## §3 — the claims, checked

| | Verdict |
| --- | --- |
| **C1** redemption is floor-neutral | **Confirmed**, and more strongly than stated — see below |
| **C2** buy-and-redeem never profitable | **False as stated** — see I-5. True for trading sequences, false once supply is burned outside redemption |
| **C3** outside LPs are floor-neutral | **Confirmed**, derived |
| **C4** rounding favours the position | **Confirmed**, every rounding direction traced |
| **C5** the template is inescapable | **Confirmed** |
| **C6** `collectFees` cannot be wedged | **Confirmed except L-1** |
| **C7** nothing can withdraw the LP | **Confirmed** |

**C1/C3 derivation.** With the launcher holding `h` of `T` total LP shares,
reserves `r0, r1`, supply `S`, `E = h·r0/T`, `tok = h·r1/T`, `C = S − tok`, and
a redemption of `b` burning `λ = h·b/C` shares (write `x = b/C`, `k = h/T`):

```
h' = h(1−x)            T' = T(1−kx)          r0' = r0(1−kx)     r1' = r1(1−kx)
E' = h(1−x)·r0(1−kx) / T(1−kx) = E(1−x)
tok' = tok(1−x)
S'  = S − b − tok·x
C'  = S' − tok' = S − b − tok·x − tok + tok·x = C − b      ✓
F'  = E(1−x)/(C−b) = E/C = F                               ✓
```

The `(1−kx)` factors cancel identically, which is why third-party liquidity
(`k < 1`) is neutral rather than merely approximately so. C3 needs no separate
argument; it is the same cancellation.

**C5.** `_marketSalt(m) = keccak256(abi.encode(m))` over the full `Market`
tuple, and `_poolAddress` is CREATE2 over that salt — so every field named in
C5 is in the preimage, as claimed. The one that is not obviously enforced is
`feeRecipient == launcher`: it holds because `_checkCreator`
(`PrecisionPoolFactory.sol:809`) rejects any creation or first seed of a named
market from anyone other than the recipient itself. `creatorFeeBps = 5000` is
exactly `MAX_CREATOR_SHARE`, which `_check` admits (`>` reverts, not `>=`) —
correct, but it is sitting on the boundary of a constant in a contract the
launcher does not control.

**C7.** The launcher's only call into the pool that moves LP is
`p.removeLiquidity` inside `redeem`, whose size is `h·amount/C` with `amount`
pulled from and burned on behalf of the caller. There is no LP `approve`, no
`transfer`, no `removeLiquidityLossy` path, no owner, no delegatecall, and no
fallback. Confirmed.

**A stronger statement than the brief makes, worth pinning as a test.** The
launcher can never burn its entire position, and the bound is tight:

```
amount ≤ balanceOf(caller) ≤ S − balanceOf(pool) ≤ S − r1
C = S − h·r1/T > S − r1        (strict, since h < T: MIN_LIQUIDITY is
                                burned to 0xdead and never returns)
⇒ amount < C  ⇒  lpBurn = ⌊h·amount/C⌋ < h
```

So `_burn(launcher, lpBurn)` can never revert for insufficient balance, and
redemption alone can never drive the pool's supply toward `MIN_LIQUIDITY` — it
approaches geometrically and never arrives. This is the cleanest answer to §4.1
and it currently rests on no assertion.

---

## §4 — where the author thought the risk was

**1. Band excursion under extreme redemption.** No brick found. Two independent
reasons: removal is exactly proportional so `_priceInRange`'s ratio is preserved
up to the floors on `_virtual0/_virtual1`, whose relative error is bounded by
`1/MIN_RESOLUTION = 1e-6` against a band `1e12` wide; and by the bound above,
the position is never fully burned, so the regime `_removeLiquidity`'s comment
warns about (a pool holding less than one input unit is worth) is not reachable
*through redemption*. It remains reachable by an outside LP exiting a pool that
buying has already drained — but that is `PrecisionPool` behaviour, in scope for
the prior review, and it strands nothing the launcher accounts for. Not fuzzed
to exhaustion here.

**2. `circulating` as an accounting fiction.** `C` cannot understate real
claims. `C = S − tokClaim`, `tokClaim` is *exactly* the launcher's pro-rata
claim on `reserve1`, and every remaining token is by definition held by an
address that can present it. Three separate things push `C` **up**, all of which
understate the floor and are therefore safe:

- the `MIN_LIQUIDITY` dead shares' token claim (noted in the code);
- accrued `creatorOwed1`, which sits in the pool's *balance* but not in
  `reserve1`, so it counts as circulating until `collectFees` burns it — at
  which point `S` falls and the floor steps up, which is the documented buyback;
- tokens abandoned in the pool by an outside LP calling
  `removeLiquidityLossy(..., take1: false)`: `reserve1` falls by the full
  pro-rata claim while the tokens stay, so they are counted as circulating and
  are unreachable forever.

Confirmed correct, in the conservative direction.

**3. Multiple markets on one launched token.** Confirmed. Tokens in a
third-party market are held by that pool on behalf of LPs who can withdraw and
redeem them, so counting them as circulating is right. `poolOf[token]` is
written once at launch and never rewritten, so naming only the launch market is
consistent. A second market cannot masquerade as a launch by either route: it
cannot set `feeRecipient = launcher` (`_checkCreator`), so it never enters
`_byCreator[launcher]` and `launches()` cannot surface it; and `infoForPool`
round-trips through `launcher.poolOf(token) != pool`, so even a pool that
somehow reached the index would describe as an empty struct.

**4. Seed dust.** Bounded and immaterial. With `s == sh`,
`used1 = ⌈lp·(sh−sl)/1e18⌉` against `lp = ⌊pooled·1e18/(sh−sl)⌋`, so the refund
is under `(sh−sl)/1e18 + 1 ≈ sh/1e18` raw units — at the admitted extreme
(`sh = 1e36`) that is one whole token, and in any realistic launch it is
`sqrt(pooled/mcap)`, i.e. tens of thousands of raw units. It cannot break the
initial floor for a reason the brief does not use: `reserve0 == 0` at that
moment, so the floor is zero regardless of `used1`, and the burn only ever helps
later. The `maxY` correction can shave `used1` without recomputing `lp`, which
mints the launcher marginally more LP per token than the formula implies —
harmless, since it is the only LP and the shares are unspendable.

**5. `sqrtPHigh` derivation.** No overflow in range: `fullMulDiv` carries the
512-bit numerator, `sqrt` is exact-floor, and the `> MAX_SQRT_PRICE` /
`sqrtPLow == 0` pair bounds both ends. `_virtual0/_virtual1` are `unchecked`
but `lp ≤ MAX_LIQUIDITY = 2^128−1` keeps `lp·1e18 ≤ 3.4e56`, far inside
uint256. Precision collapse: see I-1 — the *resolution* question has a different
answer than the brief assumes.

**6. Reentrancy.** Clean. `launch`/`redeem`/`collectFees` share one guard;
`LaunchToken` has no callbacks; the forced transfers in `collectFees` run after
every state write the launcher owns and after the pool has already zeroed
`creatorOwed0/1`, so a receiver reentering finds nothing to double-spend and is
blocked by the guard anyway. `redeem` pays `to` last. `receive()` correctly
gates on `factory.isPool`, and note that a `SELFDESTRUCT` force-send bypasses it
— harmless, because no path in the launcher ever reads
`address(this).balance`. See I-3 for the one ordering that is safe by property
rather than by construction.

**7. The tithe.** Fallback cannot be used to grief a *reverting* burner; see
L-1 for the gas variant. The hardcoding is defensible — see below.

---

## The three separate questions

**Is 20% the right allocation cap?** Yes, but for a weaker reason than the
header gives. The cap is not what protects buyers — `floorPrice` already quotes
the *diluted* floor, so a buyer who reads it sees the truth whatever `allocBps`
was. What the cap actually bounds is how much of the first buyers' ETH is a
transfer to the creator, and 20% is at the upper end of defensible for that: a
creator holding 20% who sells into the pool also triggers the documented
downward floor move, so the two effects compound in the same direction. I would
keep 20% and spend the effort on I-2 instead — an allocation that is *visible*
at 20% is safer than one that is capped at 10% and invisible.

**Is the immutable tithe defensible?** Yes, and I would not make it a
constructor parameter. The argument in the code is correct: a permanent
commitment an operator can repoint is not a permanent commitment, and the whole
value of the paragraph is that reading the source answers the question. Two
observations rather than objections. First, the asymmetry is odd — `treasury`
takes the same 10% and *is* a constructor parameter, so the contract is already
not fully self-describing about where the ETH goes, and the tithe's argument
would justify hardcoding both. Second, `TITHE_RECORD` is an unconstrained EOA-
shaped address; if that key is lost the BETH accrues somewhere unusable. That
costs only the record, not the burn, which is the same trade `_tithe`'s fallback
already accepts — so it is consistent, but it is a second place the record can
be lost and only one of the two is commented.

**Anything asserted in tests that is not true in general?** Two.

The larger one is **I-5**: C2 and "the floor converges onto the market from
below and never crosses it" are false once supply is burned outside redemption.
The stateless fuzz tests appeared to establish C2 unconditionally; they missed
it because none of them burns. The safety property survives — via C1, not via
C2 — but the claim as written does not, and the brief presents it as settled.
Already found and pinned by the two working-tree test files that postdate the
brief.

The smaller one is **L-1**:
`testASeizedBurnerCannotWedgeTheSweep` passes for a narrower reason than its
name claims. It proves the sweep survives a burner that *refuses*; the name and
the surrounding comment claim it survives a burner that has been *seized*,
which is a strictly larger class that includes gas exhaustion, against which
the code is not defended. A reader auditing by test names would conclude the
mitigation is complete. Nothing else in the suite appeared to pass for the
wrong reason, though C2 is the claim whose test coverage I leaned on rather than
re-derived.

---

## Review of the two working-tree suites that postdate the brief

`test/PrecisionLauncherGuards.t.sol` and `test/PrecisionLauncherInvariant.t.sol`
are not in the brief's coverage table. Both are net positives — the Guards
header records the single best finding of the exercise (all eleven `redeem`
call sites passed `minEthOut = 0`, so the launcher's only user-facing
protection had never executed), and the invariant runner found I-5 in three
calls. Reviewed on the same terms as the contract:

### T-1 — three assertions are arithmetically vacuous, one of them in the invariant that was explicitly rewritten to stop being vacuous

`invariant_PositionIsOnlyEverBurned` (`:257`) asserts two things:

```solidity
assertEq(pool.balanceOf(address(uint160(0xF000 + i))), 0, ...);   // addresses nothing ever touches
assertLe(pool.balanceOf(address(launcher)), pool.totalSupply(), ...);  // true of any ERC-20, always
```

`0xF000..0xF002` appear nowhere else in the file — the handler's actors are
`0xA000..0xA002` — so the first is checking that three arbitrary addresses which
no code path can reach hold nothing. The second is an ERC-20 invariant, not a
launcher one: no balance can exceed total supply in any conforming token, so it
holds whatever the launcher does. **The invariant named for C7 does not test
C7.** 128,000 calls prove nothing here.

`invariant_BackingIsCoveredByRealReserves` (`:207`) has the same problem in its
first assertion, which is notable because the docstring above it is an extended
explanation of having just removed exactly this defect ("it passed 128,000 calls
and proved almost nothing, which is worse than having no invariant at all"):

```solidity
backing = reserve0 * lpHeld / lpTotal;
assertLe(backing, pool.reserve0(), ...);     // lpHeld <= lpTotal, so this is x*k <= x
```

The *second* assertion in that function (`reserve0 <= address(pool).balance`) is
real and does anchor to something the launcher does not derive — so the
invariant earns its place, but only on its second line, and the docstring
credits the first.

Meaningful replacements:

- For C7: snapshot `pool.balanceOf(launcher)` between calls and assert it is
  non-increasing, **and** that it decreases only on a call where
  `handler.redeems()` incremented. That is the actual claim — the position moves
  only by being burned through a redemption — and nothing currently tests it.
- For backing: compare against ETH the launcher could actually be made to pay,
  e.g. `quoteRedeem(circulating) <= address(pool).balance`.

`testStrandedTokensDoNotInflateTheFloor` (`:267`) is near-tautological for the
same reason — an inbound transfer to the launcher changes neither `totalSupply`
nor the position, so `floorPrice` is unchanged by construction — but it is a
legitimate regression guard against someone later "fixing" `circulating` to
exclude the launcher's own balance, which is the wrong fix. Keep it; the comment
should say that is what it defends.

### T-2 — the reentrancy guard is not exercised

`testRedeemToAHostileRecipientRevertsWithoutSideEffects` uses a `Rejector` that
reverts on receipt. That tests the *revert* path, not the *reentrancy* path.
§4.6 asks specifically about ordering around callouts, and `redeem`'s `to` is an
arbitrary address called with all gas after every state write. No test has a
`to` that calls back into `redeem`, `collectFees` or `launch`. The guard should
catch it; nothing demonstrates that it does.

Same gap on `collectFees`: `LauncherBrick.t.sol` covers a creator that reverts
and one that burns gas, but not one that reenters.

### T-3 — still uncovered after both new suites

- L-1's gas-burning burner.
- I-1's real boundary: nothing launches near `pooled == 1e12`.
  `testLaunchAcceptsItsOwnBoundaries` tests the launcher's *stated* boundaries,
  which is precisely I-1's point — the binding one is somewhere else and
  untested.
- `redeem` with `to == address(launcher)`, which reverts in `receive()`.
  Harmless, but it is a user-reachable revert with a confusing error.

### What T-1 says about the exercise generally

Both files were written to close a gap found by auditing the suite rather than
the contract, and the same class of defect reappeared inside the fix — a
docstring asserting rigour above a line that has none. That is worth more than
the individual findings: the failure mode here is not missing tests, it is tests
whose names and comments outrun their assertions. `testASeizedBurnerCannotWedge-
TheSweep` (L-1) is the third instance in this codebase. A cheap standing check
is to mutate the contract and confirm the named test actually fails.

## Addendum — fixes applied, and the new scope that arrived with them

The working tree changed during the review. All four of L-1, L-2, I-1 and I-2
are now implemented, and correctly:

| Finding | Fix | Verdict |
| --- | --- | --- |
| L-1 | `TITHE_GAS = 200_000` cap on the `depositTo` call (`:331`, `:624`) | **Closed** — see N-4 for why, and for two residual notes |
| L-2 | `setCreator` → `pendingCreatorOf` → `acceptCreator` (`:648-667`) | **Closed.** Zero permitted only to cancel a pending offer; `delete` before the write, so a stale pending cannot re-accept |
| I-1 | `MIN_POOLED = 1e12` + `if (pooled < MIN_POOLED) revert Bad();` (`:328`, `:420`) | **Closed**, and the value is exactly right: `v1 ≈ pooled/BAND ≥ MIN_RESOLUTION` ⟺ `pooled ≥ 1e12` |
| I-2 | `allocBps` in `Launched`, `allocBpsOf` mapping, `LaunchInfo.allocBps` | **Closed** on all three surfaces |

One consistency note on the I-2 fix: `allocBpsOf` charges a cold `SSTORE`
(~22k) on every launch, and the lens header argues explicitly against exactly
that — "a reverse index inside the launcher … would charge storage on every
launch to serve a question only an off-chain reader ever asks. This costs
nothing at launch time." The `Launched` event alone would have served every
indexer; the mapping exists only so the lens can read it on-chain into
`LaunchInfo`. That is a defensible trade, but it is now the opposite of what the
paragraph above it claims the design does. Either drop the mapping and let the
lens's consumers read the event, or update the header — the same
comment-outruns-code pattern as T-1, N-3.

**Core math is unchanged.** `redeem`, `collectFees` and `quoteRedeem` are
byte-identical to the versions whose hashes matched the brief; only comments
were added. The C1–C7 verification above therefore carries over to the current
file without re-derivation.

Sizes are fine: `LaunchToken` 5,989 B, `PrecisionLauncher` 14,072 B,
`PrecisionLauncherLens` 5,211 B. (`forge build --sizes` does report an EIP-170
failure, but for `zQuoter`, `Moloch`, `ClassicalCurveSale` and `SafeSummoner` —
pre-existing and unrelated.)

**Both file hashes in the brief are now stale**, and more importantly
`LaunchToken`'s creation code is embedded in `PrecisionLauncher`'s initcode, so
per §6 any previously mined CREATE2 salt or address for the launcher is void.
Check `deploy/PrecisionLauncher.md` before deploying.

New, unreviewed scope came with the fixes: `LaunchToken.setImage`, `_mimeOf`,
and a `contractURI()` that assembles a full inline `data:application/json;base64`
document. Reviewed now:

### N-1 — the on-chain image is assembled inside the lens's enumeration loop, so one creator can degrade a shared page

`PrecisionLauncherLens.sol:182` calls `t.contractURI()` from `_describe`, which
`launches()` and `launchesForCreator()` call once per pool in a page.
`contractURI()` now does `Base64.encode(SSTORE2.read(p))` over up to ~24,575
bytes and then base64s the entire assembled JSON — roughly 44 KB of returned
string per token, built in memory.

Failure scenario: a creator calls `setImage` with a full-size image. Every page
of `launches()` containing that token now carries ~44 KB; memory expansion is
quadratic in the total, so a page holding several such tokens runs into millions
of gas of memory cost alone and exceeds a node's `eth_call` cap. The caller
cannot page *past* it — they must shrink `count` and step around it — and the
lens's stated purpose is enumeration.

Read-only and recoverable by pagination, hence low. But it is a shared-resource
griefing vector on the product's main discovery endpoint, introduced by new
code, and the fix is nearly free: return the *stored* `_contractURI` string in
list views and assemble the inline document only in the singular `infoFor` /
`infoForPool` path. That also matches how a UI actually consumes these — a grid
wants names, not 44 KB of base64 per tile.

### N-2 — `image/svg+xml` makes the image field creator-controlled active content

`setImage` admits mime code 2, `image/svg+xml`, and serves it as
`data:image/svg+xml;base64,…` inside the `image` field. SVG is a document
format, not a bitmap: it can carry `<script>`, `<foreignObject>`, and external
references. The contract's escaping is correct and not the issue — `_mimeOf` is
a fixed set and `LibString.escapeJSON` covers name, symbol and description, so
there is no JSON injection. The exposure is entirely in the consumer.

This repo ships its own front end (`zSwap.html`, `dapp/preview/`), so it is the
consumer. Any renderer that drops this into an `<img>` is fine; anything that
inlines it into the DOM, or opens it same-origin, executes creator-supplied
script with the page's origin. This is the failure that has repeatedly bitten
NFT marketplaces.

Not a contract change — removing SVG would cost a legitimate and much cheaper
image format. It is a **requirement on every consumer**: render in a sandboxed
`iframe` or a plain `<img>`, never inline, and never same-origin. Worth stating
in the `setImage` docstring, since the contract is where an integrator will look.

### N-3 — `setCreator`'s docstring contradicts itself

`:637-638` still carries the pre-fix sentence "Zero is refused, since that would
burn the stream rather than end it", eleven lines above the new code and comment
saying zero *is* permitted, to cancel a pending handoff. Both readings are in
the same docstring. Delete the older sentence — and note this is the T-1 pattern
again, a comment left standing after the code beneath it changed.

### N-4 — the L-1 fix is sound, but "cannot fail" overstates it and the degradation is silent

**Why the cap works, stated precisely.** The original defect was not that the
callee could consume gas — it is that its consumption *scaled with what it was
given*. Uncapped, EIP-150 hands it 63/64 of everything remaining, so raising the
transaction's gas limit raised the callee's take proportionally and always left
1/64 behind: failure at *every* gas limit, which is what made it permanent.
`gas: TITHE_GAS` pins the take at a constant, so every additional gas the caller
supplies lands in the leftover instead. "Fails at all limits" becomes "succeeds
at any sufficient limit," which is the property required. The value is coherent
on both sides: it comfortably exceeds `depositTo`'s real cost (~50k on the first
tithe, when `TITHE_RECORD`'s slot is still cold) and it is finite.

**Residual 1 — the threshold is higher than the code suggests.** The docstring
above `collectFees` says the forced transfer "cannot fail." Against a
gas-consuming burner the fallback is not the ~41k of a bare `CREATE`:
`forceSafeTransferETH` first attempts its *own* `call` with Solady's
`GAS_STIPEND_NO_GRIEF` of 100,000 (`SafeTransferLib.sol:155`) — which the same
hostile burner also consumes — and only then pays `CREATE` (32,000 + 4,400 code
deposit + 5,000 `SELFDESTRUCT` ≈ 41k). So the fallback costs ~141k, and `_tithe`
needs roughly **342k remaining at its call site** for the guarantee to hold.
Unremarkable for a real `collectFees`, and a caller who supplies less simply
gets a revert and re-sends — recoverable, not a wedge. But the guarantee is
conditional on gas, and the comment states it unconditionally.

**Residual 2 — the sacrifice is unobservable.** The cap trades the liveness risk
for a small correctness risk in the other direction: if `depositTo` ever costs
more than `TITHE_GAS` — a gas repricing, a proxy that grew — the tithe silently
degrades to a force-send and the BETH record is lost permanently, with no
signal. `FeesCollected` emits `titheEth` but not which path ran, so no indexer
can detect that the record stopped minting. The forked tithe tests assert the
mint, but only against the pinned block; they cannot catch a future repricing.

Return the `ok` flag from `_tithe` and add a `bool recorded` to
`FeesCollected`. A few bytes, and it makes the one thing this design is willing
to sacrifice visible when it is actually sacrificed.

## Reproduction

The two file hashes were verified against the brief before review began.

**One blocker worth knowing:** the working tree contains an unrelated
pre-existing compile error in `test/zSwap.t.sol` (`address[15]` vs `address[9]`
at `test/zSwap.t.sol:48`, and a missing `DATA10` at `:83`). `forge test` compiles
the whole tree, so **nothing runs at all** until it is fixed or skipped:

```
forge test --skip 'test/zSwap*.t.sol' --match-path 'test/PrecisionLauncher*.t.sol' \
           --no-match-path 'test/*LiveFactory*'
```

Result: **69 passed, 1 failed**, 862s. The single failure was
`invariant_FloorNeverExceedsMarginalPrice` reported as a `replay failure` — a
**stale persisted-failure artifact**, not a live break: that invariant has since
been renamed to `invariant_FloorStaysUnderMarketForTradingSequences` and the
`burnVoluntarily` action in the shrunk sequence no longer exists on the handler,
so forge replayed a sequence against a selector that is gone. Re-running that
suite alone confirms it: **8 passed, 0 failed**, 561s, 128,000 calls per
invariant, 0 reverts. The underlying behaviour it originally caught is real and
is I-5 above. Clear `cache/invariant/failures/` before trusting a replay verdict
either way.

So the suite is green: **77 passed, 0 failed** across the seven launcher suites,
once the stale artifact is discounted.

The two working-tree suites that postdate the brief's coverage table —
`test/PrecisionLauncherInvariant.t.sol` (7 invariants, 128k calls each) and
`test/PrecisionLauncherGuards.t.sol` (10 tests) — are a material addition and
close most of what I would otherwise have recommended writing. `LiveFactory` was
excluded (self-pins to a different block).

Still not covered, and worth adding:

- the L-1 regression: a *gas-burning* burner (`5b600056`) alongside the
  reverting one in `testASeizedBurnerCannotWedgeTheSweep`;
- the `lpBurn < lpHeld` bound proved above, as an invariant — it is the
  cleanest available answer to §4.1 and nothing currently asserts it;
- the §4.1 tail directly: redemptions interleaved with outside-LP exits,
  asserting `_tradeable` survives.
