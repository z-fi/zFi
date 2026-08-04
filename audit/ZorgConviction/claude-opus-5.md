# ZorgConviction + TokenList — Deployment Audit

Date: 2026-08-01
Auditor: Claude Opus 5
Base revision: `c32ade4`, with `src/dao/ZorgConviction.sol` and `src/utils/TokenList.sol` uncommitted.

## Status

All findings are resolved, accepted with reasons, or answered by the trust model
the DAO already operates under. `test/ZorgConvictionAudit.t.sol` holds a
regression test per finding: each began as a proof of concept asserting the
defect and now asserts the fix. `test/ZorgConvictionMoloch.t.sol` re-runs the
share-side findings against the REAL `Moloch`/`Shares` pair rather than a mock,
closing the coverage gap this audit opened with. 172 tests pass across the
TokenList, ZorgConviction and Moloch suites.

Deployment artifacts were re-mined on 2026-08-01 (see `deploy/TokenList.md`):
both the registry AND the renderer had drifted from their frozen initcode, and
`test/TokenListMinedDeploy.t.sol` now deploys the exact recorded payload through
the real SafeSummoner on a fork and skips itself if the record ever goes stale
again.

| ID | Resolution |
| --- | --- |
| C-01 | Fixed — `_execute` asserts the share balance cannot fall, whatever the route |
| C-02 | Accepted (exec is a security multisig) + `burnExecRole` added so the DAO can retire it |
| H-01 | Fixed — only allocation INCREASES are paused; exit is always open |
| H-02 | Fixed — only increases require the listing to be listed |
| H-03 | Fixed — the constructor refuses a share token whose transfers are locked |
| M-01 | Accepted: DAO trust over shares is a stated assumption of the system |
| M-02 | Fixed — exact exponential halving, so accrual depends only on elapsed time |
| M-03 | Fixed — earned conviction and live support are explicit; the lens ranks their sum |
| M-04 | Fixed — the underlying image URI is scheme- and character-checked |
| L-01 | Fixed — `BadInput` for a zero exec holder |
| L-02 | Fixed — `decreaseBond` added |
| L-03 / L-04 | Accepted, documented in the source |
| L-05 / L-06 | Not taken: see "Accepted" below |
| T-02 / T-03 / T-04 | Fixed in `TokenList`; **the mined salt is now stale** |
| — | Harness: the TokenList suites needed a mainnet fork and fs permissions they never had; 15 tests were failing for that reason alone |

### Accepted, with reasons

- **C-02 / M-01.** The exec credential is held by a security multisig and can now
  be burned outright, and users are already trusting the DAO with their zOrg
  shares — it can inflate them through ordinary governance regardless. The
  arbitrary-execution power is therefore a deliberate choice, not an oversight.
  The escrow invariant added for C-01 still applies to both branches, so neither
  the DAO nor the multisig can reduce bonded escrow *through this contract*.
- **L-05.** A transient-storage reentrancy guard is cheaper, but it pins the
  contract to an EVM version, and the guard is not on a hot path. Not worth the
  coupling.
- **L-06.** `receive()` stays. With C-02 accepted and the escrow invariant in
  place, an ETH balance is not an additional exposure.

## Verdict

(Original verdict, before remediation.) **NO-GO for `ZorgConviction`.** Two critical and three high findings, five of them
reproduced as passing proof-of-concept tests in `test/ZorgConvictionAudit.t.sol`.
Four of the five are permanent-loss-of-escrow paths: users hand over a zOrgz NFT
and an explicit amount of Moloch shares, and there are four independent ways for
those assets to become unrecoverable, three of which are reachable by a single
actor other than the depositor.

**`TokenList` is deployable.** It has already been through a full remediation
cycle (`audit/TokenList/gpt5.6-sol-pro.md`) and this pass found no unauthorized
write path, no reentrancy, and no fund risk. Four low/informational items below,
plus one new coupling risk introduced *by* `ZorgConviction`: `delist` is now a
power that can freeze other people's money (H-03).

