/**
 * Paying a name privately, and publishing your Tacit address on one.
 *
 * A name carries its owner's Tacit address in a "finance.tacit" text record,
 * so a sender types the name and the payment stays private. The record lives
 * wherever the name does: .wei and .gwei on their registries, .eth on its
 * resolver, and a Basename on Base - which is read here, but cannot be
 * written from this page, because the private panel is Ethereum's.
 *
 * Run: node --test test/ui/tacit-names.test.mjs
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const F = JSON.parse(fs.readFileSync(path.join(ROOT, 'test', 'fixtures', 'confidential.json'), 'utf8'));
const KEY = { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: F.seed };
const SLOW = { timeout: 30000 };
const RECIP = F.send.lock.recipient;

async function open(chain) {
  const p = await loadPage({ chain, storage: { ...KEY } });
  await p.connect();
  p.click('pv');
  await p.settle();
  p.click('pvGo');                       // one signature per visit unlocks the key
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'the key to unlock', ...SLOW });
  return p;
}
/** A tacit1 address for a key, with the Ethereum lane its flag byte declares. */
const tacitFor = (p, key) => p.window.eval(`cpTacEnc("tacit",cpCat([0,3],hexToBytes("${key}"),hexToBytes("${key}"),hexToBytes("${key}")))`);
/** What the page makes of a recipient the sender typed. */
const recip = (p, s) => p.window.eval(`cpRecipAt(${JSON.stringify(s)}).then(h=>"OK:"+h,e=>"ERR:"+(e&&e.message||e))`);
const pubBtn = p => p.$('pvKey').querySelector('button[data-a="pub"]');

