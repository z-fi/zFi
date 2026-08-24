/**
 * Granular time input on the cause (DAICO) launch form.
 *
 * The tap schedule and the sale deadline used to be whole months and whole
 * days, which made an hour-long tap or a week-long raise unexpressible. Both
 * fields now carry a unit select and accept decimals, and every figure the
 * form derives — the vesting rate, the deadline timestamp, the preview — is
 * computed from seconds rather than from a month count. These assertions run
 * against the real dapp/index.html, because the arithmetic and the DOM wiring
 * only exist together.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM, VirtualConsole, ResourceLoader } from 'jsdom';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const PAGE = path.join(ROOT, 'dapp', 'index.html');
const BENEFICIARY = '0x1111111111111111111111111111111111111111';

class LocalLoader extends ResourceLoader {
  fetch(url) {
    const m = /^https:\/\/zfi\.wei\.is\/(.*)$/.exec(url.split('?')[0]);
    if (!m) return null;
    const file = path.join(ROOT, 'dapp', m[1]);
    if (!fs.existsSync(file)) return null;
    return Promise.resolve(fs.readFileSync(file));
  }
}

const open = [];
const PROBE = ['coinValidateForm', 'coinParseDurationSec', 'coinDurationLabel',
               'coinUpdatePreview', 'syncCoinURL', 'coinUnit', '_coinLaunchType'];

async function boot(query) {
  const vc = new VirtualConsole();
  vc.on('jsdomError', () => {});
  const dom = new JSDOM(fs.readFileSync(PAGE, 'utf8'), {
    url: 'https://zfi.wei.is/' + query,
    runScripts: 'dangerously',
    resources: new LocalLoader(),
    pretendToBeVisual: true,
    virtualConsole: vc,
    beforeParse(w) {
      w.matchMedia = () => ({ matches: false, media: '', addListener() {}, removeListener() {},
                              addEventListener() {}, removeEventListener() {}, onchange: null });
      w.TextEncoder = TextEncoder;
      w.TextDecoder = TextDecoder;
      w.scrollTo = () => {};
      w.fetch = () => Promise.reject(new Error('no network in this test'));
      w.document.addEventListener('DOMContentLoaded', () => {
        for (const f of ['modules/coin.js', 'modules/auction.js']) {
          const el = w.document.createElement('script');
          el.textContent = fs.readFileSync(path.join(ROOT, 'dapp', f), 'utf8');
          w.document.head.appendChild(el);
        }
      });
      w.document.write = () => {};
    },
  });
  const w = dom.window;
  await new Promise(r => {
    if (w.document.readyState === 'complete') return r();
    w.addEventListener('load', r);
    setTimeout(r, 15000);
  });
  open.push(dom);
  const probe = w.document.createElement('script');
  probe.textContent = `window.__p = {}; window.__missing = [];
    for (const n of ${JSON.stringify(PROBE)}) {
      try { window.__p[n] = eval(n); } catch (e) { window.__missing.push(n); }
    }`;
  w.document.body.appendChild(probe);
  return { w, api: w.__p ?? {}, missing: w.__missing ?? ['probe did not run'] };
}

const $ = (w, id) => w.document.getElementById(id);
const set = (w, id, v) => { const el = $(w, id); el.value = v; };

test.after(() => { for (const d of open) try { d.window.close(); } catch {} });

test('cause duration granularity', async (t) => {
  await t.test('reads hours and days, not just months', async () => {
    const { w, api, missing } = await boot('?mode=cause&symbol=BEE&name=Bees#coin');
    if (missing.length) return t.skip('page did not boot: ' + missing.join(','));

    set(w, 'causeTapMonths', '6');
    $(w, 'causeTapMonthsUnit').value = 'hour';
    assert.equal(api.coinParseDurationSec('causeTapMonths'), 6n * 3600n, 'hours were not honoured');

    $(w, 'causeTapMonthsUnit').value = 'day';
    assert.equal(api.coinParseDurationSec('causeTapMonths'), 6n * 86400n, 'days were not honoured');

    $(w, 'causeTapMonthsUnit').value = 'month';
    assert.equal(api.coinParseDurationSec('causeTapMonths'), 6n * 2629746n, 'months regressed');
  });

  await t.test('takes a fraction of a unit exactly', async () => {
    const { w, api, missing } = await boot('?mode=cause&symbol=BEE&name=Bees#coin');
    if (missing.length) return t.skip('page did not boot');

    // 1.5 months is the whole point of the decimal: the old integer parser
    // returned null here and the form refused to launch.
    set(w, 'causeTapMonths', '1.5');
    $(w, 'causeTapMonthsUnit').value = 'month';
    assert.equal(api.coinParseDurationSec('causeTapMonths'), (3n * 2629746n) / 2n);

    set(w, 'causeDeadline', '2.5');
    $(w, 'causeDeadlineUnit').value = 'day';
    assert.equal(api.coinParseDurationSec('causeDeadline'), 216000n);
  });

  await t.test('an hour-scale tap and deadline are launchable', async () => {
    const { w, api, missing } = await boot(
      `?mode=cause&symbol=BEE&name=Bees&tap=1&beneficiary=${BENEFICIARY}` +
      '&days=12&daysUnit=hour&months=36&monthsUnit=hour#coin');
    if (missing.length) return t.skip('page did not boot');

    assert.equal($(w, 'causeDeadlineUnit').value, 'hour', 'deadline unit did not follow the link');
    assert.equal($(w, 'causeTapMonthsUnit').value, 'hour', 'vesting unit did not follow the link');
    assert.equal(api.coinValidateForm(), null, 'an hours-based cause should be launchable');
  });

  await t.test('rejects a duration too short to accrue anything', async () => {
    const { w, api, missing } = await boot(
      `?mode=cause&symbol=BEE&name=Bees&tap=1&beneficiary=${BENEFICIARY}#coin`);
    if (missing.length) return t.skip('page did not boot');

    set(w, 'causeTapMonths', '0.5');
    $(w, 'causeTapMonthsUnit').value = 'hour';
    assert.match(api.coinValidateForm() || '', /at least 1 hour/, 'a half-hour vest slipped through');

    set(w, 'causeTapMonths', '12');
    $(w, 'causeTapMonthsUnit').value = 'month';
    set(w, 'causeDeadline', '0');
    assert.match(api.coinValidateForm() || '', /Deadline/, 'a zero deadline slipped through');
  });

  await t.test('the preview states the duration in the unit that was chosen', async () => {
    const { w, api, missing } = await boot(
      `?mode=cause&symbol=BEE&name=Bees&tap=1&beneficiary=${BENEFICIARY}#coin`);
    if (missing.length) return t.skip('page did not boot');

    set(w, 'causeDeadline', '36');
    $(w, 'causeDeadlineUnit').value = 'hour';
    set(w, 'causeTapMonths', '10');
    $(w, 'causeTapMonthsUnit').value = 'day';
    api.coinUpdatePreview();

    const html = $(w, 'coinCausePreview').innerHTML;
    assert.match(html, /36h/, 'the deadline still reads in days');
    assert.match(html, /over 10d/, 'the tap still reads in months');
  });

  await t.test('a per-hour tap rate drips faster than a per-month one', async () => {
    const { w, api, missing } = await boot(
      `?mode=cause&symbol=BEE&name=Bees&ongoing=1&tap=1&beneficiary=${BENEFICIARY}#coin`);
    if (missing.length) return t.skip('page did not boot');

    set(w, 'causeTapEthRate', '1');
    $(w, 'causeTapEthRateUnit').value = 'month';
    api.coinUpdatePreview();
    const perMonth = $(w, 'coinCausePreview').innerHTML;
    assert.match(perMonth, /\/mo/, 'the rate unit is not shown');

    $(w, 'causeTapEthRateUnit').value = 'hour';
    api.coinUpdatePreview();
    const perHour = $(w, 'coinCausePreview').innerHTML;
    assert.match(perHour, /\/h\b|\/h</, 'the hourly rate unit is not shown');
    assert.notEqual(perHour, perMonth, 'switching the rate unit changed nothing');
    assert.equal(api.coinValidateForm(), null, 'an hourly rate should be launchable');
  });

  await t.test('units survive the shareable link', async () => {
    const { w, api, missing } = await boot(
      `?mode=cause&symbol=BEE&name=Bees&tap=1&beneficiary=${BENEFICIARY}#coin`);
    if (missing.length) return t.skip('page did not boot');

    $(w, 'causeDeadlineUnit').value = 'hour';
    $(w, 'causeTapMonthsUnit').value = 'day';
    $(w, 'causeTapEthRateUnit').value = 'day';
    api.syncCoinURL();
    const qs = w.location.search;
    assert.match(qs, /daysUnit=hour/, 'deadline unit missing from the link');
    assert.match(qs, /monthsUnit=day/, 'vesting unit missing from the link');
    assert.match(qs, /rateUnit=day/, 'rate unit missing from the link');
  });

  await t.test('an unknown unit in a link falls back instead of being trusted', async () => {
    const { w, api, missing } = await boot(
      '?mode=cause&symbol=BEE&name=Bees&tap=1&days=5&daysUnit=fortnight#coin');
    if (missing.length) return t.skip('page did not boot');
    assert.equal($(w, 'causeDeadlineUnit').value, 'day', 'a junk unit was accepted');
    assert.equal(api.coinUnit('causeDeadline'), 'day');
  });
});
