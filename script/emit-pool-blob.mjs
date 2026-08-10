#!/usr/bin/env node
// Emit the exact PrecisionPool creation code that PrecisionPoolFactory must be
// constructed with, to `out/PrecisionPool.blob.txt`.
//
// WHY THIS IS NOT `emit-creation-code.mjs`. That script emits initcode PLUS
// abi-encoded constructor args, because it exists to feed a salt miner for a
// contract that gets deployed. PrecisionPool is never deployed that way: the
// factory holds its BARE creation code and appends per-market constructor args
// itself at `createPool` time. Handing the factory anything with args already
// encoded would produce pools whose constructor arguments are the wrong ones.
//
// WHY THE OPTIMIZER SETTING IS LOAD-BEARING HERE. foundry.toml restricts
// `src/pools/PrecisionPoolFactory.sol` to `max_optimizer_runs = 200`, which
// transitively pins PrecisionPool inside that compilation unit. The same source
// at the default 9,999,999 runs compiles to ~24.7 KB of creation code, which
// does NOT fit the factory's SSTORE2 blob (EIP-170, less one byte for the STOP)
// and makes the factory unconstructable. Both builds sit in `out/` at once,
// under different paths, so picking the artifact by path is a coin flip. This
// selects it the way the checker does: matching source hash AND pinned runs.
//
// Two things follow from the blob, and both are consumed downstream:
//   - the factory's own initcode embeds it, so its mined salt depends on it;
//   - `poolInitCodeHash` is a CREATE2 input, so EVERY pool address does too.
// A blob from the wrong build silently changes both.
//
// Usage:
//   node script/emit-pool-blob.mjs

import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {keccak256} from "ethers";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SOURCE = "src/pools/PrecisionPool.sol";
const PINNED_RUNS = 200;
/// EIP-170 less the STOP byte SSTORE2 prepends.
const MAX_BLOB = 24_576 - 1;

const sourceHash = keccak256(fs.readFileSync(path.join(ROOT, SOURCE)));

const candidates = [];
(function visit(dir) {
  if (!fs.existsSync(dir)) return;
  for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) visit(full);
    else if (entry.name === "PrecisionPool.json") candidates.push(full);
  }
})(path.join(ROOT, "out"));

let picked = null;
for (const file of candidates.sort()) {
  const artifact = JSON.parse(fs.readFileSync(file, "utf8"));
  const metadata =
    typeof artifact.metadata === "string" ? JSON.parse(artifact.metadata) : artifact.metadata;
  if (!metadata) continue;
  const key = Object.keys(metadata.sources || {}).find((k) => k.endsWith(SOURCE));
  if (!key) continue;
  if (metadata.sources[key].keccak256.toLowerCase() !== sourceHash.toLowerCase()) continue;
  if (metadata.settings.optimizer.runs !== PINNED_RUNS) continue;
  picked = {file, artifact};
  break;
}

if (!picked) {
  throw Error(
    `no PrecisionPool artifact for ${SOURCE} at optimizer_runs=${PINNED_RUNS}; ` +
      "run the canonical forge build first",
  );
}

const blob = picked.artifact.bytecode.object;
if (!/^0x[0-9a-f]+$/i.test(blob)) throw Error("artifact contains invalid bytecode");
const bytes = (blob.length - 2) / 2;
if (bytes > MAX_BLOB) {
  throw Error(
    `pool creation code is ${bytes} B, over the ${MAX_BLOB} B SSTORE2 limit; ` +
      "the factory would be unconstructable. This is what the 200-run pin prevents.",
  );
}

fs.mkdirSync(path.join(ROOT, "out"), {recursive: true});
fs.writeFileSync(path.join(ROOT, "out", "PrecisionPool.blob.txt"), blob);

console.log(`artifact        ${path.relative(ROOT, picked.file)}`);
console.log(`optimizer_runs  ${PINNED_RUNS}`);
console.log(`blob bytes      ${bytes}  (limit ${MAX_BLOB}, headroom ${MAX_BLOB - bytes})`);
console.log(`poolInitCodeHash ${keccak256(blob)}`);
console.log(`written         out/PrecisionPool.blob.txt`);
