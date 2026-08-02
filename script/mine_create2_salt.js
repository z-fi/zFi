#!/usr/bin/env node
// Mine a CREATE2 salt that produces a leading-N-zero-byte contract address.
// Uses the standard CREATE2 formula locally (no RPC required):
//   addr = keccak256(0xff || factory || salt || keccak256(initcode))[12:]
//
// Parallelized across CPU cores via worker_threads. Each worker iterates over
// a disjoint stride of salts. Uses the native `keccak` npm package for ~5×
// throughput vs. ethers' JS keccak256.
//
// Usage:
//   node script/mine_create2_salt.js [leading_zero_bytes=2] [max_iter=1e10] [bytecode_file] [start_salt=0]

const { Worker, isMainThread, parentPort, workerData } = require("node:worker_threads");
const fs = require("fs");
const path = require("path");
const os = require("os");
const createKeccakHash = require("keccak");
const { getCreate2Address } = require("ethers");

const FACTORY = "0x00000000004473e1f31C8266612e7FD5504e6f2a";

// Precompute factory bytes once for keccak use.
const factoryBuf = Buffer.from(FACTORY.slice(2).toLowerCase(), "hex");

function keccak256Buf(buf) {
  return createKeccakHash("keccak256").update(buf).digest();
}

if (isMainThread) {
  const leadingZeroBytes = parseInt(process.argv[2] || "2", 10);
  const maxIter = parseInt(process.argv[3] || "10000000000", 10);
  const startSalt = BigInt(process.argv[5] || "0");
  const bytecodeFile = process.argv[4]
    ? path.resolve(process.argv[4])
    : path.join(__dirname, "..", "out", "zQuoter.creation.txt");

  const creation = fs.readFileSync(bytecodeFile, "utf8").trim();
  if (!creation.startsWith("0x")) throw new Error("bytecode file must start with 0x");
  const initCodeHashBuf = keccak256Buf(Buffer.from(creation.slice(2), "hex"));
  const initCodeHash = "0x" + initCodeHashBuf.toString("hex");

  const numWorkers = os.cpus().length;
  const perWorker = Math.ceil(maxIter / numWorkers);

  console.log("factory       :", FACTORY);
  console.log("bytecode file :", path.relative(process.cwd(), bytecodeFile));
  console.log("bytecode bytes:", (creation.length - 2) / 2);
  console.log("initCodeHash  :", initCodeHash);
  console.log("target prefix :", "0x" + "00".repeat(leadingZeroBytes), `(${leadingZeroBytes} leading zero bytes)`);
  console.log("max iter      :", maxIter.toLocaleString());
  console.log("start salt    :", startSalt.toLocaleString());
  console.log("workers       :", numWorkers, `(${perWorker.toLocaleString()} iters each)`);
  console.log("");

  let globalBest = 0;
  let totalIters = 0;
  let found = false;
  let workersDone = 0;
  const start = Date.now();

  const workers = [];
  for (let i = 0; i < numWorkers; i++) {
    const w = new Worker(__filename, {
      workerData: {
        initCodeHashHex: initCodeHash,
        startSaltHex: "0x" + startSalt.toString(16),
        startOffset: i,
        stride: numWorkers,
        maxIterPerWorker: perWorker,
      },
    });
    workers.push(w);

    w.on("message", (msg) => {
      if (msg.type === "progress") {
        totalIters += msg.iters;
      } else if (msg.type === "improvement") {
        if (msg.zeros > globalBest) {
          globalBest = msg.zeros;
          const elapsed = (Date.now() - start) / 1000;
          console.log(
            `[${elapsed.toFixed(1).padStart(7)}s | ${(totalIters / 1e6).toFixed(0)}M iters] ` +
            `${msg.zeros} leading zeros: ${msg.address}  salt=${msg.salt}`
          );
          if (msg.zeros >= leadingZeroBytes) {
            found = true;
            const expected = getCreate2Address(FACTORY, msg.salt, initCodeHash);
            console.log("");
            console.log("FOUND:");
            console.log("  salt    :", msg.salt);
            console.log("  address :", msg.address);
            console.log("  verified:", expected.toLowerCase() === msg.address ? "yes" : "NO — ethers mismatch");
            console.log("  elapsed :", elapsed.toFixed(2) + "s");
            console.log("  iters   :", totalIters.toLocaleString(), "(across all workers)");
            // Exit straight away rather than terminate()-ing the workers first.
            // Tearing down a worker mid-hash aborts inside the native keccak
            // addon, which printed a FATAL ERROR *after* the result and made a
            // successful mine look like a crash. process.exit takes the threads
            // with it.
            process.exit(0);
          }
        }
      } else if (msg.type === "done") {
        workersDone++;
        if (workersDone === numWorkers && !found) {
          console.log("no match found within", maxIter.toLocaleString(), "iterations");
          process.exit(1);
        }
      }
    });

    w.on("error", (err) => {
      console.error("worker failed:", err.message);
      process.exit(2);
    });
  }

  // Periodic throughput report
  setInterval(() => {
    if (found) return;
    const elapsed = (Date.now() - start) / 1000;
    const rate = totalIters / elapsed;
    console.log(
      `[${elapsed.toFixed(0).padStart(7)}s] best=${globalBest}, ` +
      `total=${(totalIters / 1e6).toFixed(0)}M iters, ` +
      `rate=${(rate / 1e6).toFixed(2)}M iter/sec`
    );
  }, 30000).unref();
} else {
  const { initCodeHashHex, startSaltHex, startOffset, stride, maxIterPerWorker } = workerData;

  // 85-byte CREATE2 preimage: 0xff || factory(20) || salt(32) || initCodeHash(32)
  const buf = Buffer.alloc(85);
  buf[0] = 0xff;
  buf.set(factoryBuf, 1);
  buf.set(Buffer.from(initCodeHashHex.slice(2), "hex"), 53);

  // Salt slot is bytes 21..52 (32 bytes). We keep high 24 bytes = 0 always,
  // and iterate the low 8 bytes as a 64-bit counter. High 24 bytes are already
  // zero from Buffer.alloc, so no need to re-zero each iteration.

  let workerBest = 0;
  let sinceReport = 0;
  const REPORT_EVERY = 500000;

  // ONE hasher for the whole run, driven through its low-level state.
  //
  // This loop used to call `createKeccakHash("keccak256")` per iteration, which
  // allocates a native Keccak object every time. The native handles are only
  // released when the JS wrapper is collected, so at mining scale the workers
  // accumulate them faster than GC reclaims them: throughput decayed from
  // 0.13M to 0.02M iter/sec over three minutes and the process eventually died
  // (exit 144) partway through a run — which reads exactly like "mining is just
  // slow" rather than like a leak, and is why a 3-byte prefix that should take
  // seconds appeared to need many minutes and then failed.
  //
  // `digest()` already calls `_resetState()` on the way out, so the only thing
  // preventing reuse is the `_finalized` guard. Going straight to the state
  // object skips that bookkeeping entirely and is ~2x faster again. Verified to
  // produce byte-identical digests to the per-call form.
  const hasher = createKeccakHash("keccak256");
  const keccakState = hasher._state;
  const keccakRate = hasher._rate;
  const keccakCapacity = hasher._capacity;
  // keccak256 has no delimited suffix (that is what distinguishes it from
  // SHA3-256), so absorb-then-squeeze is the complete operation.

  // 64-bit salt counter as two 32-bit halves (stays within Number safe range).
  const firstSalt = BigInt(startSaltHex) + BigInt(startOffset);
  let saltLo = Number(firstSalt & 0xffffffffn) >>> 0;
  let saltHi = Number((firstSalt >> 32n) & 0xffffffffn) >>> 0;

  for (let i = 0; i < maxIterPerWorker; i++) {
    // Write salt low 8 bytes (bytes 45..52) as big-endian.
    // saltHi goes into bytes 45..48, saltLo into bytes 49..52.
    buf[45] = (saltHi >>> 24) & 0xff;
    buf[46] = (saltHi >>> 16) & 0xff;
    buf[47] = (saltHi >>> 8) & 0xff;
    buf[48] = saltHi & 0xff;
    buf[49] = (saltLo >>> 24) & 0xff;
    buf[50] = (saltLo >>> 16) & 0xff;
    buf[51] = (saltLo >>> 8) & 0xff;
    buf[52] = saltLo & 0xff;

    // Native keccak256, reusing the state above rather than allocating.
    keccakState.initialize(keccakRate, keccakCapacity);
    keccakState.absorb(buf);
    const hash = keccakState.squeeze(32);

    // Count leading zero bytes in address (hash[12..32])
    let zeros = 0;
    if (hash[12] === 0) {
      zeros = 1;
      if (hash[13] === 0) {
        zeros = 2;
        if (hash[14] === 0) {
          zeros = 3;
          if (hash[15] === 0) {
            zeros = 4;
            if (hash[16] === 0) {
              zeros = 5;
              for (let k = 17; k < 32 && hash[k] === 0; k++) zeros++;
            }
          }
        }
      }
    }

    if (zeros > workerBest) {
      workerBest = zeros;
      const addrHex = "0x" + hash.slice(12).toString("hex");
      const saltHex = "0x" + buf.slice(21, 53).toString("hex");
      parentPort.postMessage({ type: "improvement", zeros, address: addrHex, salt: saltHex });
    }

    sinceReport++;
    if (sinceReport >= REPORT_EVERY) {
      parentPort.postMessage({ type: "progress", iters: sinceReport });
      sinceReport = 0;
    }

    // Increment salt by stride using 64-bit arithmetic in two 32-bit halves.
    const newLo = saltLo + stride;
    if (newLo >= 0x100000000) {
      saltLo = newLo - 0x100000000;
      saltHi = (saltHi + 1) >>> 0;
    } else {
      saltLo = newLo;
    }
  }

  if (sinceReport > 0) {
    parentPort.postMessage({ type: "progress", iters: sinceReport });
  }
  parentPort.postMessage({ type: "done" });
  parentPort.close();
}
