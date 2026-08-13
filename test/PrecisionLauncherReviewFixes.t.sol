// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";
import {PrecisionLauncherLens} from "../src/pools/PrecisionLauncherLens.sol";

/// @dev Coverage for everything added in response to the external review.
///
/// Those changes were the least-tested code in the repo the moment they landed,
/// which is the wrong place for that to be true: `acceptCreator` guards a
/// permanent income stream, `MIN_POOLED` is a new revert path, and `allocBps` /
/// `fullyDilutedWei` were added precisely BECAUSE the allocation was invisible -
/// a field that lies is worse than one that is missing, since a reader who had
/// to compute it themselves would at least have got it right.
///
/// One of the review's findings (L-1) was a wedge inside the fix for an earlier
/// wedge. Fixes deserve the same scrutiny as the code they fix, and this file
/// is that scrutiny.
contract PrecisionLauncherReviewFixesTest is Test {
    PrecisionPoolFactory factory;
    PrecisionLauncher launcher;
    PrecisionLauncherLens lens;

    address creator = address(0xC0FFEE);
    address next = address(0xBEEF);
    address alice = address(0xA11CE);
    address treasury = address(0x7EA);

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant MCAP = 3 ether;
    // Mirrors of PrecisionLauncher's internal constants. Spelled out rather
    // than inlined: these two tests previously hardcoded 1e12 for the pooled
    // floor, which is MIN_START_MCAP's value, not MIN_POOLED's.
    uint256 constant MIN_POOLED = 2e12;
    uint256 constant MIN_START_MCAP = 1e12;
    uint256 constant MAX_ALLOC_BPS = 2_000;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        launcher = new PrecisionLauncher(factory, treasury);
        lens = new PrecisionLauncherLens(launcher);
        vm.deal(alice, 10_000 ether);
    }

    function _launch(uint256 allocBps) internal returns (LaunchToken token, PrecisionPool pool) {
        (address t, address p) = launcher.launch("R", "R", "", SUPPLY, allocBps, MCAP, creator);
        (token, pool) = (LaunchToken(t), PrecisionPool(payable(p)));
    }

    // ------------------------------------------------------- I-2: VISIBILITY

    /// The stored allocation must match what the creator actually received,
    /// across the whole admitted range.
    function testAllocationIsRecordedAndMatchesWhatWasPaid() public {
        uint256[3] memory bps = [uint256(0), 1_000, 2_000];
        for (uint256 i; i < bps.length; ++i) {
            (LaunchToken token,) = _launch(bps[i]);
            assertEq(launcher.allocBpsOf(address(token)), bps[i], "stored allocation wrong");
            assertEq(token.balanceOf(creator), SUPPLY * bps[i] / 10_000, "paid allocation disagrees with stored");
            assertEq(lens.infoFor(address(token)).allocBps, bps[i], "lens disagrees with the launcher");
        }
    }

    /// An unlaunched token must read zero rather than someone else's number.
    function testAllocationOfAnUnknownTokenIsZero() public view {
        assertEq(launcher.allocBpsOf(address(0xDEAD)), 0);
        assertEq(lens.infoFor(address(0xDEAD)).allocBps, 0);
    }

    /// `fullyDilutedWei` must actually be fully diluted - the whole point of
    /// adding it is that `startMcapWei` values only the POOLED supply, so a
    /// reader who conflates them understates dilution by exactly the
    /// allocation. Prove the two differ by that ratio and not by accident.
    function testFullyDilutedExceedsTheLaunchValuationByTheAllocation() public {
        (LaunchToken token,) = _launch(2_000);

        PrecisionLauncherLens.LaunchInfo memory o = lens.infoFor(address(token));

        // Definitionally: supply * marginal price.
        assertEq(
            o.fullyDilutedWei, o.totalSupply * o.marketPrice / 1e18, "fullyDilutedWei is not supply x market price"
        );

        // At the open, the pooled supply is worth `MCAP`, so the whole supply
        // is worth MCAP / (1 - alloc) = MCAP * 10000/8000 = 1.25x.
        assertApproxEqRel(o.fullyDilutedWei, MCAP * 10_000 / 8_000, 0.001e18, "dilution not reflected");
        assertGt(o.fullyDilutedWei, MCAP, "fully diluted did not exceed the pooled valuation");
    }

    /// With no allocation the two must coincide, which is the control for the
    /// test above.
    function testFullyDilutedEqualsTheLaunchValuationWithNoAllocation() public {
        (LaunchToken token,) = _launch(0);
        assertApproxEqRel(lens.infoFor(address(token)).fullyDilutedWei, MCAP, 0.001e18, "no-allocation case drifted");
    }

    // ------------------------------------------------------- L-2: THE HANDOFF

    /// The offer must not move anything until it is accepted - including the
    /// fee stream, which must keep paying the incumbent in the meantime.
    function testPendingHandoffDoesNotDivertFeesBeforeAcceptance() public {
        (LaunchToken token, PrecisionPool pool) = _launch(0);
        vm.prank(alice);
        pool.swapExactIn{value: 20 ether}(address(0), 20 ether, 0, alice);

        vm.prank(creator);
        launcher.setCreator(address(token), next);

        assertEq(launcher.creatorOf(address(token)), creator, "offer moved the stream");
        assertEq(launcher.pendingCreatorOf(address(token)), next);

        uint256 creatorBefore = creator.balance;
        uint256 nextBefore = next.balance;
        (uint256 creatorEth,,,,) = launcher.collectFees(address(token));

        assertEq(creator.balance - creatorBefore, creatorEth, "incumbent was not paid while an offer was pending");
        assertEq(next.balance, nextBefore, "pending creator was paid before accepting");
    }

    /// Only the named destination may accept, and only once.
    function testOnlyTheNamedDestinationMayAcceptAndOnlyOnce() public {
        (LaunchToken token,) = _launch(0);

        vm.prank(creator);
        launcher.setCreator(address(token), next);

        vm.prank(alice);
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.acceptCreator(address(token));

        // The incumbent cannot accept on the destination's behalf either.
        vm.prank(creator);
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.acceptCreator(address(token));

        vm.prank(next);
        launcher.acceptCreator(address(token));
        assertEq(launcher.creatorOf(address(token)), next);

        // A second acceptance has nothing to consume.
        vm.prank(next);
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.acceptCreator(address(token));
    }

    /// An offer must be replaceable and cancellable while it is outstanding -
    /// otherwise a mistyped destination is only half-fixed by two steps.
    function testAnOfferCanBeReplacedAndCancelled() public {
        (LaunchToken token,) = _launch(0);

        vm.startPrank(creator);
        launcher.setCreator(address(token), address(0xDEAD)); // the typo
        launcher.setCreator(address(token), next); // corrected
        vm.stopPrank();
        assertEq(launcher.pendingCreatorOf(address(token)), next, "offer not replaced");

        // The superseded destination cannot accept.
        vm.prank(address(0xDEAD));
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.acceptCreator(address(token));

        // Cancelling with zero closes it entirely.
        vm.prank(creator);
        launcher.setCreator(address(token), address(0));
        vm.prank(next);
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.acceptCreator(address(token));
        assertEq(launcher.creatorOf(address(token)), creator, "cancelling moved the stream");
    }

    /// After a completed handoff the old holder has no authority left, and the
    /// new one has all of it.
    function testAuthorityFullyTransfersOnAcceptance() public {
        (LaunchToken token,) = _launch(0);

        vm.prank(creator);
        launcher.setCreator(address(token), next);
        vm.prank(next);
        launcher.acceptCreator(address(token));

        vm.prank(creator);
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.setCreator(address(token), creator);

        vm.prank(next);
        launcher.setCreator(address(token), alice);
        assertEq(launcher.pendingCreatorOf(address(token)), alice, "new holder cannot offer");
    }

    /// The handoff must not reach a token this launcher never launched, whoever
    /// calls it.
    function testHandoffCannotTouchAnUnlaunchedToken() public {
        vm.prank(address(0));
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.setCreator(address(0xDEAD), alice);

        vm.prank(alice);
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.acceptCreator(address(0xDEAD));
    }

    // -------------------------------------------------------- BATCH SWEEPING

    /// The DAO takes a share of EVERY launch, so collection has to scale past
    /// one transaction per token.
    function testBatchSweepCollectsAcrossLaunches() public {
        address[] memory tokens = new address[](3);
        for (uint256 i; i < 3; ++i) {
            (LaunchToken tk, PrecisionPool pl) = _launch(0);
            tokens[i] = address(tk);
            vm.prank(alice);
            pl.swapExactIn{value: 10 ether}(address(0), 10 ether, 0, alice);
        }

        uint256 treasuryBefore = treasury.balance;
        uint256 creatorBefore = creator.balance;

        // Permissionless: a stranger may sweep, and is paid nothing for it.
        uint256 strangerBefore = address(0xDEAD).balance;
        vm.prank(address(0xDEAD));
        (uint256 swept, uint256 creatorEth, uint256 protocolEth,,, bool allRecorded) =
            launcher.collectFeesMany(tokens);
        assertTrue(allRecorded, "a burn record was missed");

        assertEq(swept, 3, "not every launch was swept");
        assertEq(address(0xDEAD).balance, strangerBefore, "the sweeper was paid");
        assertEq(treasury.balance - treasuryBefore, protocolEth, "treasury underpaid");
        assertEq(creator.balance - creatorBefore, creatorEth, "creator underpaid");
        assertGt(protocolEth, 0);
    }

    /// A bad entry must not cost the caller the whole batch - otherwise they
    /// have to bisect to find which one, and the convenience is worthless.
    function testBatchSweepSkipsBadEntriesInsteadOfReverting() public {
        (LaunchToken good, PrecisionPool pool) = _launch(0);
        vm.prank(alice);
        pool.swapExactIn{value: 10 ether}(address(0), 10 ether, 0, alice);

        address[] memory tokens = new address[](4);
        tokens[0] = address(0xDEAD); // never launched
        tokens[1] = address(good);
        tokens[2] = address(good); // duplicate - second sweep finds nothing
        tokens[3] = address(0); // zero

        uint256 treasuryBefore = treasury.balance;
        (uint256 swept,, uint256 protocolEth,,,) = launcher.collectFeesMany(tokens);

        // The duplicate still "sweeps" - it simply collects zero - so what is
        // asserted is that the two unlaunched entries were skipped and the real
        // one paid exactly once.
        assertEq(swept, 2, "unlaunched entries were not skipped");
        assertGt(protocolEth, 0, "the valid entry did not pay");
        assertEq(treasury.balance - treasuryBefore, protocolEth, "treasury payment disagrees");

        // Nothing is left behind: a follow-up sweep finds an empty stream.
        (,, uint256 again,,,) = launcher.collectFeesMany(tokens);
        assertEq(again, 0, "fees survived the batch");
    }

    /// An empty batch is a no-op rather than a revert.
    function testBatchSweepOfNothingIsANoOp() public {
        (uint256 swept,,,,, bool allRecorded) = launcher.collectFeesMany(new address[](0));
        assertTrue(allRecorded, "an empty batch reported a missed record");
        assertEq(swept, 0);
    }

    // -------------------------------------------------------- I-1: MIN_POOLED

    /// The token side of the pool's resolution floor is a property of SUPPLY.
    /// Below it the launch must fail HERE, with a stated reason, rather than
    /// inside `_seed`.
    function testSupplyFloorIsEnforcedAndIndependentOfValuation() public {
        uint256[3] memory caps = [uint256(1e12), 3 ether, 1_000 ether];
        for (uint256 i; i < caps.length; ++i) {
            vm.expectRevert(PrecisionLauncher.Bad.selector);
            launcher.launch("S", "S", "", MIN_POOLED - 1, 0, caps[i], creator);
        }
        // The boundary itself launches, at the lowest valuation the launcher
        // will take - which is the "independent of valuation" half of the name.
        launcher.launch("S", "S", "", MIN_POOLED, 0, MIN_START_MCAP, creator);
    }

    /// The floor applies to the POOLED remainder, not the headline supply, so
    /// an allocation can push an otherwise-valid supply under it.
    function testTheFloorAppliesAfterTheAllocationIsTakenOut() public {
        // MAX_ALLOC_BPS of 2.4e12 leaves 1.92e12 pooled - under the floor,
        // though the headline supply clears it.
        uint256 supply = 24e11;
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.launch("S", "S", "", supply, MAX_ALLOC_BPS, MCAP, creator);

        // The same supply with no allocation is fine.
        launcher.launch("S", "S", "", supply, 0, MCAP, creator);
    }
}
