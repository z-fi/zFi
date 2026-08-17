/**
 * Turn a user's uploaded file into bytes small enough to live on-chain.
 *
 * The target is `LaunchToken.setImage(bytes,uint8)`, which stores the image as
 * CONTRACT CODE via SSTORE2 - 200 gas a byte, against 20,000 per 32-byte word
 * for storage. That is what makes an on-chain logo affordable at all, and it
 * also fixes the ceiling: EIP-170 caps a data contract at 24,575 bytes, so no
 * image can ever exceed that no matter how much anyone is willing to spend.
 *
 * FORMAT IS THE LEVER, NOT THE STORAGE. The obvious pipeline - draw to a canvas
 * and call `toBlob(..., 'image/png')` - is the wrong default for exactly the art
 * this is for. Browsers emit 24/32-bit PNG and do not palette-quantize, so a
 * flat cartoon mark that ought to be a 2 KB PNG-8 comes out 3-5x larger. Real
 * PNG-8 would mean shipping a median-cut quantizer and a PNG encoder in the
 * page. Lossless WebP gets the same result or better for free, and since the
 * output is a `data:` URI the mime is simply declared. So: WebP first, PNG kept
 * as the fallback for browsers that will not encode it.
 *
 * SVG IS PASSED THROUGH UNTOUCHED. Rasterising a vector mark to fit a byte
 * budget is destroying the smallest and sharpest version of the thing to make a
 * larger and blurrier one. A typical logo is 1-3 KB as SVG and looks correct at
 * every size.
 *
 * The encoders are injectable so the selection logic - which is where the bugs
 * would be - can be tested without a browser.
 */

/** Mime codes, matching `LaunchToken._mimeOf`. */
export const MIME = {png: 0, webp: 1, svg: 2, gif: 3, jpeg: 4, avif: 5};
export const MIME_NAME = ["image/png", "image/webp", "image/svg+xml", "image/gif", "image/jpeg", "image/avif"];

/** EIP-170 less the leading STOP byte SSTORE2 writes. A hard wall, not advice. */
export const MAX_BYTES = 24575;

/**
 * Default budget. Well under the wall on purpose: the ceiling is what the chain
 * permits, not what a logo should cost. At 30 gwei, 8 KB is ~0.05 ETH and
 * 24.5 KB is ~0.16 ETH, and the difference is invisible on a 128px avatar.
 */
export const DEFAULT_BUDGET = 8192;

/** Dimensions to try, largest first. */
const SIZES = [512, 384, 256, 192, 128, 96, 64];

/**
 * Gas to store `n` raw bytes through SSTORE2, and the ether that costs.
 *
 * Deliberately shown BEFORE signing rather than after: this is the one step of
 * a launch whose price the user controls, and the only way that control means
 * anything is if the number moves while they are choosing.
 */
export function storageGas(n) {
  // 200/byte code deposit + ~32k for the CREATE + 16/byte calldata + base tx.
  return n * 200 + 32000 + n * 16 + 21000;
}

export function storageCostWei(n, gasPriceWei) {
  return BigInt(storageGas(n)) * BigInt(gasPriceWei);
}

const isSvg = (file) => file.type === "image/svg+xml" || /\.svg$/i.test(file.name || "");

/**
 * Strip what an exporter leaves behind. Conservative on purpose - comments,
 * XML declarations and editor metadata only. Anything cleverer risks changing
 * how the mark renders, and the bytes saved are not worth a logo that shifts.
 */
function tidySvg(text) {
  return text
    .replace(/<\?xml[^>]*\?>/g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<!DOCTYPE[^>]*>/gi, "")
    .replace(/\s+xmlns:(inkscape|sodipodi|dc|cc|rdf|serif)="[^"]*"/g, "")
    .replace(/<(metadata|sodipodi:namedview)[\s\S]*?<\/\1>/g, "")
    .replace(/>\s+</g, "><")
    .trim();
}

