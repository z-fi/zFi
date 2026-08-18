/**
 * App shell: theme, slippage persistence, deep links, the share button, custom
 * token import, and the accessibility affordances.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  A, MockChain, loadPage, fixedRateQuoter, closeAllPages, HTML_PATH,
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

  /**
   * A pasted address used to be assumed fungible: symbol(), decimals(), and
   * `std:"ft"` written in. An ERC-721 usually fell over on decimals() and
   * surfaced as "execution reverted", which explains nothing; one that DOES
   * expose decimals() was listed as swappable, which is worse, because the
   * registry's own listings are classified and the page already refuses to
   * swap a collection. Detection puts the hand-typed path on the same footing.
   */
  const COLLECTION = '0xfeed567890abcdef1234567890abcdef12345678';
  const withCollection = c =>
    c.setToken(COLLECTION, { symbol: 'PUNK', name: 'CryptoPunks', erc721: true });

  const importToken = async (p, addr) => {
    p.queuePrompt(addr);
    p.select('fromSel', '__custom');
    await p.settle();
  };

  test('detects an ERC-721 and files it as a collection, not a swappable token', async () => {
    const p = await setup({ prep: withCollection });
    await p.connect();
    await importToken(p, COLLECTION);
    await p.waitFor(() => [...p.$('toSel').options].some(o => o.textContent === 'PUNK'),
      { label: 'collection imported' });

    const opt = [...p.$('toSel').options].find(o => o.textContent === 'PUNK');
    assert.equal(opt.parentElement?.label, 'NFT collections — auction only',
      'a collection belongs on the auction shelf, like the registry\'s own');
    assert.equal(opt.disabled, true, 'and cannot be picked as a swap output');
    p.close();
  });

  test('says what is wrong instead of failing on a missing decimals()', async () => {
    // An address with code that is neither: no decimals, no ERC-165 answer.
    const NEITHER = '0xdead567890abcdef1234567890abcdef12345678';
    const p = await setup({ prep: c => c.setCode(NEITHER, '0x60006000f3') });
    await p.connect();
    await importToken(p, NEITHER);
    await p.waitFor(() => /ERC-20 or ERC-721/i.test(p.text('stat')),
      { label: 'a reason, not a revert' });
    assert.ok(!/execution reverted/i.test(p.text('stat')), 'the raw revert helps nobody');
    p.close();
  });

  test('says so when there is no contract at the address at all', async () => {
    const EMPTY = '0xabc4567890abcdef1234567890abcdef12345678';
    const p = await setup();
    await p.connect();
    await importToken(p, EMPTY);
    await p.waitFor(() => /no contract at that address/i.test(p.text('stat')),
      { label: 'the actual problem' });
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

  test('a wallet-less browser is offered a way in, not a dead end', async () => {
    // This used to print "No wallet detected" and stop, which is a true
    // statement and a useless one: the person reading it has no wallet to
    // press. A desktop browser with no extension is exactly the case
    // WalletConnect exists for, so it is offered instead of announced.
    const dom = await loadPage({ chain: new MockChain() });
    dom.window.ethereum = undefined;
    dom.click('swap');
    await dom.settle();
    assert.ok(!dom.$('wkWrap').classList.contains('hide'), 'no wallet chooser appeared');
    const rows = [...dom.$('wkList').querySelectorAll('.tkr')].map(r => r.textContent);
    assert.deepEqual(rows, ['WalletConnect'], 'the chooser did not offer WalletConnect');
    dom.close();
  });
});

describe('the footer', () => {
  test('names the version, and says nothing at all when it cannot name the address', async () => {
    // A page whose bytes never change is only auditable if you can tell WHICH
    // forever you are looking at. But a root cannot carry its own address: the
    // wrapper is CREATE2 over initcode naming chunks derived from these very
    // bytes, so writing the address in changes the address.
    //
    // It used to SAY that. True, and nobody's problem but ours - and served
    // anywhere other than a web3:// gateway it read as a warning that something
    // had gone wrong, which is not a thing a footer should imply on a page
    // handling money. Absent is the honest rendering of "not applicable here".
    // Bound to the page's own ZSWAP_VERSION rather than to a literal. The
    // claim worth pinning is that the footer renders the version the page
    // DECLARES — a hardcoded "0.1" only pins how far behind the test is, and
    // breaks on a bump that is correct.
    const declared = fs.readFileSync(HTML_PATH, 'utf8').match(/const ZSWAP_VERSION="([^"]*)";/);
    assert.ok(declared, 'the page declares ZSWAP_VERSION');
    assert.ok(/^\d+\.\d+$/.test(declared[1]), `ZSWAP_VERSION="${declared[1]}" is not a version`);
    const p = await loadPage({ chain: new MockChain() });
    assert.equal(p.text('footV'), `zSwap v${declared[1]}`, 'the build is named');
    assert.equal(p.text('footAddr'), '', 'no address, and no explanation nobody asked for');
    assert.equal(p.$('footAddr').querySelector('a'), null, 'no link to an address it does not have');
    p.close();
  });

  test('reads its own address off a web3 gateway hostname', async () => {
    // `<address>.<chain>.w3link.io` carries the contract in the URL, so a page
    // served that way can simply look - which costs nothing and is always right.
    const addr = '0x00000000000000000000000000000000000000ab';
    const p = await loadPage({ chain: new MockChain(), url: `https://${addr}.1.w3link.io/` });
    const link = p.$('footAddr').querySelector('a');
    assert.ok(link, 'an address in the hostname should become a link');
    assert.match(link.getAttribute('href'), new RegExp(addr, 'i'));
    p.close();
  });

  test('a successor build links back to the version it succeeded', async () => {
    // ZSWAP_PREVIOUS is hand-written and baked into immutable bytes - nothing
    // derives it, and it cannot be corrected after deploy. Left empty, a
    // successor ships looking like a root: the chain still records the parent,
    // but the page gives a reader no way back to it. The address here is the
    // deployed root, so this test also fails if a future build forgets to
    // re-point it at ITS predecessor.
    const ROOT = '0x00000095643CFfA7D9fae407a84dfCB6406456c6';
    const self = '0x00000000000000000000000000000000000000ab';
    const p = await loadPage({ chain: new MockChain(), url: `https://${self}.1.w3link.io/` });
    await p.settle();
    const hrefs = [...p.$('footAddr').querySelectorAll('a')].map(a => a.getAttribute('href'));
    assert.ok(hrefs.some(h => new RegExp(ROOT, 'i').test(h)),
      `no link back to the predecessor; footer had ${hrefs.join(', ') || 'no links'}`);
    p.close();
  });

  // The successor chain is only worth having if something reads it. `html()`
  // never changes, so the page cannot become the new version - it can only say
  // that one exists, and link it. Nothing here navigates on the reader's
  // behalf: the bytes on screen stay the bytes that were audited.
  test('announces a newer version when the chain has one', async () => {
    const self = '0x00000000000000000000000000000000000000ab';
    const tip = '0x00000000000000000000000000000000000000cd';
    const chain = new MockChain();
    chain.lineage.set(self, tip);
    const p = await loadPage({ chain, url: `https://${self}.1.w3link.io/` });
    await p.settle();
    const links = [...p.$('footAddr').querySelectorAll('a')];
    const newer = links.find(a => /newer/i.test(a.textContent));
    assert.ok(newer, 'a successor on chain must be surfaced');
    // Same gateway, same chain label — only the address changes, so a reader
    // on w3link stays on w3link and one on w4eth stays on w4eth.
    assert.equal(newer.getAttribute('href'), `https://${tip}.1.w3link.io/`);
    assert.ok(links.some(a => new RegExp(self, 'i').test(a.getAttribute('href'))),
      'and this build is still named, unchanged');
    p.close();
  });

  // A stolen governance key can name a successor in one transaction. The page
  // records nothing and can never be patched, so the only defence it can carry
  // is a clock: a version too young to have been looked at is not linked.
  test('does not point at a successor younger than the maturity delay', async () => {
    const self = '0x00000000000000000000000000000000000000ab';
    const tip = '0x00000000000000000000000000000000000000cd';
    const chain = new MockChain();
    chain.lineage.set(self, tip);
    chain.previousOf.set(tip, self);
    chain.succeededAt.set(self, Math.floor(Date.now() / 1000) - 60);  // a minute old
    const p = await loadPage({ chain, url: `https://${self}.1.w3link.io/` });
    await p.settle();
    assert.doesNotMatch(p.text('footAddr'), /newer/i, 'too young to be linked');
    p.close();
  });

  test('points at it once the delay has passed', async () => {
    const self = '0x00000000000000000000000000000000000000ab';
    const tip = '0x00000000000000000000000000000000000000cd';
    const chain = new MockChain();
    chain.lineage.set(self, tip);
    chain.previousOf.set(tip, self);
    chain.succeededAt.set(self, Math.floor(Date.now() / 1000) - 4 * 86400);
    const p = await loadPage({ chain, url: `https://${self}.1.w3link.io/` });
    await p.settle();
    const newer = [...p.$('footAddr').querySelectorAll('a')].find(a => /newer/i.test(a.textContent));
    assert.ok(newer, 'three days is the wait, not forever');
    assert.match(newer.getAttribute('href'), new RegExp(tip, 'i'));
    p.close();
  });

  // Shipping twice in a week must not leave a reader stranded on the older of
  // two young versions - nor pointed at either of them.
  test('walks back through a burst of young versions', async () => {
    const v1 = '0x00000000000000000000000000000000000000ab';
    const v2 = '0x00000000000000000000000000000000000000cd';
    const v3 = '0x00000000000000000000000000000000000000ef';
    const now = Math.floor(Date.now() / 1000);
    const chain = new MockChain();
    chain.lineage.set(v1, v3);                 // latest() jumps straight to the tip
    chain.previousOf.set(v3, v2);
    chain.previousOf.set(v2, v1);
    chain.succeededAt.set(v2, now - 60);       // v3 is a minute old
    chain.succeededAt.set(v1, now - 4 * 86400); // v2 has stood four days
    const p = await loadPage({ chain, url: `https://${v1}.1.w3link.io/` });
    await p.settle();
    const newer = [...p.$('footAddr').querySelectorAll('a')].find(a => /newer/i.test(a.textContent));
    assert.ok(newer, 'the mature one is still worth pointing at');
    assert.match(newer.getAttribute('href'), new RegExp(v2, 'i'), 'v0.2, not the fresh v0.3');
    p.close();
  });

  test('says nothing when this build IS the tip', async () => {
    const self = '0x00000000000000000000000000000000000000ab';
    const p = await loadPage({ chain: new MockChain(), url: `https://${self}.1.w3link.io/` });
    await p.settle();
    assert.doesNotMatch(p.text('footAddr'), /newer/i,
      'latest() returning this address means there is no successor');
    p.close();
  });

  test('stays silent when the notice cannot be trusted', async () => {
    // A wallet on another chain reads another chain's `latest()`, which is not
    // this contract's lineage. A missing notice is a smaller harm than one
    // pointing at an address that means nothing here.
    const self = '0x00000000000000000000000000000000000000ab';
    const chain = new MockChain();
    chain.chainId = '0xa';
    chain.lineage.set(self, '0x00000000000000000000000000000000000000cd');
    const p = await loadPage({ chain, url: `https://${self}.1.w3link.io/` });
    await p.settle();
    assert.doesNotMatch(p.text('footAddr'), /newer/i);
    assert.ok(!chain.calls.some(c => c.selector === '52bfe789'),
      'and the call is not even made off mainnet');
    p.close();
  });
});

describe('the docs', () => {
  /**
   * The page carries ~2.7 KB of explanation in `title` tooltips, and a phone
   * cannot show a single word of it - there is no hover. These are the same
   * explanations somewhere a thumb can reach.
   */
  test('are closed by default and open from the footer', async () => {
    const p = await loadPage({ chain: new MockChain() });
    assert.ok(!p.visible('docPanel'), 'docs must not be in the way by default');
    p.click('footDoc');
    assert.ok(p.visible('docPanel'), 'the footer link opens them');
    assert.equal(p.text('footDoc'), 'hide', 'and says how to put them away');
    p.click('footDoc');
    assert.ok(!p.visible('docPanel'));
    assert.equal(p.text('footDoc'), 'how it works');
    p.close();
  });

  test('cover every surface the page has', async () => {
    // A feature nobody can find is a feature that does not exist. If a tab or
    // a mode is added and this list is not, that is the omission worth failing.
    const p = await loadPage({ chain: new MockChain() });
    const text = p.$('docPanel').textContent;
    for (const topic of ['Swapping', 'Sending', 'Orders', 'Liquidity', 'Launching', 'Fees'])
      assert.match(text, new RegExp(topic), `nothing documents ${topic}`);
    p.close();
  });

  test('state the fee split the contract actually implements', async () => {
    // Docs that drift are worse than none: this is the number a creator
    // decides on. PROTOCOL_BPS and TITHE_BPS are both 1_000 of 10_000, and the
    // creator takes the remainder - so 80/10/10, and half the swap fee never
    // leaves the pool at all.
    const p = await loadPage({ chain: new MockChain() });
    const text = p.$('docPanel').textContent;
    assert.match(text, /80% creator, 10% protocol, 10% tithe/, 'the split is misstated');
    // And what the tithe IS, since "burned" alone reads as lost rather than as a
    // reduction in ether supply that every ether holder shares in.
    assert.match(text, /BETH/, 'the tithe should name where the ether goes');
    assert.match(text, /1%/, 'the pool fee on a launched market is 1%');
    p.close();
  });

  test('do not promise a backend', async () => {
    const p = await loadPage({ chain: new MockChain() });
    assert.match(p.$('docPanel').textContent, /no server/i);
    p.close();
  });
});
