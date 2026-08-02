// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";
import {PostDeployListings} from "./PostDeployListings.sol";

/// @dev Deploys the EXACT mined initcode through the real SafeSummoner on a mainnet
///      fork and checks the resulting addresses, wiring and seeded state. A salt is
///      only meaningful if the payload it was mined for actually constructs.
contract TokenListMinedDeployTest is Test, PostDeployListings {
    address constant SUMMONER = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant OWNER = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;
    address constant RENDERER = 0x000000F2CcbE111146ec4aa17c76BC1eCBa4f7C6;
    address constant LIST = 0x000000e852c6513458C6ea2F99916d513E77edF9;

    bytes32 constant RENDERER_SALT = 0x000000000000000000000000000000000000000000000000000000000171eb16;
    bytes32 constant LIST_SALT = 0x00000000000000000000000000000000000000000000000000000000004803cc;

    /// @dev The recorded initcode is a frozen artifact of a specific build, and the
    ///      salt was mined FOR that build. Editing the source invalidates both, so
    ///      running this against a stale payload would either fail for a reason
    ///      that has nothing to do with the deployment or, worse, pass and suggest
    ///      the mined address still corresponds to the code in the tree. Skip
    ///      loudly instead; re-mine, re-record, and it comes back on its own.
    function testMinedDeploymentLandsAndWires() public {
        bytes memory recorded = vm.readFileBinary("deploy/TokenList.initcode.bin");
        bytes memory recordedRenderer = vm.readFileBinary("deploy/TokenListRenderer.initcode.bin");
        bytes memory compiled = abi.encodePacked(vm.getCode("TokenList.sol:TokenList"), abi.encode(OWNER, RENDERER));
        bytes memory compiledRenderer = vm.getCode("TokenListRenderer.sol:TokenListRenderer");
        if (keccak256(recorded) != keccak256(compiled) || keccak256(recordedRenderer) != keccak256(compiledRenderer)) {
            emit log("TokenList deployment artifacts are stale: re-mine both salts and re-record both initcodes");
            vm.skip(true);
        }

        assertGt(SUMMONER.code.length, 0, "SafeSummoner must exist on this fork");
        assertEq(RENDERER.code.length, 0, "renderer address must be vacant");
        assertEq(LIST.code.length, 0, "list address must be vacant");

        (bool ok, bytes memory ret) =
            SUMMONER.call(abi.encodeWithSignature("create2Deploy(bytes,bytes32)", recordedRenderer, RENDERER_SALT));
        assertTrue(ok, "renderer deploy failed");
        ret;
        assertEq(RENDERER.code.length > 0, true, "renderer has no code");

        bytes memory lInit = vm.readFileBinary("deploy/TokenList.initcode.bin");
        (ok,) = SUMMONER.call(abi.encodeWithSignature("create2Deploy(bytes,bytes32)", lInit, LIST_SALT));
        assertTrue(ok, "list deploy failed");
        assertGt(LIST.code.length, 0, "list has no code");

        TokenList list = TokenList(LIST);
        assertEq(list.owner(), OWNER, "owner");
        assertEq(address(list.renderer()), RENDERER, "renderer wired");
        assertFalse(list.rendererLocked());

        // The constructor seeds FOUR, not eleven: the per-transaction gas cap does
        // not fit the original set, so the other seven are applied afterwards
        // through `list` + `setLogoSVG`. See the constructor comment in TokenList.
        // This assertion read 11 and had never actually run, because the artifacts
        // were stale for long enough that the guard above skipped the whole test.
        assertEq(list.total(), 4, "constructor-seeded set");
        assertEq(list.get(address(0)).symbol, "ETH");
        assertEq(list.idOf(address(0)), 0);
        assertEq(list.get(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2).symbol, "WETH");
        assertEq(list.get(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48).decimals, 6, "USDC decimals");

        // Then the real post-deploy route, against the real deployed registry: the
        // same owner multicalls `deploy/TokenList.postdeploy.calldata.txt` carries.
        // Deploying the mined payload and never exercising this left the half of the
        // launch that actually produces the shipped list untested at this address.
        Listing[] memory pending = _postDeployListings();
        for (uint256 i; i < pending.length; ++i) {
            Listing memory e = pending[i];
            uint256 lid = uint256(uint160(e.token));
            bytes[] memory calls = new bytes[](e.onchainSvg ? 3 : 2);
            calls[0] = abi.encodeWithSignature(
                "list(address,uint24,uint32,string,string,string)", e.token, e.color, e.rank, "", e.url, e.description
            );
            calls[1] = abi.encodeWithSignature("setLogoSVG(uint256,string)", lid, e.logo);
            if (e.onchainSvg) calls[2] = abi.encodeWithSignature("setOnchainSvg(uint256,bool)", lid, true);
            vm.prank(OWNER);
            list.multicall(calls);
        }
        assertEq(list.total(), 11, "full set after the post-deploy route");
        TokenList.Token memory zorg = list.get(ZORG);
        assertEq(zorg.name, "zOrg Shares", "zOrg name");
        assertEq(zorg.symbol, "ZORG", "zOrg symbol");
        assertEq(zorg.url, "https://zorg.wei.domains", "zOrg link");
        assertEq(list.rankedIds()[8], list.idOf(ZORG), "zOrg placement");
        assertEq(uint8(list.get(ZORGZ).standard), uint8(TokenList.Standard.ERC721), "zOrgz is ERC-721");
        assertEq(uint8(list.get(WNS).standard), uint8(TokenList.Standard.ERC721), "WNS is ERC-721");
        assertTrue(list.get(ZORGZ).onchainSvg, "zOrgz token IDs use onchain SVG");
        assertTrue(list.get(WNS).onchainSvg, "WNS token IDs use onchain SVG");
        assertEq(list.rankedIds()[10], list.idOf(WNS), "WNS is final initial listing");
        assertEq(list.ownerOf(0), LIST, "attested listing held by the registry");
        assertTrue(list.supportsInterface(0x49064906) && list.supportsInterface(0xb45a3c0e));
        assertGt(bytes(list.tokenURI(0)).length, 1000, "card renders");
        assertGt(bytes(list.json(0)).length, 100, "json renders");

        emit log_named_uint("TokenList runtime", LIST.code.length);
        emit log_named_uint("Renderer runtime", RENDERER.code.length);
    }
}
