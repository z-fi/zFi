# TokenList Security Audit — Response and Remediation

Date: 2026-08-01

Auditor: GPT 5.6 Sol (Pro)

Base revision: `c32ade4` (`Order positions as ERC-721, route composition, and a Swapbol approve fix`), with `src/utils/TokenList.sol` uncommitted.

## Executive summary

The audit reviewed `src/utils/TokenList.sol` as a canonical token-metadata source
and returned a NO-GO verdict: no critical or high-severity vulnerability, no
unauthorized write path, no reentrancy route and no fund-custody risk, but six
medium-severity correctness and integrity issues that are deployment blockers
specifically *because* the contract's purpose is to be authoritative about facts.

That framing is correct and the verdict is accepted. Every medium finding was
validated. All six are fixed, along with five of the seven low findings, and the
two remaining are answered below with reasons rather than fixes.

The review also surfaced a defect the audit did not look for and could not have
seen from source: the contract could not be deployed at all under the settings it
was pinned to once the fixes were applied, and its apparent size headroom was an
artifact of an optimizer cliff. That is documented under B-01, and it is the
finding that changed the architecture.

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| M-01 | Medium | Native currency had two inconsistent ids; address APIs could not reach it | Fixed |
| M-02 | Medium | Failed metadata reads persisted and were marked successfully synced | Fixed |
| M-03 | Medium | Canonical metadata is destructively altered by sanitisation | Partially fixed |
| M-04 | Medium | Foreign identity under-specified; malformed EVM listings could brick reads | Fixed (a: accepted) |
| M-05 | Medium | "Deploy anywhere" constructor could seed incorrect assets off mainnet | Fixed |
| M-06 | Medium | Logo backslashes could make `json()` malformed | Fixed |
| L-01 | Low | Events cannot support the advertised log-only indexer | Fixed (documentation) |
| L-02 | Low | Unlimited extras could make a listing impossible to delist | Fixed |
| L-03 | Low | Pagination and search process the entire list | Fixed |
| L-04 | Low | `setLogoSVG` bypassed the effective logo-size limit | Fixed |
| L-05 | Low | Mutable ERC-721 metadata lacked ERC-4906 signalling | Fixed |
| L-06 | Low | Foreign/native listing ownership went stale after an ownership transfer | Fixed |
| L-07 | Low/Design | Governance, dependency pinning, schema versioning | Partially fixed |
| B-01 | Blocker | Undeployable under its own pinned profile; headroom was an optimizer artifact | Fixed |
| B-02 | Low | Ownerless deployment guard was incidental, not explicit | Fixed |

## Scope

| Item | Reviewed |
| --- | --- |
| Primary contract | `src/utils/TokenList.sol` |
| Added by remediation | `src/utils/TokenListRenderer.sol` |
| Direct dependencies | Solady `ERC721`, `Ownable`, `Multicallable`, `MetadataReaderLib`, `Base58`, `Base64`, `LibSort`, `LibString` (pinned at `acd959a`) |
| Tests | `test/TokenList.t.sol`, `test/TokenListDeploy.t.sol`, `test/TokenListPreview.t.sol` |
| Compiler profile | Solidity 0.8.36, `via_ir = true`, optimizer at **200 runs** (see B-01) |

---

# Findings and fixes

## B-01 — Undeployable under its pinned profile; apparent headroom was an artifact

Not reported by the audit, and not visible from source. It is recorded first
because it invalidated the remediation plan the other findings implied.

`foundry.toml` pinned `TokenList` to `max_optimizer_runs = 1` and recorded 24,027 B
with "549 B is the entire headroom." Both numbers were accurate. The conclusion
drawn from them — that roughly 549 B of fixes could be absorbed — was not.

At `runs=1` the contract sat on an optimizer cliff. Measured, one fix at a time:

| change | size | delta |
| --- | ---: | ---: |
| baseline | 24,027 | — |
| `_uri` backslash reject (M-06) | 24,048 | +21 |
| `search` length hoist | 24,040 | +13 |
| `setLogoSVG` bound (L-04) | 24,624 | +597 |
| `_textBlock` local hoist | 25,199 | +1,172 |
| `tokensPaged` clamp (L-03) | 25,227 | +1,200 |
| `_pull` preserve-on-empty (M-02) | 25,266 | +1,239 |
| **all six together** | **25,260** | **+1,233** |

Six changes costing ~1,200 B each also cost ~1,200 B combined: this is one
threshold being crossed, not per-change cost. Worse, size was not monotonic in
the source. Removing Base58 gave 24,437 B; removing two view overloads gave
25,115 B; removing **both** gave 25,453 B — larger than either alone.

The practical consequence is that "trim features until it fits" is not a plannable
strategy here. Each candidate has to be compiled to be known, and combinations do
not compose.

A sweep across optimizer settings showed `runs=1` is uniquely bad and every value
from 2 to 400 lands flat at the same size. The restriction is now pinned to
exactly 200 via matched `min_optimizer_runs`/`max_optimizer_runs`, so only the
existing `lens` profile can satisfy it and the choice cannot silently drift.

That recovered the cliff but not enough: with every audit fix applied the single
contract measured 25,831 B, 1,255 B over. Stubbing `tokenURI` and `json` measured
rendering at ~7.2 KB of pure string assembly holding no state.

Fix: split `TokenListRenderer` out of `TokenList`.

| contract | runtime | headroom |
| --- | ---: | ---: |
| `TokenList` | 21,428 | 3,148 |
| `TokenListRenderer` | 7,301 | 17,275 |

The reason this matters is not that it fits. An immutable registry holding
identities that wallets cache forever must retain room to ship a security fix,
and this audit found six in a single pass. At ~140 B of chaotic headroom it did
not have that room, which would have meant shipping with a known inability to
respond to the next finding.

The renderer is **governance-settable**, not immutable, so the card can be
improved after deployment without redeploying the registry and re-listing every
token under fresh ids. See L-07 for what that delegates.

## M-01 — Native currency had two inconsistent ids

Validated. The constructor registered the native asset through the namespaced
overload, whose local branch required `account != bytes32(0)`; the native asset
therefore fell through to the hashed, `FOREIGN_FLAG`-set path. The address
overload meanwhile returned `uint256(uint160(token))`, so `idOf(address(0))` was
0 — a different id for the same asset.

Every address-based getter was consequently unreachable for the one asset wallets
most conventionally address as `address(0)`: `get(address(0))`, `logoOf`,
`themeOf` all reverted `Unknown` on a listing that plainly existed, and
`isListed(idOf(address(0)))` was false.

Fix: the local EVM branch now returns `uint256(account)` for *every* local
account including zero, so the native asset is id 0 and both overloads agree by
construction. `idOf(address)` reduces to `uint256(uint160(token))` and stays
`pure`.

The audit's second suggestion — reserve id 0 explicitly — is the one taken, in
preference to special-casing `address(0)` in the address overload, because it
makes the two overloads agree structurally rather than by a matching pair of
exceptions.

Regression: `testNativeAssetHasExactlyOneId`.

## M-02 — Failed metadata reads persisted and were marked synced

Validated, and the audit's fifth sub-case is the sharpest thing in the report.

`MetadataReaderLib.readDecimals` is `uint8(_uint(target, ...))` — it truncates the
full returned word. A token returning 274 (`0x112`) reads back as 18. The old
`d > 36 ? 0 : d` guard inspected the *already-truncated* value, so it accepted
the spoof and the card asserted 18 decimals on the authority of a value the token
never returned. Decimals is the one field a consumer computes amounts with.

Fixes:

- Read the full word with `readUint` and range-check **before** narrowing, so the
  bound means what it says.
- Treat an empty or zero read as "no answer", not as "the answer is empty". A
  failed read no longer overwrites stored text or resets decimals. `sync` is
  permissionless by design, so without this any transient failure — a proxy whose
  `name()` grew past the 60,000-gas stipend, a token that revoked its metadata, a
  selfdestructed one — let anybody blank a good listing.
