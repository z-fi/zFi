# zSwap v0.3 pre-release audit: record and responses

An external pre-release audit (GPT Astra) reviewed `zSwap.html` at `66f3067` on 2026-09-28 and recommended holding release over two transaction-safety findings. Both were confirmed against the current page, fixed, and covered by tests that fail on the old code. This file records the answers and the exact build the release is locked to. The audit's report is preserved verbatim at the end.

## Locked build

| | |
|---|---|
| Commit | `c859c08` |
| Page | `zSwap.html`, 677,534 bytes, 28 chunks |
| keccak256(zSwap.html) | `0xae7c5cac29d0bd7cfdea701e8f07aac3a004ade06f22664651a5637a2098b3ab` |
| Resolver relay gas | 29,703,936 of the 30,000,000 eth_call budget |
| Tests | UI 1,689 and browser 30 tests on `e1bda9d`, and the address, Tacit, names and send suites (311 tests) on these bytes, 0 failures; Foundry zSwap 83/83; check-zSwap all pass |

Also verified end to end on an anvil mainnet fork in real Chromium: an ETH send landed as a 21,000-gas transfer and a 0.05 ETH→USDC swap received exactly the quoted 133.732996 USDC; the page sets no gas or fee fields, so the wallet estimates both. A real unclaimed airdrop allocation's `claimAndShield` simulates successfully on mainnet with the page's calldata.

The audit's two fixes first shipped in `3b051c0` (680,829 B, keccak `0x055e22c2…ae32`). The lock moved to `2f0254a` after the final review below, then to `a040769` for cUSD loan parity with tacit.finance, then to `9a3f23e`, where a points claim is offered only when the distributor's own `verify` accepts its proof, then to `7ad72ac`, where a lone decimal comma reads as a decimal (so iOS comma keypads can type amounts) and .wei reveals wait on chain time, then to `82958f2`, which adds a private airdrop claim, a small-send warning and two edge guards, then to `6597c2f`, where a send the wallet's RPC fails says whether anything went out, then to `984b9e0`, where a points activity the page does not know is listed as other rather than as an ETH amount, then to `3a462ac` after the last review below, then to `1c0607a`, which reads Tacit's unified tacit1 addresses, then to `e1bda9d`, where quotes, wallets, relay sockets and private rows keep to the current state, then to `c859c08`, which reads Tacit's 0x80 spend-key flag; everything in `3b051c0` is carried forward unchanged in behaviour.

The hash and length are pinned in `test/zSwap.t.sol`, the registry calldata and `deploy/zSwap-v0.3-LAUNCH.md`. `node script/sync-zSwap-artifacts.mjs --committed` confirms that every pinned copy agrees with the committed page. Any change to `zSwap.html` after `c859c08` voids this lock and needs the full pin sequence and test sweep again.

## Findings at a glance

| Item | Audit | Verdict | Outcome |
|---|---|---|---|
| P1: an ambiguous batch failure replays transactions | Hold release | Confirmed at HEAD | Fixed in `3b051c0`, carried into `c859c08` |
| P2: quote expiry is not rechecked before submission | Hold release | Confirmed at HEAD | Fixed in `3b051c0`, carried into `c859c08` |
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

## Final review after the audit

After the audit fixes, the final page was read by hand and then reviewed again by seven independent reviewers, each on one cross-cutting theme: wallet and chain lifecycle, numbers and units, Tacit state machines, untrusted data, the non-swap action flows checked against their compiled contracts, long-session robustness, and byte savings. Every finding below was confirmed by tracing before it was fixed.

