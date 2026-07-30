# 🔐 Security Review — Swapbol

_Performed by **Claude Opus 5** (`claude-opus-5[1m]`) at **max reasoning effort**, running as an interactive agent in Claude Code. Line-by-line review of the forwarder, its eleven sibling forwarders, `zRouter.snwap`, and `SafeExecutor`, with every reported finding reproduced as a passing exploit test against the pre-fix contract before any patch was written. Single-agent review — no fan-out, no confidence scores: a finding is here because an exploit test passed._

---

## Scope

|                        |                                                                             |
| ---------------------- | --------------------------------------------------------------------------- |
| **File reviewed**      | `src/forwarders/Swapbol.sol` (136 lines at review, 185 after)                |
| **Deployment status**  | **Not deployed.** Untracked working-tree file; no address reference anywhere in the repo, dapp, or worker. |
| **Read for context**   | `zRouter.snwap` / `snwapMulti` / `SafeExecutor`, `src/Swapboard.sol`, and all 11 sibling forwarders (`Matcha`, `OneInch`, `Parasol`, `Kyberol`, `Odosol`, `OKXol`, `Ensol`, `Bitgetol`, `OpenOceanol`, `Bebop`, `Cowol`) |
| **Prior art applied**  | `audit/zRouter/zellic.md` #1 "ETH value not bound to actions"; `Cowol`'s own note on third parties driving a forwarder through the public `SafeExecutor` |
| **Toolchain**          | solc 0.8.36, `via_ir`, optimizer 9,999,999 runs; tests on a pinned mainnet fork (block 24,880,000) |
| **Review date**        | 2026-07-30                                                                   |

**Method.** The eleven siblings are the specification. Swapbol is a near-copy of `Matcha` with three deliberate edits, so the review reduced to: which edits are improvements, which are regressions, and what does the family invariant depend on that this file breaks. Five exploits were written and confirmed passing against the unmodified contract, then inverted into regressions.

---

## Summary

| #   | Finding                                                             | Severity      | Status |
| --- | ------------------------------------------------------------------- | ------------- | ------ |
| 1   | Unbounded, permanent ERC-20 approval granted to a caller-supplied address | **High**      | Fixed  |
| 2   | `fill` is re-entrant and sweeps to a caller-supplied recipient        | **High**      | Fixed  |
| 3   | Unspent ETH is never swept on an ETH-in / token-out route             | **Medium**    | Fixed  |
| 4   | Call value is the whole balance rather than `msg.value`               | **Medium**    | Fixed  |
| 5   | The repo's own Swapbol suite was red, for a real reason               | Informational | Fixed  |
| —   | Seven observations reviewed and deliberately not changed              | Informational | Below  |

Findings 1 and 2 are **independent paths to the same theft**: taking a user's unspent input out of the forwarder mid-settlement, in a way `snwap`'s `amountOutMin` check structurally cannot detect. Neither fix closes the other's path.

The single structural cause is that Swapbol took the approval spender from calldata. Every sibling hardcodes it:

```solidity
// Matcha.sol — and OneInch, Parasol, Kyberol, Odosol, OKXol, Ensol, Bitgetol, OpenOceanol, Bebop
address constant AH = 0x0000000000001fF3684f28c67538d4D072C22734; // AllowanceHolder
...
} else if (allowance(tokenIn, address(this), AH) == 0) {
    safeApprove(tokenIn, AH, type(uint256).max);
}

// Swapbol.sol — `board` is a function parameter
} else if (allowance(tokenIn, address(this), board) == 0) {
    safeApprove(tokenIn, board, type(uint256).max);
}
```

The lazy-infinite-approval pattern is safe for the siblings *only* because the spender is a known constant. Copying it while making the spender caller-controlled inverts what it means.

---

## Findings

### [High] 1. `fill` grants an unbounded, permanent ERC-20 approval to any address the caller names

`Swapbol.fill` · Fixed

**Description**

`fill` is `public` and unpermissioned. The first time it is called for a given `(tokenIn, board)` pair it grants `board` an infinite approval on `tokenIn` from the forwarder's own balance, and never revokes it. Because `board` is a parameter, anybody can call `fill` once with a `board` they control — an EOA is sufficient, no contract needed — and walk away holding a permanent, unbounded claim on whatever that token balance of the forwarder ever becomes.

That converts a stateless pass-through into a standing capability store. The forwarder's own NatSpec asserted the opposite ("Holds no state and no balances between calls"), and `zRouter`'s comment on `SafeExecutor` — *"has no token approvals, safe for arbitrary external calls"* — is the invariant the whole snwap design rests on. Swapbol accumulated exactly the thing that comment rules out.

