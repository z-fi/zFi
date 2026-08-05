// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {TokenListPage} from "../src/utils/TokenListPage.sol";
import {TokenList} from "../src/utils/TokenList.sol";

/// @dev Stands in for the registry at its constant mainnet address, so the JSON route
///      can be exercised without a fork. Only the two reads `tokenListJson` performs.
contract MockRegistry {
    uint256[] internal _ids;
    mapping(uint256 => TokenList.Token) internal _t;

    function push(uint256 id, TokenList.Token memory t) external {
        _ids.push(id);
        _t[id] = t;
    }

    function rankedIds() external view returns (uint256[] memory) {
        return _ids;
    }

    function get(uint256 id) external view returns (TokenList.Token memory) {
        return _t[id];
    }
}

contract TokenListPageJsonTest is Test {
    TokenListPage internal p;
    MockRegistry internal reg;

    address internal constant D1 = address(0xDA7A1);
    address internal constant D2 = address(0xDA7A2);
    address internal constant D3 = address(0xDA7A3);
    address internal constant D4 = address(0xDA7A4);

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function setUp() public {
        vm.etch(D1, hex"01");
        vm.etch(D2, hex"02");
        vm.etch(D3, hex"03");
        vm.etch(D4, hex"04");
        p = new TokenListPage(D1, D2, D3, D4);

        MockRegistry m = new MockRegistry();
        vm.etch(address(p.REGISTRY()), address(m).code);
        reg = MockRegistry(address(p.REGISTRY()));

        // A well-formed ERC-20, with a data: logo.
        reg.push(1, _tok(WETH, "Wrapped Ether", "WETH", 18, TokenList.Standard.ERC20, true, "data:image/svg+xml;base64,AAA"));
        // A second ERC-20, no logo.
        reg.push(2, _tok(USDC, "USD Coin", "USDC", 6, TokenList.Standard.ERC20, true, ""));
        // Native: address 0 — must never reach a token list.
        reg.push(3, _tok(address(0), "Ether", "ETH", 18, TokenList.Standard.NATIVE, true, ""));
        // A collection — likewise excluded.
        reg.push(4, _tok(address(0xBEEF), "Some NFT", "NFT", 0, TokenList.Standard.ERC721, true, ""));
        // A reservation: no account yet.
        reg.push(5, _tok(address(0), "Not Yet", "SOON", 18, TokenList.Standard.ERC20, false, ""));
        // Nameless — dropped rather than emitted broken.
        reg.push(6, _tok(address(0xCAFE), "", "NONAME", 18, TokenList.Standard.ERC20, true, ""));
        // Hostile logo scheme — must not be handed to a consumer.
        reg.push(7, _tok(address(0xD00D), "Evil", "EVIL", 18, TokenList.Standard.ERC20, true, "javascript:alert(1)"));
    }

    function _tok(
        address account,
        string memory name,
        string memory symbol,
        uint8 decimals,
        TokenList.Standard standard,
        bool deployed,
        string memory logo
    ) internal pure returns (TokenList.Token memory t) {
        t.account = bytes32(uint256(uint160(account)));
        t.chainId = 1;
        t.decimals = decimals;
        t.kind = TokenList.Kind.EVM;
        t.standard = standard;
        t.deployed = deployed;
        t.name = name;
        t.symbol = symbol;
        t.logo = logo;
    }

    function test_OnlyDeployedErc20sWithTextAppear() public view {
        string memory j = p.tokenListJson();
        assertTrue(_has(j, '"symbol":"WETH"'));
        assertTrue(_has(j, '"symbol":"USDC"'));
        assertFalse(_has(j, '"symbol":"ETH"'), "native asset leaked into the token list");
        assertFalse(_has(j, '"symbol":"NFT"'), "collection leaked into the token list");
        assertFalse(_has(j, '"symbol":"SOON"'), "reservation leaked into the token list");
        assertFalse(_has(j, '"symbol":"NONAME"'), "nameless entry emitted");
    }

    function test_AddressIsChecksummed() public view {
        assertTrue(_has(p.tokenListJson(), '"address":"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"'));
    }

    function test_HostileLogoSchemeIsDropped() public view {
        string memory j = p.tokenListJson();
        assertTrue(_has(j, '"symbol":"EVIL"'), "listing itself should still appear");
        assertFalse(_has(j, "javascript:"), "javascript: logoURI reached the token list");
    }

    function test_SafeLogoSurvives() public view {
        assertTrue(_has(p.tokenListJson(), '"logoURI":"data:image/svg+xml;base64,AAA"'));
    }

    /// @dev The schema's minor version tracks the token count, not the listing count.
    function test_VersionMinorTracksEmittedTokens() public view {
        assertTrue(_has(p.tokenListJson(), '"version":{"major":1,"minor":3,"patch":0}'));
    }

    function test_TimestampIsIso8601() public {
        vm.warp(1_767_225_600); // 2026-01-01T00:00:00Z
        assertTrue(_has(p.tokenListJson(), '"timestamp":"2026-01-01T00:00:00Z"'));
    }

    function test_Request_JsonRoute() public view {
        string[] memory r = new string[](1);
        r[0] = "tokenlist.json";
        (uint16 code, string memory body, TokenListPage.KeyValue[] memory h) =
            p.request(r, new TokenListPage.KeyValue[](0));
        assertEq(code, 200);
        assertEq(h[0].value, "application/json");
        assertTrue(_has(body, '"tokens":['));
        // A live list must not be cached as immutable.
        assertFalse(_has(h[1].value, "immutable"), "live JSON marked immutable");
    }

    function test_Request_RootAndUnknownPathsServeHtml() public view {
        TokenListPage.KeyValue[] memory none = new TokenListPage.KeyValue[](0);
        (, string memory a, TokenListPage.KeyValue[] memory ha) = p.request(new string[](0), none);
        string[] memory other = new string[](1);
        other[0] = "index.html";
        (, string memory b, TokenListPage.KeyValue[] memory hb) = p.request(other, none);
        assertEq(ha[0].value, "text/html");
        assertEq(hb[0].value, "text/html");
        assertEq(a, b);
        assertTrue(_has(ha[1].value, "immutable"), "bytecode-backed HTML should be immutable");
    }

    function test_EmptyRegistryStillValidJson() public {
        // `vm.etch` swaps code but leaves storage, so the previous mock's id array
        // would survive a re-etch. Zero slot 0 — MockRegistry's `_ids` length.
        vm.store(address(p.REGISTRY()), bytes32(0), bytes32(0));
        string memory j = p.tokenListJson();
        assertTrue(_has(j, '"tokens":[]'));
        assertTrue(_has(j, '"minor":0'));
    }

    function _has(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j != n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
