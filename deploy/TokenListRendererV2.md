# TokenListRenderer v2 — candidate

Status: **NOT DEPLOYED.** Mined and verified against mainnet state; awaiting a deploy
and a `setRenderer` from the multisig.

| | |
| --- | --- |
| address | `0x00000058b2462d824a380F1156fE19E3F082a395` (3 leading zero bytes) |
| salt | `0xc30aded664686202772fe418fbc2b2c448028fe46703b772bf6d8bee0e44b4b1` |
| initCodeHash | `0x13be007fd137b139224240c8de837ca1d28fc185b9fb108c13f31097e331f454` |
| runtime | 16,930 B — 95 B **smaller** than the live renderer |
| compiler | `0.8.36+commit.8a079791`, `optimizer_runs = 20`, `via_ir`, evm `prague` |

The live renderer stays recorded in `deploy/TokenListRenderer.*` and remains
`0x000000d595e36Dd0228c4040D981A01A59DbbE87` until the swap happens. Do not overwrite
those files with this candidate — they are the record of what mainnet actually runs.

## What it changes

Two trait fixes, both visible only to marketplaces. Nothing the dapp reads changes.

1. **`Per-token Artwork` is emitted only on ERC-721/1155.** The field is meaningless on
   a fungible — the registry will not even let it be set there — but it was emitted on
   every listing, reading "Not declared" on ERC-20s. That pooled "collection that did
   not declare onchain art" with "fungible, where the question is undefined", and
   OpenSea counted it as a shared trait across 82% of the collection.
2. **`Sort Weight` and `Decimals` carry `display_type: "number"`.** Without it a
   marketplace buckets a number as a category: every listing has a distinct weight, so
   every one displayed "1, 9%" and the curation ordering was invisible.

## Verified against mainnet, not fixtures

`test/TokenListRendererSwap.t.sol` forks mainnet, deploys this candidate, calls
`setRenderer` as the real owner, and diffs all 11 live listings:

```
json() byte-identical on all 11    <- the deployed dapp parses this; the page is immutable
contractURI unchanged              <- dapp subtitle and OpenSea collection blurb
card art identical on all 11
11 listings gained display_type
9 listings shed Per-token Artwork  <- the non-collections; both collections keep it
```

## Deploy

```sh
cast send 0x00000000004473e1f31C8266612e7FD5504e6f2a \
  "$(cat deploy/TokenListRendererV2.deploy.calldata.txt)" \
  --private-key <deployer> --rpc-url <rpc>      # ~3.6M gas

# confirm it landed before touching the registry
cast code 0x00000058b2462d824a380F1156fE19E3F082a395 --rpc-url <rpc> | wc -c

# then, from the 2-of-3 multisig 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2:
#   setRenderer(0x00000058b2462d824a380F1156fE19E3F082a395)
```

`setRenderer` calldata: `0x` + selector + padded address —

```
0x56d3163d00000000000000000000000000000058b2462d824a380f1156fe19e3f082a395
```

Reproduce the artifacts:

```sh
forge build --force
node script/build-create2-artifact.mjs TokenListRenderer \
  0xc30aded664686202772fe418fbc2b2c448028fe46703b772bf6d8bee0e44b4b1
# then rename deploy/TokenListRenderer.* -> deploy/TokenListRendererV2.*
```
