/**
 * Swap tab: quoting, display, the funding waterfall, and the exact transaction
 * handed to the wallet.
 *
 * Run: node --test test/ui/
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  A, SEL, MockChain, loadPage, fixedRateQuoter, cpammQuoter, domainSeparator,
  assertAddressesMatchPage, word, wordAddr, selectorOf, closeAllPages, encodeSingleHop,
} from './harness.mjs';

// A failed assertion skips the test's own close(); without this the page's
// intervals keep the run alive and the failure never prints.
after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const RATE = 3000n * ETH; // 1 ETH = 3000 USDC

/** A connected wallet holding 10 ETH and 50k USDC, quoting at a flat 3000. */
async function setup(over = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: RATE });
  Object.assign(chain, over.chain || {});
  const page = await loadPage({ chain, ...over.page });
  if (over.connect !== false) await page.connect();
  return page;
}

const decodeMulticall = data => {
  // multicall(bytes[]) — return the inner call payloads
  assert.equal(selectorOf(data), SEL.MULTICALL, 'expected a multicall');
  const body = '0x' + data.replace(/^0x/, '').slice(8);
  const n = Number(word(body, 1));
  const out = [];
  for (let i = 0; i < n; i++) {
    const off = Number(word(body, 2 + i)) / 32;
    const at = 2 + off;
    const len = Number(word(body, at));
    const start = (at + 1) * 64;
    out.push('0x' + body.replace(/^0x/, '').slice(start, start + len * 2));
  }
  return out;
};

describe('fixtures', () => {
  test('harness addresses match the ones the page hardcodes', () => {
    assertAddressesMatchPage(assert);
  });
});

describe('connection', () => {
  test('the disconnected label is an invitation, and clicking it connects', async () => {
    // It used to read "Not connected" and do nothing when clicked - a status
    // nobody can act on, which also no longer fitted the row beside seven
    // controls. Now it says what the click does, and the click does it.
    const p = await setup({ connect: false });
    assert.equal(p.text('addr'), 'Connect');
    p.click('addr');
    await p.settle();
    assert.notEqual(p.text('addr'), 'Connect', 'clicking the label did not connect');
    p.close();
  });

  test('the disconnected label is reachable by keyboard', async () => {
    // The Enter/Space branch was unreachable: role and tabIndex were set only
    // once a wallet existed, so the label was not focusable in the one state
    // where it now has something to do.
    const p = await setup({ connect: false });
    const el = p.$('addr');
    assert.equal(el.getAttribute('role'), 'button', 'not announced as a control');
    assert.equal(el.tabIndex, 0, 'not focusable while disconnected');
    el.dispatchEvent(new p.window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    await p.settle();
    assert.notEqual(p.text('addr'), 'Connect', 'Enter on the label did not connect');
    p.close();
  });

  test('starts disconnected and offers to connect', async () => {
    const p = await setup({ connect: false });
    assert.equal(p.text('addr'), 'Connect');
    assert.equal(p.text('swap'), 'Connect Wallet');
    assert.equal(p.disabled('swap'), false, 'connect must always be clickable');
    p.close();
  });

  test('connecting shows the account and its balance', async () => {
    const p = await setup();
    assert.equal(p.text('addr'), '0x1111...1111');
    assert.match(p.text('bal'), /Balance: 10\b/);
    p.close();
  });

  test('prefers a reverse-resolved name over the hex address', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, ETH);
    chain.reverse.set(A.ACCOUNT.toLowerCase(), 'alice.wei');
    // The forward record has to agree before the name is shown — a reverse
    // record alone is a claim anyone can make about any name.
    chain.names.set('alice.wei', A.ACCOUNT);
    chain.quoteHandler = fixedRateQuoter({ rate: RATE });
    const p = await loadPage({ chain });
    await p.connect();
    await p.waitFor(() => p.text('addr') === 'alice.wei', { label: 'reverse name' });
    p.close();
  });

  test('refuses to operate off mainnet and asks the wallet to switch', async () => {
    const chain = new MockChain({ chainId: '0xa' });
    chain.setNative(A.ACCOUNT, ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: RATE });
    const p = await loadPage({ chain });
    p.click('swap');
    await p.settle();
    assert.ok(chain.log.some(r => r.method === 'wallet_switchEthereumChain'),
      'must request a chain switch rather than quoting on the wrong chain');
    p.close();
  });

  test('a rejected connection leaves no error shouting at the user', async () => {
    const p = await setup({ connect: false });
    p.chain.rejectNext = Object.assign(Error('User rejected the request'), { code: 4001 });
    p.click('swap');
    await p.settle();
    assert.equal(p.text('stat'), '', 'a deliberate rejection is not an error state');
    assert.equal(p.text('addr'), 'Connect');
    p.close();
  });

  test('a wallet account or chain change reloads rather than mixing state', async () => {
    const p = await setup();
    p.emit('accountsChanged', [A.OTHER]);
    assert.equal(p.reloads(), 1, 'accountsChanged must reload');
    p.emit('chainChanged', '0xa');
    assert.equal(p.reloads(), 2, 'chainChanged must reload');
    p.close();
  });
});

