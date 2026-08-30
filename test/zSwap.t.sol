// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";

contract zSwapDeployTest is Test {
    // keccak256 and length of zSwap.html. To recompute after editing the dapp:
    //   node -e "const e=require('ethers'),fs=require('fs');const h=fs.readFileSync('zSwap.html');console.log(e.keccak256(h),h.length)"
    bytes32 constant EXPECTED_HASH = 0x585543386f78918fb45298107f3c50c3f3251539ef9dc6b743f3f9fe24425622;
    uint256 constant EXPECTED_LEN = 372985;

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

    uint256 constant CHUNKS = 16;

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
        return _new(p);
    }

    /// @dev The constructor takes CHUNKS positional addresses; every call site
    /// spelling them out is CHUNKS edits per new slot, and one missed slot is a
    /// test that passes while checking the wrong arity.
    function _new(address[CHUNKS] memory p) internal returns (zSwap) {
        return new zSwap(address(this), address(0), p);
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
        //
        // Walked rather than named one variable per chunk: the unrolled form had
        // to be edited in four places to add a chunk, and a slot left out of the
        // concat is a page that serves correctly here while the DEPLOYED one
        // drops a slice. The loop covers whatever the arity is.
        address[CHUNKS] memory d = [
            z.DATA1(), z.DATA2(), z.DATA3(), z.DATA4(), z.DATA5(), z.DATA6(),
            z.DATA7(), z.DATA8(), z.DATA9(), z.DATA10(), z.DATA11(), z.DATA12(),
            z.DATA13(),
            z.DATA14(), z.DATA15(), z.DATA16()
        ];
        bytes memory all;
        for (uint256 i; i != CHUNKS; ++i) {
            bytes memory c = d[i].code;
            assertGt(c.length, 0, "empty chunk");
            assertLe(c.length, 24576, "chunk over EIP-170");
            all = bytes.concat(all, c);
        }
        assertEq(all.length, EXPECTED_LEN, "chunk codesize mismatch");
        assertEq(keccak256(all), EXPECTED_HASH, "chunk content mismatch");
    }

    function test_NameAndVersion() public {
        zSwap z = _deploy();
        assertEq(z.NAME(), "zSwap");
        assertEq(z.VERSION(), "0.3");
    }

    function test_RejectsMissingOrDuplicatedChunks() public {
        // One distinct chunk per slot, built rather than named: at eight the
        // hand-written a..h list was already the thing that had to be extended
        // in three places to add a slot, which is exactly the edit this test
        // exists to make unnecessary.
        address[CHUNKS] memory ok;
        for (uint256 k; k != CHUNKS; ++k) {
            ok[k] = _writeChunk(bytes(abi.encodePacked(bytes1(uint8(65 + k)))));
        }

        // A zero address has no code, so EVERY position must reject it. Written as
        // a loop rather than one `new` per slot so a new chunk cannot be added
        // with its guard silently untested - the case this file exists to catch,
        // and the reason going from eight to fourteen needed nothing here but
        // the count.
        for (uint256 i; i != CHUNKS; ++i) {
            address[CHUNKS] memory p = ok;
            p[i] = address(0);
            vm.expectRevert(zSwap.InvalidData.selector);
            _new(p);
        }

        // A duplicate would serve one slice twice and drop another entirely. Every
        // unordered pair, for the same reason.
        for (uint256 i; i != CHUNKS; ++i) {
            for (uint256 j = i + 1; j != CHUNKS; ++j) {
                address[CHUNKS] memory p = ok;
                p[j] = p[i];
                vm.expectRevert(zSwap.InvalidData.selector);
                _new(p);
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
        // Moved off 0x0000002d9a651b729e3aFBE57Fc84FFDa4a98a13, which let Curve
        // win an exact-out quote it cannot serve - `exchange` is exact-in only
        // and `get_dx` is not a tight inverse of `get_dy`, so the swap lands
        // under the target and the router refuses to under-deliver. The
        // replacement declines Curve on exact-out and is otherwise identical:
        // compared across 30 ordered pairs in both directions before switching,
        // same best-source and same amounts on every one.
        assertTrue(
            _contains(html, bytes("const ZQUOTER=\"0xc7a03f9ed2be5feea18ce93e12f4f05c98287c16\"")),
            "wrong zQuoter deployment"
        );
        assertTrue(_contains(html, bytes("Q(\"e453166e\"")), "missing 1/2-hop builder");
        assertTrue(_contains(html, bytes("Q(\"4c464f59\"")), "missing 3-hop builder");
        assertTrue(_contains(html, bytes("\"892af013\",\"85f86a90\"")), "missing split/hybrid builders");
    }
}
