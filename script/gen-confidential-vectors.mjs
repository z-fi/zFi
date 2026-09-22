#!/usr/bin/env node
/**
 * Regenerates test/fixtures/confidential.json - the private bridge's reference
 * vectors - with Tacit's own modules, against Tacit's own deployment record.
 *
 *   node script/gen-confidential-vectors.mjs --tacit ../tacit [--rpc <mainnet url>]
 *
 * The page re-derives every value in the fixture in its own arithmetic, and
 * check-zSwap and test/ui/private-bridge.test.mjs hold it to these. So nothing
 * here is computed by the page: the note, its commitment, leaf and deposit id,
 * the wrap witness and its pool.wrap calldata, the memo, the Merkle path, the
 * relay fee, both exit recipes and their escrows and calldata, and both unwrap
 * witnesses all come out of Tacit's dapp modules.
 *
 * What does not depend on the deployment is carried over from the current
 * fixture as input: the harness account and its fixed signature, the memo
 * ephemeral, the neighbouring leaf, the gas numbers and the deadlines. The seed
 * is Tacit's own identity derivation of that signature (evm-wallet.js), so the
 * page's key is the one tacit.finance derives from the same wallet.
 *
 * The pool and router come from Tacit's deployment record and must match the
 * page's CP_POOL / CP_ROUTER. executorImpl is read from the live router, and
 * both escrows are checked against the live router's escrowAddressFor.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { getAddress, AbiCoder } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIX = path.join(ROOT, 'test', 'fixtures', 'confidential.json');
const argv = process.argv.slice(2);
const arg = (k, d) => { const i = argv.indexOf('--' + k); return i > -1 ? argv[i + 1] : d; };
const die = (m) => { console.error(m); process.exit(1); };

const TACIT = arg('tacit');
if (!TACIT) die('usage: node script/gen-confidential-vectors.mjs --tacit <tacit repo> [--rpc <mainnet url>]');
const RPC = arg('rpc', 'https://mainnet.gateway.tenderly.co');
const load = (p) => import(pathToFileURL(path.resolve(TACIT, p)).href);

const { keccak_256 } = await load('node_modules/@noble/hashes/sha3.js');
const { sha256 } = await load('node_modules/@noble/hashes/sha2.js');
const { hmac } = await load('node_modules/@noble/hashes/hmac.js');
const secp = await load('node_modules/@noble/secp256k1/index.js');
const { makeConfidentialPoolUx } = await load('dapp/confidential-pool-ux.js');
const { makeConfidentialPool } = await load('dapp/confidential-pool.js');
const { makeConfidentialRouter } = await load('dapp/confidential-router.js');
const { makeConfidentialMemo } = await load('dapp/confidential-memo.js');
const { getConfidentialDeployment } = await load('dapp/confidential-deployments.js');

const cat = (m) => { const o = new Uint8Array(m.reduce((n, x) => n + x.length, 0)); let p = 0; for (const x of m) { o.set(x, p); p += x.length; } return o; };
secp.etc.hmacSha256Sync = (key, ...m) => hmac(sha256, key, cat(m));
const deps = { secp, keccak256: keccak_256, sha256 };

const old = JSON.parse(fs.readFileSync(FIX, 'utf8'));
const cfg = getConfidentialDeployment('mainnet');
const page = fs.readFileSync(path.join(ROOT, 'zSwap.html'), 'utf8');
for (const [k, v] of [['CP_POOL', cfg.pool], ['CP_ROUTER', cfg.router], ['CP_CE', cfg.collateralEngine], ['CP_CUSD', (cfg.assets.find((a) => a.ticker === 'cUSD') || {}).assetId]]) {
  if (!v) die(`Tacit's deployment record carries no value for ${k}`);
  const m = page.match(new RegExp(k + '="(0x[0-9a-fA-F]{40}|0x[0-9a-fA-F]{64})"'));
  if (!m || m[1].toLowerCase() !== String(v).toLowerCase()) die(`${k} in zSwap.html is ${m && m[1]}; Tacit's deployment record says ${v}`);
}
const blk = page.match(/CP_BLOCK=(\d+)/);
if (!blk || Number(blk[1]) !== Number(cfg.deployBlock)) die(`CP_BLOCK in zSwap.html is ${blk && blk[1]}; Tacit's deployment record says ${cfg.deployBlock}`);
const eth = cfg.assets.find((a) => a.ticker === 'cETH');
if (!eth || eth.assetId.toLowerCase() !== old.ethAssetId.toLowerCase()) die('native ETH is not the asset the fixture was built for');
const SCALE = BigInt(eth.unitScale), ETH = eth.assetId, ZERO = '0x0000000000000000000000000000000000000000';

const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw Error(`${method}: ${j.error.message}`);
  return j.result;
};
const liveAddr = async (data) => getAddress('0x' + String(await rpc('eth_call', [{ to: cfg.router, data }, 'latest'])).slice(-40));
const executorImpl = await liveAddr('0x93228617');

// The only RPC the modules make here is the gas price the relay fee is priced at.
// Relay submits are answered as already settled and kept, so the op a Tacit flow hands the relay can be read back.
const submits = [];
const fetchImpl = async (url, init) => {
  if (String(url).endsWith('/confidential/submit')) {
    submits.push(JSON.parse(init.body));
    const b = JSON.stringify({ jobId: '0x' + String(submits.length).padStart(64, '0'), status: 'settled' });
    return { ok: true, status: 200, text: async () => b, json: async () => JSON.parse(b) };
  }
  const { method } = JSON.parse(init.body);
  if (method !== 'eth_gasPrice') throw Error('unexpected RPC ' + method);
  return { ok: true, json: async () => ({ jsonrpc: '2.0', id: 1, result: '0x' + BigInt(old.gasPriceWei).toString(16) }) };
};
const ux = makeConfidentialPoolUx({ ...deps, fetchImpl, network: 'mainnet' });
const pool = makeConfidentialPool(deps);
const router = makeConfidentialRouter({ ...deps, cfg: { chainId: cfg.chainId, router: cfg.router } });
const memo = makeConfidentialMemo(deps);
const hex = (b) => '0x' + Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');

// The seed is Tacit's identity: `deriveIdentity` over the harness's fixed signature, answered by a stand-in
// provider. Tacit checks the signature recovers to the connected account, so the stand-in answers as the
// account the fixed signature recovers to; the message it was asked to sign is pinned as well.
const { makeEvmWallet } = await load('dapp/evm-wallet.js');
const { prfBytesToScalar } = await load('dapp/prf-wallet.js');
const { ripemd160, bech32, base58 } = await load('dapp/vendor/tacit-deps.min.js');
const u8 = (h) => Uint8Array.from(Buffer.from(String(h).replace(/^0x/, ''), 'hex'));
const utf8 = (s) => new TextEncoder().encode(s);
const ev = { asked: null, account: '0x' + '11'.repeat(20) };
globalThis.window = { ethereum: { request: async ({ method, params }) => {
  if (method === 'eth_requestAccounts') return [ev.account];
  if (method === 'eth_getCode') return '0x';
  if (method === 'personal_sign') { ev.asked = Buffer.from(u8(params[0])).toString('utf8'); return old.sig; }
  throw Error('unexpected wallet request ' + method);
} }, addEventListener() {}, dispatchEvent() {} };
const ew = makeEvmWallet({ secp, sha256, keccak256: keccak_256, bytesToHex: (b) => Buffer.from(b).toString('hex'), hexToBytes: u8, prfBytesToScalar });
let id;
try { id = await ew.deriveIdentity(); } catch (e) {
  if (!ev.asked || !/signature is from/.test(e.message)) throw e;
  const m = utf8(ev.asked), h = keccak_256(new Uint8Array([...utf8(`\x19Ethereum Signed Message:\n${m.length}`), ...m]));
  const s = old.sig.slice(2), v = parseInt(s.slice(128, 130), 16);
  const P = secp.Signature.fromCompact(s.slice(0, 128)).addRecoveryBit(v >= 27 ? v - 27 : v).recoverPublicKey(h).toRawBytes(false);
  ev.account = '0x' + Buffer.from(keccak_256(P.slice(1))).subarray(12).toString('hex');
  id = await ew.deriveIdentity();
}
const seed = '0x' + id.priv, account = old.account, identityMessage = ev.asked, pub = '0x' + id.pubHex;
// The recipe nonce is the page's own: sha256("zswap-exit-nonce-v1:" ‖ fingerprint ‖ ":" ‖ index).
const fpOf = (sd) => Buffer.from(sha256(utf8('zswap-cp-v1:' + sd))).toString('hex').slice(0, 16);
const nonceOf = (sd) => BigInt('0x' + Buffer.from(sha256(utf8('zswap-exit-nonce-v1:' + fpOf(sd) + ':0'))).toString('hex')).toString();
if (nonceOf(old.seed) !== old.nonce) die('the fixture nonce is not the page\'s derivation of its seed');
const nonce = nonceOf(seed);
const w = ux.buildWrap({ walletPriv: seed, amountWei: old.amountWei, ticker: 'cETH', index: old.index });
const note = w.note, value = BigInt(note.value);
const hA = secp.ProjectivePoint.fromAffine(pool.prover.commit(1n, 1n).toAffine()).add(secp.ProjectivePoint.BASE.negate()).toAffine();
const word = (v) => '0x' + v.toString(16).padStart(64, '0');
const memoHex = memo.encodeMemo(memo.sealMemo(pub, note, () => BigInt(old.eph)));
const path0 = pool.merklePath([w.leaf, old.otherLeaf], 0);
const root = pool.merkleRootFrom(w.leaf, 0, path0);
const nullifier = pool.nativeNullifier(note.secret, w.leaf);

const minFee = await ux.quoteOpFee('cETH', 'unwrap');
const { fee, net } = ux.quoteUnwrapFee(value, 'cETH', { minFee });
const netWei = net * SCALE;

const recipeBase = router.buildBatchExit({
  exitedAsset: ETH, feeAsset: ZERO, finalRecipient: account, deadline: old.deadline, nonce,
  calls: [{ target: router.OP_STACK_L1_BRIDGE[8453], value: netWei, data: router.depositETHToCalldata({ l2Recipient: account, minGasLimit: 200000 }) }],
  sweepTokens: [ZERO], minOuts: [0n],
});
const R = old.robinhood;
const over = BigInt(R.maxSubmissionCost) + BigInt(R.gasLimit) * BigInt(R.maxFeePerGas);
const recipeRh = router.buildArbitrumBridgeExit({
  exitedAsset: ETH, l2Recipient: account, l2CallValue: netWei - over, maxSubmissionCost: R.maxSubmissionCost,
  gasLimit: R.gasLimit, maxFeePerGas: R.maxFeePerGas, finalRecipient: account, deadline: old.deadline, nonce,
});
const escrowOf = async (r, label) => {
  const local = router.exitRecipeEscrow(executorImpl, r, cfg.router);
  const live = await liveAddr(router.escrowAddressForCalldata(r));
  if (local.toLowerCase() !== live.toLowerCase()) die(`${label} escrow: Tacit's module says ${local}, the live router says ${live}`);
  return local;
};
const escrowBase = await escrowOf(recipeBase, 'Base');
const escrowRh = await escrowOf(recipeRh, 'Robinhood');

const noteIn = { ...note, root, leafIndex: 0, path: path0 };
const realNow = Date.now;
Date.now = () => (Number(old.unwrapDeadline) - 3600) * 1000;
const unwrapRelay = ux.buildUnwrap({ note: noteIn, recipient: escrowBase, feeOpts: { minFee } }).op;
const unwrapSelf = ux.buildUnwrap({ note: noteIn, recipient: escrowBase, selfSettle: true }).op;
Date.now = realNow;
if (unwrapRelay.deadline !== old.unwrapDeadline) die('the unwrap deadline did not land on the fixture\'s bucket');

// A pool-minted token note: TAC, wrapped by burning the public ERC-20 and withdrawn back to it through
// the relay at its in-asset fee floor. Pins the page's per-asset derivation against Tacit's.
const TAC_ID = '0xf0bbe868af10c6c67652a99709bf32048d1aa7194efe3e9a1ef1bde43f94762b';
const tacTicker = ['cTAC', 'TAC'].find((k) => ux.assetByTicker[k] && ux.assetByTicker[k].assetId.toLowerCase() === TAC_ID);
if (!tacTicker) die('Tacit\'s deployment record does not carry TAC');
const tw = ux.buildWrap({ walletPriv: seed, amountWei: '100000000000000000000', ticker: tacTicker, index: 0 });
const tPath = pool.merklePath([tw.leaf, old.otherLeaf], 0);
const tRoot = pool.merkleRootFrom(tw.leaf, 0, tPath);
const tMin = await ux.quoteOpFee(tacTicker, 'unwrap');
Date.now = () => (Number(old.unwrapDeadline) - 3600) * 1000;
const tUnwrap = ux.buildUnwrap({ note: { ...tw.note, root: tRoot, leafIndex: 0, path: tPath }, recipient: account, feeOpts: { minFee: tMin } }).op;
Date.now = realNow;
const tac = {
  assetId: TAC_ID, amountWei: '100000000000000000000', note: tw.note, leaf: tw.leaf, depositId: tw.depositId, commit: tw.commit,
  wrapOp: tw.wrapOp, wrapCalldata: tw.calldata, memo: memo.encodeMemo(memo.sealMemo(pub, tw.note, () => BigInt(old.eph))),
  root: tRoot, path: tPath, nullifier: pool.nativeNullifier(tw.note.secret, tw.leaf), fee: tUnwrap.fee, unwrapRelay: tUnwrap,
};

// A cBTC lock built by Tacit's own driver (cbtc-lock-mint.js) from fixed coins and a fixed fee rate: the commit
// and reveal it broadcasts, the key-derived note blinding, the lock script, the outpoint the pool keys the lock
// by, and the fee-free mint op. Schnorr's aux randomness is zeroed for the run so the reveal is reproducible;
// the page's port has to produce the same bytes from the same inputs.
const V = await load('dapp/vendor/tacit-deps.min.js');
V.secp.etc.hmacSha256Sync = (k, ...m) => V.hmac(V.sha256, k, V.concatBytes(...m));
const { makeCbtcLockMint } = await load('dapp/cbtc-lock-mint.js');
const { makeConfidentialCdp } = await load('dapp/confidential-cdp.js');
const cUtxos = [{ txid: 'aa'.repeat(32), vout: 1, value: 150000, status: { confirmed: true } }, { txid: 'bb'.repeat(32), vout: 0, value: 20000, status: { confirmed: true } }];
const sentBtc = [], realFetch = globalThis.fetch;
globalThis.fetch = async (url, opts = {}) => {
  const s = String(url), ok = (b, t) => ({ ok: true, status: 200, json: async () => b, text: async () => t ?? JSON.stringify(b) });
  if (s.endsWith('/utxo')) return ok(cUtxos);
  if (s.endsWith('/fee-estimates')) return ok({ 2: 3 });
  if (s.endsWith('/tx') && opts.method === 'POST') { if (!sentBtc.includes(opts.body)) sentBtc.push(opts.body); return ok(null, 'ok'); }
  return realFetch(url, opts);
};
Object.defineProperty(crypto, 'getRandomValues', { configurable: true, value: (a) => a.fill(0) });
let lockMint, lk;
try { lockMint = makeCbtcLockMint({ priv: u8(seed), pool, cbtcAsset: pool.CBTC_ZK_ASSET_ID }); lk = await lockMint.lock({ amountSats: 100000 }); }
finally { globalThis.fetch = realFetch; delete crypto.getRandomValues; }
if (sentBtc.length !== 2) die('the lock driver did not broadcast a commit and a reveal');
const rev = (h) => Buffer.from(h, 'hex').reverse().toString('hex');
// The reveal's input 0 spends the commit; its witness is [schnorr sig, envelope script, control block].
const rv = Buffer.from(sentBtc[1], 'hex');
const lkCommitTxid = rev(rv.subarray(7, 39).toString('hex'));
const lkBlind = '0x' + BigInt(lk.blinding).toString(16).padStart(64, '0');
const lkXY = pool.commitXY(100000n, lkBlind);
const lkOutpoint = pool.outpointKey(rev(lk.lockTxid), lk.lockVout);
const cdp = makeConfidentialCdp({ keccak256: keccak_256, pool, signSchnorr: () => { throw Error('unused'); } });
const cbtc = {
  utxos: cUtxos, feeRate: 3, amountSats: 100000, commit: sentBtc[0], reveal: sentBtc[1], commitTxid: lkCommitTxid,
  lockTxid: lk.lockTxid, lockVout: lk.lockVout, blinding: lkBlind, cx: lkXY.cx, cy: lkXY.cy, anchor: lk.anchor,
  lockSpk: Buffer.from(lockMint.ownLockScriptPubKey()).toString('hex'), outpoint: lkOutpoint,
  mintOp: cdp.buildCbtcMintOp({ chainBinding: ux.chainBindingHex(), outpoint: lkOutpoint, vBtc: 100000n, blinding: lkBlind }),
};

// A cUSD position opened against that cBTC note by Tacit's own buildCdpMintOp. The position key, the debt
// note's nk and its blinding are HMACs of the Tacit key over (controller, position index), so the key alone
// re-derives every secret of the position; the bearer cBTC leg carries owner 0, as the guest accepts.
const CE = String(cfg.collateralEngine).toLowerCase(), CURVE_N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const cdpSecret = (tag, i) => V.hmac(V.sha256, u8(seed), new Uint8Array([...utf8(tag), ...u8(CE), ...u8(i.toString(16).padStart(8, '0'))]));
const posPriv = BigInt('0x' + Buffer.from(cdpSecret('tacit-cdp-position-v1', 0)).toString('hex')) % CURVE_N || 1n;
const posOwner = '0x' + Buffer.from(secp.getPublicKey(posPriv.toString(16).padStart(64, '0'), true)).subarray(1).toString('hex');
const debtNk = '0x' + Buffer.from(cdpSecret('tacit-cdp-debt-nk-v1', 0)).toString('hex');
const debtBlind = '0x' + (BigInt('0x' + Buffer.from(cdpSecret('tacit-cdp-debt-blinding-v1', 0)).toString('hex')) % CURVE_N || 1n).toString(16).padStart(64, '0');
const cbtcLeaf = pool.leaf(pool.CBTC_ZK_ASSET_ID, lkXY.cx, lkXY.cy, '0x' + '00'.repeat(32));
const cdpPath = pool.merklePath([cbtcLeaf, old.otherLeaf], 0), cdpRoot = pool.merkleRootFrom(cbtcLeaf, 0, cdpPath);
const RAY = '0x' + (10n ** 27n).toString(16).padStart(64, '0'), nonce0 = '0x' + '00'.repeat(32);
const cdpOp = cdp.buildCdpMintOp({
  chainBinding: ux.chainBindingHex(), controller: CE, owner: posOwner, debtOwner: pool.nkToOwner(debtNk), debtValue: 3000000000n,
  nonce: nonce0, rateSnapshot: RAY, fee: 0n, spendRoot: cdpRoot, debtBlinding: debtBlind,
  collateral: [{ asset: pool.CBTC_ZK_ASSET_ID, cx: lkXY.cx, cy: lkXY.cy, owner: '0x' + '00'.repeat(32), nk: '0x' + '00'.repeat(32), value: 100000n, leafIndex: 0, path: cdpPath, blinding: lkBlind }],
});
const cdpLeg = [cdp.basketLeg(pool.CBTC_ZK_ASSET_ID, 100000n)];
const cdpFix = {
  controller: CE, index: 0, debtValue: '3000000000', rateSnapshot: RAY, posOwner, debtNk, debtBlinding: debtBlind, cbtcLeaf, root: cdpRoot, path: cdpPath,
  positionLeaf: cdp.positionLeaf(CE, cdp.debtAssetId(CE), cdp.basketRoot(cdpLeg), 3000000000n, RAY, posOwner, nonce0), op: cdpOp,
  debtMemo: memo.encodeMemo(memo.sealMemo(pub, { value: 3000000000n, blinding: debtBlind, secret: debtNk, asset: cdp.debtAssetId(CE), owner: pool.nkToOwner(debtNk) }, () => BigInt(old.eph))),
};

// A Tacit note on Bitcoin held by this key: a CXFER framed by Tacit's own envelope encoder, its outputs built
// by Tacit's own derivations (tests/composition.mjs). vout 0 is received over ECDH from a sender key, vout 1 is
// this key's own change, vouts 2-3 are the sender's change and padding. Key-alone discovery must open exactly
// vouts 0 and 1, with these amounts.
const Kc = await load('tests/composition.mjs');
const { makeBtcWallet } = await load('dapp/bitcoin-taproot-wallet.js');
const skS = u8('02'.repeat(32)), pkS = secp.getPublicKey(skS, true), myPriv = u8(seed), myPub = u8(pub);
const bIn = { txid: 'cc'.repeat(32), vout: 3 }, bAn = new Uint8Array([...Buffer.from(bIn.txid, 'hex').reverse(), 3, 0, 0, 0]);
const TACID = '0xf0bbe868af10c6c67652a99709bf32048d1aa7194efe3e9a1ef1bde43f94762b';
const compB = (v, r) => {
  if (BigInt(v) === 0n) return Buffer.from(secp.ProjectivePoint.BASE.multiply(BigInt(r)).toRawBytes(true)).toString('hex'); // 0·H + r·G
  const { cx, cy } = pool.commitXY(BigInt(v), r); return (BigInt(cy) & 1n ? '03' : '02') + cx.slice(2);
};
const outsB = [
  [12345678n, Kc.deriveBlinding(skS, myPub, bAn, 0), Kc.deriveAmountKeystreamECDH(skS, myPub, bAn, 0)],
  [777n, Kc.deriveChangeBlinding(myPriv, bAn, 1), Kc.deriveAmountKeystreamSelf(myPriv, bAn, 1)],
  [5000n, Kc.deriveChangeBlinding(skS, bAn, 2), Kc.deriveAmountKeystreamSelf(skS, bAn, 2)],
  [0n, Kc.deriveChangeBlinding(skS, bAn, 3), Kc.deriveAmountKeystreamSelf(skS, bAn, 3)],
];
const payB = new Uint8Array(Buffer.concat([Buffer.from([0x23]), Buffer.from(TACID.slice(2), 'hex'), Buffer.alloc(64), Buffer.from([4]),
  ...outsB.map(([v, r, ks]) => Buffer.concat([Buffer.from(compB(v, r), 'hex'), Buffer.from(Kc.encryptAmount(v, ks))])), Buffer.from([0, 0])]));
try { Kc.decodeCXferPayload(payB); } catch (e) { die('Tacit rejects the fixture CXFER payload: ' + e.message); }
const scrB = makeBtcWallet({ priv: skS, fetchUtxos() {}, broadcastTx() {}, fetchFeeRate() {} }).prims.encodeEnvelopeScript(pkS.slice(1), payB);
const btcNote = {
  txid: 'dd'.repeat(32),
  tx: { txid: 'dd'.repeat(32),
    vin: [{ txid: 'ee'.repeat(32), vout: 0, witness: ['00'.repeat(64), Buffer.from(scrB).toString('hex'), 'c0' + '00'.repeat(32)] },
      { txid: bIn.txid, vout: bIn.vout, witness: ['30'.repeat(71), Buffer.from(pkS).toString('hex')] }],
    vout: [0, 1, 2, 3].map((i) => ({ scriptpubkey: i === 1 ? '5120' + pub.slice(4) : '0014' + '00'.repeat(20), value: 546 })) },
  found: [{ o: 0, a: TACID, v: '12345678' }, { o: 1, a: TACID, v: '777' }],
};
// The leaf Tacit's reflection folds each found output under (the one /reflection/note-witness is asked about):
// btcNoteLeaf over the output's own x-only Taproot key, or 32 zero bytes when the output is not P2TR.
for (const f of btcNote.found) {
  const [v, r] = outsB[f.o], { cx, cy } = pool.commitXY(v, r);
  f.leaf = pool.btcNoteLeaf(TACID, cx, cy, pool.p2trXonly(btcNote.tx.vout[f.o].scriptpubkey) || '0x' + '00'.repeat(32));
}

// One key, two chains: the same key read as a Bitcoin address and a WIF, with Tacit's own primitives.
const btc = { address: bech32.encode('bc', [0, ...bech32.toWords(ripemd160(sha256(u8(pub))))]) };
{ const p = new Uint8Array([0x80, ...u8(seed), 1]); btc.wif = base58.encode(new Uint8Array([...p, ...sha256(sha256(p)).subarray(0, 4)])); }
// A note sealed to this key by someone else (a tacit.finance transfer, say): not index-derived, so only
// trial-decrypting its memo finds it. Key-alone recovery has to.
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const fSecret = '0x' + Buffer.from(sha256(utf8('zswap-found-note-secret'))).toString('hex');
const fBlind = '0x' + (BigInt('0x' + Buffer.from(sha256(utf8('zswap-found-note-blinding'))).toString('hex')) % N).toString(16).padStart(64, '0');
const fOwner = pool.nkToOwner(fSecret), fXY = pool.commitXY(2000000n, fBlind);
const fNote = { value: '2000000', blinding: fBlind, secret: fSecret, asset: ETH, owner: fOwner, cx: fXY.cx, cy: fXY.cy };
const found = { note: fNote, leaf: pool.leaf(ETH, fXY.cx, fXY.cy, fOwner), memo: memo.encodeMemo(memo.sealMemo(pub, fNote, () => BigInt(old.eph))) };

// Private sends, built by Tacit's own code under a fixed random stream that the page replays byte for byte: a self
// transfer splitting the reference note (buildTransferOp), a one-transaction wrap-and-transfer (buildWrapTransferOp),
// a stealth lock of the whole note to another key (stealthSend, as submitted to the relay), the locker's refund of
// that lock, and a claim of a lock another key sent to this one. Tacit's claim/refund wrappers seal the output memo
// a second time inside the relay client, so those two are assembled from buildStealthClaim/buildStealthRefund and one
// seal - the same bytes the page submits. Also the key's unified tacit1 address, with its BIP-352 scan key.
const { makeTacitAddress } = await load('dapp/tacit-address.js');
const rng = (tag) => { let c = 0, buf = new Uint8Array(0); return (a) => { let o = 0; while (o < a.length) { if (!buf.length) buf = sha256(utf8(tag + ':' + c++)); const k = Math.min(buf.length, a.length - o); a.set(buf.subarray(0, k), o); buf = buf.subarray(k); o += k; } return a; }; };
const withRng = async (tag, fn) => { Object.defineProperty(crypto, 'getRandomValues', { configurable: true, value: rng(tag) }); try { return await fn(); } finally { delete crypto.getRandomValues; } };
const scal = (t) => BigInt('0x' + Buffer.from(sha256(utf8(t))).toString('hex')) % N;
const cb = ux.chainBindingHex(), sIn = { ...noteIn, asset: ETH }, DL = 1900800000n, sFee = 10000n, idK = ux.identity(seed);
const xfer = await withRng('zswap-vector-xfer', () => ux.buildTransferOp({ walletPriv: seed, notes: [sIn], recipientPubHex: pub, amount: value / 4n, fee: sFee }));
const wtV = value / 2n;
const wt = await withRng('zswap-vector-wt', () => ux.buildWrapTransferOp({ walletPriv: seed, amountWei: wtV * SCALE, ticker: 'cETH', recipientPubHex: pub, amount: wtV, fee: 0n, index: 0 }));
// The lock set is only in settle() calldata. Tacit's own decoder, run over the stealth lock and the claim of that
// lock its integration doc cites from mainnet, gives the lock leaves, the memo tail and the claim's lock nullifier.
const txIn = async (h) => (await rpc('eth_getTransactionByHash', [h])).input;
const scanLockIn = await txIn('0x20d46c1d47865dc8e906494c57b6d6abe9d2e7b577471864c93df5fd23ce2b0d');
const scanClaimIn = await txIn('0xa34ab7589fe37137d3859f1eefa625c4b8a4ef06932ea89641290f3887be3947');
const lockDec = ux.lockScan.decodeSettleCalldata(scanLockIn), lockFields = ux.lockScan.decodePublicValuesLockFields(lockDec.publicValues);
if (lockFields.lockLeaves.length !== 1) die('the cited stealth lock does not carry exactly one lock leaf');
const scan = { lockInput: scanLockIn, lockLeaves: lockFields.lockLeaves, lockMemos: lockDec.memos.slice(lockFields.leavesCount), leavesCount: lockFields.leavesCount,
  claimInput: scanClaimIn, claimNullifier: pool.nullifier(lockFields.lockLeaves[0]) };
// Those two settles batched through TacitRelayer.relaySettle, both overloads, as Tacit's decoder reads them back.
{
  const coder = AbiCoder.defaultAbiCoder(), SC = 'tuple(bytes,bytes,bytes[])[]';
  const raw = (inp) => { const d = ux.lockScan.decodeSettleCalldata(inp); return [d.publicValues, d.proof, d.memos]; };
  const callsOf = (inp) => ux.lockScan.decodeRelaySettleCalldata(inp).map((c) => {
    const f = ux.lockScan.decodePublicValuesLockFields(c.publicValues);
    return { lockLeaves: f.lockLeaves, leavesCount: f.leavesCount, memos: c.memos };
  });
  scan.relayInput = '0xfcccb833' + coder.encode([SC, 'address[]', 'uint256[]', 'address[]', 'uint256[]'], [[raw(scanClaimIn), raw(scanLockIn)], [ZERO], [0n], [], []]).slice(2);
  scan.seededInput = '0xe2b28725' + coder.encode(['tuple(bytes32,bytes32,uint32)[]', SC, 'address[]', 'uint256[]', 'address[]', 'uint256[]'],
    [[[ETH, '0xf0bbe868af10c6c67652a99709bf32048d1aa7194efe3e9a1ef1bde43f94762b', 30]], [raw(scanLockIn)], [], [], [], []]).slice(2);
  scan.relayCalls = callsOf(scan.relayInput);
  scan.seededCalls = callsOf(scan.seededInput);
  // A claim a searcher resent through its own contract on mainnet to take the relay fee: the settle rides nested in
  // that transaction's calldata. Its lock nullifier is the one of the stealth lock this claim spent.
  const pvArr = (pv, f) => {
    const o = pv.slice(2), d = o.slice(Number(BigInt('0x' + o.slice(0, 64))) * 2), w = (b) => Number(BigInt('0x' + d.slice(b * 2, b * 2 + 64))), off = w(f * 32);
    return Array.from({ length: w(off) }, (_, i) => '0x' + d.slice((off + 32 + i * 32) * 2, (off + 64 + i * 32) * 2));
  };
  scan.nestedInput = await txIn('0x31e16c2a0485536c14ca7994834000017931468adab6682854edf6dba98c74a5');
  scan.nestedCalls = ux.lockScan.decodeNestedSettles(scan.nestedInput).map((c) => {
    const f = ux.lockScan.decodePublicValuesLockFields(c.publicValues);
    return { lockLeaves: f.lockLeaves, leavesCount: f.leavesCount, memos: c.memos, lockNullifiers: pvArr(c.publicValues, 18) };
  });
  if (scan.nestedCalls.length !== 1 || scan.nestedCalls[0].lockNullifiers[0] !== pool.nullifier('0x491b381c314a9ef48dd67358e6e4d14c372e52cae3cc6bdbe69115f645b786e6')) {
    die('the resent claim does not decode to the claim of its stealth lock');
  }
}
const seed2 = '0x' + scal('zswap-send-vector-recipient').toString(16).padStart(64, '0');
const pub2 = '0x' + Buffer.from(secp.getPublicKey(seed2.slice(2), true)).toString('hex');
let built; const s0 = submits.length;
await withRng('zswap-vector-lock', () => ux.stealthSend({ walletPriv: seed, recipientPubHex: pub2, notes: [sIn], amount: value, deadline: DL, onBuilt: (b) => { built = b; } }));
const lockSub = submits[s0];
if (!lockSub || lockSub.type !== 'stealthlock') die('stealthSend did not submit a stealth lock');
// Both apps append a tail to every lock memo, sealed to the SENDER's own key off the memo's ephemeral E:
// key = sha256(compress(a·E) ‖ "tacit-stealth-sender-v1"), a sha256-counter keystream over asset(32) ‖
// amount_be8 ‖ lBlinding(32) ‖ deadline_be8 ‖ refundPriv(32) ‖ ownerPub(32) ‖ recipientPub(33), so the sender's
// key alone finds and refunds an unclaimed lock. Computed here from the spec; Tacit's stealthSend must have
// appended exactly this tail, Tacit's own sender opener must accept it, and its recipient opener must still
// read the 145-byte memo in front of it.
const recipientMemo = lockSub.memos[0].slice(0, 292);
const senderTail = (() => {
  const E = secp.ProjectivePoint.fromHex(lockSub.memos[0].slice(2, 68));
  const key = sha256(new Uint8Array([...E.multiply(BigInt(seed)).toRawBytes(true), ...utf8('tacit-stealth-sender-v1')]));
  const be8 = (x) => u8(BigInt(x).toString(16).padStart(16, '0'));
  const plain = new Uint8Array([...u8(ETH), ...be8(value), ...u8(built.lBlinding), ...be8(DL), ...u8(built.refundPriv), ...u8(built.ownerPub), ...u8(pub2)]);
  const o = new Uint8Array(plain.length);
  for (let i = 0; i < plain.length; i += 32) { const k = sha256(new Uint8Array([...key, i >> 5])); for (let j = 0; j < 32 && i + j < plain.length; j++) o[i + j] = plain[i + j] ^ k[j]; }
  return Buffer.from(o).toString('hex');
})();
const lockMemoFull = recipientMemo + senderTail;
if (lockSub.memos[0] !== lockMemoFull) die('Tacit\'s stealthSend appended a different sender tail than the shared format gives');
if (!ux.airdrop.openStealthMemo({ recipientSpendPriv: seed2, leaf: built.lockLeaf, memoHex: lockMemoFull })) die('Tacit does not open a stealth memo that carries a sender tail');
if (!ux.airdrop.openStealthSenderTail({ senderPriv: seed, ephemeralPub: '0x' + lockMemoFull.slice(2, 68), leaf: built.lockLeaf, tailHex: '0x' + senderTail })) die('Tacit does not open the sender tail');
const lkPath = pool.merklePath([built.lockLeaf], 0), lkRoot = pool.merkleRootFrom(built.lockLeaf, 0, lkPath);
const r0 = submits.length;
await withRng('zswap-vector-refund', () => ux.stealthRefund({ walletPriv: seed, refundPriv: built.refundPriv, lockSetRoot: lkRoot, fee: sFee,
  lockRecord: { asset: ETH, lCx: built.lCx, lCy: built.lCy, ownerPub: built.ownerPub, amount: value, deadline: DL, refundPub: built.refundPub, lBlinding: built.lBlinding, lIndex: 0, lPath: lkPath } }));
const refundSub = submits[r0];
if (!refundSub || refundSub.type !== 'stealthrefund') die('stealthRefund did not submit a refund');
const refund = { op: refundSub.op, memos: refundSub.memos };
const cAmt = 3000000n, e2 = scal('zswap-send-vector-eph'), lb2 = word(scal('zswap-send-vector-lblind')), rp2 = ux.airdrop.refundPubOf(scal('zswap-send-vector-refund'));
const { ownerPub: op2 } = ux.stealth.oneTimeAddress({ recipientSpendPub: pub, ephemeralPriv: e2 });
const c2 = pool.commitXY(cAmt, lb2), leaf2 = ux.stealth.stealthLockLeafBlind(ETH, c2.cx, c2.cy, op2, DL, rp2);
const memo2 = ux.airdrop.sealStealthMemo({ recipientSpendPub: pub, ephemeralPriv: e2, asset: ETH, amount: cAmt, lBlinding: lb2, deadline: DL, refundPub: rp2 });
const opened = ux.airdrop.openStealthMemo({ recipientSpendPriv: seed, leaf: leaf2, memoHex: memo2 });
if (!opened) die('Tacit could not open the stealth memo it sealed to this key');
const { oneTimePriv } = ux.stealth.recoverOneTimeKey({ recipientSpendPriv: seed, ephemeralPub: opened.ephemeralPub });
const cPath = pool.merklePath([built.lockLeaf, leaf2], 1), cRoot = pool.merkleRootFrom(leaf2, 1, cPath);
const k0 = submits.length;
await withRng('zswap-vector-claim', () => ux.stealthClaim({ walletPriv: seed, lockRecord: { ...opened, oneTimePriv, leaf: leaf2, lIndex: 1, lPath: cPath }, lockSetRoot: cRoot, fee: sFee }));
const claimSub = submits[k0];
if (!claimSub || claimSub.type !== 'stealthclaim') die('stealthClaim did not submit a claim');
const claim = { op: claimSub.op, memos: claimSub.memos };
// A partial withdrawal: Tacit's sendUnwrap pays 0.004 out of the 0.01 note and keeps the rest as shielded change,
// under a change owner derived from the note's own blinding (so a retry rebuilds the same op).
const suAmt = 400000n, s1 = submits.length;
Date.now = () => (Number(old.unwrapDeadline) - 3600) * 1000;
try { await withRng('zswap-vector-su', () => ux.sendUnwrap({ note: sIn, walletPriv: seed, recipient: account, amount: suAmt, feeOpts: { minFee: sFee, feeBps: 0n }, wait: false })); }
finally { Date.now = realNow; }
const suSub = submits[s1];
if (!suSub || suSub.type !== 'sendunwrap') die('sendUnwrap did not submit a send-and-unwrap');
if (suSub.op.input.nk !== suSub.op.input.secret) die('Tacit\'s send-and-unwrap op does not carry the input nk exec-sendunwrap reads');
const su = { tag: 'zswap-vector-su', amount: String(suAmt), recipient: account, deadline: old.unwrapDeadline, op: suSub.op, memos: suSub.memos };
const tagged = (t, m) => { const h = sha256(utf8(t)); return sha256(new Uint8Array([...h, ...h, ...m])); };
const scanPriv = BigInt('0x' + Buffer.from(tagged('BIP0352/ScanKey', u8(seed))).toString('hex')) % N;
const spendPub = secp.getPublicKey(u8(seed), true);
const address = makeTacitAddress({ secp }).encodeTacitAddress({ network: 'mainnet', btcSpendPub: spendPub, btcScanPub: secp.getPublicKey(scanPriv.toString(16).padStart(64, '0'), true), evmOwnerPub: spendPub });
const send = {
  fee: String(sFee), deadline: String(DL), address,
  xfer: { tag: 'zswap-vector-xfer', amount: String(value / 4n), op: xfer.op, memos: xfer.memos },
  scan, su,
  exitWithMemo: router.exitAndExecuteCalldata({ publicValues: '0x1234', proof: '0xabcdef', memos: xfer.memos.slice(0, 1), recipe: recipeBase }),
  wt: { tag: 'zswap-vector-wt', value: String(wtV), index: 0, op: wt.op, memos: wt.memos, commit: wt.depositCommit, depositId: wt.depositId,
    calldata: router.wrapAndSettleETHCalldata({ wrapAmount: wtV * SCALE, commit: wt.depositCommit, publicValues: '0x1234', proof: '0xabcdef', memos: wt.memos, feeRecipient: ZERO }) },
  lock: { tag: 'zswap-vector-lock', recipient: pub2, op: lockSub.op, memo: recipientMemo, memoFull: lockMemoFull, refundPriv: built.refundPriv, lBlinding: built.lBlinding, lockRoot: lkRoot, lockPath: lkPath },
  refund: { tag: 'zswap-vector-refund', op: refund.op, memos: refund.memos },
  claim: { tag: 'zswap-vector-claim', leaf: leaf2, memo: memo2, lockRoot: cRoot, lockPath: cPath, op: claim.op, memos: claim.memos },
};

// Tacit's own KAT for the deposit commitment and id — the primitive an
// invoice and an ordinary wrap share. The page derives both itself, so this is
// what catches a divergence rather than the shared-code-path argument.
const KAT = path.join(TACIT, 'contracts', 'sp1', 'confidential', 'fixtures', 'deposit_id_vectors.json');
const depositIdKat = fs.existsSync(KAT)
  ? JSON.parse(fs.readFileSync(KAT, 'utf8')).vectors.map(
      ({ assetId, value, cx, cy, owner, depositCommit, depositId }) =>
        ({ assetId, value, cx, cy, owner, depositCommit, depositId }))
  : die('no deposit_id_vectors.json in ' + KAT + ' — update the Tacit checkout');

const out = {
  depositIdKat,
  account, sig: old.sig, identityMessage, seed, pub, pool: getAddress(cfg.pool), router: getAddress(cfg.router), executorImpl,
  ethAssetId: ETH, H: { x: word(hA.x), y: word(hA.y) }, amountWei: old.amountWei, index: old.index,
  note, leaf: w.leaf, depositId: w.depositId, commit: w.commit, wrapOp: w.wrapOp, wrapCalldata: w.calldata,
  eph: old.eph, memo: memoHex, otherLeaf: old.otherLeaf, root, path: path0, nullifier,
  gasPriceWei: old.gasPriceWei, minFee: String(minFee), fee: String(fee), net: String(net), netWei: String(netWei),
  nonce, deadline: old.deadline, unwrapDeadline: old.unwrapDeadline,
  base: {
    recipe: recipeBase, escrow: escrowBase, escrowCalldata: router.escrowAddressForCalldata(recipeBase),
    activate: router.activateExitCalldata(recipeBase), reclaim: router.reclaimExitCalldata(recipeBase, []),
    exitAndExecute: router.exitAndExecuteCalldata({ publicValues: '0x1234', proof: '0xabcdef', memos: [], recipe: recipeBase }),
  },
  robinhood: {
    est: R.est, sub: R.sub, l2Gas: R.l2Gas, gasLimit: R.gasLimit, maxSubmissionCost: R.maxSubmissionCost,
    maxFeePerGas: R.maxFeePerGas, l2CallValue: String(netWei - over),
    recipe: recipeRh, escrow: escrowRh, activate: router.activateExitCalldata(recipeRh),
  },
  unwrapRelay, unwrapSelf, tac, btc, found, cbtc, cdp: cdpFix, btcNote, send,
};
const text = JSON.stringify(out, (_k, v) => (typeof v === 'bigint' ? v.toString() : v), 1);

const flat = (o, p = '', acc = {}) => { for (const [k, v] of Object.entries(o)) { if (v && typeof v === 'object') flat(v, p + k + '.', acc); else acc[p + k] = String(v); } return acc; };
const a = flat(old), b = flat(JSON.parse(text));
const changed = Object.keys(b).filter((k) => a[k] !== b[k]);
const gone = Object.keys(a).filter((k) => !(k in b));
fs.writeFileSync(FIX, text);
console.log(`pool ${out.pool}  router ${out.router}  executorImpl ${executorImpl}`);
console.log(`escrows match the live router: Base ${escrowBase}, Robinhood ${escrowRh}`);
console.log(changed.length ? `changed (${changed.length}):\n  ` + changed.join('\n  ') : 'no field changed');
if (gone.length) console.log('dropped:\n  ' + gone.join('\n  '));
