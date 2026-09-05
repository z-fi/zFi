# The L2 mirror — Base (8453) and Robinhood Chain (4663)

What zSwap needs on a chain beyond the quoter and router that were already
there: the Precision pool suite, the three boards, their forwarders and their
views. Mainnet keeps every contract it has; nothing here changes an address
the page uses on chain 1.

Tooling: `script/l2-mirror.mjs` (`build` / `check <chainId>` / `deploy <chainId>`),
manifest and creation payloads under `deploy/l2/`, and per-chain deployment
logs `deploy/l2/deployed.<chainId>.json` with tx hashes and gas.

## Two paths, decided by what the initcode binds

**Replay.** SafeSummoner has identical code at `0x00000000004473e1...` on all
three chains and derives a CREATE2 address from (salt, initcode) alone. A
contract whose creation payload binds nothing chain-specific is therefore
deployed by resending the mainnet calldata in `deploy/<Name>.deploy.calldata.txt`,
and lands at the **mainnet vanity address**. That is the whole Precision pool
suite (the executor `0x25Fc36...` already sits at the same address on every
chain, and the factory itself is the only other dependency) and the two views,
which take the board as a call argument.

**CREATE3.** The three boards take the chain's WETH as a constructor argument,
and Orderbol, Swapbol and PrecisionRoute bind mainnet's WETH as a source
constant. Different initcode means a different CREATE2 address, so these go
through CreateX CREATE3 (`0xba5Ed0...`, same code on every chain), whose
address derives from (deployer, salt) and never from the initcode: one salt,
one address on both L2s, each chain getting its own build. The salts are
prefixed with the deployer and carry a zero guard byte (see
`script/mine-create3.mjs`), and were mined to the same three-zero-byte shape
as the mainnet addresses.

The three that hardcode WETH have L2 sources of their own rather than an edited
original, so the mainnet contracts keep reproducing from their files:

| L2 source | differs from | how |
|---|---|---|
| `src/forwarders/OrderbolL2.sol` | Orderbol | WETH is an immutable constructor argument |
| `src/forwarders/SwapbolL2.sol` | Swapbol | WETH immutable; **no v1 board binding** — the legacy Swapboard only ever existed on mainnet, so the forwarder binds three venues and refuses the v1 fill shape |
| `src/pools/PrecisionRouteL2.sol` | PrecisionRoute | WETH immutable, still bound once at deployment and never read from a caller |

Tests: `test/OrderbolL2*.t.sol` and `test/SwapbolL2.t.sol` are the original
suites bound to a WETH that is NOT the mainnet constant; `test/PrecisionRouteL2*.t.sol`
run the original route suites, including the live-market `routeFromWETH` fork
test, through the L2 variant.

## Deliberately not mirrored

- **PrecisionLauncher / PrecisionLauncherLens / FeeSplitter** — cause coins
  stay mainnet-only for now. The launcher's tithe targets (BETH burner, DAO)
  are source constants that do not exist off mainnet; its own runbook says not
  to deploy it elsewhere without changing them and re-reviewing. The page
  reads `PLAUNCH` as zero on the L2s and withholds launch mode and the
  launcher-backed panels.
- **Swapboard v1** (`0x000000fF3D7A2d...`) — legacy; `SB1` is zero on the
  L2s and the book scan covers one generation there.
- **V4QuoteLens** — binds Uniswap's mainnet V4Quoter; the L2 quoters read v4
  natively and `v4lens` stays zero in the chain table.
- **SLOW, TokenList, ZLISTLENS, WNS** — mainnet-rooted data the page already
  reads through `cfgRead`/`l1Read` from any chain.

## Base (8453) — replay set, live 2026-09-05

Deployer `0x68575B073DE49a94e3E3ACf6F3A0d6E3b66267C7`. Every address is the
mainnet one; `poolInitCodeHash` read back as
`0x897b0181f6b0a84c801ae9934c3e8219c68bd65d46d2d534068ae4cda61cbf10`, matching
mainnet, and every dependent's `factory()` returns the factory.

