/**
 * Shareable links: the deep-link reader (applyLink) and the share button that
 * produces them.
 *
 * The documented contract, from the page itself:
 *   #to=alice.wei&amount=10&token=USDC          request a payment
 *   #to=alice.wei&amount=1&token=ETH&lock=1d    request it time-locked via SLOW
 *   #token=ETH&out=USDC&amount=500&exactOut=1   "pay me 500 USDC, spend ETH"
 * token/out accept a symbol or a 0x address; lock accepts seconds or 1h/1d/1w.
 *
 * A link is an untrusted string that arrives from a stranger, so the two things
 * under test are: it fills the form it claims to, and it can never do anything
 * on its own.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const MOON = '0x1234567890abcdef1234567890abcdef12345678';

async function open(hash, prep = () => {}) {
  const chain = new MockChain({ autoConnected: true });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 1000n * USDC);
  chain.setErc20(A.WBTC, A.ACCOUNT, 10n ** 8n);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  prep(chain);
  const p = await loadPage({ chain, hash });
  await p.settle();
  return p;
}

const tabOf = p => ['Swap', 'Send', 'Book']
  .find(t => p.$('tab' + t).getAttribute('aria-selected') === 'true');
const symOf = (p, which) => p.$(which).selectedOptions[0]?.textContent;

/**
 * Click share and wait for the handler to FINISH, not merely for the clipboard
 * write to resolve — the status line is written after the await, so returning
 * early both races that assertion and tears the window down mid-handler.
 */
async function share(p) {
  p.$('stat').textContent = '';   // so a leftover status cannot end the wait early
  p.click('lk');
  await p.waitFor(() => p.text('stat') !== '', { label: 'share to complete' });
  return p.copied()[p.copied().length - 1];
}

describe('payment request links', () => {
  test('the documented payment link fills every field it names', async () => {
    const p = await open('to=alice.wei&amount=10&token=USDC',
      c => c.names.set('alice.wei', A.OTHER));
    assert.equal(tabOf(p), 'Send');
    assert.equal(symOf(p, 'fromSel'), 'USDC');
    assert.equal(p.value('amt'), '10');
    assert.equal(p.value('rc'), 'alice.wei');
    assert.equal(p.value('dly'), '0', 'no lock was requested');
    p.close();
  });

  test('the documented time-locked link selects the lock', async () => {
    const p = await open('to=alice.wei&amount=1&token=ETH&lock=1d',
      c => c.names.set('alice.wei', A.OTHER));
    assert.equal(tabOf(p), 'Send');
    assert.equal(p.value('dly'), '86400');
    assert.match(p.text('swap'), /Lock 1 ETH for 1d/,
      'the button must describe the lock the link asked for');
    p.close();
  });

  test('a recipient alone opens the send tab', async () => {
    const p = await open('to=' + A.OTHER);
    assert.equal(tabOf(p), 'Send');
    p.close();
  });

  test('the recipient is resolved and previewed, never assumed', async () => {
    const p = await open('to=alice.wei&amount=1&token=ETH',
      c => c.names.set('alice.wei', A.OTHER));
    await p.waitFor(() => p.text('rcvEl') !== '', { label: 'resolution' });
    assert.equal(p.text('rcvEl').toLowerCase(), A.OTHER.toLowerCase());
    p.close();
  });

  test('a link naming an unregistered recipient refuses to arm the button', async () => {
    const p = await open('to=nobody.wei&amount=1&token=ETH');
    assert.equal(p.disabled('swap'), true);
    assert.match(p.text('stat'), /Name not registered/);
    p.close();
  });
});

