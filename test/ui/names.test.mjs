/**
 * Claiming a .wei name, and the roll it can enter.
 *
 * Two registrations live behind one tile. A FREE `name.id.wei` is a single
 * transaction to the subdomain registrar, no ether, nothing held. A PAID
 * `name.wei` is ENS-style commit/reveal against the same registry the page
 * already resolves through: commit a hash, wait a minute, then reveal the
 * label and the secret with the fee attached.
 *
 * Commit/reveal is the only flow in this page where a user can be out of
 * pocket with nothing to show for it. The commitment is `keccak256(abi.encode(
 * bytes normalizedLabel, address owner, bytes32 secret))`, computed on the
 * page - so an encoder that is wrong by one word, or a secret that does not
 * outlive a reload, burns the commit fee and leaves the name unclaimable
 * until the commitment lapses. That is what most of this file is about.
 *
 * The expected commitment below is not derived here. It was read from mainnet:
 *
 *   cast call 0x0000000000696760E15f265e828DB644A0c242EB \
 *     "makeCommitment(string,address,bytes32)(bytes32)" \
 *     "zswaptest" 0x1111...1111 0x2222...2222
 *
 * which is why the fixtures below use that label, that account and that
 * secret: the page has to reproduce a value the registry itself produced.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const WNS = '0x0000000000696760E15f265e828DB644A0c242EB';
const WREG = '0x53745292f0d30d68204a63002C17bDa16C772bf7';
const WROLL = '0x0000C82AA4D72871568eF3859D2b0E7CF37e45f2';
const IDWEI = 'cea9efa56b7c8a673303d04b917a7119a2a68f8c4803d8e6fd1c3a1f0d2e4ebe';

const SEL = {
  AVAIL: '8f8dc386', FEE: 'fcee45f4', PREM: '1bf1fffb', CID: 'fb021939',
  COMMIT: 'f14fcbc8', COMMITS: '839df945', REVEAL: 'ea9384fa', SUB: 'a00fd3c8', REV: '9af8b7aa',
  STATE: 'c19d93fb', WEIGHT: '0767d178', TICKET: '673b4784', ENTER: '23972aef',
  OWNER: '6352211e',
};

// Read from mainnet, not computed here. See the header.
const MAINNET_COMMITMENT = '0xcb53c3959d18f8c373553bde8c221b25531ee561ee917e0dec88b859b4677c29';
const SECRET = '0x' + '22'.repeat(32);

const ETH = 10n ** 18n;
const word = (data, i) => data.slice(10 + i * 64, 10 + (i + 1) * 64);
const u256 = v => BigInt(v).toString(16).padStart(64, '0');
const FEE = 5n * 10n ** 14n;   // what mainnet charges a 5+ character label

// A registry that says yes to everything and prices every name the same. The
// page's job is to ask the right questions and spend the right value; deriving
// a fee schedule in the mock would only be testing the mock. Defaults only: a
// test that has already said what a selector answers keeps its own answer, so
// a fixture cannot quietly overwrite the thing under test.
const withWns = (chain, { available = true } = {}) => {
  const fill = (to, sel, hex) => {
    if (!chain.answers.has(`${to.toLowerCase()}:${sel}`)) chain.answer(to, sel, hex);
  };
  fill(WNS, SEL.AVAIL, data => {
    // isAvailable(string label, uint256 parentId): offset, parentId, then the
    // label. A query under the wrong parent is answered honestly - false -
    // rather than waved through, so the page cannot pass a parent that would
    // make every name on chain look taken.
    const parent = data.slice(10 + 64, 10 + 128);
    const wanted = parentSeen => parentSeen === u256(0) || parentSeen === IDWEI;
    if (!wanted(parent)) return '0x' + u256(0);
    return '0x' + u256(available ? 1 : 0);
  });
  fill(WNS, SEL.FEE, '0x' + u256(FEE));
  fill(WNS, SEL.PREM, '0x' + u256(0));
  fill(WNS, SEL.CID, '0x' + u256(0x1234));
  fill(WNS, SEL.REV, '0x' + u256(0x20) + u256(0));     // no primary name
  fill(WROLL, SEL.STATE, '0x' + [1, 0, 2000000000, ETH / 10n, 0, 57, 10n ** 18n, 0, 0, 0, 0, 0, 0].map(u256).join(''));
  // The page pre-flights every transaction as an `eth_call` before it asks the
  // wallet, so the write selectors need an answer too or the flow dies before
  // anything is signed.
  fill(WNS, SEL.COMMIT, '0x');
  // commitments(bytes32) — the registry's own record of when it accepted a
  // commitment. This is what the countdown must run on: the same number the
  // contract measures MIN/MAX_COMMITMENT_AGE against.
  fill(WNS, SEL.COMMITS, () => chain.commitBlocked ? undefined : '0x' + u256(chain.commitAt ?? 0));
  fill(WNS, SEL.REVEAL, '0x' + u256(0x1234));
  fill(WREG, SEL.SUB, '0x' + u256(0x1234));
  fill(WROLL, SEL.ENTER, '0x');
  return chain;
};

// The page reads getRandomValues once per commit; pinning it is what lets the
// commitment be compared against a value the chain produced.
const fixSecret = p => {
  p.window.crypto.getRandomValues = a => { for (let i = 0; i < a.length; i++) a[i] = 0x22; return a; };
};

async function openNames(opts = {}) {
  const chain = withWns(opts.chain ?? new MockChain(), opts);
  chain.setNative(A.ACCOUNT, 10n * ETH);
  const p = await loadPage({ chain });
  await p.connect();
  p.click('wn');
  await p.settle();
  return p;
}

/**
 * The wei panel is not driven by `update()` - that function returns early the
 * moment names mode is on, which is deliberate: a name has no quote to refresh.
 * The cost is that connecting a wallet, which ends in `update()`, refreshed
 * everything EXCEPT the panel the person was looking at. Clicking connect from
 * the wei tab left the button on its disconnected label with no quote behind
 * it: the wallet was connected and the tab looked dead.
 */
