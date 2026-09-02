import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { AbiCoder } from 'ethers';
import { readFileSync } from 'node:fs';
import {
  A, MockChain, loadPage, fixedRateQuoter, closeAllPages,
} from './harness.mjs';

// Read out of the page rather than copied, so moving the pin cannot leave this
// suite green against an address nothing asks for.
const RPCS_PIN = /const RPCS_PIN="(0x[0-9a-fA-F]{40})"/
  .exec(readFileSync(new URL('../../zSwap.html', import.meta.url), 'utf8'))[1];

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const coder = AbiCoder.defaultAbiCoder();

/**
 * The page before any wallet exists.
 *
 * A deeplink lands people on the dapp with nothing but a browser. Everything
 * they came for - the quote, the token list, the chart - is a read, and reads
 * go through the page's public-RPC pool: the endpoints the v0.3 deployment
 * curates on chain, merged ahead of the seeds baked into the page. Signing is
 * the only thing that must stay impossible, and it walls at the wallet picker.
 */
describe('the page before any wallet exists', () => {
  const chainWithQuote = () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    return chain;
  };

  test('quotes a pair from the public pool', async () => {
    const chain = chainWithQuote();
    const p = await loadPage({ walletless: true, chain });
    assert.ok((chain.httpLog || []).length > 0, 'no read ever left through the pool');
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'the quote did not resolve without a wallet');
    p.close();
  });

  test('a failing endpoint is rotated off, not fatal', async () => {
    const chain = chainWithQuote();
    const p = await loadPage({ walletless: true, chain });
    chain.failNext = 1; // the first node of the next read is down
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'failover did not reach the second endpoint');
    p.close();
  });

  test('the send tab still walls at the wallet picker', async () => {
    const chain = chainWithQuote();
    const p = await loadPage({ walletless: true, chain });
    p.click('tabSend');
    p.type('rc', A.ACCOUNT);
    p.type('amt', '1');
    await p.settle();
    p.click('swap');
    await p.settle();
    assert.ok(!p.$('wkWrap').classList.contains('hide'), 'the wallet picker did not open');
    assert.equal(chain.sent.length, 0, 'something was sent without a wallet');
    p.close();
  });

  test('the DAO-curated list is adopted ahead of the seeds', async () => {
    const SELF = '0x' + 'ab'.repeat(20);
    // The roster address is pinned in the page's own bytes - it is no longer
    // read off the contract serving the page, because on a .wei or IPFS name
    // there is no address in the host to read it from. Answer where the page
    // actually asks, or this tests a lookup that no longer exists.
    const LIST = RPCS_PIN;
    const URL = 'https://curated.example';
    const chain = chainWithQuote();
    const ethCall = chain.ethCall.bind(chain);
    chain.ethCall = (tx, block) => {
      if ((tx.to || '').toLowerCase() === LIST.toLowerCase() && tx.data.startsWith('0xd77e4c79'))
        return coder.encode(['string[]'], [[URL]]); // rpcs()
      return ethCall(tx, block);
    };
    const p = await loadPage({
      walletless: true, chain,
      url: 'https://' + SELF + '.1.w3link.io/',
      hash: 'token=ETH&out=USDC',
    });
    await p.settle(); // the init-time curated load
    await p.typeAmount('amt', '1');
    await p.settle();
    const urls = (chain.httpLog || []).map(h => h.url);
    assert.ok(urls.includes(URL), `the curated endpoint was never used: got ${[...new Set(urls)].join(', ')}`);
    p.close();
  });

  // The satellite is the one mutable surface the walletless read path depends
  // on, so every way it can fail has to end with the page still working on the
  // endpoints it shipped with - never with a blank page, and never with a
  // retry loop that runs for the life of the session.
  test('a satellite that cannot be read leaves the seeds intact', async () => {
    const SELF = '0x' + 'ab'.repeat(20);
    const chain = chainWithQuote();
    const ethCall = chain.ethCall.bind(chain);
    chain.ethCall = (tx, block) => {
      // A version that predates the satellite: RPCS() is not a function here.
      if ((tx.to || '').toLowerCase() === SELF) throw new Error('execution reverted');
      return ethCall(tx, block);
    };
    const p = await loadPage({
      walletless: true, chain,
      url: 'https://' + SELF + '.1.w3link.io/',
      hash: 'token=ETH&out=USDC',
    });
    await p.settle();
    await p.typeAmount('amt', '1');
    await p.settle();
    assert.equal(p.value('outAmt'), '3000', 'the quote died with the curation read');
    p.close();
  });

  // A single node answering this call would decide which node answers every
  // call after it. Two must agree, and one of the two is always a seed the
  // curation cannot displace.
  test('a curated list only one node vouches for is not adopted', async () => {
    const SELF = '0x' + 'ab'.repeat(20);
    const LIST = '0x' + 'cd'.repeat(20);
    const EVIL = 'https://evil.example';
    const chain = chainWithQuote();
    const ethCall = chain.ethCall.bind(chain);
    let asked = 0;
    chain.ethCall = (tx, block, url) => {
      if ((tx.to || '').toLowerCase() === SELF && tx.data.startsWith('0x0b6feb61'))
        return coder.encode(['address'], [LIST]);
      if ((tx.to || '').toLowerCase() === LIST && tx.data.startsWith('0xd77e4c79')) {
        // Only the first endpoint asked tells the lie; the seed disagrees.
        asked++;
        return coder.encode(['string[]'], [asked === 1 ? [EVIL] : []]);
      }
      return ethCall(tx, block, url);
    };
    const p = await loadPage({
      walletless: true, chain,
      url: 'https://' + SELF + '.1.w3link.io/',
      hash: 'token=ETH&out=USDC',
    });
    await p.settle();
    await p.typeAmount('amt', '1');
    await p.settle();
    const urls = (chain.httpLog || []).map(h => h.url);
    assert.ok(!urls.includes(EVIL), 'a list only one node vouched for was adopted');
    p.close();
  });

  test('the registry token list loads without a wallet', async () => {
    const chain = chainWithQuote();
    chain.registry = [regRow('ZREG', '0x' + 'ee'.repeat(20))];
    const p = await loadPage({ walletless: true, chain, hash: 'token=ETH&out=USDC' });
    await p.settle();
    await p.waitFor(
      () => [...p.$('toSel').options].some(o => o.textContent.startsWith('ZREG')),
      { label: 'registry token appearing in the picker' },
    );
    p.close();
  });
});

/** The registry-row shape the lens serves — see floor-quote.test.mjs for the fuller form. */
const regRow = (s, a) => ({
  i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
  a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true,
});
