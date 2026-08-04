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
  assertAddressesMatchPage, word, wordAddr, selectorOf, closeAllPages,
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
  test('starts disconnected and offers to connect', async () => {
    const p = await setup({ connect: false });
    assert.equal(p.text('addr'), 'Not connected');
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
    assert.equal(p.text('addr'), 'Not connected');
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
    assert.match(rate, /UniV3 0\.3%/, 'names the venue and its fee tier');
    // default slippage is 0.5%, so the floor is 3000 * 0.995
    assert.match(rate, /Min 2985 USDC/);
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
