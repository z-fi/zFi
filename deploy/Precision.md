# Precision pool suite — deployment runbook

**Status: LIVE ON MAINNET, VERIFIED, UNSEEDED.** Seven contracts deployed 2026-08-11 and
verified on Etherscan. `poolCount()` is 0 — no market exists yet, so nothing
holds user funds.

| contract | address | deploy tx |
|---|---|---|
| `PrecisionPoolFactory` | `0x000000Eb27B557aB426d9E99cFd54EC455799e81` | `0xe620792024b860bad633360c881740c193ab9358a34c2afb67f084da4dede48e` |
| `PrecisionRoute` | `0x000000384711c65f633Aa4487b968ecb7956DB0F` | `0xd3db79cc98ff796930fbdae0166865f072ac98bb22ee85c6f2862ae9fc5c742e` |
| `PrecisionZap` | `0x000000d193680877a83D3C6bCA73D8726D120c67` | `0x4226929a9634657464b28c5aa10ebf9765a98840bc5b1d962d08a91527f6050f` |
| `PrecisionPoolLens` | `0x000000Bad3a2fa57ed74fa06000573ccddF6B7fB` | `0x86c38f84220e63fe0650846759ca21ad54aed1880bc83361852dec04f728e6bb` |
| `ConstantSurchargeHook` | `0x000000Aee5a5acCFe16088A29A555D93eE42ec03` | `0xbc34840c31a88f4d865bab846e3f0fe60e2ec47faea55052ae0d75205dd32963` |
| `PrecisionPoolPolicy` | `0x00000045fc7b570Be4d71F67219508ebD295EC6D` | `0x13fb57c19a534cfb04cbafd51788cff694b98a89babebf172cd4ab0f7012eb92` |
| `PrecisionLiquidityLens` | `0x000000956bf20A41C54BaE4a4b6F5C8A166DAB4E` | `0x3cc3fce277b85ae92a63502b243b69bb70fd1b27ad20287d2065eab72a5a3673` |

Factory landed in block 25,725,625; the liquidity lens followed in 25,729,951.
Total ~13.3M gas, ~0.0023 ETH.

`PrecisionLiquidityLens` is the LP-side counterpart to `PrecisionPoolLens`:
seed/add/remove previews and the zap split. It was deployed separately and
deliberately - it is a pure view, referenced by no contract, so it can be
replaced by deploying another and repointing the frontend. Extending the
already-verified `PrecisionPoolLens` would instead have left a live address no
longer reproducing from source.

Confirmed from chain state after deployment:

- `poolInitCodeHash` = `0x897b0181f6b0a84c801ae9934c3e8219c68bd65d46d2d534068ae4cda61cbf10`,
  matching the mined blob. This is the check that matters: it means every market
  address the factory derives is the one this repo describes.
- All five dependents return the factory address from `factory()`.
- `PrecisionPoolPolicy.owner()` is `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2`.
- Route and zap both carry the zRouter executor.

### Verification

All six verified on Etherscan at **200 optimizer runs**, solc 0.8.36,
`--compilation-profile default`. The run count is load-bearing: verifying at the
repo's default 9,999,999 produces different bytecode and Etherscan rejects the
match, the same pin that decides whether the pool blob fits SSTORE2 at all.

**Pools do not inherit this.** The factory deploys each market via CREATE2 from
the SSTORE2 blob, so a new pool lands unverified until `PrecisionPool` is
submitted for that address with its nine constructor args. Etherscan often
propagates a similar-match afterwards, but verify the first market explicitly
rather than relying on it.

`deploy/PrecisionPool.verify.sh` does it, reading the nine args off the pool
rather than reconstructing what we think was submitted:

```
ETHERSCAN_API_KEY=... deploy/PrecisionPool.verify.sh 0x<pool>
```

The first market is **`0xc37F8c7E9Afe897893952ABa7fD91E0AB947837d`** (ETH/ZORG,
0.30%, unowned), created 2026-08-12 in
`0x917a240c82e1a2a2ae03fbab4c3f70b9c3f8d6ce0f44eb712618f9066d0e7ef5`. Its
deployed runtime is 19,440 bytes and reproduces from source at these settings -
checked byte for byte, differing only where the immutables are written in.

**Verified 2026-08-12**, and Etherscan reports it as an *Exact Match*. Two
gotchas worth keeping:

- `--compilation-profile default` is required, not optional. The build cache
  holds several profiles (`tokenlist`, `lens`) and forge refuses to guess.
- The site shows the verification immediately; the **API lags** it by a good
  while. `checkverifystatus` returned `Pass - Verified` while `getsourcecode`
  and `getabi` still answered "not verified" for the same address. Read the
  page, or the GUID, before concluding a verification failed.

**Creating a market costs ~4.63M gas**, of which ~3.9M is code deposit at 200
gas a byte. That is the architecture: a market IS a contract. The dapp prices
it before the wallet prompt because a wallet's default tip is sized for
ordinary transactions - the first create paid 2 gwei against a 0.163 gwei base
fee, and 92% of the fee went to the validator.

### The deployer key is burned

