// Mine a CreateX CREATE3 salt for a vanity address that is IDENTICAL on every chain.
//
//   node script/mine-create3.mjs <deployer> <prefix-hex> [workers] [label]
//
// `label` distinguishes independent searches. The walk is deterministic — same
// deployer and same start counter give the same salt — so mining twice for two
// contracts returns the SAME address unless the searches start somewhere
// different. Pass a different label per contract.
//
// CreateX lives at the same address with the same codehash on mainnet, Base and
// Robinhood Chain, and CREATE3 derives the address from (deployer, salt) alone —
// never from the initcode. So one salt gives one address that can hold different
// logic per chain, which is exactly what zQuoterBase and zQuoterRobinhood need.
//
// The salt layout is load-bearing: <deployer:20> <0x00> <random:11>.
//  - the 20-byte sender prefix makes the salt PERMISSIONED — only that deployer
//    can use it, so nobody can front-run the address on a chain you have not
//    reached yet;
//  - byte 20 MUST be 0x00. Setting it to 0x01 asks CreateX for redeploy
//    protection, which mixes block.chainid into the guarded salt and gives a
//    DIFFERENT address on every chain — the opposite of the goal.
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads'
import { cpus } from 'node:os'
import { create3Address } from './create3-derive.mjs'

const [deployerArg, prefixArg, workersArg, labelArg] = process.argv.slice(2)

if (isMainThread) {
  if (!deployerArg || !prefixArg) {
    console.error('usage: node script/mine-create3.mjs <deployer> <prefix-hex> [workers]')
    process.exit(1)
  }
  const deployer = deployerArg.toLowerCase().replace(/^0x/, '')
  const prefix = prefixArg.toLowerCase().replace(/^0x/, '')
  if (deployer.length !== 40) throw new Error('deployer must be 20 bytes')
  const n = Number(workersArg) || Math.max(1, cpus().length - 2)
  const expected = Math.pow(16, prefix.length)
  console.log(`mining ${prefix}... for deployer 0x${deployer} on ${n} workers`)
  console.log(`~${expected.toLocaleString()} attempts expected`)

  let total = 0
  let done = false
  for (let i = 0; i < n; i++) {
    const w = new Worker(new URL(import.meta.url), {
      workerData: { deployer, prefix, seed: i, label: labelArg || '' },
    })
    w.on('message', (m) => {
      if (m.tried) {
        total += m.tried
        if (!done) process.stdout.write(`\r  ${total.toLocaleString()} tried`)
        return
      }
      if (done) return
      done = true
      console.log(`\n\nFOUND after ~${total.toLocaleString()} attempts`)
      console.log(`  salt        0x${m.salt}`)
      console.log(`  guardedSalt 0x${m.guarded}`)
      console.log(`  address     0x${m.address}`)
      console.log(`\nVerify before using it:`)
      console.log(`  cast call 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed \\`)
      console.log(`    'computeCreate3Address(bytes32)(address)' 0x${m.guarded} -r <rpc>`)
      process.exit(0)
    })
  }
} else {
  const { deployer, prefix, seed, label } = workerData
  const buf = Buffer.alloc(11)
  buf.writeUInt8(seed, 0)
  // Offset the walk by the label so independent searches do not converge.
  let base = 0n
  for (const ch of label) base = base * 131n + BigInt(ch.charCodeAt(0))
  buf.writeUInt16BE(Number(base % 65536n), 1)
  let counter = 0n
  let tried = 0
  for (;;) {
    counter++
    buf.writeBigUInt64BE(counter, 3)
    const salt = deployer + '00' + buf.toString('hex')
    const r = create3Address(deployer, salt)
    if (r.address.startsWith(prefix)) {
      parentPort.postMessage({ salt, guarded: r.guarded, address: r.address })
      break
    }
    if (++tried % 20000 === 0) {
      parentPort.postMessage({ tried: 20000 })
    }
  }
}
