#!/usr/bin/env node
/**
 * Drive the real zSwap.html against a forked mainnet, EXECUTING rather than
 * simulating.
 *
 * Everything else in this repo checks the page against fixtures or against
 * `eth_call`. Both answer "would this revert", and neither answers the
 * question that actually matters: does the state afterwards look the way the
 * page said it would. A fill that succeeds and pays the wrong address passes
 * every eth_call we run.
 *
 * So this points the page at an anvil fork, impersonates whichever account the
 * flow needs, and reads the balances back afterwards. Real contracts, real
 * state, real transactions - and a chain that can be thrown away.
 *
 *   anvil --fork-url <rpc> --fork-block-number <n> --auto-impersonate --port 8545 --silent
 *   node script/fork-drive.mjs swap
 *   node script/fork-drive.mjs --account 0x… liquidity
 *
 * IT NEEDS AN ARCHIVE RPC, and that is the whole practical constraint. Every
 * state slot anvil has not seen is a round trip upstream, and the routing path
 * touches a great many: measured against free public endpoints this ran at
 * roughly one fetch every seven seconds, so a single quote took minutes and a
 * swap timed out. The same run against a paid archive endpoint is seconds.
 * Two symptoms tell you which wall you have hit:
 *
 *   "failed to get storage for 0x…"  the upstream pruned that block. Pin
 *                                    --fork-block-number to something recent,
 *                                    or use an archive provider.
 *   reads crawling in the progress   throttling. Nothing to fix in the page.
 *
 * Pin the block: foundry caches fork state per block under
 * ~/.foundry/cache/rpc, so a pinned fork is slow once and fast afterwards,
 * while an unpinned one pays full price on every run.
 *
 * `--auto-impersonate` is what makes `eth_sendTransaction` work from an
 * address nobody holds the key to, which is the whole point: these are the
 * user's own flows, run as the user, without the user's key.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM, VirtualConsole } from 'jsdom';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HTML = path.join(ROOT, 'zSwap.html');

const argv = process.argv.slice(2);
const val = (f, d) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : d; };
const RPC = val('--rpc', 'http://127.0.0.1:8545');
const SCENARIO = argv.find(a => !a.startsWith('--') && argv[argv.indexOf(a) - 1] !== '--rpc'
  && argv[argv.indexOf(a) - 1] !== '--account') || 'swap';
// Defaults to the address that created the first Precision market, because its
// positions are what most of these flows are about.
const ACCOUNT = val('--account', '0x1c0aa8ccd568d90d61659f060d1bfb1e6f855a20');
const sleep = ms => new Promise(r => setTimeout(r, ms));

/**
 * A forked node is not a local one.
 *
 * Every state access anvil has not seen before is a round trip to the upstream
 * archive, and the page opens with a burst of them - so the first minute is
 * slow and an individual request can stall past node's default header timeout.
 * That is the fork warming up, not a failure, and retrying is the correct
 * response to it. A revert, by contrast, is an answer: it is returned, never
 * retried.
 */
const rpc = async (method, params = [], tries = 6) => {
  let last;
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(RPC, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(120000),
      });
      const j = await r.json();
      if (j.error) {
        // Not every JSON-RPC error is an answer. A fork that cannot fetch a
        // slot from upstream reports it here, and that is a network failure
        // wearing an error object - retryable, unlike a revert.
        const upstream = /failed to get (storage|account|code|nonce)|error sending request|deadline|timeout/i
          .test(j.error.message || '');
        throw Object.assign(Error(`${method}: ${j.error.message}`), { rpcError: !upstream });
      }
      return j.result;
    } catch (e) {
      if (e.rpcError) throw e;          // the chain answered; that IS the answer
      last = e;
      await sleep(400 * (i + 1));
    }
  }
  throw Error(`${method}: ${last?.message || 'unreachable'} after ${tries} tries`);
};

/** The page's provider: everything goes to the fork, as the impersonated account. */
class ForkChain {
  constructor(account) {
    this.account = account;
    this.busy = 0;
    this.sent = [];
    this.log = [];
  }
  get inFlight() { return this.busy; }
  async request(arg) {
    this.busy++;
    try { return await this.#handle(arg); } finally { this.busy--; }
  }
  async #handle({ method, params = [] }) {
    if (process.env.FORK_TRACE) console.error(`    -> ${method}`);
    if (method === 'eth_chainId') return '0x1';
    if (method === 'eth_accounts' || method === 'eth_requestAccounts') return [this.account];
    // Batched sends are a wallet feature; the fork has no wallet, so the page
    // falls back to sending them one at a time - which is what we want to see.
    if (method === 'wallet_getCapabilities') throw Error('method not supported');
    if (method === 'eth_sendTransaction') {
      const tx = { ...params[0], from: params[0].from || this.account };
      this.sent.push(tx);
      const hash = await rpc('eth_sendTransaction', [tx]);
      const rc = await rpc('eth_getTransactionReceipt', [hash]);
      if (rc && rc.status === '0x0') throw Error(`reverted on chain: ${hash}`);
      return hash;
    }
    this.log.push(method);
    try {
      return await rpc(method, params);
    } catch (e) {
      // A page that turns a node failure into "no route" is lying to the user
      // about whose fault it is, so make the difference visible here.
      this.errors = (this.errors || 0) + 1;
      if (process.env.FORK_ERRORS) console.error(`    !! ${method}: ${e.message.slice(0, 110)}`);
      throw e;
    }
  }
}

const until = async (f, ms, label, note) => {
  const end = Date.now() + ms, t0 = Date.now();
  let ticks = 0;
  for (;;) {
    try { const v = f(); if (v) return v; } catch (_) {}
    if (Date.now() > end) throw Error(`timed out waiting for ${label}${note ? ` (${note()})` : ''}`);
    // A cold fork answers the first calls slowly - it is fetching state from
    // upstream per access - so say what is happening rather than hanging mute.
    if (++ticks % 50 === 0) {
      process.stderr.write(`    …${label}, ${((Date.now() - t0) / 1000).toFixed(0)}s${note ? ` — ${note()}` : ''}\n`);
    }
    await sleep(100);
  }
};

