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
| `src/forwarders/SwapbolL2.sol` | Swapbol | WETH immutable; **no v1 board binding** — the legacy Swapboard only ever existed on mainnet, so the forwarder binds three venues and refuses the v1 fill shape; **admits the L2 routers' AMM vocabulary** (`swapAero`, `swapAeroCL`, `swapDeep`, `sweep(address,uint256,address)`, `deposit(address,uint256)`) instead of mainnet zRouter's |
| `src/pools/PrecisionRouteL2.sol` | PrecisionRoute | WETH immutable, still bound once at deployment and never read from a caller |

Tests: `test/OrderbolL2*.t.sol` and `test/SwapbolL2.t.sol` are the original
suites bound to a WETH that is NOT the mainnet constant; `test/PrecisionRouteL2*.t.sol`
run the original route suites, including the live-market `routeFromWETH` fork
test, through the L2 variant.

## Deliberately not mirrored

- **Causes** — the loot-only DAICO path (`cauGo`, SafeSummoner's
  `safeSummonDAICO` and the Majeur sale, tap and loot contracts behind it) is
  Ethereum-only. Robinhood has none of those contracts and Base has two of six.
  The page disables the Cause option off mainnet and turns a cause back into a
  coin on a chain switch. Coins are a different contract (PrecisionLauncher)
  and ARE mirrored; see "The coin launcher" below.
- **Swapboard v1** (`0x000000fF3D7A2d...`) — legacy; `SB1` is zero on the
  L2s and the book scan covers one generation there.
- **V4QuoteLens** — binds Uniswap's mainnet V4Quoter as a constant, so the same
  bytecode is useless anywhere else. Replaced rather than mirrored, and the
  replacement covers mainnet too: `V4QuoteLensL2` is a CREATE3 entry in the
  manifest with `chains: [1, 8453, 4663]`, live at
  `0x00000000Dc6f467A7AA88e216a904Cf758453EbC` on all three, each build bound to
  its own chain's Uniswap V4Quoter. It is the first entry here that is not
  L2-only, which is what `chains` on a manifest entry exists for. See
  `deploy/V4QuoteLensL2.md`.
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

Same salts, same addresses, Robinhood's WETH `0x0Bd7…AD73`, live 2026-09-06.
Every immutable was read back and matched. The deployer ran dry after
Dutchboard on the first pass; 0.01 ETH was bridged from its mainnet balance
through the chain's Inbox (`0x1A07cc4B…`, `depositEth()`, credited in ~8 min)
and `deploy 4663` resumed from where the log said it had stopped.

| contract | address | tx (4663) |
|---|---|---|
| Swapboard | `0x0000001330435808A906432449D233d482Bc9b60` | `0x2440663e4e29ba9368098a7b73d5e947363b5ddab2a52a691e3d4c6bf6236604` |
| Dutchboard | `0x000000fa42d555173395323b2956e9c42EFaEFf2` | `0x775b00245a20a19123f5c5e997b56e0e0d0766c5d1d9cbc85b1c3276d2ccdb32` |
| Floorboard | `0x000000AC7d32e802B003a31F790eb28Ed3294Bac` | `0x143e8b976384dd0643f69cd25e7ac636c18ffc9d184de9ab004418c5fcd97ee3` |
| OrderbolL2 | `0x0000007a1c93d42dD739E8d6cA9Dabf330934970` | `0x4618f3fabdf273853a4ad80d2e828675f18e4cba54835135ec724ddd7fdb5234` |
| SwapbolL2 | `0x00000032100E634903378DAEED6bA448f35F541a` | `0xc40a00ca361488161d32d74ccf26d1a1ebfb0b72fba66945fd320cfbc298c7e2` |
| PrecisionRouteL2 | `0x000000D14E24e5FC8965bcDE58f21f704C944999` | `0x4c5c444d622c9a5bc06d279b72b66b002d84d821d6c83e4fbca18247c39cf21d` |

~31.9M gas at ~0.4 gwei plus the L1 component, ~0.014 ETH in all.

## SwapbolL2 superseded once (2026-09-06)

The first SwapbolL2 (`0x00000032100E634903378DAEED6bA448f35F541a`, both chains) kept
mainnet zRouter's AMM allowlist in `_validateAmmData`, so any hybrid book+AMM plan whose
remainder was an Aerodrome, Slipstream or Deepstate leg, or used the L2 routers' 3-arg
`sweep` / 2-arg `deposit`, reverted `BadPlan` at preflight. It holds no funds and nothing
points at it. The corrected build lives at `0x000000015d9428959A495E31A6999E1C61C64F00`
on both chains (new CREATE3 salt in the manifest; `supersedes` records the old address),
and the page's `L2B.sw` and its forwarder gate (`BOL_OK`) name the L2 vocabulary.

## The coin launcher (replay set, live 2026-09-15)

