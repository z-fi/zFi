/**
 * The interaction sounds.
 *
 * The page has a small voice per moment rather than one chime for everything:
 * a single-note blip when a tab moves, a rising fifth when a wallet opens, a
 * soft two-note when the wallet accepts a transaction, an ascending major
 * arpeggio when one CONFIRMS, and a falling pair when one reverts. It costs no
 * fetch and no file - oscillators, envelopes, and a try/catch so a browser
 * without WebAudio (or a test without the stub) is simply silent.
 *
 * What the tests pin is the SHAPE of when it sounds: never at load, once per
 * user action, and - the property the split exists for - the celebratory sound
 * belongs to a transaction that landed, not one that was merely accepted.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;

// The voices, by the notes they play. Named here so a test reads as the sound
// a user hears rather than as a count of oscillators.
const BLIP = [880];
const OPEN = [523.25, 783.99];
const SENT = [392, 587.33];
const GOT = [392, 493.88, 587.33, 783.99];
const FAIL = [311.13, 233.08];

const last = p => p.window.__chime.voices[p.window.__chime.voices.length - 1] || null;

describe('the interaction sounds', () => {
  test('never sound at load, even when the hash opens another tab', async () => {
    const p = await loadPage({ chime: true, chain: new MockChain(), hash: 'tab=send' });
    await p.settle();
    assert.equal(p.window.__chime.ctx, 0, 'the page sang before anyone acted');
    p.close();
  });

  test('a tab click is one blip, one note', async () => {
    const p = await loadPage({ chime: true, chain: new MockChain() });
    await p.settle();
    p.click('tabSend');
    assert.equal(p.window.__chime.ctx, 1, 'each session tunes exactly one context');
    assert.deepEqual(last(p), BLIP, 'a tab should blip, not sing');
    p.close();
  });

  test('the keyboard walks tabs and blips like a click', async () => {
    const p = await loadPage({ chime: true, chain: new MockChain() });
    await p.settle();
    p.$('tabSwap').focus();
    p.$('tabSwap').dispatchEvent(new p.window.KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
    await p.settle();
    assert.deepEqual(last(p), BLIP, 'keyboard navigation did not blip');
    p.close();
  });

  test('connecting opens on a rising fifth', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chime: true, chain });
    await p.settle();
    await p.connect();
    assert.deepEqual(last(p), OPEN, 'connecting did not sing');
    p.close();
  });

  test('acceptance and confirmation are different sounds, in that order', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chime: true, chain });
    await p.connect();
    p.click('tabSend');
    await p.settle();

    // The wallet refuses: no sound at all, because nothing happened.
    chain.rejectNext = new Error('user rejected');
    p.type('rc', A.OTHER);
    await p.typeAmount('amt', '1');
    const quiet = p.window.__chime.voices.length;
    p.click('swap');
    await p.settle();
    assert.equal(p.window.__chime.voices.length, quiet, 'a rejected transaction sang anyway');

    // The wallet takes it, and the chain keeps it: accepted, then landed.
    p.click('swap');
    await p.settle();
    assert.equal(chain.sent.length, 1, 'the send never landed');
    const heard = p.window.__chime.voices.slice(quiet);
    assert.deepEqual(heard, [SENT, GOT], 'a send should be accepted, then celebrated - once each');
    p.close();
  });

  test('the liquidity and coin toggles are navigation, and blip like one', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chime: true, chain });
    await p.connect();
    await p.settle();

    for (const id of ['lq', 'ln']) {
      const before = p.window.__chime.voices.length;
      p.click(id);            // on
      await p.settle();       // the mode loads; let it finish before judging
      assert.deepEqual(last(p), BLIP, `opening ${id} did not blip`);
      p.click(id);            // and off again
      await p.settle();
      assert.deepEqual(last(p), BLIP, `closing ${id} did not blip`);
      assert.equal(p.window.__chime.voices.length, before + 2, `${id} sang more than once per click`);
    }
    p.close();
  });

  test('opening one mode over the other blips once, not twice', async () => {
    // lqSet and lnSet call each other to stay mutually exclusive, so a sound
    // living in the setter rather than on the click would double here.
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chime: true, chain });
    await p.connect();
    await p.settle();
    p.click('lq');
    await p.settle();
    const before = p.window.__chime.voices.length;
    p.click('ln');
    assert.equal(p.window.__chime.voices.length, before + 1, 'displacing a mode sang twice');
    await p.settle();
    p.close();
  });

  test('a launch lands on the fanfare, like any other confirmed transaction', async () => {
    // The launch is the one flow that settles through `waitTx` directly rather
    // than through `settle`, so it does not inherit the confirmation sound -
    // it has to be given one, and this is what says it still has it.
    const COIN = '0x' + '77'.repeat(20);
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setToken(COIN, { symbol: 'ZCAT', decimals: 18, name: 'Zero Cat' });
    chain.launchToken = COIN;
    const p = await loadPage({ chime: true, chain });
    await p.connect();
    p.click('ln');
    await p.settle();

    const quiet = p.window.__chime.voices.length;
    p.type('lnName', 'Zero Cat');
    p.type('lnSym', 'ZCAT');
    p.click('lnGo');
    await p.waitFor(() => /is live/.test(p.text('stat')), { label: 'the launch to settle' });
    const heard = p.window.__chime.voices.slice(quiet);
    assert.deepEqual(heard, [SENT, GOT], 'a coin going live should be accepted, then celebrated');
    p.close();
  });

  test('the mute switch silences everything, and is remembered', async () => {
    // One switch in front of every voice. A page that forgets it was muted is
    // worse than one that never sang - you mute it once per visit forever.
    const p = await loadPage({ chime: true, chain: new MockChain() });
    await p.settle();
    p.click('sd');                       // mute
    const quiet = p.window.__chime.voices.length;
    p.click('tabSend'); await p.settle();
    p.click('tabSwap'); await p.settle();
    assert.equal(p.window.__chime.voices.length, quiet, 'a muted page still sang');
    assert.equal(p.window.localStorage.getItem('snd'), '0', 'the choice was not remembered');
    p.close();

    // A fresh page with that setting stays quiet from the first interaction.
    const q = await loadPage({ chime: true, chain: new MockChain(), storage: { snd: '0' } });
    await q.settle();
    q.click('tabSend');
    await q.settle();
    assert.equal(q.window.__chime.voices.length, 0, 'the page forgot it was muted');
    q.close();
  });

  test('unmuting sings again, so the switch confirms itself', async () => {
    const p = await loadPage({ chime: true, chain: new MockChain(), storage: { snd: '0' } });
    await p.settle();
    p.click('sd');
    await p.settle();
    assert.ok(p.window.__chime.voices.length > 0, 'unmuting should be audible');
    assert.equal(p.window.localStorage.getItem('snd'), '1');
    p.close();
  });

  test('a transaction the chain throws out falls instead of rising', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chime: true, chain });
    await p.connect();
    p.click('tabSend');
    await p.settle();
    p.type('rc', A.OTHER);
    await p.typeAmount('amt', '1');

    const quiet = p.window.__chime.voices.length;
    chain.failNextReceipt = true;
    p.click('swap');
    await p.settle();
    const heard = p.window.__chime.voices.slice(quiet);
    assert.deepEqual(heard, [SENT, FAIL], 'a reverted transaction should be accepted, then mourned - never celebrated');
    p.close();
  });
});
