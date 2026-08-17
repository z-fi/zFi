#!/usr/bin/env node
// One command to take a built tree to a mineable state, and to keep
// deploy/Precision.md honest about what it is describing.
//
// Emits the pool blob, emits the factory's exact creation payload, and rewrites
// the Inputs table in the runbook with the values it just computed. Doing these
// by hand is how a runbook ends up quoting a `poolInitCodeHash` from a build
// that no longer exists - which is worse than quoting none, because it looks
// authoritative and every market address depends on it.
//
// Safe to re-run. It is a pure function of the built artifacts.
//
// Usage:
//   forge build && node script/precision-prep.mjs

import {execFileSync} from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {keccak256} from "ethers";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const EXECUTOR = "0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db";
const RUNBOOK = path.join(ROOT, "deploy", "Precision.md");

const run = (args) =>
  execFileSync("node", args, {cwd: ROOT, encoding: "utf8", maxBuffer: 1 << 28});

// 1. The blob. This script refuses an oversized or wrong-runs build itself.
process.stdout.write(run([path.join("script", "emit-pool-blob.mjs")]));
const blob = fs.readFileSync(path.join(ROOT, "out", "PrecisionPool.blob.txt"), "utf8").trim();
const poolBytes = (blob.length - 2) / 2;
const poolHash = keccak256(blob);

// 2. The factory payload, through the same artifact selection the checker uses.
process.stdout.write(
  run([
    path.join("script", "emit-creation-code.mjs"),
    "PrecisionPoolFactory",
    JSON.stringify([EXECUTOR, blob]),
  ]),
);
const creation = fs
  .readFileSync(path.join(ROOT, "out", "PrecisionPoolFactory.creation.txt"), "utf8")
  .trim();
const facBytes = (creation.length - 2) / 2;
const facHash = keccak256(creation);

// 3. Rewrite the runbook's Inputs table so it cannot drift from the tree.
const table = `| input | value |
|---|---|
| CREATE2 factory (SafeSummoner) | \`0x00000000004473e1f31C8266612e7FD5504e6f2a\` |
| \`trustedExecutor\` | \`${EXECUTOR}\` (zRouter executor, live) |
| pool creation code | ${poolBytes.toLocaleString("en-US")} B (SSTORE2 cap 24,575) |
| \`poolInitCodeHash\` | \`${poolHash}\` |
| factory creation code | ${facBytes.toLocaleString("en-US")} B (EIP-3860 cap 49,152) |
| factory initcode hash | \`${facHash}\` |`;

const md = fs.readFileSync(RUNBOOK, "utf8");
const start = md.indexOf("| input | value |");
const end = md.indexOf("\n\n", start);
if (start === -1 || end === -1) throw Error("could not find the Inputs table in deploy/Precision.md");
fs.writeFileSync(RUNBOOK, md.slice(0, start) + table + md.slice(end));

console.log("");
console.log("runbook Inputs table updated from this build.");
console.log("");
console.log("next, and only when the code is frozen:");
console.log(`  node script/mine_create2_salt.js 2 1e10 out/PrecisionPoolFactory.creation.txt`);
