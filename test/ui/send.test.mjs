/**
 * Send tab: recipient resolution, plain transfers, SLOW time-locks, and the
 * pending-position list.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, SEL, MockChain, loadPage, fixedRateQuoter, word, wordAddr, selectorOf, closeAllPages,
} from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;

async function setup(prep = () => {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 5_000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  prep(chain);
  const p = await loadPage({ chain });
  await p.connect();
  p.click('tabSend');
  await p.settle();
  return p;
}

/** Fill the recipient box and wait for resolution to finish. */
async function recipient(p, v) {
  p.type('rc', v);
  await new Promise(r => p.window.setTimeout(r, 320));
  await p.settle();
}

describe('send tab layout', () => {
  test('hides swap-only controls and relabels the amount panel', async () => {
    const p = await setup();
    assert.equal(p.visible('rcvPanel'), false, 'there is no output token to choose');
    assert.equal(p.visible('flip'), false);
    assert.equal(p.visible('slipL'), false, 'slippage is meaningless for a transfer');
    assert.equal(p.text('payL'), 'Amount');
    assert.equal(p.visible('dlyL'), true);
    assert.equal(p.$('tabSend').getAttribute('aria-selected'), 'true');
    assert.equal(p.$('tabSwap').getAttribute('aria-selected'), 'false');
    p.close();
  });

  test('offers a time lock rather than swap slippage', async () => {
    const p = await setup();
    assert.match(p.$('dlyL').textContent, /Time lock/);
    assert.equal(p.$('dly').options[0].textContent, 'Instant');
    p.close();
  });

  test('the button stays disabled until both amount and recipient are valid', async () => {
    const p = await setup();
    assert.equal(p.disabled('swap'), true);
    await p.typeAmount('amt', '1');
    assert.equal(p.disabled('swap'), true, 'an amount alone is not enough');
    await recipient(p, A.OTHER);
    assert.equal(p.disabled('swap'), false);
    p.close();
  });
});

describe('recipient resolution', () => {
  test('accepts a hex address and previews it', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    await recipient(p, A.OTHER);
    assert.match(p.text('swap'), /Send 1 ETH →/);
    assert.match(p.text('swap'), /0x2222…2222/, 'shows who is being paid');
    p.close();
  });

  test('resolves a .wei name and shows the address it will pay', async () => {
    const p = await setup(c => c.names.set('alice.wei', A.OTHER));
    await p.typeAmount('amt', '1');
    await recipient(p, 'alice.wei');
    assert.equal(p.text('rcvEl').toLowerCase(), A.OTHER.toLowerCase(),
      'the resolved address must be visible before signing');
    assert.match(p.text('swap'), /→ alice\.wei/);
    p.close();
  });

  test('refuses an unregistered name', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    await recipient(p, 'nobody.wei');
    assert.match(p.text('stat'), /Name not registered/);
    assert.equal(p.disabled('swap'), true);
    assert.ok(p.$('rc').classList.contains('bad'));
    p.close();
  });

  test('refuses something that is neither an address nor a supported name', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    await recipient(p, 'alice@example.com');
    assert.match(p.text('stat'), /must be an address or a \.wei/);
    assert.equal(p.disabled('swap'), true);
    p.close();
  });

  // A disabled button that just says "Send" makes you guess which of the two
  // fields is at fault. It should name the one that is missing.
  test('the dead button says which field is still empty', async () => {
    const p = await setup();
    assert.equal(p.text('swap'), 'Enter an amount');
    assert.equal(p.disabled('swap'), true);
    await p.typeAmount('amt', '1');
    assert.equal(p.text('swap'), 'Name a recipient',
      'with an amount typed, the missing piece is the recipient');
    assert.equal(p.disabled('swap'), true);
    p.close();
  });

  test('an amount over the balance is caught before signing', async () => {
    const p = await setup();
    await recipient(p, A.OTHER);
    await p.typeAmount('amt', '999');
    assert.equal(p.text('swap'), 'Insufficient balance');
    assert.equal(p.disabled('swap'), true);
    p.close();
  });

  test('a recipient edited after the preview aborts rather than paying the old one', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    await recipient(p, A.OTHER);
    // Change the field without firing input, so the resolved target goes stale
    // exactly as it would if resolution lost a race with the click.
    p.$('rc').value = '0x3333333333333333333333333333333333333333';
    p.click('swap');
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'a changed recipient must never be paid silently');
    assert.match(p.text('stat'), /recipient changed/i);
    p.close();
  });
});

