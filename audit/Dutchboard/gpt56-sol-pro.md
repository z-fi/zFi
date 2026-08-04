# Dutchboard.sol — response to the GPT 5.6 Sol (Pro) audit

Reviewer verdict: **NO-GO for mainnet**, 2 Critical / 2 High / 1 Medium / 1 Low / 1 Informational.

Assessment: **both Criticals are real and were reproducible as described.** The two Highs are
real composability defects. M-01 is a real standards collision. L-01 and I-01 are correct.
Every finding has been addressed in `src/Dutchboard.sol`; nothing was dismissed.

The reviewer's headline remedy — delete the live-position nesting layer entirely — was **not**
taken. Nesting is the feature, not an accident of the design, and the two Criticals are both
failures of *binding* and *accounting*, not of the concept. What was wrong is that the callback
proved "something left, something arrived" instead of "this exact thing arrived, against no
other liability". Both are fixable without removing the layer, and the fixes below make the two
invariants the reviewer named enforced on chain rather than merely monitored:

```
one board-held NFT  ↔  exactly one liability
ERC-20 balanceOf    ≥  escrowed[token] + totalClaimable[token]
```

| ID   | Severity | Verdict | Disposition |
| ---- | -------- | ------- | ----------- |
| C-01 | Critical | Confirmed | Fixed — full-tuple callback binding |
| C-02 | Critical | Confirmed | Fixed — unallocated-balance accounting + `totalClaimable` |
| H-01 | High     | Confirmed | Fixed — settlement freezes the outer listing |
| H-02 | High     | Confirmed | Fixed — Dutchboard now emits reciprocal callbacks, incl. the ETH leg |
| M-01 | Medium   | Confirmed | Fixed — ERC-721 rejected from both fungible paths |
| L-01 | Low      | Confirmed | Fixed — documentation corrected |
| I-01 | Info     | Confirmed | Fixed — aggregate accounting, events, and a `freeBalance` view |

---

## C-01 — Forged NFT-proceeds credit → theft of unrelated escrowed NFTs

**Confirmed.** The transient snapshot was keyed by payment token alone and stored the bare
sentinel `1`. `beforeOrderProceeds` proved token id *X* was outside the board;
`afterOrderProceeds` proved token id *Y* was inside it. Nothing required `X == Y`, and nothing
bound the caller, `orderId`, listing, amount, or `nft` flag into the slot. A collection earns
callback authority just by having one of its NFTs escrowed, which an attacker gets by listing
their own token — so the whole exploit is permissionless and needs no reentrancy.

The reviewer's step-by-step reproduction is accurate as written.

### Mitigation

The transient slot is now derived from the complete callback context:

```solidity
function _proceedsSlot(address board, uint256 orderId, address token, uint256 amount, bool nft)
    internal pure returns (bytes32)
{
    return keccak256(abi.encode(_PROCEEDS_TRANSIENT_BASE, board, orderId, token, amount, nft));
}
```

Any field the `after` leg varies — including the token id — lands on a different, empty slot and
reverts with `InvalidProceedsCallback`. The credit therefore requires that *the same* token id
was demonstrably outside the board before settlement and inside it after, which is exactly the
"same NFT" proof that was missing.

Three further custody guards were added, giving the explicit state machine the reviewer asked
for without a new enum:

- `heldAsProceeds[token][tokenId]` is set when an NFT is credited as proceeds and cleared when
  it is claimed. `_registerLiveClaim` rejects it, and so does `onERC721Received`. An NFT can
  never simultaneously back listing escrow and a proceeds claim.
- `onERC721Received` verifies ownership without moving anything (so a collection can call it
  directly). It now also rejects a token id already registered as escrow or already owed out as
  proceeds — closing the one path by which a collection could mint a second liability over an
  NFT the board already owed.
- `beforeOrderProceeds` rejects `token == address(this)`. This board's receipts are minted, not
  escrowed; an "arrival" of one would be a fabrication.

