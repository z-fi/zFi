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

  // A browser puts every classic script's top-level const into ONE shared global lexical
  // environment; jsdom's w.eval gives each call its own, so evaluating the page a script
  // at a time hides every cross-script reference behind a false ReferenceError. Evaluate
  // modules/precision.js and the page's inline scripts as one unit, which is what the
  // browser effectively does for name resolution.
  const scripts = [...html.matchAll(/<script(?![^>]*src=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  const errs = [];
  // The last statement routes on load and paints the gallery, which needs a network this
  // test does not give it. Neutralise it so a boot failure is about the page, not the stub.
  const joined = [fs.readFileSync(path.join(ROOT, 'dapp/modules/precision.js'), 'utf8')]
    .concat(scripts.map(src => src.replace(/\nroute\(\);?\s*$/, '\n')))
    .join('\n;\n');
  try { w.eval(joined); } catch (e) { errs.push(e); }
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

  // The tile is two panels and a flipper now, and both halves are painted from one
  // side value. They must never disagree about which way the trade runs.
  const doc = w.document;
  w.causeSwapSide('buy');
  const buyIn = doc.getElementById('causeSwapSym').textContent;
  const buyOut = doc.getElementById('causeSwapOutSym').textContent;
  assert.match(buyIn, /ETH/);
  assert.match(buyOut, /CELL/);

  w.causeSwapFlip();
  assert.match(doc.getElementById('causeSwapSym').textContent, /CELL/, 'flip must swap the pay side');
  assert.match(doc.getElementById('causeSwapOutSym').textContent, /ETH/, 'flip must swap the receive side');

  w.causeSwapFlip();
  assert.equal(doc.getElementById('causeSwapSym').textContent, buyIn, 'flipping twice returns to where it started');
  assert.equal(doc.getElementById('causeSwapOutSym').textContent, buyOut);

  // Switching sides must clear the old side's numbers rather than leave them to be read
  // as a quote for the new direction.
  doc.getElementById('causeSwapAmt').value = '123';
  w.causeSwapFlip();
  assert.equal(doc.getElementById('causeSwapAmt').value, '');
  assert.equal(doc.getElementById('causeSwapOut').textContent, '0.0');
});

test('balance shortcuts fill a number a person can read, without overshooting', async () => {
  const { w } = boot();
  const doc = w.document;
  doc.body.innerHTML += '<input id="causeSwapAmt">';
  w.causeSwapQuote = () => {};   // the fill is what is under test, not the quote

  // A real holding: 18,013.602899070631317592 shares.
  const held = 18013602899070631317592n;

  // "all" must stay exact — trimming it strands dust that can never be sold.
  w.causeSwapFill(held, true);
  assert.equal(doc.getElementById('causeSwapAmt').value, '18013.602899070631317592');

  // Everything else trims, and trims DOWN, so a shortcut never asks for more than is held.
  w.causeSwapFill(held / 2n);
  const half = doc.getElementById('causeSwapAmt').value;
  assert.equal(half, '9006.801449');
  assert.ok(w.ethers.parseEther(half) <= held / 2n, 'a trimmed fill must never round up');
  assert.ok(half.split('.')[1].length <= 6, 'six decimals is the readable limit');

  // A whole number should not acquire a decimal point on the way through.
  w.causeSwapFill(5000000000000000000000n);
  assert.equal(doc.getElementById('causeSwapAmt').value, '5000');
});

test('the chat composer initialises in the drawer that actually contains it', async () => {
  // This shipped broken: a first-match edit put causeChatCompose inside loadHolders,
  // where #causeChatBox does not exist, so it bailed on its own guard and the Proposals
  // & Chat drawer rendered an empty div. The contract call had been proven on a fork;
  // the wiring that reaches it never had been. Both pages share loadProposals, so this
  // covers the cause page and the DAICO page at once.
  const { w } = boot();
  const src = fs.readFileSync(path.join(ROOT, 'dapp/coin/index.html'), 'utf8');

  const callLine = src.split('\n').findIndex(l => l.includes('causeChatCompose(daoAddr).catch'));
  assert.ok(callLine > 0, 'nothing initialises the compose box');

  // Walk back to the enclosing top-level function and insist it is the right one.
  let owner = null;
  for (let i = callLine; i >= 0; i--) {
    const m = src.split('\n')[i].match(/^(?:async )?function ([A-Za-z_$][\w$]*)/);
    if (m) { owner = m[1]; break; }
  }
  assert.equal(owner, 'loadProposals',
    `the composer is initialised from ${owner}, which does not render #causeChatBox`);

  // And the box it fills must be emitted by that same function.
  const body = src.slice(src.indexOf('async function loadProposals'), src.indexOf('\n}\n', src.indexOf('async function loadProposals')));
  assert.match(body, /id="causeChatBox"/, 'loadProposals must render the box it fills');

  // The composer bails without a wallet rather than offering an input that cannot post.
  w.document.body.innerHTML += '<div id="causeChatBox"></div>';
  w._connectedAddress = null;
  await w.causeChatCompose('0xD5dcE9BEE03e69362981afE48323A657fCceB8bE');
  assert.match(w.document.getElementById('causeChatBox').innerHTML, /Connect a wallet/);
});

// The launched-coin detail page is the same failure mode as the Market tile above:
// one big template literal that parses fine and throws on the first render. It also
// has to hold up with no floor (a coin nobody has bought yet), which is the branch
// most likely to be written against a coin that has already traded.
test('the launched coin page renders from a LaunchInfo, with and without a floor', async () => {
  const { w } = boot();
  const info = {
    token: '0x6404e57f917a7baf6e26cda37c93aeefd4771417',
    pool: '0xaf9f2e884798e4b63abc9fc6879cd74bd21c8157',
    creator: '0x1111111111111111111111111111111111111111',
    owner: '0x1111111111111111111111111111111111111111',
    name: 'Free Roman', symbol: 'FREEROMAN',
    contractURI: 'data:application/json,' + encodeURIComponent(JSON.stringify({
      name: 'Free Roman', symbol: 'FREEROMAN', description: 'a coin', image: ''
    })),
    totalSupply: 1000000000000000000000000000n,
    circulating: 12000000000000000000000000n,
    backingEth: 700000000000000000n,
    floorPrice: 61205827814n,
    marketPrice: 60927114987n,
    reserve0: 700000000000000000n, reserve1: 988000000000000000000000000n,
    lpHeld: 1n, allocBps: 0n,
    fullyDilutedWei: 42039700000000000000n,
    pendingFeeEth: 0n, pendingBurn: 0n,
  };
  w.mcAggregate = async calls => calls.map(() => ({ success: false, returnData: '0x' }));
  w.fetchMetadata = async () => ({ description: 'a coin' });
  w.updateOGMeta = () => {};
  // One filled 5-minute bucket of the pool's own tape: bucket index, then packed
  // open/high/low/close, with the trade count in the top word.
  const bar = (1n << 192n) | (3000000n << 128n) | (3000000n << 96n)
            | (3000000n << 64n) | (3000000n << 32n) | 12345n;
  w.withRPCOnce = async (key, fn) => fn({
    call: async () => '0x' + (32).toString(16).padStart(64, '0')
      + (1).toString(16).padStart(64, '0') + bar.toString(16).padStart(64, '0'),
  });

  // The page's `_renderGen` is a script-scoped `let` this sandbox cannot read, and it
  // has not been bumped: route() is neutralised at boot, so it is still 0.
  await w.renderLaunchedCoinPage(info.token, info, 0);
  await new Promise(r => setImmediate(r));   // the chart loads after the paint
  let out = w.document.getElementById('app').innerHTML;
  assert.match(out, /lcChart/, 'the chart slot must be in the page');
  // The chart is drawn from the pool's own tape — no indexer — so it must survive
  // the round trip from packed words to an SVG.
  assert.match(w.document.getElementById('lcChart').innerHTML, /<svg/, 'the tape must draw');
  assert.match(out, /Free Roman/);
  assert.match(out, /lcAmount/, 'the trade input must render');
  assert.match(out, /Redeem at the floor/, 'a coin with a floor must offer the redemption');
  assert.doesNotMatch(out, /undefined/, 'a rendered "undefined" means a value went missing');

  // Nobody has bought yet: no floor, no redemption panel, and no NaN where a
  // premium would be.
  await w.renderLaunchedCoinPage(info.token, { ...info, floorPrice: 0n, backingEth: 0n }, 0);
  out = w.document.getElementById('app').innerHTML;
  assert.doesNotMatch(out, /Redeem at the floor/);
  assert.doesNotMatch(out, /NaN/);
  assert.doesNotMatch(out, /undefined/);
});

// The gallery builds its cards in a template literal too, and the launched-coin card
// is the one every new coin gets. Render it with no DAICOs, no auctions and nothing
// else in play, so a throw can only be about this card.
test('the gallery renders a launched coin card', async () => {
  const { w } = boot();
  const row = {
    token: '0x6404e57f917a7baf6e26cda37c93aeefd4771417',
    pool: '0xaf9f2e884798e4b63abc9fc6879cd74bd21c8157',
    creator: '0x1111111111111111111111111111111111111111',
    owner: '0x1111111111111111111111111111111111111111',
    name: 'Free Roman', symbol: 'FREEROMAN', contractURI: '',
    totalSupply: 10n ** 27n, circulating: 12n * 10n ** 24n,
    backingEth: 700000000000000000n,
    floorPrice: 61205827814n, marketPrice: 60927114987n,
    reserve0: 700000000000000000n, reserve1: 988n * 10n ** 24n,
    lpHeld: 1n, allocBps: 0n, fullyDilutedWei: 42n * 10n ** 18n,
    pendingFeeEth: 0n, pendingBurn: 0n,
  };
  w.launchRegistry = { launches: async () => [row], tokens: async () => [row.token], note() {} };
  w.withRPC = async () => { throw new Error('no DAICO scan in this test'); };
  w.mcAggregate = async calls => calls.map(() => ({ success: false, returnData: '0x' }));
  w.fetchMetadata = async () => ({});
  w.fetchNftAuctions = async () => [];
  w.fetchZammV0CoinsForGallery = async () => [];
  w.getEthUsd = async () => 3000;
  w.loadSpamListCached = () => {}; w.loadSpamListFresh = () => {};
  w.updateOGMeta = () => {}; w._galleryCacheLoad = () => null; w._galleryCacheSave = () => {};

  await w.renderGallery();
  const out = w.document.getElementById('app').innerHTML;
  assert.match(out, /FREEROMAN/i, 'the launched coin must reach the grid');
  assert.match(out, /backed by ether/, 'the card states what actually backs the price');
  assert.doesNotMatch(out, /undefined/);
  assert.doesNotMatch(out, /NaN/);
});
