# ZorgConviction deterministic deployment manifest

Status: **NOT DEPLOYED — ARTIFACTS FRESH, FORK-REPLAYED, READY TO BROADCAST**

Conviction voting over the live `TokenList`. zOrg holders bond shares to a listing
id; support accrues, and `ZorgTokenListLens` returns a ranking driven by it.

**This does not touch the deployed registry.** `ZorgConviction` never calls
`setRank` and holds no permission over `TokenList`. The lens can only ever return
ids the registry already lists, so conviction permutes the curated set and can never
add to it or surface something delisted. Both properties are asserted against the
LIVE registry in `test/ZorgConvictionLive.t.sol` and `test/ZorgMinedDeploy.t.sol`.

## Fixed deployment context

| Item | Value |
| --- | --- |
| Network | Ethereum mainnet, chain ID 1 |
| CREATE2 factory | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| Factory entry point | `create2Deploy(bytes creationCode, bytes32 salt)` |
| Deployment call value | `0` |
| Compiler | Solidity 0.8.36, `via_ir = true`; Conviction and its renderer pinned to **200 runs** by `compilation_restrictions` |

## Constructor arguments — all verified live before mining

| arg | value | verified |
| --- | --- | --- |
| `dao_` | `0x5E58BA0e06ED0F5558f83bE732a4b899a674053E` | `shares()` returns the zOrg token below |
| `shares_` | `0x00a6bA94BBb5474725515De88fE04F854f2dCb12` | `transfersLocked()` false, so it passes the H-03 gate |
| `zorgz_` | `0x00000000008835ceF3E0D2333695f288Ee6b63A6` | listed in the registry as zzz |
| `weiNames_` | `0x0000000000696760E15f265e828DB644A0c242EB` | listed in the registry as WEI |
| `tokenList_` | `0x0000006013dF75A31678B786061C2B54bf531524` | live, eleven entries |
| `renderer_` | `0x000000fF3C0e5393AF82B1dba6a4a97b5FB1086B` | deployed at step 3 |
| `receiptArt_` | `0x0000007f4342bdddA2A951b9e181B42328DD1eD9` | deployed at step 2 |
| `halfLife_` | `259200` (**3 days**) | see below |

### Why three days

Conviction converges on its target by closing half the remaining gap each half-life:
`target + gap * 2^-(elapsed/halfLife)`. At three days a bond is 21% effective after
a day, 50% after three, 80% after a week. That is deliberately responsive — the point
is that changes are visible.

The anti-mercenary property does not rest on the half-life. Lock tiers ship at
90/180/365-day exit delays paying 1.1x/1.25x/1.5x, so sustained commitment is priced
into the bond itself. And `setHalfLife` is `onlyDAO`, so this is a starting value:
lengthen it if three days proves too twitchy.

Note that `setHalfLife` carries no bound beyond non-zero. The DAO could set it to one
second, which collapses conviction into a plain token-weighted vote of current
holdings. That is inside the DAO's stated trust model, not a defect — but it means the
guarantee is governance, not mechanism.

## Artifact matrix

| Contract | Status | Expected address | Salt | Initcode hash | Creation | Runtime |
| --- | --- | --- | --- | --- | ---: | ---: |
| ZorgPageStyle | NOT DEPLOYED | `0x000000507b8F2DEE4893269De45652B960061941` | `0x000000…00b6f3be` | `0x20139039…75caff01` | 7,017 | 6,991 |
| ZorgReceiptArt | NOT DEPLOYED | `0x0000007f4342bdddA2A951b9e181B42328DD1eD9` | `0x000000…00bbf733` | `0xd50389c1…4a2c4c48` | 12,869 | 12,843 |
| ZorgConvictionRenderer | NOT DEPLOYED | `0x000000fF3C0e5393AF82B1dba6a4a97b5FB1086B` | `0x000000…002d5b72` | `0x370be461…c01b67d6` | 19,054 | 18,884 |
| ZorgConviction | NOT DEPLOYED | `0x000000aEAB63b69FCeBbbFB0AbB1E629B3118909` | `0x000000…010dc3cb` | `0x90b61cae…9efe909d` | 22,330 | 20,324 |
| ZorgTokenListLens | NOT DEPLOYED | `0x0000008d3e9680Ee6750875D93d2910402AcBD6d` | `0x000000…0028c887` | `0xe988f938…4da37a83` | 6,198 | 5,893 |

Every runtime is comfortably under EIP-170; the tightest is `ZorgConviction` at
4,252 B spare. Sizes were checked in BOTH build modes —
isolated and full `forge build` — because `via_ir` output depends on which files share
a compilation unit, and `TokenList` was re-mined twice over that. These are identical
in both: no sensitivity.

## DEPLOY IN THIS ORDER

Each address is baked into the next contract's creation code, so a contract landing
anywhere unexpected invalidates every salt below it. Confirm `code.length > 0` before
each step.

```
1. ZorgPageStyle           -> 0x000000507b8F2DEE4893269De45652B960061941
2. ZorgReceiptArt          -> 0x0000007f4342bdddA2A951b9e181B42328DD1eD9
3. ZorgConvictionRenderer  -> 0x000000fF3C0e5393AF82B1dba6a4a97b5FB1086B   (carries 1)
4. ZorgConviction          -> 0x000000aEAB63b69FCeBbbFB0AbB1E629B3118909   (carries 2, 3, TokenList)
5. ZorgTokenListLens       -> 0x0000008d3e9680Ee6750875D93d2910402AcBD6d   (carries 4, TokenList)
```

