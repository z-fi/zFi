#!/usr/bin/env node
// Emit the exact creation payload (initcode ++ abi-encoded constructor args)
// for a compiled contract, to `out/<Name>.creation.txt`.
//
// This is the input a salt is mined against, so it has to come from the same
// artifact selection the checker and the artifact builder use - same source
// hash, same pinned optimizer runs. Mining against a payload built any other
// way produces a salt for an address that will never be deployed.
//
// Usage:
//   node script/emit-creation-code.mjs Swapboard '["0xC02a..."]'

import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {AbiCoder, keccak256} from "ethers";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SOURCES = {
  Swapboard: "src/Swapboard.sol",
  Dutchboard: "src/Dutchboard.sol",
  Floorboard: "src/Floorboard.sol",
  SwapboardView: "src/SwapboardView.sol",
  Orderbol: "src/forwarders/Orderbol.sol",
  Swapbol: "src/forwarders/Swapbol.sol",
  Cowol: "src/forwarders/Cowol.sol",
  Swapbatch: "src/forwarders/Swapbatch.sol",
  FloorboardView: "src/FloorboardView.sol",
  Fwabol: "src/forwarders/Fwabol.sol",
  FwabolV2: "src/forwarders/FwabolV2.sol",
  V4QuoteLens: "src/V4QuoteLens.sol",
  V4Port: "src/forwarders/V4Port.sol",
  zQuoterV4: "src/zQuoterV4.sol",
  PrecisionPoolFactory: "src/pools/PrecisionPoolFactory.sol",
  PrecisionPool: "src/pools/PrecisionPool.sol",
  PrecisionRoute: "src/pools/PrecisionRoute.sol",
  PrecisionPoolLens: "src/pools/PrecisionPoolLens.sol",
  PrecisionZap: "src/pools/PrecisionZap.sol",
  ConstantSurchargeHook: "src/pools/ConstantSurchargeHook.sol",
  PrecisionPoolPolicy: "src/pools/PrecisionPoolPolicy.sol",
};
// See the note in check-create2-artifacts.mjs: both Fwabols are named `Fwabol`
// in Solidity, and only the key tells them apart.
const ARTIFACT_NAMES = {FwabolV2: "Fwabol"};
const artifactName = (n) => ARTIFACT_NAMES[n] ?? n;
// Mirrors foundry.toml's compilation_restrictions. See the sibling tables in
// check-create2-artifacts.mjs and build-create2-artifact.mjs.
const PINNED_RUNS = {
  Swapboard: 200,
  Dutchboard: 20,
  Floorboard: 200,
  SwapboardView: 200,
  Orderbol: 9_999_999,
  Swapbol: 9_999_999,
  Cowol: 9_999_999,
  Swapbatch: 9_999_999,
  FloorboardView: 9_999_999,
  Fwabol: 9_999_999,
  FwabolV2: 9_999_999,
  V4QuoteLens: 9_999_999,
  V4Port: 9_999_999,
  zQuoterV4: 9_999_999,
  PrecisionPoolFactory: 200,
  PrecisionPool: 200,
  PrecisionRoute: 200,
  PrecisionPoolLens: 200,
  PrecisionZap: 200,
  ConstantSurchargeHook: 200,
  PrecisionPoolPolicy: 200,
};

const [name, argsJson = "[]"] = process.argv.slice(2);
const source = SOURCES[name];
if (!source) {
  console.error(`usage: node script/emit-creation-code.mjs <${Object.keys(SOURCES).join("|")}> '[args]'`);
  process.exit(1);
}

const sourceHash = keccak256(fs.readFileSync(path.join(ROOT, source)));
const expectedRuns = PINNED_RUNS[name];

const candidates = [];
(function visit(dir) {
  if (!fs.existsSync(dir)) return;
  for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) visit(full);
    else if (entry.name === `${artifactName(name)}.json`) candidates.push(full);
  }
})(path.join(ROOT, "out"));

let artifact;
for (const file of candidates.sort()) {
  const candidate = JSON.parse(fs.readFileSync(file, "utf8"));
  const metadata = typeof candidate.metadata === "string" ? JSON.parse(candidate.metadata) : candidate.metadata;
  const key = metadata && Object.keys(metadata.sources || {}).find((k) => k.endsWith(source));
  if (
    key &&
    metadata.sources[key].keccak256.toLowerCase() === sourceHash.toLowerCase() &&
    metadata.settings.optimizer.runs === expectedRuns
  ) {
    artifact = candidate;
    break;
  }
}
if (!artifact) throw Error(`no fresh ${name} artifact at optimizer_runs=${expectedRuns}; run the canonical forge build`);

const inputs = artifact.abi.find((item) => item.type === "constructor")?.inputs || [];
const args = JSON.parse(argsJson);
if (inputs.length !== args.length) throw Error(`${name} constructor expects ${inputs.length} arg(s), got ${args.length}`);

const encoded = inputs.length
  ? AbiCoder.defaultAbiCoder().encode(inputs.map((i) => i.type), args).slice(2)
  : "";
const creation = artifact.bytecode.object + encoded;
const out = path.join(ROOT, "out", `${name}.creation.txt`);
fs.writeFileSync(out, creation + "\n");

console.log(`${name.padEnd(14)} runs=${String(expectedRuns).padEnd(9)} creation=${(creation.length - 2) / 2}B`
  + ` runtime=${(artifact.deployedBytecode.object.length - 2) / 2}B initHash=${keccak256(creation)}`);
console.log(`  -> ${path.relative(ROOT, out)}`);
