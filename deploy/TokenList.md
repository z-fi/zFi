# TokenList deterministic deployment manifest

Status: **NOT DEPLOYED — DO NOT DEPLOY. ARTIFACTS RE-MINED 2026-08-03, BUT THE
BUILD IS NOT REPRODUCIBLE. SEE "BUILD REPRODUCIBILITY" BELOW.**

> Re-mined after the renderer audit in
> `audit/TokenList/renderer-claude-opus-5.md`. Both artifacts moved: the renderer
> was substantially rewritten, and the registry's creation code embeds the
> renderer address as a constructor argument, so the registry's salt is invalid
> whenever the renderer's is. Salts, addresses, initcode and calldata below are
> all regenerated from the current tree.
>
> Verified by `test/TokenListMinedDeploy.t.sol`, which now DEPLOYS the recorded
> payload through the real SafeSummoner on a mainnet fork, checks it lands at the
> address below, and then applies the post-deploy route to the full eleven-entry
> list. That test had been silently skipping — the artifacts were stale for long
> enough that its own staleness guard suppressed it — which is how it came to
> still assert an eleven-token constructor after seeding was cut to four. It runs
> and passes now; a skip here means the artifacts have drifted again.
>
> Both addresses carry three leading zero bytes, the same target the previous
> pair was mined for. Re-mine for four if a longer prefix is wanted — expect
> hours rather than the seconds each of these took.
>
> NOTE ON MINING: `script/mine_create2_salt.js` allocated a native keccak object
> per iteration, so worker throughput decayed from 0.13M to 0.02M iter/sec and the
> process died partway through long runs. Fixed in this change; a 3-byte prefix
> now takes seconds. The script still prints a `napi_create_reference` FATAL
> during teardown AFTER reporting a verified result — cosmetic, but it means the
> exit code is not a reliable success signal. Read the `FOUND:` block.

Frozen deterministic build targets for the token registry and its card renderer,
derived from the exact recorded initcode and salts below. These are build targets,
not evidence of mainnet deployment or of present address vacancy. Before deploying,
require `eth_getCode(expectedAddress) == 0x`, simulate the exact calldata, and
verify the receipt and runtime code afterward.

## BUILD REPRODUCIBILITY — BLOCKING

`TokenList`'s compiled size depends on WHICH OTHER FILES ARE IN THE BUILD, not
only on the settings. Under `via_ir`, including the test suite puts the registry
in a different compilation unit and the IR optimizer makes different decisions:

| Command (from clean `out/`) | `TokenList` runtime |
| --- | ---: |
| `forge build src/utils/TokenList.sol src/utils/TokenListRenderer.sol` | 23,939 (fits) |
| `forge build` / `forge test` | **24,817 — EXCEEDS EIP-170** |

Three consequences, all bad:

1. A fresh clone's default build produces a registry that **cannot be deployed at
   all**. Foundry does not enforce EIP-170 inside tests, so the suite passes
   against a variant that mainnet would reject.
2. The suite therefore validates bytecode 872 B different from what ships. Green
   tests on a fresh CI say nothing about the recorded payload.
3. `test/TokenListMinedDeploy.t.sol` compares the recorded initcode against
   `vm.getCode`, which in a full build returns the 24,817 variant — so it skips
   itself on a fresh clone and the deploy package goes unverified exactly where
   verification matters most.

The recorded artifacts here ARE self-consistent: they were built with the isolated
command, and `TokenListMinedDeploy` deploys those exact bytes through the real
SafeSummoner on a mainnet fork, lands at the address below, wires the renderer and
reaches the full eleven-entry list. That passes only when `out/` holds the isolated
build.

This is the same class of defect as B-01 in `audit/TokenList/gpt5.6-sol-pro.md`:
apparent headroom that is an artifact of a build setting rather than real margin.
Lowering `max_optimizer_runs` does not help — 1, 10 and 20 all produce ~24,817 in
the full build. The registry needs to actually shrink, or the build needs to
guarantee a stable compilation unit, before this package is safe to deploy.

## Fixed deployment context

| Item | Value |
| --- | --- |
| Network | Ethereum mainnet, chain ID 1 |
| CREATE2 factory | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| Factory entry point | `create2Deploy(bytes creationCode, bytes32 salt)` |
| Deployment call value | `0` |
| Compiler | Solidity 0.8.36, `via_ir = true`, optimizer **20 runs** (pinned by `foundry.toml` compilation restrictions) |
| Solady revision | `acd959a` |
| Owner (constructor arg) | `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2` |

The deterministic address is `CREATE2(SafeSummoner, salt, keccak256(creationCode))`.

**SEEDING IS MAINNET-ONLY.** The constructor returns early when
`block.chainid != 1`. Deployed to any other chain the same bytecode yields an
empty, ownable registry rather than a list that calls the native asset "Ether"
and hands unrelated contracts Circle's branding. See audit finding M-05.

## Artifact matrix

| Contract | Status | Expected address | Salt | Initcode hash | Creation | Runtime |
| --- | --- | --- | --- | --- | ---: | ---: |
| TokenListRenderer | NOT DEPLOYED | `0x000000F2CcbE111146ec4aa17c76BC1eCBa4f7C6` | `0x000000…0171eb16` | `0x6b8c29a0…b02fefc4` | 14,974 | 14,948 |
| TokenList | NOT DEPLOYED | `0x000000e852c6513458C6ea2F99916d513E77edF9` | `0x000000…004803cc` | `0xf1c93fcd…bdc2b0c3` | 37,223 | 23,939 |

