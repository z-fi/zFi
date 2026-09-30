import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { A, MockChain, loadPage, closeAllPages, CP_BLOCK } from './harness.mjs';
after(closeAllPages);
const F = JSON.parse(fs.readFileSync(new URL('../fixtures/confidential.json', import.meta.url), 'utf8'));
const POOL = F.pool, B0 = CP_BLOCK + 0x100, u256 = v => BigInt(v).toString(16).padStart(64, '0');
const fp = createHash('sha256').update('zswap-cp-v1:' + F.seed).digest('hex').slice(0, 16);
const KEY = { ['zswap:cpk:' + A.ACCOUNT.toLowerCase()]: F.seed };

test('a paid request whose self-settle landed but whose wait timed out stops offering settle', async () => {
  const chain = new MockChain();
  chain.blockNumber = '0x' + (B0 + 0x8).toString(16);
  chain.setNative(A.ACCOUNT, 10n * 10n ** 18n);
  chain.answer(POOL, '9fda5b66', '0x' + u256(1) + u256(0) + u256(10n ** 10n) + F.ethAssetId.slice(2) + u256(0) + u256(18));
  chain.answer(POOL, '0be4f422', '0x' + u256(0));
  chain.answer(POOL, '7da9874f', '0x' + u256(2));   // depositStatus: consumed — the settle landed
  chain.relay = { status: { status: 'proven' } };
  chain.lanes = {};
  const dep = '0x' + 'cd'.repeat(32);
  const n = { p: 1, i: -1, v: '1000000', dep, at: 1, op: {}, memo: '0x', tx: '0x' + 'ef'.repeat(32), job: '0xjob', js: 'proven', rb: 'https://api.tacit.finance', self: 1, pv: '0x' + dep.slice(2), pr: '0x01' };
  const p = await loadPage({ chain, storage: { ...KEY, ['zswap:cpn:' + fp]: JSON.stringify([n]) } });
  await p.connect();
  p.click('pv');
  await p.settle();
  p.click('pvGo');
  await p.waitFor(() => /Key unlocked/.test(p.text('pvKey')), { label: 'unlock' });
  await p.waitFor(() => /paid/.test(p.text('pvList')), { label: 'the row', timeout: 20000 });
  p.click(p.$('pvList').querySelector('button[data-a="wrapsend"]'));
  await p.settle(); await new Promise(r=>setTimeout(r,500)); await p.settle();
  console.log('ROW:', p.text('pvList'), '| buttons:', [...p.$('pvList').querySelectorAll('button')].map(b => b.dataset.a).join(','));
  assert.ok(!p.$('pvList').querySelector('button[data-a="wrapsend"]'), 'no settle offered for a deposit the pool already consumed');
  p.close();
});
