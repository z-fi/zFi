/**
 * zSteward's queue page and the routing the list admin pages share, driven
 * through their real DOM against a mock chain.
 *
 * What has to hold: a queued change reads back as the call it will make, with
 * the status the chain gives it; landing it sends exactly the execute() that
 * matches the Queued event; and a write to a list zSteward owns is wrapped as
 * narrow() when it only removes and as queue() otherwise, while a list it does
 * not own is written directly as before.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';
import { Interface, AbiCoder } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const ROUTE = fs.readFileSync(path.join(ROOT, 'dapp/steward-route.js'), 'utf8');
const inline = html => html.replace('<script src="./steward-route.js"></script>', `<script>${ROUTE}</script>`);
const QUEUE_HTML = inline(fs.readFileSync(path.join(ROOT, 'dapp/steward-queue.html'), 'utf8'));
const STW = fs.readFileSync(path.join(ROOT, 'deploy/zSteward.address.txt'), 'utf8').trim().toLowerCase();

const RPCL = '0x8c7348d039f58c4e9cfa936ef410eec759213b12';
const EPS = '0x00000051f365d898132f4ebf345cd3968e02f288';
const SOLV = '0x1dfbb2f41b596f72187370469074c46de60da2e3';
const FLAGS = '0x0000008a1a3c78440d0a28ebb4bb5526aba91d45';
const STEWARD = '0x' + '5e'.repeat(20);
const GUARDIAN = '0x' + '6a'.repeat(20);
const EOA = '0x1c0aa8ccd568d90d61659f060d1bfb1e6f855a20';
const DELAY = 259200n, GRACE = 1209600n, NOW = 2_000_000_000n;
const FROM = 26098664;

const coder = AbiCoder.defaultAbiCoder();
const ST = new Interface([
  'function accept(address)', 'function queue(address,bytes) returns (bytes32)',
  'function execute(address,bytes,uint256)', 'function cancel(bytes32)', 'function narrow(address,bytes)',
  'function narrows(bytes) pure returns (bool)',
  'event Queued(bytes32 indexed id, address indexed target, bytes data, uint256 nonce, uint256 eta)',
  'event Executed(bytes32 indexed id)', 'event Cancelled(bytes32 indexed id)', 'event Narrowed(address indexed target, bytes data)',
]);
const LISTS = new Interface([
  'function add(string)', 'function remove(uint256)', 'function pop()',
  'function add(bytes32,uint256,string)', 'function remove(bytes32,uint256,uint256)',
  'function setEnabled(uint256,bool)', 'function set(bytes32,uint256,uint8)', 'function acceptOwnership()',
]);
const b32 = s => '0x' + Buffer.from(s, 'ascii').toString('hex').padEnd(64, '0');
const enc = (sig, args) => LISTS.encodeFunctionData(sig, args);
const id = n => '0x' + (n + 1).toString(16).padStart(64, '0');

/* zSteward.narrows, as the contract defines it. */
const narrows = d => {
  const s = d.slice(2, 10), n = (d.length - 2) / 2, w = i => BigInt('0x' + d.slice(10 + i * 64, 74 + i * 64));
  return s === '4cc82215' ? n === 36 : s === 'a4ece52c' ? n === 4 : s === 'aceba3fd' ? n === 100 : s === 'b87e183d' ? n === 68
    : s === 'e5c13dd1' ? n === 68 && w(1) === 0n : s === '97f10dcd' ? n === 100 && w(2) === 2n : false;
};

const OPS = [
  { target: RPCL, data: enc('add(string)', ['https://new.example']), eta: NOW - 10n },                 // due
  { target: EPS, data: enc('add(bytes32,uint256,string)', [b32('rpc'), 8453, 'https://x.example']), eta: NOW + 3600n }, // waiting
  { target: SOLV, data: enc('setEnabled(uint256,bool)', [0, true]), eta: NOW - 100n, done: 'Executed' },
  { target: FLAGS, data: enc('set(bytes32,uint256,uint8)', [b32('bridge'), 8453, 1]), eta: NOW + 9n, done: 'Cancelled' },
  { target: RPCL, data: enc('add(string)', ['https://old.example']), eta: NOW - GRACE - 100n },       // lapsed
];
const log = (ev, args, n) => { const l = ST.encodeEventLog(ST.getEvent(ev), args); return { ...l, address: STW, transactionHash: '0x' + (0xa0 + n).toString(16).padStart(64, '0') }; };
const LOGS = [
  ...OPS.flatMap((o, n) => [log('Queued', [id(n), o.target, o.data, n, o.eta], n), ...(o.done ? [log(o.done, [id(n)], n + 10)] : [])]),
  log('Narrowed', [RPCL, enc('remove(uint256)', [0])], 20),
];
const OWNERS = { [RPCL]: [STW, 0], [EPS]: [EOA, STW], [SOLV]: [EOA, 0], [FLAGS]: [EOA, 0] };
const word = v => '0x' + BigInt(v).toString(16).padStart(64, '0');
const addr = a => word(a === 0 ? 0 : BigInt(a));

