// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";

contract zSwapDeployTest is Test {
    // keccak256 and length of zSwap.html. To recompute after editing the dapp:
    //   node -e "const e=require('ethers'),fs=require('fs');const h=fs.readFileSync('zSwap.html');console.log(e.keccak256(h),h.length)"
    bytes32 constant EXPECTED_HASH = 0x3079211498c4cc2d261f08f1e00b024310ff5cf494be73da1522b6a1655580fb;
    uint256 constant EXPECTED_LEN = 24547;

    function test_HtmlPayloadRoundTrip() public {
        zSwap z = new zSwap();
        bytes memory served = bytes(z.html());

        assertEq(served.length, EXPECTED_LEN, "html() length mismatch");
        assertEq(keccak256(served), EXPECTED_HASH, "html() content mismatch");

        // The data contract's runtime bytecode IS the HTML payload, byte-for-byte.
        address d = z.DATA();
        assertEq(d.code.length, EXPECTED_LEN, "DATA codesize mismatch");
        assertEq(keccak256(d.code), EXPECTED_HASH, "DATA code mismatch");
    }

    function test_NameAndVersion() public {
        zSwap z = new zSwap();
        assertEq(z.NAME(), "zSwap");
        assertEq(z.VERSION(), "0.2");
    }

    function test_ResolveMode_Is5219() public {
        zSwap z = new zSwap();
        assertEq(z.resolveMode(), bytes32("5219"));
    }

    function test_Erc5219_Request() public {
        zSwap z = new zSwap();
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
        zSwap z = new zSwap();

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
