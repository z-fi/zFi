#!/usr/bin/env node
/**
 * Bring everything derived from zSwap.html back in step with it.
 *
 * WHY THIS EXISTS. The page's bytes are pinned in four places, and an edit
 * invalidates all of them at once:
 *
 *   out/zSwap.chunk*.creation.txt          the 27 data contracts
 *   script/zSwapRegistry-*.calldata.txt    the DAO call that serves the page
 *   test/zSwap.t.sol                       EXPECTED_LEN and EXPECTED_HASH
 *   src/zSwap.sol                          the payload size and headroom in its
 *                                          own architecture note, which is what
 *                                          a verifier reads on a block explorer
 *
 * Only the first two have builders. The Solidity pins are read by `forge test`
 * alone, so an edit that rebuilds the chunks and the calldata still leaves the
 * page green under `check-zSwap.mjs` and red under Foundry - which is exactly
 * how it went wrong. `check-zSwap.mjs` now REFUSES that drift; this script is
 * the other half, the one command that resolves it.
 *
 * Nothing here signs or sends, and nothing touches zSwap.html itself.
 *
 * Usage:
 *   node script/sync-zSwap-artifacts.mjs             # rewrite what has drifted
 *   node script/sync-zSwap-artifacts.mjs --check     # report only, exit 1 on drift
 *   node script/sync-zSwap-artifacts.mjs --committed # same, against HEAD not the worktree
 *
 * --check reads the working tree, so it answers "are the pins right for the page
 * I am looking at". That is the wrong question straight after a commit: the pins
 * and the page can be individually correct on disk and still disagree in HEAD if
 * the page moved between building the pins and staging them. --committed reads
 * both sides out of HEAD and answers "did what I just push actually hang together",
 * which is the one a puller experiences. Run it after the commit, not before.
 */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { keccak256 } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HEAD = process.argv.includes('--committed');
const CHECK = HEAD || process.argv.includes('--check');
const CHUNKS = 27;
const EIP170 = 24576;

const show = f => execFileSync('git', ['show', `HEAD:${f}`], { cwd: ROOT, maxBuffer: 1 << 28 });
const rel = f => path.relative(ROOT, f);
const read = f => (HEAD ? show(f) : fs.readFileSync(path.join(ROOT, f))).toString('utf8');
const write = (f, s) => fs.writeFileSync(path.join(ROOT, f), s);
const has = f => { if (!HEAD) return fs.existsSync(path.join(ROOT, f)); try { show(f); return true } catch { return false } };

const page = HEAD ? show('zSwap.html') : fs.readFileSync(path.join(ROOT, 'zSwap.html'));
const LEN = page.length;
const HASH = keccak256(page).toLowerCase();
const HEADROOM = CHUNKS * EIP170 - LEN;

const n = x => x.toLocaleString('en-US');
let drifted = 0;
const note = (what, from, to) => {
  drifted++;
  console.log(`  ${CHECK ? 'DRIFT' : 'fixed'}  ${what}`);
  if (from !== undefined) console.log(`         ${from}  ->  ${to}`);
};

console.log(`${HEAD ? 'HEAD:' : ''}zSwap.html is ${n(LEN)} B, ${HASH.slice(0, 10)}…, ${n(HEADROOM)} B of headroom over ${CHUNKS} chunks\n`);

if (HEADROOM < 0) {
  console.error(`the page no longer fits ${CHUNKS} x ${EIP170} B - raise the chunk count`);
  console.error('that means zSwap.sol\'s constructor arity too, and CHUNKS in the scripts and tests');
  process.exit(1);
}

