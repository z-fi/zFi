# PrecisionLauncher — deployment runbook

**Status: NOT DEPLOYED. NOT AUDITED.** This file is the pre-flight checklist, not
a record. Do not treat the presence of a runbook as readiness — see "Blocking"
below.

| contract | runtime | initcode | note |
|---|---|---|---|
| `PrecisionLauncher` | 7,289 B | 14,858 B | constructor deploys the token implementation |
| `LaunchToken` | 7,150 B | 7,251 B | ONE implementation; each launch is a 45-byte proxy |
| `PrecisionLauncherLens` | 6,627 B | 7,016 B | pure view, replaceable |

Note the launcher's initcode is roughly double its runtime: the token
implementation's creation code rides in the CONSTRUCTOR, not the deployed body,
which is exactly the saving the clone switch bought (the launcher was 11,088 B
of runtime when it embedded the token). **A CREATE2 salt is mined against that
14,858-byte initcode**, so re-measure it after any edit to either contract —
changing `LaunchToken` moves the launcher's address.

All three sit far under EIP-170; size is not a constraint here, unlike most of
this repo. The 200-run pins in `foundry.toml` are still load-bearing for a
different reason — see "Compiler unit".

## Dependencies (already live)

| contract | address |
|---|---|
| `PrecisionPoolFactory` | `0x000000Eb27B557aB426d9E99cFd54EC455799e81` |
| BETH burner | `0x2cb662Ec360C34a45d7cA0126BCd53C9a1fd48F9` |
| tithe record (DAO) | `0x5E58BA0e06ED0F5558f83bE732a4b899a674053E` |

The last two are **source constants**, not constructor arguments. That is
deliberate: a permanent tithe an operator can repoint is not permanent. The cost
is that this contract is **not portable off Ethereum mainnet** — on a chain
without BETH, `_tithe` falls through to its forced-transfer fallback and the
tenth is sent to a codeless address. Do not deploy elsewhere without changing
those constants and re-reviewing.

## Compiler unit

200 optimizer runs for both files, pinned via `compilation_restrictions` in
`foundry.toml` so a plain `forge build` produces the deployable artifact.

The pin matters even though neither contract is near EIP-170:
`PrecisionLauncher` **embeds `LaunchToken`'s creation code**, so a
differently-optimized `LaunchToken` changes the launcher's initcode and
therefore any mined CREATE2 address. Verify at 200 runs, solc 0.8.36,
`--compilation-profile default`.

`LaunchToken` instances are **PUSH0 minimal proxies** (`LibClone.clone_PUSH0`),
not full deployments — so there is exactly one implementation to verify, cloned
by every launch. Verify `tokenImplementation` once; Etherscan resolves proxies
to it automatically and each clone needs no constructor args, because it has
none: state is set by `initialize` in the same transaction as the clone.

Two consequences of that choice worth carrying into the deployment:

- **PUSH0 means Shanghai or later.** `foundry.toml` already targets Prague, so
  this is satisfied, but it narrows the "do not deploy below Cancun" note in
  `deploy/Precision.md` no further — Cancun already implies PUSH0.
- The implementation is **locked at construction** (`_initializeOwner(0xdead)`),
  so it can never be initialized, its supply can never be minted, and it cannot
  be made to impersonate a launched token. Confirm on-chain after deploy that
  `tokenImplementation.owner() == 0x…dEaD` before announcing anything.

## The check that decides everything

The factory CREATE2s each market from an SSTORE2 blob fixed at ITS deployment.
If this repo's `PrecisionPool` no longer compiles to that blob, the launcher
still works locally while producing markets at addresses nothing else in the
system describes.

```
cast call 0x000000Eb27B557aB426d9E99cFd54EC455799e81 "poolInitCodeHash()(bytes32)"
# must equal 0x897b0181f6b0a84c801ae9934c3e8219c68bd65d46d2d534068ae4cda61cbf10
```

