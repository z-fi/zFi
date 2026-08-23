/**
 * Every handler a page names must exist.
 *
 * Three separate breakages shipped in one day with the identical shape: a
 * refactor moved or trimmed a block, took the implementation with it, and left
 * the markup still calling it. The reopen panel lost causeReopenPropose and
 * MOLOCH_PROP_ABI; the Market panel lost loadCausePool and the eight symbols
 * under it, which killed the render mid-flight and took Proposals & Chat, the
 * refresh timer and the connect path down with it.
 *
 * None of it was caught, because nothing executes these pages: the rest of the
 * suite boots zSwap.html, dapp/index.html and dapp/dao/index.html, and the coin
 * page was only ever syntax-checked. A syntax check is exactly the wrong shape
 * of test for this bug — every one of those files parsed perfectly.
 *
 * So this asserts the one invariant that would have caught all three, without
 * booting anything: every name an inline handler calls, and every bare call at
 * statement level, resolves to something the page or its <script src> deps
 * define.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

const PAGES = ['dapp/coin/index.html', 'dapp/index.html', 'dapp/dao/index.html',
               'dapp/auction/index.html', 'dapp/predict/index.html', 'dapp/orderbook/index.html'];

// Names the page gets from somewhere other than its own text.
const AMBIENT = new Set([
  'alert','confirm','prompt','open','close','print','fetch','setTimeout','setInterval',
  'clearTimeout','clearInterval','requestAnimationFrame','scrollTo','encodeURIComponent',
  'decodeURIComponent','parseInt','parseFloat','isNaN','String','Number','Boolean','BigInt',
  'Array','Object','JSON','Math','Date','Promise','Error','Set','Map','RegExp','Symbol',
  'console','window','document','location','navigator','history','localStorage','ethers',
  'return','if','for','while','switch','catch','typeof','void','delete','new','this','function',
  'await','throw','yield','else','do','try','in','of','case','break','continue','super','import',
]);

function definedNames(src) {
  const out = new Set();
  for (const re of [
    /(?:^|\n)\s*(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/g,
    /(?:^|\n)\s*(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=/g,
    /window\.([A-Za-z_$][\w$]*)\s*=/g,
  ]) for (const m of src.matchAll(re)) out.add(m[1]);
  return out;
}

for (const page of PAGES) {
  const file = path.join(ROOT, page);
  if (!fs.existsSync(file)) continue;

  test(`${page}: every handler it names is defined`, () => {
    const html = fs.readFileSync(file, 'utf8');
    const defined = definedNames(html);

    // Pull in whatever the page loads via <script src>, resolved against its own dir.
    for (const m of html.matchAll(/<script[^>]*src=["']([^"']+)["']/g)) {
      const dep = path.resolve(path.dirname(file), m[1]);
      if (fs.existsSync(dep)) definedNames(fs.readFileSync(dep, 'utf8')).forEach(n => defined.add(n));
    }

    // ...and whatever it pulls in by hand. dapp/index.html defers most of itself to
    // modules it document.write()s from a TAB_MODULES table, so a static src scan sees
    // almost none of the page's real vocabulary.
    for (const m of html.matchAll(/['"](\.?\/?(?:modules|vendor)\/[\w.-]+\.js)['"]/g)) {
      const dep = path.resolve(path.dirname(file), m[1]);
      if (fs.existsSync(dep)) definedNames(fs.readFileSync(dep, 'utf8')).forEach(n => defined.add(n));
    }

    const missing = new Map();
    const note = (name, where) => {
      if (defined.has(name) || AMBIENT.has(name)) return;
      if (!missing.has(name)) missing.set(name, where);
    };

    // A JS comment describing a handler is not a handler. Dropping comment-only lines
    // is enough: a real handler lives in emitted markup, never after a // on its own line.
    const code = html.split('\n')
      .filter(l => { const t = l.trim(); return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*'); })
      .join('\n');

    // 1. inline event handlers: onclick="foo(...)", oninput="bar(...)"
    for (const m of code.matchAll(/\bon[a-z]+=["']\s*([A-Za-z_$][\w$]*)\s*\(/g)) note(m[1], `on-handler ${m[1]}()`);

    // 2. bare statement-level calls inside the page's own scripts — the shape that
    //    killed the render at loadCausePool(...) rather than merely failing on click.
    for (const s of code.matchAll(/<script(?![^>]*src=)[^>]*>([\s\S]*?)<\/script>/g))
      for (const m of s[1].matchAll(/(?:^|\n)\s{0,4}([A-Za-z_$][\w$]*)\s*\(/g)) note(m[1], `bare call ${m[1]}()`);

    assert.deepEqual([...missing.entries()], [],
      `${page} names ${missing.size} function(s) that nothing defines:\n` +
      [...missing.values()].map(v => '  - ' + v).join('\n'));
  });
}
