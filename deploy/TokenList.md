# TokenList deterministic deployment manifest

Status: **DEPLOYED AND VERIFIED ON ETHEREUM MAINNET, 2026-08-04. LIST COMPLETE (11/11).**

> **DEPLOYED 2026-08-04.**
>
> | | address | tx |
> | --- | --- | --- |
> | `TokenListRenderer` | `0x000000d595e36Dd0228c4040D981A01A59DbbE87` | deployed first; its address is a constructor arg to the registry |
> | `TokenList` | `0x0000006013dF75A31678B786061C2B54bf531524` | `0xe5e00f9671a8ebe7a0812806d1ad2986e8c2f54f6bd81bef513cfc286c21dd38` |
>
> Registry deployed in block 25,675,344 for 13,469,118 gas at 0.292 gwei (0.003933 ETH).
> Both contracts are **verified on Etherscan**, and each runtime bytecode hash was
> checked against the local build before and after: registry
> `0x10477f53…52897e7f`, matching exactly.
>
> Owner is the 2-of-3 `Multisig` at `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2`
> behind a 3600 s `TimelockExecutor`. Ownership was baked into the initcode, so it
> never passed through an EOA and there was no window of single-key control.
>
> **Post-deploy listings, all applied.** The constructor seeded 4 (ETH, WETH, USDC,
> USDT). wstETH was listed on its own; the remaining six (rETH, WBTC, BOLD, ZORG,
> zOrgz, WNS) went through in ONE batched multisig transaction via the multisig's own
> `batch(address[],uint256[],bytes[])` — target is the multisig itself, since `batch`
> is `onlySelf`. That batch is recorded at `deploy/BATCH-remaining-6.calldata.txt`
> (9,892 B, ~6.62M gas). `total()` is 11, in exact rank order.
>
> **Deployment gotcha worth remembering.** The registry deployment needs ~13.5M gas
> against EIP-7825's 16,777,216 per-transaction cap — only 24% headroom. Any wallet
> padding its gas estimate by 25% or more pushes past the cap, and the node rejects
> it with an opaque `-32603 Internal error` rather than naming the cause. PIN THE GAS
> LIMIT MANUALLY (15,000,000 was used) rather than letting a wallet estimate.
>
> **Interface additions in this build:** `contractURI()` (ERC-7572, forwarded from
> the renderer in assembly), `Locked(uint256)` (ERC-5192, emitted on every listing
> mint), `ContractURIUpdated()`. `contractURI()` is a third member of the interface
> any replacement renderer must implement, alongside `tokenURI` and `json`.
>
> **Still open by choice:** `rendererLocked()` is false, so the card can still be
> improved — including Bitcoin-aware labels reading the `protocol`/`origin` extras.

The recorded initcode and salts below are no longer build TARGETS — they are the
record of what was deployed. Both addresses now hold code, so the vacancy checks
this document used to insist on are spent: re-running the recorded calldata reverts.

## Reproducing the deployed bytecode — THE COMMAND MATTERS

```
forge build src/utils/TokenList.sol src/utils/TokenListRenderer.sol
```

Those two paths, alone. A bare `forge build`, or any `forge test` run, compiles the
sources in a unit that also holds the test contracts, and under `via_ir` that changes
the optimiser's output — hundreds of bytes, from identical source at identical
settings. The deployed bytecode came from the isolated build, so only the isolated
build reproduces it. Foundry does not enforce EIP-170 in tests, so the full-build
variant never announces itself either.

Verified this way on 2026-08-04: renderer 17,025 B and registry 24,243 B, both
byte-identical to `eth_getCode` at the addresses above.

**DO NOT RUN `forge fmt` ON THESE TWO FILES.** Reformatting changes the source, which
changes the metadata hash appended to the bytecode, which changes the deployed
bytecode — a whitespace-only edit silently breaks reproduction against a live,
immutable contract. They are committed exactly as deployed and are deliberately not
`fmt`-clean. `test/TokenListMinedDeploy.t.sol` hashes both sources and skips loudly
if either moves.

