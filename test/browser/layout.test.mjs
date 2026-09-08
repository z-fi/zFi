/**
 * The page laid out on real screens.
 *
 * Everything here is invisible to jsdom, which has no layout: it cannot tell
 * that the meta row's grid had squeezed the wallet address to ZERO pixels wide
 * on a tablet, that raising the browser's text size pushed the tabs off the
 * side of the card and gave the whole document a horizontal scrollbar, or that
 * the footer's links were ten pixels tall on a phone. Each of those shipped.
 *
 * The page is served from immutable contract code, so a layout defect found
 * after deployment is permanent. These are the measurements that would have
 * caught the ones we found.
 *
 * Run: node --test test/browser/
 */
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import { chromium } from 'playwright';

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

/** A loaded page at one screen size. Token list settled, so widths are final. */
async function at({ width, height, touch = true, scheme = 'light', root = 0 }) {
  const ctx = await browser.newContext({
    viewport: { width, height }, hasTouch: touch, isMobile: touch, colorScheme: scheme,
  });
  const pg = await ctx.newPage();
  if (root) await pg.addInitScript(px => {
    addEventListener('DOMContentLoaded', () => { document.documentElement.style.fontSize = px + 'px'; });
  }, root);
  await pg.goto(origin, { waitUntil: 'load' });
  await pg.waitForFunction(() => document.querySelectorAll('#fromSel option').length > 1);
  await pg.waitForTimeout(250);
  return { pg, ctx };
}

/** Every laid-out element whose box escapes the viewport on either side. */
const escapees = pg => pg.evaluate(() => {
  const out = [];
  for (const el of document.querySelectorAll('body *')) {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') continue;
    const r = el.getBoundingClientRect();
    if (!r.width && !r.height) continue;
    if (r.right > innerWidth + 0.5 || r.left < -0.5)
      out.push((el.id ? '#' + el.id : el.tagName.toLowerCase()) + ` ${r.left.toFixed(0)}..${r.right.toFixed(0)}`);
  }
  return out;
});

const SCREENS = [
  { name: 'iPhone SE', width: 320, height: 568 },
  { name: 'iPhone 13', width: 390, height: 844 },
  { name: 'Pixel 7', width: 412, height: 915 },
  { name: 'phone landscape', width: 844, height: 390 },
  { name: 'iPad portrait', width: 768, height: 1024 },
  { name: 'laptop', width: 1280, height: 800, touch: false },
];

describe('the card on real screens', () => {
  for (const s of SCREENS) {
    test(`${s.name}: nothing escapes the viewport`, async () => {
      const { pg, ctx } = await at(s);
      assert.deepEqual(await escapees(pg), [], 'boxes outside the viewport');
      assert.equal(await pg.evaluate(() => document.documentElement.scrollWidth),
        await pg.evaluate(() => document.documentElement.clientWidth),
        'the document scrolls sideways');
      await ctx.close();
    });

    test(`${s.name}: the wallet address is readable, not a sliver`, async () => {
      // The meta row was a fixed grid: seven controls and a slippage label ate
      // the whole 22em card, and the address column - the one thing that says
      // WHICH wallet is about to sign - collapsed. On a tablet it was 0px.
      const { pg, ctx } = await at(s);
      const w = await pg.evaluate(() => {
        const a = document.getElementById('addr');
        a.textContent = '0x1234...5678';
        return a.getBoundingClientRect().width;
      });
      assert.ok(w >= 60, `#addr is ${w.toFixed(0)}px wide - a short address needs ~51px`);
      await ctx.close();
    });
  }

  test('the tools cluster keeps the address off the chopping block', async () => {
    // When the controls cannot share a line with the address they take their
    // own, right-aligned. What must never happen is the address shrinking to
    // an ellipsis while the icons keep their full width.
    const { pg, ctx } = await at({ width: 390, height: 844 });
    const m = await pg.evaluate(() => {
      const a = document.getElementById('addr').getBoundingClientRect();
      const t = document.querySelector('.mtl').getBoundingClientRect();
      return { addr: a.width, meta: document.querySelector('.meta').clientWidth, tools: t.width, wrapped: a.top + a.height / 2 < t.top };
    });
    assert.ok(m.wrapped, 'the cluster should drop to its own line on a phone');
    assert.ok(m.addr >= m.meta - 1, 'the address takes the whole line it was given');
    await ctx.close();
  });
});

describe('reflow at a raised text size', () => {
  // WCAG 1.4.10: at 200% text nothing may need horizontal scrolling. The tabs
  // used to run off the side of the card and take the document with them.
  for (const [label, px] of [['150%', 24], ['200%', 32]]) {
    test(`${label} text on a phone still fits its width`, async () => {
      const { pg, ctx } = await at({ width: 390, height: 844, root: px });
      assert.equal(await pg.evaluate(() => document.documentElement.scrollWidth),
        390, 'the document scrolls sideways');
      assert.deepEqual(await escapees(pg), []);
      await ctx.close();
    });
  }
});

describe('what a thumb has to hit', () => {
  test('every control on a phone is at least 30px tall', async () => {
    // The footer links were 10px, and the select in each SLOW/order row was 14
    // - the row around it was padded, but the padding was not clickable.
    const { pg, ctx } = await at({ width: 390, height: 844 });
    for (const open of [null, 'tabSend', 'tabBook']) {
      if (open) await pg.evaluate(id => document.getElementById(id).click(), open);
      await pg.waitForTimeout(200);
      const small = await pg.evaluate(() => {
        const out = [];
        for (const el of document.querySelectorAll('button,a[href],select,input:not([type=hidden]),[role=button]')) {
          const cs = getComputedStyle(el);
          if (cs.display === 'none' || cs.visibility === 'hidden') continue;
          // The native selects behind the rich picker are hidden stand-ins:
          // transparent, one pixel, and deaf to the pointer.
          if (cs.pointerEvents === 'none' || cs.opacity === '0') continue;
          const r = el.getBoundingClientRect();
          if (!r.width && !r.height) continue;
          // #slip is wrapped by its own label, which carries the hit area.
          if (el.id === 'slip') continue;
          if (r.width < 30 || r.height < 30) out.push(`${el.id || el.className || el.tagName} ${r.width.toFixed(0)}x${r.height.toFixed(0)}`);
        }
        return out;
      });
      assert.deepEqual(small, [], `too small to hit (${open || 'swap'})`);
    }
    await ctx.close();
  });
});

describe('the token sheet', () => {
  test('is full-bleed on a phone and merely wide on a tablet', async () => {
    // The bottom sheet is keyed to pointer:coarse, so a 1024px iPad was
    // getting a search list stretched the whole way across the screen.
    for (const [width, height, bleeds] of [[390, 844, true], [1024, 1366, false]]) {
      const { pg, ctx } = await at({ width, height });
      await pg.evaluate(() => document.getElementById('fromPick').click());
      await pg.waitForTimeout(200);
      const b = await pg.evaluate(() => {
        const r = document.querySelector('.tkp:not(.hide)').getBoundingClientRect();
        return { left: r.left, right: r.right, bottom: r.bottom, w: r.width };
      });
      assert.equal(b.bottom, height, 'the sheet sits on the bottom edge');
      if (bleeds) assert.equal(b.w, width, 'a phone gets the full width');
      else {
        assert.ok(b.w < width, `a tablet sheet should not span ${width}px`);
        assert.ok(Math.abs((width - b.right) - b.left) < 2, 'and should be centred');
      }
      await ctx.close();
    }
  });
});
