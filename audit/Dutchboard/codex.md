# Dutchboard Security Audit — Independent Validation and Hardening

Date: 2026-07-30  
Auditor: OpenAI Codex  
Status: All validated findings fixed

---

## Executive summary

Dutchboard implements time-decaying, partially fillable escrow listings over an
arbitrary sold asset and quote asset. The review covered its price schedule,
partial-fill arithmetic, ERC-20 and ERC-721 custody, native and token settlement,
batch accounting, cancellation lifecycle, external-call ordering, reentrancy
protection, view integration, and deployment constraints.

The time-decay arithmetic, partial-fill reference-price model, per-leg taker
bounds, batch ETH accounting, cancellation authorization, and transient
reentrancy guard were found sound under the documented design.

Six security issues were validated:

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| DB-01 | **High** | A second listing could claim an NFT already escrowed for another maker and steal it on cancellation | Fixed |
| DB-02 | **High** | Unverified NFT delivery could charge a taker without delivering the bundle or discard a maker's stale claim | Fixed |
| DB-03 | **Medium** | A short or no-op ERC-20 deposit could create an unbacked listing against pooled escrow | Fixed |
| DB-04 | **Medium** | Outbound ERC-20 behavior could under-deliver or consume another listing's pooled escrow | Fixed |
| DB-05 | **Medium** | A taxed or no-op quote transfer could release the lot while underpaying the seller | Fixed |
| DB-06 | **Low** | Filling to Dutchboard itself could close the claim while permanently stranding the asset | Fixed |

No unresolved critical or high-severity finding remains under the supported
standard ERC-20/ERC-721 asset model.

The most serious issue, DB-01, did not require the attacker to own the NFT, hold
capital, or win a race. It arose because ERC-721 `transferFrom` has no return
value and a quietly failing collection could let an attacker create a second
listing backed by an NFT already held for a victim. Cancelling the attacker's
listing then transferred the victim's NFT to the attacker.

The fixes make the contract's documented asset assumptions enforceable:

- every NFT movement proves source ownership before transfer and destination
  ownership afterward;
- every ERC-20 movement proves the exact debit and exact credit;
- failed delivery or cancellation restores the complete transaction and listing;
- unsupported fee/no-op token behavior fails closed; and
- Dutchboard itself cannot be selected as an unrecoverable recipient.

---

## Scope

| Item | Reviewed |
| --- | --- |
| Primary contract | `src/Dutchboard.sol` |
| Direct comparison | `src/DutchAuction.sol` |
| Downstream consumer | Dutchboard paths in `src/SwapboardView.sol` |
| Unit tests | `test/Dutchboard.t.sol` |
| Fuzz tests | `test/DutchboardFuzz.t.sol` |
| Stateful invariants | `test/DutchboardInvariant.t.sol` |
| Audit regressions | `test/DutchboardAudit.t.sol` |
| Integration tests | `test/SwapboardViewDutch.t.sol` |
| Adversarial mocks | Relevant contracts in `test/SwapboardMocks.sol` |
| Compiler | Solidity 0.8.36, `via_ir`, optimizer at 9,999,999 runs |
| Target EVM | Prague configuration; EIP-1153 requires Cancun or later |
| Deployment status | Working-tree contract; no deployed Dutchboard address was identified in the reviewed repository |

The review did not audit the internal logic of arbitrary listed token contracts,
the external mainnet router used by the composition test, or unrelated pool and
forwarder contracts.

---

## Architecture and security properties

### Listing model

A maker escrows either:

- a positive ERC-20 amount, allowing partial fills; or
- one ERC-721 token or an ERC-721 bundle of at most 100 IDs, settling atomically.

The maker chooses a quote asset. `quote == address(0)` means native ETH;
otherwise the taker pays the selected ERC-20 directly to the seller.

### Price model

`startPrice` and `endPrice` are total prices for the full initial lot. Price is:

- flat at `startPrice` before `startTime`;
- linearly decreasing during `duration`; and
- flat at `endPrice` afterward.

An ERC-20 partial fill costs:

```solidity
ceil(priceOf(id) * take / initial)
```

The immutable `initial` denominator is essential. Repricing against `remaining`
would change the unit price after every fill and make fill history influence later
takers.

### Required invariants

The review treated these as the core safety requirements:

