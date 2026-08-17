#!/usr/bin/env node
/**
 * Time a real quote against real mainnet, and print the round-trip waterfall.
 *
 * Quoting is entirely read-only — eth_call, eth_blockNumber, eth_getCode — so
 * it can be measured without a wallet by injecting a provider that forwards to
 * an HTTP RPC. eth_sendTransaction throws here; nothing can be signed or sent.
 *
 * What it reports is the SERIAL DEPTH, not the call count. Round trips that
 * overlap cost nothing extra; the number that matters is the longest chain of
 * requests that had to wait for each other, because that is what the user
 * experiences as the quote being slow.
 *
 * Usage:
 *   node script/measure-quote.mjs                    # ETH -> USDC, 1
 *   node script/measure-quote.mjs --pair ETH,WBTC --amount 5 --runs 3
 *   node script/measure-quote.mjs --rpc https://...
 */
import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AbiCoder } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2);
const val = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d; };

// Never hardcode an endpoint that carries a key — this file is committed.
const RPC = val('--rpc', process.env.ETH_RPC_URL || 'https://eth-mainnet.public.blastapi.io');
// A LIST, because the interesting case is CHANGING pairs.
// Re-quoting one pair hits candCache, which predates any of this — so a
// same-pair loop measures the old cache and reports no difference. A user
// walking the token picker changes the pair on every step, and that is the
// path where a per-pair block-number cache cannot help.
const PAIRS = val('--pairs', val('--pair', 'ETH,USDC')).trim().split(/\s+/).map(p => p.split(','));
const AMOUNT = val('--amount', '1');
const RUNS = Number(val('--runs', '3'));
const ACCOUNT = val('--account', '0x0000000000000000000000000000000000000001');
// Simulate a stingier node. Public RPCs cap eth_call gas anywhere from ~50M to
// 500M; passing an explicit `gas` makes the node enforce that number, which is
// the same ceiling its own cap would impose. Tuning against one generous
// endpoint and calling it done is how a fast path stays fast only for us.
const GASCAP = val('--gascap', '');

// Served over http rather than file:// so the page sees an ordinary origin.
const html = fs.readFileSync(path.join(ROOT, 'zSwap.html'));
const server = http.createServer((_, res) => {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(html);
}).listen(0, '127.0.0.1');
await new Promise(r => server.once('listening', r));
const PORT = server.address().port;

const browser = await chromium.launch();
const page = await browser.newPage();
page.on('pageerror', e => console.error('PAGEERROR', e.message));

const heavy = [];
await page.exposeFunction('__rpc', async (method, params) => {
  if (/sendTransaction|sign|permissions/i.test(method)) throw Error(`refused: ${method}`);
  const t0 = Date.now();
  const r = await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method,
      params: (GASCAP && method === 'eth_call' && params?.[0])
        ? [{ ...params[0], gas: '0x' + BigInt(GASCAP).toString(16) }, ...params.slice(1)]
        : params }),
  }).then(x => x.json());
  // A failing aggregate3 says nothing about WHICH venue was too heavy — the
  // wrapper is what the node reports on. Decode the batch so the inner
  // targets and selectors are nameable.
  if (r.error && params?.[0]?.data?.startsWith('0x82ad56cb')) {
    try {
      const [inner] = new AbiCoder().decode(
        ['tuple(address target,bool allowFailure,bytes callData)[]'],
        '0x' + params[0].data.slice(10));
      heavy.push(inner.map(c => `${c.target.slice(0, 10)}:${c.callData.slice(0, 10)}`));
    } catch {}
  }
  return { ms: Date.now() - t0, error: r.error ? r.error.message : null, result: r.result };
});

await page.addInitScript(({ acct }) => {
  window.__log = [];
  let seq = 0;
  window.ethereum = {
    isMetaMask: true,
    on() {}, removeListener() {},
    request: async ({ method, params }) => {
      if (method === 'eth_chainId') return '0x1';
      if (method === 'eth_accounts' || method === 'eth_requestAccounts') return [acct];
      const id = ++seq;
      const start = performance.now();
      const rec = { id, method, start, end: null,
        to: (params && params[0] && params[0].to) || '',
        sel: (params && params[0] && params[0].data || '').slice(0, 10) };
      window.__log.push(rec);
      const r = await window.__rpc(method, params || []);
      rec.end = performance.now();
      rec.net = r.ms;
      if (r.error) { rec.err = r.error; throw Error(r.error); }
      return r.result;
    },
  };
}, { acct: ACCOUNT });

