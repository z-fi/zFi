// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";

/// @dev A renderer with code that SUCCEEDS and returns nothing — the insidious
///      counterpart to one that reverts. `setRenderer` only checks code length.
contract SilentRenderer {
    fallback() external {}
}

contract FinalCheckTest is Test {
    TokenList list;
    address owner = address(0xA11CE);
    SilentRenderer silent;

    function setUp() public {
        vm.chainId(8453);
        list = new TokenList(owner, new TokenListRenderer());
        silent = new SilentRenderer();
    }

    /// @dev The hand-rolled `_hexColor` replaced `slice(toHexString(c,3),2)` to reclaim
    ///      644 B. Fuzzed against that exact reference across the full uint24 domain,
    ///      because it is hand-written nibble arithmetic on a value the card paints
    ///      with and `themeOf` publishes.
    function testFuzzHexColorMatchesTheLibraryItReplaced(uint24 color) public {
        vm.prank(owner);
        uint256 id = list.listForeign(TokenList.Kind.SVM, 0, bytes32(uint256(1)), "n", "s", 0, color, 1, "");
        (uint24 got, string memory hexColor) = list.themeOf(id);
        assertEq(got, color);
        assertEq(hexColor, string.concat("#", LibString.slice(LibString.toHexString(uint256(color), 3), 2)));
        assertEq(bytes(hexColor).length, 7);
    }

    /// @dev The assembly forwarder returns the callee's returndata verbatim, so a
    ///      renderer that succeeds with EMPTY returndata yields zero bytes rather than
    ///      an encoded empty string. That is the loud outcome, not the silent one:
    ///      every real consumer decodes, and a zero-byte payload fails to decode as a
    ///      string. Only a caller that discards the value sees nothing wrong — and the
    ///      compiler elides the decode entirely in that case, which is why this asserts
    ///      the raw returndata rather than a revert.
    ///
    ///      Reachable only by pointing `setRenderer` at a contract that lacks
    ///      `contractURI`; `setRenderer` checks for code, not for the interface. See
    ///      the replacement-renderer requirements in deploy/TokenList.md.
    function testContractUriOnSilentRendererYieldsUndecodableEmpty() public {
        vm.prank(owner);
        list.setRenderer(TokenListRenderer(address(silent)));
        (bool ok, bytes memory ret) = address(list).staticcall(abi.encodeWithSignature("contractURI()"));
        assertTrue(ok, "the raw call itself succeeds");
        assertEq(ret.length, 0, "zero bytes: no consumer can decode this as a string");
    }

    /// @dev The renderer is replaceable forever until `lockRenderer`. Prove the swap
    ///      actually re-points reads, and that locking is genuinely one-way.
    function testRendererIsReplaceableUntilLocked() public {
        TokenListRenderer fresh = new TokenListRenderer();
        vm.prank(owner);
        list.setRenderer(fresh);
        assertEq(address(list.renderer()), address(fresh));

        vm.prank(owner);
        list.lockRenderer();
        assertTrue(list.rendererLocked());
        TokenListRenderer another = new TokenListRenderer();
        vm.prank(owner);
        vm.expectRevert(TokenList.NotEditable.selector);
        list.setRenderer(another);
    }
}
