# TokenListRenderer Audit — Findings and Remediation

Date: 2026-08-02

Reviewer: Claude Opus 5

Scope: `src/utils/TokenListRenderer.sol`, read against `src/utils/TokenList.sol`.
Both files are uncommitted, so there is no git baseline; sizes below are measured
against the tree as it stood before this pass.

## Executive summary

The renderer had no unauthorized write path and no way to affect what the registry
stores — it is `pure`, holds no state, and takes the listing by value, exactly as
its header claims. The defects are all in what it *shows*, which for a contract
whose entire job is to be the visible face of a canonical token list is the
category that matters.

Seven issues, one of which erased text from every card of a whole listing class.
All seven are fixed, plus eight presentation improvements. Neither contract had
been deployed, so the fixes land in v1 rather than as a post-deploy renderer swap;
the cost is that both mined salts are invalidated and must be re-mined.

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| R-01 | High (display) | Reserved banner painted over the description; first two lines erased on every reserved card | Fixed |
| R-02 | Medium | `json()` omitted `description` — present in the struct and on the card, absent from the read dapps are told to batch | Fixed |
| R-03 | Medium | Undeployed listings reported `0x00…00`, colliding with the native asset's deliberate id | Fixed |
| R-04 | Medium | `frozen` invisible in both outputs; a wallet could not tell a sealed listing from an editable one | Fixed |
| R-05 | Medium | `ipfs://` logos rendered as broken images on every card, every time | Fixed |
| R-06 | Low | `name` was the only text with no width bound; worst case left the 720px frame | Fixed |
| R-07 | Low/Design | Sanitisation was a caller precondition stated in no signature and enforced by nothing | Fixed |
| E-01 | Design | Extension fields were structurally unreachable by any renderer, present or future | Fixed |
| B-01 | Blocker | Deployment-gas guard measured two transactions as one, coupling the registry's budget to the renderer's size | Fixed |

---

# Findings

## R-01 — The reservation banner erased the description it sat on

The banner drew an opaque `#d7d7d7` rect at `y=278` spanning 54px, while the
description band was fixed at baselines 300/320/340. Lines one and two were
therefore painted over on **every** reserved card, and line three survived only as
a dimmed fragment under the 0.64 black wash — so the card showed the middle of a
sentence and nothing else.

A reservation is precisely the listing whose description carries the most weight:
it has no account, no logo source and no onchain facts, and the prose is the only
thing distinguishing it. It was the one listing whose description could not be
read.

Fixed by making the two layouts explicit. A deployed listing spends the middle of
the card on the account (`ADDRESS` at 258/278, description at 300/320/340); a
reservation has no account, so the `ADDRESS` block is dropped — the banner already
says the address is pending — the description moves up to 250/270/290, and the
banner drops to `y=300`, below it and above the footer rule.

## R-02 — `description` was missing from the compact JSON

The struct carried it and `tokenURI` emitted it, but `json()` did not. That is the
read `TokenList` explicitly tells consumers to batch through `Multicallable` to
build a list, so reaching a description meant additionally calling `tokenURI`,
base64-decoding it and re-parsing — for a field already sitting in the struct
being read. Added as `"desc"`.

## R-03 — Reservations reported the native asset's address

`json()` called `_account(t)` unconditionally, which renders the zero word as
`0x0000000000000000000000000000000000000000` for an EVM listing. That is
bit-identical to the id the registry *deliberately* gives the native asset
(see M-01 in the previous audit, which established that rule precisely so
`address(0)` means ETH). Any consumer keying rows by `a` merged every reservation
into the ETH listing. `"x":false` disambiguated only for a consumer that read it.

The card already printed `PENDING / NOT ASSIGNED`. The machine-readable side now
agrees: `"a":""`, which cannot collide with a real account in any namespace.

## R-04 — A sealed listing looked exactly like an editable one

`freeze` is the strongest commitment the registry can make, and `lockRenderer` is
its other half — yet neither the card nor the metadata mentioned it. A wallet
rendering a listing had no way to show that its owner-authored fields were sealed
forever, which is the entire signal freezing exists to broadcast.

