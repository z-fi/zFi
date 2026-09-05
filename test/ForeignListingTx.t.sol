// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {TokenList} from "../src/utils/TokenList.sol";

/// @notice Replays a `build-foreign-listing.mjs` batch against the REAL registry on a
///         mainnet fork, as the owner, and reads every listing back the way zSwap will.
///
/// @dev The batch is whichever file FOREIGN_LISTING names (default: the Base
///      equivalents batch). The assertions are the page's own filter: each new
///      listing must render as `k=eip155`, `c=<chain>`, `p=ERC-20`, carry decimals
///      that agree with the token on its own chain (checked by the generator), and
///      be reachable by the id the generator printed. Idempotent: a batch already
///      applied on chain is skipped rather than failed.
contract ForeignListingTxTest is Test {
    address constant REG = 0x0000006013dF75A31678B786061C2B54bf531524;
    address constant SAFE = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;
    uint256 constant FOREIGN_FLAG = 1 << 255;

    function test_ReplayBatch() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")));
        string memory file = vm.envOr("FOREIGN_LISTING", string("./deploy/BASE-list.calldata.txt"));
        bytes memory cd = vm.parseBytes(vm.replace(vm.readFile(file), "\n", ""));
        assertEq(bytes4(cd), bytes4(0xac9650d8), "not a multicall");
        TokenList reg = TokenList(payable(REG));

        // The listings this batch creates are the `listForeign` calls inside it.
        (uint64 chainId, bytes32[] memory accounts, uint8[] memory decs) = _listings(cd);
        assertGt(accounts.length, 0, "batch lists nothing");
        uint256 id0 = reg.idOf(TokenList.Kind.EVM, chainId, accounts[0]);
        if (reg.isListed(id0)) {
            emit log("already listed - skipped");
            return;
        }

        uint256 before_ = reg.total();
        uint256 g = gasleft();
        vm.prank(SAFE);
        (bool ok,) = REG.call(cd);
        emit log_named_uint("gas used", g - gasleft());
        assertTrue(ok, "multicall reverted");
        assertEq(reg.total(), before_ + accounts.length, "listing count");

        for (uint256 i; i < accounts.length; ++i) {
            uint256 id = reg.idOf(TokenList.Kind.EVM, chainId, accounts[i]);
            assertTrue(id & FOREIGN_FLAG != 0, "foreign flag");
            TokenList.Token memory t = reg.get(id);
            assertEq(t.chainId, chainId, "chain id");
            assertTrue(t.kind == TokenList.Kind.EVM, "kind");
            assertTrue(t.standard == TokenList.Standard.ERC20, "standard must be ERC20 or the page drops it");
            assertEq(t.decimals, decs[i], "decimals");
            assertFalse(t.synced, "foreign listings are owner-attested, never synced");
            assertGt(bytes(t.symbol).length, 0, "symbol");
            string memory js = reg.json(id);
            assertTrue(_has(js, '"k":"eip155"'), "json namespace");
            assertTrue(_has(js, string.concat('"c":', vm.toString(uint256(chainId)))), "json chain");
            assertTrue(_has(js, '"p":"ERC-20"'), "json standard");
            assertTrue(_has(js, string.concat('"a":"', _hex20(accounts[i]), '"')), "json account is the token");
            emit log_named_string("listed", string.concat(t.symbol, " ", bytes(js).length > 120 ? "ok" : js));
        }
    }

    /// @dev Walks the multicall's inner calls and pulls (chainId, account, decimals)
    ///      out of every `listForeign` (selector of the 9-arg signature).
    function _listings(bytes memory cd)
        internal
        pure
        returns (uint64 chainId, bytes32[] memory accounts, uint8[] memory decs)
    {
        bytes memory body = new bytes(cd.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = cd[i + 4];
        bytes[] memory calls = abi.decode(body, (bytes[]));
        bytes4 sel = TokenList.listForeign.selector;
        uint256 n;
        for (uint256 i; i < calls.length; ++i) if (bytes4(calls[i]) == sel) ++n;
        accounts = new bytes32[](n);
        decs = new uint8[](n);
        uint256 k;
        for (uint256 i; i < calls.length; ++i) {
            if (bytes4(calls[i]) != sel) continue;
            bytes memory args = new bytes(calls[i].length - 4);
            for (uint256 j; j < args.length; ++j) args[j] = calls[i][j + 4];
            (, uint64 cid, bytes32 account,,, uint8 d,,,) =
                abi.decode(args, (uint8, uint64, bytes32, string, string, uint8, uint24, uint32, string));
            if (k == 0) chainId = cid;
            else require(cid == chainId, "mixed chains in one batch");
            accounts[k] = account;
            decs[k] = d;
            ++k;
        }
    }

    function _hex20(bytes32 account) internal pure returns (string memory) {
        bytes memory h = "0123456789abcdef";
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i; i < 20; ++i) {
            uint8 b = uint8(account[12 + i]);
            out[2 + i * 2] = h[b >> 4];
            out[3 + i * 2] = h[b & 15];
        }
        return string(out);
    }

    function _has(string memory s, string memory needle) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(needle);
        if (b.length > a.length) return false;
        for (uint256 i; i + b.length <= a.length; ++i) {
            bool hit = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
