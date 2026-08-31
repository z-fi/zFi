import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const WK = 'zswap:wk';
const OTHER = '0x2222222222222222222222222222222222222222';

/**
 * The page already reconnected on refresh - but only ever by rebinding
 * `window.ethereum`. With two wallets installed exactly one of them is there
 * and the rest announce over EIP-6963, so a person who picked the second one
 * from the chooser came back to either nothing or, worse, the OTHER wallet's
 * account. Which wallet was chosen has to survive the refresh too.
 */
function fixture(accounts) {
  const c = new MockChain({ autoConnected: true, accounts });
  c.setNative(accounts[0], 10n * ETH);
  c.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  return c;
}

describe('the wallet survives a refresh', () => {
  test('the injected wallet reconnects, as it always did', async () => {
    const p = await loadPage({ chain: fixture([A.ACCOUNT]), hash: null });
    await p.settle();
    assert.match(p.text('addr'), /0x1111|1111/, 'the account should come back on its own');
    p.close();
  });

  test('a chosen 6963 wallet comes back, not whatever is on window.ethereum', async () => {
    const injected = fixture([A.ACCOUNT]);
    const chosen = fixture([OTHER]);
    const p = await loadPage({
      chain: injected, hash: null,
      wallets: [{ rdns: 'io.other.wallet', chain: chosen }],
      storage: { [WK]: 'io.other.wallet' },
    });
    await p.settle();
    assert.match(p.text('addr'), /2222/,
      'the wallet the person actually chose must be the one that comes back');
    assert.doesNotMatch(p.text('addr'), /1111/, 'not the injected one');
    p.close();
  });

  test('an explicit disconnect is still honoured', async () => {
    const q = await loadPage({
      chain: fixture([A.ACCOUNT]), hash: null,
      wallets: [{ rdns: 'io.other.wallet', chain: fixture([OTHER]) }],
      storage: { [WK]: 'io.other.wallet' },
      session: { dc: '1' },
    });
    await q.settle();
    assert.doesNotMatch(q.text('addr'), /2222|1111/,
      'a person who disconnected must stay disconnected across a refresh');
    q.close();
  });

  /**
   * Remembering the wallet must not hand it the connect button unconditionally.
   * A wallet that is installed but locked answers `eth_accounts` with nothing;
   * adopting it anyway meant every later connect went to a wallet that could
   * not answer, and the chooser never appeared again.
   */
  /**
   * Disconnect used to call `wallet_revokePermissions`, which does not merely
   * forget the account - it tears down the site's grant in the wallet. Coming
   * back then meant the whole approval flow again, and the address chip is a
   * TOGGLE: one stray click on it and reconnecting was a chore. Forgetting the
   * account locally is what the button is for; revoking is the wallet's own
   * job, and its own screen.
   */
  test('disconnecting does not revoke the wallet grant', async () => {
    const chain = fixture([A.ACCOUNT]);
    const seen = [];
    const inner = chain.request.bind(chain);
    chain.request = async args => { seen.push(args.method); return inner(args); };

    const p = await loadPage({ chain, hash: null });
    await p.settle();
    await p.waitFor(() => /1111/.test(p.text('addr')), { label: 'the wallet to come back' });

    p.window.__reloaded = 0;
    p.click('addr');
    await p.settle();
    assert.ok(!seen.includes('wallet_revokePermissions'),
      'the grant must survive so reconnecting is one click');
    assert.equal(p.window.sessionStorage.getItem('dc'), '1',
      'but this tab should stay disconnected until asked otherwise');
    p.close();
  });

  test('a remembered wallet holding no account is not adopted', async () => {
    const locked = fixture([A.ACCOUNT]);
    locked.autoConnected = false;              // installed, but locked
    const p = await loadPage({
      chain: fixture([A.ACCOUNT]), hash: null,
      wallets: [{ rdns: 'io.locked.wallet', chain: locked }],
      storage: { [WK]: 'io.locked.wallet' },
    });
    await p.settle();
    await p.waitFor(() => /1111/.test(p.text('addr')),
      { label: 'the injected wallet to answer instead' });
    p.close();
  });

  test('a remembered wallet that is gone does not hang the page', async () => {
    // Uninstalled since last visit: nothing announces that rdns, so the page
    // must fall through to the injected wallet rather than waiting forever.
    const p = await loadPage({
      chain: fixture([A.ACCOUNT]), hash: null,
      storage: { [WK]: 'io.uninstalled.wallet' },
    });
    await p.settle();
    // The page waits a beat for the remembered wallet to announce itself before
    // giving up on it, so the fallback is late rather than absent.
    await p.waitFor(() => /1111/.test(p.text('addr')), { label: 'fallback to the injected wallet' });
    p.close();
  });
});
