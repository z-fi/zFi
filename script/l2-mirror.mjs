#!/usr/bin/env node
// The L2 mirror of the mainnet book and pool suite, on Base (8453) and
// Robinhood Chain (4663).
//
// Two kinds of contract, two deployment paths, one manifest:
//
//   REPLAY. A contract whose creation payload has nothing chain-specific in it
//   - no WETH, no PoolManager, only addresses that already sit at the same
//   place on every chain (zRouter's executor, the factory itself) - is deployed
//   by sending the very same SafeSummoner calldata that deployed it on mainnet.
//   SafeSummoner has identical code at 0x00000000004473e1... on all three chains
//   and derives the address from (salt, initcode) alone, so the mirror lands at
//   the mainnet vanity address. `deploy/<Name>.deploy.calldata.txt` is the
//   payload; nothing is rebuilt.
//
//   CREATE3. A contract that binds the chain's WETH cannot share mainnet's
//   initcode, so it cannot share mainnet's CREATE2 address either. CreateX
//   CREATE3 derives the address from (deployer, salt) and never from the
//   initcode, so ONE salt puts Base's build and Robinhood's build - different
//   constructor arguments - at ONE address on both chains. That address goes in
//   zSwap.html's per-chain table. The salt is sender-prefixed, so only the
//   deployer can use it, and byte 20 is 0x00 so the address does not depend on
//   the chain id (see script/mine-create3.mjs).
//
// Usage:
//   node script/l2-mirror.mjs build            # emit creation payloads from out/, check manifest
//   node script/l2-mirror.mjs check <chainId>  # what is live vs missing on that chain
//   node script/l2-mirror.mjs deploy <chainId> # PRIVATE_KEY=0x... ; sends what is missing, in order
//
// The manifest (deploy/l2/manifest.json) holds the CREATE3 salts and the
// derived addresses; the creation payloads it is checked against are written
// beside it, one per chain where the constructor arguments differ.

import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {AbiCoder, Contract, JsonRpcProvider, Wallet, getAddress, keccak256} from "ethers";
import {create3Address} from "./create3-derive.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DEPLOY = path.join(ROOT, "deploy");
const L2DIR = path.join(DEPLOY, "l2");
const MANIFEST = path.join(L2DIR, "manifest.json");

const SAFE_SUMMONER = "0x00000000004473e1f31C8266612e7FD5504e6f2a";
const CREATEX = "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed";
const EXECUTOR = "0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db";
const L2_QUOTER = "0x000000bd2DB80567c23E353ca95a251c573cBf9B";
const ZROUTER = "0x000000000000FB114709235f1ccBFfb925F600e4";

