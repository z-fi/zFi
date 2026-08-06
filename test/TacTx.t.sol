// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListPage} from "../src/utils/TokenListPage.sol";

/// @notice Execute the EXACT multicall bytes the multisig will broadcast.
contract TacTxTest is Test {
    address constant REG  = 0x0000006013dF75A31678B786061C2B54bf531524;
    address constant PAGE = 0x000000B06Bc63Ef8830645D4524cd0d0Ae824b3d;
    address constant SAFE = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;
    uint256 constant ID =
        104165018710067097353655755692819801489527232022561016148205125677286991358696;

    function test_RawMulticall() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        if (TokenList(payable(REG)).isListed(ID)) { emit log("already listed - skipped"); return; }

        bytes memory cd = vm.parseBytes(vm.replace(vm.readFile("./deploy/TAC-list.calldata.txt"), "\n", ""));
        emit log_named_uint("calldata bytes", cd.length);

        uint256 jsonBefore = _count(TokenListPage(PAGE).tokenListJson());
        uint256 before_ = TokenList(payable(REG)).total();

        uint256 g = gasleft();
        vm.prank(SAFE);
        (bool ok,) = REG.call(cd);
        emit log_named_uint("gas used", g - gasleft());
        assertTrue(ok, "multicall reverted");

        TokenList.Token memory t = TokenList(payable(REG)).get(ID);
        assertEq(TokenList(payable(REG)).total(), before_ + 1, "not listed");
        assertEq(t.name, "Tacit Coin");
        assertEq(t.symbol, "TAC");
        assertEq(t.decimals, 8);
        assertEq(t.account, 0xf0bbe868af10c6c67652a99709bf32048d1aa7194efe3e9a1ef1bde43f94762b);
        assertEq(t.chainId, 0, "non-EVM must carry no eip155 id");
        assertTrue(t.kind == TokenList.Kind.OTHER, "kind not OTHER");
        assertTrue(t.standard == TokenList.Standard.TACIT, "standard not TACIT");
        assertFalse(t.synced, "must not claim onchain sync");
        assertEq(t.url, "https://tacit.finance");
        assertGt(bytes(t.logo).length, 0, "logo empty");
        assertGt(bytes(t.description).length, 0, "description empty");
        assertEq(t.audit, "https://tacit.finance/verify", "audit link missing");

        // The description says TAC is provable "from the etch transaction alone".
        // That claim is only actionable if the listing says WHICH transaction, so the
        // etch txid is carried as an extension field rather than left implicit.
        assertEq(
            TokenList(payable(REG)).getExtra(ID, bytes32("etch tx")),
            "e2d10be19c2b73b86e14be99dc237a3d999ba3dfbe6f3e3714590acee2ca481e",
            "etch txid missing"
        );
        assertEq(
            TokenList(payable(REG)).getExtra(ID, bytes32("issued")),
            "21,000,000 non-mintable",
            "supply extra missing"
        );
        bytes32[] memory keys = TokenList(payable(REG)).extraKeys(ID);
        assertEq(keys.length, 2, "unexpected extension key count");
        emit log_named_uint("extension keys", keys.length);
        assertEq(TokenList(payable(REG)).ownerOf(ID), REG, "must be held by the registry");

        // integrators untouched
        assertEq(_count(TokenListPage(PAGE).tokenListJson()), jsonBefore, "leaked into tokenlist.json");
        emit log_named_uint("tokenlist.json tokens, unchanged", jsonBefore);

        // position 13, after FWA
        uint256[] memory ids = TokenList(payable(REG)).rankedIds();
        assertEq(ids[ids.length - 1], ID, "not last");
        emit log_named_uint("position", ids.length);

        // the card renders
        assertGt(bytes(TokenList(payable(REG)).tokenURI(ID)).length, 0, "tokenURI empty");
        emit log("card renders");

        // a non-owner cannot send these bytes
        vm.prank(address(0xBAD));
        (bool ok2,) = REG.call(cd);
        assertFalse(ok2, "non-owner could list");
        emit log("guard: non-owner reverts");
    }

    function _count(string memory j) internal pure returns (uint256 n) {
        bytes memory b = bytes(j);
        for (uint256 i; i + 8 < b.length; ++i)
            if (b[i]=='"'&&b[i+1]=='c'&&b[i+2]=='h'&&b[i+3]=='a'&&b[i+4]=='i'&&b[i+5]=='n'&&b[i+6]=='I'&&b[i+7]=='d') ++n;
    }
}
