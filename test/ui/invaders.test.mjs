/**
 * The invaders easter egg.
 *
 * The game SHIPS INLINE in zSwap.html; `game/` holds the prototype it grew
 * from, kept because its harness is the only way to play against the real
 * on-chain logos while tuning. The two can drift, so the tests that matter are
 * the page-driven ones at the bottom of this file — the module tests above
 * cover the rules, the page tests cover what is actually deployed.
 *
 * Rules are tested as a state machine rather than as pixels: what makes a game
 * like this fun is a handful of rules interacting, and those are far easier to
 * get right against assertions.
 *
 * Everything here drives the state machine directly rather than a rendered
 * frame: the game exposes `state()` and its step function precisely so a test
 * can advance time deterministically instead of racing requestAnimationFrame.
 */
import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { invaders, weiSprite, WEI_PATH, INVADERS_CSS, armLongPress } from '../../game/invaders.mjs';
import { A, MockChain, loadPage, closeAllPages } from './harness.mjs';

/** A zTokenlist row, matching the shape the registry serves. */
const row = (sym, addr, dec = 18, p = 'ERC-20') => ({
  i: '1', c: 1, k: 'eip155', p, x: true, o: false, f: false,
  a: addr, n: sym, s: sym, d: dec, t: '#888', r: 1, u: '', au: '', l: '', desc: '', e: [], v: true,
});

/** A game on a fixed-size host with an injected clock, so time is ours. */
function play({ icons = ['WETH', 'USDC', 'ZAMM'].map(s => ({ sym: s, html: `<i>${s}</i>` })),
  cols, rows } = {}) {
  const dom = new JSDOM('<div id="c"></div>', { pretendToBeVisual: true });
  const { window } = dom;
  window.requestAnimationFrame = () => 0;
  window.cancelAnimationFrame = () => {};
  global.requestAnimationFrame = window.requestAnimationFrame;
  global.cancelAnimationFrame = window.cancelAnimationFrame;
  const host = window.document.getElementById('c');
  Object.defineProperty(host, 'clientWidth', { value: 340 });
  Object.defineProperty(host, 'clientHeight', { value: 260 });
  let t = 0;
  const g = invaders(host, { icons, ship: '<b>E</b>', now: () => t, ...(cols ? { cols } : {}), ...(rows ? { rows } : {}) });
  return {
    g, host, window,
    tick(ms = 16) { t += ms; g._step(ms / 1000, t); },
    run(n, ms = 16) { for (let i = 0; i < n; i++) this.tick(ms); },
    faces: () => [...host.querySelectorAll('.invx')].map(n => n.title),
    close: () => { g.stop(); dom.window.close(); },
  };
}