describe('plain transfers', () => {
  test('an ETH send is a bare value transfer to the recipient', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1.5');
    await recipient(p, A.OTHER);
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'transfer' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.OTHER.toLowerCase(), 'straight to the recipient');
    assert.equal(BigInt(tx.value), 1500000000000000000n);
    assert.ok(!tx.data || tx.data === '0x', 'a plain ETH send carries no calldata');
    p.close();
  });

  test('an ERC-20 send calls transfer on the token, with no ether attached', async () => {
    const p = await setup();
    p.pickToken('fromSel', 'USDC');
    await p.settle();
    await p.typeAmount('amt', '250');
    await recipient(p, A.OTHER);
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'transfer' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.USDC.toLowerCase());
    assert.equal(selectorOf(tx.data), SEL.TRANSFER);
    const body = '0x' + tx.data.slice(10);
    assert.equal(wordAddr(body, 0).toLowerCase(), A.OTHER.toLowerCase());
    assert.equal(word(body, 1), 250n * USDC, 'amount is in token units, not wei');
    assert.equal(tx.value, '0x0');
    p.close();
  });

  test('the Max button reserves less gas for a transfer than for a swap', async () => {
    const p = await setup();
    p.click(p.$('bal').querySelector('a'));
    await p.settle();
    const sendMax = Number(p.value('amt'));

    p.click('tabSwap');
    await p.settle();
    p.click(p.$('bal').querySelector('a'));
    await p.settle();
    const swapMax = Number(p.value('amt'));

    assert.ok(sendMax > swapMax,
      `a plain send costs less gas than a swap, so it can spend more (${sendMax} vs ${swapMax})`);
    assert.ok(sendMax < 10, 'but it still cannot spend the entire balance');
    p.close();
  });
});

describe('time-locked sends', () => {
  test('an ETH lock deposits into SLOW with the delay and the value', async () => {
    const p = await setup();
    await p.typeAmount('amt', '2');
    await recipient(p, A.OTHER);
    p.select('dly', '86400');
    await p.settle();
    assert.match(p.text('swap'), /Lock 2 ETH for 1d/);

    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'deposit' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.SLOW.toLowerCase());
    assert.equal(selectorOf(tx.data), SEL.DEPOSITTO);
    const body = '0x' + tx.data.slice(10);
    assert.equal(wordAddr(body, 0), A.ZERO, 'native deposits name the zero token');
    assert.equal(wordAddr(body, 1).toLowerCase(), A.OTHER.toLowerCase());
    assert.equal(word(body, 2), 0n, 'the amount rides as msg.value, not as an argument');
    assert.equal(word(body, 3), 86400n, 'the chosen delay');
    assert.equal(BigInt(tx.value), 2n * ETH);
    p.close();
  });

  test('an ERC-20 lock approves SLOW first, then deposits the amount', async () => {
    const p = await setup();
    p.pickToken('fromSel', 'USDC');
    await p.settle();
    await p.typeAmount('amt', '100');
    await recipient(p, A.OTHER);
    p.select('dly', '3600');
    await p.settle();

    p.click('swap');
    await p.waitFor(() => p.chain.sent.length >= 2, { label: 'approve + deposit' });
    await p.settle();

    const [approve, deposit] = p.chain.sent;
    assert.equal(approve.to.toLowerCase(), A.USDC.toLowerCase());
    assert.equal(selectorOf(approve.data), SEL.APPROVE);
    assert.equal(wordAddr('0x' + approve.data.slice(10), 0).toLowerCase(), A.SLOW.toLowerCase(),
      'the escrow, not the router, is the spender here');

    assert.equal(deposit.to.toLowerCase(), A.SLOW.toLowerCase());
    const body = '0x' + deposit.data.slice(10);
    assert.equal(wordAddr(body, 0).toLowerCase(), A.USDC.toLowerCase());
    assert.equal(word(body, 2), 100n * USDC, 'an ERC-20 amount is an argument');
    assert.equal(word(body, 3), 3600n);
    assert.equal(deposit.value, '0x0');
    p.close();
  });

  test('the delay choice survives leaving and returning to the tab', async () => {
    const p = await setup();
    p.select('dly', '604800');
    await p.settle();
    p.click('tabSwap');
    await p.settle();
    p.click('tabSend');
    await p.settle();
    assert.equal(p.value('dly'), '604800', 'a chosen lock must not silently reset to Instant');
    p.close();
  });
});