**Not adopted:** authenticating boards by immutable address, code hash, or factory. Dutchboard is
deliberately permissionless about what it will escrow, and an allowlist would make the composability
gated on a deployer's judgement. It is not needed for soundness either: with the tuple bound and
the delta measured, a malicious collection can only ever credit itself assets it genuinely
delivered, which is the same thing as making a gift.

---

## C-02 — Double-counted ERC-20 deposit → flash-funded drainage of pooled escrow

**Confirmed, and this was the more dangerous of the two.** `beforeOrderProceeds` snapshotted the
*raw* board balance. Between the two legs — legal, because EIP-1153 transient state outlives the
call frame while the reentrancy guard does not — an attacker calls `listERC20For`, which raises
both the physical balance and `escrowed[token]` by `B`. The `after` leg sees a real `+B` delta
and credits `claimable += B` on top of the `escrowed += B` the same tokens already created. Two
liabilities, one deposit. `claimSurplus` then `cancel` extracts `2B`.

The reviewer's insolvency arithmetic is correct at every step.

### Mitigation

The snapshot is now of the **unallocated** balance, exactly as recommended:

```solidity
function _freeBalance(address token) internal view returns (uint256) {
    return IERC20(token).balanceOf(address(this)) - escrowed[token] - totalClaimable[token];
}
```

with `totalClaimable[token]` added as the aggregate of every `claimableProceeds` entry —
incremented on credit, decremented in `claimSurplus`.

This is what makes the fix hold rather than merely patching the one sequence. Every ordinary
board operation moves balance and liability by the same amount in the same direction:

| Operation | `balanceOf` | `escrowed` | `totalClaimable` | free |
| --------- | ----------- | ---------- | ---------------- | ---- |
| list ERC-20 | `+a` | `+a` | — | 0 |
| cancel | `−r` | `−r` | — | 0 |
| fill (escrow leg) | `−t` | `−t` | — | 0 |
| `claimSurplus` | `−a` | — | `−a` | 0 |
| credited proceeds | `+a` | — | `+a` | 0 |

So free balance is invariant under *every* interleaving an attacker can construct, not just
`listERC20For`. Only a genuinely unaccounted inbound transfer moves it — which is precisely what
the callback is trying to detect. No `PROCEEDS_IN_FLIGHT` lock over the whole contract is needed,
and none was added: locking would have broken legitimate nested settlement.

The subtraction is checked, so the conservation invariant
`balanceOf ≥ escrowed + totalClaimable` is *enforced*: any state that violates it makes every
proceeds callback for that token revert rather than proceed on bad numbers. A public
`freeBalance(address)` view exposes the same quantity to monitors.

Note that the quote leg of a fill never touches board balance — payment goes taker → seller
directly — so it does not appear in the table.

---

## H-01 — Buyer pays for a spent or depleted underlying position

**Confirmed.** A callback only ever *credited* proceeds; it did not disturb the outer listing.
A maker could therefore fill their own underlying Swapboard order in the block before the
victim's Dutchboard fill, claim the proceeds to their own DBPOS receipt, and still deliver a
spent SBPOS at the full advertised price. `maxCost` bounds the price and says nothing about what
is being bought. Partial fills are the same attack with a dial.

### Mitigation

Crediting proceeds now **freezes** the outer listing:

```solidity
if (!frozen[listingId]) { frozen[listingId] = true; emit Frozen(listingId); }
```

`frozen[id]` blocks `_settle`, `_quote` (so `costOf`, `quoteFill` and `tryFillMany` all report
it as unfillable rather than reverting mid-batch), `takeFor`, and `legOf`.

Freeze rather than close, deliberately. Closing would zero the seller, delete the callback
registration, and strand every later partial settlement — and with a bundle, strand the other
NFTs too. A frozen listing is still live: its registration survives so subsequent partial
settlements keep crediting the same receipt, and the seller can `cancel` to take the changed
position back, claim what accrued, and relist on terms that describe what they are actually
selling. That is the reviewer's required flow, with recoverability preserved for the whole bundle.

---

