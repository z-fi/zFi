/**
 * Where a name is read from, and how many times.
 *
 * Every name this page understands is rooted on Ethereum. `.wei` and `.gwei`
 * live in registries deployed only there; `.eth` lives in the ENS registry,
 * which exists at the same address on Base and Robinhood only as unrelated
 * code that answers nothing. So a name typed while connected to an L2 must be
 * resolved against a mainnet node over plain HTTP, never against the node the
 * wallet is on - and a recipient that silently resolves to the zero address,
 * or to whatever a squatted registry says, is the worst failure this page has.
 *
 * The exception is Basenames. `*.base.eth` has no record in the L1 registry at
 * all: its L1 resolver is a wildcard that answers by reverting OffchainLookup
 * at a gateway, which this page does not follow. Base's own registry holds the
 * records outright, so that is where the page reads them - on chain, on Base,
 * from whichever chain the wallet is on.
 *
 * The counting matters as much as the routing. The ENSIP-10 walk asks the
 * registry for a resolver once per label, and a two-label name connected to an
 * L2 spent that as separate HTTPS round trips against a public node that rate
 * limits. They go out as one multicall now, and these tests hold that: an
 * assertion on the number of reads is the only thing that keeps a later edit
 * from quietly unbatching them.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, SEL, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const BASE = 8453;
const RH = 4663;
const NAMED = '0x3333333333333333333333333333333333333333';

// Every mainnet RPC the page carries, plus Base's, keyed the way the harness
// routes them: a JSON-RPC POST whose URL contains the fragment.
const L1_FRAGMENTS = ['ethereum-rpc', 'blastapi'];
const BASE_FRAGMENT = 'base-rpc';

/** A mainnet MockChain that knows one .eth name and one .wei name. */
const l1Fixture = () => {
  const l1 = new MockChain({ chainId: 1 });
  l1.ensResolver = A.ENSRESOLVER;
  l1.ensNames.set('alice.eth', NAMED);
  l1.names.set('alice.wei', NAMED);
  return l1;
};

/** A Base MockChain holding a Basenames record and its primary name. */
const baseFixture = () => {
  const b = new MockChain({ chainId: BASE });
  b.ensResolver = A.ENSRESOLVER;
  b.ensNames.set('alice.base.eth', NAMED);
  return b;
};

async function openOn(chainId, { l1 = l1Fixture(), base = null } = {}) {
  const chain = new MockChain({ chainId, autoConnected: true });
  for (const f of L1_FRAGMENTS) chain.remotes[f] = l1;
  if (base) chain.remotes[BASE_FRAGMENT] = base;
  const p = await loadPage({ chain });
  await p.connect();
  p.click('tabSend');
  await p.settle();
  return { p, chain, l1, base };
}

/** Type a recipient and wait for the resolved address to land under the field. */
async function resolveRecipient(p, value) {
  p.type('rc', value);
  await new Promise(r => p.window.setTimeout(r, 320));
  await p.settle();
  return { shown: p.text('rcvEl'), status: p.text('stat') };
}

describe('a name is read from Ethereum, whatever chain the wallet is on', () => {
  for (const [label, chainId] of [['Base', BASE], ['Robinhood', RH]]) {
    test(`a .eth recipient on ${label} resolves against a mainnet node`, async () => {
      const { p, chain, l1 } = await openOn(chainId);
      const { shown } = await resolveRecipient(p, 'alice.eth');

      assert.equal(shown.toLowerCase(), NAMED, 'the name must resolve to its address');
      assert.ok(
        l1.calls.some(c => c.to.toLowerCase() === A.ENSREG.toLowerCase()
          || c.to.toLowerCase() === A.MC3.toLowerCase()),
        'the ENS registry must be asked on mainnet');
      assert.ok(
        !chain.calls.some(c => c.to.toLowerCase() === A.ENSREG.toLowerCase()),
        `the ${label} node holds no ENS registry and must not be asked`);
      p.close();
    });

    test(`a .wei recipient on ${label} resolves against a mainnet node`, async () => {
      const { p, chain, l1 } = await openOn(chainId);
      const { shown } = await resolveRecipient(p, 'alice.wei');

      assert.equal(shown.toLowerCase(), NAMED);
      assert.ok(l1.calls.some(c => c.to.toLowerCase() === A.WNS.toLowerCase()),
        'WNS must be asked on mainnet');
      assert.ok(!chain.calls.some(c => c.to.toLowerCase() === A.WNS.toLowerCase()),
        `WNS is not deployed on ${label} and must not be asked there`);
      p.close();
    });
  }

  test('an unregistered .eth name is refused rather than sent to the zero address', async () => {
    const { p } = await openOn(RH);
    const { shown, status } = await resolveRecipient(p, 'nobody.eth');
    assert.equal(shown, '', 'nothing may be shown as the recipient');
    assert.match(status, /not registered/i);
    p.close();
  });
});

