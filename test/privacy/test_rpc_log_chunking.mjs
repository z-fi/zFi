#!/usr/bin/env node
//
// RPC log chunking regression tests.
//
// Covers the retry + recursive block-range subdivision logic used by the
// Privacy Pools history loader in dapp/index.html.
//
// Usage: node test/privacy/test_rpc_log_chunking.mjs
//
import { strict as assert } from 'node:assert';

function ppSleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function ppIsTransientRpcError(err) {
  const msg = String(err?.message || err || '').toLowerCase();
  return (
    msg.includes('timeout') ||
    msg.includes('429') ||
    msg.includes('rate') ||
    msg.includes('network') ||
    msg.includes('socket') ||
    msg.includes('fetch') ||
    msg.includes('temporar') ||
    msg.includes('503') ||
    msg.includes('502') ||
    msg.includes('connection')
  );
}

async function ppProviderGetLogsWithRetry(provider, request, attempts = 3) {
  let lastErr;
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      if (provider) {
        return await provider.getLogs(request);
      }
      return await ppReadWithRpc(async (rpc) => rpc.getLogs(request));
    } catch (err) {
      lastErr = err;
      if (attempt >= attempts - 1 || !ppIsTransientRpcError(err)) throw err;
      await ppSleep(1);
    }
  }
  throw lastErr;
}

const PP_LOG_CHUNK_MAX_DEPTH = 12;

function ppIsRangeLimitedLogsError(err) {
  const msg = String(err?.message || err || '').toLowerCase();
  return (
    msg.includes('block range') ||
    msg.includes('maximum block range') ||
    msg.includes('max block range') ||
    msg.includes('query exceeds') ||
    msg.includes('exceeded max allowed range') ||
    msg.includes('too many results') ||
    /limited to 0\s*-\s*\d+\s*blocks range/.test(msg) ||
    /ranges? over \d+.*not supported/.test(msg)
  );
}

async function ppGetLogsChunked(provider, filter, fromBlock, toBlock, chunkSize = 1250000, depth = 0, maxDepth = PP_LOG_CHUNK_MAX_DEPTH) {
  try {
    return await ppProviderGetLogsWithRetry(provider, { ...filter, fromBlock, toBlock });
  } catch (e) {
    if (!ppIsRangeLimitedLogsError(e)) throw e;
    if (fromBlock >= toBlock) throw e;
    if (depth >= maxDepth) {
      throw new Error('RPC log range limit persisted after maximum subdivision: ' + String(e?.message || e || 'unknown error'));
    }
    const logs = [];
    const span = toBlock - fromBlock + 1;
    const nextChunkSize = Math.max(1, Math.floor(Math.min(chunkSize, span - 1) / 2));
    if (nextChunkSize >= span) throw e;
    for (let start = fromBlock; start <= toBlock; start += nextChunkSize) {
      const end = Math.min(start + nextChunkSize - 1, toBlock);
      logs.push(...await ppGetLogsChunked(provider, filter, start, end, nextChunkSize, depth + 1, maxDepth));
    }
    return logs;
  }
}

let quoteRPC = null;

async function ppReadWithRpc(work) {
  return await quoteRPC.call(async (rpc) => await work(rpc));
}

function makeQuoteRpc(providers) {
  const calls = [];
  return {
    calls,
    async call(fn) {
      let lastErr;
      for (const provider of providers) {
        calls.push(provider.name || 'provider');
        try {
          return await fn(provider);
        } catch (err) {
          lastErr = err;
        }
      }
      throw lastErr || new Error('All RPCs failed');
    },
  };
}

function makeRangeLimitedProvider({ maxRange, transientFailures = new Map(), nonRangeFailure = null }) {
  const calls = [];
  return {
    calls,
    async getLogs(request) {
      const fromBlock = Number(request.fromBlock);
      const toBlock = Number(request.toBlock);
      calls.push({ fromBlock, toBlock });

      if (nonRangeFailure) {
        throw new Error(nonRangeFailure);
      }

      const key = `${fromBlock}:${toBlock}`;
      const remainingTransient = transientFailures.get(key) || 0;
      if (remainingTransient > 0) {
        transientFailures.set(key, remainingTransient - 1);
        throw new Error('timeout while fetching logs');
      }

      const span = toBlock - fromBlock + 1;
      if (span > maxRange) {
        throw new Error(`exceed maximum block range: ${maxRange}`);
      }

      return [{ fromBlock, toBlock }];
    },
  };
}

function makeFallbackProvider(name, impl) {
  return {
    name,
    calls: [],
    async getLogs(request) {
      this.calls.push({ method: 'getLogs', request });
      return await impl.getLogs(request);
    },
    async getBalance(address) {
      this.calls.push({ method: 'getBalance', address });
      return await impl.getBalance(address);
    },
  };
}

let passed = 0;
let failed = 0;

async function test(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`  \x1b[32mPASS\x1b[0m ${name}`);
  } catch (e) {
    failed++;
    console.log(`  \x1b[31mFAIL\x1b[0m ${name}`);
    console.log(`       ${e.message}`);
  }
}

console.log('\n── RPC log chunking ──');

await test('ppReadWithRpc retries actual reads across fallback providers', async () => {
  const first = makeFallbackProvider('first', {
    async getLogs() { throw new Error('timeout while fetching logs'); },
    async getBalance() { throw new Error('timeout while fetching balance'); },
  });
  const second = makeFallbackProvider('second', {
    async getLogs() { return []; },
    async getBalance() { return 7n; },
  });
  quoteRPC = makeQuoteRpc([first, second]);

  const balance = await ppReadWithRpc(async (rpc) => await rpc.getBalance('0xabc'));
  assert.equal(balance, 7n);
  assert.equal(first.calls.length, 1);
  assert.equal(second.calls.length, 1);
});

