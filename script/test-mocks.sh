#!/usr/bin/env bash
# Run mock-only test suites against a throwaway local chain.
#
# WHY THIS EXISTS
#
# `profile.default` in foundry.toml sets both `eth_rpc_url` and
# `fork_block_number`, which makes EVERY suite fork mainnet at the pin —
# including suites built entirely from mocks, which need no mainnet state at
# all. Neither key can be unset from the environment (`FOUNDRY_ETH_RPC_URL=`
# and `FOUNDRY_FORK_BLOCK_NUMBER=` are both ignored), so there is no per-run
# override.
#
# For most suites the wasted fork is merely slow. For the INVARIANT suites it
# is fatal: the fuzzer generates random addresses and forge issues a fresh
# eth_getAccount for each one, so a 128k-call run becomes hundreds of thousands
# of RPC round trips. No free public endpoint serves that. Measured 2026-08-07
# on test/ZorgConvictionSolvency.t.sol, which needs zero mainnet state:
#
#   eth-mainnet.public.blastapi.io   HTTP 429, failed in setup
#   ethereum-rpc.publicnode.com      HTTP 403 (archive), failed in setup
#   ethereum-rpc.publicnode.com      recent pin: 378s of timeouts, 0 runs
#   local anvil (this script)        3 passed, 384,000 calls, 25.7s
#
# Every one of those failures reads as `[FAIL: failed to set up invariant
# testing environment: ...]`, which looks like a broken contract until you read
# to the end of the line. That is the trap this script removes: the suite is
# either green or it tells you something real about the code.
#
# The local chain is empty and that is correct — these suites deploy their own
# mocks in setUp() and never touch a mainnet address. If a suite added a real
# mainnet dependency it would fail loudly here rather than silently pass, which
# is the right failure direction.
#
# Usage:
#   script/test-mocks.sh                       # the mock-only Zorg suites
#   script/test-mocks.sh --match-path 'test/Foo.t.sol'   # anything else
set -euo pipefail

PORT="${ANVIL_PORT:-8599}"
cd "$(dirname "$0")/.."

# ZorgPreviewDump is excluded because it is NOT mock-only: it reads the live
# TokenList at 0x000000146057913eC6A42a961D2E6Cb179f16272 to render the preview
# page, so on an empty chain that address has no code and setUp() reverts with
# BadInput(). Run it with a plain `forge test` against the mainnet pin.
if [ $# -eq 0 ]; then
    set -- --match-path 'test/Zorg*.t.sol' --no-match-path 'test/ZorgPreviewDump.t.sol'
fi

anvil --port "$PORT" --silent &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null || true' EXIT

until curl -s -m 2 -X POST -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
    "http://127.0.0.1:$PORT" >/dev/null 2>&1; do
    sleep 1
done

FOUNDRY_ETH_RPC_URL="http://127.0.0.1:$PORT" FOUNDRY_FORK_BLOCK_NUMBER=0 \
    forge test "$@"