describe('quoting', () => {
  test('exact-in shows output, rate, source and the slippage floor', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000');
    const rate = p.text('rate');
    assert.match(rate, /1 ETH ≈ 3,000 USDC/);
    // \s, not a literal space: the venue and its fee tier are joined with a
    // non-breaking space so a narrow card cannot split "UniV3" from "0.3%".
    assert.match(rate, /UniV3\s0\.3%/, 'names the venue and its fee tier');
    // default slippage is 0.5%, so the floor is 3000 * 0.995
    assert.match(rate, /Min 2985 USDC/);
    p.close();
  });

  /**
   * The split builders are asked at a WIDENED bound — clamp(slip * 3, 1.5%, 5%)
   * — because two legs on the same pair move each other's price and the user's
   * own setting would mostly just make the call revert. But the winner is then
   * chosen on expected output alone, so a split that beats a direct route by a
   * wei replaces a 0.5% worst case with a 1.5% one. The Min was always the
   * honest widened figure; nothing said the setting had been overridden.
   */
  const u = v => BigInt(v).toString(16).padStart(64, '0');
  const encodeSplitReturn = ({ legs, msgValue = 0n, callData = '0x' }) => {
    // (Quote[2] legs, bytes multicall, uint256 msgValue): 8 static leg words,
    // then the bytes offset, then msgValue — the shape decQ reads with v = 8.
    let head = '';
    for (let i = 0; i < 2; i++) {
      const l = legs[i] || { source: 0, feeBps: 0n, amountIn: 0n, amountOut: 0n };
      head += u(l.source) + u(l.feeBps || 0n) + u(l.amountIn) + u(l.amountOut);
    }
    head += u(320) + u(msgValue);
    const d = callData.replace(/^0x/, '');
    return '0x' + head + u(d.length / 2) + d.padEnd(Math.ceil(d.length / 64) * 64, '0');
  };

  test('a split route says the slippage bound was widened past the setting', async () => {
    const direct = fixedRateQuoter({ rate: RATE });
    const p = await setup({ chain: { quoteHandler: req => {
      if (req.selector !== SEL.SPLIT_A) return direct(req);   // SPLIT_B reverts
      const body = '0x' + req.data.replace(/^0x/, '').slice(8);
      const amountIn = word(body, 3);
      if (amountIn === 0n) return null;
      // 1% better than the direct route, so the split wins on output alone.
      const out = (amountIn * RATE / 10n ** 18n) / 10n ** 12n * 101n / 100n;
      return encodeSplitReturn({
        legs: [
          { source: 3, feeBps: 30n, amountIn: amountIn / 2n, amountOut: out / 2n },
          { source: 0, feeBps: 30n, amountIn: amountIn - amountIn / 2n, amountOut: out - out / 2n },
        ],
        msgValue: amountIn,
        callData: '0x' + SEL.MULTICALL + u(32) + u(0),
      });
    } } });
    await p.typeAmount('amt', '1');

    assert.match(p.text('rate'), /Split — bound widened to 1\.5%/,
      'the user set 0.5%; the executed route bounds at 1.5%');
    // 3030 USDC quoted, floored at the bound that will actually be enforced.
    assert.match(p.text('rate'), /Min 2984\.55 USDC/, 'and the Min is that same widened figure');
    p.close();
  });

  test('a direct route never claims a widened bound', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    assert.ok(!/widened/.test(p.text('rate')));
    p.close();
  });

  test('exact-out drives the input field and shows a rounded-up maximum', async () => {
    const p = await setup();
    await p.typeAmount('outAmt', '3000');
    assert.equal(p.value('amt'), '1');
    const rate = p.text('rate');
    assert.match(rate, /Max 1\.005 ETH/, 'exact-out bounds the input, not the output');
    assert.match(p.$('rate').title, /^Exact maximum: /,
      'the displayed max is rounded up, so the exact figure stays available');
    p.close();
  });

  // Curve's `exchange` is exact-in only. An exact-out route through it is built
  // from `get_dx(want)`, and `get_dx` does not invert `get_dy` - it rounds down,
  // so the pool delivers just under `want` and zRouter refuses with Slippage().
  // Measured on the live USDC/BOLD pool, and reverting at every size and even at
  // a 90% bound, because the bound caps the INPUT. Eight of the fifty-six
  // ordered pairs quoted confidently and then reverted; the page must not offer
  // them. Exact-IN through Curve is unaffected and must still route.
  test('refuses an exact-out route that runs through Curve', async () => {
    const p = await setup({ chain: { quoteHandler: fixedRateQuoter({ rate: RATE, source: 5 }) } });
    await p.typeAmount('outAmt', '3000');
    assert.equal(p.value('amt'), '', 'no input figure, because there is no route to quote');
    assert.ok(!/Curve/.test(p.text('rate')), 'and it is not offered on the rate line');
    assert.equal(p.$('swap').disabled, true, 'the button cannot be pressed into a revert');
    // "No route" would be false here: the pair trades fine, just not in this
    // direction, and exact-IN is one keystroke away. The page cannot switch
    // venues itself - the builders each return their own finished choice - so
    // the least it can do is name the way out.
    assert.match(p.text('stat'), /exact-output is unavailable/i, 'it says what is wrong');
    assert.match(p.text('stat'), /amount to PAY/i, 'and what to do instead');
    p.close();
  });

  test('still routes exact-IN through Curve, which works', async () => {
    const p = await setup({ chain: { quoteHandler: fixedRateQuoter({ rate: RATE, source: 5 }) } });
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'exact-in is unaffected by the exact-out guard');
    assert.match(p.text('rate'), /Curve/, 'and still names the venue');
    p.close();
  });

  test('the displayed maximum never rounds below what the calldata can spend', async () => {
    const p = await setup();
    await p.typeAmount('outAmt', '3000');
    const shown = p.text('rate').match(/Max ([\d.]+) ETH/)[1];
    const exact = p.$('rate').title.match(/Exact maximum: ([\d.]+) ETH/)[1];
    assert.ok(Number(shown) >= Number(exact),
      `displayed max ${shown} must not understate the spendable ${exact}`);
    p.close();
  });

  test('slippage changes the floor', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    assert.match(p.text('rate'), /Min 2985 USDC/);
    p.type('slip', '5');
    await new Promise(r => p.window.setTimeout(r, 320));
    await p.settle();
    await p.waitFor(() => /Min 2850 USDC/.test(p.text('rate')), { label: '5% floor' });
    p.close();
  });

  test('an unroutable pair reports no route and disables the button', async () => {
    const p = await setup();
    p.chain.quoteHandler = () => null;
    await p.typeAmount('amt', '1');
    assert.match(p.text('stat'), /No route/);
    assert.equal(p.disabled('swap'), true);
    p.close();
  });

  test('an amount above the balance is refused before any signing', async () => {
    const p = await setup();
    await p.typeAmount('amt', '999');
    assert.equal(p.text('swap'), 'Insufficient balance');
    assert.equal(p.disabled('swap'), true);
    assert.equal(p.chain.sent.length, 0);
    p.close();
  });

  test('rejects an amount with more decimals than the token has', async () => {
    const p = await setup();
    p.chain.setErc20(A.USDT, A.ACCOUNT, 1000n * USDC);
    p.pickToken('fromSel', 'USDT');   // 6 decimals, and not the output token
    await p.settle();
    await p.typeAmount('amt', '1.1234567');
    assert.match(p.text('stat'), /USDT has 6 decimals/);
    assert.equal(p.disabled('swap'), true);
    p.close();
  });

  test('selecting the same token on both sides is prevented in the options', async () => {
    const p = await setup();
    const from = [...p.$('fromSel').options].find(o => o.textContent === 'USDC');
    assert.equal(from.disabled, true, 'the other side\'s token must not be selectable');
    p.close();
  });

  test('all quotes in one update resolve against a single pinned block', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    const quoteBlocks = new Set(
      p.chain.calls.filter(c => c.selector === SEL.AGG3).map(c => c.block));
    assert.equal(quoteBlocks.size, 1, 'routes must be compared at one chain state');
    assert.equal([...quoteBlocks][0], p.chain.blockNumber);
    p.close();
  });
});

