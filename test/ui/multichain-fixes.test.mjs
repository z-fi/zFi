/**
 * What the page binds to the wallet's chain, and what it refuses to.
 *
 * Every send used to compare the wallet's chain to the literal 1, so a wallet
 * on Base or Robinhood quoted fine and then died at the button with "wallet
 * changed". The Permit2 domain, the Curve ordinal, the custom-token store and
 * the explorer links were pinned to mainnet the same way. These pin the
 * chain-bound behaviour on both sides of the line.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const BASE = '0x2105';
const MOON = '0x' + '77'.repeat(20);
const MAIN = '0x' + '88'.repeat(20);

const onBase = (extra = {}) => {
  const chain = new MockChain({ chainId: BASE });
  chain.setNative(A.ACCOUNT, 10n * ETH);
  return loadPage({ chain, hash: null, ...extra });
};

describe('a wallet on Base', () => {
  test('is allowed to send, and is not told it changed', async () => {
    const p = await onBase();
    await p.connect({ pin: false });
    assert.equal(p.window.eval('CHAIN_ID'), 8453);
    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'WETH');
    await p.settle();
    await p.typeAmount('amt', '2');
    p.click('swap');
    await p.waitFor(() => p.chain.sent.length > 0 || /Error/.test(p.text('stat')), { label: 'send' });
    assert.doesNotMatch(p.text('stat'), /wallet changed|Switch your wallet/, 'the wallet is on the page\'s chain');
    assert.equal(p.chain.sent.length, 1, 'the wrap is sent');
    p.close();
  });

  test('binds the chain-scoped state to the chain, not to mainnet', async () => {
    const p = await onBase();
    await p.connect({ pin: false });
    const w = p.window;
    assert.equal(w.eval('P2DOM().chainId'), 8453, 'Permit2 typed data names the live chain');
    assert.equal(w.eval('SRC_CURVE'), -1, 'the Curve ordinal is the chain table\'s, not update()\'s');
    assert.equal(w.eval('STORE()'), 'zswap:custom:8453', 'custom tokens are kept per chain');
    assert.match(w.eval('txLink("0x" + "ab".repeat(32), "Done")'), /basescan\.org\/tx\//, 'tx links go to the chain\'s explorer');
    assert.match(w.eval('escan("' + MOON + '")'), /basescan\.org\/token\//);
    assert.equal(p.visible('ln'), false, 'launch mode is withheld where the launcher is not deployed');
    assert.equal(p.visible('wn'), false, 'names are registered on mainnet only');
    p.close();
  });

  test('restores the custom tokens kept for that chain and not mainnet\'s', async () => {
    const p = await onBase({ storage: {
      'zswap:custom': JSON.stringify([{ sym: 'MAIN', addr: MAIN, dec: 18, std: 'ft' }]),
      'zswap:custom:8453': JSON.stringify([{ sym: 'MOON', addr: MOON, dec: 18, std: 'ft' }]),
    } });
    await p.connect({ pin: false });
    const syms = [...p.$('fromSel').options].map(o => o.textContent);
    assert.ok(syms.includes('MOON'), `Base custom token restored (have ${syms})`);
    assert.ok(!syms.includes('MAIN'), 'mainnet custom token does not leak into Base');
    p.close();
  });
});

describe('a wallet on mainnet', () => {
  test('keeps the mainnet bindings', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain });
    await p.connect();
    const w = p.window;
    assert.equal(w.eval('CHAIN_ID'), 1);
    assert.equal(w.eval('P2DOM().chainId'), 1);
    assert.equal(w.eval('SRC_CURVE'), 5);
    assert.equal(w.eval('STORE()'), 'zswap:custom');
    assert.match(w.eval('txLink("0x" + "ab".repeat(32), "Done")'), /etherscan\.io\/tx\//);
    assert.equal(w.eval('BOARDS().length'), 2);
    assert.equal(p.visible('ln'), true);
    p.close();
  });

  test('names the chain to switch to when the wallet has moved under the page', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain });
    await p.connect({ pin: false });
    p.pickToken('fromSel', 'ETH');
    p.pickToken('toSel', 'WETH');
    await p.settle();
    await p.typeAmount('amt', '1');
    // The wallet answers eth_chainId with Base from here on, without emitting
    // chainChanged, which is what a wallet mid-switch looks like.
    chain.chainId = BASE;
    p.click('swap');
    await p.waitFor(() => p.text('stat') !== '', { label: 'refusal' });
    assert.match(p.text('stat'), /Switch your wallet to Ethereum/);
    assert.equal(chain.sent.length, 0, 'nothing is sent to the wrong chain');
    p.close();
  });

  // The hazard this guards is that "USDC" is a different contract on each
  // chain, so a Base link resolved against mainnet's list buys the wrong token.
  // The page now adopts the link's chain before it resolves either symbol,
  // which answers that at the source rather than with a warning.
  test('a link for another chain resolves its symbols on that chain', async () => {
    const chain = new MockChain();
    const p = await loadPage({ chain, hash: 'token=ETH&out=USDC&chain=8453' });
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 8453, { label: 'link chain adopted' });
    await p.settle();
    const picked = p.window.eval('TOKENS[toSel.value].addr').toLowerCase();
    assert.equal(picked, '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913',
      "the link's USDC must be Base's, never mainnet's");
    p.close();
  });
});

describe('a wallet the user disconnected on purpose', () => {
  test('still tells the page which chain it is on', async () => {
    const chain = new MockChain({ chainId: BASE, autoConnected: true });
    const p = await loadPage({ chain, hash: null, session: { dc: '1' } });
    await p.waitFor(() => p.window.eval('wireWallet.probed') === 1, { label: 'chain probe' });
    await p.settle();
    assert.equal(p.window.eval('CHAIN_ID'), 8453, 'reads go to Base, so the page is on Base');
    assert.equal(p.text('addr'), 'Connect', 'the account stays disconnected');
    p.close();
  });
});

describe('without a wallet', () => {
  test('the network mark opens a list, and the pick survives a reload', async () => {
    const p = await loadPage({ walletless: true, hash: null });
    p.click('net');
    await p.settle();
    const rows = [...p.$('wkList').querySelectorAll('.tkr')];
    assert.deepEqual(rows.map(r => r.textContent), ['Ethereum', 'Robinhood', 'Base'],
      'every supported chain is offered, not only the next one in a rotation');
    assert.equal(rows.filter(r => r.classList.contains('cur')).length, 1, 'exactly one row is marked');
    assert.equal(rows[0].getAttribute('aria-current'), 'true', 'and it is the chain in force');
    assert.equal(p.reloads(), 0, 'opening the list does not move the page on its own');
    // Base is last in the list, so a rotation could never have reached it first.
    p.click(rows[2]);
    await p.settle();
    assert.equal(p.reloads(), 1, 'choosing a chain reloads onto it');
    assert.equal(p.window.localStorage.getItem('zswap:chain'), '8453', 'the chain chosen is the chain stored');
    p.close();
    const q = await loadPage({ walletless: true, hash: null, storage: { 'zswap:chain': '8453' } });
    await q.settle();
    assert.equal(q.window.eval('CHAIN_ID'), 8453, 'the stored chain is restored');
    assert.match(q.text('net'), /Base network/);
    q.close();
  });

  test('a stored L2 seats its own pair before the list lands', async () => {
    const { HTML_PATH } = await import('./harness.mjs');
    const html = (await import('node:fs')).readFileSync(HTML_PATH, 'utf8');
    const gate = [...html.matchAll(/(?:tokenlist:"|ZLISTLENS=")0x([0-9a-fA-F]{40})/g)].map(m => m[1].toLowerCase());
    for (const id of ['8453', '4663']) {
      const chain = new MockChain({ chainId: 1 }), req = chain.request.bind(chain);
      chain.request = async a => {
        if (a.method === 'eth_call' && gate.some(g => JSON.stringify(a.params).toLowerCase().includes(g))) await new Promise(r => setTimeout(r, 3000));
        return req(a);
      };
      const q = await loadPage({ chain, walletless: true, hash: null, storage: { 'zswap:chain': id } });
      const [ready, sym, opt, pick] = q.window.eval('[listReady,TOKENS[toSel.value].sym,toSel.options[toSel.selectedIndex].textContent,toPick.textContent]');
      assert.equal(ready, false, 'the list is still out');
      assert.ok(opt.includes(sym) && pick.includes(sym), `${id}: the label ${pick} sits over ${sym}`);
      q.close();
    }
  });

  test('a pinned read node is only used on the chain it was pinned for', async () => {
    const p = await loadPage({ walletless: true, hash: 'chain=8453&token=ETH&out=WETH&amount=1',
      storage: { 'zswap:rpc': 'https://pinned.example' } });
    await p.settle();
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 8453, { label: 'link chain' });
    await p.settle();
    assert.ok(!(p.chain.httpLog || []).some(r => /pinned\.example/.test(r.url)), 'a mainnet pin never answers a Base read');
    p.close();
  });
});

describe('the hybrid plan on an L2', () => {
  test('only hands the forwarder an AMM leg it can validate', async () => {
    const p = await onBase();
    await p.connect({ pin: false });
    const w = p.window;
    const sel = w.eval('SEL_MULTICALL');
    const swapV3 = '0xafeae12b' + '00'.repeat(32 * 8);
    const aeroCL = '0xcb924a09' + '00'.repeat(32 * 8);
    const mc = inner => {
      const body = inner.slice(2);
      const words = ['20', '01', '20', (body.length / 2).toString(16)].map(x => x.padStart(64, '0')).join('');
      return '0x' + sel + words + body + '0'.repeat((64 - body.length % 64) % 64);
    };
    assert.equal(w.eval(`bolOk("${swapV3}")`), true, 'a UniV3 leg is accepted');
    assert.equal(w.eval(`bolOk("${mc(swapV3)}")`), true, 'wrapped in a multicall too');
    // The deployed SwapbolL2 admits the L2 router vocabulary: Aerodrome and
    // Slipstream legs, Deepstate fills, the 3-arg sweep and the 2-arg deposit.
    assert.equal(w.eval(`bolOk("${mc(aeroCL)}")`), true, 'a Slipstream leg is accepted by the corrected forwarder');
    const sweep3 = '0xdc2c256f' + '00'.repeat(32 * 3);
    assert.equal(w.eval(`bolOk("${mc(sweep3)}")`), true, 'the L2 sweep shape too');
    assert.equal(w.eval(`bolOk("${mc('0xdeadbeef' + '00'.repeat(32))}")`), false, 'anything outside the vocabulary is still refused');
    assert.equal(w.eval('SOURCES[SRC_DEEP]||"?"'), '?');
    p.close();
  });
});

describe('share links', () => {
  test('carry the chain off mainnet and omit it on mainnet', async () => {
    const p = await onBase();
    await p.connect({ pin: false });
    p.click('lk');
    await p.settle();
    assert.match(String(p.copied()), /chain=8453/);
    p.close();
    const chain = new MockChain();
    const q = await loadPage({ chain });
    await q.connect();
    q.click('lk');
    await q.settle();
    assert.doesNotMatch(String(q.copied()), /chain=/);
    q.close();
  });
});

/**
 * The chain mark used to hand the wallet a switch request and then say nothing
 * at all: a decline looked identical to a switch that worked, and a wallet that
 * added a network without selecting it left the page building transactions for
 * a chain the wallet was not on.
 */
