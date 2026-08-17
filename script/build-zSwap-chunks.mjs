#!/usr/bin/env node
/**
 * Split zSwap.html into data-contract chunks and emit deployable initcode.
 *
 * WHY CHUNKS
 * The page is stored as the runtime bytecode of data contracts, so a single
 * contract caps the dapp at EIP-170's 24,576 bytes. Splitting across nine
 * contracts moves that ceiling to ~221KB — the limit now applies per chunk, not
 * to the page. zSwap takes the chunk addresses as constructor args and
 * reassembles them in html(), so its own creation bytecode stays small.
 *
 * THE PAGE MUST BE STRIPPED FIRST. zSwap.html carries no comments: they were
 * ~45% of the file and were being deployed with it. `script/strip-zSwap.mjs`
 * is idempotent and reports the sizes, so run it if an edit reintroduces any.
 *
 * DEPLOY ORDER
 *   1..9. deploy chunk i           -> address A..I
 *   10.   deploy zSwap(dao, previous, A, B, C, D, E, F, G, H, I)
 *         (constructor args appended to the creation code)
 *
 * Every chunk must be non-empty and distinct or the constructor reverts
 * InvalidData, which is why the guard below refuses a count that would leave
 * one empty rather than quietly emitting fewer files than the wrapper expects.
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
const n = 11;
// The count is a positional argument; `--file` and its value are not it.
const countArg = process.argv.slice(2).find(a => /^\d+$/.test(a));
if (countArg && countArg !== String(n)) {
  console.error(`zSwap currently supports exactly ${n} data chunks; update the wrapper before changing this.`);
  process.exit(1);
}

/* `--file` so the STRIPPED page can be chunked without overwriting the
   commented source. zSwap.html carries its explanations; what gets deployed
   is `out/zSwap.min.html`, and pointing at it beats clobbering the original. */
const fileArg = (() => {
  const i = process.argv.indexOf("--file");
  return i > -1 && process.argv[i + 1] ? process.argv[i + 1] : null;
})();
const SRC = fileArg ? path.resolve(fileArg) : path.join(ROOT, "zSwap.html");
const html = fs.readFileSync(SRC);
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
  // An empty tail slice used to be skipped, which emitted fewer chunk files
  // than the wrapper's constructor arity and left the shortfall to be noticed
  // at deploy time - or not, since the round-trip guard below still passes on a
  // short set. The constructor rejects a zero-code chunk outright, so say it
  // here, where the count can still be changed.
  if (!slice.length) {
    console.error(`chunk ${i + 1} would be empty: ${html.length} B does not fill ${n} chunks`);
    process.exit(1);
  }
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