describe('token controls', () => {
  test('flip swaps the pair and carries the quoted amount over', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000');
    p.click('flip');
    await p.settle();
    assert.equal(p.$('fromSel').selectedOptions[0].textContent, 'USDC');
    assert.equal(p.$('toSel').selectedOptions[0].textContent, 'ETH');
    assert.equal(p.value('amt'), '3000', 'the amount you were receiving becomes what you pay');
    p.close();
  });

  test('Max leaves a gas reserve for ETH but spends an ERC-20 in full', async () => {
    const p = await setup();
    p.click(p.$('bal').querySelector('a'));
    await p.settle();
    const eth = Number(p.value('amt'));
    assert.ok(eth > 9.9 && eth < 10, `ETH max ${eth} must reserve gas but stay close to balance`);

    p.click('flip');                  // ETH->USDC becomes USDC->ETH
    await p.settle();
    p.click(p.$('bal').querySelector('a'));
    await p.settle();
    assert.equal(p.value('amt'), '50000', 'an ERC-20 has no gas cost, so Max is the whole balance');
    p.close();
  });

  test('balance refreshes when the pay token changes', async () => {
    const p = await setup();
    assert.match(p.text('bal'), /Balance: 10\b/);
    p.chain.setErc20(A.WBTC, A.ACCOUNT, 250_000_000n); // 2.5 WBTC, 8 decimals
    p.pickToken('fromSel', 'WBTC');
    await p.waitFor(() => /Balance: 2\.5\b/.test(p.text('bal')), { label: 'WBTC balance' });
    p.close();
  });
});

describe('WETH <-> ETH', () => {
  test('WETH to ETH unwraps directly instead of routing through a pool', async () => {
    const p = await setup();
    p.chain.setErc20(A.WETH, A.ACCOUNT, 5n * ETH);
    p.pickToken('fromSel', 'WETH');
    await p.settle();
    p.pickToken('toSel', 'ETH');
    await p.settle();
    await p.typeAmount('amt', '2');

    assert.equal(p.value('outAmt'), '2', 'unwrapping is 1:1');
    assert.match(p.text('rate'), /1 WETH = 1 ETH/);

    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'unwrap tx' });
    await p.settle();
    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.WETH.toLowerCase(), 'goes straight to WETH');
    assert.equal(selectorOf(tx.data), SEL.WETH_WITHDRAW, 'calls withdraw(uint256)');
    assert.equal(word('0x' + tx.data.slice(10), 0), 2n * ETH);
    assert.equal(tx.value, '0x0');
    // No approval: withdraw burns the caller's own balance.
    assert.equal(p.chain.sent.filter(t => selectorOf(t.data || '0x') === SEL.APPROVE).length, 0);
    p.close();
  });

  /**
   * `swap.onclick` re-derives the value it expects to send and refuses to sign
   * if the quote disagrees: `from.addr===ZERO ? (isIn ? amountIn : limit) : 0`.
   * The 1:1 shortcuts build `last` by hand and carried neither field, so on the
   * wrap leg `wantsValue` read `undefined` and every wrap threw `bad value`
   * before anything reached the wallet. The unwrap leg only survived because
   * WETH-in takes the `: 0` arm and never looks at `isIn` at all.
   */
  test('ETH to WETH wraps directly and passes the value guard', async () => {
    const p = await setup();
    p.pickToken('fromSel', 'ETH');
    await p.settle();
    p.pickToken('toSel', 'WETH');
    await p.settle();
    await p.typeAmount('amt', '2');

    assert.equal(p.value('outAmt'), '2', 'wrapping is 1:1');
    assert.match(p.text('rate'), /1 ETH = 1 WETH/);

    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'wrap tx' });
    await p.settle();
    assert.ok(!/bad value/.test(p.text('stat')), `value guard rejected the wrap: ${p.text('stat')}`);
    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.WETH.toLowerCase(), 'goes straight to WETH');
    assert.equal(selectorOf(tx.data), SEL.WETH_DEPOSIT, 'calls deposit()');
    assert.equal(BigInt(tx.value), 2n * ETH, 'the ETH rides along as value');
    p.close();
  });

  /**
   * The 1:1 shortcut is gated on there being no recipient, so naming one sends
   * the pair to zQuoter — which answers with source 7, WETH_WRAP. The page's
   * SOURCES table is zQuoter's AMM enum verbatim for 0-7, but 7 had been
   * overwritten with "Precision", a venue zQuoter does not know about. A plain
   * wrap was therefore announced as a Precision pool, which is also the one
   * label that makes the page go ask the Precision factory to vouch for a pool
   * that does not exist.
   */
  test('a wrap routed through the quoter is named a wrap, not a Precision pool', async () => {
    const p = await setup({
      chain: { quoteHandler: fixedRateQuoter({ rate: ETH, decIn: 18, decOut: 18, source: 7, feeBps: 0n }) },
    });
    p.pickToken('fromSel', 'ETH');
    await p.settle();
    p.pickToken('toSel', 'WETH');
    await p.settle();
    p.type('rc', A.OTHER);
    await p.typeAmount('amt', '1');

    assert.match(p.text('rate'), /Wrap/, 'source 7 is WETH_WRAP');
    assert.ok(!/Precision/.test(p.text('rate')), 'and Precision is not a zQuoter venue');
    p.close();
  });
});