Now `"f":<bool>` in the JSON, a `Curation: Sealed | Editable` attribute, and a
`SEALED` chip on the card. The chip is drawn only when true: an `EDITABLE` mark on
every ordinary listing is noise, and its absence is already the ordinary case.

## R-05 — IPFS logos were guaranteed broken images

`TokenList._uri` accepts `ipfs://`, and the renderer dropped it straight into
`<image href='ipfs://…'>`. No browser or wallet SVG renderer resolves that scheme,
so those listings drew an empty well every time.

Fixed in the renderer rather than in storage, because it is a display decision:
`ipfs://<cid>` is rewritten to `https://ipfs.io/ipfs/<cid>` for the `href` only.
The registry keeps the canonical URI, `json` still reports it verbatim, and a
later renderer can pick a different gateway without rewriting a single listing.

## R-06 — `name` was the only unbounded run of text

Every other field was either fitted (`_fit` on the footer links), metric-bounded
(the description band counts glyphs in a monospace face), or short by schema.
`t.name` was interpolated raw at 16px Helvetica from `x=176`, and `NAME_MAX` is 40
— which in the uppercase worst case runs past the 720px frame. Now fitted to 34
glyphs. No listing in the seeded set is affected (the longest real name is
`Wrapped liquid staked Ether 2.0`, 31 characters).

## R-07 — The sanitisation contract was implicit

Every function is `public pure` over a caller-supplied struct, so anyone may call
the renderer with anything, and the header presents it as a standalone, swappable,
reusable component. Its only defense was `TokenList._clean` — a caller invariant
stated in no signature and enforced by nothing.

Demonstrated: a `name` of `</text><script>alert(1)</script><text>` emitted exactly
that markup into the SVG, and a `symbol` containing a quote produced JSON that
`json.loads` rejects outright.

**Not exploitable through `TokenList`**, which strips all six dangerous characters
before storage. But the next registry to point at this renderer inherits an
injection sink, and "safe because of what someone else does" is not a property a
reusable pure function should rely on. Every free-text field now passes through
`_safe`, which mirrors `_clean` exactly — so against the registry it removes
nothing — and the header states the reasoning.

Dropping rather than escaping is deliberate: escaping would have to differ between
the two documents this text lands in (`&amp;` is right for the XML and wrong for
the JSON), and one filter correct for both is worth more than fidelity to a
character no display string needs.

## E-01 — Extension fields could never reach a card

`TokenList`'s extras mapping exists so that a new field — a CoinGecko id, a social
handle, a category — costs a transaction rather than a redeploy and a re-listing of
every token. But the renderer signature was `(uint256, Token memory)`, and the
renderer is `pure`, so **no renderer, present or future, could read them**. The
escape hatch was invisible on the only surface it was built for.

`tokenURI` and `json` now take an `Extra[]`, which `TokenList._extrasOf` flattens
from the mapping. Extras reach the card as chips, the JSON as `"e"`, and the
metadata as ordinary NFT attributes. Two-argument overloads remain for callers with
no extension fields.

This was the one change that had to happen before the salts were mined: the
signature is the interface every future renderer must implement, and it could not
be widened after deployment without replacing the registry.

## B-01 — The deployment guard measured two transactions as one

`testDeploymentFitsInATransaction` measured `new TokenList(owner, new
TokenListRenderer())` — both contracts in a single call — against a 15M budget
under EIP-7825's 16,777,216 per-transaction cap. The renderer's growth pushed the
combined figure to 16.07M and the test failed.

The measurement was wrong for the deployment it models. `deploy/TokenList.md`
deploys the two through **separate** CREATE2 factory calls with separate calldata
files, each with its own cap. Charging one budget for a deposit cost that is
actually split made the registry's headroom a function of how large the renderer
happens to be — exactly the coupling that splitting them apart was meant to end.

Now measured per transaction. Both are comfortably inside the cap:

| Transaction | Gas | Cap |
| --- | ---: | ---: |
| `TokenListRenderer` | 3,049,658 | 16,777,216 |
| `TokenList` (incl. four seeded cards) | 12,947,134 | 16,777,216 |

---

# Presentation improvements

| Change | Why |
| --- | --- |
| Provenance pill | `METADATA READ ONCHAIN` / `OWNER ATTESTED` was 12px grey text under the title — the weight of a footnote for the most consequential fact on the card. Now a bordered chip in the theme colour. |
| Adaptive symbol size | A 12-glyph `SYMBOL_MAX` symbol at a fixed 40px ran to x=629 and crowded the band. Now 40/32/26px by length. |
| Chip row | Curation state and extension fields between the identity band and the account, stopping at the frame rather than drawing off the edge. What is not drawn is still in `json` and in the attributes. |
| Contrast floor | The theme colour is owner-chosen and the frame is pure black, so nothing stopped a listing from picking one dark enough that its own 40px symbol was invisible. Rec. 601 luma below 72 is lifted toward white — for painting only; `themeOf` and `json` still report what was set. |
| `<title>` + `role='img'` | Every card is now named for anything reading the document rather than looking at it. |
| Underlined footer links | They read as links instead of as more grey text. Deliberately **not** wrapped in `<a href>`: the card is consumed as an `<img>` where the anchor is inert anyway, and a sanitiser that strips the element would take the visible URL with it. |
| `--` instead of `???` | Three question marks read as a rendering failure rather than an absent symbol. Card only — `json` keeps `""`, because a program must be able to tell absent from literal. |
| `URL_CHARS` / `AUDIT_CHARS` / `NAME_CHARS` | The footer's magic `46` joined the other layout metrics, which the file's convention keeps together. |

The SVG is now assembled in named bands (`_well`, `_header`, `_identity`,
`_account`, `_chips`, `_footer`) rather than as one forty-argument concatenation.
The output shape is unchanged; keeping each band's operands live only for the
length of its own helper is what holds the deployed size down.

# Sizes

| Contract | Runtime | EIP-170 headroom |
| --- | ---: | ---: |
| `TokenListRenderer` | 14,948 | 9,628 |
| `TokenList` | 23,939 | 637 |

`TokenList` grew by **87 bytes** — the `_extrasOf` flattener and the wider call.
Its 637 B of headroom is almost entirely pre-existing: the tree measured 23,852 B
before this pass, not the 21,711 B recorded in `deploy/TokenList.md`. **That
manifest figure is stale, and its claim of "2,865 B of runtime headroom" is wrong
by a factor of four.** Given B-01 in the previous audit — headroom at these
settings is an optimizer artifact, not real margin — the registry's true remaining
room should be re-measured and re-recorded as part of the re-mine, not carried
forward from the manifest.

One further build hazard, pre-existing and unaddressed here: `src/dao/
ZorgTokenListLens.sol` imports `TokenList`, and its compilation profile builds the
registry at 200 runs, producing a **24,811 B** artifact that exceeds EIP-170. Which
variant lands in `out/` depends on what was built last. Any deploy must build the
registry alone and verify `runs=20` in the artifact metadata.

# Verification

`test/TokenListRenderer.t.sol` is new: 18 tests, one per finding plus the
improvements, exercising the renderer **directly** rather than through the registry
— because the renderer is `public pure` over a caller-supplied struct, and
`_clean` is not in the path when someone calls it that way.

Suite: 97 passed, 0 failed, 1 skipped across the seven `TokenList*` suites, plus
57 passed across the `Zorg*` suites. The skip is
`TokenListMinedDeploy`, which detects that the recorded initcode no longer matches
a fresh compile and skips itself — the intended signal, and the reason the manifest
is now marked stale.

Three existing tests were updated, all for intentional interface changes:

- `TokenListAudit.testJsonIsParseable` — the quote/key count moved with the three
  new JSON fields (19 keys, 11 string-valued).
