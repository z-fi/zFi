import test from "node:test";
import assert from "node:assert/strict";
import {loadPage, MockChain, A} from "./harness.mjs";
import {readFile} from "node:fs/promises";

const PLAUNCH = "0x0000002fc8e77585a008aa45d78a71ad36293aee";
const SEL_LAUNCH = "6a648dc6";

/**
 * Launching a coin.
 *
 * Not a tab: it is an icon in the meta row that swaps the panel underneath,
 * the same grammar the liquidity droplet already uses. Most of what can go
 * wrong here is in the ARGUMENT ENCODING - `launch` takes three strings before
 * four static words, and the page's existing `encStr` cannot serve because it
 * hardcodes an offset of 0x20 that is only right for a lone string. So the
 * encoding is checked against the real ABI layout rather than merely for the
 * presence of a selector.
 */

async function open_(opts = {}) {
  const chain = opts.chain ?? new MockChain();
  if (!opts.noFunds) chain.setNative(A.ACCOUNT, 10n ** 19n);
  const p = await loadPage({chain});
  await p.connect();
  p.click("ln");
  return p;
}

const head = (data, i) => data.slice(10 + i * 64, 10 + (i + 1) * 64);
const word = (data, i) => BigInt("0x" + head(data, i));
const at = (data, byteOff) => data.slice(10 + byteOff * 2);