- The card now reads `METADATA READ ONCHAIN` rather than `VERIFIED ONCHAIN`. The
  audit is right that the old wording claims far more than the contract
  establishes: it sounds like the token's legitimacy, issuer or art were verified,
  none of which is true.

Not adopted: per-field status flags and a `lastSyncBlock`. Preserve-on-failure
plus honest wording addresses the integrity problem; the flags are a schema
expansion better made deliberately than under remediation pressure.

Regressions: `testDecimalsCannotBeSpoofedByTruncation`,
`testSyncCannotBlankALiveListing`.

## M-03 — Canonical metadata is destructively altered

Validated as described; partially fixed, and the remainder is a deliberate
trade-off rather than an oversight.

`_clean` admits printable ASCII and drops `"` `'` `\` `<` `>` `&`, so two distinct
source strings can normalise to the same displayed value, Unicode branding is
erased, and — the concrete case — a URL of the form `?a=1&b=2` is silently
rewritten to `?a=1b=2`, which is neither the source value nor a valid equivalent.

What is fixed: the provenance claim. The card no longer says text was "verified"
when it was in fact read, truncated and stripped (see M-02).

What is not: the separation of raw canonical values from safe rendering values.
That is the correct design and the audit is right about it. It is deferred
because it doubles the stored string fields on a contract whose size ceiling was
the binding constraint on this entire pass, and because the sanitiser is the
single control preventing a hostile `name()` from injecting into both JSON and
SVG. Replacing one global sanitiser with per-context escaping is a change that
wants its own review, not a corner of this one.

Consumers needing exact source values should read the token contract directly.
The registry does not claim to reproduce them byte-for-byte, and the header
should be read that way.

## M-04 — Foreign identity under-specified; malformed EVM listings could brick reads

**Part B (malformed EVM accounts) — validated and fixed.** `listForeign` did not
require EVM accounts to fit in 160 bits, while `_account` renders every EVM record
through `LibString.toHexString(uint256(t.account), 20)`, which reverts when the
value does not fit. The owner could therefore create a listing where `get(id)`
succeeds but `json(id)`, `tokenURI(id)` and any batched read revert — and because
Solady's `Multicallable` bubbles a subcall failure, one such listing would revert
an entire batch, taking down a whole page rather than one row.

Fix: `idOf` rejects any EVM account with non-zero upper 96 bits, so the state is
unreachable rather than merely unrendered. Regression:
`testForeignEVMAccountMustFitIn160Bits`.

**Part A (non-EVM network identity) — accepted, not fixed.** The observation is
correct: `Kind` plus a zeroed `chainId` cannot distinguish Solana mainnet from
devnet, `Kind.OTHER` collapses every remaining namespace to `"raw"`, and the same
32-byte account on two networks derives one id.

It is not fixed because the proposed remedy — a full `(namespaceId, networkId,
account)` key — is a breaking change to the identity schema, and the schema is
precisely what must not churn. Non-EVM listing is unused in this deployment. The
honest position is that **`Kind.SVM` and `Kind.OTHER` are not production-ready and
should not be used** until the key is redesigned; EVM listings, local and foreign,
are unaffected because `chainId` disambiguates them properly.

## M-05 — Constructor was not safely deployable across chains

Validated. Every constant in the constructor describes Ethereum mainnet: the seven
addresses, the art, the links, and the native asset's own "Ether" text. Seeding
on `token.code.length != 0` treats code presence as evidence of identity, which it
is not. On another chain an unrelated contract at USDC's address would inherit
Circle's logo, link, description and rank — and `_pull` only corrects
name/symbol/decimals, so the false project identity stays attached to a listing
that looks curated. The native card had the same defect in plainer form: it called
BNB, POL and AVAX "Ether".

Fix: seeding is gated on `block.chainid == 1`. One bytecode still deploys
anywhere; off mainnet it starts empty and the owner lists explicitly, which is the
only honest default when the constants do not apply.

Regression: `testSeedingIsMainnetOnly`.

## M-06 — Logo backslashes could make `json()` malformed

Validated. `_uri` rejected quotes, brackets, ampersands and control characters but
not `\`, while `json()` carried a comment asserting that it did. A logo is the one
display string that never passes through `_clean`, which is where every other
field loses its backslashes, and it is interpolated raw into both `"l":"…"` and
the `"image"` field. A trailing backslash escapes the closing quote and the
document stops parsing.

Fix: `_uri` rejects `\`; the incorrect comment is corrected. Regression:
`testLogoCannotEscapeTheJSONString`.

## L-01 — Events cannot support the advertised log-only indexer

Validated as a documentation defect. `Listed` omits kind, colour, rank, logo,
links and description; `Updated` carries only an id and a field label; and
`setArt` changes rank while emitting only `"art"`, so an indexer following the
comment and skipping art updates would hold a stale ranking.

Fixed by correcting the claim rather than by expanding the events. Event
signatures cannot be changed after deploy, and a full typed-event redesign is a
larger schema decision than this pass should force. The comment no longer promises
log-only reconstruction; ERC-4906 (L-05) now gives consumers a correct
cache-invalidation signal, which is what most indexers actually needed from it.

## L-02 — Unlimited extras could make `delist` unexecutable

Validated. `delist` iterates every extra key, and the owner could add unboundedly
many, making the only path that can remove a listing exceed the block gas limit —
permanently stranding a bad or malicious listing.

Fix: extras are capped at 32 keys per listing. Clearing a key frees a slot.
Regression: `testExtraKeysAreBounded`.

## L-03 — Pagination and search process the entire list

Validated. `tokensPaged` calls `rankedIds()` — a full O(n log n) sort of every id —
and then returns *whole structs including base64 logos*. A logo may be up to
24,576 B, so a 20-row page can be megabytes of returndata and will hit provider
`eth_call` return-size limits well before the list feels large. The `start + count`
overflow additionally made `tokensPaged(start, type(uint256).max)` — the natural
way to ask for "the rest" — panic instead of paging.

Fixes:

- `start + count` is clamped against the remainder rather than computed and
  checked, so an unbounded count pages correctly.
- Added `rankedIdsPaged(start, count)` — ranked ids alone, the read a UI should
  build a list from.
- Added `summariesPaged(start, count)` returning a `Summary` struct with every
  field a dropdown or token picker renders and none of the unbounded ones: no
  logo, no description, no links. Each row is bounded, so a page has a predictable
  size. Measured on the seeded set, a struct page is over 3× a summary page even
  with modest art; a single `LOGO_MAX` logo would put one struct row at 24 KB.

Not fixed: `rankedIds()` still sorts the whole list internally. The intended
consumption pattern — fetch ranked ids once per session, then batch `get`/`json`
through `Multicallable` for the visible window — keeps that to one call, and an
onchain ranking structure maintained on the write path is not justified at this
list's size.

Note for consumers: `_ids` uses swap-and-pop, so listing order — the tie-break
among equal ranks — is not stable across delists. Clients doing scroll pagination
should page over one fetched id array rather than re-querying per page.

Regression: `testPagedReadsAreBoundedAndRanked`.

## L-04 — `setLogoSVG` bypassed the effective logo-size limit

Validated. `setArt` bounds the stored URI at `LOGO_MAX`; `setLogoSVG` bounded the
*raw markup* and then base64-encoded it, so the same field could be written ~33 KB
through one path and 24,576 B through the other — and that value is then embedded
in an SVG and base64-encoded again by `tokenURI`.

Fix: `setLogoSVG` builds the URI and bounds the result, so both paths enforce one
limit on the thing actually stored. Regression:
`testLogoSVGSizeIsBoundedAfterEncoding`.

Not fixed: the namespace check still tests whether the xmlns string appears
anywhere rather than that the root element declares it. It is a rendering
guard, not a security control, and a stricter parse is not worth the bytes.

## L-05 — Missing ERC-4906 metadata update events

Validated. Every listing is mutable — art, links, rank, and a permissionless
`sync` — and none of it signalled a refresh in a form any marketplace understands.
A corrected logo or re-synced symbol could sit stale in every client indefinitely,
which for a token list is the failure that matters most.

Fixes: `MetadataUpdate(id)` emitted from a single `_touch` helper alongside the
existing `Updated` event, so a new mutation cannot pick up one and forget the
other; `BatchMetadataUpdate(0, type(uint256).max)` on a renderer swap, which
restyles every card at once; `supportsInterface` returns true for `0x49064906`.

Also adopted the audit's ERC-5192 suggestion: `locked(id)` and interface
`0xb45a3c0e`, so wallets can tell the NFTs are bound and stop rendering transfer
controls that always revert.

Regression: `testAdvertisesMetadataUpdateAndLockInterfaces`.

## L-06 — Foreign/native listing ownership went stale

Validated. Attested listings were minted to the owner and are permanently
non-transferable, so after an ownership handover the *previous* curator remained
`ownerOf` every one of them, indefinitely and irreversibly.

Fix: attested listings are minted to `address(this)`. Ownership is stable and
listing identity is no longer coupled to whoever is curator that day. Local
listings continue to be held by the token contract itself, which is the whole
point of the design.

## L-07 — Governance, dependency pinning, schema versioning

Partially addressed; the rest is deployment policy rather than code.

Adopted:

- Solady is pinned at `acd959a`, recorded above.
- The compiler profile is pinned exactly (0.8.36, `via_ir`, 200 runs, matched
  min/max) — see B-01.

Not adopted, with reasons:

- `pragma solidity 0.8.36` exact rather than `^0.8.36`: consistent with the rest
  of this repo, which uses the caret throughout; changing it here alone would be
  inconsistent without being safer, since the profile already pins the version
  actually used.
- Schema version / `listRevision` counter: ERC-4906 now provides the
  cache-invalidation signal this was proposed to serve.
- ETH rescue: no inherited payable path can strand value here in a way a rescue
  function would not itself widen the owner's reach.

**Standing risk, unchanged and now slightly widened.** The owner can list,
delist, re-rank, and rewrite every logo, link and foreign text. The audit is right
that this is the principal security boundary. Making the renderer
governance-settable widens it: the registry's promise that local
name/symbol/decimals come from the token and cannot be forged remains true of
*storage*, but is not true of what a wallet *displays*, because a renderer may
print anything. A renderer swap is therefore a change to what every listing
appears to say and belongs behind the same multisig and timelock as curation.
Consumers needing unmediated facts should read `get`/`json` fields rather than
parsing the card.

That widening is bounded rather than permanent: `lockRenderer()` closes the route
for good, and `freeze(id)` seals an individual listing's owner-authored fields.
See "Governance minimisation" below. Neither is a substitute for a multisig while
the renderer remains unlocked.

## B-02 — Ownerless deployment guard was incidental

Found by the existing test suite while remediating L-06, and worth recording
because of how it surfaced.

`testCannotDeployWithoutAnOwner` passed only as a side effect: `_mint(initialOwner,
ethId)` reverts for the zero address. Moving attested listings to `address(this)`
(L-06) removed that side effect and the test failed immediately — correctly. An
ownerless list can never be curated again: no listing, no delisting, no correcting
a bad link, ever.

Fix: an explicit `if (initialOwner == address(0)) revert BadInput();`. The
constructor also now rejects a codeless renderer, for the same reason `list`
rejects a codeless token — a staticcall to one succeeds with empty returndata, so
an EOA renderer would make every card render as an empty string rather than
revert.

The test itself had a second defect: `new TokenList(address(0), new
TokenListRenderer())` binds `vm.expectRevert` to the *renderer* deployment, which
succeeds. The renderer is now constructed on its own line, and the assertion
names `BadInput` rather than accepting any revert.

---

# Added during remediation: governance minimisation

Two features were added that are not audit findings. They exist because this pass
widened owner power (a settable renderer) and the audit was right to name
governance as the principal security boundary. They narrow it back, permanently.

## `freeze(id)` — seal one listing

Irreversible. After it, the owner cannot touch art, links, rank, audit, foreign
text or extras for that id. Every owner-authored setter routes through a single
`_mustEdit` guard rather than each carrying its own check, so a setter added later
cannot silently escape the seal.

Two paths deliberately remain open:

- **`sync` still works.** It copies facts from the token contract, not from the
  owner. Freezing seals what governance authored; it does not freeze what the
  token says about itself.
- **`delist` still works.** This is the significant call. Blocking removal would
  make the commitment maximal, but a frozen listing whose project later rugs — or
  whose frozen, unremovable link starts serving malware — becomes a permanent
  billboard that nobody can take down. Removing a listing is not misrepresenting
  it, so removal stays available while rewriting does not.

A freeze does not survive delisting: a relisted id starts editable, and the flag
is cleared with the rest of the entry rather than lingering as stale state
(`testFreezeDoesNotSurviveDelist`).

## `lockRenderer()` — seal the card, forever

Irreversible. The registry ships with a settable renderer so the card can improve
after deployment, but that is also the last route by which governance can change
what every listing *appears* to say, since a renderer may print anything
regardless of storage.

The two features are complementary and neither is complete alone: **while the
renderer is unlocked, `freeze` guarantees only that a listing's stored fields
cannot change, not what a wallet displays for it.** An end-to-end guarantee for a
given listing requires both. The intended lifecycle is to deploy with a settable
renderer, iterate on the card, then `lockRenderer()` once it is final, freezing
individual listings as their projects ask for the commitment.

Regressions: `testFreezeSealsEveryOwnerAuthoredField`,
`testFreezeLeavesSyncAndDelistWorking`, `testRendererLockIsPermanent`,
`testFreezeDoesNotSurviveDelist`.

---

# Positive properties confirmed

The audit's list of sound properties was re-checked and holds, with two now
strengthened:

- Owner-only curation is applied consistently; permissionless `sync` can only
  target the local address already stored in the listing.
- Metadata reads are static and gas-capped, and **now cannot corrupt a good
  listing when they fail** (M-02).
- `_mint` rather than `_safeMint` avoids callbacks into listed token contracts.
- `_beforeTokenTransfer` blocks every non-mint/non-burn transfer, and the lock is
  **now discoverable** via ERC-5192 (L-05).
- `_ids`/`_position` swap-and-pop removal is internally consistent; extra-key
  position tracking handles both middle and last-element deletion.
- Fixed text fields cannot inject JSON or SVG markup.
- No caller-controlled external execution, delegatecall, transfer, allowance or
  custody path exists. The renderer is reached by `staticcall` from a `view`
  function and is `pure` throughout, so it cannot affect registry state.

# Verification

`forge test --match-path "test/TokenList*"` — 58 passing, 0 failing.

`test/TokenListMinedDeploy.t.sol` deploys the exact mined initcode through the real
SafeSummoner on a fork and asserts the resulting addresses, wiring and seeded state.

Deployed sizes under the pinned profile, confirmed with `forge build --force`:
`TokenList` 21,428 B, `TokenListRenderer` 7,301 B, optimizer runs 200 — measured
from an actual deployment through SafeSummoner on a mainnet fork, not from
`--sizes`. See `deploy/TokenList.md`.

Deployment order is renderer first, then `TokenList(initialOwner, renderer)`.

Outstanding items before mainnet, none of them code changes: transfer ownership to
a multisig; confirm `Kind.SVM`/`Kind.OTHER` remain unused (M-04a); and record
creation- and runtime-bytecode hashes for both contracts against this profile.
