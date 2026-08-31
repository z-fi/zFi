const RPC = process.env.ETH_RPC_URL || 'https://ethereum-rpc.publicnode.com';
import fs from 'node:fs';
const map = {
  PrecisionPoolFactory:  '0x000000Eb27B557aB426d9E99cFd54EC455799e81',
  PrecisionPoolLens:     '0x000000Bad3a2fa57ed74fa06000573ccddF6B7fB',
  PrecisionLiquidityLens:'0x000000956bf20A41C54BaE4a4b6F5C8A166DAB4E',
  PrecisionRoute:        '0x0000007Be74558A1F8c9045301c6F44C8eD0c9eB',
  PrecisionPoolPolicy:   '0x00000045fc7b570Be4d71F67219508ebD295EC6D',
  PrecisionLauncher:     '0x0000002fC8E77585A008Aa45d78A71ad36293aEe',
};
const code = async a => { const r = await fetch(RPC,{method:'POST',headers:{'content-type':'application/json'},
  body:JSON.stringify({id:1,jsonrpc:'2.0',method:'eth_getCode',params:[a,'latest']})});
  return (await r.json()).result.replace(/^0x/,''); };
const rows = [];
for (const [n,a] of Object.entries(map)) {
  const j = JSON.parse(fs.readFileSync(`out/${n}.sol/${n}.json`,'utf8'));
  const L = (j.deployedBytecode.object||'').replace(/^0x/,''), V = await code(a);
  const imm = j.deployedBytecode.immutableReferences || {};
  const slots = Object.values(imm).flat();
  const mask = h => { const b = Buffer.from(h,'hex'); for (const s of slots) b.fill(0, s.start, s.start+s.length); return b.toString('hex'); };
  const same = L.length === V.length && mask(L) === mask(V);
  // the live configuration, read straight out of the deployed code
  const vals = slots.map(s => '0x' + V.slice((s.start+12)*2, (s.start+s.length)*2)).filter(v => /^0x[0-9a-f]{40}$/.test(v));
  rows.push({ n, a, same, slots: slots.length, vals: [...new Set(vals)] });
  console.log(`${n.padEnd(23)} ${same ? 'VERIFIED — identical outside immutables' : 'MISMATCH'}  (${slots.length} immutable slots)`);
}
fs.writeFileSync('scope-verify.json', JSON.stringify(rows,null,2));
console.log('\nLive immutable configuration:');
for (const r of rows) if (r.vals.length) console.log(' ', r.n, '->', r.vals.join(' '));
