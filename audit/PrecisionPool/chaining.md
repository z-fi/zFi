# PrecisionPool + call chaining — audit

Scope: `src/pools/PrecisionPool.sol`, and the chaining layer around it
(`PrecisionRoute.sol`, `PrecisionZap.sol`, the factory's checkpointed route).

**Status: all findings fixed.** H-1, H-2, L-1 and L-2 in `PrecisionRoute.sol`;
M-1 as a new `routeUpTo` entry point, backed by a new `PrecisionPool.quoteExactIn`.
Regressions live in `test/PrecisionPoolMultihop.t.sol`:
`test_ZapInSweepsOnlyItsOwnLeftoversNotRestingBalances` and
`test_NativeEntryIsRefusedWhileAnotherRouteIsOpen`. The first was confirmed to
fail against the unfixed sweep (all 1000 resting USDC drained to a
caller-chosen recipient) and to pass after.

## Summary

The pool itself holds up. The arithmetic is conservative in the right
directions, the documented growing-K behaviour is genuinely internally
consistent, and the liveness guards (`_tradeable`, `MIN_RESOLUTION`, the
band postcondition on add-only) close the "permanently inert immutable pool"
class of bug rather than papering over it.

The chaining layer is where the risk is. `PrecisionZap` and
`PrecisionPoolFactory` both implement the same discipline — a transient,
single-use, intent-committed checkpoint, plus a reentrancy lock — and reason
about it explicitly. `PrecisionRoute` implements only half of it, and one
function opts out entirely.

---

## H-1 — `PrecisionRoute.zapIn` sweeps unbounded balances, bypassing the checkpoint

`PrecisionRoute.zapIn` ends with:

```solidity
_sweep(t0, to);
_sweep(t1, to);
```

and `_sweep` transfers the contract's **entire** balance of that token
(`balanceOf(address(this))`, or `address(this).balance` for native) to a
caller-chosen `to`. It is not bounded to the leftovers of this zap.

The checkpoint machinery (`checkpoint` / `_consume`) bounds what may be
*spent*: only the fresh delta, only by the exact committed calldata. The sweep
is outside that entirely — it hands over whatever happens to be resting,
regardless of who put it there or which call it was checkpointed for. With
`tokenIn == address(0)` no checkpoint is consumed at all.

`trustedExecutor` is not authentication. The canonical executor is zRouter's
`SafeExecutor` — `execute(address,bytes)`, no caller check — as the factory's
own comment at [PrecisionPoolFactory.sol:141](src/pools/PrecisionPoolFactory.sol#L141)
documents. So anyone can call `zapIn`.

Attack: while a victim's funds rest in `PrecisionRoute`, re-enter the public
executor and call `zapIn` with a dust deposit into any pool holding the resting
token; the trailing sweep pays out the resting balance to the attacker. The
deposit must actually succeed (there is no `try`), which costs the attacker
dust plus one swap fee — not a barrier.

Two windows where funds rest:

- **Between `checkpoint` and `route`.** The input token is transferred in
  during that gap and `PrecisionRoute` holds no lock across it. This is
  precisely the window the factory refuses to leave open (`_ROUTE_OPEN` spans
  checkpoint→settlement).
- **Mid-`route`.** Hops pay `address(this)`, so an intermediate rests while
  hop *i+1* is set up.

Both require a control transfer while funds rest, i.e. a callback-capable
token in the path (permissionless pool creation means the pair is attacker-
choosable, though the *route* is the victim's). The pool's `_afterSwap` hook is
capped at `HOOK_GAS = 150_000`, which is not enough to drive a `zapIn`, so the
hook is not a viable trigger — a transfer-hooking token is.

Severity is Medium-to-High depending on how much you weight the callback-token
precondition. I'd fix it regardless: the entire checkpoint design exists to
survive exactly this scenario, and the sweep silently exempts itself.

**Fixed.** `zapIn` now snapshots both pool tokens on entry, subtracts its own
funding (`msg.value` for native, the `_consume`-verified transfer for ERC-20),
and `_sweep` returns only the balance above that floor. Its own leftovers still
come back; nobody else's resting balance moves. Combined with H-2's lock, the
reentrant window is closed as well.

## H-2 — `PrecisionRoute` has no reentrancy guard at all

`PrecisionZap` has `nonReentrant` on both `checkpoint` and `exit`. The factory
holds `_ROUTE_OPEN` across the whole checkpoint→settle interval and argues at
length for why a per-call guard is insufficient. `PrecisionRoute` has neither:
`checkpoint`, `route`, and `zapIn` are all freely re-enterable.

The per-token `active` flag makes a second checkpoint *for the same token*
revert, and the intent commitment stops a nested `route` from spending another
route's delta — so the funding itself is defended. What is not defended is
everything reachable *while* a route is mid-flight, which is H-1.

**Fixed.** Added the factory's arrangement rather than a per-call guard, since
the per-call version leaves the funding gap open by construction: a transient
`IDLE → OPEN → SETTLING → IDLE` lifecycle where `checkpoint` opens the route and
only the call that spends it closes it. While a route is open, a native-funded
entry — which consumes no checkpoint and so has nothing in its own arguments
constraining it — is refused outright, and an ERC-20-funded one must still match
the committed intent. `SETTLING` is never re-entrant; routes are never
legitimately concurrent.

## M-1 — Routes are all-or-nothing; `swapUpTo` is unreachable from the router

`PrecisionPool.swapUpTo` / `swapUpToFromFactory` exist for a well-argued
reason ([PrecisionPool.sol:402-416](src/pools/PrecisionPool.sol#L402-L416)): a
band refuses rather than clamps, so a leg sized from a stale quote reverts at
submission, and an aggregator has nothing to route around.

`PrecisionRoute.route` uses only `swapExactIn`. So the exact failure mode
partial fill was built to remove is fully present on every multi-hop route —
and it is *worse* there, because any one of N hops leaving its band takes the
whole route down.

**Fixed**, as `PrecisionRoute.routeUpTo` — but not by applying `swapUpTo` per
hop, which is the obvious construction and is wrong.

Clamping hop 1 is easy: the unconsumed head is still `tokenIn` and goes back to
the payer. Clamping hop *i>1* strands an *intermediate* token — something the
caller never asked to hold and cannot unwind without another transaction.
Returning it turns a clean revert into a silent bad position; swapping it back
pays a second fee and moves the price twice to undo work just done; reverting is
the status quo.

So the clamp happens **once, at the front**: search for the largest starting
amount for which *every* hop fits, then execute that route whole. The remainder
is then always `tokenIn`, and the intermediate case is not handled so much as
made unrepresentable.

The predicate is monotone and therefore bisectable. A pool's `fits` is monotone
decreasing in its own input and output is monotone increasing in input, so hop
*i*'s input is monotone increasing in the route's input and its fit monotone
decreasing in it; a conjunction of monotone-decreasing predicates is monotone
decreasing. This is the same argument — and the same bisect-don't-solve
conclusion — that `PrecisionPool._maxIn` already makes one level down.

**Drift was the real risk, and it is closed structurally.** A search that models
the transition even slightly differently from execution returns a size that
reverts, which is precisely the failure partial fill exists to remove. Rather
than reimplement the swap math in the router or lean on the lens mirroring it,
the pool now exposes `quoteExactIn`, which runs `_transitionAt` — the same
function `_swapExact` runs. The router's `route` and `routeUpTo` also share one
`_walk`, so the executed path cannot differ between them either. (This was
available because the pools are not yet deployed; on a deployed pool the search
would have had to go through the lens and accept tested-not-guaranteed
agreement.)

Cost is paid only on the clamping path — a route that fits whole returns on the
first probe — and is roughly log2(amountIn) view walks otherwise.

**Hooks.** Each probe samples the hook at the size being probed and execution
runs at exactly the probed size, so the model is exact where the pool's own
`_maxIn` had to refuse partial fill outright. A hook whose surcharge is not
monotone in size can still yield a valid but suboptimal fill; one that answers
differently between probe and swap makes the route revert — no loss, and a
property of a pool the caller chose.

Tests: `test_RouteUpToClampsAtTheFrontAndRefundsTheInputToken`,
`test_RouteUpToFindsTheLargestSizeThatFits` (replays the state to assert the
chosen size executes and one unit more does not — a conservative search would
silently underfill every route), and
`test_RouteUpToConsumesEverythingWhenTheRouteFits`.

## L-1 — `PrecisionRoute` constructor accepts an EOA executor

```solidity
if (address(factory_).code.length == 0 || trustedExecutor_ == address(0)) revert Bad();
```

`PrecisionZap` requires `trustedExecutor_.code.length != 0`. `PrecisionRoute`
only rejects zero. Cheap to align; on an immutable contract a mistyped
executor is unrecoverable.

**Fixed.** Now requires code, matching `PrecisionZap`.

## L-2 — `_slot` keys on `caller()` for a caller that is always the same

`PrecisionRoute._slot` mixes `caller()` into the checkpoint slot, but every
caller reaching it has already passed `msg.sender != trustedExecutor`. The
mixing is harmless but implies a multi-executor design that does not exist, and
invites the reader to assume checkpoints are caller-isolated for a reason.
Either drop it or say why it's there.

**Fixed.** Dropped; `_slot` is keyed on the token alone and is now `pure`, with
a comment saying why.

---

## Pool-level review — no findings

Things I specifically tried to break and could not:

- **Fee rounding.** Both fee classes and the creator cut are taken as a
  difference from a floored remainder, so split-trade fee evasion is closed.
  The documented cost (a few raw units pays a whole unit) is real, bounded by
  one raw unit per fee class per swap, and correctly disclosed.
- **`_maxIn` bisection.** `hasRoom` really is monotone decreasing in
  `amountIn`: all three of its failure conditions (reserve room, uint128
  headroom, band exit) turn on monotonically with size. The zero-output
  condition runs the other way and is correctly handled outside the bisection.
  If `lo` yields zero output, output monotonicity means nothing below it is
  fillable either, so the revert is correct rather than a missed fill.
- **`_executable` vs `_swapExact` drift.** `_executable` replays the nested
  floors in the swap's order (surcharge, then base fee) rather than collapsing
  them, and checks room and range against the same quantities. The reasoning in
  the comment matches the code.
- **Partial fill on hooked pools.** Refused rather than approximated, because
  the surcharge is sampled once at the requested size. Correct call.
- **Range arithmetic overflow.** `sqrtPHigh <= 1e36` and reserves ≤ uint128
  keep `lo*lo`, `hiExclusive*hiExclusive`, and `_ratio` inside uint256 with
  large margin.
- **`_assertBacked` skipping `hookOwed` when `hook == address(0)`.** Safe —
  `hook` is immutable, so those counters can never be nonzero in that case.
- **Reentrancy into the pool.** The transient guard is held across `_pay` (so
  native output callbacks and token transfer hooks cannot re-enter) and across
  `_afterSwap`. It does not protect *other* contracts, which is what H-1 turns
  on, but the pool itself is sound.
