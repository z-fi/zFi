/**
 * Proposal rendering and loading states for dapp/dao/index.html.
 *
 * The DAO page had no test coverage at all, and its failure modes are the
 * quiet kind: a vote tally that renders but is unreadable, a quorum bar that
 * is off by a factor of the snapshot supply, a re-render that appends a second
 * copy of every proposal instead of replacing them. None of those throw.
 *
 * The page is loaded in jsdom with ethers injected and the external scripts
 * stripped. Note that the page's own globals are top-level `let` bindings,
 * which are NOT window properties — state has to be installed through
 * window.eval so it resolves to the same global lexical environment.
 */
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM, VirtualConsole } from 'jsdom';
import * as ethersLib from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const E = 10n ** 18n;

let dom, w, doc;

function loadDaoPage() {
  let html = fs.readFileSync(path.join(ROOT, 'dapp/dao/index.html'), 'utf8');
  // theme.js / ethers.min.js / wallet.js are not resolvable here; ethers is
  // injected directly and walletInit is stubbed.
  html = html.replace(/<script src="[^"]*"><\/script>/g, '');

  const virtualConsole = new VirtualConsole();
  virtualConsole.on('jsdomError', () => {});

  return new JSDOM(html, {
    url: 'https://dao.test/',
    runScripts: 'dangerously',
    pretendToBeVisual: true,
    virtualConsole,
    beforeParse(win) {
      win.ethers = ethersLib;
      win.walletInit = () => {};
      win.matchMedia = q => ({
        media: q, matches: false,
        addEventListener() {}, removeEventListener() {},
        addListener() {}, removeListener() {},
      });
      win.TextEncoder = TextEncoder;
      win.TextDecoder = TextDecoder;
      // jsdom ships no canvas backend; the hero fire animation is irrelevant here.
      win.HTMLCanvasElement.prototype.getContext = () => ({
        fillRect() {}, clearRect() {}, drawImage() {}, putImageData() {},
        createImageData: () => ({ data: [] }),
        getImageData: () => ({ data: new Uint8ClampedArray(4) }),
        set fillStyle(v) {}, get fillStyle() { return '#000'; },
      });
      Object.defineProperty(win.navigator, 'clipboard', {
        configurable: true, value: { writeText: async () => {} },
      });
    },
  });
}

// A proposal literal, built as source so it lands in the page's own scope.
function proposalSrc(id, state, forV, againstV, abstainV, createdAt) {
  return `{id:${id}n,proposer:'0x${'11'.repeat(20)}',state:${state},snapshotBlock:1n,`
    + `createdAt:${createdAt}n,queuedAt:0n,supplySnapshot:${1000n * E}n,`
    + `forVotes:${forV}n,againstVotes:${againstV}n,abstainVotes:${abstainV}n,`
    + `futarchy:{enabled:false},voters:[]}`;
}

/** 1 Active (55% of quorum), 1 Executed, 1 Defeated. */
function installFixtureDAO() {
  const now = Math.floor(Date.now() / 1000);
  const proposals = [
    proposalSrc(1, 1, 100n * E, 10n * E, 0n, now - 100),
    proposalSrc(2, 6, 500n * E, 0n, 0n, now - 100),
    proposalSrc(3, 4, 1n * E, 900n * E, 0n, now - 100),
  ].join(',');
  w.eval(`currentDAO = {member:null,dao:{dao:'0x${'22'.repeat(20)}',`
    + `meta:{name:'T',symbol:'T'},`
    + `gov:{quorumBps:2000,quorumAbsolute:0,proposalTTL:604800,timelockDelay:0},`
    + `proposals:[${proposals}],messages:[]}}`);
}

