# zSwap v0.3 — launch runbook

The page and all its on-chain dependencies are ready. What remains is deploying the page itself and a few operational switches.

## Status (2026-09-25)

| | |
|---|---|
| Page | `zSwap.html`, 675,496 B, 28 chunks (12,632 B headroom) |
| Identity | `CP_MSG` is Tacit's shared identity message (tacit 2abd65b0, `dapp/identity-message.js`), byte-equal; the derivation is unchanged |
| Checks | `script/check-zSwap.mjs` all pass; `check-create2-artifacts.mjs` 27/27 reproduce |
| Tests | UI suite 90 files (1,537 tests), run one file at a time; Foundry zSwap 83, zSolverFill 17, PM 76 (without the default mainnet fork), zGuard 18, Precision fork 19; browser 30 |
| Live smoke (read-only, real Chromium) | quotes land on 1 / 8453 / 4663 in 7–10 s, no page errors |
| Markets | PM LIVE `0x0000003b…aB5C5` on mainnet, verified (Etherscan + Sourcify); the page's `#mk` mode (mainnet only) |
| zGuard | LIVE `0x00000057…2b1961` on 1/8453/4663, verified (Sourcify + Etherscan) |
| Explorers | every zFi contract under `deploy/` verified on Etherscan (1/8453/4663) |

## Deploy steps

1. **Commit the tree.** It also holds work from other sessions (v0.3 polish, private bridge, zEndpoints, chunk count, audit fixes). Note that anything under `dapp/` auto-deploys to zfi.wei.is on push.
2. **Chunks.** `node script/build-zSwap-chunks.mjs` then `PRIVATE_KEY=… ETH_RPC_URL=… node script/deploy-zSwap-chunks.mjs`.
   - Cost: 28 transactions at about 5.24M gas each (`--dry-run` on mainnet, 2026-09-25), about 147M gas in total: about 0.013 ETH at 0.09 gwei, 0.074 ETH at 0.5 gwei, 0.147 ETH at 1 gwei. Fund the key with about 2× the figure at the gas price of the day.
   - Use a dedicated funded key, **not** `0x68575B07…`: it signs Tacit's header relay and reflection, and Tacit asked that it not be used.
3. **Successor.** Run `node script/build-zSwapNext.mjs <28 chunk addresses>`. It emits the initcode and the calldata for the DAO's `deployNext` on the current tip.
4. **DAO** executes `deployNext`. Then record the wrapper address in README / `docs/src/README.md` and rerun `node script/check-zSwap.mjs`.
   - `deployNext` works once per version: a second call reverts `AlreadySucceeded()`. Before the vote, `eth_call` the emitted calldata from the DAO to the tip with `cast call --from 0x5E58BA0e… <tip> <calldata>`. It must return the mined successor address, and `forge test --match-path 'test/zSwapNext*.t.sol'` must pass. A wrong initcode or salt cannot be redone from v0.2.
   - Immediately before the vote, and again after it passes but before execution, run `node script/sync-zSwap-artifacts.mjs --committed`. It must report that every pinned copy agrees with the committed page, so the calldata you `eth_call` is the calldata you execute.
   - `TIP` in `build-zSwapNext.mjs` is v0.2 `0xe6869528…`. Its `successor()` read zero on 2026-09-25; re-read it before the vote.
5. **Old version.** v0.2's "newer →" link finds the successor once it matures (MATURITY = 3 days).
6. **Repoint `zswap.wei`.** It serves `0x000063Af…`, a standalone v0.3 whose `PREVIOUS()` is zero. It sits outside the v0.2 lineage, so nothing carries its visitors to the successor. Point the WNS addr record at the new wrapper, and update or clear the IPFS contenthash, which gateways may prefer.

## If a step fails

- **A chunk deploy dies part-way.** Every confirmed chunk is recorded in `out/zSwap.chunks.deployed.json` and re-verified byte for byte on a re-run, so re-running resumes where it stopped. A chunk whose on-chain code does not match is redeployed, never reused. Chunks are inert data, so a half-finished set costs only its gas. If the page changes before the set is complete, rebuild the chunks and deploy a fresh set; the old ones are simply abandoned.
- **`build-zSwapNext` refuses.** It reads every chunk back from chain first. Fix the chunk list; nothing has been spent on the successor yet.
- **The DAO vote has not executed.** The proposal can be replaced freely until then. Once `deployNext` has run, v0.2 has no second slot. Fix forward from the new version's own `deployNext`, and the live v0.2 keeps serving meanwhile.

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

- **Solver-lane fills** run through `zRouter.snwap` with the zSolverFill executor `0x0000004c…3E85`. The router checks the minimum at the recipient, and a zGuard deadline leg goes in front of the fill.
- **zGuard's `snap`/`floor` end-to-end minimum** is live, but the page does not use it yet. A future page could use it to replace the widened bounds on split and two-hop ERC-20 routes.
- **Private payments** go to `tacit1…` addresses, Tacit keys, and names that publish `finance.tacit`. A bare 0x address with a published record is paid privately. Without one, it gets a public payout from the pool.
- **The next router** should add a standalone `deadline(uint256)` guard; see `deploy/zGuard.md`.
