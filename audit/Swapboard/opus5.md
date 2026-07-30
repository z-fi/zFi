# 🔐 Security Review — Swapboard

_Performed by **Claude Opus 5** (`claude-opus-5[1m]`) at **max reasoning effort**, running as an interactive agent in Claude Code. Manual line-by-line review of the full contract and its dependencies (Solady `Multicallable`, `ReentrancyGuardTransient`, `SafeTransferLib`), with every reported finding reproduced as a failing Foundry test against the pre-fix contract before any patch was written, and re-run after. Single-agent review — no fan-out, no confidence heuristics: a finding is here because an exploit test passed._

> **Post-review note:** a later independent pass added exact outbound ERC-20
> and WETH delta checks, a strict already-returned-NFT preflight, and a
> nonpayable constructor. Its current-tree findings and verification metrics
> supersede this report's final bytecode/gas/test counts; see
> [`codex.md`](codex.md).

---

## Scope

|                        |                                                                             |
| ---------------------- | --------------------------------------------------------------------------- |
| **File reviewed**      | `src/Swapboard.sol` (629 lines at review, 687 after; 766 in the current tree) |
| **Base commit**        | `4216153` — "zQuoter repoint, Swapboard extension, zSwap v0.2 payload"       |
| **Deployment status**  | **Not deployed.** The live boards are `0x000000fF…DbecF` (v1) and `0x00000000CC…B831` (v2, 5-arg `createOrder`). This 9-arg extension has never been deployed, so all fixes — including an error rename — are non-breaking. |
| **Dependencies read**  | Solady `Multicallable`, `ReentrancyGuardTransient`, `SafeTransferLib`, `FixedPointMathLib` |
| **Downstream checked** | `src/SwapboardView.sol` (`ISwapboardV2.Order` layout), `dapp/orderbook/index.html` |
| **Toolchain**          | solc 0.8.36, `via_ir`, optimizer 9,999,999 runs                              |
| **Review date**        | 2026-07-30                                                                   |