`0xAcFBA7Ce872C6eAD99d535586f84b0D68ADE4082` was used to broadcast and its
private key was exposed in plaintext during the session. Nothing downstream
depends on it — no contract records the deployer, and CREATE2 addresses derive
from the SafeSummoner, salt and initcode rather than the sender — but it should
be swept and abandoned rather than reused.

Three leading zero bytes each. Salts are in `deploy/<Name>.salt.txt` and the
broadcast calldata in `deploy/<Name>.deploy.calldata.txt`.

`PrecisionPoolPolicy`'s owner is `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2`,
baked into its initcode and therefore into its salt. It is an advisory oracle no
contract reads, and `renounceOwnership` is disabled.

**Broadcast in the order listed.** The factory's address is a constructor
argument to the other five, so deploying any of them first yields a contract
pointing at nothing.

**These addresses are valid for exactly this bytecode.** Any edit to a
pool-suite source file invalidates the affected salt; an edit to
`PrecisionPool.sol` or `PrecisionPoolFactory.sol` invalidates all six, because
the factory embeds the pool blob and the other five embed the factory address.
Re-run `script/precision-prep.mjs`, re-mine, and re-run the checker. That
checker is what catches a stale artifact, and it has caught one this session —
a factory salt mined two seconds before the source changed under it.

The rest of this file is why the ordering above is what it is: two constraints
that decide everything, and neither is obvious from reading the contracts.

---

## The two constraints that decide everything

### 1. The factory embeds the pool, and only one build of the pool fits

`PrecisionPoolFactory`'s constructor takes `PrecisionPool`'s **bare creation
code** as an argument and stores it with SSTORE2. SSTORE2 writes the blob as
contract code, so it is bounded by EIP-170: 24,576 bytes, one of which goes to
the leading `STOP`. The blob must therefore be **≤ 24,575 bytes**.

foundry.toml now pins `src/pools/PrecisionPool.sol` to `max_optimizer_runs = 200`
**in its own right**. Before that it had no entry and inherited whichever
setting its compilation unit carried — 200 through the factory, the default
standalone — so two builds sat in `out/` at once and picking between them was a
coin flip that decided every market address. The numbers:

| build | pool creation code | fits the blob? |
|---|---|---|
| 200 runs (pinned) | 20,630 B | yes, 3,945 B headroom |
| 9,999,999 runs (default) | 24,657 B | **no — factory is unconstructable** |

Measure the **creation-code** column of `forge build --force --sizes`, not the
runtime column. The runtime figure is 19,228 B and is not what this bound
applies to; reading the wrong column reports ~5 KB of headroom that is not there.

With the pin in place a canonical build produces exactly one PrecisionPool
artifact. `script/emit-pool-blob.mjs` still selects on source hash **and**
pinned runs and refuses an oversized blob, so a stray artifact from an
overridden profile cannot be picked up by accident.

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
| pool creation code | 20,630 B (SSTORE2 cap 24,575) |
| `poolInitCodeHash` | `0x897b0181f6b0a84c801ae9934c3e8219c68bd65d46d2d534068ae4cda61cbf10` |
| factory creation code | 29,245 B (EIP-3860 cap 49,152) |
| factory initcode hash | `0xb87630079e4971ebde7b67c3a2547d276376c12ed9f251231561645f5d01f59e` |

These rows are regenerated, not hand-written: `node script/precision-prep.mjs`
emits both payloads and rewrites this table from the artifacts it just built.
Do not edit them by hand, and do not trust a copy of this file that was not
produced by that script against the current tree.

**Any source edit to `PrecisionPool.sol` or `PrecisionPoolFactory.sol`
invalidates both hashes.** Re-run the prep script before mining. A salt is valid
for exactly one bytecode, and `poolInitCodeHash` is a CREATE2 input, so a stale
pool hash silently relocates every market address the factory will ever produce.

### The executor, verified rather than assumed

An audit pass flagged that the factory's safety argument rests on
`trustedExecutor` bubbling every revert, and that this was unverifiable from
source. It is verifiable on-chain, and it holds. `0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db`:

| property | observed |
|---|---|
| runtime size | 252 bytes |
| selectors | exactly one, `0x1cff79cd` (`execute(address,bytes)`); everything else reverts |
| `SSTORE` / `DELEGATECALL` / `SELFDESTRUCT` / `CREATE` | none |
| `CALL` | one |
| failure path | `RETURNDATASIZE / RETURNDATACOPY / REVERT` — the standard bubble |
| compiler | solc 0.8.33 |

No storage means no admin and no upgrade path; no `DELEGATECALL` means no proxy
target. The single `CALL` is followed by the bubble, so a reverting settlement
cannot be swallowed and reported as success. That closes the scenario where a
reentrant substitution completes the committed swap while the outer hop reports
failure and desynchronises a router's accounting.

`trustedExecutor` is immutable in both the factory and the route, so this needs
re-checking only if that address is ever changed.

`PrecisionPoolPolicy` additionally needs an `initialOwner`. It is an advisory
oracle that no contract reads (see its header), so this is not a protocol
authority — but it is still an owner, and `renounceOwnership` is disabled.
Decide deliberately or do not deploy it.

---

## Sequence

```sh
# 0. Canonical build. Everything below reads out/.
forge build

# 1-2. Blob, factory payload, and the Inputs table above - one command.
node script/precision-prep.mjs

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
