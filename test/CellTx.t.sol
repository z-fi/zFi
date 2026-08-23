// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListPage} from "../src/utils/TokenListPage.sol";

/// @notice Builds and executes the CELL listing multicall for the src_co multisig.
///         Run against live mainnet state:
///           forge test --match-contract CellTx -vv
/// @dev The calldata that gets broadcast is written by the same test that proves what
///      it does, so the file and the assertions can never drift apart.
contract CellTxTest is Test {
    using LibString for string;

    address constant REG = 0x0000006013dF75A31678B786061C2B54bf531524;
    address constant PAGE = 0x000000B06Bc63Ef8830645D4524cd0d0Ae824b3d;
    address constant SAFE = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;
    address constant CELL = 0xf142CfA6Ca3DFa4A131f12aACEF4890e390d70D6;

    // Local listings are keyed by the address itself.
    uint256 constant ID = uint256(uint160(CELL));

    uint24 constant COLOR = 0xB62A38; // the mark's own oxblood bezel
    // Sparse by 1,000, continuing the tail: FOLD holds 987000.
    uint32 constant RANK = 986_000;
    string constant URL = "https://cell.wei.is";
    string constant DESC =
        "A hardware wallet that requires a live pulse, or a drop of fresh blood, to authorize a transaction.";

    function test_CellListing() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")));

        string memory svg = vm.readFile("./dapp/tokenlist/marks/cell.svg").replace("\n", "");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(TokenList.list, (CELL, COLOR, RANK, "", URL, DESC));
        calls[1] = abi.encodeCall(TokenList.setLogoSVG, (ID, svg));
        bytes memory cd = abi.encodeWithSignature("multicall(bytes[])", calls);

        vm.writeFile("./deploy/CELL-list.calldata.txt", vm.toString(cd));
        emit log_named_uint("calldata bytes", cd.length);
        emit log_named_bytes32("calldata sha256", sha256(cd));

        TokenList reg = TokenList(payable(REG));
        if (reg.isListed(ID)) {
            emit log("already listed - simulation skipped");
            return;
        }

        uint256 jsonBefore = _count(TokenListPage(PAGE).tokenListJson());
        uint256 before_ = reg.total();

        uint256 g = gasleft();
        vm.prank(SAFE);
        (bool ok,) = REG.call(cd);
        emit log_named_uint("gas used", g - gasleft());
        assertTrue(ok, "multicall reverted");

        // Everything textual is read from the token by `list` itself, not supplied by
        // the curator: that is what earns the card's onchain chip.
        TokenList.Token memory t = reg.get(ID);
        assertEq(reg.total(), before_ + 1, "not listed");
        assertEq(t.name, "CELL Shares");
        assertEq(t.symbol, "CELL");
        assertEq(t.decimals, 18);
        assertEq(t.account, bytes32(uint256(uint160(CELL))));
        assertEq(t.chainId, 1);
        assertTrue(t.kind == TokenList.Kind.EVM, "kind not EVM");
        assertTrue(t.standard == TokenList.Standard.ERC20, "standard not ERC20");
        assertTrue(t.synced, "must claim onchain sync");
        assertEq(t.color, COLOR);
        assertEq(t.rank, RANK);
        assertEq(t.url, URL);
        assertTrue(t.logo.startsWith("data:image/svg+xml;base64,"), "logo not an inline data SVG");
        assertEq(t.description, DESC, "description was clipped or filtered");

        // Soulbound to its subject.
        assertEq(reg.ownerOf(ID), CELL, "card must be held by the token");

        // Tail of the list, and every rank strictly descending: a collision would
        // reorder the page silently, so it fails here instead.
        uint256[] memory ids = reg.rankedIds();
        assertEq(ids[ids.length - 1], ID, "not seated at the tail");
        for (uint256 i = 1; i < ids.length; ++i) {
            assertGt(reg.get(ids[i - 1]).rank, reg.get(ids[i]).rank, "rank collision");
        }
        emit log_named_uint("position", ids.length);

        // An EVM ERC-20, so unlike TAC it SHOULD reach the integrator feed.
        assertEq(_count(TokenListPage(PAGE).tokenListJson()), jsonBefore + 1, "missing from tokenlist.json");

        assertGt(bytes(reg.tokenURI(ID)).length, 0, "tokenURI empty");

        vm.prank(address(0xBAD));
        (bool ok2,) = REG.call(cd);
        assertFalse(ok2, "non-owner could list");
        emit log("guard: non-owner reverts");
    }

    function _count(string memory j) internal pure returns (uint256 n) {
        bytes memory b = bytes(j);
        for (uint256 i; i + 8 < b.length; ++i) {
            if (
                b[i] == '"' && b[i + 1] == 'c' && b[i + 2] == 'h' && b[i + 3] == 'a' && b[i + 4] == 'i'
                    && b[i + 5] == 'n' && b[i + 6] == 'I' && b[i + 7] == 'd'
            ) ++n;
        }
    }
}
