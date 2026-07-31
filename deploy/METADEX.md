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
| Replacement Swapboard | **NOT DEPLOYED** | `0xD3958F4f0610DEEff356193722ceb942BDd20d39` | `0x000000000000000000000000000000000000000000000000000000000000bb4ed7` | `0x3a37851e6aaaeb1570cceaf8c0404dcf55107d65e2f88a3a3c5c2608634ed6f2` | 24,419 B | 24,139 B |
| Dutchboard | **NOT DEPLOYED** | `0xbb84C1875BD0DbB0392Bd6A337E2690060A9321C` | `0x35fa7f853ac5d3e482cea32afdfc4d8e71cd14024b99128a08ad1e11b26525e8` | `0x73d63b8a746f456d0f816056bbc6752ee0ea87d89092eb3fdd69669be66e437e` | 17,395 B | 17,154 B |
| SwapboardView | **NOT DEPLOYED** | `0xF796EF7B108a8DbC8F9650579fAb88BBa00BD296` | `0x00000000000000000000000000000000000000000000000000000000008409e7` | `0xd255af2a37dd789bc6920b252c38eecd1c1646e7c41d1515f91e41614cc77371` | 24,074 B | 24,048 B |
| Orderbol | **NOT DEPLOYED** | `0xf03bE3A900762D7D31e6d69809fd2D54Aa53b2BA` | `0x000000000000000000000000000000000000000000000000000000000000362f` | `0xa020eab931e1ce6d2464adb688fdc5659285976fb7fb4dd5d4f557da9e938c41` | 8,544 B | 8,141 B |
| Swapbol | **NOT DEPLOYED** | `0xa8429A3516E0ad2b0500b2bc7E85BE0262fb2154` | `0x01a9500773adf0551c6646949e9508b5c389411f8fbd53cca1c33ff370a2a023` | `0xd68c9824dbffca8e7f7b62ba5a124c7ce7da69883b4abe5b6255162da366fd97` | 14,629 B | 14,017 B |

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

- Constructor: `constructor(address _weth)`
- Argument: canonical mainnet WETH
  `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`.
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

- Constructor:
  `constructor(address swapboard_, address dutchboard_)`
- Arguments, in order:
  1. replacement Swapboard
     `0xD3958F4f0610DEEff356193722ceb942BDd20d39`;
  2. Dutchboard
     `0xbb84C1875BD0DbB0392Bd6A337E2690060A9321C`.
- Placement calls retain their board argument for ABI compatibility, but it
  must equal the matching immutable deployment binding. The returned order or
  listing ID is checked against the requested maker/seller, assets, amounts,
  terms, and active state before any refund is sent.
- A five-minute placement deadline is used by the zSwap UI; direct callers may
  pass their own deadline or zero to disable that optional bound.
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
     `0xD3958F4f0610DEEff356193722ceb942BDd20d39`;
  3. Dutchboard
     `0xbb84C1875BD0DbB0392Bd6A337E2690060A9321C`.
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
