import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';
after(closeAllPages);
const ETH = 10n ** 18n;

test('a wallet that changes network while the pending-nonce read is out is not handed the send', async () => {
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
  assert.equal(p.disabled('swap'), false);
  const d = chain.dispatch.bind(chain);
  let flipped = false;
  chain.dispatch = async (m, a) => {
    if (m === 'eth_getTransactionCount' && a[1] === 'pending' && !flipped) {
      flipped = true;
      chain.chainId = '0x2105';
      p.emit('chainChanged', '0x2105');
    }
    return d(m, a);
  };
  p.click('swap');
  await new Promise(r => setTimeout(r, 1500));
  await p.settle();
  const sends = chain.log.filter(r => r.method === 'eth_sendTransaction');
  console.log('flipped', flipped, 'sends', sends.length, 'chainAtSend', chain.chainId, 'stat', p.text('stat'));
  assert.equal(sends.length, 0, 'eth_sendTransaction must not reach a wallet now on Base');
  p.close();
});
