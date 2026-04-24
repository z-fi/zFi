#!/usr/bin/env node
// Builds the calldata needed to register zSwap.html with HTMLRegistry via
// zRouter.execute().
//
// Inner: HTMLRegistry.setHtmlAsTarget(zRouter, <zSwap.html>)
// Outer: zRouter.execute(HTMLRegistry, 0, <inner>)
//
// Prereq (already done by user): zRouter.trust(HTMLRegistry, true)
//
// After running:
//   script/zSwapRegistry-setHtmlAsTarget.calldata.txt  — pass this as `data` to zRouter.execute(...)
//   script/zSwapRegistry-execute.calldata.txt          — full calldata for zRouter (target=zRouter, value=0, data=<above>)
//
// Run: node script/build-zSwapRegistry-call.mjs

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Interface, getAddress } from 'ethers';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HTML_PATH = path.join(ROOT, 'zSwap.html');
const OUT_INNER = path.join(ROOT, 'script', 'zSwapRegistry-setHtmlAsTarget.calldata.txt');
const OUT_OUTER = path.join(ROOT, 'script', 'zSwapRegistry-execute.calldata.txt');

const ZROUTER      = getAddress('0x000000000000FB114709235f1ccBFfb925F600e4');
const HTMLREGISTRY = getAddress('0xFa11bacCdc38022dbf8795cC94333304C9f22722');

const htmlBuf = fs.readFileSync(HTML_PATH);
const html = htmlBuf.toString('utf8');
const htmlSha = crypto.createHash('sha256').update(htmlBuf).digest('hex');

const registryIface = new Interface([
  'function setHtmlAsTarget(address target, string htmlData)',
]);
const routerIface = new Interface([
  'function execute(address target, uint256 value, bytes data)',
]);

const innerCalldata = registryIface.encodeFunctionData('setHtmlAsTarget', [ZROUTER, html]);
const outerCalldata = routerIface.encodeFunctionData('execute', [HTMLREGISTRY, 0n, innerCalldata]);

fs.writeFileSync(OUT_INNER, innerCalldata + '\n');
fs.writeFileSync(OUT_OUTER, outerCalldata + '\n');

const innerBytes = (innerCalldata.length - 2) / 2;
const outerBytes = (outerCalldata.length - 2) / 2;

console.log('zSwap.html:            ', htmlBuf.length, 'B');
console.log('zSwap.html sha256:     ', htmlSha);
console.log('zRouter:               ', ZROUTER);
console.log('HTMLRegistry:          ', HTMLREGISTRY);
console.log('setHtmlAsTarget selector:', innerCalldata.slice(0, 10));
console.log('execute selector:      ', outerCalldata.slice(0, 10));
console.log('inner calldata bytes:  ', innerBytes);
console.log('outer calldata bytes:  ', outerBytes);
console.log('');
console.log('wrote:', path.relative(ROOT, OUT_INNER));
console.log('wrote:', path.relative(ROOT, OUT_OUTER));
