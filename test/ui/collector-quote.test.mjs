/**
 * Runs dapp/index.html's collector-DAO quote path for real.
 *
 * The Collectol work shipped a ReferenceError (`_exactOut`, a symbol that only
 * exists on the coin page) that no amount of syntax checking or on-chain
 * simulation could see: the file parses, the calldata I hand-built simulates,
 * and the reference only resolves when that branch actually runs. The only
 * thing that catches it is executing the page's own function.
 *
 * So this loads the real page in jsdom and calls getDaicoCoinBuyQuote against
 * live mainnet, asserting on what it returns: which venue it picked, that the
 * multicall decodes to the leg sequence the route needs, and that msg.value
 * matches the shape (native input pays, token input does not).
 *
 * Network-dependent by design - the point is the real quoter, the real lens and
 * the real pool. Skips itself if the RPC is unreachable rather than failing CI
 * on someone else's outage.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM, VirtualConsole, ResourceLoader } from 'jsdom';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const PAGE = path.join(ROOT, 'dapp', 'index.html');
const RPC = process.env.ETH_RPC_URL || 'https://ethereum.publicnode.com';

const FWC = '0x883d646d0C8202Aa23F01d4aF45E4E73804c3a49';
const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const ZERO = '0x0000000000000000000000000000000000000000';

let win = null, api = null, bootErr = null;

/**
 * Boots the real page.
 *
 * Two things make this fiddly, both worth knowing:
 *
 *  - `w.eval(src)` does NOT work. Top-level `const`/`let` inside eval belong to
 *    the eval's own scope and vanish when it returns, so every definition on the
 *    page disappears. Only real <script> evaluation keeps them.
 *  - those same declarations live in the global LEXICAL environment, never on
 *    `window`, so there is no `w.tokens` to read afterwards. The page has to
 *    hand them out from inside its own realm, which is what the probe below does.
 *
 * Loading from a file:// URL with usable resources lets jsdom pull the page's
 * own vendor bundles (ethers et al) off disk, exactly as the browser would.
 */
async function boot() {
  if (win || bootErr) return win;
  const vc = new VirtualConsole();
  const fatal = [];
  vc.on('jsdomError', (e) => fatal.push(e));

  // A real https origin, served from disk. file:// is an opaque origin, which
  // makes the page's own localStorage access throw asynchronously and fail the
  // run for a reason that has nothing to do with the code under test.
  class LocalLoader extends ResourceLoader {
    fetch(url, opts) {
      const m = /^https:\/\/zfi\.wei\.is\/(.*)$/.exec(url.split('?')[0]);
      if (!m) return null;                       // no third-party fetches
      const file = path.join(ROOT, 'dapp', m[1]);
      if (!fs.existsSync(file)) return null;
      return Promise.resolve(fs.readFileSync(file));
    }
  }

  const dom = new JSDOM(fs.readFileSync(PAGE, 'utf8'), {
    url: 'https://zfi.wei.is/',
    runScripts: 'dangerously',
    resources: new LocalLoader(),
    pretendToBeVisual: true,
    virtualConsole: vc,
    // The theme script reads matchMedia at parse time; jsdom has no such thing,
    // and the throw takes out whatever else that block was going to define.
    beforeParse(w) {
      w.matchMedia = () => ({ matches: false, media: '', addListener() {}, removeListener() {},
                              addEventListener() {}, removeEventListener() {}, onchange: null });
      w.TextEncoder = TextEncoder;
      w.TextDecoder = TextDecoder;
      w.scrollTo = () => {};
    },
  });
  const w = dom.window;
  w.TextEncoder ??= TextEncoder;
  w.TextDecoder ??= TextDecoder;
  await new Promise(r => {
    if (w.document.readyState === 'complete') return r();
    w.addEventListener('load', r);
    setTimeout(r, 15000);
  });

  // The page fetches over the network for prices; give it the real thing.
  w.fetch = (...a) => fetch(...a);

  // Ask the page, from inside its own realm, for the bindings under test.
  // Per-name, so one binding that lives in another script block cannot hide
  // whether the rest resolved.
  const WANT = ['COLLECTOR_SALES', 'tokens', 'ROUTER_IFACE', 'isDaicoCoinBuyPath',
                'collectorSaleFor', 'getDaicoCoinBuyQuote', 'isExactOutDisabled', '_inputMode'];
  const probe = w.document.createElement('script');
  probe.textContent = `window.__probe = {};
    window.__missing = [];
    ${WANT.map(n => `try { window.__probe[${JSON.stringify(n)}] = ${n}; }
      catch (e) { window.__missing.push(${JSON.stringify(n)}); }`).join('\n')}`;
  w.document.body.appendChild(probe);

  api = w.__probe;
  const missing = w.__missing ?? ['probe did not run'];
  if (!api) {
    bootErr = new Error('probe produced nothing' +
      (fatal.length ? ' | jsdom: ' + fatal.map(e => e.message).slice(0, 3).join('; ') : ''));
    return null;
  }
  if (missing.length) console.log('   (bindings not reachable in harness: ' + missing.join(', ') + ')');
  win = w;
  return win;
}

