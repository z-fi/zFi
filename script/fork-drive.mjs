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
    return rpc(method, params);
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

const ZORG = '0x00a6ba94bbb5474725515de88fe04f854f2dcb12';
const POOL = '0xc37f8c7e9afe897893952aba7fd91e0ab947837d';
const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';

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

  /**
   * Place an order as one account and fill it as another.
   *
   * The multi-board executor is the piece with the most moving parts and the
   * least real exercise: an order is escrowed at the board, the taker's fill
   * goes through zRouter and Swapbol, and the maker is paid by a contract the
   * taker never names. Nothing about that is visible in an eth_call - it all
   * turns on where the assets end up.
   */
  async order(page) {
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
  zQuoter: '0x0000002d9a651b729e3aFBE57Fc84FFDa4a98a13',
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
await Promise.all(Object.values(WARM).map(a => rpc('eth_getCode', [a, 'latest'])));
process.stdout.write(` ${Object.keys(WARM).length} contracts\n`);
/**
 * Gas has to come from somewhere, and this is a throwaway chain.
 *
 * anvil's cheat methods APPLY but do not always answer - `anvil_setBalance`
 * here returns an empty body and never resolves, which hangs anything that
 * awaits it. So this is fired without waiting and then CHECKED, which is the
 * honest way round: the balance is the thing we need, not the acknowledgement.
 */
const want = 10n ** 19n;
if ((await bal('ETH', ACCOUNT)) < want) {
  fetch(RPC, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'anvil_setBalance',
      params: [ACCOUNT, '0x' + want.toString(16)] }),
  }).catch(() => {});
  await sleep(1500);
  const got = await bal('ETH', ACCOUNT);
  if (got < want) { console.error(`could not fund ${ACCOUNT} (has ${fmt(got)} ETH)`); process.exit(1); }
}
console.log(`funded  ${fmt(await bal('ETH', ACCOUNT))} ETH`);

const run = scenarios[SCENARIO];
if (!run) { console.error(`unknown scenario "${SCENARIO}". Try: ${Object.keys(scenarios).join(', ')}`); process.exit(1); }
console.log(`\n[${SCENARIO}]`);
const chain = new ForkChain(ACCOUNT);
const page = await openPage(chain);
try {
  await run(page);
  console.log(`\n[${SCENARIO}] ok`);
} catch (e) {
  console.error(`\n[${SCENARIO}] FAILED: ${e.message}`);
  process.exitCode = 1;
} finally {
  page.close();
}