describe('paying a name privately', () => {
  test('a Basename that published a Tacit address is paid by name, read from Base', async () => {
    const chain = new MockChain();
    chain.ensResolver = A.ENSRESOLVER;
    chain.texts = new Map([['bob.base.eth|finance.tacit', 'PLACEHOLDER']]);
    const p = await open(chain);
    chain.texts.set('bob.base.eth|finance.tacit', tacitFor(p, RECIP));
    p.queueConfirm(true);
    assert.equal(await recip(p, 'bob.base.eth'), 'OK:' + RECIP.toLowerCase().replace(/^0x/, ''), 'the key the Basename publishes');
    assert.match(p.asked.confirm.at(-1), /bob\.base\.eth → tacit1/, 'the sender sees where the name points');
    p.close();
  });

  test('a Basename with nothing published is not told to publish from a panel that refuses it', async () => {
    const chain = new MockChain();
    chain.ensResolver = A.ENSRESOLVER;
    chain.texts = new Map();
    const p = await open(chain);
    const r = await recip(p, 'bob.base.eth');
    assert.match(r, /^ERR:/);
    assert.match(r, /finance\.tacit record on Base/, r);
    assert.doesNotMatch(r, /zSwap's private panel/, 'the page cannot publish a Basename, so it must not say it can');
    p.close();
  });

  test('a .wei name is still read from its own registry', async () => {
    const chain = new MockChain();
    const p = await open(chain);
    chain.texts = new Map([['bob.wei|finance.tacit', tacitFor(p, RECIP)]]);
    p.queueConfirm(true);
    assert.equal(await recip(p, 'bob.wei'), 'OK:' + RECIP.toLowerCase().replace(/^0x/, ''));
    p.close();
  });
});

describe('seeing your own address', () => {
  test('the panel shows the tacit1 address in short, and the modal gives it in full', async () => {
    const p = await open(new MockChain());
    const addr = p.window.eval('cpTacAddr(cpSeed)');
    const shown = p.$('pvKey').querySelector('.pvkm').textContent;
    assert.equal(shown, addr.slice(0, 12) + '\u2026' + addr.slice(-6), 'the short form comes from the key itself');
    assert.ok(addr.startsWith(shown.split('\u2026')[0]) && addr.endsWith(shown.split('\u2026')[1]), 'both ends are the real address');
    p.click(p.$('pvKey').querySelector('button[data-a="addr"]'));
    await p.waitFor(() => {
      const ta = p.$('wkList').querySelector('textarea');
      return ta && ta.value === addr;
    }, { label: 'the full address, ready to copy', ...SLOW });
    p.close();
  });
});

describe('publishing to a name', () => {
  const owned = (chain, name) => { chain.names.set(name, A.ACCOUNT); return chain; };

  test('with no primary name, a name this wallet owns can be named and is published to', async () => {
    const chain = owned(new MockChain(), 'alice.wei');
    const p = await open(chain);
    p.queuePrompt('alice.wei');
    p.queueConfirm(true);
    p.click(pubBtn(p));
    await p.waitFor(() => chain.sentTo(A.WNS).length > 0, { label: 'the setText', ...SLOW });
    assert.equal(chain.sentTo(A.WNS).at(-1).data.slice(2, 10), '3fb24782', 'setText(uint256,string,string)');
    assert.equal(chain.texts.get('alice.wei|finance.tacit'), p.window.eval('cpTacAddr(cpSeed)'), 'the key this wallet derives');
    p.close();
  });

  test('a name that does not point at this wallet is refused before any transaction', async () => {
    const chain = new MockChain();
    chain.names.set('mallory.wei', A.OTHER);
    const p = await open(chain);
    p.queuePrompt('mallory.wei');
    p.click(pubBtn(p));
    await p.waitFor(() => /does not point at this wallet/.test(p.text('stat')), { label: 'the refusal', ...SLOW });
    assert.equal(chain.sentTo(A.WNS).length, 0, 'nothing was sent');
    p.close();
  });

  test('a Basename is refused with what to do instead', async () => {
    const chain = new MockChain();
    const p = await open(chain);
    p.queuePrompt('alice.base.eth');
    p.click(pubBtn(p));
    await p.waitFor(() => /record set on Base/.test(p.text('stat')), { label: 'the refusal', ...SLOW });
    p.close();
  });

  test('the panel says which name already carries this key, and republishing is not asked for', async () => {
    const chain = owned(new MockChain(), 'alice.wei');
    chain.reverse.set(A.ACCOUNT.toLowerCase(), 'alice.wei');
    const p = await open(chain);
    chain.texts = new Map([['alice.wei|finance.tacit', p.window.eval('cpTacAddr(cpSeed)')]]);
    p.click('pv'); await p.settle(); p.click('pv'); await p.settle();
    await p.waitFor(() => /published to alice\.wei/.test(p.text('pvKey')), { label: 'the published mark', ...SLOW });
    p.click(pubBtn(p));
    await p.waitFor(() => /already points to your Tacit address/.test(p.text('stat')), { label: 'the note', ...SLOW });
    assert.equal(chain.sentTo(A.WNS).length, 0, 'nothing was sent');
    p.close();
  });

  test('a name holding someone else\'s address is offered for republishing', async () => {
    const chain = owned(new MockChain(), 'alice.wei');
    chain.reverse.set(A.ACCOUNT.toLowerCase(), 'alice.wei');
    const p = await open(chain);
    chain.texts = new Map([['alice.wei|finance.tacit', tacitFor(p, RECIP)]]);
    await p.settle();
    assert.doesNotMatch(p.text('pvKey'), /published to/, 'someone else\'s address is not this key');
    p.queueConfirm(true);
    p.click(pubBtn(p));
    await p.waitFor(() => chain.sentTo(A.WNS).length > 0, { label: 'the setText', ...SLOW });
    assert.equal(chain.texts.get('alice.wei|finance.tacit'), p.window.eval('cpTacAddr(cpSeed)'));
    assert.match(p.asked.confirm.at(-1), /This replaces tacit1/, 'the confirmation says a record is being replaced');
    p.close();
  });

  // A name can resolve to this wallet while a different wallet owns it; the registry's
  // refusal of the write should say that, not surface a bare revert.
  test('a name this wallet does not own is refused in words when the pre-flight reverts', async () => {
    const chain = owned(new MockChain(), 'alice.wei');
    chain.revertOn(A.WNS, '3fb24782', 'execution reverted: custom error 0x82b42900');
    const p = await open(chain);
    p.queuePrompt('alice.wei');
    p.queueConfirm(true);
    p.click(pubBtn(p));
    await p.waitFor(() => /Only alice\.wei's owner can set its records/.test(p.text('stat')), { label: 'the refusal', ...SLOW });
    assert.equal(chain.sentTo(A.WNS).length, 0, 'nothing was sent');
    p.close();
  });
});

after(closeAllPages);
