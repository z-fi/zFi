// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";

contract zSwapDeployTest is Test {
    // keccak256 and length of zSwap.html. To recompute after editing the dapp:
    //   node -e "const e=require('ethers'),fs=require('fs');const h=fs.readFileSync('zSwap.html');console.log(e.keccak256(h),h.length)"
    bytes32 constant EXPECTED_HASH = 0x0cebca5a3920a7aac7aca78ae8a5de55602747d6da2affb07770fb79d2f7e832;
    uint256 constant EXPECTED_LEN = 49424;


    /// @dev Deploys `data` as a contract whose runtime bytecode IS that data,
    /// mirroring how the chunks are deployed on-chain (PUSH2 len, DUP1,
    /// PUSH1 0x0a, PUSH0, CODECOPY, PUSH0, RETURN | payload).
    function _writeChunk(bytes memory data) internal returns (address p) {
        bytes memory initcode =
            bytes.concat(hex"61", bytes2(uint16(data.length)), hex"80600a5f395ff3", data);
        assembly ("memory-safe") {
            p := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(p != address(0), "chunk deploy failed");
    }

    /// @dev Builds zSwap exactly as production does: split zSwap.html into
    /// three parts, deploy each as its own data contract, pass all three in.
    function _deploy() internal returns (zSwap) {
        bytes memory html = vm.readFileBinary("zSwap.html");
        uint256 per = (html.length + 2) / 3;
        address[3] memory p;
        for (uint256 k; k < 3; ++k) {
            uint256 start = k * per;
            uint256 end = start + per > html.length ? html.length : start + per;
            bytes memory part = new bytes(end - start);
            for (uint256 i; i < end - start; ++i) part[i] = html[start + i];
            p[k] = _writeChunk(part);
        }
        return new zSwap(p[0], p[1], p[2]);
    }

    function test_HtmlPayloadRoundTrip() public {
        zSwap z = _deploy();
        bytes memory served = bytes(z.html());

        assertEq(served.length, EXPECTED_LEN, "html() length mismatch");
        assertEq(keccak256(served), EXPECTED_HASH, "html() content mismatch");

        // The data contract's runtime bytecode IS the HTML payload, byte-for-byte.
        // Each chunk's runtime bytecode is its slice of the page, and the three
        // concatenated must reproduce it exactly.
        bytes memory c1 = z.DATA1().code;
        bytes memory c2 = z.DATA2().code;
        bytes memory c3 = z.DATA3().code;
        assertEq(c1.length + c2.length + c3.length, EXPECTED_LEN, "chunk codesize mismatch");
        assertEq(keccak256(bytes.concat(c1, c2, c3)), EXPECTED_HASH, "chunk content mismatch");
        assertTrue(c1.length <= 24576 && c2.length <= 24576 && c3.length <= 24576, "chunk over EIP-170");
    }

    function test_NameAndVersion() public {
        zSwap z = _deploy();
        assertEq(z.NAME(), "zSwap");
        assertEq(z.VERSION(), "0.2");
    }

    function test_RejectsMissingOrDuplicatedChunks() public {
        address a = _writeChunk(bytes("a"));
        address b = _writeChunk(bytes("b"));

        vm.expectRevert(zSwap.InvalidData.selector);
        new zSwap(address(0), a, b); // missing chunk

        vm.expectRevert(zSwap.InvalidData.selector);
        new zSwap(a, address(0), b);

        vm.expectRevert(zSwap.InvalidData.selector);
        new zSwap(a, b, address(0));

        vm.expectRevert(zSwap.InvalidData.selector);
        new zSwap(a, a, b); // duplicated chunk

        vm.expectRevert(zSwap.InvalidData.selector);
        new zSwap(a, b, b);
    }

    function test_ResolveMode_Is5219() public {
        zSwap z = _deploy();
        assertEq(z.resolveMode(), bytes32("5219"));
    }

    function test_Erc5219_Request() public {
        zSwap z = _deploy();
        string[] memory resource = new string[](0);
        zSwap.KeyValue[] memory params = new zSwap.KeyValue[](0);
        (uint16 status, string memory body, zSwap.KeyValue[] memory headers) = z.request(resource, params);

        assertEq(status, 200, "status");
        assertEq(bytes(body).length, EXPECTED_LEN, "body length");
        assertEq(keccak256(bytes(body)), EXPECTED_HASH, "body content");
        assertEq(headers.length, 2, "header count");
        assertEq(headers[0].key, "Content-Type");
        assertEq(headers[0].value, "text/html");
        assertEq(headers[1].key, "Cache-Control");
        assertEq(headers[1].value, "public, max-age=31536000, immutable");
    }

    /// @dev Sanity-check that path/query are ignored — same response for any input.
    function test_Erc5219_IgnoresPathAndParams() public {
        zSwap z = _deploy();

        string[] memory r1 = new string[](2);
        r1[0] = "foo";
        r1[1] = "bar";
        zSwap.KeyValue[] memory p1 = new zSwap.KeyValue[](1);
        p1[0] = zSwap.KeyValue("k", "v");

        (uint16 s1, string memory b1, zSwap.KeyValue[] memory h1) = z.request(r1, p1);
        (uint16 s2, string memory b2, zSwap.KeyValue[] memory h2) = z.request(new string[](0), new zSwap.KeyValue[](0));

        assertEq(s1, s2);
        assertEq(keccak256(bytes(b1)), keccak256(bytes(b2)));
        assertEq(h1.length, h2.length);
    }
}