await page.goto(`http://127.0.0.1:${PORT}/`, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(6000);           // token list, ranking, chart

const pick = (id, sym) => page.evaluate(([i, s]) => {
  const el = document.getElementById(i);
  const o = [...el.options].find(x => x.textContent.trim() === s);
  if (!o || o.disabled) return false;
  el.value = o.value; el.dispatchEvent(new Event('change', { bubbles: true }));
  return true;
}, [id, sym]);

await page.waitForTimeout(1500);

/** Longest chain of requests that had to wait for each other. */
const serialDepth = (calls) => {
  const sorted = [...calls].sort((a, b) => a.start - b.start);
  let best = 0;
  const depth = new Map();
  for (const c of sorted) {
    let d = 1;
    for (const p of sorted) {
      if (p === c) break;
      if (p.end <= c.start + 1) d = Math.max(d, (depth.get(p) || 1) + 1);
    }
    depth.set(c, d);
    best = Math.max(best, d);
  }
  return best;
};

console.log(`\nRPC   ${RPC}`);
console.log(`walk  ${PAIRS.map(p => p.join('->')).join(', ')}   amount ${AMOUNT}   runs ${RUNS}\n`);

// The amount is typed ONCE. Changing a token fires the page's own change
// handler, which starts a quote immediately — so the measured window has to
// open BEFORE the pair changes, or it catches the tail of the previous quote
// and reports a suspiciously fast one that never happened.
await page.fill('#amt', AMOUNT);
await page.waitForTimeout(4000);

const totals = [];
for (let run = 1; run <= RUNS; run++) {
  const [FROM, TO] = PAIRS[(run - 1) % PAIRS.length];
  const prev = await page.evaluate(() => document.getElementById('outAmt').value);
  await page.evaluate(() => { window.__log.length = 0; });
  const t0 = Date.now();
  if (!await pick('fromSel', FROM)) throw Error(`no ${FROM} in the from list`);
  if (!await pick('toSel', TO)) throw Error(`no ${TO} in the to list`);
  await page.waitForFunction(
    (p) => { const v = document.getElementById('outAmt').value; return v && v !== '...' && v !== p; },
    prev, { timeout: 60000 },
  ).catch(() => console.log('  (quote did not resolve/change)'));
  const wall = Date.now() - t0;
  await page.waitForTimeout(250);           // let stragglers land in the log
  const { log, out, rate, gaveUp, stat } = await page.evaluate(() => ({
    log: window.__log.map(r => ({ method: r.method, start: r.start, end: r.end, net: r.net, err: r.err, to: r.to, sel: r.sel })),
    out: document.getElementById('outAmt').value,
    gaveUp: (typeof mcGaveUp !== 'undefined') ? mcGaveUp : 'n/a',
    stat: document.getElementById('stat').textContent,
    rate: document.getElementById('rate').textContent,
  }));
  const done = log.filter(r => r.end != null);
  const by = {};
  for (const r of done) {
    by[r.method] ||= { n: 0, ms: 0 };
    by[r.method].n++; by[r.method].ms += r.net || 0;
  }
  totals.push({ wall, calls: done.length, depth: serialDepth(done) });
  console.log(`         gaveUp=${gaveUp}${stat ? '  stat: ' + stat.slice(0, 70) : ''}`);
  console.log(`run ${run} ${FROM}->${TO}: ${wall} ms wall · ${done.length} calls · serial depth ${serialDepth(done)} · out ${out}`);
  for (const [m, v] of Object.entries(by).sort((a, b) => b[1].ms - a[1].ms)) {
    console.log(`         ${m.padEnd(18)} n=${String(v.n).padStart(3)}  ${String(v.ms).padStart(6)} ms total  ${Math.round(v.ms / v.n)} ms avg`);
  }
  // The chain of calls that actually determined the wall time: at each level,
  // the request that finished last is what the next level had to wait for.
  if (argv.includes('--waterfall')) {
    const lv = [];
    let open = done.filter(r => r.end != null).sort((a, b) => a.start - b.start);
    let cursor = open.length ? open[0].start : 0;
    while (open.length) {
      const level = open.filter(r => r.start <= cursor + 30);
      if (!level.length) break;
      const last = level.reduce((a, b) => (a.end > b.end ? a : b));
      lv.push({ n: level.length, last, span: Math.round(last.end - cursor) });
      cursor = last.end;
      open = open.filter(r => r.start > cursor - 30 && !level.includes(r));
    }
    for (const [i, l] of lv.entries()) {
      const to = (l.last.to || '').slice(0, 10);
      console.log(`         L${i + 1}  ${String(l.n).padStart(2)} call(s), `
        + `${String(l.span).padStart(4)} ms  <- ${l.last.method} ${to} ${l.last.sel || ''}`);
    }
  }
  const errs = log.filter(r => r.err);
  if (errs.length) console.log(`         ${errs.length} failed: ${[...new Set(errs.map(e => e.err))].join('; ').slice(0, 120)}`);
  if (run === 1) console.log(`         rate: ${rate}`);
}

// Price one bare round trip, so a removed hop can be valued directly.
const probe = async (method, params) => {
  const t = [];
  for (let i = 0; i < 5; i++) {
    const r = await page.evaluate(([m, p]) => window.__rpc(m, p), [method, params]);
    t.push(r.ms);
  }
  return t.sort((a, b) => a - b)[2];
};
console.log(`\none bare round trip (median of 5):`);
console.log(`  eth_blockNumber  ${await probe('eth_blockNumber', [])} ms`);
console.log(`  eth_getCode      ${await probe('eth_getCode', ['0x00000087A6dc5071779Ed1F8274A39230768B976', 'latest'])} ms`);

const avg = a => Math.round(a.reduce((x, y) => x + y, 0) / a.length);
console.log(`\nmean ${avg(totals.map(t => t.wall))} ms wall · `
  + `${avg(totals.map(t => t.calls))} calls · serial depth ${avg(totals.map(t => t.depth))}`);

if (heavy.length) {
  console.log(`\n${heavy.length} batch(es) failed on gas. Inner calls:`);
  const freq = {};
  for (const b of heavy) for (const c of b) freq[c] = (freq[c] || 0) + 1;
  for (const [c, n] of Object.entries(freq).sort((a, b) => b[1] - a[1]).slice(0, 12)) {
    console.log(`  x${String(n).padStart(3)}  ${c}`);
  }
  console.log(`  batch sizes: ${[...new Set(heavy.map(b => b.length))].sort((a,b)=>a-b).join(', ')}`);
}
await browser.close();
server.close();