async function openPage(chain) {
  const vc = new VirtualConsole();
  const dom = new JSDOM(fs.readFileSync(HTML, 'utf8'), {
    runScripts: 'dangerously', pretendToBeVisual: true, url: 'https://zswap.fork/',
    virtualConsole: vc,
    beforeParse(w) {
      w.TextEncoder = TextEncoder; w.TextDecoder = TextDecoder;
      w.matchMedia = w.matchMedia || (q => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {} }));
      w.ethereum = { request: a => chain.request(a), on() {}, removeListener() {} };
      w.scrollTo = () => {};
    },
  });
  const w = dom.window, d = w.document;
  const page = {
    window: w, doc: d, chain,
    $: id => d.getElementById(id),
    text: id => (d.getElementById(id)?.textContent || '').trim(),
    value: id => d.getElementById(id)?.value ?? '',
    click: el => (typeof el === 'string' ? d.getElementById(el) : el)?.click(),
    type(id, v) {
      const el = d.getElementById(id); el.value = v;
      el.dispatchEvent(new w.Event('input', { bubbles: true }));
    },
    /** The curated list arrives after connect, so a symbol has to be waited for. */
    async waitToken(id, sym, ms = 90000) {
      await until(() => [...d.getElementById(id).options].some(o => o.textContent === sym),
        ms, `${sym} in the token list`,
        () => `note="${(d.getElementById('listNote')?.textContent || '').slice(0, 40)}"`);
    },
    pick(id, sym) {
      const el = d.getElementById(id);
      const o = [...el.options].find(x => x.textContent === sym);
      if (!o) throw Error(`${sym} is not in ${id}`);
      if (o.disabled) throw Error(`${sym} is disabled in ${id}`);
      el.value = o.value;
      el.dispatchEvent(new w.Event('change', { bubbles: true }));
    },
    /** Select by option VALUE rather than label - `__custom` has no stable text. */
    select(id, value) {
      const el = d.getElementById(id);
      el.value = value;
      el.dispatchEvent(new w.Event('change', { bubbles: true }));
    },
    /**
     * Answer the page's next `prompt()`.
     *
     * Importing a collection is the one flow that asks the user a question
     * through the browser rather than through a field, and jsdom has no dialog -
     * `prompt` is undefined, so the import path could not be driven at all.
     */
    queuePrompt(answer) {
      w.prompt = () => answer;
    },
    // Lenient on purpose: a forked node answers some of the page's bigger
    // batches slowly, and the page also polls in the background - so "quiet"
    // is a best effort rather than a precondition.
    settle: async (ms = 20000) => {
      const end = Date.now() + ms;
      while (chain.busy !== 0 && Date.now() < end) await sleep(120);
      await sleep(200);
    },
    close: () => w.close(),
  };
  await sleep(1200);
  page.click('swap');
  await until(() => page.text('addr') !== 'Not connected', 40000, 'connect');
  await page.settle();
  await sleep(500);
  return page;
}

// ------------------------------------------------------------------ helpers
const p32 = v => BigInt(v).toString(16).padStart(64, '0');
const bal = async (token, who) => BigInt(token === 'ETH'
  ? await rpc('eth_getBalance', [who, 'latest'])
  : await rpc('eth_call', [{ to: token, data: '0x70a08231' + p32(BigInt(who)) }, 'latest']));
const fmt = (v, d = 18) => (Number(v) / 10 ** d).toFixed(6);
/** Token decimals, because 94 USDC printed at 18 places reads as 0.000000. */
const DEC = {};
const dec = sym => DEC[sym] ?? 18;
const amt = (v, sym) => `${(Number(v) / 10 ** dec(sym)).toFixed(6)} ${sym}`;

const ZORG = '0x00a6ba94bbb5474725515de88fe04f854f2dcb12';
const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
const USDT = '0xdAC17F958D2ee523a2206206994597C13D831ec7';
const DAI  = '0x6B175474E89094C44Da98b954EedeAC495271d0F';
const FWA  = '0xa0df17b5ac76ababa36e1450e2cbcd18a620c845';
/** Holders deep enough to lend any of the above. Impersonated, never signed for. */
Object.assign(DEC, { USDC: 6, USDT: 6 });
const WHALES = [
  '0x28C6c06298d514Db089934071355E5743bf21d60',
  '0xF977814e90dA44bFA03b6295A0616a897441aceC',
  '0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503',
];

/**
 * Move `amount` of `token` to `to` from whoever on the fork actually has it.
 *
 * Returns false for two very different reasons, and used to report them the same
 * way: "could not source USDC" was printed both when no whale held enough AND
 * when a cold fork simply never answered. The second is the node, not the chain,
 * and reading it as the first sends you looking for a richer whale that already
 * exists. So the reason is recorded and the caller can say which happened.
 */
const FUND = { why: null };
async function fund(token, to, amount) {
  FUND.why = null;
  if (await bal(token, to) >= amount) return true;
  const held = [];
  for (const w of WHALES) {
    const has = await bal(token, w);
    held.push(has);
    if (has < amount) continue;
    // Gas for the whale, then a plain transfer. Impersonation makes this a
    // normal transaction from an address nobody holds the key to.
    fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'anvil_setBalance',
        params: [w, '0x' + (10n ** 18n).toString(16)] }) }).catch(() => {});
    await sleep(400);
    try {
      const h = await rpc('eth_sendTransaction', [{ from: w, to: token,
        data: '0xa9059cbb' + p32(BigInt(to)) + p32(amount) }]);
      const rc = await rpc('eth_getTransactionReceipt', [h]);
      if (rc?.status === '0x1' && await bal(token, to) >= amount) return true;
      FUND.why = `the transfer from ${w.slice(0, 10)} did not land (status ${rc?.status})`;
    } catch (e) {
      // An upstream fetch failure is the fork struggling, not a poor whale.
      FUND.why = `the fork did not answer while funding from ${w.slice(0, 10)}: ${e.message}`;
    }
  }
  if (!FUND.why) {
    const best = held.length ? held.reduce((a, b) => (b > a ? b : a), 0n) : 0n;
    FUND.why = `no whale holds ${amount} (deepest has ${best})`;
  }
  return false;
}
/** The reason the last `fund` failed, for a message that names the real cause. */
const fundFailed = what => Error(`could not source ${what} - ${FUND.why}`);
const POOL = '0xc37f8c7e9afe897893952aba7fd91e0ab947837d';
const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';

/**
 * Quote a pair and send it, asserting on what MOVED.
 *
 * Every swap scenario is the same four steps with different assets, and the
 * assertion that matters is always the same one: the balance change has to
 * match the number the page put on screen. A swap that succeeds and delivers
 * something else is the failure this exists to catch.
 */