test("launching a coin", async (t) => {
  await t.test("is an icon beside liquidity, not a tab of its own", async () => {
    const p = await loadPage({chain: new MockChain()});
    assert.ok(p.$("ln"), "no launch control");
    // Drawn, not typed: U+1FA99 renders as a blank disc on systems whose emoji
    // font predates it, which is most of them. An inline stroke follows the
    // theme and the active state without a font having to cooperate.
    assert.ok(p.$("ln").querySelector("svg"), "the coin should be drawn, not an emoji");
    assert.ok(!p.visible("lnPanel"), "the panel starts closed");
    p.click("ln");
    assert.ok(p.visible("lnPanel"), "clicking the coin opens it");
    // And it takes the swap surface over rather than stacking beneath it.
    assert.ok(!p.visible("rcvPanel"), "the receive panel should stand down");
    p.click("ln");
    assert.ok(!p.visible("lnPanel"), "clicking again closes it");
    p.close();
  });

  await t.test("keeps the address bar, relabelled for what it now means", async () => {
    // Not hidden. `owner` is not merely who receives the allocation - it is who
    // collects creator fees for the life of the token and who may edit its
    // metadata, which a project may well want to be a multisig rather than the
    // key that happened to sign the launch. The page already relabels this same
    // input for liquidity, so this is its own grammar.
    const p = await open_();
    assert.ok(p.visible("rc"), "the address bar stays");
    assert.match(p.$("rc").placeholder, /Creator/, "and says what it now sets");
    assert.ok(!p.visible("swap"), "the swap button does stand down");
    p.click("ln");
    assert.match(p.$("rc").placeholder, /Recipient/, "and reverts when launch mode ends");
    p.close();
  });

  await t.test("groups the supply as it is typed", async () => {
    // Nine ungrouped digits is where a stray zero becomes a tenfold error in
    // the opening price that nothing downstream will question.
    const p = await open_();
    p.type("lnSupply", "1000000000");
    assert.equal(p.value("lnSupply"), "1,000,000,000");
    p.close();
  });

  await t.test("signs the raw number the grouped one stands for", async () => {
    // What is shown and what is signed must not drift: separators are stripped
    // and the value normalised to 18 decimals.
    const p = await open_();
    p.type("lnName", "A");
    p.type("lnSym", "X");
    p.type("lnSupply", "1000000000");
    assert.equal(p.value("lnSupply"), "1,000,000,000");
    p.click("lnGo");
    await p.waitFor(() => p.chain.sent.length > 0, {label: "launch"});
    await p.settle();
    assert.equal(word(p.chain.sent[0].data, 3), 10n ** 27n, "commas leaked into the amount");
    p.close();
  });

  await t.test("gives the launch button the page's primary styling", async () => {
    // Without it the button is inline and lands beside the note rather than
    // under the form, which is what the first screenshot showed.
    const p = await open_();
    assert.ok(p.$("lnGo").classList.contains("primary"), "Launch is a primary action");
    p.close();
  });

  await t.test("keeps every meta-row control on one line", async () => {
    // `.meta` is an explicit grid. Adding the coin without widening it pushed
    // the theme toggle onto a second row.
    const p = await loadPage({chain: new MockChain()});
    const cols = p.window.getComputedStyle(p.doc.querySelector(".meta")).gridTemplateColumns;
    const kids = p.doc.querySelector(".meta").children.length;
    assert.ok(cols.split(/\s+/).filter(Boolean).length >= kids,
      `${kids} controls but only ${cols} - something will wrap`);
    p.close();
  });

  await t.test("is mutually exclusive with liquidity mode", async () => {
    // Both take over the same surface, so both being on would render two
    // panels into one slot.
    const p = await loadPage({chain: new MockChain()});
    p.click("lq");
    // Settled before asserting: the droplet kicks off a pool read, and tearing
    // the page down mid-flight throws from a listener no test is watching.
    await p.settle();
    p.click("ln");
    assert.ok(p.visible("lnPanel"));
    assert.ok(!p.visible("lqPanel"), "the droplet should have stood down");
    p.click("lq");
    await p.settle();
    assert.ok(!p.visible("lnPanel"), "and the coin should stand down in turn");
    p.close();
  });

  await t.test("leaves the swap tab with the coin, like the droplet", async () => {
    const p = await loadPage({chain: new MockChain()});
    p.click("ln");
    p.click("tabSend");
    assert.ok(!p.visible("lnPanel"), "launch mode must not survive a tab change");
    assert.ok(!p.visible("ln"), "the coin hides off-tab");
    p.close();
  });

  await t.test("states the opening price rather than making you derive it", async () => {
    // The contract takes a VALUATION; everybody thinks in price per token.
    const p = await open_();
    p.type("lnSupply", "1000000000");
    p.type("lnMcap", "30");
    p.type("lnSym", "pcat");
    const note = p.text("lnNote");
    // Leads with the CONSEQUENCE, not the label. "Starting market cap" says
    // what the field is called; the share the first ether takes is what moving
    // it actually does, and at the old default of 3 that was a quarter of the
    // supply with nothing on screen hinting at it.
    assert.match(note, /1 ETH buys [\d.]+% of all/, "the depth consequence is not stated");
    assert.match(note, /opens at 1 ETH/, "no opening price shown");
    assert.doesNotMatch(note, /e-\d/, "an exponent is not a price anyone can read");
    assert.match(note, /PCAT/, "the symbol should be echoed, upper-cased");
    // And with no symbol yet it must not shout a placeholder back.
    p.type("lnSym", "");
    assert.match(p.text("lnNote"), /\btokens\b/, "a missing symbol reads as lowercase prose");
    p.close();
  });

  await t.test("warns when the market is thin enough for one buyer to take it", async () => {
    // Verified against the deployed launcher: out = pooled*in/(mcap+in), so a
    // 3 ETH open hands the first single ether ~25% of the supply. That is a
    // choice somebody may want, but almost never the one they meant.
    const p = await open_();
    p.type("lnSupply", "1000000000");
    p.type("lnMcap", "3");
    assert.match(p.text("lnNote"), /25% of all/, "the share must be stated outright");
    assert.equal(p.$("lnNote").style.color, "rgb(204, 51, 51)", "and flagged when extreme");
    p.type("lnMcap", "30");
    assert.match(p.text("lnNote"), /3.2% of all/);
    assert.equal(p.$("lnNote").style.color, "", "a sane depth is not an error");
    p.close();
  });

  await t.test("counts the first ether's share against ALL supply, as it says", async () => {
    // The pool receives `supply - allocation`, and `out = pooled*in/(mcap+in)`
    // is a share OF THAT. The sentence claims "of all", so a kept fifth used to
    // inflate the same 20% into a stated 25% - the page overstating the buyer's
    // side by exactly the amount the creator had removed from it.
    const p = await open_();
    p.type("lnSupply", "1000000000");
    p.type("lnMcap", "3");
    p.type("lnAlloc", "20");
    assert.match(p.text("lnNote"), /1 ETH buys 20% of all/,
      `25% of the pool is 20% of the supply, got ${p.text("lnNote")}`);
    // The flag is a claim about the POOL - and holding supply back makes a pool
    // easier to take, never harder - so it must survive the rescaling.
    assert.equal(p.$("lnNote").style.color, "rgb(204, 51, 51)",
      "an allocation must not quietly retire the thin-market warning");
    p.close();
  });

  await t.test("leaves the launch's own error standing while the creator is typed", async () => {
    // The creator box is the swap recipient box wearing a different label, and
    // its input handler used to run the swap quote regardless of mode: that
    // blanks `stat` on every keystroke, so the reason a launch had just been
    // refused vanished under the correction it was asking for.
    const p = await open_();
    p.type("lnName", "銀".repeat(40));
    p.type("lnSym", "ZCAT");
    p.click("lnGo");
    await p.settle();
    assert.match(p.text("stat"), /limit is 64/, "the refusal should be on screen");
    p.type("rc", "vitalik.eth");
    // The swap path is debounced by 250ms, so a check that does not outlast the
    // debounce passes even when the handler is wired straight through.
    await new Promise((r) => setTimeout(r, 320));
    await p.settle();
    assert.match(p.text("stat"), /limit is 64/,
      `typing a creator must not erase why the launch was refused, got ${p.text("stat")}`);
    assert.ok(!p.$("rc").classList.contains("bad"),
      "and the field must not be marked bad by the swap path's rules");
    p.close();
  });

  await t.test("discloses fully diluted only when an allocation makes it differ", async () => {
    const p = await open_();
    p.type("lnSupply", "1000000000");
    p.type("lnMcap", "3");
    assert.ok(!/creator keeps/.test(p.text("lnNote")), "no allocation, no second number");
    p.type("lnAlloc", "20");
    assert.match(p.text("lnNote"), /creator keeps/, "an allocation must be spelled out");
    p.close();
  });

  await t.test("encodes launch with the real ABI layout, not encStr's", async () => {
    const p = await open_();
    p.type("lnName", "Precision Cat");
    p.type("lnSym", "PCAT");
    p.type("lnSupply", "1000000000");
    p.type("lnMcap", "3");
    p.type("lnAlloc", "5");
    p.click("lnGo");
    await p.waitFor(() => p.chain.sent.length > 0, {label: "the launch call"});
    await p.settle();

    const tx = p.chain.sent[0];
    assert.equal(tx.to.toLowerCase(), PLAUNCH, "wrong launcher");
    assert.ok(tx.data.startsWith("0x" + SEL_LAUNCH), "wrong selector");
    assert.equal(BigInt(tx.value || 0), 0n, "a launch needs no ether");

    // Seven head words: three offsets then four statics.
    assert.equal(word(tx.data, 0), 224n, "name offset must clear the 7-word head");
    assert.equal(word(tx.data, 3), 10n ** 27n, "supply is 1e9 at 18 decimals");
    assert.equal(word(tx.data, 4), 500n, "5% is 500 bps");
    assert.equal(word(tx.data, 5), 3n * 10n ** 18n, "3 ETH valuation");
    assert.equal("0x" + head(tx.data, 6).slice(24), A.ACCOUNT.toLowerCase(), "owner is the caller");

    // And the strings really are where the offsets say they are.
    const nameAt = Number(word(tx.data, 0));
    assert.equal(BigInt("0x" + at(tx.data, nameAt).slice(0, 64)), 13n, '"Precision Cat" is 13 bytes');
    assert.equal(
      Buffer.from(at(tx.data, nameAt).slice(64, 64 + 26), "hex").toString(),
      "Precision Cat",
      "the name did not survive encoding"
    );
    const symAt = Number(word(tx.data, 1));
    assert.equal(BigInt("0x" + at(tx.data, symAt).slice(0, 64)), 4n, '"PCAT" is 4 bytes');
    p.close();
  });

  await t.test("carries the logo in the SAME transaction, not a second one", async () => {
    // The image lives on the token, and the token does not exist until the
    // launch runs - so `setImage` could not be called until the first
    // transaction had confirmed. That second prompt was declinable, which left
    // coins with no art and nothing on screen explaining why.
    const p = await open_();
    p.type("lnName", "Zero Cat");
    p.type("lnSym", "ZCAT");
    // Driven through the REAL file input, using an SVG - the one format whose
    // path needs no canvas, which jsdom does not implement. Assigning to
    // `window.lnArtBytes` looks equivalent and is not: a top-level `let` in a
    // classic script is not a property of `window`, so the page never saw it.
    const svg = '<svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>';
    const file = new p.window.File([svg], "logo.svg", {type: "image/svg+xml"});
    Object.defineProperty(p.$("lnArt"), "files", {value: [file], configurable: true});
    p.$("lnArt").dispatchEvent(new p.window.Event("change"));
    await p.waitFor(() => /KB/.test(p.text("lnArtNote")), {label: "the logo to encode"});
    p.click("lnGo");
    await p.waitFor(() => p.chain.sent.length > 0, {label: "launch"});
    await p.settle();

    assert.equal(p.chain.sent.length, 1, "a logo must not cost a second transaction");
    const tx = p.chain.sent[0];
    assert.ok(tx.data.startsWith("0x72cf7bd8"), "should call launchWithArt");
    assert.ok(!tx.data.includes("d4fb64a1"), "setImage must not be sent separately");
    // The bytes are really in there, at the offset the head points to.
    // The SVG bytes really are in the tail, at the offset the head points to.
    const hex = Buffer.from(svg.replace(/>\s+</g, "><"), "utf8").toString("hex");
    assert.ok(tx.data.includes(hex), "the art did not ride along");
    p.close();
  });

  await t.test("refuses what the launcher would refuse, but says which field", async () => {
    // Every guard in the launcher reverts with a bare `Bad()`. Catching these
    // here is the difference between a named field and "execution reverted".
    const p = await open_();
    const cases = [
      [{lnName: "", lnSym: "X"}, /name and a symbol/],
      [{lnName: "A", lnSym: ""}, /name and a symbol/],
      [{lnName: "A", lnSym: "X", lnSupply: "0"}, /positive number/],
      [{lnName: "A", lnSym: "X", lnSupply: "1000000000", lnAlloc: "25"}, /0 to 20/],
    ];
    for (const [fields, expected] of cases) {
      p.type("lnSupply", "1000000000");
      p.type("lnMcap", "3");
      p.type("lnAlloc", "0");
      for (const [id, v] of Object.entries(fields)) p.type(id, v);
      p.click("lnGo");
      await p.settle();
      assert.match(p.text("stat"), expected, `case ${JSON.stringify(fields)}`);
      assert.equal(p.chain.sent.length, 0, "nothing should have been sent");
    }
    p.close();
  });

  await t.test("catches too little pooled supply before the chain does", async () => {
    const p = await open_();
    p.type("lnName", "A");
    p.type("lnSym", "X");
    p.type("lnSupply", "0.000001"); // 1e12 raw, under MIN_POOLED of 2e12
    p.type("lnMcap", "3");
    p.click("lnGo");
    await p.settle();
    assert.match(p.text("stat"), /reaches the pool/, "should name the pool, not revert blankly");
    assert.equal(p.chain.sent.length, 0);
    p.close();
  });

  await t.test("cannot be double-submitted into two launches", async () => {
    // The guard used to be set AFTER `checkWallet` and the ENS lookup, both of
    // which await - so a second click while a wallet was prompting a network
    // switch sent a second launch. Two coins, two lots of gas, one status line.
    const p = await open_();
    p.type("lnName", "Zero Cat");
    p.type("lnSym", "ZCAT");
    p.click("lnGo");
    p.click("lnGo");
    p.click("lnGo");
    await p.waitFor(() => p.chain.sent.length > 0, {label: "launch"});
    await p.settle();
    assert.equal(p.chain.sent.length, 1, "one click, one coin");
    p.close();
  });

  await t.test("re-enables the button after a refusal, so it can be corrected", async () => {
    // The early returns and throws all pass through `finally`; if one did not,
    // a single mistyped field would leave the form permanently dead.
    const p = await open_();
    p.type("lnName", "");
    p.click("lnGo");
    await p.settle();
    assert.ok(!p.$("lnGo").disabled, "a rejected launch must leave the form usable");
    p.type("lnName", "Zero Cat");
    p.type("lnSym", "ZCAT");
    p.click("lnGo");
    await p.waitFor(() => p.chain.sent.length > 0, {label: "the corrected launch"});
    p.close();
  });

  await t.test("measures name and symbol in bytes, as the contract does", async () => {
    // `maxlength` counts UTF-16 units; `MAX_NAME`/`MAX_SYMBOL` count UTF-8
    // BYTES. Forty CJK characters sit well inside the input's own limit of 64
    // and are 120 bytes on chain, where the launcher answers with a bare
    // `Bad()`. The page has both numbers and can say which field and by how
    // much, so there is no reason to spend a transaction finding out.
    const p = await open_();
    p.type("lnName", "\u9280".repeat(40));
    p.type("lnSym", "ZCAT");
    p.click("lnGo");
    await p.settle();
    assert.match(p.text("stat"), /120 bytes.*limit is 64/,
      `the refusal should name the overage, got ${p.text("stat")}`);
    assert.equal(p.chain.sent.length, 0, "and nothing should have been sent");
    p.close();
  });

  await t.test("connects the wallet rather than scolding about it", async () => {
    // Launch used to answer a disconnected click with "Connect a wallet
    // first", which names the obstacle and then makes the user go find the
    // button themselves. The click already said what they wanted; the only
    // thing missing was the wallet, so ask for it.
    const p = await loadPage({chain: new MockChain()});
    p.click("ln");
    p.type("lnName", "A");
    p.type("lnSym", "X");
    p.click("lnGo");
    await p.waitFor(() => p.text("addr") !== "Not connected",
      {label: "the launch click to open the wallet"});
    assert.equal(p.chain.sent.length, 0,
      "connecting is not launching — nothing should be signed yet");
    p.close();
  });
});