## Fixed deployment context

| Item | Value |
| --- | --- |
| Network | Ethereum mainnet, chain ID 1 |
| CREATE2 factory | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| Factory entry point | `create2Deploy(bytes creationCode, bytes32 salt)` |
| Deployment call value | `0` |
| Compiler | Solidity 0.8.36, `via_ir = true`, optimizer **20 runs** (pinned by `compilation_restrictions` in `foundry.toml`, for BOTH files) |
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
| TokenListRenderer | **DEPLOYED** | `0x000000d595e36Dd0228c4040D981A01A59DbbE87` | `0x000000…01b888f4` | `0xe86dc3bd…45a9bd17` | 17,051 | 17,025 |
| TokenList | **DEPLOYED** | `0x0000006013dF75A31678B786061C2B54bf531524` | `0x000000…002febeb` | `0x7729b7f8…5460a3b0` | 37,711 | 24,243 |

Both runtimes are under EIP-170 (24,576 B) and both creation payloads are under
EIP-3860 (49,152 B). `TokenList` retains 11,441 B of initcode headroom and **333 B
of runtime headroom**. That runtime margin is the binding constraint: the via_ir
optimizer moves it NON-MONOTONICALLY with unrelated edits — one enum member cost
601 B in this build while the next three cost 68 B between them — so ANY further
source change needs a `forge build --force --sizes` check BEFORE a salt search, or
the mining time is spent on a payload that cannot deploy.

Full values:

- `deploy/TokenListRenderer.salt.txt` — `0x0000000000000000000000000000000000000000000000000000000001b888f4`
- `deploy/TokenList.salt.txt` — `0x00000000000000000000000000000000000000000000000000000000002febeb`

## DEPLOY THE RENDERER FIRST

The order is not a preference. `TokenList`'s constructor takes the renderer address
as its second argument, so the renderer address is baked into `TokenList`'s creation
code and therefore into its salt and address. Deploying out of order, or deploying a
renderer that lands anywhere other than the address above, invalidates
`TokenList.salt.txt` entirely.

```
1. create2Deploy(TokenListRenderer.creation, TokenListRenderer.salt)
   -> expect 0x000000d595e36Dd0228c4040D981A01A59DbbE87
   -> require code.length > 0 before continuing

2. create2Deploy(TokenList.creation, TokenList.salt)
   -> expect 0x0000006013dF75A31678B786061C2B54bf531524
```

The constructor reverts `BadInput()` if the renderer address has no code, so step 2
cannot silently succeed against a missing renderer — but it will consume gas and
fail, so confirm step 1 first.

## Constructor arguments (TokenList)

```
initialOwner  0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2
renderer_     0x000000d595e36Dd0228c4040D981A01A59DbbE87

abi-encoded tail (already appended to TokenList.creation.txt):
0x000000000000000000000000006cd14f36f65ecbb29b2519ccbe63a0dc8549f2
  000000000000000000000000000000d595e36dd0228c4040d981a01a59dbbe87
```

`TokenListRenderer` takes no constructor arguments.

## Bitcoin-rooted listings

`Standard` ships as `UNKNOWN, NATIVE, ERC20, ERC721, ERC1155, TACIT, RUNE, ORDINAL,
BRC20`. **That set can never grow.** `setStandard` takes the enum by ABI and an
out-of-range value reverts at decode, so unlike `_extra` there is no escape hatch —
anything not named here must be carried as an extension field forever.

All four Bitcoin formats list under `Kind.OTHER` with `chainId == 0` and a 32-byte
account word, and can never be `synced`: no Bitcoin state is readable from the EVM,
so their text is owner-attested and the card says OWNER ATTESTED.

### Account convention — fixed before the first listing