function chainFetch(seen = []) {
  return async (_url, init) => {
    const req = JSON.parse(init.body), ok = result => ({ ok: true, json: async () => ({ jsonrpc: '2.0', id: req.id, result }) });
    seen.push(req);
    if (req.method === 'eth_getCode') return ok('0x6000');
    if (req.method === 'eth_blockNumber') return ok('0x' + (FROM + 10).toString(16));
    if (req.method === 'eth_getBlockByNumber') return ok({ timestamp: '0x' + NOW.toString(16) });
    if (req.method === 'eth_getLogs') return ok(LOGS);
    const { to, data } = req.params[0], t = to.toLowerCase(), sel = data.slice(2, 10);
    if (t === STW) {
      if (sel === '69b41170') return ok(word(DELAY));
      if (sel === '137d29d9') return ok(word(GRACE));
      if (sel === '637eea19') return ok(addr(STEWARD));
      if (sel === '452a9320') return ok(addr(GUARDIAN));
      if (sel === 'ae1f986e') return ok(word(narrows(coder.decode(['bytes'], '0x' + data.slice(10))[0]) ? 1 : 0));
    }
    if (OWNERS[t] && sel === '8da5cb5b') return ok(addr(OWNERS[t][0]));
    if (OWNERS[t] && sel === 'e30c3978') return ok(addr(OWNERS[t][1]));
    throw Error('unhandled ' + t + ' ' + sel);
  };
}

/* A wallet that records what it is asked to send and mines it at once. */
function wallet(account, sent) {
  return {
    request: async ({ method, params }) => {
      if (method === 'eth_requestAccounts') return [account];
      if (method === 'eth_chainId') return '0x1';
      if (method === 'eth_call') return '0x';
      if (method === 'eth_sendTransaction') { sent.push(params[0]); return '0x' + 'cd'.repeat(32); }
      if (method === 'eth_getTransactionReceipt') return { status: '0x1' };
      throw Error('wallet: ' + method);
    },
  };
}

function open(html, { account, sent = [], seen = [] } = {}) {
  const dom = new JSDOM(html, {
    runScripts: 'dangerously', url: 'https://zfi.wei.is/dapp/steward-queue.html',
    beforeParse(w) {
      w.fetch = chainFetch(seen);
      w.TextEncoder = TextEncoder; w.TextDecoder = TextDecoder;
      w.confirm = () => true;
      if (account) w.ethereum = wallet(account, sent);
    },
  });
  return dom.window;
}
const settle = async (n = 40) => { for (let i = 0; i < n; i++) await new Promise(r => setTimeout(r, 0)); };
const text = (w, sel) => w.document.querySelector(sel).textContent;