// ---- 1. Solidity: the length and hash Foundry asserts against ----
{
  const f = 'test/zSwap.t.sol';
  let s = read(f);
  const len = Number((s.match(/EXPECTED_LEN = (\d+);/) || [])[1]);
  const hash = String((s.match(/EXPECTED_HASH = (0x[0-9a-fA-F]{64});/) || [])[1]).toLowerCase();
  if (len !== LEN || hash !== HASH) {
    note(`${f}: EXPECTED_LEN / EXPECTED_HASH`, `${n(len)} B ${hash.slice(0, 10)}…`, `${n(LEN)} B ${HASH.slice(0, 10)}…`);
    if (!CHECK) {
      s = s.replace(/EXPECTED_LEN = \d+;/, `EXPECTED_LEN = ${LEN};`)
           .replace(/EXPECTED_HASH = 0x[0-9a-fA-F]{64};/, `EXPECTED_HASH = ${HASH};`);
      write(f, s);
    }
  }
}

// ---- 2. Solidity: the architecture note a verifier reads ----
{
  const f = 'src/zSwap.sol';
  let s = read(f);
  const said = Number((s.match(/HTML payload \((\d+) B\)/) || [])[1]);
  const head = Number((s.match(/(\d+) B headroom/) || [])[1]);
  const arity = Number((s.match(/address\[(\d+)\] memory d\)/) || [])[1]);
  if (arity !== CHUNKS) {
    console.error(`  zSwap.sol's constructor takes ${arity} chunks, this script expects ${CHUNKS}`);
    process.exit(1);
  }
  for (const m of s.match(/(\d+) data contracts/g) || []) {
    if (Number(m.split(' ')[0]) !== arity) {
      note(`${f}: docstring "${m}"`, m, `${arity} data contracts`);
      if (!CHECK) s = s.replace(/\d+ data contracts/g, `${arity} data contracts`);
    }
  }
  if (said !== LEN) {
    note(`${f}: payload size`, `${n(said)} B`, `${n(LEN)} B`);
    if (!CHECK) s = s.replace(/HTML payload \(\d+ B\)/, `HTML payload (${LEN} B)`);
  }
  if (head !== HEADROOM) {
    note(`${f}: headroom`, `${n(head)} B`, `${n(HEADROOM)} B`);
    if (!CHECK) s = s.replace(/\d+ B headroom/, `${HEADROOM} B headroom`);
  }
  if (!CHECK) write(f, s);
}

// ---- 3. the launch runbook's status table ----
{
  const f = 'deploy/zSwap-v0.3-LAUNCH.md';
  if (has(f)) {
    const s = read(f);
    const row = s.match(/`zSwap\.html`, ([\d,]+) B, (\d+) chunks \(([\d,]+) B headroom\)/);
    const want = `\`zSwap.html\`, ${n(LEN)} B, ${CHUNKS} chunks (${n(HEADROOM)} B headroom)`;
    if (row && row[0] !== want) {
      note(`${f}: status row`, row[0], want);
      if (!CHECK) write(f, s.replace(row[0], want));
    }
  }
}

// ---- 4. the builders, which own their own outputs ----
if (!CHECK) {
  for (const [script, what] of [
    ['build-zSwap-chunks.mjs', 'chunks'],
    ['build-zSwapRegistry-call.mjs', 'registry calldata'],
  ]) {
    try {
      execFileSync(process.execPath, [path.join(ROOT, 'script', script)], { cwd: ROOT, stdio: 'pipe' });
      console.log(`  rebuilt ${what}`);
    } catch (e) {
      console.error(`  ${script} failed:\n${String(e.stdout || '')}${String(e.stderr || '')}`);
      process.exit(1);
    }
  }
}

console.log('');
if (CHECK) {
  if (drifted) {
    console.error(HEAD ? `${drifted} artifact(s) out of step IN HEAD - the commit is not self-consistent`
                       : `${drifted} artifact(s) out of step - run: node script/sync-zSwap-artifacts.mjs`);
    process.exit(1);
  }
  console.log(HEAD ? 'HEAD hangs together: every pinned copy agrees with the committed page'
                   : 'every pinned copy of the page agrees with it');
} else {
  console.log(drifted ? `${drifted} pin(s) rewritten` : 'pins already agreed');
  console.log('now run: node script/check-zSwap.mjs  &&  forge test --match-path "test/zSwap*.t.sol"');
}
