#!/usr/bin/env node
/**
 * Split zSwap.html into data-contract chunks and emit deployable initcode.
 *
 * WHY CHUNKS
 * The page is stored as the runtime bytecode of data contracts, so a single
 * contract caps the dapp at EIP-170's 24,576 bytes. Splitting across two
 * contracts moves that ceiling to ~49KB — the limit now applies per chunk, not
 * to the page. zSwap takes the chunk addresses as constructor args and
 * reassembles them in html(), so its own creation bytecode stays small.
 *
 * DEPLOY ORDER
 *   1. deploy chunk 1           -> address A
 *   2. deploy chunk 2           -> address B
 *   3. deploy chunk 3           -> address C
 *   4. deploy zSwap(A, B, C)    (constructor args appended to the creation code)
 *
 * Each chunk's initcode is the classic data-contract stub:
 *   PUSH2 <len> DUP1 PUSH1 0x0a PUSH0 CODECOPY PUSH0 RETURN | <payload>
 * which returns the payload as the contract's runtime bytecode.
 *
 * Usage: node script/build-zSwap-chunks.mjs
 */
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const EIP170 = 24576;
const n = 3;
if (process.argv[2] && process.argv[2] !== "3") {
  console.error("zSwap currently supports exactly 3 data chunks; update the wrapper before changing this.");
  process.exit(1);
}

const html = fs.readFileSync(path.join(ROOT, "zSwap.html"));
const per = Math.ceil(html.length / n);
if (per > EIP170) {
  console.error(`chunk size ${per} exceeds EIP-170 (${EIP170}); use more chunks`);
  process.exit(1);
}

const stub = (len) =>
  "61" + len.toString(16).padStart(4, "0") + "80600a5f395ff3";

fs.mkdirSync(path.join(ROOT, "out"), { recursive: true });

const parts = [];
for (let i = 0; i < n; i++) {
  const slice = html.subarray(i * per, Math.min((i + 1) * per, html.length));
  if (!slice.length) continue;
  const initcode = "0x" + stub(slice.length) + slice.toString("hex");
  const file = path.join(ROOT, "out", `zSwap.chunk${i + 1}.creation.txt`);
  fs.writeFileSync(file, initcode);
  parts.push({ i: i + 1, bytes: slice.length, file, initcode });
}

// Round-trip guard: the concatenated chunks must reproduce the page exactly.
const rebuilt = Buffer.concat(
  parts.map((p) => Buffer.from(p.initcode.slice(2 + stub(p.bytes).length), "hex"))
);
if (!rebuilt.equals(html)) {
  console.error("FATAL: chunks do not reassemble to zSwap.html");
  process.exit(1);
}

console.log(`zSwap.html: ${html.length} B -> ${parts.length} chunk(s)`);
for (const p of parts) {
  console.log(
    `  chunk${p.i}: ${p.bytes} B runtime (${EIP170 - p.bytes} B under EIP-170)  -> ${path.relative(ROOT, p.file)}`
  );
}
console.log(`reassembly verified: ${rebuilt.length} B == zSwap.html`);
console.log(`\nheadroom at this chunk count: ${EIP170 * parts.length - html.length} B`);
