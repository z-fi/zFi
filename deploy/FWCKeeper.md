# FWCKeeper

Permissionless trigger for the FWC collector DAO's recurring treasury chores.
Holds Moloch permits; anyone may poke it; proceeds always land in the vault.

| | |
|---|---|
| address | `0x00A6b579C4dd6B30E1db15B2ba99c8A101632C8a` |
| deployer | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| salt | `0x0000000000000000000000000000000000000000000000000000000000000082` |
| initcode hash | `0x7d73ae03d8a56ec0f1dd85bd0dc0392d1c0b549a17e9f77d69b3536f26cc7097` |
| creation size | 13,361 B |
| deploy gas | ~2,973,522 |
| guardian | src_co multisig `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2` |

Predicted address confirmed by `eth_call` against the live SafeSummoner.

## Setup order

1. `create2Deploy` with `FWCKeeper.deploy.calldata.txt` → the address above.
2. Send it **10,000 FWC shares**. `Badges.onSharesChanged` seats it automatically,
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