| contract | address | tx |
|---|---|---|
| PrecisionPoolFactory | `0x000000Eb27B557aB426d9E99cFd54EC455799e81` | `0x1591d23a5c71df039dc625b64fea3c4e5ccec9567588d03556ecccc7a7b210e1` |
| PrecisionZap | `0x000000d193680877a83D3C6bCA73D8726D120c67` | `0xb4a4158dc6fe4b708f998ccef0095b109a7aed0bf6680a9d87b009263863071f` |
| PrecisionPoolLens | `0x000000Bad3a2fa57ed74fa06000573ccddF6B7fB` | `0xfde7d69e463bfd836beff15221131ee8885a51f2e2a78ad818fb841bdc0cb6d8` |
| PrecisionLiquidityLens | `0x000000956bf20A41C54BaE4a4b6F5C8A166DAB4E` | `0x7c67df336b1422205b5039000b1615173d7eb2dcef5268228d47860cbcf60bc4` |
| ConstantSurchargeHook | `0x000000Aee5a5acCFe16088A29A555D93eE42ec03` | `0x684841a923a0690df5be9e00d4cb3a6cc6c9f0f2393fc4ea438221c4a290936f` |
| PrecisionPoolPolicy | `0x00000045fc7b570Be4d71F67219508ebD295EC6D` | `0x2c4c1abeefa80441e80e25692600b3150f62840d5bd6d4e947bcf59a3d7ee763` |
| SwapboardView | `0x000000E0b25449F32f7D9259aC449bA88E78dFCE` | `0x1d27196b8a7c9c581c1b973910ff503ba7b34b649c90e11b76cc83ce264b2f65` |
| FloorboardView | `0x0000004E376e9dB5D9EC28E6711E1a64997C6ba7` | `0x931c0b8ac43ff97d7821df6fc96cb7d8a16346d2c49b40711c328420269e1730` |

Total ~19.7M gas at 0.006 gwei.

## Base (8453) — CREATE3 set

CREATE3 through CreateX, live 2026-09-05. One address per contract on both
L2s. Constructor arguments on Base: WETH `0x4200…0006`; OrderbolL2 and
SwapbolL2 bind the three boards above, PrecisionRouteL2 binds the mirrored
factory and the executor. Every immutable was read back after deployment and
matched.

| contract | address (same on 4663) | tx (8453) |
|---|---|---|
| Swapboard | `0x0000001330435808A906432449D233d482Bc9b60` | `0x4ecdf33e7494f0e335dab1af3ed85f96d2d6e480344e6b1affd373a329025527` |
| Dutchboard | `0x000000fa42d555173395323b2956e9c42EFaEFf2` | `0xdf63c69181adb8cc52794618e12f69630a3ba5141cab3bc61bd71b79931a1a81` |
| Floorboard | `0x000000AC7d32e802B003a31F790eb28Ed3294Bac` | `0xa09a02f32bc6f8a8c72c3fcb746a7eb9e12740a6cd056215b5eefebfb0c17968` |
| OrderbolL2 | `0x0000007a1c93d42dD739E8d6cA9Dabf330934970` | `0xd18e4e1046d8655eb33d01ef070246130b9e296a86d6048f02bfbd533b27de3b` |
| SwapbolL2 | `0x00000032100E634903378DAEED6bA448f35F541a` | `0xce2472a70ce2979c590bd50e551c97024b666096d9ab8838bbe4e6cba8a9e880` |
| PrecisionRouteL2 | `0x000000D14E24e5FC8965bcDE58f21f704C944999` | `0xfd6419ba07590e4a939f8ba0575a4ca26f275c4b4bc9bc2db819cbea3a31e270` |

~31.9M gas at 0.006 gwei. Salts are in `deploy/l2/manifest.json`; the exact
payload each chain deployed is `deploy/l2/<Name>.<chainId>.creation.txt`.

