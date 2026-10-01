/**
 * A second round of small corrections. A link that swaps the pair under the
 * button holds it like one that rewrites the amount. A swap that settles drops
 * a quote still on its way. The .wei button stays held through its own
 * transaction, and the commit and the free claim finish even when the name box
 * changed under the wallet prompt. A reverse name comes back lowercase, so its
 * records are read under the right node. A cause amount that does not parse
 * offers no burn of the whole balance. A Dutch NFT listing shows its real
 * floor. A network switch waits for a private or market transaction. An
 * imported list can attach an L2 exit to a note already held. A failed exit
 * whose settle may still land is retried on its own terms. A self exit is not
 * "bridged" until its nullifier is spent. A cUSD loan the relay forgot reads
 * as failed. A proposal is sent once for two presses. A backing says it
 * backed. A send-tab lookup stays on the send tab. A launch waits for its
 * logo. Each case failed on the page before it.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { A, MockChain, loadPage, closeAllPages, fixedRateQuoter, ensNamehash, CP_BLOCK } from './harness.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const ETH = 10n ** 18n;
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const SLOW = { timeout: 15000 };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const symOf = (p, which) => p.$(which).selectedOptions[0]?.textContent;

// Holds the calls `pick` selects until released; everything else goes straight
// through. While anything is held the chain is never idle, so a test waits on
// `held`/`done` here rather than on settle().
function gate(chain, pick) {
  const g = { on: false, held: 0, done: 0 };
  let open;
  const opened = new Promise(r => { open = r; });
  g.release = () => { g.on = false; open(); };
  const inner = chain.dispatch.bind(chain);
  chain.dispatch = async (m, a) => {
    if (g.on && pick(m, a)) {
      g.held++;
      await opened;
      try { return await inner(m, a); } finally { g.done++; }
    }
    return inner(m, a);
  };
  return g;
}
const callTo = addr => (m, a) => m === 'eth_call' && (a[0]?.to || '').toLowerCase() === addr.toLowerCase();

// ---------------------------------------------------------------------------

describe('a link that changes the pair', () => {
  test('a hash change that swaps the token holds the button; landing on the link does not', async () => {
    const chain = new MockChain({ autoConnected: true });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.WBTC, A.ACCOUNT, 10n ** 8n);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    const p = await loadPage({ chain, hash: 'token=ETH&out=USDC&amount=1' });
    await p.settle();
    assert.equal(p.value('amt'), '1', 'the landing link filled the amount');
    assert.equal(p.window.eval('lkArm'), 0, 'a page load with a hash arms nothing');

    // Only the token changes; the amount is the one the link already wrote.
    p.window.location.hash = '#token=WBTC&out=USDC&amount=1';
    await p.waitFor(() => symOf(p, 'fromSel') === 'WBTC', { label: 'the pushed link' });
    assert.equal(p.value('amt'), '1');
    const sent = p.chain.sent.length;
    p.click('swap');
    assert.equal(p.text('stat'), 'The link just changed this trade — check it, then press again.');
    await p.settle();
    assert.equal(p.chain.sent.length, sent, 'nothing was sent');
    p.close();
  });
});

describe('a quote still in flight when a swap settles', () => {
  test('is dropped, so "You receive" is not filled against an empty "You pay"', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    const p = await loadPage({ chain });
    await p.connect();
    await p.typeAmount('amt', '1');
    chain.receiptPending = true;
    p.click('swap');
    await p.waitFor(() => /Sent/.test(p.text('stat')), { label: 'the swap to be sent' });

    // A new amount while the swap is out: its quote reaches the quoter and waits there.
    const g = gate(chain, callTo(A.ZQUOTER));
    g.on = true;
    p.type('amt', '2');
    await p.waitFor(() => g.held > 0, { label: 'the new quote to start', ...SLOW });

    chain.receiptPending = false;
    await p.waitFor(() => /Done/.test(p.text('stat')), { label: 'the receipt', timeout: 20000 });
    g.release();
    await p.waitFor(() => g.done >= g.held, { label: 'the late quote to answer', ...SLOW });
    await p.settle();
    await sleep(50);
    await p.settle();

    assert.equal(chain.sent.length, 1, 'the swap itself went out');
    assert.equal(p.value('amt'), '', 'a settled swap clears what was paid');
    assert.equal(p.value('outAmt'), '', 'and the late quote does not fill what would be received');
    assert.equal(p.window.eval('last'), null, 'nor leave a quote behind the button');
    p.close();
  });
});

// ---- .wei names, as names.test.mjs serves them ----
const WNS = '0x0000000000696760E15f265e828DB644A0c242EB';
const WREG = '0x53745292f0d30d68204a63002C17bDa16C772bf7';
const WROLL = '0x0000C82AA4D72871568eF3859D2b0E7CF37e45f2';
const IDWEI = 'cea9efa56b7c8a673303d04b917a7119a2a68f8c4803d8e6fd1c3a1f0d2e4ebe';
const WSEL = {
  AVAIL: '8f8dc386', FEE: 'fcee45f4', PREM: '1bf1fffb', CID: 'fb021939',
  COMMIT: 'f14fcbc8', COMMITS: '839df945', REVEAL: 'ea9384fa', SUB: 'a00fd3c8', REV: '9af8b7aa',
  STATE: 'c19d93fb', WEIGHT: '0767d178', TICKET: '673b4784', ENTER: '23972aef',
};
const SECRET = '0x' + '22'.repeat(32);
const WN_KEY = 'zswap:wns:' + A.ACCOUNT.toLowerCase();

const withWns = chain => {
  chain.answer(WNS, WSEL.AVAIL, data => {
    const parent = data.slice(10 + 64, 10 + 128);
    return '0x' + u256(parent === u256(0) || parent === IDWEI ? 1 : 0);
  });
  chain.answer(WNS, WSEL.FEE, '0x' + u256(5n * 10n ** 14n));
  chain.answer(WNS, WSEL.PREM, '0x' + u256(0));
  chain.answer(WNS, WSEL.CID, '0x' + u256(0x1234));
  chain.answer(WNS, WSEL.REV, '0x' + u256(0x20) + u256(0));
  chain.answer(WROLL, WSEL.STATE, '0x' + [1, 0, 2000000000, ETH / 10n, 0, 57, ETH, 0, 0, 0, 0, 0, 0].map(u256).join(''));
  chain.answer(WNS, WSEL.COMMIT, '0x');
  chain.answer(WNS, WSEL.COMMITS, () => '0x' + u256(chain.commitAt ?? 0));
  chain.answer(WNS, WSEL.REVEAL, '0x' + u256(0x1234));
  chain.answer(WREG, WSEL.SUB, '0x' + u256(0x1234));
  chain.answer(WROLL, WSEL.ENTER, '0x');
  return chain;
};

async function openNames() {
  const chain = withWns(new MockChain());
  chain.setNative(A.ACCOUNT, 10n * ETH);
  const p = await loadPage({ chain });
  await p.connect();
  p.click('wn');
  await p.settle();
  return p;
}

describe('the .wei button during its own transaction', () => {
  test('stays held through a reveal while the panel ticks, and comes back after', async () => {
    const p = await openNames();
    p.window.localStorage.setItem(WN_KEY, JSON.stringify({
      label: 'zswaptest', secret: SECRET, r: 1, at: Math.floor(Date.now() / 1000) - 120,
    }));
    p.click('wn'); await p.settle();
    p.click('wn'); await p.settle();
    assert.match(p.text('wnGo'), /Register zswaptest\.wei/);
    assert.equal(p.$('wnGo').disabled, false);

    p.chain.receiptPending = true;
    p.click('wnGo');
    await p.waitFor(() => /Sent/.test(p.text('stat')), { label: 'the reveal to be sent' });
    assert.equal(p.chain.sentTo(A.ZROUTER).length, 1, 'the reveal went out');
    await sleep(1600);   // the panel's one-second tick has run, more than once
    assert.equal(p.$('wnGo').disabled, true, 'the tick does not re-offer a reveal that is already out');

    p.chain.receiptPending = false;
    await p.waitFor(() => p.text('stat') === 'zswaptest.wei is yours.', { label: 'the reveal to land', timeout: 20000 });
    await p.settle();
    assert.ok(!p.window.eval('wnGo.k'), 'the hold is let go');
    p.type('wnName', 'satoshi');
    await p.waitFor(() => !p.$('wnGo').disabled && p.text('wnGo') === 'Commit', { label: 'the button to come back', ...SLOW });
    p.close();
  });
});

describe('the .wei name box changed under the wallet prompt', () => {
  const heldSend = p => {
    const g = gate(p.chain, m => m === 'eth_sendTransaction');
    g.on = true;
    return g;
  };

  test('a commit still keeps its transaction and says it committed', async () => {
    const p = await openNames();
    p.type('wnName', 'zswaptest');
    await p.settle();
    assert.equal(p.text('wnGo'), 'Commit');
    const g = heldSend(p);
    p.click('wnGo');
    await p.waitFor(() => g.held > 0, { label: 'the wallet prompt', ...SLOW });
    p.type('wnName', 'another');   // the quote it starts clears the one being committed
    assert.equal(p.window.eval('wnQ'), null);
    g.release();
    await p.waitFor(() => /Committed|Cannot read/.test(p.text('stat')), { label: 'the commit to finish', ...SLOW });
    assert.equal(p.text('stat'), 'Committed. Register the name in a minute.');
    const held = JSON.parse(p.window.localStorage.getItem(WN_KEY));
    assert.equal(held.label, 'zswaptest', 'the committed label is kept');
    assert.match(held.tx || '', /^0x[0-9a-f]{64}$/, 'with the transaction that carries it');
    p.close();
  });

  test('a free claim names the label it claimed', async () => {
    const p = await openNames();
    p.$('wnTld').value = 'id';
    p.$('wnTld').dispatchEvent(new p.window.Event('change'));
    p.type('wnName', 'satoshi');
    await p.settle();
    assert.equal(p.text('wnGo'), 'Claim satoshi.id.wei');
    const g = heldSend(p);
    p.click('wnGo');
    await p.waitFor(() => g.held > 0, { label: 'the wallet prompt', ...SLOW });
    p.type('wnName', 'nakamoto');
    await p.waitFor(() => /nakamoto\.id\.wei is free/.test(p.text('wnNote')), { label: 'the box to requote', ...SLOW });
    g.release();
    await p.waitFor(() => /is yours|Cannot read/.test(p.text('stat')), { label: 'the claim to finish', ...SLOW });
    assert.equal(p.text('stat'), 'satoshi.id.wei is yours.');
    const tx = p.chain.sentTo(WREG)[0];
    assert.ok(tx && tx.data.includes(Buffer.from('satoshi').toString('hex')), 'satoshi is what was claimed');
    p.close();
  });
});

describe('a reverse name in capitals', () => {
  test('comes back lowercase, so its Tacit record is read under the right node', async () => {
    const chain = new MockChain();
    chain.reverse.set(A.ACCOUNT.toLowerCase(), 'Alice.wei');
    chain.names.set('alice.wei', A.ACCOUNT);
    chain.texts = new Map([['alice.wei|finance.tacit', 'tacit1alicesrecord']]);
    const p = await loadPage({ chain });
    assert.equal(await p.window.eval(`nameRevRaw("${A.ACCOUNT}")`), 'alice.wei');
    assert.equal(await p.window.eval(`nameRev("${A.ACCOUNT}").then(nameText)`), 'tacit1alicesrecord');
    assert.equal(p.window.eval(`namehash("alice.wei")`), ensNamehash('alice.wei'));
    p.close();
  });
});

// ---- a cause, as cause-burn.test.mjs serves it ----
const DAO = '0x00000000000000000000000000000000cafe0001';
const LOOT = '0x00000000000000000000000000000000cafe0002';
const SHARES = '0x00000000000000000000000000000000cafe0003';

describe('a cause amount that does not parse', () => {
  test('offers no burn at all, rather than a burn of the whole balance', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n ** 19n);
    chain.setToken(LOOT, { symbol: 'CAUSE', decimals: 18, name: 'Clean Water Loot' });
    chain.setCause(LOOT, {
      dao: DAO, shares: SHARES, sharesSupply: ETH, lootSupply: 9_999_999n * ETH, treasury: 4n * ETH,
      price: 10n ** 12n, deadline: BigInt(Math.floor(Date.now() / 1000) + 22 * 86400), remaining: 5_000_000n * ETH,
    });
    chain.setErc20(LOOT, A.ACCOUNT, 1_000_000n * ETH);
    const p = await loadPage({ chain, storage: {
      'zswap:custom': JSON.stringify([{ sym: 'CAUSE', addr: LOOT, dec: 18, std: 'ft' }]) } });
    await p.connect();
    p.pickToken('fromSel', 'CAUSE');
    await p.settle();
    assert.match(p.text('cbEl'), /Burn 1,?000,?000 CAUSE for 0\.4 ETH/, 'an empty amount offers the balance');

    for (const bad of ['1e3', '1 000']) {
      p.type('amt', bad);
      await sleep(320);
      await p.settle();
      assert.match(p.text('cbEl'), /1 CAUSE redeems for 0\.0000004 ETH$/, `"${bad}" is not an amount`);
      assert.doesNotMatch(p.text('cbEl'), /Burn/);
      assert.equal(p.$('cbGo'), null, `and "${bad}" offers no Burn button`);
    }
    p.type('amt', '');
    await p.waitFor(() => /Burn 1,?000,?000 CAUSE/.test(p.text('cbEl')), { label: 'the balance again' });
    assert.ok(p.$('cbGo'));
    p.close();
  });
});

describe('a Dutch NFT listing in the book', () => {
  test('shows its floor as the price it falls to, not zero', async () => {
    const NFT = '0x00000000000000000000000000000000000c0113';
    const now = Math.floor(Date.now() / 1000);
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setCode(NFT, '0x6000');
    chain.recent = [{
      id: 3n, board: A.DUTCH, dutch: true, maker: A.OTHER, pf: true, exp: BigInt(now + 7200),
      nA: true, nB: false, cp: A.ZERO,
      tA: NFT, aA: 1n, symA: 'PUNK', decA: 0,
      tB: A.WETH, aB: 2n * ETH, symB: 'WETH', decB: 18,
    }];
    // An NFT listing keeps no initial amount: the price is per item.
    chain.dutchListings.set('3', { start: now - 60, duration: 3600, startPrice: 2n * ETH, endPrice: ETH / 2n, initial: 0n, remaining: 1n });
    const p = await loadPage({ chain });
    await p.connect();
    p.click('tabBook');
    await p.waitFor(() => p.$('book').querySelector('[data-bf="0"]'), { label: 'filter chips' });
    p.click(p.$('book').querySelector('[data-bf="0"]'));
    await p.waitFor(() => /Dutch/.test(p.text('book')) && /floor/.test(p.text('book')), { label: 'the Dutch row', ...SLOW });
    assert.match(p.text('book'), /floor 0\.5 WETH in \d+m/);
    assert.doesNotMatch(p.text('book'), /floor 0 WETH/);
    p.close();
  });
});

describe('a network switch while a private or market transaction is out', () => {
  test('is refused for a wallet that switches in place', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain });
    await p.connect();
    p.window.ethereum.sw = () => true;   // a WalletConnect-style session: the page aims, nothing is asked
    for (const flag of ['cpBusy', 'mkBusy']) {
      p.window.eval(`${flag}=1`);
      await p.window.eval('switchNet(8453)');
      assert.equal(p.text('stat'), 'Still on Ethereum — finish the transaction in progress first.', flag);
      assert.equal(p.window.eval('CHAIN_ID'), 1, `still on Ethereum while ${flag}`);
      p.window.eval(`${flag}=0`);
    }
    await p.window.eval('switchNet(8453)');
    assert.equal(p.window.eval('CHAIN_ID'), 8453, 'with nothing out, the same switch goes through');
    await p.settle();
    await sleep(50);
    await p.settle();
    p.close();
  });
});

// ---- the confidential pool, as sweep-fixes.test.mjs serves it ----
const SEL_CP = { IMPL: '93228617', ASSETS: '9fda5b66', NEXT: '0be4f422', DEPOSIT: '7da9874f' };
function poolChain() {
  const chain = new MockChain();
  chain.blockNumber = '0x' + (CP_BLOCK + 0x200).toString(16);
  chain.gasPrice = 10n ** 8n;
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.answer(F.router, SEL_CP.IMPL, '0x' + F.executorImpl.slice(2).toLowerCase().padStart(64, '0'));
  chain.answer(F.pool, SEL_CP.ASSETS, '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
  chain.answer(F.pool, SEL_CP.NEXT, () => '0x' + u256(chain.nextLeaf ?? 0));
  chain.answer(F.pool, SEL_CP.DEPOSIT, '0x' + u256(0));
  return chain;
}

async function unlocked() {
  const p = await loadPage({ chain: poolChain() });
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
const rowOf = (p, key) => [...p.$('pvList').querySelectorAll('.cpr')]
  .find(r => [...r.querySelectorAll('button')].some(b => b.dataset.k === key));

describe('importing a note list', () => {
  test('attaches an L2 exit to a note this key already holds', async () => {
    const p = await unlocked();
    const key = p.window.eval(`(()=>{const n=${NOTE('21', '23', 1000000)};cpNotes.push(n);
      cpPool.leaves.push(cpNoteOf(n).leaf);cpPaint();window.__N=n;return cpKeyOf(n)})()`);
    assert.ok(rowOf(p, key)?.querySelector('button[data-a="exit"]'), 'the note is held and ready');
    const rec = JSON.parse(p.window.eval('JSON.stringify(__N)'));
    rec.ex = { ch: 8453, to: A.OTHER, du: '9999999999', dl: '9999999999', fee: '0', v: '1000000' };
    p.queuePrompt(JSON.stringify([rec]));
    p.click(p.$('pvKey').querySelector('button[data-a="import"]'));
    await p.waitFor(() => /Imported|Nothing new/.test(p.text('stat')), { label: 'the import result', ...SLOW });
    assert.equal(p.text('stat'), 'Imported 1 note.');
    assert.equal(p.window.eval('cpNotes.filter(n=>cpKeyOf(n)===' + JSON.stringify(key) + ').length'), 1, 'no second copy of the note');
    assert.equal(p.window.eval('__N.ex&&__N.ex.ch'), 8453, 'the exit is on the note already held');
    assert.equal(p.window.eval('__N.ex.im'), 1, 'marked as imported');
    assert.match(rowOf(p, key)?.textContent || '', /imported/, 'and its row shows the imported exit');
    p.close();
  });
});

describe('a failed exit whose settle may still land', () => {
  const exiting = (p, je) => p.window.eval(`(()=>{const n=${NOTE('0b', '0d', 1000000)};
      n.ex={ch:1,to:"${A.OTHER}",self:0,job:"0xjob1",js:"failed",je:${JSON.stringify(je)},du:String(nowS()+3600),dl:String(nowS()+259200),fee:"0",wei:"10000000000000000",nonce:"1"};
      cpNotes.push(n);cpPaint();return cpKeyOf(n)})()`);
  const retryOf = (p, key) => [...p.$('pvList').querySelectorAll('button[data-a="exit"]')].find(b => b.dataset.k === key);
  const finished = p => p.waitFor(() => !/Building the exit/.test(p.text('stat')) && p.text('stat'), { label: 'the retry to finish', ...SLOW });

  test('is retried on its own terms inside its window', async () => {
    const p = await unlocked();
    const retry = retryOf(p, exiting(p, 'settle reverted: x — broadcast and possibly still pending: 0xabc'));
    assert.equal(retry?.textContent, 'retry');
    p.click(retry);
    await p.waitFor(() => p.asked.confirm.length || /has not settled|already exiting/.test(p.text('stat')), { label: 'the retry to answer', ...SLOW });
    assert.ok(!p.asked.confirm.some(m => /Build this exit again/.test(m)), 'a settle that may still land is not rebuilt');
    assert.match(p.text('stat'), /has not settled into the pool yet/, 'it went past the guard');
    p.close();
  });

  test('one that plainly failed is still offered as a rebuild', async () => {
    const p = await unlocked();
    const retry = retryOf(p, exiting(p, 'settle reverted: x'));
    p.queueConfirm(true);
    p.click(retry);
    await p.waitFor(() => p.asked.confirm.some(m => /Build this exit again/.test(m)), { label: 'the rebuild to be offered', ...SLOW });
    await finished(p);
    assert.match(p.text('stat'), /has not settled into the pool yet/);
    p.close();
  });
});

describe('a self exit to an L2', () => {
  test('reads as sent until its nullifier is spent in the pool, then as bridged', async () => {
    const p = await unlocked();
    p.window.eval(`(()=>{const n=${NOTE('31', '33', 1000000)};
      n.ex={ch:8453,to:"${A.OTHER}",self:1,job:"0xjob3",js:"proven",ptx:"0x${'ab'.repeat(32)}",du:String(nowS()+3600),dl:String(nowS()+259200),fee:"0",wei:"10000000000000000",nonce:"3"};
      cpNotes.push(n);window.__X=n})()`);
    assert.equal(p.window.eval('cpStatus(__X).s'), 'exiting', 'a settle that is only sent has not bridged');
    p.window.eval('cpPaint()');
    assert.match(p.text('pvList'), /sent…/);
    assert.doesNotMatch(p.text('pvList'), /on Base/);
    assert.equal(p.window.eval('(()=>{const c=cpPool;cpPool=null;try{return cpStatus(__X).s}finally{cpPool=c}})()'), 'bridged',
      'with no pool read, it reads as before');
    p.window.eval('cpPool.spent.push(cpNoteOf(__X).nu);cpPaint()');
    assert.equal(p.window.eval('cpStatus(__X).s'), 'bridged');
    assert.match(p.text('pvList'), /on Base/);
    p.close();
  });
});

describe('a cUSD loan the relay forgot', () => {
  test('reads as failed, like one the relay failed', async () => {
    const p = await loadPage({ chain: new MockChain() });
    const rows = js => p.window.eval(`cpSaveCdps([{i:0,v:"100000000",cv:"200000000",leaf:"0x${'ab'.repeat(32)}",job:"j1",js:"${js}"}]);cpCdpRows()`);
    assert.match(rows('unknown'), /1 cUSD<\/b> against 2 cBTC<\/span><span>loan failed</);
    assert.match(rows('failed'), /loan failed/);
    assert.match(rows('pending'), /opening…/);
    p.close();
  });
});

// ---- the zFi DAO, as governance.test.mjs serves it ----
const GDAO = '0x5E58BA0e06ED0F5558f83bE732a4b899a674053E';
const RESOLVER = '0x000000E7DAD6128683D1fb415e80B30c23dAb7AC';
const BADGES = '0x2809A7EB62D5a50e40153080F548c306Db01c221';
const V1 = '0x00000095643CFfA7D9fae407a84dfCB6406456c6';
const V2 = '0xe686952842627A2cf81DF42CCaD54ef98046DB8D';
const addrWord = a => a.slice(2).toLowerCase().padStart(64, '0');

describe('proposing', () => {
  test('two quick presses send one proposal', async () => {
    const chain = new MockChain();
    chain.answer(GDAO, 'c08cc02d', '0x' + u256(0))
      .answer(GDAO, '31933916', '0x' + u256(0))
      .answer(GDAO, '79502c55', '0x' + u256(0))
      .answer(RESOLVER, 'f8b1cb3c', '0x' + u256(32) + u256(2) + addrWord(V1) + addrWord(V2))
      .answer(RESOLVER, '9fa6a6e3', '0x' + addrWord(V2))
      .answer(V1, '451aae60', '0x' + u256(0))
      .answer(GDAO, '59a342d6', '0x' + u256(86400))
      .answer(GDAO, 'eef09bad', '0x' + u256(86400))
      .answer(GDAO, 'cd2ddd0c', '0x' + u256(1000))
      .answer(BADGES, '70a08231', '0x' + u256(1));
    for (const s of ['56781388', 'ee5b2895', 'ac9650d8']) chain.answer(GDAO, s, '0x');
    const p = await loadPage({ chain });
    await p.connect();
    await p.settle();
    p.click('footGov');
    await p.waitFor(() => /versions/.test(p.text('gvList')) && p.visible('gvNew'), { label: 'the proposal form' });
    await p.settle();
    p.type('gvTo', A.ACCOUNT); p.type('gvData', '0x1234'); p.type('gvDesc', 'Fund the thing');
    chain.receiptPending = true;
    p.click('gvGo');
    p.click('gvGo');
    await p.waitFor(() => chain.sentTo(GDAO).length >= 1, { label: 'the proposal', ...SLOW });
    await sleep(400);
    chain.receiptPending = false;
    await p.waitFor(() => /Done/.test(p.text('gvS')), { label: 'the proposal to land', timeout: 20000 });
    await p.settle();
    assert.equal(chain.sentTo(GDAO).length, 1, 'one proposal, not two');
    p.close();
  });
});

describe('backing a cause while the line changes', () => {
  test('says it backed, and keeps the token, after a flip during the receipt', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n ** 19n);
    chain.setToken(LOOT, { symbol: 'DUCK', decimals: 18, name: 'Feed Ducks Loot' });
    chain.setCause(LOOT, {
      dao: DAO, shares: SHARES, sharesSupply: ETH, lootSupply: 4_000_000n * ETH, treasury: 3_600_000_000_000_000_000n,
      price: 10n ** 12n, deadline: BigInt(Math.floor(Date.now() / 1000) + 22 * 86400), remaining: 5_999_999n * ETH,
    });
    const p = await loadPage({ chain, storage: { 'zswap:custom': JSON.stringify([{ sym: 'DUCK', addr: LOOT, dec: 18, std: 'ft' }]) } });
    await p.connect();
    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'DUCK');
    await p.settle();
    p.type('amt', '1');
    await p.waitFor(() => !!p.$('cbGo'), { label: 'the Back button' });
    chain.receiptPending = true;
    p.click('cbGo');
    await p.waitFor(() => chain.sent.length > 0, { label: 'the backing transaction' });
    p.click('flip');
    await p.waitFor(() => symOf(p, 'fromSel') === 'DUCK' && p.window.eval('cbBuy') === false, { label: 'the flipped line' });
    chain.receiptPending = false;
    await p.waitFor(() => /Backed|Burned/.test(p.text('stat')), { label: 'the receipt', timeout: 20000 });
    assert.equal(p.text('stat'), 'Backed · burn it back any time for what is left.');
    const kept = JSON.parse(p.window.localStorage.getItem('zswap:custom') || '[]').find(t => t.addr === LOOT);
    assert.equal(kept?.cause, 1, 'the cause token is kept as a cause');
    p.close();
  });
});

describe('a send-tab name lookup', () => {
  test('does not land on the Swap tab when the user moved there first', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.names.set('alice.wei', A.OTHER);
    const p = await loadPage({ chain });
    await p.connect();
    p.click('tabSend');
    await p.settle();
    const g = gate(chain, callTo(WNS));
    g.on = true;
    p.type('rc', 'alice.wei');
    await p.waitFor(() => g.held > 0, { label: 'the lookup to start', ...SLOW });
    assert.equal(p.text('rcvEl'), 'resolving…');
    p.click('tabSwap');
    assert.equal(p.$('tabSwap').getAttribute('aria-selected'), 'true');
    g.release();
    await p.waitFor(() => g.done >= g.held, { label: 'the lookup to answer', ...SLOW });
    await p.settle();
    await sleep(50);
    assert.equal(p.value('rc'), '', 'the swap tab has no recipient');
    assert.equal(p.text('rcvEl'), '', 'and the send tab\'s answer is not written into it');
    p.close();
  });
});

describe('a launch while its logo is still being read', () => {
  test('is refused until the logo is in', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n ** 19n);
    const p = await loadPage({ chain });
    await p.connect();
    p.click('ln');
    p.type('lnName', 'A');
    p.type('lnSym', 'X');
    p.type('lnSupply', '1000000000');
    p.window.eval('Tx(lnArtNote,"reading…")');
    p.click('lnGo');
    await p.waitFor(() => p.text('stat') || p.chain.sent.length, { label: 'the launch to answer', ...SLOW });
    await p.settle();
    assert.equal(p.text('stat'), 'The logo is still loading.');
    assert.equal(p.chain.sent.length, 0, 'nothing was sent');
    assert.equal(p.$('lnGo').disabled, false, 'the button is free to press again');
    p.window.eval('Tx(lnArtNote,"none")');
    p.click('lnGo');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'the launch', ...SLOW });
    p.close();
  });
});