async function tradeAndCheck(page, { from, to, amount, exactOut = false, recipient = null }) {
  await page.waitToken('fromSel', from);
  await page.waitToken('toSel', to);
  // The equal-pair guard blocks a side that the other already holds, so park
  // the receive side somewhere neutral before moving the pay side.
  const parking = ['USDC', 'USDT', 'WBTC', 'DAI'].find(x => x !== from && x !== to);
  page.pick('toSel', parking);
  page.pick('fromSel', from);
  page.pick('toSel', to);
  await sleep(700);
  if (recipient) page.type('rc', recipient);

  const who = recipient || ACCOUNT;
  const addrOf = sym => ({ ETH: 'ETH', WETH, USDC, USDT, DAI, ZORG, FWA }[sym]);
  const b0 = { in: await bal(addrOf(from), ACCOUNT), out: await bal(addrOf(to), who) };

  // Clear the status FIRST. Switching tokens leaves its own messages behind,
  // and a wait that accepts "No route" will match the previous pair's failure
  // and report it as this one's - which is how a harness invents a bug and
  // then hides a real one behind it.
  page.$('stat').textContent = '';
  page.type(exactOut ? 'outAmt' : 'amt', amount);
  await until(() => {
    const v = page.value(exactOut ? 'amt' : 'outAmt');
    return (v && v !== '...') || /No route|Pick|Invalid/i.test(page.text('stat'));
  // A deep pair's FIRST quote on a cold fork walks every venue that has ever
  // held it - hundreds of slots, one upstream fetch each. Cached afterwards.
  }, 600000, `a quote for ${from}->${to}`, () => `${page.chain.log.length} reads`);
  const shown = page.value(exactOut ? 'amt' : 'outAmt');
  if (!shown) throw Error(page.text('stat') || 'no quote');
  const rate = page.text('rate');
  VENUE.last = (rate.match(/·\s*([A-Za-z0-9 +.%]+?)\s*(?:·|$)/) || [, '?'])[1].trim();
  console.log(`  quote      ${amount} ${exactOut ? to : from} -> ${shown} ${exactOut ? from : to} · ${rate.split('·').slice(1).join('·').trim().slice(0, 40)}`);

  page.$('stat').textContent = '';
  page.click('swap');
  // "Sent" is not "Done": the page reports the hash before the receipt lands,
  // so a wait that stops there reads a pending transaction as a settled one.
  await until(() => /Done|Error|High price impact/i.test(page.text('stat')), 180000, 'the swap',
    () => page.text('stat').slice(0, 40));
  if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));
  await page.settle();
  await sleep(800);

  const b1 = { in: await bal(addrOf(from), ACCOUNT), out: await bal(addrOf(to), who) };
  const got = b1.out - b0.out, paid = b0.in - b1.in;
  console.log(`  moved      -${amt(paid, from)}  +${amt(got, to)}`);
  if (got <= 0n) throw Error(`${to} did not arrive`);
  // Exact-in: what arrived must match the quote. Exact-out: the OUTPUT is the
  // fixed side, so that is what gets checked against what was asked for.
  const target = exactOut ? Number(amount) : Number(shown);
  const actual = Number(got) / 10 ** dec(to);
  const drift = Math.abs(actual - target) / target;
  if (drift > 0.02) throw Error(`delivered ${actual}, quoted ${target} (${(drift * 100).toFixed(2)}% off)`);
  console.log(`  vs quote   ${(drift * 100).toFixed(3)}% off`);
}

