/**
 * zSwap invaders — an easter egg for v0.4.
 *
 * The tokens you can trade today descend on you; the ether logo shoots back.
 * Invaders are drawn from whatever the page's token list holds at that moment,
 * so the roster is the live market rather than a baked-in set — and the WEI
 * pixel invader (the same path the names tile already draws) fills out the
 * ranks when the list is short.
 *
 * DOM rather than canvas, deliberately: every token icon is ALREADY an HTML
 * string in the page — a data: URI <img> from the list, or a generated letter
 * disc. Drawing those on a canvas would mean loading each one as an Image and
 * handling the ones that never arrive. Reusing the markup costs nothing and
 * cannot fail. Thirty absolutely-positioned nodes moved by transform is well
 * inside what a phone does at 60fps.
 *
 * This file is DEV SOURCE. The deployed page carries no comments and no
 * indentation (see script/strip-zSwap.mjs), so integration is: strip, inline,
 * wire the long-press. Kept standalone so it can be played and tested without
 * touching the v0.3 candidate.
 */

/** The names-tile invader, reused as a sprite. Free bytes: the page has it. */
export const WEI_PATH =
  'M3 1h1v1H3zM5 2h1v1H5zM10 2h1v1h-1zM12 1h1v1h-1zM4 4h8v1H4zM3 5h10v1H3zM2 6h12v3H2z'
  + 'M3 9h10v1H3zM4 10h8v1H4zM5 11h2v1H5zM9 11h2v1H9zM2 12h3v1H2zM7 12h2v1H7zM11 12h3v1h-3z'
  + 'M1 13h2v1H1zM13 13h2v1h-2zM3 6h3v2H3zM10 6h3v2h-3z';

export const weiSprite = (size = 20) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 16 16" fill="currentColor" fill-rule="evenodd"`
  + ` shape-rendering="crispEdges"><path d="${WEI_PATH}"/></svg>`;

const COLS = 6, ROWS = 4;      // 24 invaders a wave, unless a caller says otherwise
const IW = 22, IH = 20;        // invader cell
const SHIP_W = 22, SHIP_H = 20;
const BULLET_W = 2, BULLET_H = 7;
const SHIP_SPEED = 190;        // px/sec
const BULLET_SPEED = 260;
const BOMB_SPEED = 110;
const LIVES = 3;

/**
 * Start a game inside `host`.
 *
 * `icons` is [{sym, html}] — the page passes its live token list. Anything
 * short of a full grid is padded with WEI invaders rather than repeating one
 * token into a wall of the same face.
 *
 * Returns a handle with `stop()`; the game also stops itself on exit.
 */
