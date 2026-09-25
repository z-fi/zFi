/**
 * The private bridge keeps its note, lock, send and inbox lists sealed under
 * the Tacit key: "z1." + iv16 ‖ ciphertext (hex) + "." + tag (hex), where the
 * ciphertext is the JSON XORed with sha256(kEnc ‖ iv ‖ be32(block)) and the tag
 * is HMAC-SHA256(kMac, iv ‖ ciphertext), all keys HMAC-SHA256(key, label). The iv is
 * HMAC-SHA256(kIv, JSON) cut to 16 bytes, so sealing draws no randomness.
 * This opens one independently of the page, so a test that reads storage checks
 * the format as well as the contents. A list an older build left in plain JSON
 * reads as it is.
 */
import { createHash, createHmac } from 'node:crypto';

const hex = h => Buffer.from(String(h).replace(/^0x/, '').padStart(64, '0'), 'hex');

export function openStore(raw, seed) {
  if (!/^z1\./.test(raw || '')) return JSON.parse(raw || '[]');
  const [, body, tag] = raw.split('.');
  const x = Buffer.from(body, 'hex'), iv = x.subarray(0, 16), c = x.subarray(16);
  const key = label => createHmac('sha256', hex(seed)).update('zswap-store-' + label + '-v1').digest();
  if (createHmac('sha256', key('mac')).update(Buffer.concat([iv, c])).digest('hex') !== tag) throw Error('the sealed list does not authenticate');
  const ke = key('enc'), out = Buffer.alloc(c.length), n = Buffer.alloc(4);
  for (let i = 0; i < c.length; i += 32) {
    n.writeUInt32BE(i / 32);
    const z = createHash('sha256').update(Buffer.concat([ke, iv, n])).digest();
    for (let t = 0; t < 32 && i + t < c.length; t++) out[i + t] = c[i + t] ^ z[t];
  }
  return JSON.parse(out.toString('utf8'));
}
