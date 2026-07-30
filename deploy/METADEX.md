# MetaDEX deterministic deployment manifest

Status: **NOT DEPLOYED**

This manifest covers the five new contracts that complete the current
Swapboard/Dutchboard hybrid. The addresses below are frozen deterministic build
targets derived from the exact recorded initcode and salt. They are not
evidence of mainnet deployment or present address vacancy. Before every
deployment, require `eth_getCode(expectedAddress) == 0x`, simulate the exact
calldata, and verify the receipt and runtime code afterward.

## Fixed deployment context

| Item | Value |
| --- | --- |
| Network | Ethereum mainnet, chain ID 1 |
| CREATE2 factory | SafeSummoner `0x00000000004473e1f31C8266612e7FD5504e6f2a` |
| Factory entry point | `create2Deploy(bytes creationCode, bytes32 salt)` |
| Deployment call value | `0` |
| Canonical WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| Legacy Swapboard v1 | `0x000000fF3D7A2d373615141d7489Ca66683DbecF` |
| Deprecated intermediate Swapboard | Excluded from discovery and execution |

The deterministic address is
`CREATE2(SafeSummoner, salt, keccak256(creationCode))`. The
`*.deploy.calldata.txt` files already encode the exact factory call. A salt is
valid only for its matching creation payload; any Solidity, compiler,
constructor, metadata, or linked-library change requires rebuilding and
re-mining.

The four state-mutating contracts use Cancun-era transient storage directly or
through their composition path; SwapboardView is read-only. The intended
deployment target is mainnet.

## Artifact matrix

The following values are frozen and cross-checked against the matching files in
`deploy/`. Every status remains **NOT DEPLOYED** until a successful mainnet
receipt and runtime-code verification are recorded.

| Contract | Status | Expected address | Salt | Initcode hash | Creation | Runtime |
| --- | --- | --- | --- | --- | ---: | ---: |
| Replacement Swapboard | **NOT DEPLOYED** | `0x0000006c0fBc8CBAe822c41C9DC00956D0941e23` | `0x0000000000000000000000000000000000000000000000000000000000bb4ed7` | `0xe83076a3e283edfa1586be975dea40a97dc44d6ef63417455f67876390166de2` | 17,988 B | 17,708 B |
| Dutchboard | **NOT DEPLOYED** | `0x000000b87444cAd0beb79545dcaE8b4508d48179` | `0x35fa7f853ac5d3e482cea32afdfc4d8e71cd14024b99128a08ad1e11b26525e8` | `0x4f5753ab664bcb2227f958a865f46cf5637c1b8004587ed4b6879ffd556c5a9c` | 12,066 B | 12,040 B |
| SwapboardView | **NOT DEPLOYED** | `0x000000B95ee642F1A216ef85b54BF77C127b1F50` | `0x00000000000000000000000000000000000000000000000000000000008409e7` | `0x0a00192f07ea9ca2465f312344e5fd4d576f9bb201e533666415e87bf61d3044` | 24,056 B | 24,030 B |
| Orderbol | **NOT DEPLOYED** | `0x0000000B98f59027FAFEac53daEf59D1135e1502` | `0x00000000000000000000000000000000000000000000000000000000018ce12f` | `0xe9343bc4a6d07ad48e6b7e6d1f927a83012b424ecaf922ee4caf06fad662c972` | 3,489 B | 3,463 B |
| Swapbol | **NOT DEPLOYED** | `0x00000040Ba80f8dc500d10ea6cF889b518592756` | `0x1a9500773adf0551c6646949e9508b5c389411f8fbd53cca1c33ff370a2a023c` | `0x5388da1b374914d8383bafc9cd511eb58ef78f5d41247f37a009a262bdb7ec80` | 7,412 B | 6,877 B |

Runtime size means deployed bytecode from the canonical production compiler
profile. Initcode hash means `keccak256` of the complete
`*.creation.txt`, including constructor arguments.

## Constructors and dependencies

### Replacement Swapboard

