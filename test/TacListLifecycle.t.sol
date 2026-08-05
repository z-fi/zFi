// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListPage} from "../src/utils/TokenListPage.sol";

/// @notice Full TAC lifecycle against live mainnet state: list -> verify -> delist -> re-list.
contract TacListLifecycleTest is Test {
    TokenList constant REG = TokenList(payable(0x0000006013dF75A31678B786061C2B54bf531524));
    TokenListPage constant PAGE = TokenListPage(0x000000B06Bc63Ef8830645D4524cd0d0Ae824b3d);
    address constant SAFE = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;

    bytes32 constant TAC_ASSET_ID =
        0xf0bbe868af10c6c67652a99709bf32048d1aa7194efe3e9a1ef1bde43f94762b;

    function _list() internal returns (uint256 id) {
        vm.startPrank(SAFE);
        id = REG.listForeign(
            TokenList.Kind.OTHER, 0, TAC_ASSET_ID,
            "Tacit Coin", "TAC", 8, 0xf7931a, 988000, ""
        );
        REG.setStandard(id, TokenList.Standard.TACIT);
        REG.setArt(id, 0xf7931a, 988000, "", "https://tacit.finance",
            "Tacit Coin is the native asset of Tacit, a confidential DeFi layer on Bitcoin. Supply is fixed at 21,000,000 and non-mintable, provable from the etch transaction alone.");
        REG.setLogoSVG(id, vm.readFile("./dapp/tokenlist/marks/tac.svg"));
        vm.stopPrank();
    }

    function test_ListThenDelistThenRelist() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        // Once TAC is listed for real, `listForeign` reverts Exists() and this
        // pre-flight has served its purpose. Skip rather than fail - the same
        // staleness that broke the FWA scripts the day FWA went live.
        if (REG.isListed(REG.idOf(TokenList.Kind.OTHER, 0, TAC_ASSET_ID))) {
            emit log("TAC already listed - pre-flight skipped");
            return;
        }

        // --- integrator JSON before ---
        uint256 jsonBefore = _countTokens(PAGE.tokenListJson());

        uint256 id = _list();
        emit log_named_uint("listing id", id);
        assertTrue(id >> 255 == 1, "foreign flag not set");
        assertEq(id, REG.idOf(TokenList.Kind.OTHER, 0, TAC_ASSET_ID), "id is not the asset hash");
        assertEq(REG.total(), 13, "not listed");
        assertEq(REG.ownerOf(id), address(REG), "foreign listing must be held by the registry");
        assertEq(REG.get(id).symbol, "TAC");
        assertEq(REG.get(id).decimals, 8);
        assertTrue(REG.get(id).standard == TokenList.Standard.TACIT, "standard not TACIT");
        assertFalse(REG.get(id).synced, "must not claim onchain sync");

        // --- integrators are untouched ---
        assertEq(_countTokens(PAGE.tokenListJson()), jsonBefore, "TAC leaked into tokenlist.json");
        emit log_named_uint("tokenlist.json tokens, unchanged", jsonBefore);

        // --- WORST CASE: delist ---
        vm.prank(SAFE);
        REG.delist(id);
        assertEq(REG.total(), 12, "delist did not remove it");
        assertFalse(REG.isListed(id), "still listed");
        vm.expectRevert();
        REG.ownerOf(id); // NFT burned
        vm.expectRevert();
        REG.get(id);     // entry wiped
        emit log("delist: entry wiped, NFT burned, count restored");

        // --- and the id is reusable: re-listing yields the SAME id ---
        uint256 id2 = _list();
        assertEq(id2, id, "re-list produced a different id");
        assertEq(REG.get(id2).symbol, "TAC");
        emit log("re-list: same id, fully restored");

        // --- ordering is preserved: TAC lands at 13, after FWA ---
        uint256[] memory ids = REG.rankedIds();
        assertEq(ids[ids.length - 1], id2, "TAC not last");
        emit log_named_uint("position", ids.length);
    }

    function _countTokens(string memory json) internal pure returns (uint256 n) {
        bytes memory b = bytes(json);
        for (uint256 i; i + 8 < b.length; ++i) {
            if (b[i] == '"' && b[i+1] == 'c' && b[i+2] == 'h' && b[i+3] == 'a'
                && b[i+4] == 'i' && b[i+5] == 'n' && b[i+6] == 'I' && b[i+7] == 'd') ++n;
        }
    }
}
