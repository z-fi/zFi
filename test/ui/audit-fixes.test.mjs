/**
 * Fixes from the pre-deploy audit. Each case failed on the page before it.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const RATE = 3000n * ETH;

const connected = async (over = {}) => {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: RATE });
  Object.assign(chain, over.chain || {});
  const p = await loadPage({ chain, ...over.page });
  await p.connect(over.connect);
  return p;
};
const intercept = (c, fn) => {
  const d = c.dispatch.bind(c);
  c.dispatch = async (m, a) => { const r = await fn(m, a, d); return r === undefined ? d(m, a) : r; };
};
const abiString = s => {
  const h = Buffer.from(s).toString('hex');
  return '0x08c379a0' + (32).toString(16).padStart(64, '0') + s.length.toString(16).padStart(64, '0')
    + h.padEnd(Math.ceil(h.length / 64) * 64, '0');
};

describe('what a node returns is not markup', () => {
  test('a receipt hash that is not a hash never reaches the status line as HTML', async () => {
    const p = await connected();
    intercept(p.chain, m => {
      if (m === 'eth_getTransactionReceipt') return { status: '0x1', transactionHash: '"><img src=x id=pwn>', logs: [] };
    });
    await p.typeAmount('amt', '1');
    p.click('swap');
    await p.waitFor(() => /Done/.test(p.text('stat')), { label: 'done' });
    assert.equal(p.$('pwn'), null, 'no element was injected');
    assert.match(p.$('stat').innerHTML, /\/tx\/0x[0-9a-f]{64}"/, 'the link is the hash the wallet returned');
    p.close();
  });

  test('a future-dated endpoint roster in storage is not trusted', async () => {
    const evil = 'https://evil.example/rpc';
    const p = await loadPage({ chain: new MockChain(), walletless: true, hash: null,
      storage: { 'zswap:ep': JSON.stringify({ t: 9e15, v: [[evil], [evil], [], [], [], [], [], [evil]] }) } });
    await p.settle();
    assert.ok(!p.window.eval('L1_RPCS').includes(evil));
    assert.ok(!p.window.eval('CHAINS[8453].rpcs').includes(evil));
    p.close();
  });
});

describe('a link that changes under the user', () => {
  test('a hash change that rewrites the amount holds the button briefly', async () => {
    const p = await connected({ page: { hash: 'token=ETH&out=USDC&amount=1' } });
    await p.settle();
    p.window.location.hash = '#token=ETH&out=USDC&amount=2';
    await p.waitFor(() => p.value('amt') === '2', { label: 'link applied' });
    const sent = p.chain.sent.length;
    p.click('swap');
    await p.settle();
    assert.match(p.text('stat'), /link just changed/);
    assert.equal(p.chain.sent.length, sent, 'nothing was sent');
    p.close();
  });
});

describe('errors people can read', () => {
  const explain = (p, e) => p.window.eval(`explain(${JSON.stringify(e)})`);

  test('an Error(string) revert is decoded', async () => {
    const p = await loadPage({ chain: new MockChain(), walletless: true, hash: null });
    assert.equal(explain(p, { data: abiString('Too little received') }), 'The contract refused: Too little received');
    assert.match(explain(p, { data: '0x4e487b71' + '11'.padStart(64, '0') }), /arithmetic limit/);
    p.close();
  });

  test('a custom error wrapped inside another is still recognised', async () => {
    const p = await loadPage({ chain: new MockChain(), walletless: true, hash: null });
    const inner = '2746152a' + '0'.repeat(128);
    const wrapped = '0x90bfb865' + '0'.repeat(64) + 'aa'.repeat(32) + inner.padEnd(Math.ceil(inner.length / 64) * 64, '0');
    assert.match(explain(p, { data: wrapped }), /slippage/i);
    p.close();
  });

  test('a page message is shown whole, without an "Error:" prefix', async () => {
    const p = await loadPage({ chain: new MockChain(), walletless: true, hash: null });
    const long = 'insufficient balance ' + 'x'.repeat(300);
    const out = explain(p, { message: long });
    assert.ok(!/^Error:/.test(out));
    assert.equal(out.length, 220);
    assert.equal(p.window.eval('isRejection(Error("Unlock cancelled."))'), true, 'a cancel is not an error');
    p.close();
  });

  test('a transaction that fails on chain keeps its explorer link', async () => {
    const p = await connected();
    await p.typeAmount('amt', '1');
    p.chain.failNextReceipt = true;
    p.click('swap');
    await p.waitFor(() => /Failed/.test(p.text('stat')), { label: 'failure' });
    assert.match(p.$('stat').innerHTML, /\/tx\/0x[0-9a-f]{64}/);
    assert.match(p.text('stat'), /reverted on chain/);
    p.close();
  });
});

describe('state across a chain change', () => {
  test('a send prepared on one chain is refused on another', async () => {
    const p = await connected();
    p.click('amt');
    p.window.eval('setChain(8453)');
    const r = await p.window.eval(`sendTx([{from:"${A.ACCOUNT}",to:"${A.ACCOUNT}",value:"0x0"}]).then(()=>"sent",e=>e.message)`);
    assert.match(r, /network changed after you pressed/);
    p.close();
  });

  test('an expired quote leaves the button live, and pressing it re-quotes', async () => {
    const p = await connected();
    await p.typeAmount('amt', '1');
    p.window.eval('last.exp=Date.now()-1;render()');
    assert.equal(p.disabled('swap'), false);
    assert.match(p.text('swap'), /expired/i);
    p.close();
  });
});

/**
 * Walletless and WalletConnect reads go to public nodes, one HTTP request per
 * call. Calls made in the same tick now share one JSON-RPC batch, and a node
 * that will not batch is answered one call at a time.
 */
describe('reads to public nodes', () => {
  const quoteWalletless = async chainOpts => {
    const chain = new MockChain();
    chain.quoteHandler = fixedRateQuoter({ rate: RATE });
    Object.assign(chain, chainOpts);
    const p = await loadPage({ chain, walletless: true, hash: 'token=ETH&out=USDC' });
    await p.settle();
    await p.typeAmount('amt', '1');
    return p;
  };

  test('calls made together travel in one request', async () => {
    const p = await quoteWalletless();
    const log = p.chain.httpLog.filter(r => r.method);
    assert.ok(log.some(r => r.batch > 1), 'some calls were batched');
    assert.notEqual(p.value('outAmt'), '', 'and the quote still landed');
    p.close();
  });

  test('a node that refuses batches still answers every call', async () => {
    const p = await quoteWalletless({ noBatch: true });
    assert.notEqual(p.value('outAmt'), '');
    assert.ok(p.window.eval('nqOff') > Date.now(), 'batching rests after a refusal');
    p.close();
  });
});

/**
 * A self-submitted settle reserves gasLimit x maxFee up front. A wallet short
 * of that gets a transaction a public node accepts and then silently drops,
 * so the page refuses before signing and points at the relay.
 */
describe('submitting a private settle yourself', () => {
  test('is refused before signing when the wallet cannot pay the gas', async () => {
    const p = await connected();
    p.chain.setNative(A.ACCOUNT, 1000n);
    const r = await p.window.eval('cpGasOk({value:"0x0",gas:"0xaae60"}).then(()=>"ok",e=>e.message)');
    assert.match(r, /too little ETH .* through the relay/);
    p.chain.setNative(A.ACCOUNT, 10n * ETH);
    assert.equal(await p.window.eval('cpGasOk({value:"0x0",gas:"0xaae60"}).then(()=>"ok",e=>e.message)'), 'ok');
    p.close();
  });
});