describe('switching the wallet between chains', () => {
  const pickRow = async (p, name) => {
    p.click('net');
    await p.settle();
    const row = [...p.$('wkList').querySelectorAll('.tkr')].find(r => r.textContent === name);
    assert.ok(row, `no ${name} row`);
    p.click(row);
    await p.settle();
  };

  test('a declined switch says so and leaves the page where it was', async () => {
    const p = await onBase();
    await p.settle();
    p.chain.failOn = {
      wallet_switchEthereumChain: Object.assign(Error('User rejected the request'), { code: 4001 }),
    };
    await pickRow(p, 'Robinhood');
    assert.equal(p.window.eval('CHAIN_ID'), 8453, 'the page stays on the chain the wallet is on');
    assert.match(p.text('stat'), /declined the switch/);
    assert.match(p.text('stat'), /Base/, 'and names where it stayed');
    assert.equal(p.reloads(), 0, 'nothing reloads onto a chain the wallet refused');
    p.close();
  });

  test('an unknown network is added, and the page follows only if the wallet selected it', async () => {
    const p = await onBase();
    await p.settle();
    p.chain.failOn = {
      wallet_switchEthereumChain: Object.assign(Error('Unrecognized chain ID'), { code: 4902 }),
    };
    await pickRow(p, 'Robinhood');
    assert.ok(p.chain.log.some(r => r.method === 'wallet_addEthereumChain'
      && r.params[0].chainId === '0x1237'), 'the page offers to add the chain it could not select');
    assert.equal(p.window.eval('CHAIN_ID'), 4663, 'and follows the wallet there');
    p.close();
  });

  test('a wallet that adds without selecting is reported, not assumed', async () => {
    const p = await onBase();
    await p.settle();
    p.chain.addSelects = false;
    p.chain.failOn = {
      wallet_switchEthereumChain: Object.assign(Error('Unrecognized chain ID'), { code: 4902 }),
    };
    await pickRow(p, 'Robinhood');
    assert.equal(p.window.eval('CHAIN_ID'), 8453,
      'the page must not claim a chain the wallet never selected');
    assert.match(p.text('stat'), /still on Base/i);
    assert.equal(p.reloads(), 0);
    p.close();
  });

  test('choosing the chain already in force does nothing', async () => {
    const p = await onBase();
    await p.settle();
    const before = p.chain.log.length;
    await pickRow(p, 'Base');
    assert.ok(!p.chain.log.slice(before).some(r => r.method === 'wallet_switchEthereumChain'),
      'no wallet prompt for a chain the wallet is already on');
    assert.equal(p.reloads(), 0);
    p.close();
  });
});