export const CHAINS = {
  // Mainnet is in this table for the entries that opt into it (see `chains` on a
  // manifest entry). The book and pool suite are NOT among them - those are the
  // mainnet contracts being mirrored, and they are already deployed there at
  // their own CREATE2 addresses. What mainnet is here for is a contract that has
  // to sit at the SAME address on all three, which is what CREATE3 buys.
  1: {
    name: "Ethereum",
    rpc: "https://ethereum-rpc.publicnode.com",
    weth: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    v4Quoter: "0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203",
    v4PoolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
  },
  8453: {
    name: "Base",
    rpc: "https://mainnet.base.org",
    weth: "0x4200000000000000000000000000000000000006",
    v4Quoter: "0x0d5e0F971ED27FBfF6c2837bf31316121532048D",
    v4PoolManager: "0x498581fF718922c3f8e6A244956aF099B2652b2b",
    // WETH and USDC. Every extra hub multiplies the quotes a route makes: three
    // Base hubs build in 35-75M gas and five in 100-350M, past the 50M many nodes
    // cap eth_call at, for the same routes these two find in 4-6M.
    hubs3: ["0x4200000000000000000000000000000000000006", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"],
  },
  4663: {
    name: "Robinhood",
    rpc: "https://rpc.mainnet.chain.robinhood.com",
    weth: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
    v4Quoter: "0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94",
    v4PoolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
    // WETH and USDG. The quoter itself carries WETH alone, and a three-hop route
    // needs two hubs distinct from both ends.
    hubs3: ["0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73", "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"],
  },
};

// Which chains an entry is built and deployed for. The mirror is an L2 mirror by
// default; an entry says otherwise with `"chains": [...]` in the manifest.
const L2_ONLY = [8453, 4663];
const chainsFor = (entry) => (entry.chains || L2_ONLY).map(Number);

// Order matters within each list: a dependent's constructor reads its
// dependency's code, so the factory precedes the pool suite and the boards
// precede the forwarders.
export const REPLAY = [
  "PrecisionPoolFactory",
  "PrecisionZap",
  "PrecisionPoolLens",
  "PrecisionLiquidityLens",
  "ConstantSurchargeHook",
  "PrecisionPoolPolicy",
  "SwapboardView",
  "FloorboardView",
  // The coin launcher binds only the factory and its treasury, and the treasury
  // is the FeeSplitter replayed just before it, so all three land at their
  // mainnet addresses. Its tithe constants name mainnet's BETH burner and DAO:
  // off mainnet the tenth is sent to that address with no receipt minted (see
  // deploy/L2Mirror.md). The lens refuses a launcher with no code, so it is last.
  "FeeSplitter",
  "PrecisionLauncher",
  "PrecisionLauncherLens",
];

// Same tables as check-create2-artifacts.mjs: source path and the pinned
// optimizer runs a fresh artifact must carry. The boards are the mainnet
// contracts rebuilt with another WETH; the three L2 variants are their own
// sources.
const SOURCES = {
  Swapboard: "src/Swapboard.sol",
  Dutchboard: "src/Dutchboard.sol",
  Floorboard: "src/Floorboard.sol",
  OrderbolL2: "src/forwarders/OrderbolL2.sol",
  SwapbolL2: "src/forwarders/SwapbolL2.sol",
  PrecisionRouteL2: "src/pools/PrecisionRouteL2.sol",
  V4QuoteLensL2: "src/V4QuoteLensL2.sol",
  zQuoter3HopL2: "src/zQuoter3HopL2.sol",
};
const OPTIMIZER_RUNS = {
  Swapboard: 200,
  Dutchboard: 20,
  Floorboard: 200,
  OrderbolL2: 9_999_999,
  SwapbolL2: 9_999_999,
  PrecisionRouteL2: 200,
  // The default, matching its mainnet sibling `V4QuoteLens`. Size is not the
  // constraint here - the whole contract is 3.3 KB - and there is no
  // compilation restriction to keep in step.
  V4QuoteLensL2: 9_999_999,
  // The default, like V4QuoteLensL2: well under EIP-170 and unrestricted.
  zQuoter3HopL2: 9_999_999,
};

// Constructor arguments per chain. `weth` is the chain's; every other address
// is either a mainnet-vanity mirror (same on every chain) or another CREATE3
// entry (same on every chain by construction).
const argsFor = (name, chainId, addr) => {
  const weth = CHAINS[chainId].weth;
  switch (name) {
    case "Swapboard":
    case "Dutchboard":
    case "Floorboard":
      return [weth];
    case "OrderbolL2":
      return [addr("Swapboard"), addr("Dutchboard"), addr("Floorboard"), weth];
    case "SwapbolL2":
      return [addr("Swapboard"), addr("Dutchboard"), addr("Floorboard"), weth];
    case "PrecisionRouteL2":
      return [mainnetAddress("PrecisionPoolFactory"), EXECUTOR, weth];
    // Uniswap's own V4Quoter, plus the PoolManager it answers for. The
    // constructor checks the second against the first, so a quoter pasted from
    // the wrong chain fails at deployment instead of returning (0, 0) forever.
    case "V4QuoteLensL2":
      return [CHAINS[chainId].v4Quoter, CHAINS[chainId].v4PoolManager];
    // The chain's own quoter and router (one address each on every chain), its
    // WETH, and the hubs a three-hop route may pass through.
    case "zQuoter3HopL2":
      return [L2_QUOTER, ZROUTER, weth, CHAINS[chainId].hubs3];
    default:
      throw Error(`no constructor shape for ${name}`);
  }
};

const readDeploy = (file) => fs.readFileSync(path.join(DEPLOY, file), "utf8").trim();
const mainnetAddress = (name) => getAddress(readDeploy(`${name}.address.txt`));
const readManifest = () => JSON.parse(fs.readFileSync(MANIFEST, "utf8"));

function findFreshArtifact(name) {
  const source = SOURCES[name];
  const sourceHash = keccak256(fs.readFileSync(path.join(ROOT, source)));
  const runs = OPTIMIZER_RUNS[name];
  const found = [];
  (function visit(dir) {
    if (!fs.existsSync(dir)) return;
    for (const e of fs.readdirSync(dir, {withFileTypes: true})) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) visit(full);
      else if (e.name === `${name}.json`) found.push(full);
    }
  })(path.join(ROOT, "out"));
  for (const file of found.sort()) {
    const a = JSON.parse(fs.readFileSync(file, "utf8"));
    const md = typeof a.metadata === "string" ? JSON.parse(a.metadata) : a.metadata;
    const key = md && Object.keys(md.sources || {}).find((k) => k.endsWith(source));
    if (key && md.sources[key].keccak256.toLowerCase() === sourceHash.toLowerCase() && md.settings.optimizer.runs === runs) {
      return a;
    }
  }
  throw Error(`no fresh ${name} artifact for ${source} at optimizer_runs=${runs}; run forge build first`);
}

