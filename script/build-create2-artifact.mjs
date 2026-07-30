#!/usr/bin/env node
// Build deterministic SafeSummoner CREATE2 artifacts for a compiled contract.
//
// Usage:
//   node script/build-create2-artifact.mjs Swapbol 0x...salt
//   node script/build-create2-artifact.mjs Swapboard 0x...salt '["0xC02a..."]'

import fs from "node:fs";
import path from "node:path";
import {execFileSync} from "node:child_process";
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
const [name, saltArg, constructorArgsJson = "[]"] = process.argv.slice(2);
if (!/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name || "") || !saltArg) {
  console.error(
    "usage: node script/build-create2-artifact.mjs <Contract> <salt> '[constructor args]'"
  );
  process.exit(1);
}

const bytecode = execFileSync("forge", ["inspect", name, "bytecode"], {
  cwd: ROOT,
  encoding: "utf8",
}).trim();
if (!/^0x[0-9a-f]+$/i.test(bytecode)) throw Error("forge returned invalid bytecode");

const abi = JSON.parse(
  execFileSync("forge", ["inspect", name, "abi", "--json"], {
    cwd: ROOT,
    encoding: "utf8",
  })
);
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

console.log(`${name}: ${address}`);
console.log(`creation: ${(creation.length - 2) / 2} bytes`);
console.log(`salt: ${salt}`);
