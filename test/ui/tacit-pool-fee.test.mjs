// What a pool spend shows and checks before it is proved. The keeper's fee, and the fee of every note merge the
// wallet would make first, are quoted and confirmed up front, so a spend that cannot be covered is refused before
// any merge is paid for. A keeper that goes quiet after the relay step is not followed by a second send from this
// wallet, and a hash the keeper returns must be a pool transaction. Addresses carry Tacit's own address ID, a pool
// address for another network is refused, and a name pays the pool lane of the Tacit address it publishes.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { MockChain, loadPage, closeAllPages } from './harness.mjs';
import { FAKE_POOL } from './tacit-fake-pool.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const ROUTER = '0x0000006c96afa6f1cd4df8fe19bc0d8b6a6cd7b5';
const POOL = '0x000000c2a20657ce25f2ba99737933d031afbee9';
const BOX = '0x52fc37ee7741468a15ce879320a7a41cebaeb232';
const KEY = '0x' + '11'.repeat(32);
const KEEPER = 'https://keeper.test/evm-pool/keeper';
const word = x => BigInt(x).toString(16).padStart(64, '0');

async function open({ keeper = false, fee = '1000000000000000' } = {}) {
  const chain = new MockChain({ chainId: '0x1' });
  chain.code.set(ROUTER, '0x5f5ff3');
  chain.answers.set(`${ROUTER}:7944b37a`, '0x' + word(BOX));
  chain.lanes = { 'tacit-evm-pool-keeper': 404, 'keeper.test/evm-pool/keeper/quote': { fee, relayer: POOL } };
  const p = await loadPage({ chain, storage: { 'zswap:pvin': '' } });
  await p.connect({ pin: false });
  await p.settle();
  p.window.eval(`cpUse(${JSON.stringify(KEY)})`);
  p.window.eval(FAKE_POOL);
  if (keeper) p.window.eval(`twW.r=${JSON.stringify(KEEPER)}`);
  p.click('pv');
  await p.settle();
  return p;
}
const calls = p => JSON.parse(p.window.eval('JSON.stringify(twW.calls)'));
async function pay(p, amount, to = 'bp1qfriend') {
  p.select('pvAct', 'send');
  p.type('pvAmt', amount);
  p.type('pvRc', to);
  p.click('pvGo');
}
const done = p => p.waitFor(() => /Sent: |Not sent|does not hold|did not answer|not a pool transaction|pool payment goes|before pool payments/.test(p.text('stat')), { label: 'the spend to finish' });

describe('Tacit address IDs', () => {
  test('are the IDs Tacit itself shows, for the tacit1 and the pool address alike, in any case', async () => {
    const p = await open();
    const t = p.window.eval('cpTacAddr(cpSeed)'), bp = p.window.eval('cpBp(cpTacAddr(cpSeed))');
    // From Tacit's dapp/address-id.js addressId() over these same two addresses (src-company/tacit 6ddec46f).
    assert.equal(p.window.eval(`cpId(${JSON.stringify(t)})`), '30db·8d95·5c87·36fa');
    assert.equal(p.window.eval(`cpId(${JSON.stringify(bp)})`), '0cce·626b·e955·e0c5');
    assert.equal(p.window.eval(`cpId(${JSON.stringify(t.toUpperCase())})`), '30db·8d95·5c87·36fa');
    p.close();
  });
});

describe('pool payment addresses', () => {
  test('a test-network pool address is refused, and nothing is sent', async () => {
    const p = await open();
    await pay(p, '0.1', 'tbp1qfriend');
    await done(p);
    assert.match(p.text('stat'), /A pool payment goes to a bp1… address/);
    assert.deepEqual(calls(p), []);
    assert.throws(() => p.window.eval('cpBq("tbp1qfriend")'), /bp1… address/, 'the Private ETH menu refuses it the same way');
    p.close();
  });

  test('a tacit1 from before pool payments is told apart from a mistyped one', async () => {
    const p = await open();
    const old = F.send.address;
    assert.equal(p.window.eval(`cpLn(${JSON.stringify(old)})[1]&4`), 0, 'the fixture address carries no pool lane');
    assert.throws(() => p.window.eval(`cpBq(${JSON.stringify(old)})`), /from before pool payments/);
    assert.equal(p.window.eval('cpBq(cpTacAddr(cpSeed))'), p.window.eval('cpBp(cpTacAddr(cpSeed))'), 'one with a pool lane pays that lane');
    assert.equal(p.window.eval('cpBq("BP1QFRIEND")'), 'bp1qfriend', 'an all-capitals pool address is read as itself');
    p.close();
  });
});

describe('paying a name from the pool', () => {
  test('pays the pool lane of the Tacit address the name publishes, after showing where it points', async () => {
    const p = await open();
    const t = p.window.eval('cpTacAddr(cpSeed)'), bp = p.window.eval('cpBp(cpTacAddr(cpSeed))');
    p.chain.texts = new Map([['bob.wei|finance.tacit', t]]);
    p.queueConfirm(true);
    await pay(p, '0.1', 'bob.wei');
    await p.waitFor(() => /Sent: 0xsend/.test(p.text('stat')), { label: 'the payment by name' });
    assert.match(p.asked.confirm[0], /^Pay bob\.wei\?\n\nbob\.wei → bp1/);
    assert.match(p.asked.confirm[0], /\nID 0cce·626b·e955·e0c5\n/, 'with the pool address\'s own ID');
    assert.deepEqual(calls(p), [['send', bp, '100000000000000000', 'keeper']]);
    p.close();
  });

  test('a name whose record has no pool lane, or no record, is refused before anything is asked', async () => {
    const p = await open();
    p.chain.texts = new Map([['old.wei|finance.tacit', F.send.address]]);
    await pay(p, '0.1', 'old.wei');
    await done(p);
    assert.match(p.text('stat'), /from before pool payments/);
    await pay(p, '0.1', 'nobody.wei');
    await p.waitFor(() => /has no Tacit address published/.test(p.text('stat')), { label: 'the empty record' });
    assert.equal(p.asked.confirm.length, 0);
    assert.deepEqual(calls(p), []);
    p.close();
  });
});

describe('the keeper fee', () => {
  test('is shown with the recipient\'s ID before proving, and declining sends nothing', async () => {
    const p = await open({ keeper: true });
    p.queueConfirm(false);
    await pay(p, '0.2');
    await done(p);
    const asked = p.asked.confirm.at(-1);
    assert.match(asked, /^Pay 0\.2 ETH to bp1qfriend…friend, ID [0-9a-f]{4}·[0-9a-f]{4}·[0-9a-f]{4}·[0-9a-f]{4}\./);
    assert.match(asked, /Keeper fee: 0\.001 ETH, at most 0\.00125 ETH if gas rises first\. Go ahead\?$/);
    assert.match(p.text('stat'), /Not sent/);
    assert.deepEqual(calls(p), []);
    p.queueConfirm(true);
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xsend/.test(p.text('stat')), { label: 'the payment once agreed' });
    assert.deepEqual(calls(p), [['send', 'bp1qfriend', '200000000000000000', 'keeper']]);
    p.close();
  });

  test('counts the note merges the wallet would pay for, and refuses a spend they cannot cover before any is made', async () => {
    const p = await open({ keeper: true });
    p.window.eval('twW.notes=()=>[{v:"100000000000000000"},{v:"100000000000000000"},{v:"100000000000000000"}]');
    p.queueConfirm(false);
    await pay(p, '0.25');
    await done(p);
    assert.match(p.asked.confirm.at(-1), /Keeper fee: 0\.002 ETH, including 1 note merge first, at most 0\.0025 ETH if gas rises first\. Go ahead\?$/);
    p.type('pvAmt', '0.35');
    p.click('pvGo');
    await p.waitFor(() => /does not hold/.test(p.text('stat')), { label: 'the refusal' });
    assert.match(p.text('stat'), /The pool does not hold 0\.35 ETH plus the 0\.001 ETH keeper fee and the fees to merge notes\./);
    assert.deepEqual(calls(p), [], 'no merge and no payment was started');
    p.close();
  });

  test('withdrawals, bridges and moves into V1 are quoted for their own gas', async () => {
    const p = await open({ keeper: true });
    p.queueConfirm(true, true);
    p.select('pvAct', 'out');
    p.type('pvAmt', '0.1');
    p.select('pvChain', '8453');
    await p.settle();
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xbridge/.test(p.text('stat')), { label: 'the bridge' });
    const q = p.chain.httpLog.filter(x => x.url.includes('keeper.test')).map(x => x.url.split('?')[1]);
    assert.deepEqual(q, ['gas=1300000'], 'the Base bridge asks for its own gas');
    assert.match(p.asked.confirm.at(-1), /^Keeper fee: 0\.001 ETH, at most 0\.00125 ETH if gas rises first\. Go ahead\?$/);
    p.close();
  });
});

