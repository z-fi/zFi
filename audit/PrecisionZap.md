# PrecisionZap Security Review

Date: 2026-07-31

## Scope and assumptions

The review covered `src/pools/PrecisionZap.sol` and the behavior it relies on
in `PrecisionPool.removeLiquidity`, `PrecisionPoolFactory.isPool`, zRouter's
`snwapMulti`, and zRouter's public `SafeExecutor`.

The intended factory is assumed to be a genuine `PrecisionPoolFactory`
deployment. Its registry contains only pools created from the factory's fixed
`PrecisionPool` creation code. The executor may be publicly callable, as the
live zRouter `SafeExecutor` is; it is not treated as end-user authentication.

## Result

No high- or medium-severity asset-loss issue was found. One low-severity
deployment defect and two defense-in-depth issues were fixed. Checkpoint
storage was also simplified to make token-slot separation exact rather than
probabilistic.

## Findings and fixes

### L-01: An EOA could be configured as the trusted executor

The constructor rejected only the zero address for `trustedExecutor`. An EOA
deployment would succeed even though the checkpoint and exit calls have to be
made atomically through a contract executor. Transient checkpoint state cannot
survive from one EOA transaction to another, so a conventional EOA-configured
zap is silently unusable. The factory already protected its corresponding
configuration with a code-length check.

Fix: require deployed code at the executor address in the constructor.

Impact: deployment/liveness failure rather than theft. Existing correctly
configured deployments are unaffected.

### I-01: Checkpoint accepted arbitrary token contracts

`exit` authenticated a pool through `factory.isPool`, but `checkpoint` would
call `balanceOf` on any contract chosen through the executor. The call is a
static call and did not expose zap-held funds, so no asset-loss exploit was
identified. It nevertheless expanded an authenticated state-transition path
to arbitrary code and allowed checkpoints that could never be consumed.

Fix: require `factory.isPool(token)` before reading the share balance.

### I-02: An output-recipient callback could enter checkpoint during exit

The checkpoint was consumed before `removeLiquidity`, so callback reentrancy
could not double-spend the funded shares. However, a native-asset recipient
could call the public executor from its receive callback and create fresh
checkpoint state while the outer exit was still settling. Transient lifetime
and exact balance deltas prevented theft, but this made the state machine
needlessly callback-sensitive and could poison a later same-transaction leg.

Fix: apply one transient reentrancy guard to both `checkpoint` and `exit`.
The checkpoint remains cleared before the pool receives control.

### Enhancement: collision-free, single-slot checkpoints

The old checkpoint used two adjacent transient slots derived from a hash. It
was secure under standard hash-collision assumptions but needed two writes and
two clears. The revised checkpoint stores `balance + 1` in one slot and uses a
high-bit namespace combined with the 160-bit pool address. Distinct pool
addresses now have provably distinct checkpoint slots, the zero value remains
the inactive sentinel, and the checkpoint consumes less transient storage.

## Validated security properties

- Only a registered pool's shares can be checkpointed or redeemed.
- A route can consume exactly the post-checkpoint balance increase, not shares
  already held by the zap.
- A checkpoint cannot be overwritten or consumed twice.
- The checkpoint is cleared before calling the pool.
- Any revert, including pool slippage failure, atomically restores the funding
  and checkpoint so a corrected call can still settle in the same transaction.
- The pool burns zap-held shares before either output transfer, and both
  outputs go directly to the requested recipient.
- Recipient callbacks cannot enter either zap state-transition function.

## Reviewed non-issues and integration constraints

- The live `SafeExecutor` is public. This is not authorization by itself and is
  not relied on as such: an arbitrary caller can only redeem the exact fresh
  shares funded in that caller's atomic route. It cannot consume donated or
  previously stranded shares.
- Directly transferring LP shares to the zap without an atomic checkpoint
  strands them. There is intentionally no public sweep because that would turn
  old balances into a prize for the next caller.
- `min0` and `min1` protect pool redemption amounts. Integrators must also set
  zRouter's per-output minima and use the same recipient in router and zap
  calldata.
- The contract requires EIP-1153 transient storage and therefore a compatible
  target chain/EVM revision.
- The constructor checks that `factory` has code, but code length is not proof
  of factory identity. Deployment tooling must bind the zap to the intended,
  verified factory address.

## Regression coverage

`test/PrecisionZapAudit.t.sol` exercises constructor configuration, caller and
pool authentication, checkpoint overwrite refusal, pre-existing dust,
funding-amount mismatch, rollback after checkpoint and slippage failures,
exact output delivery, and recipient callback reentrancy.

Verification results:

- `PrecisionZapAuditTest`: 7/7 tests passed.
- `PrecisionPoolInvariantEdgeTest`: all four multi-pool invariants passed under
  Foundry's default invariant campaign, including checkpointed zap exits.
- `PrecisionPoolSnwapTest`: 9/9 mainnet-fork tests passed against the live
  zRouter/SafeExecutor, including checkpointed LP redemption.
- The production-profile `forge build --sizes` passed. `PrecisionZap` deployed
  bytecode is 1,540 bytes (1,770-byte initcode).
- `forge fmt --check` and `git diff --check` passed for the reviewed changes.
