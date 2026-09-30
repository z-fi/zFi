/**
 * tacit1 addresses with a pool lane (flag 0x04), and with 0x80 saying the Ethereum-side key is
 * the Bitcoin spend key, against the vectors Tacit pins in tests/tacit-address-pool.mjs: a V1 send still reads the Ethereum-side key from any of
 * them, a pool send reads the bp1 address the pool lane carries, lanes a reader does not
 * know are skipped, and a known lane that is short is refused.
 */
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { MockChain, loadPage, closeAllPages } from './harness.mjs';

after(closeAllPages);

const REAL_RECORD = 'tacit1qqpsxr8grjvk4asyvlk4aguyd0suvtmg3cevxxcznec82u70rrxps7hjqgedd68hq0su4dzzvcsl482xhz8put8p5fv7qctmg7k9twznf6lngqcvaqwfj6hkq3n76h4rs347r330dz8r9scmq208qatneuvvcxr67gpe2s29';
const V0 = 'tacit1qqps9xyupdmvk43ew87un0hnrmqxcdtq7vjf6mhfuhvrc4mz2ktwqhm0qdk5lnmv6yyy73yd0mccau2em5n66y5a0pyh3xfuhzwmf8g39kctxq5cns9hdj6k89clmjd77v0vqmp4vrejf8twa8jas0zhvf2edczlduk6e0c7';
const BP = 'bp1qf5rdn2trtk94rqya5637yeqyvp5qllkeztth8dfesrc5x9tvqluqlahm5yyv7km9tq9s9spmdqqukkw46zudgxu7aawem8fyey0kseqh6xr40k26x7ew8zqujenn45kk2kh47aqzxxj3pp8q2rukjss02vszf7eaa';
const U85 = 'tacit1qzzs9xyupdmvk43ew87un0hnrmqxcdtq7vjf6mhfuhvrc4mz2ktwqhm0qdk5lnmv6yyy73yd0mccau2em5n66y5a0pyh3xfuhzwmf8g39kctxqngxmx5kxhvt2xqfmf4rufjqgcrgplldjykhww6nnq83gv2kcplcplm0hgggeadk2kqtqtqrk6qpedvat59c6sdeam6ankwjfjgldpjp05v82lv45dajuwype9n88tfdv4d0ta6qyvd9zzzwq58ed9pq75emyyf75';
const UNIFIED = 'tacit1qqrs9xyupdmvk43ew87un0hnrmqxcdtq7vjf6mhfuhvrc4mz2ktwqhm0qdk5lnmv6yyy73yd0mccau2em5n66y5a0pyh3xfuhzwmf8g39kctxq5cns9hdj6k89clmjd77v0vqmp4vrejf8twa8jas0zhvf2edczldupxsdkdfvdwck5vqnkn28cnyq3sxsrl7myfdwua48xq0zsc4dsrlsrlklwss3n6mv4vqkqkq8d5qrj6e6hgt34qmnmh4m8vayny376ryzlgcw47etgmm9cugrjtxwwkj6e267hm5qgc62yyyupg0j62zpafjgjz2hf';

const A32 = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const pm = v => { const G = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]; let c = 1; for (const x of v) { const t = c >>> 25; c = ((c & 0x1ffffff) << 5) ^ x; for (let i = 0; i < 5; i++) if ((t >>> i) & 1) c ^= G[i]; } return c; };
const hrpX = h => [...h].map(c => c.charCodeAt(0) >> 5).concat([0], [...h].map(c => c.charCodeAt(0) & 31));
const bytesOf = a => { const k = a.lastIndexOf('1'), d = [...a.slice(k + 1)].map(c => A32.indexOf(c)).slice(0, -6), o = []; let acc = 0, bits = 0; for (const x of d) { acc = (acc << 5 | x) & 4095; bits += 5; if (bits >= 8) { bits -= 8; o.push(acc >> bits & 255); } } return o; };
const bech = bytes => { const d = []; let acc = 0, bits = 0; for (const b of bytes) { acc = (acc << 8) | b; bits += 8; while (bits >= 5) { bits -= 5; d.push((acc >>> bits) & 31); } } if (bits) d.push((acc << (5 - bits)) & 31); const p = pm(hrpX('tacit').concat(d, [0, 0, 0, 0, 0, 0])) ^ 0x2bc830a3; return 'tacit1' + d.concat([0, 1, 2, 3, 4, 5].map(i => (p >>> (5 * (5 - i))) & 31)).map(x => A32[x]).join(''); };
const withFlags = (a, flags, extra = []) => { const b = [...bytesOf(a), ...extra]; b[1] = flags; return bech(b); };