export function invaders(host, { icons = [], ship = '', onExit = () => {},
  now = () => performance.now(), cols = COLS, rows = ROWS } = {}) {
  const W = host.clientWidth || 340, H = host.clientHeight || 260;
  const el = (cls, html) => {
    const d = host.ownerDocument.createElement('div');
    d.className = cls; if (html) d.innerHTML = html;
    return d;
  };

  const wrap = el('inv');
  wrap.tabIndex = 0;
  wrap.setAttribute('role', 'application');
  wrap.setAttribute('aria-label', 'Token invaders. Arrow keys to move, space to fire, escape to leave.');
  host.appendChild(wrap);

  const hud = el('invhud');
  wrap.appendChild(hud);

  // ---- state ----
  let alive = [], bullets = [], bombs = [];
  let shipX = (W - SHIP_W) / 2, left = false, right = false;
  let score = 0, lives = LIVES, wave = 1, over = false, won = false;
  let dir = 1, stepAt = 0, lastFire = -Infinity, raf = 0, last = now();

  const roster = () => {
    const out = [];
    for (let i = 0; i < cols * rows; i++) {
      const t = icons[i % Math.max(1, icons.length)];
      out.push(icons.length ? t : { sym: 'WEI', html: weiSprite() });
    }
    // A short list would otherwise be the same few faces tiled; the WEI
    // invader fills the gap so a wave still looks like a wave.
    if (icons.length && icons.length < cols * rows) {
      for (let i = icons.length; i < out.length; i += 1)
        if (i % 3 === 0) out[i] = { sym: 'WEI', html: weiSprite() };
    }
    return out;
  };

  function spawn() {
    for (const a of alive) a.node.remove();
    alive = [];
    const list = roster();
    const padX = (W - cols * IW) / 2;
    for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
      const t = list[r * cols + c];
      const node = el('invx', t.html);
      node.title = t.sym;
      wrap.appendChild(node);
      alive.push({ node, sym: t.sym, x: padX + c * IW, y: 16 + r * IH, col: c, row: r });
    }
    dir = 1;
  }

  const shipNode = el('invship', ship || weiSprite(SHIP_W));
  wrap.appendChild(shipNode);

  const place = (node, x, y) => { node.style.transform = `translate(${x.toFixed(1)}px,${y.toFixed(1)}px)`; };

  function fire() {
    const t = now();
    // One shot in flight, the way the original worked: it makes the rhythm of
    // the game about timing rather than about holding the button down.
    if (over || bullets.length || t - lastFire < 120) return;
    lastFire = t;
    const node = el('invb');
    wrap.appendChild(node);
    bullets.push({ node, x: shipX + SHIP_W / 2 - BULLET_W / 2, y: H - SHIP_H - 12 });
  }

  function drop() {
    if (!alive.length) return;
    // Only the lowest invader in a column can bomb — otherwise the front rank
    // absorbs its own side's fire and the screen fills with nothing.
    const byCol = new Map();
    for (const a of alive) { const cur = byCol.get(a.col); if (!cur || a.y > cur.y) byCol.set(a.col, a); }
    const front = [...byCol.values()];
    const a = front[(Math.random() * front.length) | 0];
    const node = el('invbomb');
    wrap.appendChild(node);
    bombs.push({ node, x: a.x + IW / 2, y: a.y + IH });
  }

  const hit = (ax, ay, aw, ah, bx, by, bw, bh) =>
    ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by;

  function syncHud() {
    hud.textContent = over
      ? (won ? `cleared wave ${wave} · ${score}` : `game over · ${score}`)
      : `${score}   ${'▲'.repeat(Math.max(0, lives))}   wave ${wave}`;
  }

  function stop() {
    if (raf) cancelAnimationFrame(raf);
    raf = 0;
    wrap.remove();
    host.ownerDocument.removeEventListener('keydown', onKey, true);
    host.ownerDocument.removeEventListener('keyup', onUp, true);
  }

  function endGame(w) { over = true; won = w; syncHud(); }

  function frame() {
    const t = now(), dt = Math.min(0.05, (t - last) / 1000);
    last = t;
    if (!over) step(dt, t);
    raf = requestAnimationFrame(frame);
  }

  function step(dt, t) {
    // ship
    if (left) shipX -= SHIP_SPEED * dt;
    if (right) shipX += SHIP_SPEED * dt;
    shipX = Math.max(0, Math.min(W - SHIP_W, shipX));
    place(shipNode, shipX, H - SHIP_H - 4);

    // invaders march in steps, faster as the wave thins — the original's
    // accelerating dread, and it falls out of the arithmetic for free.
    const period = Math.max(90, 620 - (cols * rows - alive.length) * 22 - (wave - 1) * 60);
    if (t - stepAt > period) {
      stepAt = t;
      let edge = false;
      for (const a of alive) {
        const nx = a.x + dir * 6;
        if (nx < 0 || nx + IW > W) edge = true;
      }
      for (const a of alive) {
        if (edge) a.y += 8; else a.x += dir * 6;
        place(a.node, a.x, a.y);
      }
      if (edge) dir *= -1;
      if (Math.random() < 0.5 + wave * 0.08) drop();
      if (alive.some(a => a.y + IH >= H - SHIP_H - 4)) return endGame(false);
    }

    for (const b of bullets) { b.y -= BULLET_SPEED * dt; place(b.node, b.x, b.y); }
    for (const b of bombs) { b.y += BOMB_SPEED * dt; place(b.node, b.x, b.y); }

    // bullet vs invader
    for (let i = bullets.length - 1; i >= 0; i--) {
      const b = bullets[i];
      if (b.y + BULLET_H < 0) { b.node.remove(); bullets.splice(i, 1); continue; }
      const j = alive.findIndex(a => hit(a.x, a.y, IW - 2, IH - 2, b.x, b.y, BULLET_W, BULLET_H));
      if (j >= 0) {
        const a = alive[j];
        a.node.classList.add('pop');
        const gone = a.node;
        setTimeout(() => gone.remove(), 120);
        alive.splice(j, 1);
        score += a.sym === 'WEI' ? 25 : 10;
        b.node.remove(); bullets.splice(i, 1);
        if (!alive.length) { wave++; score += 100; spawn(); }
      }
    }
    // bomb vs ship
    for (let i = bombs.length - 1; i >= 0; i--) {
      const b = bombs[i];
      if (b.y > H) { b.node.remove(); bombs.splice(i, 1); continue; }
      if (hit(shipX, H - SHIP_H - 4, SHIP_W, SHIP_H, b.x, b.y, 2, 6)) {
        b.node.remove(); bombs.splice(i, 1);
        lives--;
        shipNode.classList.add('pop');
        setTimeout(() => shipNode.classList.remove('pop'), 200);
        if (lives <= 0) return endGame(false);
      }
    }
    syncHud();
  }

  function onKey(e) {
    if (e.key === 'Escape') { e.preventDefault(); stop(); onExit(); return; }
    if (e.key === 'ArrowLeft') { left = true; e.preventDefault(); }
    else if (e.key === 'ArrowRight') { right = true; e.preventDefault(); }
    else if (e.key === ' ' || e.key === 'Enter') {
      e.preventDefault();
      if (over) { over = false; won = false; score = 0; lives = LIVES; wave = 1; spawn(); syncHud(); }
      else fire();
    }
  }
  function onUp(e) {
    if (e.key === 'ArrowLeft') left = false;
    if (e.key === 'ArrowRight') right = false;
  }
  host.ownerDocument.addEventListener('keydown', onKey, true);
  host.ownerDocument.addEventListener('keyup', onUp, true);

  // Touch: drag anywhere to steer, tap to fire.
  let touching = false;
  wrap.addEventListener('pointerdown', e => {
    touching = true;
    shipX = Math.max(0, Math.min(W - SHIP_W, e.offsetX - SHIP_W / 2));
    if (over) { over = false; score = 0; lives = LIVES; wave = 1; spawn(); syncHud(); } else fire();
  });
  wrap.addEventListener('pointermove', e => {
    if (touching) shipX = Math.max(0, Math.min(W - SHIP_W, e.offsetX - SHIP_W / 2));
  });
  wrap.addEventListener('pointerup', () => { touching = false; });

  spawn();
  syncHud();
  wrap.focus();
  raf = requestAnimationFrame(frame);

  return {
    stop,
    // Exposed for tests: the game is a state machine, and asserting on it is
    // far steadier than asserting on pixels.
    state: () => ({ score, lives, wave, over, won, alive: alive.length, bullets: bullets.length, bombs: bombs.length, shipX }),
    _fire: fire, _drop: drop, _step: step, _spawn: spawn,
  };
}