/**
 * A time lock does not release itself: somebody has to send the claim once it
 * matures. The tip is what buys that somebody, so what matters is that it is
 * quoted from live gas, paid in ether whatever is being sent, and given back
 * when the transfer is reversed instead of claimed.
 */
describe('keeper tip', () => {
  // 1 gwei (the harness default) x the page's 180k claim budget.
  const TIP = 180_000n * 10n ** 9n;

  /** A tipped ETH lock, ready to submit. */
  async function tipped(p, amount = '2', delay = '86400') {
    await p.typeAmount('amt', amount);
    await recipient(p, A.OTHER);
    p.select('dly', delay);
    await p.settle();
    p.click('tipCk');
    await p.settle();
  }

  test('the tip is only offered once there is a lock to claim', async () => {
    const p = await setup();
    assert.equal(p.visible('tipL'), false, 'an instant send needs nobody to claim it');
    p.select('dly', '86400');
    await p.settle();
    assert.equal(p.visible('tipL'), true);
    p.select('dly', '0');
    await p.settle();
    assert.equal(p.visible('tipL'), false);
    p.close();
  });

  test('ticking auto-claim quotes the tip from live gas', async () => {
    const p = await setup();
    p.select('dly', '86400');
    await p.settle();
    assert.equal(p.text('tipNote'), '', 'an unticked box costs nothing and says nothing');
    p.click('tipCk');
    await p.settle();
    assert.match(p.text('tipNote'), /tip ≈ 0\.00018 ETH/,
      'the quote must name the cost before it is signed');
    p.close();
  });

  test('an ETH lock pays the tip alongside the amount in one value', async () => {
    const p = await setup();
    await tipped(p);
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'tipped deposit' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.SLOW.toLowerCase());
    assert.equal(selectorOf(tx.data), SEL.DEPOSITTIP);
    const body = '0x' + tx.data.slice(10);
    assert.equal(wordAddr(body, 1).toLowerCase(), A.OTHER.toLowerCase());
    assert.equal(word(body, 2), 2n * ETH,
      'unlike depositTo, the tipped path splits msg.value and must be told the amount');
    assert.equal(word(body, 3), 86400n, 'the delay is unchanged by tipping');
    assert.equal(word(body, 4), TIP, 'the tip is an argument, not only value');
    assert.equal(BigInt(tx.value), 2n * ETH + TIP,
      'ether transfers carry amount and tip in the same msg.value');
    p.close();
  });

  test('an ERC-20 lock sends the tip as the whole value', async () => {
    const p = await setup();
    p.pickToken('fromSel', 'USDC');
    await p.settle();
    await tipped(p, '100', '3600');
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length >= 2, { label: 'approve + tipped deposit' });
    await p.settle();

    const deposit = p.chain.lastSent;
    assert.equal(selectorOf(deposit.data), SEL.DEPOSITTIP);
    const body = '0x' + deposit.data.slice(10);
    assert.equal(word(body, 2), 100n * USDC);
    assert.equal(word(body, 4), TIP);
    assert.equal(BigInt(deposit.value), TIP,
      'the tip is ether even when the transfer is not');
    p.close();
  });

  test('a tip that no longer fits the balance is caught before signing', async () => {
    const p = await setup();
    await p.typeAmount('amt', '10');   // the entire ETH balance
    await recipient(p, A.OTHER);
    p.select('dly', '86400');
    await p.settle();
    assert.equal(p.disabled('swap'), false, 'without a tip the whole balance is sendable');
    p.click('tipCk');
    await p.settle();
    assert.match(p.text('swap'), /Insufficient ETH for amount \+ keeper tip/);
    assert.equal(p.disabled('swap'), true);
    assert.equal(p.chain.sent.length, 0);
    p.close();
  });

  test('reversing a tipped transfer reclaims the tip from the gate', async () => {
    const now = Math.floor(Date.now() / 1000);
    const p = await setup(c => {
      c.slowOut = [2n];
      c.slowPending.set('2', {
        timestamp: BigInt(now), id: BigInt(A.ZERO) | (86400n << 160n), amount: ETH,
      });
      c.slowTips.set('2', TIP);
    });
    await p.waitFor(() => p.$('pos').textContent.includes('Reversible'), { label: 'positions' });
    p.click([...p.$('pos').querySelectorAll('button')].find(b => b.textContent === 'Reverse'));
    await p.waitFor(() => p.chain.sent.length >= 2, { label: 'reverse + refund' });
    await p.settle();

    const refund = p.chain.lastSent;
    assert.equal(refund.to.toLowerCase(), A.SLOW_GATE.toLowerCase(),
      'the tip is held by the gate, not by SLOW');
    assert.equal(selectorOf(refund.data), SEL.REFUNDTIP);
    assert.equal(word('0x' + refund.data.slice(10), 0), 2n);
    p.close();
  });

  test('reversing an untipped transfer asks for no second signature', async () => {
    const now = Math.floor(Date.now() / 1000);
    const p = await setup(c => {
      c.slowOut = [2n];
      c.slowPending.set('2', {
        timestamp: BigInt(now), id: BigInt(A.ZERO) | (86400n << 160n), amount: ETH,
      });
    });
    await p.waitFor(() => p.$('pos').textContent.includes('Reversible'), { label: 'positions' });
    p.click([...p.$('pos').querySelectorAll('button')].find(b => b.textContent === 'Reverse'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'reverse' });
    await p.settle();
    assert.equal(p.chain.sent.length, 1, 'there is no tip to give back');
    p.close();
  });
});

