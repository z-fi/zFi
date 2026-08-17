// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {LaunchToken} from "../src/pools/PrecisionLauncher.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
import {LibClone} from "../lib/solady/src/utils/LibClone.sol";

/// @notice The on-chain logo. Simple marks - a cartoon, a wordmark - held as
///         contract code and assembled into an ERC-7572 document on read, so a
///         launched token depends on no pinning service and no gateway.
///
///         The tests are mostly about the SEAMS: that storing an image does not
///         destroy the external-URI path, that clearing it puts that path back,
///         and that the owner cannot inject anything into the data URI it now
///         controls the contents of.
contract LaunchTokenImageTest is Test {
    LaunchToken t;
    address owner = address(0xC0FFEE);
    address stranger = address(0xBEEF);

    // A real 1x1 PNG. Not a placeholder blob: `contractURI` embeds whatever it
    // is given, and a test that proves round-tripping of arbitrary bytes has
    // not shown that a viewer would render the result.
    bytes constant PNG =
        hex"89504e470d0a1a0a0000000d4948445200000001000000010802000000907753"
        hex"de0000000c4944415408d763f8cfc0000003010100b5a37f2b0000000049454e"
        hex"44ae426082";

    function setUp() public {
        // A clone, as the launcher now makes them. A directly-deployed
        // `LaunchToken` cannot be used as a token at all: its constructor locks
        // it so the template can never be claimed, so `new` gives a template
        // and only a clone of one is initializable.
        t = LaunchToken(LibClone.clone_PUSH0(address(new LaunchToken())));
        t.initialize("Test Coin", "TEST", "ipfs://placed-earlier", 1e27, owner, "", 0);
    }

    function _uri() internal view returns (string memory) {
        return t.contractURI();
    }

    // ------------------------------------------------- the two shapes it has

    /// With no image, this is exactly what it always was. The whole feature has
    /// to be invisible until used, because every already-planned launch sets a
    /// URI and nothing else.
    function test_withNoImageItIsStillJustTheStoredString() public view {
        assertEq(_uri(), "ipfs://placed-earlier");
        assertEq(t.imagePointer(), address(0));
    }

    function test_storingAnImageSwitchesToAnAssembledDocument() public {
        vm.prank(owner);
        t.setImage(PNG, 0);

        string memory uri = _uri();
        assertTrue(LibString.startsWith(uri, "data:application/json;base64,"), "not a JSON data URI");

        string memory json = string(Base64.decode(LibString.slice(uri, 29)));
        assertTrue(LibString.contains(json, '"name":"Test Coin"'), "name missing");
        assertTrue(LibString.contains(json, '"symbol":"TEST"'), "symbol missing");
        assertTrue(LibString.contains(json, "data:image/png;base64,"), "image missing");
        // The bytes actually survive the round trip, rather than merely a field
        // of the right shape being present.
        assertTrue(LibString.contains(json, Base64.encode(PNG)), "the image bytes changed");
    }

    /// The URI the owner set earlier is not thrown away when an image arrives -
    /// it becomes the description. Setting one before an image is therefore not
    /// wasted, which is the case every existing launch is in.
    function test_theStoredStringBecomesTheDescription() public {
        vm.prank(owner);
        t.setImage(PNG, 0);
        string memory json = string(Base64.decode(LibString.slice(_uri(), 29)));
        assertTrue(LibString.contains(json, '"description":"ipfs://placed-earlier"'), "description dropped");
    }

    // ------------------------------------------------------------ reversible

    /// Empty bytes clear the image. Without this, `SSTORE2.write("")` would
    /// deploy a one-byte STOP contract that reads back as an empty image and
    /// renders as a BROKEN one - a token stuck displaying nothing, with no way
    /// back to a working external URI.
    function test_anEmptyImageClearsItAndRestoresTheStoredString() public {
        vm.startPrank(owner);
        t.setImage(PNG, 0);
        assertTrue(t.imagePointer() != address(0));
        t.setImage("", 0);
        vm.stopPrank();

        assertEq(t.imagePointer(), address(0), "the pointer must be cleared, not emptied");
        assertEq(_uri(), "ipfs://placed-earlier", "and the external URI is served again");
    }

    /// Open with a rough mark, pay for a better one later. The point of leaving
    /// this editable rather than sealing it at launch.
    function test_theImageCanBeReplaced() public {
        bytes memory better = bytes(string.concat("<svg>", LibString.repeat("x", 400), "</svg>"));
        vm.startPrank(owner);
        t.setImage(PNG, 0);
        address first = t.imagePointer();
        t.setImage(better, 2);
        vm.stopPrank();

        assertTrue(t.imagePointer() != first, "a new pointer");
        assertEq(t.imageMime(), 2);
        string memory json = string(Base64.decode(LibString.slice(_uri(), 29)));
        assertTrue(LibString.contains(json, "data:image/svg+xml;base64,"), "mime did not follow");
        assertTrue(LibString.contains(json, Base64.encode(better)), "new bytes did not follow");
    }

    // --------------------------------------------------------------- guards

    function test_onlyTheOwnerMaySetAnImage() public {
        vm.prank(stranger);
        vm.expectRevert();
        t.setImage(PNG, 0);
    }

    /// The mime is a CODE, not a string, and an unknown code is refused rather
    /// than falling through to a default. The owner now controls bytes that end
    /// up inside a `data:` URI, and a free-form mime would be the one field
    /// they could inject through.
    function test_anUnknownMimeIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(LaunchToken.BadMime.selector);
        t.setImage(PNG, 6);
    }

    /// A name or description carrying a quote must not be able to break out of
    /// the JSON it is embedded in. Owner-controlled, so this is reachable.
    function test_aQuoteInTheDescriptionCannotBreakTheJson() public {
        vm.startPrank(owner);
        t.setContractURI('evil","image":"http://elsewhere');
        t.setImage(PNG, 0);
        vm.stopPrank();

        string memory json = string(Base64.decode(LibString.slice(_uri(), 29)));
        // Escaped, so the injected key never becomes a key.
        assertTrue(LibString.contains(json, '\\"image\\":'), "the quote was not escaped");
        assertFalse(LibString.contains(json, '"image":"http://elsewhere'), "injection succeeded");
        // And the real image field is still the one that was stored.
        assertTrue(LibString.contains(json, '"image":"data:image/png;base64,'), "real image field lost");
    }

    // ----------------------------------------------------------------- cost

    /// The claim that makes this affordable: code deposit at 200 gas a byte
    /// rather than storage at 20,000 per 32-byte word. Asserted rather than
    /// described, because it is the entire reason for the design.
    function test_storingAnImageCostsCodeRatesNotStorageRates() public {
        bytes memory art = new bytes(3000);
        for (uint256 i; i < art.length; ++i) {
            art[i] = bytes1(uint8(i));
        }

        vm.prank(owner);
        uint256 before = gasleft();
        t.setImage(art, 1);
        uint256 used = before - gasleft();

        emit log_named_uint("gas to store a 3 KB image", used);
        // Storage would be ceil(4000/32) * 20000 = 2.5M for the base64 form.
        // Code deposit is 3000 * 200 = 600k plus overhead.
        assertLt(used, 1_000_000, "this is being stored at storage rates");
        assertEq(t.imagePointer().code.length, art.length + 1, "SSTORE2 keeps the STOP byte");
    }

    /// Reading is a view call, where gas is free - but not INFINITE, since
    /// providers cap `eth_call`. Two base64 passes over a large image is the
    /// worst case, so measure it at the EIP-170 ceiling.
    function test_readingTheLargestPossibleImageStaysWithinAnEthCallBudget() public {
        bytes memory art = new bytes(24_575);
        vm.prank(owner);
        t.setImage(art, 1);

        uint256 before = gasleft();
        string memory uri = _uri();
        uint256 used = before - gasleft();

        emit log_named_uint("gas to render a 24 KB image", used);
        assertGt(bytes(uri).length, 24_575, "it rendered something");
        assertLt(used, 30_000_000, "over a typical eth_call cap");
    }
}
