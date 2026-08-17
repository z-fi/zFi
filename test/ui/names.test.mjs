/**
 * Ethereum name resolution: the ENSIP-10 wildcard walk, forward-verified reverse
 * records, and the return-shape guard that stands between a name service and the
 * zero address.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, MockChain, loadPage, fixedRateQuoter, ensNamehash, closeAllPages,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;

async function setup(prep = () => {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  prep(chain);
  const p = await loadPage({ chain });
  await p.connect();
  p.click('tabSend');
  await p.settle();
  return p;
}

async function recipient(p, v) {
  p.type('rc', v);
  await new Promise(r => p.window.setTimeout(r, 320));
  await p.settle();
}

/** Point the exact node at the resolver — the ordinary, non-wildcard case. */
function exactName(chain, name, addr) {
  chain.ensResolvers.set(ensNamehash(name), A.ENSRESOLVER);
  chain.ensNames.set(name, addr);
}

/** Point only the PARENT at the resolver, so the name is reachable via ENSIP-10. */
function wildcardName(chain, parent, name, addr) {
  chain.ensResolvers.set(ensNamehash(parent), A.ENSRESOLVER);
  chain.ensWildcard = true;
  chain.ensNames.set(name, addr);
}

describe('ENS forward resolution', () => {
  test('resolves a name whose own node holds the resolver', async () => {
    const p = await setup(c => exactName(c, 'alice.eth', A.OTHER));
    await p.typeAmount('amt', '1');
    await recipient(p, 'alice.eth');
    assert.equal(p.text('rcvEl').toLowerCase(), A.OTHER.toLowerCase());
    p.close();
  });

  test('resolves a subname through its parent wildcard resolver', async () => {
    // The exact node has NO resolver. Before the ENSIP-10 walk this read as
    // "not registered", which is how every subname-shaped name failed.
    const p = await setup(c => wildcardName(c, 'uni.eth', 'bob.uni.eth', A.OTHER));
    await p.typeAmount('amt', '1');
    await recipient(p, 'bob.uni.eth');
    assert.equal(p.text('rcvEl').toLowerCase(), A.OTHER.toLowerCase(),
      'the parent resolver must be asked through resolve(name,data)');
    p.close();
  });

  test('refuses to treat a non-ENSIP-10 ancestor as a wildcard', async () => {
    // The `eth` node really does carry a resolver on mainnet, and it does NOT
    // support resolve(). Without the supportsInterface gate every unregistered
    // .eth name would be put to it as a wildcard query.
    const p = await setup(c => {
      c.ensResolvers.set(ensNamehash('eth'), A.ENSRESOLVER);
      c.ensWildcard = false;
      c.ensNames.set('nobody.eth', A.OTHER);   // reachable only via the ancestor
    });
    await p.typeAmount('amt', '1');
    await recipient(p, 'nobody.eth');
    assert.match(p.text('stat'), /Name not registered/);
    assert.equal(p.disabled('swap'), true);
    p.close();
  });

  test('says so when the records live off chain rather than calling the name unregistered', async () => {
    const p = await setup(c => {
      wildcardName(c, 'cb.eth', 'x.cb.eth', A.OTHER);
      c.ensOffchain = true;
    });
    await p.typeAmount('amt', '1');
    await recipient(p, 'x.cb.eth');
    assert.match(p.text('stat'), /off chain/i,
      'an OffchainLookup revert is a real name this page cannot read, not a missing one');
    p.close();
  });

  test('refuses a name it cannot hash faithfully instead of guessing', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    await recipient(p, 'vitaliké.eth');
    assert.match(p.text('stat'), /cannot resolve/i,
      'no UTS-46 here, so an unspellable name must say that rather than "not registered"');
    p.close();
  });
});

describe('reverse resolution', () => {
  test('shows a reverse name only when the forward record agrees', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.ensResolvers.set(ensNamehash(
      A.ACCOUNT.replace(/^0x/, '').toLowerCase() + '.addr.reverse'), A.ENSRESOLVER);
    chain.ensRevNames.set(A.ACCOUNT, 'alice.eth');
    exactName(chain, 'alice.eth', A.ACCOUNT);
    const p = await loadPage({ chain });
    await p.connect();
    await p.waitFor(() => p.text('addr') === 'alice.eth', { label: 'verified reverse name' });
    p.close();
  });

  test('ignores a reverse record whose forward record points elsewhere', async () => {
    // Anyone may point a reverse record at any name. Only the forward record
    // settles it, so an unbacked claim must never reach the header.
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.ensResolvers.set(ensNamehash(
      A.ACCOUNT.replace(/^0x/, '').toLowerCase() + '.addr.reverse'), A.ENSRESOLVER);
    chain.ensRevNames.set(A.ACCOUNT, 'vitalik.eth');
    exactName(chain, 'vitalik.eth', A.OTHER);   // forward disagrees
    const p = await loadPage({ chain });
    await p.connect();
    await new Promise(r => setTimeout(r, 200));
    await p.settle();
    assert.notEqual(p.text('addr'), 'vitalik.eth',
      'an unverified reverse record is a claim, not a name');
    assert.match(p.text('addr'), /^0x/, 'it should fall back to the hex address');
    p.close();
  });

  test('a WNS reverse record still has to agree forward', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.reverse.set(A.ACCOUNT.toLowerCase(), 'alice.wei');
    chain.names.set('alice.wei', A.OTHER);      // points at someone else
    const p = await loadPage({ chain });
    await p.connect();
    await new Promise(r => setTimeout(r, 200));
    await p.settle();
    assert.match(p.text('addr'), /^0x/, 'WNS gets no exemption from the forward check');
    p.close();
  });
});
