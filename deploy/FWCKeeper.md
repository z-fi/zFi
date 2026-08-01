# FWCKeeper

Permissionless trigger for the FWC collector DAO's recurring treasury chores.
Holds Moloch permits; anyone may poke it; proceeds always land in the vault.

| | |
|---|---|
| address | `0x002d1618D1a198F581a709837f25a88c951D515C` |
| deployer | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| salt | `0x00000000000000000000000000000000000000000000000000000000000001ca` |
| initcode hash | `0x1ef2933ecb191cb22f2fc101fa70ba10e6d8ef4fe24a2cccce3f69d0df77304c` |
| creation size | 14,750 B |
| deploy gas | ~2,973,522 |
| guardian | src_co multisig `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2` |

Predicted address confirmed by `eth_call` against the live SafeSummoner.

## Setup order

1. `create2Deploy` with `FWCKeeper.deploy.calldata.txt` → the address above.
2. Send it **10,000 FWC shares** (recoverable — `reclaim(shares)` returns them to the guardian).
    `Badges.onSharesChanged` seats it automatically,
   which is what makes `chat()` reachable — no badge proposal needed.
3. Call `selfDelegate()` (`0x3f0a52ff`) — votes follow delegation, not balance.
4. Grant permits, either by proposing from the dapp or by letting the keeper
   author its own proposal via `proposeClaimPermit` / `proposeRemintPermit`.

## Permits (at config = 0)

| permit | nonce | id |
|---|---|---|
| fee claim | `keccak("FWC_FEE_CLAIM_156")` | `0x11d269afc91497978dc22a1214655d50fa7ec712900d2113951e54e01f2caea9` |
| remint | `keccak("FWC_REMINT")` | `0x1f10b9e9c924c59fc19dc29bb3517d21607b0e5021886b5da0b43170a3b984e3` |

Both ids move with the DAO's `config`, so an emergency bump requires re-granting.
`claimPermitId()` / `remintPermitId()` always report the ids needed right now.

## Supersedes

`0x00A6b579C4dd6B30E1db15B2ba99c8A101632C8a` — deployed and verified, then abandoned
before any grant. It had no way to move a token or a wei, so shares sent to it for
proposal rights would have been burnt. Do not fund it.
