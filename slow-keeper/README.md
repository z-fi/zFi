# slow-keeper

Settles expired **tipped** SLOW transfers through `SLOWGate` and collects the relayer tip.

- `SLOW` — [0x000000000000888741b254d37e1b27128afeaabc](https://etherscan.io/address/0x000000000000888741b254d37e1b27128afeaabc)
- `SLOWGate` — [0xb8B546b93a82f4Aa6f0345142dF5679B659ef3D4](https://etherscan.io/address/0xb8B546b93a82f4Aa6f0345142dF5679B659ef3D4)

Ethereum mainnet only.

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

**Flashbots Protect.** `gate.claim` is a first-come-first-served race with other keepers.
Submitting through Flashbots Protect keeps the claim out of the public mempool and, more
importantly, means a lost race is dropped rather than landing as a paid revert. A send
that never gets included simply requeues.

**Atomic batches.** `claimMany` reverts entirely on the first bad id. The bot simulates
the exact batch via `eth_estimateGas` immediately before signing, and on failure splits to
per-id simulation so one stale entry can't block the rest.

**Profit gate.** Claims only when `tip >= gas * (baseFee + priorityFee) * MARGIN_MULTIPLE`.
The margin absorbs basefee movement between simulation and inclusion.

**RPC failover, pooled by role.** Endpoints are not interchangeable, so they are not
round-robined as one list. Probed 2026-08-03 against this exact workload:

| endpoint | `getLogs` range | state reads |
| --- | --- | --- |
| `mainnet.gateway.tenderly.co` | unlimited | ok |
| `rpc.mevblocker.io` | unlimited | ok |
| `eth.drpc.org` | 10,000 | ok (throttles `estimateGas`) |
| `eth-pokt.nodies.app`, `1rpc.io/eth` | 50 | ok |
| `eth.blockrazor.xyz` | 25 | ok |
| `eth-mainnet.public.blastapi.io` | 10 | ok |
| `ethereum-rpc.publicnode.com` | archive-gated | ok |
| `eth.rpc.blxrbdn.com` | unavailable | ok |

Only the top two can serve a cold backfill. The rest are still useful: steady-state
polling advances ~1 block per tick, which fits inside even a 10-block cap, and every one
of them serves `eth_call`/Multicall3.

State reads go through viem's `fallback` transport in priority order. Log discovery uses
its own pool that *learns* each endpoint's range limit from the error text and shrinks its
window to fit, so a capped endpoint is throttled rather than discarded. Rate-limit
messages are deliberately distinguished from range-limit messages — conflating them
permanently shrinks a healthy endpoint that was briefly throttled (`test/classify.test.mjs`
pins this against the real strings each provider returns).

Backfill progress is consumed per window, so a source dying mid-scan costs only the
unscanned remainder rather than the whole pass.

**Sends never fall back.** Claims go to Flashbots Protect only. A public-mempool fallback
would silently invert the economics — lost races would land as paid reverts instead of
being dropped — so if Protect is unreachable the bot waits.

## Two ways to run it

**Worker** (`npm start`) — polls every 12s, runs forever. Lowest latency to settlement.

**Cron** (`npm run once`) — one pass, then exits. Given the delays SLOW deals in are hours
to days, an hourly pass settles just as reliably as a 12-second poll, costs a fraction of
a 24/7 worker, and cuts RPC usage roughly 300x. It also fails *loudly*: a non-zero exit
lands in the scheduler's run history. A wedged worker just goes quiet, which at this tip
volume is indistinguishable from a healthy idle one.

A cron pass keeps settling while passes still produce claims, so a backlog larger than one
batch clears in a single run. Both modes are defined in `render.yaml` — run one, not both.

In worker mode a heartbeat line prints every `HEARTBEAT_EVERY` passes with the queue
shape and gas balance, so the log distinguishes idle from stuck.

## Config

| Var | Required | Default | Notes |
| --- | --- | --- | --- |
| `RPC_URL` | yes | — | Primary, tried first. Must allow wide `eth_getLogs` ranges — endpoints capped at 10 blocks **cannot backfill**. |
| `RPC_URLS` | no | — | Comma-separated extras, inserted ahead of the built-in public fallbacks. |
| `RPC_URLS_STATE` / `RPC_URLS_LOGS` | no | — | Role-specific overrides for an endpoint good at only one job. |
| `PRIVATE_KEY` | yes | — | Keeper EOA. Gas float only. |
| `SEND_RPC_URL` | no | `https://rpc.flashbots.net/fast` | Send-only endpoint. |
| `MARGIN_MULTIPLE` | no | `1.25` | Required tip-to-cost ratio. |
| `PRIORITY_GWEI` | no | `0.05` | Priority fee bid. |
| `MAX_FEE_GWEI` | no | `50` | Hard ceiling on `maxFeePerGas`. |
| `MAX_BATCH` | no | `10` | Max ids per `claimMany`. |
| `POLL_MS` | no | `12000` | Poll interval. |
| `START_BLOCK` | no | `24986598` | SLOW's deploy block. |
| `ONE_SHOT` | no | — | `true` runs a single pass and exits (cron mode). Exit code is the liveness signal. |
| `HEARTBEAT_EVERY` | no | `100` | Passes between heartbeat lines in worker mode. `0` disables. |
| `DRY_RUN` | no | — | `true` logs decisions without sending. |

## Local run

```sh
npm install
RPC_URL=... PRIVATE_KEY=0x... npm run dry-run
```

## Security

The keeper key cannot move user funds. The gate has no path to `safeTransferFrom` or
`withdrawFrom`, and `_doClaim` pins the payout to `pt.to` — the caller only ever receives
the tip. Worst case for a leaked key is loss of the ETH held for gas.
