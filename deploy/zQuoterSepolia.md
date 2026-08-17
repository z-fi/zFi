# zQuoterSepolia

A minimal quoter for the zRouter on **Sepolia (11155111)**, so integrators can try
the zRouter + zQuoter pairing without a mainnet position.

| | |
|---|---|
| Address | `0x2ef402B070C7e0869FDB9c4EBc9B09e471ebD755` |
| Deploy tx | `0x33db618d572930dcb6bef93641df49f51580ee8dff94f39f747acb19630a2cfd` |
| Deployer | `0xAcFBA7Ce872C6eAD99d535586f84b0D68ADE4082` (nonce 0) |
| Source | [`src/zQuoterSepolia.sol`](../src/zQuoterSepolia.sol) |
| Compiler | solc 0.8.36, via_ir, optimizer 9,999,999 — the **default** profile |
| Runtime size | 13,421 B (11,155 B under EIP-170) |

Deployed runtime bytecode was compared byte-for-byte against
`out/zQuoterSepolia.sol/zQuoterSepolia.json` and matches **exactly**, metadata tail
included. Source is **verified on Etherscan** (built with the default profile, no
constructor arguments):

https://sepolia.etherscan.io/address/0x2ef402b070c7e0869fdb9c4ebc9b09e471ebd755

```
forge verify-contract 0x2ef402B070C7e0869FDB9c4EBc9B09e471ebD755 \
  src/zQuoterSepolia.sol:zQuoterSepolia --chain sepolia --watch
```

## Why it is not a port of src/zQuoter.sol

Unlike the rest of `deploy/`, this contract is NOT the mainnet artifact retargeted.
The mainnet quoter is a thin shell over a base quoter at
`0x658bF1A6608210FDE7310760f391AD4eC8006A5F`, which has no code on Sepolia — and a
staticcall to a codeless address succeeds with EMPTY RETURNDATA, so a port would not
have reverted, it would have quoted zeros. It also quotes Curve, Lido, Sushi and
zAMM, none of which the Sepolia router can execute.

## The deployment it is built for

Every constant below was read out of the deployed Sepolia zRouter's own runtime
code rather than assumed, and each is asserted in
[`test/zQuoterSepoliaFork.t.sol`](../test/zQuoterSepoliaFork.t.sol).

| | Sepolia |
|---|---|
| zRouter | `0x000000000000FB114709235f1ccBFfb925F600e4` |
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| V2 factory | `0xF62c03E08ada871A0bEb309762E260a7a6a880E6` |
| V3 factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |
| V4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| V4 StateView | `0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C` |

Both pool init-code hashes are the canonical Uniswap values, identical to mainnet.

**The Sepolia zRouter carries `swapV2`, `swapV3` and `swapV4` — and NOT `swapVZ`.**
zAMM is live on Sepolia at its usual address with byte-identical code, but the
router cannot route to it, so the quoter does not quote it. Quoting a venue the
router cannot execute yields a "best" route that reverts, which is worse than no
route. Adding zAMM here requires a router redeploy first.

## V4 protocol fees

`PoolManager.protocolFeeController()` is the ZERO ADDRESS on Sepolia, so no pool can
carry a protocol fee. The corrected fee composition this contract uses (see
`src/zQuoterV4.sol` for what the naive `protocolFee + lpFee` did to mainnet quotes
when Uniswap switched protocol fees on at block 25623201) therefore reduces to
`swapFee = lpFee` and is a no-op today — while staying correct if Sepolia ever
enables them. `testV4ProtocolFeesAreOffOnSepolia` asserts the controller is unset,
so that change surfaces as a loud failure rather than as silently wrong V4 quotes.

## Live verification

Quoted and then EXECUTED against the live router, not just simulated.

0.01 ETH -> USDC (`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`) picked UNI_V4 @ 1%:

- quoted `amountOut` — 270,946,983
- received on-chain — 270,946,983 (tx `0x7f34d9667054f94189a073d60d51c83327066d9046183d5371f3d5f477e43b1f`)

Exact, not approximate: the quote is a pure function of state that did not move
between the call and the swap.

The full grid for 1 ETH -> USDC at deploy time, which is also the argument for
covering V4 rather than stopping at V2:

```
V2         30    24,717.77
V3          1    24,269.69      V4    1   24,179.60
V3          5    25,005.43      V4    5   23,027.88
V3         30    24,788.43      V4   30   25,488.65  <- best
V3        100    25,366.32      V4  100   25,233.16
```

A V2-only quoter would hand integrators 3.1% less than the chain will give them.

## Scope

Single-hop only. No multi-hop, split or hub routing — mainnet's quoter carries
~1,200 lines of that, and Sepolia liquidity is a handful of pools with nothing to
hub through. V4 quoting is hookless-only: a hook can rewrite a swap arbitrarily, and
the router's `swapV4` has no hook argument to execute against in any case.

`AMM`, `Quote`, `getQuotes` and `buildBestSwap` keep the mainnet quoter's exact
shapes, unused enum ordinals included, so integrator code written here moves to
mainnet unedited — the venues it never sees on Sepolia simply start appearing.
