/**
 * Switching networks under WalletConnect.
 *
 * A WalletConnect v2 request names its chain in its own envelope, so a session
 * that approved the account on several chains already reaches all of them: a
 * switch is the page choosing which chain it aims at, not a request to the
 * phone. The page cannot restore a WalletConnect session after a reload (the
 * relay socket and its keys live in memory), so a switch must happen in place.
 *
 * The wallet here is a real WalletConnect peer: it reads the pairing link the
 * page offers, answers the proposal with its own X25519 key, derives the same
 * session key and settles a session over a stand-in relay socket. Every request
 * the page sends reaches it encrypted, carrying the chainId the page chose.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { A, MockChain, loadPage, closeAllPages, selectorOf } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const subtle = webcrypto.subtle;
const hex = b => Buffer.from(b).toString('hex');
const unhex = h => new Uint8Array(Buffer.from(h, 'hex'));
const WETH_BASE = '0x4200000000000000000000000000000000000006';

async function wcPeer(p, { chains = [1, 8453], account = A.ACCOUNT } = {}) {
  const w = p.window;
  Object.defineProperty(w.crypto, 'subtle', { value: subtle, configurable: true });
  const U = w.eval('WCU');
  const peer = { requests: [], topics: new Set(), held: [], sock: null, sKey: null, sTopic: null };
  let rid = 1;
  const toPage = o => w.setTimeout(() => peer.sock?.onmessage?.({ data: JSON.stringify(o) }), 0);
  const deliver = (topic, message) =>
    toPage({ id: 9e15 + rid++, jsonrpc: '2.0', method: 'irn_subscription', params: { id: 's', data: { topic, message } } });
  const toSession = body => deliver(peer.sTopic, U.encode(peer.sKey, { jsonrpc: '2.0', ...body }));
  peer.accounts = cs => cs.map(c => `eip155:${c}:${account}`);

  const onSession = async message => {
    const m = U.decode(peer.sKey, message);
    if (m?.method) (peer.seen ||= []).push(m.method);
    if (!m || m.method !== 'wc_sessionRequest') return;
    const { request, chainId } = m.params;
    peer.requests.push({ method: request.method, chainId, params: request.params });
    if (peer.hold && request.method === 'eth_sendTransaction') await peer.hold;
    let result, error = null;
    try { result = await p.chain.request({ method: request.method, params: request.params }); }
    catch (e) { error = { code: e.code ?? -32000, message: e.message }; }
    toSession(error ? { id: m.id, error } : { id: m.id, result });
  };

  class RelaySocket {
    constructor() { peer.sock = this; peer.opens = (peer.opens || 0) + 1; w.setTimeout(() => this.onopen?.(), 0); }
    close() {}
    send(raw) {
      const m = JSON.parse(raw);
      if (!m.method) return;
      toPage({ id: m.id, jsonrpc: '2.0', result: m.method === 'irn_subscribe' ? 'sub' : true });
      if (m.method === 'irn_subscribe') { peer.topics.add(m.params.topic); (peer.subs ||= []).push(m.params.topic); }
      if (m.method !== 'irn_publish') return;
      if (m.params.topic === peer.sTopic) onSession(m.params.message);
      else peer.held.push(m.params);
    }
  }
  w.WebSocket = RelaySocket;

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
      namespaces: { eip155: { accounts: peer.accounts(chains),
        methods: ['eth_sendTransaction', 'personal_sign', 'eth_signTypedData_v4'],
        events: ['chainChanged', 'accountsChanged'] } } } });
  };
  peer.send = toSession;
  peer.event = (name, data) => toSession({ id: rid++, method: 'wc_sessionEvent',
    params: { chainId: 'eip155:1', event: { name, data } } });
  peer.update = cs => toSession({ id: rid++, method: 'wc_sessionUpdate',
    params: { namespaces: { eip155: { accounts: peer.accounts(cs),
      methods: ['eth_sendTransaction'], events: ['chainChanged', 'accountsChanged'] } } } });
  return peer;
}

async function connectWc(opts = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  const p = await loadPage({ chain, walletless: true });
  const peer = await wcPeer(p, opts);
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
  return { p, peer };
}

const pickNet = async (p, name) => {
  p.click('net');
  await p.settle();
  const row = [...p.$('wkList').querySelectorAll('.tkr')].find(r => r.textContent === name);
  assert.ok(row, `no ${name} row`);
  p.click(row);
};

// A relay that answers every call and delivers nothing, installed before the
// page runs so a session it resumes at load has somewhere to go.
const quietRelay = log => w => {
  Object.defineProperty(w.crypto, 'subtle', { value: subtle, configurable: true });
  w.WebSocket = class {
    constructor() { w.setTimeout(() => this.onopen?.(), 0); }
    close() {}
    send(raw) {
      const m = JSON.parse(raw);
      if (!m.method) return;
      if (m.method === 'irn_subscribe') log.push(m.params.topic);
      if (m.method === 'irn_publish') (log.published ||= []).push(m.params);
      w.setTimeout(() => this.onmessage?.({ data: JSON.stringify({ id: m.id, jsonrpc: '2.0', result: true }) }), 0);
    }
  };
};

/**
 * The session's keys used to live only in memory, so every refresh - and every
 * reload a chain or account change forces - meant scanning a new code. The
 * session is kept until it expires or either side ends it.
 */
