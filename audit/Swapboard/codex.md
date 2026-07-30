# Swapboard Security Audit — Independent Validation and Hardening

Date: 2026-07-30

Auditor: OpenAI Codex

Base revision: `4216153` (`zQuoter repoint, Swapboard extension, zSwap v0.2 payload`)

## Executive summary

This review covered the escrow, fill, cancellation, expiry, batching, NFT, and
ETH/WETH paths in `src/Swapboard.sol`, together with its Solady dependencies,
adversarial mocks, and current downstream consumers.

The audit validated two high-severity NFT settlement vulnerabilities, six
medium-severity settlement/accounting issues, and two low-severity lifecycle
issues. One additional informational hardening item was also implemented. All
reported issues are fixed and covered by regression tests.

No unresolved critical or high-severity finding remains under the documented
standard-token and canonical-WETH deployment model.

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| SB-01 | High | An attacker could create a second order backed by another maker's escrowed NFT | Fixed |
| SB-02 | High | A no-op NFT payment could release the maker's escrow for free | Fixed |
| SB-03 | Medium | An ERC-20 marked as `nftB` could report failure through a return value the board ignored | Fixed |
| SB-04 | Medium | A taker could pay for an NFT that was no longer delivered | Fixed |
| SB-05 | Medium | Cancel and sweep could close an order without returning its NFT | Fixed |
| SB-06 | Medium | A short ERC-20 bid on an NFT order could be charged the full ask | Fixed |
| SB-07 | Medium | Outbound ERC-20 behavior could short recipients or consume another order's pooled escrow | Fixed |
| SB-08 | Medium, configuration-dependent | Short-minting or over-burning WETH could settle from unrelated escrow | Fixed |
| SB-09 | Low | A strict NFT already returned to its maker could leave a dead order uncancellable | Fixed |
| SB-10 | Low | Payable construction could permanently strand deployment ETH | Fixed |
| SB-11 | Informational | The ERC-721 receiver hook accepted untracked safe deposits with no recovery path | Fixed |
| SB-12 | Low | A sponsored order could name the board or the wrapper as maker, locking the escrow and burning a taker's payment | Fixed |

> **SB-12 was added by a later independent pass** (Claude Opus 5, 2026-07-30)
> re-reviewing the post-fix tree. It re-verified SB-01 … SB-11 as fixed and
> found no new critical, high, or medium severity issue.

## Scope

| Item | Reviewed |
| --- | --- |
| Primary contract | `src/Swapboard.sol` |
| Direct dependencies | Solady `Multicallable`, `SafeTransferLib`, `FixedPointMathLib`, and `ReentrancyGuardTransient` |
| Tests and mocks | `test/Swapboard*.t.sol`, `test/SwapboardMocks.sol` |
| Downstream consumers | `src/SwapboardView.sol`, `src/forwarders/Swapbol.sol`, `src/forwarders/Swapbatch.sol` |
| Compiler profile | Solidity 0.8.36, `via_ir = true`, optimizer enabled with 9,999,999 runs |
| Deployment status | Reviewed implementation is an uncommitted working-tree extension; no deployment address for it was identified in the repository |

The review did not audit the economic value of arbitrary listed tokens, the
internal correctness of canonical WETH, or every unrelated contract in the
repository.

## Methodology

The review combined:

- line-by-line analysis of every external entry point and internal settlement
  helper;
- state-machine analysis across create, partial fill, full fill, cancel, and
  expiry sweep;
- checks-effects-interactions and callback/reentrancy analysis;
- adversarial ERC-20, ERC-721, and WETH behavior;
- pooled-custody conservation analysis;
- comparison of the pre-fix implementation with the hardened working tree;
- regression tests for each validated issue;
- 20,000-run fuzzing of partial-fill and ETH-payment conservation properties;
- compatibility tests against SwapboardView, Swapbol, and Swapbatch; and
- bytecode-size, formatting, and diff-integrity checks.

The original NFT review reproduced the first six failure modes against the
pre-fix implementation before inverting them into regressions. The subsequent
pass independently traced those paths, validated the fixes, and added the
fungible escrow, WETH-boundary, and lifecycle findings below.

