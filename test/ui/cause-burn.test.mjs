/**
 * Burning cause loot back for its share of the treasury.
 *
 * A cause raised through the DAICO launcher sells `loot`: an ERC20 that is a
 * claim on a DAO's ether rather than a position in a market. Nothing pools it,
 * so every other price the page can show is absent by construction — the burn
 * line is the only number, and it therefore has to be right rather than merely
 * present.
 *
 * Two things are checked here that a DOM assertion alone would miss:
 *
 *   - IDENTIFICATION. A token is cause loot only when the DAO it names names
 *     it back. Accepting a token on its own DAO() getter would let any
 *     contract with that method be priced against a treasury it has no claim
 *     on, and the number shown would be somebody else's ether.
 *
 *   - THE CALLDATA. ragequit takes its token list as a dynamic array AFTER two
 *     static words, so the head carries an offset the page has to compute
 *     rather than the array itself. Getting that wrong sends a transaction
 *     that either reverts or burns loot for nothing, and it is invisible to
 *     any test that only reads the rendered line.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPage, MockChain, A } from './harness.mjs';

const DAO = '0x00000000000000000000000000000000cafe0001';
const LOOT = '0x00000000000000000000000000000000cafe0002';
const SHARES = '0x00000000000000000000000000000000cafe0003';
const SEL_RAGEQUIT = '29f64d1a';

const ONE = 10n ** 18n;

/**
 * A cause holding 4 ETH, against 1 share and 9,999,999 loot. Those are the
 * launcher's own numbers: the founder's single share is minted at deploy and
 * the rest of the 10,000,000 is what backers bought.
 */
function causeChain(over = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n ** 19n);
  chain.setToken(LOOT, { symbol: 'CAUSE', decimals: 18, name: 'Clean Water Loot' });
  chain.setCause(LOOT, {
    dao: DAO,
    shares: SHARES,
    sharesSupply: over.sharesSupply ?? ONE,
    lootSupply: over.lootSupply ?? 9_999_999n * ONE,
    treasury: over.treasury ?? 4n * ONE,
    // A live sale at 1e12 wei a unit — a 10 ETH goal over ten million units.
    price: over.price ?? 10n ** 12n,
    deadline: over.deadline ?? BigInt(Math.floor(Date.now() / 1000) + 22 * 86400),
    remaining: over.remaining ?? 5_000_000n * ONE,
  });
  chain.setErc20(LOOT, A.ACCOUNT, over.balance ?? 1_000_000n * ONE);
  return chain;
}

/**
 * The loot token arrives the way a real one does: remembered in the page's own
 * custom-token store, because a cause token is not on any curated list and
 * never will be. Seeding it there rather than reaching into the page's arrays
 * means the selection path under test is the one a user actually walks.
 */
const remembers = (addr, sym) => ({
  'zswap:custom': JSON.stringify([{ sym, addr: addr.toLowerCase(), dec: 18, std: 'ft' }]),
});

async function openWith(chain, { addr = LOOT, sym = 'CAUSE' } = {}) {
  const p = await loadPage({ chain, storage: remembers(addr, sym) });
  await p.connect();
  p.pickToken('fromSel', sym);
  await p.settle();
  return p;
}

test('burning cause loot', async (t) => {
  await t.test('prices the burn against the treasury, not against a market', async () => {
    const p = await openWith(causeChain());
    const line = p.$('cbEl');
    assert.ok(!line.classList.contains('hide'), 'no burn line for a cause token');
    // 4 ETH * 1,000,000 / 10,000,000 = 0.4 ETH. The founder's one share counts
    // toward the denominator, which is what makes the split honest.
    assert.match(line.textContent, /Burn 1,?000,?000 CAUSE for 0\.4 ETH/);
  });

  await t.test('quotes the amount typed, not just the balance', async () => {
    const p = await openWith(causeChain());
    p.type('amt', '2000000');
    // The line rides the page's debounced update, so it has to be waited for
    // rather than read straight after the keystroke.
    await p.waitFor(() => /2000000/.test(p.$('cbEl').textContent), { label: 'burn line to requote' });
    assert.match(p.$('cbEl').textContent, /Burn 2,?000,?000 CAUSE for 0\.8 ETH/);
  });

  await t.test('says nothing about an ordinary token', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n ** 19n);
    chain.setErc20(A.USDC, A.ACCOUNT, 1000n * 10n ** 6n);
    const p = await loadPage({ chain });
    await p.connect();
    await p.settle();
    assert.ok(p.$('cbEl').classList.contains('hide'), 'burn line shown for a plain token');
  });

  await t.test('refuses a token whose DAO does not name it back', async () => {
    // The DAO answers loot() with a DIFFERENT address. This is the whole
    // reason the check runs both ways: a token can claim any DAO it likes, and
    // only the DAO's own answer settles whether the claim is real.
    const chain = causeChain();
    const other = '0x00000000000000000000000000000000cafe0009';
    chain.setToken(other, { symbol: 'FAKE', decimals: 18, name: 'Not A Cause' });
    chain.setErc20(other, A.ACCOUNT, 1000n * ONE);
    // Registered against the same DAO, which still names CAUSE as its loot.
    chain.causes.set(other.toLowerCase(), chain.causes.get(LOOT.toLowerCase()));
    const p = await openWith(chain, { addr: other, sym: 'FAKE' });
    assert.ok(p.$('cbEl').classList.contains('hide'),
      'priced a burn against a treasury the token has no claim on');
  });

  await t.test('sends ragequit with the token array laid out after the two counts', async () => {
    const p = await openWith(causeChain());
    p.type('amt', '1000000');
    await p.waitFor(() => /1000000/.test(p.$('cbEl').textContent), { label: 'burn line to quote' });
    p.$('cbGo').click();
    await p.settle();

    const sent = p.chain.sent.at(-1);
    assert.ok(sent, 'no transaction sent');
    assert.equal(sent.to.toLowerCase(), DAO, 'burn went somewhere other than the DAO');
    assert.equal(BigInt(sent.value ?? '0x0'), 0n, 'a burn should carry no ether');

    const data = sent.data;
    assert.equal(data.slice(2, 10), SEL_RAGEQUIT);
    const word = (i) => BigInt('0x' + data.slice(10 + i * 64, 10 + (i + 1) * 64));
    assert.equal(word(0), 96n, 'token array offset must clear the three head words');
    assert.equal(word(1), 0n, 'a backer holds no shares to burn');
    assert.equal(word(2), 1_000_000n * ONE, 'burned the wrong amount of loot');
    assert.equal(word(3), 1n, 'the token array should hold exactly one entry');
    assert.equal(word(4), 0n, 'the claimed token should be ether, the zero address');
  });
});