/**
 * The receipt read.
 *
 * `launch` returns the token address, but a transaction does not hand its
 * return value back - so the page recovers the token from the `Launched` log
 * and uses it to add the coin and select the pair. Everything about that is
 * silent when it breaks: the launch still lands, the status line still says
 * the coin is live, and only the pair never switches. It shipped with a topic
 * hash for a five-argument event that has six, so the log was never found and
 * that whole path had never once run.
 *
 * Pinned against the SOURCE rather than a copied hash, because a copied hash
 * would drift the same way the first one did.
 */
test("the Launched topic tracks the contract", async () => {
  const [html, sol] = await Promise.all([
    readFile(new URL("../../zSwap.html", import.meta.url), "utf8"),
    readFile(new URL("../../src/pools/PrecisionLauncher.sol", import.meta.url), "utf8"),
  ]);

  const body = /event Launched\(([\s\S]*?)\);/.exec(sol);
  assert.ok(body, "PrecisionLauncher no longer declares a Launched event");
  const types = body[1]
    .split(",")
    .map((p) => p.trim().split(/\s+/)[0])
    .filter(Boolean);
  const sig = `Launched(${types.join(",")})`;

  const used = /kecStr\("(Launched\([^"]*\))"\)/.exec(html);
  assert.ok(used, "the page no longer derives the Launched topic");
  assert.equal(used[1], sig, "the page's Launched signature has drifted from the contract's");
});