/** The browser encoders, isolated so `prepareImage` can be tested without one. */
export const browserBackend = {
  async decode(file) {
    return await createImageBitmap(file);
  },
  async encode(bitmap, side, mime, quality) {
    const scale = Math.min(1, side / Math.max(bitmap.width, bitmap.height));
    const w = Math.max(1, Math.round(bitmap.width * scale));
    const h = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    ctx.imageSmoothingQuality = "high";
    ctx.drawImage(bitmap, 0, 0, w, h);
    const blob = await new Promise((res) => canvas.toBlob(res, mime, quality));
    // A browser that cannot encode the format hands back a PNG rather than
    // failing, so the TYPE has to be checked instead of trusted.
    if (!blob || blob.type !== mime) return null;
    return {bytes: new Uint8Array(await blob.arrayBuffer()), width: w, height: h};
  },
};

/**
 * @param {File} file
 * @param {{budget?: number, backend?: object}} [opts]
 * @returns {Promise<{bytes: Uint8Array, mime: number, mimeName: string,
 *   width?: number, height?: number, lossless: boolean, gas: number}>}
 */
export async function prepareImage(file, opts = {}) {
  const budget = Math.min(opts.budget ?? DEFAULT_BUDGET, MAX_BYTES);
  const backend = opts.backend ?? browserBackend;

  // Vectors: pass through, and refuse rather than rasterise if oversized. A
  // 30 KB SVG is a detailed illustration, and quietly turning it into a blurry
  // 128px bitmap is not what anyone uploading one asked for.
  if (isSvg(file)) {
    const bytes = new TextEncoder().encode(tidySvg(await file.text()));
    if (bytes.length > MAX_BYTES) {
      throw new Error(
        `This SVG is ${(bytes.length / 1024).toFixed(1)} KB and the on-chain limit is ` +
          `${(MAX_BYTES / 1024).toFixed(1)} KB. Simplify the artwork, or upload a PNG instead.`
      );
    }
    return {
      bytes,
      mime: MIME.svg,
      mimeName: MIME_NAME[MIME.svg],
      lossless: true,
      gas: storageGas(bytes.length),
    };
  }

  const bitmap = await backend.decode(file);

  // Lossless first, largest first, and take the first thing that fits. Trying
  // every combination and picking the global smallest would systematically
  // choose the tiniest, ugliest option - the budget is a ceiling to stay under,
  // not a target to approach.
  let best = null;
  for (const side of SIZES) {
    for (const [mime, name, quality, lossless] of [
      [MIME.webp, "image/webp", 1, true],
      [MIME.png, "image/png", undefined, true],
    ]) {
      const out = await backend.encode(bitmap, side, name, quality);
      if (!out) continue;
      if (!best || out.bytes.length < best.bytes.length) best = {...out, mime, lossless};
      if (out.bytes.length <= budget) {
        return {
          bytes: out.bytes,
          mime,
          mimeName: MIME_NAME[mime],
          width: out.width,
          height: out.height,
          lossless,
          gas: storageGas(out.bytes.length),
        };
      }
    }
  }

  // Nothing lossless fit. Photographs land here; flat marks essentially never
  // do. Lossy WebP is tried before giving up, because a photograph at quality
  // 0.8 is still a photograph, whereas a 64px lossless one is a smudge.
  for (const side of SIZES) {
    for (const q of [0.85, 0.7, 0.55]) {
      const out = await backend.encode(bitmap, side, "image/webp", q);
      if (!out) continue;
      if (out.bytes.length <= budget) {
        return {
          bytes: out.bytes,
          mime: MIME.webp,
          mimeName: MIME_NAME[MIME.webp],
          width: out.width,
          height: out.height,
          lossless: false,
          gas: storageGas(out.bytes.length),
        };
      }
      if (!best || out.bytes.length < best.bytes.length) best = {...out, mime: MIME.webp, lossless: false};
    }
  }

  throw new Error(
    `The smallest version of this image is ${(best ? best.bytes.length / 1024 : 0).toFixed(1)} KB, ` +
      `over the ${(budget / 1024).toFixed(1)} KB budget. Flat colours and simple shapes compress ` +
      `far better than photographs - or raise the budget if you are happy to pay for it.`
  );
}

/** `bytes` as the hex `setImage` expects. */
export function toHex(bytes) {
  let s = "0x";
  for (const b of bytes) s += b.toString(16).padStart(2, "0");
  return s;
}
