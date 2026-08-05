// Harness with enough DOM to actually exercise render/paint/sort/filter,
// driving the real page script against the frozen mainnet fixtures.
import fs from 'fs';

const els = {};
function mk(tag='div'){
  return {
    tag, textContent:'', href:'', hidden:false, dataset:{}, className:'', style:{}, value:'',
    _kids:[], _cards:[], _html:'',
    get innerHTML(){return this._html},
    set innerHTML(v){
      this._html = v;
      // Synthesise one element per rendered card, carrying its data-i.
      this._cards = [...v.matchAll(/<figure class=p [^>]*data-i="(\d+)"/g)]
        .map(m => ({dataset:{i:m[1]}, hidden:false, style:{}}));
      this._btns = [...v.matchAll(/data-f="([^"]*)"/g)].map(m => ({dataset:{f:m[1]}, _p:'false',
        setAttribute(k,val){this._p=val}, getAttribute(){return this._p}}));
    },
    append(x){this._kids.push(x)}, replaceChildren(){this._kids=[]; this._cards=[];},
    prepend(){}, focus(){}, setAttribute(){}, addEventListener(){},
    querySelectorAll(sel){ return sel === '.p' || sel === '.p[data-i]' ? this._cards : (this._btns||[]) },
    showModal(){this.open=true}, close(){this.open=false},
  };
}
global.document = {
  getElementById: i => els[i] ||= mk(),
  createElement: mk, querySelector: () => mk(), body:{appendChild(){}},
};
global.window = {}; global.localStorage = {getItem:()=>null,setItem(){},removeItem(){}};
global.requestAnimationFrame = f => f(); global.Image = function(){return mk()};
global.navigator = {}; URL.createObjectURL=()=>''; URL.revokeObjectURL=()=>{};
global.Blob = function(){}; global.prompt = () => null;

let src = fs.readFileSync(new URL('./page.harness.js', import.meta.url),'utf8');
src = src.replace('window.fetch=async','globalThis.fetch=window.fetch=async');
src = src.replace('boot();',
  'globalThis.__b=boot;globalThis.__R=()=>ROWS;globalThis.__paint=paint;globalThis.__K=v=>KIND=v;globalThis.__tl=tokenListJson;globalThis.__open=open_;globalThis.__fn=fname;globalThis.__svg=svgText;');
fs.writeFileSync(new URL('./.v2m.gen.mjs', import.meta.url), src + '\nexport{};');
await import('./.v2m.gen.mjs');
await globalThis.__b();

const R = globalThis.__R(), grid = els.grid;
const L='0x0000006013df75a31678b786061c2b54bf531524';
const shown = () => grid._cards.filter(c => !c.hidden).length;
const orderOf = () => grid._cards.map(c => c.style.order);

let fails = 0;
const ok = (name, cond, extra='') => { console.log(`${cond?'PASS':'FAIL'}  ${name}${extra?'  '+extra:''}`); if(!cond) fails++; };

console.log('=== summary strip ===');
console.log(els.sm.innerHTML.replace(/<\/div>/g,'</div>\n').replace(/<[^>]+>/g,' ').replace(/ +/g,' ').trim());
ok('summary hidden=false', els.sm.hidden === false);

console.log('\n=== rank normalisation ===');
const rk = R.map(r => +r.rank.toFixed(3));
ok('rank in [0.15,1]', rk.every(v => v >= 0.15 && v <= 1), `min=${Math.min(...rk)} max=${Math.max(...rk)}`);
ok('top rank is 1', Math.max(...rk) === 1);
ok('spread is meaningful (not all equal)', new Set(rk).size > 1, `distinct=${new Set(rk).size}`);

console.log('\n=== sort ===');
els.sort.value='rank'; globalThis.__paint();
const bySym = R.map(r=>r.m.s);
const rankOrder = grid._cards.map((c,i)=>({s:bySym[i],o:+c.style.order})).sort((a,b)=>a.o-b.o).map(x=>x.s);
console.log('  rank :', rankOrder.join(' '));
ok('rank sort is descending by r', rankOrder[0] === 'ETH');
els.sort.value='symbol'; globalThis.__paint();
const symOrder = grid._cards.map((c,i)=>({s:bySym[i],o:+c.style.order})).sort((a,b)=>a.o-b.o).map(x=>x.s);
console.log('  symbol:', symOrder.join(' '));
ok('symbol sort is A-Z', symOrder.join() === [...bySym].sort((a,b)=>a.localeCompare(b)).join());
ok('order values are a permutation 0..n-1',
   new Set(orderOf().map(Number)).size === R.length && Math.max(...orderOf().map(Number)) === R.length-1);

