# slow-keeper

Settles expired **tipped** SLOW transfers through `SLOWGate` and collects the relayer tip.

- `SLOW` — [0x000000006513b7821171c8447ec7ecdfa3b956fd](https://etherscan.io/address/0x000000006513b7821171c8447ec7ecdfa3b956fd)
- `SLOWGate` — [0x76D1956b3BE7c0D09A16dE00DcE9B6f54ef28D34](https://etherscan.io/address/0x76D1956b3BE7c0D09A16dE00DcE9B6f54ef28D34)

## Chains

Both contracts are at those same addresses, with identical runtime and identical
selectors, on all three chains zSwap ships on. zSwap v0.3 offers the auto-claim tip on
every one of them, so all three need watching: a tip posted on a chain nobody keeps is
ETH the user spent that nobody will ever collect.

| id | chain | SLOW deploy block | send path | L1 data fee |
| --- | --- | --- | --- | --- |
| `1` | Ethereum | 25913818 | Flashbots Protect | none |
| `8453` | Base | 50927361 | `mainnet.base.org` | read from the GasPriceOracle predeploy |
| `4663` | Robinhood | 55448611 | `rpc.mainnet.chain.robinhood.com` | already inside the gas estimate |

The L2 deploy blocks were established by binary-searching `eth_getCode` at the SLOW
address over the full block height against an archive endpoint, and each is pinned by
the block below it returning `0x`. On Robinhood the gate's code appears in the same
block, which is what SLOW creating it in its constructor looks like.

**One process, all three.** `CHAINS` is a comma-separated list of ids and defaults to
`1`, so an existing mainnet deployment that never sets it behaves exactly as it did.
Each chain gets its own keeper instance: its own tip book, its own block cursor, its own
endpoint pools, its own loop and its own error boundary. They share only the signing
key, and that is safe because nonce sequences are per chain. A dead Robinhood endpoint
costs Robinhood a pass and nothing anywhere else.

Every log line is tagged with its chain (`[eth]`, `[base]`, `[rh]`), because on a hosted
log stream three interleaved keepers are otherwise indistinguishable and "which chain
went quiet" is precisely the question worth answering.

## How it earns

`SLOW.depositToWithTip` posts an ETH tip on the gate alongside a timelocked transfer.
Once the timelock expires, anyone can call `gate.claim(transferId)`: the gate routes
`slow.claimTipped`, the underlying is paid to the transfer's recipient, and the tip is
forwarded to `msg.sender`. That tip is the only revenue — untipped transfers pay nothing.

A claim is only valid when **both** hold at send time:

1. `block.timestamp >= pt.timestamp + delay` (delay is packed above the token address in the id).
2. `guardians[pt.to] == address(0)` — `_doClaim` reverts `ClaimBlockedByGuardian` otherwise.

Condition 2 can flip in either direction *after* the tip is posted, so the bot re-checks
it every pass rather than caching it.

## Design notes

**No database.** State is rebuilt from `TipPosted` logs at boot and reconciled against
`slow.pendingTransfers` via multicall. `pendingTransfers` is deleted on every settlement
path, so `timestamp == 0` means the tip is gone — claimed by another keeper, or the
transfer was reversed/clawed back and the tip is now the depositor's to refund. A full
re-read runs every 25 passes to evict those.

**Flashbots Protect, on mainnet.** `gate.claim` is a first-come-first-served race with
other keepers. Submitting through Flashbots Protect keeps the claim out of the public
mempool and, more importantly, means a lost race is dropped rather than landing as a paid
revert. A send that never gets included simply requeues.

Neither L2 has an equivalent, so claims there go through an ordinary endpoint and sit in
the public mempool, where a lost race lands as a paid revert instead of a free drop. That
is what makes the pre-send simulation load-bearing on an L2 rather than merely tidy, and
why it stays immediately before signing. The amounts involved are small — a reverted claim
on Base costs a fraction of a cent — but the economics are genuinely different and the
send endpoint is per chain for that reason (`SEND_RPC_URL` alone stays mainnet's).

**Atomic batches.** `claimMany` reverts entirely on the first bad id. The bot simulates
the exact batch via `eth_estimateGas` immediately before signing, and on failure splits to
per-id simulation so one stale entry can't block the rest.

**Profit gate.** Claims only when `tip >= cost * MARGIN_MULTIPLE`, where `cost` is
`gas * (baseFee + priorityFee)` plus whatever L1 data fee the chain charges on top. The
margin absorbs basefee movement between simulation and inclusion.

On an L2 that second term is not optional. A claim pays twice — once for L2 execution,
once for the bytes the sequencer posts to Ethereum — and the second half is priced off the
L1 base fee, so it can be the larger of the two. The two stacks bill it in different
places, so they are read differently:

- **Base (OP-stack)** returns L2 execution gas only from `eth_estimateGas` and charges the
  L1 component separately. It is read from the `GasPriceOracle` predeploy at
  `0x420…000F`, over the calldata plus a 160-byte non-zero allowance for the signed
  envelope the oracle never sees, and multiplied by `L1_FEE_PAD` (default 2) because the
  L1 base fee moves much further between simulation and inclusion than an L2 one does.
- **Robinhood (Nitro)** folds the posting cost into the estimate as extra gas units — a
  plain value send estimates at 21225, not 21000 — so `gas * gasPrice` already contains
  it. Reading an oracle as well would charge it twice and decline claims that are in fact
  profitable.
- **Mainnet** has no such component and makes no extra call.

A chain that charges an L1 component the keeper could not read declines the claim for that
pass. Reporting zero would quietly reduce the gate to an execution-only check on exactly
the chain where that check is incomplete.

**RPC failover, pooled by role, per chain.** Endpoints are not interchangeable, so they
are not round-robined as one list, and each chain brings its own pools. The full tables,
with what each endpoint was probed to serve and what was rejected as unusable, live in
`src/chains.js` next to the chain they belong to. In summary, probed against this exact
workload:

| chain | widest `getLogs` window | notes |
| --- | --- | --- |
| Ethereum (2026-08-03) | unlimited, three independent operators | `rpc.mevblocker.io`, `eth.api.onfinality.io/public`, `gateway.tenderly.co/public/mainnet` |
| Base (2026-09-19) | 2,000 (`mainnet.base.org`) | no unlimited source exists; ~590k blocks of history is a few hundred windows |
| Robinhood (2026-09-19) | unlimited (`rpc.mainnet.chain.robinhood.com`) | the whole history comes back in one request |

**Every one of these is keyless.** That is what lets the bot run with no account anywhere.
Only a wide-range source can serve a cold backfill; the narrow ones still carry steady
state, because a pass advances far fewer blocks than even a 10-block cap, and all of them
serve `eth_call`/Multicall3.

Two endpoints deserve naming because their failure modes are quiet rather than loud.
`robinhood-rpc.publicnode.com` answers every historical read with "Archive requests
require a personal token", so it can serve neither a backfill nor a state read at a past
block, and it is left out of that chain's pools entirely. And drpc advertises a
10,000-block `getLogs` limit in its rejection text while actually serving about seventy:
the pool therefore only adopts a quoted limit when it is *narrower* than the window that
was just refused, and halves otherwise, so a source that misreports walks down to what it
really serves instead of retrying the same refused width forever.

State reads go through viem's `fallback` transport in priority order. Log discovery uses
its own pool that *learns* each endpoint's range limit from the error text and shrinks its
window to fit, so a capped endpoint is throttled rather than discarded. Rate-limit
messages are deliberately distinguished from range-limit messages — conflating them
permanently shrinks a healthy endpoint that was briefly throttled (`test/classify.test.mjs`
pins this against the real strings each provider returns, and `test/logpool.test.mjs` pins
the per-chain pools and the convergence behaviour).

Backfill progress is consumed per window, so a source dying mid-scan costs only the
unscanned remainder rather than the whole pass.

**Endpoints are never logged verbatim.** Provider URLs carry the key in the path, and
anything printed lands in the host's log store and in any transcript pasted for debugging.
Only host plus a 4-character fingerprint is emitted.

**Permanent failures evict.** A single-id simulation failure is diagnosed against
`pendingTransfers` rather than guessed from the revert string — `gate.claim` on a cleared
transfer surfaces SLOW's custom `TransferDoesNotExist`, which viem renders only as
"reverted for an unknown reason". A settled id is dropped instead of being re-simulated
every pass forever.

**Sends never fall back.** Claims go to their chain's single configured send endpoint and
nowhere else. On mainnet that is Flashbots Protect, where a public-mempool fallback would
silently invert the economics — lost races would land as paid reverts instead of being
dropped — so if Protect is unreachable the bot waits.

## Two ways to run it

**Worker** (`npm start`) — polls every 3 minutes, runs forever.

**Cron** (`npm run once`) — one pass, then exits. It also fails *loudly*: a non-zero exit
lands in the scheduler's run history, where a wedged worker just goes quiet — which at this
tip volume is indistinguishable from a healthy idle one.

Neither is in a hurry. SLOW's delays run hours to days, so claiming three minutes (or an
hour) after expiry is indistinguishable from claiming in twelve seconds, and the slower
cadence is what keeps request volume inside what free public endpoints tolerate
indefinitely. The design goal is that tips get picked up *eventually and without
supervision*, not that they get picked up fast.

**Run exactly one instance.** Two processes sharing a key will sign competing claims
against the same nonce; the relay rejects the loser with `Missing or invalid parameters`.
That is handled gracefully — nothing is spent and the ids requeue — but it wastes passes
and muddies the log. This is about processes, not chains: one process covering three
chains is the intended shape, because the nonce sequences it signs against are per chain
and never collide.

A cron pass keeps settling while passes still produce claims, so a backlog larger than one
batch clears in a single run. Each chain runs its pass regardless of what the others did,
and any chain failing turns the whole run red — an outage on one chain must not cost the
others their settlement, and it must still show up in the scheduler's history. Both modes
are defined in `render.yaml` — run one, not both.

In worker mode a heartbeat line prints every `HEARTBEAT_EVERY` passes with the queue
shape and gas balance — one per chain, since a single chain going quiet is exactly the
failure worth catching.

## Config

Every per-chain setting can be suffixed with a chain id — `MAX_FEE_GWEI_8453`,
`SEND_RPC_URL_4663`, `RPC_URLS_LOGS_8453` — and the suffixed value always wins. What an
*unsuffixed* value means depends on the setting, and the split is deliberate:

- **Chain-specific** (`RPC_URL`, `RPC_URLS`, `RPC_URLS_STATE`, `RPC_URLS_LOGS`,
  `SEND_RPC_URL`, `START_BLOCK`, `PRIORITY_GWEI`, `MAX_FEE_GWEI`): unsuffixed applies to
  chain 1 alone. Every other chain falls through to its own built-in default. An
  unsuffixed `SEND_RPC_URL` names Flashbots Protect, which does not exist on an L2; an
  unsuffixed `MAX_FEE_GWEI` of 50 is four orders of magnitude off an L2 base fee. Carrying
  either sideways is how an L2 keeper misprices or fails to send — and keeping them on
  chain 1 is also what makes the existing mainnet deployment behave verbatim.
- **Chain-agnostic** (`MARGIN_MULTIPLE`, `MAX_BATCH`, `LOG_CHUNK`, `L1_FEE_PAD`,
  `SLOW_ADDRESS`, `GATE_ADDRESS`): unsuffixed applies to every chain.
- **Process-wide** (`CHAINS`, `PRIVATE_KEY`, `POLL_MS`, `RECEIPT_TIMEOUT_MS`,
  `HEARTBEAT_EVERY`, `ONE_SHOT`, `DRY_RUN`): one value, no suffix.

| Var | Required | Default | Notes |
| --- | --- | --- | --- |
| `CHAINS` | no | `1` | Comma-separated chain ids to watch. `1,8453,4663` for all three. An unsupported id fails at boot. |
| `RPC_URL` | **no** | — | Optional. If set, tried first. Must allow wide `eth_getLogs` ranges. Unset is fine and fully supported — the built-in pools are keyless. |
| `RPC_URLS` | no | — | Comma-separated extras, inserted ahead of the built-in public fallbacks. |
| `RPC_URLS_STATE` / `RPC_URLS_LOGS` | no | — | Role-specific overrides for an endpoint good at only one job. |
| `PRIVATE_KEY` | yes | — | Keeper EOA, shared across every chain. Gas float only — fund it on each chain you watch. |
| `SEND_RPC_URL` | no | per chain | `https://rpc.flashbots.net/fast` on 1, `https://mainnet.base.org` on 8453, `https://rpc.mainnet.chain.robinhood.com` on 4663. |
| `MARGIN_MULTIPLE` | no | `1.25` | Required tip-to-cost ratio. |
| `PRIORITY_GWEI` | no | per chain | `0.05` on 1, `0.001` on 8453, `0` on 4663 — Nitro orders by arrival, so a priority bid buys nothing there. |
| `MAX_FEE_GWEI` | no | per chain | `50` on 1, `0.5` on 8453, `1` on 4663. Hard ceiling on `maxFeePerGas`. |
| `L1_FEE_PAD` | no | `2` on 8453, `1` elsewhere | Headroom on the L1 data component. Values below 1 are ignored. |
| `MAX_BATCH` | no | `10` | Max ids per `claimMany`. |
| `LOG_CHUNK` | no | `250000` | Backfill window. Large on purpose — capped sources shrink themselves to fit. |
| `POLL_MS` | no | `180000` | Poll interval. Three minutes; see above. |
| `START_BLOCK` | no | per chain | `25913818` on 1, `50927361` on 8453, `55448611` on 4663. |
| `ONE_SHOT` | no | — | `true` runs a single pass and exits (cron mode). Exit code is the liveness signal. |
| `HEARTBEAT_EVERY` | no | `20` | Passes between heartbeat lines in worker mode. `0` disables. |
| `DRY_RUN` | no | — | `true` logs decisions without sending. |

## Turning the L2s on

Nothing in this repo needs redeploying as a different service. On the existing `slow-keeper`
worker (or cron), set:

```
CHAINS=1,8453,4663
```

and fund the keeper address with a little ETH on Base and on Robinhood. Everything else has
a built-in per-chain default, and the unsuffixed vars already set on that service keep
meaning exactly what they meant. Reverting is the same single change: drop `CHAINS`, or set
it back to `1`.

## Local run

```sh
npm install
PRIVATE_KEY=0x... npm run dry-run                      # mainnet only, no RPC_URL needed
PRIVATE_KEY=0x... CHAINS=1,8453,4663 npm run dry-run   # all three
npm test                                               # no key, no network
```

`DRY_RUN=true` is read-only end to end: it discovers, hydrates, checks guardians, simulates
and prices, then stops short of signing.

## Security

The keeper key cannot move user funds. The gate has no path to `safeTransferFrom` or
`withdrawFrom`, and `_doClaim` pins the payout to `pt.to` — the caller only ever receives
the tip. Worst case for a leaked key is loss of the ETH held for gas.