Listing ids are `keccak256(kind, chainId, account)` and permanent, and all four
formats share the single `chainId == 0` namespace, so this cannot be revised later
without orphaning every card minted under the old scheme. The registry cannot
validate a Bitcoin identifier — it cannot see that chain — so this is curator
discipline, pinned by `testBitcoinAccountConventionIsCollisionFree`.

| format | `account` | notes |
| --- | --- | --- |
| Tacit | the 32-byte `asset_id`, verbatim | the only format with a native 32-byte id |
| Runes | `keccak256("rune:<block>:<tx>")` | the Rune ID, decimal, no padding |
| Ordinals | `keccak256("ord:<txid>i<index>")` | full inscription id; `i<index>` present even at 0 |
| BRC-20 | `keccak256("brc20:<ticker>")` | **ticker lowercased** |

Hashing rather than bit-packing, even for Runes where `block:tx` is 96 bits and would
fit: a packed layout is bespoke to this project, still needs a domain tag to stay
collision-free, and cannot be done at all for an inscription id. One rule covering all
four is worth more to an indexer than a reversible layout for the two shortest.

Two normalisations carry real risk if skipped:

- **BRC-20 tickers are case-insensitive and first-deploy-wins.** Hashing them
  unnormalised makes `CAT` and `cat` two listings for one token — the
  duplicate-identity failure this schema already refuses for the native asset (M-01)
  and for Solana mints.
- **Use the Rune ID, never the rune name.** Names carry display-only spacers, so one
  rune has several equally valid spellings and no single canonical string.

For an ordinals COLLECTION rather than a single inscription, use the collection's
parent inscription id, per the ordinals provenance standard.

### Reserved extension keys

Conventions, not contract features — `_extra` takes any `bytes32` key, so these cost
nothing in bytecode or in the frozen ABI and can be set or corrected at any time.

| key | holds |
| --- | --- |
| `ref` | the canonical id string the hashed `account` commits to |
| `protocol` | the metaprotocol (`tacit`, `runes`, `ordinals`, `brc20`) |
| `origin` | where the asset came from, e.g. `tacit:<asset_id>` |
| `factory` | the contract that minted it, for bridged assets |

`origin` and `factory` let a consumer VERIFY lineage itself: check the token was
minted by the canonical factory and reflects the named origin.

**They must never be read as provenance.** `synced` means one specific thing — this
registry read name/symbol/decimals from the account's own contract on this chain, and
anyone may re-run that read permissionlessly. An owner-written extra that could flip
it would launder an assertion into a verified fact, which is the exact confusion this
registry exists to prevent. Extras name WHERE TO LOOK; only `_pull` observing a real
contract moves `synced`. Pinned by `testExtrasCannotUpgradeProvenance`.

For a Bitcoin asset that will later have an EVM address, the honest upgrade path is
`reserve` → `activateReserved`: owner-attested with a stable id while pending, then
read from the bridged contract once it exists, keeping the same id and card. That is
provenance EARNED rather than declared, and it stays live — anyone may `sync` it
afterwards, forever, without the owner.

Set `ref` and `protocol` on every Bitcoin listing, and `freeze` it once correct if the
binding should be permanent: a hashed account is not reversible, so `ref` is the only
record of what it commits to.

## Files

| File | Contents |
| --- | --- |
| `TokenList.address.txt` / `TokenListRenderer.address.txt` | Expected CREATE2 address |
| `TokenList.salt.txt` / `TokenListRenderer.salt.txt` | Mined salt |
| `TokenList.creation.txt` / `TokenListRenderer.creation.txt` | Full creation code, hex |
| `TokenList.initcode.bin` / `TokenListRenderer.initcode.bin` | Same, raw bytes, read by the fork replay test |
| `TokenList.deploy.calldata.txt` / `TokenListRenderer.deploy.calldata.txt` | Exact factory calldata |

## Verification performed