1. A live ERC-20 listing is backed by exactly its recorded `remaining` escrow.
2. One listing cannot consume escrow that backs another listing of the same token.
3. A live NFT listing is backed by the exact NFT IDs it records.
4. A caller cannot create a claim over another maker's already-escrowed NFT.
5. A taker is not charged unless the exact lot amount reaches the named recipient.
6. A seller receives the exact ERC-20 quote amount charged to the taker.
7. One `msg.value` cannot settle multiple ETH legs in a batch.
8. Reentrancy cannot observe or exploit pre-fill listing state.
9. A failed external movement restores listing state and every earlier movement.
10. Price never exceeds the maker's declared bracket and never increases over time.

---

## Methodology

The contract was reviewed line by line and then traced across listing, fill,
batch-fill, cancellation, and view paths. Candidate issues were sanity-checked
against:

- the documented asset model;
- Solidity rollback semantics;
- the existing DutchAuction behavior;
- the repository's established Swapboard threat model;
- downstream encoding and view consumers; and
- executable adversarial cases.

The repository already contains broken-token mocks modelling behaviors that have
appeared in deployed assets:

- ERC-721 transfers that silently no-op instead of reverting;
- sticky approvals that survive transfer;
- ERC-20 transfers that return `true` while moving nothing;
- sender-paid fees that over-debit escrow;
- recipient taxes that under-credit the buyer; and
- transfer taxes that underpay the seller.

Eleven regression tests exercise the validated issues after remediation. Leads
that amounted only to documented behavior, self-harm, infeasible overflow, or an
unavoidable fully malicious-token trust assumption were not reported as open
vulnerabilities.

---

## Findings

## [DB-01] High — An attacker could duplicate another maker's NFT escrow and steal it through cancellation

Affected path: `listNFT` → `cancel`  
Fixed in: `_moveNFT`

### Description

The original NFT listing loop trusted a no-return external call:

```solidity
l.ids = ids;
for (uint256 i; i < ids.length; ++i) {
    IERC721(token).transferFrom(msg.sender, address(this), ids[i]);
}
```

ERC-721 `transferFrom` returns no value. A collection that quietly returns when
`from` is not the owner is indistinguishable from a successful collection unless
the caller checks ownership.

This becomes an escrow-confusion vulnerability whenever Dutchboard already owns
the named ID for a legitimate listing:

1. A victim lists NFT `#1`; Dutchboard becomes its owner.
2. An attacker lists the same contract and ID.
3. The collection sees `from == attacker`, notices the attacker is not the owner,
   and quietly returns instead of reverting.
4. Dutchboard creates the attacker's listing even though no NFT moved.
5. The attacker cancels their listing.
6. Dutchboard is the real owner, so `transferFrom(board, attacker, #1)` succeeds.
7. The victim's listing remains live but is now backed by nothing.

The attacker needs no ownership, approval, capital, or timing advantage.

### Impact

Direct theft of another maker's escrowed NFT from any collection with quietly
failing transfer behavior.

### Proof-of-concept shape

The regression `test_CannotDuplicateAnotherListingsNftEscrow` models this path:

```solidity
// Victim escrows #1.
vm.startPrank(victim);
nft.setApprovalForAll(address(board), true);
uint256 victimListing =
    board.listNFT(address(nft), address(quote), ids, 100e18, 100e18, 0, 1 hours);
vm.stopPrank();

// Attacker never owned #1. The listing must fail before it can claim the escrow.
vm.prank(attacker);
vm.expectRevert(
    abi.encodeWithSelector(Dutchboard.NFTTransferFailed.selector, address(nft), 1)
);
board.listNFT(address(nft), address(quote), ids, 1, 1, 0, 1 hours);
```

### Remediation

All NFT movements now prove both ends:

```solidity
function _moveNFT(address token, address from, address to, uint256 tokenId) internal {
    if (IERC721(token).ownerOf(tokenId) != from) {
        revert NFTTransferFailed(token, tokenId);
    }
    IERC721(token).transferFrom(from, to, tokenId);
    if (IERC721(token).ownerOf(tokenId) != to) {
        revert NFTTransferFailed(token, tokenId);
    }
}
```

The source check is load-bearing. A destination-only check would still pass when
the board already held the NFT for somebody else.

### Status

Fixed and covered by:

- `test_CannotDuplicateAnotherListingsNftEscrow`

---

## [DB-02] High — Unverified NFT delivery could charge the taker or discard the maker's claim

Affected paths: NFT `fill`, NFT `cancel`  
Fixed in: `_moveNFT`, `_returnNFT`

### Description

The same no-return behavior affected outbound settlement. The listing was deleted
before the transfer loop, and the seller was paid after the loop. If the collection
quietly failed to move an NFT, the call could continue with:

- the taker charged even though the bundle was not delivered; or
- cancellation completing even though the maker received nothing.

Sticky approvals create a concrete version of this failure. A broken collection
may fail to clear a per-token approval when the NFT enters escrow. The approved
party can then pull the NFT out while the listing remains live. Without source and
destination checks, the next fill or cancellation can silently settle against
missing escrow.

### Impact

- A taker can lose the full quote payment without receiving the NFT bundle.
- A cancellation can erase the maker's only on-chain accounting claim while
  returning nothing.

### Remediation

Fills route every ID through `_moveNFT(board, recipient, id)`. This requires the
board to own the NFT before transfer and the recipient to own it afterward.

Cancellation uses `_returnNFT`:

```solidity
function _returnNFT(address token, address to, uint256 tokenId) internal {
    address owner = IERC721(token).ownerOf(tokenId);
    if (owner == to) return;
    if (owner != address(this)) revert NFTTransferFailed(token, tokenId);
    IERC721(token).transferFrom(address(this), to, tokenId);
    if (IERC721(token).ownerOf(tokenId) != to) {
        revert NFTTransferFailed(token, tokenId);
    }
}
```

The `owner == to` branch is deliberate. If a sticky approval already returned the
NFT to its maker, the desired cancellation outcome is complete; attempting a stale
`transferFrom(board, maker, id)` against a strict collection would revert and make
the dead listing impossible to close.

If somebody else owns the NFT, cancellation reverts and Solidity restores the
deleted listing, preserving the maker's claim.

### Status

Fixed and covered by:

- `test_FillRejectsNftThatEscapedEscrow`
- `test_CancelClosesWhenNftAlreadyReturnedToMaker`
- `test_CancelDoesNotDiscardClaimWhenNftWasStolen`

---

## [DB-03] Medium — Short or no-op ERC-20 deposits could create unbacked listings

Affected path: `listERC20`  
Fixed in: `_pullEscrowToken`

### Description

The original path recorded the requested amount and trusted safe-transfer return
data:

```solidity
l.initial = amount;
l.remaining = amount;
safeTransferFrom(token, msg.sender, address(this), amount);
```

Safe transfer helpers correctly handle revert data, `false`, missing return data,
and EOA targets. They cannot prove that a token returning `true` actually moved
the requested balance.

A fee-on-transfer token may debit the maker by `amount` but credit the board by
less. A successful-looking no-op token may credit nothing. Because escrow is
pooled by token address, the nominal listing can appear backed by balances that
belong to other makers.

### Impact

- Takers can pay for an unbacked or partially backed listing.
- Later fills can consume the same token balance that backs another maker's order.
- Escrow accounting diverges from `initial` and `remaining`.

### Remediation

Incoming escrow now verifies both the maker debit and board credit:

```solidity
function _pullEscrowToken(address token, address from, uint256 amount) internal {
    uint256 fromBefore = IERC20(token).balanceOf(from);
    uint256 boardBefore = IERC20(token).balanceOf(address(this));
    safeTransferFrom(token, from, address(this), amount);

    uint256 spent = _decrease(fromBefore, IERC20(token).balanceOf(from));
    if (spent != amount) {
        revert BalanceDeltaMismatch(token, from, amount, spent);
    }

    uint256 received =
        _increase(boardBefore, IERC20(token).balanceOf(address(this)));
    if (received != amount) {
        revert BalanceDeltaMismatch(token, address(this), amount, received);
    }
}
```

The transfer and the listing storage writes revert atomically on a mismatch.

### Status

Fixed and covered by:

- `test_ShortEscrowDepositIsRejected`

---

## [DB-04] Medium — Outbound ERC-20 behavior could under-deliver or consume pooled escrow

Affected paths: ERC-20 `fill`, ERC-20 `cancel`  
Fixed in: `_sendEscrowToken`

### Description