function creationFor(name, chainId, addr) {
  const a = findFreshArtifact(name);
  const inputs = a.abi.find((x) => x.type === "constructor")?.inputs || [];
  const args = argsFor(name, chainId, addr);
  if (inputs.length !== args.length) throw Error(`${name}: constructor takes ${inputs.length}, manifest gives ${args.length}`);
  const enc = AbiCoder.defaultAbiCoder().encode(inputs.map((i) => i.type), args);
  return {creation: a.bytecode.object + enc.slice(2), runtime: (a.deployedBytecode.object.length - 2) / 2};
}

// ----------------------------------------------------------------- build

function build() {
  const m = readManifest();
  const deployer = m.deployer.toLowerCase().replace(/^0x/, "");
  const addr = (n) => getAddress(m.create3[n].address);
  let failed = false;
  for (const [name, entry] of Object.entries(m.create3)) {
    const salt = entry.salt.toLowerCase().replace(/^0x/, "");
    if (!salt.startsWith(deployer) || salt.slice(40, 42) !== "00") {
      console.error(`FAIL ${name}: salt is not deployer-prefixed with a zero guard byte`);
      failed = true;
      continue;
    }
    const derived = getAddress("0x" + create3Address(deployer, salt).address);
    if (derived !== addr(name)) {
      console.error(`FAIL ${name}: manifest says ${entry.address}, salt derives ${derived}`);
      failed = true;
      continue;
    }
    for (const chainId of chainsFor(entry)) {
      const {creation, runtime} = creationFor(name, Number(chainId), addr);
      if (runtime > 24_576) {
        console.error(`FAIL ${name}: runtime ${runtime} B exceeds EIP-170`);
        failed = true;
      }
      const file = path.join(L2DIR, `${name}.${chainId}.creation.txt`);
      fs.writeFileSync(file, creation + "\n");
      console.log(`ok  ${name.padEnd(17)} ${derived}  chain ${chainId}  creation=${(creation.length - 2) / 2}  runtime=${runtime}`);
    }
  }
  for (const name of REPLAY) {
    // Replays are checked by check-create2-artifacts.mjs; here only that the
    // payload exists and names the address the page uses.
    readDeploy(`${name}.deploy.calldata.txt`);
    console.log(`ok  ${name.padEnd(17)} ${mainnetAddress(name)}  replay`);
  }
  if (failed) process.exit(1);
}

// ----------------------------------------------------------------- check / deploy

const provider = (chainId) => new JsonRpcProvider(CHAINS[chainId].rpc, Number(chainId), {staticNetwork: true});

async function plan(chainId) {
  const m = readManifest();
  const p = provider(chainId);
  const rows = [];
  // The replay set IS the mainnet suite being mirrored; there is nothing to
  // replay onto the chain it came from.
  for (const name of Number(chainId) === 1 ? [] : REPLAY) {
    const address = mainnetAddress(name);
    const code = await p.getCode(address);
    rows.push({name, kind: "replay", address, live: code.length > 2, data: readDeploy(`${name}.deploy.calldata.txt`)});
  }
  for (const [name, entry] of Object.entries(m.create3)) {
    if (!chainsFor(entry).includes(Number(chainId))) continue;
    const address = getAddress(entry.address);
    const code = await p.getCode(address);
    const creation = fs.readFileSync(path.join(L2DIR, `${name}.${chainId}.creation.txt`), "utf8").trim();
    rows.push({name, kind: "create3", address, live: code.length > 2, salt: entry.salt, creation});
  }
  return rows;
}