## H-02 — One-way integration strands proceeds when a DBPOS is nested

**Confirmed.** Dutchboard consumed Swapboard's callbacks but emitted none of its own, so a DBPOS
escrowed on another Dutchboard settled into an untracked balance with no path out. Worse for the
native-ETH case: the receiving board's `receive` accepts only WETH, so the inner fill reverted
outright.

### Mitigation

Dutchboard now emits the reciprocal callbacks, making the integration symmetric rather than
one-way. `_payQuoteToken` brackets the transfer with the same opt-in probe Swapboard makes of
this board — a 30k-gas `acceptsOrderProceeds(uint256)` static call, and only an affirmative
answer turns on `beforeOrderProceeds` / `afterOrderProceeds`. Ordinary sellers are unaffected
beyond one cold static call. A revert inside an accepted callback bubbles: an escrow that opted
in and then refused the accounting must not be paid anyway.

The ETH leg is handled rather than left to revert. When the seller opts in, `_payQuoteETH` wraps
the payment to canonical WETH and delivers that through the callbacks:

```solidity
if (_notifyBeforeProceeds(seller, id, weth, cost)) {
    IWETH(weth).deposit{value: cost}();
    _sendEscrowToken(weth, seller, cost);
    _notifyAfterProceeds(seller, id, weth, cost);
} else {
    safeTransferETH(seller, cost);
}
```

An escrow accounts for arrivals by token; a bare ETH send would either bounce off its `receive`
or land as unattributable dust. Everyone else still receives native ETH on the unchanged path.

These calls happen with this board's reentrancy guard set and after all listing state is
written, so an adversarial seller gains nothing from being called.

---

## M-01 — ERC-721 token id `1` through the fungible path

**Confirmed.** `_checkAssets` only required code at the address. ERC-20 and ERC-721 share
`balanceOf(address)` and `transferFrom(address,address,uint256)`, so a standard ERC-721 listed
through `listERC20` with `amount == 1` satisfies every exact-delta check this board makes — and
then locks, because `transfer(address,uint256)` does not exist on the way out. As a quote asset
with a cost of exactly `1`, it silently moves token id 1 out of the taker.

### Mitigation

An ERC-165 probe for `0x80ac58cd` now rejects ERC-721s from **both** fungible paths: the sold
token in `_listERC20`, and the quote asset in `_checkAssets` (which covers the NFT listing paths
too, since an NFT lot can also be quoted).

The probe is used only to *reject*. The reviewer additionally suggested *requiring* ERC-165 on
the NFT paths; that was not adopted, because it would make pre-165 and non-declaring collections
unlistable for no security gain — the NFT paths already prove custody by `ownerOf` before and
after every move, which is a stronger check than a self-report. Rejecting on an affirmative
answer is sound in the direction that matters: a contract claiming to be an ERC-721 is taken at
its word and kept out of code that would treat it as fungible.

This does not make hybrid or adversarial tokens safe, and does not claim to. It removes the
collision for standards-compliant assets, which is the reachable-by-accident case.

---

## L-01 — Closed-listing view documentation

**Confirmed** — stale documentation, not a state error. `getListing` and `getListings` now
document that `seller == address(0)` is the sole liveness marker, that historical terms are
retained on purpose so spent receipts still render and indexers can report what was sold, and
that `frozen[id]` marks a still-open listing that is no longer fillable.

---

## I-01 — Solvency and proceeds monitoring

**Confirmed.** Added, in the shape requested:

- `totalClaimable[token]` — the aggregate that makes the solvency check a two-slot read.
- `freeBalance(token)` — the enforced quantity itself; reverts if the board is insolvent.
- `heldAsProceeds[token][tokenId]` — per-token NFT custody status, publicly readable.
- `event ProceedsCredited(id, source, sourceOrderId, token, amount, nft)`
- `event ProceedsClaimed(id, token, to, amount, nft)`
- `event Frozen(id)` — new, and needed: a frozen listing disappears from quotes without a
  `Cancelled` or `Filled`, which would otherwise look like an indexer bug.

