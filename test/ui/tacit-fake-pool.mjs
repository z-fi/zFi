// The real pool wallet is Tacit's bundle, loaded and proved in a browser; here a stand-in with the same shape.
export const FAKE_POOL = `twW={c:CHAIN_ID,k:cpSeed,address:"bp1qfakepool0000000000000000",calls:[],failRelay:0,balance:()=>5n*10n**17n,sync:async()=>({balance:5n*10n**17n}),
receive:{address:"0x52fc37ee7741468a15ce879320a7a41cebaeb232",sweep:async o=>{twW.calls.push(["sweep"]);return "0xsweep"}},deposit:async(v,o)=>{twW.calls.push(["deposit",String(v)]);return "0xdep"},
send:async(to,v,o)=>{twW.calls.push(["send",to,String(v),o&&o.via||"keeper"]);if(twW.failRelay&&!(o&&o.via))throw Error("keeper down");return "0xsend"},
withdraw:async(to,v,o)=>{twW.calls.push(["withdraw",to,String(v),o&&o.via||"keeper"]);return "0xwd"},quote:async()=>({fee:"1000000000000000"}),terminate(){}};1`;
