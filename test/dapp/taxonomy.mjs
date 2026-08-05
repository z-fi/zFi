// Prove the anticipatory taxonomy: inject the listing kinds that do not exist yet
// (Bitcoin-rooted formats, ERC-1155, reservations, an unknown standard) and check
// the filter tiers, counts, chips and card badges all behave.
import fs from 'fs';

const els = {};
function mk(){
  return {
    textContent:'', href:'', hidden:false, dataset:{}, className:'', style:{}, value:'',
    _kids:[], _cards:[], _btns:[], _html:'',
    get innerHTML(){return this._html},
    set innerHTML(v){
      this._html = v;
      this._cards = [...v.matchAll(/<figure class=p data-i="(\d+)"/g)].map(m=>({dataset:{i:m[1]},hidden:false,style:{}}));
      this._btns  = [...v.matchAll(/<button data-f="([^"]*)" aria-pressed="(\w+)" class="([^"]*)">([^<]*)<b>(\d+)</g)]
        .map(m=>({f:m[1],pressed:m[2]==='true',zero:/\bz\b/.test(m[3]),label:m[4],count:+m[5]}));
    },
    append(x){this._kids.push(x)}, replaceChildren(){this._kids=[];this._cards=[];},
    prepend(){}, focus(){}, setAttribute(){}, addEventListener(){},
    querySelectorAll(s){return s==='.p'||s==='.p[data-i]'?this._cards:this._btns},
    showModal(){this.open=true}, close(){this.open=false},
  };
}
global.document={getElementById:i=>els[i]||=mk(),createElement:mk,querySelector:()=>mk(),body:{appendChild(){}}};
global.window={}; global.localStorage={getItem:()=>null,setItem(){},removeItem(){}};
global.requestAnimationFrame=f=>f(); global.Image=function(){return mk()};
global.navigator={}; URL.createObjectURL=()=>''; URL.revokeObjectURL=()=>{};
global.Blob=function(){}; global.prompt=()=>null;

let src=fs.readFileSync(new URL('./page.harness.js', import.meta.url),'utf8');
src=src.replace('window.fetch=async','globalThis.fetch=window.fetch=async');
src=src.replace('boot();','globalThis.__b=boot;globalThis.__R=()=>ROWS;globalThis.__render=render;globalThis.__K=v=>KIND=v;globalThis.__chips=chips;globalThis.__paint=paint;');
fs.writeFileSync(new URL('./.v3m.gen.mjs', import.meta.url),src+'\nexport{};');
await import('./.v3m.gen.mjs');
await globalThis.__b();

const R=globalThis.__R();
let fails=0;
const ok=(n,c,x='')=>{console.log(`${c?'PASS':'FAIL'}  ${n}${x?'  '+x:''}`);if(!c)fails++};

// --- inject the anticipated listings -------------------------------------------
const base={c:1,k:'eip155',x:true,o:false,f:false,d:0,t:'#f7931a',r:900000,u:'',au:'',l:'',desc:'',e:[],v:false};
const add=(o)=>{const i=R.length;R.push({m:{i:String(1000+i),...base,...o},img:'',i,rank:.5,
  q:[o.s,o.n,o.a].filter(Boolean).join(' ').toLowerCase()})};
add({p:'Rune',    s:'UNCOMMON•GOODS', n:'Uncommon Goods', a:'', k:'btc', c:0});
add({p:'Ordinal', s:'ORD',            n:'An Inscription', a:'', k:'btc', c:0});
add({p:'BRC-20',  s:'ORDI',           n:'ordi',           a:'', k:'btc', c:0});
add({p:'Tacit',   s:'TAC',            n:'Tacit Asset',    a:'', k:'btc', c:0});
add({p:'ERC-1155',s:'MULTI', n:'Multi Token', a:'0x1111111111111111111111111111111111111111', o:true});
add({p:'ERC-20',  s:'SOON',  n:'Not Deployed Yet', a:'', x:false});          // reservation
add({p:'ERC-20',  s:'BRIDGE',n:'Awaiting Bridge',  a:'', x:false});          // not yet bridged
add({p:'Unknown', s:'???',   n:'Some New Format',  a:'0x2222222222222222222222222222222222222222'});
globalThis.__render();

const top = () => els.fc._btns;
const sub = () => (els.fc2.hidden ? [] : els.fc2._btns);
const shown = () => els.grid._cards.filter(c=>!c.hidden).length;
const pick = k => { globalThis.__K(k); globalThis.__chips(); globalThis.__paint(); };
const fmt = bs => bs.map(b=>`${b.label}:${b.count}${b.zero?'(muted)':''}${b.pressed?'*':''}`).join('  ');

console.log('\n=== top tier ===');
console.log(' ', fmt(top()));
ok('groups + reserved + read onchain offered',
   ['all','c1','bitcoin','reserved','v'].every(k=>top().some(b=>b.f===k)));