/**
 * Routing through a hub when the on-chain hub builder cannot be called.
 *
 * Measured against the deployed quoter: buildBestSwapViaETHMulticall needs
 * ~160M gas for ETH->USDC and build3HopMulticall over 200M, because each one
 * walks six hubs x two legs x every venue inside a single eth_call. The usual
 * RPC cap is 50M — geth's default — so on most providers those calls simply
 * never answer, and the page was left with direct pools only. For wstETH->USDT
 * that meant quoting a dust pool at 18.88 USDT against the 23,328 a hub route
 * pays; for USDC->WBTC it meant no route at all.
 *
 * buildBestSwap is the same per-leg selection at ~5M, so the page runs the hub
 * loop itself: one call per hub for leg 1, one per surviving hub for leg 2,
 * then the winner assembled into the two-leg plan zQuoter would have built.
 */
describe('hub routing without the on-chain hub builder', () => {
  const HUB_RATE = 4n;   // 1 tokenIn -> 4 hub -> 16 tokenOut, so a hub beats nothing
  function cappedRpc() {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
    // A provider that refuses the 160M builders and answers the 5M one.
    chain.quoteHandler = ({ selector, data }) => {
      if (selector !== SEL.QUOTE_ONE) return null;          // hub builders "out of gas"
      const body = '0x' + data.replace(/^0x/, '').slice(8);
      const amountIn = word(body, 4);
      if (!amountIn) return null;
      const amountOut = amountIn * HUB_RATE;
      return encodeSingleHop({
        amountIn, amountOut,
        amountLimit: amountOut * 9950n / 10000n,
        msgValue: wordAddr(body, 2) === A.ZERO ? amountIn : 0n,
        callData: '0x' + SEL.MULTICALL + '00'.repeat(28),
      });
    };
    return chain;
  }

  test('finds a two-leg hub route and hands the wallet one multicall', async () => {
    const p = await loadPage({ chain: cappedRpc() });
    await p.connect();
    await p.typeAmount('amt', '1');

    assert.notEqual(p.value('outAmt'), '', 'a routed pair must still quote');
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.ZROUTER.toLowerCase(), 'the plan runs on the router');
    const calls = decodeMulticall(tx.data);
    assert.equal(calls.length, 4, 'leg 1, leg 2, hub sweep, ether sweep');
    // The sweeps are what stop leg 1 overshoot being left in a router whose
    // sweep() is public. Both must return to the payer, not the recipient.
    const sweeps = calls.filter(c => selectorOf(c) === SEL.SWEEP);
    assert.equal(sweeps.length, 2, 'both leftovers are swept');
    for (const s of sweeps) {
      const args = '0x' + s.slice(10);
      assert.equal(word(args, 2), 0n, 'amount 0 = whatever is actually left');
      assert.equal(wordAddr(args, 3).toLowerCase(), A.ACCOUNT.toLowerCase(), 'back to the payer');
    }
    p.close();
  });

  test('does not run the hub loop when the on-chain builder answered', async () => {
    // On a provider that can run them, the builders are better informed and the
    // client-side loop is pure waste — it must not fire at all.
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
    const base = fixedRateQuoter({ rate: RATE });
    let oneHopCalls = 0;
    chain.quoteHandler = req => {
      if (req.selector === SEL.QUOTE_ONE) { oneHopCalls++; return null; }
      return base(req);
    };
    const p = await loadPage({ chain });
    await p.connect();
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'the on-chain builder still wins');
    assert.ok(oneHopCalls <= 2, `hub loop must stay dormant, saw ${oneHopCalls} single-hop calls`);
    p.close();
  });
});

describe('transaction payload', () => {
  test('an ETH swap sends exactly the quoted value to the router', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    await p.settle();

    const tx = p.chain.lastSent;
    assert.equal(tx.to.toLowerCase(), A.ZROUTER.toLowerCase());
    assert.equal(BigInt(tx.value), ETH, 'msg.value must equal the input, to the wei');
    assert.equal(tx.from.toLowerCase(), A.ACCOUNT.toLowerCase());
    p.close();
  });

  test('the page pre-flights the swap with eth_call before asking to sign', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    const before = p.chain.calls.filter(c => c.to === A.ZROUTER.toLowerCase()).length;
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    await p.settle();
    const after = p.chain.calls.filter(c => c.to === A.ZROUTER.toLowerCase()).length;
    assert.ok(after > before, 'a simulated call must precede the signature request');
    const callIdx = p.chain.log.findIndex(r =>
      r.method === 'eth_call' && (r.params[0].to || '').toLowerCase() === A.ZROUTER.toLowerCase());
    const sendIdx = p.chain.log.findIndex(r => r.method === 'eth_sendTransaction');
    assert.ok(callIdx < sendIdx, 'simulation must come first');
    p.close();
  });

  test('reports the transaction hash and then confirmation', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    p.click('swap');
    await p.waitFor(() => /Done/.test(p.text('stat')), { label: 'settlement' });
    assert.match(p.$('stat').innerHTML, /etherscan\.io\/tx\/0x/, 'links the transaction');
    p.close();
  });

  test('a stale quote refuses to send and re-quotes instead', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    // Age the quote past its 45s TTL exactly as the clock would.
    p.window.eval('last.exp = Date.now() - 1');
    p.click('swap');
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'an expired quote must never be sent');
    assert.match(p.text('stat'), /expired/i);
    p.close();
  });

  test('a user rejection at signing leaves the button usable', async () => {
    const p = await setup();
    await p.typeAmount('amt', '1');
    p.chain.rejectNext = Object.assign(Error('User denied transaction signature'), { code: 4001 });
    p.click('swap');
    await p.settle();
    await p.waitFor(() => !p.disabled('swap'), { label: 're-enabled button' });
    assert.equal(p.text('stat'), '', 'a rejection is not an error message');
    p.close();
  });
});

