# zSwap v0.3 pre-release audit: record and responses

An external pre-release audit (GPT Astra) reviewed `zSwap.html` at `66f3067` on 2026-09-28 and recommended holding release over two transaction-safety findings. Both were confirmed against the current page, fixed, and covered by tests that fail on the old code. This file records the answers and the exact build the release is locked to. The audit's report is preserved verbatim at the end.

## Locked build

| | |
|---|---|
| Commit | `3b051c0` |
| Page | `zSwap.html`, 680,829 bytes, 28 chunks |
| keccak256(zSwap.html) | `0x055e22c2ee895f3e9572280b07e68d0dbb12de5525e25d17b4ffe1f75fe2ae32` |
| Resolver relay gas | 29,987,917 of the 30,000,000 eth_call budget |

The hash and length are pinned in `test/zSwap.t.sol`, the registry calldata and `deploy/zSwap-v0.3-LAUNCH.md`. `node script/sync-zSwap-artifacts.mjs --committed` confirms that every pinned copy agrees with the committed page. Any change to `zSwap.html` after `3b051c0` voids this lock and needs the full pin sequence and test sweep again.

## Findings at a glance

| Item | Audit | Verdict | Outcome |
|---|---|---|---|
| P1: an ambiguous batch failure replays transactions | Hold release | Confirmed at HEAD | Fixed in `3b051c0` |
| P2: quote expiry is not rechecked before submission | Hold release | Confirmed at HEAD | Fixed in `3b051c0` |
| Browser: the picker gap is −0.25 px | Low, unresolved gate | Not reproduced | No change |
| UI harness: 26 failed, 4 cancelled | Environmental, passed alone | Agreed | Clean full run |

## P1: an ambiguous batch failure automatically replays transactions

**Audit claim.** `sendBatch0` re-sends each call with `eth_sendTransaction` whenever `wallet_sendCalls` throws anything other than a user rejection or a "timed out" message. If the wallet accepted the batch and only the response was lost, the payment or swap runs twice, and it is no longer atomic.

**Verification.** Confirmed. The fallback was unchanged at `c88ce01`, the head the audit did not see. A disconnect (4900), an internal error (−32603) and any error without a code all led to a replay.

**Fix.** The one-by-one fallback now runs only for error codes that mean nothing was submitted. Any other error leaves the batch as possibly sent and asks the user to check their wallet before retrying. Rejections keep their existing handling.

```js
if(![4200,-32601,-32602,5700,5710,5740,5750,5760].includes(e?.code))
  throw Er("batch may have been sent"+CWA);   // CWA = " — check your wallet's activity before retrying"
```

- `4200` (unsupported method), `−32601` (method not found) and `−32602` (invalid params) are refused before anything executes.
- The EIP-5792 codes are also refused before anything executes: `5700` unsupported capability, `5710` unsupported chain, `5740` bundle too large, `5750` upgrade declined, `5760` atomicity unsupported.
- The same rule now covers the WalletConnect "relay timed out" case from the earlier pass, instead of a match on message text.

**Tests.** `test/ui/approvals.test.mjs`, "a batch the wallet may have taken is never sent again as steps". The mock records the batch, then throws 4900, −32603 and an error with no code, one per run. Each run asserts exactly one batch, no standalone transactions, and the wallet-activity message. The test fails on the old page and passes on `3b051c0`. The existing 5700 fallback test and the 4001 decline tests still pass.

## P2: quote expiry is checked before confirmation but not before submission

**Audit claim.** The swap handler checks `last.exp` before the price-impact dialog, but afterwards only checks that the quote object is the same one. Approvals and wraps can take minutes, so a quote past its 45-second window (30 seconds for solver responses) could still reach the wallet.

**Verification.** Confirmed. On-chain minimums and deadlines still bound the trade, as the audit notes. The risk is presenting a stale route, and spending approval gas on a swap that then fails.

**Fix.** Two checks were added:

- After the impact confirmation, an expired quote refreshes and asks for a new press.
- Immediately before the swap or batch goes to the wallet, after any separate approval or wrap, the captured quote's expiry is checked again. If it has passed, the page refreshes the quote and shows "Quote expired — refreshing…".