describe('steward-queue.html', () => {
  test('every queued change reads back as its call, with the status the chain gives it', async () => {
    const w = open(QUEUE_HTML);
    await settle();
    const ops = [...w.document.querySelectorAll('#ops .op')].map(e => e.textContent);
    assert.equal(ops.length, 5);
    const has = (call, status) => assert.ok(ops.some(t => t.includes(call) && t.includes(status)), `${call} · ${status}\n${ops.join('\n')}`);
    has('zRpcList.add("https://new.example")', 'due — anyone can land it');
    has('zEndpoints.add("rpc", 8453, "https://x.example")', 'waiting · due in 1h');
    has('zSolverList.setEnabled(0, true)', 'landed');
    has('zSwapFlags.set("bridge", 8453, 1)', 'cancelled');
    has('zRpcList.add("https://old.example")', 'lapsed');
    assert.ok(text(w, '#narrows').includes('zRpcList.remove(0)'));
    assert.equal(text(w, '#delay'), '3d');
    assert.equal(text(w, '#steward'), STEWARD);
  });

  test('the lists show who holds them and whether zSwap follows them', async () => {
    const w = open(QUEUE_HTML);
    await settle();
    const rows = Object.fromEntries([...w.document.querySelectorAll('#lists tr')].map(r => [r.querySelector('b').textContent, r.textContent]));
    assert.match(rows.zRpcList, /additions wait the delay/);
    assert.match(rows.zEndpoints, /offered to zSteward, not yet accepted/);
    assert.match(rows.zSolverList, /apply at once/);
  });

  test('anyone lands a due change, with exactly the execute() its Queued event names', async () => {
    const sent = [];
    const w = open(QUEUE_HTML, { account: '0x' + '77'.repeat(20), sent });
    await settle();
    w.document.getElementById('connect').click();
    await settle();
    const land = [...w.document.querySelectorAll('#ops button')].filter(b => b.textContent === 'Land it');
    assert.equal(land.length, 1, 'only the due change can be landed');
    assert.ok(![...w.document.querySelectorAll('#ops button')].some(b => b.textContent === 'Cancel'), 'a stranger cannot cancel');
    assert.ok([...w.document.querySelectorAll('#lists button')].some(b => b.textContent === 'Accept'), 'but can complete an offered handover');
    land[0].click();
    await settle();
    assert.equal(sent.length, 1);
    assert.equal(sent[0].to.toLowerCase(), STW);
    const [target, data, n] = ST.decodeFunctionData('execute', sent[0].data);
    assert.deepEqual([target.toLowerCase(), data, n], [RPCL, OPS[0].data, 0n]);
  });

  test('anyone accepts an offered list; the steward cancels and removes at once', async () => {
    const sent = [];
    const w = open(QUEUE_HTML, { account: STEWARD, sent });
    await settle();
    w.document.getElementById('connect').click();
    await settle();
    const accept = [...w.document.querySelectorAll('#lists button')].find(b => b.textContent === 'Accept');
    assert.ok(accept, 'zEndpoints was offered, so it can be accepted');
    accept.click();
    await settle();
    assert.equal(sent.at(-1).to.toLowerCase(), STW);
    assert.equal(ST.decodeFunctionData('accept', sent.at(-1).data)[0].toLowerCase(), EPS);
    let target, data;

    const cancels = [...w.document.querySelectorAll('#ops button')].filter(b => b.textContent === 'Cancel');
    assert.equal(cancels.length, 2, 'the waiting and the due change, newest first');
    cancels[0].click();
    await settle();
    assert.deepEqual([...ST.decodeFunctionData('cancel', sent.at(-1).data)], [id(1)]);

    w.document.getElementById('target').value = w.document.querySelector('#target option').value;
    const ta = w.document.getElementById('calldata');
    ta.value = enc('remove(uint256)', [1]);
    ta.oninput();
    await settle();
    assert.match(text(w, '#preview'), /zRpcList\.remove\(1\).*applies at once/);
    assert.equal(w.document.getElementById('submit').textContent, 'Remove now');
    w.document.getElementById('submit').click();
    await settle();
    [target, data] = ST.decodeFunctionData('narrow', sent.at(-1).data);
    assert.deepEqual([target.toLowerCase(), data], [RPCL, enc('remove(uint256)', [1])]);

    ta.value = enc('add(string)', ['https://more.example']);
    ta.oninput();
    await settle();
    assert.match(text(w, '#preview'), /queued for 3d/);
    w.document.getElementById('submit').click();
    await settle();
    [target, data] = ST.decodeFunctionData('queue', sent.at(-1).data);
    assert.deepEqual([target.toLowerCase(), data], [RPCL, enc('add(string)', ['https://more.example'])]);
  });
});

describe('steward-route.js', () => {
  const route = () => {
    const w = new JSDOM(`<script>${ROUTE}</script>`, { runScripts: 'dangerously', beforeParse(w) { w.fetch = chainFetch(); } }).window;
    return w.zSteward;
  };

  test('a list zSteward does not own is written directly', async () => {
    const z = route(), data = enc('add(string)', ['https://a.example']);
    assert.deepEqual({ ...await z.route(RPCL, data, EOA) }, { to: RPCL, data, note: '' });
    assert.equal(await z.may(EOA, EOA), true);
    assert.equal(await z.may(STEWARD, EOA), false);
  });

  test('under zSteward an addition is queued and a removal applies at once', async () => {
    const z = route();
    const add = enc('add(bytes32,uint256,string)', [b32('rpc'), 8453, 'https://a.example']);
    let r = await z.route(EPS, add, STW);
    assert.equal(r.to.toLowerCase(), STW);
    assert.deepEqual(ST.decodeFunctionData('queue', r.data).map(x => typeof x === 'string' ? x.toLowerCase() : x), [EPS, add]);
    assert.match(r.note, /Queued in zSteward\. It can land 72 h/);
    const rm = enc('remove(bytes32,uint256,uint256)', [b32('rpc'), 8453, 0]);
    r = await z.route(EPS, rm, STW);
    assert.deepEqual(ST.decodeFunctionData('narrow', r.data).map(x => typeof x === 'string' ? x.toLowerCase() : x), [EPS, rm]);
    const off = enc('set(bytes32,uint256,uint8)', [b32('bridge'), 0, 2]);
    assert.equal(ST.decodeFunctionData('narrow', (await z.route(FLAGS, off, STW)).data)[1], off);
    assert.equal(await z.may(STEWARD, STW), true);
    assert.equal(await z.may(EOA, STW), false, 'the old owner has no say once zSteward holds the list');
  });

  test('accepting an offer is never wrapped', async () => {
    const z = route(), data = enc('acceptOwnership()', []);
    assert.deepEqual({ ...await z.route(FLAGS, data, STW) }, { to: FLAGS, data, note: '' });
  });
});