describe('ERC-20 funding waterfall', () => {
  /** USDC in, ETH out, with the wallet already holding a big USDC balance. */
  async function erc20Swap(prep = () => {}) {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
    chain.quoteHandler = fixedRateQuoter({ rate: ETH / 3000n, decIn: 6, decOut: 18 });
    prep(chain);
    const p = await loadPage({ chain });
    await p.connect();
    p.click('flip');                  // the default pair is ETH->USDC
    await p.settle();
    await p.typeAmount('amt', '3000');
    return p;
  }

  test('an existing allowance skips approval entirely', async () => {
    const p = await erc20Swap(c => c.setAllowance(A.USDC, A.ACCOUNT, A.ZROUTER, 10n ** 30n));
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    await p.settle();
    assert.equal(p.chain.sent.length, 1, 'no approval transaction should be needed');
    assert.equal(p.chain.lastSent.to.toLowerCase(), A.ZROUTER.toLowerCase());
    assert.equal(p.chain.lastSent.value, '0x0', 'an ERC-20 swap sends no ether');
    p.close();
  });

  test('prefers a gasless EIP-2612 permit and bundles it with the swap', async () => {
    const p = await erc20Swap(c => c.setToken(A.USDC, {
      symbol: 'USDC', decimals: 6, name: 'USD Coin',
      domainSeparator: domainSeparator('USD Coin', '1', A.USDC),
    }));
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    await p.settle();

    assert.equal(p.chain.signed.length, 1, 'exactly one signature');
    assert.equal(p.chain.signed[0].typedData.primaryType, 'Permit');
    assert.equal(p.chain.signed[0].typedData.message.spender.toLowerCase(),
      A.ZROUTER.toLowerCase(), 'permit must name the router as spender');
    assert.equal(p.chain.sent.length, 1, 'no separate approval transaction');

    const calls = decodeMulticall(p.chain.lastSent.data);
    assert.equal(selectorOf(calls[0]), SEL.RPERMIT, 'the permit rides in the same multicall');
    p.close();
  });

  test('falls back to Permit2 when the token has no permit but Permit2 is approved', async () => {
    const p = await erc20Swap(c => c.setAllowance(A.USDC, A.ACCOUNT, A.PERMIT2, 10n ** 30n));
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    await p.settle();

    assert.equal(p.chain.signed.length, 1);
    assert.equal(p.chain.signed[0].typedData.primaryType, 'PermitTransferFrom');
    assert.equal(p.chain.signed[0].typedData.message.spender.toLowerCase(),
      A.ZROUTER.toLowerCase());
    const calls = decodeMulticall(p.chain.lastSent.data);
    assert.equal(selectorOf(calls[0]), SEL.P2TF, 'Permit2 transfer leads the multicall');
    p.close();
  });

  /**
   * A DAI-style permit is indistinguishable from an EIP-2612 one through every
   * probe the page used to make: DOMAIN_SEPARATOR answers, nonces(owner)
   * answers, and the domain hashes to the same 32 bytes because the struct that
   * differs is not part of the domain. But its permit takes
   * (holder,spender,nonce,expiry,allowed,v,r,s), and zRouter.permit is strictly
   * IERC2612 — permitDAI is a separate entrypoint the page does not build. So
   * the page collected a signature that could never be used and the swap
   * reverted in preflight, AFTER the user had signed for it.
   *
   * The typehash is the one thing the two disagree on that is readable, so it
   * is what decides. Both directions are pinned, because a check that answers
   * "not 2612" to everything would pass the test below and silently cost every
   * real 2612 token its gasless approval.
   */
  const TH_2612 = '0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9';
  const TH_DAI = '0xea2aa0a1be11a07ed86d755c93467f4f82362b452371d1ba94d1715123511acb';

  test('a DAI-style permit is not mistaken for one the router can call', async () => {
    const p = await erc20Swap(c => {
      c.setToken(A.USDC, {
        symbol: 'USDC', decimals: 6, name: 'USD Coin',
        domainSeparator: domainSeparator('USD Coin', '1', A.USDC),
        permitTypehash: TH_DAI,
      });
      c.setAllowance(A.USDC, A.ACCOUNT, A.PERMIT2, 10n ** 30n);
    });
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    await p.settle();

    assert.equal(p.chain.signed.length, 1, 'exactly one signature, and not a wasted one');
    assert.equal(p.chain.signed[0].typedData.primaryType, 'PermitTransferFrom',
      'the DAI-style permit must be skipped for a funding route that works');
    assert.equal(selectorOf(decodeMulticall(p.chain.lastSent.data)[0]), SEL.P2TF);
    p.close();
  });

  test('a token that publishes the 2612 typehash still gets its gasless permit', async () => {
    const p = await erc20Swap(c => c.setToken(A.USDC, {
      symbol: 'USDC', decimals: 6, name: 'USD Coin',
      domainSeparator: domainSeparator('USD Coin', '1', A.USDC),
      permitTypehash: TH_2612,
    }));
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    await p.settle();

    assert.equal(p.chain.signed[0].typedData.primaryType, 'Permit');
    assert.equal(selectorOf(decodeMulticall(p.chain.lastSent.data)[0]), SEL.RPERMIT);
    p.close();
  });

  /**
   * Permit2 is the one funding route that pays the router BEFORE the swap runs.
   * Every other route pulls: an allowance lets safeTransferFrom take the exact
   * amount the venue needs, and zRouter refunds `msg.value - amountIn` itself
   * when the input is ether. Permit2 instead deposits whatever the page asked
   * for, and on exact-output the page has to ask for the slippage-padded maxIn
   * because the true input is not known until the pool is touched.
   *
   * The pad then sits in zRouter as a real balance whose transient credit dies
   * with the transaction — and sweep() is public, so the next caller takes it.
   * Up to the user's whole slippage setting, silently, on every exact-output
   * swap funded this way. A trailing sweep back to the payer restores the same
   * invariant the ether path already had.
   */
  async function erc20SwapExactOut(prep = () => {}) {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
    chain.quoteHandler = fixedRateQuoter({ rate: ETH / 3000n, decIn: 6, decOut: 18 });
    prep(chain);
    const p = await loadPage({ chain });
    await p.connect();
    p.click('flip');
    await p.settle();
    await p.typeAmount('outAmt', '1');   // exactly 1 ETH out, spending USDC
    return p;
  }

  test('Permit2 returns the unspent exact-output pad instead of stranding it', async () => {
    const p = await erc20SwapExactOut(c => c.setAllowance(A.USDC, A.ACCOUNT, A.PERMIT2, 10n ** 30n));
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    await p.settle();

    const calls = decodeMulticall(p.chain.lastSent.data);
    assert.equal(selectorOf(calls[0]), SEL.P2TF, 'Permit2 still funds the swap');
    const tail = calls[calls.length - 1];
    assert.equal(selectorOf(tail), SEL.SWEEP, 'and the leftover input goes home');

    const args = '0x' + tail.slice(10);
    assert.equal(wordAddr(args, 0).toLowerCase(), A.USDC.toLowerCase(), 'sweeps the input token');
    assert.equal(word(args, 1), 0n, 'id 0 - an ERC-20');
    assert.equal(word(args, 2), 0n, 'amount 0 means whatever is left, which is what we cannot predict');
    assert.equal(wordAddr(args, 3).toLowerCase(), A.ACCOUNT.toLowerCase(), 'back to the payer');
    p.close();
  });

  test('an exact-input Permit2 swap adds no sweep, having nothing left over', async () => {
    // The deposit is the input, to the wei, so a sweep would only burn gas.
    const p = await erc20Swap(c => c.setAllowance(A.USDC, A.ACCOUNT, A.PERMIT2, 10n ** 30n));
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    await p.settle();

    const calls = decodeMulticall(p.chain.lastSent.data);
    assert.equal(selectorOf(calls[0]), SEL.P2TF);
    assert.ok(!calls.some(c => selectorOf(c) === SEL.SWEEP), 'no sweep on exact-input');
    p.close();
  });

  test('uses atomic wallet batching when the wallet supports it', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = { '0x1': { atomic: { status: 'supported' } } };
    });
    p.click('swap');
    await p.waitFor(() => p.chain.batches.length > 0, { label: 'batch' });
    await p.settle();

    const batch = p.chain.batches[0];
    assert.equal(batch.atomicRequired, true, 'a partial batch would leave a dangling approval');
    assert.equal(batch.calls.length, 2, 'approve + swap');
    assert.equal(selectorOf(batch.calls[0].data), SEL.APPROVE);
    assert.equal(batch.calls[1].to.toLowerCase(), A.ZROUTER.toLowerCase());
    p.close();
  });

  test('legacy wallets get a plain approve, then the swap', async () => {
    const p = await erc20Swap();
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length >= 2, { label: 'approve + swap' });
    await p.settle();

    const [approve, swap] = p.chain.sent;
    assert.equal(approve.to.toLowerCase(), A.USDC.toLowerCase());
    assert.equal(selectorOf(approve.data), SEL.APPROVE);
    assert.equal(wordAddr('0x' + approve.data.slice(10), 0).toLowerCase(), A.ZROUTER.toLowerCase());
    assert.equal(swap.to.toLowerCase(), A.ZROUTER.toLowerCase());
    p.close();
  });

  test('clears a stale non-zero allowance first, for USDT-style tokens', async () => {
    // A partial existing allowance is the case that reverts on approve() for
    // tokens that require going through zero.
    const p = await erc20Swap(c => c.setAllowance(A.USDC, A.ACCOUNT, A.ZROUTER, 1n));
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length >= 3, { label: 'zero + approve + swap' });
    await p.settle();

    const [zero, approve] = p.chain.sent;
    assert.equal(selectorOf(zero.data), SEL.APPROVE);
    assert.equal(word('0x' + zero.data.slice(10), 1), 0n, 'must reset to zero first');
    assert.equal(selectorOf(approve.data), SEL.APPROVE);
    assert.ok(word('0x' + approve.data.slice(10), 1) > 0n, 'then set the real amount');
    p.close();
  });

  /**
   * The recovery id, and the two funding routes that disagreed about it.
   *
   * zRouter.permit hands (v, r, s) to the token, and the page has always added
   * 27 to a raw 0/1 v before building that call. permit2TransferFrom hands a
   * packed 65-byte signature to Permit2, whose SignatureVerification splits it
   * and calls ecrecover — which answers address(0) for v in {0,1} and reverts
   * InvalidSigner. The page did not normalise there, so a wallet that returns
   * the raw form got a signature prompt and then a revert, which is precisely
   * the outcome the waterfall's other guards exist to prevent.
   *
   * Both directions are pinned. A fix that clamped every v to 27 would pass a
   * one-sided test and silently break every wallet that already answers 28.
   */
  const p2Signature = data => {
    const args = '0x' + data.replace(/^0x/, '').slice(8);
    assert.equal(word(args, 4), 0xa0n, 'the signature is the fifth head word');
    const len = Number(word(args, 5));
    return args.replace(/^0x/, '').slice(6 * 64, 6 * 64 + len * 2);
  };

  for (const [raw, want] of [[0x00, '1b'], [0x01, '1c'], [0x1b, '1b'], [0x1c, '1c']]) {
    test(`a Permit2 signature carrying v=${raw} reaches Permit2 as 0x${want}`, async () => {
      const p = await erc20Swap(c => {
        c.sigV = raw;
        c.setAllowance(A.USDC, A.ACCOUNT, A.PERMIT2, 10n ** 30n);
      });
      p.click('swap');
      await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
      await p.settle();

      const calls = decodeMulticall(p.chain.lastSent.data);
      assert.equal(selectorOf(calls[0]), SEL.P2TF);
      const sig = p2Signature(calls[0]);
      assert.equal(sig.length, 130, 'a 65-byte signature, packed whole');
      assert.equal(sig.slice(128), want);
      p.close();
    });
  }

  test('a 2612 permit normalises its v the same way', async () => {
    const p = await erc20Swap(c => {
      c.sigV = 0x00;
      c.setToken(A.USDC, {
        symbol: 'USDC', decimals: 6, name: 'USD Coin',
        domainSeparator: domainSeparator('USD Coin', '1', A.USDC),
      });
    });
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'swap tx' });
    await p.settle();

    const permit = decodeMulticall(p.chain.lastSent.data)[0];
    assert.equal(selectorOf(permit), SEL.RPERMIT);
    // permit(token, value, deadline, v, r, s) — v is the fourth word.
    assert.equal(word('0x' + permit.slice(10), 3), 27n);
    p.close();
  });
});

