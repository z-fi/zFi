/**
 * Behaviours pinned here:
 *
 * - Liquidity mode refuses a recipient typed as the raw address of a routing
 *   contract: the status line says so and no deposit is sent. A string that
 *   is not an address still asks for one that resolves, and an ordinary
 *   checksummed address still receives the shares.
 * - On the TAC/ETH farm band the add button reads "Add & stake" while staking
 *   is ticked, whatever the one-sided box says; with staking unticked it reads
 *   "Zap in" with one-sided on and "Add liquidity" with it off.
 * - The theme button stores "d" or "l" and shows the matching icon when <html>
 *   carries another class as well, as a page translator adds.
 * - A single-NFT Dutch listing filled from the book by a wallet that cannot
 *   batch passes its pre-flight read of the listing, then approves and fills.
 * - A WalletConnect session message that carries a method, such as the page's
 *   own request coming back on the session topic, leaves the request pending;
 *   the wallet's reply settles it.
 * - A first visit with no kept list and an unreachable registry says the
 *   built-in list is in use because the registry is unreachable.
 * - On the Orders tab, a link that lands on the same tab and the same pair
 *   keeps a "You want" amount the user typed, whether it names a want of its
 *   own or none at all; a want an earlier link wrote is replaced by the next
 *   link's.
 * - A page opened on a link that names a mode (#m=lq, ln, wn, pv or mk) opens
 *   that mode with no script error and no unhandled rejection.
 * - In liquidity mode, a link that fills the empty "LP shares to" field holds
 *   the add button: a press inside the hold says the link just changed the
 *   trade and sends nothing, and a press after it deposits for the address
 *   the link named.
 * - A copied link carries a decimal-comma amount such as "0,5", and the page
 *   it opens shows that amount in "You pay" with the same quote.
 * - A private send of exactly one ready note, pressed while a background
 *   refresh is reading the pool, hands the relay one stealth lock, and the
 *   send's row follows that lock until it lands.
 * - A market whose quote calls come back empty from the multicall reads
 *   "Could not quote.", and Buy sends no bet.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash, webcrypto } from 'node:crypto';
import { getAddress, AbiCoder, keccak256, toUtf8Bytes } from 'ethers';
import {
  A, SEL, MockChain, loadPage, closeAllPages, fixedRateQuoter, domainSeparator,
  word, wordAddr, selectorOf, HTML_PATH, CP_BLOCK,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const SLOW = { timeout: 15000 };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const aw = a => a.toLowerCase().replace(/^0x/, '').padStart(64, '0');
const args = data => '0x' + data.replace(/^0x/, '').slice(8);
const typeInto = (p, el, v) => {
  el.value = v;
  el.dispatchEvent(new p.window.Event('input', { bubbles: true }));
};

// ---------------------------------------------------------------------------

describe('a liquidity recipient', () => {
  const LENS = '0x4444444444444444444444444444444444444444';
  const POOL = '0x7777777777777777777777777777777777777777';
  const sqrtRaw = (price, d0 = 18, d1 = 6) =>
    BigInt(Math.floor(Math.sqrt(price * 10 ** (d1 - d0)) * 1e18));
  const ROUTING = 'That is a routing contract — anything sent there can be taken by anyone.';
  const EOA = getAddress('0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed');

  test('a raw routing-contract address is refused at the add; a checksummed address receives the shares', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 50n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 100000n * USDC);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setCode(LENS, '0x60006000');
    chain.setPools(A.ZERO, A.USDC, [{
      pool: POOL, fee: 3000n, liquidity: 10n ** 21n,
      reserve0: 100n * ETH, reserve1: 300000n * USDC,
      sqrtLow: sqrtRaw(2000), sqrtHigh: sqrtRaw(4000), sqrtNow: sqrtRaw(3000),
    }]);
    const lens = fs.readFileSync(HTML_PATH, 'utf8').match(/const PPLENS="0x[0-9a-fA-F]{40}"/)[0];
    const p = await loadPage({ chain, patch: [[lens, `const PPLENS="${LENS}"`]] });
    await p.connect();
    p.click('lq');
    await p.settle();
    p.click(await p.waitFor(() => p.$('lqList').querySelector('[data-act="a"]'), { label: 'the band', ...SLOW }));
    const box = p.$('lqList').querySelector('.lqadd');
    const go = box.querySelector('[data-act="ac"]');
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '1');
    typeInto(p, i1, '3000');
    await p.waitFor(() => !go.disabled, { label: 'the preview', ...SLOW });

    // Pressed before the field's own debounced check runs, so the add answers by itself.
    p.type('rc', A.ZROUTER);
    p.click(go);
    await p.waitFor(() => p.text('stat') === ROUTING || p.chain.sent.length,
      { label: 'the add to answer', ...SLOW });
    assert.equal(p.text('stat'), ROUTING);
    await sleep(400);
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'no approval and no deposit');
    assert.equal(p.text('stat'), ROUTING, 'the field check names the same reason');
    assert.ok(p.$('rc').classList.contains('bad'), 'the field is marked');
    assert.equal(p.text('rcvEl'), '', 'and no recipient is shown');

    p.type('rc', 'not-an-address');
    await sleep(400);
    await p.settle();
    p.click(go);
    await p.waitFor(() => /that resolves\.$/.test(p.text('stat')), { label: 'the unresolvable refusal', ...SLOW });
    assert.equal(p.chain.sent.length, 0);

    p.type('rc', EOA);
    await p.waitFor(() => p.text('rcvEl') === EOA, { label: 'the recipient shown', ...SLOW });
    p.click(go);
    await p.waitFor(() => p.chain.sentTo(POOL).length, { label: 'the deposit', ...SLOW });
    await p.settle();
    const add = p.chain.sentTo(POOL).at(-1);
    assert.equal(selectorOf(add.data), SEL.ADDEXACT);
    assert.equal(wordAddr(args(add.data), 4).toLowerCase(), EOA.toLowerCase(), 'the shares go to the named address');
    p.close();
  });
});

// ---- the TAC/ETH farm, as pfarm.test.mjs serves it ----
describe('the add button on the farm band', () => {
  const TAC = '0xA1313eb9f3A445606D9583bcAc3ebeB56a858279';
  const FARM = '0x0000003bF4BA0B21f5e0d35119b337F4d4CF82E0';
  const POOL = '0x0155358241411dB868BA714aE7c83A27087e3D6E';
  const RATE = 6410750000000000n;
  const row = (s, a, o = {}) => ({
    i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
    a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true, ...o,
  });

  async function openBand() {
    const chain = new MockChain();
    chain.registry = [row('ETH', A.ZERO, { p: 'Native' }), row('TAC', TAC), row('USDC', A.USDC, { d: 6 })];
    chain.conviction = [1, 2, 3];
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(TAC, A.ACCOUNT, 1000n * ETH);
    chain.setToken(TAC, { symbol: 'TAC', decimals: 18, name: 'TAC', domainSeparator: domainSeparator('TAC', '1', TAC) });
    chain.quoteHandler = fixedRateQuoter({ rate: 14000n * ETH, decOut: 18 });
    chain.setPools(A.ZERO, TAC, [{
      pool: POOL, fee: 3000n, liquidity: 2160175009930805825n,
      reserve0: 17503584633155263n, reserve1: 250n * ETH,
      sqrtLow: 3779257685557097674n, sqrtHigh: 3779257685557097674402n, sqrtNow: 119510621510568635147n,
    }]);
    chain.setCode(FARM, '0x6000');
    chain.answer(POOL, '18160ddd', '0x' + u256(2160175009930805825n));
    chain.answer(POOL, '443cb4bc', '0x' + u256(17503584633155263n));
    chain.answer(POOL, '5a76f25e', '0x' + u256(250n * ETH));
    chain.answer(POOL, '2af1f249', '0x' + u256(119510621510568635147n));
    const fin = Math.floor(Date.now() / 1e3) + 30 * 86400;
    for (const [s, v] of Object.entries({ '7b0a47ee': RATE, ebe2b12b: fin, '817b1cd2': 0, '98807d84': 0, '008cc262': 0 })) {
      chain.answer(FARM, s, '0x' + u256(v));
    }
    const p = await loadPage({ chain, hash: 'token=ETH&out=TAC' });
    await p.connect({ pin: false });
    await p.settle();
    p.click(await p.waitFor(() => p.$('pfEl').querySelector('[data-pf="go"]'), { label: 'the farm line', ...SLOW }));
    const band = () => [...p.$('lqList').querySelectorAll('.lqrow')]
      .find(r => r.dataset.pool.toLowerCase() === POOL.toLowerCase());
    await p.waitFor(() => band()?.querySelector('.pfb'), { label: 'the farm block on the band', ...SLOW });
    return { p, box: band().querySelector('.lqadd') };
  }

  test('reads "Add & stake" while staking is ticked, whatever the one-sided box says', async () => {
    const { p, box } = await openBand();
    const go = box.querySelector('[data-act="ac"]');
    const zap = box.querySelector('.lqz'), stake = box.querySelector('.pfk');
    const flip = (el, on) => {
      el.checked = on;
      el.dispatchEvent(new p.window.Event('change', { bubbles: true }));
      return go.textContent;
    };
    assert.ok(stake.checked, 'arriving by Farm ticks staking');
    assert.equal(go.textContent, 'Add & stake');
    assert.equal(flip(zap, true), 'Add & stake', 'one-sided on, staking ticked');
    assert.equal(flip(zap, false), 'Add & stake', 'one-sided off again, staking still ticked');

    assert.equal(flip(stake, false), 'Add liquidity', 'staking unticked, one-sided off');
    assert.equal(flip(zap, true), 'Zap in', 'staking unticked, one-sided on');
    assert.equal(flip(stake, true), 'Add & stake', 'staking ticked over a one-sided deposit');
    assert.equal(flip(stake, false), 'Zap in', 'unticked again, the one-sided deposit is named');
    assert.equal(flip(zap, false), 'Add liquidity', 'staking unticked, one-sided off again');
    await p.settle();
    assert.equal(go.textContent, 'Add liquidity', 'the label holds once the page is idle');
    p.close();
  });
});

describe('the theme button', () => {
  test('stores the choice and shows the matching icon when <html> carries another class', async () => {
    const p = await loadPage();
    const html = p.doc.documentElement, th = p.$('th'), tc = p.$('tc');
    html.classList.add('translated-ltr');
    assert.ok(!th.querySelector('circle'), 'light to begin with, so the moon is shown');

    p.click('th');
    assert.equal(p.window.localStorage.getItem('t'), 'd');
    assert.ok(html.classList.contains('d'), 'dark is on');
    assert.ok(html.classList.contains('translated-ltr'), 'the other class is left alone');
    assert.ok(th.querySelector('circle'), 'dark shows the sun');
    assert.equal(tc.getAttribute('content'), '#0a0a0a');

    p.click('th');
    assert.equal(p.window.localStorage.getItem('t'), 'l');
    assert.ok(!html.classList.contains('d'), 'dark is off');
    assert.ok(html.classList.contains('translated-ltr'));
    assert.ok(!th.querySelector('circle'), 'light shows the moon');
    assert.match(th.querySelector('path').getAttribute('d'), /^M20\.5 14\.6/);
    assert.equal(tc.getAttribute('content'), '#fff');
    p.close();
  });
});

describe('a single-NFT Dutch listing filled from the book', () => {
  test('a wallet that cannot batch passes the listing pre-flight, then approves and fills', async () => {
    const NFT = '0x00000000000000000000000000000000000c0114';
    const ID = 7n, TOKEN_ID = 42n, PRICE = 1500n * USDC;
    const now = Math.floor(Date.now() / 1000);
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 5000n * USDC);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setCode(NFT, '0x6000');
    // The lens reports an NFT lot's amount as its token id.
    chain.recent = [{
      id: ID, board: A.DUTCH, dutch: true, maker: A.OTHER, pf: true, exp: BigInt(now + 7200),
      nA: true, nB: false, cp: A.ZERO,
      tA: NFT, aA: TOKEN_ID, symA: 'PUNK', decA: 0,
      tB: A.USDC, aB: PRICE, symB: 'USDC', decB: 6,
    }];
    // Dutchboard.listings(id) for a live single-NFT lot: isNFT set and `remaining` zero.
    // Words: seller, isNFT, startTime, duration, token, startPrice, quote, endPrice, initial, remaining, expiry.
    chain.answer(A.DUTCH, SEL.DUTCH_LISTING, '0x' + [
      aw(A.OTHER), u256(1), u256(now - 60), u256(3600), aw(NFT), u256(2000n * USDC),
      aw(A.USDC), u256(1000n * USDC), u256(0), u256(0), u256(now + 7200),
    ].join(''));
    // The fill is simulated with eth_call before it is sent.
    chain.answer(A.DUTCH, SEL.DUTCH_FILL, '0x');

    const p = await loadPage({ chain });
    await p.connect();
    p.click('tabBook');
    p.click(await p.waitFor(() => p.$('book').querySelector('[data-bf="0"]'), { label: 'filter chips', ...SLOW }));
    const fill = await p.waitFor(() => p.$('book').querySelector('button[data-x="f"][data-d="1"]'),
      { label: 'the Dutch NFT row', ...SLOW });
    assert.match(p.text('book'), /#42/);
    assert.equal(fill.textContent, 'Fill');

    const reads = () => p.chain.calls
      .filter(c => c.to === A.DUTCH.toLowerCase() && c.selector === SEL.DUTCH_LISTING).length;
    const before = reads();
    p.click(fill);
    await p.waitFor(() => p.chain.sentTo(A.DUTCH).length || /refresh and retry/.test(p.text('stat')),
      { label: 'the fill or a refusal', ...SLOW });
    assert.doesNotMatch(p.text('stat'), /listing changed/);
    assert.ok(reads() > before, 'the listing is read again before anything is sent');
    assert.equal(p.chain.batches.length, 0, 'nothing is batched');

    const [ap, fl] = p.chain.sent;
    assert.equal(ap.to.toLowerCase(), A.USDC.toLowerCase(), 'the approval goes first');
    assert.equal(selectorOf(ap.data), SEL.APPROVE);
    assert.equal(wordAddr(args(ap.data), 0).toLowerCase(), A.DUTCH.toLowerCase());
    assert.equal(word(args(ap.data), 1), PRICE);
    assert.equal(fl.to.toLowerCase(), A.DUTCH.toLowerCase(), 'then the fill');
    assert.equal(selectorOf(fl.data), SEL.DUTCH_FILL);
    assert.equal(word(args(fl.data), 0), ID);
    assert.equal(wordAddr(args(fl.data), 2).toLowerCase(), A.ACCOUNT.toLowerCase());
    assert.equal(word(args(fl.data), 3), PRICE);
    p.close();
  });
});

// ---- a WalletConnect peer over a stand-in relay socket, as wc-switch.test.mjs builds it ----
describe('a WalletConnect request', () => {
  const subtle = webcrypto.subtle;
  const hex = b => Buffer.from(b).toString('hex');
  const unhex = h => new Uint8Array(Buffer.from(h, 'hex'));
  const ME = new RegExp(A.ACCOUNT.slice(-4));
  const MARK = 777001;

  async function wcPeer(p) {
    const w = p.window;
    Object.defineProperty(w.crypto, 'subtle', { value: subtle, configurable: true });
    const U = w.eval('WCU');
    const peer = { requests: [], acked: new Set(), topics: new Set(), held: [], sock: null, sKey: null, sTopic: null };
    let rid = 1;
    const toPage = o => w.setTimeout(() => peer.sock?.onmessage?.({ data: JSON.stringify(o) }), 0);
    const deliver = (topic, message) =>
      toPage({ id: 9e15 + rid++, jsonrpc: '2.0', method: 'irn_subscription', params: { id: 's', data: { topic, message } } });
    const toSession = b => deliver(peer.sTopic, U.encode(peer.sKey, { jsonrpc: '2.0', ...b }));

    const onSession = async message => {
      const m = U.decode(peer.sKey, message);
      if (m && !m.method) peer.acked.add(m.id);
      if (!m || m.method !== 'wc_sessionRequest') return;
      const { request, chainId } = m.params;
      peer.requests.push({ method: request.method, chainId, params: request.params });
      if (peer.before) await peer.before(m, message);
      let result, error = null;
      try { result = await p.chain.request({ method: request.method, params: request.params }); }
      catch (e) { error = { code: e.code ?? -32000, message: e.message }; }
      toSession(error ? { id: m.id, error } : { id: m.id, result });
    };

    w.WebSocket = class {
      constructor() { peer.sock = this; w.setTimeout(() => this.onopen?.(), 0); }
      close() {}
      send(raw) {
        const m = JSON.parse(raw);
        if (!m.method) return;
        toPage({ id: m.id, jsonrpc: '2.0', result: m.method === 'irn_subscribe' ? 'sub' : true });
        if (m.method === 'irn_subscribe') peer.topics.add(m.params.topic);
        if (m.method !== 'irn_publish') return;
        if (m.params.topic === peer.sTopic) onSession(m.params.message);
        else peer.held.push(m.params);
      }
    };

    peer.scan = async uri => {
      const [, pTopic, symHex] = /^wc:([0-9a-f]+)@2\?.*symKey=([0-9a-f]+)/.exec(uri);
      const symKey = unhex(symHex);
      const prop = U.decode(symKey, peer.held.find(x => x.topic === pTopic).message);
      const kp = await subtle.generateKey({ name: 'X25519' }, true, ['deriveBits']);
      const pub = new Uint8Array(await subtle.exportKey('raw', kp.publicKey));
      const them = await subtle.importKey('raw', unhex(prop.params.proposer.publicKey), { name: 'X25519' }, false, []);
      const shared = await subtle.deriveBits({ name: 'X25519', public: them }, kp.privateKey, 256);
      const hk = await subtle.importKey('raw', shared, 'HKDF', false, ['deriveBits']);
      peer.sKey = new Uint8Array(await subtle.deriveBits(
        { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: new Uint8Array(0) }, hk, 256));
      peer.sTopic = hex(new Uint8Array(await subtle.digest('SHA-256', peer.sKey)));
      deliver(pTopic, U.encode(symKey, { id: prop.id, jsonrpc: '2.0',
        result: { relay: { protocol: 'irn' }, responderPublicKey: hex(pub) } }));
      await p.waitFor(() => peer.topics.has(peer.sTopic), { label: 'the page to subscribe to the session' });
      toSession({ id: rid++, method: 'wc_sessionSettle', params: { relay: { protocol: 'irn' },
        namespaces: { eip155: { accounts: [`eip155:1:${A.ACCOUNT}`],
          methods: ['eth_sendTransaction', 'personal_sign', 'eth_signTypedData_v4'],
          events: ['chainChanged', 'accountsChanged'] } } } });
    };
    peer.deliver = deliver;
    peer.send = toSession;
    return peer;
  }

  async function connectWc() {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain, walletless: true });
    const peer = await wcPeer(p);
    const wcRow = () => [...p.$('wkList').querySelectorAll('.tkr')].find(r => r.textContent === 'WalletConnect');
    p.click('swap');
    p.click(await p.waitFor(wcRow, { label: 'the wallet chooser' }));
    await p.waitFor(() => p.$('wkList').querySelector('.wcq'), { label: 'the pairing code' });
    p.click(p.$('wkList').querySelector('.wcn .fclink'));
    const uri = await p.waitFor(() => p.copied().find(u => /^wc:/.test(u)), { label: 'the pairing link' });
    await peer.scan(uri);
    await p.waitFor(() => ME.test(p.text('addr')), { label: 'the session to connect', ...SLOW });
    await p.settle();
    return { p, peer };
  }

  test('stays pending through a session message that carries a method, and settles on the wallet\'s reply', async () => {
    const { p, peer } = await connectWc();
    let answer;
    const held = new Promise(r => { answer = r; });
    peer.before = async (m, raw) => {
      if (m.params.request.method !== 'personal_sign') return;
      // The page's own request, delivered back to it on the session topic: same id, a method, no result.
      peer.deliver(peer.sTopic, raw);
      // A ping behind it. The page acknowledges a ping, so its ack shows the request was handled first.
      peer.send({ id: MARK, method: 'wc_sessionPing', params: {} });
      await held;
    };
    p.window.eval(`window.__got=undefined;rpc("personal_sign",["0x00","${A.ACCOUNT}"])`
      + '.then(v=>{window.__got={v:String(v)}},e=>{window.__got={e:String(e&&e.message)}})');
    const got = () => p.window.eval('JSON.stringify(window.__got)');
    await p.waitFor(() => peer.acked.has(MARK), { label: 'the echoed request and the ping to be handled', ...SLOW });
    assert.ok(peer.requests.some(r => r.method === 'personal_sign'), 'the request reached the wallet');
    assert.equal(got(), undefined, 'the request is still pending');

    answer();
    await p.waitFor(got, { label: 'the wallet\'s reply', ...SLOW });
    assert.deepEqual(JSON.parse(got()), { v: p.chain.personalSig }, 'the wallet\'s own signature is what the request returns');
    p.close();
  });
});

describe('the token list on a first visit', () => {
  test('names an unreachable registry as the reason the built-in list is in use', async () => {
    // MockChain's registry is null, which the harness models as unreachable.
    const p = await loadPage({ chain: new MockChain(), hash: null });
    const note = () => p.text('listNote');
    await p.waitFor(() => note() && !/…$/.test(note()), { label: 'the list read to finish', ...SLOW });
    assert.equal(note(), 'Built-in token list — registry unreachable');
    assert.ok(p.visible('listNote'));
    const syms = [...p.$('fromSel').options].map(o => o.textContent.trim());
    assert.ok(syms.includes('ETH') && syms.includes('USDC'), `the built-in list fills the pickers: ${syms}`);
    p.close();
  });
});

// ---- links, as links.test.mjs opens them ----
async function openLinked(hash) {
  const chain = new MockChain({ autoConnected: true });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 1000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  const p = await loadPage({ chain, hash });
  await p.settle();
  return p;
}
const tabOf = p => ['Swap', 'Send', 'Book'].find(t => p.$('tab' + t).getAttribute('aria-selected') === 'true');
const symOf = (p, which) => p.$(which).selectedOptions[0]?.textContent;

describe('a link pushed at the Orders tab', () => {
  // Assigning the hash is enough: jsdom fires hashchange itself, and a second,
  // hand-made event would apply the link twice.
  const push = async (p, hash, arrived, label) => {
    p.window.location.hash = hash;
    await p.waitFor(arrived, { label, ...SLOW });
    await p.settle();
  };

  test('keeps a typed "You want" on the same tab and pair, and replaces a want a link wrote', async () => {
    const p = await openLinked('tab=book&token=ETH&out=USDC&amount=1&want=3000');
    assert.equal(tabOf(p), 'Book');
    assert.equal(p.value('outAmt'), '3000');

    await push(p, 'tab=book&want=2500', () => p.value('outAmt') === '2500', 'the second link\'s want');
    assert.equal(p.value('amt'), '1', 'the amount the first link wrote is left as it was');

    p.type('outAmt', '2800');
    await p.settle();
    // Each later link also rewrites the amount the first link filled, which is how its arrival shows.
    await push(p, 'tab=book&amount=2&want=1', () => p.value('amt') === '2', 'a link with a want of its own');
    assert.equal(p.value('outAmt'), '2800', 'the typed want survives a link that names one');
    await push(p, 'tab=book&amount=3', () => p.value('amt') === '3', 'a link with no want');
    assert.equal(p.value('outAmt'), '2800', 'the typed want survives a link that names none');
    assert.equal(tabOf(p), 'Book');
    assert.equal(symOf(p, 'fromSel'), 'ETH');
    assert.equal(symOf(p, 'toSel'), 'USDC');
    p.close();
  });
});

describe('a mode named in the link at load', () => {
  test('opens with no script error and no unhandled rejection', async () => {
    const rejections = [];
    const onRejection = e => rejections.push(String(e?.message ?? e));
    process.on('unhandledRejection', onRejection);
    try {
      for (const m of ['lq', 'ln', 'wn', 'pv', 'mk']) {
        rejections.length = 0;
        const p = await loadPage({ hash: 'm=' + m });
        await p.waitFor(() => p.$(m).getAttribute('aria-pressed') === 'true', { label: `#m=${m} to open its mode`, ...SLOW });
        await p.settle();
        await sleep(50);
        assert.deepEqual(rejections, [], `#m=${m} leaves no unhandled rejection`);
        assert.deepEqual(p.consoleErrors.map(e => String(e?.message ?? e)), [], `#m=${m} raises no script error`);
        assert.equal(p.$(m).getAttribute('aria-pressed'), 'true', `#m=${m} stays open`);
        p.close();
      }
    } finally {
      process.off('unhandledRejection', onRejection);
    }
  });
});

describe('a link that fills the liquidity recipient', () => {
  const LENS = '0x4444444444444444444444444444444444444444';
  const POOL = '0x7777777777777777777777777777777777777777';
  const sqrtRaw = (price, d0 = 18, d1 = 6) =>
    BigInt(Math.floor(Math.sqrt(price * 10 ** (d1 - d0)) * 1e18));
  const HOLD = 'The link just changed this trade — check it, then press again.';
  const EOA = getAddress('0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed');

  test('holds the add button: a press inside the hold sends nothing, a press after it pays the linked address', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 50n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 100000n * USDC);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.setCode(LENS, '0x60006000');
    chain.setPools(A.ZERO, A.USDC, [{
      pool: POOL, fee: 3000n, liquidity: 10n ** 21n,
      reserve0: 100n * ETH, reserve1: 300000n * USDC,
      sqrtLow: sqrtRaw(2000), sqrtHigh: sqrtRaw(4000), sqrtNow: sqrtRaw(3000),
    }]);
    const lens = fs.readFileSync(HTML_PATH, 'utf8').match(/const PPLENS="0x[0-9a-fA-F]{40}"/)[0];
    const p = await loadPage({ chain, patch: [[lens, `const PPLENS="${LENS}"`]] });
    await p.connect();
    p.click('lq');
    await p.settle();
    await p.waitFor(() => p.$('lqList').querySelector('[data-act="a"]'), { label: 'the band', ...SLOW });
    assert.equal(p.value('rc'), '', 'no recipient to begin with');

    // The page's clock stands still from here, so the hold cannot lapse while the test works.
    let now = Date.now();
    p.window.Date.now = () => now;
    p.window.location.hash = `token=ETH&out=USDC&lq=1&to=${EOA}`;
    await p.waitFor(() => p.value('rc') === EOA, { label: 'the link to fill the recipient', ...SLOW });
    await p.settle();
    assert.equal(p.$('lq').getAttribute('aria-pressed'), 'true', 'still in liquidity mode');

    p.click(await p.waitFor(() => p.$('lqList').querySelector('[data-act="a"]'), { label: 'the band again', ...SLOW }));
    const box = p.$('lqList').querySelector('.lqadd');
    const go = box.querySelector('[data-act="ac"]');
    const [i0, i1] = box.querySelectorAll('.lqin');
    typeInto(p, i0, '1');
    typeInto(p, i1, '3000');
    await p.waitFor(() => !go.disabled, { label: 'the preview', ...SLOW });

    p.click(go);
    await p.waitFor(() => p.text('stat') === HOLD || p.chain.sent.length || p.chain.batches.length,
      { label: 'the add to answer', ...SLOW });
    assert.equal(p.text('stat'), HOLD);
    await p.waitFor(() => !go.disabled, { label: 'the button back', ...SLOW });
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'no approval and no deposit inside the hold');
    assert.equal(p.chain.batches.length, 0);

    // Past the hold, the same press goes through.
    now += 2600;
    p.click(go);
    await p.waitFor(() => p.chain.sentTo(POOL).length, { label: 'the deposit', ...SLOW });
    await p.settle();
    const add = p.chain.sentTo(POOL).at(-1);
    assert.equal(selectorOf(add.data), SEL.ADDEXACT);
    assert.equal(wordAddr(args(add.data), 4).toLowerCase(), EOA.toLowerCase(), 'the shares go to the address the link named');
    p.close();
  });
});

describe('a copied link with a decimal comma', () => {
  test('opens a page with the same amount in "You pay" and the same quote', async () => {
    const p = await openLinked('token=ETH&out=USDC');
    await p.typeAmount('amt', '0,5');
    const quoted = p.value('outAmt');
    assert.ok(quoted && quoted !== '...', `half an ether is quoted: ${quoted}`);
    p.$('stat').textContent = '';
    p.click('lk');
    await p.waitFor(() => p.text('stat') !== '', { label: 'the link to be copied', ...SLOW });
    const url = p.copied().at(-1);
    p.close();
    assert.equal(new URLSearchParams(new URL(url).hash.slice(1)).get('amount'), '0,5', 'the link carries the amount as typed');

    const p2 = await openLinked(new URL(url).hash.slice(1));
    assert.equal(tabOf(p2), 'Swap');
    assert.equal(symOf(p2, 'fromSel'), 'ETH');
    assert.equal(symOf(p2, 'toSel'), 'USDC');
    assert.equal(p2.value('amt'), '0,5');
    await p2.waitFor(() => p2.value('outAmt') === quoted, { label: 'the same quote', ...SLOW });
    p2.close();
  });
});

// ---- Tacit's pool, as private-send.test.mjs serves it ----
describe('a private send pressed while the pool refreshes', () => {
  const F = JSON.parse(fs.readFileSync(new URL('../fixtures/confidential.json', import.meta.url), 'utf8'));
  const S = F.send;
  const coder = AbiCoder.defaultAbiCoder();
  const POOL = F.pool, RELAY = 'api.tacit.finance';
  const CP = { ASSETS: '9fda5b66', NEXT: '0be4f422', DEPOSIT: '7da9874f', SETTLE: '717fd7f2', WT: '50de88e1' };
  const T = {
    LEAVES: keccak256(toUtf8Bytes('LeavesInserted(uint256,bytes32[],bytes[])')),
    SPENT: keccak256(toUtf8Bytes('NullifiersSpent(bytes32[])')),
    WRAP: keccak256(toUtf8Bytes('Wrap(bytes32,bytes32,uint256)')),
  };
  const KEY = { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: F.seed };
  const LONG = { timeout: 30000 };
  const B0 = CP_BLOCK + 0x100;

  // settle() calldata: PublicValues with note nullifiers (3), note leaves (4), lock leaves (17), lock nullifiers (18).
  const pvWith = ({ nullifiers = [], leaves = [], lockLeaves = [], lockNullifiers = [] }) => {
    const arrs = { 3: nullifiers, 4: leaves, 17: lockLeaves, 18: lockNullifiers }, head = [];
    let tail = '', off = 34 * 32;
    for (let i = 0; i < 34; i++) {
      if (!arrs[i]) { head.push(u256(0)); continue; }
      head.push(u256(off));
      const enc = u256(arrs[i].length) + arrs[i].map(x => x.slice(2)).join('');
      tail += enc; off += enc.length / 2;
    }
    return '0x' + u256(32) + head.join('') + tail;
  };

  function poolChain() {
    const chain = new MockChain();
    chain.blockNumber = '0x' + (B0 + 0x100).toString(16);
    chain.gasPrice = 0n;
    chain.setNative(A.ACCOUNT, 10n ** 18n);
    chain.answer(POOL, CP.ASSETS, '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
    chain.answer(POOL, CP.NEXT, () => '0x' + u256(chain.nextLeaf ?? 0));
    chain.answer(POOL, CP.DEPOSIT, () => '0x' + u256(chain.depositStatus ?? 0));
    chain.answer(POOL, CP.SETTLE, '0x');
    chain.answer(F.router, CP.WT, '0x');
    chain.txs = new Map();
    chain.ntx = 0;
    chain.jobs = 0;
    chain.relay = { status: { status: 'pending' } };
    chain.lanes = {};
    Object.defineProperty(chain.lanes, RELAY + '/confidential/submit', { enumerable: true, get: () => ({ ok: true, jobId: '0xjob' + (++chain.jobs), status: 'pending' }) });
    Object.defineProperty(chain.lanes, RELAY + '/confidential/status', { enumerable: true, get: () => chain.relay.status });
    return chain;
  }

  /** One pool.settle() transaction: its calldata, where the lock set lives, and the events it emits. */
  function settleOn(chain, c) {
    const tx = '0x' + createHash('sha256').update('settle-' + (++chain.ntx)).digest('hex');
    const block = '0x' + (B0 + chain.ntx).toString(16), all = [...(c.memos || []), ...(c.lockMemos || [])];
    chain.txs.set(tx, { hash: tx, to: POOL, input: '0x' + CP.SETTLE + coder.encode(['bytes', 'bytes', 'bytes[]'], [pvWith(c), '0x00', all]).slice(2) });
    let at = 0;
    const first = chain.nextLeaf ?? 0;
    if ((c.nullifiers || []).length) chain.logs.push({ address: POOL, blockNumber: block, logIndex: '0x' + (at++).toString(16), transactionHash: tx, topics: [T.SPENT], data: coder.encode(['bytes32[]'], [c.nullifiers]) });
    if ((c.leaves || []).length) {
      chain.logs.push({ address: POOL, blockNumber: block, logIndex: '0x' + (at++).toString(16), transactionHash: tx, topics: [T.LEAVES, '0x' + u256(first)], data: coder.encode(['bytes32[]', 'bytes[]'], [c.leaves, all]) });
      chain.nextLeaf = first + c.leaves.length;
    }
    chain.blockNumber = '0x' + (BigInt(chain.blockNumber) + 5n).toString(16);
  }

  /** The fixture note: deposited under this key at its derivation index and settled into leaf 0. */
  function withNote(chain) {
    chain.logs.push({ address: POOL, blockNumber: '0x' + (B0 - 1).toString(16), logIndex: '0x0', topics: [T.WRAP, F.depositId, F.ethAssetId], data: '0x' + u256(F.amountWei) });
    settleOn(chain, { leaves: [F.leaf, F.otherLeaf], memos: [F.memo, '0x' + '11'.repeat(169)] });
    return chain;
  }

  const poke = p => p.doc.dispatchEvent(new p.window.Event('visibilitychange'));
  const locks = p => p.window.__posts.filter(x => /\/confidential\/submit$/.test(x.url))
    .map(x => JSON.parse(x.body)).filter(x => x.type === 'stealthlock');
  const refreshing = p => p.window.eval('pvTick') !== 0;

  // `relay.hold` keeps every submit unanswered until `relay.release()`; the post itself is recorded at once.
  async function open(chain) {
    const p = await loadPage({ chain, storage: { ...KEY } });
    const inner = p.window.fetch;
    let opened = null, open;
    p.relay = {
      hold: () => { opened = new Promise(r => { open = r; }); },
      release: () => { opened = null; open?.(); },
    };
    p.window.__posts = [];
    p.window.fetch = async (url, init) => {
      if (init && init.body) p.window.__posts.push({ url: String(url), body: init.body });
      if (opened && /\/confidential\/submit$/.test(String(url))) await opened;
      return inner(url, init);
    };
    await p.connect();
    p.click('pv');
    await p.settle();
    p.click('pvGo');                       // one signature per visit unlocks the key
    await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock', ...SLOW });
    poke(p);
    await p.waitFor(() => /0\.01 tETH/.test(p.text('pvList')) && p.$('pvList').querySelector('button[data-a="split"]'),
      { label: 'the note, found from the key', ...LONG });
    return p;
  }

  // Every eth_blockNumber waits while `on`. It waits before the chain counts it as in flight, so settle()
  // still sees the rest of the page go quiet around it.
  function holdBlockNumber(chain) {
    const g = { on: true, held: 0 };
    let open;
    const opened = new Promise(r => { open = r; });
    g.release = () => { g.on = false; open(); };
    const inner = chain.request.bind(chain);
    chain.request = async args => {
      if (g.on && args.method === 'eth_blockNumber') { g.held++; await opened; }
      return inner(args);
    };
    return g;
  }

  const until = async (p, fn, label) => {
    for (let i = 0; i < 40 && !fn(); i++) { poke(p); await p.settle(); await sleep(50); }
    await p.waitFor(fn, { label, ...LONG });
  };

  test('hands the relay one stealth lock, and the row follows that lock until it lands', async () => {
    const p = await open(withNote(poolChain()));
    let now = (Number(S.deadline) - 7776000) * 1000;
    p.window.Date.now = () => now;
    p.select('pvAct', 'send');
    await p.settle();
    p.type('pvAmt', '0.01');
    p.type('pvRc', S.lock.recipient);
    await p.settle();
    await p.waitFor(() => !refreshing(p), { label: 'no refresh under way yet', ...LONG });

    // A minute on, a refresh reads the pool afresh, and the node is slow to give it the head block.
    const node = holdBlockNumber(p.chain);
    now += 61000;
    poke(p);
    await p.waitFor(() => node.held > 0 && refreshing(p), { label: 'the refresh to wait on the node', ...SLOW });

    // The send is pressed under it: it prices its fee, then queues its own pool read behind the refresh.
    const mark = p.chain.log.length;
    p.relay.hold();
    p.click('pvGo');
    await p.waitFor(() => p.chain.log.slice(mark).some(e => e.method === 'eth_gasPrice'), { label: 'the send to price its fee', ...SLOW });
    await p.settle();
    assert.equal(locks(p).length, 0, 'nothing reaches the relay before the pool is read');
    node.release();

    // The refresh finishes while the relay still holds the send's answer.
    await p.waitFor(() => !refreshing(p) || locks(p).length >= 2, { label: 'the refresh to finish', ...LONG });
    p.relay.release();
    await p.waitFor(() => /Sent through the relay/.test(p.text('stat')), { label: 'the send to finish', ...LONG });
    await p.waitFor(() => !refreshing(p), { label: 'the last refresh to finish', ...LONG });
    await p.settle();

    const sent = locks(p);
    assert.equal(sent.length, 1, 'one stealth lock reaches the relay');
    assert.equal(sent[0].mode, 'settle');
    assert.match(p.text('pvList'), /sent to 0[23]/);
    const [lock] = sent;
    settleOn(p.chain, { nullifiers: [F.nullifier], lockLeaves: [lock.op.lockLeaf], lockMemos: lock.memos });
    p.chain.relay.status = { status: 'settled' };
    await until(p, () => /waiting for the recipient/.test(p.text('pvList')), 'the row to follow that lock on chain');
    assert.equal(locks(p).length, 1, 'and nothing more is sent');
    p.close();
  });
});