| ID | Severity | Finding | PoC |
| --- | --- | --- | --- |
| C-01 | Critical | Escrowed shares can be burned through `dao.ragequit`; `_execute`'s asset guard is address-based and misses it | ✅ |
| C-02 | Critical | The exec role is an irrevocable, freely transferable NFT that self-authorizes arbitrary execution | ✅ |
| H-01 | High | An emergency pause traps every allocated bond — `allocate` is the only deallocation path and is `whenNotPaused` | ✅ |
| H-02 | High | Delisting a token permanently traps every bond allocated to it | ✅ |
| H-03 | High | `Shares.setTransfersLocked` bricks `unbond` forever | — |
| M-01 | Medium | Bonding sinks Moloch voting power into the governor, where only the DAO can direct it | — |
| M-02 | Medium | Conviction accrual is path-dependent and pokeable by anyone holding a receipt | ✅ |
| M-03 | Medium | `_score` counts live weight in full, so a bond allocated this block scores as if held | ✅ |
| M-04 | Medium | zOrgz-supplied metadata is interpolated into the receipt's SVG and JSON unsanitised | — |
| L-01 … L-06 | Low | See below | — |
| T-01 … T-04 | Low/Info | `TokenList` | — |

---

# ZorgConviction

## C-01 — Escrowed shares can be burned through the DAO

`_execute` protects user escrow by address:

```solidity
if (target == address(zorgz) || target == shares) revert ProtectedAsset();
```

`Moloch.ragequit` is `public` and burns **the caller's** shares
(`Moloch.sol:738`, `_shares.burnFromMoloch(msg.sender, sharesToBurn)`). The
caller here is the governor. So `execute(dao, 0, ragequit(...))` destroys the
entire escrowed share balance without ever naming `shares` as the target, while
`bondedWeight` accounting is left intact. Every `unbond` afterwards reverts on an
empty balance, and the zOrgz NFTs go with them because `unbond` transfers shares
first.

The treasury assets ragequit pays out land in the governor, where the same
`execute` can forward them anywhere. This is a complete drain of user escrow, not
a griefing case.

Regression: `testEscrowCannotBeBurnedThroughDaoRagequit`, `testExecCannotBurnEscrowThroughDao`.

The existing test `testExecCannotMoveUserEscrowAssets` asserts the guard holds,
but only against the two direct targets; it uses a `MockShares` with no ragequit
and a plain EOA as `dao`, so the integration this contract is built for is not
covered anywhere in the suite.

**Fix.** An address denylist cannot express "do not reduce my escrow". Assert the
invariant instead — snapshot `shares.balanceOf(address(this))` and
`zorgz.ownerOf` for the escrowed set before the call and require them unchanged
after; the balance check is one SLOAD-free external read and catches every
indirect path, present and future. At minimum, also reject `target == dao`.

## C-02 — The exec role is an irrevocable transferable key to arbitrary execution

`emergencyExecute` requires `paused`, and the same role sets `paused` via
`emergencyPause()`. There is no second party in that sequence: whoever holds the
`exec.zorg.wei` name can pause and then make the governor call anything, with any
value, including the C-01 path.

The role is worse than a hot key:

- It is an ordinary transferable ENS-style subdomain. `_hasRole` reads
  `weiNames.ownerOf` live, so selling, lending or losing the name transfers full
  emergency power with it.
- It cannot be revoked. `installExecRoleName` is one-shot (`rolesInstalled`), the
  subdomain already exists so it cannot be re-registered, and nothing in this
  contract can burn or reassign it. The DAO can only `resume`, which the holder
  re-pauses in the next block.
- There is no timelock, no value cap, and no DAO veto window.

**Fix.** Decide what emergency power actually needs to be: if it is "stop the
world", give the role `emergencyPause` only and leave execution with the DAO. If
arbitrary execution is genuinely required, make the role revocable by the DAO
(a settable address, or a `rolesInstalled` reset), and separate the pauser from
the executor so one key cannot do both.

## H-01 — A pause traps every allocated bond

`allocate` is the only way to *reduce* an allocation, and it carries
`whenNotPaused`. `unbond` requires `allocatedByBond == 0`. So while paused, a
holder with any live allocation can neither deallocate nor exit — both the zOrgz
and the shares are frozen until the DAO calls `resume`, which C-02's holder can
undo indefinitely.

The asymmetry runs the wrong way: `bondZorgz` and `increaseBond` are *not*
paused, so during an emergency stop users can still deposit into the system but
cannot leave it.

Regression: `testPauseDoesNotTrapAllocatedBonds`.

**Fix.** Allow allocation *decreases* while paused (`amount < oldAmount` skips
the modifier), or add a `deallocateAll` exit path outside the pause. Add
`whenNotPaused` to `bondZorgz`/`increaseBond` so a pause stops inflows too.

## H-02 — Delisting a token permanently traps the bonds allocated to it

```solidity
if (!ITokenListView(tokenList).isListed(listingId)) revert UnknownListing();
```

is the first line of `allocate`, which is also the only way to set an allocation
back to zero. Once the TokenList owner delists an id, every receipt holding an
allocation to it is stuck: `allocate(..., 0)` reverts `UnknownListing`, and
`unbond` reverts `BondHasActiveAllocations`. Shares and zOrgz are unrecoverable.