describe('a WalletConnect session across a reload', () => {
  test('is kept when it settles, and resumed at load without a new pairing', async () => {
    const { p } = await connectWc();
    const saved = p.window.localStorage.getItem('zswap:wcs');
    assert.ok(JSON.parse(saved || 'null')?.t, 'the settled session is kept');
    assert.equal(p.window.localStorage.getItem('zswap:wk'), 'wc');
    const topic = JSON.parse(saved).t;
    p.close();

    const subs = [];
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const q = await loadPage({ chain, walletless: true, hash: null,
      storage: { 'zswap:wcs': saved, 'zswap:wk': 'wc' }, beforeParse: quietRelay(subs) });
    await q.waitFor(() => /1111/.test(q.text('addr')), { label: 'the resumed session' });
    assert.ok(subs.includes(topic), 'the page listens on the kept session topic');
    assert.ok(q.$('wkWrap').classList.contains('hide'), 'no pairing code was needed');
    q.window.eval(`rpc("personal_sign",["0x00","${A.ACCOUNT}"]).catch(()=>{})`);
    const pub = await q.waitFor(() => (subs.published || []).find(x => x.topic === topic), { label: 'a request on the session' });
    const U = q.window.eval('WCU');
    const body = U.decode(U.unhex(JSON.parse(saved).k), pub.message);
    assert.equal(body?.params?.request?.method, 'personal_sign', 'the kept key still speaks to the wallet');
    q.close();
  });

  test('an expired session is dropped, not resumed', async () => {
    const subs = [];
    const expired = JSON.stringify({ t: 'ab'.repeat(32), k: 'cd'.repeat(32), a: [`eip155:1:${A.ACCOUNT}`],
      m: ['eth_sendTransaction'], c: 1, x: Math.floor(Date.now() / 1e3) - 60 });
    const q = await loadPage({ chain: new MockChain(), walletless: true, hash: null,
      storage: { 'zswap:wcs': expired, 'zswap:wk': 'wc' }, beforeParse: quietRelay(subs) });
    await q.settle();
    assert.equal(q.text('addr'), 'Connect');
    assert.equal(subs.length, 0, 'nothing was asked of the relay');
    assert.equal(q.window.localStorage.getItem('zswap:wcs'), null, 'and the stale keys are gone');
    q.close();
  });

  test('the wallet ending the session forgets it', async () => {
    const { p, peer } = await connectWc();
    peer.send({ id: 77, method: 'wc_sessionDelete', params: { code: 6000, message: 'bye' } });
    await p.waitFor(() => /ended the session/.test(p.text('stat')), { label: 'the session end' });
    assert.equal(p.window.localStorage.getItem('zswap:wcs'), null);
    await p.waitFor(() => p.reloads() > 0, { label: 'the page to drop the dead account' });
    p.close();
  });

  test('a dropped relay socket reconnects and listens again, keeping the session', async () => {
    const { p, peer } = await connectWc();
    const topic = peer.sTopic;
    const before = peer.subs.filter(t => t === topic).length;
    peer.sock.onclose?.({ code: 1006 });
    await p.waitFor(() => peer.opens === 2 && peer.subs.filter(t => t === topic).length > before,
      { label: 'the relay to come back', timeout: 5000 });
    await p.settle();
    assert.doesNotMatch(p.text('stat'), /dropped/);
    assert.match(p.text('addr'), /1111/);
    p.close();
  });
});

