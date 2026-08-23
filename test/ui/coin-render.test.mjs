/**
 * Actually run the cause page's render.
 *
 * Everything else covering this page is static: page-handlers.test.mjs proves every
 * name a handler calls exists, and cause-market.test.mjs pins the arithmetic. Neither
 * executes a template literal, and that is where this page keeps breaking — a `${...}`
 * reaching for a variable that belongs to a different function parses perfectly, passes
 * both, and throws the moment it renders. It shipped exactly that way twice in one day.
 *
 * So this evaluates the page's own script in a sandbox and calls the renderers. It does
 * not assert on wording, which would make it a chore to keep green; it asserts that the
 * markup builds at all, with the reference values the live pool actually returns.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM, VirtualConsole } from 'jsdom';
import { ethers } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

function boot() {
  const html = fs.readFileSync(path.join(ROOT, 'dapp/coin/index.html'), 'utf8');
  const dom = new JSDOM('<!doctype html><html><body><div id="app"></div><div id="causePool"></div></body></html>',
    { runScripts: 'outside-only', url: 'https://zfi.wei.is/coin/', virtualConsole: new VirtualConsole() });
  const w = dom.window;
  w.ethers = ethers;
  // Pollers and network must not run: this test renders, it does not load.
  w.setInterval = () => 0; w.setTimeout = () => 0; w.fetch = () => new Promise(() => {});
  w.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  w.scrollTo = () => {};
  for (const stub of ['walletInit', 'connectWallet', 'zfiLoadingSVG', 'startPoller', 'stopPoller',
                      'toggleProposals', 'toggleHolders', 'loadHolders', 'showStatus'])
    w[stub] = () => '';
  // wallet.js state the page reads at load; without these route() throws on the way in.
  w._connectedAddress = null;
  w._signer = null;
  w.getWalletConnectTxOverrides = () => ({});
  w.EthereumProvider = { init: async () => ({ on() {}, enable: async () => [] }) };

  const scripts = [...html.matchAll(/<script(?![^>]*src=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  const errs = [];
  // The last statement routes on load and paints the gallery, which needs a network this
  // test does not give it. Neutralise it so a boot failure is about the page, not the stub.
  for (const src of scripts) {
    try { w.eval(src.replace(/\nroute\(\);?\s*$/, '\n')); } catch (e) { errs.push(e); }
  }
  return { w, errs };
}

test('the page\'s own scripts evaluate', () => {
  const { w, errs } = boot();
  // A stubbed dependency can still trip a top-level call; anything else is a real break.
  const real = errs.filter(e => !/is not a function|is not defined/.test(e.message));
  assert.deepEqual(real.map(e => e.message), []);
  assert.equal(typeof w.loadCausePool, 'function', 'loadCausePool must survive evaluation');
  assert.equal(typeof w.causeSwapSide, 'function');
});

test('the Market tile renders against real pool values without reaching out of scope', async () => {
  const { w } = boot();
  const CELL = '0xf142CfA6Ca3DFa4A131f12aACEF4890e390d70D6';
  const app = w.document.getElementById('app');
  Object.assign(app.dataset, {
    dao: '0xD5dcE9BEE03e69362981afE48323A657fCceB8bE',
    treasury: '2663698524889695025', sharesSupply: '8108109000000000000000000',
    lootSupply: '0', price: '333000000000', userBalance: '18001000000000000000000',
    sym: 'CELL',
  });
  // The live pool: one 0.3% band, ETH as token0.
  w.withRPC = async fn => fn({
    call: async ({ data }) =>
      data.startsWith('0x355da246') ? '0x' + (1).toString(16).padStart(64, '0')
      : data.startsWith('0x29c21083')
        ? '0x' + '0'.repeat(64) + (1).toString(16).padStart(64, '0')
          + ['0xaf9f2e884798e4b63abc9fc6879cd74bd21c8157', 0, 0,
             356242404745870914368n, 0, 3000n, 25020744727485219n,
             2706218041194631472538n, 356242404745870914368n, 8938585727342525217n,
             ...Array(9).fill(0)]
            .map(v => typeof v === 'string'
              ? v.slice(2).toLowerCase().padStart(64, '0')
              : BigInt(v).toString(16).padStart(64, '0')).join('')
      : '0x',
  });

  await w.loadCausePool(app.dataset.dao, CELL, 0, true);
  const out = w.document.getElementById('causePool').innerHTML;

  assert.match(out, /Market/);
  assert.match(out, /causeSwapAmt/, 'the swap input must render');
  assert.match(out, /Add liquidity/);
  // The depth row is where an out-of-scope `metadata` reference threw before.
  assert.match(out, /Depth/);
  assert.doesNotMatch(out, /undefined/, 'a rendered "undefined" means a value went missing');

  // And the tabs must paint without throwing, which is what repaints call.
  w.causeSwapSide('sell');
  w.causeSwapSide('buy');
});
