import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';
after(closeAllPages);
const ETH = 10n ** 18n;

test('a send the wallet fails, while its nonce read hangs, still reports and frees the button', async () => {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  const p = await loadPage({ chain });
  await p.connect();
  p.click('tabSend');
  await p.settle();
  await p.typeAmount('amt', '1');
  p.type('rc', A.OTHER);
  await new Promise(r => p.window.setTimeout(r, 320));
  await p.settle();
  const d = chain.dispatch.bind(chain);
  chain.dispatch = async (m, a) => {
    if (m === 'eth_getTransactionCount' && a[1] === 'pending') return new Promise(() => {});
    if (m === 'eth_sendTransaction') throw Object.assign(new Error('Internal JSON-RPC error.'), { code: -32603 });
    return d(m, a);
  };
  p.click('swap');
  await new Promise(r => setTimeout(r, 12000));
  console.log('stat=', JSON.stringify(p.text('stat')), 'busy=', p.window.eval('busy'), 'disabled=', p.disabled('swap'));
  assert.match(p.text('stat'), /RPC/);
  assert.equal(p.window.eval('busy'), 0);
  p.close();
});
