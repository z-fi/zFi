/**
 * Eight small corrections across the page: a token-ID field a phone can type a
 * name into, a launch preview that reads a decimal comma the way the launch
 * does, a slippage field whose steps land on its own default, private rows that
 * stop hiding change once a send has left this key, a relay prompt that keeps
 * the pin when dismissed, a farm line that notices its own end, a pool history
 * with a gap that is refused, and an exit retry the relay forgot that can be
 * built again. Each case failed on the page before it.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AbiCoder, keccak256, toUtf8Bytes } from 'ethers';
import { A, MockChain, loadPage, closeAllPages, CP_BLOCK, ensNamehash } from './harness.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const coder = AbiCoder.defaultAbiCoder();
const ETH = 10n ** 18n;
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const SLOW = { timeout: 15000 };

describe('the token ID field', () => {
  test('takes a .wei name on a phone keyboard, and the name resolves to its token ID', async () => {
    const p = await loadPage({ chain: new MockChain() });
    const el = p.$('nftId');
    assert.equal(el.placeholder, 'Any from collection');
    assert.notEqual(el.getAttribute('inputmode'), 'numeric', 'a numeric keypad has no letters and no dot');
    const id = BigInt(ensNamehash('zfi.wei')).toString();
    assert.equal(p.window.eval('nftIdIn(WNS,"zfi.wei")'), id);
    assert.equal(p.window.eval('nftIdIn(WNS,"zfi")'), id, 'the suffix is implied');
    p.close();
  });
});

describe('the launch preview', () => {
  test('reads a decimal comma in the starting market cap as the launch does', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain });
    await p.connect();
    p.click('ln');
    p.type('lnSupply', '1000000000');
    p.type('lnMcap', '2.5');
    const dot = p.text('lnNote');
    assert.match(dot, /1 ETH buys 28% of all/);
    p.type('lnMcap', '2,5');
    assert.equal(p.text('lnNote'), dot, '2,5 is 2.5, not 25');
    assert.equal(p.$('lnNote').style.color, 'var(--w)', 'and a market that thin is flagged');
    p.close();
  });
});

describe('the slippage field', () => {
  test('steps from its own default onto tenths', async () => {
    const p = await loadPage({ chain: new MockChain() });
    const el = p.$('slip');
    assert.equal(el.value, '0.5');
    assert.equal(el.getAttribute('min'), '0');
    assert.equal(el.getAttribute('step'), '0.1');
    assert.equal(el.validity.stepMismatch, false, 'the default is on a step');
    el.stepUp();
    assert.equal(el.value, '0.6');
    p.close();
  });
});

// ---- the confidential pool, as the mock chain serves it ----
const SEL_CP = { IMPL: '93228617', ASSETS: '9fda5b66', NEXT: '0be4f422', DEPOSIT: '7da9874f' };
const T_LEAVES = keccak256(toUtf8Bytes('LeavesInserted(uint256,bytes32[],bytes[])'));
const B0 = CP_BLOCK + 0x100;
const leavesLog = (first, leaves) => ({
  address: F.pool, blockNumber: '0x' + (B0 + 0x5 + first).toString(16), logIndex: '0x0',
  topics: [T_LEAVES, '0x' + u256(first)],
  data: coder.encode(['bytes32[]', 'bytes[]'], [leaves, leaves.map(() => '0x')]),
});

// No relay lanes: every relay call 404s, which is how a relay that has
// forgotten a job answers its status.
function poolChain() {
  const chain = new MockChain();
  chain.blockNumber = '0x' + (B0 + 0x100).toString(16);
  chain.gasPrice = 10n ** 8n;
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.answer(F.router, SEL_CP.IMPL, '0x' + F.executorImpl.slice(2).toLowerCase().padStart(64, '0'));
  chain.answer(F.pool, SEL_CP.ASSETS, '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
  chain.answer(F.pool, SEL_CP.NEXT, () => '0x' + u256(chain.nextLeaf ?? 0));
  chain.answer(F.pool, SEL_CP.DEPOSIT, '0x' + u256(0));
  return chain;
}

async function unlocked(storage) {
  const p = await loadPage({ chain: poolChain(), storage });
  await p.connect();
  p.click('pv');
  await p.settle();
  p.click('pvGo');
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock', ...SLOW });
  await p.waitFor(() => p.window.eval('!!cpPool') && /No deposits yet|Shielded/.test(p.text('pvList')), { label: 'the pool to load', ...SLOW });
  await p.settle();
  return p;
}

// A note held by its own secret, as a split's change or a claim comes back.
const NOTE = (s, b, v) => `({i:-1,v:"${v}",s:"0x${'00'.repeat(31)}${s}",b:"0x${'00'.repeat(31)}${b}",at:nowS()})`;
const OTHER_PUB = '03' + 'ab'.repeat(32);

describe('private rows after a send', () => {
  test('a send that has left this key no longer hides its change', async () => {
    const p = await unlocked();
    const key = p.window.eval(`(()=>{const S={id:"sw1",a:CP_ETH,v:"250000",to:"${OTHER_PUB}",at:nowS(),self:0,st:"fund",
      n:"locked-note",ins:["locked-note"],dl:String(nowS()+7776000),lf:"0x${'cd'.repeat(32)}"};cpSends.push(S);window.__S=S;
      const c=Object.assign(${NOTE('07', '09', 740000)},{sid:"sw1"});cpNotes.push(c);cpPool.leaves.push(cpNoteOf(c).leaf);return cpKeyOf(c)})()`);
    const paint = st => { p.window.eval(`__S.st="${st}";cpPaint()`); return p.$('pvList'); };
    const btn = (list, a) => [...list.querySelectorAll(`button[data-a="${a}"]`)].find(b => b.dataset.k === key);

    for (const [st, row] of [['fund', /funding…/], ['lock', /locking…/]]) {
      const list = paint(st);
      assert.match(list.textContent, row, `the ${st} send is on its own row`);
      assert.match(list.textContent, /0\.0025 tETH sent to 03abab/);
      assert.equal(btn(list, 'split'), undefined, `while it is in flight (${st}) the change stays out of reach`);
    }
    for (const [st, row] of [['sent', /waiting for the recipient/], ['claimed', /claimed/], ['refunded', /taken back/]]) {
      const list = paint(st);
      assert.match(list.textContent, row, `the ${st} send is on its own row`);
      assert.ok(btn(list, 'split'), `a ${st} send leaves its change splittable`);
      assert.ok(btn(list, 'exit'), `and withdrawable (${st})`);
      assert.match(list.textContent, /Shielded 0\.0074 tETH/, `and counted (${st})`);
    }
    p.close();
  });
});

describe('the relay prompt', () => {
  test('dismissing it keeps a pinned relay; an empty answer still clears it', async () => {
    const PIN = 'https://relay.example.com';
    const p = await unlocked({ 'zswap:cprelay': PIN });
    const relayBtn = () => p.$('pvKey').querySelector('button[data-a="relay"]');
    assert.match(relayBtn().textContent, /relay\.example\.com · pinned/);
    p.click(relayBtn());                       // no answer queued: the dialog is dismissed
    await p.waitFor(() => /^Relay: /.test(p.text('stat')), { label: 'the relay status', ...SLOW });
    assert.equal(p.window.__promptDefaults.at(-1), PIN, 'the prompt opened on the pin');
    assert.equal(p.window.localStorage['zswap:cprelay'], PIN, 'a dismissed prompt changes nothing');
    assert.match(p.text('stat'), /Relay: https:\/\/relay\.example\.com · pinned/);
    p.queuePrompt('');
    p.click(relayBtn());
    await p.waitFor(() => /Relay: https:\/\/api\.tacit\.finance/.test(p.text('stat')), { label: 'the default relay', ...SLOW });
    assert.equal(p.window.localStorage['zswap:cprelay'], undefined, 'an empty answer clears the pin');
    p.close();
  });
});

describe('the TAC/ETH farm line', () => {
  const FARM = '0x0000003bF4BA0B21f5e0d35119b337F4d4CF82E0';
  const POOL = '0x0155358241411dB868BA714aE7c83A27087e3D6E';

  test('repaints as ended when its end passes, with nothing else changed', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setCode(FARM, '0x6000');
    const fin = Math.floor(Date.now() / 1e3) + 30 * 86400;
    for (const [s, v] of Object.entries({ '18160ddd': 2160175009930805825n, '443cb4bc': 17503584633155263n, '5a76f25e': 250n * ETH, '2af1f249': 119510621510568635147n }))
      chain.answer(POOL, s, '0x' + u256(v));
    for (const [s, v] of Object.entries({ '7b0a47ee': 6410750000000000n, 'ebe2b12b': fin, '817b1cd2': ETH, '98807d84': ETH, '008cc262': 0n }))
      chain.answer(FARM, s, '0x' + u256(v));
    const p = await loadPage({ chain });
    await p.connect();
    await p.waitFor(() => p.visible('pfEl') && /TAC\/day/.test(p.text('pfEl')), { label: 'the paying line', ...SLOW });
    // A month and a day later, by the page's own clock; the farm's state is as it was.
    p.window.eval('tSk+=31*86400;pfDraw()');
    assert.ok(p.visible('pfEl'), 'a stake is still in it');
    assert.match(p.text('pfEl'), /TAC\/ETH farm · ended · your stake is still here/);
    assert.doesNotMatch(p.text('pfEl'), /TAC\/day/);
    p.close();
  });
});

describe('the pool history', () => {
  // Leaves 0 and 2 arrive; the log carrying leaf 1 does not, while the pool says three exist.
  const L = i => '0x' + String(i + 1).repeat(64);
  const gapped = () => {
    const chain = poolChain();
    chain.logs.push(leavesLog(0, [L(0)]), leavesLog(2, [L(2)]));
    chain.nextLeaf = 3;
    return chain;
  };
  const sync = p => p.window.eval('cpSync(true).then(()=>"stored",e=>e.message)');

  test('a missing leaves log is incomplete history, not a pool with a hole', async () => {
    const p = await loadPage({ chain: gapped() });
    await p.settle();
    assert.equal(await sync(p), "The pool's history came back incomplete.");
    assert.equal(p.window.eval('cpPool'), null, 'nothing is kept');
    assert.equal(p.window.localStorage['zswap:cppool'], undefined, 'or cached');
    // The same history with the log restored is taken whole.
    p.chain.logs.push(leavesLog(1, [L(1)]));
    assert.equal(await sync(p), 'stored');
    assert.deepEqual([...p.window.eval('cpPool.leaves')], [L(0), L(1), L(2)]);
    p.close();
  });

  test('a cached pool that a gapped update would extend is read again from scratch', async () => {
    const p = await loadPage({ chain: gapped() });
    await p.settle();
    p.window.localStorage['zswap:cppool'] = JSON.stringify({ v: 3, pool: p.window.eval('CP_POOL'), to: B0, leaves: [L(0)],
      memos: [], spent: [], wraps: [], lk: [], lm: [], ln: [], ls: [], q: [], tx: [] });
    p.window.eval('cpPool=null');
    assert.equal(await sync(p), "The pool's history came back incomplete.");
    assert.equal(p.window.localStorage['zswap:cppool'], undefined, 'the cache it would have extended is dropped');
    p.close();
  });
});

describe('an exit the relay forgot', () => {
  test('can be built again inside its window', async () => {
    const p = await unlocked();
    const key = p.window.eval(`(()=>{const n=${NOTE('0b', '0d', 1000000)};
      n.ex={ch:1,to:"${A.OTHER}",self:0,job:"0xjob1",js:"unknown",du:String(nowS()+3600),dl:String(nowS()+259200),fee:"0",wei:"10000000000000000",nonce:"1"};
      cpNotes.push(n);cpPaint();return cpKeyOf(n)})()`);
    const retry = [...p.$('pvList').querySelectorAll('button[data-a="exit"]')].find(b => b.dataset.k === key);
    assert.equal(retry?.textContent, 'retry', 'the relay\'s 404 reads as a failure with a retry');
    p.queueConfirm(true);
    p.click(retry);
    await p.waitFor(() => p.asked.confirm.some(m => /Build this exit again/.test(m)), { label: 'the rebuild to be offered', ...SLOW });
    await p.waitFor(() => !/Building the exit/.test(p.text('stat')) && p.text('stat'), { label: 'the retry to finish', ...SLOW });
    assert.doesNotMatch(p.text('stat'), /already exiting/);
    // Past the guard, the rebuild reads the pool, which does not hold this note.
    assert.match(p.text('stat'), /has not settled into the pool yet/);
    p.close();
  });
});