function skipIfUnavailable(t, w, ...names) {
  if (!w) { t.skip('page did not boot: ' + (bootErr?.message ?? 'unknown')); return true; }
  for (const n of names) {
    if (!api[n]) { t.skip(`${n} not reachable`); return true; }
  }
  return false;
}

test('page exposes the collector wiring', async (t) => {
  const w = await boot();
  if (skipIfUnavailable(t, w, 'COLLECTOR_SALES', 'collectorSaleFor', 'isDaicoCoinBuyPath')) return;

  const cfg = api.COLLECTOR_SALES[FWC.toLowerCase()];
  assert.ok(cfg, 'FWC must be registered as a collector sale');
  assert.equal(cfg.collectol, '0x0000003b9DFB69a1c764b1b136EE93dEDcdB2EE3');
  assert.equal(String(cfg.feeOrHook), '30');
});

test('collector routing does not depend on how the token was selected', async (t) => {
  const w = await boot();
  if (skipIfUnavailable(t, w, 'isDaicoCoinBuyPath', 'collectorSaleFor', 'tokens')) return;

  // Every way FWC can land in `tokens`. Only the search path sets _isDaicoCoin,
  // and FWC is a builtin, so the quick-pick icon never goes near it.
  const provenances = {
    'builtin / quick-pick': { address: FWC, symbol: 'FWC', decimals: 18 },
    'dropdown after search': { address: FWC, symbol: 'FWC', decimals: 18, _isDaicoCoin: true, _feeOrHook: '30' },
    'pasted address': { address: FWC, symbol: 'FWC', decimals: 18, _isCustom: true },
    'deeplink lowercase': { address: FWC.toLowerCase(), symbol: 'FWC', decimals: 18 },
  };
  const tokens = api.tokens;
  const isBuy = api.isDaicoCoinBuyPath;
  const saleFor = api.collectorSaleFor;
  for (const [how, tok] of Object.entries(provenances)) {
    tokens.FWC = tok;
    tokens.ETH ??= { address: ZERO, symbol: 'ETH', decimals: 18 };
    tokens.USDC ??= { address: USDC, symbol: 'USDC', decimals: 6 };
    assert.equal(isBuy('ETH', 'FWC'), true, `ETH->FWC via ${how}`);
    assert.equal(isBuy('USDC', 'FWC'), true, `USDC->FWC via ${how}`);
    assert.ok(saleFor('FWC'), `collector recognised via ${how}`);
  }
});

