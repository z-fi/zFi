import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { AbiCoder, Interface } from 'ethers';
import { readFileSync } from 'node:fs';
import { A, MockChain, loadPage, fixedRateQuoter, cpammQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const USDC = 10n ** 6n;
const coder = AbiCoder.defaultAbiCoder();

const chainWithQuote = () => {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.setErc20(A.USDC, A.ACCOUNT, 50_000n * USDC);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  return chain;
};

// The off-chain solver lanes. What matters is not that a lane can win - it is
// that it can only win HONESTLY, and that the page decides which adapter runs
// rather than the roster deciding for it.
describe('the solver lanes', () => {
  const SELF = '0x' + 'ab'.repeat(20);
  // THE ADAPTER IS PINNED IN THE PAGE'S OWN BYTES, so a test that invents an
  // address tests nothing: the page correctly refuses it and abandons the
  // solver path, which is how a whole suite went red without anything being
  // broken. Read the pin out of the page instead - then a redeploy that moves
  // the address moves these with it, and can never leave the suite asserting
  // against an adapter the page would never call.
  const PAGE = readFileSync(new URL('../../zSwap.html', import.meta.url), 'utf8');
  const pin = (name) => {
    const m = PAGE.match(new RegExp(`const ${name}="(0x[0-9a-fA-F]{40})"`));
    if (!m) throw new Error(`${name} is not pinned in zSwap.html - has the constant been renamed?`);
    // Lowercased: the page pins a checksummed literal, and `wire` compares
    // against a lowercased `tx.to`. Mixed case here silently matches nothing.
    return m[1].toLowerCase();
  };
  const FILL = pin('SOLVER_FILL_PIN');
  const EXEC = pin('SOLVER_EXEC_PIN');
  // The roster address is pinned too now. It used to be read off whichever
  // contract served the page, which meant working out that contract's address
  // from the hostname first - impossible on any host but an address subdomain,
  // so every published name lost its lanes in silence. Serve the roster where
  // the page actually looks for it.
  const LIST = pin('SOLVERS_PIN');
  const ROUTER = '0x' + '77'.repeat(20);

  // (name, endpoint, adapter, handicapBps, enabled)
  const lane = (name, ep, adapter, bps = 50, on = true) => [name, ep, adapter, bps, on];
  const LANE_T = ['tuple(string,string,address,uint16,bool)[]'];

  function wire(chain, lanes) {
    const ethCall = chain.ethCall.bind(chain);
    chain.ethCall = (tx, block) => {
      const to = (tx.to || '').toLowerCase();
      if (to === FILL && tx.data.startsWith('0x495c73b0')) return coder.encode(['address'], [EXEC]); // EXEC()
      if (to === LIST && tx.data.startsWith('0xe3b06401')) return coder.encode(LANE_T, [lanes]);     // solvers()
      return ethCall(tx, block);
    };
  }

  const open = (chain) => loadPage({
    walletless: true, chain,
    url: 'https://' + SELF + '.1.w3link.io/',
    hash: 'token=ETH&out=USDC',
  });

  test('a lane naming an adapter the page was not built with is ignored', async () => {
    // THE PIN. A hostile node can return any roster it likes; it must not be
    // able to make the page call an adapter that is not the built-in one.
    const chain = chainWithQuote();
    const EVIL = '0x' + 'ba'.repeat(20);
    wire(chain, [lane('0x', 'https://lane.example', EVIL)]);
    chain.lanes = {
      'lane.example': { buyAmount: '999999999999', transaction: { to: ROUTER, data: '0xdead' } },
    };
    const p = await open(chain);
    await p.typeAmount('amt', '1');
    const asked = (chain.httpLog || []).some(h => String(h.url).includes('lane.example'));
    assert.ok(!asked, 'a lane with an unpinned adapter was still queried');
    p.close();
  });

  test('a lane the page does not have a shape for is skipped', async () => {
    const chain = chainWithQuote();
    wire(chain, [lane('NotARealAggregator', 'https://nope.example', FILL)]);
    chain.lanes = { 'nope.example': { buyAmount: '999999999999' } };
    const p = await open(chain);
    await p.typeAmount('amt', '1');
    assert.ok(!(chain.httpLog || []).some(h => String(h.url).includes('nope.example')),
      'the page invented a shape for a protocol it does not speak');
    p.close();
  });

  test('a disabled lane is never asked', async () => {
    const chain = chainWithQuote();
    wire(chain, [lane('0x', 'https://off.example', FILL, 50, false)]);
    chain.lanes = { 'off.example': { buyAmount: '999999999999', transaction: { to: ROUTER, data: '0x' } } };
    const p = await open(chain);
    await p.typeAmount('amt', '1');
    assert.ok(!(chain.httpLog || []).some(h => String(h.url).includes('off.example')),
      'a lane parked on chain was still queried');
    p.close();
  });

  test('an enabled, pinned lane is asked, and asks for the output to reach EXEC', async () => {
    // A route that pays anyone but EXEC measures nothing at the adapter and
    // reverts by design, so the taker the page sends is load-bearing.
    const chain = chainWithQuote();
    wire(chain, [lane('0x', 'https://good.example', FILL)]);
    chain.lanes = {
      'good.example': { buyAmount: '1', transaction: { to: ROUTER, data: '0x1234' } },
    };
    const p = await open(chain);
    await p.typeAmount('amt', '1');
    const hit = (chain.httpLog || []).find(h => String(h.url).includes('good.example'));
    assert.ok(hit, 'a pinned, enabled lane was never asked');
    assert.ok(String(hit.url).toLowerCase().includes(EXEC.slice(2).toLowerCase()),
      `the lane was not told to pay EXEC: ${hit.url}`);
    p.close();
  });

  test('a lane that refuses does not break the quote', async () => {
    const chain = chainWithQuote();
    wire(chain, [lane('0x', 'https://dead.example', FILL)]);
    chain.lanes = { 'dead.example': 403 };
    const p = await open(chain);
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'a refusing lane took the on-chain quote down with it');
    p.close();
  });

  // THE POSITIVE CASE. Every other test here passes when a lane loses, which
  // is also what happens if the lane is never asked at all - so without this
  // one the suite would be green on a feature that does nothing.
  test('a lane that clears the floor wins, and routes through the pinned adapter', async () => {
    const chain = chainWithQuote();
    wire(chain, [lane('0x', 'https://strong.example', FILL)]);
    // The chain pays 3000 USDC; this pays 3600, which clears 3000's floor even
    // after the lane's own slippage and the 50bp handicap.
    chain.lanes = {
      'strong.example': { buyAmount: (3600n * USDC).toString(), transaction: { to: ROUTER, data: '0x1234' } },
    };
    const p = await open(chain);
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3600', 'the winning lane was not adopted');
    // The user has to be able to see WHOSE route this is and what it is bound
    // to - an off-chain solver is not the same thing as the page's own pools.
    const line = p.$('rate').textContent;
    assert.match(line, /0x solver/, `the winning lane was not named: ${line}`);
    // The shared `Min` suffix carries the bound for every route; what a solver
    // route adds is whose route it is.
    assert.match(line, /Min /, `the guaranteed minimum was not shown: ${line}`);
    assert.doesNotMatch(line, /at least/, `the minimum was shown twice: ${line}`);
    p.close();
  });

  // Every shape the page speaks, each asked to pay EXEC. A shape that quietly
  // stopped matching its aggregator's response would otherwise just go quiet -
  // the lane would lose every race and nothing would say why.
  const SHAPES = {
    ParaSwap: {
      '/prices': { priceRoute: { destAmount: (3600n * USDC).toString(), srcDecimals: 18, destDecimals: 6, tokenTransferProxy: ROUTER } },
      '/transactions/1': { to: ROUTER, data: '0x1234' },
    },
    KyberSwap: {
      '/ethereum/api/v1/routes?': { data: { routeSummary: { amountOut: (3600n * USDC).toString() } } },
      '/ethereum/api/v1/route/build': { data: { data: '0x1234', routerAddress: ROUTER } },
    },
    Enso: { '': { amountOut: (3600n * USDC).toString(), tx: { to: ROUTER, data: '0x1234' } } },
    OKX: { '/dex/aggregator/swap': { code: '0', data: [{ tx: { to: ROUTER, data: '0x1234' }, routerResult: { toTokenAmount: (3600n * USDC).toString() } }] } },
  };

  for (const [name, routes] of Object.entries(SHAPES)) {
    test(`the ${name} shape decodes a win`, async () => {
      const chain = chainWithQuote();
      const ep = `https://${name.toLowerCase()}.example`;
      wire(chain, [lane(name, ep, FILL)]);
      chain.lanes = {};
      for (const [frag, body] of Object.entries(routes)) chain.lanes[ep + frag] = body;
      const p = await open(chain);
      await p.typeAmount('amt', '1');
      assert.equal(p.value('outAmt'), '3600', `${name} quoted a win the page did not adopt`);
      p.close();
    });
  }

  // Seeing the field is how a user can tell the selection was made on floors
  // rather than on whoever advertised the biggest number.
  test('the losing venues are listed, ranked, and collapsed until asked for', async () => {
    const chain = chainWithQuote();
    wire(chain, [lane('0x', 'https://a.example', FILL), lane('ParaSwap', 'https://b.example', FILL)]);
    chain.lanes = {
      'a.example': { buyAmount: (3600n * USDC).toString(), transaction: { to: ROUTER, data: '0x1234' } },
      'b.example/prices': { priceRoute: { destAmount: (3200n * USDC).toString(), srcDecimals: 18, destDecimals: 6, tokenTransferProxy: ROUTER } },
      'b.example/transactions/1': { to: ROUTER, data: '0x1234' },
    };
    const p = await open(chain);
    await p.typeAmount('amt', '1');

    const box = p.$('rankBox');
    assert.ok(box.classList.contains('hide'), 'the venue list was shown without being asked for');

    const rows = [...box.querySelectorAll('i')].map(r => r.textContent);
    assert.equal(rows.length, 3, `expected on-chain + two lanes, got: ${JSON.stringify(rows)}`);
    assert.match(rows[0], /0x/, `the winner is not listed first: ${JSON.stringify(rows)}`);
    assert.ok(box.querySelector('i.w'), 'no row is marked as the winner');
    // Ranked by floor, descending: 3600 > 3200, and the chain's 3000 is last.
    assert.match(rows[2], /On-chain/, `rows are not ranked by floor: ${JSON.stringify(rows)}`);
    // Losers carry their gap to the winner, so the comparison is legible.
    assert.match(rows[1], /-\d+\.\d+%/, `no delta shown on a losing venue: ${rows[1]}`);

    const caret = p.$('rate').querySelector('.rk');
    assert.ok(caret, 'no control to open the list');
    caret.onclick();
    assert.ok(!box.classList.contains('hide'), 'the list did not open');
    p.close();
  });

  /**
   * The caret is a CHILD of `rate`; every disclosure suffix below it assigns
   * `rate.textContent`, which discards children. The caret was appended ahead
   * of eight of them, so it survived only the quotes that had nothing to
   * disclose - and vanished on exactly the degraded ones whose ranking most
   * deserves inspection, taking with it the only way to pin a lane.
   */
  test('the caret survives a quote that carries a disclosure suffix', async () => {
    // A pool shallow enough that 10 ETH moves it ~1%, so the quote carries an
    // "Impact" suffix - the last of the eight that assign `rate.textContent`.
    const chain = chainWithQuote();
    chain.setNative(A.ACCOUNT, 100_000n * ETH);
    chain.quoteHandler = cpammQuoter({ reserveIn: 1000n * ETH, reserveOut: 3_000_000n * USDC, source: 0 });
    wire(chain, [lane('0x', 'https://a.example', FILL), lane('ParaSwap', 'https://b.example', FILL)]);
    chain.lanes = {
      'a.example': { buyAmount: (3600n * USDC).toString(), transaction: { to: ROUTER, data: '0x1234' } },
      'b.example/prices': { priceRoute: { destAmount: (3200n * USDC).toString(), srcDecimals: 18, destDecimals: 6, tokenTransferProxy: ROUTER } },
      'b.example/transactions/1': { to: ROUTER, data: '0x1234' },
    };
    const p = await open(chain);
    await p.typeAmount('amt', '10');

    assert.match(p.text('rate'), /Impact \d/, 'this quote was meant to carry a suffix below the caret');
    assert.ok(p.$('rankBox').firstChild, 'the venue list is empty, so the caret is absent for another reason');
    const caret = p.$('rate').querySelector('.rk');
    assert.ok(caret, 'a disclosure suffix wiped the caret off a degraded quote');
    caret.onclick();
    assert.ok(!p.$('rankBox').classList.contains('hide'), 'the list did not open');
    p.close();
  });

  // The page hand-rolls its calldata - no ABI library ships in it - so the one
  // thing worth proving is that what it builds actually decodes as the call it
  // means to make. A silent layout slip here would send a well-formed
  // transaction to the wrong arguments.
  test('the winning lane builds calldata that decodes as fill()', async () => {
    const chain = chainWithQuote();
    wire(chain, [lane('0x', 'https://c.example', FILL)]);
    chain.lanes = {
      'c.example': { buyAmount: (3600n * USDC).toString(), transaction: { to: ROUTER, data: '0xdeadbeefcafe' } },
    };
    // A connected wallet, because the page only builds `last` once there is an
    // account to build it for - walletless visitors get the price, not a
    // transaction.
    const p = await loadPage({ chain, url: 'https://' + SELF + '.1.w3link.io/', hash: 'token=ETH&out=USDC' });
    await p.connect();
    await p.typeAmount('amt', '1');

    const q = p.window.eval('last');
    assert.ok(q, 'no quote was recorded');
    assert.equal(q.to.toLowerCase(), FILL.toLowerCase(), 'the route does not go through the pinned adapter');

    const iface = new Interface([
      'function fill(address target,address spender,address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,address to,bytes data)',
    ]);
    const d = iface.parseTransaction({ data: q.callData });
    assert.equal(d.name, 'fill', 'the calldata is not a fill() call');
    assert.equal(d.args[0].toLowerCase(), ROUTER.toLowerCase(), 'target is not the router the lane named');
    assert.equal(d.args[2], '0x0000000000000000000000000000000000000000', 'tokenIn is not ETH');
    assert.equal(d.args[3], 10n ** 18n, 'amountIn is not the amount typed');
    assert.equal(d.args[7], '0xdeadbeefcafe', 'the solver payload was mangled in encoding');
    // minOut must be the FLOOR, never the quote - that is the whole bargain.
    assert.ok(d.args[5] < 3600n * USDC, `minOut is the quote, not the floor: ${d.args[5]}`);
    p.close();
  });

  // Somebody who asks for a venue by name gets it, even when its floor is
  // lower - and is told, so the trade-off is visible rather than silent.
  test('a hand-picked venue overrules the floor comparison, and says so', async () => {
    const chain = chainWithQuote();
    wire(chain, [lane('0x', 'https://a.example', FILL), lane('ParaSwap', 'https://b.example', FILL)]);
    chain.lanes = {
      'a.example': { buyAmount: (3600n * USDC).toString(), transaction: { to: ROUTER, data: '0x1234' } },
      'b.example/prices': { priceRoute: { destAmount: (3400n * USDC).toString(), srcDecimals: 18, destDecimals: 6, tokenTransferProxy: ROUTER } },
      'b.example/transactions/1': { to: ROUTER, data: '0x1234' },
    };
    const p = await open(chain);
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3600', 'the best floor did not win by default');

    // Pin the weaker venue by clicking its row.
    const rows = [...p.$('rankBox').querySelectorAll('i')];
    const para = rows.find(r => r.textContent.includes('ParaSwap'));
    assert.ok(para, 'ParaSwap was not listed');
    para.onclick();
    await p.settle();

    assert.equal(p.value('outAmt'), '3400', 'the pinned venue was not used');
    assert.match(p.$('rate').textContent, /ParaSwap solver · pinned/, 'the pin was not disclosed');
    // The bound still comes from the pinned lane, never from the one it beat.
    const q = p.window.eval('last');
    if (q) assert.ok(q.amountLimit < 3400n * USDC, 'minOut was not the pinned lane floor');
    p.close();
  });

  test('pinning the chain keeps every lane out of the result', async () => {
    const chain = chainWithQuote();
    wire(chain, [lane('0x', 'https://a.example', FILL)]);
    chain.lanes = {
      'a.example': { buyAmount: (3600n * USDC).toString(), transaction: { to: ROUTER, data: '0x1234' } },
    };
    const p = await open(chain);
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3600');

    const onchain = [...p.$('rankBox').querySelectorAll('i')].find(r => r.textContent.includes('On-chain'));
    onchain.onclick();
    await p.settle();
    assert.equal(p.value('outAmt'), '3000', 'the chain was pinned but a lane still won');
    p.close();
  });

  // Exact output inverts everything: the lane offers to SPEND, the number it
  // can be held to is a ceiling, and cheaper wins.
  test('an exact-output lane wins by costing less, and bounds the spend', async () => {
    const chain = chainWithQuote();
    wire(chain, [lane('0x', 'https://o.example', FILL)]);
    // The chain wants ~1 ETH for 3000 USDC; this lane wants 0.9.
    chain.lanes = {
      // The real 0x buy-side response: no `sellAmount`, an estimate and a cap.
      'o.example': {
        estimatedNetSellAmount: (9n * 10n ** 17n).toString(),
        maxSellAmount: (95n * 10n ** 16n).toString(),
        allowanceTarget: ROUTER,
        transaction: { to: ROUTER, data: '0xfeed' },
      },
    };
    const p = await loadPage({ chain, url: 'https://' + SELF + '.1.w3link.io/', hash: 'token=ETH&out=USDC' });
    await p.connect();
    // Typing into the RECEIVE box is the exact-output mode.
    await p.typeAmount('outAmt', '3000');

    const q = p.window.eval('last');
    assert.ok(q, 'no quote was recorded');
    assert.equal(q.to.toLowerCase(), FILL.toLowerCase(), 'exact-out did not route through the adapter');

    const iface = new Interface([
      'function fill(address target,address spender,address tokenIn,uint256 amountIn,address tokenOut,uint256 minOut,address to,bytes data)',
    ]);
    const d = iface.parseTransaction({ data: q.callData });
    // amountIn is the CEILING the user could spend; minOut is the exact output.
    assert.equal(d.args[5], 3000n * USDC, 'minOut is not the exact output asked for');
    // The ceiling is the LESSER of the lane's published cap and what the user's
    // slippage authorises. 0x caps at 0.95; 0.9 quoted at 0.5% authorises
    // 0.9045; the spend must be bounded by the user's number, not the lane's,
    // or a lane could spend more than was agreed to just by publishing a
    // roomier cap.
    const authorised = (9n * 10n ** 17n * 10050n) / 10000n;
    assert.equal(d.args[3], authorised, 'amountIn is not clamped to the authorised slippage');
    assert.ok(d.args[3] < 95n * 10n ** 16n, 'the lane cap governed instead of the user slippage');
    assert.ok(d.args[3] < 10n ** 18n, 'the ceiling is not cheaper than the chain');
    assert.equal(d.args[1].toLowerCase(), ROUTER.toLowerCase(), 'spender is not the allowanceTarget');
    p.close();
  });

  test('sell-side-only lanes sit out an exact-output quote', async () => {
    const chain = chainWithQuote();
    wire(chain, [lane('1inch', 'https://s.example', FILL)]);
    chain.lanes = { 's.example': { dstAmount: '1', tx: { to: ROUTER, data: '0x' } } };
    const p = await loadPage({ chain, url: 'https://' + SELF + '.1.w3link.io/', hash: 'token=ETH&out=USDC' });
    await p.connect();
    await p.typeAmount('outAmt', '3000');
    assert.ok(!(chain.httpLog || []).some(h => String(h.url).includes('s.example')),
      'a sell-side-only lane was asked for an exact-output quote');
    p.close();
  });

  // The bold row must be the venue the quote is BUILT FROM. When a pin is
  // active that is not the best floor, and bolding the best one tells the
  // reader they are getting something they are not.
  test('the marked row follows the venue actually used, not the best floor', async () => {
    const chain = chainWithQuote();
    wire(chain, [lane('0x', 'https://a.example', FILL), lane('ParaSwap', 'https://b.example', FILL)]);
    chain.lanes = {
      'a.example': { buyAmount: (3600n * USDC).toString(), transaction: { to: ROUTER, data: '0x1234' } },
      'b.example/prices': { priceRoute: { destAmount: (3400n * USDC).toString(), srcDecimals: 18, destDecimals: 6, tokenTransferProxy: ROUTER } },
      'b.example/transactions/1': { to: ROUTER, data: '0x1234' },
    };
    const p = await open(chain);
    await p.typeAmount('amt', '1');

    // No pin: the best floor is also what is used, so it is marked.
    let marked = p.$('rankBox').querySelector('i.w');
    assert.match(marked.textContent, /0x/, `unpinned, the used venue was not marked: ${marked.textContent}`);

    // Pin the weaker one. The mark must move to it.
    const para = [...p.$('rankBox').querySelectorAll('i')].find(r => r.textContent.includes('ParaSwap'));
    para.onclick();
    await p.settle();

    marked = p.$('rankBox').querySelector('i.w');
    assert.match(marked.textContent, /ParaSwap/,
      `pinned ParaSwap but the list marks ${marked.textContent} as the one in use`);
    p.close();
  });

  test('a lane that cannot beat the on-chain floor does not win', async () => {
    // The whole point of comparing floors: a lane quoting barely above the
    // chain still loses, because its floor is below the chain's floor.
    const chain = chainWithQuote();
    wire(chain, [lane('0x', 'https://weak.example', FILL)]);
    chain.lanes = {
      'weak.example': { buyAmount: '3000000001', transaction: { to: ROUTER, data: '0x1234' } },
    };
    const p = await open(chain);
    await p.typeAmount('amt', '1');
    assert.equal(p.value('outAmt'), '3000', 'a lane won on a quote that its floor could not back');
    p.close();
  });
});
