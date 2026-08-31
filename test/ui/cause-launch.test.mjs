/**
 * Launching a cause — the launcher's B-side.
 *
 * The coin path opens a market; this one opens a fund. It shares the panel,
 * the name, the symbol and the logo, and swaps supply/valuation/allocation for
 * two numbers: a goal and how long it runs.
 *
 * WHAT IS ACTUALLY AT RISK is the calldata, and it is worth saying why this
 * suite decodes it rather than trusting a selector. `safeSummonDAICO` takes
 * four structs, and because all four are STATIC tuples they are inlined — the
 * head is fifty-two words before the first byte of a string, and the page
 * writes it as a template with only seven words spliced in. A template is the
 * right call for a format whose governance words never vary, but its failure
 * mode is silent: a word in the wrong slot still encodes, still simulates
 * against a mock, and deploys a DAO whose quorum, tap or sale ceiling is not
 * what the form said. So the head is decoded here word by word against the
 * ABI layout, exactly as the coin path's `encLaunch` is.
 *
 * The economics are pinned for the same reason. Price is the goal divided by
 * ten million, and the launcher's own guard exists because integer division
 * floors: a price of zero mints the entire ceiling to whoever calls first, for
 * nothing.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { loadPage, MockChain, A } from './harness.mjs';

const SUMMONER = '0x00000000004473e1f31c8266612e7fd5504e6f2a';
const OFFERING = '0x000000a4ad929c9e108ad2b1d2fbede0c2ae57e1';
const TAPVEST = '0x0000000060cdd33cbe020fae696e70e7507bf56d';
const RENDERER = '0x000000000011c799980827f52d3137b4abd6e654';
const LOOT_SENTINEL = '0x00000000000000000000000000000000000003ef';
const SEL_DAICO = '4e1e3b11';
const SEL_SETALLOW = 'da46098c';
const SEL_CONFIGURE = 'fca53be5';

const ONE = 10n ** 18n;
const UNITS = 10_000_000n;

async function openLauncher(kind = 'cause', opts = {}) {
  const chain = new MockChain();
  chain.setNative(A.ACCOUNT, 10n ** 19n);
  const p = await loadPage({ chain, ...opts });
  await p.connect();
  p.click('ln');
  p.select('lnKind', kind);
  await p.settle();
  return p;
}

/** Fill the four fields a cause asks for and press Launch. */
async function launch(p, { name = 'Clean Water', sym = 'WATER', goal = '10', days = '30' } = {}) {
  p.type('lnName', name);
  p.type('lnSym', sym);
  p.type('lnGoal', goal);
  p.type('lnDays', days);
  await p.settle();
  p.click('lnGo');
  await p.waitFor(() => p.chain.sent.length > 0, { label: 'the launch transaction' });
  await p.settle();
  return p.chain.sent.at(-1);
}

const word = (data, i) => BigInt('0x' + data.slice(10 + i * 64, 10 + (i + 1) * 64));
const addrAt = (data, i) => '0x' + data.slice(10 + i * 64 + 24, 10 + (i + 1) * 64);
/** Read a dynamic tail by the offset sitting in head word `i`. */
const tailAt = (data, i) => data.slice(10 + Number(word(data, i)) * 2);
const strAt = (data, i) => {
  const t = tailAt(data, i);
  const n = Number(BigInt('0x' + t.slice(0, 64)));
  return Buffer.from(t.slice(64, 64 + n * 2), 'hex').toString('utf8');
};