`Cowol` is the in-repo precedent that this is a known hazard: it is the one sibling that holds tokens across a call boundary, and its header says so explicitly — *"To prevent a third party from approving rogue order digests via the public SafeExecutor…"*.

**Proof of concept** — `test_E1`, passing pre-fix:

```solidity
address spender = address(0xDEADBEEF);          // a plain EOA
vm.prank(attacker);
fwd.fill(spender, address(usd), address(0), attacker, "");

assertEq(usd.allowance(address(fwd), spender), type(uint256).max);  // ← passes
```

And `test_E2`, the complete cross-user theft. The board is the **real `Swapboard`** and behaves correctly throughout; the entire loss is in the forwarder:

1. Attacker plants the approval to a `Thief` contract.
2. Attacker lists 100 of their own ERC-20 for 6,000 USD on the board. Any token may run code on transfer; theirs calls `Thief`.
3. Victim routes 10,000 USD through `snwap` → `Swapbol` → `Swapboard.fillOrder(…, 6000e6, victim)`, expecting 4,000 back.
4. During `Swapboard`'s payout leg the attacker's token fires, `Thief` pulls the forwarder's remaining 4,000 USD, and the refund sweep then finds a zero balance.

```solidity
assertEq(usd.balanceOf(victim), 0);            // ← no refund
assertEq(usd.balanceOf(attacker), 10_000e6);   // ← 6,000 earned as maker, 4,000 stolen
```

**Impact**

Theft of any unspent input the forwarder is holding for a user, by an attacker who pre-positioned in an unrelated earlier transaction. `snwap` measures only `tokenOut` growth at `recipient` — it never checks that unspent `tokenIn` came back — so `amountOutMin` cannot detect this class of loss at all. The forwarder is the sole guarantor of the refund.

**Remediation**

The approval is now scoped to the call: granted for exactly the balance being forwarded, and revoked before returning.

```solidity
uint256 approved;
if (tokenIn != address(0)) {
    approved = balanceOf(tokenIn);
    if (approved != 0) safeApprove(tokenIn, board, approved);
}
... board call ...
if (approved != 0) safeApprove(tokenIn, board, 0);
```

Bounding it at `balanceOf` rather than `type(uint256).max` is a second, independent tightening: a hostile board cannot pull more than the caller actually forwarded. Always starting from a zero allowance also makes the approve-from-nonzero tokens (USDT and friends) work by construction.

> **Response:** Fixed. Worth recording why the obvious alternative was rejected: gating `msg.sender == SAFE_EXECUTOR`, the way `Cowol` does, **does not fix this**. `zRouter.snwap` is itself public and forwards arbitrary `executorData` through `SafeExecutor`, so an attacker reaches `fill` through the front door with `msg.sender` satisfied. `Cowol` survives because it pairs that gate with a balance-equality invariant on the order, not because of the gate. Regressions: `test_NoApprovalSurvivesTheCall`, `test_ApprovalIsBoundedByTheForwardedBalance`, `test_PlantedApprovalCannotStealVictimsUnspentInput`.

---

### [High] 2. `fill` is re-entrant, and its sweeps pay a caller-supplied recipient

`Swapbol.fill` · Fixed

**Description**

Independent of any approval. The board call hands control to code chosen by whoever created the order being filled — a token, an NFT, a maker. `fill` has no reentrancy guard, and its two sweeps send the forwarder's entire balance of `tokenOut` and `tokenIn` to a `recipient` taken from calldata. Any code running during the board call can therefore re-enter `fill` with a harmless `board`, name itself as `recipient`, and have the forwarder hand over the victim's unspent input.

This is the same theft as finding 1 by a completely different route, and it needs no preparation: no planted approval, no earlier transaction.

**Proof of concept** — `test_E3`, passing pre-fix. Identical setup to `test_E2` but the attacker's token re-enters instead of pulling:

```solidity
function onTransfer() external {
    fwd.fill(address(this), address(0), address(usd), owner, "");  // tokenOut = the victim's input
}
...
assertEq(usd.balanceOf(victim), 0);
assertEq(usd.balanceOf(attacker), 10_000e6);   // ← passes: swept out re-entrantly
```

**Impact**

Same as finding 1, and cheaper to mount.

**Remediation**

A transient-storage reentrancy guard around the whole of `fill`, cleared only after the last sweep:

```solidity
assembly ("memory-safe") {
    if tload(REENTRANCY_GUARD_SLOT) { mstore(0x00, 0xab143c06) revert(0x1c, 0x04) }
    tstore(REENTRANCY_GUARD_SLOT, 1)
}
```

