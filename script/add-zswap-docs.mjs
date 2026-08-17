#!/usr/bin/env node
/**
 * Add the in-page docs to zSwap.html. Idempotent: run it as often as you like.
 *
 * WHY THIS IS A SCRIPT AND NOT JUST AN EDIT. It was applied twice by hand and
 * overwritten twice, because the file was being edited in another buffer at the
 * same time - a saved buffer carries the whole file, so it silently reverts
 * anything written since it was opened. A patch that can be re-run costs
 * nothing to re-apply and cannot be lost that way.
 *
 * Run:  node script/add-zswap-docs.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FILE = path.join(ROOT, 'zSwap.html');
let s = fs.readFileSync(FILE, 'utf8');

/* If a docs block is already there, REPLACE it rather than bailing. Bailing is
   what let a stale copy survive: an editor buffer saved over the file, bringing
   back an older docPanel, and an "already present" check happily left the old
   wording in place. The text here is the source of truth; anything on disk is a
   copy that may have been reverted. */
const EXISTING = /<div id="docPanel"[\s\S]*?<\/div>\s*(?=<footer id="foot">)/;
const hadDocs = EXISTING.test(s);
if (hadDocs) s = s.replace(EXISTING, '');

const CSS_ANCHOR = '.lnon #chTog,.lnon #chBox,.lnon #bkTog,.lnon #book,.lnon #pos{display:none!important}';
const CSS = CSS_ANCHOR + `
/* DOCS. The page already explains itself - 21 \`title\` tooltips, ~2.7 KB of it -
   and every word is unreachable on a phone, because there is no hover. This is
   the same explanation in a place a thumb can get to. Native <details> so it
   costs no script and collapses to a scannable list of headings. */
.docs{margin-top:.5em}
.docs details{border-top:1px solid var(--e)}
.docs details:last-child{border-bottom:1px solid var(--e)}
.docs summary{cursor:pointer;list-style:none;padding:.7em .2em;font-size:.78em;font-weight:600;
letter-spacing:.02em;color:var(--f);display:flex;justify-content:space-between;align-items:center}
.docs summary::-webkit-details-marker{display:none}
.docs summary::after{content:"+";color:var(--m);font-weight:400}
.docs details[open] summary::after{content:"\\2013"}
.docs p{margin:0 0 .7em;padding:0 .2em;font-size:.72em;line-height:1.6;color:var(--n)}
.docs b{color:var(--f);font-weight:600}
.docs em{font-style:normal;color:var(--m)}`;