## Severity definitions

- **Critical:** direct, broadly exploitable loss of most or all protocol
  custody, or permanent protocol-wide failure.
- **High:** direct loss of an order's principal with realistic preconditions
  and little or no victim recovery.
- **Medium:** material loss, overcharge, under-delivery, or pooled-accounting
  failure with narrower token/configuration preconditions.
- **Low:** localized loss or permanent lifecycle failure requiring user or
  deployment error.
- **Informational:** defensive hardening, documentation, or operational risk
  without a demonstrated unauthorized value transfer.

## Trust model and invariants

The conclusions in this report rely on the following model:

1. `weth` is the target chain's canonical, immutable WETH deployment.
2. A supported ERC-20 reports balances honestly and does not rebase pooled
   custody between transactions.
3. A supported ERC-721 reports `ownerOf` honestly.
4. Makers are responsible for the behavior and economic value of the asset
   selected as ordinary ERC-20 `tokenB`.
5. The target execution environment supports the reentrancy guard's configured
   storage mode.

The core invariants are:

- every active fungible order remains backed by its remaining `amountA`;
- a fill cannot release more tokenA than its maker escrowed;
- a prepaid ETH fill cannot spend WETH belonging to another order;
- a failed payout restores the order and all preceding payment movements;
- a private order authorizes `msg.sender`, never a caller-supplied recipient;
- a partial fill cannot make the resting unit price worse for the maker; and
- an NFT movement is accepted only when ownership proves the intended transfer
  occurred.

## Detailed findings

### SB-01 — Attacker could claim another maker's escrowed NFT

**Severity:** High

**Affected path:** NFT `tokenA` creation

**Status:** Fixed in `_moveNFT`

#### Description

The original escrow check transferred the NFT and then verified only that the
board owned it:

```solidity
IERC721(tokenA).transferFrom(msg.sender, address(this), amountA);
if (IERC721(tokenA).ownerOf(amountA) != address(this)) {
    revert NFTEscrowFailed(tokenA, amountA);
}
```

That proves where the NFT is, but not who supplied it. If a broken collection
quietly returns on an unauthorized transfer, an attacker can name an NFT that
the board already holds for a victim. The transfer does nothing, the
destination check passes, and a second order is stored against the victim's
escrow.

The attacker can then cancel the second order. Because the board is the actual
owner, cancellation transfers the victim's NFT to the attacker while the
victim's original order remains active and unbacked.

#### Impact

Any NFT held by the board from a collection with a silent unauthorized-transfer
failure could be stolen without capital, timing, or privilege.

#### Remediation

Every NFT movement now proves both ends:

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

The source check is load-bearing: it proves the current caller owned the NFT
before the attempted escrow transfer.

#### Regression

`test_CannotEscrowAnNftTheBoardAlreadyHolds` and
`test_CannotEscrowAnNftOwnedBySomeoneElse`.

---

### SB-02 — No-op NFT payment released escrow for free

**Severity:** High

**Affected path:** `nftB` fill payment

**Status:** Fixed in `_moveNFT`

#### Description

The NFT payment leg originally trusted `transferFrom`:

```solidity
if (nftB) IERC721(tokenB).transferFrom(msg.sender, maker, fillAmountB);
```

ERC-721 `transferFrom` returns no value. A collection that silently no-ops is
therefore indistinguishable from one that paid the maker. Settlement continued
and released the maker's fungible or NFT escrow to the taker.

The same path was reachable by a taker that did not own the requested NFT if
the collection returned quietly instead of reverting on the invalid `from`.

#### Impact

Complete loss of the maker's escrow on an order priced in an affected
collection.

#### Remediation

The payment leg now calls:

```solidity
_moveNFT(tokenB, msg.sender, maker, fillAmountB);
```

The board requires the taker to own the NFT before payment and the maker to own
it afterward.

#### Regression

`test_NftPaymentThatNeverArrivesIsCaught` and
`test_NftPaymentFromANonOwnerIsCaught`.

---

