// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
import {ZorgConviction, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockNFT, MockWeiNames, MockTokenList} from "./ZorgConviction.t.sol";

/// Runs the REAL onchain art of zOrgz #9953 (fetched from mainnet and pinned to
/// `dapp/zorg/zorgz-9953.uri`) through `ZorgConviction.tokenURI`, so the receipt
/// image can be reviewed as the contract actually produces it rather than from a
/// hand-drawn stand-in.
contract ZorgReceiptArtTest is Test {
    address dao = address(0xDA0);
    address holder = address(0xB0B);

    MockShares shares;
    MockNFT zorgz;
    ZorgConviction conviction;

    uint256 constant ID = 9953;

    function setUp() public {
        shares = new MockShares();
        zorgz = new MockNFT();
        MockWeiNames names = new MockWeiNames();
        names.mint(address(0xD0A1), "zorg.wei");
        conviction = new ZorgConviction(
            dao, address(shares), zorgz, names, address(new MockTokenList()), new ZorgConvictionRenderer(new ZorgPageStyle()), new ZorgReceiptArt(), 7 days
        );
        vm.deal(holder, 10 ether);
    }

    function _bond(uint256 amount) internal {
        string memory real = vm.readFile("./dapp/zorg/zorgz-9953.uri");
        zorgz.mint(holder, ID, "");
        zorgz.setRawTokenURI(ID, real);
        shares.mint(holder, amount);
        vm.startPrank(holder);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), ID);
        conviction.bondZorgz{value: 0.1 ether}(ID, amount);
        vm.stopPrank();
    }

    function _image(string memory metadataJson) internal pure returns (string memory) {
        bytes memory b = bytes(metadataJson);
        bytes memory key = bytes('"image":"');
        for (uint256 i; i + key.length < b.length; ++i) {
            bool hit = true;
            for (uint256 k; k < key.length; ++k) {
                if (b[i + k] != key[k]) {
                    hit = false;
                    break;
                }
            }
            if (!hit) continue;
            uint256 start = i + key.length;
            for (uint256 end = start; end < b.length; ++end) {
                if (b[end] == '"') {
                    bytes memory out = new bytes(end - start);
                    for (uint256 j; j < out.length; ++j) out[j] = b[start + j];
                    return string(out);
                }
            }
        }
        return "";
    }

    function _metadata() internal view returns (string memory) {
        string memory uri = conviction.tokenURI(ID);
        bytes memory b = bytes(uri);
        bytes memory out = new bytes(b.length - 29);
        for (uint256 i; i < out.length; ++i) out[i] = b[i + 29];
        return string(Base64.decode(string(out)));
    }

    function testStandardReceiptInvertsTheRealZorgz() public {
        _bond(1200 ether);
        string memory image = _image(_metadata());
        assertGt(bytes(image).length, 0, "no image");
        vm.writeFile("./dapp/zorg/receipt-9953.uri", image);

        string memory svg = string(Base64.decode(_drop(image, 26)));
        // The inversion is an SVG filter primitive, and it must embed the real
        // zOrgz art rather than the fallback tile.
        assertTrue(_has(svg, "feComponentTransfer"), "no filter");
        assertTrue(_has(svg, "data:image/svg+xml;base64,"), "no embedded art");
        assertFalse(_has(svg, "font-family='monospace'"), "fell back to the placeholder tile");
    }

    function testEternalReceiptInjectsTheGoldGlyphIntoTheRealZorgz() public {
        _bond(conviction.ETERNAL_MIN_ZORG());
        vm.prank(holder);
        conviction.eternalize(ID);

        string memory image = _image(_metadata());
        vm.writeFile("./dapp/zorg/receipt-9953-eternal.uri", image);

        // Unwrap the inversion to reach the source art the receipt embeds.
        string memory svg = string(Base64.decode(_drop(image, 26)));
        uint256 at = _indexOf(svg, "data:image/svg+xml;base64,");
        assertLt(at, bytes(svg).length, "no embedded art");
        string memory rest = _drop(svg, at + 26);
        string memory inner = string(Base64.decode(_upTo(rest, "'")));
        assertTrue(_has(inner, "#264cb5"), "gold source glyph not injected");
        assertTrue(_has(inner, 'fill="url(#bg)"'), "real zOrgz background lost");
    }

    function _drop(string memory v, uint256 start) internal pure returns (string memory) {
        bytes memory b = bytes(v);
        bytes memory o = new bytes(b.length - start);
        for (uint256 i; i < o.length; ++i) o[i] = b[i + start];
        return string(o);
    }

    function _upTo(string memory v, bytes1 stop) internal pure returns (string memory) {
        bytes memory b = bytes(v);
        uint256 n;
        while (n < b.length && b[n] != stop) ++n;
        bytes memory o = new bytes(n);
        for (uint256 i; i < n; ++i) o[i] = b[i];
        return string(o);
    }

    function _indexOf(string memory v, string memory needle) internal pure returns (uint256) {
        bytes memory b = bytes(v);
        bytes memory n = bytes(needle);
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
