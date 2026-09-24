/**
 * What the page says when it does not know.
 *
 * A read can fail. A reference price can be unavailable. A node can drop a
 * call and return success with nothing in it. In every one of those cases the
 * page holds no information, and the bug this file guards against is the page
 * spending that absence as though it were a fact — and spending it, every
 * time, in the direction that lets the action proceed:
 *
 *   a failed balance read      became "Insufficient balance"
 *   a single node's answer     was enough to adopt a whole endpoint roster
 *
 * Two other candidates did NOT survive checking, and are recorded here so
 * nobody re-files them. An unknown price impact looked like it skipped both
 * confirmation gates; it does, but the page says "Impact unknown" on the rate
 * line and the only route that can reach that state is exact-input, so a
 * blocking prompt would fire on every book-only coin and teach people to click
 * through. And mcFailed counts sub-calls that reverted with empty returndata,
 * which is a dropped call AND a venue with no route — indistinguishable, so
 * the `&&mcOk===ok0` beside it is a real heuristic, not an over-narrow gate.
 *
 * The suite around this one is thick on happy paths and thin on failure paths,
 * which is how all three survived. These drive the failure.
 *
 * Note the assertions on the first two are on the ABSENCE of the false claim,
 * not the presence of any particular new wording — so rewording the page does
 * not quietly un-test it.
 *
 * Run: node --test --test-concurrency=1 test/ui/unknown-is-not-zero.test.mjs
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const ETH = 10n ** 18n;


describe('a balance the page could not read', () => {
  const setup = async () => {
    const chain = new MockChain({ chainId: '0x1' });
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain });
    await p.connect?.();
    return p;
  };

  // A live quote for more than the balance. Without this the button returns
  // "Swap" long before the balance check, and every assertion below passes
  // for the wrong reason.
  const QUOTE = `last={impact:0,exp:Date.now()+6e4,amountIn:10n**24n,isIn:true,
    lossTok:0n,lossDec:18,lossSym:"ETH",recipient:null};fromBalance=0n`;

  test('is not reported as insufficient', async () => {
    const p = await setup();

    // Control first: with the balance genuinely read as zero, this IS
    // insufficiency and the page is right to say so. If this stops holding,
    // the assertion underneath means nothing.
    p.window.eval(`${QUOTE};balUnread=false;render()`);
    assert.equal(p.text('swap'), 'Insufficient balance', 'a known-zero balance no longer reports insufficiency');

    p.window.eval('balUnread=true;render()');
    assert.notEqual(
      p.text('swap'), 'Insufficient balance',
      'the page claimed insufficiency on a balance it never read',
    );
    p.close();
  });

  test('does not block the swap on an amount it cannot check', async () => {
    const p = await setup();
    p.window.eval(`${QUOTE};balUnread=true;render()`);
    assert.equal(
      p.disabled('swap'), false,
      'an unread balance disabled the button; the chain rejects a real overspend, an unread one is not an overspend',
    );
    p.close();
  });

  test('is cleared by a later successful read', async () => {
    const p = await setup();
    p.window.eval('balUnread=true');
    await p.window.eval('refreshBalance()');
    assert.equal(
      p.window.eval('balUnread'), false,
      'the unread flag survived a read that succeeded, so it would stick for the session',
    );
    p.close();
  });
});

describe('the curated roster', () => {

  test('is not adopted on a single node\'s say-so', async () => {
    const chain = new MockChain({ chainId: '0x1' });
    chain.setNative(A.ACCOUNT, ETH);
    // Every node but one is unreachable, so only one answer comes back.
    const p = await loadPage({ walletless: true, chain });
    const one = await p.window.eval(`(async()=>{
      let n=0;
      window.fetch=async()=>{n++;if(n>1)throw Error("unreachable");
        return{ok:true,status:200,json:async()=>({jsonrpc:"2.0",id:1,result:"0x"+"11".repeat(32)})}};
      return await quorum2(["https://a/","https://b/","https://c/","https://d/"],{to:RPCS_PIN,data:"0x"})})()`);
    assert.equal(one, '', 'one answer was enough to adopt a roster');
    p.close();
  });

  test('declines when the nodes split evenly', async () => {
    const chain = new MockChain({ chainId: '0x1' });
    const p = await loadPage({ walletless: true, chain });

    // Two say one thing, two say another. Whichever way the array is ordered,
    // the answer must be the same: nothing. A first-past-the-post tally would
    // return whichever value reached two occurrences first, making pool
    // position decide between truth and a lie.
    for (const order of [['x', 'x', 'y', 'y'], ['y', 'y', 'x', 'x'], ['x', 'y', 'x', 'y']]) {
      const r = await p.window.eval(`(async()=>{
        const say=${JSON.stringify(Object.fromEntries(order.map((v, i) => ['https://' + 'abcd'[i] + '/', v.repeat(32)])))};
        window.fetch=async u=>({ok:true,status:200,
          json:async()=>({jsonrpc:"2.0",id:1,result:"0x"+say[String(u)]})});
        return await quorum2(["https://a/","https://b/","https://c/","https://d/"],{to:RPCS_PIN,data:"0x"})})()`);
      assert.equal(r, '', `an even split returned an answer for order ${order.join(',')}`);
    }
    p.close();
  });

  test('is adopted on a clear majority, and the dissenter is demoted not dropped', async () => {
    const chain = new MockChain({ chainId: '0x1' });
    const p = await loadPage({ walletless: true, chain });

    const out = await p.window.eval(`(async()=>{
      const pool=["https://a/","https://b/","https://c/","https://d/"];
      const say={"https://a/":"aa","https://b/":"aa","https://c/":"aa","https://d/":"bb"};
      window.fetch=async u=>({ok:true,status:200,
        json:async()=>({jsonrpc:"2.0",id:1,result:"0x"+say[String(u)].repeat(32)})});
      const r=await quorum2(pool,{to:RPCS_PIN,data:"0x"});
      return JSON.stringify([r,pool])})()`);
    const [answer, pool] = JSON.parse(out);

    assert.equal(answer, 'aa'.repeat(32), 'a three-to-one majority was not adopted');
    assert.equal(pool[pool.length - 1], 'https://d/', 'the dissenting node was not moved to the back of the pool');
    assert.equal(pool.length, 4, 'the dissenting node was dropped rather than demoted');
    p.close();
  });
});