// ---------------------------------------------------------------- scenarios
const scenarios = {
  /** Buy ZORG through whatever venue the page picks, and check what arrived. */
  async swap(page) {
    await page.waitToken('toSel', 'ZORG');
    page.pick('toSel', 'ZORG');
    await sleep(800);
    const before = { eth: await bal('ETH', ACCOUNT), zorg: await bal(ZORG, ACCOUNT) };
    page.type('amt', '0.001');
    await until(() => {
      const o = page.value('outAmt');
      return (o && o !== '...') || /No route/i.test(page.text('stat'));
    }, 600000, 'a quote', () => `${page.chain.log.length} reads, out="${page.value('outAmt')}"`);
    const quoted = page.value('outAmt');
    console.log(`  quote      ${quoted} ZORG · ${page.text('rate').slice(0, 60)}`);
    if (!quoted) throw Error(page.text('stat'));

    page.click('swap');
    await until(() => /Done|Error/i.test(page.text('stat')), 180000, 'the swap',
      () => page.text('stat').slice(0, 50));
    await page.settle();
    if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));

    const after = { eth: await bal('ETH', ACCOUNT), zorg: await bal(ZORG, ACCOUNT) };
    const got = after.zorg - before.zorg;
    console.log(`  spent      ${fmt(before.eth - after.eth)} ETH (including gas)`);
    console.log(`  received   ${fmt(got)} ZORG`);
    const drift = Math.abs(Number(got) / 1e18 - Number(quoted)) / Number(quoted);
    console.log(`  vs quote   ${(drift * 100).toFixed(4)}% off`);
    if (drift > 0.01) throw Error('the fill differs from the quote by more than 1%');
    console.log(`  tx         ${page.chain.sent.length} transaction(s), to ${page.chain.sent.at(-1).to}`);
  },

  /** Add to the live band, then withdraw it all again, and check the round trip. */
  async liquidity(page) {
    await page.waitToken('toSel', 'ZORG');
    page.pick('toSel', 'ZORG');
    await sleep(800);
    page.click('lq');
    await until(() => page.$('lqList').querySelector('.lqrow'), 60000, 'the band list');
    await page.settle();

    const row = page.$('lqList').querySelector('.lqrow');
    console.log(`  band       ${row.querySelector('.lqband').textContent.trim().slice(0, 40)}`);
    console.log(`  holding    ${(row.querySelector('.lqmine')?.textContent || 'none').trim().slice(0, 60)}`);

    const before = { eth: await bal('ETH', ACCOUNT), zorg: await bal(ZORG, ACCOUNT) };
    row.querySelector('[data-act="a"]').click();
    await sleep(300);
    const ins = row.querySelectorAll('.lqin');
    ins[0].value = '0.0005';
    ins[0].dispatchEvent(new page.window.Event('input', { bubbles: true }));
    await until(() => ins[1].value, 10000, 'the mirrored amount');
    console.log(`  depositing 0.0005 ETH + ${ins[1].value} ZORG (mirrored from reserves)`);
    await until(() => /deposits/i.test(row.querySelector('.lqpv').textContent), 30000, 'preview');

    row.querySelector('[data-act="ac"]').click();
    await until(() => /Added|Error/i.test(page.text('stat')) || page.chain.sent.length, 90000, 'the add');
    await page.settle();
    await sleep(1500);
    const after = { eth: await bal('ETH', ACCOUNT), zorg: await bal(ZORG, ACCOUNT) };
    console.log(`  spent      ${fmt(before.eth - after.eth)} ETH + ${fmt(before.zorg - after.zorg)} ZORG`);
    const shares = BigInt(await rpc('eth_call',
      [{ to: POOL, data: '0x70a08231' + p32(BigInt(ACCOUNT)) }, 'latest']));
    console.log(`  LP shares  ${shares}`);
    console.log(`  status     ${page.text('stat').slice(0, 70)}`);
  },

  /** ETH out to an ERC-20, through whichever venue wins. */
  async 'swap:eth-token'(page) { await tradeAndCheck(page, { from: 'ETH', to: 'USDC', amount: '0.05' }); },

  /** The other direction, which needs an approval the ETH path does not. */
  async 'swap:token-eth'(page) {
    if (!await fund(USDC, ACCOUNT, 500n * 10n ** 6n)) throw fundFailed('USDC');
    await tradeAndCheck(page, { from: 'USDC', to: 'ETH', amount: '100' });
  },

  /** Neither side native: two ERC-20s, and a route that may hop. */
  async 'swap:token-token'(page) {
    if (!await fund(USDC, ACCOUNT, 500n * 10n ** 6n)) throw fundFailed('USDC');
    await tradeAndCheck(page, { from: 'USDC', to: 'DAI', amount: '100' });
  },

  /** A Precision band as the winning venue, which settles at the pool itself. */
  async 'swap:precision'(page) { await tradeAndCheck(page, { from: 'ETH', to: 'ZORG', amount: '0.002' }); },

  /** A hooked V4 pool, priced by running the hook and settled through V4Port. */
  async 'swap:v4-hooked'(page) { await tradeAndCheck(page, { from: 'ETH', to: 'FWA', amount: '0.002' }); },

  /** Exact-out: the RECEIVE side is fixed and the page solves for the input. */
  async 'swap:exact-out'(page) {
    await tradeAndCheck(page, { from: 'ETH', to: 'USDC', amount: '50', exactOut: true });
  },

  /** Somebody else is paid, which is a different recipient in the calldata. */
  async 'swap:recipient'(page) {
    await tradeAndCheck(page, { from: 'ETH', to: 'USDC', amount: '0.02',
      recipient: '0x000000000000000000000000000000000000dEaD' });
  },

  /** ETH -> WETH is a wrap, not a trade: 1:1, and no quoter involved. */
  async 'swap:wrap'(page) {
    await page.waitToken('toSel', 'WETH');
    page.pick('toSel', 'WETH');
    await sleep(600);
    const b0 = await bal(WETH, ACCOUNT);
    page.type('amt', '0.01');
    await until(() => { const v = page.value('outAmt'); return v && v !== '...'; },
      120000, 'a wrap quote', () => `out="${page.value('outAmt')}"`);
    console.log(`  priced as  ${page.value('outAmt')} WETH · ${page.text('rate').slice(0, 44)}`);
    page.click('swap');
    await until(() => /Done|Error/i.test(page.text('stat')), 120000, 'the wrap');
    if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));
    await page.settle(); await sleep(600);
    const got = await bal(WETH, ACCOUNT) - b0;
    console.log(`  wrapped    ${fmt(got)} WETH`);
    if (got !== 10n ** 16n) throw Error(`expected exactly 0.01 WETH, got ${fmt(got)}`);
  },

  /** And back out again, which is the unwrap path. */
  async 'swap:unwrap'(page) {
    if (!await fund(WETH, ACCOUNT, 10n ** 16n)) throw fundFailed('WETH');
    await page.waitToken('fromSel', 'WETH');
    page.pick('toSel', 'USDC');
    page.pick('fromSel', 'WETH');
    page.pick('toSel', 'ETH');
    await sleep(700);
    const b0 = await bal(WETH, ACCOUNT);
    page.type('amt', '0.005');
    await until(() => page.value('outAmt') === '0.005', 60000, 'the 1:1 unwrap rate',
      () => `out="${page.value('outAmt')}" rate="${page.text('rate').slice(0, 40)}"`);
    console.log(`  priced as  ${page.text('rate')} | button "${page.text('swap')}"`);
    page.$('stat').textContent = '';
    page.click('swap');
    await until(() => /Done|Error/i.test(page.text('stat')), 120000, 'the unwrap');
    if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));
    await page.settle(); await sleep(600);
    console.log(`  unwrapped  ${fmt(b0 - await bal(WETH, ACCOUNT))} WETH`);
  },

  /** Plain value transfer on the send tab. */
  async 'send:eth'(page) {
    const TO = '0x000000000000000000000000000000000000bEEF';
    page.click('tabSend');
    await sleep(500);
    const b0 = await bal('ETH', TO);
    page.type('rc', TO);
    page.type('amt', '0.01');
    await sleep(800);
    page.click('swap');
    await until(() => /Done|Error/i.test(page.text('stat')), 120000, 'the send',
      () => page.text('stat').slice(0, 40));
    if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));
    await page.settle(); await sleep(600);
    const got = await bal('ETH', TO) - b0;
    console.log(`  sent       ${fmt(got)} ETH`);
    if (got !== 10n ** 16n) throw Error(`expected 0.01 ETH, moved ${fmt(got)}`);
  },

  /** The same, for a token, which needs a transfer rather than a value send. */
  async 'send:token'(page) {
    const TO = '0x000000000000000000000000000000000000bEEF';
    if (!await fund(USDC, ACCOUNT, 50n * 10n ** 6n)) throw fundFailed('USDC');
    await page.waitToken('fromSel', 'USDC');
    page.click('tabSend');
    await sleep(400);
    page.pick('fromSel', 'USDC');
    await sleep(600);
    const b0 = await bal(USDC, TO);
    page.type('rc', TO);
    page.type('amt', '10');
    await sleep(800);
    page.click('swap');
    await until(() => /Done|Error/i.test(page.text('stat')), 120000, 'the send',
      () => page.text('stat').slice(0, 40));
    if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));
    await page.settle(); await sleep(600);
    console.log(`  sent       ${Number(await bal(USDC, TO) - b0) / 1e6} USDC`);
    if (await bal(USDC, TO) - b0 !== 10n * 10n ** 6n) throw Error('wrong amount moved');
  },

  /**
   * An order sourced BY A SWAP, which is the claim worth proving.
   *
   * The Orders tab filling an order only shows the board works. This shows the
   * router treating a resting order as liquidity: a maker posts a price no AMM
   * can beat, and a plain swap on the other side has to take it - through
   * zRouter and Swapbol, with the maker paid by a contract the swapper never
   * names.
   */
  async 'swap:via-book'(page) {
    const MAKER = '0xF977814e90dA44bFA03b6295A0616a897441aceC';
    // The maker sells USDC absurdly cheaply for WETH. Nothing on any AMM can
    // compete, so if the book is in the routing set at all, this must win.
    if (!await fund(USDC, MAKER, 400n * 10n ** 6n)) throw fundFailed('USDC for the maker');
    fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'anvil_setBalance',
        params: [MAKER, '0x' + (10n ** 19n).toString(16)] }) }).catch(() => {});
    await sleep(1000);

    const mChain = new ForkChain(MAKER);
    const mPage = await openPage(mChain);
    try {
      await mPage.waitToken('fromSel', 'USDC');
      mPage.click('tabBook');
      await sleep(400);
      mPage.pick('toSel', 'DAI');
      mPage.pick('fromSel', 'USDC');
      mPage.pick('toSel', 'ETH');
      await sleep(700);
      mPage.type('amt', '300');          // 300 USDC
      mPage.type('outAmt', '0.01');      // for 0.01 ETH: far under the market
      await sleep(700);
      mPage.click('swap');
      await until(() => /Placed|Done|Error/i.test(mPage.text('stat')), 180000, 'the maker order',
        () => mPage.text('stat').slice(0, 40));
      if (/Error/i.test(mPage.text('stat'))) throw Error(`placing: ${mPage.text('stat')}`);
      await mPage.settle();
      console.log(`  posted     300 USDC for 0.01 ETH (below any AMM)`);
    } finally { mPage.close(); }

    // Now a plain swap the other way. The book should beat every pool.
    await tradeAndCheck(page, { from: 'ETH', to: 'USDC', amount: '0.01' });
    if (!/Orderbook|Book/i.test(VENUE.last || '')) {
      console.log(`  note       routed via ${VENUE.last} rather than the book`);
      throw Error(`the book was not sourced: took ${VENUE.last}`);
    }
  },

  /**
   * Place an order as one account and fill it as another.
   *
   * The multi-board executor is the piece with the most moving parts and the
   * least real exercise: an order is escrowed at the board, the taker's fill
   * goes through zRouter and Swapbol, and the maker is paid by a contract the
   * taker never names. Nothing about that is visible in an eth_call - it all
   * turns on where the assets end up.
   */
  async 'order:fixed'(page) {
    const TAKER = '0x28C6c06298d514Db089934071355E5743bf21d60';
    await page.waitToken('fromSel', 'ZORG');

    // ---- maker: sell 50 ZORG for 0.0004 ETH, which settles as WETH
    page.click('tabBook');
    await sleep(400);
    // The landing pair is ETH -> ZORG, so ZORG is disabled on the pay side
    // until something else vacates the receive side. Step through USDC.
    page.pick('toSel', 'USDC');
    page.pick('fromSel', 'ZORG');
    page.pick('toSel', 'ETH');
    await sleep(800);
    page.type('amt', '50');
    page.type('outAmt', '0.0004');
    await sleep(600);
    console.log(`  button     ${page.text('swap')}`);

    const mk0 = { zorg: await bal(ZORG, ACCOUNT) };
    page.click('swap');
    await until(() => /Placed|Done|Error/i.test(page.text('stat')), 180000, 'the placement',
      () => page.text('stat').slice(0, 44));
    await page.settle();
    if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));
    const mk1 = { zorg: await bal(ZORG, ACCOUNT) };
    console.log(`  escrowed   ${fmt(mk0.zorg - mk1.zorg)} ZORG · ${page.chain.sent.length} tx`);
    if (mk0.zorg - mk1.zorg === 0n) throw Error('nothing left the maker');

    // ---- taker: a different account, and it must find the order in the book
    fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'anvil_setBalance',
        params: [TAKER, '0x' + (10n ** 19n).toString(16)] }) }).catch(() => {});
    await sleep(1200);

    const takerChain = new ForkChain(TAKER);
    const taker = await openPage(takerChain);
    try {
      taker.click('tabBook');
      await until(() => /Fill/.test(taker.$('book').textContent), 120000, 'the order in the book',
        () => `${taker.$('book').textContent.length} chars of book`);
      await taker.settle();

      const row = [...taker.$('book').querySelectorAll('button')].find(b => b.textContent === 'Fill');
      if (!row) throw Error('no fillable row');
      console.log(`  book row   ${row.closest('div')?.textContent.trim().slice(0, 52)}`);

      const t0 = { zorg: await bal(ZORG, TAKER) }, m0 = { weth: await bal(WETH, ACCOUNT) };
      taker.click(row);
      await until(() => /Done|Error/i.test(taker.text('stat')), 180000, 'the fill',
        () => taker.text('stat').slice(0, 44));
      await taker.settle();
      if (/Error/i.test(taker.text('stat'))) throw Error(taker.text('stat'));

      const t1 = { zorg: await bal(ZORG, TAKER) }, m1 = { weth: await bal(WETH, ACCOUNT) };
      console.log(`  taker got  ${fmt(t1.zorg - t0.zorg)} ZORG`);
      console.log(`  maker got  ${fmt(m1.weth - m0.weth)} WETH`);
      if (t1.zorg - t0.zorg === 0n) throw Error('the taker received nothing');
      if (m1.weth - m0.weth === 0n) throw Error('the maker was not paid');
    } finally { taker.close(); }
  },

  /**
   * The same round trip, but on a DECAYING price.
   *
   * A Dutch order is escrowed against Dutchboard rather than the fixed board,
   * and its price is a function of time, so what the taker pays is not what the
   * maker typed. The fill is the only place that arithmetic is exercised end to
   * end - a quote never settles it - and the two boards are different contracts
   * reached through the same button, which is exactly where a routing mistake
   * would hide.
   */
  async 'order:dutch'(page) {
    const TAKER = '0x28C6c06298d514Db089934071355E5743bf21d60';
    await page.waitToken('fromSel', 'ZORG');

    page.click('tabBook');
    await sleep(400);
    page.pick('kind', 'Dutch decay');
    await sleep(400);
    // Same vacate-the-receive-side dance as order:fixed.
    page.pick('toSel', 'USDC');
    page.pick('fromSel', 'ZORG');
    page.pick('toSel', 'ETH');
    await sleep(800);
    // 60, not 50: order:fixed sells 50 on the same board, and these scenarios
    // share a fork. Two rows reading "50 ZORG" would make the row lookup below
    // ambiguous, and it would pick whichever sorted first.
    page.type('amt', '60');            // sell 60 ZORG
    page.type('outAmt', '0.0004');     // starting at 0.0004 ETH
    page.type('floorAmt', '0.0002');   // decaying to 0.0002
    page.pick('dly', '1 hour');          // over an hour
    await sleep(700);
    console.log(`  button     ${page.text('swap')}`);
    if (/Pick|Invalid|Choose|Set /i.test(page.text('swap')))
      throw Error(`the page will not accept the order: "${page.text('swap')}"`);

    const z0 = await bal(ZORG, ACCOUNT);
    page.click('swap');
    await until(() => /Placed|Done|Error/i.test(page.text('stat')), 180000, 'the dutch placement',
      () => page.text('stat').slice(0, 44));
    await page.settle();
    if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));
    const escrowed = z0 - await bal(ZORG, ACCOUNT);
    console.log(`  escrowed   ${fmt(escrowed)} ZORG, decaying 0.0004 -> 0.0002 ETH`);
    if (escrowed === 0n) throw Error('nothing left the maker');

    // Let the price walk down a little, so the fill is priced by the CURVE and
    // not by the opening number. Half the window puts it near the midpoint.
    await rpc('evm_increaseTime', [1800]).catch(() => {});
    await rpc('evm_mine', []).catch(() => {});

    fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'anvil_setBalance',
        params: [TAKER, '0x' + (10n ** 19n).toString(16)] }) }).catch(() => {});
    await sleep(1200);

    const taker = await openPage(new ForkChain(TAKER));
    try {
      taker.click('tabBook');
      // OURS, not merely the first fillable thing on the book.
      //
      // This took the first `Fill` button it found, which on a mainnet fork is a
      // stranger's order - the book is real. It filled one (10 ZORG for 100
      // WETH, at a price nobody would take) and then reported "the maker was not
      // paid", which was true and meant nothing: the maker of that order is not
      // us. A scenario that asserts on OUR balances has to act on OUR row.
      const mine = () => [...taker.$('book').querySelectorAll('button')]
        .filter(b => b.textContent === 'Fill')
        .find(b => /\b60 ZORG\b/.test(b.closest('div')?.textContent || ''));
      await until(mine, 120000, 'our dutch order in the book',
        () => `${taker.$('book').textContent.length} chars of book`);
      await taker.settle();
      const row = mine();
      if (!row) throw Error('our dutch row went missing after settling');
      console.log(`  book row   ${row.closest('div')?.textContent.trim().slice(0, 52)}`);

      // A Dutch lot quoted in ETH pays its maker in ETH, NOT WETH. The page says
      // so itself - `payNative` is true for `r.dutch && r.tB===ZERO` - and the
      // maker sends no transaction during someone else's fill, so their ether
      // balance moves for exactly one reason. Measuring WETH here reported "the
      // maker was not paid" on a fill that had paid them correctly.
      //
      // Both are summed anyway: which side of the wrapped boundary the proceeds
      // land on is the contract's business, and the assertion that matters is
      // that the maker got PAID.
      const t0 = await bal(ZORG, TAKER);
      const m0 = await bal('ETH', ACCOUNT) + await bal(WETH, ACCOUNT);
      taker.click(row);
      await until(() => /Done|Error/i.test(taker.text('stat')), 180000, 'the dutch fill',
        () => taker.text('stat').slice(0, 44));
      await taker.settle();
      if (/Error/i.test(taker.text('stat'))) throw Error(taker.text('stat'));

      const got = await bal(ZORG, TAKER) - t0;
      const paid = (await bal('ETH', ACCOUNT) + await bal(WETH, ACCOUNT)) - m0;
      console.log(`  taker got  ${fmt(got)} ZORG`);
      console.log(`  maker got  ${fmt(paid)} ETH+WETH`);
      if (got === 0n) throw Error('the taker received nothing');
      if (paid <= 0n) throw Error('the maker was not paid');
      // The whole point of a decay: partway through the window the price must
      // be under where it opened. Equal to the start means the curve never ran.
      if (paid > 4n * 10n ** 14n)
        throw Error(`paid ${fmt(paid)}, which is not below the 0.0004 opening - the decay did not apply`);
    } finally { taker.close(); }
  },

  /**
   * A climbing bid: the mirror of a Dutch, and the only flow that BUYS.
   *
   * Every other order path sells something the maker already holds. A bid
   * escrows the PAY side and rises toward a maximum, so the asset moving at
   * placement is the one being spent - the opposite direction through the same
   * escrow, and the case a sell-shaped assumption would get wrong.
   */
  async 'order:bid'(page) {
    await page.waitToken('toSel', 'ZORG');
    page.click('tabBook');
    await sleep(400);
    page.pick('kind', 'Climbing bid');
    await sleep(400);
    page.pick('fromSel', 'ETH');
    page.pick('toSel', 'ZORG');
    await sleep(800);
    page.type('amt', '0.0008');        // at most 0.0008 ETH
    page.type('outAmt', '50');         // for 50 ZORG
    page.type('floorAmt', '0.0004');   // opening at half that
    page.pick('dly', '1 hour');
    await sleep(700);
    console.log(`  button     ${page.text('swap')}`);
    if (/Pick|Invalid|Choose|Set /i.test(page.text('swap')))
      throw Error(`the page will not accept the bid: "${page.text('swap')}"`);

    // A bid spends the PAY side, so that is the balance that must move. The
    // page may spend ether or wrapped ether depending on what covers it, so
    // both are counted - what matters is that the escrow was funded.
    const e0 = await bal('ETH', ACCOUNT), w0 = await bal(WETH, ACCOUNT);
    page.click('swap');
    await until(() => /Placed|Done|Error/i.test(page.text('stat')), 180000, 'the bid placement',
      () => page.text('stat').slice(0, 44));
    await page.settle();
    if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));
    const spent = (e0 - await bal('ETH', ACCOUNT)) + (w0 - await bal(WETH, ACCOUNT));
    console.log(`  bid placed 0.0004 -> 0.0008 ETH for 50 ZORG · moved ${fmt(spent)}`);
    if (spent === 0n) throw Error('the bid escrowed nothing');

    // And it has to be visible as a bid, or nobody can ever take it.
    page.click('tabBook');
    await until(() => /ZORG/.test(page.$('book').textContent), 120000, 'the bid in the book',
      () => `${page.$('book').textContent.length} chars of book`);
    console.log(`  listed     ${page.$('book').textContent.trim().slice(0, 60)}`);
  },

  /**
   * The taker side of a bid, which nothing else reaches.
   *
   * Every other order scenario SELLS: the maker escrows the thing being sold
   * and a taker pays for it. Hitting a bid runs the other way - the standing
   * order holds the PAYMENT, and whoever acts on it delivers the asset and is
   * paid out of that escrow. Floorboard settles it through `hitMany`, which is
   * not payable precisely because no ether moves from the taker.
   *
   * So this is a whole settlement direction, and until now no simulation had
   * ever executed it. The page calls the button "Sell into" rather than "Fill",
   * which is the tell that it is a different act.
   */
  async 'order:hitbid'(page) {
    const SELLER = '0x28C6c06298d514Db089934071355E5743bf21d60';
    await page.waitToken('toSel', 'ZORG');

    // ---- bidder: offer to BUY 70 ZORG, climbing from 0.0004 to 0.0008 ETH
    page.click('tabBook');
    await sleep(400);
    page.pick('kind', 'Climbing bid');
    await sleep(400);
    page.pick('fromSel', 'ETH');
    page.pick('toSel', 'ZORG');
    await sleep(800);
    page.type('amt', '0.0008');
    page.type('outAmt', '70');         // 70, so the row cannot be confused with 50 or 60
    page.type('floorAmt', '0.0004');
    page.pick('dly', '1 hour');
    await sleep(700);
    if (/Pick|Invalid|Choose|Set /i.test(page.text('swap')))
      throw Error(`the page will not accept the bid: "${page.text('swap')}"`);
    page.click('swap');
    await until(() => /Placed|Done|Error/i.test(page.text('stat')), 180000, 'the bid placement',
      () => page.text('stat').slice(0, 44));
    await page.settle();
    if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));
    console.log(`  bid placed 0.0004 -> 0.0008 ETH for 70 ZORG`);

    // Let it climb, so what the seller receives is the CURVE's price and not
    // merely the opening number.
    await rpc('evm_increaseTime', [1800]).catch(() => {});
    await rpc('evm_mine', []).catch(() => {});

    // ---- seller: needs ZORG to deliver. The bidder has plenty.
    fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'anvil_setBalance',
        params: [SELLER, '0x' + (10n ** 19n).toString(16)] }) }).catch(() => {});
    await sleep(1000);
    await rpc('eth_sendTransaction', [{ from: ACCOUNT, to: ZORG,
      data: '0xa9059cbb' + p32(BigInt(SELLER)) + p32(200n * 10n ** 18n) }]);
    if (await bal(ZORG, SELLER) < 70n * 10n ** 18n) throw Error('could not get ZORG to the seller');

    const seller = await openPage(new ForkChain(SELLER));
    try {
      seller.click('tabBook');
      // The book is filtered by the SELECTED PAIR, so a page left on its landing
      // pair simply does not list our bid - the row was never missing, it was
      // never asked for. The seller is selling ZORG, so that is the pay side.
      await seller.waitToken('fromSel', 'ZORG');
      seller.pick('toSel', 'USDC');
      seller.pick('fromSel', 'ZORG');
      seller.pick('toSel', 'ETH');
      await sleep(900);
      await seller.settle();
      // "Sell into", not "Fill" - and ours, not a stranger's.
      const mine = () => [...seller.$('book').querySelectorAll('button')]
        .filter(b => b.textContent === 'Sell into')
        .find(b => /\b70 ZORG\b/.test(b.closest('div')?.textContent || ''));
      await until(mine, 120000, 'our bid in the seller\'s book',
        () => `${seller.$('book').textContent.length} chars of book`);
      await seller.settle();
      const row = mine();
      console.log(`  book row   ${row.closest('div')?.textContent.trim().slice(0, 52)}`);

      const s0 = { zorg: await bal(ZORG, SELLER), weth: await bal(WETH, SELLER), eth: await bal('ETH', SELLER) };
      const b0 = await bal(ZORG, ACCOUNT);
      seller.click(row);
      await until(() => /Done|Error/i.test(seller.text('stat')), 180000, 'the hit',
        () => seller.text('stat').slice(0, 44));
      await seller.settle();
      if (/Error/i.test(seller.text('stat'))) throw Error(seller.text('stat'));

      const gave = s0.zorg - await bal(ZORG, SELLER);
      const got = (await bal(WETH, SELLER) - s0.weth) + (await bal('ETH', SELLER) - s0.eth);
      const bought = await bal(ZORG, ACCOUNT) - b0;
      console.log(`  seller gave ${fmt(gave)} ZORG`);
      console.log(`  seller got  ${fmt(got)} ETH+WETH`);
      console.log(`  bidder got  ${fmt(bought)} ZORG`);
      // Gas is paid in ether by the seller, so the proceeds are checked on the
      // wrapped side alone when the two together could net negative.
      if (gave === 0n) throw Error('the seller delivered nothing');
      if (bought === 0n) throw Error('the bidder received nothing for their escrow');
    } finally { seller.close(); }
  },

  /**
   * Cancelling, which is the only path that gives an escrow BACK.
   *
   * It also crosses the wrapped-ether boundary on its own terms - the board has
   * `cancelUnwrap` beside `cancel` - so it is exactly where a mistake about
   * which side of that boundary an asset sits would hide. Everything else in
   * this file spends; nothing else asks for a refund.
   */
  async 'order:cancel'(page) {
    await page.waitToken('fromSel', 'ZORG');
    page.click('tabBook');
    await sleep(400);
    page.pick('kind', 'Fixed limit');
    await sleep(400);
    page.pick('toSel', 'USDC');
    page.pick('fromSel', 'ZORG');
    page.pick('toSel', 'ETH');
    await sleep(800);
    page.type('amt', '80');            // distinct from every other scenario's size
    page.type('outAmt', '0.0004');
    await sleep(600);

    const before = await bal(ZORG, ACCOUNT);
    page.click('swap');
    await until(() => /Placed|Done|Error/i.test(page.text('stat')), 180000, 'the placement',
      () => page.text('stat').slice(0, 44));
    await page.settle();
    if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));
    const escrowed = before - await bal(ZORG, ACCOUNT);
    console.log(`  escrowed   ${fmt(escrowed)} ZORG`);
    if (escrowed === 0n) throw Error('nothing was escrowed to cancel');

    page.click('tabBook');
    const rows = () => [...page.$('book').querySelectorAll('button')]
      .filter(b => b.textContent === 'Cancel')
      .filter(b => /\b80 ZORG\b/.test(b.closest('div')?.textContent || ''));
    const count = () => rows().length;
    const mine = () => rows()[0];
    await until(mine, 120000, 'our order under YOUR ORDERS',
      () => `${page.$('book').textContent.length} chars of book`);
    await page.settle();
    const had = count();
    const row = mine();
    console.log(`  row        ${row.closest('div')?.textContent.trim().slice(0, 52)}`);

    page.click(row);
    await until(() => /Done|Error/i.test(page.text('stat')), 180000, 'the cancel',
      () => page.text('stat').slice(0, 44));
    await page.settle();
    if (/Error/i.test(page.text('stat'))) throw Error(page.text('stat'));

    const returned = await bal(ZORG, ACCOUNT) - (before - escrowed);
    console.log(`  returned   ${fmt(returned)} ZORG`);
    // The whole escrow, not part of it: a cancel that refunds less than it took
    // is a cancel that lost something.
    if (returned !== escrowed)
      throw Error(`escrowed ${fmt(escrowed)} but got back ${fmt(returned)}`);
    // And ONE of them must leave the book, or the order still looks fillable.
    //
    // Counted rather than matched. These scenarios re-run against a long-lived
    // fork, and a placement whose wait timed out still landed on chain - so an
    // earlier attempt can leave its own 80 ZORG order resting there forever,
    // and "is there still a row saying 80 ZORG" answers yes no matter what this
    // run did. The count is what this run is responsible for.
    await page.settle();
    await until(() => count() < had, 120000, 'the cancelled row to leave the book',
      () => `${count()} rows now, ${had} before`);
  },

  /**
   * List a real NFT, then take it back.
   *
   * The NFT paths have thorough unit coverage and no live execution at all,
   * which is the exact gap that let a Swapbatch struct mismatch survive twenty
   * passing tests: a mock agrees with whatever shape you build it to. A real
   * ERC-721 does not. It has its own approval semantics, its own `ownerOf`, and
   * a `transferFrom` with no receiver hook - so escrowing one either works
   * against the real thing or it does not.
   *
   * Moonbirds because it is a plain 721 with an easy holder to impersonate; the
   * page has never seen it, so the collection is imported through the same
   * `__custom` prompt a user would use, which exercises the ERC-721 detection
   * as well.
   */
  async 'nft:list-cancel'() {
    const PUNKS = '0x23581767a106ae21c074b2276D25e5C3e136a68b';  // Moonbirds
    const ID = 1n;
    const owner = ('0x' + (await rpc('eth_call', [{ to: PUNKS,
      data: '0x6352211e' + p32(ID) }, 'latest'])).slice(26)).toLowerCase();
    console.log(`  holder     ${owner} owns #${ID}`);
    fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'anvil_setBalance',
        params: [owner, '0x' + (10n ** 19n).toString(16)] }) }).catch(() => {});
    await sleep(1000);

    const p = await openPage(new ForkChain(owner));
    try {
      await until(() => p.$('tabBook'), 90000, 'the page');
      p.click('tabBook');
      await sleep(600);

      // Import the collection the way a user would: the page prompts for an
      // address and works out for itself that it is a 721.
      p.queuePrompt(PUNKS);
      p.select('fromSel', '__custom');
      await until(() => /MOONBIRD|BIRB|\w/.test(
        p.$('fromSel').selectedOptions[0]?.textContent || '') &&
        p.$('fromSel').selectedOptions[0].textContent !== 'ETH',
        120000, 'the collection to import',
        () => `fromSel="${p.$('fromSel').selectedOptions[0]?.textContent}"`);
      console.log(`  imported   ${p.$('fromSel').selectedOptions[0].textContent}`);
      p.pick('toSel', 'ETH');
      await sleep(800);

      // Ask 5 ETH for token #1.
      p.type('outAmt', '5');
      p.type('nftId', String(ID));
      await sleep(800);
      console.log(`  button     ${p.text('swap')}`);
      if (/Pick|Invalid|Choose|Set /i.test(p.text('swap')))
        throw Error(`the page will not accept the listing: "${p.text('swap')}"`);

      p.click('swap');
      await until(() => /Placed|Done|Error/i.test(p.text('stat')), 240000, 'the listing',
        () => p.text('stat').slice(0, 44));
      await p.settle();
      if (/Error/i.test(p.text('stat'))) throw Error(p.text('stat'));

      // The escrow is the thing to check: the board must actually hold the token.
      const holder = ('0x' + (await rpc('eth_call', [{ to: PUNKS,
        data: '0x6352211e' + p32(ID) }, 'latest'])).slice(26)).toLowerCase();
      console.log(`  #${ID} now at  ${holder}`);
      if (holder === owner) throw Error('the token never left the seller - nothing was escrowed');

      // ---- and take it back
      p.click('tabBook');
      const mine = () => [...p.$('book').querySelectorAll('button')]
        .find(b => b.textContent === 'Cancel');
      await until(mine, 120000, 'the listing under YOUR ORDERS',
        () => `${p.$('book').textContent.length} chars of book`);
      await p.settle();
      p.click(mine());
      await until(() => /Done|Error/i.test(p.text('stat')), 240000, 'the cancel',
        () => p.text('stat').slice(0, 44));
      await p.settle();
      if (/Error/i.test(p.text('stat'))) throw Error(p.text('stat'));

      const back = ('0x' + (await rpc('eth_call', [{ to: PUNKS,
        data: '0x6352211e' + p32(ID) }, 'latest'])).slice(26)).toLowerCase();
      console.log(`  returned   #${ID} to ${back}`);
      if (back !== owner) throw Error(`cancel did not return the token: it sits at ${back}`);
    } finally { p.close(); }
  },
};

