# List stETH, LUSD and ZAMM — src_co multisig tx

One transaction. Three listings, each seated in an existing rank gap next to the
asset it belongs beside, rather than appended to the tail.

## Transaction

| field | value |
| --- | --- |
| to | `0x0000006013dF75A31678B786061C2B54bf531524` (TokenList registry) |
| value | `0` |
| data | contents of [`BATCH-stETH-LUSD-ZAMM.calldata.txt`](./BATCH-stETH-LUSD-ZAMM.calldata.txt) |
| from | `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2` (registry owner) |
| operation | CALL (not delegatecall) |
| gas | 4,298,870 measured; budget 5.5M |

4,964 bytes, selector `0xac9650d8` (`multicall(bytes[])`). sha256 of the CALLDATA
BYTES is `eb4928fa1d0ef168cf234027af87de2f49545194b980d427f59db4a25de15ee1`.

Six calls: `list` then `setLogoSVG` for each token, batched so no listing is ever
briefly visible without its art.

## The three listings

| token | address | color | rank | seats |
| --- | --- | --- | --- | --- |
| stETH | `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` | `0x00A3FF` | 997500 | after wstETH (998000), before rETH (997000) |
| LUSD | `0x5f98805A4E8be255a32880FDeC7F6728C6568bA0` | `0x7B6AD6` | 992500 | after BOLD (993000), before ZORG (992000) |
| ZAMM | `0xE9b1cFEA55BAA219e34301f2F31b9FD0921664ED` | `0xFFFFFF` | 991500 | after ZORG (992000), before zOrgz (991000) |

| token | url | description |
| --- | --- | --- |
| stETH | `https://lido.fi` | Liquid staking token from Lido. Balances rebase as Ethereum staking rewards accrue, so one stETH tracks one staked Ether. Wrap to wstETH for the non-rebasing balance most DeFi integrations expect. |
| LUSD | `https://www.liquity.org` | Stablecoin of Liquity v1, borrowed against Ether at zero interest and redeemable one to one for the collateral behind it. The system is immutable: no governance, no admin keys, no upgrade path. |
| ZAMM | `https://www.zamm.finance` | Community token for zAMM, first launched on v0 of the exchange. |

`name`, `symbol`, `decimals` and `standard` are NOT in the calldata — `list` reads them
from each token and sets `synced = true`, which earns the METADATA READ ONCHAIN chip.
Confirmed against live state: `Liquid staked Ether 2.0` / `stETH` / 18,
`LUSD Stablecoin` / `LUSD` / 18, `ZAMM` / `ZAMM` / 18, all `ERC-20`.

## Art

LUSD and ZAMM use the dapp's own icons from `dapp/index.html` (`LUSD_ICON`,
`ZAMM_ICON`), copied verbatim to
[`dapp/tokenlist/marks/`](../dapp/tokenlist/marks/) and stored as inline data SVGs by
`setLogoSVG`. Only the presentation size changed, 24 -> 32; the geometry is untouched.
Vectors rather than raster, so the whole batch costs 4M gas instead of FWA's 11.2M for
one PNG.

stETH's mark is the wstETH art READ BACK OUT OF THE REGISTRY, not the dapp's
`STETH_ICON`. That icon draws the logo's lower bowl as a single shape at `opacity .6`,
which renders as a flat pale blob at card size and loses the fold; the stored wstETH
art draws the faces separately and reads correctly. Same Lido logo either way — one
brand, two tokens — and the two cards are distinguished by name, symbol and address,
not by art.

## Ranks

The half-step scheme DAI started. Each new listing takes the midpoint of an existing
1,000-wide gap, so nothing is renumbered and every rank stays distinct — which matters,
because ties break by array position and `delist` swap-pops, making tied order
deterministic but not stable. The resulting order, asserted in the test:

    1 ETH  2 WETH  3 wstETH  4 stETH  5 rETH  6 WBTC  7 USDC  8 USDT
    9 DAI  10 BOLD  11 LUSD  12 ZORG  13 ZAMM  14 zOrgz  15 WEI  16 FWA  17 TAC

Remaining headroom in the three touched gaps is now 500 on each side. `rank` is a
uint32; these are round numbers with room to keep halving.

## Verified before signing

`test/BatchListTx.t.sol` executes the exact calldata bytes as the multisig against
live mainnet state:

    forge test --match-contract BatchListTx -vv

- `total()` 14 → 17
- per listing: name / symbol / decimals / account / chainId / colour / rank / url all as intended
- `kind == EVM`, `standard == ERC20` auto-detected, `synced == true` on all three
- descriptions survive `_clean` unclipped
- logos stored as inline `data:image/svg+xml;base64,` URIs
- `ownerOf(id)` is each token itself — listings are soulbound to their subject
- **curation order asserted position by position**, and every rank in the list checked
  strictly descending, so a collision fails the test rather than reordering the page
- `tokenlist.json` +3 — all three are EVM ERC-20s and belong in the integrator feed
- every `tokenURI` renders; cards dumped to `dapp/tokenlist/batch-preview.html`
- a non-owner sending the same bytes reverts

## Note on stETH

stETH is a REBASING token: balances change without a transfer, and integrations that
cache a balance or assume transfer-only accounting will mis-handle it. That is why Lido
ships wstETH, and why the description says so on the card. It does not disqualify the
listing — the registry states facts about the asset — but `tokenlist.json` is consumed
by swap frontends, so the caveat belongs where an integrator will read it.

## Reversing

`setArt(id, …)` re-authors colour, rank, logo, url and description; `setRank(id, …)`
moves one listing alone. Nothing here is frozen, and `delist(id)` wipes an entry —
re-listing yields the same id, since a local id is the address.
