import { create3Address, PROXY_HASH } from './create3-derive.mjs'
const deployer = process.argv[2].toLowerCase().replace(/^0x/, '')
const salt = deployer + '00' + '0102030405060708090a0b'
const r = create3Address(deployer, salt)
console.log('proxy initcode hash 0x' + PROXY_HASH)
console.log('salt        0x' + salt)
console.log('guardedSalt 0x' + r.guarded)
console.log('address     0x' + r.address)
