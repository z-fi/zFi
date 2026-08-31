/**
 * The handful of things jsdom cannot see.
 *
 * jsdom has no layout: nothing scrolls, nothing has a size, focus moves no
 * viewport. That is fine for almost everything the page does - and useless for
 * the bugs that only exist BECAUSE a real browser lays things out. The token
 * picker shipped closing itself the instant it opened, in every real browser,
 * with 827 jsdom tests passing over it: `tkFind.focus()` scrolled the input
 * into view, and the page closes the picker on any scroll behind it.
 *
 * So this suite is deliberately small. It covers only what needs a viewport.
 *
 * Run: node --test test/browser/
 */
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import { chromium } from 'playwright';

const PAGE = new URL('../../zSwap.html', import.meta.url);
let server, browser, origin;

before(async () => {
  const html = fs.readFileSync(PAGE);
  server = http.createServer((_, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(html);
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  origin = `http://127.0.0.1:${server.address().port}/`;
  browser = await chromium.launch();
});

after(async () => {
  await browser?.close();
  await new Promise(r => server?.close(r));
});

/** A page with its console errors collected, loaded and settled. */
async function open() {
  const pg = await browser.newPage();
  const errors = [];
  pg.on('pageerror', e => errors.push(String(e.message)));
  pg.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  await pg.goto(origin, { waitUntil: 'load' });
  // The built-in tokens are there without any network; the rest may or may not
  // arrive, and nothing here should depend on which.
  await pg.waitForFunction(() => document.querySelectorAll('#fromSel option').length > 1);
  return { pg, errors };
}

const hidden = (pg, id) => pg.$eval('#' + id, el => el.classList.contains('hide'));

describe('the token picker, in a browser that lays things out', () => {
  test('it opens, and stays open', async () => {
    const { pg, errors } = await open();
    await pg.click('#fromPick');
    await pg.waitForTimeout(300);
    assert.equal(await hidden(pg, 'tkPanel'), false,
      'the picker closed itself - focus scrolled, and the scroll handler shut it');
    assert.ok((await pg.$$('#tkList .tkr')).length > 1, 'it should list tokens');
    assert.deepEqual(errors, []);
    await pg.close();
  });

  test('choosing a token changes the pair and closes it', async () => {
    const { pg } = await open();
    await pg.click('#fromPick');
    await pg.waitForTimeout(300);
    const before = (await pg.$eval('#fromPick', el => el.textContent)).trim();

    const rows = await pg.$$eval('#tkList .tkr', ns => ns
      .map((x, i) => ({ i, off: x.getAttribute('aria-disabled') === 'true' }))
      .filter(x => !x.off).map(x => x.i));
    assert.ok(rows.length > 1, 'need something other than the current token to pick');
    await pg.$$eval('#tkList .tkr', (ns, i) => ns[i].click(), rows[1]);
    await pg.waitForTimeout(500);

    assert.notEqual((await pg.$eval('#fromPick', el => el.textContent)).trim(), before,
      'picking a token should change the token');
    assert.equal(await hidden(pg, 'tkPanel'), true, 'and put the picker away');
    await pg.close();
  });

  /**
   * The panel is positioned from `getBoundingClientRect` - viewport coordinates
   * - so it has to resolve against the viewport. It did, until the card became
   * a positioned ancestor for the game overlay; then the panel inherited the
   * card's own offset on top of coordinates that already included it, and
   * landed a card's width and height away from the button it belongs to.
   */
  test('it lands under the button it belongs to', async () => {
    const { pg } = await open();
    await pg.click('#fromPick');
    await pg.waitForTimeout(300);
    const g = await pg.evaluate(() => {
      const r = s => { const b = document.querySelector(s).getBoundingClientRect();
        return { l: b.left, t: b.top, w: b.width, h: b.height }; };
      return { card: r('.card'), pick: r('#fromPick'), panel: r('#tkPanel'), vw: innerWidth };
    });
    assert.ok(Math.abs(g.panel.l - g.card.l) < 3,
      `panel left ${g.panel.l} should track the card's ${g.card.l}`);
    const gap = g.panel.t - (g.pick.t + g.pick.h);
    assert.ok(gap > 0 && gap < 40, `panel should sit just under the button, gap was ${gap}`);
    assert.ok(g.panel.l + g.panel.w <= g.vw, 'and stay on screen');
    await pg.close();
  });

  test('the search box filters without dismissing the list', async () => {
    const { pg } = await open();
    await pg.click('#fromPick');
    await pg.waitForTimeout(300);
    await pg.fill('#tkFind', 'eth');
    await pg.waitForTimeout(300);
    assert.equal(await hidden(pg, 'tkPanel'), false, 'typing must not close it');
    assert.ok((await pg.$$('#tkList .tkr')).length >= 1, 'and should still match something');
    await pg.close();
  });

  test('a real scroll behind it still dismisses it', async () => {
    // The handler earns its keep: the panel is absolutely positioned, so it
    // would otherwise float away from the button it belongs to.
    const { pg } = await open();
    await pg.setViewportSize({ width: 500, height: 300 });
    await pg.click('#fromPick');
    await pg.waitForTimeout(300);
    assert.equal(await hidden(pg, 'tkPanel'), false);
    await pg.evaluate(() => window.scrollTo(0, 200));
    await pg.waitForTimeout(300);
    assert.equal(await hidden(pg, 'tkPanel'), true, 'scrolling the page should close it');
    await pg.close();
  });
});
