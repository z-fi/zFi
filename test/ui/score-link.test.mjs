import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);
const ETH = 10n ** 18n;

/**
 * #score=<name>.arcade.wei turns a shared score from a claim into something the
 * reader can check.
 *
 * What it reads matters. The "score" text record is written by the minter, but
 * `setText` is owner-only and the player OWNS the name afterwards - so the
 * holder can rewrite their own record to anything. The LABEL cannot be
 * rewritten by anyone: it is the name itself, fixed by the contract at mint.
 * So the label is the source of truth here and the record is only reported
 * where the two disagree.
 */
function fixture({ owner = A.ACCOUNT, record = null } = {}) {
  const chain = new MockChain({ autoConnected: true });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  chain.scoreName = { owner, record };
  return chain;
}

const card = p => p.$('scEl').textContent.replace(/\s+/g, ' ').trim();

describe('a shared score resolves from chain', () => {
  test('the label is what the card reports', async () => {
    const p = await loadPage({ chain: fixture(), hash: 'score=4820-w7-k3x9.arcade.wei' });
    await p.settle();
    await p.waitFor(() => /Minted score/.test(card(p)), { label: 'the name to resolve' });
    assert.match(card(p), /4,820/, 'the score comes out of the label');
    assert.match(card(p), /wave 7/, 'and so does the wave');
    assert.match(card(p), /1111/, 'with whoever holds it');
    p.close();
  });

  test('a name minted before waves still reads', async () => {
    const p = await loadPage({ chain: fixture(), hash: 'score=10-wens.arcade.wei' });
    await p.settle();
    await p.waitFor(() => /Minted score/.test(card(p)), { label: 'the name to resolve' });
    assert.match(card(p), /Minted score 10/);
    assert.doesNotMatch(card(p), /wave/, 'it has no wave to report');
    p.close();
  });

  test('a record the holder has rewritten is called out', async () => {
    const p = await loadPage({
      chain: fixture({ record: '999999' }), hash: 'score=4820-w7-k3x9.arcade.wei' });
    await p.settle();
    await p.waitFor(() => /Minted score/.test(card(p)), { label: 'the name to resolve' });
    assert.match(card(p), /now reads 999999, not 4820/, 'the discrepancy must be shown');
    assert.ok(p.$('scEl').querySelector('.scw'), 'and marked as a warning');
    assert.match(card(p), /4,820/, 'while the label still stands as the minted score');
    p.close();
  });

  test('a name that was never minted says so', async () => {
    const chain = fixture();
    chain.scoreName = { owner: A.ZERO };
    const p = await loadPage({ chain, hash: 'score=9999-w9-zzzz.arcade.wei' });
    await p.settle();
    await p.waitFor(() => /never been minted/.test(card(p)), { label: 'the refusal' });
    p.close();
  });

  test('anything not under arcade.wei is ignored', async () => {
    for (const bad of ['vitalik.eth', 'arcade.wei', 'a.b.arcade.wei', '<script>.arcade.wei']) {
      const p = await loadPage({ chain: fixture(), hash: 'score=' + bad });
      await p.settle();
      assert.ok(p.$('scEl').classList.contains('hide'), `${bad} should not open the card`);
      p.close();
    }
  });

  test('no score in the link leaves the card shut', async () => {
    const p = await loadPage({ chain: fixture(), hash: 'token=ETH&out=USDC' });
    await p.settle();
    assert.ok(p.$('scEl').classList.contains('hide'));
    p.close();
  });
});