/**
 * EIP-5792, and the difference between what a wallet says and what happened.
 */
describe('atomic batching', () => {
  async function erc20Swap(prep = () => {}) {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, ETH);
    chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
    chain.quoteHandler = fixedRateQuoter({ rate: ETH / 3000n, decIn: 6, decOut: 18 });
    prep(chain);
    const p = await loadPage({ chain });
    await p.connect();
    p.click('flip');
    await p.settle();
    await p.typeAmount('amt', '3000');
    return p;
  }

  /**
   * Capabilities are keyed by chain id, and wallets spell one however they
   * like. The page used to guess at spellings, which cost it "0x01" — a
   * perfectly ordinary way to write mainnet — and, worse, made it accept "0x0",
   * which is not a chain at all. Deciding on the NUMBER settles both.
   */
  for (const key of ['0x1', '0x01', '1', 1]) {
    test(`capabilities keyed ${JSON.stringify(key)} are read as mainnet`, async () => {
      const p = await erc20Swap(c => {
        c.capabilities = { [key]: { atomic: { status: 'supported' } } };
      });
      p.click('swap');
      await p.waitFor(() => p.chain.batches.length > 0, { label: 'batch' });
      await p.settle();
      assert.equal(p.chain.batches[0].calls.length, 2, 'approve + swap');
      p.close();
    });
  }

  /**
   * Base answering "atomic" says nothing about mainnet, and batching on the
   * strength of it buys a wallet prompt that can only fail. Key 0 is the one
   * exception and stays honoured — it is the chain-global answer, not a chain.
   */
  test('another chain\'s capabilities are not borrowed for mainnet', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = { '0x2105': { atomic: { status: 'supported' } } };
    });
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length >= 2, { label: 'approve + swap' });
    await p.settle();
    assert.equal(p.chain.batches.length, 0, 'Base must not pass for mainnet');
    assert.equal(selectorOf(p.chain.sent[0].data), SEL.APPROVE, 'a plain approval instead');
    p.close();
  });

  test('a mainnet "unsupported" still overrides a chain-global "supported"', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = {
        '0x01': { atomic: { status: 'unsupported' } },
        '0x0': { atomic: { status: 'supported' } },
      };
    });
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length >= 2, { label: 'approve + swap' });
    await p.settle();
    assert.equal(p.chain.batches.length, 0,
      'the chain-specific answer decides, however it is spelled');
    p.close();
  });

  test('the batch id is asked for on the chain the page trades', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = { '0x1': { atomic: { status: 'supported' } } };
    });
    p.click('swap');
    await p.waitFor(() => p.chain.batches.length > 0, { label: 'batch' });
    await p.settle();
    assert.equal(p.chain.batches[0].chainId, '0x1');
    p.close();
  });

  /**
   * 400 is EIP-5792's partial-failure code. It was unhandled, so a batch the
   * wallet had already given up on read as "still pending" and the page sat on
   * it for the full ten-minute timeout — no error, no re-enabled button, just a
   * spinner over a transaction that was never coming.
   */
  test('a 400 status is reported, not waited out', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = { '0x1': { atomic: { status: 'supported' } } };
      c.callsStatusHandler = () => ({ status: 400, receipts: [] });
    });
    p.click('swap');
    await p.waitFor(() => /batch failed/.test(p.text('stat')), { label: 'failure surfaced' });
    await p.waitFor(() => !p.disabled('swap'), { label: 're-enabled button' });
    p.close();
  });

  /**
   * A wallet may answer with one receipt per call. Reading receipts[0] then
   * read the APPROVAL's receipt and reported its success as the swap's — the
   * page said "Done", linked the approval, and cleared the quote, for a trade
   * that reverted. atomicRequired is supposed to make this unreachable, but a
   * promise from the wallet is not a reason to call a revert a fill.
   */
  test('a reverted call anywhere in the batch is a failure', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = { '0x1': { atomic: { status: 'supported' } } };
      c.callsStatusHandler = () => ({
        status: 200,
        receipts: [
          { status: '0x1', transactionHash: '0x' + 'aa'.repeat(32) },
          { status: '0x0', transactionHash: '0x' + 'bb'.repeat(32) },
        ],
      });
    });
    p.click('swap');
    await p.waitFor(() => /batch reverted/.test(p.text('stat')), { label: 'revert surfaced' });
    p.close();
  });

  test('the trade at the end of the batch is the receipt reported', async () => {
    const p = await erc20Swap(c => {
      c.capabilities = { '0x1': { atomic: { status: 'supported' } } };
      c.callsStatusHandler = () => ({
        status: 200,
        receipts: [
          { status: '0x1', transactionHash: '0x' + 'aa'.repeat(32) },
          { status: '0x1', transactionHash: '0x' + 'bb'.repeat(32) },
        ],
      });
    });
    p.click('swap');
    await p.waitFor(() => /Done/.test(p.text('stat')), { label: 'settled' });
    assert.match(p.text('stat'), /bbbbbb/, 'the swap receipt, not the approval');
    p.close();
  });
});

