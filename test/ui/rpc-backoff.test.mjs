/**
 * What a rate-limited node costs.
 *
 * withRPC walked to the next endpoint on any failure, which is right for a node that is
 * down and exactly wrong for one saying "too many requests": every read became three
 * requests across three public nodes, which produced more 429s, which tripled the next
 * read. The console filled with alternating 429 and 403 from publicnode and tenderly
 * because the page was the thing causing them.
 *
 * Two properties fix it and both are pinned here: a throttled node is skipped until it
 * has had time to forget, and identical reads in flight at once are one request.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const html = fs.readFileSync(path.join(ROOT, 'dapp/coin/index.html'), 'utf8');
const grab = re => { const m = html.match(re); assert.ok(m, 'not found: ' + re); return m[0]; };

const build = () => new Function([
  "const RPCS=['a','b','c'];", 'let rpcIdx=0;', 'const RPC_TIMEOUT_MS=5000;',
  'const _rpcDeadline=p=>p;', 'const _rpcProviders=RPCS.map(u=>u);',
  grab(/const _rpcCooldownUntil = [\s\S]*?\n}\n\n\/\/ Reads that repeat/).replace('\n\n// Reads that repeat', ''),
  grab(/const _rpcInflight = new Map\(\);[\s\S]*?\n}/),
  'return {withRPC,withRPCOnce,_rpcCooldownUntil};',
].join('\n'))();

const throttle = msg => () => { throw new Error(msg); };

test('a node that says "too many" is skipped, not retried on every read', async () => {
  const M = build();
  const tried = [];
  const fn = p => { tried.push(p); if (p === 'a') throw new Error('server responded 429 Too Many Requests'); return 'ok:' + p; };

  assert.equal(await M.withRPC(fn), 'ok:b');
  assert.deepEqual(tried, ['a', 'b'], 'the first read discovers the limit');

  tried.length = 0;
  assert.equal(await M.withRPC(fn), 'ok:b');
  assert.deepEqual(tried, ['b'], 'the second must not pay for the same 429 again');
  assert.ok(M._rpcCooldownUntil[0] > Date.now(), 'the throttled node is on cooldown');
});

test('403 counts as throttled too — publicnode answers both', async () => {
  const M = build();
  const tried = [];
  const fn = p => { tried.push(p); if (p === 'a') throw new Error('403 Forbidden'); return 'ok'; };
  await M.withRPC(fn);
  tried.length = 0;
  await M.withRPC(fn);
  assert.deepEqual(tried, ['b'], 'a 403 should cool the node the same way a 429 does');
});

test('an ordinary failure does NOT cool the node, only a throttle does', async () => {
  const M = build();
  const fn = p => { if (p === 'a') throw new Error('connection reset'); return 'ok'; };
  await M.withRPC(fn);
  assert.ok(M._rpcCooldownUntil[0] <= Date.now(),
    'a transient network error must not sideline a healthy endpoint for 20s');
});

test('every node throttled still makes the call rather than giving up', async () => {
  const M = build();
  let n = 0;
  // All three refuse once, then recover: the page must still get an answer.
  const fn = p => { n++; if (n <= 3) throw new Error('429'); return 'ok:' + p; };
  await assert.rejects(() => M.withRPC(fn));   // first pass: all three refuse
  assert.equal(await M.withRPC(fn), 'ok:a', 'cooled nodes go to the back of the queue, not out of it');
});

test('identical reads in flight at once are one request', async () => {
  const M = build();
  let n = 0;
  const slow = () => { n++; return new Promise(r => setTimeout(() => r('v'), 10)); };
  const [x, y] = await Promise.all([M.withRPCOnce('k', slow, 200), M.withRPCOnce('k', slow, 200)]);
  assert.equal(n, 1, 'a repaint that follows a trade should not re-ask what is already in flight');
  assert.equal(x, y);
});
