/**
 * The dapp's RPC fallback provider (dapp/index.html makeFallbackProvider).
 *
 * Unlike the rest of test/ui/, which loads the immutable zSwap.html page, this
 * pulls the function straight out of dapp/index.html and runs it against fake
 * providers. Extracting the live source rather than copying it means the tests
 * cannot drift away from the page.
 *
 * What matters here is the failover policy, which is invisible from the DOM and
 * only shows up as a slow or hard-failed quote in production:
 *   - a stalled node must not cost the full timeout before anything else is tried
 *   - a contract revert must NOT fan out across every RPC (same answer everywhere)
 *   - a hedged race must never leak an unhandled rejection from the loser
 *
 * Run: node --test test/ui/
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

// Lift `const HEDGE …` through the end of makeFallbackProvider out of the page.
function loadProviderFactory() {
  const html = fs.readFileSync(path.join(ROOT, 'dapp', 'index.html'), 'utf8');
  const start = html.indexOf('const HEDGE = Symbol');
  const end = html.indexOf('const quoteRPC = makeFallbackProvider(RPCS);');
  assert.ok(start > 0 && end > start, 'makeFallbackProvider not found in dapp/index.html');
  const src = html.slice(start, end);
  // The factory closes over CHAIN_ID, ethers and makeWalletReader. Stub them:
  // no wallet node, and a provider that is just an identity tag per URL.
  const make = new Function(`
    const CHAIN_ID = 1;
    const ethers = { JsonRpcProvider: function (u) { this.url = u; } };
    function makeWalletReader() { return null; }
    ${src}
    return makeFallbackProvider;
  `);
  return make();
}

const makeFallbackProvider = loadProviderFactory();
const sleep = (ms, v) => new Promise((r) => setTimeout(() => r(v), ms));
const revert = () => Object.assign(new Error('execution reverted: 0x'), { code: 'CALL_EXCEPTION' });

describe('RPC fallback provider', () => {
  test('a fast leader answers alone — no duplicate request', async () => {
    const seen = [];
    const q = makeFallbackProvider(['a', 'b', 'c']);
    const t0 = Date.now();
    const res = await q.call(async (p) => { seen.push(p.url); await sleep(50); return p.url; });
    assert.equal(res, 'a');
    assert.deepEqual(seen, ['a'], 'hedge fired for a call that was already fast');
    assert.ok(Date.now() - t0 < 400);
  });

  test('a stalled leader is overtaken by the hedge, not waited out', async () => {
    const q = makeFallbackProvider(['a', 'b', 'c']);
    const t0 = Date.now();
    const res = await q.call(async (p) => {
      if (p.url === 'a') { await sleep(3800); return 'a'; } // stalls past the 4s timeout
      await sleep(60);
      return p.url;
    });
    const elapsed = Date.now() - t0;
    assert.equal(res, 'b');
    // Sequential failover would have burned the full 4s timeout on 'a' first.
    assert.ok(elapsed < 1400, `hedge did not take over in time (${elapsed}ms)`);
  });

  test('a merely slow leader still wins if it beats the backup', async () => {
    const q = makeFallbackProvider(['a', 'b', 'c']);
    const res = await q.call(async (p) => {
      if (p.url === 'a') { await sleep(1000); return 'a'; }
      await sleep(3800);
      return p.url;
    });
    assert.equal(res, 'a', 'hedge discarded the leader that answered first');
  });

  test('a contract revert is fatal — it is not retried across every RPC', async () => {
    const seen = [];
    const q = makeFallbackProvider(['a', 'b', 'c']);
    await assert.rejects(
      q.call(async (p) => { seen.push(p.url); throw revert(); }),
      /reverted/,
    );
    assert.deepEqual(seen, ['a'], 'a deterministic revert fanned out to other nodes');
  });

  test('a revert reached through a hedged race is still fatal', async () => {
    const seen = [];
    const q = makeFallbackProvider(['a', 'b', 'c']);
    await assert.rejects(
      q.call(async (p) => {
        seen.push(p.url);
        if (p.url === 'a') { await sleep(1100); throw revert(); }
        throw revert();
      }),
      /reverted/,
    );
    assert.ok(!seen.includes('c'), `kept trying after a revert verdict: ${seen}`);
  });

  test('every node timing out terminates instead of hanging', async () => {
    const q = makeFallbackProvider(['a', 'b', 'c']);
    const t0 = Date.now();
    await assert.rejects(q.call(async () => { await sleep(9000); }, { timeoutMs: 300 }));
    assert.ok(Date.now() - t0 < 2500, 'exhausting all nodes took longer than the timeouts allow');
  });

  test('long-timeout work (archive log scans) is never hedged', async () => {
    const seen = [];
    const q = makeFallbackProvider(['a', 'b', 'c']);
    const pending = q.call(async (p) => { seen.push(p.url); await sleep(1500); return p.url; }, { timeoutMs: 60000 });
    await sleep(1100); // well past the 900ms hedge delay
    assert.deepEqual(seen, ['a'], 'doubled a long scan across nodes for no latency win');
    await pending;
  });

  test('the losing racer never leaks an unhandled rejection', async () => {
    const leaked = [];
    const onLeak = (e) => leaked.push(e);
    process.on('unhandledRejection', onLeak);
    try {
      const q = makeFallbackProvider(['a', 'b', 'c']);
      const res = await q.call(async (p) => {
        if (p.url === 'a') { await sleep(1200); throw new Error('502 bad gateway'); }
        await sleep(30);
        return 'b';
      });
      assert.equal(res, 'b');
      await sleep(1500); // outlive the loser's own failure
      assert.deepEqual(leaked.map(String), []);
    } finally {
      process.off('unhandledRejection', onLeak);
    }
  });
});

describe('quote admission control', () => {
  const html = fs.readFileSync(path.join(ROOT, 'dapp', 'index.html'), 'utf8');
  const start = html.indexOf("const QUOTE_SUPERSEDED = Symbol");
  const end = html.indexOf('\n}', html.indexOf('function requestQuote(')) + 2;
  assert.ok(start > 0 && end > start, 'requestQuote not found in dapp/index.html');
  const src = html.slice(start, end);

  // Build a fresh, isolated copy per test: module-level counters are stateful.
  function build() {
    const log = { started: [], concurrent: 0, peak: 0 };
    const gate = new Map(); // seq -> resolve, so tests decide when a quote lands
    const finish = (amt, value) => { const g = gate.get(amt); assert.ok(g, `no quote for ${amt}`); gate.delete(amt); g(value); };
    const factory = new Function('log', 'gate', `
      const withRetry = (fn) => Promise.resolve().then(fn);
      const getQuote = (amt) => {
        log.started.push(amt);
        log.concurrent++;
        log.peak = Math.max(log.peak, log.concurrent);
        return new Promise((res) => gate.set(amt, res)).finally(() => { log.concurrent--; });
      };
      const getExactOutQuote = getQuote;
      ${src}
      return { requestQuote, QUOTE_SUPERSEDED };
    `);
    return { ...factory(log, gate), log, finish };
  }

  test('a new request does not wait behind a quote already in flight', async () => {
    const { requestQuote, log, finish } = build();
    const first = requestQuote('1', 'ETH', 'USDC');
    const second = requestQuote('10', 'ETH', 'USDC');
    await sleep(0);
    assert.deepEqual(log.started, ['1', '10'], 'the newer quote was made to wait for the older one');
    finish('10', 'B'); finish('1', 'A');
    assert.equal(await second, 'B');
    assert.equal(await first, 'A');
  });

  test('concurrency is capped — a burst does not stampede the RPCs', async () => {
    const { requestQuote, log, finish } = build();
    const rs = ['1', '2', '3', '4', '5'].map((a) => requestQuote(a, 'ETH', 'USDC'));
    await sleep(0);
    assert.equal(log.peak, 2, `ran ${log.peak} quotes at once`);
    assert.deepEqual(log.started, ['1', '2'], `unexpected admissions: ${log.started}`);
    // Draining the first frees a slot for the survivor of the burst (the newest).
    finish('1', 'A');
    await sleep(0);
    assert.deepEqual(log.started, ['1', '2', '5'], `wrong request drained: ${log.started}`);
    assert.equal(log.peak, 2, `peak rose to ${log.peak} while draining`);
    finish('2', 'B'); finish('5', 'E');
    await Promise.all(rs);
  });

  test('only the newest parked request survives; evicted ones report supersession', async () => {
    const { requestQuote, QUOTE_SUPERSEDED, log, finish } = build();
    const a = requestQuote('1', 'ETH', 'USDC');
    const b = requestQuote('2', 'ETH', 'USDC');
    const c = requestQuote('3', 'ETH', 'USDC'); // parks
    const d = requestQuote('4', 'ETH', 'USDC'); // evicts c, parks
    assert.equal(await c, QUOTE_SUPERSEDED, 'an evicted request did not report supersession');
    finish('1', 'A');
    await sleep(0);
    assert.ok(log.started.includes('4'), 'the parked request never ran when a slot freed');
    assert.ok(!log.started.includes('3'), 'an evicted request ran anyway');
    finish('2', 'B'); finish('4', 'D');
    assert.equal(await d, 'D');
    await Promise.all([a, b]);
  });

  test('a failing quote still frees its slot and drains the parked request', async () => {
    const { requestQuote, log, finish } = build();
    const a = requestQuote('1', 'ETH', 'USDC');
    const b = requestQuote('2', 'ETH', 'USDC');
    const c = requestQuote('3', 'ETH', 'USDC');
    a.catch(() => {});
    await sleep(0); // withRetry defers the call by a microtask
    // Reject the first by finishing it with a thenable that throws.
    finish('1', Promise.reject(new Error('rpc down')));
    await sleep(0); await sleep(0);
    assert.ok(log.started.includes('3'), 'a rejected quote wedged the queue shut');
    await assert.rejects(a, /rpc down/);
    finish('2', 'B'); finish('3', 'C');
    assert.equal(await c, 'C');
    await b;
  });

  test('rejections still reach the caller rather than being swallowed', async () => {
    const { requestQuote, finish } = build();
    const a = requestQuote('1', 'ETH', 'USDC');
    a.catch(() => {});
    await sleep(0);
    finish('1', Promise.reject(new Error('boom')));
    await assert.rejects(a, /boom/);
  });
});

describe('external price fan-out deadline', () => {
  const src = fs.readFileSync(path.join(ROOT, 'dapp', 'modules', 'aggregators.js'), 'utf8');
  const start = src.indexOf('function settleWithin');
  const settleWithin = new Function(`${src.slice(start, src.indexOf('\n}', start) + 2)} return settleWithin;`)();

  test('a straggler is dropped to null rather than gating the quote', async () => {
    const t0 = Date.now();
    const out = await settleWithin(300, [sleep(50, 'fast'), sleep(5000, 'slow')]);
    assert.deepEqual(out, ['fast', null]);
    assert.ok(Date.now() - t0 < 900, 'waited on the straggler anyway');
  });

  test('a rejected aggregator becomes null, not a failed quote', async () => {
    const out = await settleWithin(300, [Promise.reject(new Error('boom')), Promise.resolve('ok')]);
    assert.deepEqual(out, [null, 'ok']);
  });

  test('returns as soon as everything lands — the deadline is a cap, not a floor', async () => {
    const t0 = Date.now();
    await settleWithin(3000, [sleep(10, 'a'), sleep(20, 'b')]);
    assert.ok(Date.now() - t0 < 300, 'blocked until the deadline even though all had settled');
  });
});

// A quote's result object outlives the request that produced it: _selectRoute()
// reads module-level `_quoteResult` when the user picks a route by hand. That
// binding was declared inside the old requestQuote block, so rewriting that
// block silently removed it and every route click threw ReferenceError — the
// route list rendered fine and simply refused to respond. Nothing else in the
// page references it, so no syntax check or existing test noticed.
describe('manual route selection wiring', () => {
  const html = fs.readFileSync(path.join(ROOT, 'dapp', 'index.html'), 'utf8');

  test('_quoteResult is declared, not an implicit global', () => {
    assert.match(html, /\blet _quoteResult\b/,
      '_quoteResult must be declared at module level — _selectRoute reads it');
  });

  test('every state _selectRoute reads has a declaration', () => {
    const body = html.slice(html.indexOf('function _selectRoute('));
    const fn = body.slice(0, body.indexOf('\n}\n'));
    // Module-level names the function reads. Assigning to an undeclared name
    // would work in sloppy mode; reading one throws.
    for (const name of ['_quoteResult', '_resetExtFlags', 'toToken', 'fromToken', 'tokens']) {
      if (!fn.includes(name)) continue;
      const declared = new RegExp(`\\b(let|const|var|function)\\s+${name}\\b`).test(html);
      assert.ok(declared, `_selectRoute reads ${name} but nothing declares it`);
    }
  });
});
