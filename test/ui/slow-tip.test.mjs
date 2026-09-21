/**
 * The keeper tip, on every chain that offers auto-claim.
 *
 * A tipped lock is claimed by whoever sends `gate.claim` once it matures, at a
 * gas price nobody knows when the lock is made. So the tip is `TIP_GAS` priced
 * at the higher of the node's gas price and the peak base fee it reports over
 * recent blocks, plus the L1 data fee on a rollup, and the whole is doubled.
 * `test/SlowTipGas.t.sol` pins `TIP_GAS` against a real claim on each chain.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const TIP_GAS = 180000n;
const BASE = '0x2105', RH = '0x1237';

/** Connected, on the Send tab, with a one-day lock and auto-claim ticked. */
async function tipOn(chainId, prep = () => {}) {
  const chain = new MockChain({ chainId });
  chain.setNative(A.ACCOUNT, 10n ** 19n);
  prep(chain);
  const l2 = chainId !== '0x1';
  const p = await loadPage(l2 ? { chain, hash: null } : { chain });
  await p.connect(l2 ? { pin: false } : undefined);
  p.click('tabSend');
  await p.settle();
  p.select('dly', '86400');
  await p.settle();
  assert.equal(p.visible('tipL'), true, 'auto-claim is offered');
  p.click('tipCk');
  await p.waitFor(() => /tip ≈/.test(p.text('tipNote')), { label: 'the tip estimate' });
  return { p, tip: BigInt(p.window.eval('String(sendTipWei)')) };
}

describe('the keeper tip', () => {
  test('on Base, prices the peak base fee and adds the L1 fee', async () => {
    const { p, tip } = await tipOn(BASE, c => {
      c.gasPrice = 6_000_000n;
      c.baseFees = [5_000_000n, 9_000_000n, 7_000_000n];
      c.l1FeeUpper = 10n ** 12n;
    });
    assert.equal(tip, (9_000_000n * TIP_GAS + 10n ** 12n) * 2n);
    p.close();
  });

  test('on Robinhood, adds the L1 component the NodeInterface reports', async () => {
    const { p, tip } = await tipOn(RH, c => {
      c.gasPrice = 70_000_000n;
      c.baseFees = [69_000_000n, 69_500_000n];
      c.l1Component = { gas: 5000n, baseFee: 70_000_000n };
    });
    assert.equal(tip, (70_000_000n * TIP_GAS + 5000n * 70_000_000n) * 2n);
    p.close();
  });

  test('on Ethereum, is the gas price alone when there is no L1 fee, doubled', async () => {
    const { p, tip } = await tipOn('0x1');
    assert.equal(tip, 10n ** 9n * TIP_GAS * 2n);
    p.close();
  });

  test('falls back to the chain gas floor when the node gives no price', async () => {
    const { p, tip } = await tipOn(BASE, c => { c.gasPrice = 0n; });
    const floor = BigInt(p.window.eval('String(CHAINS[8453].gasFloor)'));
    assert.equal(tip, floor * TIP_GAS * 2n, 'the floor, not a flat half-milliether');
    p.close();
  });
});
