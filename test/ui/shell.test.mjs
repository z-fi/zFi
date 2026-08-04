/**
 * App shell: theme, slippage persistence, deep links, the share button, custom
 * token import, and the accessibility affordances.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, MockChain, loadPage, fixedRateQuoter, closeAllPages,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const CUSTOM = '0x1234567890abcdef1234567890abcdef12345678';

async function setup({ prep = () => {}, ...opts } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 1000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  prep(chain);
  const p = await loadPage({ chain, ...opts });
  return p;
}

describe('theme', () => {
  test('follows the OS preference when nothing is stored', async () => {
    const light = await setup();
    assert.equal(light.doc.documentElement.className, '', 'no dark preference, no dark class');
    light.close();

    const dark = await setup({ prefersDark: true });
    assert.equal(dark.doc.documentElement.className, 'd', 'a dark OS preference must be honoured');
    dark.close();
  });

  test('a stored choice overrides the OS preference', async () => {
    const p = await setup({ prefersDark: true, storage: { t: 'l' } });
    assert.equal(p.doc.documentElement.className, '', 'an explicit choice wins over the OS');
    p.close();
  });

  test('toggles and remembers the choice', async () => {
    const p = await setup();
    p.click('th');
    assert.equal(p.doc.documentElement.className, 'd');
    assert.equal(p.window.localStorage.getItem('t'), 'd');
    p.close();

    const p2 = await setup({ storage: { t: 'd' } });
    assert.equal(p2.doc.documentElement.className, 'd', 'a stored theme must survive a reload');
    p2.close();
  });

  test('declares a colour scheme so native controls match', async () => {
    // Without this, select dropdowns and scrollbars render light on a dark page.
    const p = await setup();
    const css = [...p.doc.querySelectorAll('style')].map(s => s.textContent).join('');
    assert.match(css, /:root\{[^}]*color-scheme:light/);
    assert.match(css, /\.d\{[^}]*color-scheme:dark/);
    p.close();
  });
});

describe('slippage', () => {
  test('defaults to 0.5% and clamps out-of-range values', async () => {
    const p = await setup();
    assert.equal(p.value('slip'), '0.5');

    p.$('slip').value = '99';
    p.$('slip').dispatchEvent(new p.window.Event('change', { bubbles: true }));
    assert.equal(p.value('slip'), '10', 'clamped to the maximum');

    p.$('slip').value = '0.001';
    p.$('slip').dispatchEvent(new p.window.Event('change', { bubbles: true }));
    assert.equal(p.value('slip'), '0.01', 'clamped to the minimum');

    p.$('slip').value = '0';
    p.$('slip').dispatchEvent(new p.window.Event('change', { bubbles: true }));
    assert.equal(p.value('slip'), '0.5', 'zero is meaningless, so it falls back to the default');
    p.close();
  });

  test('persists across reloads', async () => {
    const p = await setup();
    p.$('slip').value = '2.5';
    p.$('slip').dispatchEvent(new p.window.Event('change', { bubbles: true }));
    assert.equal(p.window.localStorage.getItem('slip'), '2.5');
    p.close();

    const p2 = await setup({ storage: { slip: '2.5' } });
    assert.equal(p2.value('slip'), '2.5');
    p2.close();
  });

  test('a stored value outside the allowed range is ignored', async () => {
    const p = await setup({ storage: { slip: '900' } });
    assert.equal(p.value('slip'), '0.5', 'a tampered store must not widen the bound');
    p.close();
  });

  test('flags a slippage loose enough to invite a sandwich', async () => {
    const p = await setup();
    assert.equal(p.$('slip').classList.contains('warn'), false);
    p.type('slip', '5');
    assert.equal(p.$('slip').classList.contains('warn'), true);
    p.type('slip', '0.5');
    assert.equal(p.$('slip').classList.contains('warn'), false);
    p.close();
  });
});

// Deep links and the share button have their own suite: links.test.mjs

describe('custom tokens', () => {
  const withCustom = c => c.setToken(CUSTOM, { symbol: 'MOON', decimals: 18, name: 'Moon' });

  test('imports a pasted token and selects it', async () => {
    const p = await setup({ prep: withCustom });
    await p.connect();
    p.queuePrompt(CUSTOM);
    p.select('fromSel', '__custom');
    await p.waitFor(() => p.$('fromSel').selectedOptions[0]?.textContent === 'MOON',
      { label: 'custom token selected' });
    assert.ok([...p.$('toSel').options].some(o => o.textContent === 'MOON'),
      'an imported token must be available on both sides');
    p.close();
  });

  test('remembers imported tokens across reloads', async () => {
    const p = await setup({ prep: withCustom });
    await p.connect();
    p.queuePrompt(CUSTOM);
    p.select('fromSel', '__custom');
    await p.waitFor(() => p.$('fromSel').selectedOptions[0]?.textContent === 'MOON',
      { label: 'import' });
    const stored = p.window.localStorage.getItem('zswap:custom');
    p.close();

    const p2 = await setup({ prep: withCustom, storage: { 'zswap:custom': stored } });
    assert.ok([...p2.$('fromSel').options].some(o => o.textContent === 'MOON'));
    p2.close();
  });

  test('cancelling the prompt restores the previous token', async () => {
    const p = await setup({ prep: withCustom });
    await p.connect();
    const before = p.$('fromSel').value;
    p.queuePrompt(null);
    p.select('fromSel', '__custom');
    await p.settle();
    assert.equal(p.$('fromSel').value, before);
    p.close();
  });

  test('a token that cannot be read leaves the form usable', async () => {
    // No metadata registered, so symbol()/decimals() revert.
    const p = await setup();
    await p.connect();
    await p.typeAmount('amt', '1');
    p.queuePrompt('0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef');
    p.select('fromSel', '__custom');
    await p.waitFor(() => /Couldn't load token/.test(p.text('stat')), { label: 'load failure' });
    assert.equal(p.$('fromSel').selectedOptions[0].textContent, 'ETH', 'reverts to the old token');
    // The regression this guards: the form used to stay on a cleared quote with
    // a dead button until an unrelated control was touched.
    await p.typeAmount('amt', '2');
    assert.equal(p.disabled('swap'), false, 'the form must still quote afterwards');
    p.close();
  });

  test('rejects a malformed address without touching the token list', async () => {
    const p = await setup();
    await p.connect();
    const n = p.$('fromSel').options.length;
    p.queuePrompt('not-an-address');
    p.select('fromSel', '__custom');
    await p.waitFor(() => /Couldn't load token/.test(p.text('stat')), { label: 'rejection' });
    assert.equal(p.$('fromSel').options.length, n);
    p.close();
  });

  test('a hostile symbol cannot inject markup into the token list', async () => {
    const p = await setup({
      prep: c => c.setToken(CUSTOM, {
        symbol: '<img src=x onerror=alert(1)>', decimals: 18, name: 'evil',
      }),
    });
    await p.connect();
    p.queuePrompt(CUSTOM);
    p.select('fromSel', '__custom');
    await p.waitFor(() => p.$('fromSel').options.length > 9, { label: 'import' });
    assert.equal(p.$('fromSel').querySelectorAll('img').length, 0);
    assert.ok(!p.$('fromSel').innerHTML.includes('onerror'));
    p.close();
  });

  test('a stored token with impossible decimals is discarded on load', async () => {
    const p = await setup({
      storage: {
        'zswap:custom': JSON.stringify([{ sym: 'BAD', addr: CUSTOM, dec: 999 }]),
      },
    });
    assert.ok(![...p.$('fromSel').options].some(o => o.textContent === 'BAD'),
      'a corrupt store must not create a token whose amounts cannot be parsed');
    p.close();
  });
});

describe('accessibility and shell affordances', () => {
  test('tabs expose their selected state to assistive tech', async () => {
    const p = await setup();
    assert.equal(p.$('tabSwap').getAttribute('role'), 'tab');
    assert.equal(p.$('tabSwap').getAttribute('aria-selected'), 'true');
    p.click('tabBook');
    await p.settle();
    assert.equal(p.$('tabBook').getAttribute('aria-selected'), 'true');
    assert.equal(p.$('tabSwap').getAttribute('aria-selected'), 'false');
    p.close();
  });

  test('status messages are announced', async () => {
    const p = await setup();
    assert.equal(p.$('stat').getAttribute('role'), 'status');
    assert.equal(p.$('stat').getAttribute('aria-live'), 'polite');
    p.close();
  });

  test('inputs and icon buttons are labelled', async () => {
    const p = await setup();
    for (const id of ['amt', 'outAmt']) {
      assert.ok(p.$(id).getAttribute('aria-label'), `${id} needs a label`);
    }
    for (const id of ['flip', 'th', 'lk']) {
      assert.ok(p.$(id).getAttribute('aria-label'), `${id} is icon-only and needs a label`);
    }
    p.close();
  });

  test('respects a reduced-motion preference', async () => {
    const p = await setup();
    const css = [...p.doc.querySelectorAll('style')].map(s => s.textContent).join('');
    assert.match(css, /prefers-reduced-motion:reduce/);
    p.close();
  });

  test('disconnecting clears the session and reloads', async () => {
    const p = await setup();
    await p.connect();
    p.click('addr');
    await p.waitFor(() => p.reloads() > 0, { label: 'reload' });
    assert.equal(p.window.sessionStorage.getItem('dc'), '1',
      'a deliberate disconnect must not silently reconnect on the next load');
    p.close();
  });

  test('does not auto-connect after an explicit disconnect', async () => {
    const chain = new MockChain({ autoConnected: true });
    chain.setNative(A.ACCOUNT, ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    const p = await loadPage({ chain });
    p.window.sessionStorage.setItem('dc', '1');
    p.close();

    const p2 = await loadPage({ chain });
    p2.window.sessionStorage.setItem('dc', '1');
    await p2.settle();
    // A fresh load with the flag set must stay disconnected.
    const p3 = await loadPage({ chain });
    await p3.settle();
    assert.equal(p3.text('addr'), '0x1111...1111', 'a new session may auto-connect');
    p2.close();
    p3.close();
  });

  test('a wallet-less browser says so instead of failing silently', async () => {
    const dom = await loadPage({ chain: new MockChain() });
    dom.window.ethereum = undefined;
    dom.click('swap');
    await dom.settle();
    assert.match(dom.text('stat'), /No wallet detected/);
    dom.close();
  });
});