test('launching a cause', async (t) => {
  await t.test('swaps the market fields for a goal and a duration', async () => {
    const p = await openLauncher('cause');
    for (const id of ['lnSupplyL', 'lnMcapL', 'lnAllocL', 'lnMktL']) {
      assert.ok(!p.visible(id), `${id} should be hidden for a cause`);
    }
    for (const id of ['lnGoalL', 'lnDaysL', 'lnVestL']) {
      assert.ok(p.visible(id), `${id} should be shown for a cause`);
    }
    // Name, symbol and logo are asked once and mean the same thing either way.
    for (const id of ['lnName', 'lnSym', 'lnArtRow']) {
      assert.ok(p.visible(id), `${id} should be shared with the coin path`);
    }
  });

  await t.test('names what is being made, everywhere the panel says it', async () => {
    const p = await openLauncher('cause');
    // The heading is the first thing read and the last thing anyone thinks to
    // update. Left saying "coin" over a goal and a deadline, it contradicts
    // every other word on the panel.
    assert.equal(p.text('lnTitle'), 'Launch a cause');
    // NOT "refundable". Burn-back returns a pro-rata share of what the cause
    // has not yet drawn, and the DAO can switch the right off entirely - the
    // panel says so itself further down. A word promising the whole amount
    // back, where a backer reads it as their own protection, is the one line
    // of copy here that could cost somebody the difference.
    assert.match(p.text('lnSub'), /burn back for whatever you have not drawn/);
    assert.doesNotMatch(p.text('lnSub'), /refundable/i);
    assert.equal(p.$('lnName').placeholder, 'Feed Ducks');
    assert.equal(p.$('lnSym').placeholder, 'DUCK');
    assert.match(p.$('rc').placeholder, /Beneficiary/);

    p.select('lnKind', 'coin');
    await p.settle();
    assert.equal(p.text('lnTitle'), 'Launch a coin');
    // Not "forever": the fee accrues only if the market trades, and a tithe
    // comes off the top. State the fact; this file does not sell anywhere else.
    assert.match(p.text('lnSub'), /0\.4% of each trade goes to the creator/);
    assert.doesNotMatch(p.text('lnSub'), /forever/i);
    assert.equal(p.$('lnName').placeholder, 'Zero Cat');
    assert.match(p.$('rc').placeholder, /Creator/);
  });

  await t.test('offers each kind as one word, so no option can truncate', async () => {
    const p = await openLauncher('cause');
    const labels = [...p.$('lnKind').options].map(o => o.textContent);
    assert.deepEqual(labels, ['Coin', 'Cause']);
    // The explanation belongs to the heading and the note, which have the room
    // for it; a select rendered at a phone's width does not.
    for (const l of labels) assert.ok(!/\s/.test(l), `"${l}" is more than one word`);
  });

  await t.test('goes back to the coin fields when the kind is switched back', async () => {
    const p = await openLauncher('cause');
    p.select('lnKind', 'coin');
    await p.settle();
    assert.ok(p.visible('lnMcapL'), 'the market fields did not come back');
    assert.ok(!p.visible('lnGoalL'), 'the goal field outlived the cause mode');
  });

  await t.test('says what a backer gets, not what a trader would', async () => {
    const p = await openLauncher('cause');
    p.type('lnGoal', '10');
    p.type('lnDays', '30');
    await p.settle();
    const note = p.text('lnNote');
    // 10 ETH over 10,000,000 units = 1e-6 ETH each, so 1 ETH backs 1,000,000.
    assert.match(note, /1 ETH backs 1,000,000 units/);
    // "at full funding" rather than "reaches you": the tap pays that rate only
    // if the goal is met, and the sentence after it prices the shortfall.
    assert.match(note, /ETH a day at full funding, over 12 months/);
    assert.match(note, /at a tenth of the goal it empties in/,
      'the note must price an under-subscribed raise, not just the happy path');
    // The note must name BOTH clocks, because the gap between them is the
    // whole value of the token it is describing.
    assert.match(note, /burn back for the rest/);
    assert.doesNotMatch(note, /market cap|creator keeps/i);
  });

  await t.test('sends one transaction to the summoner, and pays for the founding share',
    async () => {
      const p = await openLauncher('cause');
      const tx = await launch(p);
      assert.equal(p.chain.sent.length, 1, 'a cause should launch in one transaction');
      assert.equal(tx.to.toLowerCase(), SUMMONER);
      assert.equal(tx.data.slice(2, 10), SEL_DAICO);
      // The founder's one share is bought at the price a backer pays, so their
      // claim on the treasury has the same shape as everyone else's.
      assert.equal(BigInt(tx.value), (10n * ONE) / UNITS, 'founder share not paid for at sale price');
    });

  await t.test('encodes the head the ABI layout actually calls for', async () => {
    const p = await openLauncher('cause');
    const { data } = await launch(p);

    assert.equal(strAt(data, 0), 'Clean Water', 'name');
    assert.equal(strAt(data, 1), 'WATER', 'symbol');
    assert.match(strAt(data, 2), /^data:application\/json,/, 'metadata is inline, not a gateway link');

    assert.equal(word(data, 3), 1000n, 'quorum should be 10%');
    assert.equal(word(data, 4), 1n, 'a cause must be ragequittable — that is the whole format');
    assert.equal(addrAt(data, 5), RENDERER, 'renderer');

    // SafeConfig starts at word 10: threshold, TTL, timelock, quorumAbsolute,
    // then seventeen words of features this format does not use.
    assert.equal(word(data, 10), ONE, 'proposalThreshold');
    assert.equal(word(data, 11), 604800n, 'proposalTTL');
    assert.equal(word(data, 12), 172800n, 'timelockDelay');
    assert.equal(word(data, 13), ONE, 'quorumAbsolute');
    for (let i = 14; i <= 30; i++) assert.equal(word(data, i), 0n, `SafeConfig word ${i}`);

    // SaleModule (31..37) is empty: the sale is wired by hand through
    // ShareOffering below, and a singleton here would be granted an allowance
    // nothing would ever use.
    for (let i = 31; i <= 37; i++) assert.equal(word(data, i), 0n, `SaleModule word ${i}`);

    // TapModule.
    assert.equal(addrAt(data, 38), TAPVEST, 'tap singleton');
    assert.equal(word(data, 39), 0n, 'the tap streams ether, not a token');
    assert.equal(word(data, 40), 10n * ONE, 'tap budget should be the whole goal');
    assert.equal(addrAt(data, 41).toLowerCase(), A.ACCOUNT.toLowerCase(), 'beneficiary defaults to you');
    /* The release clock, NOT the raise clock. TapVest accrues from the summon
       on wall-clock time regardless of when anyone backs the cause, so vesting
       over the raise window would leave the whole budget claimable exactly
       when backing closes — and a late backer's burn worth nothing. */
    assert.equal(word(data, 42), (10n * ONE) / 31556952n, 'tap rate should spend the goal over the release window');

    // SeedModule (43..50) is empty: a cause creates no pool.
    for (let i = 43; i <= 50; i++) assert.equal(word(data, i), 0n, `SeedModule word ${i}`);
  });

  await t.test('mints and sells LOOT, so the raise never hands over the vote', async () => {
    const p = await openLauncher('cause');
    const { data } = await launch(p);

    // initHolders / initShares: the founder, and one share.
    const holders = tailAt(data, 7);
    assert.equal(BigInt('0x' + holders.slice(0, 64)), 1n, 'one founding holder');
    assert.equal('0x' + holders.slice(88, 128), A.ACCOUNT.toLowerCase(), 'founder is the caller');
    const shares = tailAt(data, 8);
    assert.equal(BigInt('0x' + shares.slice(64, 128)), ONE, 'founder gets exactly one share');
    assert.equal(BigInt('0x' + tailAt(data, 9).slice(0, 64)), 0n, 'no loot is minted at summon');

    // extraCalls: setAllowance on the DAO, then configure on ShareOffering.
    const calls = tailAt(data, 51);
    assert.equal(BigInt('0x' + calls.slice(0, 64)), 2n, 'two init calls');
    const at = (byteOff) => calls.slice(64 + byteOff * 2);
    const elem = (i) => at(Number(BigInt('0x' + calls.slice(64 + i * 64, 128 + i * 64))));

    /* Each element is (address to, uint256 value, bytes data). The bytes are
       dynamic, so the tuple's own head is three words and its calldata begins
       after a length word at 0x60 — data therefore starts 256 hex chars in. */
    const callTo = (e) => '0x' + e.slice(24, 64);
    const callData = (e) => e.slice(256);

    const allow = elem(0);
    const ad = callData(allow);
    assert.equal(ad.slice(0, 8), SEL_SETALLOW);
    assert.equal('0x' + ad.slice(32, 72), OFFERING, 'the offering is the spender');
    assert.equal('0x' + ad.slice(96, 136), LOOT_SENTINEL,
      'allowance must be keyed to the LOOT mint sentinel, not to shares');

    const cfg = elem(1);
    assert.equal(callTo(cfg), OFFERING, 'configure goes to ShareOffering');
    const cd = callData(cfg);
    assert.equal(cd.slice(0, 8), SEL_CONFIGURE);
    assert.equal('0x' + cd.slice(32, 72), LOOT_SENTINEL,
      'the sale must sell the same token the allowance permits');
    assert.equal(BigInt('0x' + cd.slice(136, 200)), (10n * ONE) / UNITS, 'price per unit');
    // 9,999,999 for sale: the founder's one share is part of the ten million.
    assert.equal(BigInt('0x' + cd.slice(264, 328)), (UNITS - 1n) * ONE, 'sale ceiling');
  });

  await t.test('releases far slower than it raises, so a late backer still has a claim',
    async () => {
      const p = await openLauncher('cause');
      const { data } = await launch(p, { goal: '10', days: '30' });
      const rate = word(data, 42);
      // What has been released by the time backing closes is what a backer who
      // arrives on the last day CANNOT burn back for. At the default it is
      // under a tenth; equal clocks would make it all of it.
      const releasedByDeadline = rate * 30n * 86400n;
      const share = Number(releasedByDeadline * 1000n / (10n * ONE)) / 1000;
      assert.ok(share < 0.1,
        `${(share * 100).toFixed(1)}% of the goal is claimable when backing closes`);
    });

  await t.test('gives the founding share to the launcher, not to the beneficiary',
    async () => {
      /* Two different people the moment the beneficiary field is filled in. The
         founding share is bought with the LAUNCHER's ether and carries the only
         vote the DAO has; the beneficiary is merely where the stream points.
         Conflating them handed the whole electorate to a third party. */
      const p = await openLauncher('cause');
      const BEN = '0x00000000000000000000000000000000000b0b0b';
      p.type('rc', BEN);
      const { data } = await launch(p);

      const holders = tailAt(data, 7);
      assert.equal('0x' + holders.slice(88, 128), A.ACCOUNT.toLowerCase(),
        'the founding share must go to whoever signed the launch');
      // ...while the tap's beneficiary IS the address that was named.
      assert.equal(addrAt(data, 41).toLowerCase(), BEN, 'the stream should point at the beneficiary');
    });

  await t.test('names the token it just made, not only the DAO', async () => {
    /* The receipt used to give the DAO address alone, so the launcher had no
       way to reach the thing they had created — the backing and burning paths
       are both keyed to the loot token, which is a CREATE2 child of the DAO. */
    const p = await openLauncher('cause');
    await launch(p);
    await p.settle();
    const html = p.$('stat').innerHTML;
    assert.match(html, /etherscan\.io\/token\/0x[0-9a-fA-F]{40}/,
      'the receipt should link the token, not just the DAO');
    /* The page also tries to add the token to the list, but that is best-effort
       by design — it reads the contract's own symbol, which does not exist here
       because the mock cannot deploy the CREATE2 child the summon would. The
       link is the part that must always be right. */
  });

  await t.test('still produces the exact bytes the fork test replays', async () => {
    /* test/CauseLaunchCalldata.t.sol sends test/fixtures/cause-launch.json to
       the REAL SafeSummoner on a mainnet fork. That is the only check on this
       encoding that cannot be wrong in the same direction as the encoder — but
       only while the fixture matches what the page builds today. A stale
       fixture would keep passing against bytes nobody ships any more, which is
       worse than no fork test at all.

       So this regenerates the calldata in-process and compares. If it fails:
         node script/dump-cause-calldata.mjs
       and re-run the fork suite. */
    const fixture = JSON.parse(
      await readFile(new URL('../fixtures/cause-launch.json', import.meta.url), 'utf8'));
    const f = fixture.form;

    const p = await openLauncher('cause', { fixedRandom: true });
    p.type('lnName', f.name);
    p.type('lnSym', f.symbol);
    p.type('lnGoal', f.goal);
    p.type('lnDays', f.days);
    p.select('lnVest', f.vest);
    await p.settle();
    p.click('lnGo');
    await p.waitFor(() => p.chain.sent.length > 0, { label: 'the launch transaction' });

    const tx = p.chain.sent.at(-1);
    assert.equal(tx.to, fixture.to, 'the launch now targets a different contract');
    assert.equal(BigInt(tx.value ?? '0x0'), BigInt(fixture.value), 'the founding share price changed');

    /* Everything but the deadline, which is wall-clock and differs by however
       long ago the fixture was generated. Its position is recorded rather than
       searched for, because it sits inside a bytes tail at a 4-byte offset from
       the word grid — see the dumper. */
    const mask = (hex) => {
      const body = hex.slice(10);
      return body.slice(0, fixture.deadlineAt) + '0'.repeat(64)
        + body.slice(fixture.deadlineAt + 64);
    };
    assert.equal(tx.data.slice(0, 10), fixture.data.slice(0, 10), 'the selector changed');
    assert.equal(mask(tx.data), mask(fixture.data),
      'cause calldata changed — regenerate: node script/dump-cause-calldata.mjs');

    // The masked word still has to be a 30-day window, just a fresher one.
    const dl = BigInt('0x' + tx.data.slice(10 + fixture.deadlineAt, 10 + fixture.deadlineAt + 64));
    const now = BigInt(Math.floor(Date.now() / 1000));
    assert.ok(dl > now + 29n * 86400n && dl < now + 31n * 86400n,
      `deadline ${dl} is not thirty days out from ${now}`);
  });

  await t.test('refuses a raise too small to price a unit', async () => {
    const p = await openLauncher('cause');
    // 10,000,000 units at any price below 1 wei each rounds the price to zero,
    // which would mint the whole ceiling to the first caller for nothing.
    p.type('lnGoal', '0.000000000001');
    p.type('lnDays', '30');
    await p.settle();
    p.type('lnName', 'Dust');
    p.type('lnSym', 'DUST');
    await p.settle();
    p.click('lnGo');
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'launched a sale that would be free');
  });

  await t.test('refuses a window too short for the tap to mean anything', async () => {
    const p = await openLauncher('cause');
    p.type('lnName', 'Rush');
    p.type('lnSym', 'RUSH');
    p.type('lnGoal', '10');
    p.type('lnDays', '0.001'); // ~86 seconds
    await p.settle();
    p.click('lnGo');
    await p.settle();
    assert.equal(p.chain.sent.length, 0, 'launched a cause that closes before anyone can back it');
  });
});