let p;
const page = async () => p ||= await loadPage({ chain: new MockChain(), walletless: true });
const recip = async a => (await page()).window.eval(`(()=>{try{return cpRecip(${JSON.stringify(a)})}catch(e){return "ERR "+e.message}})()`);
const bp = async a => (await page()).window.eval(`cpBp(${JSON.stringify(a)})`);

test('the addresses in use today pay the same key as before', async () => {
  assert.match(await recip(REAL_RECORD), /^0[23][0-9a-f]{64}$/);
  assert.match(await recip(V0), /^0[23][0-9a-f]{64}$/);
  assert.equal(UNIFIED.length, 329);
  assert.equal(await recip(UNIFIED), await recip(V0), 'a unified address pays the same Ethereum-side key');
});

test('the pool lane reads as the bp1 address it carries', async () => {
  assert.equal(await bp(UNIFIED), BP);
  assert.equal(await bp(BP), BP, 'a bp1 address passes through');
  assert.equal(await bp(V0), V0, 'an address with no pool lane has no bp1 to offer');
});

test('0x80 names the spend key as the Ethereum-side key, once', async () => {
  assert.equal(U85.length, 276);
  assert.equal(await recip(U85), await recip(V0), 'the pooled form pays the same Ethereum-side key');
  assert.equal(await bp(U85), BP);
  const v0 = bytesOf(V0), short = bech([0, 0x81, ...v0.slice(2, 68)]);
  assert.equal(short.length, 121);
  assert.equal(await recip(short), await recip(V0), 'marked with no pool lane');
  assert.equal(await bp(short), short, 'and no bp1 to offer');
  assert.match(await recip(withFlags(UNIFIED, 0x87)), /^ERR /, 'an Ethereum-side key named twice');
  assert.match(await recip(withFlags(U85, 0x85, [1])), /^ERR /, 'no unknown lane, so the length is exact');
  assert.equal(await bp(withFlags(U85, 0x8d, Array(9).fill(3))), BP, 'an unknown lane past the known ones is skipped');
});

test('lanes the page does not know are skipped, and a short known lane is refused', async () => {
  const later = withFlags(UNIFIED, 0x0f, Array(40).fill(9));
  assert.equal(await bp(later), BP);
  assert.equal(await recip(later), await recip(V0));
  assert.equal(await recip(withFlags(V0, 0x0b, Array(12).fill(1))), await recip(V0));
  assert.match(await recip(withFlags(UNIFIED, 0x07, [1])), /^ERR /, 'no unknown lane, so the length is exact');
  assert.match(await recip(withFlags(V0, 0x07)), /^ERR /, 'a pool flag without its 97 bytes');
  assert.match(await recip(bech(bytesOf(withFlags(UNIFIED, 0x0f)).slice(0, 150))), /^ERR /, 'an unknown lane never excuses a short known one');
  const poolOnly = bech([0, 5, ...bytesOf(V0).slice(2, 68), ...bytesOf(UNIFIED).slice(101)]);
  assert.equal(await bp(poolOnly), BP, 'Bitcoin and pool lanes only');
  assert.match(await recip(poolOnly), /Ethereum lane/, 'and V1, which needs the Ethereum lane, says so');
  p.close();
});
