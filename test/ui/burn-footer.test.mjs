import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage } from './harness.mjs';

const ETH = 10n ** 18n;
const BETH = '0x2cb662ec360c34a45d7ca0126bcd53c9a1fd48f9';

/**
 * How much ether this launchpad has destroyed.
 *
 * A tenth of every fee is burned through the canonical BETH burner, which
 * mints a receipt to the DAO recording it happened. That receipt balance IS
 * the running total - the ether itself is gone, so there is nothing else left
 * to count.
 */
async function open_(burned) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  if (burned !== undefined) {
    chain.setToken(BETH, { symbol: 'BETH', decimals: 18, name: 'Burned ETH' });
    chain.setErc20(BETH, '0x5e58ba0e06ed0f5558f83be732a4b899a674053e', burned);
  }
  const p = await loadPage({ chain });
  await p.settle();
  return p;
}

describe('the burn counter in the footer', () => {
  test('shows the running total without a wallet', async () => {
    // The whole point is that a visitor sees it before doing anything.
    const p = await open_(59652212438077211n);
    assert.match(p.$('footBurn').textContent, /0\.0597 ETH burned/, p.$('footBurn').textContent);
    p.close();
  });

  test('links to the receipt rather than asking to be believed', async () => {
    const p = await open_(1n * ETH);
    const a = p.$('footBurn').querySelector('a');
    assert.ok(a, 'the figure is not a link');
    assert.match(a.href, /etherscan/);
    assert.ok(a.href.includes(BETH.slice(2)) || a.href.toLowerCase().includes(BETH), 'does not point at BETH');
    p.close();
  });

  test('shows nothing rather than a zero before anything is burned', async () => {
    const p = await open_(0n);
    assert.equal(p.$('footBurn').textContent, '', 'a zero counter is noise');
    p.close();
  });

  test('a footer that cannot reach the chain simply says less', async () => {
    // It must never be able to take the page down with it.
    const p = await open_(undefined);
    assert.equal(p.$('footBurn').textContent, '');
    assert.ok(p.$('foot').textContent.includes('how it works'), 'the rest of the footer survived');
    p.close();
  });
});
