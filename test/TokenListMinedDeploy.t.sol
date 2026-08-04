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
    address constant RENDERER = 0x000000d595e36Dd0228c4040D981A01A59DbbE87;
    address constant LIST = 0x0000006013dF75A31678B786061C2B54bf531524;

    bytes32 constant RENDERER_SALT = 0x0000000000000000000000000000000000000000000000000000000001b888f4;
    bytes32 constant LIST_SALT = 0x00000000000000000000000000000000000000000000000000000000002febeb;

    /// @dev The recorded initcode is a frozen artifact of a specific build, and the
    ///      salt was mined FOR that build. Editing the source invalidates both, so
    ///      running this against a stale payload would either fail for a reason
    ///      that has nothing to do with the deployment or, worse, pass and suggest
    ///      the mined address still corresponds to the code in the tree. Skip
    ///      loudly instead; re-mine, re-record, and it comes back on its own.
    function testMinedDeploymentLandsAndWires() public {
        bytes memory recorded = vm.readFileBinary("deploy/TokenList.initcode.bin");
        bytes memory recordedRenderer = vm.readFileBinary("deploy/TokenListRenderer.initcode.bin");
        // Staleness is a question about the SOURCE, not about whichever build happens
        // to be in `out/`.
        //
        // This compared the recorded initcode against `vm.getCode`, which made the
        // check depend on how the caller had built: under `via_ir` a contract compiles
        // differently depending on which other files share its compilation unit, and
        // the isolated build these artifacts came from differs from a full `forge
        // build` by hundreds of bytes. So this guard tripped on every full-suite run
        // and skipped the one test that replays the real deployment — silently, which
        // is how it came to carry a stale assertion of its own for so long.
        //
        // The recorded source hashes answer what this is actually asking: did the code
        // these artifacts were mined for change? True or false regardless of build
        // mode, so this test now runs everywhere.
        string memory manifest = vm.readFile("deploy/TokenList.sources.txt");
        string[2] memory sources = ["src/utils/TokenList.sol", "src/utils/TokenListRenderer.sol"];
        for (uint256 i; i < sources.length; ++i) {
            string memory entry = string.concat(sources[i], " ", vm.toString(keccak256(bytes(vm.readFile(sources[i])))));
            if (!vm.contains(manifest, entry)) {
                emit log_named_string("source changed since the salts were mined", sources[i]);
                emit log("re-mine, re-record with script/build-create2-artifact.mjs, and update the constants here");
                vm.skip(true);
            }
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

        // The CONSTRUCTOR's half of the split: four, not eleven. This assertion read
        // 11 until now, written when eleven tokens still fit in initcode. EIP-7825's
        // per-transaction gas cap moved seven of them to owner calldata, and because
        // this suite skips itself whenever the recorded artifacts go stale, the stale
        // expectation was never executed against the contract it describes. It would
        // have failed on the first green re-mine — that is, at the exact moment this
        // test was finally being trusted to clear the deployment.
        assertEq(list.total(), 4, "constructor seeds exactly the four that fit");
        assertEq(list.get(address(0)).symbol, "ETH");
        assertEq(list.idOf(address(0)), 0);
        assertEq(list.get(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2).symbol, "WETH");
        assertEq(list.get(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48).decimals, 6, "USDC decimals");

        // The OWNER's half: the seven that no longer fit, applied with the very
        // calldata `TokenListPostDeploy` emits for broadcast. Replaying both halves
        // here is the only place the mined payload and the follow-up transactions are
        // proven to compose into the intended list.
        Listing[] memory pending = _postDeployListings();
        for (uint256 i; i < pending.length; ++i) {
            vm.prank(OWNER);
            list.multicall(_callsFor(pending[i]));
        }
        assertEq(list.total(), 11, "four seeded plus seven applied");

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