| Severity | Finding | Fix |
|---|---|---|
| High | A cBTC loan record stored the collateral note's blinding, its spend secret, in unsealed browser storage | The field is no longer stored; nothing read it |
| Medium | After a laptop sleep or a suspended mobile tab, a mined swap could be reported as unconfirmed, inviting a second swap | The receipt wait counts only time the page is awake |
| Medium | Flip turned an amount typed as "1,5" into 15 | Flip carries the text as typed; since `7ad72ac` the parser reads a lone decimal comma as a decimal and refuses only the ambiguous "1,000" form |
| Medium | A cause's goal and days read "1,5" as 15, written into an immutable DAO | Both go through the same parser as a swap amount |
| Medium | A device clock more than 10 minutes slow made every swap revert `Expired()` | The page reads chain time once per visit and offsets its clock when it is more than 90 s off |
| Medium | A taken-back private send was labelled "claimed" | It reads "refunded" once the refund output is in the pool |
| Medium–low | A paid request could stay on "settle" forever | A request already settled on chain reads as settled |
| Medium | A pool→V1 move that failed before sending left a phantom pending note | The saved note is dropped when the move throws (`df9a51c`) |
| Low | A governance payload with malformed calldata could display misleadingly against a proposal | Only clean-hex calldata is matched |
| Low | A wallet injected after load was never bound to chain and account events | It is bound on connect |
| Low | The chart toggle stopped working with full browser storage; solver lanes failed on iOS before 15.4 | Storage is written after the UI update; `hasOwnProperty` replaces `Object.hasOwn` |

A cross-check against Tacit's own modules (about 3,000 comparisons over 12 random keys, by the Tacit team) found zSwap's Tacit cryptography byte-identical except two cUSD loan details, fixed in `a040769`: the debt note's keys now use Tacit's `deriveOutputKeys(key, anchor, "cdpDebt", 0)`, so tacit.finance finds a zSwap loan from the key alone, and the next position index comes from the chain's `CdpPositionInserted` settles, so a key already used on tacit.finance is never reused. The mint op is byte-identical to Tacit's `buildCdpMintOp` at tacit `6df65935`, and check-zSwap pins it.

Checked and found clean: every order-book, SLOW, Precision, Markets, names, launch and governance selector, argument order, value and approval spender against the compiled ABIs; all 69 HTML sinks traced to validated data, with no eval, postMessage or unpinned code; every wallet and chain switch path.

Deferred as rare or bounded: a key import racing a background refresh, two open tabs saving notes at the same moment, a Private ETH proof interrupted by a network switch (costs gas at most), and cosmetic bidi characters in token-list names.

Byte savings paid for all of it: three aliases (`St`, `Tx`, `Sm`) over 757 sites, chosen by parsing the script, cut 6,003 B and took the resolver headroom from about 4.5K gas to about 523K.

New tests: `test/ui/final-edges.test.mjs` (the comma and clock cases) and an assertion in `test/ui/cbtc.test.mjs` that a loan record carries no blinding. Each fails on the page before its fix.

## Last review before deploy

On 2026-09-30 the locked `984b9e0` was reviewed again by four independent reviewers (transaction paths; Tacit private flows; live on-chain dependencies on 1, 8453 and 4663; visual UX in real Chromium at phone and desktop width, both themes), and Tacit's own team checked the integration against its relay and contracts. Each fix below comes with a test in `test/ui/final-*.test.mjs` that fails on `984b9e0`.

| Severity | Finding | Fix |
|---|---|---|
| Medium (Tacit) | "escrow + mint" asked Tacit's relay to prove a cBTC mint before its bond existed, which the live relay refuses, so the button could never complete | Removed: a lock posts its escrow first and mints once covered; check-zSwap refuses the one-transaction path |
| Medium | A wallet that switched network while the pre-send nonce read was out was still handed the send | The chain is checked after the nonce read, right before the send |
| Medium | A cUSD loan whose settle landed while its wait timed out stayed on "settle" | The row reconciles from the transaction receipt |
| Low–medium | A failed send whose wallet RPC never answered the second nonce read left the page busy | Both nonce reads are capped at 3 s |
| Low–medium | A paid request settled from this wallet stayed on "settle" after a timeout | Settle first reads the deposit's status and marks a consumed one settled |
| Low–medium | "Claim privately" dropped its TAC note when the send may already have gone out | The note is kept unless nothing was sent |
| Low | A batch that fell back to one-by-one steps could send an expired quote | The quote's expiry is checked before the final step |
| Low | A cUSD debt note stayed "settling…" after its loan job failed | It is dropped unless its leaf is in the pool |
| Low | A wiped browser listed only loans at key index 0–15 | The match covers every index the walk finds |
| Low | Typing "0," flashed a comma error; disconnect cut an in-flight send; a points claim racing a refresh reported an error | Fixed |
| UX | Opening a mode moved its own button up to 150 px; dialog buttons touched the panel edge; the menu clipped on a phone; the private "In" selector was cut off | Fixed |

