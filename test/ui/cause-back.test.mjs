/**
 * Backing a cause, and watching one age.
 *
 * Backing and burning are the same relationship seen from either end, so they
 * share one line: ether in and the cause's token out, or the trade run
 * backwards. There is no market on either side, which is the point — every
 * number here comes from the sale and the treasury, never from a venue.
 *
 * The two things worth pinning:
 *
 *   - THE COST IS ROUNDED THE WAY THE CONTRACT ROUNDS IT. ShareOffering
 *     computes `(amount * price + 1e18 - 1) / 1e18` and reverts on a short
 *     payment, so a page that rounds down underpays by a wei on every amount
 *     that does not divide evenly and the buy simply fails.
 *
 *   - "RELEASED" IS MEASURED AGAINST WHAT WAS RAISED, NOT AGAINST THE GOAL.
 *     The goal never reaches the chain — it only ever existed on the launch
 *     form. The honest denominator is what backers actually paid, and the
 *     numerator is the part of it the tap has already drawn out. Measuring
 *     against a goal the chain cannot see would be a number nobody could check.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPage, MockChain, A } from './harness.mjs';

const DAO = '0x00000000000000000000000000000000cafe0001';
const LOOT = '0x00000000000000000000000000000000cafe0002';
const SHARES = '0x00000000000000000000000000000000cafe0003';
const OFFERING = '0x000000a4ad929c9e108ad2b1d2fbede0c2ae57e1';
const SEL_BUY = 'cce7ec13';

const ONE = 10n ** 18n;
const PRICE = 10n ** 12n; // a 10 ETH goal over ten million units

/**
 * A cause that raised 4 ETH of a 10 ETH goal and has had 0.4 of it drawn by
 * the tap — so it is 10% released, and a burn pays back less than was paid in.
 */
function causeChain(over = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n ** 19n);
  chain.setToken(LOOT, { symbol: 'DUCK', decimals: 18, name: 'Feed Ducks Loot' });
  chain.setCause(LOOT, {
    dao: DAO,
    shares: SHARES,
    sharesSupply: ONE,
    lootSupply: over.lootSupply ?? 4_000_000n * ONE,
    treasury: over.treasury ?? 3_600_000_000_000_000_000n,
    price: over.price ?? PRICE,
    deadline: over.deadline ?? BigInt(Math.floor(Date.now() / 1000) + 22 * 86400),
    remaining: over.remaining ?? 5_999_999n * ONE,
    // A 10 ETH budget over a year, last released a day ago.
    saleToken: over.saleToken,
    salePayToken: over.salePayToken,
    ratePerSec: over.ratePerSec ?? (10n * ONE) / 31556952n,
    lastClaim: over.lastClaim ?? BigInt(Math.floor(Date.now() / 1000) - 86400),
    tapBudget: over.tapBudget ?? 10n * ONE,
  });
  return chain;
}

const remembers = { 'zswap:custom': JSON.stringify([{ sym: 'DUCK', addr: LOOT, dec: 18, std: 'ft' }]) };

/** ETH in, cause out — the backing direction. */
async function openBacking(chain) {
  const p = await loadPage({ chain, storage: remembers });
  await p.connect();
  p.pickToken('fromSel', 'ETH');
  p.pickToken('toSel', 'DUCK');
  await p.settle();
  return p;
}