Verified to clear between *sequential* calls in one transaction, so a `multicall` of several snwap legs through this forwarder still composes.

> **Response:** Fixed. The pairing matters more than either fix alone: revoking approvals does nothing about re-entrancy, and the guard does nothing about a planted approval, because that path never calls the forwarder at all. Both exploits had to be written before it was clear that two orthogonal fixes were required. Regressions: `test_ReentrantSweepCannotStealVictimsUnspentInput`, `test_FillIsNotReentrant`.

---

### [Medium] 3. Unspent ETH is never swept when the output is a token

`Swapbol.fill` · Fixed

**Description**

The ETH sweep was gated on `tokenOut == address(0)`:

```solidity
if (tokenOut == address(0)) { ...sweep selfbalance to recipient... }
else { ...sweep tokenOut... }
```

ETH-in / token-out is an ordinary route. On it, any ETH a board refunds falls through every sweep — the ETH branch is not taken, and the `tokenIn` refund below is gated on `tokenIn != address(0)`, which is false. The remainder simply rests in the forwarder until the next caller, who may name any board and any recipient.

**Proof of concept** — `test_E4`, passing pre-fix: 10 ETH in, board keeps 6, and 4 ETH stays put — then an unrelated caller takes it.

```solidity
assertEq(address(fwd).balance, 4 ether);       // ← stranded
...
assertEq(address(sink).balance, 4 ether);      // ← taken by an unrelated caller
```

**Remediation**

Residual ETH is now swept unconditionally, after both token sweeps, since whatever is there is either the output leg or an unspent refund either way. The `tokenOut == address(0)` special case disappears.

> **Response:** Fixed. This also restores the property the file's own NatSpec claims and its own test asserts — see finding 5.

---

### [Medium] 4. The board is called with the contract's whole balance, not what the caller sent

`Swapbol.fill` · Fixed

**Description**

```solidity
if (tokenIn == address(0)) value = address(this).balance;
```

`receive()` is open and the contract can hold a residue (finding 3), so the value passed to an arbitrary board is not bound to what this caller provided. This is the pattern `audit/zRouter/zellic.md` reported against the router itself as *"ETH value not bound to actions"*, reached here through the forwarder.

**Proof of concept** — `test_E5`, passing pre-fix:

```solidity
vm.deal(address(fwd), 5 ether);                // pre-existing
fwd.fill{value: 1 ether}(address(sink), address(0), ...);
assertEq(address(sink).balance, 6 ether);      // ← passes: sent 6, given 1
```

**Remediation**

`uint256 value = tokenIn == address(0) ? msg.value : 0;`

`SafeExecutor` forwards `msg.value` verbatim (`call(gas(), target, callvalue(), …)`), so `msg.value` is exactly the deposit the router made — the substitution is exact for the intended flow and strictly narrower for every other one.

> **Response:** Fixed, accepting that this deviates from all eleven siblings, which use `address(this).balance`. The deviation is deliberate: it is the remediation the project's own zRouter audit prescribed for this pattern, and the siblings only get away with it because they hold no residue. The siblings carry the same latent issue and are worth a follow-up pass.

---

### [Informational] 5. The repo's own Swapbol suite was failing, and the assertion was right

`test/Swapbol.t.sol` · Fixed

**Description**

`test_HoldsNothingBetweenCalls` was red on arrival:

```
[FAIL: assertion failed: 577021548053172 != 0]
```

Not a flake, and not a bad assertion. `foundry.toml` pins a mainnet fork at block 24,880,000 for the whole default profile, so **every test in this repo runs forked** — and the address Forge deterministically deploys `Swapbol` to, `0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f`, holds 0.000577 ETH on real mainnet. The test asserted the invariant the contract's own NatSpec claims, and the contract did not hold it.

This is worth more than a test fix. It is a live demonstration of finding 4 with a real balance: a forwarder deployed to an address that already has ETH — which the repo's CREATE2 vanity-mining flow makes more likely, not less — hands that balance to the first caller's chosen board.

**Remediation**

Finding 3's unconditional sweep makes the test pass on its own merits. `setUp` now also zeroes the balance so the suite measures itself rather than mainnet, and one test that pre-funded the forwarder instead of sending value was rewritten to send value, which is what `SafeExecutor` actually does.

> **Response:** Fixed. Flagging the fork dependency separately: these forwarder suites are silently fork-coupled, so a Forge-derived address colliding with a funded mainnet account can make assertions non-deterministic. Worth a `vm.deal(..., 0)` in any forwarder suite that asserts on balances.

---

### [Informational] 6. The header's premise is false for every board that exists today