Both runtimes are under EIP-170 (24,576 B) and both creation payloads are under
EIP-3860 (49,152 B). `TokenListRenderer` retains 9,628 B of runtime headroom.
`TokenList` retains **637 B** — measured, not inherited: the previous record here
claimed 2,865 B, which was stale by a factor of four and predated changes that had
already landed in the tree. Adding a seed or a large SVG needs a size check before
it is accepted, and so does any fix to the registry itself, which is not
upgradeable.

Deployment gas, measured per transaction against EIP-7825's 16,777,216 cap —
these deploy as TWO transactions, so the cap applies to each separately:

| Transaction | Gas |
| --- | ---: |
| `TokenListRenderer` | 3,049,658 |
| `TokenList` (four seeded cards) | 12,947,134 |

BUILD HAZARD: `src/dao/ZorgTokenListLens.sol` imports `TokenList`, and building it
compiles the registry at 200 runs, producing a 24,811 B artifact that EXCEEDS
EIP-170. That file is not on this branch, but if it lands, whichever artifact was
written last wins in `out/`. Always build the registry alone and confirm
`optimizer.runs == 20` in the artifact metadata before mining or deploying.

Full values:

- `deploy/TokenListRenderer.salt.txt` — `0x000000000000000000000000000000000000000000000000000000000171eb16`
- `deploy/TokenList.salt.txt` — `0x00000000000000000000000000000000000000000000000000000000004803cc`

## DEPLOY THE RENDERER FIRST

The order is not a preference. `TokenList`'s constructor takes the renderer address
as its second argument, so the renderer address is baked into `TokenList`'s creation
code and therefore into its salt and address. Deploying out of order, or deploying a
renderer that lands anywhere other than the address above, invalidates
`TokenList.salt.txt` entirely.

```
1. create2Deploy(TokenListRenderer.creation, TokenListRenderer.salt)
   -> expect 0x000000F2CcbE111146ec4aa17c76BC1eCBa4f7C6
   -> require code.length > 0 before continuing

2. create2Deploy(TokenList.creation, TokenList.salt)
   -> expect 0x000000e852c6513458C6ea2F99916d513E77edF9
```

The constructor reverts `BadInput()` if the renderer address has no code, so step 2
cannot silently succeed against a missing renderer — but it will consume gas and
fail, so confirm step 1 first.

## Constructor arguments (TokenList)

```
initialOwner  0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2
renderer_     0x000000F2CcbE111146ec4aa17c76BC1eCBa4f7C6

abi-encoded tail (already appended to TokenList.creation.txt):
0x000000000000000000000000006cd14f36f65ecbb29b2519ccbe63a0dc8549f2
  000000000000000000000000000000f2ccbe111146ec4aa17c76bc1ecba4f7c6
```

`TokenListRenderer` takes no constructor arguments.

## Files

| File | Contents |
| --- | --- |
| `TokenList.address.txt` / `TokenListRenderer.address.txt` | Expected CREATE2 address |
| `TokenList.salt.txt` / `TokenListRenderer.salt.txt` | Mined salt |
| `TokenList.creation.txt` / `TokenListRenderer.creation.txt` | Full creation code, hex |
| `TokenList.initcode.bin` / `TokenListRenderer.initcode.bin` | Same, raw bytes, read by the fork replay test |
| `TokenList.deploy.calldata.txt` / `TokenListRenderer.deploy.calldata.txt` | Exact factory calldata |

## Verification performed

At Ethereum block `25,660,327` on 2026-08-01, the following read-only mainnet-fork
checks passed:

- Both expected addresses were vacant before the local replay.
- `test/TokenListMinedDeploy.t.sol` deployed both recorded payloads through
  SafeSummoner at their mined addresses.
- The registry had all 11 expected entries, including zOrgz and WNS as ERC-721
  collections with the onchain-SVG hint; renderer wiring and ownership also matched.
- The generated TokenList gallery parsed every `tokenURI()` as JSON, including both
  NFT collection cards.

Vacancy is time-sensitive: repeat `eth_getCode(expectedAddress) == 0x` immediately
before broadcasting the two deployment transactions.

## A salt is only valid for its exact payload

Any change to the Solidity source — **including a comment** — changes the embedded
metadata hash, changes the creation code, and changes the address. This is not
theoretical: during preparation a one-line change silencing an unused-parameter
warning altered the renderer's initcode hash, which moved the renderer address,
which changed `TokenList`'s constructor argument, which invalidated both salts.

Re-mine both, in order, after ANY source, compiler, optimizer, or dependency change.

Note also that `forge build` and `forge build --force` have produced different
bytecode for identical source in this repo. **Mine only from a completed
`--force` build**, and do not mine while another `forge build --force` is running:
it clears `out/` and the artifacts can vanish mid-read.

## Post-deployment

1. Verify runtime code against the artifacts.
2. Confirm `owner()`, `renderer()` and `total()` on mainnet.
3. Transfer ownership to a multisig — the owner is the principal security boundary
   and can list, delist, re-rank and rewrite every logo and link.
4. Consider `lockRenderer()` once the card is final. Until then the owner can change
   what every listing *appears* to say, even though storage stays honest.