An outbound token can behave differently from its inbound `transferFrom`:

- return `true` while moving nothing;
- debit the board by `amount + fee`; or
- debit `amount` but credit the recipient by `amount - tax`.

These cases have different consequences:

- a no-op or recipient tax charges the taker without delivering the requested lot;
- a sender fee spends balance belonging to the next listing of the same pooled
  token; and
- a no-op cancellation can delete the listing without returning its escrow.

Checking only the board's balance is insufficient because a recipient tax can
debit the correct amount while under-delivering. Checking only the recipient is
insufficient because a sender fee can credit the correct amount while overdrawing
the board.

### Impact

- Taker under-delivery or total non-delivery.
- Cross-listing consumption of another maker's escrow.
- Loss of a maker's accounting claim during cancellation.

### Remediation

Every outbound ERC-20 movement proves both deltas:

```solidity
function _sendEscrowToken(address token, address to, uint256 amount) internal {
    uint256 boardBefore = IERC20(token).balanceOf(address(this));
    uint256 toBefore = IERC20(token).balanceOf(to);
    safeTransfer(token, to, amount);

    uint256 spent =
        _decrease(boardBefore, IERC20(token).balanceOf(address(this)));
    if (spent != amount) {
        revert BalanceDeltaMismatch(token, address(this), amount, spent);
    }

    uint256 received = _increase(toBefore, IERC20(token).balanceOf(to));
    if (received != amount) {
        revert BalanceDeltaMismatch(token, to, amount, received);
    }
}
```

The listing is still written before external calls, but a mismatch reverts the
entire transaction and restores that state.

### Status

Fixed and covered by:

- `test_TrueReturningNoOpPayoutIsRejected`
- `test_SenderFeeCannotConsumeAnotherListingsEscrow`
- `test_RecipientTaxCannotUnderDeliver`
- `test_CancelNoOpPayoutDoesNotDiscardClaim`

---

## [DB-05] Medium — Quote-token settlement could underpay the seller

Affected path: ERC-20 quote settlement in `_settle`  
Fixed in: `_payQuoteToken`

### Description

The original quote leg transferred directly from taker to seller:

```solidity
safeTransferFrom(quote, msg.sender, seller, cost);
```

This avoids quote custody but does not prove settlement. A taxed token can debit
the taker by the full `cost`, credit the seller by less, and return success. The
lot has already been delivered and the listing state updated by this point.

Solidity rollback protects both sides only when the contract detects the mismatch
and reverts.

### Impact

The seller receives less than the scheduled price while the taker receives the
full lot.

### Remediation

The quote leg now verifies the exact taker debit and exact seller credit:

```solidity
function _payQuoteToken(
    address token,
    address from,
    address to,
    uint256 amount
) internal {
    if (amount == 0 || from == to) return;

    uint256 fromBefore = IERC20(token).balanceOf(from);
    uint256 toBefore = IERC20(token).balanceOf(to);
    safeTransferFrom(token, from, to, amount);

    uint256 spent = _decrease(fromBefore, IERC20(token).balanceOf(from));
    if (spent != amount) {
        revert BalanceDeltaMismatch(token, from, amount, spent);
    }

    uint256 received = _increase(toBefore, IERC20(token).balanceOf(to));
    if (received != amount) {
        revert BalanceDeltaMismatch(token, to, amount, received);
    }
}
```

Zero-cost fills do not make a needless token call. A self-fill is economically a
no-op, so it also skips a token round-trip whose net balance delta cannot be
meaningfully measured.

### Status

Fixed and covered by:

- `test_QuoteTokenMustPaySellerExactly`

---

## [DB-06] Low — Dutchboard could be selected as an unrecoverable recipient

Affected path: `_settle`  
Fixed by: recipient validation

### Description

The `to` parameter makes router composition possible, but the original validation
rejected only the zero address.

If `to == address(this)`:

- an ERC-20 transfer sends escrow from the board back to itself;
- an NFT transfer can likewise leave the NFT owned by the board; and
- the listing can be reduced or deleted even though the asset remains in custody.

There is no rescue authority and no accounting entry for the stranded asset after
the listing closes.

### Impact

Permanent loss through user or integration error. The caller chooses `to`, so
this is not a third-party theft vector, but the mistake is irreversible.

### Remediation