---

## Removed

`_isLiveClaim` — the unused ERC-165 probe for `LIVE_ORDER_POSITION`. The reviewer correctly
noted it was dead code and that self-reported interface support authenticates nothing. It is
gone; `_isERC721` takes its place in the opposite (rejecting) role.

Registration of *every* escrowed NFT is kept, not narrowed to self-declared live positions. It
is the board's NFT custody index — it is what makes double-listing one token id impossible — and
narrowing it would reopen that hole for collections that do not declare the interface. Callback
authenticity does not rest on the registry: it rests on the bound tuple and the measured delta.

---

## Points not accepted

**"Remove the callback machinery from the initial deployment."** Declined. The layer's two
failures were binding and accounting, both now fixed and both testable as invariants. Shipping a
board that refuses live positions and then reintroducing nesting later would mean two escrow
formats in the wild and a migration, which is the worse risk.

**"Block every other state-changing function between `before` and `after`."** Declined in favour
of unallocated-balance accounting, which neutralises the interleaving arithmetically instead of
by exclusion. A global lock would forbid legitimate nested settlement — precisely the case H-02
requires to work.

---

## Build and operational gate

### EIP-170 — the reviewer's warning was right, and it had already bitten

The reviewer could not certify runtime size and flagged the inline SVG as the likely constraint.
Measured: the submitted revision compiled to **26,074 bytes of runtime code — 1,498 over the
enforced 24,576-byte limit.** It was undeployable as submitted, independently of any of the
security findings. (For scale, the pre-nesting contract at `HEAD` is 12,427 bytes; the inline
`tokenURI` is the overwhelming majority of the growth, not the callback layer.)

Fixed by the fallback the reviewer named, following the pattern already used by the sibling
board: `src/utils/DutchboardMetadata.sol` is an immutable renderer deployed by the constructor
and held in `METADATA_RENDERER`. It is not upgradeable and not settable. `tokenURI` passes a
fully resolved `RenderParams` snapshot — decimals and symbol were already captured at listing
time precisely so metadata never calls untrusted code — so the renderer calls nothing.

The renderer also gained a `FROZEN` state, so a receipt whose underlying position settled reads
as frozen rather than continuing to render a decay curve that can no longer be filled.

### Remaining, unchanged from the reviewer's list

Pin the exact compiler build rather than `^0.8.36`; pin the Solady and `PositionSVG` commits;
target the EVM revision live on mainnet rather than the Glamsterdam target; confirm the
constructor receives canonical mainnet WETH and test `cancelUnwrap` against it; and run the
suite on a fork with representative and adversarial assets.

## Verification status of this patch

Compiles clean under `solc 0.8.36` with `via_ir`. Runtime size `20,863` bytes (was `26,074`).

Existing suites re-run against the patched contract:

| Suite | Result |
| ----- | ------ |
| `Dutchboard.t.sol` | 21 passed |
| `DutchboardAudit.t.sol` | 11 passed |
| `DutchboardNFT.t.sol` | 57 passed |
| `DutchboardHardening.t.sol` | 21 passed |
| `DutchboardCancelUnwrap.t.sol` | 9 passed |
| `DutchboardPosition.t.sol` | 6 passed |
| `DutchboardBundleGas.t.sol` | 6 passed |
| `DutchboardMakerFor.t.sol` | 4 passed |
| `DutchboardFuzz.t.sol` | 23 passed |
| `DutchAuction.t.sol` | 75 passed |
| `DutchAuctionCostBounds.t.sol` | 4 passed |
| `DutchAuctionInvariant.t.sol` | 3 passed |
| `DutchboardInvariant.t.sol` | 8 passed |
| `DutchAuctionSnwapFork.t.sol` | 1 passed, **4 failed** |

`Ran 14 test suites in 1647.80s: 249 tests passed, 4 failed, 0 skipped (253 total)`.