describe('pending positions', () => {
  /** One incoming position, matured or not, plus one outgoing reversible one. */
  function withPositions(chain, { ready = true } = {}) {
    const now = Math.floor(Date.now() / 1000);
    const delay = 86400n;
    const idIn = BigInt(A.USDC) | (delay << 160n);
    const idOut = BigInt(A.ZERO) | (delay << 160n);
    chain.slowIn = [1n];
    chain.slowOut = [2n];
    chain.slowPending.set('1', {
      timestamp: BigInt(ready ? now - 90000 : now), id: idIn, amount: 500n * USDC,
    });
    chain.slowPending.set('2', {
      timestamp: BigInt(now), id: idOut, amount: ETH,
    });
  }

  test('a matured incoming position can be claimed', async () => {
    const p = await setup(c => withPositions(c));
    await p.waitFor(() => p.$('pos').textContent.includes('500'), { label: 'positions' });

    const claim = [...p.$('pos').querySelectorAll('button')].find(b => b.textContent === 'Claim');
    assert.ok(claim, 'a matured incoming position must offer a claim');
    p.click(claim);
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'claim tx' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.SLOW.toLowerCase());
    assert.equal(selectorOf(tx.data), SEL.CLAIM);
    assert.equal(word('0x' + tx.data.slice(10), 0), 1n, 'claims the right position');
    p.close();
  });

  test('an unmatured outgoing position reverses and withdraws in one transaction', async () => {
    const p = await setup(c => withPositions(c));
    await p.waitFor(() => p.$('pos').textContent.includes('Reversible'), { label: 'positions' });

    const rev = [...p.$('pos').querySelectorAll('button')].find(b => b.textContent === 'Reverse');
    assert.ok(rev, 'a pending outgoing position must be reversible');
    p.click(rev);
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'reverse tx' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.SLOW.toLowerCase());
    // reverse() only credits an internal balance, so it MUST be paired with a
    // withdraw or the funds sit in the escrow and the user sees nothing back.
    assert.equal(selectorOf(tx.data), SEL.MULTICALL, 'reverse alone would strand the funds');
    assert.match(tx.data, new RegExp(SEL.REVERSE));
    assert.match(tx.data, new RegExp(SEL.WITHDRAWFROM));
    p.close();
  });

  test('the tab badge counts only what is claimable now', async () => {
    const ready = await setup(c => withPositions(c, { ready: true }));
    await ready.waitFor(() => /Send \(1\)/.test(ready.text('tabSend')), { label: 'ready badge' });
    ready.close();

    const pending = await setup(c => withPositions(c, { ready: false }));
    await pending.settle();
    assert.equal(pending.text('tabSend'), 'Send',
      'a position that is still locked must not advertise itself as claimable');
    pending.close();
  });

  test('an unmatured incoming position shows its countdown instead of a claim', async () => {
    const p = await setup(c => withPositions(c, { ready: false }));
    await p.waitFor(() => p.$('pos').textContent.includes('500'), { label: 'positions' });
    assert.match(p.$('pos').textContent, /Arrives in/);
    const claim = [...p.$('pos').querySelectorAll('button')].find(b => b.textContent === 'Claim');
    assert.equal(claim, undefined, 'nothing to claim before it matures');
    p.close();
  });
});