/**
 * A shared link names its chain.
 *
 * Following one used to be abandoned outright whenever a wallet extension was
 * present and pointed somewhere else: the handler set a message and returned
 * before the pair, the amount or the recipient were ever applied. So a link to
 * a Robinhood trade opened, for anyone with MetaMask on mainnet, as the mainnet
 * default pair - the trade that was shared simply was not shown.
 *
 * Reading a chain needs no wallet, and the swap button already asks the wallet
 * to switch when it disagrees, so the page follows the link either way and says
 * what will happen.
 */
describe('following a link to another chain', () => {
  const linked = (extra = {}) => {
    const chain = new MockChain({ chainId: BASE });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    return loadPage({ chain, hash: 'chain=4663&token=ETH&out=USDG&amount=1', ...extra });
  };

  test('a disconnected visitor lands on the trade that was shared', async () => {
    const p = await loadPage({ walletless: true, hash: 'chain=4663&token=ETH&out=USDG&amount=1' });
    await p.settle();
    assert.equal(p.window.eval('CHAIN_ID'), 4663, 'the page follows the chain in the link');
    assert.equal(p.value('amt'), '1', 'and the amount it carried');
    p.close();
  });

  test('a wallet on another chain no longer discards the link', async () => {
    const p = await linked();
    p.chain.autoConnected = true;
    await p.settle();
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 4663, { label: 'link chain adopted' });
    assert.equal(p.value('amt'), '1', 'the amount in the link is applied, not dropped');
    const sel = p.text('fromSel') + '/' + p.text('toSel');
    assert.ok(/ETH/.test(sel), `the pair in the link is applied, got ${sel}`);
    p.close();
  });

  // A status line is not a durable surface - the quote that follows owns it.
  // What has to hold is that connecting adopts the chain the link named rather
  // than dragging the page back to wherever the wallet happened to be.
  test('connecting from a link asks the wallet for the link chain', async () => {
    const p = await linked();
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 4663, { label: 'link chain adopted' });
    await p.settle();
    p.click('addr');
    await p.settle();
    const asked = p.chain.log.filter(r => r.method === 'wallet_switchEthereumChain');
    assert.ok(asked.length, 'connecting must ask the wallet to join the chain the link named');
    assert.equal(asked[asked.length - 1].params[0].chainId, '0x1237', 'and it must ask for Robinhood');
    assert.equal(p.window.eval('CHAIN_ID'), 4663, 'the page stays on the chain that was shared');
    p.close();
  });
});