/**
 * Recovering the token address.
 *
 * `launch` returns `(token, pool)`, but a transaction does not hand a return
 * value back, so the page recovers the address some other way in order to add
 * the coin and select the pair. It has two sources, both free, and they check
 * each other:
 *
 *   - The PREFLIGHT, which runs regardless and whose return value is the
 *     address the launch would produce at current state. A prediction: the
 *     token is a CREATE clone, so a launch landing first moves it.
 *   - The `Launched` LOG, which arrives inside the receipt the page fetches
 *     anyway to read `status`. Not a prediction - it is what happened.
 *
 * So the log wins wherever it is present, and the preflight matters only for
 * the wallet RPCs that return a receipt carrying no logs at all.
 */
test("finding the launched coin", async (t) => {
  const COIN = "0x" + "77".repeat(20);
  const OTHER = "0x" + "99".repeat(20);

  // The page adds the coin to its token list before selecting it, which means
  // reading `symbol`/`decimals` off it - so the fixture has to be a real token,
  // not just an address the launcher names.
  const withCoin = (chain, addr = COIN) =>
    chain.setToken(addr, {symbol: "ZCAT", decimals: 18, name: "Zero Cat"});

  const launch = async (p) => {
    p.type("lnName", "Zero Cat");
    p.type("lnSym", "ZCAT");
    p.click("lnGo");
    await p.waitFor(() => /is live/.test(p.text("stat")), {label: "the launch to settle"});
  };

  await t.test("reads it from the log, and selects the new pair", async () => {
    const chain = withCoin(new MockChain());
    chain.launchToken = COIN;
    const p = await open_({chain});
    await launch(p);
    assert.match(p.text("stat"), /ZCAT is live at/, "the coin should be named");
    const sel = p.$("toSel");
    assert.match(sel.options[sel.selectedIndex].textContent, /ZCAT/,
      "the launched coin should be selected as the output token");
    p.close();
  });

  await t.test("prefers the log over the preflight when they disagree", async () => {
    // The nonce race seen from the page: the preflight predicted one address
    // and a different one was really created. Only the log knows.
    const chain = withCoin(new MockChain());
    chain.launchToken = OTHER;
    chain.launchLogToken = COIN;
    const p = await open_({chain});
    await launch(p);
    assert.ok(p.text("stat").includes(COIN.slice(0, 6)),
      `the log's address should win, got ${p.text("stat")}`);
    p.close();
  });

  await t.test("falls back to the preflight when the receipt carries no logs", async () => {
    const chain = withCoin(new MockChain());
    chain.launchToken = COIN;
    chain.thinReceipts = true;
    const p = await open_({chain});
    await launch(p);
    assert.match(p.text("stat"), /ZCAT is live at/,
      "a receipt without logs should not lose the coin");
    p.close();
  });

  await t.test("refuses a predicted address that belongs to somebody else", async () => {
    // The nonce race with no log to correct it. `creatorOf` answering with
    // somebody else's creator is the only thing between the page and adopting
    // a stranger's coin as the user's own - `poolOf` would have confirmed it,
    // because under this race the predicted address IS a real launched token.
    const chain = withCoin(new MockChain());
    chain.launchToken = COIN;
    chain.thinReceipts = true;
    chain.creatorOfAnswer = "0x" + "ee".repeat(20);
    const p = await open_({chain});
    await launch(p);
    assert.equal(p.text("stat"), "ZCAT is live",
      "an unverifiable address must be dropped, not adopted");
    p.close();
  });
});
