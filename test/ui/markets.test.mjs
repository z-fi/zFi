/**
 * Markets: the parimutuel PM singleton as a zSwap mode.
 *
 * The page decodes PM's getMarkets page (an array of tuples that each carry a
 * dynamic string) by hand, so the list is checked against ABI the test encodes
 * independently. Every write is checked at the calldata level: the selector,
 * the market id, the side, the recipient and the slippage floor, since a
 * rendered line cannot show that a bet went to the wrong side.
 */
import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { loadPage, MockChain, A, closeAllPages, domainSeparator } from './harness.mjs';

after(closeAllPages);

const PM = '0x0000003b32cdd39bc950e56093df98af220ab5c5';
const WST = '0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0';
const BOLD = '0x6440f144b7e50d6a8439336510312d2f54beb01d';
const ONE = 10n ** 18n;
const now = () => Math.floor(Date.now() / 1000);

const w = (v) => BigInt(v).toString(16).padStart(64, '0');
const aw = (a) => a.toLowerCase().replace(/^0x/, '').padStart(64, '0');
const word = (hex, i) => BigInt('0x' + hex.slice(10 + i * 64, 74 + i * 64));

/** ABI for PM.getMarkets: (MarketView[] page, uint256 next). */
function marketsRet(ms) {
  const elems = ms.map((m) => {
    const d = Buffer.from(m.d, 'utf8').toString('hex');
    return [m.id, 0, 0, m.o, m.c, m.f ?? 0, m.x ?? 0, m.l ?? 0, m.cc ? 1 : 0, m.s ?? 0, m.y, m.n, m.p, m.w ?? 0, 15 * 32]
      .map((v, i) => (i === 1 ? aw(m.r) : i === 2 ? aw(m.a) : w(v))).join('')
      + w(d.length / 2) + d.padEnd(Math.ceil(d.length / 64) * 64, '0');
  });
  let cur = ms.length * 32;
  const offs = elems.map((e) => { const o = w(cur); cur += e.length / 2; return o; });
  return '0x' + w(64) + w(0) + w(ms.length) + offs.join('') + elems.join('');
}

/** ABI for PM.positions: (uint256[] yes, uint256[] no, uint256[] claimable), in the order asked. */
const posRet = (rows) => {
  const arr = (k) => w(rows.length) + rows.map((r) => w(r[k])).join('');
  const [a, b, c] = [arr(0), arr(1), arr(2)];
  return '0x' + w(96) + w(96 + a.length / 2) + w(96 + (a.length + b.length) / 2) + a + b + c;
};

const RAIN = 0xa0n, BALL = 0xb0n, STABLE = 0xc0n;

function pmChain({ held = {} } = {}) {
  const c = new MockChain();
  c.setNative(A.ACCOUNT, 100n * ONE);
  const t = now();
  const markets = [
    { id: RAIN, d: 'Will it rain in Lisbon on Friday?', r: A.OTHER, a: WST, o: t - 3600, c: t + 3 * 86400, y: 3n * ONE, n: ONE, p: 4n * ONE, cc: true },
    { id: BALL, d: 'Does the home side win the final?', r: A.OTHER, a: A.ZERO, o: t - 9 * 86400, c: t - 86400, s: 1, y: 2n * ONE, n: 2n * ONE, p: 4n * ONE, w: 2n * ONE },
    { id: STABLE, d: 'BOLD above peg at month end', r: A.ACCOUNT, a: BOLD, o: t - 60, c: t + 20 * 86400, y: 500n * ONE, n: 1500n * ONE, p: 2000n * ONE },
  ];
  c.answer(PM, 'ec979082', '0x' + w(markets.length));
  c.answer(PM, '80968d48', (d) => (word(d, 0) === 0n ? marketsRet(markets) : marketsRet([])));
  c.answer(PM, 'afa8f792', (d) => {
    const n = Number(word(d, 2)), ids = Array.from({ length: n }, (_, i) => word(d, 3 + i));
    return posRet(ids.map((id) => held[id] ?? [0n, 0n, 0n]));
  });
  c.answer(PM, '124d6efc', (d) => '0x' + w(word(d, 2)) + w(word(d, 2) * 2n));
  c.answer(PM, 'ffecc085', '0x' + w(0));
  c.answer(WST, 'bb2952fc', (d) => '0x' + w((word(d, 0) * 8n) / 10n));
  for (const sel of ['c2b5b4c8', '28ccbb45', '2a304886', 'b390d8b5', '6f406fa1', 'ddd5e1b2', '0fc95438', 'ae418095', '52a34b05', '5ea2145b'])
    c.answer(PM, sel, '0x' + w(1));
  return c;
}