describe('the fee the keeper may take', () => {
  test('is capped at a quarter over the fee shown, as Tacit\'s own page caps it', async () => {
    const p = await open({ keeper: true });
    p.window.eval('twW.send=async(to,v,o)=>{twW.calls.push(["send",to,String(v),String(o&&o.maxFee)]);return "0xsend"}');
    p.queueConfirm(true);
    await pay(p, '0.2');
    await p.waitFor(() => /Sent: 0xsend/.test(p.text('stat')), { label: 'the payment' });
    assert.deepEqual(calls(p), [['send', 'bp1qfriend', '200000000000000000', '1250000000000000']]);
    p.close();
  });

  test('a fee that rose after it was shown is refused, and not sent from this wallet instead', async () => {
    const p = await open({ keeper: true });
    p.window.eval('twW.send=async(to,v,o)=>{twW.calls.push(["send",to,String(v),o&&o.via||"keeper"]);throw Object.assign(Error("The relay fee went up since it was shown. Check the new fee and try again."),{feeMoved:2000000000000000n})}');
    p.queueConfirm(true);
    await pay(p, '0.2');
    await p.waitFor(() => /fee went up/.test(p.text('stat')), { label: 'the refusal' });
    assert.ok(!p.asked.confirm.some(m => /from this wallet instead/.test(m)), 'no send from this wallet is offered');
    assert.equal(calls(p).length, 1);
    p.close();
  });
});

describe('a keeper that does not answer', () => {
  test('in the wallet\'s own words is not followed by a send from this wallet', async () => {
    const p = await open();
    p.window.eval('twW.send=async(to,v,o)=>{twW.calls.push(["send",to,String(v),o&&o.via||"keeper"]);throw Object.assign(Error("The relay did not answer, and it may still have sent your payment. Check Activity before sending again."),{said:true})}');
    await pay(p, '0.1');
    await done(p);
    assert.match(p.text('stat'), /The keeper did not answer, and it may still send this\./);
    assert.ok(!p.asked.confirm.some(m => /from this wallet instead/.test(m)));
    assert.equal(calls(p).length, 1);
    p.close();
  });

  test('after the relay step is not followed by a send from this wallet', async () => {
    const p = await open();
    p.window.eval(`twW.send=async(to,v,o)=>{twW.calls.push(["send",to,String(v),o&&o.via||"keeper"]);o.onStep("sending through the relayer");throw new TypeError("Failed to fetch")}`);
    await pay(p, '0.1');
    await done(p);
    assert.match(p.text('stat'), /The keeper did not answer, and it may still send this\. Check your pool balance before trying again\./);
    assert.ok(!p.asked.confirm.some(m => /from this wallet instead/.test(m)), 'no second send is offered');
    assert.equal(calls(p).length, 1);
    p.close();
  });

  test('before the relay step still offers this wallet', async () => {
    const p = await open();
    p.window.eval('twW.failRelay=1');
    p.queueConfirm(true);
    await pay(p, '0.1');
    await p.waitFor(() => /Sent: 0xsend/.test(p.text('stat')), { label: 'the payment from this wallet' });
    assert.deepEqual(calls(p).map(c => c[3]), ['keeper', 'self']);
    p.close();
  });
});

describe('the hash a keeper returns', () => {
  test('must be a transaction that touched the pool', async () => {
    const p = await open();
    p.window.eval(`twW.P=${JSON.stringify(POOL)}`);
    p.chain.lastLogs = [{ address: '0x' + '22'.repeat(20), topics: [], data: '0x' }];
    await pay(p, '0.1');
    await done(p);
    assert.match(p.text('stat'), /The keeper answered 0xsend, which is not a pool transaction\. Reload before sending again\./);
    p.chain.lastLogs = [{ address: POOL.replace('c2a2', 'C2A2'), topics: [], data: '0x' }];
    p.click('pvGo');
    await p.waitFor(() => /Sent: 0xsend/.test(p.text('stat')), { label: 'a pool transaction' });
    p.close();
  });
});