### SB-03 — ERC-20 failure could be hidden by the `nftB` interface

**Severity:** Medium

**Affected path:** Misconfigured `nftB` payment

**Status:** Fixed by ownership confirmation

#### Description

ERC-20 and ERC-721 share the selector for:

```solidity
transferFrom(address,address,uint256)
```

If a maker marked an ERC-20 as `nftB`, the board called it through an interface
declaring no return value. An ERC-20 that returned `false` for insufficient
balance or allowance was therefore read as successful payment. The taker could
receive the escrow despite paying nothing.

#### Impact

Loss of the complete escrow on a type-misconfigured order. Unlike an actively
malicious token scenario, this can arise through integration or UI error.

#### Remediation

The NFT payment path now calls `ownerOf` before and after transfer. A plain
ERC-20 cannot satisfy that interface and fails closed before escrow is
released.

#### Regression

`test_Erc20MarkedAsAnNftCannotSilentlyFailToPay`.

---

### SB-04 — Taker could pay for an NFT that was not delivered

**Severity:** Medium

**Affected path:** `nftA` payout

**Status:** Fixed in `_moveNFT`

#### Description

NFT custody was checked only when the order was created. A collection with a
sticky per-token approval could let the maker or an approved third party remove
the NFT from escrow while the order remained active.

The original payout then called an unverified `transferFrom` after moving the
taker's payment to the maker. If that transfer silently failed, the order
closed and the taker paid in full without receiving the NFT.

#### Impact

Loss of the taker's full payment. The attack requires a defective collection
and a party able to remove the NFT from escrow.

#### Remediation

NFT payout now requires the board to own the NFT immediately before transfer
and the named recipient to own it immediately afterward. Any failure reverts
the complete fill, including the earlier payment.

#### Regression

`test_FillRevertsWhenEscrowedNftNoLongerMoves`.

---

### SB-05 — Cancel or sweep could destroy an NFT claim without returning it

**Severity:** Medium

**Affected paths:** `cancelOrder`, `cancelExpired`, `trySweepExpired`

**Status:** Fixed in `_returnNFT` and `_returnEscrow`

#### Description

The original return paths cleared `active`, `amountA`, and `amountB`, then
called an unverified NFT `transferFrom`. If that transfer silently did nothing,
the order still closed. The maker lost the on-chain claim representing the
escrow without recovering the NFT.

The same behavior affected permissionless expiry sweeps.

#### Impact

Permanent loss of the maker's recorded claim. A failing batch reverted if the
token reverted, but a quiet no-op could falsely report successful settlement.

#### Remediation

All three return paths share `_returnEscrow`. The NFT branch:

1. accepts completion if the maker already owns the NFT;
2. otherwise requires the board to own it;
3. transfers it to the maker; and
4. proves the maker owns it afterward.

If settlement fails, the transaction reverts and restores the order state.

#### Regression

`test_CancelRevertsRatherThanDiscardingTheClaim`,
`test_HonestNftSweepUnaffected`, and the ordinary cancel/sweep suites.

---

### SB-06 — Short NFT bid could be charged the full ask

**Severity:** Medium

**Affected path:** ERC-20 payment for an NFT order

**Status:** Fixed in `_fill`

#### Description

Every NFT order settles in full. The original full-fill branch replaced
`fillAmountB` with the entire stored `amountB`:

```solidity
if (nftA || nftB || fillAmountB == 0 || fillAmountB >= amountB) {
    (outA, fillAmountB, full) = (amountA, amountB, true);
}
```

For an NFT sold for an ERC-20, a taker could pass a nonzero amount below the
ask. Instead of rejecting the bid, the board rewrote it to the full price and
pulled that amount from the taker's allowance.

#### Impact

The caller's explicit spend bound was violated. A router offering one unit
against a 1,000-unit listing could be charged all 1,000 units.

#### Remediation

For `nftA`, a nonzero bid below `amountB` now reverts. The zero sentinel still
means "take the whole order," and an overbid is still clamped to the ask.