async function openMarkets(chain, hash) {
  const p = await loadPage({ chain, ...(hash ? { hash } : {}) });
  await p.connect();
  if (!p.$('mkPanel').classList.contains('hide')) return p;
  p.click('mk');
  await p.waitFor(() => p.$('mkList').querySelectorAll('.mkr').length > 0, { label: 'markets listed' });
  return p;
}

const rows = (p) => [...p.$('mkList').querySelectorAll('.mkr')].map((r) => r.textContent);
const pick = async (p, id) => {
  p.$('mkList').querySelector(`.mkr[data-k="${id}"]`).click();
  await p.waitFor(() => !p.$('mkDet').classList.contains('hide'), { label: 'detail open' });
};
const p_wait = (chain, label) => new Promise((res, rej) => { const t0 = Date.now(); const tick = () => chain.sentTo(PM).length ? res() : Date.now() - t0 > 15000 ? rej(Error('timed out: ' + label)) : setTimeout(tick, 25); tick(); });
const act = (p, a) => p.$('mkActs').querySelector(`[data-a="${a}"]`);

test('markets mode', async (t) => {
  await t.test('lists open markets by liquidity, searches text, and filters settled', async () => {
    const p = await openMarkets(pmChain());
    assert.equal(p.$('mk').getAttribute('aria-pressed'), 'true');
    assert.ok(p.$('swap').classList.contains('hide'), 'the swap button yields to the markets panel');
    const open = rows(p);
    assert.equal(open.length, 2, 'the settled market is not in Open');
  });

  await t.test('ranks by USD liquidity and matches every search term', async () => {
    const p = await openMarkets(pmChain());
    const open = rows(p);
    assert.match(open[0], /rain in Lisbon/, '4 wstETH (≈ $8k at the fallback) outranks 2,000 BOLD');
    assert.match(open[0], /YES 75%/);
    p.type('mkFind', 'lisbon friday');
    await p.waitFor(() => rows(p).length === 1, { label: 'search narrows' });
    assert.match(rows(p)[0], /rain in Lisbon/);
    p.type('mkFind', 'lisbon peg');
    await p.waitFor(() => /No markets match/.test(p.$('mkList').textContent), { label: 'all terms must match' });
    p.type('mkFind', '');
    p.$('mkChips').querySelector('[data-f="done"]').click();
    await p.waitFor(() => rows(p).length === 1, { label: 'settled filter' });
    assert.match(rows(p)[0], /home side/);
    assert.match(rows(p)[0], /YES won/);
  });

  await t.test('buys YES with ETH in a wstETH market through betETH and the Lido route', async () => {
    const chain = pmChain();
    const p = await openMarkets(chain);
    await pick(p, RAIN);
    assert.deepEqual([...p.$('mkPay').options].map((o) => o.textContent), ['ETH', 'wstETH']);
    p.type('mkAmt', '1');
    await p.waitFor(() => /Wins/.test(p.$('mkQ').textContent), { label: 'quote' });
    act(p, 'yes').click();
    await p.waitFor(() => chain.sentTo(PM).length === 1, { label: 'bet sent' });
    const tx = chain.sentTo(PM)[0];
    assert.equal(BigInt(tx.value), ONE, 'the whole ETH amount rides along');
    assert.equal(tx.data.slice(2, 10), 'c2b5b4c8', 'betETH');
    assert.equal(word(tx.data, 0), RAIN);
    assert.equal(word(tx.data, 1), 1n, 'YES');
    assert.equal('0x' + tx.data.slice(10 + 2 * 64 + 24, 10 + 3 * 64), A.ACCOUNT.toLowerCase());
    assert.equal(word(tx.data, 3), (8n * ONE / 10n) * 9950n / 10000n, 'floor = quoted shares less 0.5% slippage');
    assert.equal(word(tx.data, 4), 0xa0n, 'route offset');
    assert.equal(word(tx.data, 5), 0n, 'empty route: Lido at the protocol rate');
  });

  await t.test('bets a token it already approved straight through bet()', async () => {
    const chain = pmChain();
    chain.setErc20(BOLD, A.ACCOUNT, 1000n * ONE);
    chain.setAllowance(BOLD, A.ACCOUNT, PM, 1000n * ONE);
    const p = await openMarkets(chain);
    await pick(p, STABLE);
    assert.deepEqual([...p.$('mkPay').options].map((o) => o.textContent), ['BOLD']);
    p.type('mkAmt', '250');
    await p.waitFor(() => /Wins/.test(p.$('mkQ').textContent), { label: 'quote' });
    act(p, 'no').click();
    await p.waitFor(() => chain.sentTo(PM).length === 1, { label: 'bet sent' });
    const tx = chain.sentTo(PM)[0];
    assert.equal(tx.data.slice(2, 10), '28ccbb45', 'bet');
    assert.equal(word(tx.data, 1), 0n, 'NO');
    assert.equal(word(tx.data, 2), 250n * ONE);
    assert.equal(BigInt(tx.value || 0), 0n);
  });

  await t.test('claims a settled win and shows it under Mine', async () => {
    const chain = pmChain({ held: { [BALL]: [ONE, 0n, 2n * ONE] } });
    const p = await openMarkets(chain);
    p.$('mkChips').querySelector('[data-f="mine"]').click();
    await p.waitFor(() => rows(p).some((r) => /home side/.test(r)), { label: 'mine lists the held market' });
    assert.ok(rows(p).some((r) => /BOLD above peg/.test(r)), 'markets you resolve are yours too');
    await pick(p, BALL);
    assert.match(act(p, 'claim').textContent, /Claim 2 ETH/);
    act(p, 'claim').click();
    await p.waitFor(() => chain.sentTo(PM).length === 1, { label: 'claim sent' });
    const tx = chain.sentTo(PM)[0];
    assert.equal(tx.data.slice(2, 10), 'ddd5e1b2');
    assert.equal(word(tx.data, 0), BALL);
  });

  await t.test('creates a market with a .wei resolver and the chosen terms', async () => {
    const chain = pmChain();
    chain.names.set('alice.wei', A.OTHER);
    const p = await openMarkets(chain);
    p.click('mkGo');
    await p.waitFor(() => !p.$('mkForm').classList.contains('hide'), { label: 'form open' });
    assert.equal(p.$('mkGo').textContent, 'Create market');
    p.type('mkDesc', 'Will the merge ship by June?');
    p.type('mkRes', 'alice.wei');
    await p.waitFor(() => /→ 0x/i.test(p.$('mkResEl').textContent), { label: 'name resolves' });
    p.select('mkAsset', BOLD);
    p.select('mkClose', '86400');
    p.type('mkExit', '2');
    p.type('mkLate', '10');
    const t0 = now();
    p.click('mkGo');
    await p.waitFor(() => chain.sentTo(PM).length === 1, { label: 'create sent' });
    const d = chain.sentTo(PM)[0].data;
    assert.equal(d.slice(2, 10), '6f406fa1', 'createMarket');
    assert.equal(word(d, 0), 0xe0n, 'string offset');
    assert.equal('0x' + d.slice(10 + 64 + 24, 10 + 128), A.OTHER.toLowerCase(), 'resolver from the name');
    assert.equal('0x' + d.slice(10 + 128 + 24, 10 + 192), BOLD, 'pot asset');
    const close = Number(word(d, 3));
    assert.ok(close >= t0 + 86400 - 5 && close <= t0 + 86400 + 5, 'closes in a day');
    assert.equal(word(d, 4), 1n, 'early close on by default');
    assert.equal(word(d, 5), 200n, 'exit tax 2%');
    assert.equal(word(d, 6), 1000n, 'late tax 10%');
    const len = Number(word(d, 7));
    assert.equal(Buffer.from(d.slice(10 + 8 * 64, 10 + 8 * 64 + len * 2), 'hex').toString(), 'Will the merge ship by June?');
  });

  await t.test('refuses a resolver name that does not resolve', async () => {
    const chain = pmChain();
    const p = await openMarkets(chain);
    p.click('mkGo');
    p.type('mkDesc', 'Anything');
    p.type('mkRes', 'nobody.wei');
    p.click('mkGo');
    await p.waitFor(() => /not registered/.test(p.$('stat').textContent), { label: 'refused' });
    assert.equal(chain.sentTo(PM).length, 0);
  });

  await t.test('a pm link opens that market, and other modes switch markets off', async () => {
    const p = await openMarkets(pmChain(), `pm=${STABLE}`);
    await p.waitFor(() => /BOLD above peg/.test(p.$('mkT').textContent), { label: 'deep link selects' });
    p.click('wn');
    await p.settle();
    assert.ok(p.$('mkPanel').classList.contains('hide'), 'names mode takes over');
    assert.equal(p.$('mk').getAttribute('aria-pressed'), 'false');
  });

  const tokenBet = async (chain) => {
    chain.setErc20(BOLD, A.ACCOUNT, 1000n * ONE);
    const p = await openMarkets(chain);
    await pick(p, STABLE);
    p.type('mkAmt', '100');
    await p.waitFor(() => /Wins/.test(p.$('mkQ').textContent), { label: 'quote' });
    act(p, 'yes').click();
    return p;
  };

  await t.test('signs an EIP-2612 permit for PM and bets in one transaction', async () => {
    const chain = pmChain();
    chain.setToken(BOLD, { symbol: 'BOLD', decimals: 18, name: 'BOLD Stablecoin', domainSeparator: domainSeparator('BOLD Stablecoin', '1', BOLD) });
    await tokenBet(chain);
    await p_wait(chain, 'betWithPermit sent');
    const tx = chain.sentTo(PM)[0];
    assert.equal(tx.data.slice(2, 10), '2a304886', 'betWithPermit');
    assert.equal(word(tx.data, 2), 100n * ONE);
    assert.equal(chain.sentTo(BOLD).length, 0, 'no approve transaction');
    const td = chain.signed.at(-1).typedData;
    assert.equal(td.primaryType, 'Permit');
    assert.equal(td.message.spender.toLowerCase(), PM, 'the permit names PM, not the router');
    assert.equal(BigInt(td.message.value), 100n * ONE);
    assert.equal(word(tx.data, 5), BigInt(td.message.deadline), 'deadline carried');
  });

  await t.test('falls back to a Permit2 signature for a token without permit', async () => {
    const chain = pmChain();
    chain.setToken(BOLD, { symbol: 'BOLD', decimals: 18, name: 'BOLD Stablecoin' });
    chain.setAllowance(BOLD, A.ACCOUNT, A.PERMIT2, 2n ** 256n - 1n);
    await tokenBet(chain);
    await p_wait(chain, 'betWithPermit2 sent');
    const tx = chain.sentTo(PM)[0];
    assert.equal(tx.data.slice(2, 10), 'b390d8b5', 'betWithPermit2');
    assert.equal(word(tx.data, 7), 0x100n, 'signature offset');
    const td = chain.signed.at(-1).typedData;
    assert.equal(td.primaryType, 'PermitTransferFrom');
    assert.equal(td.message.spender.toLowerCase(), PM);
    assert.equal(td.message.permitted.token.toLowerCase(), BOLD);
    assert.equal(word(tx.data, 5), BigInt(td.message.nonce), 'nonce carried');
  });

  await t.test('batches approve + bet when the wallet can, with no signature', async () => {
    const chain = pmChain();
    chain.setToken(BOLD, { symbol: 'BOLD', decimals: 18, name: 'BOLD Stablecoin' });
    chain.capabilities = { '0x1': { atomic: { status: 'ready' } } };
    await tokenBet(chain);
    await p_wait(chain, 'batch sent');
    const b = chain.batches.at(-1);
    assert.ok(b, 'one wallet_sendCalls');
    const calls = b.calls ?? b[0]?.calls ?? b;
    assert.equal(calls.length, 2);
    assert.equal(calls[0].to.toLowerCase(), BOLD);
    assert.equal(calls[0].data.slice(2, 10), '095ea7b3', 'approve');
    assert.equal(calls[1].to.toLowerCase(), PM);
    assert.equal(calls[1].data.slice(2, 10), '28ccbb45', 'bet');
    assert.equal(chain.signed.length, 0);
  });
});
