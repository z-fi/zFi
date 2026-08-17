import test from "node:test";
import assert from "node:assert/strict";
import {
  prepareImage,
  storageGas,
  storageCostWei,
  toHex,
  MIME,
  MAX_BYTES,
} from "../../dapp/modules/image-onchain.mjs";

/**
 * The selection logic, without a browser.
 *
 * `canvas.toBlob` cannot run in node, so the encoders are injected. That is not
 * a compromise - the encoders are the browser's job and are not this module's
 * to test. What IS this module's job is choosing among their outputs, and every
 * way that choice can go wrong is reachable from here: taking the smallest
 * instead of the largest that fits, rasterising a vector, silently accepting a
 * PNG when WebP was asked for, or letting anything past EIP-170.
 */

/** A backend whose byte count is a stated function of size and format. */
function fakeBackend(sizeFor) {
  const calls = [];
  return {
    calls,
    async decode() {
      return {width: 1024, height: 1024};
    },
    async encode(_bitmap, side, mime, quality) {
      calls.push({side, mime, quality});
      const n = sizeFor(side, mime, quality);
      if (n === null) return null;
      return {bytes: new Uint8Array(n), width: side, height: side};
    },
  };
}

const svgFile = (text) => ({
  type: "image/svg+xml",
  name: "logo.svg",
  text: async () => text,
});
const rasterFile = {type: "image/png", name: "art.png"};

test("on-chain image preparation", async (t) => {
  await t.test("passes an SVG through rather than rasterising it", async () => {
    // The smallest and sharpest version of a vector mark is the vector. Turning
    // it into a bitmap to hit a byte budget destroys the thing being uploaded.
    const r = await prepareImage(svgFile('<svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>'));
    assert.equal(r.mime, MIME.svg);
    assert.ok(r.lossless);
    assert.ok(new TextDecoder().decode(r.bytes).startsWith("<svg"));
  });

  await t.test("tidies exporter cruft out of an SVG", async () => {
    const messy =
      '<?xml version="1.0"?><!-- drawn in something --><svg xmlns="http://www.w3.org/2000/svg" ' +
      'xmlns:inkscape="http://x"><metadata><rdf/></metadata>  <circle r="4"/>  </svg>';
    const r = await prepareImage(svgFile(messy));
    const out = new TextDecoder().decode(r.bytes);
    assert.ok(!out.includes("<?xml"), "declaration");
    assert.ok(!out.includes("<!--"), "comment");
    assert.ok(!out.includes("metadata"), "editor metadata");
    assert.ok(!out.includes("inkscape"), "editor namespace");
    assert.ok(out.includes("<circle r=\"4\"/>"), "the artwork itself must survive");
  });

  await t.test("refuses an oversized SVG instead of quietly rasterising it", async () => {
    const huge = svgFile("<svg>" + "p".repeat(MAX_BYTES + 1000) + "</svg>");
    await assert.rejects(() => prepareImage(huge), /on-chain limit/);
  });

  await t.test("takes the LARGEST version that fits, not the smallest overall", async () => {
    // The budget is a ceiling to stay under, not a target to approach. A module
    // that minimised bytes would hand back a 64px smudge every time.
    const backend = fakeBackend((side) => side * 10);
    const r = await prepareImage(rasterFile, {budget: 4000, backend});
    assert.equal(r.width, 384, "512 was over budget, 384 fits, so 384 wins");
    assert.equal(r.bytes.length, 3840);
  });

  await t.test("prefers lossless WebP over PNG at the same size", async () => {
    // The reason this module exists: browsers do not palette-quantise PNG, so
    // flat cartoon art comes out several times larger than it should.
    const backend = fakeBackend((_side, mime) => (mime === "image/webp" ? 2000 : 9000));
    const r = await prepareImage(rasterFile, {budget: 4000, backend});
    assert.equal(r.mime, MIME.webp);
    assert.ok(r.lossless);
  });

  await t.test("falls back to PNG where WebP cannot be encoded", async () => {
    const backend = fakeBackend((side, mime) => (mime === "image/webp" ? null : side * 5));
    const r = await prepareImage(rasterFile, {budget: 3000, backend});
    assert.equal(r.mime, MIME.png);
    assert.ok(r.lossless);
  });

  await t.test("only goes lossy once nothing lossless fits", async () => {
    // A photograph at quality 0.85 is still a photograph; a 64px lossless one
    // is a smudge. But the trade is only worth making when forced.
    const backend = fakeBackend((side, mime, q) =>
      q === undefined || q === 1 ? 50000 : Math.round(side * 4 * q)
    );
    const r = await prepareImage(rasterFile, {budget: 2000, backend});
    assert.equal(r.lossless, false);
    assert.equal(r.mime, MIME.webp);
    assert.ok(r.bytes.length <= 2000);
    // And it tried every lossless option first.
    assert.ok(backend.calls.some((c) => c.mime === "image/png"), "PNG was never attempted");
  });

  await t.test("reports what it could not do rather than returning something broken", async () => {
    const backend = fakeBackend(() => 90000);
    await assert.rejects(() => prepareImage(rasterFile, {budget: 2000, backend}), /over the/);
  });

  await t.test("never returns more than EIP-170 allows, whatever the budget says", async () => {
    // The budget is advice; this is a wall. A caller passing a huge budget must
    // not be able to build a transaction that cannot possibly succeed.
    const backend = fakeBackend(() => MAX_BYTES + 1);
    await assert.rejects(() => prepareImage(rasterFile, {budget: 1e9, backend}));
  });

  await t.test("prices the write before it is signed", async () => {
    // 200 gas a byte for the code deposit is the claim the whole design rests
    // on; it is what makes an on-chain logo cost cents rather than an auction.
    assert.equal(storageGas(0), 53000);
    assert.equal(storageGas(1000), 269000);
    assert.ok(storageGas(3000) < 750000, "3 KB must stay well under a million gas");
    // A 3 KB mark at 0.1 gwei.
    assert.equal(storageCostWei(3000, 100000000n), 70100000000000n);
  });

  await t.test("hex-encodes for setImage", () => {
    assert.equal(toHex(new Uint8Array([0, 1, 255])), "0x0001ff");
    assert.equal(toHex(new Uint8Array()), "0x");
  });
});