- Constructor: `constructor(address weth_)`
- Argument: canonical mainnet WETH
  `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
- External prerequisite: canonical WETH already has code.
- Artifacts:
  - `deploy/Swapboard.address.txt`
  - `deploy/Swapboard.salt.txt`
  - `deploy/Swapboard.creation.txt`
  - `deploy/Swapboard.deploy.calldata.txt`
- `out/Swapboard.creation.txt` is a distribution mirror and must be
  byte-identical to `deploy/Swapboard.creation.txt`; the `deploy/` copy is the
  manifest input.

### Dutchboard

- Constructor: none.
- Canonical mainnet WETH is compiled into the runtime for native cancellation
  and routing.
- NFTs may be listed two ways: `listNFT` for bundles, which needs an ERC-721
  approval, and a push listing that needs none — `safeTransferFrom` into the
  board carrying an ABI-encoded `PushTerms` as the transfer's `data`. See the
  contract for why there is no `listNFTFor`.
- Any source edit moves this address. Solidity appends a CBOR metadata hash
  derived from the source text, so even a comment-only change produces
  different creation code and invalidates `Dutchboard.salt.txt`. Re-mine and
  regenerate the artifacts before deploying, and remember that `Swapbol`
  embeds this address in its own creation code and must be re-mined after.
- Artifacts:
  - `deploy/Dutchboard.address.txt`
  - `deploy/Dutchboard.salt.txt`
  - `deploy/Dutchboard.creation.txt`
  - `deploy/Dutchboard.deploy.calldata.txt`

### SwapboardView

- Constructor: none.
- No deployment-time venue binding. Read calls receive legacy/current
  Swapboard and Dutchboard addresses explicitly.
- Artifacts:
  - `deploy/SwapboardView.address.txt`
  - `deploy/SwapboardView.salt.txt`
  - `deploy/SwapboardView.creation.txt`
  - `deploy/SwapboardView.deploy.calldata.txt`

### Orderbol

- Constructor: none.
- No deployment-time board binding. Each placement call names its target
  board; exact scoped approval and funded-balance checkpoints enforce the
  transaction boundary.
- Canonical mainnet WETH is compiled into the runtime for native Dutch lots.
- Artifacts:
  - `deploy/Orderbol.address.txt`
  - `deploy/Orderbol.salt.txt`
  - `deploy/Orderbol.creation.txt`
  - `deploy/Orderbol.deploy.calldata.txt`

### Swapbol

- Constructor:
  `constructor(address boardV1_, address boardCurrent_, address dutchboard_)`
- Arguments, in order:
  1. legacy v1
     `0x000000fF3D7A2d373615141d7489Ca66683DbecF`;
  2. replacement Swapboard
     `0x0000006c0fBc8CBAe822c41C9DC00956D0941e23`;
  3. Dutchboard
     `0x000000b87444cAd0beb79545dcaE8b4508d48179`.
- The constructor rejects zero, duplicate, or code-less venues. Replacement
  Swapboard and Dutchboard must therefore be deployed before Swapbol.
- Frozen artifacts:
  - `deploy/Swapbol.address.txt`
  - `deploy/Swapbol.salt.txt`
  - `deploy/Swapbol.creation.txt`
  - `deploy/Swapbol.deploy.calldata.txt`

## Required deployment order

1. Reconfirm that sources, compiler settings, artifacts, and constructor
   arguments still match this frozen manifest.
2. Check the SafeSummoner runtime and verify all five expected addresses are
   empty at the deployment block. Simulate the independent Swapboard,
   Dutchboard, SwapboardView, and Orderbol calldata with zero value.
3. Deploy and verify replacement Swapboard and Dutchboard. SwapboardView and
   Orderbol may be deployed in either order after their own preflight.
4. Once legacy v1, replacement Swapboard, and Dutchboard all have the expected
   runtime code, simulate the exact Swapbol calldata. Its constructor otherwise
   rejects code-less dependencies.
5. Deploy Swapbol with zero value.
6. Verify every receipt, returned address, deployed runtime hash, runtime size,
   immutable/constructor read, and `eth_getCode`.
7. Regenerate zSwap's on-chain HTML chunks and wrapper artifacts from these
   target constants, but publish the five addresses as live only after the
   mainnet runtime checks succeed.

## Final freeze checklist

- [x] Every table value above is copied from the final matching artifact.
- [x] `keccak256(*.creation.txt)` matches the recorded initcode hash.
- [x] Each SafeSummoner calldata file decodes to its matching creation code and
      salt.
- [x] Recomputed CREATE2 address matches `*.address.txt`.
- [x] Runtime size is below EIP-170's 24,576-byte limit.
- [x] Swapboard creation code ends with the ABI-encoded canonical WETH argument.
- [x] Swapbol creation code ends with legacy v1, replacement Swapboard, and
      Dutchboard in constructor order.
- [x] `deploy/Swapboard.creation.txt` and
      `out/Swapboard.creation.txt` are byte-identical.
- [ ] All five expected addresses are empty before deployment.
- [ ] Exact factory calls simulate successfully with `value == 0`.
- [ ] Mainnet receipts and runtime hashes are recorded after deployment.

Until every deployment receipt and runtime check is complete, the status of
each contract in this file remains **NOT DEPLOYED**.
