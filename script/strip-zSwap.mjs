#!/usr/bin/env node
/**
 * Strip comments and indentation from zSwap.html.
 *
 * The page IS the deployed artifact: build-zSwap-chunks.mjs splits these exact
 * bytes across ten data contracts, and EIP-170 caps each at 24,576 — so every
 * comment byte is paid for on chain, forever, by whoever deploys the next
 * version. zSwap.html carried ~45% comments and was 97% of its ceiling; that is
 * why it is now stored stripped rather than stripped at build time. The
 * deployed bytes stay byte-identical to the file in the repo, which is what the
 * footer's auditability claim rests on.
 *
 * So this is a MIGRATION AND A GUARD, not a build step. It is idempotent: run
 * it after any edit that reintroduces comments and it reports what came off.
 * Zero means the file is already deployable as-is. The prose that used to be in
 * the page is in `git log -p zSwap.html`, which is where it stays recoverable.
 *
 * NOT A MINIFIER. Nothing is renamed, reordered or rewritten; only comments and
 * leading indentation are removed, so the file stays diffable against what the
 * chain serves.
 *
 * Usage: node script/strip-zSwap.mjs [--write]   (--write emits out/zSwap.min.html)
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SRC = path.join(ROOT, "zSwap.html");
const OUT = path.join(ROOT, "out", "zSwap.min.html");
const EIP170 = 24576, CHUNKS = 19;

/**
 * A `/` is a regex only where an expression may START.
 *
 * The alternative is treating it as division, and the file is full of literals
 * this decides the meaning of — `/[<>&"'`]/g` carries a backtick and both
 * quote characters inside a character class, so misreading it as division puts
 * the scanner into a string state that swallows the rest of the script. The
 * standard test: look back at the last significant token, and only call it
 * division after something a value can end with.
 */
const endsValue = t => /[\w$)\]]$/.test(t) &&
  !/(^|[^\w$])(return|typeof|instanceof|in|of|new|delete|void|throw|case|do|else|yield|await)$/.test(t);

/** Remove JS comments from `s`, honouring strings, templates and regexes. */
export function stripJs(s) {
  let out = "", i = 0, prev = "";
  const n = s.length;
  while (i < n) {
    const c = s[i], d = s[i + 1];
    if (c === "/" && d === "/") {
      while (i < n && s[i] !== "\n") i++;
      continue;
    }
    if (c === "/" && d === "*") {
      i += 2;
      while (i < n && !(s[i] === "*" && s[i + 1] === "/")) i++;
      i += 2;
      // A block comment between two tokens must not join them.
      if (/\w$/.test(prev) && /\w/.test(s[i] || "")) { out += " "; prev = " "; }
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      const q = c; let j = i + 1, depth = 0;
      while (j < n) {
        if (s[j] === "\\") { j += 2; continue; }
        if (q === "`" && s[j] === "$" && s[j + 1] === "{") { depth++; j += 2; continue; }
        if (q === "`" && depth && s[j] === "}") { depth--; j++; continue; }
        if (s[j] === q && !depth) break;
        j++;
      }
      const lit = s.slice(i, j + 1);
      out += lit; prev = lit; i = j + 1; continue;
    }
    if (c === "/" && !endsValue(prev.trimEnd())) {
      // Regex literal: a class `[...]` may contain an unescaped `/`.
      let j = i + 1, cls = false;
      while (j < n) {
        if (s[j] === "\\") { j += 2; continue; }
        if (s[j] === "[") cls = true;
        else if (s[j] === "]") cls = false;
        else if (s[j] === "/" && !cls) break;
        else if (s[j] === "\n") break;
        j++;
      }
      while (j + 1 < n && /[a-z]/.test(s[j + 1])) j++;
      const lit = s.slice(i, j + 1);
      out += lit; prev = lit; i = j + 1; continue;
    }
    out += c;
    if (!/\s/.test(c)) prev = (prev + c).slice(-24);
    else prev = prev + c;
    i++;
  }
  return out;
}

/** Drop blank lines and leading indentation, which the browser never reads. */
const squeeze = s => s.split("\n").map(l => l.replace(/^[ \t]+/, "")).filter(l => l !== "").join("\n");

/**
 * Every string, template and regex literal in `s`, in order.
 *
 * `stripJs` copies literals through byte-for-byte, so the only thing that can
 * alter one is `squeeze` — which works line by line and has no idea where a
 * literal starts. A multi-line template with meaningful indentation, or a blank
 * line inside one, would come out silently different: the page still parses, it
 * just emits something else, forever, because these bytes are deployed as
 * immutable code. Nothing in the page trips it TODAY, which is luck rather than
 * design, so `strip` compares this before and after and refuses on any drift.
 */
