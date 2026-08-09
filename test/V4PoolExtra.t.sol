// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {V4Port, PoolKey} from "../src/forwarders/V4Port.sol";

interface ITokenList {
    function owner() external view returns (address);
    function idOf(address) external view returns (uint256);
    function setExtra(uint256 id, bytes32 key, string calldata value) external;
    function json(uint256 id) external view returns (string memory);
    function extraKeys(uint256 id) external view returns (bytes32[] memory);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

/// @notice The v4 pool key travels in the token list, not in a new contract.
///
/// zSwap's UI is permanent bytecode, so a pool key baked into the page means a
/// page redeploy for every new hooked pool - and log-scan discovery is not an
/// option either: full-range `eth_getLogs` is refused by every free RPC a
/// browser is likely to be pointed at. What is left is an onchain list read in
/// one `eth_call`, and `TokenList` already is one: it carries open-ended
/// per-listing extras, it is DAO-owned, and `json(id)` emits them as `"e"` -
/// which the page already fetches for every token.
///
/// @dev THE RISK THIS TEST EXISTS FOR. The value goes in as a string and comes
///      back out through a renderer that escapes what it emits. If that
///      escaping touched the value, the page would parse a mangled key and
///      route into a pool that does not exist. So the assertion is not "the
///      write succeeded" - it is that the exact bytes survive the round trip
///      through `json`, and that the key they spell still trades.
contract V4PoolExtraTest is Test {
    address constant TOKENLIST = 0x0000006013dF75A31678B786061C2B54bf531524;
    address constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address constant HOOK = 0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444;
    address constant PORT = 0x000000dfb53Fa7f1c486470034741d5BCBE14BE9;

    /// @dev keccak256("zfi.v4pool")
    bytes32 constant KEY = 0x95a932c205571d4d1ca72715c642a2eca21dde79ffc28ff11509681f9383385f;

    string constant VALUE =
        "v1:0x0000000000000000000000000000000000000000:0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845:0:60:0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444";

    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        vm.deal(user, 10 ether);
    }

    function test_theKeySurvivesTheRoundTripThroughJson() public {
        uint256 id = ITokenList(TOKENLIST).idOf(FWA);
        address owner = ITokenList(TOKENLIST).owner();

        assertEq(ITokenList(TOKENLIST).extraKeys(id).length, 0, "no extras on FWA today");

        vm.prank(owner);
        ITokenList(TOKENLIST).setExtra(id, KEY, VALUE);

        bytes32[] memory keys = ITokenList(TOKENLIST).extraKeys(id);
        assertEq(keys.length, 1, "one extra now");
        assertEq(keys[0], KEY, "under the key the page looks for");

        // The whole point: the value is in the JSON the page already loads, and
        // it is byte-identical to what went in.
        string memory blob = ITokenList(TOKENLIST).json(id);
        assertTrue(_contains(blob, VALUE), "the pool key survives the renderer verbatim");
        assertTrue(_contains(blob, '"e":'), "and arrives in the extras field");
    }

    /// And the key it spells is a pool that actually trades - so the page can
    /// go straight from a token list entry to a working route with nothing
    /// else configured anywhere.
    function test_theKeyItSpellsIsATradeablePool() public {
        uint256 id = ITokenList(TOKENLIST).idOf(FWA);
        vm.prank(ITokenList(TOKENLIST).owner());
        ITokenList(TOKENLIST).setExtra(id, KEY, VALUE);

        // Parsed out of the string above, exactly as the page will parse it.
        PoolKey memory key = PoolKey(address(0), FWA, 0, 60, HOOK);

        uint256 before = IERC20(FWA).balanceOf(user);
        vm.prank(user);
        uint256 out = V4Port(payable(PORT)).swap{value: 0.01 ether}(
            key, true, 0.01 ether, 1, user, block.timestamp + 300
        );

        assertGt(out, 0, "the listed pool trades");
        assertEq(IERC20(FWA).balanceOf(user) - before, out, "through the live port, to the user");
    }

    function test_onlyTheListOwnerCanPublishAPoolKey() public {
        uint256 id = ITokenList(TOKENLIST).idOf(FWA);
        vm.prank(user);
        vm.expectRevert();
        ITokenList(TOKENLIST).setExtra(id, KEY, VALUE);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
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
