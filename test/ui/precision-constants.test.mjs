/**
 * The precision protocol's addresses, wherever they are written down.
 *
 * There are three copies now — zSwap.html, dapp/index.html and dapp/coin/index.html —
 * each with its own encoder names because each page grew its own. A shared module would
 * be better, but zSwap ships as immutable page code and cannot import one, so at least
 * two copies are permanent. What is not acceptable is one drifting: a lens redeployed
 * and updated in a single file leaves the others calling an address that no longer
 * answers, and the symptom of that is "no route", which reads like an empty pool rather
 * than like a bug.
 *
 * The first version of this test compared PRESENCE of a known-good address, which is
 * vacuous — changing the address in a file simply made that file stop being checked. It
 * compares assignments now: whatever a page assigns to a role, every page must agree.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const PAGES = ['zSwap.html', 'dapp/index.html', 'dapp/coin/index.html'];

// role -> the identifier each page happens to use for it.
const ROLES = {
  'pool lens':       ['PPLENS', 'PPLENS_ADDRESS'],
  'liquidity lens':  ['PLQLENS', 'PLQLENS_ADDRESS'],
  'route executor':  ['PROUTE', 'PROUTE_ADDRESS'],
  'pool factory':    ['PFACTORY', 'PFACTORY_ADDRESS'],
  'router':          ['ZROUTER', 'ZROUTER_ADDRESS'],
};

function assignmentsIn(src, names) {
  const found = [];
  for (const n of names) {
    const re = new RegExp(`\\b${n}\\s*=\\s*["']?(0x[0-9a-fA-F]{40})["']?`, 'g');
    for (const m of src.matchAll(re)) found.push(m[1].toLowerCase());
  }
  return found;
}

test('every page assigns the same address to the same role', () => {
  const sources = Object.fromEntries(PAGES.map(f => [f, fs.readFileSync(path.join(ROOT, f), 'utf8')]));
  let checked = 0;

  for (const [role, names] of Object.entries(ROLES)) {
    const byFile = {};
    for (const [file, src] of Object.entries(sources)) {
      const vals = assignmentsIn(src, names);
      if (vals.length) byFile[file] = vals;
    }
    const carriers = Object.keys(byFile);
    if (carriers.length < 2) continue;   // nothing to cross-check for this role
    checked++;

    // Within a file, one role must not carry two addresses.
    for (const [file, vals] of Object.entries(byFile)) {
      const distinct = new Set(vals);
      assert.equal(distinct.size, 1,
        `${file} assigns the ${role} ${distinct.size} different addresses: ${[...distinct].join(', ')}`);
    }
    // Across files, they must agree.
    const distinct = new Set(Object.values(byFile).map(v => v[0]));
    assert.equal(distinct.size, 1,
      `the ${role} differs between pages: ` +
      Object.entries(byFile).map(([f, v]) => `${f}=${v[0]}`).join('  '));
  }

  // If naming ever changes so nothing matches, this test must fail rather than pass empty.
  assert.ok(checked >= 3, `only ${checked} role(s) were cross-checked; the ROLES map has gone stale`);
});
