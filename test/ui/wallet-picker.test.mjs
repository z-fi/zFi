import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { MockChain, loadPage } from './harness.mjs';

/**
 * Two extensions in one browser both write window.ethereum, so the last one to
 * load wins and the other is unreachable no matter which the person actually
 * wanted to pay with. EIP-6963 has each announce itself with an id, so the page
 * can address them individually and let the user choose.
 *
 * A wallet announces in reply to the page's request event, which is what these
 * fakes do - the page scans at load and again when connect is pressed.
 */
// What a real extension announces: a data URI it supplies itself.
const ICON = 'data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\'/%3E';

function announce(win, chain, wallets) {
  const seen = [];
  win.addEventListener('eip6963:requestProvider', () => {
    for (const w of wallets) {
      win.dispatchEvent(new win.CustomEvent('eip6963:announceProvider', {
        detail: {
          info: { uuid: w.uuid, name: w.name, rdns: `x.${w.uuid}`, icon: ICON },
          provider: {
            request: args => { seen.push([w.name, args.method]); return chain.request(args); },
            on: () => {},
          },
        },
      }));
    }
  });
  return seen;
}

const rows = p => [...p.$('wkList').querySelectorAll('.tkr')].map(r => r.textContent);
const open = p => !p.$('wkWrap').classList.contains('hide');

describe('choosing among several wallets', () => {
  test('two announced wallets produce a chooser, and the pick is what gets used', async () => {
    const chain = new MockChain();
    const p = await loadPage({ chain });
    const seen = announce(p.window, chain, [
      { uuid: 'a1', name: 'Alpha Wallet' },
      { uuid: 'b2', name: 'Beta Wallet' },
    ]);

    p.click('swap');
    await p.settle();
    assert.ok(open(p), 'two wallets did not produce a chooser');
    assert.deepEqual(rows(p), ['Alpha Wallet', 'Beta Wallet', 'WalletConnect']);
    // Every row carries a mark, including the one no extension announced - a
    // bare row reads as broken next to four that are not. The WalletConnect
    // mark is page bytes, not a link to walletconnect.com.
    const wc = [...p.$('wkList').querySelectorAll('.tkr')][2];
    assert.ok(wc.querySelector('.wki svg'), 'the WalletConnect row has no icon');
    assert.equal(p.$('wkList').querySelectorAll('img,.wki').length, 3,
      'not every wallet row carries a mark');

    // Pick the second one - the one that would have lost the window.ethereum race.
    [...p.$('wkList').querySelectorAll('.tkr')][1].click();
    await p.settle();
    assert.ok(!open(p), 'the chooser stayed open after a pick');
    assert.ok(seen.some(([n, m]) => n === 'Beta Wallet' && m === 'eth_requestAccounts'),
      'the chosen wallet was never asked to connect');
    assert.ok(!seen.some(([n]) => n === 'Alpha Wallet'),
      'the wallet the user did not pick was used anyway');
    p.close();
  });

  test('a lone injected wallet stays one click, with no chooser', async () => {
    const p = await loadPage({ chain: new MockChain() });
    p.click('swap');
    await p.settle();
    assert.ok(!open(p), 'a chooser interrupted someone who had only one wallet');
    p.close();
  });

  test('backing out of the chooser connects nothing', async () => {
    const chain = new MockChain();
    const p = await loadPage({ chain });
    const seen = announce(p.window, chain, [
      { uuid: 'a1', name: 'Alpha Wallet' },
      { uuid: 'b2', name: 'Beta Wallet' },
    ]);
    p.click('swap');
    await p.settle();
    assert.ok(open(p));
    p.$('wkWrap').click();
    await p.settle();
    assert.ok(!open(p), 'the chooser survived a click on the backdrop');
    assert.equal(seen.length, 0, 'backing out still talked to a wallet');
    p.close();
  });

  test('hammering connect asks the wallet exactly once', async () => {
    // The re-entrancy latch used to be set AFTER the chooser was awaited, so
    // every click landing in that window sent its own eth_requestAccounts.
    // Wallets rate-limit that ("DApp requests are too frequent"), which reads
    // as the page being broken. One injected wallet is the case that bites:
    // wkResolve returns straight away, so all the clicks get through together.
    const chain = new MockChain();
    const p = await loadPage({ chain });
    const asks = [];
    const inner = p.window.ethereum.request;
    p.window.ethereum.request = args => { asks.push(args.method); return inner(args); };
    p.click('swap');
    p.click('swap');
    p.click('swap');
    await p.settle();
    const n = asks.filter(m => m === 'eth_requestAccounts').length;
    assert.equal(n, 1, `the wallet was asked to connect ${n} times`);
    p.close();
  });

  test('an injected wallet never touches the read node', async () => {
    // The HTTP read node exists solely because routing every eth_call to a
    // phone measured ~5s per round trip over the WalletConnect relay. It must
    // stay sealed inside that case: a browser wallet is already an RPC, so a
    // page that quietly called out to a third party for reads would be a trust
    // assumption nobody asked for and nobody could see.
    const chain = new MockChain();
    const p = await loadPage({ chain });
    const calls = [];
    p.window.fetch = (...a) => { calls.push(String(a[0])); return Promise.reject(Error('no')); };
    p.click('swap');
    await p.settle();
    await p.settle();
    assert.equal(p.$('addr').textContent.includes('0x'), true, 'the injected wallet did not connect');
    assert.deepEqual(calls, [], `the page called out to ${calls.join(', ')}`);
    p.close();
  });
});