Steps 1 and 2 are independent of each other. The lens at step 5 is a pure read
surface — nothing depends on it, and it can be redeployed freely.

Full values:

- `deploy/ZorgPageStyle.salt.txt` — `0x0000000000000000000000000000000000000000000000000000000000b6f3be`
  initcode keccak — `0x20139039ce75aded6856b7325a6211bbd38dbe1a2636f57482045d8775caff01`
- `deploy/ZorgReceiptArt.salt.txt` — `0x0000000000000000000000000000000000000000000000000000000000bbf733`
  initcode keccak — `0xd50389c1176920ee0ea7118d2023357e74173158eddd7f2bccba313e4a2c4c48`
- `deploy/ZorgConvictionRenderer.salt.txt` — `0x00000000000000000000000000000000000000000000000000000000002d5b72`
  initcode keccak — `0x370be461a535108c6c83af8faef26ccfcbdd09f7acaeca7d4183e3b6c01b67d6`
- `deploy/ZorgConviction.salt.txt` — `0x00000000000000000000000000000000000000000000000000000000010dc3cb`
  initcode keccak — `0x90b61caef0338405edbe7000386a6d7668adc64210968068f2fe293e9efe909d`
- `deploy/ZorgTokenListLens.salt.txt` — `0x000000000000000000000000000000000000000000000000000000000028c887`
  initcode keccak — `0xe988f938b26600e11ca3440cd617a0f8d429258dd3c804e2b861fa1d4da37a83`

## Verification performed

`test/ZorgMinedDeploy.t.sol` forks mainnet at block 25,678,000 — after `TokenList`
was deployed — and pushes each recorded payload through the real SafeSummoner in the
order above. It asserts each address was vacant first, that each lands where this file
says, that the deployed conviction contract reports the right DAO, registry and
half-life, that the lens reads the live eleven-entry list, and that an unvoted list
comes back in exactly the curated order. A second case asserts the registry's
`rankedIds()` is byte-identical before and after the whole stack exists.

`test/ZorgConvictionLive.t.sol` covers the wiring questions a mock registry cannot:
DAO-to-shares consistency, the transfer-lock gate, and that lens output is always a
subset of the curated list.

The salts are only valid for these exact sources. `deploy/ZorgConviction.sources.txt`
records their hashes and the fork replay skips loudly if any of them moves.

## Emergency controls

| control | holder | effect |
| --- | --- | --- |
| `emergencyPause()` | `exec` role, a transferable wei-name credential | blocks allocation INCREASES only; withdrawal and exit stay open |
| `resume()`, `setHalfLife`, `setLockTier`, `setRenderer`, `burnExecRole` | zOrg Moloch | tuning, and retiring the emergency role for good |
| `delist(id)` | the TokenList owner multisig | removes an entry from the conviction view entirely, whatever is bonded to it |

Two separately-keyed organisations, either able to neutralise a bad outcome from its
own side, and no path by which conviction can alter what the registry stores.


## Pending Moloch proposal: `setRenderer`

Queued and waiting on the timelock. Recorded here because the execution arguments
are NOT recoverable from the proposal itself: the Moloch stores only
`proposalId = keccak(op, to, value, data, nonce)`, so `executeByVotes` has to be
handed the preimage. Ours survives only as a `chat` message inside the proposing
multicall (block 25,696,967) — reconstructing it meant scraping printable ASCII
out of that calldata, which is not a procedure to rely on twice.

| field | value |
| --- | --- |
| Moloch | `0x5E58BA0e06ED0F5558f83bE732a4b899a674053E` |
| proposal id | `0xe78a45cec2e9fb4d8c06e31588e61751ee8b01496673519361606ad5c9707d25` |
| `op` | `0` |
| `to` | `0x0000006D936bA3653b8854490E16E782cd32a9a8` (the governor) |
| `value` | `0` |
| `data` | `0x56d3163d0000000000000000000000000000006b980ae5e796b3ef484e767993d0e29979` |
| `nonce` | `0x238f613abfc45402e05ca6cef98099e02b872c173c1ba5ce06c88ea6947acef0` |
| queued | block 25,698,163 — 2026-08-06 20:00 UTC |

Verified: `proposalId(op,to,value,data,nonce)` returns the id above, and the renderer
being installed (`0x0000006b980ae5e796b3ef484e767993d0e29979`) holds 19,700 bytes of code.

```sh
cast send 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E \
  'executeByVotes(uint8,address,uint256,bytes,bytes32)' \
  0 0x0000006D936bA3653b8854490E16E782cd32a9a8 0 \
  0x56d3163d0000000000000000000000000000006b980ae5e796b3ef484e767993d0e29979 \
  0x238f613abfc45402e05ca6cef98099e02b872c173c1ba5ce06c88ea6947acef0
```

**The window is 24 hours wide.** `timelockDelay` and `proposalTTL` are both 86,400,
so this is executable from 2026-08-07 20:00 UTC and expires at 2026-08-08 20:00 UTC.
Miss it and the proposal has to go through voting and queueing again. Check with
`state(id)` before sending rather than trusting the arithmetic above.