console.log('\n=== filters ===');
els.sort.value='rank';
for (const [k,expect] of [['all',R.length],['ERC-20',R.filter(r=>r.m.p==='ERC-20').length],
                          ['Native',R.filter(r=>r.m.p==='Native').length],['v',R.filter(r=>r.m.v).length]]) {
  globalThis.__K(k); globalThis.__paint();
  ok(`filter ${k}`, shown() === expect, `shown=${shown()} expected=${expect}`);
}
globalThis.__K('all');

console.log('\n=== search + filter compose ===');
els.q.value='eth'; globalThis.__K('ERC-20'); globalThis.__paint();
const both = R.filter(r=>r.q.includes('eth') && r.m.p==='ERC-20').length;
ok('search AND kind', shown() === both, `shown=${shown()} expected=${both}`);
els.q.value=''; globalThis.__K('all'); globalThis.__paint();

console.log('\n=== filter chips offered ===');
console.log(' ', (els.fc._btns||[]).map(b=>b.dataset.f).join(' | '));

console.log('\n=== detail dialog ===');
globalThis.__open(1);
console.log('  title:', els.dt.textContent);
console.log('  desc :', els.ddesc.textContent.slice(0,70));
ok('desc shown for WETH', els.ddesc.hidden === false && els.ddesc.textContent.length > 0);
const kv = els.dkv.innerHTML.replace(/<[^>]+>/g,'|').split('|').filter(Boolean);
console.log('  keys :', kv.filter((_,i)=>i%2===0).join(', '));
ok('dialog exposes authoring + card art + brand colour',
   /authoring/.test(els.dkv.innerHTML) && /brand colour/.test(els.dkv.innerHTML));

console.log('\n=== download name + svg extraction ===');
const fn = globalThis.__fn, sv = globalThis.__svg;
for (const [inp,exp] of [['ETH/USD','ETH-USD.svg'],['a b','a-b.svg'],['','listing.svg'],['.htaccess','htaccess.svg'],['x'.repeat(300), 'x'.repeat(48)+'.svg']])
  ok(`fname(${JSON.stringify(inp)})`, fn(inp,'.svg') === exp, `-> ${fn(inp,'.svg')}`);
ok('svgText(base64)', sv(R[0].img).trim().startsWith('<svg'));
ok('svgText(raw, unencodable) does not throw',
   sv("data:image/svg+xml,<svg><text>100%</text></svg>").includes('<svg'));

console.log('\n=== tokenlist.json ===');
const tl = JSON.parse(globalThis.__tl());
ok('8 erc-20 tokens', tl.tokens.length === 8, tl.tokens.map(t=>t.symbol).join(','));

console.log(`\n${fails ? fails+' FAILURE(S)' : 'core checks passed'}`);

console.log('\n=== outbound links per listing ===');
const html = grid.innerHTML;
const figs = html.split('<figure').slice(1);
let lf = 0;
for (const f of figs) {
  const sym = (f.match(/class=sy>([^<]*)/)||[])[1];
  const os  = (f.match(/href="(https:\/\/opensea[^"]*)"/)||[])[1] || '';
  const es  = (f.match(/href="(https:\/\/etherscan[^"]*)"/)||[])[1] || '';
  const row = R.find(r => r.m.s === sym);
  const isSub = row.m.x && row.m.a && !/^0x0{40}$/i.test(row.m.a);
  const esOk = isSub ? es === 'https://etherscan.io/token/'+row.m.a
                     : es === 'https://etherscan.io/nft/'+L+'/'+row.m.i;
  const osOk = os === 'https://opensea.io/assets/ethereum/'+L+'/'+row.m.i;
  if(!esOk||!osOk) lf++;
  console.log(`  ${sym.padEnd(7)} ${isSub?'token ':'nft   '} ${osOk&&esOk?'ok':'MISMATCH'}  ${es}`);
}
ok('every card links correctly', lf === 0);
ok('no card is still role=button', !/role=button/.test(html));
ok('details control present on each card', (html.match(/class="lk dtl"/g)||[]).length === R.length);
console.log('\n=== provenance chips actually in use ===');
const chips = {};
for (const r of R) { const t = (grid.innerHTML.match(new RegExp(`class=sy>${r.m.s}<[\\s\\S]*?class="c (on|at|nc)">([^<]*)<`))||[])[2]; chips[t]=(chips[t]||0)+1; }
for (const [k,v] of Object.entries(chips)) console.log(`  ${String(v).padStart(3)}  ${k}`);
process.exit(lf ? 1 : 0);