describe('DAO proposals', () => {
  before(async () => {
    dom = loadDaoPage();
    w = dom.window;
    doc = w.document;
    await new Promise(r => setTimeout(r, 400));
    installFixtureDAO();
  });
  after(() => { try { w.close(); } catch {} });

  describe('vote amount formatting', () => {
    // The bug this pins: tallies printed as raw 18-decimal strings, so a real
    // proposal read "1591891.552865487391515666" beside a "0.0".
    test('abbreviates large tallies', () => {
      assert.equal(w.fmtVoteAmount(1591891552865487391515666n), '1.59M');
      assert.equal(w.fmtVoteAmount(2500n * E), '2.5K');
    });

    test('never rounds a non-zero tally down to zero', () => {
      assert.equal(w.fmtVoteAmount(0n), '0');
      assert.equal(w.fmtVoteAmount(1000n), '<0.0001');
    });

    test('leaves ordinary amounts legible', () => {
      assert.equal(w.fmtVoteAmount(2500000000000000000n), '2.5');
    });
  });

  test('countdown formatting', () => {
    assert.equal(w.fmtCountdown(90061), '1d 1h');
    assert.equal(w.fmtCountdown(3660), '1h 1m');
    assert.equal(w.fmtCountdown(0), '0s');
    assert.equal(w.fmtCountdown(-5), '0s', 'a passed deadline must not go negative');
  });

  test('skeletons render as visible placeholder cards', () => {
    // .skeleton previously had no CSS at all, so "loading" was an empty panel.
    w.showProposalsSkeleton();
    assert.equal(doc.querySelectorAll('.proposal-skeleton').length, 2);
    const css = fs.readFileSync(path.join(ROOT, 'dapp/dao/index.html'), 'utf8');
    assert.match(css, /\.skeleton\s*\{[^}]*background:/, '.skeleton must carry a background');
  });

  describe('rendering', () => {
    before(async () => {
      w._connectedAddress = null;
      await w.renderProposals(0n);
    });

    test('renders every proposal and clears the skeletons', () => {
      assert.equal(doc.querySelectorAll('.proposal-item').length, 3);
      assert.equal(doc.querySelectorAll('.proposal-skeleton').length, 0);
    });

    test('quorum bar reflects turnout against bps of snapshot supply', () => {
      // 110 cast against a 20% quorum of a 1000 supply = 110/200 = 55%.
      const row = [...doc.querySelectorAll('.proposal-progress')]
        .map(e => e.textContent.replace(/\s+/g, ' ').trim())
        .find(t => t.startsWith('Quorum'));
      assert.equal(row, 'Quorum 55.0% 110 / 200');
    });

    test('only the open proposal gets a quorum bar', () => {
      assert.equal(doc.querySelectorAll('.proposal-quorum-bar').length, 1);
    });

    test('shows the voting deadline while a proposal is open', () => {
      const row = [...doc.querySelectorAll('.proposal-progress')]
        .map(e => e.textContent.replace(/\s+/g, ' ').trim())
        .find(t => t.startsWith('Voting closes'));
      assert.match(row, /^Voting closes in \d+d/);
    });

    test('re-rendering replaces the list rather than appending to it', async () => {
      await w.renderProposals(0n);
      await w.renderProposals(0n);
      assert.equal(doc.querySelectorAll('.proposal-item').length, 3);
    });
  });

  describe('wallet state', () => {
    test('without a wallet, an active proposal invites connecting', async () => {
      w._connectedAddress = null;
      await w.renderProposals(0n);
      assert.equal(doc.querySelectorAll('.proposal-connect-hint').length, 1);
      assert.equal(doc.querySelectorAll('.proposal-button.for').length, 0,
        'vote buttons must not appear without a signer');
    });

    test('with a wallet, the vote buttons appear', async () => {
      w._connectedAddress = '0x' + '33'.repeat(20);
      await w.renderProposals(0n);
      assert.equal(doc.querySelectorAll('.proposal-button.for').length, 1);
      assert.equal(doc.querySelectorAll('.proposal-connect-hint').length, 0);
    });
  });

  describe('filters', () => {
    test('chips carry live per-bucket counts', async () => {
      w.setProposalFilter('all');
      await new Promise(r => setTimeout(r, 50));
      const chips = [...doc.querySelectorAll('.proposal-filter')]
        .map(b => b.textContent.replace(/\s+/g, ''));
      assert.deepEqual(chips, ['All3', 'Open1', 'Ready0', 'Closed2']);
    });

    test('narrow the list to their bucket', async () => {
      w.setProposalFilter('open');
      await new Promise(r => setTimeout(r, 50));
      assert.equal(doc.querySelectorAll('.proposal-item').length, 1);

      w.setProposalFilter('closed');
      await new Promise(r => setTimeout(r, 50));
      assert.equal(doc.querySelectorAll('.proposal-item').length, 2);
    });

    test('a filter whose bucket is empty falls back to All', async () => {
      w.setProposalFilter('ready');   // count is 0
      await new Promise(r => setTimeout(r, 50));
      assert.equal(doc.querySelectorAll('.proposal-item').length, 3);
    });
  });

  test('a DAO with no proposals says so and hides the toolbar', async () => {
    w.eval('currentDAO.dao.proposals = []');
    w.setProposalFilter('all');
    await new Promise(r => setTimeout(r, 50));
    assert.match(doc.getElementById('proposalsList').textContent, /No proposals yet/);
    assert.equal(doc.getElementById('proposalsToolbar').style.display, 'none');
    installFixtureDAO();
  });

  test('the deep-link read asks for the same proposal window as the wallet read', () => {
    // A 5-proposal read-only window against a 200-proposal connected window is
    // what made the list visibly jump to different content on connect.
    const src = fs.readFileSync(path.join(ROOT, 'dapp/dao/index.html'), 'utf8');
    assert.match(src, /getDAOWithDAICO\(\s*address,\s*0,\s*200,\s*0,\s*200,/,
      'getDAOWithDAICO must fetch 200 proposals, matching fetchUserDAOs');
  });
});
