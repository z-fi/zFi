// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @dev Regression tests for the audit findings in
///      `audit/ZorgConviction/claude-opus-5.md`. Each one started as a proof of
///      concept asserting the defect and now asserts the fix, so the exact
///      failure it describes cannot come back unnoticed.
import {Test} from "../lib/forge-std/src/Test.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {ZorgConviction, IERC721Zorgz, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockNFT, MockWeiNames, MockTokenList} from "./ZorgConviction.t.sol";

/// @dev Moloch's share token burns from the caller on ragequit.
contract AuditShares is MockShares {
    bool public transfersLocked;

    function burn(address account, uint256 amount) external {
        balanceOf[account] -= amount;
    }

    function setTransfersLocked(bool locked) external {
        transfersLocked = locked;
    }
}

/// @dev Stands in for Moloch: a public `ragequit` that burns the CALLER's shares.
contract MockMolochRagequit {
    AuditShares public shares;

    constructor(AuditShares shares_) {
        shares = shares_;
    }

    function ragequit(uint256 sharesToBurn) external {
        shares.burn(msg.sender, sharesToBurn);
    }
}

contract ZorgConvictionAuditTest is Test {
    address proposer = address(0xB0B);
    address exec = address(0xE11C);
    address domainOwner = address(0xD0A1);

    AuditShares shares;
    MockNFT zorgz;
    MockWeiNames names;
    MockTokenList tokenList;
    ZorgConvictionRenderer renderer;
    ZorgConviction conviction;
    MockMolochRagequit dao;

    uint64 constant HALF_LIFE = 7 days;
    uint256 constant ETH_BOND = 0.1 ether;

    function setUp() public {
        shares = new AuditShares();
        zorgz = new MockNFT();
        names = new MockWeiNames();
        tokenList = new MockTokenList();
        renderer = new ZorgConvictionRenderer(new ZorgPageStyle());
        dao = new MockMolochRagequit(shares);
        names.mint(domainOwner, "zorg.wei");
        zorgz.mint(proposer, 77, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(proposer, 100 ether);
        vm.deal(proposer, 10 ether);
        tokenList.setListed(123, true);
        tokenList.setListed(456, true);
        conviction =
            new ZorgConviction(address(dao), address(shares), zorgz, names, address(tokenList), renderer, new ZorgReceiptArt(), HALF_LIFE);
        vm.startPrank(proposer);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), 77);
        conviction.bondZorgz{value: ETH_BOND}(77, 100 ether);
        vm.stopPrank();
    }

    function _installExec() internal {
        uint256 root = conviction.zorgWeiId();
        vm.prank(domainOwner);
        names.approve(address(conviction), root);
        vm.prank(domainOwner);
        conviction.claimZorgWei();
        vm.prank(address(dao));
        conviction.installExecRoleName(exec);
    }

    /// @dev The receipt has independent dynamic commitment and redemption
    ///      traits; a no-lock bond is open while still redeemable.
    function testCommitmentAndRedeemableTraitsAreDistinct() public view {
        string memory uri = conviction.tokenURI(77);
        string memory json = string(Base64.decode(LibString.slice(uri, 29)));
        assertTrue(LibString.contains(json, '{"trait_type":"Commitment","value":"open"}'));
        assertTrue(LibString.contains(json, '{"trait_type":"Redeemable","value":"yes"}'));
        assertTrue(LibString.contains(json, '"trait_type":"Bond age"'));
    }

    /// @dev The receipt image inverts its escrowed zOrgz so a custody receipt cannot
    ///      be mistaken for the asset. `filter:invert(1)` is a CSS filter function,
    ///      which standalone SVG rasterizers may ignore — and where it is ignored the
    ///      receipt renders identical to the unstaked NFT. The SVG filter primitive
    ///      needs no CSS engine.
    function testReceiptImageInvertsWithoutACssEngine() public view {
        string memory uri = conviction.tokenURI(77);
        string memory json = string(Base64.decode(LibString.slice(uri, 29)));
        uint256 at = LibString.indexOf(json, "data:image/svg+xml;base64,", 10);
        string memory svg = string(Base64.decode(LibString.slice(json, at + 26, LibString.indexOf(json, '"', at))));
        assertTrue(LibString.contains(svg, "<feFuncR type='table' tableValues='1 0'/>"));
        assertTrue(LibString.contains(svg, "filter='url(#i)'"));
        assertFalse(LibString.contains(svg, "filter:invert"));
    }

    /// C-01: `_execute` names the two escrowed assets, but Moloch's `ragequit`
    ///       is public and burns the CALLER's shares, so a call to the DAO
    ///       itself emptied the escrow without either forbidden target ever
    ///       appearing. The balance invariant catches it whatever the route.
    function testEscrowCannotBeBurnedThroughDaoRagequit() public {
        assertEq(shares.balanceOf(address(conviction)), 100 ether);
        vm.prank(address(dao));
        vm.expectRevert(ZorgConviction.EscrowReduced.selector);
        conviction.execute(address(dao), 0, abi.encodeCall(MockMolochRagequit.ragequit, (100 ether)));
        assertEq(shares.balanceOf(address(conviction)), 100 ether);

        vm.prank(proposer);
        conviction.unbond(77);
        assertEq(shares.balanceOf(proposer), 100 ether);
    }

    /// C-01b: and the emergency branch is held to the same invariant, so the
    ///        exec credential cannot pause itself into a drain either.
    function testExecCannotBurnEscrowThroughDao() public {
        _installExec();
        vm.prank(exec);
        conviction.emergencyPause();
        vm.prank(exec);
        vm.expectRevert(ZorgConviction.EscrowReduced.selector);
        conviction.emergencyExecute(address(dao), 0, abi.encodeCall(MockMolochRagequit.ragequit, (100 ether)));
        assertEq(shares.balanceOf(address(conviction)), 100 ether);
    }

    /// C-02: the credential is a transferable name, so the DAO cannot retire it
    ///       by holding it. `burnExecRole` is the switch that ends the role.
    function testDaoCanBurnTheExecRole() public {
        _installExec();
        vm.prank(address(dao));
        conviction.burnExecRole();
        vm.prank(exec);
        vm.expectRevert(ZorgConviction.Unauthorized.selector);
        conviction.emergencyPause();
    }

    /// H-01: `allocate` is the only way to REDUCE an allocation, so gating the
    ///       whole function on the pause turned an emergency stop into
    ///       confiscation. Only increases are gated now, and exit always works.
    function testPauseDoesNotTrapAllocatedBonds() public {
        vm.prank(proposer);
        conviction.allocate(77, 123, 50 ether);
        _installExec();
        vm.prank(exec);
        conviction.emergencyPause();

        // Adding support to a halted system is what a pause should stop.
        vm.prank(proposer);
        vm.expectRevert(ZorgConviction.Unauthorized.selector);
        conviction.allocate(77, 123, 100 ether);
        vm.prank(proposer);
        vm.expectRevert(ZorgConviction.Unauthorized.selector);
        conviction.increaseBond(77, 1);

        // Withdrawing it, and leaving, is not.
        vm.prank(proposer);
        conviction.allocate(77, 123, 0);
        vm.prank(proposer);
        conviction.unbond(77);
        assertEq(shares.balanceOf(proposer), 100 ether);
        assertEq(zorgz.ownerOf(77), proposer);
    }

    /// H-02: the `isListed` check applies to increases only. Delisting a token
    ///       is routine curation, and it used to trap every bond pointed at it.
    function testDelistingDoesNotTrapAllocatedBonds() public {
        vm.prank(proposer);
        conviction.allocate(77, 123, 100 ether);

        tokenList.setListed(123, false);

        vm.prank(proposer);
        vm.expectRevert(ZorgConviction.UnknownListing.selector);
        conviction.allocate(77, 123, 100 ether + 1); // no new support for a delisted id

        vm.prank(proposer);
        conviction.allocate(77, 123, 0); // but withdrawing it always works
        vm.prank(proposer);
        conviction.unbond(77);
        assertEq(zorgz.ownerOf(77), proposer);
    }

    /// H-03: a locked share token makes `unbond` impossible, so refuse to deploy
    ///       against one rather than escrow into a contract with no exit.
    function testDeploymentRefusesALockedShareToken() public {
        shares.setTransfersLocked(true);
        ZorgReceiptArt art = new ZorgReceiptArt();
        vm.expectRevert(ZorgConviction.SharesLocked.selector);
        new ZorgConviction(address(dao), address(shares), zorgz, names, address(tokenList), renderer, art, HALF_LIFE);
    }

    /// L-02: `increaseBond` had no counterpart, so any partial recovery meant a
    ///       full exit. A bond can now be trimmed down to what it has allocated.
    function testBondCanBePartiallyWithdrawn() public {
        vm.prank(proposer);
        conviction.allocate(77, 123, 60 ether);

        // `decreaseBond` now also honours the ETH maturity, so that a top-up
        // cannot be withdrawn the moment it has captured an early-exit tax.
        // Serve the term before testing the allocation floor.
        (,,,, uint64 maturityAt,,,) = conviction.ethBonds(77);
        vm.warp(maturityAt);

        vm.prank(proposer);
        vm.expectRevert(ZorgConviction.AllocationExceeded.selector);
        conviction.decreaseBond(77, 41 ether);

        vm.prank(proposer);
        conviction.decreaseBond(77, 40 ether);
        assertEq(conviction.bondedWeight(77), 60 ether);
        assertEq(shares.balanceOf(proposer), 40 ether);
        assertEq(conviction.availableBondWeight(77), 0);
    }

    /// M-02: halving composes exactly, so accrual depends only on total elapsed
    ///       time. Poking a listing once a block no longer buys anything.
    function testConvictionIsNotInflatableByPokingAccrual() public {
        vm.startPrank(proposer);
        conviction.allocate(77, 123, 50 ether);
        conviction.allocate(77, 456, 50 ether);
        vm.stopPrank();

        for (uint256 i; i < 14; ++i) {
            skip(HALF_LIFE / 14);
            vm.prank(proposer);
            conviction.allocate(77, 123, 50 ether); // no-op write, accrues 123 only
        }

        assertApproxEqAbs(conviction.convictionOf(123), conviction.convictionOf(456), 1e6);
        assertApproxEqAbs(conviction.convictionOf(456), 25 ether, 0.001 ether); // half the gap, once
    }

    /// M-03: a fresh placement is visible as live support immediately, but it
    ///       has earned no conviction yet. The two values stay distinct so a
    ///       TokenList can be responsive without pretending new support is
    ///       already time-tested.
    function testFreshAllocationHasLiveSupportButNoConviction() public {
        vm.prank(proposer);
        conviction.allocate(77, 123, 100 ether);
        assertEq(conviction.convictionOf(123), 0); // zero seconds held
        assertEq(conviction.supportOf(123), 100 ether);

        skip(HALF_LIFE);
        assertApproxEqAbs(conviction.convictionOf(123), 50 ether, 0.001 ether);
        assertApproxEqAbs(conviction.supportOf(123), 150 ether, 0.001 ether);
        skip(HALF_LIFE);
        assertApproxEqAbs(conviction.convictionOf(123), 75 ether, 0.001 ether);
    }
}
