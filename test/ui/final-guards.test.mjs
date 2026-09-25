import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { A, MockChain, loadPage, closeAllPages, CAUSE_CLONE, HTML_PATH } from './harness.mjs';

after(closeAllPages);

const ONE = 10n ** 18n;

describe('recipients the page refuses', () => {
  test('every SLOW contract, on the plain path as well as the bridge', async () => {
    const p = await loadPage({ chain: new MockChain(), walletless: true, hash: null });
    for (const k of ['SLOW', 'SLOW_GATE', 'ARRIVAL', 'RELAY'])
      assert.match(p.window.eval(`rcErr(${k})`), /bridge itself/, k);
    assert.equal(p.window.eval(`rcErr(${JSON.stringify(A.OTHER)})`), '');
    p.close();
  });
});

describe('a cause is a Moloch clone or it is not a cause', () => {
  const DAO = '0x00000000000000000000000000000000cafe0101';
  const LOOT = '0x00000000000000000000000000000000cafe0102';
  const SHARES = '0x00000000000000000000000000000000cafe0103';
  const chainWith = (code) => {
    const chain = new MockChain();
    if (code) chain.code.set(DAO, code);
    chain.setToken(LOOT, { symbol: 'CAUSE', decimals: 18, name: 'Loot' });
    chain.setCause(LOOT, { dao: DAO, shares: SHARES, sharesSupply: ONE, lootSupply: ONE, treasury: ONE });
    return chain;
  };

  test('the launcher\'s own clone is accepted', async () => {
    const p = await loadPage({ chain: chainWith(null), walletless: true, hash: null });
    const r = await p.window.eval(`cbLook(${JSON.stringify(LOOT)})`);
    assert.equal(r.dao.toLowerCase(), DAO);
    assert.equal(p.chain.code.get(DAO), CAUSE_CLONE);
    p.close();
  });

  test('a look-alike that answers loot() and shares() is not', async () => {
    const p = await loadPage({ chain: chainWith('0x60006000fd'), walletless: true, hash: null });
    const r = await p.window.eval(`cbLook(${JSON.stringify(LOOT)})`);
    assert.equal(r.dao, '', 'a contract that is not the clone must not be treated as a cause DAO');
    p.close();
  });
});

describe('the Markets list', () => {
  test('keeps comparison signs and apostrophes in a question, escaped', async () => {
    const p = await loadPage({ chain: new MockChain(), walletless: true, hash: null });
    const html = p.window.eval(`(()=>{const m=${JSON.stringify('Will ETH be > $5k & <b>up</b> on Dec 31? It\'s close')};
      return m.replace(/\\p{C}/gu,"").slice(0,140).replace(/[<&]/g,c=>c<"<"?"&amp;":"&lt;")})()`);
    const d = p.window.document.createElement('div');
    d.innerHTML = html;
    assert.equal(d.textContent, 'Will ETH be > $5k & <b>up</b> on Dec 31? It\'s close');
    assert.equal(d.children.length, 0, 'no markup survives');
    assert.ok(fs.readFileSync(HTML_PATH, 'utf8').includes('.replace(/[<&]/g,c=>c<"<"?"&amp;":"&lt;")}${m.d.length>140'), 'mkRow renders through the same escape');
    p.close();
  });
});