// --------------------------------------------------------------------- main
const chainId = await rpc('eth_chainId').catch(() => null);
if (!chainId) {
  console.error(`no fork at ${RPC}. Start one:\n  anvil --fork-url <rpc> --auto-impersonate --port 8545 --silent`);
  process.exit(1);
}
const block = Number(BigInt(await rpc('eth_blockNumber')));
console.log(`fork ${RPC} · block ${block} · as ${ACCOUNT}`);
/**
 * Warm the fork.
 *
 * anvil fetches state from upstream on first touch, so the page's opening
 * burst of reads is paid for one round trip at a time - minutes, on a cold
 * fork, for a quote that takes a second against a real node. Touching the
 * contracts the routing path walks pulls their code and the hot slots in
 * before the page starts, which turns the first quote from a stall into a
 * wait.
 */
const WARM = {
  zQuoter: '0xc7a03f9ed2be5feea18ce93e12f4f05c98287c16',
  zRouter: '0x000000000000FB114709235f1ccBFfb925F600e4',
  tokenlist: '0x0000006013dF75A31678B786061C2B54bf531524',
  convictionLens: '0x000000cEa3AB048d59473F3fb116A8D7F1abd247',
  precisionLens: '0x000000Bad3a2fa57ed74fa06000573ccddF6B7fB',
  factory: '0x000000Eb27B557aB426d9E99cFd54EC455799e81',
  swapboardView: '0x000000E0b25449F32f7D9259aC449bA88E78dFCE',
  multicall: '0xcA11bde05977b3631167028862bE2a173976CA11',
  zorgPool: '0xc37f8c7e9afe897893952aba7fd91e0ab947837d',
  zorg: '0x00a6ba94bbb5474725515de88fe04f854f2dcb12',
};
process.stdout.write('warming');
const warmed = await Promise.all(
  Object.entries(WARM).map(async ([k, a]) => [k, a, await rpc('eth_getCode', [a, 'latest'])]));