This is not hypothetical governance risk — delisting is routine curation, and it
is exactly what happens to a token that turns out to be a scam, which is also the
token most likely to have accumulated bonded support.

Regression: `testDelistingDoesNotTrapAllocatedBonds`.

**Fix.** Only gate *increases* on `isListed`. Decreasing an allocation, and
zeroing it, must always be possible. `support.weight` bookkeeping for a delisted
id is harmless; the score simply drains.

## H-03 — `setTransfersLocked` bricks `unbond` forever

Moloch shares are lockable (`Moloch.sol:814` → `Shares.setTransfersLocked`), and
the lock permits transfers only when `from == DAO || to == DAO`
(`Moloch.sol:1166`). The governor is neither. So:

- With transfers locked at deploy time, `bondZorgz` reverts and the contract is
  inert — a deployment-configuration trap.
- If the DAO locks transfers *after* bonds exist, `unbond`'s `safeTransfer`
  reverts and every escrowed share and zOrgz is frozen permanently. The DAO can
  unlock, but nothing obliges it to, and C-02's holder does not even need it.

Given that Moloch DAOs commonly ship with transfers locked, this needs to be
settled before deployment, not discovered after.

**Fix.** Read `shares.transfersLocked()` in the constructor and revert if set;
document that locking transfers is a rug of this contract's users; or, better,
have the DAO grant the governor a permanent exemption in the Shares contract.
Note that no test exercises the real `Shares` token — `MockShares` has no lock.

## M-01 — Bonding hands Moloch voting power to the DAO executive

`Shares._moveTokens` repoints votes on transfer and `_autoSelfDelegate`s the
recipient, so bonded shares' Moloch voting power accrues to the governor
contract. The governor never delegates it back, and the only way it can be
exercised is `execute`, which is `onlyDAO`. Two consequences:

1. A user who bonds to express *conviction about a token listing* silently
   transfers their *DAO governance vote* to the DAO's own executive, which can
   vote the pooled stake via `execute(dao, vote(...))`. That is a governance
   capture proportional to TVL in this contract.
2. If the DAO chooses not to vote it, the shares still count toward
   `getPastTotalSupply` quorum basis (`Moloch.sol:284`), so a large bonded pool
   can push quorum out of reach.

**Fix.** Delegate the governor's balance back to each bond's receipt holder if
Shares supports it, or at minimum delegate to `address(0)`/a burn address and
document that bonded shares are non-voting. Explicitly forbid `target == dao` in
`_execute` (which C-01 also requires).

## M-02 — Conviction is path-dependent and free to poke

`_advance` is not a semigroup: applying it over `2e` differs from applying it
twice over `e`. Frequent accrual moves conviction toward its target *faster* in
both directions (with `elapsed == halfLife`, one step gives 50 % of the gap,
fourteen steps give ~64 %).

`allocate` accrues the target listing and has no "value actually changed" check,
so any holder of any receipt — one wei of bond is enough — can call
`allocate(myReceipt, anyListing, 0)` once a block to pump a listing's score, or
to accelerate a rival's decay after its weight drops.

Regression: `testConvictionIsNotInflatableByPokingAccrual` — two listings, identical weight
and identical elapsed time, different scores.

**Fix.** Use a genuinely time-homogeneous decay (fixed-point `k^elapsed`, e.g.
`LibWadMath`/`expWad`), so the result depends only on total elapsed time. As a
cheap partial mitigation, skip the state write when `amount == oldAmount`.

## M-03 — `_score` counts live weight in full

```solidity
score = _advance(...);
return score + support.weight;
```

A bond allocated in this very block scores its full weight with zero holding
time, and an infinitely-held bond of the same weight scores `2 × weight`. So the
entire time dimension the design exists for is worth a factor of two, and
`2 × capital` buys past it instantly. PoC:
`testFreshAllocationScoresNothing` — `convictionOf == 0` at t+0, half the weight after one half-life.

If this is intentional ("score = accrued + current"), it should be named and
documented as such, because `convictionOf` will be read as time-weighted support
by anything consuming it.

## M-04 — zOrgz metadata is interpolated unsanitised into the receipt

`_underlyingImage` extracts `"image":"…"` from the zOrgz tokenURI and
`_invertedImage` splices it into `<image href='…'>` — a single-quoted SVG
attribute — and then into the receipt's JSON. Nothing rejects `'`, `<`, `&` or
`"`. A zOrgz whose image field contains a quote injects markup into every
renderer of the bonded receipt, and a backslash breaks the JSON document.