Settlement now rejects both invalid recipients before changing state:

```solidity
if (to == address(0) || to == address(this)) revert Bad();
```

### Status

Fixed and covered by:

- `test_BoardCannotBeTheFillRecipient`

---

## Sound components and deliberate non-findings

The following surfaces were reviewed and did not produce a valid vulnerability.

### Reentrancy and call ordering

All mutating entry points use a transient-storage guard. Listing, fill, batch fill,
and cancellation remain locked across:

- sold-token calls;
- quote-token calls;
- ERC-721 calls;
- seller ETH callbacks; and
- refund callbacks.

Fill and cancellation update or delete listing state before external delivery.
Any later failure reverts the whole transaction, so reentrant reads can observe
only post-operation state and no failed transfer can leave that state committed.

The hard-coded selector for `Reentrancy()` was verified as `0xab143c06`.

### Batch ETH reuse

`fillMany` passes each leg only the unspent portion:

```solidity
msg.value - ethSpent
```

An ETH-quoted leg refuses a cost above that value, and ERC-20-quoted legs return
zero ETH usage. `ethSpent` therefore cannot exceed `msg.value`, and one attached
value cannot pay multiple sellers twice.

The pinned-fork unit test `testFillManyCannotReuseValueAcrossEthLegs` passes.

### Price monotonicity and overflow

The schedule is non-increasing because:

- `startPrice >= endPrice`;
- elapsed time never decreases inside one chain history; and
- the interpolated subtraction grows with elapsed time.

The interpolation product is bounded by a 96-bit price difference times a
40-bit duration. Partial-fill cost multiplies a 96-bit price by a 128-bit take.
Both are far below 256-bit overflow.

The `uint96` price cast is checked because `startPrice <= type(uint96).max`, and
`endPrice <= startPrice` proves the second cast safe.

### Partial-fill reference pricing

Cost is always prorated against `initial`, not `remaining`. This preserves unit
price independence from fill history. A taker cannot manipulate the next user's
rate by choosing a particular first fill size.

### Ceiling-division drift

Ceiling division applies per fill. Splitting one economic purchase into many
transactions can cost up to one quote base unit of additional rounding per chunk.
At extreme ratios, aggregate proceeds can exceed the displayed full-lot price.

This is deliberate and seller-favoring. It prevents a positive-price dust fill
from rounding to zero, each taker sees the exact result through `costOf`, and
`maxCost` bounds what each fill may spend. It was not changed.

### Free-at-end listings

`endPrice == 0` is explicitly supported. After the decay window, the lot may be
filled for free. This is the maker-selected schedule, not an expiry bypass.

The fixed quote helper skips the zero-amount token call, which makes the free
semantics independent of whether the quote token accepts zero transfers.

### Fill before a future start

A future-start listing is fillable at `startPrice` before its decay begins. The
contract documents that price is flat outside the window; it does not describe a
closed pre-start phase. This behavior was retained.

### Seller cancellation

The seller may cancel at any time, including while a taker's fill is pending. A
seller can front-run a fill, but can only reclaim their own unsold escrow. This is
the documented lifecycle rather than a theft path.

### Forced ETH

Forced or pre-existing ETH is inert. Settlement forwards only the current leg's
`cost` and refunds only `msg.value - ethUsed`; it never sweeps `selfbalance()`.
One caller cannot collect ETH that was already present.

### Unchecked `nextId`

`nextId++` is unchecked, but collision requires `2^256` successful listings.
This is operationally infeasible and not a realistic overflow issue.

### Pagination gas

`getListings(start, end)` accepts a caller-selected range. Very large ranges can
exhaust on-chain gas, but callers pay for their own range and can paginate. No
state or third-party funds are affected.

---

## Accepted and residual risks

### Rebasing assets

Rebasing tokens remain unsupported. Exact per-call deltas prove one transfer but
cannot isolate pooled custody from a supply change between transactions.

### Fully malicious assets

A token that lies consistently through both its transfer method and
`balanceOf`/`ownerOf` can manufacture a matching false state. Permissionless
listing primitives cannot establish the honesty or economic value of the asset
contract itself.

The new checks materially defend against broken or non-standard implementations;
they do not turn arbitrary malicious code into a trustworthy asset.

### Contract sellers that reject ETH