describe('the registry walk is one read, not one per label', () => {
  /** Round trips the page made to a mainnet node, which is what an L2 pays for. */
  const l1Requests = chain =>
    (chain.httpLog || []).filter(e => L1_FRAGMENTS.some(f => e.url.includes(f))).length;

  test('a deep .eth name costs the same two mainnet round trips as a shallow one', async () => {
    const l1 = l1Fixture();
    l1.ensNames.set('pay.team.alice.eth', NAMED);
    const { p, chain } = await openOn(RH, { l1 });

    const before = l1Requests(chain);
    const seen = l1.calls.length;
    const { shown } = await resolveRecipient(p, 'pay.team.alice.eth');
    assert.equal(shown.toLowerCase(), NAMED);

    // One batch for the four-label walk, one at the resolver it found, which
    // asks addr() and supportsInterface(ENSIP-10) together.
    assert.equal(l1Requests(chain) - before, 2,
      'the walk must not spend a round trip per label');

    const batched = l1.calls.slice(seen).filter(c =>
      c.to.toLowerCase() === A.MC3.toLowerCase() && c.selector === SEL.AGG3);
    assert.equal(batched.length, 2, 'and multicalls carry both');
    p.close();
  });

  test('a node that cannot batch still resolves the name', async () => {
    const l1 = l1Fixture();
    // aggregate3 itself refused - the failure mode of a provider that caps
    // eth_call below what the batch needs, which must not cost a name.
    l1.batchLimit = 1;
    const { p } = await openOn(RH, { l1 });
    const { shown } = await resolveRecipient(p, 'alice.eth');
    assert.equal(shown.toLowerCase(), NAMED, 'the walk must fall back to single calls');
    p.close();
  });
});

describe('Basenames are read from Base', () => {
  test('a .base.eth recipient on Base resolves against Base itself', async () => {
    const base = baseFixture();
    const chain = new MockChain({ chainId: BASE, autoConnected: true });
    for (const f of L1_FRAGMENTS) chain.remotes[f] = l1Fixture();
    // The wallet IS Base here, so the record has to come off the connected
    // node. Give the same fixtures to the wallet's own chain.
    chain.ensResolver = A.ENSRESOLVER;
    chain.ensNames.set('alice.base.eth', NAMED);

    const p = await loadPage({ chain });
    await p.connect();
    p.click('tabSend');
    await p.settle();
    const { shown } = await resolveRecipient(p, 'alice.base.eth');

    assert.equal(shown.toLowerCase(), NAMED);
    assert.ok(chain.calls.some(c => c.to.toLowerCase() === A.BNREG.toLowerCase()),
      "Base's own registry is the one holding the record");
    void base;
    p.close();
  });

  test('a .base.eth recipient from another chain still reaches Base', async () => {
    const { p, chain, l1, base } = await openOn(RH, { base: baseFixture() });
    // The header's own reverse lookup already asked mainnet; only what the
    // recipient costs is under test here.
    const seen = l1.calls.length;
    const { shown } = await resolveRecipient(p, 'alice.base.eth');

    assert.equal(shown.toLowerCase(), NAMED, 'the name resolves from Robinhood too');
    assert.ok(base.calls.some(c => c.to.toLowerCase() === A.BNREG.toLowerCase()),
      'the read must land on Base');
    assert.ok(!l1.calls.slice(seen).some(c => c.to.toLowerCase() === A.ENSREG.toLowerCase()),
      'a Basename has no L1 registry record, so asking for one is a wasted round trip');
    assert.ok(!chain.calls.some(c => c.to.toLowerCase() === A.BNREG.toLowerCase()),
      'and Robinhood carries no Basenames registry');
    p.close();
  });

  test('an unregistered Basename is refused', async () => {
    const { p } = await openOn(RH, { base: baseFixture() });
    const { shown, status } = await resolveRecipient(p, 'nobody.base.eth');
    assert.equal(shown, '');
    assert.match(status, /not registered/i);
    p.close();
  });
});

describe('the connected account shows the name it holds', () => {
  test('on Base a Basenames primary name reaches the header', async () => {
    const chain = new MockChain({ chainId: BASE, autoConnected: true });
    for (const f of L1_FRAGMENTS) chain.remotes[f] = l1Fixture();
    chain.ensResolver = A.ENSRESOLVER;
    chain.ensNames.set('alice.base.eth', A.ACCOUNT);
    chain.ensRevNames.set(A.ACCOUNT, 'alice.base.eth');

    const p = await loadPage({ chain });
    await p.connect();
    await p.settle();
    assert.equal(p.text('addr'), 'alice.base.eth');
    p.close();
  });

  test('a reverse record that does not resolve back is not shown', async () => {
    const chain = new MockChain({ chainId: BASE, autoConnected: true });
    for (const f of L1_FRAGMENTS) chain.remotes[f] = l1Fixture();
    chain.ensResolver = A.ENSRESOLVER;
    // Claimed by the account, but forward-resolving to someone else.
    chain.ensNames.set('alice.base.eth', NAMED);
    chain.ensRevNames.set(A.ACCOUNT, 'alice.base.eth');

    const p = await loadPage({ chain });
    await p.connect();
    await p.settle();
    assert.match(p.text('addr'), /^0x/, 'an unconfirmed claim must stay an address');
    p.close();
  });

  test('a .wei primary name on an L2 comes from mainnet', async () => {
    const l1 = l1Fixture();
    l1.names.set('me.wei', A.ACCOUNT);
    l1.reverse.set(A.ACCOUNT.toLowerCase(), 'me.wei');
    const { p } = await openOn(RH, { l1 });
    assert.equal(p.text('addr'), 'me.wei');
    p.close();
  });
});
