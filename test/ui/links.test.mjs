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

describe('a link to a token only the registry knows', () => {
  /** The registry-row shape the lens serves. `e` carries the V4 pool specs,
   *  including the hooks address, which is how a hooked token like FWA
   *  declares the pool the page must quote. */
  const regRow = (s, a, e = []) => ({
    i: '1', c: 1, k: 'eip155', p: 'ERC-20', x: true, o: false, f: false,
    a, n: `${s} Token`, s, d: 18, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e, v: true,
  });

  // applyLink runs twice - once against the tokens baked into the page, again
  // once the on-chain list resolves. A link naming a registry-only token
  // cannot be answered on the first pass, and answering it anyway meant
  // showing the default pair and QUOTING it before correcting: a real price
  // for a market the user never asked about, followed by a second quote for
  // the right one.
  test('settles on the linked token without quoting a pair it never named', async () => {
    const FWA = '0x' + 'fa'.repeat(20);
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * 10n ** 18n);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * 10n ** 18n });
    chain.registry = [regRow('FWA', FWA)];

    const p = await loadPage({ chain, hash: 'token=ETH&out=FWA&amount=1' });
    await p.settle();

    const sel = p.$('toSel');
    const settled = sel.options[sel.selectedIndex]?.textContent || '';
    assert.match(settled, /FWA/i, `the link named FWA, the page settled on ${settled}`);
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

  /**
   * Back off a link lands on a bare `#`, which used to hit `applyLink`'s empty
   * early return and change nothing - so the amount and recipient a link had
   * filled in stayed on screen with nothing in the URL accounting for them.
   * The same empty hash also arrives at load, where the form is the user's own
   * and must not be touched, so the two cases are told apart by whether a
   * hashchange event was passed.
   */
  test('going back to a bare hash undoes what the link filled in', async () => {
    const p = await open('to=alice.wei&amount=3&token=ETH', c => { c.names.set('alice.wei', A.OTHER); });
    await p.waitFor(() => p.value('amt') === '3', { label: 'link applied' });
    const tabBefore = tabOf(p);
    const fromBefore = p.$('fromSel').value;

    p.window.location.hash = '';
    p.window.dispatchEvent(new p.window.HashChangeEvent('hashchange'));
    await p.waitFor(() => p.value('amt') === '', { label: 'amount cleared' });

    assert.equal(p.value('rc'), '', 'the recipient the link supplied is still there');
    // Where the user IS stays put - yanking the tab or the pair around would be
    // a worse surprise than the state it is undoing.
    assert.equal(tabOf(p), tabBefore, 'going back should not move the user off their tab');
    assert.equal(p.$('fromSel').value, fromBefore, 'going back should not change the token pair');
    p.close();
  });

  test('a load with no hash leaves a typed form alone', async () => {
    const p = await open('');
    await p.typeAmount('amt', '2.5');
    assert.equal(p.value('amt'), '2.5');
    // applyLink() runs at init with an empty hash; if that cleared, every user
    // who typed before the page settled would watch their amount vanish.
    assert.equal(p.value('amt'), '2.5', 'init must not clear the form');
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

  test('a swap share carries the recipient, so "buy X for someone" survives', async () => {
    // "Spend ETH, pay ross.wei 100 USDC" is one link or it is nothing. The
    // reader has always understood `to` on the swap tab; the share button only
    // emitted it on send, so the half of the request that names WHO got
    // dropped the moment you copied it.
    const p = await open('');
    p.type('rc', 'ross.wei');
    await p.typeAmount('outAmt', '100');
    const q = new URLSearchParams(new URL(await share(p)).hash.slice(1));
    assert.equal(q.get('to'), 'ross.wei', 'the recipient must survive a swap share');
    assert.equal(q.get('amount'), '100');
    assert.equal(q.get('exactOut'), '1');
    assert.equal(q.get('out'), 'USDC', 'and still name the output token');
    p.close();
  });

  test('a swap share with no recipient carries no to=', async () => {
    const p = await open('');
    await p.typeAmount('amt', '1');
    const q = new URLSearchParams(new URL(await share(p)).hash.slice(1));
    assert.equal(q.get('to'), null, 'an empty recipient must not appear in the link');
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

  test('shares a LAUNCHED coin by address, not by its ticker', async () => {
    // The case that actually shipped: pick a coin off the launch list, copy a
    // link, and it read `out=ZCAT`. Launched coins are found by scanning the
    // most recent launches, so the reader's list holds a different set as new
    // ones arrive - and nothing stops a second coin taking the ticker. Both
    // make a symbol link rot; the address does not.
    const POOL = '0x' + 'c1'.repeat(20);
    const COIN = '0x' + 'c2'.repeat(20);
    const chain = new MockChain({ autoConnected: true });
    // The launch scan runs as part of loading the curated list, so the fixture
    // needs a registry for launched coins to reach the picker at all.
    const rows = [row('ETH', A.ZERO, 18, 'Native'), row('USDC', A.USDC, 6)];
    chain.registry = rows;
    chain.conviction = rows.map((_, i) => i + 1);
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setToken(COIN, { symbol: 'ZCAT', decimals: 18, name: 'Zero Cat' });
    chain.setLaunched([{ pool: POOL, token: COIN, reserve0: 20n * ETH }]);
    // Loaded from the LAUNCH LIST, not pasted as an address: pasting adds it as
    // a custom token, which is a different flag and was already handled - that
    // difference is what made the first version of this test vacuous.
    const p = await loadPage({ chain, hash: null });
    await p.settle();
    const to = p.$('toSel');
    const opt = [...to.options].find(o => /ZCAT/.test(o.textContent));
    assert.ok(opt, `the launch list never offered the coin: ${[...to.options].map(o => o.textContent)}`);
    to.value = opt.value;
    to.dispatchEvent(new p.window.Event('change', { bubbles: true }));
    await p.settle();
    p.type('amt', '1');
    await p.settle();

    const q = new URLSearchParams(new URL(await share(p)).hash.slice(1));
    assert.equal(q.get('out').toLowerCase(), COIN.toLowerCase(),
      `a launched coin must be linked by address, got ${q.get('out')}`);
    p.close();
  });

  test('shares a session-only token by address, even when its symbol is unique here', async () => {
    // The near-miss: a coin opened from the launch list is added to THIS
    // session, which makes its symbol unambiguous in THIS list - so the
    // builder happily wrote `out=ZCAT`. Nobody else has that token, so
    // `symAddr` finds nothing on their side and the link quietly selects
    // neither leg. A link that only works for its author is worse than a long
    // one; the address carries itself and adds the token on arrival.
    const p = await open(`token=ETH&out=${MOON}&amount=1`,
      c => c.setToken(MOON, { symbol: 'ZCAT', decimals: 18, name: 'Zero Cat' }));
    const q = new URLSearchParams(new URL(await share(p)).hash.slice(1));
    assert.match(q.get('out'), /^0x/,
      `a token only this session knows must be linked by address, got ${q.get('out')}`);
    assert.equal(q.get('out').toLowerCase(), MOON.toLowerCase(), 'and it must be the right one');
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

/**
 * A registry row in the shape zTokenlist serves, so these tests can curate the
 * list the page actually adopts. Kept in step with ranked-default.test.mjs.
 */
const row = (sym, addr, dec = 18, p = 'ERC-20') => ({
  i: '1', c: 1, k: 'eip155', p, x: true, o: false, f: false,
  a: addr, n: sym, s: sym, d: dec, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true,
});

/** Open a link against a curated registry, which the page loads WHILE the link applies. */
async function openListed(hash, registry, prep = () => {}, storage = {}) {
  const chain = new MockChain({ autoConnected: true });
  chain.registry = registry;
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.WBTC, A.ACCOUNT, 10n ** 8n);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  prep(chain);
  const p = await loadPage({ chain, hash, storage });
  await p.settle();
  return p;
}

/**
 * The token list arrives from chain AFTER the page has already applied the
 * hash, and it does not append - it REPLACES the array the link just indexed
 * into. A link that remembered "token number 3" would land on whatever token
 * number 3 became, which is a different asset with a straight face. So the
 * link has to hold addresses across every await, and re-import a token the
 * reload dropped.
 */
describe('links survive the token list landing underneath them', () => {
  const LISTED = [
    row('ETH', A.ZERO, 18, 'Native'), row('WBTC', A.WBTC, 8),
    row('USDT', A.USDT, 6), row('USDC', A.USDC, 6),
  ];

  test('a link names the token it named, not the index it occupied', async () => {
    // The built-in list and the registry disagree about every position.
    const p = await openListed(`token=${A.WBTC}&out=${A.USDC}&amount=1`, LISTED);
    assert.equal(symOf(p, 'fromSel'), 'WBTC');
    assert.equal(symOf(p, 'toSel'), 'USDC');
    p.close();
  });

  test('a token the user saved survives it too', async () => {
    const p = await openListed(null, LISTED,
      c => c.setToken(MOON, { symbol: 'MOON', decimals: 18, name: 'Moon' }),
      { 'zswap:custom': JSON.stringify([{ sym: 'MOON', addr: MOON, dec: 18, std: 'ft' }]) });
    assert.ok([...p.$('toSel').options].some(o => o.textContent === 'MOON'),
      'the registry does not list it, and the picker is the only record the user has');
    p.close();
  });

  test('a link-imported token survives the reload that would have dropped it', async () => {
    const p = await openListed(`token=ETH&out=${MOON}&amount=1`, LISTED,
      c => c.setToken(MOON, { symbol: 'MOON', decimals: 18, name: 'Moon' }));
    assert.equal(symOf(p, 'toSel'), 'MOON',
      'the imported token is not in the registry, so only a re-import can keep it');
    p.close();
  });
});

/**
 * Symbols are curated, not unique: anyone can get a second "USDC" listed. A
 * link that resolved a symbol by taking the first match would hand whoever
 * ranks highest the ability to repoint every existing link.
 */
describe('ambiguous symbols', () => {
  const FAKE = '0xfeed00000000000000000000000000000000feed';
  const TWO_USDC = [
    row('ETH', A.ZERO, 18, 'Native'), row('WBTC', A.WBTC, 8),
    row('USDC', FAKE, 6), row('USDC', A.USDC, 6),
  ];

  /** Follow a link once the curated list - the one holding both USDCs - is up. */
  const follow = async (p, hash) => {
    p.window.location.hash = hash;
    p.window.dispatchEvent(new p.window.HashChangeEvent('hashchange'));
    await p.settle();
    await p.settle();
  };

  test('a symbol claimed by two tokens selects neither', async () => {
    const p = await openListed(`token=ETH&out=${A.WBTC}`, TWO_USDC);
    assert.equal(p.$('toSel').dataset.addr, A.WBTC.toLowerCase());
    await follow(p, 'token=ETH&out=USDC&amount=1');
    assert.equal(p.$('toSel').dataset.addr, A.WBTC.toLowerCase(),
      'the ambiguous side must hold, not guess between two tokens');
    p.close();
  });

  test('the address form still selects exactly one of them', async () => {
    const p = await openListed(`token=ETH&out=${A.USDC}&amount=1`, TWO_USDC);
    assert.equal(p.$('toSel').dataset.addr, A.USDC.toLowerCase());
    p.close();
  });

  test('sharing such a token writes its address, not its symbol', async () => {
    const p = await openListed(`token=ETH&out=${A.USDC}&amount=1`, TWO_USDC);
    const q = new URLSearchParams(new URL(await share(p)).hash.slice(1));
    assert.equal(q.get('out').toLowerCase(), A.USDC.toLowerCase(),
      'a symbol two tokens answer to cannot identify either');
    p.close();
  });
});

describe('the orderbook tab', () => {
  test('shares a link that reopens on the orderbook, with its expiry', async () => {
    const p = await open('');
    p.click('tabBook');
    await p.settle();
    p.select('dly', '86400');
    p.type('amt', '2');
    await p.settle();
    const url = await share(p);
    const q = new URLSearchParams(new URL(url).hash.slice(1));
    assert.equal(q.get('tab'), 'book');
    assert.equal(q.get('lock'), '86400');
    p.close();

    const p2 = await open(new URL(url).hash.slice(1));
    assert.equal(tabOf(p2), 'Book', 'an order link shared as a swap would reopen as the wrong trade');
    assert.equal(p2.value('dly'), '86400', 'and would silently reset the expiry');
    assert.equal(p2.value('amt'), '2');
    p2.close();
  });

  test('an unknown tab= is ignored rather than obeyed', async () => {
    const p = await open('token=ETH&out=USDC&amount=1&tab=evil');
    assert.equal(tabOf(p), 'Swap');
    p.close();
  });
});

describe('liquidity mode', () => {
  test('a payment link keeps its recipient', async () => {
    const p = await open('');
    p.click('lq');
    await p.settle();
    assert.equal(p.$('lq').getAttribute('aria-pressed'), 'true');

    p.chain.names.set('alice.wei', A.OTHER);
    // Assigning the hash is enough: jsdom fires hashchange itself. Dispatching
    // one as well applies the link TWICE, and the second pass would paper over
    // exactly the clobber this test is here to catch.
    p.window.location.hash = 'to=alice.wei&amount=3&token=ETH';
    await p.waitFor(() => tabOf(p) === 'Send', { label: 'tab switch' });
    assert.equal(p.value('rc'), 'alice.wei',
      'leaving liquidity mode blanks the recipient, so the link must leave it first');
    assert.equal(p.value('amt'), '3');
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

/**
 * Symbols resolve against the loaded list and nothing else, so a link naming a
 * coin that has since dropped out of the shown cohort used to apply half a pair
 * and say nothing - the form quietly kept whatever was already selected, and
 * the person following the link had no way to tell the difference between "this
 * is the trade" and "this leg was ignored". Addresses always resolve, which is
 * why the share button emits them; the notice is for links typed by hand.
 */
describe('a symbol that resolves to nothing says so', () => {
  test('an unknown symbol is reported rather than skipped', async () => {
    const p = await open('token=ETH&out=NOSUCHCOIN&amount=1');
    assert.match(p.text('stat'), /NOSUCHCOIN/,
      'the ignored leg should be named');
    assert.match(p.text('stat'), /address/i, 'and the way round it offered');
    p.close();
  });

  test('a symbol that does resolve stays silent', async () => {
    const p = await open('token=ETH&out=USDC&amount=1');
    assert.doesNotMatch(p.text('stat'), /Couldn/, 'a working link must not warn');
    assert.equal(symOf(p, 'toSel'), 'USDC');
    p.close();
  });

  test('an address is never warned about, listed or not', async () => {
    const p = await open(`token=ETH&out=${MOON}`, chain =>
      chain.setToken(MOON, { symbol: 'MOON', decimals: 18, name: 'Moon' }));
    assert.doesNotMatch(p.text('stat'), /Couldn/,
      'an address is read from chain, so there is nothing to warn about');
    p.close();
  });
});