Coins are PrecisionLauncher markets, and the launcher replays like the pool
suite: its payload binds only the factory and its treasury, and the treasury is
the FeeSplitter replayed just before it. `REPLAY` in `script/l2-mirror.mjs`
carries all three, in dependency order. Same salt, same bytecode, same address
as mainnet; every runtime's codehash was read back equal to mainnet's.

| contract | address (same on all three chains) | tx (8453) | tx (4663) |
|---|---|---|---|
| FeeSplitter | `0x000000aA142133107c7D2664F900f80e28BbfFbd` | `0x6c26a274ed27a3793271e162d2a22436ffe7d381da71c349081addcc9aac34ec` | `0x48cb269595b6762854092b783a752869a00c857a9f1c864fa083da00620ce06e` |
| PrecisionLauncher | `0x0000002fC8E77585A008Aa45d78A71ad36293aEe` | `0x601761ef8bd4c28956679c322841ea4b640c1129244fc753ab06358c850091d4` | `0x9e00eeb870533b01bf0f9cb9412d615e3ea19acfe22ccddb5e4bfa3f1de7878c` |
| PrecisionLauncherLens | `0x00000041201F1542EE49F9722b2590DEDFE4296B` | `0xf72a83b2b5f98bb44c64facbbfcf8b899805a474ff3b87ddea5e3a763c42119e` | `0x89d0572bc90be7d1a09b64db3227b5bf68e7f35d01b073d4759568f8fa602ee1` |

About 6.0M gas per chain (0.78M, 3.75M, 1.49M). All three, plus the
LaunchToken template the launcher deploys (`0xc931Ea35093De3CD045F69258f107cd567Fe4759`,
the same on both chains), are verified: Etherscan on 8453, Sourcify exact match
on 4663, all at 200 runs with `--compilation-profile default`. A replay's address carries no
sender, so on any further chain with SafeSummoner, the mirrored factory and the
CREATE3 set live, any funded key can send them with
`PRIVATE_KEY=0x… node script/l2-mirror.mjs deploy <chainId>`.

After landing:

- **FeeSplitter has no split.** Its constructor names the ops Safe
  `0x006CD14F…` as owner and nothing else, so the treasury tenth accrues in it
  and `release` reverts until the Safe calls `setSplit`. On mainnet the split is
  the Safe itself at 100%. The Safe on 8453 and 4663 has three owners; mainnet's
  has four (`0x999657A4…` is not on the L2s).
- **The tithe mints no receipt.** `deploy/PrecisionLauncher.md` says where the
  tenth goes on each chain.
- `test/PrecisionLauncherL2.t.sol` replays whatever is not yet live on a fork of
  each chain and runs launch, buy, sell and `collectFees` against it, so it
  holds before and after the broadcast.

The page names the launcher in `L2B.la`, so launch mode, launched-coin
discovery in the token picker, fee collection and the floor readout all run
against the connected chain.

## The three-hop companion (CREATE3, live 2026-09-15)

The L2 quoters have no `build3HopMulticall`, so zSwap asks `zQuoter3HopL2`
(`src/zQuoter3HopL2.sol`) instead: same selector, same arguments, same return
shape as mainnet zQuoter's builder. It prices every leg through the chain's
deployed quoter (`getQuotes`) and only adds routing and router calldata. One
source serves both chains because the quoters' AMM ordinals agree on V2, v3 and
v4, and Aerodrome and Slipstream only ever come from Base.

| chain | address | tx | block | gas |
|---|---|---|---|---|
| 8453 | `0x000000f584434F81fC115b1A59243a4287dB08be` | `0x66ae451708332a7f41858c33a36cbb71fa9cfbc89f98cbbab5558a790bc7a869` | 51340741 | 2,078,003 |
| 4663 | `0x000000f584434F81fC115b1A59243a4287dB08be` | `0x294f8ff207174c196fe302e96c14dfb0fe70b7781f657d636204490062361675` | 63613437 | 2,078,423 |

Constructor arguments per chain are the quoter `0x000000bd2d…`, the router, the
chain's WETH and its hubs: WETH and USDC on Base, WETH and USDG on Robinhood.

**Two hubs, on purpose.** A route asks the quoter once per first hub and twice per
ordered hub pair, and each ask scans every venue. Measured on Base: two hubs build
in 4-7M gas, three in 35-75M, five in 100-350M, for the same routes. Base's
publicnode caps `eth_call` at 50M, so a five-hub build is a route the page never
sees. With WETH as one of two hubs, an ether endpoint has no three-hop route; the
quoter's own two-hop builder covers ether -> hub -> token.

Verified: Etherscan on 8453, Sourcify exact match on 4663 (default profile,
9,999,999 runs). Evidence: `test/zQuoter3HopL2.t.sol` builds and executes routes
through the live routers on forks of both chains; the page asks it for three-hop
routes off mainnet (`test/ui/three-hop-l2.test.mjs`).