`Swapbol` NatSpec · Fixed

**Description**

The contract documented itself as a thin pass-through — *"the board pays the user directly rather than routing tokens back through this contract. The sweep below is only for a partial or refunded leg."* Checked against the live bytecode, that is true only of the board that has not been deployed yet:

| Board | `fillOrder` selector | Takes `recipient`? |
| --- | --- | --- |
| v1 `0x000000fF3D7A2d373615141d7489Ca66683DbecF` | `0xc37dfc5b` `(uint256,uint256)` | no |
| v2 `0x00000000CC3915a0f5F98CBdC558Ac1a8e85B831` | `0x23fcbd34` `(uint256,uint256,uint256)` | no |
| v3 (unmined) | `0x8ab3bfc9` `(uint256,uint256,uint256,address)` | yes |

Verified by fetching each deployment's runtime code and matching selectors; neither live board contains `0x8ab3bfc9`.

Against v1 and v2 the sweep is not a fallback — it is the delivery path, and the **entire output** transits this contract rather than only an unspent remainder. That is the opposite of what the header led a reader to assume, and it is the assumption under which findings 1 and 2 would have been triaged as "only the leftovers".

**Impact**

No additional loss path: `snwap`'s `amountOutMin` does catch output that never reaches the recipient, so an attacker stealing the *output* causes a revert rather than a theft. But it means the value at risk inside the forwarder was the full trade rather than the remainder, with a single check one contract away as the only thing standing behind it, and no defence in the forwarder itself.

**Remediation**

Header corrected with the three board versions, their selectors, and which one honours a recipient — plus the consequence that `data` must be encoded per board version.

> **Response:** Fixed. Found while scoping whether the approval spender could be hardcoded, which is a good argument for asking deployment questions during a review rather than after it. This also settles that question for now: two of the three boards are known, the third is deliberately unmined until Swapboard's post-audit bytecode is frozen, so an allowlist cannot be completed yet.

---

## Reviewed and deliberately not changed

- **`fill` is still permissionless, and still an arbitrary-call primitive** — any caller may make the forwarder call any address with any calldata.

  > **Response:** By design, and now actually safe. This is the `SafeExecutor` model: arbitrary calls are harmless from a contract that holds no balance and grants no approval. Findings 1–4 were precisely the ways Swapbol failed to be that contract; with them fixed, a caller supplying a hostile board can only rob themselves. Adding a `msg.sender` gate would not have substituted (see finding 1) and would break direct integration.

- **Approve-then-revoke costs roughly 20k more gas per ERC-20 fill** than the siblings' amortised lazy-approve.

  > **Response:** Accepted as the price of taking the board from calldata. The alternative that keeps the sibling gas profile is to hardcode an allowlist of known Swapboard addresses and refuse anything else, which would let the infinite approval stay. That is a legitimate design choice — it trades the generic "any board" property for gas — and if the intent is to only ever serve the two live boards plus this one, it is the better trade. Flagged for the author rather than decided here.

- **`snwap` never verifies that unspent `tokenIn` was returned** — it measures only `tokenOut` growth at `recipient`.

  > **Response:** Router behaviour, out of scope to change, but it is the reason findings 1–3 are High rather than Low: the forwarder is the *only* thing standing behind the refund, and a loss there is invisible to `amountOutMin`. Documented in the contract header so the next forwarder author does not assume the router is a backstop.

- **`balanceOf` and `allowance` return 0 when the staticcall fails** (Solady semantics — `mul(mload(0x20), and(gt(returndatasize(), 0x1f), staticcall(...)))`).

  > **Response:** Left as-is. A token whose `balanceOf` reverts will silently skip its sweep rather than reverting the call. This is upstream Solady behaviour shared with every sibling, and changing it here alone would be worse than the inconsistency.

- **Private Swapboard orders cannot be routed through this forwarder.** `Swapboard` checks `counterparty` against `msg.sender`, which is Swapbol, not the user.

  > **Response:** Correct and unavoidable — it is the property that stops a caller-supplied recipient from draining every private order, documented in `Swapboard`'s own header. Noted here so integrators do not surface private orders as routable.

- **The transient guard requires Cancun.**

  > **Response:** Accepted. These forwarders are mainnet-only by construction — every sibling hardcodes a mainnet aggregator address — and `Swapboard` already depends on transient storage via Solady. Unlike Solady's `ReentrancyGuardTransient` there is no `SSTORE` fallback for older chains; if this is ever ported to one, that needs revisiting.

