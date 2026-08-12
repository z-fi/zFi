#!/usr/bin/env bash
# Run the whole fork suite the way it was designed to be run: ONE anvil, ONE
# node process, one warm-up, snapshot-isolated scenarios.
#
# This exists because the obvious script - a shell loop calling fork-drive once
# per scenario, restarting anvil when it looked stuck - is the worst possible
# shape for this. Every invocation threw away anvil's in-memory fork cache and
# the first quote paid the cold cost again, so a suite of sixteen scenarios paid
# it sixteen times: 600s timeouts, scenarios failing for reasons that had
# nothing to do with the page, and hours spent hunting dapp bugs that were
# cache misses. `fork-drive.mjs all` already shares one warm fork across every
# scenario. Nothing needed writing; something needed deleting.
#
# Usage:
#   script/fork-suite.sh                  # every scenario
#   script/fork-suite.sh swap:wrap order:cancel
#   FORK_BLOCK=25739900 script/fork-suite.sh
set -euo pipefail

RPC_UP="${FORK_UPSTREAM:-https://mainnet.gateway.tenderly.co/6iRl6GAEIRHvSbcFXqvQ5P}"
BLOCK="${FORK_BLOCK:-25739900}"
PORT="${FORK_PORT:-8545}"
LOCAL="http://127.0.0.1:${PORT}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

alive () { cast block-number --rpc-url "$LOCAL" >/dev/null 2>&1; }

if alive; then
  echo "using the anvil already on :${PORT} (block $(cast block-number --rpc-url "$LOCAL"))"
  echo "  its cache is warm — that is worth more than a clean boot"
else
  echo "starting anvil, forked at ${BLOCK}"
  # No --silent: when this wedges, its log is the only thing that says so.
  nohup anvil --fork-url "$RPC_UP" --fork-block-number "$BLOCK" \
    --auto-impersonate --port "$PORT" > /tmp/anvil-fork-suite.log 2>&1 &
  for _ in $(seq 1 60); do sleep 2; alive && break; done
  alive || { echo "anvil never came up; see /tmp/anvil-fork-suite.log"; exit 1; }
fi

# The block must postdate every contract the page drives, or the registry comes
# back empty and the failures point at the dapp. fork-drive checks this itself
# and refuses to run - see the guard in its warm-up.
exec node "$ROOT/script/fork-drive.mjs" "${@:-all}" --rpc "$LOCAL"
