// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @dev ZorgConviction against the REAL Moloch share token rather than a mock.
///      Every other suite escrows `MockShares`, which has no transfer lock, no
///      ragequit, no vote checkpoints and no `onSharesChanged` callback - i.e.
///      none of the behaviour that produced findings C-01, H-03 and M-01 in
///      `audit/ZorgConviction/claude-opus-5.md`. Those fixes were verified
///      against a mock written to imitate Moloch; this is the same set of
///      assertions against Moloch itself.
import {Test} from "../lib/forge-std/src/Test.sol";
import {Moloch, Shares, Call} from "../src/dao/Moloch.sol";
import {ZorgConviction, IERC721Zorgz, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";
import {MockNFT, MockWeiNames} from "./ZorgConviction.t.sol";

contract ListedToken {
    function name() public pure returns (string memory) {
        return "Listed Token";
    }

    function symbol() public pure returns (string memory) {
        return "LIST";
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }
}

contract ZorgConvictionMolochTest is Test {
    address alice = address(0xA11CE);
    address curator = address(0xC0FFEE);
    address domainOwner = address(0xD0A1);

    Moloch moloch;
    Shares shares;
    MockNFT zorgz;
    MockWeiNames names;
    TokenList tokenList;
    ZorgConviction conviction;
    uint256 listingId;

    uint64 constant HALF_LIFE = 7 days;
    uint256 constant BOND = 100 ether;
    uint256 constant ETH_BOND = 0.1 ether;

    function setUp() public {
        moloch = new Moloch(); // this contract is the SUMMONER
        address[] memory holders = new address[](1);
        holders[0] = alice;
        uint256[] memory initShares = new uint256[](1);
        initShares[0] = BOND;
        moloch.init("Zorg", "ZORG", "", 5000, true, address(0), holders, initShares, new Call[](0));
        shares = moloch.shares();

        zorgz = new MockNFT();
        names = new MockWeiNames();
        names.mint(domainOwner, "zorg.wei");
        zorgz.mint(alice, 77, "data:image/svg+xml;base64,PHN2Zy8+");
        vm.deal(alice, 10 ether);

        tokenList = new TokenList(curator, new TokenListRenderer());
        ListedToken token = new ListedToken();
        vm.prank(curator);
        listingId = tokenList.list(address(token), 0x627EEA, 10, "", "https://example.com", "A listed token.");

        conviction = new ZorgConviction(
            address(moloch),
            address(shares),
            IERC721Zorgz(address(zorgz)),
            IWeiNames(address(names)),
            address(tokenList),
            new ZorgConvictionRenderer(new ZorgPageStyle()), new ZorgReceiptArt(),
            HALF_LIFE
        );

        vm.startPrank(alice);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), 77);
        vm.stopPrank();
    }

    function _bond() internal {
        vm.prank(alice);
        conviction.bondZorgz{value: ETH_BOND}(77, BOND);
    }

    function testBondAndUnbondRoundTripThroughRealShares() public {
        _bond();
        assertEq(shares.balanceOf(address(conviction)), BOND);
        assertEq(shares.balanceOf(alice), 0);
        assertEq(zorgz.ownerOf(77), address(conviction));

        vm.prank(alice);
        conviction.allocate(77, listingId, 60 ether);
        skip(HALF_LIFE);
        assertApproxEqAbs(conviction.convictionOf(listingId), 30 ether, 0.001 ether);

        vm.prank(alice);
        conviction.allocate(77, listingId, 0);
        vm.prank(alice);
        conviction.unbond(77);
        assertEq(shares.balanceOf(alice), BOND);
        assertEq(zorgz.ownerOf(77), alice);
    }

    /// C-01 against the real thing: `ragequit` is public, burns the caller's
    /// shares, and lives on the DAO rather than on the share token, so the
    /// address denylist never sees it. The balance invariant does.
    function testRealRagequitCannotEmptyTheEscrow() public {
        _bond();
        address[] memory tokens = new address[](1);
        tokens[0] = address(0); // ETH; the treasury is empty, so only the burn matters

        vm.prank(address(moloch));
        vm.expectRevert(ZorgConviction.EscrowReduced.selector);
        conviction.execute(address(moloch), 0, abi.encodeCall(Moloch.ragequit, (tokens, BOND, 0)));

        assertEq(shares.balanceOf(address(conviction)), BOND);
        vm.prank(alice);
        conviction.unbond(77);
        assertEq(shares.balanceOf(alice), BOND);
    }

    /// H-03: a locked share token has no exit, because Moloch's lock permits a
    /// transfer only when one side is the DAO and this governor is neither.
    /// The constructor refuses to deploy against one.
    function testConstructorRefusesLockedRealShares() public {
        vm.prank(address(moloch));
        moloch.setTransfersLocked(true, false);
        assertTrue(shares.transfersLocked());

        // Construct the renderer FIRST: a deployment inside the argument list is
        // the call `expectRevert` latches onto, not the one under test.
        ZorgConvictionRenderer renderer = new ZorgConvictionRenderer(new ZorgPageStyle());
        ZorgReceiptArt art = new ZorgReceiptArt();
        vm.expectRevert(ZorgConviction.SharesLocked.selector);
        new ZorgConviction(
            address(moloch),
            address(shares),
            IERC721Zorgz(address(zorgz)),
            IWeiNames(address(names)),
            address(tokenList),
            renderer, art,
            HALF_LIFE
        );
    }

    /// H-03, residual: the constructor cannot stop the DAO locking transfers
    /// AFTER bonds exist, and that still strands them. This asserts the exposure
    /// rather than a fix, so the trust assumption is visible in the suite and
    /// not only in the audit.
    function testLockingSharesAfterBondingStrandsTheEscrow() public {
        _bond();
        vm.prank(address(moloch));
        moloch.setTransfersLocked(true, false);

        vm.prank(alice);
        vm.expectRevert(); // Shares.Locked
        conviction.unbond(77);

        // ... and the DAO unlocking releases it again.
        vm.prank(address(moloch));
        moloch.setTransfersLocked(false, false);
        vm.prank(alice);
        conviction.unbond(77);
        assertEq(shares.balanceOf(alice), BOND);
    }

    /// M-01: bonded shares carry their Moloch voting power into the governor,
    /// which self-delegates and never votes on its own. Accepted, not fixed -
    /// asserted here so the consequence is explicit.
    function testBondingMovesMolochVotingPowerIntoTheGovernor() public {
        assertEq(shares.getVotes(alice), BOND);
        _bond();
        assertEq(shares.getVotes(alice), 0);
        assertEq(shares.getVotes(address(conviction)), BOND);
        assertEq(shares.totalSupply(), BOND); // still counted in the quorum basis

        vm.prank(alice);
        conviction.unbond(77);
        assertEq(shares.getVotes(alice), BOND);
        assertEq(shares.getVotes(address(conviction)), 0);
    }
}