`zorgz` is immutable and presumably first-party, which is what keeps this out of
the high band, but it is the same class of defect `TokenList._uri` exists to
prevent. Reuse that check: require the extracted value to start with `data:`,
`https://` or `ipfs://` and contain no `'"<>&\` — otherwise fall back to
`_fallbackImage`.

## Low

- **L-01** `installExecRoleName(address(0))` reverts with
  `ExecRoleAlreadyInstalled`, which is not the reason.
- **L-02** No partial withdrawal. `increaseBond` exists with no counterpart, so
  the only way to recover any shares is to zero every allocation and exit
  entirely — one transaction per listing, with no batch helper.
- **L-03** `setHalfLife` retroactively re-prices all un-accrued elapsed time for
  every listing, because nothing is accrued at the point of change and
  `_advance` reads the new value. Sweeping every listing is not possible, so this
  is inherent; document it, and prefer changing it right after a broad accrual.
- **L-04** `_listingSupport` survives delisting, so a delisted-then-relisted id
  (a TokenList id is the token address, so it *is* reusable) resumes with its old
  conviction and weight.
- **L-05** `nonReentrant` uses a plain `bool`; transient storage (`tstore`) is
  available under 0.8.36 + Cancun and is materially cheaper on every guarded
  call.
- **L-06** `receive()` is open and `execute`/`emergencyExecute` forward `value`
  with no cap. Nothing here holds ETH by design, so this is only an amplifier for
  C-02, but a governor that cannot receive ETH cannot have its ETH stolen.

---

# TokenList

The remediated contract holds up. Curation is `onlyOwner` throughout, local
`name`/`symbol`/`decimals` genuinely cannot be authored by the owner, `_pull`
correctly treats an empty read as "no answer", the pre-narrowing decimals range
check is right, `_clean`/`_uri` close the injection surface the renderer depends
on, `delist`'s swap-pop is correct including the last-element case, and
`rankedIds`' key packing sorts on both keys as documented. No new medium or above.

- **T-01 (new coupling, see H-02).** `delist` now has a financial consequence
  outside this contract: it permanently freezes bonded assets in
  `ZorgConviction`. The fix belongs in `ZorgConviction`, but the TokenList owner
  should know that delisting is no longer a purely editorial act.
- **T-02** `setExtra` emits `ExtraSet` but not `MetadataUpdate`. Every other
  mutation goes through `_touch`; if extras ever become renderer-visible, this
  omission means clients never refresh. Route it through `_touch` now.
- **T-03** `listForeign` does not enforce the documented `chainId == 0` for
  non-EVM namespaces, so the same Solana mint can be listed twice under two ids.
  One line: `if (kind != Kind.EVM && chainId != 0) revert BadInput();`
- **T-04** `_uri` validates the scheme but not the MIME, so a `data:text/html`
  logo is accepted and lands in `<image href>` and in the `image` JSON field.
  Owner-authored and mostly inert in marketplaces, but constraining `data:` to
  `data:image/` costs one `startsWith`.

---

# Coverage gaps

The `ZorgConviction` suite passes (10/10) but tests only against `MockShares`,
which has no transfer lock, no ragequit, no voting checkpoints and no
`onSharesChanged` callback — i.e. none of the Moloch behaviour that produces
C-01, H-03 and M-01. Before redeploying, wire the tests to the real
`Moloch`/`Shares` pair and to the real `TokenList`, not to mocks.

`test/ZorgConvictionAudit.t.sol` now contains nine regression tests covering
every fixed finding.

The harness gap is closed: `TokenList.t.sol`, `TokenListPreview.t.sol` and
`TokenListDeploy.t.sol` fork mainnet in `setUp` (the seeded set only exists at
chain id 1, and every seed is skipped where the address has no code), and
`foundry.toml` grants the `deploy/` read and `dapp/` write permissions those
suites need. That alone took the TokenList suites from 34/49 to 49/49 without a
single source change.

Still uncovered, and worth doing before mainnet: run the ZorgConviction suite
against the real `Moloch`/`Shares` pair rather than `MockShares`. The mock has no
transfer lock, no ragequit, no vote checkpoints and no `onSharesChanged`
callback — i.e. none of the behaviour behind C-01, H-03 and M-01.

---

## Addendum — 2026-08-02

Second pass, covering the ETH-bond / lock-tier / eternalize surface that did not
exist when the table above was written, plus the dashboard renderer.

### Fixed

| ID | Finding | Resolution |
| --- | --- | --- |
| H-04 | **Loyalty distribution could be sandwiched risk-free.** `decreaseBond` gated only on the lock tier, never on the ETH maturity that `topUpZorg` resets. A tier-0 receipt could front-run any pending early `unbond` with a large `topUpZorg`, take almost the whole loyalty half of that exit tax, then withdraw the top-up in the very next call — for the cost of gas. Measured: attacker 0.0099 ETH vs 0.000099 ETH for a holder bonded from the start (99%). | `decreaseBond` now honours `ethBonds[].maturityAt` as well as `receiptLocks[].unlockAt`. No new state: `_increaseBond` already renewed that clock for exactly this reason. `test/ZorgLoyaltySandwich.t.sol` |
| B-01 | **`ZorgConviction` exceeded EIP-170 by 13,595 B — undeployable.** | Receipt metadata and artwork moved to `ZorgReceiptArt`, reached through `IZorgReceiptArt` and DAO-replaceable via `setReceiptArt`. Plus a 200-run compilation restriction. 38,171 B → **20,324 B**. |
| B-02 | `ZorgConvictionRenderer` hit EIP-170 while the dashboard was being built out. | Stylesheet moved to `ZorgPageStyle`, read at call time (`html` is `view`, not `pure`). |
| R-01 | Dashboard `rpc()` treated empty returndata as data. An `eth_call` to a codeless address succeeds with `0x`, so a wrong or undeployed `tokenList` — immutable, therefore permanent — surfaced as `Cannot convert 0x to a BigInt` from inside a decoder, naming nothing. | `rpc` rejects `0x` and names the address. |
| R-02 | Allocation truncated to 4 decimals on display and was read straight back by `set`, silently rewriting e.g. `340.123456789` to `340.1234`. | Field renders full 18-decimal precision. |
| R-03 | `<img>` emitted with an empty `src` for the receipt tile and for any listing without a logo — a broken-image icon as the first thing a visitor saw. `list()` and `setLogoSVG()` are separate calls, so that is the ordinary state of a freshly listed token. | Background image for the tile; explicit empty-tile fallback for listings. |
| R-04 | `.off{display:none}` lost the cascade to `.me{display:flex}` (equal specificity, declared later), so the bonded-receipt strip rendered for every visitor as a stray empty avatar. | `display:none!important` — ordering alone would regress on the next appended rule. |
| R-05 | Copy buttons failed silently: `navigator.clipboard` rejects in an insecure context and is blocked by permissions policy in an iframe, and the promise had no `catch`. | Selection-copy fallback inside the open dialog (a modal makes the rest of the document inert), and the outcome is always reported. |
| R-06 | The record labelled the collection flag `onchainSvg` as "Onchain SVG", which reads as a claim about the logo. Every ERC-20 is false by definition, so wstETH appeared to deny art it has. | Reports the logo's own storage; per-token art shown only where it exists. |
| R-07 | Lock tier was typed as a bare number with neither duration nor boost shown — a blind commitment of up to a year. | The menu is read from `lockTiers`, so it tracks `setLockTier` instead of drifting. |

### Test defects found and fixed

Three tests asserted incorrect expectations rather than contract faults:
`vm.prank` consumed by an `ETERNAL_MIN_ZORG()` call in the argument list; an
omitted 0.08 ETH credit from a receipt's own earlier early exit; and an exact
assertion against a reward index that truncates by design and sweeps the 1-wei
remainder to the treasury.

### Deployment shape

Five contracts, all under EIP-170 (`forge build --force --sizes`):

| Contract | Runtime | Margin |
| --- | ---: | ---: |
| ZorgConviction | 20,324 | +4,252 |
| ZorgConvictionRenderer | 18,884 | +5,692 |
| ZorgReceiptArt | 12,843 | +11,733 |
| ZorgPageStyle | 6,991 | +17,585 |
| ZorgTokenListLens | 5,893 | +18,683 |

Order: `ZorgPageStyle` and `ZorgReceiptArt` first, then
`ZorgConvictionRenderer(style)`, then `ZorgConviction(..., renderer, receiptArt, halfLife)`,
then `ZorgTokenListLens(tokenList, conviction)`. No salts are mined for any of
them. `TokenList` and its renderer remain **not deployed**; their mined
addresses are still vacant.

### Still open

- **M-01 / C-02 stand as accepted.** DAO trust over shares, exec credential.
- **Backers panel not built.** Per-listing bonded zOrgz needs `eth_getLogs` over
  `Allocated`, a different data path from the page's `eth_call` client.
- **Day-one appearance.** Every listing starts at zero support, so the ranking
  bars read flat until people bond. Truthful, but worth a decision.