export function literals(s) {
  const out = [];
  let i = 0, prev = "";
  const n = s.length;
  while (i < n) {
    const c = s[i], d = s[i + 1];
    if (c === "/" && d === "/") { while (i < n && s[i] !== "\n") i++; continue; }
    if (c === "/" && d === "*") {
      i += 2;
      while (i < n && !(s[i] === "*" && s[i + 1] === "/")) i++;
      i += 2;
      if (/\w$/.test(prev) && /\w/.test(s[i] || "")) prev = " ";
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      const q = c; let j = i + 1, depth = 0;
      while (j < n) {
        if (s[j] === "\\") { j += 2; continue; }
        if (q === "`" && s[j] === "$" && s[j + 1] === "{") { depth++; j += 2; continue; }
        if (q === "`" && depth && s[j] === "}") { depth--; j++; continue; }
        if (s[j] === q && !depth) break;
        j++;
      }
      const lit = s.slice(i, j + 1);
      out.push(lit); prev = lit; i = j + 1; continue;
    }
    if (c === "/" && !endsValue(prev.trimEnd())) {
      let j = i + 1, cls = false;
      while (j < n) {
        if (s[j] === "\\") { j += 2; continue; }
        if (s[j] === "[") cls = true;
        else if (s[j] === "]") cls = false;
        else if (s[j] === "/" && !cls) break;
        else if (s[j] === "\n") break;
        j++;
      }
      while (j + 1 < n && /[a-z]/.test(s[j + 1])) j++;
      const lit = s.slice(i, j + 1);
      out.push(lit); prev = lit; i = j + 1; continue;
    }
    if (!/\s/.test(c)) prev = (prev + c).slice(-24); else prev = prev + c;
    i++;
  }
  return out;
}

const scripts = h => [...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]).join("\n");

export function strip(html) {
  const before = literals(scripts(html));
  // <style>…</style>: CSS has only /* */ comments, and no regex or template to
  // confuse. Handled separately so the JS scanner never sees it.
  html = html.replace(/(<style>)([\s\S]*?)(<\/style>)/g,
    (_, a, css, b) => a + squeeze(css.replace(/\/\*[\s\S]*?\*\//g, "")) + b);
  html = html.replace(/(<script>)([\s\S]*?)(<\/script>)/g,
    (_, a, js, b) => a + squeeze(stripJs(js)) + b);
  // HTML comments in the markup — and ONLY there. Run globally, this also ate
  // `<!--` … `-->` out of JS: lnPrepare's SVG sanitizer carries
  // `.replace(/<!--[\s\S]*?-->/g,"")` as a regex literal, and deleting the
  // middle of it left `.replace(/` dangling, so the stripped page no longer
  // parsed. Silent, and fatal — the page ships as immutable code, so a strip
  // that mangles a script block bricks a deployment permanently. Split the
  // markup on the blocks already processed above and only clean between them.
  html = html.split(/(<style>[\s\S]*?<\/style>|<script>[\s\S]*?<\/script>)/)
    .map(seg => /^<(?:style|script)>/.test(seg) ? seg : seg.replace(/<!--[\s\S]*?-->/g, ""))
    .join("");
  html = squeeze(html);
  const after = literals(scripts(html));
  if (after.length !== before.length) {
    throw Error(`strip changed the literal count: ${before.length} -> ${after.length}`);
  }
  for (let i = 0; i < before.length; i++) {
    if (before[i] !== after[i]) {
      throw Error(`strip altered a literal:\n  before ${JSON.stringify(before[i].slice(0, 120))}` +
        `\n  after  ${JSON.stringify(after[i].slice(0, 120))}`);
    }
  }
  return html;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const src = fs.readFileSync(SRC, "utf8");
  const out = strip(src);
  const a = Buffer.byteLength(src), b = Buffer.byteLength(out);
  const per = Math.ceil(b / CHUNKS);
  console.log(`source   ${a.toLocaleString()} bytes`);
  console.log(`stripped ${b.toLocaleString()} bytes  (-${(a - b).toLocaleString()}, -${((a - b) / a * 100).toFixed(1)}%)`);
  console.log(`per chunk ${per.toLocaleString()} / ${EIP170.toLocaleString()}  (${(per / EIP170 * 100).toFixed(1)}% full, ${(EIP170 - per).toLocaleString()} spare each)`);
  if (per > EIP170) { console.error("STILL over EIP-170"); process.exit(1); }
  if (process.argv.includes("--write")) {
    fs.mkdirSync(path.dirname(OUT), { recursive: true });
    fs.writeFileSync(OUT, out);
    console.log(`wrote ${path.relative(ROOT, OUT)}`);
  }
}