describe('swap links', () => {
  test('the documented exact-output link sets the receive side', async () => {
    const p = await open('token=ETH&out=USDC&amount=500&exactOut=1');
    assert.equal(tabOf(p), 'Swap');
    assert.equal(symOf(p, 'fromSel'), 'ETH');
    assert.equal(symOf(p, 'toSel'), 'USDC');
    assert.equal(p.value('outAmt'), '500', 'exactOut fills what you want to receive');
    p.close();
  });

  test('without exactOut the amount is what you spend', async () => {
    const p = await open('token=ETH&out=USDC&amount=2');
    assert.equal(p.value('amt'), '2');
    p.close();
  });

  test('exactOut is ignored when the link names no output token', async () => {
    const p = await open('token=ETH&amount=2&exactOut=1');
    assert.equal(p.value('amt'), '2', 'there is nothing to be exact about');
    p.close();
  });

  test('an out= token forces the swap tab even alongside a recipient', async () => {
    const p = await open('token=ETH&out=USDC&amount=1&to=' + A.OTHER);
    assert.equal(tabOf(p), 'Swap');
    assert.equal(p.value('rc'), A.OTHER, 'the recipient becomes the swap payout address');
    p.close();
  });
});

describe('token identification', () => {
  test('accepts a symbol in either case', async () => {
    const p = await open('token=eth&out=usdc&amount=1');
    assert.equal(symOf(p, 'fromSel'), 'ETH');
    assert.equal(symOf(p, 'toSel'), 'USDC');
    p.close();
  });

  test('accepts a known token by address', async () => {
    const p = await open(`token=${A.WBTC}&out=USDC&amount=1`);
    assert.equal(symOf(p, 'fromSel'), 'WBTC');
    p.close();
  });

  test('imports an unknown token named by address', async () => {
    const p = await open(`token=ETH&out=${MOON}&amount=1`,
      c => c.setToken(MOON, { symbol: 'MOON', decimals: 18, name: 'Moon' }));
    assert.equal(symOf(p, 'toSel'), 'MOON', 'a link may introduce a token the page did not know');
    p.close();
  });

  test('a link-imported token is not silently added to the saved list', async () => {
    const p = await open(`token=ETH&out=${MOON}&amount=1`,
      c => c.setToken(MOON, { symbol: 'MOON', decimals: 18, name: 'Moon' }));
    assert.equal(p.window.localStorage.getItem('zswap:custom'), null,
      'a stranger\'s link must not permanently edit the token list');
    p.close();
  });

  test('an unreadable token address is ignored rather than breaking the form', async () => {
    const p = await open('token=ETH&out=0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef&amount=1');
    assert.equal(symOf(p, 'fromSel'), 'ETH');
    assert.ok(symOf(p, 'toSel'), 'the output side must still hold a usable token');
    p.close();
  });

  test('an unknown symbol leaves the defaults alone', async () => {
    const p = await open('token=NOTATOKEN&amount=1');
    assert.equal(symOf(p, 'fromSel'), 'ETH');
    p.close();
  });

  test('a one-sided link moves the other side out of the way', async () => {
    // token=USDC collides with the default USDC output.
    const p = await open('token=USDC&amount=1');
    assert.equal(symOf(p, 'fromSel'), 'USDC');
    assert.notEqual(symOf(p, 'toSel'), 'USDC');
    assert.doesNotMatch(p.text('stat'), /Pick different tokens/,
      'a valid link must never dead-end on a self-pair');
    p.close();
  });

  test('a link naming the same token on both sides still resolves to a usable pair', async () => {
    const p = await open('token=USDC&out=USDC&amount=1');
    assert.notEqual(symOf(p, 'fromSel'), symOf(p, 'toSel'));
    assert.doesNotMatch(p.text('stat'), /Pick different tokens/);
    p.close();
  });
});