An ETH-quoted listing made by a seller contract that rejects native transfers is
unfillable. The seller can still cancel and recover escrow. Pull-payment accounting
would change the minimal ownerless design and was not introduced.

### Refund-rejecting callers

A caller that sends excess ETH and rejects the refund causes its own fill to
revert. Exact-value calls remain usable.

### Seller cancellation race

Listings are cancellable rather than firm. Integrators must tolerate a fill
reverting because the seller or another taker changed the listing first.

### Target-chain compatibility

The reentrancy guard uses EIP-1153 transient storage. Deployments require a
Cancun-or-later EVM. Deployment on an older execution environment will fail or be
incompatible.

### External price risk

The schedule never reads an oracle or pool. This prevents fill-time pool
manipulation, but it also means the maker's off-chain anchor can become stale.
That market risk belongs to the maker's chosen schedule.

---

## Changes implemented

`src/Dutchboard.sol` now includes:

- `NFTTransferFailed(address token, uint256 tokenId)`;
- `BalanceDeltaMismatch(address token, address account, uint256 expected, uint256 actual)`;
- `_pullEscrowToken` for exact deposit verification;
- `_sendEscrowToken` for exact delivery and cancellation verification;
- `_payQuoteToken` for exact taker-to-seller settlement;
- `_moveNFT` for source and destination ownership proofs;
- `_returnNFT` for safe stale-listing cancellation;
- `_increase` and `_decrease` non-reverting delta helpers;
- `IERC721.ownerOf`;
- `IERC20.balanceOf`; and
- rejection of `to == address(this)`.

The public listing/view structure and fill function signatures remain unchanged.
`SwapboardView` integration therefore needs no encoding or ABI migration.

---

## Regression coverage

`test/DutchboardAudit.t.sol` contains eleven adversarial regressions:

| Test | Property |
| --- | --- |
| `test_CannotDuplicateAnotherListingsNftEscrow` | Another listing cannot claim an NFT already held for a victim |
| `test_FillRejectsNftThatEscapedEscrow` | Missing NFT escrow cannot charge the taker |
| `test_CancelClosesWhenNftAlreadyReturnedToMaker` | An already-returned NFT does not brick cancellation |
| `test_CancelDoesNotDiscardClaimWhenNftWasStolen` | A stolen NFT does not cause cancellation to erase the maker's claim |
| `test_ShortEscrowDepositIsRejected` | Nominal listing amount must equal actual escrow received |
| `test_TrueReturningNoOpPayoutIsRejected` | Successful-looking no-op output cannot charge the taker |
| `test_CancelNoOpPayoutDoesNotDiscardClaim` | No-op cancellation preserves the listing |
| `test_SenderFeeCannotConsumeAnotherListingsEscrow` | One payout cannot overdraw pooled escrow |
| `test_RecipientTaxCannotUnderDeliver` | Exact board debit cannot hide buyer under-delivery |
| `test_QuoteTokenMustPaySellerExactly` | Seller quote credit must equal scheduled cost |
| `test_BoardCannotBeTheFillRecipient` | Escrow cannot be stranded by self-recipient settlement |

---

## Verification

### Adversarial regressions

Command:

```text
forge test --match-path test/DutchboardAudit.t.sol -vv
```

Result:

```text
11 passed; 0 failed; 0 skipped
```

### Pinned-mainnet unit and router-composition tests

Command:

```text
forge test --match-path test/Dutchboard.t.sol -vv
```

Result:

```text
21 passed; 0 failed; 0 skipped
```

This includes native/ERC-20 quote paths, cancellation, partial fills, per-leg
bounds, mixed batches, duplicate batch IDs, storage packing, refunds, and live
router composition.

### Dutchboard/SwapboardView integration

Command:

```text
forge test --match-path test/SwapboardViewDutch.t.sol -vv
```

Result:

```text
10 passed; 0 failed; 0 skipped
```

### Fuzz properties

Command:

```text
forge test --offline --match-path test/DutchboardFuzz.t.sol -vv
```

Result:

```text
18 properties passed at 256 runs each
```

The fuzz suite covers monotonic pricing, window clamps, positive-price rounding,
cost monotonicity, full-lot price equality, fill-history independence, escrow
conservation, split-fill rounding, direct quote settlement, ETH refunds, taker
bounds, cancellation, and listing validation.