describe('ending a WalletConnect session', () => {
  test('disconnecting forgets the kept session', async () => {
    const { p } = await connectWc();
    p.queueConfirm(true);
    p.click('addr');
    await p.waitFor(() => p.reloads() > 0, { label: 'the reload' });
    assert.equal(p.window.localStorage.getItem('zswap:wcs'), null);
    p.close();
  });

  // The session lives in the page's memory, so a disconnect that only reloads
  // leaves the wallet listing a connection nothing will ever answer again.
  test('disconnecting tells the wallet the session is over', async () => {
    const { p, peer } = await connectWc();
    p.queueConfirm(true);
    p.click('addr');
    await p.waitFor(() => p.reloads() > 0, { label: 'the reload' });
    assert.ok((peer.seen || []).includes('wc_sessionDelete'), 'the wallet must hear the session end');
    p.close();
  });
});

describe('a WalletConnect network switch', () => {
  test('moves the page and the session in place, and the next send is aimed at the new chain', async () => {
    const { p, peer } = await connectWc();
    assert.equal(p.window.eval('CHAIN_ID'), 1);
    p.window.eval('fcMineToks=["0x00000000000000000000000000000000000000aa"]');
    await pickNet(p, 'Base');
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 8453 && !p.window.eval('switchNet.busy'), { label: 'the switch' });
    await p.settle();
    assert.equal(p.reloads(), 0, 'a reload would end the WalletConnect session');
    assert.match(p.text('addr'), /1111/, 'still connected');
    assert.match(p.text('net'), /Base network/);
    assert.equal(p.window.eval('walletChain'), 8453);
    assert.equal(p.window.eval('offChain()'), false, 'the page does not tell the user to switch the wallet');
    assert.ok(!peer.requests.some(r => r.method === 'wallet_switchEthereumChain'),
      'no switch prompt reaches the phone: the request envelope carries the chain');
    assert.match(p.window.location.hash, /chain=8453/, 'the link names the chain now in force');
    assert.equal(p.window.eval('WETH').toLowerCase(), WETH_BASE);
    assert.ok(p.window.eval('TOKENS.some(t=>t.addr==="0x833589fcd6edb6e08f4c7c32d4f71b54bda02913")'),
      'the token list is Base\'s');
    assert.equal(p.window.eval('[...fromSel.options].every((o,i)=>o.textContent===TOKENS[i]?.sym||o.value==="__custom")'), true,
      'the pickers are rebuilt over the new list');
    assert.equal(p.window.eval('fcMineToks.length'), 0, 'no creator-fee claim is carried over from the chain just left');

    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'WETH');
    await p.settle();
    await p.typeAmount('amt', '1');
    p.click('swap');
    await p.waitFor(() => peer.requests.some(r => r.method === 'eth_sendTransaction') || /Error|Switch/.test(p.text('stat')),
      { label: 'the send' });
    const sent = peer.requests.find(r => r.method === 'eth_sendTransaction');
    assert.ok(sent, `nothing was sent (${p.text('stat')})`);
    assert.equal(sent.chainId, 'eip155:8453', 'the wallet is asked to sign on Base');
    assert.equal(sent.params[0].to.toLowerCase(), WETH_BASE, 'against Base\'s WETH');
    assert.equal(selectorOf(sent.params[0].data), 'd0e30db0');
    p.close();
  });

  test('while a send waits on the wallet, the page keeps the chain it was built for', async () => {
    const { p, peer } = await connectWc();
    let release;
    peer.hold = new Promise(r => { release = r; });
    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'WETH');
    await p.settle();
    await p.typeAmount('amt', '1');
    p.click('swap');
    await p.waitFor(() => peer.requests.some(r => r.method === 'eth_sendTransaction'), { label: 'the send to reach the wallet' });
    await pickNet(p, 'Base');
    await p.waitFor(() => /in progress/.test(p.text('stat')), { label: 'the refusal' });
    assert.match(p.text('stat'), /Still on Ethereum/);
    assert.equal(p.window.eval('CHAIN_ID'), 1, 'the page stays on the chain the send was built for');
    assert.equal(p.window.eval('walletChain'), 1);
    peer.event('chainChanged', 'eip155:8453');
    await p.settle();
    await new Promise(r => setTimeout(r, 30));
    assert.equal(p.window.eval('CHAIN_ID'), 1, 'nor does the wallet\'s own chainChanged move it mid-send');
    release();
    await p.waitFor(() => /Done/.test(p.text('stat')), { label: 'the send to settle' });
    assert.equal(peer.requests.find(r => r.method === 'eth_sendTransaction').chainId, 'eip155:1');
    await pickNet(p, 'Base');
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 8453 && !p.window.eval('switchNet.busy'), { label: 'the switch' });
    assert.equal(p.reloads(), 0);
    p.close();
  });

  test('on the Orders tab, the book is read again from the new chain\'s boards', async () => {
    const { p } = await connectWc();
    const w = p.window;
    p.click('tabBook');
    await p.settle();
    const mainSb = w.eval('MB.sb').toLowerCase(), baseSb = w.eval('L2B.sb').toLowerCase();
    const seen = [];
    const inner = p.chain.request.bind(p.chain);
    p.chain.request = async a => { seen.push(JSON.stringify(a.params || []).toLowerCase()); return inner(a); };
    await pickNet(p, 'Base');
    await p.waitFor(() => w.eval('CHAIN_ID') === 8453 && !w.eval('switchNet.busy'), { label: 'the switch' });
    await p.settle();
    assert.equal(w.eval('tab'), 'book', 'the tab in use is kept');
    assert.ok(seen.some(s => s.includes(baseSb.slice(2))), 'Base\'s board is read');
    assert.ok(!p.$('book').innerHTML.toLowerCase().includes(mainSb.slice(2)), 'no mainnet board is left on screen');
    assert.equal(w.eval('bookRows.every(r=>BOARDS().some(b=>b.a.toLowerCase()===String(r.board).toLowerCase()))'), true,
      'every row the book can act on belongs to a Base board');
    assert.equal(p.reloads(), 0);
    p.close();
  });

  test('refuses a chain the session never approved, plainly, and stays put', async () => {
    const { p, peer } = await connectWc({ chains: [1] });
    const before = peer.requests.length;
    await pickNet(p, 'Robinhood');
    await p.waitFor(() => /approved/.test(p.text('stat')), { label: 'the refusal' });
    assert.match(p.text('stat'), /Still on Ethereum/);
    assert.match(p.text('stat'), /not approved Robinhood/);
    assert.equal(p.window.eval('CHAIN_ID'), 1, 'the page stays on the chain the session covers');
    assert.equal(p.window.eval('switchNet.busy'), false);
    assert.equal(p.reloads(), 0);
    assert.match(p.text('addr'), /1111/);
    assert.equal(peer.requests.length, before, 'nothing is asked of the wallet');
    p.close();
  });

  test('follows the wallet\'s own chainChanged in place, and ignores a chain the page does not serve', async () => {
    const { p, peer } = await connectWc();
    peer.event('chainChanged', 'eip155:8453');
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 8453 && !p.window.eval('switchNet.busy'), { label: 'the follow' });
    await p.settle();
    assert.equal(p.reloads(), 0, 'the session survives the wallet changing chain');
    assert.match(p.text('addr'), /1111/);

    peer.event('chainChanged', '0x89');
    await p.settle();
    await new Promise(r => setTimeout(r, 30));
    assert.equal(p.window.eval('CHAIN_ID'), 8453, 'an unserved chain moves nothing');
    assert.equal(p.reloads(), 0);
    assert.equal(p.window.eval('offChain()'), false);
    const before = peer.requests.length;
    await p.window.eval('rpc("personal_sign",["0x00","0x1111111111111111111111111111111111111111"])');
    assert.equal(peer.requests[before].chainId, 'eip155:8453', 'requests stay aimed at the page\'s chain');
    p.close();
  });

  test('a session update that keeps the account adds its chains without a reload', async () => {
    const { p, peer } = await connectWc({ chains: [1] });
    peer.update([1, 4663]);
    await new Promise(r => setTimeout(r, 30));
    await p.settle();
    assert.equal(p.reloads(), 0, 'the account in use is still approved, so the session stays');
    await pickNet(p, 'Robinhood');
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 4663 && !p.window.eval('switchNet.busy'), { label: 'the switch' });
    assert.equal(p.reloads(), 0);

    peer.update([1]);
    await p.waitFor(() => p.reloads() === 1, { label: 'the reload' });
    p.close();
  });
});