test('ETH -> FWC quotes the continuous sale, not the shallow pool', async (t) => {
  const w = await boot();
  if (skipIfUnavailable(t, w, 'getDaicoCoinBuyQuote', 'tokens')) return;
  const tokens = api.tokens;
  tokens.FWC = { address: FWC, symbol: 'FWC', decimals: 18 }; // builtin shape
  tokens.ETH ??= { address: ZERO, symbol: 'ETH', decimals: 18 };

  let q;
  try {
    q = await api.getDaicoCoinBuyQuote('1', 'ETH', 'FWC');
  } catch (e) {
    if (/fetch|network|timeout|ECONN/i.test(String(e))) return t.skip(`RPC unavailable: ${e}`);
    throw e; // a ReferenceError lands here, which is the whole point
  }

  assert.ok(q, 'quote returned');
  assert.ok(q.expectedOutput > 0n, 'positive output');
  assert.equal(q.sourceA, 'sale', `expected the mint, got ${q.sourceA}`);
  assert.equal(q.msgValue, 10n ** 18n, 'native input funds the snwap by value');
  // The sale mints 1e6 shares per ETH; the pool would pay a small fraction.
  assert.ok(q.expectedOutput >= 900000n * 10n ** 18n,
    `expected ~1e6 FWC from the mint, got ${q.expectedOutput}`);
});

test('USDC -> FWC hops to ETH and funds the forwarder as WETH', async (t) => {
  const w = await boot();
  if (skipIfUnavailable(t, w, 'getDaicoCoinBuyQuote', 'tokens', 'ROUTER_IFACE')) return;
  const tokens = api.tokens;
  tokens.FWC = { address: FWC, symbol: 'FWC', decimals: 18 };
  tokens.USDC ??= { address: USDC, symbol: 'USDC', decimals: 6 };

  let q;
  try {
    q = await api.getDaicoCoinBuyQuote('2000', 'USDC', 'FWC');
  } catch (e) {
    if (/fetch|network|timeout|ECONN/i.test(String(e))) return t.skip(`RPC unavailable: ${e}`);
    throw e;
  }

  assert.ok(q.expectedOutput > 0n, 'positive output');
  assert.equal(q.msgValue, 0n, 'a token trade must not send value');
  assert.equal(q.isTwoHop, true);

  // Decode the leg sequence. This is where a route silently loses money: a
  // missing sweep strands funds, a missing wrap starves the forwarder.
  const sels = q.calls.map(c => c.slice(0, 10));
  const name = (s) => {
    const RI = api.ROUTER_IFACE;
    for (const f of RI.fragments) {
      if (f.type === 'function' && RI.getFunction(f.name).selector === s) return f.name;
    }
    return s;
  };
  const seq = sels.map(name);
  assert.ok(seq.includes('wrap'), `expected a wrap leg, got ${seq.join(',')}`);
  assert.ok(seq.includes('snwap'), `expected an snwap leg, got ${seq.join(',')}`);
  // Everything that can be left behind must come back.
  const sweeps = q.calls.filter(c => name(c.slice(0, 10)) === 'sweep')
    .map(c => api.ROUTER_IFACE.decodeFunctionData('sweep', c)[0].toLowerCase());
  for (const tok of [ZERO, USDC.toLowerCase(), '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2']) {
    assert.ok(sweeps.includes(tok), `missing sweep for ${tok}: swept ${sweeps.join(',')}`);
  }
  assert.equal(sweeps[sweeps.length - 1], USDC.toLowerCase(), 'input token swept last');
});

// `_inputMode` is a top-level `let`, so it lives in the global lexical scope and
// cannot be assigned through `window`. Set it from inside the page's own realm.
function setInputMode(w, mode) {
  const s = w.document.createElement('script');
  s.textContent = `_inputMode = ${JSON.stringify(mode)};`;
  w.document.body.appendChild(s);
}

test('exact-out is offered for a collector DAO and refused for a pool-only coin', async (t) => {
  const w = await boot();
  if (skipIfUnavailable(t, w, 'isExactOutDisabled', 'tokens')) return;
  const tokens = api.tokens;
  tokens.FWC = { address: FWC, symbol: 'FWC', decimals: 18 };
  tokens.ETH ??= { address: ZERO, symbol: 'ETH', decimals: 18 };
  tokens.POOLONLY = { address: '0x1111111111111111111111111111111111111111',
                      symbol: 'POOLONLY', decimals: 18, _isDaicoCoin: true, _feeOrHook: '30' };

  assert.equal(api.isExactOutDisabled('ETH', 'FWC'), false, 'collector supports exact-out');
  assert.equal(api.isExactOutDisabled('ETH', 'POOLONLY'), true, 'pool-only DAICO stays exact-in');
});