describe('connecting from the wei tab', () => {
  async function disconnected(opts = {}) {
    const chain = withWns(opts.chain ?? new MockChain({ autoConnected: false }), opts);
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain });
    p.click('wn');
    await p.settle();
    return p;
  }

  test('the panel comes to life instead of sitting there', async () => {
    const p = await disconnected();
    assert.ok(p.visible('wnPanel'), 'the wei panel should be open');
    p.type('wnName', 'satoshi');
    await p.settle();

    // Disconnected, the register button offers to connect rather than register.
    p.click('wnGo');
    await p.settle();
    await p.settle();

    assert.ok(p.text('addr') !== 'Connect', 'the wallet should be connected');
    await p.waitFor(() => !p.$('wnGo').disabled,
      { label: 'the panel to come back after connecting' });
    assert.doesNotMatch(p.text('wnGo'), /Connecting/, 'the button must not stay mid-connect');
    p.close();
  });

  /**
   * `swap` carries every word connect() says about its progress - and names
   * mode hides `swap`. So connecting from the wei tab showed NOTHING while the
   * wallet was deciding: no label change, no spinner, a dead-looking tab for as
   * long as the wallet took. That is the hang.
   */
  test('it says it is connecting, on the button being looked at', async () => {
    const p = await disconnected();
    // The register button is inert without a name in the box, so give it one.
    p.type('wnName', 'satoshi');
    await p.settle();
    let release;
    const held = new Promise(r => { release = r; });
    const inner = p.chain.request.bind(p.chain);
    p.chain.request = async args => {
      if (args.method === 'eth_requestAccounts') await held;
      return inner(args);
    };

    p.click('wnGo');
    await p.waitFor(() => /Connecting/.test(p.text('wnGo')),
      { label: 'the wei button to report the connection in progress' });
    assert.ok(p.$('wnGo').disabled, 'and not invite a second click');

    release();
    await p.settle();
    await p.waitFor(() => !p.$('wnGo').disabled, { label: 'the button to come back' });
    p.close();
  });

  test('the roll entry button does the same', async () => {
    const p = await disconnected();
    p.type('wnName', 'satoshi');
    await p.settle();
    p.click('wnEnter');
    await p.settle();
    await p.settle();
    assert.ok(p.text('addr') !== 'Connect', 'the wallet should be connected');
    p.close();
  });
});