process.stdout.write(` ${Object.keys(WARM).length} contracts\n`);
/**
 * A fork older than the contracts is not a failing dapp, but it reads as one.
 *
 * This suite was pinned at 25,640,000, which predates `ZorgTokenListLens`. With
 * no code there the registry came back EMPTY, so the page fell back to its
 * built-in tokens and every scenario naming a listed one - DAI, FWA - spent 90
 * seconds waiting for a token that was never going to arrive, then blamed the
 * token list. Three scenarios looked broken and none of them were.
 *
 * So the block is checked against the addresses this run actually needs, and a
 * stale pin says so in one line instead of timing out three times.
 */
const missing = warmed.filter(([, , code]) => !code || code === '0x');
if (missing.length) {
  console.error(`\nfork block ${block} predates ${missing.length} contract(s) this suite drives:`);
  for (const [k, a] of missing) console.error(`  ${k.padEnd(16)} ${a}`);
  console.error(`\nThe page would fall back to its built-in token list and the failures would\n`
    + `point at the dapp. Re-pin the fork past their deployment and run again.`);
  process.exit(1);
}
/**
 * Gas has to come from somewhere, and this is a throwaway chain.
 *
 * anvil's cheat methods APPLY but do not always answer - `anvil_setBalance`
 * here returns an empty body and never resolves, which hangs anything that
 * awaits it. So this is fired without waiting and then CHECKED, which is the
 * honest way round: the balance is the thing we need, not the acknowledgement.
 */
