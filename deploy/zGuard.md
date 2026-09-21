# zGuard

`0x00000057B53fB5feEdedaf7066e1f1C7002b1961`, the same address on Ethereum (1), Base (8453) and Robinhood (4663).

Source: `src/utils/zGuard.sol`. Tests: `test/zGuard.t.sol` covers the checks and all three routers. `test/PrecisionPoolMultihop.t.sol` runs the live zRouter and PrecisionRoute on the pinned fork.

## Why it exists

Precision swaps, Precision zaps and solver fills run without a deadline. `zRouter.snwap` does not check one, and neither do `PrecisionRoute.route`/`routeFromWETH`/`zapIn` or `PrecisionPool.swapExactIn`. `minOut` is the only bound.

zGuard adds a deadline without a new router. It runs as its own zero-amount `snwap` leg in the same multicall, and it never holds tokens.

It also offers `snap`/`floor`, one end-to-end minimum for an ERC-20 bundle.

## How the page uses it

- `GUARD` in `zSwap.html` pins this address. `gLegs()` adds `deadline(by, ZROUTER)` ahead of these legs:
  - Precision swaps: native, ERC-20, and the Permit2 funded variant;
  - Precision zaps.
- The leg is added only where `hasCode(GUARD)` is true. So the page behaves exactly as before on a chain until the guard is deployed there, and switches the guard on by itself afterwards.

Two rules come from `snwap` forwarding the whole `msg.value` to every leg:

- **Native bundles:** guard legs go first. The guard returns the ether to the router (`back`), and the swap leg after it spends that ether. A guard leg AFTER a native swap runs out of funds.
- **ERC-20 bundles:** no `msg.value`, so guard legs can go anywhere, including a trailing `floor`.

## Deploy

No constructor arguments. Every chain uses the same SafeSummoner payload:

```
to:   0x00000000004473e1f31C8266612e7FD5504e6f2a   (SafeSummoner, identical code on 1/8453/4663)
data: deploy/zGuard.deploy.calldata.txt
salt: 0x00000000000000000000000000000000000000000000000000000000004ef4e1
```

`node script/check-create2-artifacts.mjs` rebuilds the initcode from source and confirms the address before anything is sent.

Status: LIVE on all three chains since 2026-09-21, deployed from `0x68575B07…` with one SafeSummoner transaction per chain. The runtime is byte-identical to `out/` (1,375 B), and Sourcify reports an exact match on 1, 8453 and 4663. Transactions and blocks are in `deploy/zGuard.deployed.json`.