describe('lock parsing', () => {
  const cases = [
    ['1h', '3600'], ['1d', '86400'], ['1w', '604800'],
    ['3600', '3600'], ['86400', '86400'],
    ['90m', '86400'],       // snaps up past 1h to the next offered option
    ['30m', '3600'],        // snaps up to the smallest real lock
    ['99w', '604800'],      // beyond the largest option, clamps to it
  ];
  for (const [input, expected] of cases) {
    test(`lock=${input} selects ${expected}s`, async () => {
      const p = await open(`to=${A.OTHER}&amount=1&token=ETH&lock=${input}`);
      assert.equal(p.value('dly'), expected);
      p.close();
    });
  }

  test('a malformed lock is ignored, not guessed at', async () => {
    const p = await open(`to=${A.OTHER}&amount=1&token=ETH&lock=soon`);
    assert.equal(p.value('dly'), '0', 'an unparseable duration must not lock funds');
    p.close();
  });

  test('lock=0 is an explicit instant send', async () => {
    const p = await open(`to=${A.OTHER}&amount=1&token=ETH&lock=0`);
    assert.equal(tabOf(p), 'Send');
    assert.equal(p.value('dly'), '0');
    p.close();
  });
});

describe('amount parsing', () => {
  for (const bad of ['-1', '1e18', 'abc', '1.2.3', '0x10', '']) {
    test(`ignores a bogus amount ${JSON.stringify(bad)}`, async () => {
      const p = await open(`token=ETH&out=USDC&amount=${encodeURIComponent(bad)}`);
      assert.equal(p.value('amt'), '', 'a malformed amount must not reach the form');
      p.close();
    });
  }

  test('accepts a leading-dot fraction', async () => {
    const p = await open('token=ETH&out=USDC&amount=.5');
    assert.equal(p.value('amt'), '.5');
    p.close();
  });

  test('an amount beyond the balance still only prefills, and is caught', async () => {
    const p = await open('token=ETH&out=USDC&amount=9999');
    assert.equal(p.value('amt'), '9999');
    await p.waitFor(() => p.text('swap') === 'Insufficient balance', { label: 'balance check' });
    assert.equal(p.disabled('swap'), true);
    p.close();
  });
});

describe('links are inert', () => {
  test('nothing is ever submitted on load', async () => {
    const p = await open('to=alice.wei&amount=10&token=USDC&lock=1d',
      c => c.names.set('alice.wei', A.OTHER));
    assert.equal(p.chain.sent.length, 0, 'a link that could spend money on load would be a weapon');
    assert.equal(p.chain.signed.length, 0, 'and it must not ask for a signature either');
    p.close();
  });

  test('a link cannot pre-approve a spender', async () => {
    const p = await open(`token=${A.USDC}&out=ETH&amount=1000`);
    assert.equal(p.chain.sent.length, 0);
    p.close();
  });

  test('an empty hash leaves the page at its defaults', async () => {
    const p = await open('');
    assert.equal(tabOf(p), 'Swap');
    assert.equal(symOf(p, 'fromSel'), 'ETH');
    assert.equal(p.value('amt'), '');
    p.close();
  });

  test('a hash with no recognised keys changes nothing', async () => {
    const p = await open('utm_source=twitter');
    assert.equal(symOf(p, 'fromSel'), 'ETH');
    assert.equal(p.value('amt'), '');
    p.close();
  });
});

describe('navigating between links', () => {
  test('a new hash re-applies without a reload', async () => {
    const p = await open('token=ETH&out=USDC&amount=1');
    assert.equal(p.value('amt'), '1');

    p.window.location.hash = 'token=ETH&out=USDC&amount=7';
    p.window.dispatchEvent(new p.window.HashChangeEvent('hashchange'));
    await p.waitFor(() => p.value('amt') === '7', { label: 'hashchange' });
    assert.equal(p.reloads(), 0, 'a hash change must not reload the app');
    p.close();
  });

  test('following a payment link from a swap link switches tabs', async () => {
    const p = await open('token=ETH&out=USDC&amount=1');
    assert.equal(tabOf(p), 'Swap');

    p.chain.names.set('alice.wei', A.OTHER);
    p.window.location.hash = 'to=alice.wei&amount=3&token=ETH';
    p.window.dispatchEvent(new p.window.HashChangeEvent('hashchange'));
    await p.waitFor(() => tabOf(p) === 'Send', { label: 'tab switch' });
    assert.equal(p.value('amt'), '3');
    p.close();
  });
});

