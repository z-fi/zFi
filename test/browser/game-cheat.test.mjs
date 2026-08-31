/**
 * How hard it is to cheat from the console.
 *
 * Not a security boundary - `claim` is permissionless, so anyone willing to
 * call the contract can mint any number, and a debugger reaches anything. What
 * this pins is the cheapest attack of all: typing `sc = 999999` into devtools.
 * That fails today only because the whole game lives inside `invPlay()`, which
 * is an accident of structure rather than a decision. Hoist the state to the
 * top level for tidiness and it opens up, silently, with every other test green.
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

async function play() {
  const pg = await browser.newPage();
  await pg.goto(origin, { waitUntil: 'load' });
  await pg.waitForFunction(() => document.querySelectorAll('#fromSel option').length > 1);
  await pg.evaluate(() => document.getElementById('wn')
    .dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })));
  await pg.waitForTimeout(750);
  await pg.evaluate(() => document.getElementById('wn')
    .dispatchEvent(new PointerEvent('pointerup', { bubbles: true })));
  await pg.waitForSelector('.inv');
  return pg;
}

describe('the score is not sitting on the window', () => {
  test('assigning sc from the console does not change the score', async () => {
    const pg = await play();
    const before = await pg.$eval('.invh', el => el.textContent);
    await pg.evaluate(() => { window.eval('sc = 999999'); });
    await pg.waitForTimeout(400);
    const after = await pg.$eval('.invh', el => el.textContent);
    assert.doesNotMatch(after, /999999/, 'the console must not be able to set the score');
    assert.equal(after.replace(/\d+s/, ''), before.replace(/\d+s/, ''),
      'only the clock should have moved');
    await pg.close();
  });

  test('the game internals are not reachable by name', async () => {
    const pg = await play();
    const reach = await pg.evaluate(() => {
      const probe = n => { try { window.eval(n); return 'reachable'; } catch { return 'unreachable'; } };
      return { mint: probe('mint'), runId: probe('runId'), born: probe('born'), hud2: probe('hud2') };
    });
    for (const [name, r] of Object.entries(reach)) {
      assert.equal(r, 'unreachable', `${name} is reachable from the console`);
    }
    await pg.close();
  });
});
