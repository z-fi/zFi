/**
 * Whose word a quote's calldata rests on.
 *
 * The quoter returns the calldata the wallet signs. When a connected wallet's
 * own node cannot run the quoter, the page asks the public pool instead, with
 * the account blinded; and a WalletConnect session reads everything through
 * the pool. In both cases one pool node alone must not be able to hand back a
 * route: two distinct nodes are asked the same pinned-block question, and the
 * answer is used only if they return the same bytes.
 *
 * Also pinned here: a wallet that wraps its node's failure the way MetaMask
 * does ({code:-32603, data:{message:"out of gas"}}) still falls back to the
 * blinded pool read.
 *
 * Run: node --test --test-concurrency=1 test/ui/quote-trust.test.mjs
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { A, SEL, MockChain, loadPage, closeAllPages, encodeQuote } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const ACCT = A.ACCOUNT.slice(2).toLowerCase();
const THIEF = 'ee'.repeat(20);

// A quoter whose route names the recipient it was asked about, as a real one
// does. A lying node names its own address instead.
const quoter = (seen, lie) => ({ selector, data }) => {
  if (seen) seen.push(data.toLowerCase());
  if (selector !== SEL.QUOTE) return null;
  const body = data.replace(/^0x/, '').slice(8);
  const recipient = body.slice(24, 64);
  const amountIn = BigInt('0x' + body.slice(5 * 64, 6 * 64));
  if (!amountIn) return null;
  return encodeQuote({ u: 4, legs: [{ source: 3, feeBps: 30n, amountIn, amountOut: amountIn * 3000n / 10n ** 12n }],
    callData: '0x' + SEL.MULTICALL + '00'.repeat(12) + (lie ? THIEF : recipient), msgValue: amountIn });
};
const node = lie => { const c = new MockChain(); c.setNative(A.ACCOUNT, 10n * ETH); c.quoteHandler = quoter(null, lie); return c; };

const verdict = p => p.waitFor(() => p.text('stat').length > 0 || p.value('outAmt') !== '', { label: 'a verdict' });

describe('a blinded quote from the pool', () => {
  const oog = () => { throw Object.assign(Error('out of gas: gas required exceeds allowance'), { code: -32003 }); };
  const setup = (lieB, walletFail = oog) => {
    const wallet = new MockChain();
    wallet.setNative(A.ACCOUNT, 10n * ETH);
    wallet.quoteHandler = walletFail;
    wallet.remotes = { publicnode: node(false), blastapi: node(lieB) };
    return wallet;
  };

  test('is not used when two pool nodes return different calldata', async () => {
    const wallet = setup(true);
    const p = await loadPage({ chain: wallet });
    await p.connect();
    await p.typeAmount('amt', '1');
    await verdict(p);
    await p.settle();
    assert.equal(p.value('outAmt'), '', 'a quote only one node vouched for was shown');
    const cd = await p.window.eval('last&&last.callData||""');
    assert.ok(!cd.toLowerCase().includes(THIEF), 'the lying node\'s route was kept');
    p.click('swap');
    await p.settle();
    assert.ok(!wallet.sent.some(t => JSON.stringify(t).toLowerCase().includes(THIEF)), 'the lying route was sent');
    assert.ok(!wallet.sent.some(t => (t.to || '').toLowerCase() === A.ZROUTER.toLowerCase()), 'a swap was sent');
    p.close();
  });

  test('is used when two pool nodes agree', async () => {
    const wallet = setup(false);
    const p = await loadPage({ chain: wallet });
    await p.connect();
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'an agreed quote was refused');
    const cd = await p.window.eval('last.callData');
    assert.ok(cd.toLowerCase().includes(ACCT), 'the route pays the real account');
    const hosts = new Set((wallet.httpLog || []).filter(r => r.method === 'eth_call').map(r => new URL(r.url).host));
    assert.ok(hosts.size >= 2, 'the quote was not asked of two nodes');
    p.close();
  });

  test('is reached when the wallet wraps its node\'s out-of-gas error', async () => {
    const wrapped = () => { throw Object.assign(Error('Internal JSON-RPC error.'),
      { code: -32603, data: { code: -32000, message: 'out of gas' } }); };
    const wallet = setup(false, wrapped);
    const p = await loadPage({ chain: wallet });
    await p.connect();
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'a wrapped node failure did not fall back to the pool');
    const cd = await p.window.eval('last.callData');
    assert.ok(cd.toLowerCase().includes(ACCT), 'the route pays the real account');
    p.close();
  });
});

// ---- WalletConnect: a real peer over a stand-in relay, as in wc-switch.
const subtle = webcrypto.subtle;
const hex = b => Buffer.from(b).toString('hex');
const unhex = h => new Uint8Array(Buffer.from(h, 'hex'));

async function wcPeer(p, account = A.ACCOUNT) {
  const w = p.window;
  Object.defineProperty(w.crypto, 'subtle', { value: subtle, configurable: true });
  const U = w.eval('WCU');
  const peer = { topics: new Set(), held: [], sock: null, sKey: null, sTopic: null };
  let rid = 1;
  const toPage = o => w.setTimeout(() => peer.sock?.onmessage?.({ data: JSON.stringify(o) }), 0);
  const deliver = (topic, message) =>
    toPage({ id: 9e15 + rid++, jsonrpc: '2.0', method: 'irn_subscription', params: { id: 's', data: { topic, message } } });
  const toSession = body => deliver(peer.sTopic, U.encode(peer.sKey, { jsonrpc: '2.0', ...body }));
  const onSession = async message => {
    const m = U.decode(peer.sKey, message);
    if (!m || m.method !== 'wc_sessionRequest') return;
    const { request } = m.params;
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
      namespaces: { eip155: { accounts: [`eip155:1:${account}`],
        methods: ['eth_sendTransaction', 'personal_sign', 'eth_signTypedData_v4'],
        events: ['chainChanged', 'accountsChanged'] } } } });
  };
  return peer;
}

async function connectWc(lieB) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = quoter(null, false);
  const p = await loadPage({ chain, walletless: true });
  const peer = await wcPeer(p);
  p.click('swap');
  await p.waitFor(() => [...p.$('wkList').querySelectorAll('.tkr')].some(r => r.textContent === 'WalletConnect'),
    { label: 'the wallet chooser' });
  p.click([...p.$('wkList').querySelectorAll('.tkr')].find(r => r.textContent === 'WalletConnect'));
  await p.waitFor(() => p.$('wkList').querySelector('.wcq'), { label: 'the pairing code' });
  p.click(p.$('wkList').querySelector('.wcn .fclink'));
  const uri = await p.waitFor(() => p.copied().find(u => /^wc:/.test(u)), { label: 'the pairing link' });
  await peer.scan(uri);
  await p.waitFor(() => /1111/.test(p.text('addr')), { label: 'the session to connect' });
  await p.settle();
  chain.remotes = { blastapi: node(lieB) };
  return { p, chain };
}

describe('a WalletConnect quote', () => {
  test('is not used when two pool nodes return different calldata', async () => {
    const { p, chain } = await connectWc(true);
    await p.typeAmount('amt', '1');
    await verdict(p);
    await p.settle();
    assert.equal(p.value('outAmt'), '', 'a quote only one node vouched for was shown');
    const cd = await p.window.eval('last&&last.callData||""');
    assert.ok(!cd.toLowerCase().includes(THIEF), 'the lying node\'s route was kept');
    assert.ok(!chain.sent.some(t => JSON.stringify(t).toLowerCase().includes(THIEF)), 'the lying route was sent');
    p.close();
  });

  test('is used when two pool nodes agree', async () => {
    const { p } = await connectWc(false);
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'an agreed quote was refused');
    const cd = await p.window.eval('last.callData');
    assert.ok(cd.toLowerCase().includes(ACCT), 'the route pays the real account');
    p.close();
  });
});