/**
 * A link's chain that the wallet has not followed.
 *
 * The page adopts the chain a link names whether or not a wallet is present,
 * which is what makes a shared trade open as the trade that was shared. But a
 * connected wallet's reads stay with that wallet - deliberately, because the
 * curated node pool must never learn a connected user's account - so while the
 * two disagree, every balance and every quote on screen would be answered by
 * the chain the WALLET is on while the page names the other one.
 *
 * That is worse than showing nothing: zQuoter and zRouter sit at the same
 * address on all three chains, so the wallet answers such a call with a real
 * price from the wrong market rather than with silence. The page holds both
 * back and says which way to move instead.
 */
describe('a link whose chain the wallet has not followed', () => {
  test('shows neither a balance nor a price from the chain the wallet sits on', async () => {
    const chain = new MockChain({ chainId: BASE, autoConnected: true });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain, hash: 'chain=4663&token=ETH&out=USDG&amount=1' });
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 4663, { label: 'link chain adopted' });
    await p.settle();
    assert.ok(p.window.eval('!!account'), 'the wallet is connected for this to mean anything');
    assert.equal(p.text('bal'), '', "a Base balance must not be shown as Robinhood's");
    assert.equal(p.value('outAmt'), '', 'no price may be taken from the chain the wallet is on');
    assert.match(p.text('stat'), /Robinhood/, 'the message names the chain the page is on');
    assert.match(p.text('stat'), /Base/, 'and the chain the wallet is on');
    p.close();
  });

  test('prices normally once the wallet and the page agree', async () => {
    const chain = new MockChain({ chainId: '0x1237', autoConnected: true });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain, hash: 'chain=4663&token=ETH&out=USDG&amount=1' });
    await p.settle();
    assert.equal(p.window.eval('CHAIN_ID'), 4663);
    assert.doesNotMatch(p.text('stat'), /switch it to/, 'a wallet already there is not told to move');
    assert.match(p.text('bal'), /Balance/, 'and its balance is its own to show');
    p.close();
  });
});
