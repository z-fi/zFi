/**
 * A cause's logo, shown wherever a launched coin's art is.
 *
 * A coin carries its own art: its contractURI() is a base64 JSON document the
 * launcher composes from an SSTORE2 image. Cause loot has no contractURI at all.
 * The logo lives on the DAO, as the orgURI the launch panel writes, and the DAO
 * returns it from contractURI(). So the page has to go token -> DAO() -> DAO
 * contractURI(), and only after the DAO names the token back as its loot:
 * otherwise any contract with a DAO() getter could borrow another cause's face.
 */
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { loadPage, MockChain, A, fixedRateQuoter, closeAllPages } from './harness.mjs';

after(closeAllPages);

const DAO = '0x00000000000000000000000000000000cafe0001';
const LOOT = '0x00000000000000000000000000000000cafe0002';
const SHARES = '0x00000000000000000000000000000000cafe0003';
const ONE = 10n ** 18n;
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQdvt9AAAADElEQVQI12P4z8AAAAMBAQC1o38rAAAAAElFTkSuQmCC';
const IMG = 'data:image/png;base64,' + PNG;

const doc = (image = IMG) => JSON.stringify({ name: 'Clean Water', symbol: 'CAUSE', image, launchType: 'cause' });
// The three shapes a DAO's contractURI arrives in: the launch panel's orgURI,
// DUNABrandRenderer's composed document, and the base64 form coins use.
const FORMS = {
  'the launch panel\'s URL-encoded orgURI': d => 'data:application/json,' + encodeURIComponent(d),
  'a ;utf8 document': d => 'data:application/json;utf8,' + d,
  'a base64 document': d => 'data:application/json;base64,' + Buffer.from(d, 'utf8').toString('base64'),
};

function causeChain({ uri = FORMS['the launch panel\'s URL-encoded orgURI'](doc()) } = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n ** 19n);
  chain.quoteHandler = fixedRateQuoter({ rate: 3000n * ONE });
  chain.setToken(LOOT, { symbol: 'CAUSE', decimals: 18, name: 'Clean Water Loot' });
  chain.setCause(LOOT, {
    dao: DAO, shares: SHARES, sharesSupply: ONE, lootSupply: 9_999_999n * ONE, treasury: 4n * ONE,
    price: 10n ** 12n, deadline: BigInt(Math.floor(Date.now() / 1000) + 22 * 86400),
    remaining: 5_000_000n * ONE,
  });
  chain.setErc20(LOOT, A.ACCOUNT, 1_000_000n * ONE);
  chain.contractURIs = { [DAO]: uri };
  return chain;
}

const remembers = (addr, sym, cause) => ({
  'zswap:custom': JSON.stringify([{ sym, addr: addr.toLowerCase(), dec: 18, std: 'ft', cause }]),
});

async function pickerRow(p, sym) {
  p.click('toPick');
  await p.settle();
  const row = [...p.$('tkList').querySelectorAll('.tkr')].find(r => r.querySelector('b')?.textContent === sym);
  assert.ok(row, `${sym} is not in the picker`);
  return row;
}

test('a cause shows its DAO\'s logo', async (t) => {
  for (const [form, wrap] of Object.entries(FORMS)) {
    await t.test(`in the picker before it is chosen, from ${form}`, async () => {
      const p = await loadPage({ chain: causeChain({ uri: wrap(doc()) }), storage: remembers(LOOT, 'CAUSE', 1) });
      await p.connect();
      await p.waitFor(() => p.$('toSel').innerHTML.includes('Causes'), { label: 'causes group' });
      const row = await pickerRow(p, 'CAUSE');
      const img = row.querySelector('img');
      assert.ok(img, 'a remembered cause shows the generated letter instead of its logo');
      assert.equal(img.getAttribute('src'), IMG, 'the bytes are not the ones the DAO holds');
      assert.doesNotMatch(row.innerHTML, /<svg|<script/i, 'art must never be inlined');
      p.close();
    });
  }

  await t.test('in the pill once it is chosen, though nothing marked it a cause', async () => {
    const p = await loadPage({ chain: causeChain(), storage: remembers(LOOT, 'CAUSE', 0) });
    await p.connect();
    p.pickToken('fromSel', 'CAUSE');
    await p.waitFor(() => p.$('fromIcon').querySelector('img'), { label: 'pill logo' });
    assert.equal(p.$('fromIcon').querySelector('img').getAttribute('src'), IMG);
    p.close();
  });

  await t.test('in a book row for a cause the picker never loaded', async () => {
    const chain = causeChain();
    chain.setErc20(A.USDC, A.ACCOUNT, 500_000n * 10n ** 6n);
    chain.recent = [{
      id: 5n, board: A.SB2, v2: 1, pf: true, exp: 0n, nA: false, nB: false, cp: A.ZERO, maker: A.OTHER,
      tA: LOOT, aA: 1000n * ONE, symA: 'CAUSE', decA: 18, tB: A.WETH, aB: ONE, symB: 'WETH', decB: 18,
    }];
    const p = await loadPage({ chain });
    await p.connect();
    p.click('tabBook');
    await p.waitFor(() => p.$('book').querySelector('[data-bf="0"]'), { label: 'filter chips' });
    p.click(p.$('book').querySelector('[data-bf="0"]'));
    await p.waitFor(() => p.$('book').querySelector(`img[src="${IMG}"]`), { label: 'cause logo in the row' });
    p.close();
  });
});

test('a cause shows no logo it cannot vouch for', async (t) => {
  await t.test('when the DAO does not name the token back', async () => {
    const chain = causeChain();
    const other = '0x00000000000000000000000000000000cafe0009';
    chain.setToken(other, { symbol: 'FAKE', decimals: 18, name: 'Not A Cause' });
    chain.causes.set(other.toLowerCase(), chain.causes.get(LOOT.toLowerCase()));
    const p = await loadPage({ chain, storage: remembers(other, 'FAKE', 1) });
    await p.connect();
    await p.settle();
    const row = await pickerRow(p, 'FAKE');
    assert.equal(row.querySelector('img'), null, 'borrowed the logo of a DAO that never named it');
    p.close();
  });

  await t.test('when the image is not an inline base64 picture', async () => {
    for (const image of ['https://example.com/logo.png', 'data:image/svg+xml;base64,PHN2Zy8+" onerror="alert(1)']) {
      const p = await loadPage({ chain: causeChain({ uri: FORMS['a ;utf8 document'](doc(image)) }),
        storage: remembers(LOOT, 'CAUSE', 1) });
      await p.connect();
      await p.settle();
      const row = await pickerRow(p, 'CAUSE');
      assert.equal(row.querySelector('img'), null, `rendered ${image}`);
      assert.doesNotMatch(row.innerHTML, /onerror/);
      p.close();
    }
  });
});