```js
if(last!==q0||Dn()>q0.exp){updateSoon();return void(stat.textContent="The quote refreshed while you were deciding — check it and press again.")}
…
if(Dn()>q.exp){updateSoon();throw Er("Quote expired — refreshing…")}
```

The solver cap needs no separate path, because a solver quote's `exp` already carries its 30-second limit.

**Tests.** Both fail on the old page and pass on `3b051c0`:

- `test/ui/swap.test.mjs`, "a quote that expires while the impact dialog is open is not the one sent". The trade is in the 16% impact tier, the quote's expiry is set during the dialog, and nothing is sent.
- `test/ui/approvals.test.mjs`, "a quote that expires during a separate approval is not sent after it". With a wallet that sends calls one at a time, the approval goes but the stale swap does not.

## Validation notes

| Audit note | Answer |
|---|---|
| Browser picker: gap of −0.25 px beneath the button (Chromium 153) | Not reproduced. `test/browser/picker.test.mjs` passes 5/5, and the browser suite 30/30, on Playwright's Chromium here. The panel is placed 6 px below the button and only rises when it is clamped to the bottom of a very short window, so a fractional −0.25 px points to sub-pixel rounding in that browser. Low severity; left unchanged. |
| 80-file UI run: 26 failed and 4 cancelled in cause-launch, cbtc and markets | Agreed that these were environmental: they came from a 120-second runner cap and competing workloads, and the audit's own isolated reruns passed. A clean single pass over all 96 UI files here ran 1,656 tests with 0 failures. |
| check-zSwap and the Foundry pins | All checks pass on the locked page. The Foundry zSwap suites pass 83/83, including the HTML round-trip, ERC-5219, and the 30M-gas resolver budget. |
| Out of scope: live wallets, production addresses and code hashes, external endpoints, integrated contracts | Covered elsewhere. Every zFi contract under `deploy/` is explorer-verified. The endpoint roster lives on chain in zEndpoints, and was health-checked and reordered on 2026-09-28 (tx `0xce6ae4a88334136c400b27bc75793224cd30a4a43f8ccc63d522e584e929ba81`). The real-wallet smoke list in `deploy/zSwap-v0.3-LAUNCH.md` stays a step before announcing. |

## Also in this release since the audit baseline

- `23bdb00`: Bitcoin reads skip unusable node answers and promote the node that answered. A Bitcoin transaction is broadcast to every node at once.
- `c88ce01`: pool ether moves into V1 as a tETH note from the Private ETH menu. The note is saved before the move is sent, and recover finds it from the key alone.
- `d0abc1f`: Precision-pool deposits check the balance before quoting, and a partial withdrawal previews what it returns.

Deferred by decision: an in-page cBTC CDP repay. It needs several KB of new proving logic, and the page links to tacit.finance for it instead.

Next step: deploy the 28 chunks for `3b051c0`, run the DAO's `deployNext`, then repoint `zswap.wei`.

---

## The audit's report (verbatim)

