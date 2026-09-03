import { ethers } from 'ethers'
const k = (h) => ethers.keccak256('0x' + h).slice(2)
export const CREATEX = 'ba5ed099633d3b313e4d5f7bdc1305d3c28ba5ed'
export const PROXY_HASH = k('67363d3d37363d34f03d5260086018f3')

/// CreateX guards the salt. sender-prefixed + byte20 == 0x00 is the only mode that
/// is BOTH permissioned to one deployer AND free of block.chainid, which is what
/// lets the same address exist on every chain.
export function guardedSalt(deployer, salt) {
  return k(deployer.padStart(64, '0') + salt)
}
export function create3Address(deployer, salt) {
  const g = guardedSalt(deployer, salt)
  const proxy = k('ff' + CREATEX + g + PROXY_HASH).slice(24)
  return { guarded: g, proxy, address: k('d694' + proxy + '01').slice(24) }
}
