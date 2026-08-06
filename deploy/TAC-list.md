# List TAC — src_co multisig tx

The registry's first non-EVM listing. One transaction: a `multicall` of four
owner calls, atomic.

## Transaction

| field | value |
| --- | --- |
| to | `0x0000006013dF75A31678B786061C2B54bf531524` (TokenList registry) |
| value | `0` |
| data | contents of [`TAC-list.calldata.txt`](./TAC-list.calldata.txt) |
| from | `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2` (registry owner) |
| operation | CALL (not delegatecall) |
| gas | ~1.05M measured; budget 1.4M |

2,052 bytes, selector `0xac9650d8` (`multicall(bytes[])`). sha256
`49875be27a5a9baa2f06509193f40854142a2f750409a0077cd0e7d5e6eca22c`.

Far cheaper than the FWA listing (11.2M gas) because the TAC mark is a 465-byte
vector rather than an 8.5 KB raster.

## The four calls

`listForeign` does not set `standard`, and it hardcodes empty url and description,
so three follow-ups are needed. Batched so the listing is never briefly visible in a
half-built state.

| # | call | why |
| --- | --- | --- |
| 1 | `listForeign(OTHER, 0, assetId, "Tacit Coin", "TAC", 8, 0xf7931a, 988000, "")` | creates the entry |
| 2 | `setStandard(id, TACIT)` | `listForeign` leaves standard UNKNOWN |
| 3 | `setArt(id, 0xf7931a, 988000, "", url, description)` | url + description |
| 4 | `setLogoSVG(id, <tac.svg>)` | logo alone; `setArt` is a full replace |

`chainId` is 0, not 1: a non-EVM namespace carries no eip155 id, and `listForeign`
enforces it. Rank 988000 continues the 1,000 step below FWA.

## The listing id

    id = keccak256(abi.encode(Kind.OTHER, uint64(0), assetId)) | (1 << 255)
       = 104165018710067097353655755692819801489527232022561016148205125677286991358696
       = 0xe64b4fb0dbc77241a053efc73e6e9fa65d5d15c48f4e018aa9d8fb0957086ae8

Derived offline and cross-checked against a fork execution — they agree. Because the
id is a hash of the asset rather than a counter, delisting and re-listing yields the
SAME id. See the lifecycle test.

## The Bitcoin data, independently verified

    asset_id   f0bbe868af10c6c67652a99709bf32048d1aa7194efe3e9a1ef1bde43f94762b
    etch txid  e2d10be19c2b73b86e14be99dc237a3d999ba3dfbe6f3e3714590acee2ca481e
    block      948242, 2026-05-07 01:32 UTC, confirmed, Taproot witness

- `SHA256(etch_txid_internalLE || vout_LE4(0))` reproduces the asset id exactly,
  recomputed from scratch. The id is a hash of the transaction that created the
  asset, so no indexer can relabel TAC.
- Supply opens to exactly 21,000,000. Verified with an independent secp256k1
  implementation: the domain-separated NUMS generator H derived from
  `SHA256("tacit-generator-H-v1")` matched the pinned KAT `02bd7bf4…5e56`, and
  `pedersenCommit(2100000000000000, 0xce741e62…7e48)` reproduced the on-chain
  commitment `02f5a454…ffc64` byte for byte.
- `mint_authority` is zero, so no further TAC can ever validate. (From the project's
  own verifier; the witness envelope was not decoded by hand.)
- `name` and `decimals` come from the IPFS attestation
  `bafkreig7m5j66zlaewjvo6bipk723udgdhnyl7ve5k2suofuvhi2mmb3ai`, not from the curator.

Note a SPEC inconsistency found while verifying: §4 says `reveal_txid_BE` while §3638
says `etch_txid_LE`. Only the little-endian (internal) reading yields the correct
asset id; big-endian gives `d8693c01…`. An implementer following §4 would get it wrong.

## Verified before signing

Executing the exact calldata bytes as the multisig against live mainnet state:

- `total()` 12 -> 13, position 13, after FWA
- name / symbol / decimals / account / url / logo / description all as intended
- `kind == OTHER`, `standard == TACIT`, `chainId == 0`
- `synced == false` — the card reads ATTESTED, not METADATA READ ONCHAIN, which is
  correct: Ethereum cannot read Bitcoin
- `ownerOf` is the registry itself; a foreign listing has no local account to hold it
- `tokenURI` renders
- **`tokenlist.json` token count unchanged at 9** — TAC cannot leak into the
  integrator feed, which filters `kind == EVM && standard == ERC20`
- a non-owner sending the same bytes reverts

## Reversing

`delist(id)` wipes the entry, clears extras, unbinds, and burns the NFT. Re-listing
restores the same id. `frozen` is false, so `setArt` / `setLogoSVG` re-author freely.

## Disclosure

TAC is the curator's own platform token. That is a conflict worth naming, though the
listing's factual claims are checkable by anyone from Bitcoin and IPFS alone, which is
unusual for an attested listing.
