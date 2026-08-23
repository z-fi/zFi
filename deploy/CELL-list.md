# List CELL — src_co multisig tx

One transaction. Adds the CELL cause's governance shares to the TokenList registry at
the tail of the list, after FOLD.

## Transaction

| field | value |
| --- | --- |
| to | `0x0000006013dF75A31678B786061C2B54bf531524` (TokenList registry) |
| value | `0` |
| data | contents of [`CELL-list.calldata.txt`](./CELL-list.calldata.txt) |
| from | `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2` (registry owner) |
| operation | CALL (not delegatecall) |
| gas | 1,167,102 measured; budget 1.6M |

1,444 bytes, selector `0xac9650d8` (`multicall(bytes[])`). sha256 of the CALLDATA
BYTES is `468a42df057ed2a37103220b8936fa5310b1844d05ebb9847c8e7cfd5c90f629`.
(`shasum -a 256` of the hex text file itself is
`37220e73ef832592a5d409cc78fad015824ad96fc36e55ec1e74866f0cf95540` — different thing,
check whichever your tooling gives you.)

## The two calls

`list` passes an empty logo on purpose: `setLogoSVG` base64-encodes the raw markup
onchain and enforces the `xmlns` declaration, so the stored data URI is built by the
contract rather than pasted in. Batched so the listing is never briefly visible
without art.

| # | call | value |
| --- | --- | --- |
| 1 | `list(address,uint24,uint32,string,string,string)` | `(CELL, 0xB62A38, 986000, "", url, description)` |
| 2 | `setLogoSVG(uint256,string)` | `(id, <cell.svg>)` — [`dapp/tokenlist/marks/cell.svg`](../dapp/tokenlist/marks/cell.svg) |

| arg | value |
| --- | --- |
| token | `0xf142CfA6Ca3DFa4A131f12aACEF4890e390d70D6` |
| color | `0xB62A38` (11938360) — the mark's own oxblood bezel band |
| rank | `986000` |
| url | `https://cell.wei.is` |
| description | `A hardware wallet that requires a live pulse, or a drop of fresh blood, to authorize a transaction.` (99 / 256 chars) |

`name`, `symbol`, `decimals` and `standard` are NOT in the calldata. `list` reads them
from the token and sets `synced = true`, which earns the card's METADATA READ ONCHAIN
chip. Confirmed against live state: `CELL Shares` / `CELL` / `18` / `ERC-20`.

## Rank

The tail was FOLD at 987000, so 986000 continues the 1,000 step and seats CELL 19th
and last. No existing rank moves. The test asserts every rank in the list is strictly
descending, so a collision fails rather than silently reordering the page.

## The listing id

A local listing's id is literally its address:

    id = 0xf142CfA6Ca3DFa4A131f12aACEF4890e390d70D6
       = 1377356713950534991442496167848235805409467527382

## What CELL is

Governance shares of the cause DAO at `0xD5dcE9BEE03e69362981afE48323A657fCceB8bE`,
whose own `contractURI` (`ipfs://QmQqFD2JCeLT74q9cTEqJK66tkU5kMAVdggnbjaDmZX8RX`)
states the mandate the description repeats verbatim. DUNA charter, shares sold
continuously through the ShareOffering at `0x000000A4Ad929C9E108aD2B1D2fBeDe0C2Ae57e1`.
This is the curator's own project — a conflict worth naming, though every claim on the
card is checkable from the token and the DAO's own metadata.

## Verified before signing

`test/CellTx.t.sol` both GENERATES the calldata and asserts what it does against live
mainnet state, so the file that gets broadcast is the one that was tested:

    forge test --match-contract CellTx -vv

- `total()` 18 → 19, seated last
- name / symbol / decimals / account / chainId / colour / rank / url / description all as intended
- `kind == EVM`, `standard == ERC20` auto-detected, `synced == true`
- description survives `_clean` byte for byte
- logo stored as an inline `data:image/svg+xml;base64,` URI
- `ownerOf(id)` is the CELL token itself — listings are soulbound to their subject
- every rank strictly descending after the insert
- **`tokenlist.json` token count +1** — CELL is an EVM ERC-20 and belongs in the
  integrator feed
- `tokenURI` renders
- a non-owner sending the same bytes reverts

## Reversing

`setArt(id, …)` re-authors colour, rank, logo, url and description; `setLogoSVG`
re-authors the art alone; `setRank(id, …)` moves the listing. `frozen` is false, and
`delist(id)` wipes the entry — re-listing yields the same id, since a local id is the
address.