test('backing a cause', async (t) => {
  await t.test('offers a rate and a deadline before any amount is typed', async () => {
    const p = await openBacking(causeChain());
    const line = p.text('cbEl');
    assert.ok(p.visible('cbEl'), 'no backing line');
    // 1e12 wei a unit means one ether backs a million of them.
    assert.match(line, /1 ETH backs 1000000 DUCK/);
    assert.match(line, /22 days left/);
  });

  await t.test('reports what the tap has drawn, measured against what was raised', async () => {
    const p = await openBacking(causeChain());
    // 4,000,000 units sold at 1e12 = 4 ETH raised; 3.6 ETH is still there.
    assert.match(p.text('cbEl'), /10% released/);
  });

  await t.test('shows nothing released before the tap has taken anything', async () => {
    const p = await openBacking(causeChain({ treasury: 4n * ONE }));
    assert.doesNotMatch(p.text('cbEl'), /% released/);
  });

  await t.test('quotes the units an amount buys, and offers to back', async () => {
    const p = await openBacking(causeChain());
    p.type('amt', '1');
    await p.waitFor(() => /Back with/.test(p.text('cbEl')), { label: 'the backing quote' });
    assert.match(p.text('cbEl'), /Back with 1 ETH for 1000000 DUCK/);
    assert.ok(p.$('cbGo'), 'no Back button');
  });

  await t.test('buys from the offering, paying the cost the contract will compute', async () => {
    const p = await openBacking(causeChain());
    p.type('amt', '1');
    await p.waitFor(() => !!p.$('cbGo'), { label: 'the Back button' });
    p.click('cbGo');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'the backing transaction' });

    const tx = p.chain.sent.at(-1);
    assert.equal(tx.to.toLowerCase(), OFFERING, 'backing must go through ShareOffering');
    assert.equal(tx.data.slice(2, 10), SEL_BUY);
    const word = (i) => BigInt('0x' + tx.data.slice(10 + i * 64, 10 + (i + 1) * 64));
    assert.equal('0x' + tx.data.slice(34, 74), DAO, 'buy is keyed by the DAO');
    assert.equal(word(1), 1_000_000n * ONE, 'bought the wrong number of units');
    // (1,000,000e18 * 1e12 + 1e18 - 1) / 1e18 == 1 ETH exactly here, and the
    // page must never send less than this or ShareOffering reverts.
    assert.equal(BigInt(tx.value), ONE, 'paid the wrong cost');
  });

  await t.test('never underpays on an amount that does not divide evenly', async () => {
    const p = await openBacking(causeChain({ price: 3n * 10n ** 12n }));
    p.type('amt', '1');
    await p.waitFor(() => !!p.$('cbGo'), { label: 'the Back button' });
    p.click('cbGo');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'the backing transaction' });

    const tx = p.chain.sent.at(-1);
    const units = BigInt('0x' + tx.data.slice(74, 138));
    const owed = (units * 3n * 10n ** 12n + ONE - 1n) / ONE;
    assert.ok(BigInt(tx.value) >= owed, `sent ${tx.value}, contract wants ${owed}`);
    assert.ok(BigInt(tx.value) <= ONE, 'spent more than was typed');
  });

  await t.test('caps a backing at what is actually left to sell', async () => {
    const p = await openBacking(causeChain({ remaining: 500_000n * ONE }));
    p.type('amt', '5');
    await p.waitFor(() => /Back with/.test(p.text('cbEl')), { label: 'the backing quote' });
    assert.match(p.text('cbEl'), /for 500000 DUCK/);
    // Paying five ether for half a million units would be a gift, not a backing.
    assert.match(p.text('cbEl'), /Back with 0\.5 ETH/);
  });

  await t.test('says so when backing has closed, and offers no button', async () => {
    const past = BigInt(Math.floor(Date.now() / 1000) - 86400);
    const p = await openBacking(causeChain({ deadline: past }));
    assert.match(p.text('cbEl'), /Backing for DUCK has closed/);
    assert.ok(!p.$('cbGo'), 'offered to back a sale that has ended');
    // The claim outlives the sale: the line still reports what has been drawn.
    assert.match(p.text('cbEl'), /10% released/);
  });

  await t.test('shows how full the raise is, as a fraction of the ceiling', async () => {
    const p = await openBacking(causeChain());
    // 4,000,000 sold of a 9,999,999 ceiling at 1e12 a unit: 4 ETH of ~10.
    assert.match(p.text('cbEl'), /4 of 9\.999999 ETH backed/);
    const bar = p.$('cbEl').querySelector('.lqbar');
    assert.ok(bar, 'no progress bar');
    // Progress is sold over the ceiling — it needs no price and cannot be
    // flattered by one.
    const at = parseFloat(bar.style.getPropertyValue('--at'));
    assert.ok(Math.abs(at - 40) < 0.2, `bar sits at ${at}%, expected ~40%`);
  });

  await t.test('files a cause under its own heading, not among tradable tokens', async () => {
    const p = await openBacking(causeChain());
    const opt = [...p.$('toSel').options].find(o => o.textContent === 'DUCK');
    assert.equal(opt.parentElement.tagName, 'OPTGROUP',
      'a cause was listed among the ordinary tokens');
    assert.match(opt.parentElement.label, /Causes/);
  });

  await t.test('asks for ether rather than failing on a token it cannot spend', async () => {
    // ShareOffering.buy credits msg.sender, so a router-mediated zap would
    // leave the backing at the router. Until that is a 5792 batch, the page
    // has to say what to switch instead of quietly offering a broken button.
    const chain = causeChain();
    chain.setErc20(A.USDC, A.ACCOUNT, 1000n * 10n ** 6n);
    const p = await loadPage({ chain, storage: remembers });
    await p.connect();
    p.pickToken('toSel', 'DUCK');
    p.pickToken('fromSel', 'USDC');
    await p.settle();
    assert.match(p.text('cbEl'), /switch the top token to ETH/);
    assert.ok(!p.$('cbGo'), 'offered to back with a token the sale cannot take');
  });

  await t.test('shows what the tap will pay, and lets anyone release it', async () => {
    const p = await openBacking(causeChain());
    // TapVest floors to whole seconds: floor(min(owed, allowance, balance)/rate)*rate.
    const rate = (10n * ONE) / 31556952n;
    const owed = (rate * 86400n) / rate * rate;
    assert.match(p.text('cbEl'), /ETH vested and unreleased/);
    assert.ok(p.$('cbRel'), 'no Release button');

    p.click('cbRel');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'the release transaction' });
    const tx = p.chain.sent.at(-1);
    assert.equal(tx.to.toLowerCase(), '0x0000000060cdd33cbe020fae696e70e7507bf56d',
      'release must go to TapVest');
    assert.equal(tx.data.slice(2, 10), '1e83409a', 'claim(dao)');
    assert.equal('0x' + tx.data.slice(34, 74), DAO, 'released the wrong cause');
    assert.equal(BigInt(tx.value ?? '0x0'), 0n, 'a release should carry no ether');
    assert.ok(owed > 0n, 'fixture should have something vested');
  });

  await t.test('never promises more than the tap can actually pay', async () => {
    // The treasury is the binding constraint here, not the elapsed time: a year
    // of accrual against 3.6 ETH cannot pay out ten.
    const p = await openBacking(causeChain({
      lastClaim: BigInt(Math.floor(Date.now() / 1000) - 31556952),
    }));
    const m = p.text('cbEl').match(/([\d.]+) ETH vested and unreleased/);
    assert.ok(m, 'no vested line');
    assert.ok(parseFloat(m[1]) <= 3.6, `promised ${m[1]} ETH against a 3.6 ETH treasury`);
  });

  await t.test('says nothing about a tap with nothing vested', async () => {
    const p = await openBacking(causeChain({ ratePerSec: 0n }));
    assert.doesNotMatch(p.text('cbEl'), /vested/);
    assert.ok(!p.$('cbRel'), 'offered a release with nothing to release');
  });

  await t.test('refuses to price a sale that mints something other than this token',
    async () => {
      /* sales() names the mint sentinel first. A DAO is free to run a sale that
         mints SHARES; quoting it off price and deadline alone would take the
         backer's ether and hand them a token the sale never mints. */
      const p = await openBacking(causeChain({ saleToken: DAO }));
      assert.doesNotMatch(p.text('cbEl'), /Back with/);
      assert.doesNotMatch(p.text('cbEl'), /1 ETH backs/);
      assert.ok(!p.$('cbGo'), 'offered to back a sale that does not mint this token');
    });

  await t.test('refuses to spend ether on a sale priced in an ERC20', async () => {
    // payToken is the second word. A non-zero one means buy() reverts on any
    // msg.value at all — UnexpectedETH — so the button could never have worked.
    const p = await openBacking(causeChain({ salePayToken: A.USDC }));
    assert.doesNotMatch(p.text('cbEl'), /Back with/);
    assert.ok(!p.$('cbGo'), 'offered to pay ether into an ERC20-priced sale');
  });

  await t.test('still prices the burn when the sale is one it cannot use', async () => {
    // The claim on the treasury is independent of how the sale was configured.
    const chain = causeChain({ saleToken: DAO });
    chain.setErc20(LOOT, A.ACCOUNT, 1_000_000n * ONE);
    const p = await loadPage({ chain, storage: remembers });
    await p.connect();
    p.pickToken('fromSel', 'DUCK');
    await p.settle();
    assert.match(p.text('cbEl'), /Burn .* DUCK for .* ETH/);
  });

  await t.test('leaves an ordinary pair alone', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n ** 19n);
    const p = await loadPage({ chain });
    await p.connect();
    await p.settle();
    assert.ok(!p.visible('cbEl'), 'a backing line appeared on a plain swap');
  });
});
