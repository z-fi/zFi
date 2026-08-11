#!/usr/bin/env bash
# Verify the FIRST Precision market on Etherscan.
#
# Pools do not inherit the factory's verification: the factory deploys each
# market with CREATE2 out of an SSTORE2 blob, so a new pool lands unverified.
# Verifying one submits the source for that bytecode, and Etherscan then shows
# later markets as similar matches - they differ only in immutables.
#
# The settings are load-bearing and are the ones the blob was built with:
# solc 0.8.36, via_ir, 200 optimizer runs, evm prague. At the repo default of
# 9,999,999 runs the bytecode differs and Etherscan rejects the match.
#
# Usage:  ETHERSCAN_API_KEY=... deploy/PrecisionPool.verify.sh [address]
set -euo pipefail
POOL="${1:-0xc37F8c7E9Afe897893952ABa7fD91E0AB947837d}"
: "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY}"

# The nine constructor args, read off the pool itself rather than reconstructed
# from what we think was submitted.
RPC="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"
get () { cast call --rpc-url "$RPC" "$POOL" "$1" ; }
ARGS=$(cast abi-encode "c(address,address,address,uint256,uint256,uint256,address,address,uint256)" \
  "$(cast parse-bytes32-address "$(get 'factory()')")" \
  "$(cast parse-bytes32-address "$(get 'token0()')")" \
  "$(cast parse-bytes32-address "$(get 'token1()')")" \
  "$(cast to-dec "$(get 'sqrtPLow()')")" \
  "$(cast to-dec "$(get 'sqrtPHigh()')")" \
  "$(cast to-dec "$(get 'fee()')")" \
  "$(cast parse-bytes32-address "$(get 'hook()')")" \
  "$(cast parse-bytes32-address "$(get 'feeRecipient()')")" \
  "$(cast to-dec "$(get 'creatorFeeBps()')")")

echo "pool         $POOL"
echo "constructor  $ARGS"
# --compilation-profile is required, not optional: the cache holds several
# profiles (tokenlist, lens) and forge refuses to guess between them.
forge verify-contract "$POOL" src/pools/PrecisionPool.sol:PrecisionPool \
  --chain 1 \
  --compilation-profile default \
  --compiler-version 0.8.36+commit.8a079791 \
  --num-of-optimizations 200 \
  --via-ir \
  --evm-version prague \
  --constructor-args "$ARGS" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch
