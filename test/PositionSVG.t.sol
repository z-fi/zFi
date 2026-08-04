// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

contract WnsReverseMock {
    function reverseResolve(address) external pure returns (string memory) {
        return "terminal.wei";
    }
}

contract SymbolNFT {
    string public symbol = "MIL";
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "approval");
        ownerOf[id] = to;
    }
}

contract PositionSVGTest is Test {
    address constant WNS = 0x0000000000696760E15f265e828DB644A0c242EB;
    MockWETH weth;
    MockERC20 lot;
    MockERC20 quote;
    Swapboard swapboard;
    Dutchboard dutchboard;

    address maker = address(0xA11CE);
    address taker = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        lot = new MockERC20("LOT", 18);
        quote = new MockERC20("QUOTE", 18);
        swapboard = new Swapboard(address(weth));
        dutchboard = new Dutchboard(address(weth));
        lot.mint(maker, 1_000e18);
        quote.mint(taker, 1_000e18);
        vm.prank(maker);
        lot.approve(address(swapboard), type(uint256).max);
        vm.prank(maker);
        lot.approve(address(dutchboard), type(uint256).max);
        vm.prank(taker);
        quote.approve(address(swapboard), type(uint256).max);
        vm.prank(taker);
        quote.approve(address(dutchboard), type(uint256).max);
    }

    function test_SwapboardPositionHasLiveSvgURI() public {
        vm.prank(maker);
        uint256 id = swapboard.createOrder(address(lot), 100e18, address(quote), 200e18, true, 0, false, false, address(0));
        string memory beforeFill = swapboard.tokenURI(id);
        _assertMetadataImage(beforeFill);

        vm.prank(taker);
        swapboard.fillOrder(id, block.timestamp, 100e18, 0, taker);
        assertTrue(keccak256(bytes(beforeFill)) != keccak256(bytes(swapboard.tokenURI(id))), "fill updates SVG");
    }

    function test_DutchboardPositionHasLiveSvgURI() public {
        vm.prank(maker);
        uint256 id = dutchboard.listERC20(address(lot), address(quote), 100e18, 200e18, 100e18, 0, 1 days);
        string memory beforeFill = dutchboard.tokenURI(id);
        _assertMetadataImage(beforeFill);

        vm.prank(taker);
        dutchboard.fill(id, 50e18, taker, type(uint256).max);
        assertTrue(keccak256(bytes(beforeFill)) != keccak256(bytes(dutchboard.tokenURI(id))), "fill updates SVG");
    }

    function test_DutchboardTerminalCurveFreezesAtSettlement() public {
        vm.prank(maker);
        uint256 id = dutchboard.listERC20(address(lot), address(quote), 100e18, 200e18, 100e18, 0, 1 days);

        vm.warp(block.timestamp + 12 hours);
        vm.prank(taker);
        dutchboard.fill(id, 100e18, taker, type(uint256).max);
        bytes memory settledSvg = _svg(dutchboard.tokenURI(id));
        assertTrue(_contains(settledSvg, bytes("DUTCH CURVE")), "curve is rendered");
        assertTrue(_contains(settledSvg, bytes("M32 258Q360 258 688 281")), "paid floor stays above zero");
        assertTrue(_contains(settledSvg, bytes("stroke-dasharray='50.0 100'")), "curve shows settlement point");

        vm.warp(block.timestamp + 7 days);
        assertEq(keccak256(settledSvg), keccak256(_svg(dutchboard.tokenURI(id))), "terminal curve stays fixed");
    }

    function test_PositionUsesReverseWNSWhenAvailable() public {
        vm.prank(maker);
        uint256 id = swapboard.createOrder(address(lot), 100e18, address(quote), 200e18, true, 0, false, false, address(0));
        string memory fallbackUri = swapboard.tokenURI(id);

        WnsReverseMock resolver = new WnsReverseMock();
        vm.etch(WNS, address(resolver).code);
        assertTrue(keccak256(bytes(fallbackUri)) != keccak256(bytes(swapboard.tokenURI(id))), "WNS name reaches SVG");
    }

    function test_NFTSymbolIsSnapshottedForBothBoards() public {
        SymbolNFT nft = new SymbolNFT();
        nft.mint(maker, 7);
        nft.mint(maker, 8);
        vm.prank(maker);
        nft.setApprovalForAll(address(swapboard), true);
        vm.prank(maker);
        uint256 swapId = swapboard.createOrder(address(nft), 7, address(quote), 1e18, false, 0, true, false, address(0));
        assertTrue(_contains(_svg(swapboard.tokenURI(swapId)), bytes(" / MIL")), "swap NFT symbol");

        vm.prank(maker);
        nft.setApprovalForAll(address(dutchboard), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 8;
        vm.prank(maker);
        uint256 dutchId = dutchboard.listNFT(address(nft), address(quote), ids, 1e18, 1e18, 0, 1 days);
        assertTrue(_contains(_svg(dutchboard.tokenURI(dutchId)), bytes("NFT / MIL")), "dutch NFT symbol");
    }

    function _assertMetadataImage(string memory uri) internal pure {
        bytes memory encoded = _withoutPrefix(uri, "data:application/json;base64,");
        bytes memory json = Base64.decode(string(encoded));
        assertTrue(_contains(json, bytes("data:image/svg+xml;base64,")), "metadata has SVG image URI");
    }

    function _svg(string memory uri) internal pure returns (bytes memory) {
        bytes memory json = Base64.decode(string(_withoutPrefix(uri, "data:application/json;base64,")));
        bytes memory prefix = bytes("data:image/svg+xml;base64,");
        uint256 start;
        while (start + prefix.length <= json.length && !_hasPrefix(json, start, prefix)) ++start;
        require(start + prefix.length <= json.length, "missing image");
        uint256 end = start + prefix.length;
        while (end < json.length && json[end] != '"') ++end;
        bytes memory encoded = new bytes(end - start - prefix.length);
        for (uint256 i; i < encoded.length; ++i) encoded[i] = json[start + prefix.length + i];
        return Base64.decode(string(encoded));
    }

    function _hasPrefix(bytes memory source, uint256 offset, bytes memory prefix) internal pure returns (bool) {
        for (uint256 i; i < prefix.length; ++i) if (source[offset + i] != prefix[i]) return false;
        return true;
    }

    function _withoutPrefix(string memory value, string memory prefix) internal pure returns (bytes memory result) {
        bytes memory source = bytes(value);
        bytes memory p = bytes(prefix);
        require(source.length >= p.length, "short URI");
        for (uint256 i; i < p.length; ++i) require(source[i] == p[i], "wrong URI type");
        result = new bytes(source.length - p.length);
        for (uint256 i; i < result.length; ++i) result[i] = source[p.length + i];
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return false;
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
}
