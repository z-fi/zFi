// The corner mark is a menu: every tab and mode by name, each reached through
// a link the page itself understands, plus the DAO that governs the page.
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const NAMES = ['Swap', 'Send', 'Orders', 'Liquidity', 'Farm', 'Launch', 'Names', 'Markets', 'Private', 'zFi DAO'];

async function open(opts = {}) {
  const p = await loadPage({ chain: opts.chain ?? new MockChain(), beforeParse: w => { w.__opened = []; w.open = (...a) => { w.__opened.push(a); return null; }; } });
  await p.connect();
  await p.settle();
  return p;
}
const rows = p => [...p.$('wkList').querySelectorAll('button.tkr')];
async function pick(p, name) {
  p.click('logoLink');
  await p.waitFor(() => p.visible('wkWrap') && rows(p).length, { label: 'the menu' });
  const b = rows(p).find(r => r.textContent.startsWith(name));
  assert.ok(b, 'a row for ' + name);
  p.click(b);
  await p.settle();
}
const pressed = (p, id) => p.$(id).getAttribute('aria-pressed') === 'true';

describe('the corner menu', () => {
  test('lists every tab and mode by name, each with a line saying what it is for', async () => {
    const p = await open();
    p.click('logoLink');
    await p.waitFor(() => p.visible('wkWrap') && rows(p).length, { label: 'the menu' });
    assert.equal(p.text('wkHdr'), 'zSwap');
    assert.equal(p.$('logoLink').getAttribute('aria-expanded'), 'true');
    assert.deepEqual(rows(p).map(r => NAMES.find(n => r.textContent.startsWith(n))), NAMES);
    assert.ok(rows(p).every(r => r.querySelector('.wks')?.textContent), 'each row says what it is for');
    p.close();
  });

  test('a tab opens by name, and a mode by name, and a tab again leaves the mode', async () => {
    const p = await open();
    await pick(p, 'Send');
    assert.equal(p.$('tabSend').getAttribute('aria-selected'), 'true');
    assert.equal(p.window.location.hash, '#tab=send');
    await pick(p, 'Private');
    await p.waitFor(() => pressed(p, 'pv'), { label: 'private mode' });
    assert.equal(p.$('tabSwap').getAttribute('aria-selected'), 'true', 'modes live on the swap tab');
    await pick(p, 'Markets');
    await p.waitFor(() => pressed(p, 'mk') && !pressed(p, 'pv'), { label: 'markets instead of private' });
    await pick(p, 'Swap');
    await p.waitFor(() => !pressed(p, 'mk') && !p.window.eval('pvMode||mkMode'), { label: 'the plain swap card' });
    assert.equal(p.$('logoLink').getAttribute('aria-expanded'), 'false');
    p.close();
  });

  test('choosing the entry already in the address bar still takes you there', async () => {
    const p = await open();
    await pick(p, 'Private');
    await p.waitFor(() => pressed(p, 'pv'), { label: 'private mode' });
    p.click('pv');
    await p.settle();
    assert.ok(!pressed(p, 'pv'));
    await pick(p, 'Private');
    await p.waitFor(() => pressed(p, 'pv'), { label: 'private mode again, with the hash unchanged' });
    p.close();
  });

  test('a mode link opens that mode, and never toggles it off', async () => {
    const p = await open();
    p.window.location.hash = 'chain=1&m=mk';
    await p.waitFor(() => pressed(p, 'mk'), { label: 'markets by link' });
    p.window.eval('applyLink(1)');
    await p.settle();
    assert.ok(pressed(p, 'mk'), 'the same link twice keeps the mode open');
    p.close();
  });

  test('the DAO opens in a new tab, as the mark used to', async () => {
    const p = await open();
    await pick(p, 'zFi DAO');
    assert.equal(p.window.__opened.length, 1);
    assert.match(p.window.__opened[0][0], /^https:\/\/zfi\.wei\.is\/dao\/#\/dao\/1\/0x5E58BA0e06ED0F5558f83bE732a4b899a674053E$/);
    assert.equal(p.window.__opened[0][2], 'noopener');
    p.close();
  });

  test('Escape closes the menu and changes nothing', async () => {
    const p = await open();
    p.click('logoLink');
    await p.waitFor(() => p.visible('wkWrap'), { label: 'the menu' });
    p.doc.dispatchEvent(new p.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    await p.settle();
    assert.ok(!p.visible('wkWrap'));
    assert.equal(p.$('logoLink').getAttribute('aria-expanded'), 'false');
    assert.equal(p.$('tabSwap').getAttribute('aria-selected'), 'true');
    p.close();
  });
});
