// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
import {ZorgConviction, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockNFT, MockWeiNames, MockTokenList} from "./ZorgConviction.t.sol";

/// Adversarial coverage for `ZorgReceiptArt`, which was produced by lifting the
/// metadata and SVG machinery out of `ZorgConviction` and rewiring it through an
/// interface. The lift is exactly the kind of change that keeps the happy path
/// working while breaking every defensive branch, so each case here drives a
/// branch that only fires on hostile or malformed underlying art.
///
/// The governing property: metadata may degrade to the fallback tile, but
/// `tokenURI` must never revert for a receipt that exists, and must never emit an
/// image URI that could break out of the `href='...'` attribute it is placed in.
contract ZorgReceiptArtAdversarialTest is Test {
    MockShares shares;
    MockNFT zorgz;
    ZorgConviction conviction;

    address holder = address(0xB0B);
    uint256 constant ID = 7;

    function setUp() public {
        shares = new MockShares();
        zorgz = new MockNFT();
        MockWeiNames names = new MockWeiNames();
        names.mint(address(0xD0A1), "zorg.wei");
        conviction = new ZorgConviction(
            address(0xDA0),
            address(shares),
            zorgz,
            names,
            address(new MockTokenList()),
            new ZorgConvictionRenderer(new ZorgPageStyle()),
            new ZorgReceiptArt(),
            7 days
        );
        vm.deal(holder, 10 ether);
    }

    function _bond(uint256 amount) internal {
        zorgz.mint(holder, ID, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(holder, amount);
        vm.startPrank(holder);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), ID);
        conviction.bondZorgz{value: 0.1 ether}(ID, amount);
        vm.stopPrank();
    }

    function _json() internal view returns (string memory) {
        string memory uri = conviction.tokenURI(ID);
        bytes memory b = bytes(uri);
        bytes memory out = new bytes(b.length - 29);
        for (uint256 i; i < out.length; ++i) out[i] = b[i + 29];
        return string(Base64.decode(string(out)));
    }

    /// ERC-721 requires a nonexistent token to revert. The governor keeps that
    /// guard rather than delegating it, so the split cannot have dropped it.
    function testNonexistentReceiptReverts() public {
        vm.expectRevert();
        conviction.tokenURI(ID);
    }

    /// A zOrgz whose `tokenURI` reverts must not take the receipt down with it.
    function testRevertingUnderlyingFallsBackInsteadOfReverting() public {
        _bond(100 ether);
        vm.mockCallRevert(address(zorgz), abi.encodeWithSignature("tokenURI(uint256)", ID), "boom");
        string memory json = _json();
        assertTrue(_has(json, "zOrgz Bond #7"), "metadata still produced");
        assertTrue(_has(_underlying(json), "font-family='monospace'"), "used the fallback tile");
    }

    /// Malformed or hostile underlying metadata must degrade, never revert.
    function testMalformedUnderlyingAlwaysDegrades() public {
        _bond(100 ether);
        string[6] memory hostile = [
            "data:image/svg+xml;base64,", // prefix with no payload
            "not-a-data-uri", // wrong scheme
            "data:application/json;base64,e30=", // valid JSON, no image key
            // image value containing a backslash escape: the scanner refuses
            // rather than trying to unescape.
            string.concat("data:application/json;base64,", Base64.encode(bytes('{"image":"data:image\\\\/svg"}'))),
            // an SVG data URI carrying a quote would break out of href='...'
            string.concat(
                "data:application/json;base64,",
                Base64.encode(bytes("{\"image\":\"data:image/svg+xml;base64,AAA'onload=alert(1)\"}"))
            ),
            // direct image URI that is not base64 SVG
            "data:image/png;base64,AAAA"
        ];
        for (uint256 i; i < hostile.length; ++i) {
            zorgz.setRawTokenURI(ID, hostile[i]);
            string memory json = _json();
            assertTrue(_has(json, "zOrgz Bond #7"), string.concat("produced metadata #", vm.toString(i)));
            assertTrue(
                _has(_underlying(json), "font-family='monospace'"),
                string.concat("fell back safely #", vm.toString(i))
            );
        }
    }

    /// The one hostile string that must NOT reach the page: a quote inside the
    /// embedded image URI would terminate the href attribute in `_invertedImage`.
    function testEmbeddedImageCannotEscapeItsAttribute() public {
        _bond(100 ether);
        zorgz.setRawTokenURI(
            ID,
            string.concat(
                "data:application/json;base64,",
                Base64.encode(bytes("{\"image\":\"data:image/svg+xml;base64,AAA'/><script>x</script>\"}"))
            )
        );
        string memory json = _json();
        // The receipt SVG is itself base64 in the metadata; decode and inspect.
        assertFalse(_has(json, "<script>"), "no script reached the metadata");
        string memory svg = string(Base64.decode(_afterImagePrefix(json)));
        assertFalse(_has(svg, "<script>"), "no script reached the SVG");
        assertFalse(_has(svg, "onload"), "no event handler reached the SVG");
    }

    /// A safe base64 SVG passes through and is actually embedded.
    function testSafeUnderlyingIsEmbedded() public {
        _bond(100 ether);
        zorgz.setRawTokenURI(ID, "data:image/svg+xml;base64,PHN2Zy8+");
        string memory svg = string(Base64.decode(_afterImagePrefix(_json())));
        assertTrue(_has(svg, "feComponentTransfer"), "inversion filter present");
        assertTrue(_has(svg, "data:image/svg+xml;base64,PHN2Zy8+"), "underlying embedded");
    }

    /// Eternal receipts splice a glyph after the 64px background rect. Art with
    /// no such anchor, or an unterminated one, must pass through untouched.
    function testEternalWithoutAnchorPassesThroughUnchanged() public {
        _bond(conviction.ETERNAL_MIN_ZORG());
        zorgz.setRawTokenURI(ID, "data:image/svg+xml;base64,PHN2Zy8+"); // <svg/>, no rect
        vm.prank(holder);
        conviction.eternalize(ID);
        string memory svg = string(Base64.decode(_afterImagePrefix(_json())));
        assertTrue(_has(svg, "data:image/svg+xml;base64,PHN2Zy8+"), "underlying unchanged");
        assertFalse(_has(svg, "#264cb5"), "no glyph without an anchor");
    }

    function testEternalWithUnterminatedAnchorDoesNotRevert() public {
        _bond(conviction.ETERNAL_MIN_ZORG());
        // Anchor present, but the tag never closes.
        bytes memory art = bytes('<svg><rect width="64" height="64" fill="#000"');
        zorgz.setRawTokenURI(
            ID, string.concat("data:image/svg+xml;base64,", Base64.encode(art))
        );
        vm.prank(holder);
        conviction.eternalize(ID);
        string memory json = _json();
        assertTrue(_has(json, '"value":"eternal"'), "still reports eternal");
    }

    /// Both status strings must reflect real state rather than a stale snapshot,
    /// since the art contract reads the governor back live.
    function testStatusStringsTrackLiveGovernorState() public {
        MockTokenList(address(conviction.tokenList())).setListed(123, true);
        _bond(100 ether);
        assertTrue(_has(_json(), '"Redeemable","value":"yes"'), "redeemable while unallocated");
        vm.prank(holder);
        conviction.allocate(ID, 123, 10 ether);
        assertTrue(_has(_json(), "clear allocations first"), "tracks the new allocation");
    }

    /// The underlying art is nested two deep: metadata -> receipt SVG (base64)
    /// -> `<image href='data:...'>` (base64 again). A fallback assertion made
    /// against the raw JSON can never fail, so unwrap both layers.
    function _underlying(string memory json) internal pure returns (string memory) {
        string memory receiptSvg = string(Base64.decode(_afterImagePrefix(json)));
        bytes memory b = bytes(receiptSvg);
        bytes memory key = bytes("data:image/svg+xml;base64,");
        uint256 at = _indexOf(receiptSvg, string(key));
        if (at >= b.length) return "";
        uint256 start = at + key.length;
        uint256 end = start;
        while (end < b.length && b[end] != "'") ++end;
        bytes memory enc = new bytes(end - start);
        for (uint256 i; i < enc.length; ++i) enc[i] = b[start + i];
        return string(Base64.decode(string(enc)));
    }

    function _afterImagePrefix(string memory json) internal pure returns (string memory) {
        bytes memory b = bytes(json);
        bytes memory key = bytes('"image":"data:image/svg+xml;base64,');
        uint256 at = _indexOf(json, string(key));
        require(at < b.length, "no image");
        uint256 start = at + key.length;
        uint256 end = start;
        while (end < b.length && b[end] != '"') ++end;
        bytes memory out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) out[i] = b[start + i];
        return string(out);
    }

    function _indexOf(string memory v, string memory needle) internal pure returns (uint256) {
        bytes memory b = bytes(v);
        bytes memory n = bytes(needle);
        if (n.length > b.length) return b.length;
        for (uint256 i; i + n.length <= b.length; ++i) {
            bool hit = true;
            for (uint256 k; k < n.length; ++k) {
                if (b[i + k] != n[k]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return i;
        }
        return b.length;
    }

    function _has(string memory v, string memory needle) internal pure returns (bool) {
        return _indexOf(v, needle) < bytes(v).length;
    }
}
