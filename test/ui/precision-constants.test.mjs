/**
 * One definition of the precision protocol's addresses, and one cross-check of the copy
 * that cannot share it.
 *
 * They used to be written out three times. dapp/index.html and dapp/coin/index.html now
 * both take them from modules/precision.js, so those two cannot disagree by construction.
 * zSwap.html still carries its own, because it ships as immutable page code and cannot
 * import anything — so that copy is checked against the module here.
 *
 * The failure this exists for: a lens is redeployed, the module is updated, and zSwap
 * keeps calling an address that no longer answers. The symptom is "no route", which
 * reads like an empty pool rather than a bug — which is exactly how a missing precision
 * source went unnoticed for a day.
 *
 * An earlier version of this compared PRESENCE of a known-good address and was worthless:
 * changing the address in a file simply made that file stop being checked, and the
 * mutation passed clean.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = f => fs.readFileSync(path.join(ROOT, f), 'utf8');
const MODULE = read('dapp/modules/precision.js');

const grabAddr = (src, name) => {
  const m = src.match(new RegExp(`\\b${name}\\s*=\\s*['"](0x[0-9a-fA-F]{40})['"]`));
  return m && m[1].toLowerCase();
};

test('zSwap, which cannot import the module, still agrees with it', () => {
  const zswap = read('zSwap.html');
  // module name -> zSwap's own name for the same contract
  const ROLES = {
    PRECISION_LENS:    'PPLENS',
    PRECISION_LQ_LENS: 'PLQLENS',
    PRECISION_ROUTE:   'PROUTE',
    PRECISION_FACTORY: 'PFACTORY',
  };
  let checked = 0;
  for (const [modName, zName] of Object.entries(ROLES)) {
    const want = grabAddr(MODULE, modName);
    assert.ok(want, `modules/precision.js no longer defines ${modName}`);
    const got = grabAddr(zswap, zName);
    if (!got) continue;            // zSwap may not use every contract
    checked++;
    assert.equal(got, want, `zSwap's ${zName} has drifted from the module's ${modName}`);
  }
  assert.ok(checked >= 3, `only ${checked} address(es) cross-checked; the role map has gone stale`);
});

test('the dapp pages take their addresses from the module, not from a second copy', () => {
  // A pasted literal beside the alias is how the two copies came back last time.
  for (const f of ['dapp/index.html', 'dapp/coin/index.html']) {
    const src = read(f);
    assert.match(src, /modules\/precision\.js/, `${f} must load the module`);
    for (const [name, addr] of Object.entries({
      lens:    grabAddr(MODULE, 'PRECISION_LENS'),
      lqLens:  grabAddr(MODULE, 'PRECISION_LQ_LENS'),
      route:   grabAddr(MODULE, 'PRECISION_ROUTE'),
      factory: grabAddr(MODULE, 'PRECISION_FACTORY'),
    })) {
      assert.ok(!new RegExp(addr, 'i').test(src),
        `${f} hardcodes the ${name} address again instead of using the module`);
    }
  }
});

test('the module still defines the selectors the pages ask it for', () => {
  // Each page reads PSEL.<role>; a renamed key would be undefined at runtime and encode
  // calldata beginning "undefined", which no node will decode into a useful error.
  const asked = new Set();
  for (const f of ['dapp/index.html', 'dapp/coin/index.html'])
    for (const m of read(f).matchAll(/PSEL\.([A-Za-z]+)/g)) asked.add(m[1]);
  assert.ok(asked.size >= 8, `only ${asked.size} selectors referenced; expected the pages to use most of them`);
  for (const key of asked)
    assert.match(MODULE, new RegExp(`\\b${key}:\\s*'0x[0-9a-f]{8}'`),
      `the pages read PSEL.${key} but the module does not define it`);
});
