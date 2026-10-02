// Writes to a list that zSteward owns go through zSteward: a call that only
// removes an entry, disables a solver or switches a lane off goes through
// narrow() and applies at once; anything else is queued for zSteward's delay
// and landed later from steward-queue.html. Lists zSteward does not own are
// written directly, exactly as before.
(() => {
  const STW = '0x0000005F38594Af514e65e7d1e4EddE773bcF886';
  const RPC = 'https://ethereum-rpc.publicnode.com';
  const hex = n => BigInt(n).toString(16).padStart(64, '0');
  const strip = h => (h || '').replace(/^0x/, '');
  const bytesArg = d => { const h = strip(d); return hex(h.length / 2) + h.padEnd(Math.ceil(h.length / 64) * 64, '0'); };
  const read = async data => {
    const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to: STW, data }, 'latest'] }) });
    const j = await r.json();
    if (j.error) throw Error(j.error.message || 'zSteward read failed');
    return j.result;
  };
  const same = (a, b) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
  const held = owner => same(owner, STW);
  let stewardJob = null;
  /** zSteward's steward, the account that queues; null if it cannot be read. */
  const steward = () => stewardJob || (stewardJob = read('0x637eea19')
    .then(r => '0x' + strip(r).slice(24))
    .catch(() => { stewardJob = null; return null; }));
  /** Whether `account` may write to a list owned by `owner`. */
  const may = async (account, owner) => same(account, owner) || (held(owner) && same(account, await steward()));
  /** The transaction to send for `data` to list `to` owned by `owner`, and a line saying what will happen. */
  async function route(to, data, owner) {
    if (!held(owner) || strip(data).slice(0, 8) === '79ba5097') return { to, data, note: '' };
    const fast = BigInt(await read('0xae1f986e' + hex(32) + bytesArg(data))) === 1n;
    const delay = Number(BigInt(await read('0x69b41170')));
    return {
      to: STW,
      data: '0x' + (fast ? '431e2b22' : 'e3d20e6d') + strip(to).toLowerCase().padStart(64, '0') + hex(64) + bytesArg(data),
      note: fast ? 'Applied at once through zSteward (a removal).'
        : 'Queued in zSteward. It can land ' + (delay / 3600).toFixed(0) + ' h after this transaction, from steward-queue.html, and not before.',
    };
  }
  window.zSteward = { STW, held, steward, may, route };
})();