ok('bitcoin counts the four rooted formats', top().find(b=>b.f==='bitcoin').count===4);
ok('an unknown standard on mainnet stays a mainnet listing, not "other"',
   !top().some(b=>b.f==='other') && top().find(b=>b.f==='c1').count===15,
   top().map(b=>b.label+':'+b.count).join(' '));
ok('reserved counts both no-address listings', top().find(b=>b.f==='reserved').count===2);

console.log('\n=== drill into bitcoin ===');
pick('bitcoin');
console.log('  sub:', fmt(sub()));
ok('sub-row unfolds', sub().length===4);
ok('sub-row lists Tacit/Rune/Ordinal/BRC-20',
   sub().map(b=>b.label).join(',')==='tacit,rune,ordinal,brc-20');
ok('bitcoin filter shows 4', shown()===4, `shown=${shown()}`);

console.log('\n=== drill into a Bitcoin subcategory ===');
pick('bitcoin|Rune');
console.log('  sub:', fmt(sub()));
ok('sub-row stays open on the parent group', sub().length===4);
ok('rune chip is the pressed one', sub().find(b=>b.label==='rune').pressed);
ok('rune filter shows 1', shown()===1, `shown=${shown()}`);

console.log('\n=== ethereum tier ===');
pick('c1');
console.log('  sub:', fmt(sub()));
ok('erc-1155 offered with a real count', sub().find(b=>b.label==='erc-1155').count===1);
pick('c1|ERC-1155');
ok('erc-1155 filter shows 1', shown()===1, `shown=${shown()}`);

console.log('\n=== reserved ===');
pick('reserved');
ok('reserved shows 2', shown()===2, `shown=${shown()}`);
ok('sub-row stays visible on a non-group filter (defaults to ethereum)',
   els.fc2.hidden===false && sub().map(b=>b.label).join(',')==='native,erc-20,erc-721,erc-1155');

console.log('\n=== badges on the anticipated cards ===');
pick('all');
for (const s of ['UNCOMMON•GOODS','SOON','MULTI','???']) {
  const f = els.grid.innerHTML.split('<figure').find(x=>x.includes(`>${s}<`)) || '';
  const badges = [...f.matchAll(/class="c (?:on|at|nc)">([^<]*)</g)].map(m=>m[1]);
  console.log(`  ${s.padEnd(15)} ${badges.join(' | ')}`);
}
const runeFig = els.grid.innerHTML.split('<figure').find(x=>x.includes('>UNCOMMON•GOODS<'));
ok('Bitcoin listing says it is unreadable from ethereum', /not readable from ethereum/.test(runeFig));
const soonFig = els.grid.innerHTML.split('<figure').find(x=>x.includes('>SOON<'));
ok('reservation badged RESERVED', /reserved/.test(soonFig));
ok('reservation is not double-badged as pending', !/pending/.test(soonFig));
const multiFig = els.grid.innerHTML.split('<figure').find(x=>x.includes('>MULTI<'));
ok('erc-1155 with onchainSvg badged', /onchain token svg/.test(multiFig));


console.log('\n=== sort by token standard (enum order, not alphabetical) ===');
globalThis.__K('all'); globalThis.__chips(); els.sort.value='standard'; globalThis.__paint();
const seq = els.grid._cards.map((c,i)=>({p:R[i].m.p, s:R[i].m.s, o:+c.style.order}))
  .sort((a,b)=>a.o-b.o);
let last=null;
for (const x of seq) { if (x.p!==last) { process.stdout.write(`\n  ${x.p.padEnd(9)}`); last=x.p; } process.stdout.write(' '+x.s); }
console.log();
const groups = [...new Set(seq.map(x=>x.p))];
ok('groups follow the Standard enum order',
   groups.join(',')==='Native,ERC-20,ERC-721,ERC-1155,Tacit,Rune,Ordinal,BRC-20,Unknown', groups.join(','));
ok('Unknown sorts last, not first', groups[groups.length-1]==='Unknown');
ok('within a standard, rank still decides',
   (()=>{const e=seq.filter(x=>x.p==='ERC-20').map(x=>R.find(r=>r.m.s===x.s).m.r);
         return e.every((v,i)=>i===0||e[i-1]>=v)})());


console.log('\n=== summary strip after adding Bitcoin + reservations ===');
console.log(' ', els.sm.innerHTML.replace(/<\/div>/g,' | ').replace(/<[^>]+>/g,' ').replace(/\s+/g,' ').trim());
const cell = l => { const m = els.sm.innerHTML.match(new RegExp(`<b>(\\d+)</b><span>${l}</span>`)); return m?+m[1]:null };
ok('chain counter increments for Bitcoin (eip155:1 + bitcoin = 2)', cell('chains')===2, `chains=${cell('chains')}`);
ok('all four Bitcoin formats count as ONE chain, not four', cell('chains')===2);
ok('sealed still 0 (nothing frozen)', cell('sealed')===0);

console.log(`\n${fails?fails+' FAILURE(S)':'all anticipation checks passed'}`);
process.exit(fails?1:0);