```solidity
if (fillAmountB != 0) {
    if (nftB && fillAmountB != amountB) {
        revert PartialFillNotAllowed(orderId);
    }
    if (nftA && fillAmountB < amountB) {
        revert PartialFillNotAllowed(orderId);
    }
}
```

#### Regression

`test_ShortBidOnAnNftOrderIsRefusedNotBilledInFull` and
`test_NftOrderStillTakesTheSentinelAndAnOverbid`.

---

### SB-07 — Outbound ERC-20 behavior could corrupt pooled escrow

**Severity:** Medium

**Affected paths:** fungible fill payout, cancel, sweep, prepaid WETH payment

**Status:** Fixed in `_sendEscrowToken`

#### Description

Incoming fungible tokenA was already balance-measured, but outgoing transfers
trusted `SafeTransferLib` return-data checks. A successful return value does not
prove the intended balance movement.

Three concrete behaviors matter:

- a true-returning no-op token leaves the recipient unpaid while the order
  closes;
- a recipient-side tax debits the board by the nominal amount but credits the
  recipient less than the event reports; and
- a sender-paid fee debits `amount + fee` from the board, consuming fungible
  escrow belonging to another maker.

Because orders pool the same token at one board address, the third behavior is
a cross-order accounting failure.

#### Impact

Under-delivery to a taker or maker, silent destruction of an order claim, or
consumption of another maker's escrow.

#### Remediation

`_sendEscrowToken` snapshots both balances and requires:

```text
boardBefore - boardAfter       == amount
recipientAfter - recipientBefore == amount
```

A mismatch reverts the full transaction and restores the payment, transfer,
and order state.

#### Regression

`test_TrueReturningNoOpTokenCannotCloseFilledOrder`,
`test_SenderFeeCannotConsumeAnotherOrder`, and
`test_RecipientTaxCannotShortTheTaker`.

---

### SB-08 — Non-standard WETH could spend unrelated WETH escrow

**Severity:** Medium, configuration-dependent

**Affected paths:** ETH wrapping, WETH redemption, prepaid WETH payment

**Status:** Fixed in `_wrapETH`, `_unwrapETH`, and `_sendEscrowToken`

#### Description

The board pools WETH from multiple orders. Previously:

- `deposit{value: amount}` was assumed to mint exactly `amount`;
- `withdraw(amount)` was assumed to burn exactly `amount` and return exactly
  that much ETH; and
- prepaid WETH delivery trusted `transfer`.

A wrapper that accepted ETH but minted too little could let an ETH fill pay its
maker from WETH backing another order. A wrapper that burned more than requested
could similarly consume neighboring escrow during an unwrap.

Canonical WETH does not behave this way, so exploitation depends on an invalid
deployment trust root or an incompatible wrapper.

#### Impact

Cross-order loss of WETH custody under a misconfigured wrapper.

#### Remediation

The board now verifies:

- the exact WETH increase after `deposit`;
- the exact WETH decrease after `withdraw`;
- the exact ETH increase received from `withdraw`; and
- the exact board debit and maker credit on prepaid delivery.

These checks isolate accidental non-standard wrappers. They cannot make a
fully malicious wrapper safe because the wrapper controls `balanceOf`.

#### Regression

`test_ShortMintingWethCannotSpendUnrelatedEscrow` and
`test_OverburningWethCannotConsumeUnrelatedEscrow`.

---

### SB-09 — Already-returned strict NFT could make cancellation impossible

**Severity:** Low

**Affected paths:** NFT cancel and expiry sweep

**Status:** Fixed in `_returnNFT`

#### Description

While validating SB-05, a strict collection exposed a separate lifecycle edge
case. A sticky approval can return the NFT to its maker before cancellation.
Calling:

```solidity
transferFrom(address(this), maker, tokenId)
```

afterward correctly reverts because the declared `from` is no longer the owner.
An unconditional transfer-and-post-check remediation would therefore leave a
dead listing permanently active even though the asset was already home.

#### Impact

The maker could not close a stale order, and a sweeper could not clean it from
the book.

#### Remediation

`_returnNFT` reads `ownerOf` first. If the maker already owns the NFT, the
return is complete and no stale transfer is attempted. Otherwise the board
must own it before transfer.

