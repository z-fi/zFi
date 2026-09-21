/**
 * What the wallet does while a transaction is in flight, and how connecting
 * talks to it.
 *
 * The page reloads when the wallet changes chain or account, because every
 * address and list it holds is per chain. A reload between "Sent" and "Done"
 * throws away the only view of the transaction the user just signed, and a
 * poll made while the wallet sits on another chain asks the wrong chain about
 * it. So an in-flight transaction holds the reload, polling pauses while the
 * wallet is away, and a wallet that comes back before the receipt costs nothing.
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;
const RATE = 3000n * ETH;

async function sending() {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: RATE });
  const p = await loadPage({ chain });
  await p.connect();
  await p.typeAmount('amt', '1');
  chain.receiptPending = true;
  p.click('swap');
  await p.waitFor(() => /Sent/.test(p.text('stat')), { label: 'sent' });
  return p;
}

const land = async p => {
  p.chain.receiptPending = false;
  await p.waitFor(() => /Done/.test(p.text('stat')), { label: 'done', timeout: 20000 });
  await new Promise(r => setTimeout(r, 1300));
};

describe('a transaction in flight', () => {
  test('a chain change waits for the receipt, and says where the wallet went', async () => {
    const p = await sending();
    p.chain.chainId = '0x2105';
    p.emit('chainChanged', '0x2105');
    await new Promise(r => setTimeout(r, 1300));
    assert.equal(p.reloads(), 0, 'no reload while the transaction is unconfirmed');
    assert.match(p.text('stat'), /Sent/, 'the transaction link stays up');
    assert.match(p.text('stat'), /switch it to Ethereum/, 'and the user is told how to finish');
    const polls = p.chain.log.filter(r => r.method === 'eth_getTransactionReceipt').length;
    await new Promise(r => setTimeout(r, 2500));
    assert.equal(p.chain.log.filter(r => r.method === 'eth_getTransactionReceipt').length, polls,
      'the wallet is not asked about the receipt while it is on another chain');
    p.chain.chainId = '0x1';
    p.emit('chainChanged', '0x1');
    await land(p);
    assert.equal(p.reloads(), 0, 'a wallet that came back before the receipt needs no reload');
    p.close();
  });

  test('an account change reloads once the transaction settles', async () => {
    const p = await sending();
    p.emit('accountsChanged', ['0x2222222222222222222222222222222222222222']);
    await new Promise(r => setTimeout(r, 1300));
    assert.equal(p.reloads(), 0, 'an account change waits too');
    await land(p);
    assert.equal(p.reloads(), 1, 'and reloads once the receipt is in');
    p.close();
  });

  test('the network picker refuses to switch mid-transaction', async () => {
    const p = await sending();
    const before = p.chain.log.length;
    p.window.eval('switchNet(8453)');
    await p.settle();
    assert.match(p.text('stat'), /finish the transaction in progress/);
    assert.ok(!p.chain.log.slice(before).some(r => r.method === 'wallet_switchEthereumChain'));
    await land(p);
    p.close();
  });
});

/**
 * A wallet's "speed up" re-sends the same call at a higher fee under the same
 * nonce, so the hash the page is watching never lands. The page finds the
 * transaction that used the nonce and follows it when it is the same call.
 */
