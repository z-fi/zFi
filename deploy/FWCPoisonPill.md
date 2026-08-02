# FWCPoisonPill

Guardian poison pill for the FWC collector DAO. One proposal grants the src_co
multisig a single-use delegatecall permit that redeems every FW NFT the vault
holds back to TokenWorks S02 for its unvested partial refund, then sweeps the
vault's ETH into the DAO treasury. A minority-protection safety valve against
continuous-sale manipulation or takeover of the vault portfolio.

Two contracts. Only the proposer is deployed by hand; it deploys the pill.

## FWCPoisonPillProposer

| | |
|---|---|
| address | `0x00001fE2ef7B69Fee2626afF8B8Cba2D18A9f888` |
| deployer | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| salt | `0x0000000000000000000000000000000000000000000000000000000000000459` |
| initcode hash | `0x188a1d7ae31ab400e9a662d3b7f54b4d5a72d6ffec59d185822452633543316f` |
| creation size | 12,492 B |
| runtime size | 8,602 B |
| optimizer | `via_ir`, `optimizer_runs = 9_999_999`, solc 0.8.36 |
| guardian | src_co multisig `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2` |
| status | deployed, source verified on Etherscan |

Two leading zero bytes, one more than FWCKeeper's `0x002d1618...`.

Predicted address confirmed by `eth_call` to `predictCreate2` against the live
SafeSummoner, and independently re-derived from
`keccak256(0xff ++ factory ++ salt ++ keccak256(initcode))[12:]` rather than
trusting a single helper.

## FWCPoisonPill

| | |
|---|---|
| address | `0x55D2cF1fD3cb803c37340CDd4Fd8fC59d750d050` |
| deployer | the proposer's constructor, plain `CREATE` at nonce 1 |
| runtime size | 3,716 B |
| storage slots | **0** |
| status | deployed, source verified on Etherscan |

Not separately deployed and not salted. `new FWCPoisonPill()` in the proposer's
constructor fixes it at `(proposer, nonce 1)`, which is what guarantees the pill
exists before any proposal can reference it — the permit id commits to this
address. `test_PillAddressIsPredictable` asserts the nonce, so the address above
follows from the mined proposer address rather than being assumed.

The zero storage slots matter more than they look: the pill executes under
`delegatecall` in the Moloch's storage context, so any state variable here would
write into DAO storage. Verified mechanically with
`forge inspect FWCPoisonPill storageLayout` (empty table), not by inspection.

## Setup order

1. `create2Deploy` with `FWCPoisonPillProposer.deploy.calldata.txt` → both
   addresses above, in one transaction.
2. Send the proposer **10,000 FWC shares**. `Badges.onSharesChanged` seats it
   automatically, which is what makes `chat()` reachable. Recoverable:
   `reclaim(shares)` returns them to the guardian.
3. Call `selfDelegate()` — votes follow delegation, not balance.
4. `propose()` (members or guardian). Check `previewProposal()` first; it returns
   exactly what the call will create.
5. Vote it through. On execution the DAO mints the guardian one permit.

## The permit (at config = 0)

`setPermit(1, pill, 0, pull(), keccak("FWC_GUARDIAN_POISON_PILL"), GUARDIAN, 1)`

| field | value |
|---|---|
| op | 1 (delegatecall) — the only way the pill acts with the DAO's authority |
| spender | GUARDIAN, and only it: `spendPermit` burns from `msg.sender` |
| count | 1 — one use, then the balance is zero |

`permitId()` reports the id needed right now; it moves with the DAO's `config`,
so a `bumpConfig()` requires re-granting. Governance can disarm at any time with
`setPermit(..., 0)` or `bumpConfig()`.

To spend: `DAO.spendPermit(1, pill, 0, pull(), nonce)` from the guardian.

## Before pulling

Check `burnWindowOpen()` and `recoverable()`. S02 honours `burn` only inside its
vesting window — **ends 2027-02-28 20:06 UTC** — and the refund decays linearly
to zero across it. Outside the window redemptions are skipped and a pull degrades
to the sweep alone; a pull that would move nothing reverts, which rolls the
permit burn back and preserves the single use.

Budget gas: a full pull is ~3.1M (~3.9k per id scanned, ~500k per pass redeemed).
The scan is O(highest FW id), 353 today.

## Notes

- Redemption proceeds never pool in the vault. `burnToDAO` forwards each refund
  straight to the treasury; `sweep()` is a separate mop-up for the vault's idle
  ETH. The pill never holds or moves ETH itself.
- Holdings are discovered by scanning `ownerOf` against the fund, never read from
  the vault's `nftIds`. That index only records the primary-mint path, which
  closed with the mint period; today it returns `[156]` while the vault owns
  three passes, the other two acquired via `execute(FW, 1 ether, remint())`.
- Remints acquired between the vote and the pull are picked up automatically —
  the scan resolves at execution time. Remints acquired *after* the pull need a
  re-grant, which is a re-run of the same `propose()`, not a redeploy.

## Verification

`test/FWCPoisonPill.t.sol`, 12 tests, mainnet fork. `test_EndToEndGovernance`
runs the full path with no `vm.prank(DAO)` shortcut — propose, vote, queue, clear
the 12h timelock, execute, pull — and liquidated 3 passes for 1.638 ETH into the
treasury.

Not audited independently. Recommended before the permit is granted.