- `TokenList.StubRenderer` — a replacement renderer must now implement the
  extras-bearing signature.
- `TokenListDeploy.testDeploymentFitsInATransaction` — see B-01.

# Not changed

- **`https://` logos** are still passed through unrewritten. Many marketplaces
  sandbox SVG and block external subresources, so these can fail to load too — but
  unlike `ipfs://` they *can* work, and there is no gateway rewrite that would help.
  Curators should prefer `data:image/svg+xml`, as every seeded listing does.
- **`https://` logo rewriting.** See above.

# Post-review deployment prep

Done after the fixes landed, on a worktree off `origin/main`.

## The registry did not actually fit

The headroom in this document's first pass — 637 B — was measured from an isolated
`forge build` of the two source files. A full `forge build` (what `forge test`
does) produced **24,811 B, over EIP-170**, from identical source at identical
settings. Under `via_ir` a contract optimises differently depending on which other
files share its compilation unit, and the two builds sat ~900 B apart.

That meant three things were wrong simultaneously:

- a fresh clone's default build produced a registry that could not be deployed;
- Foundry does not enforce EIP-170 inside tests, so the suite passed against a
  variant mainnet would have rejected — green tests said nothing about the shipped
  bytes;
- `TokenListMinedDeploy` compared the recorded initcode against `vm.getCode`, so
  under a full build it always mismatched and **skipped itself**. It had been
  skipping long enough to hide a stale assertion of its own: it still expected an
  eleven-token constructor after seeding was cut to four.

Lowering `max_optimizer_runs` does not help — 1, 10 and 20 all produce ~24,817.

## What fixed it

`TokenListLens` now owns `rankedIds`, `rankedIdsPaged`, `rankedSummaries` and
`search`; `TokenList.summariesPaged` pages in listing order and the registry drops
`LibSort` entirely. The split follows what can and cannot be replaced: the registry
is immutable and must retain room to ship a security fix, while a lens can be
redeployed at will, so the replaceable work moved to the replaceable contract.

Measured savings were badly non-additive — removing `search` alone saved 1,471 B,
removing `search` and `rankedIdsPaged` together saved only 472 — which is the same
optimizer cliff B-01 described, so each candidate configuration had to be measured
rather than reasoned about.

| | before | after |
| --- | ---: | ---: |
| isolated build | 23,939 | 22,167 |
| full build | **24,811 (over)** | 21,275 |
| worst-case headroom | **-235** | **+2,409** |

The lens is stateless — the registry is a call parameter, not an immutable — so it
has no constructor arguments and no deployment ordering constraint, and one
deployment serves every `TokenList`. The renderer/registry coupling already means
mining one salt wrong invalidates both; there was nothing to gain from a third link
in that chain.

## The guard now asks the right question

`TokenListMinedDeploy`'s staleness check compares recorded source hashes
(`deploy/TokenList.sources.txt`) instead of `vm.getCode`. Whether the source drifted
is true or false regardless of how the caller built, so the test runs under both
build modes and skips only when the code genuinely changed. Verified: from a clean
`out/`, a full `forge test` runs it and it passes.

## Also done

- All three salts mined. Registry `0x0000000fc6abe3eB907a6F6335EC6f5b1e987564`
  (four leading zero bytes), renderer `0x000000f7269197d82ADB734aCaed9Fe978760067`,
  lens `0x0000002F54FA973183Bca49681659488c4033951`.
- `script/mine_create2_salt.js` allocated a native keccak object per iteration.
  Throughput decayed from 0.13M to 0.02M iter/sec and the process died partway
  through long runs — which reads as "mining is slow" rather than as a leak.
  Reusing one hasher's state made these three mines take 62 s, 22 s and 8 s.
  Digests verified byte-identical; every mined address independently re-derived
  with ethers.
- `deploy/TokenList.md` corrected: the compiler row said 200 runs where the build
  pins 20, and the headroom claim was stale by 4x.
- 108 tests pass from a clean build, nothing skipped.