#### Regression

`test_CancelClosesWhenTheNftIsAlreadyHome` and
`test_CancelSkipsTransferWhenStrictNftIsAlreadyHome`.

---

### SB-10 — Payable constructor could strand deployment ETH

**Severity:** Low

**Affected path:** deployment

**Status:** Fixed

#### Description

The constructor was payable despite the contract being ownerless and having no
authenticated ETH recovery path. ETH accidentally attached to deployment would
not correspond to an order and could never be withdrawn.

#### Impact

Permanent loss of deployment value.

#### Remediation

The constructor is now nonpayable.

#### Regression

`test_ConstructorRejectsDeploymentValue`.

---

### SB-11 — Receiver hook accepted unrecoverable untracked NFTs

**Severity:** Informational

**Affected path:** direct ERC-721 safe transfer

**Status:** Fixed

#### Description

The previous `onERC721Received` implementation accepted arbitrary
`safeTransferFrom` deposits. Such NFTs were not associated with an order, and
the ownerless board had no authenticated rescue mechanism.

#### Remediation

The hook now reverts with `DirectNFTTransfer`. Orders continue to escrow NFTs
with verified `transferFrom`.

Unsolicited plain `transferFrom` deposits cannot be prevented by the receiver,
so callers must still avoid transferring assets directly to the board.

#### Regression

`test_DirectSafeNftTransfersAreRejected`.

---

### SB-12 — A sponsored order could name the board or the wrapper as maker

**Severity:** Low

**Affected path:** `createOrderFor`, `createOrders`, `createOrderWithEthFor`

**Status:** Fixed

#### Description

`_createOrder` validated only `maker != address(0)`, while `_to` deliberately
refused both `address(this)` and `weth` as a delivery address, on the stated
grounds that the contract is immutable and neither mistake is recoverable. A
maker is the delivery address for returned escrow and for fill proceeds, so the
same two addresses were unsafe there and unguarded.

With `maker == address(this)` the order was terminally broken in three ways:

- `cancelOrder` was unreachable, because `msg.sender` can never be the board.
- `cancelExpired` / `trySweepExpired` reverted, because `_sendEscrowToken`
  cannot observe a board debit when the board is also the recipient. The escrow
  was locked permanently.
