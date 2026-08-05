#!/usr/bin/env node
/**
 * Deterministic CREATE2 artifacts for TokenListPage and its four data chunks.
 *
 * The page's address depends on its constructor args, which are the four chunk
 * addresses, which are themselves CREATE2 — so the whole set is computable before
 * anything is broadcast, and the page's vanity salt can be mined offline.
 *
 *   node script/build-tokenlist-page-deploy.mjs            # print the initcode hash to mine
 *   node script/build-tokenlist-page-deploy.mjs 0x<salt>   # emit every deploy artifact
 *
 * Mine with foundry (deployer-independent — this factory does not mix msg.sender
 * into the salt; verified against the live TokenList and TokenListRenderer):
 *
 *   cast create2 --starts-with 000000 \
 *     --deployer 0x00000000004473e1f31C8266612e7FD5504e6f2a \
 *     --init-code-hash <hash printed by this script>
 */
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {AbiCoder, Interface, getCreate2Address, keccak256, toBeHex, zeroPadValue} from "ethers";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const FACTORY = "0x00000000004473e1f31C8266612e7FD5504e6f2a";
const CHUNKS = 4;
/* Chunk salts are plain counters. They are never seen by anyone — only their resulting
   addresses are, as constructor args — so there is nothing to gain by mining them, and
   a fixed counter keeps the whole set reproducible from source alone. */
const CHUNK_SALT = (i) => zeroPadValue(toBeHex(BigInt(i)), 32);

const iface = new Interface([
  "function create2Deploy(bytes creationCode,bytes32 salt) returns (address)",
]);
const out = path.join(ROOT, "out");
const dir = path.join(ROOT, "deploy");
fs.mkdirSync(dir, {recursive: true});

// --- chunks -----------------------------------------------------------------
const chunks = [];
for (let i = 1; i <= CHUNKS; i++) {
  const file = path.join(out, `TokenListPage.chunk${i}.creation.txt`);
  if (!fs.existsSync(file)) throw Error(`missing ${file}; run build-tokenlist-chunks.mjs first`);
  const creation = fs.readFileSync(file, "utf8").trim();
  const salt = CHUNK_SALT(i);
  const address = getCreate2Address(FACTORY, salt, keccak256(creation));
  chunks.push({i, creation, salt, address, bytes: (creation.length - 2) / 2});
}

// The page must reassemble to exactly the source it claims to serve.
const page = fs.readFileSync(path.join(ROOT, "dapp", "tokenlist", "page.html"));
const rebuilt = Buffer.concat(
  // stub is `61<len:2> 80 600a 5f 39 5f f3` = 10 bytes = 20 hex chars
  chunks.map((c) => Buffer.from(c.creation.slice(2 + 20), "hex"))
);
if (!rebuilt.equals(page)) throw Error("FATAL: chunks do not reassemble to page.html");

// --- page -------------------------------------------------------------------
const artifactPath = path.join(out, "TokenListPage.sol", "TokenListPage.json");
if (!fs.existsSync(artifactPath)) throw Error("no TokenListPage artifact; run forge build --force");
const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
const meta = typeof artifact.metadata === "string" ? JSON.parse(artifact.metadata) : artifact.metadata;
const srcHash = keccak256(fs.readFileSync(path.join(ROOT, "src/utils/TokenListPage.sol")));
const key = Object.keys(meta.sources || {}).find((k) => k.endsWith("src/utils/TokenListPage.sol"));
if (!key || meta.sources[key].keccak256.toLowerCase() !== srcHash.toLowerCase()) {
  throw Error("stale TokenListPage artifact — the salt would be mined against the wrong bytes");
}
const runs = meta.settings.optimizer.runs;

const encodedArgs = AbiCoder.defaultAbiCoder().encode(
  ["address", "address", "address", "address"],
  chunks.map((c) => c.address)
);
const creation = artifact.bytecode.object + encodedArgs.slice(2);
const initCodeHash = keccak256(creation);

console.log(`page.html         ${page.length} B`);
for (const c of chunks) {
  console.log(`  chunk${c.i}          ${String(c.bytes - 10).padStart(6)} B runtime  ->  ${c.address}`);
}
console.log(`TokenListPage     creation ${(creation.length - 2) / 2} B, optimizer_runs=${runs}`);
console.log(`initCodeHash      ${initCodeHash}`);

const saltArg = process.argv[2];
if (!saltArg) {
  console.log(`\nmine with:\n  cast create2 --starts-with 000000 --deployer ${FACTORY} --init-code-hash ${initCodeHash}`);
  process.exit(0);
}

const salt = zeroPadValue(toBeHex(BigInt(saltArg)), 32);
const address = getCreate2Address(FACTORY, salt, initCodeHash);
const zeros = (address.slice(2).match(/^(00)*/) || [""])[0].length / 2;
if (zeros < 3) throw Error(`salt yields ${address} — only ${zeros} leading zero byte(s), wanted >= 3`);

for (const c of chunks) {
  const name = `TokenListPage.chunk${c.i}`;
  fs.writeFileSync(path.join(dir, `${name}.creation.txt`), c.creation + "\n");
  fs.writeFileSync(path.join(dir, `${name}.salt.txt`), c.salt + "\n");
  fs.writeFileSync(path.join(dir, `${name}.address.txt`), c.address + "\n");
  fs.writeFileSync(
    path.join(dir, `${name}.deploy.calldata.txt`),
    iface.encodeFunctionData("create2Deploy", [c.creation, c.salt]) + "\n"
  );
}
fs.writeFileSync(path.join(dir, "TokenListPage.creation.txt"), creation + "\n");
fs.writeFileSync(path.join(dir, "TokenListPage.salt.txt"), salt + "\n");
fs.writeFileSync(path.join(dir, "TokenListPage.address.txt"), address + "\n");
fs.writeFileSync(
  path.join(dir, "TokenListPage.deploy.calldata.txt"),
  iface.encodeFunctionData("create2Deploy", [creation, salt]) + "\n"
);
fs.writeFileSync(path.join(dir, "TokenListPage.initcode.bin"), Buffer.from(creation.slice(2), "hex"));

console.log(`\nsalt              ${salt}`);
console.log(`ADDRESS           ${address}   (${zeros} leading zero bytes)`);
console.log(`artifacts written to deploy/`);