describe('price impact gates', () => {
  /** Pool sized so a trade of `size` produces a chosen impact. */
  async function pool({ reserveIn = 1000n * ETH, reserveOut = 3_000_000n * USDC } = {}) {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 100_000n * ETH);
    chain.quoteHandler = cpammQuoter({ reserveIn, reserveOut, source: 0 });
    const p = await loadPage({ chain });
    await p.connect();
    return p;
  }

  test('a deep-liquidity trade shows no impact at all', async () => {
    const p = await pool();
    await p.typeAmount('amt', '0.01'); // 1/100_000 of the pool
    assert.doesNotMatch(p.text('rate'), /Impact/,
      'showing 0.00% on every ordinary trade teaches people to ignore the warning');
    p.close();
  });

  test('a noticeable trade shows the impact percentage', async () => {
    const p = await pool();
    await p.typeAmount('amt', '10');   // 1% of the pool => ~1%
    assert.match(p.text('rate'), /Impact 0\.9\d%/);
    assert.equal(p.text('stat'), '', 'below the warn tier there is no alarm');
    p.close();
  });

  test('a costly trade explains the loss in tokens, not just a percentage', async () => {
    const p = await pool();
    await p.typeAmount('amt', '100');  // 10% of the pool => ~9%
    assert.match(p.text('stat'), /High price impact: 9\.\d+%/);
    assert.match(p.text('stat'), /worse than the market rate/);
    assert.match(p.text('stat'), /USDC/, 'the loss is quoted in the token being received');
    p.close();
  });

  test('a severe trade requires a confirmation before sending', async () => {
    const p = await pool();
    await p.typeAmount('amt', '200');  // 20% of the pool => ~16.5%
    p.click('swap');                   // no queued answer => confirm() returns false
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'declining the dialog must abort the swap');
    assert.equal(p.asked.confirm.length, 1);
    assert.match(p.asked.confirm[0], /Price impact/);

    p.queueConfirm(true);
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'confirmed swap' });
    p.close();
  });

  test('a ruinous trade demands the loss be typed back, not just clicked through', async () => {
    const p = await pool();
    await p.typeAmount('amt', '1000'); // the whole reserve => ~49%
    p.queuePrompt('');                 // wrong answer
    p.click('swap');
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'a wrong answer must not send');
    assert.equal(p.asked.confirm.length, 0, 'the severe tier must not be a click-through');
    assert.match(p.asked.prompt[0], /STOP/);

    const need = p.asked.prompt[0].match(/Type (\d+) to accept/)[1];
    p.queuePrompt(need);
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'accepted swap' });
    p.close();
  });

  test('the typed gate asks for a number the user can only get by reading', async () => {
    const p = await pool();
    await p.typeAmount('amt', '1000');
    p.queuePrompt('');
    p.click('swap');
    await p.settle();
    const shown = p.asked.prompt[0].match(/priced ([\d.]+)% away/)[1];
    const need = p.asked.prompt[0].match(/Type (\d+) to accept/)[1];
    assert.equal(need, String(Math.floor(Number(shown))),
      'the demanded token must come from the number in the message');
    p.close();
  });
});