Live checks found every address the page calls has code on its chain, every RPC and zEndpoints URL answers, all eight solver lanes quote, and ETH→USDC quotes agree within 0.05% of Kyber and ParaSwap on all three chains. Tacit's pinned pool module hash-matches on GitHub and tacit.finance, and its CIDs are pinned on Filebase. Tacit: GO.

## Also in this release since the audit baseline

- `c859c08`: a tacit1 address may set 0x80, meaning its Ethereum-side key is its Bitcoin spend key (the pooled form is flags 0x85, 276 characters, per tacit `57ae2431`); a V1 send reads that key, and an address naming the key both ways is refused.
- `e1bda9d`: late answers from a quote, a solver roster, a name roll, a points read or a private-send preview are dropped once the view has moved on; a rejected wallet connection is forgotten; a stale WalletConnect socket is closed; a node answer that is not hex is retried; SLOW relay deadlines use chain time; a deep link resolves both tokens at once; text-box dialogs have side margins.
- `1c0607a`: a tacit1 address may carry Tacit's pool lane (flag 0x04, up to 329 characters). The page reads it by lane as Tacit's `tacit-address.js` does: a V1 send takes the Ethereum-side key from any such address or .wei record, and a pool send takes one that carries the pool as its bp1 address. Checked against Tacit's pinned vectors; Tacit shows these addresses only once this build is live.
- `3a462ac`: the last review above.

- `23bdb00`: Bitcoin reads skip unusable node answers and promote the node that answered. A Bitcoin transaction is broadcast to every node at once.
- `c88ce01`: pool ether moves into V1 as a tETH note from the Private ETH menu. The note is saved before the move is sent, and recover finds it from the key alone.
- `984b9e0`: a /points activity the page does not recognise is counted and listed as "other" with no amount, so new Tacit categories (such as the Bitcoin pool) are never shown as ETH.
- `6597c2f`: when the wallet's own RPC fails a send (for example MetaMask's Infura: "Internal error"), the page compares the account's pending nonce through the wallet before and after, then says the transaction went out (do not resend), nothing was sent, or check the wallet first; the raw wallet text is replaced by a plain sentence.
- `82958f2`: "Claim privately" claims the TAC airdrop straight into a Tacit V1 TAC note (TacAirdrop.claimAndShield, note derived from the key and saved first); a private send whose relayed claim would cost the recipient more than half asks first; a Private ETH proof holds the page busy; a key import waits out a background refresh.
- `7ad72ac`: one comma reads as the decimal point unless it could be a thousands group ("1,000" is refused with both readings), matching tacit.finance; .wei reveals time from the chain clock; the loan-key walk allows Tacit's 20-key gap.
- `9a3f23e`: a Tacit points claim is shown only when the distributor's `owed` and `verify` both accept it; the 1M TAC airdrop's 8,652 proofs were each checked against the on-chain root.
- `a040769`: cUSD loan keys and position index match tacit.finance.
- `2f0254a`, `df9a51c`: the final-review fixes above.
- `d0abc1f`: Precision-pool deposits check the balance before quoting, and a partial withdrawal previews what it returns.

Deferred by decision: an in-page cBTC CDP repay. It needs several KB of new proving logic, and the page links to tacit.finance for it instead.

Next step: deploy the 28 chunks for `c859c08`, run the DAO's `deployNext`, then repoint `zswap.wei`.

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
