# TokenList deterministic deployment manifest

Status: **NOT DEPLOYED — ARTIFACTS RE-MINED 2026-08-03 (second pass)**

> Re-mined after `TokenListLens` split ranking, rank-paging and search off the
> registry. That move was not tidying: it is what made the registry fit under
> EIP-170 in every build configuration rather than only in one. See "Build
> reproducibility" below for what went wrong and what fixed it.
>
> All three artifacts are regenerated from the current tree and verified by
> `test/TokenListMinedDeploy.t.sol`, which deploys the recorded payload through
> the real SafeSummoner on a mainnet fork, checks it lands at the address below,
> wires the renderer, and applies the post-deploy route to the full eleven-entry
> list. 108 tests pass from a clean build with nothing skipped.
>
> NOTE ON MINING: `script/mine_create2_salt.js` allocated a native keccak object
> per iteration, so worker throughput decayed from 0.13M to 0.02M iter/sec and the
> process died partway through long runs. Fixed; these three took 62 s, 22 s and
> 8 s. The script still prints a `napi_create_reference` FATAL during teardown
> AFTER reporting a verified result — cosmetic, but the exit code is not a
> reliable success signal. Read the `FOUND:` block.

## Build reproducibility

Under `via_ir`, a contract compiles differently depending on which other files
share its compilation unit. Identical source at identical settings, built two
ways:

| Command (from clean `out/`) | `TokenList` runtime |
| --- | ---: |
| `forge build src/utils/TokenList.sol src/utils/TokenListRenderer.sol src/utils/TokenListLens.sol` | 22,167 |
| `forge build` / `forge test` | 21,275 |

Roughly 900 B apart, and before the lens split the larger of the two was **24,811
— over EIP-170**. Foundry does not enforce the limit inside tests, so the suite
passed against a variant mainnet would have rejected, while the shipped artifact
came from the other build and fit. Three things were wrong at once: a fresh clone
could not produce a deployable registry, the tests validated bytecode that was not
the deployed bytecode, and `TokenListMinedDeploy` compared the recorded initcode
against `vm.getCode` — so under a full build it always mismatched and skipped
itself, silently, for long enough to hide a stale assertion of its own.

Resolved on all three counts:

1. **Margin, not a build flag.** Ranking, rank-paging and search moved to
   `TokenListLens`. The registry now fits in EVERY configuration — worst case
   22,167 against 24,576, so 2,409 B spare. Lowering `max_optimizer_runs` was
   tried first and does not help: 1, 10 and 20 all produced ~24,817.
2. **The canonical build is the isolated one** (first row above). A deterministic
   artifact should be a function of the source it deploys, not of every unrelated
   file in the repo — under a full build, adding any test anywhere would move the
   bytecode and silently invalidate a mined salt.
3. **The staleness guard asks about the source, not the build.**
   `deploy/TokenList.sources.txt` records the keccak of each source file the salts
   were mined for, and `TokenListMinedDeploy` compares against that. It now runs
   under both build modes and skips only when the source has genuinely drifted.

## Fixed deployment context## Fixed deployment context

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
| TokenListRenderer | NOT DEPLOYED | `0x000000244989957984A19F27F92eAeb36017D44b` | `0x000000…010dcbc0` | `0x974669ca…178723e5` | 15,032 | 15,006 |
| TokenListLens | NOT DEPLOYED | `0x000000AA6F2d3D14680dAdd3E4563F96BcC13bCB` | `0x000000…00766582` | `0x2e89e39d…58506b7a` | 4,243 | 4,217 |
| TokenList | NOT DEPLOYED | `0x00000054Fb325D187431A845bf8cBbD1eEc05C54` | `0x000000…00c4d0da` | `0xfb794a77…8afc2702` | 35,451 | 22,167 |

All three runtimes are under EIP-170 (24,576 B) and all three creation payloads
are under EIP-3860 (49,152 B). Headroom, measured against the LARGER of the two
build modes above, which is the number that matters:

| Contract | Worst-case runtime | Headroom |
| --- | ---: | ---: |
| `TokenList` | 22,167 | 2,409 |
| `TokenListRenderer` | 15,108 | 9,468 |
| `TokenListLens` | 4,217 | 20,359 |

The registry's 2,409 B is the one to watch: it is not upgradeable, so that is the
entire budget for ever shipping a security fix. The renderer and the lens can both
be replaced, which is why the split put the replaceable work on their side of the
line. Adding a seed or a large SVG needs a size check before it is accepted.

Deployment gas, measured per transaction against EIP-7825's 16,777,216 cap. These
deploy as separate transactions, so the cap applies to each one on its own:

| Transaction | Gas |
| --- | ---: |
| `TokenListRenderer` | 3,049,658 |
| `TokenList` (four seeded cards) | 12,237,337 |
| `TokenListLens` | well under; no constructor, no storage |

Full values:

- `deploy/TokenListRenderer.salt.txt` — `0x00000000000000000000000000000000000000000000000000000000010dcbc0`
- `deploy/TokenList.salt.txt` — `0x0000000000000000000000000000000000000000000000000000000000c4d0da`

## DEPLOY THE RENDERER FIRST

The order is not a preference. `TokenList`'s constructor takes the renderer address
as its second argument, so the renderer address is baked into `TokenList`'s creation
code and therefore into its salt and address. Deploying out of order, or deploying a
renderer that lands anywhere other than the address above, invalidates
`TokenList.salt.txt` entirely.

```
1. create2Deploy(TokenListRenderer.creation, TokenListRenderer.salt)
   -> expect 0x000000244989957984A19F27F92eAeb36017D44b
   -> require code.length > 0 before continuing

2. create2Deploy(TokenList.creation, TokenList.salt)
   -> expect 0x00000054Fb325D187431A845bf8cBbD1eEc05C54

3. create2Deploy(TokenListLens.creation, TokenListLens.salt)   [any time]
   -> expect 0x000000AA6F2d3D14680dAdd3E4563F96BcC13bCB
```

The constructor reverts `BadInput()` if the renderer address has no code, so step 2
cannot silently succeed against a missing renderer — but it will consume gas and
fail, so confirm step 1 first.

Step 3 has no ordering constraint at all. `TokenListLens` is stateless and takes
the registry as a call parameter rather than a constructor argument, so its salt
does not depend on either address above, and one deployment serves every
`TokenList` on every chain. That is deliberate: the renderer/registry coupling
already means mining one wrong invalidates both, and extending that chain to a
third contract would have bought nothing.

## Constructor arguments (TokenList)

```
initialOwner  0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2
renderer_     0x000000244989957984A19F27F92eAeb36017D44b

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
