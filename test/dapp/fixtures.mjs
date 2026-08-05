#!/usr/bin/env node
/**
 * Build the offline test harness for dapp/tokenlist/page.html.
 *
 * Reads every call the page makes from live mainnet once, freezes the answers, and
 * writes:
 *
 *   page.harness.js   the page's own script, prefixed with a shim that replays those
 *                     answers — so the suites exercise the real decode path with no
 *                     network and no browser.
 *   preview.html      the page with the same shim inlined, openable in a browser.
 *
 * Both are committed, so `node test/dapp/fuzz.mjs` works from a clean checkout with no
 * RPC. Re-run this only when the registry changes or the page's calls do.
 *
 * Usage: node test/dapp/fixtures.mjs
 */
import fs from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..");
const PAGE = path.join(ROOT, "dapp", "tokenlist", "page.html");

const L = "0x0000006013df75a31678b786061c2b54bf531524";
const RPCS = [
  "https://ethereum-rpc.publicnode.com",
  "https://eth.merkle.io",
  "https://eth.drpc.org",
  "https://eth-mainnet.public.blastapi.io",
];
const W = (x) => BigInt(x).toString(16).padStart(64, "0");

async function call(data) {
  let last;
  for (const u of RPCS) {
    try {
      const r = await fetch(u, {
        method: "POST",
        headers: {"content-type": "application/json"},
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "eth_call",
          params: [{to: L, data}, "latest"],
        }),
      });
      const j = await r.json();
      if (j.error) throw Error(j.error.message);
      return j.result;
    } catch (e) {
      last = e;
    }
  }
  throw last;
}

function decodeIds(h) {
  h = h.slice(2);
  const o = Number(BigInt("0x" + h.slice(0, 64))) * 2;
  const n = Number(BigInt("0x" + h.slice(o, o + 64)));
  return Array.from({length: n}, (_, i) =>
    BigInt("0x" + h.slice(o + 64 + i * 64, o + 128 + i * 64))
  );
}

// Selectors the page sends. `ids` is rankedIds(), not ids() — see the page's devdoc.
const S = {ids: "0xdf7ca268", json: "0x74e18e96", uri: "0xc87b56dd", curi: "0xe8a3d485"};

const T = {};
for (const sel of [S.curi, S.ids]) T[sel] = await call(sel);
const ids = decodeIds(T[S.ids]);
process.stderr.write(`listings: ${ids.length}\n`);
for (const id of ids) {
  for (const sel of [S.json, S.uri]) T[sel + W(id)] = await call(sel + W(id));
  process.stderr.write(".");
}
process.stderr.write("\n");

const SHIM = `/* OFFLINE HARNESS SHIM — not part of the deployed page.
   The registry's answers were read from mainnet once and frozen below. This decodes
   the page's real multicall(bytes[]) calldata and replays each subcall from that
   table, so the page runs its actual decode path with no network. */
window.__T__=${JSON.stringify(T)};
(function(){
 const W=x=>BigInt(x).toString(16).padStart(64,'0');
 function unmc(hex){let h=hex.slice(2);const w=i=>Number(BigInt('0x'+h.slice(i*64,(i+1)*64)));
  let arr=w(0)/32,n=w(arr),out=[];
  for(let i=0;i<n;i++){let p=arr+1+w(arr+1+i)/32,len=w(p);out.push('0x'+h.slice((p+1)*64,(p+1)*64+len*2))}
  return out}
 function mcRet(items){let n=items.length,offs=[],body='',cur=n*32;
  for(const it of items){let d=it.slice(2),len=d.length/2,pad=(32-len%32)%32;
   offs.push(cur);body+=W(len)+d+'0'.repeat(pad*2);cur+=32+len+pad}
  return '0x'+W(32)+W(n)+offs.map(W).join('')+body}
 window.ethereum=undefined;
 window.fetch=async(u,o)=>{
  const req=JSON.parse(o.body),data=req.params[0].data;
  if(!data.startsWith('0xac9650d8'))throw Error('harness: unexpected call');
  const subs=unmc('0x'+data.slice(10));
  const outs=subs.map(s=>{const r=window.__T__[s];if(!r)throw Error('harness: no fixture for '+s.slice(0,10));return r});
  await new Promise(r=>setTimeout(r,120));
  return {ok:true,json:async()=>({jsonrpc:'2.0',id:req.id,result:mcRet(outs)})};
 };
})();
`;

const page = fs.readFileSync(PAGE, "utf8");
const i = page.lastIndexOf("<script>");
const pageScript = page.slice(i + "<script>".length, page.lastIndexOf("</script>"));

// What the Node suites import: shim first, then the page's own script verbatim.
fs.writeFileSync(path.join(HERE, "page.harness.js"), SHIM + "\n" + pageScript);

// A browser-openable copy: same shim, plus a theme hook and an honest banner.
const THEME =
  "<style>\n" +
  ":root[data-theme=light]{--bg:#faf8f5;--pn:#fff;--ink:#1a1815;--mu:#6b6560;--hr:#e3ddd4;--ac:#4a63c4;--at:#b96908;--nt:#5e7a6b}\n" +
  ":root[data-theme=dark]{--bg:#121110;--pn:#1b1917;--ink:#efeae3;--mu:#9a928a;--hr:#2e2a26;--ac:#8ca0f0;--at:#f7931a;--nt:#8fb3a0}\n" +
  "</style>";
const TAIL =
  THEME +
  "<script>\n" +
  "(function(){const s=document.getElementById('src');\n" +
  " const fix=()=>{if(s.textContent!=='frozen snapshot')s.textContent='frozen snapshot'};\n" +
  " new MutationObserver(fix).observe(s,{childList:true,characterData:true,subtree:true});fix();\n" +
  " const b=document.createElement('p');b.className='eb';b.style.cssText='color:var(--at);margin:0 0 14px';\n" +
  " b.textContent='preview — registry answers frozen from mainnet; the live page reads them over eth_call';\n" +
  " document.querySelector('.w').prepend(b);})();\n" +
  "</" + "script>";

const body = (
  page.slice(0, i) + "<script>\n" + SHIM + "</" + "script>\n" + page.slice(i) + TAIL
).replace("<!doctype html><html lang=en>", "");
fs.writeFileSync(path.join(HERE, "preview.html"), body);

console.log(`wrote page.harness.js and preview.html from ${ids.length} listings`);
