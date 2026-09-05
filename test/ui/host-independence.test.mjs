/**
 * The page must behave the same however it was reached.
 *
 * It is served from at least four kinds of host: its own address as a
 * subdomain (0x....wei.limo), the published names (zswap.wei, zerofi.wei), a
 * first-party domain (zerofi.sh), and an IPFS gateway. They are different
 * origins with different hostname shapes, and only the first carries the
 * page's own contract address.
 *
 * WHY THIS FILE EXISTS. `loadSolvers` and `loadCurated` used to begin by
 * working out which contract was serving the page - `selfFromUrl()`, which
 * reads the first hostname label and returns "" unless it looks like an
 * address - and returned immediately when that failed. So on every published
 * NAME the external solver lanes and the governable RPC roster were skipped in
 * silence: no roster read, no endpoints, not one request, and a quote that
 * presented itself as the best available while never having asked four of the
 * venues. It reached production because every test ran on a host that happened
 * to satisfy the check.
 *
 * Run: node --test test/ui/host-independence.test.mjs
 */
import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { AbiCoder } from 'ethers';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const coder = AbiCoder.defaultAbiCoder();
const ETH = 10n ** 18n;

// Read the pins out of the page, so a redeploy that moves an address moves
// this suite with it rather than leaving it asserting against a stale one.
const PAGE = readFileSync(new URL('../../zSwap.html', import.meta.url), 'utf8');
const pin = (name) => {
  const m = PAGE.match(new RegExp(`(?:const|let) ${name}="(0x[0-9a-fA-F]{40})"`));
  if (!m) throw new Error(`${name} is not pinned in zSwap.html - has it been renamed?`);
  return m[1].toLowerCase();
};
const SOLVERS = pin('SOLVERS_PIN');
const FILL = pin('SOLVER_FILL_PIN');
const EXEC = pin('SOLVER_EXEC_PIN');

const LANE_T = ['tuple(string,string,address,uint16,bool)[]'];

/** Every host the page is actually published on, plus the address form. */
const HOSTS = [
  ['its own address as a subdomain', 'https://0x000063afec5a39188bf36ce90c46a2689b9a8573.wei.limo/'],
  ['the zswap.wei name', 'https://zswap.wei.limo/'],
  ['the zerofi.wei name', 'https://zerofi.wei.limo/'],
  ['a .wei.domains gateway', 'https://zfi.wei.domains/'],
  ['a first-party domain', 'https://zerofi.sh/'],
  ['an IPFS gateway subdomain', 'https://bafybeifoydszhjmumsrw7ufdgliv5wiwwo6cfytzgw3c2mk3kldnhsrycm.ipfs.dweb.link/'],
];

describe('the roster is found however the page was reached', () => {
  for (const [what, url] of HOSTS) {
    test(`reads the pinned roster when served from ${what}`, async () => {
      const chain = new MockChain();
      chain.setNative(A.ACCOUNT, 10n * ETH);
      chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });

      const asked = { roster: false, exec: false };
      const orig = chain.ethCall.bind(chain);
      const lanes = [['0x', 'https://a.example', FILL, 50, true]];
      chain.ethCall = (tx, block) => {
        const to = (tx.to || '').toLowerCase(), data = tx.data || '';
        if (to === FILL && data.startsWith('0x495c73b0')) {          // EXEC()
          asked.exec = true;
          return coder.encode(['address'], [EXEC]);
        }
        if (to === SOLVERS && data.startsWith('0xe3b06401')) {        // solvers()
          asked.roster = true;
          return coder.encode(LANE_T, [lanes]);
        }
        return orig(tx, block);
      };

      const p = await loadPage({ chain, url });
      await p.connect();
      await p.typeAmount('amt', '1');

      assert.ok(asked.exec,
        `never asked the adapter for its executor on ${url} - the lane path was abandoned early`);
      assert.ok(asked.roster,
        `never read the roster at ${SOLVERS} on ${url} - no lane can load, and nothing says so`);
      p.close();
    });
  }

  // The pins are what make the above true. If they ever go back to being read
  // off whatever host served the page, the hostname becomes load-bearing again
  // and every published name silently loses its lanes.
  test('the roster and node list are named in the page, not derived from the URL', () => {
    assert.match(PAGE, /const SOLVERS_PIN="0x[0-9a-fA-F]{40}"/, 'the solver roster is not pinned');
    assert.match(PAGE, /const RPCS_PIN="0x[0-9a-fA-F]{40}"/, 'the node list is not pinned');
    const loadSolvers = PAGE.slice(PAGE.indexOf('const loadSolvers='), PAGE.indexOf('const lanePost='));
    assert.ok(!/selfFromUrl\(\)/.test(loadSolvers),
      'loadSolvers went back to reading the hostname; it is inert on every published name');
    const loadCurated = PAGE.slice(PAGE.indexOf('const loadCurated='), PAGE.indexOf('const OX_ETH='));
    assert.ok(!/selfFromUrl\(\)/.test(loadCurated),
      'loadCurated went back to reading the hostname; the governable node list stops loading');
  });
});