/**
 * SLOW does not let a transfer go stale in the escrow forever, and it does not
 * treat a guarded account like an unguarded one. Both rules are the contract's,
 * not the page's — a page that ignores either builds calldata that reverts, or
 * leaves the user's ether where they cannot reach it.
 */
describe('recovery paths', () => {
  const DAY = 86400n;
  const GRACE = 2592000;

  /** One outgoing position, matured `agedSecs` ago. */
  function outgoing(chain, agedSecs) {
    const now = Math.floor(Date.now() / 1000);
    chain.slowOut = [2n];
    chain.slowPending.set('2', {
      timestamp: BigInt(now - agedSecs) - DAY, id: BigInt(A.ZERO) | (DAY << 160n), amount: ETH,
    });
  }
  const btn = (p, label) =>
    [...p.$('pos').querySelectorAll('button')].find(b => b.textContent === label);

  test('a matured transfer the recipient abandoned is clawed back after the grace', async () => {
    const p = await setup(c => outgoing(c, GRACE + 60));
    await p.waitFor(() => p.$('pos').textContent.includes('past grace'), { label: 'positions' });

    const b = btn(p, 'Clawback');
    assert.ok(b, 'past the grace the escrow is the sender\'s to take back');
    p.click(b);
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'clawback tx' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.SLOW.toLowerCase());
    assert.equal(selectorOf(tx.data), SEL.MULTICALL, 'clawback alone would strand the funds');
    assert.match(tx.data, new RegExp(SEL.CLAWBACK));
    assert.match(tx.data, new RegExp(SEL.WITHDRAWFROM));
    p.close();
  });

  test('within the grace the transfer is still the recipient\'s', async () => {
    const p = await setup(c => outgoing(c, 60));
    await p.waitFor(() => p.$('pos').textContent.includes('Matured'), { label: 'positions' });
    assert.equal(btn(p, 'Clawback'), undefined, 'the grace belongs to the recipient');
    assert.equal(btn(p, 'Reverse'), undefined, 'reverse is over once the lock expires');
    p.close();
  });

  test('a guarded recipient unlocks rather than claims', async () => {
    const now = Math.floor(Date.now() / 1000);
    const p = await setup(c => {
      c.slowGuardian = A.SLOW_GATE;
      c.slowIn = [1n];
      c.slowPending.set('1', {
        timestamp: BigInt(now) - 2n * DAY, id: BigInt(A.USDC) | (DAY << 160n), amount: 500n * USDC,
      });
    });
    await p.waitFor(() => p.$('pos').textContent.includes('500'), { label: 'positions' });

    const b = btn(p, 'Unlock');
    assert.ok(b, 'claim reverts for a guarded account — the page must say what it will do');
    p.click(b);
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'unlock tx' });
    await p.settle();
    assert.equal(selectorOf(p.chain.lastSent.data), SEL.UNLOCK);
    p.close();
  });

  test('a guarded sender reverses without the withdraw it cannot make', async () => {
    const p = await setup(c => { c.slowGuardian = A.SLOW_GATE; outgoing(c, -3600); });
    await p.waitFor(() => p.$('pos').textContent.includes('Reversible'), { label: 'positions' });
    p.click(btn(p, 'Reverse'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'reverse tx' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(selectorOf(tx.data), SEL.REVERSE,
      'withdrawFrom needs the guardian to co-sign, so bundling it reverts the reverse too');
    p.close();
  });

  test('a tip nobody spent is offered back once the transfer has settled', async () => {
    const p = await setup(c => {
      c.slowOut = [2n];          // settled: pendingTransfers reads back zero
      c.slowTips.set('2', 10n ** 15n);
    });
    await p.waitFor(() => p.$('pos').textContent.includes('Keeper tip'), { label: 'stale tip' });
    p.click(btn(p, 'Reclaim tip'));
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'refund tx' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.SLOW_GATE.toLowerCase());
    assert.equal(selectorOf(tx.data), SEL.REFUNDTIP);
    assert.equal(word('0x' + tx.data.slice(10), 0), 2n);
    p.close();
  });
});

