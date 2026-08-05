# List FWA — src_co multisig tx

**Executed 2026-08-05.** Confirmed on chain: `total()` is 12, FWA sits at position 12
after WEI, `ownerOf` is the FWA token itself, standard auto-detected `ERC-20`,
`synced: true`, and the stored logo is byte-identical to
`dapp/tokenlist/marks/fwa.uri.txt`.


One transaction. Adds Fake World Assets to the TokenList registry at position 12,
immediately after WEI.

## Transaction

| field | value |
| --- | --- |
| to | `0x0000006013dF75A31678B786061C2B54bf531524` (TokenList registry) |
| value | `0` |
| data | contents of [`FWA-list.calldata.txt`](./FWA-list.calldata.txt) |
| from | `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2` (registry owner) |
| operation | CALL (not delegatecall) |
| gas | ~11.2M measured — set the limit deliberately, see below |

The calldata is 9,124 bytes — nearly all of it the logo. Its sha256 is
`c2c8ddc79a1ffc020cc8e4b7a6bb4b492165a61c86f3be221f68c9979f329dfc`; check that after
pasting, since a truncated paste of a blob this size still decodes to a *valid* call
with a corrupt logo.

## What it calls

`list(address,uint24,uint32,string,string,string)` — selector `0x6c37705d`.

| arg | value |
| --- | --- |
| token | `0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845` |
| color | `0xf2a0c0` (15900864) |
| rank | `989000` |
| logo | `data:image/png;base64,…` — 8,522 B, 35% of `LOGO_MAX` |
| url | `https://www.fwa.fun` |
| description | see below (232 / 256 chars) |

> Fake World Assets is an onchain protocol pairing NFTs with ETH-backed positions via
> randomised acquisition. FWA is its fixed-supply reward token. Transfers are locked:
> it moves only through its Uniswap V4 pool, not wallet to wallet.

`name`, `symbol`, `decimals`, and `standard` are NOT in the calldata. `list` reads them
from the token itself and sets `synced = true`, which is what earns the card's
METADATA READ ONCHAIN chip. Confirmed on a fork: `Fake World Assets` / `FWA` / `18` /
`ERC-20`.

## Rank

Ranks are sort *weights*, sparse by 1,000 so a listing can be slotted between two
others without renumbering. WEI holds 990000 at position 11, so 989000 puts FWA
directly below it and leaves the usual gap for whatever comes next.

## Verified before signing

Simulated against live mainnet state, as the multisig, using the exact calldata bytes
rather than a re-encoding of the arguments:

- `total()` 11 → 12
- position 12, directly after WEI
- `ownerOf(listing)` is the FWA token itself — listings are soulbound to their subject
- standard auto-detected `ERC-20`, `synced: true`
- a non-owner sending the same calldata reverts
- the live renderer at `0x0000009650f4aEF08AdB2De98bdD2695A41eDcF4` embeds the PNG into
  the card SVG (10.7 KB card)

## The transfer lock

FWA is not freely transferable. Verified on a fork:

```
holder -> holder  transfer()  ->  revert 0x2f352531  InvalidTransfer()
owner  -> anyone  transfer()  ->  ok
```

`_afterTokenTransfer` permits only mints, burns, the owner, addresses flagged
`isDistributor`, and the Uniswap V4 PoolManager (capped per-tx by a transient allowance
the hook bumps). Everything else reverts — the source comment calls it "the lock".

This is deliberate protocol design, not a defect, and it does not disqualify the
listing. It matters because `tokenlist.json` is consumed by swap frontends: FWA is
swappable on its pool but will revert in any flow that assumes ERC-20 transferability
(vaults, bridges, plain sends). Hence the disclosure in the description.

Supply is genuinely fixed — the contract has no `mint` function, only `burn`. The owner
`0x019817aD02a31B990433542097bE29D97613E8Cb` can move FWA freely and set distributors;
it has not been inspected.

## Gas

The simulated call used **11,198,721 gas** — roughly a third of a block. Almost all of
it is `SSTORE` for the 8,522-byte logo: ~266 words at 20k gas each is ~5.3M before
anything else. This is inherent to storing the art on chain, not a defect in the call.

Two consequences for signing:

- Set the gas limit explicitly. Safe's estimator has to simulate an 11M-gas call and can
  come back low or fail to estimate; a limit that is too low burns the fee and lists
  nothing. Budget ~13M.
- Pick the moment. At 5 gwei this is ~0.056 ETH; at 30 gwei it is ~0.34 ETH. Nothing
  about the listing is time-sensitive.

## Reversing

`setArt(id, …)` re-authors colour, rank, logo, url, and description; `frozen` is false,
so nothing here is permanent. The listing id is
`918413654914014884208350033397884031592738900037`.
