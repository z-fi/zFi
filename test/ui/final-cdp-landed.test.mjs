import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { A, MockChain, loadPage, closeAllPages, CP_BLOCK } from './harness.mjs';
after(closeAllPages);
const F = JSON.parse(fs.readFileSync(new URL('../fixtures/confidential.json', import.meta.url), 'utf8'));
const D = F.cdp, C = F.cbtc, POOL = F.pool, ENGINE = '0x000000003f608BDdF0ca45934003ffb9DbDF70DB';
const B0 = CP_BLOCK + 0x100, u256 = v => BigInt(v).toString(16).padStart(64, '0');
const CBTC = '0x62a20d98fc1cd20289621d1315294cb8772f934d822e404b71e1f471cf0679c8';
const fp = createHash('sha256').update('zswap-cp-v1:' + F.seed).digest('hex').slice(0, 16);
const KEY = { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: F.seed };

test('a loan whose self-settle landed but whose wait timed out reconciles to open', async () => {
  const chain = new MockChain();
  chain.blockNumber = '0x' + (B0 + 0x8).toString(16);
  chain.setNative(A.ACCOUNT, 10n * 10n ** 18n);
  chain.answer(POOL, '9fda5b66', '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
  chain.answer(POOL, '0be4f422', '0x' + u256(0));
  chain.answer(ENGINE, '2c4e722e', '0x' + u256(10n ** 27n));
  chain.relay = { status: { status: 'proven' } };
  chain.lanes = {};
  // the engine's CdpMinted for this exact position: the settle landed
  chain.logs.push({ address: ENGINE, blockNumber: '0x' + (B0 + 0x6).toString(16), logIndex: '0x0', transactionHash: '0x' + 'ab'.repeat(32),
    topics: ['0x232c7d098ca44092999087e6ee530a2171f95f9ecb1caa363f6dcf448fb7dd57', D.positionLeaf], data: '0x' + u256(D.debtValue) + u256(7676504869n) });
  // the record cpCdpSettle leaves when settle() throws after sendTx (tx not mined in time / wallet moved network)
  const rec = { i: 0, v: String(D.debtValue), cv: '100000', rate: '0x' + u256(10n ** 27n), leaf: D.positionLeaf, memo: '0x', at: 1,
    job: '0xjob', js: 'proven', rb: 'https://api.tacit.finance', self: 1, pv: '0x' + D.positionLeaf.slice(2), pr: '0x01', stx: '0x' + 'ab'.repeat(32) };
  const storage = { ...KEY, ['zswap:cpc:' + fp]: JSON.stringify([rec]),
    ['zswap:cpn:' + fp]: JSON.stringify([{ i: -1, v: '100000', a: CBTC, s: '0x' + '00'.repeat(32), b: C.blinding, z: 1, at: 0 }]) };
  const p = await loadPage({ chain, storage });
  await p.connect();
  p.click('pv');
  await p.settle();
  p.click('pvGo');
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'unlock' });
  await p.waitFor(() => /cUSD against/.test(p.text('pvList')), { label: 'the loan row', timeout: 20000 });
  p.click(p.$('pvKey').querySelector('button[data-a="recover"]'));
  await p.waitFor(() => !/Scanning/.test(p.text('stat')), { label: 'recover', timeout: 20000 });
  p.window.eval('pvTick=0'); p.window.eval('pvRefresh()');
  await p.settle();
  console.log('ROW:', p.text('pvList'));
  assert.match(p.text('pvList'), /repay on tacit\.finance/, 'the position is open on chain');
  p.close();
});
