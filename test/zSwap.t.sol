// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";

contract zSwapDeployTest is Test {
    // keccak256 and length of zSwap.html. To recompute after editing the dapp:
    //   node -e "const e=require('ethers'),fs=require('fs');const h=fs.readFileSync('zSwap.html');console.log(e.keccak256(h),h.length)"
    bytes32 constant EXPECTED_HASH = 0x868f6b14c8080738ce6ca212f1dc3b4adb541dffb2d6a9557f3696448a5bfe65;
    uint256 constant EXPECTED_LEN = 126674;

    /// @dev Deploys `data` as a contract whose runtime bytecode IS that data,
    /// mirroring how the chunks are deployed on-chain (PUSH2 len, DUP1,
    /// PUSH1 0x0a, PUSH0, CODECOPY, PUSH0, RETURN | payload).
    function _writeChunk(bytes memory data) internal returns (address p) {
        bytes memory initcode = bytes.concat(hex"61", bytes2(uint16(data.length)), hex"80600a5f395ff3", data);
        assembly ("memory-safe") {
            p := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(p != address(0), "chunk deploy failed");
    }

    uint256 constant CHUNKS = 6;

    /// @dev Builds zSwap exactly as production does: split zSwap.html into
    /// CHUNKS parts, deploy each as its own data contract, pass them all in.
    function _deploy() internal returns (zSwap) {
        bytes memory html = vm.readFileBinary("zSwap.html");
        uint256 per = (html.length + CHUNKS - 1) / CHUNKS;
        address[CHUNKS] memory p;
        for (uint256 k; k < CHUNKS; ++k) {
            uint256 start = k * per;
            uint256 end = start + per > html.length ? html.length : start + per;
            bytes memory part = new bytes(end - start);
            for (uint256 i; i < end - start; ++i) {
                part[i] = html[start + i];
            }
            p[k] = _writeChunk(part);
        }
        return new zSwap(address(this), address(0), p[0], p[1], p[2], p[3], p[4], p[5]);
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return needle.length == 0;
        for (uint256 i; i <= haystack.length - needle.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }

    function test_HtmlPayloadRoundTrip() public {
        zSwap z = _deploy();
        bytes memory served = bytes(z.html());

        assertEq(served.length, EXPECTED_LEN, "html() length mismatch");
        assertEq(keccak256(served), EXPECTED_HASH, "html() content mismatch");

        // The data contract's runtime bytecode IS the HTML payload, byte-for-byte.
        // Each chunk's runtime bytecode is its slice of the page, and all of
        // them concatenated must reproduce it exactly.
        bytes memory c1 = z.DATA1().code;
        bytes memory c2 = z.DATA2().code;
        bytes memory c3 = z.DATA3().code;
        bytes memory c4 = z.DATA4().code;
        bytes memory c5 = z.DATA5().code;
        bytes memory c6 = z.DATA6().code;
        assertEq(
            c1.length + c2.length + c3.length + c4.length + c5.length + c6.length,
            EXPECTED_LEN,
            "chunk codesize mismatch"
        );
        assertEq(
            keccak256(bytes.concat(c1, c2, c3, c4, c5, c6)), EXPECTED_HASH, "chunk content mismatch"
        );
        assertTrue(
            c1.length <= 24576 && c2.length <= 24576 && c3.length <= 24576 && c4.length <= 24576
                && c5.length <= 24576 && c6.length <= 24576,
            "chunk over EIP-170"
        );
    }

    function test_NameAndVersion() public {
        zSwap z = _deploy();
        assertEq(z.NAME(), "zSwap");
        assertEq(z.VERSION(), "0.1");
    }

    function test_RejectsMissingOrDuplicatedChunks() public {
        address a = _writeChunk(bytes("a"));
        address b = _writeChunk(bytes("b"));

        address c = _writeChunk(bytes("c"));
        address d = _writeChunk(bytes("d"));
        address e = _writeChunk(bytes("e"));
        address f = _writeChunk(bytes("f"));

        // A zero address has no code, so EVERY position must reject it. Written as
        // a loop rather than one `new` per slot so a seventh chunk cannot be added
        // with its guard silently untested - the case this file exists to catch.
        for (uint256 i; i != CHUNKS; ++i) {
            address[CHUNKS] memory p = [a, b, c, d, e, f];
            p[i] = address(0);
            vm.expectRevert(zSwap.InvalidData.selector);
            new zSwap(address(this), address(0), p[0], p[1], p[2], p[3], p[4], p[5]);
        }

        // A duplicate would serve one slice twice and drop another entirely. Every
        // unordered pair, for the same reason.
        for (uint256 i; i != CHUNKS; ++i) {
            for (uint256 j = i + 1; j != CHUNKS; ++j) {
                address[CHUNKS] memory p = [a, b, c, d, e, f];
                p[j] = p[i];
                vm.expectRevert(zSwap.InvalidData.selector);
                new zSwap(address(this), address(0), p[0], p[1], p[2], p[3], p[4], p[5]);
            }
        }
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

    /// @dev The immutable frontend must keep querying every on-chain candidate
    ///      that its execution path can select: 1/2-hop, 3-hop, split, hybrid.
    ///      This is a wiring regression test; the corresponding fork tests
    ///      execute each generated calldata path against zRouter.
    function test_SwapFrontend_usesAllOnchainRouteBuilders() public {
        bytes memory html = vm.readFileBinary("zSwap.html");
        assertTrue(
            _contains(html, bytes("const ZQUOTER=\"0x0000002d9a651b729e3aFBE57Fc84FFDa4a98a13\"")),
            "wrong zQuoter deployment"
        );
        assertTrue(_contains(html, bytes("Q(\"e453166e\"")), "missing 1/2-hop builder");
        assertTrue(_contains(html, bytes("Q(\"4c464f59\"")), "missing 3-hop builder");
        assertTrue(_contains(html, bytes("\"892af013\",\"85f86a90\"")), "missing split/hybrid builders");
    }
}
