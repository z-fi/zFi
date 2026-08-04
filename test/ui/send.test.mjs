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