/**
 * SLOW is one address on Ethereum, Base and Robinhood — the same bytecode at
 * 0x000000006513B7821171C8447ec7ECdfa3b956Fd on all three — so the lock is not
 * a mainnet feature the other two chains fall back out of. What does not travel
 * is the keeper: the tip gate is deployed everywhere, but only mainnet has a
 * bot watching it, and a tip nobody will ever claim is worse than no tip.
 */
describe('SLOW on the other chains', () => {
  const BASE = '0x2105', RH = '0x1237';

  async function onChain(hex, prep = () => {}) {
    const chain = new MockChain({ chainId: hex });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    prep(chain);
    const p = await loadPage({ chain, hash: null });
    await p.connect({ pin: false });
    p.click('tabSend');
    await p.settle();
    return p;
  }

  for (const [name, hex, id] of [['Base', BASE, 8453], ['Robinhood', RH, 4663]]) {
    test(`${name} offers the same lock, at the same address`, async () => {
      const p = await onChain(hex);
      assert.equal(p.window.eval('CHAIN_ID'), id);
      assert.equal(p.visible('dlyL'), true, 'the delay is offered off mainnet');

      await p.typeAmount('amt', '2');
      await recipient(p, A.OTHER);
      p.select('dly', '86400');
      await p.settle();
      p.click('swap');
      await p.waitFor(() => p.chain.sent.length > 0, { label: 'deposit' });
      await p.settle();

      const tx = p.chain.lastSent;
      assert.equal(tx.to.toLowerCase(), A.SLOW.toLowerCase(), 'one SLOW, every chain');
      assert.equal(selectorOf(tx.data), SEL.DEPOSITTO);
      assert.equal(word('0x' + tx.data.slice(10), 3), 86400n);
      assert.equal(BigInt(tx.value), 2n * ETH);
      p.close();
    });

    test(`${name} does not sell a keeper tip nobody is running`, async () => {
      const p = await onChain(hex);
      p.select('dly', '86400');
      await p.settle();
      assert.equal(p.visible('tipL'), false, 'no keeper watches this chain, so nothing is offered');
      p.close();
    });

    // The other half of the round trip. A position made here is settled here,
    // and the page must reach it through SLOW itself — the bridged rows use a
    // different contract, and routing an ordinary one that way would revert.
    test(`${name} claims a matured position through SLOW itself`, async () => {
      const now = Math.floor(Date.now() / 1000);
      const p = await onChain(hex, c => {
        c.slowIn = [4n];
        c.slowPending.set('4', {
          timestamp: BigInt(now) - 2n * 86400n,
          id: BigInt(A.ZERO) | (86400n << 160n), amount: ETH,
        });
      });
      await p.waitFor(() => p.$('pos').textContent.includes('Ready to claim'), { label: 'positions' });
      const b = [...p.$('pos').querySelectorAll('button')].find(x => x.textContent === 'Claim');
      assert.ok(b, `a matured position is claimable on ${name}`);
      p.click(b);
      await p.waitFor(() => p.chain.sent.length > 0, { label: 'claim tx' });
      await p.settle();
      assert.equal(p.chain.lastSent.to.toLowerCase(), A.SLOW.toLowerCase());
      assert.equal(selectorOf(p.chain.lastSent.data), SEL.CLAIM);
      p.close();
    });

    test(`${name} reverses an ordinary lock through SLOW, not through the bridge`, async () => {
      const now = Math.floor(Date.now() / 1000);
      const p = await onChain(hex, c => {
        c.slowOut = [5n];
        c.slowPending.set('5', {
          timestamp: BigInt(now), id: BigInt(A.ZERO) | (86400n << 160n), amount: ETH,
        });
      });
      await p.waitFor(() => p.$('pos').textContent.includes('Reversible'), { label: 'positions' });
      assert.equal(p.$('pos').textContent.includes('Bridged in'), false,
        'a lock made here was not bridged, and must not be labelled as if it were');
      const b = [...p.$('pos').querySelectorAll('button')].find(x => x.textContent === 'Reverse');
      p.click(b);
      await p.waitFor(() => p.chain.sent.length > 0, { label: 'reverse tx' });
      await p.settle();
      assert.equal(p.chain.lastSent.to.toLowerCase(), A.SLOW.toLowerCase(),
        'SlowArrival would refuse it — this account is pt.from, so SLOW hears it directly');
      assert.equal(selectorOf(p.chain.lastSent.data), SEL.MULTICALL);
      p.close();
    });
  }

  test('mainnet still offers the tip', async () => {
    const p = await setup();
    p.select('dly', '86400');
    await p.settle();
    assert.equal(p.visible('tipL'), true);
    p.close();
  });
});

