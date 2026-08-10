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
const ZERO = "0x0000000000000000000000000000000000000000";
const UNIVERSAL_ROUTER = "0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af";
const EIP170 = 24_576;
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
  PrecisionRoute: "src/pools/PrecisionRoute.sol",
  PrecisionZap: "src/pools/PrecisionZap.sol",
  PrecisionPoolLens: "src/pools/PrecisionPoolLens.sol",
  ConstantSurchargeHook: "src/pools/ConstantSurchargeHook.sol",
  PrecisionPoolPolicy: "src/pools/PrecisionPoolPolicy.sol",
};

// A table key is not always the Solidity contract name. The second Fwabol IS
// named `Fwabol` on chain - it supersedes the first and the page will call it
// that - but the first is deployed and immutable, and its source cannot be
// touched without changing its metadata hash and therefore its address. So the
// two share a contract name and are told apart by their key. Anything absent
// here is its own artifact name, which is the ordinary case.
const ARTIFACT_NAMES = {FwabolV2: "Fwabol"};
const artifactName = (name) => ARTIFACT_NAMES[name] ?? name;

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
// PrecisionPool itself is absent by design: it is never deployed through the
// CREATE2 factory. Its creation code is a constructor ARGUMENT to
// PrecisionPoolFactory, and pools are deployed by the factory under its own
// salt scheme. `emit-pool-blob.mjs` is what pins that payload.
const OPTIMIZER_RUNS = {
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
  PrecisionRoute: 200,
  PrecisionZap: 200,
  PrecisionPoolLens: 200,
  ConstantSurchargeHook: 200,
  PrecisionPoolPolicy: 200,
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
      else if (entry.name === `${artifactName(name)}.json`) candidates.push(full);
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

const PRECISION_EXECUTOR = "0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db";
// Policy owner, chosen at deployment. It is an advisory oracle no contract
// reads, but the address is baked into the initcode and therefore the salt.
const PRECISION_POLICY_OWNER = "0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2";

const specs = [
  // The Precision suite. The factory carries the pool's creation code as its
  // second constructor argument, so its spec reads the frozen blob rather than
  // rebuilding it - `emit-pool-blob.mjs` is what guarantees that file came from
  // the 200-run artifact. Every other member takes the factory's mined address,
  // which is why they could not be mined until it existed.
  {
    name: "PrecisionPoolFactory",
    args: [PRECISION_EXECUTOR, fs.readFileSync(path.join(ROOT, "out", "PrecisionPool.blob.txt"), "utf8").trim()],
  },
  {name: "PrecisionRoute", args: [artifactAddress("PrecisionPoolFactory"), PRECISION_EXECUTOR]},
  {name: "PrecisionZap", args: [artifactAddress("PrecisionPoolFactory"), PRECISION_EXECUTOR]},
  {name: "PrecisionPoolLens", args: [artifactAddress("PrecisionPoolFactory")]},
  {name: "ConstantSurchargeHook", args: [artifactAddress("PrecisionPoolFactory")]},
  {name: "PrecisionPoolPolicy", args: [artifactAddress("PrecisionPoolFactory"), PRECISION_POLICY_OWNER]},
  {name: "Swapboard", args: [WETH]},
  {name: "Dutchboard", args: [WETH]},
  {name: "Floorboard", args: [WETH]},
  {name: "SwapboardView", args: []},
  {
    name: "Orderbol",
    args: [
      artifactAddress("Swapboard"),
      artifactAddress("Dutchboard"),
      artifactAddress("Floorboard"),
    ],
  },
  {
    name: "Swapbol",
    args: [
      LEGACY,
      artifactAddress("Swapboard"),
      artifactAddress("Dutchboard"),
      artifactAddress("Floorboard"),
    ],
  },
  {name: "Cowol", args: []},
  {name: "FloorboardView", args: []},
  // No legacy board is bound: the zero address disables that whole path for
  // this deployment, which the constructor permits so long as a modern board
  // is set.
  {name: "Swapbatch", args: [WETH, ZERO, artifactAddress("Swapboard")]},
  // The Universal Router is bound at construction rather than passed per call:
  // a caller-supplied router would let anyone pair this contract's ETH with
  // arbitrary calldata. Mainnet UR, read off the Permit2 spender in the live
  // FWA sell payload rather than guessed.
  {name: "Fwabol", args: [UNIVERSAL_ROUTER]},
  // Everything it needs - the canonical V4Quoter - is a constant.
  {name: "V4QuoteLens", args: []},
  // No constructor args: the PoolManager, the token, the hook and the pool
  // parameters are all constants, so nothing can be pointed elsewhere.
  {name: "FwabolV2", args: []},
  // Any pool, hooked or not: the key is a call argument. Safe because the
  // only funds it can move are the caller's own - see the contract header.
  {name: "V4Port", args: []},
  // Reads everything through StateView, so it stays `view` and callers keep
  // their view-ness. No constructor arguments to get wrong.
  {name: "zQuoterV4", args: []},
];

let failed = false;

// A contract listed in SOURCES but absent from `specs` is not checked - it is
// merely mentioned. Cowol sat in that gap: named at the top of the file, so it
// read as covered, while nothing ever recompiled it or compared its stored
// payload, right up until it was deployed. The three tables have to agree, and
// disagreeing is itself a failure rather than a silent omission.
for (const name of Object.keys(SOURCES)) {
  if (!specs.some((spec) => spec.name === name)) {
    failed = true;
    console.error(`FAIL ${name}: in SOURCES but has no entry in specs, so it is never checked`);
  }
  if (OPTIMIZER_RUNS[name] === undefined) {
    failed = true;
    console.error(`FAIL ${name}: in SOURCES but has no optimizer_runs declared`);
  }
}
for (const {name} of specs) {
  if (!SOURCES[name]) {
    failed = true;
    console.error(`FAIL ${name}: in specs but has no source mapping`);
  }
}
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
