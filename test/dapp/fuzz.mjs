// State-space fuzzer for the page's UI machine.
// Drives random sequences of (search, filter, sort, open, load-state) against the
// real script and checks invariants after every step. Deterministic seed so a
// failure is reproducible.
import fs from 'fs';

let seed = 12345;
const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
const pick = a => a[Math.floor(rnd() * a.length) % a.length];

const els = {};
function parseCards(v) {
  // Mirrors querySelectorAll('.p[data-i]') vs '.p': skeletons have class=p and no data-i.
  const all = [...v.matchAll(/<figure class=(?:p|"p[^"]*")([^>]*)>/g)];
  return all.map(m => {
    const di = /data-i="(\d+)"/.exec(m[1]);
    return {dataset: di ? {i: di[1]} : {}, hidden: false, style: {}, _hasI: !!di};
  });
}
function mk() {
  return {
    textContent: '', href: '', hidden: false, dataset: {}, className: '', style: {}, value: '',
    open: false, _kids: [], _cards: [], _btns: [], _html: '',
    get innerHTML() { return this._html },
    set innerHTML(v) {
      this._html = v;
      this._kids = [];   // real innerHTML detaches existing children, including EMPTY
      this._cards = parseCards(v);
      this._btns = [...v.matchAll(/<button data-f="([^"]*)" aria-pressed="(\w+)" class="([^"]*)">([^<]*)<b>(\d+)</g)]
        .map(m => ({f: m[1], pressed: m[2] === 'true', cls: m[3], label: m[4], count: +m[5]}));
    },
    append(x) { this._kids.push(x) },
    replaceChildren() { this._kids = []; this._cards = []; this._html = '' },
    prepend() {}, focus() {}, setAttribute() {}, addEventListener() {},
    querySelectorAll(sel) {
      if (sel === '.p[data-i]') return this._cards.filter(c => c._hasI);
      if (sel === '.p') return this._cards;
      return this._btns;
    },
    showModal() { this.open = true }, close() { this.open = false },
  };
}
global.document = {getElementById: i => els[i] ||= mk(), createElement: mk, querySelector: () => mk(), body: {appendChild(){}}};
global.window = {}; global.localStorage = {getItem: () => null, setItem(){}, removeItem(){}};
global.requestAnimationFrame = f => f(); global.Image = function(){ return mk() };
global.navigator = {}; URL.createObjectURL = () => ''; URL.revokeObjectURL = () => {};
global.Blob = function(){}; global.prompt = () => null;

let src = fs.readFileSync(new URL('./page.harness.js', import.meta.url), 'utf8');
src = src.replace('window.fetch=async', 'globalThis.fetch=window.fetch=async');
src = src.replace('boot();',
  'globalThis.X={boot,paint,render,chips,open_,get ROWS(){return ROWS},set KIND(v){KIND=v},get KIND(){return KIND},SKEL,tokenListJson};');
fs.writeFileSync(new URL('./.fuzzm.gen.mjs', import.meta.url), src + '\nexport{};');
await import('./.fuzzm.gen.mjs');
const X = globalThis.X;
await X.boot();

// Extra listings so the fuzzer explores kinds that mainnet does not have yet.
const base = {c:1,k:'eip155',x:true,o:false,f:false,d:18,t:'#f7931a',r:900000,u:'',au:'',l:'',desc:'',e:[],v:false};
const add = o => { const i = X.ROWS.length;
  X.ROWS.push({m:{i:String(9000+i),...base,...o}, img:'', i, rank:.5,
    q:[o.s,o.n,o.a].filter(Boolean).join(' ').toLowerCase()}) };
if (process.env.BARE !== '1') {
add({p:'Rune',    s:'UNCOMMON•GOODS', n:'Uncommon Goods', a:'', k:'raw', c:0});
add({p:'BRC-20',  s:'ORDI', n:'ordi', a:'', k:'raw', c:0});
add({p:'ERC-1155',s:'MULTI',n:'Multi', a:'0x'+'1'.repeat(40), o:true});
add({p:'ERC-20',  s:'SOON', n:'Reserved One', a:'', x:false});
add({p:'',        s:'?',    n:'', a:'', bad:true});          // unparseable metadata
add({p:'ERC-20',  s:'DEGEN',  n:'Degen',       a:'0x'+'2'.repeat(40), c:8453});
add({p:'ERC-721', s:'BNFT',   n:'Base NFT',    a:'0x'+'3'.repeat(40), c:8453});
add({p:'ERC-20',  s:'ARB',    n:'Arbitrum',    a:'0x'+'9'.repeat(40), c:42161});
add({p:'ERC-20',  s:'WHO',    n:'Unknown Chain',a:'0x'+'a'.repeat(40), c:999999});
}
X.render();

const SORTS = ['rank','standard','symbol','name','decimals','bogus'];
const TERMS = ['', 'e', 'eth', 'zz', 'xyz', '0x', 'UNCOMMON', 'soon', '  ', '0xc02aaa', '•'];

const EVMS=['Native','ERC-20','ERC-721','ERC-1155'], BTCS=['Tacit','Rune','Ordinal','BRC-20'];
let steps = 0, fails = 0;
const fail = (msg, ctx) => { console.log(`FAIL @step ${steps}: ${msg}\n      ${ctx}`); fails++ };

function invariants(tag) {
  const R = X.ROWS, grid = els.grid;
  const cards = grid._cards.filter(c => c._hasI);
  const vis = cards.filter(c => !c.hidden);

  // 1. every visible card maps to a real row
  for (const c of vis) if (!R[c.dataset.i]) return fail('visible card with no row', `${tag} i=${c.dataset.i}`);

  // 2. visible set matches an independently computed filter
  const f = els.q.value.trim().toLowerCase(), K = X.KIND;
  const want = R.filter(r => {
    if (f && !r.q.includes(f)) return false;
    if (K === 'all') return true;
    if (K === 'v') return !!r.m.v;
    if (K === 'reserved') return r.m.x === false;
    const grp = m => m.k === 'eip155' ? 'c' + m.c
      : BTCS.includes(m.p) ? 'bitcoin' : m.k === 'solana' ? 'solana' : 'other';
    if (K.includes('|')) { const [g, st] = K.split('|'); return grp(r.m) === g && r.m.p === st; }
    return grp(r.m) === K;
  }).length;
  if (vis.length !== want) return fail('visible count disagrees with filter', `${tag} shown=${vis.length} want=${want} KIND=${K} q="${f}"`);

  // 3. cnt text agrees with what is on screen
  const shownNum = parseInt(els.cnt.textContent, 10);
  if (shownNum !== vis.length) return fail('cnt text disagrees', `${tag} cnt="${els.cnt.textContent}" vis=${vis.length}`);

  // 4. order is a permutation of 0..n-1
  const ords = cards.map(c => +c.style.order).sort((a,b)=>a-b);
  if (cards.length && (ords[0] !== 0 || ords[ords.length-1] !== cards.length-1 || new Set(ords).size !== cards.length))
    return fail('order is not a permutation', `${tag} ${ords.slice(0,8)}…`);

  // 5. empty-state message shown exactly when nothing matches
  const emptyShown = els.grid._kids.some(k => k.className === 'ct' && !k.hidden);
  if (R.length && (vis.length === 0) !== emptyShown)
    return fail('empty-state out of sync', `${tag} vis=${vis.length} emptyShown=${emptyShown}`);

  // 6. the sub-row belongs to the group owning the active filter, and a selected
  //    standard is the pressed chip in it (a zero-count standard included)
  const wantG = K.includes('|') ? K.split('|')[0] : (/^c\d+$/.test(K) || K === 'bitcoin') ? K : 'c1';
  const wantStds = wantG === 'bitcoin' ? BTCS : EVMS;
  const subLabels = els.fc2._btns.map(b => b.label).join(',');
  if (subLabels !== wantStds.map(x => x.toLowerCase()).join(','))
    return fail('sub-row is not the owning group', `${tag} KIND=${K} want=${wantG} sub=[${subLabels}]`);
  if (K.includes('|') && !els.fc2._btns.some(b => b.f === K && b.pressed))
    return fail('active standard not pressed in sub-row', `${tag} KIND=${K} sub=[${subLabels}]`);
  // a sub-row count must never exceed its group's own total
  const groupTotal = R.filter(r => (r.m.k === 'eip155' ? 'c' + r.m.c
    : BTCS.includes(r.m.p) ? 'bitcoin' : r.m.k === 'solana' ? 'solana' : 'other') === wantG).length;
  for (const b of els.fc2._btns)
    if (b.count > groupTotal)
      return fail('sub-row count exceeds its group', `${tag} ${b.label}=${b.count} groupTotal=${groupTotal}`);

  // 7. no chip claims a count it cannot honour
  for (const b of [...els.fc._btns, ...els.fc2._btns])
    if (b.count > R.length) return fail('chip count exceeds rows', `${tag} ${b.label}=${b.count}`);
}

const ops = [
  () => { els.q.value = pick(TERMS); X.paint(); return `search "${els.q.value}"` },
  () => { const b = pick([...els.fc._btns, ...els.fc2._btns]); X.KIND = b.f; X.chips(); X.paint(); return `chip ${b.f}` },
  () => { els.sort.value = pick(SORTS); X.paint(); return `sort ${els.sort.value}` },
  () => { const i = Math.floor(rnd()*X.ROWS.length); X.open_(String(i)); return `open ${i}` },
  () => { X.render(); return 'render' },
  () => { // simulate mid-load: skeletons in the grid, then a keystroke
    els.grid.innerHTML = X.SKEL.repeat(5); els.q.value = pick(TERMS); X.paint();
    X.render(); return 'loading-state + keystroke' },
  () => { JSON.parse(X.tokenListJson()); return 'export tokenlist.json' },
];

console.log('fuzzing UI state machine…');
for (steps = 1; steps <= 4000; steps++) {
  let what = '?';
  try { what = pick(ops)(); }
  catch (e) { fail('THREW: ' + e.message, what + '\n      ' + (e.stack||'').split('\n')[1]); break }
  invariants(what);
  if (fails > 4) break;
}
console.log(`${steps-1} steps, ${fails} failure(s)`);
process.exit(fails ? 1 : 0);
