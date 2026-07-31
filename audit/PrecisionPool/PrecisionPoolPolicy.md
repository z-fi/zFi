# PrecisionPoolPolicy Security Reference

**Date:** 2026-07-31  
**Status:** Approved for use as the zSwap routing policy, subject to the
integration and governance requirements below  
**Contract:** `src/pools/PrecisionPoolPolicy.sol`  
**Solidity:** 0.8.36, via IR, optimizer enabled  
**Source SHA-256:** `5219610ffc2e40178a0fdd3b223d21eb0080f3e9ff3d39ebdfce1bf50de42888`

## Purpose

`PrecisionPoolPolicy` separates permissionless pool creation from zSwap
endorsement. It does not alter PrecisionPool custody, LP accounting, swaps, or
factory deployment:

- every canonical factory pool with no hook is routable by default;
- a pool with a nonzero hook is denied until that exact pool address is
  approved;
- any existing factory pool can be blocked; and
- a non-factory address is always denied.

There is intentionally no token-wide allowlist. A specific unhooked pool with
an unsafe token or bad configuration can be blocked without making the
factory permissioned or creating token administration across the protocol.

## Policy Semantics

The stored policy is one enum, so blocking an approved hooked pool overwrites
the approval rather than maintaining two conflicting booleans.

| Factory pool | Hook | Stored policy | `isRoutable` |
| --- | --- | --- | --- |
| no | any | `Default` | false |
| yes | zero | `Default` | true |
| yes | nonzero | `Default` | false |
| yes | nonzero | `Approved` | true |
| yes | any | `Blocked` | false |

`Approved` cannot be assigned to an unhooked pool. `Blocked` short-circuits
before either external read, so a known incident block remains a cheap
`false` result even if factory RPC simulation is unavailable. Approval skips
the pool hook read after factory provenance is confirmed. These shortcuts are
sound for `PrecisionPoolFactory`, whose `isPool` membership only changes from
false to true, and `PrecisionPool`, whose hook is immutable.

`requireRoutable(pool)` exposes the same decision as a reverting preflight for
routes that can include the policy check in the execution transaction.

## Ownership

The contract uses Solady `Ownable` and initializes an explicit nonzero owner in
the constructor. Only the owner can assign `Default`, `Approved`, or `Blocked`.
Solady's direct ownership transfer and two-transaction ownership handover
remain available.

`renounceOwnership` is disabled. A production routing policy must retain an
incident-response authority. This does not make ownership transfer infallible:
a direct transfer to a mistyped, burned, or inaccessible nonzero address can
still strand administration. Use Solady's ownership handover for governance
migrations and verify the pending owner onchain before completion.

The production owner should be a threshold Safe with independently secured
signers. A single owner cannot simultaneously provide timelocked approvals
and immediate emergency blocking. This implementation follows the requested
minimal single-owner model. If delayed approvals plus a fast block-only
guardian become requirements, implement and separately review that governance
change rather than putting the sole owner behind a delay and assuming blocks
remain immediate.

Owner compromise can approve or unblock routing through a malicious hooked
pool. It cannot transfer pool assets, alter pool immutables, mint LP shares, or
prevent users from withdrawing directly.

## Enforcement Boundary

This registry is a policy oracle, not a protocol pause:

- direct calls to `PrecisionPool` remain permissionless;
- generic zRouter calls remain permissionless;
- blocking affects only clients or execution adapters that consult this
  contract; and
- an offchain check does not stop a transaction already in the mempool if the
  owner blocks the pool before that transaction is mined.

zSwap must call `isRoutable` before displaying or quoting a pool and recheck it
immediately before constructing a transaction. That is sufficient for zSwap
curation but is not strict same-transaction enforcement.

For strict enforcement on an ERC-20 route through the current zRouter,
prepend an atomic zero-input `snwap` call through SafeExecutor to
`requireRoutable(pool)`, followed by the existing factory checkpoint and
funded settlement calls. A block cannot interleave between calls in one
transaction.

Do not prepend that same `snwap` preflight to a native-input zRouter
`multicall`. zRouter multicall uses delegatecall, so every `snwap` entry sees
and forwards the full transaction `msg.value`. The policy preflight is
nonpayable and will revert. Strict atomic policy enforcement for native input
requires a policy-aware executor or gateway that checks the policy and then
forwards value to the factory in one call, or a separately reviewed factory
integration.

The current `zSwap.html` does not contain PrecisionPool integration. Its next
onchain HTML version must embed the chain-specific policy address and ABI in
addition to the factory and lens addresses. An old immutable zSwap page cannot
discover a newly deployed policy automatically.

## Hook Review Boundary

