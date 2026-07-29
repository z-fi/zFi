#!/usr/bin/env bash
# Extract zQuoter creation (init) bytecode using the EIP-170-compatible deploy
# recipe: solc 0.8.36, via_ir, optimizer runs 20, yul optimizer disabled.
#
# The DAO contracts in src/dao/ fail yul=false on their own (unrelated to
# zQuoter), so we temporarily move them aside during the build.
#
# Outputs:
#   out/zQuoter.creation.txt       — creation bytecode (deploy tx `data` field)
#   out/zQuoter.runtime.txt        — runtime bytecode (informational)
#   out/zQuoter.size.txt           — size report

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

DAO_DIR="$ROOT/src/dao"
DAO_HOLDOUT="/tmp/zquoter_dao_holdout_$$"

# Temporary foundry config with yul=false deploy recipe.
TMP_CFG=$(mktemp /tmp/zquoter.foundry.XXXXXX.toml)
cat > "$TMP_CFG" <<'EOF'
[profile.default]
solc = "0.8.36"
via_ir = true
optimizer = true
optimizer_runs = 20

[profile.default.optimizer_details]
yul = false
EOF

cleanup() {
  if [ -d "$DAO_HOLDOUT" ]; then
    mv "$DAO_HOLDOUT" "$DAO_DIR"
  fi
  rm -f "$TMP_CFG"
}
trap cleanup EXIT

echo "==> moving src/dao out of compile path"
if [ -d "$DAO_DIR" ]; then
  mv "$DAO_DIR" "$DAO_HOLDOUT"
fi

echo "==> building with yul=false, runs=20"
FOUNDRY_CONFIG="$TMP_CFG" forge clean >/dev/null
FOUNDRY_CONFIG="$TMP_CFG" forge build --skip test

mkdir -p out

echo "==> extracting creation bytecode"
FOUNDRY_CONFIG="$TMP_CFG" forge inspect zQuoter bytecode \
  > out/zQuoter.creation.txt

echo "==> extracting runtime bytecode (informational)"
FOUNDRY_CONFIG="$TMP_CFG" forge inspect zQuoter deployedBytecode \
  > out/zQuoter.runtime.txt

echo "==> writing size report"
FOUNDRY_CONFIG="$TMP_CFG" forge build --skip test --sizes 2>&1 \
  | grep -E "zQuoter\s" \
  | head -1 \
  > out/zQuoter.size.txt

echo ""
echo "Done."
echo "  creation bytecode: out/zQuoter.creation.txt ($(wc -c < out/zQuoter.creation.txt) bytes)"
echo "  runtime bytecode:  out/zQuoter.runtime.txt  ($(wc -c < out/zQuoter.runtime.txt) bytes)"
echo "  size report:       $(cat out/zQuoter.size.txt)"
