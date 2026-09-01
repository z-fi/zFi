/**
 * The game on a phone.
 *
 * It shipped with a 9px HUD and a 20x15 close button - sizes that only make
 * sense for a mouse - and with text selection left on, so a long press on the
 * tile that OPENS the game could select the words instead of starting it. None
 * of that is visible to jsdom, which has no layout, no touch, and no notion of
 * how big anything is.
 *
 * Run: node --test test/browser/
 */
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import { chromium, devices } from 'playwright';

let server, browser, origin;

before(async () => {
  const html = fs.readFileSync(new URL('../../zSwap.html', import.meta.url));
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

/** Open the game the way a thumb does: a long press on the names tile. */
async function playOn(device) {
  const ctx = await browser.newContext({ ...devices[device] });
  const pg = await ctx.newPage();
  await pg.goto(origin, { waitUntil: 'load' });
  await pg.waitForFunction(() => document.querySelectorAll('#fromSel option').length > 1);
  await pg.evaluate(() => document.getElementById('wn')
    .dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })));
  await pg.waitForTimeout(750);
  await pg.evaluate(() => document.getElementById('wn')
    .dispatchEvent(new PointerEvent('pointerup', { bubbles: true })));
  await pg.waitForSelector('.inv', { timeout: 5000 });
  return { pg, ctx };
}

describe('the game on a phone', () => {
  for (const device of ['iPhone SE', 'iPhone 13', 'Pixel 7']) {
    test(`${device}: the controls can be hit with a thumb`, async () => {
      const { pg, ctx } = await playOn(device);
      const m = await pg.evaluate(() => {
        const hud = document.querySelector('.invh');
        // The game rewrites the HUD every frame, so measure in this same tick.
        hud.innerHTML = '<span>game over · 4820</span><span class="invm">mint this score</span>'
          + '<span class="invsh">share</span><span class="invq">✕</span>';
        const g = document.querySelector('.inv').getBoundingClientRect();
        const box = s => { const b = hud.querySelector(s).getBoundingClientRect();
          return { h: b.height, insetL: b.left - g.left, insetR: g.right - b.right }; };
        return {
          font: parseFloat(getComputedStyle(hud).fontSize),
          quit: box('.invq'), mint: box('.invm'), share: box('.invsh'),
        };
      });
      assert.ok(m.font >= 11, `HUD text was ${m.font}px`);
      for (const [name, b] of Object.entries(m).filter(([k]) => k !== 'font')) {
        assert.ok(b.h >= 30, `${name} is only ${Math.round(b.h)}px tall to tap`);
        assert.ok(b.insetL >= 0 && b.insetR >= 0, `${name} spills outside the game`);
      }
      await pg.close(); await ctx.close();
    });
  }

  test('a long press starts the game instead of selecting text', async () => {
    const { pg, ctx } = await playOn('iPhone 13');
    const sel = await pg.evaluate(() => ({
      field: getComputedStyle(document.querySelector('.inv')).webkitUserSelect,
      tile: getComputedStyle(document.getElementById('wn')).webkitUserSelect,
      selected: String(getSelection()),
    }));
    assert.equal(sel.field, 'none', 'the field must not be selectable');
    assert.equal(sel.tile, 'none', 'nor the tile the press lands on');
    assert.equal(sel.selected, '', 'and the press should have selected nothing');
    await pg.close(); await ctx.close();
  });

  test('a tap that lands on a sprite still aims at the finger', async () => {
    // The ship is placed from `e.offsetX`, which is measured against whatever
    // the pointer actually hit. Aliens, bullets and the ship sit above the
    // field with default pointer-events, so a thumb landing on one reported an
    // offset inside that 20px sprite and the ship jumped to the left edge —
    // i.e. aiming failed exactly when the screen was busiest.
    const { pg, ctx } = await playOn('iPhone 13');
    const at = await pg.evaluate(() => {
      const g = document.querySelector('.inv').getBoundingClientRect();
      const a = document.querySelector('.invx').getBoundingClientRect();
      const x = a.left + a.width / 2, y = a.top + a.height / 2;
      const el = document.elementFromPoint(x, y);
      return { x: Math.round(x), y: Math.round(y), left: g.left,
               hit: (el && el.className) || '' };
    });
    assert.ok(!/inv[xsbd]\b/.test(at.hit),
      `a sprite is swallowing the tap: hit "${at.hit}"`);
    await pg.touchscreen.tap(at.x, at.y);
    await pg.waitForTimeout(100);
    const centre = await pg.evaluate(() => {
      const g = document.querySelector('.inv').getBoundingClientRect();
      const s = document.querySelector('.invs').getBoundingClientRect();
      return s.left + s.width / 2 - g.left;
    });
    const want = at.x - at.left;
    assert.ok(Math.abs(centre - want) <= 3,
      `tapped ${Math.round(want)}px into the field but the ship went to ${Math.round(centre)}px`);
    await pg.close(); await ctx.close();
  });

  test('the field takes the gesture rather than scrolling the page', async () => {
    const { pg, ctx } = await playOn('iPhone 13');
    assert.equal(await pg.$eval('.inv', el => getComputedStyle(el).touchAction), 'none',
      'dragging to move the ship must not scroll the page instead');
    await pg.close(); await ctx.close();
  });
});
