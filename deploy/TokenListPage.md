# TokenListPage deterministic deployment manifest

Status: **DEPLOYED ON ETHEREUM MAINNET, 2026-08-05.**

| | address | tx |
| --- | --- | --- |
| `TokenListPage` | `0x000000B06Bc63Ef8830645D4524cd0d0Ae824b3d` | `0x4968a41b52e7003ca4236d17fdec484d2addd7e39b8c54749445f8f479b68d7b` |
| chunk 1 | `0x78bcf2171c1f9149D85F4c3ABFd76fBc699d406A` | `0x14864d7b6c900873876fe95674db96397908a6f2039ad10c47fb82739d3debed` |
| chunk 2 | `0x38F10F887Ff4B5430Bf02E65534f7C962cd104FE` | `0x40de3c4d83f33b01ba940da0a5b1ab2071dad25911930ab51d9690d46dbe150b` |
| chunk 3 | `0x272606B7c3A6F139bAA4Fb4bDCFDba46185489EB` | `0xf366848f5f9fcf959855ea6a8e4bef66cefa8ffa6b73ffb367baef86517b57bd` |
| chunk 4 | `0x1A3F9255883C8724308adD19A22E5aeF09112Ad0` | `0x5654ad52adcab28f374d3934b4b552c6c596d77743c7f0f1cc8dd1ce637e42c4` |

Deployed via the SafeSummoner CREATE2 factory `0x00000000004473e1f31C8266612e7FD5504e6f2a`
from burner `0xAcFBA7Ce872C6eAD99d535586f84b0D68ADE4082` (discarded after; the page
contract is immutable and ownerless, so the deployer holds no authority over it).

Total 13.79M gas across 5 transactions, ~0.00175 ETH at ~0.10 gwei.

## Verification performed

- Each chunk's onchain code compared byte-for-byte against its build artifact.
- The four chunks concatenated == `dapp/tokenlist/page.html` (56,855 B) BEFORE the
  wrapper was deployed, so the constructor could not bind a broken set.
- `html()` returns 56,855 bytes identical to `page.html`.
- `resolveMode()` == `bytes32("5219")`.
- `request(["tokenlist.json"])` returns 200, `application/json`,
  `max-age=300` (NOT immutable — the list is live), 8 tokens, checksummed addresses.

## Reproduce

```sh
node script/build-tokenlist-chunks.mjs
forge build --force --contracts src/utils/TokenListPage.sol   # optimizer_runs=20, via_ir
node script/build-tokenlist-page-deploy.mjs 0xaa58adcb8cf6c1b2b97df155fb95f16770d74a65a513ac22753506cd62669013
```

Salt `0xaa58adcb…62669013`, initCodeHash `0xd48de9db…fef7b88a`. The salt is only valid
for initcode built at `optimizer_runs = 20` with `via_ir` — any other setting mines a
different address.

## Why the page does not contain its own address

Its address is CREATE2 over its constructor args, which are the data contracts holding
these very bytes. Writing the address into the page changes the bytes, which changes
the chunks, which changes the address — there is no fixed point. The page instead reads
its address from the gateway hostname (`<addr>.w4eth.io`) and says nothing when served
from anywhere else.

## Etherscan

`TokenListPage` is **verified** (`0.8.36+commit.8a079791`, `optimizer_runs = 20`,
`via_ir`, evmVersion `prague`):

    forge verify-contract 0x000000B06Bc63Ef8830645D4524cd0d0Ae824b3d \
      src/utils/TokenListPage.sol:TokenListPage --chain mainnet \
      --compiler-version 0.8.36+commit.8a079791 --num-of-optimizations 20 --via-ir \
      --constructor-args 0x000…406a000…04fe000…89eb000…2ad0

The four data chunks are **not** verified and cannot be. They have no Solidity source:
each one's runtime bytecode IS a slice of `page.html`, returned by a 10-byte
constructor stub, so there is nothing for a source verifier to compile and compare.
That costs nothing in trust — the bytes are public and self-describing (chunk 1 begins
`<!doctype html>`), and the claim that matters is checkable directly:

```sh
P=0x000000B06Bc63Ef8830645D4524cd0d0Ae824b3d
for c in 0x78bcf217… 0x38F10F88… 0x272606B7… 0x1A3F9255…; do
  cast code $c --rpc-url $RPC | cut -c3-
done | tr -d '\n' > chunks.hex
# concatenated chunk code == the bytes html() serves == dapp/tokenlist/page.html
```

Confirmed 2026-08-05: concatenation == `html()` output == 56,855 B.

## Not done here

- `TokenListRenderer` trait fixes (conditional `Per-token Artwork`, `display_type` on
  numerics) are in the source and tested but **not deployed**. They need a fresh
  renderer plus `setRenderer`, which is owned by the 2-of-3 multisig
  `0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2` behind a timelock.
- Etherscan verification of `TokenListPage`.