async function check(chainId) {
  for (const r of await plan(chainId)) {
    console.log(`${r.live ? "live   " : "missing"} ${r.kind.padEnd(7)} ${r.name.padEnd(17)} ${r.address}`);
  }
}

async function deploy(chainId) {
  const key = process.env.PRIVATE_KEY;
  if (!key) throw Error("PRIVATE_KEY is not set");
  const p = provider(chainId);
  const wallet = new Wallet(key, p);
  const m = readManifest();
  const rows = await plan(chainId);
  // Only a CREATE3 salt is tied to its sender. A replay's address is (salt,
  // initcode) alone, so any funded key can send the replays once the CREATE3
  // set is live.
  if (rows.some((r) => !r.live && r.kind === "create3") && wallet.address.toLowerCase() !== m.deployer.toLowerCase()) {
    throw Error(`the CREATE3 salts are permissioned to ${m.deployer}, not ${wallet.address}`);
  }
  const createx = new Contract(CREATEX, [
    "function deployCreate3(bytes32 salt, bytes initCode) payable returns (address)",
    "function computeCreate3Address(bytes32 salt) view returns (address)",
  ], wallet);
  console.log(`${CHAINS[chainId].name}: deployer ${wallet.address}, balance ${await p.getBalance(wallet.address)} wei`);
  const results = [];
  for (const r of await plan(chainId)) {
    if (r.live) {
      console.log(`live     ${r.name.padEnd(17)} ${r.address}`);
      continue;
    }
    let tx;
    if (r.kind === "replay") {
      tx = await wallet.sendTransaction({to: SAFE_SUMMONER, data: r.data});
    } else {
      // CreateX must agree with the derivation before anything is sent.
      const deployer = wallet.address.toLowerCase().replace(/^0x/, "");
      const guarded = "0x" + create3Address(deployer, r.salt.toLowerCase().replace(/^0x/, "")).guarded;
      const computed = await createx.computeCreate3Address(guarded);
      if (getAddress(computed) !== r.address) throw Error(`${r.name}: CreateX derives ${computed}, manifest says ${r.address}`);
      tx = await createx.deployCreate3(r.salt, r.creation);
    }
    console.log(`sending  ${r.name.padEnd(17)} ${r.address}  tx ${tx.hash}`);
    const receipt = await tx.wait();
    // A public endpoint is a pool of nodes, and the one answering getCode may
    // trail the one that mined the receipt by a block or two. Ask again before
    // calling it a failure.
    let code = "0x";
    for (let i = 0; i < 10 && code.length <= 2; i++) {
      if (i) await new Promise((res) => setTimeout(res, 1500));
      code = await p.getCode(r.address);
    }
    if (receipt.status !== 1 || code.length <= 2) throw Error(`${r.name}: deployment did not land (status ${receipt.status}, code ${code.length})`);
    console.log(`landed   ${r.name.padEnd(17)} ${r.address}  block ${receipt.blockNumber}  gas ${receipt.gasUsed}  runtime ${(code.length - 2) / 2} B`);
    results.push({name: r.name, address: r.address, tx: tx.hash, block: receipt.blockNumber, gas: receipt.gasUsed.toString()});
    // Written after every landing: a run that dies on funds mid-list must not
    // lose the record of what it already put on chain.
    record(chainId, results.at(-1));
  }
  console.log(`recorded ${results.length} deployment(s) in deploy/l2/deployed.${chainId}.json`);
}

function record(chainId, entry) {
  const log = path.join(L2DIR, `deployed.${chainId}.json`);
  const prior = fs.existsSync(log) ? JSON.parse(fs.readFileSync(log, "utf8")) : [];
  fs.writeFileSync(log, JSON.stringify([...prior, entry], null, 2) + "\n");
}

const [cmd, chainArg] = process.argv.slice(2);
const chainId = Number(chainArg);
if (cmd === "build") build();
else if (cmd === "check" && CHAINS[chainId]) await check(chainId);
else if (cmd === "deploy" && CHAINS[chainId]) await deploy(chainId);
else {
  console.error("usage: node script/l2-mirror.mjs build | check <chainId> | deploy <chainId>");
  process.exit(1);
}
