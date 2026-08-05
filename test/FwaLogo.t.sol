// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";

contract FwaLogoTest is Test {
    function test_OnchainCardEmbedsFwaLogo() public {
        // The LIVE deployed renderer, not a local build.
        TokenListRenderer r = TokenListRenderer(0x0000009650f4aEF08AdB2De98bdD2695A41eDcF4);
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        TokenList.Token memory t;
        t.chainId = 1; t.deployed = true; t.synced = true;
        t.name = "Fake World Assets"; t.symbol = "FWA"; t.decimals = 18;
        t.color = 0xf2a0c0; t.rank = 989000;
        t.account = bytes32(uint256(uint160(0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845)));
        t.logo = vm.readFile("dapp/tokenlist/marks/fwa.uri.txt");

        string memory uri = r.tokenURI(12, t, new TokenListRenderer.Extra[](0));
        string memory json = string(Base64.decode(_after(uri, ",")));
        emit log_named_uint("tokenURI bytes", bytes(uri).length);
        // decode the image field -> the card SVG
        string memory img = _val(json, '"image":"');
        string memory card = string(Base64.decode(_after(img, ",")));
        emit log_named_uint("card svg bytes", bytes(card).length);
        assertTrue(_has(card, "<image"), "logo not drawn into card");
        assertTrue(_has(card, "data:image/png;base64,"), "png uri not embedded");
        assertTrue(_has(card, "FWA"), "symbol missing");
        emit log("RESULT: live onchain renderer embeds the FWA PNG into the card SVG");
    }

    function _after(string memory s, string memory sep) internal pure returns (string memory) {
        bytes memory b = bytes(s); bytes1 k = bytes(sep)[0];
        for (uint256 i; i != b.length; ++i) { if (b[i] != k) continue;
            bytes memory o = new bytes(b.length - i - 1);
            for (uint256 j; j != o.length; ++j) o[j] = b[i + 1 + j];
            return string(o); }
        revert("sep");
    }
    function _val(string memory j, string memory key) internal pure returns (string memory) {
        bytes memory h = bytes(j); bytes memory k = bytes(key);
        for (uint256 i; i + k.length < h.length; ++i) { bool hit = true;
            for (uint256 x; x != k.length; ++x) if (h[i+x] != k[x]) { hit = false; break; }
            if (!hit) continue;
            uint256 st = i + k.length; uint256 en = st;
            while (en < h.length && h[en] != '"') ++en;
            bytes memory o = new bytes(en - st);
            for (uint256 j2; j2 != o.length; ++j2) o[j2] = h[st + j2];
            return string(o); }
        revert("no key");
    }
    function _has(string memory hay, string memory n_) internal pure returns (bool) {
        bytes memory h = bytes(hay); bytes memory n = bytes(n_);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) { bool ok = true;
            for (uint256 j; j != n.length; ++j) if (h[i+j] != n[j]) { ok = false; break; }
            if (ok) return true; }
        return false;
    }
}
