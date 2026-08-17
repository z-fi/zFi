#!/usr/bin/env node
/**
 * The liquidity tile's amount boxes, made honest.
 *
 * THE PROBLEM. In liquidity mode the two big boxes at the top of the card are
 * the deposit for "Create a new band". They were shown ALWAYS - including when
 * that form was collapsed, which is whenever the pair already has bands. In
 * that state they fed nothing and previewed nothing: a number typed there did
 * literally nothing until you happened to expand the section, at which point it
 * retroactively became the form's first input. Meanwhile each existing band has
 * its own small inputs inside the row, so the screen showed two identical-
 * looking places to type with no relationship between them.
 *
 * THE FIX. Keep the tile boxes as the deposit - they are the biggest, best
 * placed inputs on the screen and they already carry the balance and the Max
 * link - but show them only when the form they feed is on screen. Row adds keep
 * their own inputs, because those belong to one band each.
 *
 * Idempotent. A script rather than an edit because zSwap.html is being worked
 * on in an editor at the same time: a saved buffer carries the whole file and
 * silently reverts anything written since it was opened. That has happened
 * repeatedly, once leaving a half-applied state where the calls survived and
 * the function they called did not. Re-running costs nothing.
 *
 * Run:  node script/fix-liquidity-amounts.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FILE = path.join(ROOT, 'zSwap.html');
let s = fs.readFileSync(FILE, 'utf8');

const HELPER = `/* The tile's amount rows belong to the create form, so they show exactly when
   it does. Left up permanently they were INERT whenever that form was
   collapsed - a number typed there fed nothing and previewed nothing until you
   happened to expand the section, at which point it retroactively became that
   form's first input. Hidden when it is closed, they cannot lie. */
const lqSyncAmounts=()=>{
const show=!lqMode||!!lqList.querySelector(".lqnew");
for(const el of [amtRow,outRow])if(el)el.classList.toggle("hide",!show);
};
`;

/* Each entry is [test, apply]. Every one is skipped if already satisfied, so a
   partial revert is repaired rather than duplicated - which is exactly the
   state a mid-edit save leaves behind. */
const steps = [
  // An earlier attempt at this added a SECOND pair of amount inputs inside the
  // create form. That approach was abandoned - it left the tile panels hollow,
  // a label and a Max link with no field - but a mid-edit save brought the
  // inputs back while the tile approach was also in place, putting FOUR amount
  // boxes on one screen. Removing them is part of the fix, not a one-off.
  ['NO_DUPLICATE_AMOUNTS', s => {
    const i = s.indexOf('+`<div class="lqamt"');
    if (i < 0) return s;
    const end = s.indexOf('</div>`', i) + '</div>`\n'.length;
    // Walk back over the comment block that introduces them, if there is one.
    let start = i;
    const c = s.lastIndexOf('/*', i);
    if (c >= 0 && s.slice(c, i).indexOf('*/') === s.slice(c, i).length - 3) start = c;
    return (s.slice(0, start) + s.slice(end))
      .replace('.lqamt{display:flex;gap:.4em;margin-bottom:.1em}\n.lqamt .lqin{flex:1;min-width:0}\n', '');
  }],

  ['const lqSyncAmounts', s => s.replace('function lqSet(on){', HELPER + 'function lqSet(on){')],

  // Every render path re-decides whether the create form is on screen.
  ['lqempty">Pick two different tokens.</div>`;lqSub.textContent="";lqRows=[];return}lqSyncAmounts();',
   s => s.replace('lqList.innerHTML=`<div class="lqempty">Pick two different tokens.</div>`;lqSub.textContent="";lqRows=[];return}',
                  'lqList.innerHTML=`<div class="lqempty">Pick two different tokens.</div>`;lqSub.textContent="";lqRows=[];return}lqSyncAmounts();')],
  ['No Precision band for this pair yet.</div>`+lqNewForm(t0,t1);lqSyncAmounts();',
   s => s.replace('lqList.innerHTML=`<div class="lqempty">No Precision band for this pair yet.</div>`+lqNewForm(t0,t1);',
                  'lqList.innerHTML=`<div class="lqempty">No Precision band for this pair yet.</div>`+lqNewForm(t0,t1);lqSyncAmounts();')],
  ['id="lqNewTog">Create a new band</button>`;\nlqSyncAmounts();',
   s => s.replace('+`<button class="lqbtn lqnewtog" id="lqNewTog">Create a new band</button>`;',
                  '+`<button class="lqbtn lqnewtog" id="lqNewTog">Create a new band</button>`;\nlqSyncAmounts();')],
  ['Could not read pools.</div>`;lqSyncAmounts();',
   s => s.replace('lqList.innerHTML=`<div class="lqempty">Could not read pools.</div>`;',
                  'lqList.innerHTML=`<div class="lqempty">Could not read pools.</div>`;lqSyncAmounts();')],
  ['lqNewForm(pr[0],pr[1]);\nlqSyncAmounts();',
   s => s.replace('ev.target.outerHTML=lqNewForm(pr[0],pr[1]);',
                  'ev.target.outerHTML=lqNewForm(pr[0],pr[1]);\nlqSyncAmounts();')],

  // Max belongs to a ROW's form only; the tile is filled by the ordinary path.
  // Guarded on the CODE, not on the comment above it: comments get stripped
  // and reformatted, and a guard that tests prose reports "anchor moved" for a
  // step that is in fact already applied.
  ['const box=lqList.querySelector(".lqadd:not(.hide)");',
   s => s.replace('const box=lqList.querySelector(".lqnew")||lqList.querySelector(".lqadd:not(.hide)");',
     `/* A ROW's add form only. The create form's amounts are the tile's own
   boxes, which the ordinary path below already fills - routing those here
   would look for a \`.lqin\` that does not exist and silently fill nothing. */
const box=lqList.querySelector(".lqadd:not(.hide)");`)],
];

let changed = 0;
for (const [have, apply] of steps) {
  // A sentinel rather than a literal: this step is a REMOVAL, so "already
  // present" cannot be tested by looking for text it adds.
  if (have !== 'NO_DUPLICATE_AMOUNTS' && s.includes(have)) continue;
  if (have === 'NO_DUPLICATE_AMOUNTS' && !s.includes('class="lqamt"')) continue;
  const next = apply(s);
  if (next === s) {
    console.error(`anchor moved, nothing written for: ${have.slice(0, 60)}`);
    process.exit(1);
  }
  s = next;
  changed++;
}

if (!changed) {
  console.log('already applied — nothing to do');
  process.exit(0);
}
fs.writeFileSync(FILE, s);
console.log(`applied ${changed} step(s) — zSwap.html is now ${s.length} bytes`);