/**
 * What the page says when something goes wrong.
 *
 * `explain` used to build its message with `String(e.data || e.message || e)`,
 * and wallets routinely hand back `data` as an OBJECT - `{code, message}`, or a
 * nested `originalError`. Stringifying one of those yields "[object Object]",
 * so the page reported "Error: [object Object]" for a whole class of real
 * failures. It was survivable while these landed in the status line under a
 * form; it stopped being survivable once the game surfaced them on its own HUD.
 *
 * This asks `explain` directly. Driving a failed swap and reading the status
 * line does not work: the re-render that follows clears it, so every such
 * assertion passes against an empty string and proves nothing.
 */
describe('what a failure is called', () => {
  // Script-level `const`s are in the global lexical scope, which a direct eval
  // can reach even though they are not properties of `window`.
  const explain = (p, e) => p.window.eval(`explain(${JSON.stringify(e)})`);

  test('an object in `data` is not reported as [object Object]', async () => {
    const p = await setup();
    const said = explain(p, { code: -32603, data: { code: 3, message: 'execution reverted: bad thing' } });
    assert.doesNotMatch(said, /\[object/, `the page said: ${said}`);
    assert.match(said, /bad thing/, 'the wallet\u2019s own words should survive');
    p.close();
  });

  test('revert data nested in an object is still decoded', async () => {
    const p = await setup();
    // 0x7939f424 - TransferFromFailed, one of the selectors the page knows.
    const said = explain(p, { code: -32603, data: { data: '0x7939f424' } });
    assert.doesNotMatch(said, /\[object/, `the page said: ${said}`);
    assert.doesNotMatch(said, /0x7939f424/, 'a known revert should read as English');
    p.close();
  });

  test('a plain message still reads exactly as it did', async () => {
    const p = await setup();
    assert.match(explain(p, { message: 'nonce too low' }), /nonce too low/);
    assert.match(explain(p, { data: '0x7939f424' }), /transfer/i, 'string data still decodes');
    p.close();
  });

  test('an error carrying nothing at all still says something', async () => {
    const p = await setup();
    const said = explain(p, { code: -32000 });
    assert.doesNotMatch(said, /\[object/, `the page said: ${said}`);
    assert.ok(said.trim().length > 0, 'silence is the one unacceptable answer');
    assert.match(said, /-32000/, 'the code is all there is, so show it');
    p.close();
  });
});
