# List DAI — src_co multisig tx

One transaction. Adds Dai Stablecoin to the TokenList registry, seated inside the
stablecoin cluster between USDT and BOLD.

## Transaction

| field | value |
| --- | --- |
| to | `0x0000006013dF75A31678B786061C2B54bf531524` (TokenList registry) |
| value | `0` |
| data | contents of [`DAI-list.calldata.txt`](./DAI-list.calldata.txt) |
| from | `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2` (registry owner) |
| operation | CALL (not delegatecall) |
| gas | 1,358,869 measured; budget 1.8M |

1,604 bytes, selector `0xac9650d8` (`multicall(bytes[])`). sha256 of the CALLDATA
BYTES is `e52175216d9744d4891927456f0b25a968d71a2e9a2c242a0600ffba24de902a`.
(`shasum -a 256` of the hex text file itself is
`f71b0b59a7c19fe814396ed7a541509d3fcb8b6ad0b4233d2b2640fbfcdb4bc2` — different
thing, check whichever your tooling gives you.)

Cheap next to FWA's 11.2M because the mark is a 601-byte vector, not an 8.5 KB raster.

## The two calls

`list` hardcodes an empty logo argument here on purpose: `setLogoSVG` base64-encodes
the raw markup onchain and enforces the `xmlns` declaration, so the stored data URI is
built by the contract rather than pasted in. Batched so the listing is never briefly
visible without art.

| # | call | value |
| --- | --- | --- |
| 1 | `list(address,uint24,uint32,string,string,string)` | `(DAI, 0xF4B731, 993500, "", url, description)` |
| 2 | `setLogoSVG(uint256,string)` | `(id, <dai.svg>)` — [`dapp/tokenlist/marks/dai.svg`](../dapp/tokenlist/marks/dai.svg) |

| arg | value |
| --- | --- |
| token | `0x6B175474E89094C44Da98b954EedeAC495271d0F` |
| color | `0xF4B731` (16037681) — the canonical Dai yellow, taken from the mark itself |
| rank | `993500` |
| url | `https://sky.money` |
| description | 231 / 256 chars, below |

> Decentralized stablecoin soft-pegged to the US dollar and issued by the Maker
> Protocol against onchain collateral. Anyone can mint Dai by locking collateral in a
> vault and burn it to redeem, with no issuer able to freeze a balance.

`name`, `symbol`, `decimals` and `standard` are NOT in the calldata. `list` reads them
from the token and sets `synced = true`, which is what earns the card's METADATA READ
ONCHAIN chip. Confirmed against live state: `Dai Stablecoin` / `DAI` / `18` / `ERC-20`.

## Rank

Ranks are sort *weights*, sparse by 1,000 so a listing can be slotted between two
others without renumbering. The tail of the list is at 988000 (TAC), but appending
there would put the third major stablecoin below a set of long-tail assets. USDT holds
994000 and BOLD 993000, so **993500** uses the existing gap and seats DAI at position
8, directly after USDT. It is the first half-step rank in the list; the sparse scheme
exists for exactly this.

## The listing id

A local listing's id is literally its address:

    id = 0x6B175474E89094C44Da98b954EedeAC495271d0F
       = 611638308582315662494001782126996865111702167823

## Verified before signing

`test/DaiTx.t.sol` executes the exact calldata bytes read back from the file, as the
multisig, against live mainnet state. It both GENERATES the calldata and asserts what
it does, so the file that gets broadcast is the one that was tested:

    forge test --match-contract DaiTx -vv

- `total()` 13 → 14, position 8, directly after USDT and before BOLD
- name / symbol / decimals / account / chainId / colour / rank / url / description all as intended
- `kind == EVM`, `standard == ERC20` auto-detected, `synced == true`
- description survives `_clean` unclipped at its full length
- logo stored as an inline `data:image/svg+xml;base64,` URI
- `ownerOf(id)` is the DAI token itself — listings are soulbound to their subject
- **`tokenlist.json` token count +1** — unlike TAC, DAI is an EVM ERC-20 and SHOULD
  reach the integrator feed
- `tokenURI` renders through the live renderer; card dumped to
  `dapp/tokenlist/dai-preview.html`
- a non-owner sending the same bytes reverts

## Reversing

`setArt(id, …)` re-authors colour, rank, logo, url and description; `setLogoSVG`
re-authors the art alone. `frozen` is false, so nothing here is permanent, and
`delist(id)` wipes the entry — re-listing yields the same id, since it is the address.
