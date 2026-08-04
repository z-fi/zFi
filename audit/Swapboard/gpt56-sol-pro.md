# Swapboard — response to the GPT 5.6 Sol (Pro) audit

Date: 2026-08-01

Auditor: GPT 5.6 Sol (Pro) — "Swapboard.sol security and production-readiness
audit", verdict **NO-GO for immutable Ethereum mainnet deployment**.

Reviewed artifact (the auditor's hash):
`4bddbc5fe51627d438b6e51a3a4d4cbb3531895365d11238f912805c692f6353`

Patched artifact:
`4c32eafa5b84581c5368501deac7c63e7e590f4855a7f014af9130203089bf2e`
(`src/Swapboard.sol`, 1465 lines)

This document records which findings were accepted, what was changed, and where
the response deliberately differs from the recommendation.

## Summary

| ID | Severity | Finding | Verdict | Status |
| --- | --- | --- | --- | --- |
| H-01 | High | A position used as `tokenB` can be redeemed or shrunk before it is delivered | **Valid** | Fixed |
| H-02 | High | A reversible freeze is not a seller commitment, so off-board sales are unsafe | **Valid** | Fixed (different mechanism) |
| M-01 | Medium | ERC-20/ERC-721 selector overlap can lock NFT id 1 in a "fungible" order | **Valid** | Fixed |
| L-01 | Low | ETH attached to a payable ERC-721 method is trapped | **Valid** | Fixed |
| L-02 | Low | "Exact" fungible payments never check the SENDER's debit | **Valid** | Fixed |
| L-03 | Low | Dynamic metadata emits no ERC-4906 signal | **Valid** | **Not fixed — no bytecode left** |
| Obs. 1 | Info | `_checkEscrowable` can revert on a noncanonical ERC-165 boolean | **Valid** | Fixed |
| Obs. 2 | Info | `quoteFillInput` is ambiguous for NFT token id 0 | **Valid** | Documented, not changed |
| Obs. 3 | Info | Comments still describe position destruction | **Valid** | Fixed |
| Obs. 4 | Info | Rebasing/reflection tokens are a solvency exclusion | Valid, already documented | No change |
| — | — | The fixes cost ~1.5 KB and pushed runtime over EIP-170 | **New, found while verifying** | Resolved by dropping L-03; see "Deployability" |

Two of the auditor's High findings are real and were reproduced as tests before
being fixed. Neither is a protocol-wide drain: both are ways for a position
SELLER to hand a counterparty a claim worth less than the one they evaluated.

## H-01 — a position could be spent before it was delivered as payment

**Accepted.** The exploit is exactly as written: an order with
`tokenB = <a live-claim board>` and `amountB = <position id>` pays out its
escrow on nothing more than the id changing hands, and the position's own owner
can empty it — `cancelOrder(P)` then `fillOrder(Q, …, P, …)` in one multicall —
between the buyer's simulation and delivery. Freezing does not stop it
(a frozen order stays cancellable), `minAmountA` protects the wrong party, and
`replaceOrder` gives a partial version that keeps the position "active and
frozen" while emptying it.

The root cause is stated precisely in the audit: **this board can verify that a
token id moved, but not what economic claim was inside it.**

**Fix.** `_checkEscrowable` is now applied to `tokenB` as well as `tokenA`, on
every creation path — `_createOrder`, `_createOrderWithEth`, and
`onERC721Received` — and independently of the caller's `nftB` flag, so the
ERC-20-shaped `transferFrom` route in M-01 cannot slip past it either. Any
token declaring `LIVE_ORDER_POSITION` (`0x28a93a2e`) is refused on both legs.

This drops the "a maker may ask to be paid in a position" feature rather than
adding a state commitment to the order struct. The reasoning: a state hash or
nonce would have to be checked against the position's own board at settlement,
which makes settlement depend on a foreign contract's storage layout — a large
new trust surface on an immutable contract, for a trade that already has a safe
form. Positions still trade through **custody-first** venues (Dutchboard being
the in-repo one): taking the receipt makes the escrow the maker, which removes
the seller's ability to cancel, unfreeze, reprice or partially fill. That is
the same conclusion the audit reaches in its "custody-first integrations"
section.

Regressions: `test/SwapboardPositionProbe.t.sol` —
`test_PositionIsRefusedAsPayment`, `test_PositionIsRefusedAsPaymentForEth`,
`test_PositionIsRefusedAsPaymentOnPush`, `test_SpentPositionCannotBuyEscrow`.
The previous test asserting the opposite (`test_PositionIsStillAcceptableAsPayment`)
was inverted rather than deleted, so the change of intent is visible in history.

## H-02 — a reversible freeze is not a commitment

**Accepted, with a different fix than the one recommended.**

The audit is right that `frozen` was only ever a promise the owner could
withdraw. It blocks fills, repricing and sweeps, but not cancellation, and not
`setFrozen(id, false)` — so a signed listing on a generic ERC-721 marketplace
can be front-run: cancel, keep the transferable receipt, let the buyer's
purchase settle against a spent ticket.

The recommended fix — active-position transfers require `active && frozen`, a
frozen owner cannot cancel, unfreeze, replace or partially fill, and transfer
thaws for the new owner — makes an unsold frozen position permanently
unspendable, which trades a theft risk for a fund-loss risk on an immutable
contract. It also breaks the working custody-first flow, where a position is
deliberately transferred INTO an escrow while frozen and must STAY frozen while
the escrow holds it.

Instead the soft freeze is left exactly as it was, and a second, stronger state
is added beside it:

```solidity
mapping(uint256 orderId => uint64 until) public frozenUntil;
function commitFrozen(uint256 orderId, uint64 until) external;   // owner only
function frozen(uint256 orderId) public view returns (bool);      // soft OR committed
```

While `block.timestamp < frozenUntil[id]` the claim cannot change **by any
path**: no fill, no sweep, no repricing, and — the part a soft freeze never
had — no cancellation, by the owner or anyone else. A commitment only ever
extends, so a buyer who reads it cannot have the window shortened under them.

Three properties make it safe on an immutable contract:

1. **It lapses.** A commitment is a timestamp, not a latch, so nothing is ever
   permanently locked.
2. **It clears on a sale.** Transferring to a DIFFERENT owner deletes it, so
   the buyer receives a position they can act on immediately. A self-transfer
   clears nothing, which closes the obvious bypass.
3. **The early exit costs the sale.** A seller who wants out before the window
   ends can hand the receipt to another address of their own — but then they no
   longer own the token their stale listing sells, so that listing fails
   instead of settling on an emptied claim.

`frozen(id)` keeps the name and signature of the mapping getter it replaces and
now answers the question callers were actually asking (soft freeze OR live
commitment), so routers, `getOrdersWithState`, `isFillableBy` and the quote
functions all account for commitments with no call-site changes.

Marketplace guidance, unchanged by this: a buyer purchasing a position off this
board should require `frozenUntil(id)` to be a timestamp that outlasts the sale. Without that, an ordinary signed ERC-721 listing remains unsafe, and this
is documented at the mapping rather than left implicit.

Regressions: `test/SwapboardAuditGPT.t.sol` —
`test_CommittedPositionCannotBeCancelledOrReduced`,
`test_CommitmentOnlyExtends`, `test_CommitmentClearsOnSaleAndNotOnSelfTransfer`,
`test_CommitmentLapses`, `test_CommittedOrderIsNotSweepable`,
`test_OnlyOwnerCommits`.

## M-01 — an ERC-721 could rest as a fungible order and lock itself

**Accepted.** ERC-20 and ERC-721 share `balanceOf(address)` and
`transferFrom(address,address,uint256)`, and Solady's `safeTransferFrom`
accepts empty return data, so escrowing token id 1 with `nftA = false` passes
the exact-delta check: the board's holdings of that collection rise by exactly
1, which is exactly `amountA`. Every exit from the resulting order then calls
`transfer(address,uint256)`, which no ERC-721 implements. The token is locked
forever; this board has no rescue path.

**Fix.** `_checkFungible` — a bounded ERC-165 probe for `0x80ac58cd` — now runs
on every leg the caller declared fungible, on all three creation paths, and
reverts `ExpectedERC20(token)`. The mirror case (`nft = true` on an ERC-20) was
already safe: `_moveNFT` calls `ownerOf`, which an ERC-20 does not implement.

Typed entry points (`createERC20ForERC721` etc.) were considered and not taken:
four more external functions is a poor trade against a bytecode budget that is
already the binding constraint (see "Deployability"), and the probe rejects the
same deterministic mistake.

This does not make a hostile hybrid token safe. Nothing at this layer can; an
integrator allowlist is still the right control for that.

Regressions: `test_ERC721CannotRestAsAFungibleOrder`,
`test_ERC721CannotBeAskedForAsAFungiblePrice`, `test_DeclaredNFTStillTrades`.

## L-01 — ETH attached to payable receipt methods

**Accepted.** Solady makes the ERC-721 mutators payable for the gas saving, and
the `receive()` WETH-only rule does not apply when calldata selects a payable
function.

**Fix.** `transferFrom` and `approve` are overridden to revert `UnexpectedETH`
on nonzero `msg.value`. One override covers all three transfer entry points:
Solady's safe variants reach the move by calling `transferFrom` in the same
frame, where `msg.value` is unchanged. As the audit notes, this is a value
check and not a reentrancy guard — guarding `transferFrom` with `nonReentrant`
would brick every safe transfer, which is why the existing guard sits only on
the two `safeTransferFrom` overloads.

Regression: `test_PayableReceiptMethodsRefuseETH`.

## L-02 — one-sided measurement of fungible pulls

**Accepted.** Measuring only the credit catches a receiver-tax token but waves
through a sender-tax one, which debits `amount + fee` and credits `amount`. The
payer loses more than the number they authorised through this board's
parameters.

**Fix.** Every fungible pull — creation escrow, escrow-increasing replacement,
and the taker-to-maker payment leg — goes through one `_pullToken` helper that
verifies both the payer's debit and the recipient's credit. The payer is always
`msg.sender`; this board never moves tokens between two third parties.

Cost: one extra `balanceOf` call per fungible pull.

**Error-shape change.** With creation and payment sharing one helper, a short
CREDIT now reports `BalanceMismatch(expected, received)` on both paths, where
the payment path previously reported `BalanceDeltaMismatch`. A sender-side
shortfall is what carries the `BalanceDeltaMismatch(token, payer, …)` form.
`test_FeeOnTransferTokenBIsRejected` in `SwapboardCoverage` was updated to the
new shape; the contract is undeployed, so this breaks nothing on chain.

Regressions: `test_SenderTaxPaymentIsRefused`, `test_SenderTaxEscrowIsRefused`.

## L-03 — no ERC-4906 metadata signal

**Valid, implemented, then deliberately reverted for bytecode.** `tokenURI`
renders maker, active status, remaining amounts, freeze state, expiry and fill
progress — all mutable — with no standard way to tell a cache it went stale.

`MetadataUpdate(uint256)` was emitted from all eight mutating paths and
`supportsInterface` answered `0x49064906`. Measured, that cost **567 B** of
runtime code — and the security fixes had already put the contract over
EIP-170 (see "Deployability"). Funnelling every emit through one internal
function recovered only 73 B of it; the cost is per call site, not per event
definition.

Given a choice between the ERC-4906 signal and the H-02 commitment (578 B),
the commitment stays. The metadata is still correct on read — `tokenURI`
always renders live state — so the residual risk is a marketplace or wallet
showing a stale cached image, which is a display defect rather than a
settlement one, and one an indexer can already avoid by watching
`OrderFilled` / `OrderPartiallyFilled` / `OrderReplaced` / `OrderFreezeSet` /
`OrderCommitmentSet` / `OrderCanceled` / `OrderExpiredSwept` / `Transfer`.

This is the finding to revisit first if the contract ever gains headroom.

The `committed(uint256)` convenience view was dropped for the same reason
(64 B). Read `frozenUntil(orderId)` and compare it to the block timestamp;
`frozen(orderId)` already folds the commitment in.

## Observation 1 — malformed ERC-165 responses

**Accepted.** `abi.decode(ret, (bool))` reverts on a noncanonical 32-byte
boolean, which turned "malformed answer" into "order refused" — the opposite of
the documented leniency.

**Fix.** `_declares` reads the return word directly in assembly and treats only
a clean `1` as affirmative. Regression: `test_MalformedERC165IsInert`.

## Observation 2 — `quoteFillInput` and NFT token id 0

**Valid; documented rather than changed.** For an NFT-sided order the function
returns `amountB`, which is a token id, and id 0 is indistinguishable from the
"no valid quote" zero. Adding a validity boolean or a second quote function
would change a signature that `SwapboardView`, the router planner and the dapp
all consume, for a case a caller can already resolve with one read: `getOrders`
reports `nftA`/`nftB`, and any NFT-sided order settles at exactly one price.
The natspec now says so explicitly.

## Observation 3 — comments describing position destruction

**Accepted.** The live-claim comments said a fill causes the held position to
cease to exist; the implementation deliberately preserves it as a spent ticket
(so a contract holding it is never left pointing at a nonexistent token). The
comments now describe the spent ticket, which is the distinction the whole
live-claim guard turns on.

## Observation 4 — rebasing and reflection tokens

**No change.** Already documented as unsupported at the contract level, for the
reason the audit gives: escrow is pooled by token address, so a negative rebase
can put the board's balance below the sum of its liabilities. Enforcement
belongs in an integrator allowlist; there is no on-chain form of it that does
not also break ordinary tokens.

## Deployability

The audit asks for measured sizes, and measuring them turned out to be the
binding constraint on which fixes could ship.

Swapboard is pinned to `max_optimizer_runs = 20` in `foundry.toml` precisely
because it sits near EIP-170's 24,576-byte runtime cap. With every fix above
applied, including ERC-4906, it measured **25,106 B — 530 B over**. The fixes
cost roughly 1.5 KB in total:

| Change | Runtime cost (B) |
| --- | ---: |
| H-02 commitment (`frozenUntil`, `commitFrozen`, checks, transfer-clear) | 578 |
| L-03 ERC-4906 emits + interface id | 567 |
| M-01 `_checkFungible` call sites | 190 |
| L-02 sender-debit checks | 84 |
| `committed()` view | 64 |
| L-01 payable ETH guards | 24 |

Dropping L-03 and `committed()` brings it to:

| Artifact | Runtime (B) | Margin to EIP-170 | Initcode (B) |
| --- | ---: | ---: | ---: |
| `Swapboard` @ `via_ir`, `optimizer_runs = 20` | 24,486 | **+90** | 30,928 |
| `SwapboardMetadata` | 6,059 | +18,517 | 6,085 |

EIP-3860's 49,152-byte initcode cap is not close to binding, even though the
constructor carries the renderer's creation code.

Two cautions for whoever ships this:

- **90 B is not real headroom.** By this repository's own standard — see the
  `TokenList` note in `foundry.toml`, where ~140 B was judged too thin for an
  immutable contract that must retain room for a security fix — the next change
  here will not fit. The durable answer is the one `TokenList` took: split the
  read surface (`getOrders`, `getOrdersWithState`, `isFillableBy`,
  `areFillableBy`, `quoteFill`, `quoteFillInput`) out into a reader contract,
  which measures ~1.6 KB and has no in-repo caller on the board itself.
- **Size is not monotonic at this optimizer setting.** Merging
  `_checkEscrowable` and `_checkFungible` into one helper — strictly less
  source, one fewer call per leg — measured **829 B LARGER** and was reverted.
  Any edit here must be re-measured rather than reasoned about.

`foundry.toml` was rewritten by concurrent work partway through this pass
(`via_ir = false`, `optimizer_runs = 200`, all per-file compilation
restrictions removed). Every size number above is against the previous, pinned
configuration (`via_ir = true`, `optimizer_runs = 20` for this file), measured
in an isolated project with only `Swapboard.sol`, `PositionSVG.sol`,
`SwapboardMetadata.sol` and Solady. **Re-measure against whatever config
actually ships.** The tree does not currently compile as a whole under the
rewritten config (`src/utils/DutchboardMetadata.sol` hits stack-too-deep
without `via_ir`), which is unrelated to this work.

## Points where this response differs from the audit

- **H-01** is closed by refusing the trade rather than by adding a position
  state commitment. Binding an order to a foreign board's internal state is a
  larger and more fragile surface than the feature is worth, and custody-first
  venues already provide the safe version of it.
- **H-02** is closed with a lapsing, sale-clearing commitment rather than by
  making transfers require `active && frozen` and forbidding a frozen owner
  from cancelling. The recommended form creates a permanent-lock hazard on an
  immutable contract and breaks the escrow flow that is already correct.
- **M-01** uses an ERC-165 probe rather than typed entry points, for bytecode
  budget reasons.
- **Observation 2** is documented rather than fixed, to avoid a breaking
  signature change for an ambiguity a caller can already resolve.
- **L-03** is acknowledged and left unfixed. It is the only finding in this
  audit that is not closed, and the reason is bytecode budget, not disagreement.

## Verification

Toolchain: solc 0.8.36, `via_ir`, optimizer on. Swapboard-related suites pass:

```
SwapboardAuditGPT        13/13   (new — H-02, M-01, L-01, L-02 regressions)
SwapboardPositionProbe    8/8    (H-01)
Swapboard                44/44
SwapboardCoverage        45/45
SwapboardAudit           19/19
SwapboardReplace         22/22
SwapboardPlan            25/25
SwapboardView (V2)       26/26
SwapboardPosition        11/11
BoardEscrowAudit         11/11
PositionAuctionHazard     2/2
DutchboardPosition        6/6
```

Unrelated failures in the same run, present independently of this change and
left alone: `SwapboardViewLegacy` and four `*Fork*` tests (archive-RPC
timeouts), and `OrderbolTest` (four `ApproveFailed()` failures from unrelated
in-flight work on `src/forwarders/Orderbol.sol`).

Not re-verified here, and still open from the audit's production checklist: a
pinned compiler binary with a recorded hash, a mainnet-fork deployment
rehearsal of the exact build, and the hostile-mock matrix beyond the mocks
already in `test/SwapboardMocks.sol`.