describe('the share button', () => {
  test('copies a link for the current swap', async () => {
    const p = await open('');
    await p.typeAmount('amt', '2');
    const url = await share(p);
    assert.match(p.text('stat'), /Link copied/);

    const q = new URLSearchParams(new URL(url).hash.slice(1));
    assert.equal(q.get('token'), 'ETH');
    assert.equal(q.get('out'), 'USDC');
    assert.equal(q.get('amount'), '2');
    assert.equal(q.get('exactOut'), null);
    p.close();
  });

  test('marks an exact-output swap so the link reopens the same way', async () => {
    const p = await open('');
    await p.typeAmount('outAmt', '600');
    const q = new URLSearchParams(new URL(await share(p)).hash.slice(1));
    assert.equal(q.get('amount'), '600');
    assert.equal(q.get('exactOut'), '1');
    p.close();
  });

  test('a send-tab share carries recipient and lock, not an output token', async () => {
    const p = await open('');
    p.click('tabSend');
    await p.settle();
    p.type('amt', '5');
    p.type('rc', 'alice.wei');
    p.select('dly', '86400');
    await p.settle();
    const q = new URLSearchParams(new URL(await share(p)).hash.slice(1));
    assert.equal(q.get('to'), 'alice.wei');
    assert.equal(q.get('amount'), '5');
    assert.equal(q.get('lock'), '86400');
    assert.equal(q.get('out'), null, 'a transfer has no output token');
    p.close();
  });

  test('falls back to showing the link when the clipboard is unavailable', async () => {
    const p = await open('');
    p.window.navigator.clipboard.writeText = async () => { throw Error('denied'); };
    await p.typeAmount('amt', '1');
    p.click('lk');
    await p.waitFor(() => /^https?:/.test(p.text('stat')), { label: 'fallback' });
    assert.match(p.text('stat'), /#token=ETH/, 'the user must still be able to copy it by hand');
    p.close();
  });

  test('shares a custom token by address, since its symbol may be ambiguous', async () => {
    const p = await open(`token=ETH&out=${MOON}&amount=1`,
      c => c.setToken(MOON, { symbol: 'USDC', decimals: 18, name: 'Fake' }));
    const q = new URLSearchParams(new URL(await share(p)).hash.slice(1));
    assert.match(q.get('out'), /^0x/,
      'a symbol that collides with a real token must not be what the link says');
    p.close();
  });
});

describe('share links round-trip', () => {
  const roundTrip = async (setUp, check) => {
    const p = await open('');
    await setUp(p);
    const url = await share(p);
    p.close();

    const p2 = await open(new URL(url).hash.slice(1));
    await check(p2);
    p2.close();
  };

  test('an exact-in swap reopens identically', () => roundTrip(
    async p => { p.click('flip'); await p.settle(); await p.typeAmount('amt', '150'); },
    async p => {
      assert.equal(tabOf(p), 'Swap');
      assert.equal(symOf(p, 'fromSel'), 'USDC');
      assert.equal(symOf(p, 'toSel'), 'ETH');
      assert.equal(p.value('amt'), '150');
    }));

  test('an exact-out swap reopens on the same side', () => roundTrip(
    async p => { await p.typeAmount('outAmt', '750'); },
    async p => {
      assert.equal(p.value('outAmt'), '750', 'the exact-out side is what the link pinned');
      // The input side is not carried in the link; it is re-quoted on open, so
      // the reopened form prices the same request against the current market.
      assert.notEqual(p.value('amt'), '', 'the spend side must be quoted for the recipient');
    }));

  test('a locked payment request reopens identically', () => roundTrip(
    async p => {
      p.click('tabSend');
      await p.settle();
      p.type('amt', '4');
      p.type('rc', A.OTHER);
      p.select('dly', '259200');
      await p.settle();
    },
    async p => {
      assert.equal(tabOf(p), 'Send');
      assert.equal(p.value('amt'), '4');
      assert.equal(p.value('rc'), A.OTHER);
      assert.equal(p.value('dly'), '259200');
    }));
});
