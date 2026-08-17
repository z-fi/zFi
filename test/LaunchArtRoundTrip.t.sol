// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {PrecisionLauncher, LaunchToken} from "../src/pools/PrecisionLauncher.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";

/// @notice The whole art path, end to end: a REAL PNG goes in through `launch`,
///         and the exact same bytes come back out of `contractURI()`.
///
///         Everything before this tested one half. The contract stores what it
///         is given and assembles a document; the page encodes calldata and
///         decodes a document. Both halves passing says nothing about whether
///         the bytes survive the trip - a wrong base64 alphabet, a stray pad
///         byte, or a JSON escape landing inside the payload would break the
///         image while leaving every existing assertion green.
contract LaunchArtRoundTripTest is Test {
    address constant FACTORY = 0x000000Eb27B557aB426d9E99cFd54EC455799e81;
    address constant TREASURY = 0x000000aA142133107c7D2664F900f80e28BbfFbd;

    PrecisionLauncher L;
    address creator = address(0xC0FFEE);

    /// A real 1x1 PNG - header, IHDR, IDAT, IEND. Not a placeholder blob: the
    /// point is that something a browser would actually render survives.
    bytes constant PNG =
        hex"89504e470d0a1a0a0000000d4948445200000001000000010802000000907753"
        hex"de0000000c4944415408d763f8cfc0000003010100b5a37f2b0000000049454e"
        hex"44ae426082";

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_745_140
        );
        L = new PrecisionLauncher(PrecisionPoolFactory(payable(FACTORY)), TREASURY);
    }

    function test_aRealPngSurvivesTheWholeRoundTrip() public {
        (address t,) = L.launchWithArt("Zero Cat", "ZCAT", "", 1_000_000_000e18, 0, 30 ether, creator, PNG, 0);

        string memory uri = LaunchToken(t).contractURI();
        assertTrue(LibString.startsWith(uri, "data:application/json;base64,"), "not a JSON data URI");

        // Decode exactly as a consumer would: strip the prefix, base64-decode
        // the document, then find the image field inside it.
        string memory json = string(Base64.decode(LibString.slice(uri, 29)));
        assertTrue(LibString.contains(json, '"name":"Zero Cat"'), "name lost");
        assertTrue(LibString.contains(json, '"symbol":"ZCAT"'), "symbol lost");
        assertTrue(LibString.contains(json, '"image":"data:image/png;base64,'), "no image field");

        // And the payload really is the PNG that went in - decoded back to
        // bytes, not merely present as a string.
        uint256 at = LibString.indexOf(json, "base64,");
        string memory b64 = LibString.slice(json, at + 7);
        b64 = LibString.slice(b64, 0, LibString.indexOf(b64, '"'));
        bytes memory got = Base64.decode(b64);
        assertEq(keccak256(got), keccak256(PNG), "the image bytes did not survive");
        assertEq(got.length, PNG.length, "length changed");
        // The PNG magic, intact after two base64 passes.
        assertEq(uint8(got[0]), 0x89);
        assertEq(uint8(got[1]), 0x50);
        emit log_named_uint("contractURI length for a 51-byte PNG", bytes(uri).length);
    }

    /// The same for SVG, where the payload contains characters JSON escapes -
    /// quotes and slashes. If escaping ever reached inside the base64 payload
    /// rather than only the surrounding fields, this is what would catch it.
    function test_anSvgWithQuotesSurvivesToo() public {
        bytes memory svg = bytes('<svg xmlns="http://www.w3.org/2000/svg"><circle r="4"/></svg>');
        (address t,) = L.launchWithArt("Q", "Q", "", 1_000_000_000e18, 0, 30 ether, creator, svg, 2);

        string memory json = string(Base64.decode(LibString.slice(LaunchToken(t).contractURI(), 29)));
        assertTrue(LibString.contains(json, '"image":"data:image/svg+xml;base64,'), "wrong mime");
        uint256 at = LibString.indexOf(json, "base64,");
        string memory b64 = LibString.slice(json, at + 7);
        b64 = LibString.slice(b64, 0, LibString.indexOf(b64, '"'));
        assertEq(keccak256(Base64.decode(b64)), keccak256(svg), "the SVG did not survive");
    }

    /// Sizes a real logo actually lands at, so the gas figures quoted to users
    /// are measured rather than modelled.
    function test_whatARealisticLogoCosts() public {
        for (uint256 kb = 1; kb <= 8; kb *= 2) {
            bytes memory art = new bytes(kb * 1024);
            for (uint256 i; i < art.length; ++i) art[i] = bytes1(uint8(i * 7));
            uint256 g = gasleft();
            L.launchWithArt("C", "C", "", 1_000_000_000e18, 0, 30 ether, creator, art, 1);
            emit log_named_uint("KB", kb);
            emit log_named_uint("  total launch gas", g - gasleft());
        }
    }
}
