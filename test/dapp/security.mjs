// Security + robustness regression checks for the hardening pass.
import fs from 'fs';
const els={};
function mk(){return{textContent:'',href:'',hidden:false,dataset:{},className:'',style:{},value:'',
 _kids:[],_cards:[],_btns:[],_html:'',
 get innerHTML(){return this._html},
 set innerHTML(v){this._html=v;
  this._cards=[...v.matchAll(/<figure class=p data-i="(\d+)"/g)].map(m=>({dataset:{i:m[1]},hidden:false,style:{}}));
  this._btns=[...v.matchAll(/data-f="([^"]*)"/g)].map(m=>({dataset:{f:m[1]},setAttribute(){},getAttribute(){}}));},
 append(x){this._kids.push(x)},replaceChildren(){this._kids=[];this._cards=[];this._html=''},
 prepend(){},focus(){},setAttribute(){},addEventListener(){},
 querySelectorAll(s){return s==='.p'||s==='.p[data-i]'?this._cards:this._btns},
 showModal(){this.open=true},close(){this.open=false}}}
global.document={getElementById:i=>els[i]||=mk(),createElement:mk,querySelector:()=>mk(),body:{appendChild(){}}};
global.window={};global.localStorage={getItem:()=>null,setItem(){},removeItem(){}};
global.requestAnimationFrame=f=>f();global.Image=function(){return mk()};
global.navigator={};URL.createObjectURL=()=>'';URL.revokeObjectURL=()=>{};
global.Blob=function(){};global.prompt=()=>null;
let src=fs.readFileSync(new URL('./page.harness.js', import.meta.url),'utf8');
src=src.replace('window.fetch=async','globalThis.fetch=window.fetch=async');
src=src.replace('boot();','globalThis.__b=boot;globalThis.__R=()=>ROWS;globalThis.__paint=paint;globalThis.__open=open_;globalThis.__u=safeUrl;globalThis.__i=safeImg;globalThis.__list=list;globalThis.__render=render;');
fs.writeFileSync(new URL('./.secm.gen.mjs', import.meta.url),src+'\nexport{};');
await import('./.secm.gen.mjs');
await globalThis.__b();
let f=0; const ok=(n,c,x='')=>{console.log(`${c?'PASS':'FAIL'}  ${n}${x?'  '+x:''}`);if(!c)f++};

console.log('=== url scheme gate ===');
for (const bad of ['javascript:alert(1)','JaVaScRiPt:alert(1)','data:text/html,<script>x</script>','vbscript:x',' javascript:x','file:///etc/passwd'])
  ok(`rejects ${JSON.stringify(bad.slice(0,28))}`, globalThis.__u(bad)==='');
for (const good of ['https://weth.io','http://x.io/a?b=1','ipfs://Qm123'])
  ok(`allows ${good}`, globalThis.__u(good)===good);

console.log('\n=== image scheme gate ===');
for (const bad of ['javascript:alert(1)','data:text/html,<svg onload=x>','http://insecure.example/a.png'])
  ok(`rejects ${JSON.stringify(bad.slice(0,26))}`, globalThis.__i(bad)==='');
for (const good of ['data:image/svg+xml;base64,AAA','https://x.io/a.png','ipfs://Qm'])
  ok(`allows ${good.slice(0,24)}`, globalThis.__i(good)===good);

console.log('\n=== javascript: url never becomes an href ===');
const R=globalThis.__R();
R[1].m.u='javascript:alert(document.domain)';
globalThis.__open(1);
ok('dialog link row has no javascript: href', !/href="javascript/i.test(els.dlk.innerHTML), els.dlk.innerHTML.slice(0,90));
ok('project site link suppressed entirely', !/project site/.test(els.dlk.innerHTML));
ok('but the raw value is still shown as text', /javascript:alert/.test(els.dkv.innerHTML));

console.log('\n=== list() refuses an oversized length word ===');
const huge='0x'+(32).toString(16).padStart(64,'0')+(2n**40n).toString(16).padStart(64,'0');
let threw=false, t0=Date.now();
try{ globalThis.__list(huge) }catch(e){ threw=true }
ok('throws instead of allocating 2^40 entries', threw, `${Date.now()-t0}ms`);
ok('valid empty list still decodes', globalThis.__list('0x'+(32).toString(16).padStart(64,'0')+''.padStart(64,'0')).length===0);

console.log('\n=== paint() after the grid is emptied ===');
els.grid.replaceChildren();
let crashed=false;
try{ globalThis.__paint() }catch(e){ crashed=true; console.log('   threw:',e.message) }
ok('no crash when ROWS outlive the grid', !crashed);

console.log(`\n${f?f+' FAILURE(S)':'all security checks passed'}`);
process.exit(f?1:0);
