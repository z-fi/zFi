import { chromium } from 'playwright';
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path';
const ROOT='/Users/z/zFi';
const MIME={'.html':'text/html','.js':'text/javascript','.css':'text/css','.json':'application/json'};
const srv=http.createServer((req,res)=>{let p=decodeURIComponent(req.url.split('?')[0]);if(p.endsWith('/'))p+='index.html';
  const f=path.join(ROOT,'dapp',p);if(!fs.existsSync(f)||fs.statSync(f).isDirectory()){res.writeHead(404);return res.end('x');}
  res.writeHead(200,{'content-type':MIME[path.extname(f)]||'application/octet-stream'});res.end(fs.readFileSync(f));});
await new Promise(r=>srv.listen(8802,r));
const b=await chromium.launch();
const pg=await b.newPage({viewport:{width:1200,height:1600},colorScheme:'dark'});
const errs=[]; pg.on('pageerror',e=>errs.push(e.message));
await pg.addInitScript(()=>{try{localStorage.clear()}catch{}});
await pg.goto('http://localhost:8802/coin/',{waitUntil:'load'});
try{await pg.waitForFunction(()=>document.querySelectorAll('.coin-card').length>0,{timeout:60000});}catch{}
await pg.waitForTimeout(3000);
const out=await pg.evaluate(()=>{
  const cards=[...document.querySelectorAll('.coin-card')];
  const by=t=>cards.filter(c=>new RegExp('>'+t+'<').test(c.innerHTML)).map(c=>c.querySelector('.coin-card-name')?.textContent);
  return {total:cards.length, cause:by('cause').length, daico:by('daico'), collect:by('collect'), fund:by('fund'),
          hidden:document.body.textContent.match(/\d+ coins hidden[^)]*\)/)?.[0]||''};
});
console.log(JSON.stringify(out,null,1)); if(errs.length)console.log('ERR',errs.slice(0,3));
await pg.screenshot({path:'/private/tmp/claude-501/gal2.png'});
await b.close(); srv.close();
