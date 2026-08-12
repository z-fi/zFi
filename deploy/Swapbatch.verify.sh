#!/usr/bin/env bash
# Verify Swapbatch on Etherscan.
#
# The settings are load-bearing and are the ones the deployed initcode was built
# with: solc 0.8.36, via_ir, the repo DEFAULT 9,999,999 optimizer runs, evm
# prague. Swapbatch is not in `PINNED_RUNS`, so it takes the default - unlike
# PrecisionPool, which is pinned at 200 and whose script is otherwise identical.
#
# Verification fails without --via-ir even when everything else matches: the
# first attempt here used forge's inferred settings and Etherscan answered
# "Compiled contract deployment bytecode does NOT match".
#
# Usage:  ETHERSCAN_API_KEY=... deploy/Swapbatch.verify.sh [address]
set -euo pipefail
ADDR="${1:-0x000000Fbde0567d1966FCa91eF2A1ddCCD1fedbd}"
: "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY}"

# Read the three immutables off the contract rather than reconstructing them
# from what we think was submitted. A binding that disagrees with the manifest
# is exactly the mistake this guards.
RPC="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"
get () { cast parse-bytes32-address "$(cast call --rpc-url "$RPC" "$ADDR" "$1")" ; }
ARGS=$(cast abi-encode "constructor(address,address,address)" \
  "$(get 'weth()')" "$(get 'legacyBoard()')" "$(get 'modernBoard()')")

echo "swapbatch    $ADDR"
echo "weth         $(get 'weth()')"
echo "legacyBoard  $(get 'legacyBoard()')   <- v1"
echo "modernBoard  $(get 'modernBoard()')"
echo "constructor  $ARGS"

# --compilation-profile is required, not optional: the cache holds several
# profiles (tokenlist, lens) and forge refuses to guess between them.
forge verify-contract "$ADDR" src/forwarders/Swapbatch.sol:Swapbatch \
  --chain 1 \
  --compilation-profile default \
  --compiler-version 0.8.36+commit.8a079791 \
  --num-of-optimizations 9999999 \
  --via-ir \
  --evm-version prague \
  --constructor-args "$ARGS" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch
