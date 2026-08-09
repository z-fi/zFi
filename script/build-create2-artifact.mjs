#!/usr/bin/env node
// Build deterministic SafeSummoner CREATE2 artifacts for a compiled contract.
//
// Usage:
//   node script/build-create2-artifact.mjs Swapbol 0x...salt
//   node script/build-create2-artifact.mjs Swapboard 0x...salt '["0xC02a..."]'

import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {
  AbiCoder,
  Interface,
  getCreate2Address,
  keccak256,
  toBeHex,
  zeroPadValue,
} from "ethers";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const FACTORY = "0x00000000004473e1f31C8266612e7FD5504e6f2a";
const SOURCES = {
  Swapboard: "src/Swapboard.sol",
  Dutchboard: "src/Dutchboard.sol",
  Floorboard: "src/Floorboard.sol",
  SwapboardView: "src/SwapboardView.sol",
  FloorboardView: "src/FloorboardView.sol",
  Orderbol: "src/forwarders/Orderbol.sol",
  Swapbatch: "src/forwarders/Swapbatch.sol",
  Swapbol: "src/forwarders/Swapbol.sol",
  Cowol: "src/forwarders/Cowol.sol",
  TokenList: "src/utils/TokenList.sol",
  TokenListRenderer: "src/utils/TokenListRenderer.sol",
  FWCPoisonPillProposer: "src/dao/FWCPoisonPill.sol",
  ZorgPageStyle: "src/dao/ZorgPageStyle.sol",
  ZorgReceiptArt: "src/dao/ZorgReceiptArt.sol",
  ZorgConvictionRenderer: "src/dao/ZorgConvictionRenderer.sol",
  ZorgConviction: "src/dao/ZorgConviction.sol",
  ZorgTokenListLens: "src/dao/ZorgTokenListLens.sol",
  Fwabol: "src/forwarders/Fwabol.sol",
  FwabolV2: "src/forwarders/FwabolV2.sol",
  V4QuoteLens: "src/V4QuoteLens.sol",
};
// See the note in check-create2-artifacts.mjs.
const ARTIFACT_NAMES = {FwabolV2: "Fwabol"};
const artifactName = (n) => ARTIFACT_NAMES[n] ?? n;
// Contracts whose deployment manifest pins them below the default optimizer
// runs. A salt is only valid for initcode built at the pinned setting, so
// picking up an artifact compiled at any other one silently mines - or
// verifies - the wrong payload.
//
// Kept in step with `OPTIMIZER_RUNS` in check-create2-artifacts.mjs and with
// foundry.toml itself. The three boards were absent from this table long after
// they were pinned in foundry.toml, so a salt mined through here would have
// been mined against 9,999,999-run initcode that the canonical build never
// produces - the exact failure the paragraph above describes.
const PINNED_RUNS = {
  Swapboard: 200,
  Dutchboard: 20,
  Floorboard: 200,
  SwapboardView: 200,
  TokenList: 20,
  TokenListRenderer: 20,
  ZorgConviction: 200,
  ZorgConvictionRenderer: 200,
};
const [name, saltArg, constructorArgsJson = "[]"] = process.argv.slice(2);
if (!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name || "") || !saltArg) {
  console.error(
    "usage: node script/build-create2-artifact.mjs <Contract> <salt> '[constructor args]'"
  );
  process.exit(1);
}

function findFreshArtifact(contractName) {
  const source = SOURCES[contractName];
  if (!source) throw Error(`no canonical source mapping for ${contractName}`);
  const sourceHash = keccak256(fs.readFileSync(path.join(ROOT, source)));
  const expectedRuns = PINNED_RUNS[contractName] ?? 9_999_999;
  const candidates = [];
  function visit(dir) {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) visit(full);
      else if (entry.name === `${artifactName(contractName)}.json`) candidates.push(full);
    }
  }
  visit(path.join(ROOT, "out"));
  for (const file of candidates.sort()) {
    const artifact = JSON.parse(fs.readFileSync(file, "utf8"));
    const metadata = typeof artifact.metadata === "string"
      ? JSON.parse(artifact.metadata)
      : artifact.metadata;
    const sourceKey = metadata && Object.keys(metadata.sources || {}).find((key) => key.endsWith(source));
    if (
      sourceKey &&
      metadata.sources[sourceKey].keccak256.toLowerCase() === sourceHash.toLowerCase() &&
      metadata.settings.optimizer.runs === expectedRuns
    ) return artifact;
  }
  throw Error(
    `no fresh ${contractName} artifact for ${source} with optimizer_runs=${expectedRuns}; ` +
      "run the canonical forge build first",
  );
}

const artifact = findFreshArtifact(name);
const bytecode = artifact.bytecode.object;
if (!/^0x[0-9a-f]+$/i.test(bytecode)) throw Error("artifact contains invalid bytecode");
const abi = artifact.abi;
const constructor = abi.find((item) => item.type === "constructor");
const inputs = constructor?.inputs || [];
let constructorArgs;
try {
  constructorArgs = JSON.parse(constructorArgsJson);
} catch {
  throw Error("constructor args must be a JSON array");
}
if (!Array.isArray(constructorArgs) || constructorArgs.length !== inputs.length) {
  throw Error(
    `${name} constructor expects ${inputs.length} argument(s), received ${
      Array.isArray(constructorArgs) ? constructorArgs.length : "non-array"
    }`
  );
}
const encodedArgs = AbiCoder.defaultAbiCoder().encode(
  inputs.map((input) => input.type),
  constructorArgs
);
const creation = bytecode + encodedArgs.slice(2);

const salt = zeroPadValue(toBeHex(BigInt(saltArg)), 32);
const address = getCreate2Address(FACTORY, salt, keccak256(creation));
const iface = new Interface([
  "function create2Deploy(bytes creationCode,bytes32 salt) returns (address)",
]);
const calldata = iface.encodeFunctionData("create2Deploy", [creation, salt]);
const dir = path.join(ROOT, "deploy");
fs.mkdirSync(dir, {recursive: true});
fs.writeFileSync(path.join(dir, `${name}.creation.txt`), creation + "\n");
fs.writeFileSync(path.join(dir, `${name}.salt.txt`), salt + "\n");
fs.writeFileSync(path.join(dir, `${name}.address.txt`), address + "\n");
fs.writeFileSync(path.join(dir, `${name}.deploy.calldata.txt`), calldata + "\n");
// The raw payload, for tests and scripts that deploy the EXACT mined bytes
// rather than re-encoding them and hoping the encoding matches.
fs.writeFileSync(path.join(dir, `${name}.initcode.bin`), Buffer.from(creation.slice(2), "hex"));

console.log(`${name}: ${address}`);
console.log(`creation: ${(creation.length - 2) / 2} bytes`);
console.log(`salt: ${salt}`);