// ---- the PM singleton, as markets.test.mjs serves it ----
describe('a market the node cannot quote', () => {
  const PM = '0x0000003b32cdd39bc950e56093df98af220ab5c5';
  const ID = 0xe0n;
  /** ABI for PM.getMarkets: (MarketView[] page, uint256 next). */
  const marketsRet = ms => {
    const elems = ms.map(m => {
      const d = Buffer.from(m.d, 'utf8').toString('hex');
      return [m.id, 0, 0, m.o, m.c, 0, 0, 0, 0, 0, m.y, m.n, m.p, 0, 15 * 32]
        .map((v, i) => (i === 1 ? aw(m.r) : i === 2 ? aw(m.a) : u256(v))).join('')
        + u256(d.length / 2) + d.padEnd(Math.ceil(d.length / 64) * 64, '0');
    });
    let cur = ms.length * 32;
    const offs = elems.map(e => { const o = u256(cur); cur += e.length / 2; return o; });
    return '0x' + u256(64) + u256(0) + u256(ms.length) + offs.join('') + elems.join('');
  };

  test('reads "Could not quote." and Buy sends no bet', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 100n * ETH);
    const t = Math.floor(Date.now() / 1000);
    const ms = [{ id: ID, d: 'Will the bridge open by Friday?', r: A.OTHER, a: A.ZERO, o: t - 60, c: t + 5 * 86400, y: ETH, n: ETH, p: 2n * ETH }];
    chain.answer(PM, 'ec979082', '0x' + u256(ms.length));
    chain.answer(PM, '80968d48', d => (BigInt('0x' + d.slice(10, 74)) === 0n ? marketsRet(ms) : marketsRet([])));
    chain.answer(PM, 'afa8f792', '0x' + u256(96) + u256(128) + u256(160) + u256(0) + u256(0) + u256(0));
    chain.answer(PM, 'ffecc085', '0x' + u256(0));
    chain.answer(PM, '4d5e9db0', '0x' + u256(0));
    // Both sides' quote calls fail inside the multicall, which hands the page a null for each.
    chain.revertOn(PM, '124d6efc');
    chain.answer(PM, 'c2b5b4c8', '0x' + u256(1));
    const p = await loadPage({ chain });
    await p.connect();
    p.click('mk');
    p.click(await p.waitFor(() => p.$('mkList').querySelector(`.mkr[data-k="${ID}"]`), { label: 'the market listed', ...SLOW }));
    await p.waitFor(() => !p.$('mkDet').classList.contains('hide'), { label: 'the detail', ...SLOW });

    p.type('mkAmt', '1');
    await p.waitFor(() => /Wins|Could not quote/.test(p.text('mkQ')), { label: 'the quote line', ...SLOW });
    assert.equal(p.text('mkQ'), 'Could not quote.');

    p.click(p.$('mkActs').querySelector('[data-a="yes"]'));
    await p.waitFor(() => p.text('stat') === 'Could not quote.' || chain.sentTo(PM).length,
      { label: 'Buy to answer', ...SLOW });
    await p.settle();
    assert.equal(p.text('stat'), 'Could not quote.');
    assert.equal(p.text('mkQ'), 'Could not quote.');
    assert.equal(chain.sentTo(PM).length, 0, 'no bet is sent');
    assert.equal(chain.batches.length, 0);
    p.close();
  });
});
