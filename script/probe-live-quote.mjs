#!/usr/bin/env node
/**
 * Run the REAL zSwap.html against a REAL node, headless, and report exactly why
 * a pair fails to quote.
 *
 * The mock chain answers from fixtures, so it can only reproduce bugs someone
 * already thought to encode. A pair that quotes on mainnet and not in the page
 * is the opposite case: the fixtures say it should work. This drives the actual
 * page over a live provider and prints every eth_call that failed, so the
 * answer comes from observation rather than from reasoning about the source.
 *
 * Usage:
 *   node script/probe-live-quote.mjs DAI
 *   node script/probe-live-quote.mjs DAI LUSD BOLD USDC --amount 1
 *   node script/probe-live-quote.mjs DAI --rpc https://...
 */
import { loadPage, closeAllPages } from '../test/ui/harness.mjs';

const argv = process.argv.slice(2);
const val = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d; };
const RPC = val('--rpc', process.env.ETH_RPC_URL || 'https://ethereum-rpc.publicnode.com');
const AMOUNT = val('--amount', '1');
const SYMS = argv.filter((a, i) => !a.startsWith('--') && argv[i - 1] !== '--rpc' && argv[i - 1] !== '--amount');
if (!SYMS.length) SYMS.push('DAI');

// A wallet that exists and holds enough to be quotable, over a real node for
// every read. Nothing here can sign: the probe never reaches a transaction.
const ACCOUNT = '0x000000000000000000000000000000000000dEaD';

class LiveChain {
  constructor(rpc) {
    this.rpc = rpc;
    this.calls = [];
    this.failures = [];
    this.id = 0;
    // The harness drains on `inFlight` by spinning microtask ticks, which over
    // a real node expires before the first response. Report quiet to that, and
    // keep the true count in `busy` for this probe's own wall-clock waits.
    this.busy = 0;
  }
  async send(method, params) {
    const res = await fetch(this.rpc, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++this.id, method, params }),
    });
    if (!res.ok) throw Error(`http ${res.status}`);
    const j = await res.json();
    if (j.error) throw Error(j.error.message || JSON.stringify(j.error));
    return j.result;
  }
  get inFlight() { return 0; }
  async request(args) {
    this.busy++;
    try { return await this._request(args); }
    finally { this.busy--; }
  }
  async _request({ method, params = [] }) {
    switch (method) {
      case 'eth_chainId': return '0x1';
      case 'eth_accounts':
      case 'eth_requestAccounts': return [ACCOUNT];
      case 'wallet_getCapabilities': return {};
      case 'eth_sendTransaction':
      case 'eth_signTypedData_v4': throw Error('probe is read-only');
    }
    if (method === 'eth_call') {
      const rec = { to: params[0]?.to, size: (params[0]?.data || '').length, block: params[1] };
      this.calls.push(rec);
      try {
        return await this.send(method, params);
      } catch (e) {
        rec.error = e.message;
        this.failures.push(rec);
        throw e;
      }
    }
    return this.send(method, params);
  }
}

const short = a => (a ? a.slice(0, 10) + '…' : '?');

console.log(`rpc ${RPC}`);
for (const sym of SYMS) {
  const chain = new LiveChain(RPC);
  let page;
  const t0 = Date.now();
  try {
    page = await loadPage({ chain });

    // The harness's own waits are tuned to a mock that answers instantly; over
    // a real node they give up long before the first quote lands. So wait on
    // wall-clock and on the page's OWN resolved state instead.
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const until = async (fn, ms, label) => {
      const end = Date.now() + ms;
      while (Date.now() < end) { try { if (fn()) return true; } catch {} await sleep(50); }
      throw Error(`timed out waiting for ${label}`);
    };

    page.click('swap');
    await until(() => page.text('addr') !== 'Not connected', 30000, 'connect');
    await until(() => chain.busy === 0, 30000, 'initial reads');

    page.pickToken('toSel', sym);
    await sleep(300);
    page.type('amt', AMOUNT);
    // Resolved means: the output left its placeholder, or the page gave up and
    // said why. Anything else is still in flight.
    await until(() => {
      const o = page.value('outAmt'), st = page.text('stat');
      return (o && o !== '...') || /No route|cannot|not registered/i.test(st);
    }, 60000, 'quote to resolve');
    await sleep(200);

    const out = page.value('outAmt');
    const stat = page.text('stat');
    const ok = out && out !== '...' && !/No route/.test(stat);
    const firstFails = chain.failures.length;
    const firstMs = Date.now() - t0;
    console.log(`\n${ok ? 'OK  ' : 'FAIL'}  ETH -> ${sym}   out=${JSON.stringify(out)}  stat=${JSON.stringify(stat)}`);
    console.log(`      quote 1: ${chain.calls.length} eth_call, ${firstFails} failed, ${firstMs}ms`);
    for (const f of chain.failures.slice(0, 8)) {
      console.log(`      x to=${short(f.to)} calldata=${f.size}ch block=${f.block} :: ${f.error}`);
    }

    // A second quote in the SAME page. If the page learned the provider's
    // limit, this one never rediscovers it - no repeat failures, and faster.
    const t1 = Date.now();
    const before = chain.calls.length;
    page.type('amt', String(Number(AMOUNT) + 1));
    await until(() => {
      const o = page.value('outAmt'), st = page.text('stat');
      return (o && o !== '...' && o !== out) || /No route/i.test(st);
    }, 60000, 'second quote');
    console.log(`      quote 2: ${chain.calls.length - before} eth_call, `
      + `${chain.failures.length - firstFails} failed, ${Date.now() - t1}ms`
      + `  out=${JSON.stringify(page.value('outAmt'))}`);
  } catch (e) {
    console.log(`\nERR   ETH -> ${sym}: ${e.message}`);
    for (const f of chain.failures.slice(0, 8)) {
      console.log(`      x to=${short(f.to)} calldata=${f.size}ch :: ${f.error}`);
    }
  } finally {
    try { page?.close(); } catch {}
  }
}
closeAllPages();