test('exact-out ETH -> FWC prices backwards from the shares', async (t) => {
  const w = await boot();
  if (skipIfUnavailable(t, w, 'getDaicoCoinBuyQuote', 'tokens')) return;
  const tokens = api.tokens;
  tokens.FWC = { address: FWC, symbol: 'FWC', decimals: 18 };
  tokens.ETH ??= { address: ZERO, symbol: 'ETH', decimals: 18 };

  setInputMode(w, 'exactOut');
  let q;
  try {
    // This is the branch that shipped a ReferenceError: it is the only caller of
    // the exact-out state, so nothing else exercises it.
    q = await api.getDaicoCoinBuyQuote('250000', 'ETH', 'FWC');
  } catch (e) {
    if (/fetch|network|timeout|ECONN/i.test(String(e))) return t.skip(`RPC unavailable: ${e}`);
    throw e;
  } finally {
    setInputMode(w, 'exactIn');
  }

  assert.equal(q.expectedOutput, 250000n * 10n ** 18n, 'delivers exactly what was asked');
  // 250k shares at 1e6/ETH is 0.25 ETH; the budget must cover it and be funded.
  assert.ok(q.msgValue > 0n, 'native exact-out still sends value');
  assert.ok(q.msgValue <= 3n * 10n ** 17n, `budget should be ~0.25 ETH, got ${q.msgValue}`);
  assert.ok(q.expectedInput > 0n, 'reports what it will spend');
});

test('exact-out USDC -> FWC sizes leg 1 to the shares, not the other way round', async (t) => {
  const w = await boot();
  if (skipIfUnavailable(t, w, 'getDaicoCoinBuyQuote', 'tokens')) return;
  const tokens = api.tokens;
  tokens.FWC = { address: FWC, symbol: 'FWC', decimals: 18 };
  tokens.USDC ??= { address: USDC, symbol: 'USDC', decimals: 6 };

  setInputMode(w, 'exactOut');
  let q;
  try {
    q = await api.getDaicoCoinBuyQuote('250000', 'USDC', 'FWC');
  } catch (e) {
    if (/fetch|network|timeout|ECONN/i.test(String(e))) return t.skip(`RPC unavailable: ${e}`);
    throw e;
  } finally {
    setInputMode(w, 'exactIn');
  }

  assert.equal(q.expectedOutput, 250000n * 10n ** 18n);
  assert.equal(q.msgValue, 0n, 'a token trade must not send value');
  assert.ok(q.expectedInput > 0n, 'reports a USDC cost');
  // 250k FWC is ~0.25 ETH; at any plausible ETH price that is hundreds of USDC,
  // so a result in the single digits would mean the decimals slipped.
  assert.ok(q.expectedInput > 100n * 10n ** 6n,
    `expected hundreds of USDC, got ${q.expectedInput} (decimal error?)`);
});

// The Collectol edits were applied by replacing text ranges, and one such range
// silently swallowed four unrelated helpers in a working copy. Cheap insurance
// that the neighbours of the edited region are still there.
test('neighbouring quote helpers survived the edits', async (t) => {
  const w = await boot();
  if (!w) { t.skip('page did not boot'); return; }
  const probe = w.document.createElement('script');
  probe.textContent = `window.__present = ['isExactOutDisabled','isCurveBuyPath','isCurveSellPath',
    'isCurvePath','getCurveQuote','getZammCoinBuyQuote','getDaicoCoinBuyQuote']
    .filter(n => { try { return typeof eval(n) === 'function'; } catch { return false; } });`;
  w.document.body.appendChild(probe);
  const present = w.__present ?? [];
  for (const n of ['isExactOutDisabled', 'isCurveBuyPath', 'isCurveSellPath', 'isCurvePath',
                   'getCurveQuote', 'getZammCoinBuyQuote', 'getDaicoCoinBuyQuote']) {
    assert.ok(present.includes(n), `${n} is missing from the page`);
  }
});

