// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {IZorgConvictionRenderer} from "./IZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "./ZorgPageStyle.sol";

/// @title ZorgConvictionRenderer
/// @notice A self-contained, replaceable onchain UI for the canonical TokenList
///         and the bonded zOrgz support that orders it.
/// @dev It reads only the governor and TokenList. A bonded receipt id is the
///      same id as the underlying zOrgz held in escrow.
///
///      THE LIST IS THE PRODUCT. The registry is a public good and most visitors
///      will never bond anything, so the default page is a token list and
///      nothing else - no status bar, no allocation fields, no action panel.
///      Every conviction control is gated behind `ON`: a connected wallet AND a
///      receipt carrying real bonded weight. A governance widget shown to
///      someone who cannot use it is noise that makes the reference harder to
///      read.
///
///      Rows open a detail dialog rather than sitting beside a permanent card
///      grid. The grid duplicated the list, could only ever show the top nine,
///      and had nowhere to put an address or a decimals field. The dialog
///      carries the whole record, and because the logos are onchain SVG it hands
///      them over as copyable source - a registry that stores art rather than a
///      CDN link should let people take the art.
///
///      A listing is itself an ERC-721 on the registry, so each one links to its
///      own marketplace page, built from the registry address this page was
///      rendered with rather than hardcoded.
contract ZorgConvictionRenderer is IZorgConvictionRenderer {
    using LibString for uint256;

    ZorgPageStyle public immutable style;

    constructor(ZorgPageStyle style_) {
        if (address(style_).code.length == 0) revert();
        style = style_;
    }

    function html(address conviction, address tokenList) external view override returns (string memory) {
        return string.concat(
            style.css(),
            _body(),
            uint256(uint160(conviction)).toHexString(20),
            "',L='",
            uint256(uint160(tokenList)).toHexString(20),
            _abi(),
            _reads(),
            _actions(),
            _render()
        );
    }

    function _body() internal pure returns (string memory) {
        return "<main class=w><header><div><div class=k>zorg.wei / canonical TokenList</div>"
            "<h1>TokenList: 100% onchain token data</h1>"
            "<p class=sub>Every name, symbol, address, decimal and logo lives on Ethereum, not a server. "
            "Open a listing to read and copy its record.</p></div>"
            "<div class=idrow><div id=pv class='face off' role=img aria-label='zOrgz preview'></div>"
            "<input id=rid class=off inputmode=numeric placeholder='zOrgz id' onchange=peek() aria-label='Your zOrgz id'>"
            "<button id=b_use class='btn ghost off' onclick=useReceipt()>use</button>"
            "<button id=b_conn class='btn ghost' onclick=connect()>connect</button></div></header>"
            "<p class=msg id=msg></p><div class='me off' id=me><div class=face id=face role=img aria-label='receipt art'></div>"
            "<span id=rstatus></span><span id=credit></span><span id=eth></span></div>"
            "<details id=acts class=off><summary>Bond and redeem</summary><div class=actgrid>"
            "<p class=gl>Open a position<i>Approve once, then bond.</i></p>"
            "<button class='btn ghost' id=b_apn onclick=approveNft()>approve zOrgz</button>"
            "<button class='btn ghost' id=b_aps onclick=approveShares()>approve zOrg</button>"
            "<button class=btn id=b_bond onclick=bond()>bond zOrgz</button>"
            "<button class='btn ghost' id=b_add onclick=addZorg()>add zOrg</button>"
            "<p class=gl>Refundable ETH<i>Full refund at maturity; earlier is taxed.</i></p>"
            "<button class='btn ghost' id=b_claim onclick=claim()>claim loyalty</button>"
            "<button class='btn ghost' id=b_wd onclick=withdraw()>withdraw ETH</button>"
            "<button class='btn ghost' id=b_redeem onclick=redeem()>redeem receipt</button>"
            "<p class=gl>Permanent<i>Neither can be undone.</i></p>"
            "<button class='btn ghost danger' id=b_lock onclick=lock()>hard lock</button>"
            "<button class='btn ghost danger' id=b_etern onclick=eternal()>eternalize</button></div></details>"
            "<h2>Listings <span class=note id=cnt></span></h2><div id=list></div>"
            "<p class=legend>Each listing is an ERC-721 on the registry. Rank is live allocation plus conviction accrued while it stands. "
            "<a href=# onclick='showActions();return false'>Bond a zOrgz</a> to help order it.</p>"
            "<dialog id=tk><div class=dhead id=tkh></div><div class=dbody id=tkb></div><div class=links id=tkl></div>"
            "<form method=dialog class=dfoot><button class=btn>close</button></form></dialog>"
            "<dialog id=dg><form method=dialog><div class=dhead id=dt></div><div class=dbody id=df></div><div class=derr id=de></div>"
            "<div class=dfoot><button class='btn ghost' value=cancel>cancel</button><button class=btn id=dok value=ok>confirm</button></div></form></dialog></main>"
            "<script>const C='";
    }

    /// @dev Selectors are pinned literals: this page has no ABI encoder, and a
    ///      wrong one is a silent no-op in a wallet.
    function _abi() internal pure returns (string memory) {
        return "',S={ids:'0xdf7ca268',json:'0x74e18e96',state:'0x1ba8024c',alloc:'0x1a0ffd57',bond:'0x07e8b38a',"
            "bondLock:'0xa86e18ca',lock:'0x0223449b',increase:'0xe554ab0a',eternal:'0x2fd4ecb0',claim:'0xc917b4b9',"
            "withdraw:'0x58bc0a50',unbond:'0x27de9e32',shares:'0x03314efa',zorgz:'0x0c8757f0',approve:'0x095ea7b3',"
            "weight:'0xe0fb17b2',used:'0x09807420',allocOf:'0x53e45ba5',locks:'0x10feefe2',isEternal:'0x467339e2',"
            "loyalty:'0x1827ac8f',ethBond:'0x0574ba2b',uri:'0xc87b56dd',tiers:'0x322ee5de',bal:'0x70a08231'};"
            "let A='',R='',ROWS=[],ME={},TT='',CP={},ON=false,MX=0n,ZA='';";
    }

    function _reads() internal pure returns (string memory) {
        return "const $=x=>document.getElementById(x),z=n=>'0x'+BigInt(n).toString(16).padStart(64,'0'),"
            "clean=h=>(h||'0x').slice(2),word=(h,i)=>BigInt('0x'+clean(h).slice(i*64,i*64+64)),num=h=>word(h,0),"
            "addr=h=>'0x'+clean(h).slice(24,64),show=(k,on)=>$(k).classList.toggle('off',!on),"
            "esc=x=>String(x).replace(/[&<>'\\\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',\"'\":'&#39;','\\\"':'&quot;'}[c])),"
            "f=x=>new Intl.NumberFormat('en-US',{maximumFractionDigits:0}).format(Number(x/1000000000000000000n)),"
            "eth=(x,p=4)=>{let s=(x/1000000000000000000n).toString(),d=(x%1000000000000000000n).toString().padStart(18,'0').slice(0,p).replace(/0+$/,'');return s+(d?'.'+d:'')},"
            "str=h=>{h=clean(h);let o=Number(BigInt('0x'+h.slice(0,64)))*2,n=Number(BigInt('0x'+h.slice(o,o+64)))*2,b=h.slice(o+64,o+64+n);"
            "return new TextDecoder().decode(Uint8Array.from(b.match(/../g)||[],x=>parseInt(x,16)))},"
            "idlist=h=>{h=clean(h);let o=Number(BigInt('0x'+h.slice(0,64)))*2,n=Number(BigInt('0x'+h.slice(o,o+64)));"
            "return Array.from({length:n},(_,i)=>BigInt('0x'+h.slice(o+64+i*64,o+128+i*64)))},"
            "units=v=>{v=String(v).trim();if(!/^(?:0|[1-9]\\d*)(?:\\.\\d{1,18})?$/.test(v))throw Error('Enter an amount with up to 18 decimals.');"
            "let[a,b='']=v.split('.');return BigInt(a)*1000000000000000000n+BigInt((b+'000000000000000000').slice(0,18))},"
            "id=v=>{if(!/^[0-9]+$/.test(String(v).trim()))throw Error('Enter a whole token id.');return BigInt(v)},"
            "wallet=()=>{if(!window.ethereum)throw Error('Open this page in an Ethereum wallet.');return window.ethereum},"
            "mainnet=async()=>{let p=wallet();if(await p.request({method:'eth_chainId'})!=='0x1')throw Error('Switch wallet to Ethereum mainnet.');return p},"
            // An eth_call to an address with no code SUCCEEDS with empty
            // returndata. The governor's TokenList address is immutable, so a
            // misconfigured one is permanent and has to name itself rather than
            // failing as "Cannot convert 0x to a BigInt" inside a decoder.
            "rpc=async(to,data)=>{let p=await mainnet(),h=await p.request({method:'eth_call',params:[{to,data},'latest']});"
            "if(!h||h==='0x')throw Error('No contract responded at '+to.slice(0,10)+'... - check the deployment.');return h},"
            "send=async(data,to=C,value)=>{if(!A)await connect();let p=await mainnet(),q={from:A,to,data};if(value)q.value=value;"
            "let h=await p.request({method:'eth_sendTransaction',params:[q]});say('Submitted '+h.slice(0,10)+'...');setTimeout(refresh,3000)},"
            "say=m=>{$('msg').textContent=m};";
    }

    function _actions() internal pure returns (string memory) {
        return "const refresh=async()=>{if(R)await loadReceipt();await load()},"
            "showActions=()=>{show('acts',true);$('acts').open=true;$('acts').scrollIntoView({block:'center'})},"
            // The tier menu is DAO-governed, so the page must READ it. Asking a
            // holder to type a tier number with neither its duration nor its
            // boost shown is a blind commitment of up to a year, and hardcoding
            // the table would drift the moment Moloch calls `setLockTier`.
            "tierMenu=async()=>{if(TT)return TT;let o=['0 = open'];for(let i=1;i<4;i++){let h=await rpc(C,S.tiers+z(i).slice(2));"
            "o.push(i+' = '+Number(word(h,0))/86400+'d, '+(Number(word(h,1))/10000).toFixed(2)+'x')}return TT=o.join(' \\u00b7 ')},"
            "ask=(title,fields)=>new Promise(r=>{$('dt').textContent=title;$('de').textContent='';"
            "$('df').innerHTML=fields.map(x=>'<label>'+esc(x.l)+'<input id=q_'+x.k+' value=\\''+esc(x.v==null?'':x.v)+'\\' inputmode='+(x.t||'decimal')+'></label>').join('');"
            "let d=$('dg'),done=false;d.showModal();d.onclose=()=>{if(done)return;done=true;"
            "if(d.returnValue!=='ok')return r(null);let o={};fields.forEach(x=>o[x.k]=$('q_'+x.k).value.trim());r(o)}});"
            "const guard=fn=>(...a)=>fn(...a).catch(e=>say(e.message||'Something went wrong.')),"
                        // Asking for a zOrgz id before knowing the wallet holds one is a
            // dead end: the only honest answer to an empty wallet is where to
            // get one. The collection link is derived from the governor's own
            // zorgz address, so it cannot drift.
            "connect=guard(async()=>{let p=await mainnet();[A]=await p.request({method:'eth_requestAccounts'});"
            "$('b_conn').textContent=A.slice(0,6)+'...'+A.slice(-4);ZA=addr(await rpc(C,S.zorgz));"
            "let b=num(await rpc(ZA,S.bal+z(A).slice(2)));"
            "if(b===0n)$('msg').innerHTML=\"No zOrgz in this wallet - <a href='https://opensea.io/assets/ethereum/\"+ZA"
            "+\"' target=_blank rel=noopener>get one</a> to bond and help order the list.\";"
            "else{say(b+' zOrgz held - enter one to bond.');show('rid',true);show('b_use',true);peek()}"
            "await refresh()}),"
            // Show the actual creature before it is committed: the id alone is
            // not something anyone recognises.
            "peek=async()=>{try{let v=$('rid').value;if(!/^[0-9]+$/.test(v))return show('pv',false);"
            "let j=JSON.parse(atob(str(await rpc(ZA,S.uri+z(v).slice(2))).split(',')[1]));"
            "if(!j.image)return show('pv',false);$('pv').style.backgroundImage=\"url('\"+j.image+\"')\";show('pv',true)}"
            "catch(e){show('pv',false)}},"
            "useReceipt=guard(async()=>{R=id($('rid').value).toString();await refresh()}),"
            "approveNft=guard(async()=>{let q=await ask('Approve a zOrgz',[{k:'id',l:'zOrgz token id',v:R,t:'numeric'}]);if(!q)return;"
            "await send(S.approve+z(C).slice(2)+z(id(q.id)).slice(2),addr(await rpc(C,S.zorgz)))}),"
            "approveShares=guard(async()=>{let q=await ask('Approve zOrg shares',[{k:'v',l:'zOrg amount'}]);if(!q)return;"
            "await send(S.approve+z(C).slice(2)+z(units(q.v)).slice(2),addr(await rpc(C,S.shares)))}),"
            "bond=guard(async()=>{let q=await ask('Bond a zOrgz',[{k:'id',l:'zOrgz token id',v:R,t:'numeric'},{k:'v',l:'zOrg shares to escrow'},"
            "{k:'e',l:'Refundable ETH',v:'0.01'},{k:'t',l:'Lock tier - '+await tierMenu(),v:'0',t:'numeric'}]);if(!q)return;"
            "if(!/^[0-3]$/.test(q.t))throw Error('Lock tier must be 0, 1, 2 or 3.');let w=units(q.v),e=units(q.e);"
            "if(w<=0n)throw Error('Bond a positive zOrg amount.');"
            "await send(S.bondLock+z(id(q.id)).slice(2)+z(w).slice(2)+z(BigInt(q.t)).slice(2),C,'0x'+e.toString(16))}),"
            "addZorg=guard(async()=>{let q=await ask('Add zOrg',[{k:'id',l:'Receipt id',v:R,t:'numeric'},{k:'v',l:'zOrg to add - renews maturity and lock'}]);"
            "if(!q)return;await send(S.increase+z(id(q.id)).slice(2)+z(units(q.v)).slice(2))}),"
            "lock=guard(async()=>{let q=await ask('Hard lock - cannot be shortened',[{k:'id',l:'Receipt id',v:R,t:'numeric'},{k:'t',l:await tierMenu(),t:'numeric'}]);"
            "if(!q)return;if(!/^[1-3]$/.test(q.t))throw Error('Tier must be 1, 2 or 3.');await send(S.lock+z(id(q.id)).slice(2)+z(BigInt(q.t)).slice(2))}),"
            "eternal=guard(async()=>{let q=await ask('Eternalize - NEVER redeemable again',[{k:'id',l:'Receipt id',v:R,t:'numeric'},"
            "{k:'c',l:'Type ETERNAL to confirm',v:'',t:'text'}]);if(!q)return;if(q.c!=='ETERNAL')throw Error('Type ETERNAL to confirm.');"
            "await send(S.eternal+z(id(q.id)).slice(2))}),"
            "claim=guard(async()=>{let q=await ask('Claim loyalty ETH',[{k:'id',l:'Receipt id',v:R,t:'numeric'}]);if(!q)return;await send(S.claim+z(id(q.id)).slice(2))}),"
            "withdraw=guard(async()=>{if(!A)await connect();await send(S.withdraw+z(A).slice(2))}),"
            "redeem=guard(async()=>{let q=await ask('Redeem - returns the zOrgz, zOrg and ETH',[{k:'id',l:'Receipt id',v:R,t:'numeric'}]);"
            "if(!q)return;await send(S.unbond+z(id(q.id)).slice(2))}),"
            "setWeight=guard(async(listing)=>{await send(S.alloc+z(BigInt(R)).slice(2)+z(BigInt(listing)).slice(2)+z(units($('a_'+listing).value)).slice(2))});";
    }

    function _render() internal pure returns (string memory) {
        return "const TIER=['open','tier 1','tier 2','tier 3'],"
            // A registry that stores SVG onchain instead of a CDN link should
            // hand the source over, not merely paint it. `svgOf` unwraps the
            // base64 data URI the registry stores back into plain markup.
            "svgOf=u=>u&&u.startsWith('data:image/svg+xml;base64,')?atob(u.slice(26)):(u||''),"
            // `navigator.clipboard` is unavailable in an insecure context and
            // blocked by permissions policy inside an iframe, where it rejects.
            // The promise had no catch, so a blocked copy did nothing at all -
            // no text on the clipboard, no error, a button that looked dead.
            // Fall back to a selection copy, and always report which happened.
            // The textarea goes INSIDE the open dialog: a modal dialog makes the
            // rest of the document inert, so a body-level node cannot be selected.
            "sel=v=>{let a=document.createElement('textarea'),ok=false;a.value=v;a.style.cssText='position:fixed;opacity:0';"
            "($('tk')||document.body).appendChild(a);a.focus();a.select();try{ok=document.execCommand('copy')}catch(e){}a.remove();return ok},"
            "cp=async(k,el)=>{let v=CP[k]||'',o=el.dataset.l||el.innerHTML;el.dataset.l=o;let ok=!!v;"
            "if(ok){try{await navigator.clipboard.writeText(v)}catch(e){ok=sel(v)}}"
            "el.innerHTML=ok?'copied':v?'blocked':'empty';setTimeout(()=>{el.innerHTML=o},1400)},"
            // A listing with no logo yet must not emit src='': `list()` and
            // `setLogoSVG()` are separate calls, so that is the ordinary state of
            // a freshly listed token, and an empty src paints a broken-image icon.
            "lg=t=>t.j.l?\"<img class=logo src='\"+esc(t.j.l)+\"' alt=''>\":'<i class=logo></i>',"
            // One subtle icon per field beats a row of footer buttons: the
            // affordance sits on the value it copies, so nothing has to be
            // labelled twice and the logo is grabbed from the logo line.
            "IC=\"<svg width=12 height=12 viewBox='0 0 16 16' fill=none stroke=currentColor stroke-width=1.5>"
            "<rect x=5.6 y=5.6 width=8.8 height=8.8/><path d='M10.4 3.4h-7.8v7.8'/></svg>\","
            "dl=(k,v,c)=>'<div class=dl><span>'+k+'</span><code>'+esc(v==null?'':v)"
            "+(c?\"<button type=button class=ic title='Copy \"+k+\"' onclick=cp('\"+c+\"',this)>\"+IC+'</button>':'')+'</code></div>',"
            "lnk=(u,t)=>u?\" <a href='\"+esc(u)+\"' target=_blank rel=noopener>\"+t+'</a>':'';"
            "function openToken(i){let t=ROWS.find(x=>String(x.id)===String(i));if(!t)return;let j=t.j;"
            "CP={a:j.a||'',s:svgOf(j.l),u:j.l||'',i:String(t.id)};"
            "$('tkh').innerHTML=lg(t)+'<div><b>'+esc(t.sym)+'</b><small>'+esc(t.name)+'</small></div>';"
            "$('tkb').innerHTML=dl('Address',j.a,'a')+dl('Chain',j.c)+dl('Decimals',j.d)+dl('Standard',j.p)"
            // `onchainSvg` is a COLLECTION flag - "selected token IDs resolve to
            // data-SVG art" - so it is false for every ERC-20 and says nothing
            // about the logo. Labelling it "Onchain SVG" read as a claim about
            // the logo, which is stored as onchain SVG for essentially every
            // listing, so wstETH appeared to deny art it plainly has. Report the
            // logo's own storage, and only mention per-token art where it exists.
            "+dl('Logo',j.l?(j.l.startsWith('data:')?'onchain SVG':'external URL'):'none',j.l?'s':0)"
            "+(j.l&&j.l.startsWith('data:')?dl('Data URI','base64 SVG','u'):'')"
            "+(j.o?dl('Token art','onchain SVG per token id'):'')"
            "+dl('Support',f(t.score)+' ('+f(t.live)+' live / '+f(t.acc)+' accrued)')"
            "+dl('Listing id',t.id,'i');"
            // Each listing is an ERC-721 on the registry, so its marketplace page
            // follows from the address this page was rendered with.
            "$('tkl').innerHTML=\"<a href='https://opensea.io/assets/ethereum/\"+L+'/'+t.id+\"' target=_blank rel=noopener>OpenSea</a>\""
            "+lnk(j.u,'Site')+lnk(j.au,'Audit');$('tk').showModal()}"
            "const dis=(k,why)=>{let e=$('b_'+k);if(e){e.disabled=!!why;e.title=why||''}};"
            "function syncActions(){let n=ME.w?'':'Load a bonded zOrgz id first.',t=Date.now()/1000;"
            "dis('add',n);dis('claim',n);"
            "dis('lock',n||(ME.eternal?'Eternal bonds cannot be locked.':ME.tier?'Already hard locked.':''));"
            "dis('etern',n||(ME.eternal?'Already eternal.':ME.w<10000000000000000000000n?'Needs 10,000 zOrg.':''));"
            "dis('redeem',n||(ME.eternal?'Eternal bonds are never redeemable.':ME.used>0n?'Set every allocation to 0 first.':"
            "t<ME.until?'Hard locked until '+new Date(ME.until*1000).toISOString().slice(0,10)+'.':''));}"
            "async function loadReceipt(){try{ME={};let w=num(await rpc(C,S.weight+z(R).slice(2)));"
            "if(w===0n){say('No bond found for zOrgz #'+R+'.');return}"
            "let[u,lk,ev,ly,eb]=await Promise.all([rpc(C,S.used+z(R).slice(2)),rpc(C,S.locks+z(R).slice(2)),rpc(C,S.isEternal+z(R).slice(2)),"
            "rpc(C,S.loyalty+z(R).slice(2)),rpc(C,S.ethBond+z(R).slice(2))]);"
            "ME={w,used:num(u),boost:word(lk,2),tier:Number(word(lk,3)),until:Number(word(lk,1)),eternal:num(ev)===1n,loyalty:num(ly),principal:word(eb,0)};"
            "try{let uri=str(await rpc(C,S.uri+z(R).slice(2))),j=JSON.parse(atob(uri.split(',')[1]));"
            "if(j.image)$('face').style.backgroundImage=\"url('\"+j.image+\"')\"}catch(e){}"
            "}catch(e){say(e.message)}}"
            // ON is the whole gate. Without a wallet AND real bonded weight the
            // page stays a token list and nothing else.
            "function paint(){ON=!!(A&&ME.w);show('me',ON);show('acts',ON);syncActions();if(!ON)return;"
            "$('me').classList.toggle('eternal-name',ME.eternal);"
            "$('rstatus').innerHTML='<b>zOrgz #'+esc(R)+'</b> \\u00b7 '+(ME.eternal?'eternal':TIER[ME.tier])+' \\u00b7 '+f(ME.w)+' zOrg bonded';"
            "$('credit').innerHTML='<b>'+f(ME.w-ME.used)+' zOrg</b> available \\u00b7 '+f(ME.used)+' allocated';"
            "$('eth').innerHTML=eth(ME.principal)+' ETH principal \\u00b7 <b>'+eth(ME.loyalty)+' ETH</b> loyalty';"
            "ROWS.forEach(t=>{let el=$('a_'+t.id);if(el&&document.activeElement!==el)el.value=t.mine?eth(t.mine,18):''})}"
            "const row=(t,i)=>'<div class=\\'r'+(ON?' on':'')+'\\' style=--s:'+(MX>0n?Number(t.score*100n/MX):0)+'% tabindex=0 data-i='+t.id+'>"
            "<span class=rank>'+String(i+1).padStart(2,'0')+'</span>"
            "<span class=top>'+lg(t)+'<span><b>'+esc(t.sym)+'</b><small>'+esc(t.name)+'</small></span></span>"
            "<span class=score>'+f(t.score)+'<small>'+f(t.live)+' live \\u00b7 '+f(t.acc)+' accrued</small></span>'"
            "+(ON?'<span class=alloc><input id=a_'+t.id+' inputmode=decimal placeholder=0 aria-label=\\'zOrg for '+esc(t.sym)+'\\'>"
            "<button class=btn onclick=setWeight('+t.id+')>set</button></span>':'')+'</div>';"
            "async function listing(id){let j={};try{j=JSON.parse(str(await rpc(L,S.json+z(id).slice(2))))}catch(e){}"
            "let st=await rpc(C,S.state+z(id).slice(2)),score=num(st),live=word(st,1),mine=0n;"
            "if(R){try{mine=num(await rpc(C,S.allocOf+z(R).slice(2)+z(id).slice(2)))}catch(e){}}"
            "return{id,j,sym:j.s||j.name||'TOKEN',name:j.n||'',score,live,acc:score-live,mine}}"
            "const load=guard(async()=>{let ii=idlist(await rpc(L,S.ids));"
            "ROWS=await Promise.all(ii.map(listing));"
            "ROWS.sort((a,b)=>a.score===b.score?0:a.score>b.score?-1:1);"
            "ON=!!(A&&ME.w);MX=ROWS[0]?ROWS[0].score:0n;$('list').innerHTML=ROWS.map(row).join('')||'<p class=legend>No listings yet.</p>';"
            "$('cnt').textContent=ROWS.length+' onchain';paint()});"
            // Delegated, so the handlers do not repeat per row and a keyboard
            // user reaches the same dialog as a pointer.
            "$('list').onclick=e=>{if(e.target.closest('.alloc'))return;let r=e.target.closest('.r');if(r)openToken(r.dataset.i)};"
            "$('list').onkeydown=e=>{if(e.key!=='Enter')return;let r=e.target.closest('.r');if(r)openToken(r.dataset.i)};"
            "load();</script>";
    }
}