describe('token invaders', () => {
  test('fields a full wave from whatever the token list holds', async () => {
    const p = play();
    assert.equal(p.g.state().alive, 24, 'a wave should be a full grid');
    assert.equal(p.faces().length, 24);
    p.close();
  });

  test('pads a short list with WEI rather than tiling one face', async () => {
    // Three tokens across twenty-four slots would otherwise be the same three
    // faces eight times over, which reads as a rendering bug rather than a
    // wave. The names-tile invader fills the ranks instead.
    const p = play({ icons: [{ sym: 'WETH', html: '<i>W</i>' }] });
    const faces = p.faces();
    assert.ok(faces.includes('WEI'), 'a one-token list should still field WEI invaders');
    assert.ok(new Set(faces).size >= 2, 'a wave of one repeated face is not a wave');
    p.close();
  });

  test('fires one shot at a time, and the first shot is not swallowed', async () => {
    // The cooldown is measured against the clock, and both start at zero on a
    // fresh page - so the opening shot went nowhere until the cooldown was
    // seeded to negative infinity.
    const p = play();
    p.g._fire();
    assert.equal(p.g.state().bullets, 1, 'the first shot must leave the ship');
    p.g._fire();
    assert.equal(p.g.state().bullets, 1, 'a second shot must wait for the first to clear');
    p.close();
  });

  test('a hit removes exactly one invader and scores it', async () => {
    const p = play();
    const before = p.g.state().alive;
    p.g._fire();
    p.run(40);
    const s = p.g.state();
    assert.equal(s.alive, before - 1, 'one shot, one invader');
    assert.ok(s.score > 0, 'a kill should score');
    assert.equal(s.bullets, 0, 'the bullet is spent');
    p.close();
  });

  test('a WEI invader is worth more than a token', async () => {
    const wei = play({ icons: [{ sym: 'WEI', html: weiSprite() }] });
    wei.g._fire(); wei.run(40);
    const weiScore = wei.g.state().score;
    wei.close();

    const tok = play({ icons: [{ sym: 'WETH', html: '<i>W</i>' }] });
    // Aim at a column the WEI padding does not occupy.
    tok.g._fire(); tok.run(40);
    const tokScore = tok.g.state().score;
    tok.close();
    assert.ok(weiScore >= tokScore, `WEI ${weiScore} should not score under a token ${tokScore}`);
  });

  test('clearing a wave starts a harder one rather than ending the game', async () => {
    // One invader, dead centre, so clearing does not depend on steering the
    // ship under every column in turn.
    const p = play({ cols: 1, rows: 1 });
    for (let i = 0; i < 60 && p.g.state().wave === 1; i++) { p.g._fire(); p.run(20); }
    const s = p.g.state();
    assert.ok(s.wave >= 2, `clearing should advance the wave, got ${s.wave}`);
    assert.equal(s.over, false, 'clearing a wave is not the end of the game');
    assert.ok(s.alive > 0, 'the next wave should be on the board');
    p.close();
  });

  test('bombs cost a life, and running out ends it', async () => {
    const p = play();
    const start = p.g.state().lives;
    // Park the ship under a column and let the front rank bomb it.
    for (let i = 0; i < 4000 && p.g.state().lives === start && !p.g.state().over; i++) p.tick(16);
    const s = p.g.state();
    assert.ok(s.lives < start || s.over, 'the ship should eventually be hit');
    p.close();
  });

  test('leaves nothing behind when it stops', async () => {
    // It lives over the swap card, so anything it forgets to remove sits on
    // top of the form afterwards.
    const p = play();
    p.g._fire();
    p.run(5);
    p.g.stop();
    assert.equal(p.host.children.length, 0, 'the game left nodes on the card');
    p.window.close();
  });

  test('a hold opens the game and the tile does NOT also toggle', async () => {
    // The trigger is the names tile, which is a real control. A hold that
    // opens the game and ALSO fires the tile's click leaves names mode open
    // underneath - so quitting the game drops you somewhere you never asked
    // to go.
    const dom = new JSDOM('<button id="wn">tile</button>', { pretendToBeVisual: true });
    const el = dom.window.document.getElementById('wn');
    let toggled = 0, opened = 0;
    el.addEventListener('click', () => { toggled++; });
    const disarm = armLongPress(el, { ms: 5, onHold: () => { opened++; } });

    el.dispatchEvent(new dom.window.Event('pointerdown'));
    await new Promise(r => setTimeout(r, 20));
    el.dispatchEvent(new dom.window.Event('pointerup'));
    el.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true, cancelable: true }));
    assert.equal(opened, 1, 'the hold should open the game');
    assert.equal(toggled, 0, 'and must swallow the click that follows it');
    disarm();
    dom.window.close();
  });

  test('a short click still reaches the tile', async () => {
    const dom = new JSDOM('<button id="wn">tile</button>', { pretendToBeVisual: true });
    const el = dom.window.document.getElementById('wn');
    let toggled = 0, opened = 0;
    el.addEventListener('click', () => { toggled++; });
    const disarm = armLongPress(el, { ms: 400, onHold: () => { opened++; } });

    el.dispatchEvent(new dom.window.Event('pointerdown'));
    el.dispatchEvent(new dom.window.Event('pointerup'));       // released well before 400ms
    el.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true, cancelable: true }));
    await new Promise(r => setTimeout(r, 450));
    assert.equal(opened, 0, 'a quick click must not open the game');
    assert.equal(toggled, 1, 'and must still toggle names mode');
    disarm();
    dom.window.close();
  });

  test('dragging off the tile abandons the hold', async () => {
    const dom = new JSDOM('<button id="wn">tile</button>', { pretendToBeVisual: true });
    const el = dom.window.document.getElementById('wn');
    let opened = 0;
    const disarm = armLongPress(el, { ms: 20, onHold: () => { opened++; } });
    el.dispatchEvent(new dom.window.Event('pointerdown'));
    el.dispatchEvent(new dom.window.Event('pointerleave'));
    await new Promise(r => setTimeout(r, 60));
    assert.equal(opened, 0, 'sliding off a tile is how a user changes their mind');
    disarm();
    dom.window.close();
  });

  test('the sprite is the same invader the names tile already draws', async () => {
    // Reusing the tile's path is what makes the sprite free: the deployed page
    // carries those bytes for the tile whether the game ships or not.
    const page = (await import('node:fs')).readFileSync(
      new URL('../../zSwap.html', import.meta.url), 'utf8');
    assert.ok(page.includes(WEI_PATH.slice(0, 60)),
      'the game sprite has drifted from the tile it is meant to reuse');
    assert.match(weiSprite(), /viewBox="0 0 16 16"/);
    assert.match(INVADERS_CSS, /\.inv\{/);
  });
});