### Stateful invariants

Command:

```text
FOUNDRY_INVARIANT_RUNS=32 FOUNDRY_INVARIANT_DEPTH=100 \
forge test --offline --match-path test/DutchboardInvariant.t.sol -vv
```

Result:

```text
8 invariants passed
32 runs × 100 calls per invariant
25,600 total state-machine calls
0 handler reverts
```

The repository default is a substantially longer 256 runs × 500 calls. That full
campaign was started but not completed during the interactive audit; the reduced
stateful campaign completed without a failure.

### Build and deployability

Command:

```text
forge build src/Dutchboard.sol --sizes
```

Result:

| Contract | Runtime | Initcode | EIP-170 runtime margin |
| --- | ---: | ---: | ---: |
| Dutchboard | 10,230 bytes | 10,256 bytes | 14,346 bytes |

The targeted compiler run completed successfully.

### Lint and workspace checks

- `forge lint src/Dutchboard.sol` reported only naming-style notes and the
  checked `uint96` narrowing warnings.
- `git diff --check` passed.
- The temporary RPC configuration change used for local-only tests was restored;
  pre-existing unrelated working-tree changes were preserved.

---

## Final assessment

Dutchboard's pricing and batch-accounting design is compact and coherent. The
material security gap was not in its Dutch-auction math; it was at the asset
movement boundary. A successful low-level or interface call is not proof that a
permissionless token moved the asset described by the listing.

The implemented ownership and exact-delta proofs close the reproducible
cross-listing theft, under-delivery, underpayment, and claim-discard paths while
preserving the public ABI and router/view integration.

No unresolved critical or high-severity issue remains under the supported
standard-token model. Remaining risks are explicit design or asset-trust
assumptions: rebases between transactions, fully malicious contracts that lie
consistently through their own state views, cancellable-order races, unpayable ETH
sellers, and Cancun-era EVM compatibility.

This review does not establish the absence of all vulnerabilities and does not
replace an independent human audit, deployment rehearsal on the exact target
chain, continuous monitoring, or a post-deployment bug bounty.

## Current-tree routed and native-asset addendum

Dutchboard now exposes `listERC20For` alongside `listERC20`; both delegate to
the same internal escrow path. The caller always funds the complete lot, while
the explicit seller receives fill payments, controls cancellation, and
receives the unsold remainder. Naming another seller can only sponsor a
fully-funded listing and cannot consume that seller's balance or allowance, so
this boundary needs no EIP-712/ERC-1271 authorization or nonce. The seller
field identifies the beneficiary and controller, not proof that the address
requested the listing.

Fungible seller validation rejects zero, Dutchboard itself, and canonical
WETH. Settlement independently rejects zero and Dutchboard as the fill
recipient. These checks prevent a listing from closing into inventory that the
ownerless board cannot attribute or recover.

`Orderbol.placeDutch` makes routed listing compatible with the zRouter funding
waterfall. ERC-20 placement consumes a transient, same-immediate-caller
checkpoint and requires the fresh balance increase to equal the lot before
granting a call-scoped allowance. Pre-existing donations remain unavailable to
the routed maker. When the user sells native ETH, Orderbol wraps the exact
`msg.value` into canonical WETH and records the user as seller because
Dutchboard deliberately escrows ERC-20 lots rather than literal ETH.

`cancelUnwrap` is the seller-only exit for a fungible WETH lot. It rejects NFT
and non-WETH listings, deletes storage before either WETH or the seller
receives control, and proves both the exact wrapper debit and exact ETH credit
before forwarding the unsold remainder. Forced ETH and WETH backing other
listings cannot subsidize a malformed redemption.

Swapbol handles both representations when consuming Dutch liquidity. Native
input pays a Dutch `quote == address(0)` leg in literal ETH, but wraps the exact
leg budget when `quote == WETH`; any other quote is incompatible with native
input and is rejected. Native book output is represented by a WETH lot, routed
to Swapbol, and unwrapped once from the aggregate current-call delta. This
explicitly includes WETH-quoted Dutch legs in ETH-input hybrid routes.

Regressions for this later work are in
`test/DutchboardMakerFor.t.sol` (3 tests),
`test/DutchboardCancelUnwrap.t.sol` (9 tests), and the native/WETH cases in
`test/SwapbolPlan.t.sol`.