/**
 * The panel is a shortcut, not the whole contract: guardians, per-token
 * balances and the transfer history live on SLOW's own page, which SLOW serves
 * from its own bytes. The link hands that page what has already been typed
 * here rather than making it be typed twice.
 */
describe('the link out to SLOW\'s own page', () => {
  test('is a send-tab affordance only', async () => {
    const p = await setup();
    assert.equal(p.visible('slowMoreL'), true);
    p.click('tabSwap');
    await p.settle();
    assert.equal(p.visible('slowMoreL'), false, 'there is nothing to hand over from a swap');
    p.close();
  });

  test('carries the chain, asset, amount, recipient and delay across', async () => {
    const p = await setup();
    p.pickToken('fromSel', 'USDC');
    await p.settle();
    await p.typeAmount('amt', '100');
    await recipient(p, A.OTHER);
    p.select('dly', '259200');
    await p.settle();

    const href = p.$('slowMore').href;
    const [base, route] = href.split('#');
    assert.equal(base, `https://${p.window.eval('SLOW_PAGE')}.w4eth.io/`,
      'the page is read off chain through the gateway, not off a server');
    const q = new URLSearchParams(route.replace('/pay?', ''));
    assert.equal(q.get('chain'), '1');
    assert.equal(q.get('asset').toLowerCase(), A.USDC.toLowerCase());
    assert.equal(q.get('amount'), '100');
    assert.equal(q.get('to').toLowerCase(), A.OTHER.toLowerCase());
    assert.equal(q.get('delay'), '259200');
    p.close();
  });

  test('names the chain the page is actually on', async () => {
    const chain = new MockChain({ chainId: '0x1237' });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain, hash: null });
    await p.connect({ pin: false });
    p.click('tabSend');
    await p.settle();
    assert.match(p.$('slowMore').href, /chain=4663/);
    p.close();
  });

  test('keeps the gateway it was itself served from', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({
      chain, hash: null,
      url: 'https://0x000000bd2db80567c23e353ca95a251c573cbf9b.1.w3link.io/',
    });
    await p.connect({ pin: false });
    p.click('tabSend');
    await p.settle();
    assert.match(p.$('slowMore').href,
      new RegExp(`^https://${p.window.eval('SLOW_PAGE')}\\.1\\.w3link\\.io/`),
      'an onchain-served page swaps the address and keeps the gateway that served it');
    p.close();
  });
});