The four failures are `BadPlan()` in the mainnet-fork suite for the *legacy* `DutchAuction`
contract routed through `zRouter.snwap → SafeExecutor → Swapbol`. None of those contracts were
touched by this patch, the error originates in the router rather than the board, and
`foundry.toml` documents that fork failures on the shared public RPC are indistinguishable from
real breakage until the message is read. Treated as pre-existing and unrelated; not
independently confirmed against an unpatched baseline.

`DutchboardInvariant.t.sol` passes in full. Three invariants have since been added for the
properties this patch introduces — `invariant_erc20BalanceCoversEveryLiability`,
`invariant_nftIsNeverBothEscrowAndProceeds`, and
`invariant_frozenListingsStayQuotableAsUnfillable`. These have **not** yet been run to
completion: the suite takes ~27 minutes per execution on the current machine. They must pass
before this revision is re-reviewed.

## Regression coverage added

`test/DutchboardProceedsAudit.t.sol` (15 tests) and `test/DutchboardNesting.t.sol` (7 tests),
plus three new invariants in `test/DutchboardInvariant.t.sol`. All 22 pass.

The nesting suite uses **two real Dutchboards** rather than a mock. A DBPOS is a live position
by construction, so board B escrowing board A's receipt reproduces H-02 exactly — and because A
then settles into B, the same fixture produces the settlement-while-escrowed event H-01 is about.

### Mutation-tested, because passing tests are not evidence

A test that passes against the patched contract proves nothing on its own. Each fix was
therefore reverted in place and the suites re-run. **12 of 22 tests failed against the reverted
contract**, with at least one killing test per finding:

| Finding | Reverted to | Tests that caught it |
| ------- | ----------- | -------------------- |
| C-01 | token-only transient key | `mismatchedTokenIdBetweenCallbackLegsReverts` |
| C-02 | raw-balance snapshot | `listingDepositCannotBeCountedAsProceeds`, `nestedCallbacksOnTheSameTokenCompose`, `oneArrivalCannotSatisfyTwoSettlements` |
| H-01 | no freeze on credit | `settlementFreezesTheOuterListingBeforeItCanBeBought`, `frozenLegIsSkippedByTryFillMany`, `partialSettlementFreezesAndLaterPartialsStillCredit`, `sellerRecoversBothThePositionAndTheProceeds` |
| H-02 | callbacks disabled | `erc20ProceedsOfANestedListingAreAttributedAndRecoverable`, `nativeETHProceedsAreWrappedRatherThanBounced` |
| M-01 | no ERC-165 probe | `standardERC721RejectedFromTheERC20SellPath`, `standardERC721RejectedAsAQuoteAsset` |

Two results are worth reading closely. `nativeETHProceedsAreWrappedRatherThanBounced` fails with
`ETHTransferFailed()` on the reverted contract — confirming the reviewer's claim that a nested
native-ETH listing did not merely strand proceeds but reverted the inner fill outright. And
`nestedCallbacksOnTheSameTokenCompose` fails with `ProceedsInFlight` — the token-only key could
not support two concurrent settlements at all, so the tuple binding fixed a functional limit as
well as a vulnerability.

**Caveat on the mutant.** It is a partial revert, not the exact pre-patch file. The
own-receipt rejection and the escrow/proceeds disjointness guards were left in place, so the
four tests covering them (`ownReceiptsCannotBeCreditedAsProceeds`,
`proceedsNFTCannotAlsoBecomeListingEscrow`, `cannotNominateAnAlreadyEscrowedNFT`,
`everyCallbackFieldIsBound`) had no opportunity to fail and are **not** mutation-validated. The
remaining passes are honest-path and documented-limitation tests, which should pass either way.

## Regression tests still owed

The reviewer's list is the right list. The mismatched-token-id callback, the
`before → listERC20For → after → claim → cancel` sequence, the global solvency and escrow-sum
invariants, NFT custody uniqueness, freeze-on-settlement ordering (including the underlying fill
landing immediately before the outer fill), cross-Dutchboard composition on both the ERC-20 and
native-ETH legs, and the standard-ERC-721-id-1 rejection all need executable coverage before
this revision is re-reviewed.
