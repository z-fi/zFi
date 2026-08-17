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

    /// @dev COMPACT ON PURPOSE. `TokenList.EXTRA_MAX` is 256 characters and
    ///      `setExtra` TRUNCATES past it rather than reverting - a longer value
    ///      is stored sheared, and a pool key cut mid-address routes nowhere.
    ///      So the encoding spends that budget carefully:
    ///
    ///        v1 : other : fee : tickSpacing : hooks
    ///
    ///      `other` is the currency paired against the LISTED token - `0` for
    ///      native ETH - and the token itself is not repeated, because the
    ///      entry is already on its listing. The page sorts the two addresses
    ///      to recover currency0/currency1, which is what v4 requires anyway.
    ///      `hooks` is `0` when the pool has none.
    ///
    ///      51 characters instead of 141, so four pools fit where one did.
    string constant VALUE = "v1:0:0:60:0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444";

    /// @dev A second, hypothetical pool for the same token - a different fee
    ///      tier with no hook. Only used to prove the list form parses; it is
    ///      not published anywhere.
    string constant SECOND = "v1:0:3000:60:0";

    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        vm.deal(user, 10 ether);
    }

    function test_theKeySurvivesTheRoundTripThroughJson() public {
        uint256 id = ITokenList(TOKENLIST).idOf(FWA);
        address owner = ITokenList(TOKENLIST).owner();

        // Published for real at this point, so assert the LIVE value rather
        // than writing one and reading it back - which would have passed just
        // as happily against a chain where nothing was ever published.
        bytes32[] memory live = ITokenList(TOKENLIST).extraKeys(id);
        assertEq(live.length, 1, "FWA carries exactly one extra");
        assertEq(live[0], KEY, "and it is the pool key");
        assertTrue(
            _contains(ITokenList(TOKENLIST).json(id), VALUE),
            "the published value is the compact key, whole and untruncated"
        );

        // Rewriting it is idempotent, which is what makes a later append safe.
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

    /// The value is a LIST, and today's single entry is a one-element one.
    /// A token gains pools - another fee tier, another hook, a USDC pair - and
    /// the page must be able to compare them rather than the listing having to
    /// overwrite the only pool it can name. Proven on the real list so the
    /// format is settled before anything is written to mainnet under it.
    function test_severalPoolsFitInOneEntry() public {
        uint256 id = ITokenList(TOKENLIST).idOf(FWA);
        string memory two = string.concat(VALUE, ";", SECOND);

        vm.prank(ITokenList(TOKENLIST).owner());
        ITokenList(TOKENLIST).setExtra(id, KEY, two);

        string memory blob = ITokenList(TOKENLIST).json(id);
        assertTrue(_contains(blob, VALUE), "the first pool survives");
        assertTrue(_contains(blob, SECOND), "and so does the second");
        assertTrue(_contains(blob, ";"), "separated, in one field");
        assertEq(ITokenList(TOKENLIST).extraKeys(id).length, 1, "still one key, not one per pool");
        assertLt(bytes(two).length, 256, "and well inside the cap that truncates");
    }

    /// Appending must not disturb what is already published - the second pool
    /// is added by rewriting the field, so the first has to come back intact.
    function test_appendingAPoolKeepsTheFirstExactly() public {
        uint256 id = ITokenList(TOKENLIST).idOf(FWA);
        address owner = ITokenList(TOKENLIST).owner();

        vm.prank(owner);
        ITokenList(TOKENLIST).setExtra(id, KEY, VALUE);
        vm.prank(owner);
        ITokenList(TOKENLIST).setExtra(id, KEY, string.concat(VALUE, ";", SECOND));

        assertTrue(_contains(ITokenList(TOKENLIST).json(id), VALUE), "first pool unchanged");
    }

    /// The cap is silent, so it gets its own test rather than a comment. A
    /// value past 256 characters is STORED TRUNCATED - no revert, no event
    /// saying so - which for a pool key means an address cut in half and a
    /// route to nowhere. Four of the compact specs still fit.
    function test_theSilentTruncationCapIsRespected() public {
        uint256 id = ITokenList(TOKENLIST).idOf(FWA);
        string memory four =
            string.concat(VALUE, ";", SECOND, ";", VALUE, ";", SECOND);
        assertLt(bytes(four).length, 256, "four pools fit in the budget");

        vm.prank(ITokenList(TOKENLIST).owner());
        ITokenList(TOKENLIST).setExtra(id, KEY, four);
        assertTrue(_contains(ITokenList(TOKENLIST).json(id), four), "and survive whole");

        // The old verbose encoding did not, which is why it was abandoned.
        string memory verbose = string.concat(
            "v1:0x0000000000000000000000000000000000000000:0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845:0:60:0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444;",
            "v1:0x0000000000000000000000000000000000000000:0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845:3000:60:0x0000000000000000000000000000000000000000"
        );
        assertGt(bytes(verbose).length, 256, "two verbose specs overflow");
        vm.prank(ITokenList(TOKENLIST).owner());
        ITokenList(TOKENLIST).setExtra(id, KEY, verbose);
        assertFalse(
            _contains(ITokenList(TOKENLIST).json(id), verbose),
            "and come back sheared, silently - the reason for the compact form"
        );
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