**Method.** Every finding below was first written as a test asserting the *vulnerable* behaviour and run against the unmodified contract. Six exploits passed. The fixes were then applied and the same tests re-run inverted, as regressions. Two further scenarios I hypothesised (an operator-approval variant of #1, and a stranded-NFT variant of #5) did **not** reproduce and were dropped rather than reported.

---

## Summary

| #   | Finding                                                              | Severity      | Status  |
| --- | -------------------------------------------------------------------- | ------------- | ------- |
| 1   | Escrow custody confirmed only at the destination — steals a third party's escrowed NFT | **High**      | Fixed   |
| 2   | NFT payment leg (`nftB`) settles without confirmation — drains the maker's escrow for free | **High**      | Fixed   |
| 3   | ERC-20 marked `nftB` returns `false` through a no-return interface    | **Medium**    | Fixed   |
| 4   | NFT payout leg (`nftA`) settles without confirmation — taker pays, receives nothing | **Medium**    | Fixed   |
| 5   | Cancel/sweep return leg unconfirmed — silently discards the maker's claim | **Medium**    | Fixed   |
| 6   | Short bid on an NFT order billed at the full ask                      | **Medium**    | Fixed   |
| —   | Nine further observations reviewed and deliberately not changed       | Informational | See below |

The root cause of findings 1–5 is one design gap. The contract had already adopted the right threat model — its `NFTEscrowFailed` check and its `LyingERC721` test mock both exist because `transferFrom` returns nothing and a non-standard ERC-721 can no-op instead of reverting — but applied that defence to exactly one of the five legs an NFT travels, and applied it in a form that answers the wrong question.

---

## Findings

### [High] 1. Escrow custody was confirmed only at the destination, letting one maker's order be backed by another maker's escrowed NFT

`Swapboard._createOrder` · Fixed in `_moveNFT`

**Description**

Escrow confirmation read:

```solidity
IERC721(tokenA).transferFrom(msg.sender, address(this), amountA);
if (IERC721(tokenA).ownerOf(amountA) != address(this)) revert NFTEscrowFailed(tokenA, amountA);
```

That answers *"does the board hold this NFT?"* — not *"did this maker's transfer put it there?"* The two questions differ whenever the board **already** held the token, which is the normal state for any NFT resting in the book.

Against a collection whose `transferFrom` returns quietly on an unauthorised transfer instead of reverting — an `if` where ERC-721 requires a `require`, a bug real collections have shipped — an attacker who has never owned the token can create an order naming it. The transfer does nothing, the destination check passes because the victim's escrow is sitting right there, and the order is created backed by somebody else's asset. The attacker then calls `cancelOrder`, at which point the board — the legitimate owner — transfers the NFT to them.

No privilege, no timing, no capital required. The victim's order stays live and "active", backed by nothing.

**Proof of concept** — `test_E1_stealEscrowedNft`, passing against the pre-fix contract:

```solidity
// victim lists NFT #1 legitimately; the board now holds it
vm.startPrank(maker);
n.setApprovalForAll(address(sb), true);
sb.createOrder(address(n), 1, address(B), 500e6, false, 0, true, false, address(0));
vm.stopPrank();
assertEq(n.ownerOf(1), address(sb));

vm.startPrank(attacker);                        // never owned token 1
uint256 id2 = sb.createOrder(address(n), 1, address(B), 1, false, 0, true, false, address(0));
sb.cancelOrder(id2);
vm.stopPrank();

assertEq(n.ownerOf(1), attacker);               // ← passes: victim's NFT taken
```

**Impact**

Total loss of any NFT escrowed on the board from a collection with this flaw, to any caller, at will.

**Remediation**

`_moveNFT` now confirms both ends, and the *source* check is the load-bearing one — it is what makes the destination check mean something:

```solidity
function _moveNFT(address token, address from, address to, uint256 tokenId) internal {
    if (IERC721(token).ownerOf(tokenId) != from) revert NFTTransferFailed(token, tokenId);
    IERC721(token).transferFrom(from, to, tokenId);
    if (IERC721(token).ownerOf(tokenId) != to) revert NFTTransferFailed(token, tokenId);
}
```

The source check removes no legitimate flow: `transferFrom(from, …)` on any conforming ERC-721 already requires `from == ownerOf(tokenId)`, so anything the new check rejects would have reverted inside the token anyway.

> **Response:** Fixed. This is the finding that reframed the rest of the review. The original check was not weak, it was aimed at the wrong question — "is the board holding it" is trivially satisfiable by an attacker precisely *because* the contract works, i.e. because other people's NFTs are already in escrow. Every subsequent NFT leg was then re-derived from "prove the transfer happened" rather than "prove the token is somewhere plausible". Regression: `test_CannotEscrowAnNftTheBoardAlreadyHolds`.

---

### [High] 2. The NFT payment leg settled without confirmation, letting a taker take the whole escrow without paying

`Swapboard._fill` · Fixed in `_moveNFT`

**Description**

The `nftB` leg is where the maker actually gets paid, and it took the token's word for it:

```solidity
if (nftB) IERC721(tokenB).transferFrom(msg.sender, maker, fillAmountB);
```

`IERC721.transferFrom` is declared with no return value, so the compiler emits no return-data decoding and no shape validation. A collection that no-ops is indistinguishable from one that settled — and settlement continues to the next line, which releases the maker's entire escrow to the taker.

This is the mirror image of the check the contract already performed on the escrow leg, on the side where the money actually moves.

**Proof of concept** — `test_E3_nftPaymentNeverArrives` (using `LyingERC721`, already present in the repo's own mocks) and `test_E3b_nftPaymentFromNonOwner`, both passing pre-fix:

```solidity
LyingERC721 bad = new LyingERC721();
bad.mint(taker, 5);
vm.prank(maker);
uint256 id = sb.createOrder(address(A), 100e18, address(bad), 5, false, 0, false, true, address(0));

vm.prank(taker);
sb.fillOrder(id, 0, 0, address(0));

assertEq(A.balanceOf(taker), 100e18);           // ← passes: escrow taken for free
assertEq(bad.ownerOf(5), taker);                //   and the NFT never left
```

The `E3b` variant is worse: a taker who owns no NFT at all drains an `nftB` order, because a sloppy collection no-ops rather than reverting on a transfer from a non-owner.

**Impact**

Total loss of the maker's escrow on any order priced in a collection with this flaw.

**Remediation**

The leg now routes through `_moveNFT(tokenB, msg.sender, maker, fillAmountB)`, which requires the taker to hold the NFT going in and the maker to hold it coming out.

> **Response:** Fixed. The asymmetry here was the tell — the contract defended the maker against a lying collection on the leg where the maker *deposits*, and trusted the same class of collection on the leg where the maker *gets paid*. Regressions: `test_NftPaymentThatNeverArrivesIsCaught`, `test_NftPaymentFromANonOwnerIsCaught`.

---

### [Medium] 3. An ERC-20 marked as `nftB` reports failure by returning `false`, which a no-return interface reads as success

`Swapboard._fill` · Fixed by the same `_moveNFT` change

**Description**

A sub-case of #2 with a materially different precondition: it needs no exotic NFT, only a maker who ticks the NFT box on a fungible token.

ERC-721 `transferFrom` and ERC-20 `transferFrom` share the selector `0x23b872dd`. Setting `nftB = true` on a plain ERC-20 therefore routes the payment through `IERC721`, which declares no return value — so an ERC-20 that reports failure by returning `false` rather than reverting (the pre-0.8 convention, still shipped by tokens in use) is read as a successful payment. `SafeTransferLib`, which exists precisely to catch this, is bypassed by the `nftB` branch.

Nothing in `_createOrder` rejects the configuration: `tokenB.code.length` passes, and the `ZeroAmount` check is deliberately skipped for a side marked as an NFT.

**Proof of concept** — `test_E3c_softFailErc20AsNftB`, passing pre-fix. A taker with **no balance and no allowance** fills the order and receives the full escrow; the maker is paid nothing.

**Impact**

Total loss of escrow on a misconfigured order. Reachable through ordinary UI or integration error rather than through a hostile token.

**Remediation**

`_moveNFT` calls `ownerOf` on `tokenB`. An ERC-20 has no `ownerOf`, so the misconfiguration now fails closed at fill time instead of settling.

> **Response:** Fixed, and worth stating explicitly because the fix is a happy side effect rather than the intent: the confirmation added for #2 also makes `nftB` self-validating. Any token that cannot answer `ownerOf` cannot be used as an NFT side. Regression: `test_Erc20MarkedAsAnNftCannotSilentlyFailToPay`.

---

### [Medium] 4. The NFT payout leg settled without confirmation, so a taker could pay and receive nothing

`Swapboard._fill` · Fixed in `_moveNFT`

**Description**

```solidity
if (nftA) IERC721(tokenA).transferFrom(address(this), to, outA);
```

Escrow was confirmed at creation, but the board's custody is not guaranteed to survive until the fill. ERC-721 requires a transfer to clear the per-token approval; collections have shipped without it. A maker who calls `approve(x, tokenId)` before listing leaves `x` able to lift the NFT out of escrow while the order stays live. The taker's payment has already moved to the maker by the time the payout leg runs, so a silent no-op charges them in full for nothing.

**Proof of concept** — `test_E2_takerPaysForNothing`, passing pre-fix:

```solidity
vm.startPrank(maker);
n.approve(maker, 3);                             // sticky: survives the transfer into escrow
n.setApprovalForAll(address(sb), true);
uint256 id = sb.createOrder(address(n), 3, address(B), 500e6, false, 0, true, false, address(0));
n.transferFrom(address(sb), maker, 3);           // reclaimed; order still active
vm.stopPrank();

vm.prank(taker);
sb.fillOrder(id, 0, 0, address(0));

assertEq(held - B.balanceOf(taker), 500e6);      // ← passes: taker paid
assertEq(n.ownerOf(3), maker);                   //   and got nothing
```

**Impact**

Loss of the taker's full payment. Requires a collection with a non-clearing approval and a maker who exploits it, so it is a maker-vs-taker attack rather than an open one — but it needs no cooperation from the taker beyond filling a normal-looking listing.

**Remediation**

Routed through `_moveNFT(tokenA, address(this), to, outA)`. The source check proves the board still holds what it is selling; the destination check proves the taker received it.

> **Response:** Fixed. Both ends earn their keep on this leg specifically: the source check catches the escrow having gone missing, and the destination check catches a payout that no-ops into a recipient who does not end up with the token. Regression: `test_FillRevertsWhenEscrowedNftNoLongerMoves`.

---

### [Medium] 5. The cancel and sweep return legs closed the order whether or not the escrow came back

`Swapboard._cancel`, `cancelExpired`, `trySweepExpired` · Fixed in `_returnNFT` / `_returnEscrow`

**Description**

All three return paths set `active = false`, zeroed both amounts, then fired an unconfirmed `transferFrom`. If the transfer did nothing, the order was closed anyway — destroying the only on-chain record of the maker's claim on an escrow the board no longer had.

This is the one leg where the *source* must **not** be checked. An NFT that has already found its way back to the maker is a settled order, not a failure, and refusing it would leave the maker permanently unable to close a dead listing.

**Proof of concept** — `test_E2b_cancelDestroysTheClaim`, passing pre-fix. A third party lifts the escrow out via a sticky approval; the maker's `cancelOrder` no-ops and closes the order regardless, leaving `active == false` and nothing returned.

**Impact**

Irrecoverable loss of the maker's claim. Not a transfer of value to an attacker, but the maker's only recourse is deleted by their own cancel.

**Remediation**

A separate helper for the return leg, checking the destination only:

```solidity
function _returnNFT(address token, address to, uint256 tokenId) internal {
    IERC721(token).transferFrom(address(this), to, tokenId);
    if (IERC721(token).ownerOf(tokenId) != to) revert NFTTransferFailed(token, tokenId);
}
```

A return that does not arrive now reverts, leaving the order live. A return that was already home still closes cleanly.

The three duplicated settlement bodies were also consolidated into one `_returnEscrow`, so cancel and both sweeps cannot drift apart. **This makes `trySweepExpired` stricter by design:** it skips *stale* entries — already settled, not yet expired, never created, which is what a keeper's list actually goes stale with — but a settlement that reverts still aborts the batch. A sweep that quietly closed an order it could not pay out would discard the very claim it exists to protect. This is not a behaviour change in kind: a collection whose `transferFrom` reverts already aborted the batch.

> **Response:** Fixed. The asymmetry between `_moveNFT` and `_returnNFT` is deliberate and is the subtlest judgement call in the patch: checking the source on the return leg would have been "more defensive" and strictly worse, stranding makers with uncancellable listings. Both halves are pinned by tests — `test_CancelRevertsRatherThanDiscardingTheClaim` and `test_CancelClosesWhenTheNftIsAlreadyHome`.

---

### [Medium] 6. A short bid on an NFT order was billed at the full ask

`Swapboard._fill` · Fixed

**Description**

An NFT order settles all-or-nothing, so `_fill` rewrites a short `fillAmountB` up to the whole `amountB`:

```solidity
if (nftA || nftB || fillAmountB == 0 || fillAmountB >= amountB) {
    (outA, fillAmountB, full) = (amountA, amountB, true);
}
```

The contract already recognised this hazard twice. `fillOrderWithEth` refuses an underpayment outright, with a five-line comment explaining that the rewrite would otherwise settle out of other makers' escrow. The `nftB` branch requires an exact match because a tokenId comparison is meaningless. But an `nftA` order priced in an ERC-20 had neither guard: `amountB` there is a genuine price, and `fillAmountB` — which bounds the spend on every other path in the contract, clamping an overbid and reverting a short bid with `PartialFillNotAllowed` — was silently ignored.

A taker bidding 1 unit on a 1,000 USDC listing was charged 1,000 USDC. Unlike findings 1–5 this needs no non-standard token: it reproduces on a textbook ERC-721.

**Proof of concept** — `test_E4_shortNftBidBilledInFull`, passing pre-fix:

```solidity
uint256 id = sb.createOrder(address(n), 7, address(B), 1000e6, false, 0, true, false, address(0));
vm.prank(taker);
sb.fillOrder(id, 0, 1, address(0));              // offers 1 unit
assertEq(held - B.balanceOf(taker), 1000e6);     // ← passes: bid 1, charged 1000e6
```

**Impact**

A taker — most plausibly a router or aggregator computing `fillAmountB` from a quote — spends up to their full allowance rather than the amount they specified. Bounded by the listed price and by allowance, and the NFT is delivered, so this is a broken spend-bound rather than theft.

**Remediation**

```solidity
if (fillAmountB != 0) {
    if (nftB && fillAmountB != amountB) revert PartialFillNotAllowed(orderId);
    if (nftA && fillAmountB < amountB) revert PartialFillNotAllowed(orderId);
}
```

An overbid still clamps to the ask, as it does for any order; the `0` sentinel still means "fill it". Only the silent overcharge is removed.

> **Response:** Fixed. Notable because the contract had already written down the reasoning for this exact hazard on the ETH path and simply had not carried it across to the ERC-20 leg — the comment in `fillOrderWithEth` describes the bug that was live one function away. Regressions: `test_ShortBidOnAnNftOrderIsRefusedNotBilledInFull`, `test_NftOrderStillTakesTheSentinelAndAnOverbid`.

---

## Reviewed and deliberately not changed

_Examined, understood, and left alone. Listed so the reasoning is on the record rather than rediscovered._

- **`tokenB` is not measured for fee-on-transfer** — `tokenA` is measured on the way in and a skimming token is refused at creation; `tokenB` goes straight from taker to maker and never touches the board's books, so a skim pays the maker less than `amountB`.

  > **Response:** Documented in the contract header rather than enforced. Measuring would cost two balance reads on every fill — including the all-ERC-20 path, which is the hot one — and would *refuse* such tokens outright rather than merely disclosing them, which is worse UX for no gain to the board. Pricing an order in a fee-on-transfer token prices in its fee.

- **`fillOrderWithEth` refuses an overpayment rather than refunding it** — an observer can front-run any ETH fill of a partial order with a 1-wei fill, shrinking `amountB` so the victim's `msg.value > owed` and their transaction reverts.

  > **Response:** Acknowledged, by design. The failure mode is a revert, not a loss, and the alternative introduces a second ETH-send path for a griefing vector that costs the griefer gas and a real fill. Documented in the existing NatSpec ("refused rather than refunded").

- **`tryFillOrders` still aborts on `ZeroFillAmount`, `PartialFillNotAllowed`, and any token revert** — only inactive, missing, expired and wrong-counterparty entries are skipped.

  > **Response:** By design and now documented on both `try*` functions. "Try" means tolerant of a list that went stale between reading and mining, not tolerant of a caller error or a broken token. Silently skipping a fill the taker asked for would be worse.

- **`SameToken` is bypassed whenever either NFT flag is set** (`tokenA == tokenB && !(nftA || nftB)`).

  > **Response:** Intentional — it is what permits a same-collection NFT⇄NFT swap. All four flag combinations were traced: each either settles correctly or reverts inside the token. The one that previously mattered (`nftB` on an ERC-20 at the same address) is closed by finding #3.

- **An ERC-721 escrowed as a *fungible* side with `amountA == 1` is permanently stuck** — the selector collision lets `safeTransferFrom` escrow tokenId 1, `balanceOf` returns 1, the delta check passes, and every exit path then calls `transfer(address,uint256)`, which no ERC-721 implements.

  > **Response:** Acknowledged, not patched. Requires `amountA` to be exactly 1 against an NFT contract with the NFT box unticked. Any defence — an ERC-165 probe on every creation — costs gas on all orders, is lie-able, and guards a pure misconfiguration.

- **Donated tokens or ETH are unrecoverable.** The board is ownerless and immutable; every payout is bound to a specific order.

  > **Response:** By design. A sweep function is the standard way this class of contract gets drained. `_to` already rejects the board and WETH as recipients for the two ways a *payout* could be stranded, which is the reachable case.

- **A fully malicious `tokenA` (lying `balanceOf`, no-op `transfer`) defeats the escrow accounting.**

  > **Response:** Out of reach of any board-level check, and identical to every open marketplace. The NFT confirmations added above raise the bar for *sloppy* collections, not for actively hostile ones.

- **Private orders cannot be routed.** `counterparty` is checked against `msg.sender`, never against `recipient`.

  > **Response:** Load-bearing, and already documented. A caller-supplied recipient used for authorisation would let anyone name the intended counterparty and drain every private order. Verified still correct after the patch; `test_RecipientCannotBypassPrivateOrder` covers it.

- **Solady's guard falls back to `SSTORE` off mainnet** (`_useTransientReentrancyGuardOnlyOnMainnet` returns `true`), costing roughly 5k extra gas per call on L2s.

  > **Response:** Left at the library default. Overriding it to `false` is safe on any chain with `TSTORE` and would be worth doing for an L2 deployment, but this board is mainnet-targeted and the default is the conservative choice. The guard's slot (`0x8000000000ab143c06`) was checked against the contract's own layout — no collision.

---

## Verified sound

_Attacked and held. Recorded so a future reviewer knows what has already been walked._

- **ETH/WETH conservation on `fillOrderWithEth`** — the historical bug class in this contract. Every branch traced by hand (`msg.value == owed`, `msg.value < owed` with `partialFill`, `nftA`, `nftB`, zero value, inactive and non-existent orders), then fuzzed: **20,000 runs** asserting that either the call reverts or the maker is paid *exactly* `msg.value` with unrelated parked escrow untouched.
- **Partial-fill conservation** — fuzzed over random `amountA`, `amountB` and six-deep fill sequences, **20,000 runs**: the board never releases more `tokenA` than was escrowed, the maker is credited exactly what takers paid, a live order is always backed on both sides, the resting remainder is never priced worse than the posted ask, and a fully settled order delivers the whole escrow for the whole ask.
- **Zombie orders are impossible** — a partial fill cannot zero `amountA` while leaving the order active, since `outA = floor(f·A/B) < A` strictly whenever `f < B`.
- **Reentrancy** — every state-mutating entry point is `nonReentrant`; storage is written before every external call, so there is no read-only reentrancy window either; `multicall` delegatecalls only into guarded functions and the transient guard clears between sub-calls.
- **`multicall`** — Solady's implementation reverts on non-zero `msg.value`, so the payable paths cannot double-spend value. An empty-calldata sub-call lands in `receive()` and reverts `NotWETH`. `msg.sender` is preserved, so no caller can be forged.
- **No stuck ETH** — `receive()` is restricted to WETH, and every `withdraw` is immediately forwarded in full.
- **Storage layout unchanged** — slot 0 is still exactly 256 bits (`maker` 160 + 3 bools + `uint64` expiry + 1 bool), and `Order` is untouched, so `SwapboardView`'s `ISwapboardV2` interface still matches.

---

## Verification

All figures in this table were measured **at review time against base commit
`4216153`**. They are a record of what this pass did, not a description of the
current tree — see "Current tree" below for today's numbers.

| |Before|After (at review)|
|---|---|---|
| Tests passing (Swapboard suites) | 84 | **98** |
| New regression tests | — | 12 (`SwapboardAudit.t.sol`) |
| New fuzz invariants | — | 2 (`SwapboardFuzz.t.sol`), 20,000 runs each |
| Exploits reproduced pre-fix | 7 | 0 |
| Deployed bytecode | 18,125 B | **17,284 B** (margin 6,451 → 7,292) |

`SwapboardView` suites re-run green.

**Current tree (measured 2026-07-30, after the later independent pass and a
subsequent re-audit).** These supersede the table above:

| | |
|---|---|
| Tests passing, `Swapboard*` excluding the lens | **150** (10 suites) |
| `SwapboardView` suites | **32** — 30 offline + 2 mainnet-fork |
| Deployed (runtime) bytecode | **16,899 B** (EIP-170 margin **7,677**) |
| Creation code, incl. constructor arg | **17,172 B** |
| initCodeHash | `0x1a1434e24c36f26cb418661ae233e0c3f3837e592c0c05383fd7169bbece2595` |

The runtime figure is 385 B below the 17,284 B recorded at review. The
initCodeHash reproduces byte-identically across a `forge clean` + rebuild, which
is what makes a mined CREATE2 salt safe to bind to it.

**Gas.** The confirmations cost roughly 1,300–1,700 per NFT leg — one or two `ownerOf` staticcalls against an already-warm address. ERC-20 paths are unchanged within noise: `+416` on a full fill (+0.2%), `+134` on a partial fill (+0.05%). Consolidating the three settlement bodies into `_returnEscrow` more than paid for the new code: the contract is **841 bytes smaller** than before the audit.

New mocks, in `test/SwapboardMocks.sol`:

- `SloppyERC721` — returns quietly on an unauthorised transfer, and never clears the per-token approval. Both are bugs real collections have shipped.
- `SoftFailERC20` — reports failure by returning `false` instead of reverting.

---

> ⚠️ This review was performed by an AI model (Claude Opus 5) and, while every finding here is backed by a reproduced exploit, AI analysis can never establish the absence of vulnerabilities. Findings 1–5 all trace to one blind spot; the existence of a single such blind spot is evidence that others may remain. An independent human review, a bug bounty, and on-chain monitoring remain warranted before deployment — particularly given this contract is immutable, ownerless, and holds user escrow with no recovery path.

---

## Subsequent routed-creation addendum

The current tree extends the reviewed contract with funded
`createOrderFor` and `createOrderWithEthFor` entry points. Their caller supplies
the entire escrow; the explicit maker receives proceeds, cancellation rights,
and returned escrow but is never debited. This is intentionally a funded gift,
so it does not need a maker signature or nonce. Integrators must not treat the
maker field as evidence of off-chain intent: another address can sponsor an
unrequested order, but cannot make the named maker pay for it.

Both ordinary and sponsored paths share internal creation logic and the same
maker guard. The board and WETH wrapper are rejected as makers and recipients,
closing unrecoverable self-payout configurations. `Orderbol` composes the
funded paths with zRouter by consuming a same-caller, transient ERC-20 balance
checkpoint and using exact, revoked allowances; pre-existing donations cannot
become a later caller's order. Native creation uses the exact call value.

Private fills still authorize `msg.sender`, not a delivery recipient. zSwap
therefore routes public fungible fills but keeps private orders and NFTs on the
direct-wallet path. This addendum describes later integration work and does
not alter the historical measurements above.
