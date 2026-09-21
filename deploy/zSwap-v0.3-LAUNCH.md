# zSwap v0.3 — launch runbook

The page and all its on-chain dependencies are ready. What remains is deploying the page itself and a few operational switches.

## Status (2026-09-22)

| | |
|---|---|
| Page | `zSwap.html`, 573,167 B, 24 chunks (16,657 B headroom) |
| Checks | `script/check-zSwap.mjs` all pass; `check-create2-artifacts.mjs` 27/27 reproduce |
| Tests | UI suite 79 files; Foundry zSwap 83, zGuard 18, Precision fork 19; browser 30 |
| Live smoke (read-only, real Chromium) | quotes land on 1 / 8453 / 4663 in 7–10 s, no page errors |
| zGuard | LIVE `0x00000057…2b1961` on 1/8453/4663, verified (Sourcify + Etherscan) |
| Explorers | every zFi contract under `deploy/` verified on Etherscan (1/8453/4663) |

## Deploy steps

1. **Commit the tree.** It also holds work from other sessions (v0.3 polish, private bridge, zEndpoints, chunk count, audit fixes). Note that anything under `dapp/` auto-deploys to zfi.wei.is on push.
2. **Chunks.** `node script/build-zSwap-chunks.mjs` then `PRIVATE_KEY=… ETH_RPC_URL=… node script/deploy-zSwap-chunks.mjs`.
   - Cost: 24 transactions at about 5.26M gas each, about 126M gas in total (roughly 0.13–0.19 ETH at 1–1.5 gwei).
   - Use a dedicated funded key, **not** `0x68575B07…`: it signs Tacit's header relay and reflection, and Tacit asked that it not be used.
3. **Successor.** Run `node script/build-zSwapNext.mjs <24 chunk addresses>`. It emits the initcode and the calldata for the DAO's `deployNext` on the current tip.
4. **DAO** executes `deployNext`. Then record the wrapper address in README / `docs/src/README.md` and rerun `node script/check-zSwap.mjs`.
5. **Old version.** Nothing to change. Its "newer →" link finds the successor once it matures (MATURITY = 3 days).

## Operational switches (independent of the deploy)

- **SLOW instant sends (SlowRelay lane).** `slow-relayer` on Render is live on all three chains through keyed Tenderly RPCs, but its EOA `0x0705…548d` is unfunded.
  - Fund it with a few × 0.001 ETH plus gas per destination chain (`MAX_FILL_WEI` is 0.001 ETH).
  - Then switch the lane on for everyone through `zSwapFlags`. It is off by default.
- **Rotate the credentials pasted in chat:** the deployer key, the Render API key, the Etherscan key, and the three Tenderly gateway URLs.

## Manual smoke test with real wallets (before announcing)

- **MetaMask (desktop):**
  - a USDC swap with a permit, sent as one transaction;
  - change network while a swap is pending;
  - speed up a pending transaction;
  - a Precision swap, whose calldata should include the zGuard deadline leg.
- **Smart account (MetaMask 7702, Coinbase or Rabby):** an approve + swap batch; decline the upgrade once and the next attempt should go step by step.
- **WalletConnect on a phone:** connect; reload, and the session should resume; disconnect, and the phone should show the session ended.
- **Safe via WalletConnect:** no permit prompt; plain approve, then swap.
- **Robinhood share link** with a wallet that lacks the chain: connect should offer to add the network.
- **Private bridge / Tacit:**
  - publish your tacit1 to your `.wei` name from zSwap, then pay that name from tacit.finance, and the reverse;
  - claim with a funded wallet;
  - a claim attempt from an unfunded wallet should point you to the relay.

## Known limits (by design, not blockers)

- **Solver-lane fills** go straight to the solver contract, so they carry no zGuard deadline. Many aggregators embed their own.
- **zGuard's `snap`/`floor` end-to-end minimum** is live, but the page does not use it yet. A future page could use it to replace the widened bounds on split and two-hop ERC-20 routes.
- **Private payments** go to `tacit1…` addresses, Tacit keys, and names that publish `finance.tacit`. There is no fallback yet for paying a bare 0x address.
- **The next router** should add a standalone `deadline(uint256)` guard; see `deploy/zGuard.md`.
