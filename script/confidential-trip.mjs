#!/usr/bin/env node
/**
 * Drive zSwap's private-bridge panel against mainnet from a terminal.
 *
 * The page cannot reach Tacit's relay from a browser until that relay's CORS
 * change is deployed, but nothing stops a terminal. This script loads the
 * page's OWN private-bridge module out of zSwap.html - not a copy of it - and
 * runs it with a real signer and a real node, so a round trip here exercises
 * exactly the bytes that are on chain: the note derivation, the recipe, the
 * escrow parity check, the dry run, the relay calls, the activation.
 *
 * Every write is real ether. Keep the amounts small.
 *
 *   PRIVATE_KEY=0x… [ETH_RPC_URL=…] node script/confidential-trip.mjs <command>
 *
 *   plan                              address, balance, pool size, live pins
 *   status                            every note this key holds and what it is doing
 *   deposit --amount 0.003 [--notes 2] wrapETH, then wait for the relay to settle
 *   exit --note 0 --chain 8453|4663|1 [--to 0x…] [--self]
 *                                     bridge to Base / Robinhood, or withdraw (chain 1);
 *                                     waits for the relay and, for an L2, activates
 *   settle --note 0 [--self]          (re)submit a deposit's settle to the relay and wait; --self has the
 *                                     relay prove only and sends pool.settle from this wallet
 *   activate --note 0                 fire a funded exit's bridge call
 *   reclaim --note 0                  post-deadline rescue
 *   request --amount 0.003            print a payment request for this key
 *   pay --file request.json [--self]  pay someone's request (--self: relay proves, this wallet settles)
 *   recover                           rebuild notes from the pool's Wrap events
 *
 * State (notes, the derived key) lives in ~/.local/state/zswap/trip-<address>.json,
 * the same records the page keeps in localStorage. The key is derived from a
 * signature exactly as the page does it, so a browser with the same wallet
 * sees the same notes.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { JsonRpcProvider, Wallet, getBytes, AbiCoder } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const html = fs.readFileSync(path.join(ROOT, 'zSwap.html'), 'utf8');

const argv = process.argv.slice(2);
const cmd = argv[0];
const arg = (k, d) => { const i = argv.indexOf('--' + k); return i > -1 ? argv[i + 1] : d; };
const flag = (k) => argv.includes('--' + k);
const die = (m) => { console.error('error: ' + m); process.exit(1); };
if (!cmd) die('usage: node script/confidential-trip.mjs <plan|status|deposit|exit|activate|reclaim|request|pay|recover>');

const pk = process.env.PRIVATE_KEY;
if (!pk) die('PRIVATE_KEY is not set. Export it in your shell; it is never read from anywhere else.');
const RPC = process.env.ETH_RPC_URL || 'https://ethereum-rpc.publicnode.com';
const provider = new JsonRpcProvider(RPC, 1, { staticNetwork: true });
const wallet = new Wallet(pk, provider);
const account = wallet.address.toLowerCase();

// ---- the page's helpers, sliced out of the page itself ----
const slice = (from, to, what) => {
  const a = html.indexOf(from); if (a < 0) die(`page slice not found: ${what}`);
  const b = html.indexOf(to, a); if (b < 0) die(`page slice end not found: ${what}`);
  return html.slice(a, b + to.length);
};
const line = (re, what) => { const m = html.match(re); if (!m) die(`page line not found: ${what}`); return m[0]; };
const helpers = [
  line(/^const ZERO="0x0{40}";$/m, 'ZERO'),
  line(/^const C="eth_call",S="eth_sendTransaction",L="latest",I="eth_chainId";$/m, 'rpc constants'),
  html.slice(html.indexOf('const strip0x='), html.indexOf('\n', html.indexOf('const trimAmt='))),
  slice('const hexToBytes=', 'return "0x"+out};', 'keccak'),
  slice('const retAddr=', 'return /^0x0{40}$/.test(a)?"":a};', 'retAddr'),
  line(/^const encBytes=.*$/m, 'encBytes'),
].join('\n');
const moduleSrc = slice('const cpHex=', 'pv.onclick=()=>{sBlip();pvSet(!pvMode)};', 'private-bridge module');

// ---- state: what the page keeps in localStorage ----
const STATE_DIR = path.join(os.homedir(), '.local', 'state', 'zswap');
const STATE = path.join(STATE_DIR, `trip-${account}.json`);
let store = {};
try { store = JSON.parse(fs.readFileSync(STATE, 'utf8')); } catch { store = {}; }
const persist = () => { fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 }); fs.writeFileSync(STATE, JSON.stringify(store, null, 1), { mode: 0o600 }); };
const LS = new Proxy(store, {
  get: (t, k) => t[k],
  set: (t, k, v) => { t[k] = String(v); persist(); return true; },
  deleteProperty: (t, k) => { delete t[k]; persist(); return true; },
});

// ---- the page's environment, real where it matters ----
const el = (extra = {}) => ({
  value: '', textContent: '', innerHTML: '', disabled: false, placeholder: '',
  classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
  setAttribute() {}, ...extra,
});
const stat = el();
Object.defineProperty(stat, 'textContent', { set(v) { if (v) console.log('  ' + v); }, get() { return ''; } });
Object.defineProperty(stat, 'innerHTML', { set(v) { if (v) console.log('  ' + String(v).replace(/<[^>]+>/g, '')); }, get() { return ''; } });
const pvNote = el();
Object.defineProperty(pvNote, 'textContent', { set(v) { if (v) console.log('  note: ' + v); }, get() { return ''; } });
const prompts = [];
let fromBalance = 0n, lastNonce = -1;

async function jsonRpc(url, method, params) {
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ id: 1, jsonrpc: '2.0', method, params: params || [] }) });
  if (!r.ok) throw Object.assign(Error('a read node answered ' + r.status), { retry: 1 });
  const j = await r.json();
  if (j && j.error) throw Object.assign(Error(j.error.message || 'the read node refused'), { code: j.error.code, retry: 1 });
  return j ? j.result : null;
}
async function rpc(method, params) {
  params = params || [];
  if (method === 'eth_chainId') return '0x1';
  if (method === 'eth_accounts' || method === 'eth_requestAccounts') return [account];
  if (method === 'personal_sign') return wallet.signMessage(getBytes(params[0]));
  if (method === 'eth_sendTransaction') {
    const q = params[0];
    const tx = { to: q.to, value: q.value ? BigInt(q.value) : 0n, data: q.data || '0x' };
    tx.gasLimit = q.gas ? BigInt(q.gas) : (await provider.estimateGas({ ...tx, from: account })) * 12n / 10n;
    // A real tip: this key is shared with other senders, and a transaction that idles in the mempool
    // gets its nonce taken from under it. Mine in the next block or two instead.
    const fd = await provider.getFeeData();
    const tip = (fd.maxPriorityFeePerGas || 0n) > 500000000n ? fd.maxPriorityFeePerGas : 500000000n;
    tx.maxPriorityFeePerGas = tip; tx.maxFeePerGas = ((fd.maxFeePerGas || 0n) - (fd.maxPriorityFeePerGas || 0n)) + tip;
    tx.nonce = await provider.getTransactionCount(account, 'pending');
    const sent = await wallet.sendTransaction(tx);
    lastNonce = sent.nonce;
    console.log(`  tx ${sent.hash} (gas limit ${tx.gasLimit})`);
    return sent.hash;
  }
  return provider.send(method, params);
}
const sandbox = {
  console, TextEncoder, TextDecoder, crypto: webcrypto, AbortController, setTimeout, clearTimeout, setInterval: () => 0, clearInterval() {},
  fetch, LS, account, get fromBalance() { return fromBalance; },
  rpc, cfgRead: rpc, httpRead: jsonRpc,
  sendTx: (p) => rpc('eth_sendTransaction', p),
  settle: async (tx, quiet) => {
    if (!tx) return;
    console.log(`  waiting for ${tx} …`);
    let r = null;
    try { r = await provider.waitForTransaction(tx, 1, 10 * 60 * 1000); }
    catch (e) {
      const n = await provider.getTransactionCount(account, 'latest');
      if (lastNonce >= 0 && n > lastNonce) throw Error(`tx ${tx} was never mined: its nonce ${lastNonce} was used by another sender from this key`);
      throw e;
    }
    if (!r || r.status !== 1) throw Error('tx reverted: ' + tx);
    console.log(`  mined in block ${r.blockNumber}`);
  },
  checkWallet: async () => {},
  connect: () => die('not connected'),
  refreshBalance: () => {}, sBlip() {}, sGot() {}, sSend() {},
  explain: (e) => 'Error: ' + String(e && e.message || e),
  err: (e) => { throw e; },
  cbDisarm() {}, lqSet() {}, lnSet() {}, wnSet() {}, fcSync() {}, seq: 0, quoting: false, lqMode: false, lnMode: false, wnMode: false,
  prompt: (msg, dflt) => { if (dflt !== undefined) { sandbox.__lastPromptDefault = dflt; } return prompts.length ? prompts.shift() : null; },
  CHAINS: {
    1: { name: 'Ethereum', explorer: 'https://etherscan.io', rpcs: [RPC] },
    8453: { name: 'Base', explorer: 'https://basescan.org', rpcs: ['https://mainnet.base.org'] },
    4663: { name: 'Robinhood', explorer: 'https://robinscan.io', rpcs: ['https://rpc.mainnet.chain.robinhood.com'] },
  },
  document: { querySelector: () => el(), hidden: false },
  stat, pvNote, pvKey: el(), pvList: el(), pvGo: el(), pvAmt: el(), pvChain: el({ value: '8453' }), pvTo: el(), pvPath: el({ value: 'relay' }),
  pvSplit: el({ value: '1' }), pvPanel: el(), pv: el(), rate: el(), flip: el(), swap: el(), rcvPanel: el(), rc: el(), rcvEl: el(),
};
const ctx = vm.createContext(sandbox);
vm.runInContext(helpers + '\n' + moduleSrc + `
;globalThis.__cp={relayFetch,cpUse,cpUnlock,cpDeposit,cpExit,cpActivate,cpReclaim,cpSelfSend,cpRequest,cpPay,cpRecover,cpSync,cpStatus,cpRelayPoll,cpSettleWrap,cpFmt,cpNoteOf,cpKeyFor,cpRelayBase,
notes:()=>cpNotes,seed:()=>cpSeed,pool:()=>cpPool,setMode:v=>{pvMode=v},CP_POOL,CP_ROUTER,CP_ETH,SEL_CPIMPL,SEL_CPNEXT};`, ctx, { filename: 'zSwap.html#private-bridge' });
const cp = ctx.__cp;
cp.setMode(true);

// ---- helpers ----
const fmtEth = (wei) => { const s = wei.toString().padStart(19, '0'); const w = s.slice(0, -18), f = s.slice(-18).replace(/0+$/, ''); return f ? `${w}.${f}` : w; };
async function refresh() { fromBalance = await provider.getBalance(account); }
async function unlock() {
  const k = cp.cpKeyFor(account);
  if (/^0x[0-9a-f]{64}$/i.test(k || '')) cp.cpUse(k);
  else { console.log('deriving the private-bridge key from one signature …'); await cp.cpUnlock(); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Self-settle a deposit: the relay only proves the wrap (mode prove) and this wallet sends pool.settle,
// which mines in a block or two - the relay's own settle key is shared and keeps losing nonce races.
async function proveAndSettleWrap(n) {
  if (!n.job || n.js === 'failed' || n.mode !== 'prove') {
    const r = await cp.relayFetch('/confidential/submit', { type: 'wrap', op: n.op, memos: [n.memo], mode: 'prove' });
    if (!r.jobId) die('the relay did not take the deposit');
    n.job = r.jobId; n.js = r.status || 'pending'; n.rb = cp.cpRelayBase(); n.mode = 'prove'; persistNotes();
  }
  const js = await pollJob(n, ['proven', 'settled'], `prove deposit #${n.i}`);
  if (js === 'settled') return;
  const data = '0x717fd7f2' + AbiCoder.defaultAbiCoder().encode(['bytes', 'bytes', 'bytes[]'], [n.pv, n.pr, [n.memo]]).slice(2);
  await rpc('eth_call', [{ from: account, to: cp.CP_POOL, data }, 'latest']);
  const tx = await rpc('eth_sendTransaction', [{ from: account, to: cp.CP_POOL, value: '0x0', data, gas: '0xaae60' }]);
  n.stx = tx; persistNotes();
  await sandbox.settle(tx, true);
}
function persistNotes() { store['zswap:cpn:' + fpOf()] = JSON.stringify(cp.notes()); persist(); }
async function pollJob(n, want, label, minutes = 30) {
  const t = () => n.ex || n;
  for (let i = 0; i < minutes * 6; i++) {
    await cp.cpRelayPoll(n);
    const js = t().js;
    if (want.includes(js)) return js;
    if (js === 'failed') die(`relay job failed: ${t().jerr || 'unknown'}`);
    if (i % 6 === 0) console.log(`  relay: ${js || 'pending'} (${label})`);
    await sleep(10000);
  }
  die(`gave up waiting on the relay (${label}); the job is still queued — rerun status later`);
}
function fpOf() { const k = Object.keys(store).find((x) => x.startsWith('zswap:cpn:')); return k ? k.slice('zswap:cpn:'.length) : ''; }
function note(i) { const n = cp.notes().find((x) => !x.p && x.i === Number(i)); if (!n) die(`no note #${i} — see status`); return n; }
async function statusLine(n) {
  const { s } = cp.cpStatus(n);
  const x = n.ex;
  return `#${n.p ? 'paid' : n.i}  ${cp.cpFmt(n.v)} ETH  ${s}${x ? `  → ${sandbox.CHAINS[x.ch].name} ${x.to}` : ''}${(n.ex || n).job ? `  relay:${(n.ex || n).js || '?'}` : ''}${x && x.esc ? `  escrow ${x.esc}` : ''}${x && x.atx ? `  activate ${x.atx}` : ''}${x && x.ptx ? `  sent ${x.ptx}` : ''}`;
}

// ---- commands ----
const run = {
  async plan() {
    await refresh();
    console.log(`signer:   ${account}`);
    console.log(`balance:  ${fmtEth(fromBalance)} ETH`);
    console.log(`relay:    ${cp.cpRelayBase()}`);
    const impl = await rpc('eth_call', [{ to: cp.CP_ROUTER, data: '0x' + cp.SEL_CPIMPL }, 'latest']);
    console.log(`executorImpl (live): 0x${impl.slice(-40)}`);
    const next = await rpc('eth_call', [{ to: cp.CP_POOL, data: '0x' + cp.SEL_CPNEXT }, 'latest']);
    console.log(`pool notes: ${Number(BigInt(next))}${Number(BigInt(next)) < 20 ? '  (tiny anonymity set — a functional test, not privacy)' : ''}`);
    const st = await fetch(cp.cpRelayBase() + '/confidential/status?id=0xdead').then((r) => r.json()).catch((e) => ({ error: String(e) }));
    console.log(`relay status route: ${JSON.stringify(st)}`);
  },
  async status() {
    await unlock(); await refresh();
    await cp.cpSync(true);
    const notes = cp.notes();
    console.log(`key fingerprint ok · ${notes.length} record(s) · pool leaves ${cp.pool().leaves.length} · balance ${fmtEth(fromBalance)} ETH`);
    for (const n of notes) { if ((n.ex || n).job) await cp.cpRelayPoll(n); console.log(await statusLine(n)); }
  },
  async deposit() {
    await unlock(); await refresh();
    sandbox.pvAmt.value = arg('amount') || die('pass --amount <eth>');
    sandbox.pvSplit.value = arg('notes', '1');
    const before = cp.notes().length;
    await cp.cpDeposit();
    const mine = cp.notes().slice(before);
    for (const n of mine) await pollJob(n, ['settled'], `deposit #${n.i}`);
    await cp.cpSync(true);
    for (const n of mine) console.log(await statusLine(n));
  },
  async exit() {
    await unlock(); await refresh();
    const n = note(arg('note', '0'));
    sandbox.pvChain.value = arg('chain', '8453');
    sandbox.pvTo.value = arg('to', '');
    sandbox.pvPath.value = flag('self') ? 'self' : 'relay';
    await cp.cpExit(n);
    if (n.ex.self) { console.log(await statusLine(n)); return; }
    await pollJob(n.ex, ['settled'], `exit #${n.i}`);
    await cp.cpSync(true);
    console.log(await statusLine(n));
    if (n.ex.ch === 1) { console.log('withdrawn — nothing to activate'); return; }
    console.log('escrow funded by the relay; activating …');
    await cp.cpActivate(n);
    console.log(await statusLine(n));
  },
  async settle() {
    await unlock(); await refresh();
    const n = note(arg('note', '0'));
    await cp.cpSync(true);
    if (cp.cpStatus(n).s !== 'pending') { console.log(await statusLine(n)); return; }
    if (flag('self')) await proveAndSettleWrap(n);
    else { if (!n.job || n.js === 'failed') await cp.cpSettleWrap(n); await pollJob(n, ['settled'], `deposit #${n.i}`); }
    await cp.cpSync(true);
    console.log(await statusLine(n));
  },
  async activate() { await unlock(); await refresh(); const n = note(arg('note', '0')); await cp.cpActivate(n); console.log(await statusLine(n)); },
  async reclaim() { await unlock(); await refresh(); const n = note(arg('note', '0')); await cp.cpReclaim(n); console.log(await statusLine(n)); },
  async request() {
    await unlock(); await refresh();
    sandbox.pvAmt.value = arg('amount') || die('pass --amount <eth>');
    await cp.cpRequest();
    console.log(sandbox.__lastPromptDefault);
  },
  async pay() {
    await unlock(); await refresh();
    const f = arg('file') || die('pass --file <request.json>');
    prompts.push(fs.readFileSync(f, 'utf8'));
    await cp.cpPay();
    const n = cp.notes().find((x) => x.p && x.js !== 'settled');
    if (n && flag('self')) await proveAndSettleWrap(n);
    else if (n) await pollJob(n, ['settled'], 'payment');
    console.log('paid and settled');
  },
  async recover() { await unlock(); await refresh(); const k = await cp.cpRecover(); console.log(`recovered ${k} deposit(s)`); for (const n of cp.notes()) console.log(await statusLine(n)); },
};
if (!run[cmd]) die(`unknown command ${cmd}`);
run[cmd]().then(() => process.exit(0)).catch((e) => { console.error(e && e.stack || e); process.exit(1); });
