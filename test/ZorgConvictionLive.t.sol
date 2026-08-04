// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction, IERC721Zorgz, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {ZorgTokenListLens, IConvictionScores, ITokenListSource} from "../src/dao/ZorgTokenListLens.sol";

/// @notice Deployment readiness for `ZorgConviction`, against the REAL mainnet
///         contracts it will be wired to rather than mocks.
///
/// @dev The suites that already exist run on a fork pinned BEFORE `TokenList` was
///      deployed, so they necessarily use a locally-deployed registry. That proves
///      the logic and cannot prove the wiring: whether the live registry answers the
///      calls this system makes, whether the DAO's share token is the one being
///      bonded, and whether the constructor accepts the real addresses. Those are
///      exactly the questions a deployment gets wrong, so they get their own fork,
///      pinned after the registry existed.
contract ZorgConvictionLiveTest is Test {
    // Live mainnet, all verified before use.
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;
    address constant SHARES = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12; // zOrg ERC-20 votes
    address constant ZORGZ = 0x00000000008835ceF3E0D2333695f288Ee6b63A6;
    address constant WNS = 0x0000000000696760E15f265e828DB644A0c242EB;
    address constant TOKENLIST = 0x0000006013dF75A31678B786061C2B54bf531524;

    uint64 constant HALF_LIFE = 3 days;

    function setUp() public {
        // After TokenList's deployment at 25,675,344 — the whole point of this suite.
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_678_000);
    }

    function _deploy() internal returns (ZorgConviction c, ZorgTokenListLens lens) {
        c = new ZorgConviction(
            DAO,
            SHARES,
            IERC721Zorgz(ZORGZ),
            IWeiNames(WNS),
            TOKENLIST,
            new ZorgConvictionRenderer(new ZorgPageStyle()),
            new ZorgReceiptArt(),
            HALF_LIFE
        );
        lens = new ZorgTokenListLens(ITokenListSource(TOKENLIST), IConvictionScores(address(c)));
    }

    /// @dev The one thing a local-registry test cannot check: that the DAO whose
    ///      shares are bonded is the DAO that issued the token being bonded. Wiring
    ///      a conviction system to a share token some other DAO controls would let
    ///      that DAO's holders rank this list.
    function testDaoSharesAreTheTokenBeingBonded() public view {
        (bool ok, bytes memory ret) = DAO.staticcall(abi.encodeWithSignature("shares()"));
        assertTrue(ok && ret.length == 32, "DAO answers shares()");
        assertEq(abi.decode(ret, (address)), SHARES, "the DAO issues the shares being bonded");
    }

    /// @dev The constructor refuses a share token whose transfers are locked (H-03).
    ///      Assert the live token actually passes that gate rather than assuming it.
    function testLiveSharesPassTheTransferLockGate() public view {
        (bool ok, bytes memory ret) = SHARES.staticcall(abi.encodeWithSignature("transfersLocked()"));
        assertTrue(ok, "shares answer transfersLocked()");
        assertFalse(abi.decode(ret, (bool)), "a locked share token would revert the constructor");
    }

    function testConstructsAgainstEveryLiveAddress() public {
        (ZorgConviction c,) = _deploy();
        assertEq(c.dao(), DAO);
        assertEq(address(c.tokenList()), TOKENLIST);
        assertEq(c.halfLife(), HALF_LIFE);
    }

    /// @dev The lens reads the live registry through its own ABI-shaped struct. A
    ///      field-order mismatch would decode silently into garbage rather than
    ///      revert, so assert against values the live list actually holds.
    function testLensDecodesTheLiveRegistry() public {
        (, ZorgTokenListLens lens) = _deploy();
        uint256[] memory ids = lens.rankedIds();
        assertEq(ids.length, 11, "the live list has eleven entries");
        // id 0 is the native asset by the registry's identity rule.
        assertEq(ids[0], 0, "ETH leads on zero conviction, i.e. curated order");
        assertEq(lens.get(ids[1]).symbol, "WETH");
        assertEq(lens.get(ids[1]).decimals, 18);
    }

    /// @dev Day one: nothing is bonded, so the lens must reproduce the curator's
    ///      ordering exactly. If it does not, conviction is silently reordering a
    ///      list nobody has voted on.
    function testZeroConvictionPreservesCuratedOrderExactly() public {
        (, ZorgTokenListLens lens) = _deploy();
        (bool ok, bytes memory ret) = TOKENLIST.staticcall(abi.encodeWithSignature("rankedIds()"));
        assertTrue(ok);
        uint256[] memory curated = abi.decode(ret, (uint256[]));
        uint256[] memory viaLens = lens.rankedIds();
        assertEq(viaLens.length, curated.length);
        for (uint256 i; i < curated.length; ++i) {
            assertEq(viaLens[i], curated[i], "lens must not reorder an unvoted list");
        }
    }

    /// @dev Conviction permutes; it cannot expand. Whatever the scores, the lens can
    ///      only ever return ids the registry already lists.
    function testLensOutputIsAlwaysASubsetOfTheCuratedList() public {
        (, ZorgTokenListLens lens) = _deploy();
        (, bytes memory ret) = TOKENLIST.staticcall(abi.encodeWithSignature("rankedIds()"));
        uint256[] memory curated = abi.decode(ret, (uint256[]));
        uint256[] memory viaLens = lens.rankedIds();
        for (uint256 i; i < viaLens.length; ++i) {
            bool found;
            for (uint256 j; j < curated.length; ++j) {
                if (viaLens[i] == curated[j]) found = true;
            }
            assertTrue(found, "lens surfaced an id the registry does not list");
        }
    }

    /// @dev The registry is never written to. Its curated weights must be identical
    ///      before and after the conviction system exists.
    function testDeployingConvictionDoesNotTouchTheRegistry() public {
        (, bytes memory before_) = TOKENLIST.staticcall(abi.encodeWithSignature("rankedIds()"));
        _deploy();
        (, bytes memory after_) = TOKENLIST.staticcall(abi.encodeWithSignature("rankedIds()"));
        assertEq(keccak256(before_), keccak256(after_), "the registry's order must be untouched");
    }
}