const DOCS = `<div id="docPanel" class="docs hide">
<details><summary>Swapping</summary>
<p>Every quote is compared across Uniswap v2, v3 and v4, Curve, Sushi and our own Precision pools, and the best one wins. One route, one signature.</p>
<p><b>Slippage</b> is the worst price you will accept &mdash; move past it and the trade reverts rather than filling badly. <b>Price impact</b> is how far your own size moves the price; the page warns as it grows and will not let a very bad one through quietly.</p>
<p>ETH and WETH are interchangeable here. The page wraps or unwraps whichever way the pool needs, inside the same transaction.</p></details>

<details><summary>Sending</summary>
<p>A plain transfer, or a <b>SLOW</b> one: time-locked, and reversible by you at any point until it matures. Useful for large amounts and for addresses you have not paid before.</p>
<p>A locked transfer does not deliver itself &mdash; someone must send the claim once it matures. Tick <b>auto-claim</b> and the page posts a small tip so a keeper does that for the recipient. The tip is refundable: reverse the transfer and it comes back.</p></details>

<details><summary>Orders</summary>
<p><b>Fixed limit</b> &mdash; a price you name. It rests until someone fills it or you cancel.</p>
<p><b>Dutch decay</b> &mdash; starts above your floor and falls to it over a window you choose. It has two clocks: the decay, then how long it rests at the floor before the escrow returns to you. Set that to <em>Forever</em> and it waits until you cancel.</p>
<p><b>Climbing bid</b> &mdash; the mirror: a bid that rises toward a ceiling you name.</p>
<p>Orders are escrowed on chain when placed, so a fill cannot fail for want of funds, and cancelling returns the escrow. Boards are denominated in WETH &mdash; an order asking for ETH is asking for WETH, and pays out as such.</p></details>

<details><summary>Liquidity <em>the droplet</em></summary>
<p>Precision pools are <b>bands</b>, not endless curves. A position earns fees only while the price is inside its band, and holds one asset or the other at the edges. A wider band is safer and earns less; a narrow one is the opposite.</p>
<p>The bar on each row shows where the price sits in that band. <em>Out of range</em> means it is earning nothing right now.</p></details>

<details><summary>Launching a coin <em>the coin</em></summary>
<p>One transaction, and no ether needed aside from gas. A fixed supply is minted, your allocation is paid to you immediately, and <b>everything else is seeded into a fresh ETH pool</b> &mdash; one-sided, so the pool opens holding only your token.</p>
<p><b>Starting market cap</b> is the pool's virtual ether reserve. It sets the opening price and how hard that price is to move, which are the same dial: roughly that much buying moves the market halfway. Small numbers mean the first buyer takes a large share of the supply, which is why the form says what one ether would buy.</p>
<p><b>Creator keeps</b> is a share of the token SUPPLY, minted straight to you when the coin launches &mdash; tokens, not ether, and not a fee on trading. Keep 10% of a billion and 100,000,000 land in your wallet at once, unlocked, with nothing vesting.</p>
<p>Whatever you keep does not go into the pool, and selling it later pulls ether back out of that pool &mdash; so a modest-looking percentage can be a claim on most of what early buyers put in. Anyone deciding whether to buy your coin can work that out too.</p>
<p>A <b>logo</b> is stored as contract code on Ethereum &mdash; no IPFS, no pinning service, nothing to go dark. Upload anything; the page compresses it and shows the size before you sign. You can replace it later.</p></details>

<details><summary>Fees</summary>
<p>A launched market charges <b>1%</b> per swap. Half of that stays in the pool as reserves, which raises the floor for every holder. The other half is collectable, and splits <b>80% creator, 10% protocol, 10% tithe</b>.</p>
<p>The <b>tithe</b> is burned to Ethereum itself. The ether goes to the BETH burner, which destroys it and mints a BETH receipt recording that it happened. Nobody can spend it and it cannot be redeemed &mdash; the ether no longer exists. What it buys is a smaller ether supply, which accrues to everyone holding ether rather than to us.</p>
<p>The token side of collected fees is burned outright too &mdash; a launched coin's supply only ever falls.</p></details>

<details><summary>What this page is</summary>
<p>There is no server. This page is a contract on Ethereum and its bytes cannot be changed by anyone, us included &mdash; a new version is a new address, not an edit. It talks to your wallet and to Ethereum, and to nothing else.</p>
<p>Your keys never leave your wallet. Nothing here custodies your funds; every trade settles from your address to a contract you can read.</p>
<p>The token list is <b>zList</b>, ranked on chain by conviction staking. Anything not on it can still be traded by pasting its address.</p></details>
</div>`;

const JS = `
/* The docs, behind a footer link rather than a seventh icon: this is a
   reference, not a mode, and the meta row is already full. */
footDoc.onclick=e=>{
e.preventDefault();
const on=docPanel.classList.contains("hide");
docPanel.classList.toggle("hide",!on);
footDoc.textContent=on?"hide":"how it works";
if(on)docPanel.scrollIntoView({behavior:"smooth",block:"nearest"});
};
`;

const steps = [
  [CSS_ANCHOR, CSS],
  ['<footer id="foot">', DOCS + '\n<footer id="foot">'],
  ['<span>&middot; <a id="footList"',
   '<span>&middot; <a id="footDoc" href="#" role="button">how it works</a></span><span>&middot; <a id="footList"'],
  ['\nlq.onclick=()=>lqSet(!lqMode);', JS + '\nlq.onclick=()=>lqSet(!lqMode);'],
];

for (const [find, put] of steps) {
  // The CSS, the footer link and the handler survive a replacement, so skip
  // whichever are already in place instead of duplicating them.
  if (put !== DOCS + '\n<footer id="foot">' && s.includes(put.split('\n')[1] ?? put)) continue;
  if (!s.includes(find)) {
    console.error(`anchor moved, nothing written:\n  ${find.slice(0, 70)}`);
    process.exit(1);
  }
  s = s.replace(find, put);
}

fs.writeFileSync(FILE, s);
console.log(`${hadDocs ? 'docs refreshed' : 'docs added'} — zSwap.html is now ${s.length} bytes`);