Against a mainnet fork pinned at block `25,640,000` on 2026-08-03, from a completed
`forge build --force` at the pinned 20-run setting:

- `test/TokenListMinedDeploy.t.sol` **passes** (not skips). It compares each recorded
  initcode against a fresh compile, deploys both through the real SafeSummoner at the
  addresses above, asserts owner/renderer wiring, asserts the four constructor seeds,
  applies the seven post-deploy `multicall`s, and asserts the resulting eleven-entry
  list including zOrgz and WNS as ERC-721 collections carrying the onchain-SVG hint.
- `test/TokenListPostDeploy.t.sol` regenerated `TokenList.postdeploy.calldata.txt`
  and asserts every one of the seven transactions fits under EIP-7825's
  16,777,216-gas per-transaction cap.
- Full suites green: 111 TokenList/renderer tests, 57 ZorgConviction/lens tests,
  0 failures, 0 skipped.

Both addresses were vacant on the fork before the replay. **Vacancy is
time-sensitive** — repeat `eth_getCode(expectedAddress) == 0x` against live mainnet
immediately before broadcasting, since these addresses are only reserved by the fact
that nobody else has mined the same payload to them.

An archive RPC is required; `foundry.toml` documents which public endpoints actually
serve archive state at this pin and which fail in ways that look like contract bugs.

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

## Known limitation: display text loses its apostrophes

`_clean` admits printable ASCII minus `" ' \ < > &`, and runs on every text field —
`name`, `symbol`, `url`, `audit`, `description` and extension values — including the
`name()`/`symbol()` read from the token itself. Apostrophes are therefore stripped
BEFORE storage. Verified against the live contract: `Circle's dollar, MakerDAO's peg`
stores as `Circles dollar, MakerDAOs peg`. The typographic `’` does not survive
either, being outside printable ASCII, so there is no substitute character.

A renderer swap CANNOT fix this. The text is filtered on the way in and the
apostrophe never reaches storage, so nothing downstream can recover it. Rewriting a
description re-runs the same filter, so the remedy is to rephrase — `Dollar
stablecoin issued by Circle` rather than `Circle's dollar stablecoin`, which is what
the seeded descriptions already do.

Five of the six characters genuinely have to go: `"` and `\` break a JSON string,
`<` `>` `&` break the XML. The apostrophe is stricter than the current renderer
requires, and deliberately so — the registry is immutable, its renderer is
replaceable, and a future renderer interpolating a name into a single-quoted
attribute is exactly the failure this cannot be patched out of. See the README
section for the full reasoning.

## Editing a live listing: `setArt` is a FULL REPLACE

There is no description-only setter. `description` is reachable only through
`setArt`, which writes `color`, `rank`, `logo`, `url` and `description` together.
Passing `""` for the logo does not mean "leave it alone" — it means "set it empty".
Verified on a fork against the live WETH listing: `setArt` with an empty logo took it
from 1,206 bytes to 0.

To edit one field, read the others from `get(id)` first and re-supply them. To avoid
carrying a multi-kilobyte logo inline, the safer shape is two calls batched
atomically through the owner multisig:

```
1. setArt(id, color, rank, "", url, newDescription)
2. setLogoSVG(id, svg)
```

`setLogoSVG` touches nothing but the logo, so it is safe on its own. `setRank`,
`setAudit`, `setStandard`, `setOnchainSvg` and `setExtra` are likewise single-field.


## Listings

| # | symbol | rank | listed |
| --- | --- | --- | --- |
| 1–11 | ETH, WETH, wstETH, rETH, WBTC, USDC, USDT, BOLD, ZORG, zzz, WEI | 1000000 … 990000 | at/after deploy |
| 12 | FWA | 989000 | 2026-08-05 — see [FWA-list.md](./FWA-list.md) |

Ranks are sort WEIGHTS, sparse by 1,000, so a listing slots between two others without
renumbering. Next in line gets 988000.
