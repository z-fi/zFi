// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {TokenListPage} from "../src/utils/TokenListPage.sol";

/// @notice Proves the chunked page contract serves dapp/tokenlist/page.html
///         byte-for-byte, using the same split point as
///         script/build-tokenlist-chunks.mjs (ceil(len / 4)).
contract TokenListPageTest is Test {
    bytes internal page;
    TokenListPage internal p;

    address internal constant D1 = address(0xDA7A1);
    address internal constant D2 = address(0xDA7A2);
    address internal constant D3 = address(0xDA7A3);
    address internal constant D4 = address(0xDA7A4);

    uint256 internal constant EIP170 = 24576;

    function setUp() public {
        page = bytes(vm.readFile("dapp/tokenlist/page.html"));

        uint256 per = (page.length + 3) / 4; // ceil, matching the build script
        address[4] memory d = [D1, D2, D3, D4];
        uint256 off;
        for (uint256 i; i != 4; ++i) {
            uint256 n = page.length > off ? _min(per, page.length - off) : 0;
            // The data contracts' runtime bytecode IS the markup.
            vm.etch(d[i], _slice(page, off, n));
            off += n;
        }
        p = new TokenListPage(D1, D2, D3, D4);
    }

    function test_HtmlMatchesSourceExactly() public view {
        assertEq(p.html(), string(page));
    }

    function test_EachChunkFitsEip170() public view {
        assertLe(D1.code.length, EIP170);
        assertLe(D2.code.length, EIP170);
        assertLe(D3.code.length, EIP170);
        assertLe(D4.code.length, EIP170);
        assertEq(
            D1.code.length + D2.code.length + D3.code.length + D4.code.length, page.length
        );
    }

    /// @dev The wrapper's arity is permanent, so prove the room it buys is real.
    function test_HasHeadroomForFutureEdits() public view {
        // Deliberately generous: the arity is permanent, so this is the margin that
        // decides whether the page can ever be edited without moving addresses.
        assertGt(EIP170 * 4, page.length + 30_000);
    }

    function test_Request_ServesHtmlWithHeaders() public view {
        string[] memory resource = new string[](0);
        TokenListPage.KeyValue[] memory params = new TokenListPage.KeyValue[](0);
        (uint16 status, string memory body, TokenListPage.KeyValue[] memory headers) =
            p.request(resource, params);

        assertEq(status, 200);
        assertEq(body, string(page));
        assertEq(headers.length, 2);
        assertEq(headers[0].key, "Content-Type");
        assertEq(headers[0].value, "text/html");
        assertEq(headers[1].key, "Cache-Control");
    }

    function test_ResolveMode_Is5219() public view {
        assertEq(p.resolveMode(), bytes32("5219"));
    }

    /// @dev html() must not corrupt memory allocated after it: a bad free-memory
    ///      pointer bump would let the next allocation overwrite the page body.
    function test_HtmlLeavesFreeMemoryPointerSound() public view {
        string memory a = p.html();
        bytes memory scribble = new bytes(1024);
        for (uint256 i; i < scribble.length; ++i) scribble[i] = 0xff;
        assertEq(a, string(page));
    }

    function test_RevertsOnEmptyChunk() public {
        vm.expectRevert(TokenListPage.InvalidData.selector);
        new TokenListPage(address(0xBEEF), D2, D3, D4);
    }

    function test_RevertsOnDuplicateChunk() public {
        vm.expectRevert(TokenListPage.InvalidData.selector);
        new TokenListPage(D1, D1, D3, D4);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _slice(bytes memory b, uint256 start, uint256 len)
        internal
        pure
        returns (bytes memory out)
    {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) out[i] = b[start + i];
    }
}