## Robinhood Chain (4663) — replay set, live 2026-09-05

Same deployer, same payloads, same addresses; `poolInitCodeHash` and the
dependents' `factory()` read back as on mainnet.

| contract | address | tx |
|---|---|---|
| PrecisionPoolFactory | `0x000000Eb27B557aB426d9E99cFd54EC455799e81` | `0x93f68d94b16d823d15e7687ee5e86f44859857346f49a7d68780ef23ed5a6497` |
| PrecisionZap | `0x000000d193680877a83D3C6bCA73D8726D120c67` | `0x105dff157c5058eb8c8c4ba7a7606cc03ccafc82fbf16518db4a313fd2334cb7` |
| PrecisionPoolLens | `0x000000Bad3a2fa57ed74fa06000573ccddF6B7fB` | `0x399f849abf05f1f58217542bd69f2040363eec79245b454f9a40d0dcc6c9b153` |
| PrecisionLiquidityLens | `0x000000956bf20A41C54BaE4a4b6F5C8A166DAB4E` | `0x15d1226e493db9a46e25fc3ee220ccf3efe1105551c84c56cb67a537de44f0cf` |
| ConstantSurchargeHook | `0x000000Aee5a5acCFe16088A29A555D93eE42ec03` | `0xdc551d1c2ce8ddfde7f25646b38dddd15c872773a9e2e4857bf056bcdfb13b48` |
| PrecisionPoolPolicy | `0x00000045fc7b570Be4d71F67219508ebD295EC6D` | `0xcd2c5eae1063a6d5018eabb2641b71fb88f818fa2cc9cd23427428e64f7e72c9` |
| SwapboardView | `0x000000E0b25449F32f7D9259aC449bA88E78dFCE` | `0xa238cdf20a728222b4679ed7304b9cb3655c2726d8c728da6ba7cdc97a6ad2dd` |
| FloorboardView | `0x0000004E376e9dB5D9EC28E6711E1a64997C6ba7` | `0x5b80d8467cfe54c5cefe14f2e7f16dc9ef923781e72ff14aa57b21ae74db421d` |

Gas on 4663 is not L2-cheap: the chain quoted 0.39–0.74 gwei during this
deployment, so the replay set cost ~0.008 ETH.

## Robinhood Chain (4663) — CREATE3 set

Same salts, same addresses, Robinhood's WETH `0x0Bd7…AD73`.

| contract | address | tx (4663) |
|---|---|---|
| Swapboard | `0x0000001330435808A906432449D233d482Bc9b60` | `0x2440663e4e29ba9368098a7b73d5e947363b5ddab2a52a691e3d4c6bf6236604` |
| Dutchboard | `0x000000fa42d555173395323b2956e9c42EFaEFf2` | `0x775b00245a20a19123f5c5e997b56e0e0d0766c5d1d9cbc85b1c3276d2ccdb32` |
| Floorboard | `0x000000AC7d32e802B003a31F790eb28Ed3294Bac` | **not yet deployed** |
| OrderbolL2 | `0x0000007a1c93d42dD739E8d6cA9Dabf330934970` | **not yet deployed** |
| SwapbolL2 | `0x00000032100E634903378DAEED6bA448f35F541a` | **not yet deployed** |
| PrecisionRouteL2 | `0x000000D14E24e5FC8965bcDE58f21f704C944999` | **not yet deployed** |

Floorboard, OrderbolL2, SwapbolL2 and PrecisionRouteL2 are **not yet on 4663**:
the deployer ran dry after Dutchboard (0.005 ETH left against ~15M gas at
0.4–0.8 gwei). Fund `0x68575B073DE49a94e3E3ACf6F3A0d6E3b66267C7` with about
0.015 ETH on 4663 and re-run `node script/l2-mirror.mjs deploy 4663`; it skips
what is live and deploys the rest in dependency order at the addresses the
page already carries. Until then the page's book on Robinhood resolves the
boards, but `floorRoutable()` is false there and neither forwarder has code.