// ---- Deep links ----
// ?from=bold&to=fwc&amt=5 was reported flaky. It is the same root cause as the
// quick-pick icon: `tokens.FWC` is a static builtin with no `_isDaicoCoin`, so
// the deeplink resolved the pair fine and then the quote fell through to the
// generic aggregator, which has no route to FWC. Cover resolution AND quoting.
async function bootWith(search) {
  const vc = new VirtualConsole();
  class LocalLoader extends ResourceLoader {
    fetch(url) {
      const m = /^https:\/\/zfi\.wei\.is\/(.*)$/.exec(url.split('?')[0]);
      if (!m) return null;
      const file = path.join(ROOT, 'dapp', m[1]);
      if (!fs.existsSync(file)) return null;
      return Promise.resolve(fs.readFileSync(file));
    }
  }
  const dom = new JSDOM(fs.readFileSync(PAGE, 'utf8'), {
    url: 'https://zfi.wei.is/' + search,
    runScripts: 'dangerously',
    resources: new LocalLoader(),
    pretendToBeVisual: true,
    virtualConsole: vc,
    beforeParse(w) {
      w.matchMedia = () => ({ matches: false, media: '', addListener() {}, removeListener() {},
                              addEventListener() {}, removeEventListener() {}, onchange: null });
      w.TextEncoder = TextEncoder; w.TextDecoder = TextDecoder; w.scrollTo = () => {};
    },
  });
  const w = dom.window;
  await new Promise(r => {
    if (w.document.readyState === 'complete') return r();
    w.addEventListener('load', r);
    setTimeout(r, 8000);
  });
  w.fetch = (...a) => fetch(...a);
  // The handler defers by 50ms and the quote race runs after that; a deep link
  // that resolves its tokens but never prices anything is still broken.
  await new Promise(r => setTimeout(r, 12000));
  const s = w.document.createElement('script');
  s.textContent = `window.__dl = { from: (typeof fromToken !== 'undefined') ? fromToken : null,
                                    to: (typeof toToken !== 'undefined') ? toToken : null,
                                    mode: (typeof _inputMode !== 'undefined') ? _inputMode : null,
                                    amt: document.getElementById('fromAmount')?.value ?? null,
                                    out: document.getElementById('toAmount')?.value ?? null,
                                    route: document.getElementById('routeInfo')?.textContent ?? null };`;
  w.document.body.appendChild(s);
  const dl = w.__dl;
  return { w, dl, close: () => { try { w.close(); } catch {} } };
}

test('deep link ?from=bold&to=fwc&amt=5 resolves both sides and the amount', async (t) => {
  const { dl, close } = await bootWith('?from=bold&to=fwc&amt=5');
  t.after(close);
  if (!dl) return t.skip('page did not boot');
  assert.equal(dl.to, 'FWC', `to side resolved, got ${dl.to}`);
  assert.equal(dl.from, 'BOLD', `from side resolved, got ${dl.from}`);
  assert.equal(dl.mode, 'exactIn');
  assert.equal(dl.amt, '5', 'amount applied to the input');
  // Resolving the pair is not enough - the link has to price.
  assert.ok(dl.out && Number(dl.out) > 0, `no quote produced (toAmount=${dl.out}, route=${dl.route})`);
  assert.match(dl.route ?? '', /sale/, `expected the mint in the route, got ${dl.route}`);
});

test('deep link ?from=eth&to=fwc&outamt=250000 switches to exact-out', async (t) => {
  const { w, dl, close } = await bootWith('?from=eth&to=fwc&outamt=250000');
  t.after(close);
  if (!dl) return t.skip('page did not boot');
  assert.equal(dl.to, 'FWC');
  assert.equal(dl.mode, 'exactOut', 'outamt must select exact-out');
  const s = w.document.createElement('script');
  s.textContent = `window.__out = document.getElementById('toAmount')?.value ?? null;`;
  w.document.body.appendChild(s);
  assert.equal(w.__out, '250000');
});

