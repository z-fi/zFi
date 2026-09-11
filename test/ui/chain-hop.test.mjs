/**
 * What a chain switch has to leave behind.
 *
 * Three of the page's switch paths do not reload — connect(), the boot wallet
 * probe, and a #chain= deep link — so anything derived from the chain that
 * survives setChain() is read back under the next chain's badge. The sharp end
 * is the solver pin: loadSolvers() memoises the fill address, and mainnet's
 * has no code on either L2, so a route built from a stale pin would send ether
 * to an address that cannot receive it. The block number is the same shape one
 * level down — chain heights differ by tens of millions, so a carried-over tag
 * prices the swap at a block that is either long past or does not exist yet.
 *
 * jsdom fires hashchange on hash assignment, so a walletless page can be driven
 * across all three chains inside one lifetime, which is the only way to observe
 * any of this.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, loadPage, closeAllPages, selectorOf } from './harness.mjs';

after(closeAllPages);

const HOPS = [8453, 4663, 1];

const hopTo = async (p, id) => {
  p.window.location.hash = `#chain=${id}&token=ETH&out=WETH`;
  await p.waitFor(() => p.window.eval('CHAIN_ID') === id, { label: `hop to ${id}` });
  await p.settle();
};

describe('a walletless chain hop', () => {
  test('rebinds every per-chain address, twice over', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    await p.settle();
    assert.equal(p.window.eval('CHAIN_ID'), 1, 'starts on Ethereum');

    for (const id of HOPS) {
      await hopTo(p, id);
      const w = p.window;
      assert.equal(w.eval('WETH'), w.eval(`CHAINS[${id}].wrapped`), `${id}: WETH follows the chain`);
      assert.equal(w.eval('V4PORT').toLowerCase(), w.eval(`CHAINS[${id}].v4port||ZERO`).toLowerCase(), `${id}: v4 port follows`);
      assert.equal(w.eval('V4LENS').toLowerCase(), A.V4LENS.toLowerCase(), `${id}: the one CREATE3 v4 lens`);
      assert.equal(w.eval('TOKENLIST').toLowerCase(), A.TOKENLIST.toLowerCase(), `${id}: the one registry, read from mainnet`);
      const boards = w.eval('JSON.stringify([SB2,SWAPBOL,DUTCH,ORDERBOL,FLOOR,PROUTE])');
      const expect = w.eval(`JSON.stringify((b=>[b.sb||ZERO,b.sw||ZERO,b.du||ZERO,b.ob||ZERO,b.fl||ZERO,b.pr||ZERO])(${id}===1?MB:L2B))`);
      assert.equal(boards, expect, `${id}: the board set is the chain's own`);
      assert.equal(w.eval('PLAUNCH') === A.ZERO, id !== 1, `${id}: the launcher is mainnet-only`);
    }
    p.close();
  });

  test('drops the memoised solver pin rather than aim an L2 route at mainnet', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    await p.settle();
    // Prime the memo the way a quote on mainnet would.
    p.window.eval('solversJob=Promise.resolve();solverFill=CHAINS[1].fill;solverExec=CHAINS[1].exec;solverLanes=[{name:"x"}]');
    assert.equal(p.window.eval('solverFill'), p.window.eval('CHAINS[1].fill'));

    await hopTo(p, 8453);
    const w = p.window;
    assert.equal(w.eval('solversJob'), null, 'the memoised job is dropped');
    assert.equal(w.eval('solverFill'), null, 'the fill pin is not carried onto Base');
    assert.equal(w.eval('solverExec'), null, 'nor the exec pin');
    assert.equal(w.eval('solverLanes'), null, 'nor the lane set');
    assert.equal(w.eval('SOLVER_FILL_PIN').toLowerCase(), w.eval('CHAINS[8453].fill').toLowerCase(),
      'and the chain table pin is Base\'s');
    p.close();
  });

  test('drops the cached block number, which is not comparable across chains', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    await p.settle();
    p.window.eval('bnVal="0x18b8f28";bnAt=Date.now()');
    assert.equal(p.window.eval('bnVal'), '0x18b8f28');
    await hopTo(p, 4663);
    assert.equal(p.window.eval('bnVal'), '', 'a mainnet height never tags a Robinhood read');
    assert.equal(p.window.eval('bnAt'), 0);
    p.close();
  });

  test('clears the address-keyed caches and invalidates in-flight reads', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    await p.settle();
    const w = p.window;
    w.eval(`metaCache.set("${A.ZERO}",{sym:"X",dec:9});candCache["1:a:b"]={at:Date.now()};chCache["a:b"]=[1]`);
    const before = w.eval('seq');
    await hopTo(p, 8453);
    assert.equal(w.eval('metaCache.size'), 0, 'token metadata does not cross chains');
    assert.equal(w.eval('Object.keys(candCache).length'), 0, 'nor order-book candidates');
    assert.equal(w.eval('Object.keys(chCache).length'), 0, 'nor chart series');
    assert.ok(w.eval('seq') > before, 'a quote in flight can no longer paint');
    assert.equal(w.eval('last'), null, 'and no quote outlives the chain it was made on');
    p.close();
  });

  test('keeps the batch calibration and the remembered pair per chain', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    await p.settle();
    assert.equal(p.window.eval('MC3_KEY()'), 'zswap:mc3');
    assert.equal(p.window.eval('LAST_PAIR()'), 'zswap:pair');
    await hopTo(p, 4663);
    assert.equal(p.window.eval('MC3_KEY()'), 'zswap:mc3:4663', 'one node\'s batch limit is not another\'s');
    assert.equal(p.window.eval('LAST_PAIR()'), 'zswap:pair:4663', 'a remembered pair belongs to its chain');
    assert.equal(p.window.eval('KEEP()'), 'zswap:deep:4663');
    p.close();
  });
});

describe('what each chain prices in', () => {
  test('names its own money, so a stable pair is not drawn upside down', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    await p.settle();
    const w = p.window;
    const usdc1 = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';
    assert.equal(w.eval(`moneyRank("${usdc1}")`), 2, 'mainnet USDC is money on mainnet');

    await hopTo(p, 8453);
    const usdcB = '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913';
    assert.equal(w.eval(`moneyRank("${usdcB}")`), 2, 'Base USDC is money on Base');
    assert.equal(w.eval(`moneyRank("${usdc1}")`), 0, 'and mainnet USDC is just a token there');
    assert.equal(w.eval(`chNaturalInv([{addr:"${usdcB}"},{addr:ZERO}])`), true,
      'so a USDC/ETH chart opens as USDC per ETH');

    await hopTo(p, 4663);
    assert.equal(w.eval('moneyRank("0x5fc5360d0400a0fd4f2af552add042d716f1d168")'), 2, 'USDG is Robinhood\'s numeraire');
    p.close();
  });
});

describe('features that exist on one chain only', () => {
  test('are withheld off it rather than offered and left to fail', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    await p.settle();
    assert.equal(p.visible('wn'), true, 'names are offered on mainnet');
    assert.equal(p.visible('pv'), true, 'so is the private bridge');

    for (const id of [8453, 4663]) {
      await hopTo(p, id);
      assert.equal(p.visible('wn'), false, `${id}: names are not offered`);
      assert.equal(p.visible('pv'), false, `${id}: the bridge is not offered`);
      assert.equal(p.visible('ln'), false, `${id}: launching is not offered`);
      assert.equal(p.window.eval('wnMode'), false, `${id}: and no mode is left on`);
      assert.equal(p.window.eval('pvMode'), false);
    }
    p.close();
  });

  test('leaves the curated read list alone off mainnet', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    await p.settle();
    await hopTo(p, 4663);
    const pool = p.window.eval('JSON.stringify(rpcPool)');
    p.window.eval('curatedTry=0');
    await p.window.eval('loadCurated()');
    assert.equal(p.window.eval('JSON.stringify(rpcPool)'), pool,
      'no Ethereum node is spliced into a Robinhood read pool');
    p.close();
  });
});

describe('a v4 swap on an L2', () => {
  // The port is one of the few addresses that genuinely differs per chain:
  // mainnet has its own build, Base and Robinhood share a second one. Nothing
  // asserted the page picks the right one, because the mock only ever answered
  // for mainnet's.
  const HOOK = '0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444';
  const V4SWAP = '48e6f730';
  const ETH = 10n ** 18n;

  const onChain = async id => {
    const { MockChain, fixedRateQuoter } = await import('./harness.mjs');
    const chain = new MockChain({ chainId: '0x' + id.toString(16) });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
    chain.v4Quote = ({ amountIn }) => amountIn * 30_000n / 10n ** 12n;
    const p = await loadPage({ chain, hash: null });
    const usdc = p.window.eval('TOKENS[TOKENS.findIndex(t=>t.sym==="USDC"||t.sym==="USDG")].addr');
    p.window.eval(`TOKENS[TOKENS.findIndex(t=>t.addr==="${usdc}")].v4=[{c0:"${A.ZERO}",c1:"${usdc}",fee:0,ts:60,hooks:"${HOOK}"}]`);
    await p.connect({ pin: false });
    return { p, usdc };
  };

  for (const [id, name] of [[8453, 'Base'], [4663, 'Robinhood']]) {
    test(`${name} aims at its own port, not mainnet's`, async () => {
      const { p, usdc } = await onChain(id);
      p.pickToken('fromSel', 'ETH');
      p.pickToken('toSel', p.window.eval(`TOKENS.find(t=>t.addr==="${usdc}").sym`));
      await p.settle();
      await p.typeAmount('amt', '1');
      p.click('swap');
      await p.settle();

      const tx = p.chain.lastSent;
      assert.ok(tx, `${name} sent something — otherwise this asserts nothing`);
      assert.equal(selectorOf(tx.data), V4SWAP, 'the hooked pool won, so it is a V4Port swap');
      assert.equal(tx.to.toLowerCase(), A.V4PORT_L2.toLowerCase(), `${name} uses the L2 port`);
      assert.notEqual(tx.to.toLowerCase(), A.V4PORT.toLowerCase(), 'and never mainnet\'s');
      assert.equal(p.window.eval('V4PORT').toLowerCase(), A.V4PORT_L2.toLowerCase(),
        `${name} binds the L2 port`);
      p.close();
    });
  }
});

describe('the venue labels', () => {
  // SOURCES is only read as SOURCES[ordinal], so a label that names a venue the
  // chain's quoter cannot emit is inert today — but it reads as if the venue
  // were live, and SRC_CURVE keys real exact-out behaviour off the same table.
  test('index the ordinals each chain\'s quoter can actually return', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    await p.settle();
    const w = p.window;

    // Ordinals every quoter shares, by construction: the L2 enums were written
    // to match mainnet's so a `source` means one thing everywhere.
    const shared = { 0: 'UniV2', 3: 'UniV3', 4: 'UniV4' };
    for (const id of [1, 8453, 4663]) {
      const src = w.eval(`JSON.stringify(CHAINS[${id}].sources)`);
      const arr = JSON.parse(src);
      for (const [i, label] of Object.entries(shared)) {
        assert.equal(arr[i], label, `chain ${id}: ordinal ${i} is ${label}`);
      }
      assert.equal(arr[w.eval('SRC_PRECISION')], 'Precision', `chain ${id}: Precision sits at its constant`);
    }

    // Base's ordinal 5 is AERO_CL, not Curve. Leaving SRC_CURVE at its default
    // would have suppressed every Slipstream exact-out route.
    assert.equal(w.eval('CHAINS[8453].curve'), -1, 'Base names no Curve ordinal');
    assert.equal(w.eval('CHAINS[8453].sources[5]'), 'AeroCL', 'because 5 is Slipstream there');
    // Mainnet and Robinhood share the enum, so 5 really is Curve on both.
    assert.equal(w.eval('CHAINS[1].sources[5]'), 'Curve');
    assert.equal(w.eval('CHAINS[4663].sources[5]'), 'Curve');
    p.close();
  });

  test('never suppress exact-out on a chain that has no Curve', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    await p.settle();
    await hopTo(p, 8453);
    // exactOutSafe rejects a quote whose legs include SRC_CURVE. With -1 that
    // can never match, so a Slipstream exact-out route is allowed through.
    assert.equal(p.window.eval('SRC_CURVE'), -1);
    assert.equal(p.window.eval('[0,3,4,5].includes(SRC_CURVE)'), false,
      'no real Base ordinal collides with the Curve sentinel');
    p.close();
  });
});

describe('Deepstate', () => {
  test('stops being consulted the moment the page leaves Robinhood', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    await p.settle();
    const asked = () => p.chain.calls.filter(c => c.to.toLowerCase() === A.DEEPLENS.toLowerCase()).length;

    await hopTo(p, 4663);
    const n0 = asked();
    await p.window.eval('deepQuote(TOKENS[1].addr,TOKENS[2].addr,1n)');
    assert.ok(asked() > n0, 'on Robinhood the lens is actually consulted');

    await hopTo(p, 8453);
    const n1 = asked();
    const got = await p.window.eval('deepQuote(TOKENS[1].addr,TOKENS[2].addr,1n)');
    assert.equal(got, null, 'off Robinhood it refuses');
    assert.equal(asked(), n1, 'and issues no read at all');
    p.close();
  });
});