export const INVADERS_CSS = `
.inv{position:absolute;inset:0;background:var(--b,#0e0e0e);overflow:hidden;outline:0;touch-action:none;border-radius:.5em}
.invx{position:absolute;width:20px;height:20px;will-change:transform;transition:opacity .12s}
.invx.pop{opacity:0;transform-origin:center}
.invship{position:absolute;width:22px;height:20px;will-change:transform}
.invship.pop{opacity:.35}
.invb{position:absolute;width:2px;height:7px;background:#16a34a;will-change:transform}
.invbomb{position:absolute;width:2px;height:6px;background:#c33;will-change:transform}
.invhud{position:absolute;top:2px;left:6px;right:6px;font-size:9px;letter-spacing:.08em;
  color:var(--m,#888);pointer-events:none;font-variant-numeric:tabular-nums}
`;

/**
 * Arm a long-press on an element that already has a click.
 *
 * The names tile is the trigger, and it is not a spare control — a short click
 * still has to toggle names mode. The whole difficulty is the click that
 * arrives AFTER a hold: without swallowing it, opening the game also flips the
 * page into names mode behind it, and leaving the game drops you somewhere you
 * did not ask to be. So the hold marks itself, and the next click is eaten in
 * the capture phase before the tile's own handler ever sees it.
 *
 * `contextmenu` is suppressed too: on touch a long press raises the callout
 * menu over the top of whatever just opened.
 */
export function armLongPress(el, { ms = 550, onHold } = {}) {
  let timer = 0, held = false;
  const cancel = () => { if (timer) clearTimeout(timer); timer = 0; };
  const down = () => { held = false; cancel(); timer = setTimeout(() => { timer = 0; held = true; onHold(); }, ms); };
  const eat = e => { if (held) { e.preventDefault(); e.stopPropagation(); held = false; } };
  const menu = e => e.preventDefault();
  el.addEventListener('pointerdown', down);
  el.addEventListener('pointerup', cancel);
  el.addEventListener('pointerleave', cancel);
  el.addEventListener('pointercancel', cancel);
  el.addEventListener('click', eat, true);
  el.addEventListener('contextmenu', menu);
  return () => {
    cancel();
    el.removeEventListener('pointerdown', down);
    el.removeEventListener('pointerup', cancel);
    el.removeEventListener('pointerleave', cancel);
    el.removeEventListener('pointercancel', cancel);
    el.removeEventListener('click', eat, true);
    el.removeEventListener('contextmenu', menu);
  };
}