test('BOLD -> FWC actually quotes, which is what the deep link needs', async (t) => {
  const w = await boot();
  if (skipIfUnavailable(t, w, 'getDaicoCoinBuyQuote', 'tokens')) return;
  const tokens = api.tokens;
  if (!tokens.BOLD) return t.skip('BOLD not registered in this build');
  // The builtin shape: exactly what a deeplink or the quick-pick hands over.
  tokens.FWC = { address: FWC, symbol: 'FWC', decimals: 18 };

  let q;
  try {
    q = await api.getDaicoCoinBuyQuote('5', 'BOLD', 'FWC');
  } catch (e) {
    if (/fetch|network|timeout|ECONN/i.test(String(e))) return t.skip(`RPC unavailable: ${e}`);
    throw e;
  }
  assert.ok(q.expectedOutput > 0n, 'BOLD must produce a quote, not fall through');
  assert.equal(q.msgValue, 0n, 'token input sends no value');
  assert.equal(q.isTwoHop, true, 'BOLD hops through ETH');
});

// Reported symptom: opening ?from=bold&to=fwc&amt=5 lands on the default pair
// and the URL itself is rewritten to ?from=eth&to=zorg. That rewrite is the
// damaging part - replaceState leaves no history entry, so the shared link is
// destroyed rather than merely ignored.
//
// The URL sync holds off while a deeplinked token is unresolved, but that hold
// used to be armed only after the params were read. Anything throwing earlier
// in init skipped both, and the default pair went to the URL. Simulate that by
// breaking a function init calls before the swap deeplink runs.
test('a deep link survives an unrelated failure earlier in init', async (t) => {
  const html = fs.readFileSync(PAGE, 'utf8');
  const vc = new VirtualConsole();
  class LocalLoader extends ResourceLoader {
    fetch(url) {
      const m = /^https:\/\/zfi\.wei\.is\/(.*)$/.exec(url.split('?')[0]);
      if (!m) return null;
      const file = path.join(ROOT, 'dapp', m[1]);
      if (!fs.existsSync(file)) return null;
      return Promise.resolve(fs.readFileSync(file));
    }
  }
  const dom = new JSDOM(html, {
    url: 'https://zfi.wei.is/?from=bold&to=fwc&amt=5',
    runScripts: 'dangerously',
    resources: new LocalLoader(),
    pretendToBeVisual: true,
    virtualConsole: vc,
    beforeParse(w) {
      w.matchMedia = () => ({ matches: false, media: '', addListener() {}, removeListener() {},
                              addEventListener() {}, removeEventListener() {}, onchange: null });
      w.TextEncoder = TextEncoder; w.TextDecoder = TextDecoder; w.scrollTo = () => {};
      // Break something init touches before the swap deeplink is parsed.
      w.addEventListener('DOMContentLoaded', () => {
        try { w.eval('loadWeiLists = function () { throw new Error("simulated init failure"); };'); } catch (_) {}
      }, { once: true });
    },
  });
  const w = dom.window;
  await new Promise(r => {
    if (w.document.readyState === 'complete') return r();
    w.addEventListener('load', r);
    setTimeout(r, 8000);
  });
  await new Promise(r => setTimeout(r, 1500));
  const s = w.document.createElement('script');
  s.textContent = `window.__u = { search: location.search,
    pf: typeof _pendingDeeplinkFrom !== 'undefined' ? _pendingDeeplinkFrom : 'n/a',
    pt: typeof _pendingDeeplinkTo !== 'undefined' ? _pendingDeeplinkTo : 'n/a' };`;
  w.document.body.appendChild(s);
  const u = w.__u;
  try { w.close(); } catch {}

  assert.ok(!/from=eth&to=zorg/.test(u.search),
    `the link was overwritten with the default pair: ${u.search}`);
  assert.match(u.search, /from=bold/, `from param lost: ${u.search}`);
  assert.match(u.search, /to=fwc/, `to param lost: ${u.search}`);
});
