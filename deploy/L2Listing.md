# Listing Base and Robinhood tokens on the canonical TokenList

The token list zSwap shows on Base (8453) and Robinhood Chain (4663) is the
**mainnet** registry at `0x0000006013dF75A31678B786061C2B54bf531524`
(token.list.wei.limo), filtered by chain. The page reads the registry through
its mainnet read path from whatever chain the wallet is on, keeps the rows whose
namespace is `eip155` and whose chain id is the wallet's, and only if that
leaves nothing swappable does it fall back to the built-in list baked into the
page. So the way to change what Base or Robinhood shows is to change the
registry - never the page.

## How a foreign listing works

A token that lives on another chain has no on-chain source the registry can
read, so the owner types its name, symbol and decimals with `listForeign`. Two
things follow from that:

- `listForeign` leaves `standard` as UNKNOWN. The page drops any row that is not
  `ERC-20`, `ERC-721` or `Native`, so a listing MUST be followed by
  `setStandard(id, ERC20)` in the same transaction, or it never appears.
- Decimals are an owner-attested claim. The page re-reads `decimals()` from the
  token on the chain it is on and drops a row that disagrees (and says so in the
  list note), so a typo cannot mis-scale amounts. The generator below reads the
  real values from the chain and refuses to guess.

The listing id is `keccak256(abi.encode(Kind.EVM, chainId, bytes32(token))) | 1<<255`,
a hash of the asset rather than a counter, so delisting and re-listing yields
the same id.

## Generating the transaction

```
node script/build-foreign-listing.mjs --chain 8453 \
  --token 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 --like 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
  --token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf --color f7931a --rank 996000 --extra origin=bitcoin \
  --out deploy/BASE-list
```

Per `--token`, in order: `listForeign` → `setStandard(ERC20)` → `setArt` (url,
description) → `setLogoSVG` → `setExtra` per note, all inside one
`multicall(bytes[])` so a listing is never visible half-built. The batch is
simulated from the owner before anything is written.

- `--like <mainnet token>` copies the mainnet listing's logo, colour and rank and
  records the equivalence as extra `eq = eip155:1:<address>`. Use it for every
  asset that is the same thing on both chains (USDC, USDT, WETH, wstETH, rETH,
  DAI …): the L2 list then reads like the mainnet one, art included.
- `--logo file.svg` for an asset with no mainnet twin. The registry stores the
  markup as a data URL (≤ 24,576 B, must carry the svg namespace).
- `--extra origin=bitcoin` (or any `key=value`, key ≤ 32 bytes) is surfaced by
  the page as "bitcoin origin" in the row's description, so a bridged or
  wrapped asset is never mistaken for the native one. That is how TAC's Bitcoin
  provenance is meant to travel to an EVM representation of it.
- `--rank` defaults to the mainnet twin's rank, else 900000. Higher ranks list
  first. The mainnet convention is 1,000 steps: ETH 1,000,000, WETH 999,000,
  wstETH 998,000 … FOLD 987,000.

Two batches are already generated and verified:

| file | chain | lists |
|---|---|---|
| `deploy/BASE-list.calldata.txt` | 8453 | USDC, USDT, WETH, wstETH, rETH, DAI (with mainnet art), cbBTC (`origin=bitcoin`), cbETH, AERO |
| `deploy/ROBINHOOD-list.calldata.txt` | 4663 | WETH (with mainnet art), USDG, NVDA, DEEP, MARIAN |

Verify a batch before sending it - it replays the exact calldata against a
mainnet fork as the owner and reads every listing back:

```
FOREIGN_LISTING=deploy/BASE-list.calldata.txt forge test --match-path test/ForeignListingTx.t.sol -vv
```

## Sending it from the multisig

In the Safe at `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2` (the registry owner),
"New transaction → Transaction builder" (or any raw-calldata path):

| field | value |
|---|---|
| to | `0x0000006013dF75A31678B786061C2B54bf531524` |
| value | `0` |
| data | the contents of the `.calldata.txt` file, one line, `0x…` |
| operation | CALL (not delegatecall) |

The `.md` beside each calldata file carries the same table plus the listing ids.
Gas is roughly 1M per listing with a logo, 0.3M without; simulate in the Safe and
budget 30% over.

## Iterating

All of these are single owner calls on the same registry, and all take the id
the generator printed:

| want | call |
|---|---|
| reorder | `setRank(id, rank)` |
| new art, link or blurb | `setArt(id, color, rank, "", url, description)` then `setLogoSVG(id, svg)` |
| add or change a note | `setExtra(id, bytes32("origin"), "bitcoin")` |
| remove from the list | `delist(id)` (re-listing later gets the same id) |

zSwap reads the registry on every load, so a change shows on the next page
load with no deployment. The built-in fallback lists in the page (Base: ETH,
WETH, wstETH, rETH, cbETH, cbBTC, USDC, USDT, DAI, AERO; Robinhood: ETH, WETH,
USDG, NVDA, DEEP, MARIAN) exist only for the day the registry is unreachable or
lists nothing for the chain, and carry the mainnet SVG art for the assets that
are the same thing.
