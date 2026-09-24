import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
// A real mainnet buildBestSwap answer for 1 ETH -> USDC (about 1,888 USDC).
const ONE_HOP = JSON.parse(fs.readFileSync(new URL('../fixtures/quoter.json', import.meta.url), 'utf8')).singleHop_ETH_USDC;

async function book() {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 100n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 500_000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  chain.answer(A.ZQUOTER, 'e7798987', ONE_HOP.data);
  const p = await loadPage({ chain });
  await p.connect();
  p.click('tabBook');
  await p.settle();
  return p;
}

describe('a limit order far under the market', () => {
  test('asks first, and sends nothing when the user declines', async () => {
    const p = await book();
    p.type('amt', '1');
    p.type('outAmt', '100');
    await p.settle();
    p.click('swap');
    await p.waitFor(() => p.asked.confirm.length > 0, { label: 'price check' });
    await p.settle();
    assert.match(p.asked.confirm[0], /under the market/);
    assert.equal(p.chain.sent.length, 0);
    p.close();
  });

  test('at the market price goes straight through', async () => {
    const p = await book();
    p.type('amt', '1');
    p.type('outAmt', '1900');
    await p.settle();
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'placement' });
    assert.equal(p.asked.confirm.length, 0);
    p.close();
  });
});

describe('recipients and messages', () => {
  test('a routing contract is refused as a recipient', async () => {
    const p = await loadPage({ chain: new MockChain(), walletless: true, hash: null });
    assert.match(p.window.eval('rcErr(ZROUTER)'), /routing contract/);
    assert.equal(p.window.eval('rcErr(A_OK)'.replace('A_OK', JSON.stringify(A.OTHER))), '');
    p.close();
  });

  test('a closed market reads in plain words', async () => {
    const p = await loadPage({ chain: new MockChain(), walletless: true, hash: null });
    assert.match(p.window.eval('explain({data:"0xe2c865df"})'), /closed/);
    p.close();
  });

  test('on Base the balance line names the chain', async () => {
    const chain = new MockChain({ chainId: '0x2105' });
    chain.setNative(A.ACCOUNT, 2n * ETH);
    const p = await loadPage({ chain });
    await p.connect({ pin: false });
    await p.settle();
    assert.match(p.window.document.body.textContent, /Balance on Base:/);
    p.close();
  });
});