describe('claiming a name', () => {
  test('is a tile beside liquidity and launch, and displaces them', async () => {
    const p = await openNames();
    assert.ok(p.visible('wnPanel'), 'the panel should open with the tile');
    assert.equal(p.$('wn').getAttribute('aria-pressed'), 'true');

    p.click('ln');
    await p.settle();
    assert.ok(!p.visible('wnPanel'), 'launch should displace names');
    assert.equal(p.$('wn').getAttribute('aria-pressed'), 'false');
    p.close();
  });

  test('does not follow the user off the swap tab', async () => {
    // The mode toggles only exist on Swap, and setTab dismisses each one by
    // name on the way out. A mode missing from that list does not hide with
    // its button - it stays open over whatever tab you switched to.
    const p = await openNames();
    p.click('tabBook');
    await p.settle();
    assert.ok(!p.visible('wnPanel'), 'the names panel followed the user to Orders');
    assert.ok(!p.visible('wnGo'), 'the register button followed the user to Orders');
    assert.ok(!p.visible('wnRollPanel'), 'the roll followed the user to Orders');
    assert.ok(!p.visible('wn'), 'the tile should only be offered on Swap');
    p.close();
  });

  test('survives a round trip through another tab without leaking the swap form', async () => {
    // setTab re-shows the receive panel and the flip arrow every time it lands
    // on Swap. A mode that hid them only once, at toggle time, comes back to a
    // half-swap-half-names form.
    const p = await openNames();
    p.click('tabSend');
    await p.settle();
    p.click('tabSwap');
    await p.settle();

    // Leaving Swap dismisses the mode outright, so coming back is a plain swap.
    assert.ok(!p.visible('wnPanel'), 'the names panel came back on its own');
    assert.ok(p.visible('rcvPanel'), 'the receive panel did not come back');

    // And re-opening it hides the swap form completely, not partially.
    p.click('wn');
    await p.settle();
    assert.ok(!p.visible('rcvPanel'), 'the receive panel leaked into names mode');
    assert.ok(!p.visible('rc'), 'the recipient box leaked into names mode');
    assert.ok(!p.visible('flip'), 'the flip arrow leaked into names mode');
    p.close();
  });

  test('refuses a label the registry would refuse, before spending anything', async () => {
    const p = await openNames();
    for (const bad of ['-lead', 'trail-', 'has.dot', 'has space']) {
      p.type('wnName', bad);
      await p.settle();
      assert.match(p.text('wnNote'), /hyphen|Letters/,
        `"${bad}" should be refused on the page, got ${p.text('wnNote')}`);
      assert.ok(p.$('wnGo').disabled, `"${bad}" left the button live`);
    }
    assert.equal(p.chain.sent.length, 0, 'a refused label must cost no transaction');
    p.close();
  });

  test('the commitment matches what the registry itself computes', async () => {
    // The whole point. If this drifts, a commit is paid for and the reveal
    // that follows it can never match.
    const p = await openNames();
    fixSecret(p);
    p.type('wnName', 'zswaptest');
    await p.settle();
    p.click('wnGo');
    await p.settle();

    const sent = p.chain.sent.filter(t => (t.to || '').toLowerCase() === WNS.toLowerCase());
    assert.equal(sent.length, 1, 'a commit should be one transaction to the registry');
    assert.equal(sent[0].data.slice(0, 10), '0x' + SEL.COMMIT, 'should call commit');
    assert.equal('0x' + word(sent[0].data, 0), MAINNET_COMMITMENT,
      'the page computed a different commitment than mainnet does for the same inputs');
    assert.equal(BigInt(sent[0].value || 0), 0n, 'a commit carries no value');
    p.close();
  });

  test('uppercase is folded before it is hashed, not after', async () => {
    // The registry normalizes A-Z internally, so a commitment over the raw
    // bytes of "ZSwapTest" is one it will never be able to match - the fee is
    // spent and the name is unclaimable until the commitment lapses.
    const p = await openNames();
    fixSecret(p);
    p.type('wnName', 'ZSwapTest');
    await p.settle();
    p.click('wnGo');
    await p.settle();
    const sent = p.chain.sent.filter(t => (t.to || '').toLowerCase() === WNS.toLowerCase());
    assert.equal('0x' + word(sent[0].data, 0), MAINNET_COMMITMENT,
      'the commitment must be over the lowercased label');
    p.close();
  });

  test('the secret is written down before the wallet is asked, and survives a reload', async () => {
    const p = await openNames();
    fixSecret(p);
    p.type('wnName', 'zswaptest');
    await p.settle();
    p.click('wnGo');
    await p.settle();

    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    const held = JSON.parse(p.window.localStorage.getItem(key));
    assert.equal(held.label, 'zswaptest', 'the label was not kept');
    assert.equal(held.secret, SECRET, 'the secret was not kept');
    assert.ok(Number.isFinite(held.at), 'the commit time was not kept');
    p.close();
  });

  test('the countdown runs from the registry\'s own record, not from the click', async () => {
    // The registry measures MIN_COMMITMENT_AGE from when IT recorded the
    // commitment. Wallet approval and mining both happen after the click, so a
    // countdown started at click time reaches zero while the registry still
    // refuses - and the refusal lands as CommitmentTooNew on the transaction
    // that carries the fee.
    const chain = new MockChain();
    // Well behind the wall clock: if the page stamps from Date.now() this test
    // cannot tell the difference, so make them disagree loudly.
    chain.commitAt = Math.floor(Date.now() / 1000) - 4242;
    const p = await openNames({ chain });
    fixSecret(p);
    p.type('wnName', 'zswaptest');
    await p.settle();
    p.click('wnGo');
    await p.settle();

    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    const held = JSON.parse(p.window.localStorage.getItem(key));
    assert.equal(held.at, chain.commitAt,
      'the commitment was stamped from the local clock, not from the registry');
    p.close();
  });

  test('an unconfirmed commitment counts down nothing and reveals nothing', async () => {
    const p = await openNames();
    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    // A tab closed while the wallet was still confirming: a secret and a hash,
    // but no block yet. It is neither ready nor lapsed, and must read as
    // neither - `at` of 0 is an age of ~57 years if taken literally.
    p.window.localStorage.setItem(key, JSON.stringify({
      label: 'zswaptest', secret: SECRET, at: 0, tx: '0x' + 'ab'.repeat(32),
    }));
    p.chain.commitBlocked = true;    // the registry cannot be read yet
    p.click('wn'); await p.settle();
    p.click('wn'); await p.settle();
    assert.match(p.text('wnGo'), /Confirming/, `got ${p.text('wnGo')}`);
    assert.ok(p.$('wnGo').disabled, 'an unconfirmed commitment offered a reveal');
    assert.doesNotMatch(p.text('wnGo'), /Commit again/,
      'an unconfirmed commitment must not read as a lapsed one');
    p.close();
  });

  test('a commitment recovers on its own when the registry read comes good', async () => {
    // The stamp used to run once and swallow its error, so a single failed
    // read stranded a PAID commitment on "Confirming…" for the whole 24-hour
    // reveal window, recoverable only by toggling the mode off and on. Note
    // there is no `tx` below on purpose: a tab closed during the wallet prompt
    // never recorded one, and the recovery must not depend on it.
    const p = await openNames();
    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    p.window.localStorage.setItem(key, JSON.stringify({
      label: 'zswaptest', secret: SECRET, at: 0,
    }));
    p.chain.commitBlocked = true;               // the node cannot answer yet
    p.click('wn'); await p.settle();
    p.click('wn'); await p.settle();
    assert.match(p.text('wnGo'), /Confirming/, `got ${p.text('wnGo')}`);

    // The node catches up, and the tick that draws the countdown picks it up
    // without the user touching anything.
    p.chain.commitBlocked = false;
    // The retry is paced at 5s off the countdown tick, so give it real time.
    for (let i = 0; i < 10 && !JSON.parse(p.window.localStorage.getItem(key)).at; i++) {
      await new Promise(r => setTimeout(r, 1100));
      await p.settle();
    }
    const held = JSON.parse(p.window.localStorage.getItem(key));
    assert.equal(held.at, p.chain.commitAt,
      'the commitment never recovered its timestamp from the registry');
    p.close();
  });

  test('a commit that never reaches the chain is escapable, not a dead end', async () => {
    // `commitments()` answers 0 both for "not yet" and for "never" - a dropped
    // or replaced commit tx is indistinguishable from a slow one. Waiting
    // forever on "Confirming…" is the wrong answer to the second case, and it
    // is the case where the user still has a name they want.
    const p = await openNames();
    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    p.chain.commitBlocked = true;
    p.window.localStorage.setItem(key, JSON.stringify({
      label: 'zswaptest', secret: SECRET, at: 0,
      since: Math.floor(Date.now() / 1000) - 900,   // eleven minutes ago
    }));
    p.click('wn'); await p.settle();
    p.click('wn'); await p.settle();
    assert.match(p.text('wnGo'), /Commit again/, `got ${p.text('wnGo')}`);
    assert.ok(!p.$('wnGo').disabled, 'the way out was offered but not clickable');

    p.click('wnGo');
    await p.settle();
    assert.equal(p.window.localStorage.getItem(key), null,
      'the dead commitment should have been cleared');
    assert.equal(p.chain.sent.length, 0, 'clearing a dead commitment must not spend anything');
    p.close();
  });

  test('a commit still within the window is not offered as dead', async () => {
    const p = await openNames();
    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    p.chain.commitBlocked = true;
    p.window.localStorage.setItem(key, JSON.stringify({
      label: 'zswaptest', secret: SECRET, at: 0,
      since: Math.floor(Date.now() / 1000) - 30,
    }));
    p.click('wn'); await p.settle();
    p.click('wn'); await p.settle();
    assert.match(p.text('wnGo'), /Confirming/, `got ${p.text('wnGo')}`);
    assert.ok(p.$('wnGo').disabled, 'a commit still settling was offered as dead');
    assert.ok(p.window.localStorage.getItem(key), 'it must keep its secret meanwhile');
    p.close();
  });

  test('a commit that is merely slow or unfollowable keeps its secret', async () => {
    // Only a REFUSAL is worth discarding a commitment for. A timeout, a
    // dropped connection, a wallet answering in a shape the page cannot
    // follow - the fee is spent and the name is still claimable for 24 hours,
    // so throwing the secret away for one of those loses it for nothing.
    const p = await openNames();
    fixSecret(p);
    p.type('wnName', 'zswaptest');
    await p.settle();
    p.chain.garbleNextTxHash = true;
    p.click('wnGo');
    await p.settle();

    assert.equal(p.chain.sent.length, 1, 'the commit should still have been sent');
    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    const held = JSON.parse(p.window.localStorage.getItem(key) || 'null');
    assert.ok(held, 'the secret for a sent commit was discarded on a non-refusal');
    assert.equal(held.secret, SECRET, 'the wrong secret was kept');
    p.close();
  });

  test('a commit the chain throws out does not leave a secret behind', async () => {
    const p = await openNames();
    fixSecret(p);
    p.type('wnName', 'zswaptest');
    await p.settle();
    p.chain.failNextReceipt = true;
    p.click('wnGo');
    await p.settle();
    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    assert.equal(p.window.localStorage.getItem(key), null,
      'a reverted commit left a commitment that can never be revealed');
    p.close();
  });

  test('a wallet that refuses the commit does not leave a secret behind', async () => {
    // A pending commitment the chain never heard of would sit in the way of
    // the next attempt, counting down against a commit that does not exist.
    const p = await openNames();
    fixSecret(p);
    p.type('wnName', 'zswaptest');
    await p.settle();
    p.chain.rejectNext = new Error('user rejected');
    p.click('wnGo');
    await p.settle();

    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    assert.equal(p.window.localStorage.getItem(key), null,
      'a refused commit left a pending commitment behind');
    p.close();
  });

  test('a free name is one transaction to the registrar, and says it cannot enter the roll', async () => {
    const p = await openNames();
    p.$('wnTld').value = 'id';
    p.$('wnTld').dispatchEvent(new p.window.Event('change'));
    p.type('wnName', 'satoshi');
    await p.settle();
    assert.match(p.text('wnNote'), /free/, 'a free name should say so');
    assert.match(p.text('wnNote'), /does not weigh/,
      'a free name must disclose that it cannot enter the roll');

    p.click('wnGo');
    await p.settle();
    assert.equal(p.chain.sent.length, 1, 'a free claim is one transaction');
    const tx = p.chain.sent[0];
    assert.equal(tx.to.toLowerCase(), WREG.toLowerCase(), 'should go to the subdomain registrar');
    assert.equal(tx.data.slice(0, 10), '0x' + SEL.SUB);
    assert.equal(word(tx.data, 0), IDWEI, 'should register under id.wei');
    assert.equal(BigInt(tx.value || 0), 0n, 'a free name costs no ether');
    p.close();
  });

  test('a commitment under a minute old is offered as a countdown, not a button', async () => {
    const p = await openNames();
    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    p.window.localStorage.setItem(key, JSON.stringify({
      label: 'zswaptest', secret: SECRET, at: Math.floor(Date.now() / 1000) - 20,
    }));
    p.click('wn'); await p.settle();   // close
    p.click('wn'); await p.settle();   // and reopen, as a reload would
    assert.match(p.text('wnGo'), /Ready in \d+s/, `got ${p.text('wnGo')}`);
    assert.ok(p.$('wnGo').disabled, 'a commitment too young to reveal left the button live');
    assert.match(p.text('wnNote'), /zswaptest\.wei is held for you/,
      'a resumed commitment should say what it is holding');
    p.close();
  });

  test('a ripe commitment reveals with the fee attached', async () => {
    const p = await openNames();
    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    p.window.localStorage.setItem(key, JSON.stringify({
      label: 'zswaptest', secret: SECRET, at: Math.floor(Date.now() / 1000) - 120,
    }));
    p.click('wn'); await p.settle();
    p.click('wn'); await p.settle();
    assert.match(p.text('wnGo'), /Register zswaptest\.wei/, `got ${p.text('wnGo')}`);

    p.click('wnGo');
    await p.settle();
    const tx = p.chain.sent.find(t => (t.to || '').toLowerCase() === WNS.toLowerCase());
    assert.ok(tx, 'nothing was revealed');
    assert.equal(tx.data.slice(0, 10), '0x' + SEL.REVEAL);
    assert.equal('0x' + word(tx.data, 1), SECRET, 'the wrong secret was revealed');
    assert.equal(BigInt(tx.value), FEE, `the reveal must carry the fee, got ${BigInt(tx.value)}`);
    assert.equal(p.window.localStorage.getItem(key), null,
      'a completed registration should release the secret');
    p.close();
  });

  test('a commitment past a day is offered again, not revealed into a revert', async () => {
    const p = await openNames();
    const key = 'zswap:wns:' + A.ACCOUNT.toLowerCase();
    p.window.localStorage.setItem(key, JSON.stringify({
      label: 'zswaptest', secret: SECRET, at: Math.floor(Date.now() / 1000) - 86401,
    }));
    p.click('wn'); await p.settle();
    p.click('wn'); await p.settle();
    assert.match(p.text('wnGo'), /Commit again/, `got ${p.text('wnGo')}`);

    p.click('wnGo');
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'a lapsed commitment must not be revealed');
    assert.equal(p.window.localStorage.getItem(key), null, 'a lapsed commitment should be dropped');
    p.close();
  });

  test('the roll reports itself, and says a nameless account cannot enter', async () => {
    const p = await openNames();
    assert.match(p.text('wnRollEl'), /57 entered/, `got ${p.text('wnRollEl')}`);
    assert.match(p.text('wnRollEl'), /0\.100 ETH staked/, `got ${p.text('wnRollEl')}`);
    assert.match(p.text('wnRollEl'), /Any paid \.wei name you own can enter/,
      'an account with no name should be told how to get in, not just that it cannot');
    // The way in is always on screen; it says what is missing rather than
    // vanishing, which is what left the roll looking like a readout.
    assert.ok(p.visible('wnEnter'), 'the roll offered no affordance at all');
    assert.equal(p.$('wnEnter').textContent, 'Enter a name you own');
    assert.equal(p.$('wnEnter').dataset.id, '', 'nothing is chosen, so nothing should be enterable');
    p.close();
  });

  test('an account whose name weighs is offered the roll, and enters free', async () => {
    const chain = new MockChain();
    // A primary name that the roll gives weight and that has not entered.
    chain.answer(WNS, SEL.REV, '0x' + u256(0x20) + u256(9) + Buffer.from('zswap.wei').toString('hex').padEnd(64, '0'));
    chain.answer(WROLL, SEL.WEIGHT, '0x' + u256(10n ** 17n));
    chain.answer(WROLL, SEL.TICKET, '0x' + u256(0));
    const p = await openNames({ chain });
    assert.ok(p.visible('wnEnter'), 'a weighing name was not offered the roll');
    assert.match(p.text('wnRollEl'), /zswap\.wei can enter, free/, `got ${p.text('wnRollEl')}`);

    p.click('wnEnter');
    await p.settle();
    const tx = p.chain.sent.find(t => (t.to || '').toLowerCase() === WROLL.toLowerCase());
    assert.ok(tx, 'entering sent nothing');
    assert.equal(tx.data.slice(0, 10), '0x' + SEL.ENTER);
    assert.equal(BigInt(tx.value || 0), 0n, 'entering the roll costs no ether');
    p.close();
  });

  test('a name already in the roll shows its odds instead of an entry button', async () => {
    const chain = new MockChain();
    chain.answer(WNS, SEL.REV, '0x' + u256(0x20) + u256(9) + Buffer.from('zswap.wei').toString('hex').padEnd(64, '0'));
    chain.answer(WROLL, SEL.WEIGHT, '0x' + u256(10n ** 17n));
    chain.answer(WROLL, SEL.TICKET, '0x' + u256(3));
    const p = await openNames({ chain });
    assert.match(p.text('wnRollEl'), /zswap\.wei is in, at about 10\.00%/, `got ${p.text('wnRollEl')}`);
    assert.equal(p.$('wnEnter').dataset.id, '',
      'a name already in the roll must not be enterable again');
    p.close();
  });

  test('asks the registry under the right parent for each ending', async () => {
    // A .wei name hangs off parent 0; a .id.wei name hangs off id.wei. Getting
    // this wrong does not fail loudly - it reports every available name as
    // taken, which reads as the registry being full rather than as a bug.
    const p = await openNames();
    // The quote is async, and `settle` can return before it has gone out under
    // a loaded test run - so wait for the question to actually be asked rather
    // than assuming it already was.
    const asked = () => p.chain.calls.filter(c => c.selector === SEL.AVAIL);
    const nextAsk = async (n, label) => {
      await p.waitFor(() => asked().length > n, { label });
      return asked().pop();
    };

    let n = asked().length;
    p.type('wnName', 'zqxjv');
    const paid = await nextAsk(n, 'the .wei availability check');
    assert.equal(paid.data.slice(10 + 64, 10 + 128), u256(0),
      'a .wei name must be asked for under parent 0');

    n = asked().length;
    p.$('wnTld').value = 'id';
    p.$('wnTld').dispatchEvent(new p.window.Event('change'));
    const free = await nextAsk(n, 'the .id.wei availability check');
    assert.equal(free.data.slice(10 + 64, 10 + 128), IDWEI,
      'a .id.wei name must be asked for under id.wei');
    await p.settle();   // let the quote finish before the window goes away
    p.close();
  });

  test('the way into the roll is never taken off the screen', async () => {
    // It used to be hidden in one place and un-hidden in another, so typing a
    // name while disconnected removed the only affordance there was - the roll
    // became a readout with no way in. Visibility is derived in one place now,
    // and the label carries whatever is missing.
    const p = await openNames();
    const seen = [];
    const look = async () => {
      await p.settle();
      assert.ok(p.visible('wnEnter'), `the way in vanished: ${JSON.stringify(seen)}`);
      seen.push(p.text('wnEnter'));
    };
    await look();                                   // nothing typed
    p.type('wnName', 'zqxjv9'); await look();        // an available name
    p.type('wnName', 'ross'); await look();          // a taken one
    p.$('wnTld').value = 'id';
    p.$('wnTld').dispatchEvent(new p.window.Event('change'));
    await look();                                   // the free ending
    p.type('wnName', ''); await look();              // and back to empty
    assert.ok(seen.every(t => t && t.trim()), `every state needs a label, got ${JSON.stringify(seen)}`);
    p.close();
  });

  /**
   * The round the quote asks about has to be the round the chain is on. The
   * quote and the roll readout start together, so a quote that reused the
   * cached round asked about round zero until the readout landed. Round zero
   * is over after the first draw, and asking it always answers "not in" -
   * which offers an entry the contract would revert.
   */
  test('a typed name is checked against the round the chain is on', async () => {
    const chain = new MockChain();
    const ROUND = 2n;
    // The readout's own attempt fails, which is exactly the state that used to
    // leave the cached round sitting at zero for every quote after it.
    let asked = 0;
    chain.answer(WROLL, SEL.STATE, () => asked++ === 0 ? undefined
      : '0x' + [1, ROUND, 2000000000, ETH / 10n, 0, 57, 10n ** 18n, 0, 0, 0, 0, 0, 0].map(u256).join(''));
    chain.answer(WNS, SEL.OWNER, '0x' + '0'.repeat(24) + A.ACCOUNT.slice(2).toLowerCase());
    chain.answer(WROLL, SEL.WEIGHT, '0x' + u256(10n ** 17n));
    const rounds = [];
    chain.answer(WROLL, SEL.TICKET, data => { rounds.push(BigInt('0x' + word(data, 0))); return '0x' + u256(0); });

    // Registered - the roll only takes a name that exists.
    const p = await openNames({ chain, available: false });
    p.type('wnName', 'zswap');
    await p.settle();

    assert.ok(asked > 1, 'the quote never read the round for itself');
    assert.ok(rounds.length, 'the roll was never asked about the typed name');
    assert.deepEqual([...new Set(rounds)], [ROUND],
      `ticketOf was asked about rounds ${rounds.join(', ')}, not the live round ${ROUND}`);
    assert.equal(p.$('wnEnter').textContent, 'Enter zswap.wei in the roll');
    assert.notEqual(p.$('wnEnter').dataset.id, '', 'a name that can enter was left unenterable');
    p.close();
  });

  test('a taken name is refused without a transaction', async () => {
    const p = await openNames({ available: false });
    p.type('wnName', 'zswap');
    await p.settle();
    assert.match(p.text('wnNote'), /taken/);
    assert.ok(p.$('wnGo').disabled, 'a taken name left the button live');
    p.close();
  });
});