> # zSwap.html pre-release audit
>
> Review date: 2026-09-28. Baseline: `66f3067`. Recommendation: hold release until the transaction recovery issue below is fixed and verified.
>
> Scope: canonical `zSwap.html`, its transaction submission and quote confirmation paths, deployment consistency checks, zSwap UI harness tests, real-browser tests, and HTML payload deployment tests. This is a frontend release review, not a complete audit of every integrated contract or external service. Application source was not modified.
>
> ## Findings
>
> ### P1 — An ambiguous batch failure automatically replays transactions
>
> Location: `zSwap.html:1782–1788` (`sendBatch0`).
>
> The catch handler for `wallet_sendCalls` falls back to individual `eth_sendTransaction` requests for every error except user rejection and an error message matching `timed out`. A disconnected-provider error or other transport/internal error does not establish that the wallet rejected the original batch. If the wallet accepted it but the response was lost, replaying the calls can execute the payment or swap twice. The fallback also discards the originally requested atomic execution.
>
> Reproduced with the actual page and existing MockChain: the mock accepts and records a one-call native transfer batch, then throws code 4900 (`Disconnected from provider`). The page submits the same transfer again as a standalone transaction. Recorded result: one accepted batch, two transfers, one marked batched and one standalone. This models an ambiguous wallet response; it is not a claim that a particular wallet was observed doing this on mainnet.
>
> Fix: permit sequential fallback only for explicit pre-execution unsupported-method/capability responses whose semantics guarantee non-submission. For transport, internal, or unknown errors, retain an indeterminate state and require the user to check wallet activity. Never infer non-submission from arbitrary error text. Add regression coverage for accepted-but-response-lost batches and verify whether each fallback call sequence is safe without atomicity.
>
> ### P2 — Quote expiry is checked before confirmation, but not before submission
>
> Location: `zSwap.html:9908`, `9910–9931`, `9993–10001`.
>
> The handler checks `last.exp` before opening its price-impact confirmation. After the user accepts, it checks object identity but does not check expiry again. Funding can subsequently wait for signatures and approval receipts with no final expiry check either. An expired quote can therefore still be handed to the wallet, defeating the declared 45-second freshness policy (30-second cap for solver responses).
>
> Reproduced by preparing a real harness quote, exercising the 16% impact confirmation, setting that same quote's expiry into the past during confirmation, and accepting. At the actual `eth_sendTransaction` call, the captured quote is expired. On-chain slippage and deadlines remain relevant safeguards; this finding does not establish that those bounds can be bypassed. The immediate risks are stale pricing/route presentation and transactions that can fail after approval costs have been incurred.
>
> Fix: revalidate the captured quote's expiry after confirmation and after asynchronous funding, immediately before handing the swap or batch to the wallet. On expiry, refresh and require a new review. Add delayed-confirmation and delayed-approval tests, including the solver freshness cap.
>
> ## Reproduction
>
> With the UI test dependencies available (this run used Node 24.11.0, ethers 6.17.0 and jsdom 26.1.0; browser checks used Playwright 1.63.0 / Chromium 153):
>
> ```sh
> node audit/zSwap-pre-release-2026-09-28/reproduce.mjs
> ```
>
> The script is a defect reproduction: its assertions confirm the current undesirable behavior. Expected output includes two transfers for `AMBIGUOUS_BATCH` and `expired: true` for `EXPIRED_AFTER_CONFIRM`. It uses simulated transactions and does not submit to a live chain.
>
> ## Validation
>
> - `node script/check-zSwap.mjs`: 69 checks passed. HTML is 679,454 bytes, uses 28 chunks, and has 8,674 bytes aggregate headroom. Registry calldata and Solidity hash/length pins match the current page.
> - `forge test --offline --match-path test/zSwap.t.sol`: 8 passed, including HTML round-trip and ERC-5219 responses. Despite `--offline`, the repository configuration still initializes an Ethereum fork; the successful run used network access.
> - Real Chromium browser suite: 29 passed, 1 failed. `test/browser/picker.test.mjs:105` expects a positive gap beneath the picker button; measured gap was -0.25 CSS pixels. Treat this as an unresolved browser regression gate with low visual severity, not as evidence of a major positioning failure. Investigate layout/rounding before changing the assertion tolerance.
> - The 80-file zSwap harness run reported 1,476 tests: 1,446 passed, 26 failed, 4 cancelled, 0 skipped. All failure/cancellation reports were in `cause-launch`, `cbtc`, and `markets`, due to the imposed 120-second runner limit or key-unlock waits under competing test workloads. The Markets worker also remained open after its parent test timed out and was stopped to let the runner finish. After removing duplicate workload and running those files independently without that runner limit, all passed: cause-launch 23/23, cBTC 17/17, Markets 33/33. Thus no unresolved assertion failure remains from this UI run, but it was not a clean single-pass run.
> - Additional checks: coin launch 41/41 passed; precision address/selector consistency 3/3 passed. Both transaction defect reproductions passed their assertions.
>
> The initial sandboxed Node test runs exposed only file-level completion, so those results are not counted as assertion-level validation. The final grouped UI run selected 80 files using the single-quoted harness import. The coin-launch file uses a double-quoted import and was run separately. Other files in `test/ui` target `dapp/index.html` and live external services and are outside this page audit. Isolated reruns used `node --test --test-isolation=none test/ui/<file>.test.mjs`.
>
> Live wallet interoperability, all production contract addresses and code hashes, every external endpoint, and every integrated Solidity contract were not independently verified by this review.