- A **fill succeeded**. The ordinary `tokenB` leg goes straight from taker to
  maker and is deliberately not balance-measured (see "Reviewed and
  deliberately not changed"), so the taker's payment landed on the board as
  untracked inventory with no owner and no rescue path.

That third case is what lifts this above self-inflicted loss by the sponsor.
The resulting order is indistinguishable from a healthy one on-book —
`isFillableBy` returns true and `getOrders` shows a live public order — so the
loss falls on an unrelated taker. `maker == weth` is the same shape, differing
only in that an unwrapped payout there would be re-wrapped to the board.

#### Remediation

Maker validation moved into a shared `_checkMaker`, applied by `_createOrder`
and `_createOrderWithEth`, which retains the zero-address check and adds the
two addresses `_to` already refuses.

#### Regression

`test_createOrderFor_refusesBoardAsMaker`,
`test_createOrderFor_refusesWethAsMaker`,
`test_createOrderWithEthFor_refusesBoardAndWethAsMaker`,
`test_createOrderFor_stillRefusesZeroMaker`,
`test_recipientGuardMatchesMakerGuard` (in `test/SwapboardAuditNew.t.sol`).

## Reviewed and deliberately not changed

### Ordinary ERC-20 `tokenB` is not balance-measured

On a normal fill, tokenB moves directly from taker to maker. A taxed token may
therefore net the maker less than the gross `amountB`, and a true-returning
no-op token is effectively a 100% tax.

This remains a documented asset-selection risk rather than pooled-custody
accounting: the maker chooses tokenB, and it never enters the board's books.
Enforcing exact deltas would add two balance reads to the hot fill path and
would deliberately remove fee-on-transfer token support.

### Rebasing tokenA remains unsupported

Exact transfer deltas protect individual calls but cannot isolate pooled
custody from a supply change between transactions. A negative rebase can leave
aggregate liabilities above the board's balance. Supporting such assets would
require materially different accounting or isolated custody.

### Fully malicious tokens remain outside the model

A token or wrapper that lies consistently through `balanceOf` or `ownerOf` can
defeat any verification based on those functions. Permissionless token support
cannot prove the honesty or value of the asset contract itself.

### `tryFillOrders` and `trySweepExpired` do not suppress every revert

The try-fill path skips orders that became missing, inactive, expired, or
unauthorized between quote and execution. It still reverts on caller errors,
dust fills, disallowed partial fills, and token failures.

The try-sweep path similarly skips stale IDs but does not isolate a settlement
that cannot return the escrow. Quietly closing such an order would discard the
claim the sweep exists to protect.

### ETH overpayment is rejected rather than refunded

A small front-running partial fill can reduce the remaining ask and make a
pending `fillOrderWithEth` value excessive. The transaction then reverts. This
is gas griefing, not loss of principal, and avoids another refund callback path.

### Recipient is not authorization

Private-order authorization correctly checks `msg.sender`, not `recipient`.
Using a caller-selected delivery address for authorization would let anyone
name the intended counterparty and drain private orders. The consequence is
that private orders cannot be filled through an arbitrary forwarding contract.

### Same-address NFT swaps remain allowed

The fungible same-token case is rejected, but the same collection is allowed
when either NFT flag is set so NFT-for-NFT swaps remain possible. Invalid flag
combinations either fail the ownership checks or are maker-side
misconfiguration; no cross-order theft remained after SB-01 through SB-03.

The later pass specifically probed the degenerate case — one collection on both
sides with the same tokenId — and it needs no dedicated check: by fill time the
escrowed token is owned by the board, so the payment leg's `ownerOf != from`
preflight refuses it and the escrow stays cancellable. The carve-out is now
commented in `_createOrder` so it does not read as merely permissive.

### Direct donations are unrecoverable

Forced ETH and unsolicited ERC-20 or plain ERC-721 `transferFrom` deposits
cannot be safely attributed to an owner. Adding an administrative sweep would
create a larger custody authority than the immutable board currently has.

## Verified sound properties

The following areas were specifically attacked and did not produce a valid
finding:

- maker-only cancellation;
- public expiry sweeping returning assets only to the maker;
- private-order counterparty enforcement;
- deadline and expiry separation;
- exact ETH underpayment protection for all-or-nothing and NFT orders;
- partial-fill full-precision arithmetic and maker-favoring rounding;
- impossibility of a live partial order with zero tokenA or tokenB remainder;
- atomic rollback across batch operations;
- state updates before every settlement interaction;
- reentrancy resistance during malicious ERC-20 payout callbacks;
- Solady multicall caller preservation;
- Solady multicall rejection of nonzero `msg.value`;
- tokenId zero handling on either NFT side;
- clamping overbids to the stored ask; and
- current `SwapboardView.ISwapboardV2.Order` ABI compatibility.

Added by the later pass:

- `balanceOf` and `ownerOf` compile to `staticcall`, so no verification read is
  itself a reentrancy vector — every untrusted non-static call is a token
  transfer or the ETH payout, all inside `nonReentrant`;
- a sponsored order cannot debit the address it names as maker;
- an ERC-721 passed as a fungible `tokenA` can only be escrowed when its tokenId
  is 1 (the balance delta must equal `amountA`), and the resulting order is
  unrecoverable but affects no other order's escrow;
- `counterparty == address(this)` yields an unfillable but still-cancellable
  order; and
- repeated minimal partial fills cannot degrade the maker's rate — floor
  rounding leaves each remainder richer in tokenA, never poorer.

## Verification results

### Contract and regression tests

- 109 targeted local Swapboard tests passed.
- The 19 adversarial tests in `SwapboardAuditTest` passed.
- After SB-12: the full non-fork `test/Swapboard*` sweep is 206 tests across 15
  suites, all passing, including the 7 new `SwapboardAuditNew` regressions.
- Both conservation fuzz properties passed with 20,000 runs each:
  - partial fills never release more tokenA than was escrowed and preserve
    backing for every live remainder;
  - ETH fills either revert atomically or pay the maker exactly the taker's
    value without touching parked WETH escrow.

### Consumer compatibility

- 19 local `SwapboardViewV2` tests passed.
- 16 Swapbol tests passed.
- 17 Swapbatch tests passed.

### Build and hygiene

- `forge build src/Swapboard.sol --offline` passed under the production
  compiler profile.
- Runtime bytecode is 17,708 bytes after SB-12 (was 16,899 before).
- EIP-170 headroom is 6,868 bytes.
- `forge fmt --check` passed for the changed contract and tests.
- `git diff --check` passed.
- Compiler output contained dependency deprecation warnings and naming/lint
  notes, but no Swapboard compilation error.

One known, unrelated scale assertion remains outside this settlement audit:
`SwapboardScaleTest.test_GasOnABusyBoardOfOtherPairs` measures the view
contract's busy-book scan against a 10 million gas target. It exercises
`SwapboardView`, not Swapboard settlement or custody.

## Files changed for the audit

- `src/Swapboard.sol`
- `test/SwapboardAudit.t.sol`
- `test/SwapboardMocks.sol`
- `test/SwapboardCoverage.t.sol`
- `test/SwapboardAuditNew.t.sol` (SB-12 regressions)
- `audit/Swapboard/codex.md`

## Conclusion

The hardened implementation closes the validated NFT ownership-confusion,
unverified-settlement, spend-bound, pooled ERC-20, and WETH-isolation failures.
Under canonical WETH and standard non-rebasing token behavior, no unresolved
critical or high-severity issue was identified.

The contract is immutable and directly custodies user assets. This review
therefore does not replace an independent human audit, deployment rehearsal
against the exact target-chain WETH deployment, a public bug bounty, or
post-deployment monitoring.

## Current-tree routed-order addendum

The post-audit integration adds `createOrderFor` and
`createOrderWithEthFor`. Both regular creation functions and their `For`
variants now share the same internal creation paths: the regular functions
substitute `msg.sender`, while a `For` call records the explicit maker.

This is a funded-gift boundary, not delegated authority. The caller supplies
all escrow from its own ERC-20 balance or `msg.value`; the named maker supplies
no allowance and is never debited. The maker receives fill proceeds, owns
maker-only cancellation, and receives returned or expired escrow. Therefore no
EIP-712/ERC-1271 authorization or nonce is required for these entry points.
Conversely, the on-chain maker field is not proof that the named address asked
for or endorsed the order. A signature would become necessary if a later
version pulled maker funds, reimbursed a sponsor, or executed a reusable
off-chain instruction.

The payout-address guard is shared across direct and sponsored creation.
Neither the board nor its WETH wrapper may be the maker, and fill recipients
may be neither address. This prevents an apparently successful order from
paying into untracked board inventory or re-wrapping an unwrapped payout into
the wrapper contract. Private-order authorization remains
`counterparty == msg.sender`; the recipient is never an authorization
substitute, so private and NFT fills remain direct-wallet operations in zSwap.

`Orderbol` is the zRouter adapter for this boundary. An ERC-20 route must first
call `checkpoint(token)` through the same immediate executor that later funds
and places the order. The transient, single-use checkpoint accepts exactly the
post-checkpoint increase, after which Orderbol grants and revokes an exact
board allowance. This prevents a later caller from claiming donated or
stranded tokens as escrow for an order they own. Native Swapboard creation is
bound to the exact call value and uses `createOrderWithEthFor`.

For cancellation and routing, Swapboard continues to represent resting native
ETH as canonical WETH. `cancelOrderUnwrap` deletes state before redemption and
checks exact WETH debit and ETH credit. Swapbol wraps only the current native
input consumed by a book leg and unwraps only the current call's WETH output
delta, leaving unrelated pooled WETH and forced ETH outside the route.

Focused routed-ownership regressions are in
`test/SwapboardMakerFor.t.sol` (7 tests) and `test/Orderbol.t.sol`
(5 tests).
