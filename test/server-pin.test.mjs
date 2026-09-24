import { test } from 'node:test';
import assert from 'node:assert/strict';
import dns from 'node:dns';
import pin, { privateIp } from '../server/pin.js';

const meta = url => pin.fetch(new Request('https://api.zfi.wei.is/proxy-metadata?url=' + encodeURIComponent(url), {
  headers: { origin: 'http://localhost:3000' },
}), {});

test('private and reserved addresses are recognised', () => {
  for (const ip of ['127.0.0.1', '10.1.2.3', '172.16.0.1', '192.168.1.1', '169.254.169.254', '100.64.0.1', '0.0.0.0', '::1', 'fd00::1', 'fe80::1', '::ffff:10.0.0.1'])
    assert.equal(privateIp(ip), true, ip);
  for (const ip of ['8.8.8.8', '1.1.1.1', '172.32.0.1', '2606:4700::1111'])
    assert.equal(privateIp(ip), false, ip);
});

test('a public-looking name that resolves to loopback is refused', async (t) => {
  const up = await dns.promises.lookup('127.0.0.1.nip.io').then(() => true, () => false);
  if (!up) return t.skip('no DNS here');
  const r = await meta('https://127.0.0.1.nip.io/x.json');
  assert.equal(r.status, 400);
  assert.match(await r.text(), /public host only/);
});