const want = 10n ** 19n;          // top up to 10 ETH
const enough = 2n * 10n ** 18n;   // but only when it has dropped below 2
if ((await bal('ETH', ACCOUNT)) < enough) {
  fetch(RPC, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'anvil_setBalance',
      params: [ACCOUNT, '0x' + want.toString(16)] }),
  }).catch(() => {});
  await sleep(1500);
  const got = await bal('ETH', ACCOUNT);
  if (got < enough) { console.error(`could not fund ${ACCOUNT} (has ${fmt(got)} ETH)`); process.exit(1); }
}
console.log(`funded  ${fmt(await bal('ETH', ACCOUNT))} ETH`);

/**
 * Every scenario gets its OWN page.
 *
 * They share the fork, which is the point - state accumulates the way it would
 * for a real user - but not a document. A page carries caches, timers and a
 * quote in flight, and a scenario inheriting those would pass or fail for
 * reasons belonging to the one before it.
 */
const names = SCENARIO === 'all' ? Object.keys(scenarios)
  : Object.keys(scenarios).filter(n => n === SCENARIO || n.startsWith(SCENARIO + ':'));
if (!names.length) {
  console.error(`unknown scenario "${SCENARIO}". Try: all, ${Object.keys(scenarios).join(', ')}`);
  process.exit(1);
}

const VENUE = { last: null };
const results = [];
for (const name of names) {
  console.log(`\n[${name}]`);
  const t0 = Date.now();
  const chain = new ForkChain(ACCOUNT);
  let page;
  try {
    page = await openPage(chain);
    VENUE.last = null;
    await scenarios[name](page);
    results.push({ name, ok: true, ms: Date.now() - t0, venue: VENUE.last });
    console.log(`[${name}] ok`);
  } catch (e) {
    results.push({ name, ok: false, ms: Date.now() - t0, why: e.message });
    console.error(`[${name}] FAILED: ${e.message}`);
  } finally {
    try { page?.close(); } catch (_) {}
  }
}

const pass = results.filter(r => r.ok).length;
console.log(`\n${'='.repeat(64)}`);
for (const r of results) {
  const via = r.venue ? `via ${r.venue}` : '';
  console.log(`  ${r.ok ? 'ok  ' : 'FAIL'}  ${r.name.padEnd(20)} ${String((r.ms / 1000).toFixed(0)).padStart(4)}s  ${r.ok ? via : r.why.slice(0, 58)}`);
}
console.log(`${'='.repeat(64)}\n  ${pass}/${results.length} paths exercised against the fork`);
if (pass !== results.length) process.exitCode = 1;
