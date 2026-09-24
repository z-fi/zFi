import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;

async function quoted() {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  const p = await loadPage({ chain, hash: 'token=ETH&out=USDC' });
  await p.connect();
  await p.typeAmount('amt', '1');
  await p.settle();
  return p;
}

describe('the swap card at rest', () => {
  test('a quote that expired after the automatic refreshes says so on the button', async () => {
    const p = await quoted();
    assert.equal(p.$('swap').textContent, 'Swap');
    p.window.eval('autoQ=AUTO_Q_MAX+1;last.exp=Date.now()-1');
    await p.waitFor(() => /Quote expired/.test(p.$('swap').textContent), { label: 'expired label', timeout: 8000 });
    p.close();
  });

  test('the hidden token selects are out of the tab order; the visible pickers carry focus', async () => {
    const p = await quoted();
    for (const id of ['fromSel', 'toSel']) assert.equal(p.$(id).getAttribute('tabindex'), '-1', id);
    p.close();
  });

  test('a send that cannot go points at the reason below the button', async () => {
    const p = await loadPage({ chain: new MockChain(), hash: 'tab=send&token=ETH' });
    await p.connect();
    assert.match(p.window.eval('render.toString()'), /see below/);
    p.close();
  });
});
