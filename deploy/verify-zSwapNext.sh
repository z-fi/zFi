#!/bin/sh
# Verify zSwap v0.2 on Etherscan. Needs a key: https://etherscan.io/myapikey
#   ETHERSCAN_API_KEY=… sh deploy/verify-zSwapNext.sh
set -e
cd "$(dirname "$0")/.."
forge verify-contract \
  0xe686952842627A2cf81DF42CCaD54ef98046DB8D \
  src/zSwap.sol:zSwap \
  --chain-id 1 \
  --compiler-version 0.8.36 \
  --num-of-optimizations 9999999 \
  --constructor-args "$(cat deploy/zSwapNext.ctorargs.txt)" \
  --watch