await test('null-provider log reads fall back to the next RPC instead of pinning to the first', async () => {
  const first = makeFallbackProvider('first', {
    async getLogs() { throw new Error('exceed maximum block range: 50000'); },
    async getBalance() { return 0n; },
  });
  const second = makeFallbackProvider('second', {
    async getLogs(request) { return [{ fromBlock: Number(request.fromBlock), toBlock: Number(request.toBlock) }]; },
    async getBalance() { return 0n; },
  });
  quoteRPC = makeQuoteRpc([first, second]);

  const logs = await ppGetLogsChunked(null, { address: '0xpool' }, 100, 200);
  assert.equal(logs.length, 1);
  assert.equal(first.calls[0].method, 'getLogs');
  assert.equal(second.calls[0].method, 'getLogs');
});

await test('all-provider failures still fail closed with an explicit RPC error', async () => {
  const first = makeFallbackProvider('first', {
    async getLogs() { throw new Error('network unreachable'); },
    async getBalance() { throw new Error('network unreachable'); },
  });
  const second = makeFallbackProvider('second', {
    async getLogs() { throw new Error('network unreachable'); },
    async getBalance() { throw new Error('network unreachable'); },
  });
  quoteRPC = makeQuoteRpc([first, second]);

  await assert.rejects(
    () => ppReadWithRpc(async (rpc) => await rpc.getBalance('0xabc')),
    /network unreachable/
  );
});

await test('null-provider chunked reads also fail closed when every RPC fails', async () => {
  const first = makeFallbackProvider('first', {
    async getLogs() { throw new Error('network unreachable'); },
    async getBalance() { return 0n; },
  });
  const second = makeFallbackProvider('second', {
    async getLogs() { throw new Error('network unreachable'); },
    async getBalance() { return 0n; },
  });
  quoteRPC = makeQuoteRpc([first, second]);

  await assert.rejects(
    () => ppGetLogsChunked(null, { address: '0xpool' }, 100, 200),
    /network unreachable/
  );
});

await test('range-limited providers recurse below 50k caps', async () => {
  quoteRPC = null;
  const provider = makeRangeLimitedProvider({ maxRange: 50_000 });
  const logs = await ppGetLogsChunked(provider, { address: '0xpool' }, 22_153_714, 24_755_000);
  assert(logs.length > 1);
  assert(provider.calls.some(call => (call.toBlock - call.fromBlock + 1) <= 50_000));
});

await test('single recursive pass is enough for 100k caps', async () => {
  quoteRPC = null;
  const provider = makeRangeLimitedProvider({ maxRange: 100_000 });
  const logs = await ppGetLogsChunked(provider, { address: '0xpool' }, 22_153_714, 24_755_000);
  assert(logs.length > 1);
  assert(provider.calls.some(call => (call.toBlock - call.fromBlock + 1) <= 100_000));
});

await test('transient timeouts are retried before range subdivision', async () => {
  quoteRPC = null;
  const transientFailures = new Map([['100:1099', 1]]);
  const provider = makeRangeLimitedProvider({ maxRange: 10_000, transientFailures });
  const logs = await ppGetLogsChunked(provider, { address: '0xpool' }, 100, 1099);
  assert.equal(logs.length, 1);
  assert.equal(provider.calls.length, 2);
});

await test('transient retries still fail after the third timeout', async () => {
  quoteRPC = null;
  const transientFailures = new Map([['100:1099', 3]]);
  const provider = makeRangeLimitedProvider({ maxRange: 10_000, transientFailures });
  await assert.rejects(
    () => ppGetLogsChunked(provider, { address: '0xpool' }, 100, 1099),
    /timeout while fetching logs/
  );
  assert.equal(provider.calls.length, 3);
});

await test('non-range errors still fail closed', async () => {
  quoteRPC = null;
  const provider = makeRangeLimitedProvider({ maxRange: 50_000, nonRangeFailure: 'execution reverted' });
  await assert.rejects(
    () => ppGetLogsChunked(provider, { address: '0xpool' }, 1, 100),
    /execution reverted/
  );
});

await test('rate-limit errors are not misclassified as range limits', async () => {
  quoteRPC = null;
  const provider = makeRangeLimitedProvider({ maxRange: 50_000, nonRangeFailure: 'rate limit exceeded' });
  await assert.rejects(
    () => ppGetLogsChunked(provider, { address: '0xpool' }, 1, 100),
    /rate limit exceeded/
  );
  assert.equal(provider.calls.length, 3);
});

await test('single-block range-limit errors bubble when no smaller split exists', async () => {
  quoteRPC = null;
  const provider = makeRangeLimitedProvider({ maxRange: 0 });
  await assert.rejects(
    () => ppGetLogsChunked(provider, { address: '0xpool' }, 42, 42),
    /exceed maximum block range/
  );
});

await test('range-limited recursion stops at the maximum subdivision depth', async () => {
  quoteRPC = null;
  const provider = makeRangeLimitedProvider({ maxRange: 0 });
  await assert.rejects(
    () => ppGetLogsChunked(provider, { address: '0xpool' }, 1, 1_250_000, 1_250_000, 0, 2),
    /maximum subdivision/
  );
});

console.log('\n════════════════════════════════════════════════════════════');
if (failed === 0) {
  console.log(`\x1b[32m  All ${passed} tests passed.\x1b[0m`);
  process.exit(0);
} else {
  console.log(`\x1b[31m  ${failed} tests failed, ${passed} passed.\x1b[0m`);
  process.exit(1);
}