`test/PrecisionLauncherLiveFactory.t.sol::testLocalPoolBytecodeStillMatchesTheLiveFactory`
asserts this against `keccak256(type(PrecisionPool).creationCode)`. **Verified
matching as of this writing.** Re-run it as the last step before broadcasting;
it is the one failure that is silent in every other test.

## Constructor

```solidity
new PrecisionLauncher(PrecisionPoolFactory factory_, address treasury_)
```

- `factory_` — the address above. Constructor rejects a codeless address.
- `treasury_` — **DECIDED: the Zorg Moloch DAO,
  `0x5E58BA0e06ED0F5558f83bE732a4b899a674053E`.** Receives 10% of collected ETH
  fees. Rejected if zero, immutable once set.

  This is the SAME address as the hardcoded `TITHE_RECORD`, so the DAO takes
  20% of the ETH side overall — a tenth paid as ETH, and a tenth as the BETH
  record of the burned tenth. That pairing is the point rather than a
  coincidence: the burn is a social artifact (proof of contribution to ETH
  politics, denominated in BETH) and the DAO takes the other side in cash.
  Verified against the live DAO contract in `testTreasuryAsTheDaoTakesBothShares`
  — it is a minimal proxy, so whether it accepts a plain ETH transfer is a
  property of code nobody in this repo wrote, and worth an assertion rather than
  an assumption.

  It also collapses the asymmetry the external review flagged. With both
  destinations resolving to one address, the constructor argument now buys only
  the ability to move the treasury if the DAO is ever superseded. Left as an
  argument deliberately — misdirecting an operational destination harms only its
  own beneficiary, whereas the tithe is a promise to every buyer — but hardcoding
  it is now a defensible alternative rather than an obviously worse one.

`PrecisionLauncherLens` then takes the launcher address, and can be redeployed
and repointed freely — it is referenced by no contract.

## Blocking before mainnet

1. **Independent security review.** `audit/PrecisionLauncher/PROMPT.md` is the
   brief. Two real defects were found during development by re-reading rather
   than by the suite (see §5 of that file); the discovery rate has not
   demonstrably flattened.
2. ~~Decide `treasury_`.~~ **Done** - the Zorg Moloch DAO, above.
3. **Decide the allocation cap.** 20% today. It dilutes every buyer's floor
   one-for-one, so it is an economic parameter, not a safety one.
4. **Re-run the initcode check above** immediately before broadcast.
5. **First launch should be deliberately small.** There is no owner, no pause,
   and no upgrade: every launch's liquidity is locked in this contract forever,
   so a defect is unrecoverable for every token ever launched, not just the
   next. Treat the first live launch as the real test.

## CREATE2

No salt mined yet. The launcher's address is not consumed by any other
contract's derivation — pools derive from the factory and the market tuple, and
the tuple contains the launcher only as `feeRecipient`. So a vanity address is
cosmetic here, unlike `PrecisionPool`, where the blob hash is structural.

One thing it *would* change: `feeRecipient` is part of every market's CREATE2
preimage, so **redeploying the launcher relocates every future market** and
orphans discovery for the old one — `_byCreator` is keyed on the old address.
Launches made under a previous launcher stay enumerable only through it. Pick
the address once.

## Test inventory

| suite | tests | forked |
|---|---|---|
| `test/PrecisionLauncher.t.sol` | 23 | via repo default |
| `test/PrecisionLauncherLifecycle.t.sol` | 12 | via repo default |
| `test/PrecisionLauncherLens.t.sol` | 13 | via repo default |
| `test/LauncherBrick.t.sol` | 6 | via repo default |
| `test/PrecisionLauncherTithe.t.sol` | 6 | yes — real BETH burner |
| `test/PrecisionLauncherLiveFactory.t.sol` | 6 | yes — self-pinned to 25,745,000 |

Note the last row's pin. The live factory landed in block 25,725,625, **after**
the repo default of 25,640,000, so that suite must pin forward or every test in
it fails against a codeless address. Same class of trap as the `fork_block_number`
note in `foundry.toml`.
