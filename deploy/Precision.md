# Precision pool suite — deployment runbook

**Status: NOT DEPLOYED. Nothing here has a mined salt or an address yet.**

This file exists so the ordering constraints are written down before anything
is mined, because two of them are load-bearing and neither is obvious from the
contracts.

---

## The two constraints that decide everything

### 1. The factory embeds the pool, and only one build of the pool fits

`PrecisionPoolFactory`'s constructor takes `PrecisionPool`'s **bare creation
code** as an argument and stores it with SSTORE2. SSTORE2 writes the blob as
contract code, so it is bounded by EIP-170: 24,576 bytes, one of which goes to
the leading `STOP`. The blob must therefore be **≤ 24,575 bytes**.

foundry.toml restricts `src/pools/PrecisionPoolFactory.sol` to
`max_optimizer_runs = 200`, which transitively pins `PrecisionPool` inside that
compilation unit. The numbers:

| build | pool creation code | fits the blob? |
|---|---|---|
| 200 runs (pinned) | 20,341 B | yes, 4,234 B headroom |
| 9,999,999 runs (default) | 24,657 B | **no — factory is unconstructable** |

Both artifacts exist in `out/` at the same time, under different paths, so
selecting one by path is a coin flip. Use `script/emit-pool-blob.mjs`, which
selects on source hash **and** pinned runs and refuses an oversized blob.

**No test can catch getting this wrong.** Forge runs with
`code_size_limit = None`, and this repo lists `code-size` / `init-code-size` in
`ignored_error_codes`, so an over-limit factory deploys happily in the test EVM
and fails only on a real chain. `test/PrecisionDeployConstraints.t.sol` pins the
byte-length bound instead, and pins the fact that the revert is unobservable.

### 2. Everything downstream is keyed to the factory address

`PrecisionRoute`, `PrecisionPoolLens`, `PrecisionZap`, `ConstantSurchargeHook`
and `PrecisionPoolPolicy` all take the factory in their constructor. Their
initcode — and so their mined salts — cannot be computed until the factory
address is fixed. Mining is strictly sequential: **factory first, then the
rest in parallel.**

And every pool address is CREATE2-derived from `poolInitCodeHash`, so a
different pool build silently relocates the entire market address space. A salt
mined against one blob is worthless against another.

---

## Inputs

| input | value |
|---|---|
| CREATE2 factory (SafeSummoner) | `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| `trustedExecutor` | `0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db` (zRouter executor, live) |
| `poolInitCodeHash` | `0x17ff58e3f57a916f77f9abd13a90eee440c44640b1aee06d01b3f3d689058ee1` |
| factory initcode hash | `0xa7eae87d8f7b5d10cfd94fcea787c3ddc5bd32b47dd047c5a52450bc246c46ad` |
| factory creation size | 28,683 B (EIP-3860 cap is 49,152, so fine) |

Hashes are for the tree at the time of writing. **Any source edit to
`PrecisionPool.sol` or `PrecisionPoolFactory.sol` invalidates both** — re-emit
before mining, never mine against a stale payload.

`PrecisionPoolPolicy` additionally needs an `initialOwner`. It is an advisory
oracle that no contract reads (see its header), so this is not a protocol
authority — but it is still an owner, and `renounceOwnership` is disabled.
Decide deliberately or do not deploy it.

---

## Sequence

```sh
# 0. Canonical build. Everything below reads out/.
forge build

# 1. The pool blob. Refuses the wrong build rather than producing a bad salt.
node script/emit-pool-blob.mjs

# 2. The factory's exact creation payload.
node script/emit-creation-code.mjs PrecisionPoolFactory \
  '["0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db","<contents of out/PrecisionPool.blob.txt>"]'

# 3. Mine. Long-running; parallel across cores.
node script/mine_create2_salt.js 2 1e10 out/PrecisionPoolFactory.creation.txt

# 4. Freeze the artifact for the mined salt.
node script/build-create2-artifact.mjs PrecisionPoolFactory <salt> \
  '["0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db","<blob>"]'

# 5. Only now are the dependents computable. For each of
#    PrecisionRoute, PrecisionPoolLens, PrecisionZap, ConstantSurchargeHook:
node script/emit-creation-code.mjs <Name> '["<factory address>", ...]'
node script/mine_create2_salt.js 2 1e10 out/<Name>.creation.txt
node script/build-create2-artifact.mjs <Name> <salt> '["<factory address>", ...]'

# 6. Verify every artifact reproduces from source before broadcasting.
node script/check-create2-artifacts.mjs
```

Constructor shapes, for step 5:

- `PrecisionRoute(factory, trustedExecutor)`
- `PrecisionZap(factory, trustedExecutor)`
- `PrecisionPoolLens(factory)`
- `ConstantSurchargeHook(factory)`
- `PrecisionPoolPolicy(factory, initialOwner)`

---

## Before broadcasting

- [ ] External audit with the **factory and route in scope**. Four review
      passes so far have each produced new findings, including a High in code
      written during the previous pass. That rate has not flattened.
- [ ] `node script/check-create2-artifacts.mjs` clean.
- [ ] The route builder filters `hook == address(0)` for `routeUpTo` paths.
      Nothing on-chain does this and `factory.isPool` is not a substitute —
      anyone can create a hooked pool through the factory. `PoolInfo.clampable`
      and `PrecisionPoolLens.routeClampable` exist for it.
- [ ] Frontends verify `pool.factory()`, or read pools through the lens. The
      pool constructor is public and LP tokens are named identically across
      every market, so a hostile pool is visually indistinguishable.
- [ ] Confirm the target chain has EIP-1153. The suite uses `tstore`/`tload`
      pervasively; `evm_version` is pinned to `prague` in foundry.toml.