describe('a replaced transaction', () => {
  const replacing = async shape => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    chain.quoteHandler = fixedRateQuoter({ rate: RATE });
    const p = await loadPage({ chain });
    await p.connect();
    await p.typeAmount('amt', '1');
    const d = chain.dispatch.bind(chain), h2 = '0x' + 'ab'.repeat(32), from = A.ACCOUNT;
    let h1 = null;
    const at = () => (chain.mined ? 0x70 : 0x64);
    chain.dispatch = async (m, a) => {
      if (m === 'eth_sendTransaction') return (h1 = await d(m, a));
      if (!h1) return d(m, a);
      const tx = chain.lastSent;
      switch (m) {
        case 'eth_getTransactionByHash': return a[0] === h1 ? { hash: h1, from, nonce: '0x5', to: tx.to, input: tx.data } : null;
        case 'eth_blockNumber': return '0x' + at().toString(16);
        case 'eth_getTransactionCount': {
          const b = a[1] === 'latest' ? at() : Number(a[1]);
          return chain.mined && b >= 0x6a ? '0x6' : '0x5';
        }
        case 'eth_getBlockByNumber':
          return a[1] === true && Number(a[0]) === 0x6a ? { transactions: [{ hash: h2, from, nonce: '0x5', ...shape(tx) }] } : d(m, a);
        case 'eth_getTransactionReceipt':
          return chain.mined && a[0] === h2 ? { status: '0x1', transactionHash: h2, blockNumber: '0x6a', logs: [] } : null;
      }
      return d(m, a);
    };
    p.click('swap');
    await p.waitFor(() => /Sent/.test(p.text('stat')), { label: 'sent' });
    chain.mined = true;
    return { p, h2 };
  };

  test('a sped-up swap is followed to the transaction that landed', async () => {
    const { p, h2 } = await replacing(tx => ({ to: tx.to, input: tx.data }));
    await p.waitFor(() => /Done/.test(p.text('stat')), { label: 'done', timeout: 30000 });
    assert.ok(p.$('stat').innerHTML.includes(h2), 'the link points at the transaction that was mined');
    p.close();
  });

  test('a cancelled swap is called cancelled', async () => {
    const { p } = await replacing(() => ({ to: A.ACCOUNT, input: '0x' }));
    await p.waitFor(() => /cancelled/.test(p.text('stat')), { label: 'cancel reported', timeout: 30000 });
    assert.doesNotMatch(p.text('stat'), /Done/);
    p.close();
  });
});

/**
 * Reads go to the wallet, never to a public node, while a wallet is present.
 * When that wallet sits on another chain, its answers describe the wrong
 * chain, so the page refuses the read and says why rather than use them.
 */
describe('a wallet on another chain', () => {
  const probe = p => p.window.eval(
    'rpc("eth_call",[{to:"0x0000000000000000000000000000000000000001",data:"0x"},"latest"]).then(()=>"ok",e=>e.offChain?"off":"err:"+e.message)');

  test('reads for the page\'s chain are refused, not answered from the wrong one', async () => {
    const chain = new MockChain({ chainId: '0x2105', autoConnected: true });
    chain.setNative(A.ACCOUNT, ETH);
    const p = await loadPage({ chain, hash: 'chain=4663&token=ETH&out=USDG' });
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 4663 && p.window.eval('walletChain') === 8453, { label: 'link over wallet' });
    await p.settle();
    const before = chain.log.filter(r => r.method === 'eth_call').length;
    assert.equal(await probe(p), 'off');
    assert.equal(chain.log.filter(r => r.method === 'eth_call').length, before, 'the wallet was not asked');
    assert.equal(await p.window.eval('rpc("eth_chainId",[])'), '0x2105', 'the wallet is still asked what chain it is on');
    p.close();
  });

  test('reads flow again once the wallet and page agree', async () => {
    const chain = new MockChain({ autoConnected: true });
    chain.setNative(A.ACCOUNT, ETH);
    const p = await loadPage({ chain, hash: null });
    await p.waitFor(() => /1111/.test(p.text('addr')), { label: 'connected' });
    assert.notEqual(await probe(p), 'off');
    p.close();
  });
});

describe('connecting', () => {
  test('a link to a chain the wallet lacks offers to add it', async () => {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain, hash: 'chain=4663&token=ETH&out=USDG' });
    await p.waitFor(() => p.window.eval('CHAIN_ID') === 4663, { label: 'link chain adopted' });
    await p.settle();
    chain.failOn = { wallet_switchEthereumChain: Object.assign(Error('Unrecognized chain ID'), { code: 4902 }) };
    p.click('addr');
    await p.settle();
    assert.ok(chain.log.some(r => r.method === 'wallet_addEthereumChain' && r.params[0].chainId === '0x1237'),
      'the page adds the chain the link named');
    assert.equal(p.window.eval('CHAIN_ID'), 4663, 'and stays on it');
    assert.equal(p.window.eval('walletChain'), 4663);
    p.close();
  });

  test('a request already open in the wallet is named, not dumped raw', async () => {
    const chain = new MockChain();
    chain.failOn = { eth_requestAccounts: Object.assign(Error("Request of type 'wallet_requestPermissions' already pending"), { code: -32002 }) };
    const p = await loadPage({ chain, hash: null });
    await p.settle();
    p.click('addr');
    await p.settle();
    assert.match(p.text('stat'), /already has a request open/);
    p.close();
  });

});
