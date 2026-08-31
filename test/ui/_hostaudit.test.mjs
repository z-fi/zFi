import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { AbiCoder } from 'ethers';
import { readFileSync } from 'node:fs';
import { A, MockChain, loadPage, fixedRateQuoter, closeAllPages } from './harness.mjs';
after(closeAllPages);
const coder = AbiCoder.defaultAbiCoder();
const ETH = 10n ** 18n;
const PAGE = readFileSync(new URL('../../zSwap.html', import.meta.url), 'utf8');
const pin = n => PAGE.match(new RegExp(`const ${n}="(0x[0-9a-fA-F]{40})"`))[1].toLowerCase();
const FILL = pin('SOLVER_FILL_PIN'), EXEC = pin('SOLVER_EXEC_PIN');
const SELF = '0x' + 'ab'.repeat(20), LIST = '0x' + 'cd'.repeat(20), RPCS = '0x' + 'ef'.repeat(20);
const LANE_T = ['tuple(string,string,address,uint16,bool)[]'];

function chainOf() {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n * ETH);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ETH });
  const ethCall = chain.ethCall.bind(chain);
  chain.ethCall = (tx, block) => {
    const to = (tx.to || '').toLowerCase();
    if (to === SELF) {
      if (tx.data.startsWith('0x0576137c')) return coder.encode(['address'], [LIST]);
      if (tx.data.startsWith('0x4f3391f6')) return coder.encode(['address'], [FILL]);
      if (tx.data.startsWith('0x0b6feb61')) return coder.encode(['address'], [RPCS]);
    }
    if (to === FILL && tx.data.startsWith('0x495c73b0')) return coder.encode(['address'], [EXEC]);
    if (to === LIST && tx.data.startsWith('0xe3b06401'))
      return coder.encode(LANE_T, [[['0x', 'https://api.zfi.wei.is/0x', FILL, 50, true]]]);
    if (to === RPCS && tx.data.startsWith('0xd77e4c79'))
      return coder.encode(['string[]'], [['https://curated.example/rpc']]);
    return ethCall(tx, block);
  };
  return chain;
}

const HOSTS = {
  address: 'https://' + SELF + '.1.w3link.io/',
  named: 'https://zerofi.wei.limo/',
  ipfs: 'https://bafybeiabc.ipfs.dweb.link/',
  pathgw: 'https://dweb.link/ipfs/bafybeiabc/',
  file: 'file:///Users/z/zFi/zSwap.html',
};

describe('host-dependent behaviour', () => {
  for (const [kind, url] of Object.entries(HOSTS)) {
    test(kind, async () => {
      const chain = chainOf();
      const p = await loadPage({ walletless: true, chain, url, hash: 'token=ETH&out=USDC' });
      const w = p.window;
      await new Promise(r => setTimeout(r, 300));
      const foot = w.document.getElementById('footAddr').innerHTML;
      console.log(`\n### ${kind}  ${url}`);
      console.log('  hostname          :', w.location.hostname, '| origin:', w.location.origin);
      console.log('  footAddr          :', JSON.stringify(foot));
      console.log('  solverLanes       :', JSON.stringify(w.eval('typeof solverLanes==="undefined"?"n/a":solverLanes')));
      console.log('  rpcPool           :', JSON.stringify(w.eval('rpcPool')));
      console.log('  curated flag      :', w.eval('curated'));
      console.log('  selfFromUrl()     :', JSON.stringify(w.eval('selfFromUrl()')));
      console.log('  WC meta url       :', JSON.stringify(w.eval('location.origin')));
      console.log('  crypto.subtle     :', typeof w.crypto?.subtle);
      const calls = (chain.httpLog||[]).map(c=>c.url+' '+c.method);
      console.log('  fetched RPCS sel  :', PAGE.length>0 && JSON.stringify([...new Set((chain.httpLog||[]).map(c=>c.url))]));
      // share link
      try { console.log('  share link base   :', w.eval('(location.origin&&location.origin!=="null"?location.origin+location.pathname:location.href.split("#")[0])')); } catch(e){ console.log('  share err', e.message); }
    });
  }
});