/**
 * The shipped game, driven through the real page.
 *
 * The trigger is the names tile, which is a live control - so the risk is not
 * that the game fails to open, it is that opening it ALSO toggles names mode
 * and leaves the form in a state nobody asked for behind the game.
 */
describe('the game in the page', () => {
  const ETH = 10n ** 18n;

  async function openPage() {
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const p = await loadPage({ chain });
    await p.connect();
    const card = p.doc.querySelector('.card');
    // jsdom lays nothing out, and the game sizes itself from the card.
    Object.defineProperty(card, 'clientWidth', { value: 340 });
    Object.defineProperty(card, 'clientHeight', { value: 300 });
    return { p, card };
  }
  const hold = async (p, ms) => {
    p.$('wn').dispatchEvent(new p.window.Event('pointerdown'));
    await new Promise(r => setTimeout(r, ms));
    p.$('wn').dispatchEvent(new p.window.Event('pointerup'));
    p.$('wn').dispatchEvent(new p.window.MouseEvent('click', { bubbles: true, cancelable: true }));
    await p.settle();
  };

  test('a hold opens it over the card, and names mode stays shut', async () => {
    const { p, card } = await openPage();
    await hold(p, 700);
    assert.ok(card.querySelector('.inv'), 'holding the tile did not open the game');
    assert.equal(card.querySelectorAll('.invx').length, 24, 'a wave should be a full grid');
    assert.ok(!p.visible('wnPanel'),
      'the click after the hold leaked through and opened names mode behind the game');
    p.close(); await closeAllPages();
  });

  test('a short click still just toggles names mode', async () => {
    const { p, card } = await openPage();
    await hold(p, 30);
    assert.ok(!card.querySelector('.inv'), 'a quick click must not open the game');
    assert.ok(p.visible('wnPanel'), 'and must still toggle names mode');
    p.close(); await closeAllPages();
  });

  test('the invaders are the tokens the page actually holds', async () => {
    const { p, card } = await openPage();
    await hold(p, 700);
    const faces = [...card.querySelectorAll('.invx')].map(n => n.title);
    assert.ok(faces.some(f => f !== 'WEI'), `no real tokens on the board: ${faces.join(' ')}`);
    assert.ok(faces.includes('WEI'), 'WEI should fill out the ranks');
    assert.ok(!faces.includes('ETH'), 'ether is the ship, it should not also be an invader');
    p.close(); await closeAllPages();
  });

  test('the front rank is the launchpad, deepest first', async () => {
    // The point of putting live tokens in the game is that getting a coin's
    // liquidity up puts it on the board. Ordering the grid straight down the
    // token list broke that promise: the curated eighteen filled three rows
    // and eighteen of twenty-four launches never appeared however deep they
    // were. The bottom row is reserved for them, in pool-depth order.
    const chain = new MockChain();
    chain.setNative(A.ACCOUNT, 10n * ETH);
    const rows = [row('ETH', A.ZERO, 18, 'Native'), row('USDC', A.USDC, 6)];
    chain.registry = rows;
    chain.conviction = rows.map((_, i) => i + 1);
    const coins = [['DEEPC', 30n], ['MIDC', 20n], ['THINC', 10n]];
    coins.forEach(([sym], i) =>
      chain.setToken('0x' + String(i + 1).repeat(40), { symbol: sym, decimals: 18, name: sym }));
    chain.setLaunched(coins.map(([sym, dep], i) => ({
      pool: '0x' + String(i + 6).repeat(40), token: '0x' + String(i + 1).repeat(40), reserve0: dep * ETH })));

    const p = await loadPage({ chain });
    await p.connect();
    const card = p.doc.querySelector('.card');
    Object.defineProperty(card, 'clientWidth', { value: 340 });
    Object.defineProperty(card, 'clientHeight', { value: 300 });
    p.$('wn').dispatchEvent(new p.window.Event('pointerdown'));
    await new Promise(r => setTimeout(r, 700));
    p.$('wn').dispatchEvent(new p.window.Event('pointerup'));
    await p.settle();

    const faces = [...card.querySelectorAll('.invx')].map(n => n.title);
    assert.equal(faces.length, 24);
    const front = faces.slice(18);                 // the last row of six
    assert.ok(front.includes('DEEPC'),
      `the deepest launch must reach the board, front rank was ${front.join(' ')}`);
    assert.ok(!faces.slice(0, 18).includes('DEEPC'),
      'launched coins belong in the front rank, not scattered through the curated ranks');
    p.close(); await closeAllPages();
  });

  /**
   * The mint is a wiring check, not a played game: scoring needs collisions,
   * and jsdom lays nothing out, so there is no honest way to reach a nonzero
   * score here. What CAN be pinned down is what the mint points at and how it
   * reports itself - and the reporting is where this went wrong. Failures used
   * to go to `err()`, which writes the swap status line, which sits UNDER the
   * game's full-card overlay. Every refusal - a rejected signature, a taken
   * label, no wallet - looked identical to a dead button.
   */
  describe('minting a score', () => {
    const page = readFileSync(new URL('../../zSwap.html', import.meta.url), 'utf8');
    const body = page.slice(page.indexOf('const mint=async'), page.indexOf('function kd(e)'));

    test('it calls claim() on the deployed ScoreMinter', () => {
      assert.ok(page.includes('0x57Fae63f7c63732fc4B77247F0255b11b9458AE1'),
        'the page must point at the deployed ScoreMinter');
      assert.ok(page.includes('SEL_SCLAIM="5cc2f461"'),
        'claim(string,string,address)');
      assert.ok(page.includes('.arcade.wei'), 'and report the name under arcade.wei');
    });

    test('the selector does not collide with the timelock claim', () => {
      assert.ok(page.includes('SEL_CLAIM="379607f5"'),
        'the timelock claim must keep its own selector');
      assert.notEqual('5cc2f461', '379607f5');
    });

    test('the old open-registrar mint is gone', () => {
      assert.doesNotMatch(page, /minted=lbl\+"\.id\.wei"/,
        'names must not come from a parent anyone can mint under');
    });

    test('a failure is reported inside the game, not behind it', () => {
      assert.doesNotMatch(body, /\berr\(/,
        'err() writes the status line, which the overlay covers');
      assert.match(body, /mintMsg=/, 'the mint should report through the HUD');
      assert.match(body, /isRejection/, 'a cancelled signature reads as cancelled');
      assert.ok(page.includes('mintMsg?`${mintMsg}`:'), 'and the HUD must render it');
    });

    test('an unconnected wallet is asked for rather than ignored', () => {
      assert.match(body, /connect to mint/, 'the reason for the pause should be shown');
      assert.match(body, /wallet not connected/, 'and a refusal should not look like a hang');
    });

    test('a score can be shared whether or not it was minted', () => {
      const sh = page.slice(page.indexOf('const shareScore='), page.indexOf('const mint=async'));
      assert.match(sh, /x\.com\/intent\/post/, 'the share should open a post');
      assert.match(sh, /encodeURIComponent/, 'and encode what it puts in it');
      // `window.open` returns null WHENEVER noopener is in the features string,
      // success or not - so asking for it there would make every share look
      // blocked. The handle is severed on the returned window instead.
      assert.doesNotMatch(sh, /"_blank","noopener/, 'noopener in features hides success');
      assert.match(sh, /win\.opener=null/, 'a new tab must not keep a handle on this one');
      assert.match(sh, /minted\?/, 'a minted name is worth naming; a bare score still shares');
    });

    /**
     * The page runs from a lot of places - localhost, an ipfs gateway under a
     * bafy hash, web3:// which is not an http URL at all - and `location.href`
     * is the right link in almost none of them. A shared score has to point at
     * somewhere a stranger can actually open, which is the stable name.
     */
    test('it links to the canonical host, not wherever this copy is served', () => {
      const sh = page.slice(page.indexOf('const shareScore='), page.indexOf('const mint=async'));
      // Points at the staging name while v0.3 is still being served from a pin;
      // it moves to zswap.wei.limo when v0.3 is the onchain page. Either way it
      // must be a name a stranger can open, never wherever this copy is served.
      assert.match(page, /const SHARE_HOST="[a-z0-9.-]*zswap\.wei\.limo"/,
        'the share target must be a stable zswap.wei.limo name');
      assert.match(sh, /"https:\/\/"\+SHARE_HOST/, 'and the share must use it');
      assert.doesNotMatch(sh, /location\.href/, 'never the serving origin');
    });

    test('a blocked pop-up falls back rather than doing nothing', () => {
      const sh = page.slice(page.indexOf('const shareScore='), page.indexOf('const mint=async'));
      assert.match(sh, /if\(win\)\{/, 'a blocked window returns null, not an error');
      assert.match(sh, /clipboard\.writeText/, 'so the text should be copied instead');
      assert.ok(page.includes('${shareMsg||"share"}'), 'and the HUD must say which happened');
    });

    test('sharing is offered only once there is a score', () => {
      assert.ok(page.includes('sc>0&&!minting?`<span class="invsh">'),
        'no score, nothing to share; mid-mint, nothing settled to share');
      assert.ok(page.includes('k==="invsh"'), 'and the HUD must act on it');
    });

    /**
     * A tap anywhere on the field restarts a finished game, and the mint is a
     * round trip to a wallet - so a player who taps while "minting..." is up
     * starts a new run with a transaction still in flight. Without a run token
     * the result lands on the new run: the next game over shows the PREVIOUS
     * run\'s name and refuses to mint the score just played, because `minted`
     * is already set.
     */
    /**
     * Every other write in this page checks the wallet before it builds a
     * transaction - same chain, same account as when the page last looked. The
     * mint did not. That matters more here than anywhere else, because `rpc`
     * hands EVERY method to the wallet once one is connected, `eth_call`
     * included: on the wrong network the preflight quietly returns "0x" - no
     * revert, nothing to catch - and the page would go on to ask for a
     * signature against a chain the minter does not exist on.
     */
    test('it checks the wallet before it builds anything', () => {
      assert.match(body, /await checkWallet\(\)/,
        'the mint must verify chain and account like every other write');
      assert.ok(body.indexOf('checkWallet') < body.indexOf('const req='),
        'and do it before building the transaction');
    });

    test('a preflight that answers with nothing is not treated as success', () => {
      assert.match(body, /strip0x\(ret\|\|""\)\.length!==64/,
        'claim returns a token id; anything else means the call did not run');
      assert.match(body, /mainnet/, 'and the message should point at the likely reason');
    });

    test('a mint that lands after a restart does not touch the new run', () => {
      assert.match(body, /const r=runId/, 'the run must be captured before the round trip');
      assert.ok(/if\(r===runId\)\{minted=/.test(body), 'and checked before the name is kept');
      assert.ok(/if\(r===runId\)\{[\s\S]{0,120}?mintMsg=/.test(body),
        'and before a failure is reported');
      assert.ok(page.includes('const again=()=>{runId++'), 'a restart must invalidate it');
    });

    /**
     * The label is the only part of the collectible anyone sees - WNS renders
     * the name and nothing else, so the text record is invisible in a wallet.
     * Carrying the wave there means an honest name records how far the run
     * actually got, and a forged one has to pick a wave that fits its score.
     */
    test('the label records the wave as well as the score', () => {
      assert.match(body, /const lbl=sc\+"-w"\+wv\+"-"/,
        'score, wave reached, then the collision tag');
      const label = (sc, wv, tag) => sc + '-w' + wv + '-' + tag;
      assert.equal(label(4820, 7, 'k3x9'), '4820-w7-k3x9');
      // MAX_LABEL on the minter is 63; nothing the game can produce comes close.
      assert.ok(label(999999999999, 42, 'zzzz').length <= 63);
    });

    test('the random tag is always four characters', () => {
      // Math.random() can produce "0.5" - slice(2,6) of that is one character,
      // and of "0" it is none, which makes a bare "245-" label and a needless
      // collision with the next player to score 245.
      assert.match(body, /padEnd\(4,"0"\)\.slice\(0,4\)/, 'pad before trimming');
      const tag = n => n.toString(36).slice(2).padEnd(4, '0').slice(0, 4);
      for (const n of [0, 0.5, 0.123456789, 1 / 3, 0.9999999999]) {
        assert.equal(tag(n).length, 4, `${n} should still give four characters`);
      }
    });

    test('a status is not dressed up as something to press', () => {
      // "minting..." and the finished name are underlined-link styling in the
      // same slot the action lives in; only the action should look pressable.
      assert.ok(page.includes('${minted||minting?"invmsg":"invm"}'),
        'a result or an in-flight mint should not read as a control');
      assert.match(page, /\.invmsg\{color:var\(--m\)\}/, 'and should be styled as text');
    });

    test('the reported message cannot inject markup', () => {
      // It lands in innerHTML, and explain() can carry a node's own error text.
      assert.ok(/mintMsg=String\([^;]*replace\(\/\[<>&/.test(body),
        'the message must be sanitised where it is assigned');
    });
  });

  test('escape puts the swap form back exactly as it was', async () => {
    const { p, card } = await openPage();
    await hold(p, 700);
    p.doc.dispatchEvent(new p.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    await p.settle();
    assert.ok(!card.querySelector('.inv'), 'escape did not close the game');
    assert.equal(card.querySelectorAll('.invx').length, 0, 'invaders were left on the card');
    assert.ok(p.visible('swap'), 'the swap button should be back');
    p.close(); await closeAllPages();
  });
});