Approval is for an exact pool address, not a hook implementation address.
That avoids approving every pool that happens to name the same hook and keeps
range, fee, tokens, creator terms, and hook bound together.

The policy confirms that a hook address is nonzero; it does not inspect hook
bytecode or behavior. A proxy hook can change after approval while the pool
address and immutable hook address remain unchanged. Prefer immutable hook
implementations. For a proxy hook, audit its implementation, upgrade
authority, and upgrade delay, and monitor implementation changes as an active
governance dependency.

## Security Properties

1. Unknown and foreign addresses fail closed.
2. Default state is safe for hooked pools and permissionless for unhooked
   factory pools.
3. An incident block overrides every positive rule.
4. Restoring a blocked hooked pool requires a fresh explicit approval.
5. Policy mutation is restricted to the Solady owner.
6. Constructor dependencies must be deployed contracts and the initial owner
   cannot be zero.
7. Ownership cannot be renounced to the zero address.
8. The contract holds no user funds and grants no token approvals.
9. There are no unbounded arrays, loops, upgrade hooks, or delegatecalls.

## Residual Risks

- **Advisory policy:** integrations that omit the check bypass the registry by
  design.
- **Governance latency:** a delayed owner also delays blocks; a fast owner can
  also approve or unblock quickly.
- **Ownership transfer:** inherited direct transfer can strand control if
  governance signs an incorrect recipient.
- **Mutable hooks:** a proxy implementation can change after pool approval.
- **Factory dependency:** default and approved queries depend on the immutable
  factory's `isPool` view. The production factory is non-upgradeable and that
  call has no mutable control path.
- **Client pinning:** zSwap must use the policy paired with the exact factory.
  A correct policy queried for the wrong factory denies valid pools; a wrong
  policy address defeats intended curation.

## Build and Test Results

The default 9,999,999-run artifact is:

| Metric | Result |
| --- | ---: |
| Runtime bytecode | 2,790 bytes |
| EIP-170 runtime margin | 21,786 bytes |
| Artifact initcode, before constructor arguments | 3,047 bytes |
| Constructor arguments | 64 bytes |

The singleton policy benefits from the default high-run optimizer and has no
size pressure. At 200 optimizer runs it is 1,857 runtime bytes. Runtime checks
are also lean: a blocked pool skips all external calls and an approved pool
skips the hook getter.

Verification:

| Suite/check | Result |
| --- | --- |
| `test/PrecisionPoolPolicy.t.sol` | 15 passed, 0 failed |
| `test/PrecisionPool.t.sol` | 75 passed, 0 failed |
| Price and seed fuzzing | 512 combined runs passed |
| `test/PrecisionPoolSnwap.t.sol` at block 25,640,000 | 9 passed, 0 failed |
| `forge fmt --check` on policy source and tests | passed |
| Forge high/medium lint on policy source | passed |
| `git diff --check` on policy source and tests | passed |

The policy suite covers constructor validation, unknown-address refusal,
default hooked and unhooked behavior, approval, revocation, blocking,
approval erasure, factory-liveness short-circuiting, unauthorized mutation,
invalid assignments, direct ownership transfer, ownership handover, and
disabled renunciation.

The configured public archive RPC returned one transient HTTP 500 during
fork account loading, before test setup or contract execution. The immediate
deterministic run passed 15 tests, and a final production-profile retry also
passed all 15. The same profile passed the 75-test pool suite and 9-test
live-zRouter suite.

## Deployment Checklist

- [ ] Deploy with the exact intended `PrecisionPoolFactory`.
- [ ] Set `initialOwner` to the production threshold Safe, not a personal EOA.
- [ ] Verify source and constructor arguments on a public explorer.
- [ ] Record the policy address beside the factory and lens for each chain.
- [ ] Audit every hook and pool tuple before assigning `Approved`.
- [ ] Exercise `Blocked` from the production Safe before enabling zSwap.
- [ ] Use ownership handover for later owner migrations.
- [ ] Subscribe to `PoolPolicySet` and `OwnershipTransferred`.
- [ ] Make zSwap fail closed on an unavailable or reverting policy read.
- [ ] Check policy before quote selection and again before submission.
- [ ] Add an atomic policy-aware gateway if native-route hard enforcement is
      required.
- [ ] Rebuild and redeploy the immutable zSwap HTML with the policy address.

## Assessment

The contract is suitable for production as a minimal zSwap routing registry.
It cleanly keeps the PrecisionPool factory permissionless, imposes no token
approval layer, defaults hooked pools to denied, and provides an explicit
per-pool incident block.

Greenlighting the registry does not greenlight an integration that only
checks it during discovery or silently falls back when the read fails. Launch
requires the Safe ownership, fail-closed zSwap checks, hook review, address
pinning, and enforcement choice documented above.