- **The four assembly helpers are verbatim Solady copies.**

  > **Response:** Verified rather than assumed. Each was checked against `lib/solady` for memory layout: `safeTransfer`/`safeApprove` clobber `0x40` and restore it with the trailing `mstore(0x34, 0)`; `balanceOf` stays inside scratch space; `allowance` saves and restores the free memory pointer around a 0x44-byte calldata frame at 0x1c. All correct, all identical to the siblings.

---

## Verified sound

- **Board reverts bubble up with their original return data**, rather than surfacing as an opaque `SnwapSlippage` from the router.
- **The guard clears between sequential calls in one transaction** — two `fill`s in a single test body both succeed, so a `multicall` of several snwap legs through this forwarder still composes.
- **Nothing is retained on any path**: token or ETH, full fill or partial, output-to-recipient or output-to-forwarder. Asserted on every exit.
- **Fee-on-transfer `tokenIn` needs no special handling** — the approval is derived from `balanceOf`, so it is whatever actually arrived.
- **`tokenIn == tokenOut` is safe**: the output sweep takes the whole balance and the refund sweep then finds zero.

---

## Verification

| |Before|After|
|---|---|---|
| Swapbol tests passing | 6 of 7 (one red) | **16 of 16** |
| New regression tests | — | 8 (`SwapbolAudit.t.sol`) + 2 in the existing suite |
| Exploits reproduced pre-fix | 5 | 0 |
| Deployed bytecode | 834 B | **903 B** (+69) |

Full `Swapbol` + `Swapboard` sweep: **140 tests, 0 failures**, including the mainnet-fork suites.

Three of the eight regressions drive the **real `Swapboard`** rather than a stub, so findings 1 and 2 are demonstrated end-to-end across the composed system — router-shaped input, genuine board, attacker-supplied token — rather than against a mock built to fail.

---

> ⚠️ This review was performed by an AI model (Claude Opus 5). Every finding here is backed by a reproduced exploit, but AI analysis cannot establish the absence of vulnerabilities. Two notes carry beyond this file: the eleven sibling forwarders share finding 4's `address(this).balance` pattern and deserve the same pass, and `snwap`'s lack of any check on returned input means **every** forwarder is individually load-bearing for its users' refunds. An independent human review and a bug bounty remain warranted before deployment.

---

## Current-tree composition addendum

Swapbol has since grown from the reviewed generic helper into the mixed-book
executor consumed by zSwap. The historical findings above still explain its
threat model, but several old “verified sound” statements are superseded:
same-token and ETH/WETH-alias routes are now rejected, and pre-existing
donations are deliberately preserved rather than swept. Only balances created
by the current call move to its recipient or refund address.

Every ERC-20 entry path now consumes a transient `checkpoint(tokenIn)` created
by the same immediate caller before funding. The checkpoint is single-use,
cleared before any token or venue receives control, and makes only the
post-checkpoint increase available. Plans require that increase to equal the
sum of book budgets plus the AMM budget. Exact board/zRouter allowances are
revoked after each leg. Thus a caller cannot appropriate a donation, inherit a
prior user's balance, or leave a standing approval for a venue to use later.

`fillPlan` and `fillPlanAndSwap` accept only constructor-bound legacy v1,
current Swapboard, and Dutchboard addresses; the deprecated intermediate board
cannot be relabelled through calldata. Output `recipient` and input `refundTo`
are separate, and both reject zero and Swapbol itself. The generic `fill`
remains available for explicitly encoded one-off board calls, with the same
checkpoint, delta-sweep, scoped-approval, self-recipient, and reentrancy
protections.

Native input is partitioned once inside one `snwap`, avoiding delegatecalled
multicall entries each observing the same `msg.value`. Swapboard legs receive
freshly wrapped WETH. Dutchboard legs receive literal ETH when their live
`quoteOf(id)` is zero, freshly wrapped WETH when the quote is canonical WETH,
and revert for any other quote under native input. For native output, all book
venues pay WETH to Swapbol, which verifies and unwraps only the aggregate WETH
increase from this call. Exact-output refunds go to `refundTo`; output goes to
`recipient`; forced ETH and donated WETH remain untouched.

Private Swapboard orders still cannot be represented as end-user-authorized
proxy fills because the board checks `counterparty == msg.sender`. zSwap
therefore uses Swapbol for public fungible plans and direct-wallet settlement
for private orders and NFTs.

The expanded focused suite passes 35 tests across `SwapbolTest`,
`SwapbolAuditTest`, and `SwapbolPlanTest`, including checkpoint isolation,
donation preservation, WETH-quoted Dutch input, native book output, exact-out
refunds, and AMM rollback. This addendum intentionally carries no deployment
address; deterministic artifacts are recorded only after final bytecode is
frozen.
