/**
 * The private panel's key handling and Tacit crypto, held to Tacit's own rules.
 *
 * - The identity signature's v must be 27/28, or 0/1, which stands for the
 *   same recovery id; any other v is refused, as Tacit refuses it. The key a
 *   valid signature derives is unchanged: it is still Tacit's
 *   sha256-of-the-signature scalar.
 * - A tacit1 address whose bech32m padding is not zero, or not under five
 *   bits, does not decode, the way Tacit's own decoder refuses it.
 * - A key imports with or without 0x, as tacit.finance exports it bare, and
 *   only when it is a scalar in (0, n).
 * - Bitcoin-lane notes and loan records are stored sealed under the key like
 *   the other private lists; a plain list an older build left is sealed the
 *   first time it is read under the key.
 * - A generation-bound note on Bitcoin (0x39) is looked up in Tacit's
 *   reflection under the bound leaf, which carries its target chain binding.
 * - A loan position's own secrets carry no debt keys: the debt note's come
 *   from deriveOutputKeys alone.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { verifyMessage, Wallet, Signature, SigningKey, keccak256, concat, toUtf8Bytes } from 'ethers';
import { MockChain, loadPage, closeAllPages, CP_BLOCK } from './harness.mjs';
import { openStore } from './cp-store.mjs';

after(closeAllPages);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const ETH = 10n ** 18n;
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const B0 = CP_BLOCK + 0x100;
const RELAY = 'api.tacit.finance';
const SLOW = { timeout: 20000 };
const fp = createHash('sha256').update('zswap-cp-v1:' + F.seed).digest('hex').slice(0, 16);
// The account the harness's fixed signature really comes from: the one Tacit derives F.seed for.
const SIGNER = verifyMessage(F.identityMessage, F.sig);

function keyChain(account = SIGNER) {
  const chain = new MockChain({ accounts: [account] });
  chain.blockNumber = '0x' + (B0 + 0x8).toString(16);
  chain.gasPrice = 10n ** 8n;
  chain.setNative(account, 10n * ETH);
  chain.answer(F.router, '93228617', '0x' + F.executorImpl.slice(2).toLowerCase().padStart(64, '0'));
  chain.answer(F.pool, '9fda5b66', '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
  chain.answer(F.pool, '0be4f422', '0x' + u256(0));
  chain.answer(F.pool, '7da9874f', '0x' + u256(0));
  chain.lanes = {};
  return chain;
}

// Press Unlock and wait for either the key or the page's refusal.
async function attempt(chain, storage = {}, before = () => {}) {
  const p = await loadPage({ chain, storage });
  const inner = p.window.fetch;
  p.window.__posts = [];
  p.window.fetch = async (url, init) => { if (init && init.body) p.window.__posts.push({ url: String(url), body: init.body }); return inner(url, init); };
  await p.connect();
  p.click('pv');
  await p.settle();
  before(p);
  p.click('pvGo');
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')) || /signature|account|spelling|two different ways/.test(p.text('stat')),
    { label: 'the unlock to finish', ...SLOW });
  await p.settle();
  return p;
}
const unlocked = (p) => /Key unlocked/.test(p.text('pvKey'));

describe('the identity signature', () => {
  test('takes v as 27/28 or 0/1 for the same key, and refuses any other v or a high s', async () => {
    const c0 = keyChain(SIGNER);
    c0.personalSig = F.sig.slice(0, 130) + '00';
    const zero = await attempt(c0);
    assert.equal(zero.window.eval('cpSeed'), F.seed, 'v 0 is v 27');
    zero.close();

    // A real wallet's signature: the key is still sha256(signature), reduced to a scalar as Tacit reduces it.
    const w0 = new Wallet('0x' + '42'.repeat(32)), sig = w0.signMessageSync(F.identityMessage);
    const cr = keyChain(w0.address);
    cr.personalSig = sig;
    const real = await attempt(cr);
    const want = BigInt('0x' + createHash('sha256').update(Buffer.from(sig.slice(2), 'hex')).digest('hex'));
    assert.ok(want > 0n && want < N);
    assert.equal(real.window.eval('cpSeed'), '0x' + u256(want));
    real.close();

    for (const v of ['1d', '02', 'ff']) {
      const c = keyChain(SIGNER);
      c.personalSig = F.sig.slice(0, 130) + v;
      const p = await attempt(c);
      assert.match(p.text('stat'), /The wallet returned an unusable signature/, `v 0x${v} is refused`);
      assert.equal(p.window.eval('cpSeed'), '');
      p.close();
    }

    // The same wallet's signature with s flipped to n - s (and v with it): an equally valid spelling, refused.
    const w = new Wallet('0x' + '43'.repeat(32)), s = Signature.from(w.signMessageSync(F.identityMessage));
    const hi = '0x' + s.r.slice(2) + u256(N - BigInt(s.s)) + (s.v === 27 ? '1c' : '1b');
    const ch = keyChain(w.address);
    ch.personalSig = hi;
    const p = await attempt(ch);
    assert.match(p.text('stat'), /second, equally valid spelling/);
    assert.equal(p.window.eval('cpSeed'), '');
    p.close();
  });
});

describe('tacit1 addresses', () => {
  // Valid bech32m checksum over a payload whose last 5-bit group carries bits that are not zero padding.
  const PADDED = 'tacit1qqps9xyupdmvk43ew87un0hnrmqxcdtq7vjf6mhfuhvrc4mz2ktwqhm0qdk5lnmv6yyy73yd0mccau2em5n66y5a0pyh3xfuhzwmf8g39kctxq5cns9hdj6k89clmjd77v0vqmp4vrejf8twa8jas0zhvf2edczldatvd69v';

  test('refuse non-zero padding, as Tacit\'s decoder does, and the key\'s own address still decodes', async () => {
    const p = await attempt(keyChain(SIGNER));
    assert.equal(p.window.eval(`cpTacDec("${PADDED}")`), null, 'the raw decode refuses it');
    assert.equal(p.window.eval(`cpLn("${PADDED}")`), null);
    assert.equal(p.window.eval(`(()=>{try{return cpRecip("${PADDED}")}catch(e){return e.message}})()`),
      'That Tacit address does not carry an Ethereum lane.', 'and nothing is sent to it');
    assert.equal(p.window.eval(`cpRecip("${F.send.address}")`), F.pub.slice(2), 'an address Tacit\'s own encoder made still decodes');
    const mine = p.window.eval('cpTacAddr(cpSeed)');
    assert.equal(p.window.eval(`cpRecip("${mine}")`), F.pub.slice(2), 'and so does the page\'s own, back to its key');
    assert.equal(p.window.eval(`cpIsMe("${mine}")`), true);
    p.close();
  });
});

describe('importing a key', () => {
  test('takes tacit.finance\'s bare-hex export or 0x, and only a scalar in (0, n)', async () => {
    const p = await attempt(keyChain(SIGNER));
    const imp = async (v, yes = true) => {
      const was = p.window.eval('cpSeed');
      p.window.eval('Sm("")');
      p.queuePrompt(v);
      if (yes) p.queueConfirm(true);
      p.click(p.$('pvKey').querySelector('button[data-a="import"]'));
      await p.waitFor(() => p.text('stat') !== '' || p.window.eval('cpSeed') !== was, { label: 'the import to finish' });
      await p.settle();
    };
    const bare = 'ab'.repeat(32);
    await imp(bare);
    assert.equal(p.window.eval('cpSeed'), '0x' + bare, 'a bare 64-hex key, as tacit.finance exports it');
    assert.equal(p.window.eval('cpPub'), new SigningKey('0x' + bare).compressedPublicKey.slice(2));

    for (const bad of ['00'.repeat(32), u256(N), 'f'.repeat(64), '0x' + u256(N + 5n), 'ab'.repeat(31)]) {
      await imp(bad, false);
      assert.equal(p.text('stat'), 'That is not a key.', `${bad.slice(0, 12)}… is refused`);
      assert.equal(p.window.eval('cpSeed'), '0x' + bare, 'and the key in use stays');
    }

    const top = u256(N - 1n).toUpperCase();
    await imp('0X' + top);
    assert.equal(p.window.eval('cpSeed'), '0x' + top.toLowerCase(), 'n - 1 is a key, in either case and prefix');
    p.close();
  });
});

const TACID = F.btcNote.found[0].a;
describe('Bitcoin-lane notes and loan records', () => {
  const btcRec = { t: F.btcNote.txid, o: 0, a: TACID, v: '12345678', c: '02' + 'ab'.repeat(32), l: F.btcNote.found[0].leaf, w: 1 };
  const cdpRec = { i: 0, v: F.cdp.debtValue, cv: '100000', rate: '0x' + u256(10n ** 27n), leaf: F.cdp.positionLeaf, at: 1, js: 'settled' };

  test('a plain list an older build left is sealed under the key on unlock, with its contents', async () => {
    const storage = { ['zswap:cpb:' + fp]: JSON.stringify([btcRec]), ['zswap:cpc:' + fp]: JSON.stringify([cdpRec]) };
    const p = await attempt(keyChain(SIGNER), storage);
    assert.ok(unlocked(p));
    await p.waitFor(() => /cUSD against/.test(p.text('pvList')) && /on Bitcoin/.test(p.text('pvList')), { label: 'both rows', ...SLOW });
    assert.match(p.text('pvList'), /12345678 units on Bitcoin\s*verified/, 'the Bitcoin note reads as it was');
    assert.match(p.text('pvList'), /30 cUSD against 0\.001 cBTC/, 'and so does the loan');
    const ls = p.window.localStorage;
    assert.match(ls['zswap:cpb:' + fp], /^z1\./, 'the Bitcoin notes are sealed');
    assert.match(ls['zswap:cpc:' + fp], /^z1\./, 'the loan records are sealed');
    assert.doesNotMatch(ls['zswap:cpb:' + fp] + ls['zswap:cpc:' + fp], new RegExp('12345678|' + F.btcNote.txid.slice(0, 16) + '|' + F.cdp.positionLeaf.slice(2, 18)), 'nothing readable is left');
    assert.deepEqual(openStore(ls['zswap:cpb:' + fp], F.seed), [btcRec]);
    assert.deepEqual(openStore(ls['zswap:cpc:' + fp], F.seed), [cdpRec]);
    // A record the page writes is sealed too.
    p.window.eval(`cpSaveCdps([...cpLoadCdps(),{i:1,v:"5",cv:"6",leaf:"0x${'cd'.repeat(32)}",at:2}])`);
    assert.match(ls['zswap:cpc:' + fp], /^z1\./);
    assert.deepEqual(openStore(ls['zswap:cpc:' + fp], F.seed).map(x => x.i), [0, 1]);
    p.close();
  });
});

describe('a generation-bound note on Bitcoin', () => {
  const B = F.btcNote, BIND = 'e5'.repeat(32);
  // The fixture's CXFER (0x23), re-framed as the bound CXFER (0x39) Tacit onboards: binding ‖ the same body.
  const boundTx = () => {
    const s = Buffer.from(B.tx.vin[0].witness[1], 'hex');
    const pushes = [];
    for (let i = 36; i < s.length;) {
      const o = s[i];
      if (o === 0x68) break;
      let n, j = i + 1;
      if (o < 76) n = o; else if (o === 76) n = s[j++]; else { n = s.readUInt16LE(j); j += 2; }
      pushes.push(s.subarray(j, j + n)); i = j + n;
    }
    const body = Buffer.concat(pushes.slice(2));
    assert.equal(body[0], 0x23);
    const pay = Buffer.concat([Buffer.from([0x39]), Buffer.from(BIND, 'hex'), body.subarray(1)]), len = Buffer.alloc(2);
    len.writeUInt16LE(pay.length);
    const script = Buffer.concat([s.subarray(0, 36), Buffer.from('055441434954' + '0101' + '4d', 'hex'), len, pay, Buffer.from([0x68])]);
    const tx = structuredClone(B.tx);
    tx.vin[0].witness[1] = script.toString('hex');
    return { tx, pay };
  };
  // Tacit's leaf over the output's own commitment and x-only Taproot key (zero when not P2TR), unbound or bound.
  const leafOf = (pay, at, vout, tx, bind) => {
    const n = pay[at], outs = [];
    for (let k = 0; k < n; k++) outs.push(pay.subarray(at + 1 + k * 41, at + 1 + k * 41 + 33));
    const pt = SigningKey.computePublicKey(outs[vout], false), spk = tx.vout[vout].scriptpubkey;
    const ak = /^5120/.test(spk) ? '0x' + spk.slice(4) : '0x' + '00'.repeat(32);
    return keccak256(concat(['0x' + TACID.slice(2), '0x' + pt.slice(4, 68), '0x' + pt.slice(68), ak,
      ...(bind ? ['0x' + bind] : []), toUtf8Bytes(bind ? 'tacit-btc-note-bound' : 'tacit-btc-note-v1')]));
  };

  test('is looked up under the bound leaf with its binding, shows verified, and is stored sealed', async () => {
    const { tx, pay } = boundTx();
    // The same arithmetic reproduces Tacit's unbound leaves for the plain transfer, so the bound ones below are its too.
    const plain = Buffer.concat([Buffer.from([0x23]), pay.subarray(33)]);
    for (const f of B.found) assert.equal(leafOf(plain, 97, f.o, B.tx), f.leaf);
    const [b0, b1] = B.found.map(f => leafOf(pay, 129, f.o, tx, BIND));

    const chain = keyChain(SIGNER);
    chain.lanes['/address/' + F.btc.address + '/utxo'] = [0, 1, 2, 3].map(o => ({ txid: B.txid, vout: o, value: 546 }));
    chain.lanes['/tx/' + B.txid] = tx;
    chain.lanes[RELAY + '/reflection/note-witness'] = { network: 'mainnet', root: '0x' + 'ab'.repeat(32), height: 966812,
      witnesses: { [b0]: { leafIndex: 7, path: [] }, [b1]: null, [B.found[0].leaf]: null, [B.found[1].leaf]: null } };
    const p = await attempt(chain);
    p.click(p.$('pvKey').querySelector('button[data-a="recover"]'));
    await p.waitFor(() => /on Bitcoin/.test(p.text('pvList')), { label: 'the Bitcoin notes', ...SLOW });
    const t = p.text('pvList');
    assert.match(t, /12345678 units on Bitcoin\s*verified/, 'the bound note is in Tacit\'s reflected note set');
    assert.match(t, /777 units on Bitcoin\s*not reflected yet/);
    const asked = p.window.__posts.filter(x => /\/reflection\/note-witness$/.test(x.url)).map(x => JSON.parse(x.body));
    assert.deepEqual(asked, [{ leaves: [b0, b1] }], 'asked about the bound leaves');
    const raw = p.window.localStorage['zswap:cpb:' + fp];
    assert.match(raw, /^z1\./, 'what the scan finds is stored sealed');
    assert.deepEqual(openStore(raw, F.seed).map(n => [n.o, n.v, n.l, n.w]), [[0, '12345678', b0, 1], [1, '777', b1, 0]]);
    assert.equal(p.window.eval(`bOpenOut(cpSeed,${JSON.stringify(B.tx)},0).l`), B.found[0].leaf, 'a plain note keeps the unbound leaf');
    await p.settle();
    p.close();
  });
});

describe('loan keys', () => {
  test('a position\'s own secrets carry no debt keys; the debt note\'s are deriveOutputKeys\'', async () => {
    const p = await loadPage({ chain: new MockChain() });
    assert.deepEqual(JSON.parse(p.window.eval(`JSON.stringify(Object.keys(cdpSecrets(0,"${F.seed}")))`)), ['pos', 'owner', 'nonce']);
    assert.equal(p.window.eval(`cdpSecrets(0,"${F.seed}").owner`), F.cdp.posOwner);
    assert.equal(p.window.eval(`cdpSecrets(0,"${F.seed}").nonce`), '0x' + '00'.repeat(32));
    const C = F.cbtc, D = F.cdp, CB = '0x62a20d98fc1cd20289621d1315294cb8772f934d822e404b71e1f471cf0679c8';
    const S = JSON.parse(p.window.eval(`(()=>{const X=cdpBuildOp({asset:"${CB}",cx:"${C.cx}",cy:"${C.cy}",owner:Z32,value:${C.amountSats}n,blinding:${BigInt(C.blinding)}n,nu:"${D.anchor}"},
      0,"${D.root}",${JSON.stringify(D.path)},${D.debtValue}n,"${D.rateSnapshot}",0,"${F.seed}");return JSON.stringify({nk:X.S.nk,b:"0x"+X.S.blind.toString(16).padStart(64,"0"),o:X.op.debtOwner})})()`));
    assert.deepEqual(S, { nk: D.debtNk, b: D.debtBlinding, o: D.op.debtOwner });
    p.close();
  });
});