/**
 * SLOW's reverts reach the user through the page's REVERTS table, and the ones
 * the send tab can actually provoke are worth naming.
 *
 * The 1155 receiver check is the one worth being precise about, because it is
 * easy to overstate. A locked transfer mints an ERC-1155 position, so the
 * recipient's code has to answer `onERC1155Received` - and real wallets do.
 * A 7702-delegated EOA is FINE: checked against a live delegate on mainnet,
 * which returns the magic value and takes the deposit. What fails is an
 * address whose code implements no hook at all, which in practice means a
 * contract that was never meant to hold tokens. The page previews the deposit
 * with an eth_call before asking for a signature, so this costs nothing but a
 * message - and an undecoded `0x9c05499b` reads like the page is broken
 * rather than like the recipient cannot hold the position.
 */
describe('what SLOW says when it refuses', () => {
  const cases = [
    ['9c05499b', /does not accept ERC-1155/i],
    ['49378211', /already settled/i],
    ['621e25c3', /has not run out/i],
    ['7a6fcaa6', /already ran out/i],
    ['c6734163', /guardian/i],
    ['2d193ecf', /guardian/i],
    ['c9252135', /grace period/i],
  ];

  test('every one is decoded rather than shown as a selector', async () => {
    const p = await setup();
    for (const [sel, want] of cases) {
      const msg = p.window.eval(`explain({data:"0x${sel}"})`);
      assert.match(msg, want, `0x${sel} should be explained, got: ${msg}`);
      assert.doesNotMatch(msg, /0x[0-9a-f]{8}/i, `0x${sel} leaked the raw selector: ${msg}`);
    }
    p.close();
  });

  test('a deposit the recipient cannot hold is refused before it is signed', async () => {
    const p = await setup();
    await p.typeAmount('amt', '2');
    await recipient(p, A.OTHER);
    p.select('dly', '86400');
    await p.settle();

    // The page previews with eth_call first; make that preview revert the way
    // SLOW does when the recipient's code implements no ERC-1155 hook.
    p.chain.revertOn(A.SLOW, SEL.DEPOSITTO, 'execution reverted: 0x9c05499b');

    p.click('swap');
    await p.waitFor(() => /does not accept ERC-1155/i.test(p.text('stat')) || p.chain.sent.length > 0,
      { label: 'the refusal' });
    assert.equal(p.chain.sent.length, 0, 'nothing was signed');
    assert.match(p.text('stat'), /does not accept ERC-1155/i);
    p.close();
  });
});
