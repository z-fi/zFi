#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {
  AbiCoder,
  Interface,
  getAddress,
  getCreate2Address,
  keccak256,
} from "ethers";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DEPLOY = path.join(ROOT, "deploy");
const FACTORY = "0x00000000004473e1f31C8266612e7FD5504e6f2a";
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const LEGACY = "0x000000fF3D7A2d373615141d7489Ca66683DbecF";
const EIP170 = 24_576;
const SOURCES = {
  Swapboard: "src/Swapboard.sol",
  Dutchboard: "src/Dutchboard.sol",
  Floorboard: "src/Floorboard.sol",
  SwapboardView: "src/SwapboardView.sol",
  Orderbol: "src/forwarders/Orderbol.sol",
  Swapbol: "src/forwarders/Swapbol.sol",
};

// Must mirror `[[profile.default.compilation_restrictions]]` in foundry.toml.
// A contract with no restriction there compiles at the profile's own
// `optimizer_runs`, which is 9,999,999.
//
// This table used to be the single expression `name === "SwapboardView" ? 200
// : 9_999_999`, written before the restrictions existed. Every board is
// restricted now - Dutchboard and Swapboard because they do not otherwise fit
// EIP-170 - so the check could never find a matching artifact and failed with
// "run the canonical forge build first" no matter how recently you had. A
// guard that cannot pass is not a guard; it trains you to skip it.
const OPTIMIZER_RUNS = {
  Swapboard: 200,
  Dutchboard: 20,
  Floorboard: 200,
  SwapboardView: 200,
  Orderbol: 9_999_999,
  Swapbol: 9_999_999,
};
const deployInterface = new Interface([
  "function create2Deploy(bytes creationCode,bytes32 salt) returns (address)",
]);

const read = (file) => fs.readFileSync(path.join(DEPLOY, file), "utf8").trim();
const artifactAddress = (name) => getAddress(read(`${name}.address.txt`));

function findFreshArtifact(name) {
  const source = SOURCES[name];
  const sourceHash = keccak256(fs.readFileSync(path.join(ROOT, source)));
  const expectedRuns = OPTIMIZER_RUNS[name];
  if (expectedRuns === undefined) throw Error(`no optimizer_runs declared for ${name}`);
  const candidates = [];
  function visit(dir) {
    if (!fs.existsSync(dir)) return;
    for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) visit(full);
      else if (entry.name === `${name}.json`) candidates.push(full);
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
    `no fresh ${name} artifact for ${source} with optimizer_runs=${expectedRuns}; ` +
      "run the canonical forge build first",
  );
}

const specs = [
  {name: "Swapboard", args: [WETH]},
  {name: "Dutchboard", args: [WETH]},
  {name: "Floorboard", args: [WETH]},
  {name: "SwapboardView", args: []},
  {
    name: "Orderbol",
    args: [artifactAddress("Swapboard"), artifactAddress("Dutchboard")],
  },
  {
    name: "Swapbol",
    args: [
      LEGACY,
      artifactAddress("Swapboard"),
      artifactAddress("Dutchboard"),
    ],
  },
];

let failed = false;
for (const {name, args} of specs) {
  try {
    const artifact = findFreshArtifact(name);
    const bytecode = artifact.bytecode.object;
    const runtime = artifact.deployedBytecode.object;
    const abi = artifact.abi;
    const inputs = abi.find((item) => item.type === "constructor")?.inputs || [];
    if (inputs.length !== args.length) {
      throw Error(`constructor expects ${inputs.length} argument(s), manifest has ${args.length}`);
    }

    const encodedArgs = AbiCoder.defaultAbiCoder().encode(
      inputs.map((input) => input.type),
      args,
    );
    const creation = bytecode + encodedArgs.slice(2);
    const storedCreation = read(`${name}.creation.txt`);
    if (storedCreation.toLowerCase() !== creation.toLowerCase()) {
      throw Error("stored creation code differs from canonical compiler output");
    }

    const salt = read(`${name}.salt.txt`);
    const address = getCreate2Address(FACTORY, salt, keccak256(creation));
    if (address !== artifactAddress(name)) throw Error(`address mismatch: recomputed ${address}`);

    const calldata = read(`${name}.deploy.calldata.txt`);
    const decoded = deployInterface.decodeFunctionData("create2Deploy", calldata);
    if (decoded[0].toLowerCase() !== creation.toLowerCase() || decoded[1].toLowerCase() !== salt.toLowerCase()) {
      throw Error("SafeSummoner calldata does not embed the matching creation code and salt");
    }
    if (deployInterface.encodeFunctionData("create2Deploy", decoded).toLowerCase() !== calldata.toLowerCase()) {
      throw Error("SafeSummoner calldata is not canonical ABI encoding");
    }

    const creationBytes = (creation.length - 2) / 2;
    const runtimeBytes = (runtime.length - 2) / 2;
    if (runtimeBytes > EIP170) throw Error(`runtime exceeds EIP-170 by ${runtimeBytes - EIP170} bytes`);
    console.log(
      `ok  ${name.padEnd(13)} ${address}  creation=${creationBytes}  runtime=${runtimeBytes}`
        + `  initHash=${keccak256(creation)}`,
    );
  } catch (error) {
    failed = true;
    console.error(`FAIL ${name}: ${error.message}`);
  }
}

const mirror = path.join(ROOT, "out", "Swapboard.creation.txt");
if (!fs.existsSync(mirror)) {
  failed = true;
  console.error("FAIL Swapboard mirror: out/Swapboard.creation.txt is missing");
} else if (fs.readFileSync(mirror, "utf8").trim().toLowerCase() !== read("Swapboard.creation.txt").toLowerCase()) {
  failed = true;
  console.error("FAIL Swapboard mirror: out/ and deploy/ creation payloads differ");
} else {
  console.log("ok  Swapboard mirror deploy/Swapboard.creation.txt == out/Swapboard.creation.txt");
}

if (failed) process.exit(1);
