// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Fwabol} from "../src/forwarders/Fwabol.sol";
import {V4QuoteLens, PoolKey} from "../src/V4QuoteLens.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Fwabol against the real pool, on a fork pinned to one block.
///
/// The claim under test is narrow and load-bearing: FWA must land in the
/// USER's wallet and never in the adapter's. FWAToken reverts any transfer
/// that does not touch the PoolManager, the owner, or a distributor, so an
/// adapter that takes delivery cannot pass the token on - the funds are stuck
/// at its address permanently, with no admin path out. A test that only
/// asserted "the call succeeded" would pass while doing exactly that.
///
/// @dev NOTHING HERE ASSERTS AN ABSOLUTE AMOUNT. A hooked pool reprices every
///      block and the free RPCs will not serve archive state, so a pinned block
///      would rot within the hour. Every assertion is instead a relation that
///      holds at any block - quote equals execution, deltas net to zero, the
///      floor binds at the boundary. Set FORK_BLOCK to pin against an archive
///      node when reproducing a specific number.
///
/// @dev THE ADAPTER IS NOT DEPLOYED AT THE DEFAULT ADDRESS, ALSO ON PURPOSE.
///      Foundry deploys test contracts from a fixed sender at a fixed nonce, so
///      `new Fwabol()` lands on 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f -
///      which on mainnet already holds 0.000577 ETH. An earlier version of this
///      file read that pre-existing balance as ETH the adapter had retained
///      from the swap and reported a fund-loss bug that does not exist. Every
///      balance assertion here is therefore a DELTA, and the adapter is put at
///      an address with nothing on it.
abstract contract FwabolForkBase is Test {
    address constant UR = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant HOOK = 0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444;
    Fwabol fwabol;
    address user = makeAddr("user");

    function setUp() public virtual {
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        // Deployed to a named, empty address rather than wherever the nonce
        // lands - see the note on the pre-existing balance above.
        fwabol = new Fwabol(UR);
        vm.etch(makeAddr("fwabol"), address(fwabol).code);
        fwabol = Fwabol(payable(makeAddr("fwabol")));
        // `router` is immutable, so it lives in the code that was just etched;
        // no storage to copy. Assert it survived rather than assume it.
        assertEq(fwabol.router(), UR, "etched adapter kept its router");
        assertEq(address(fwabol).balance, 0, "the adapter starts empty");

        vm.deal(user, 10 ether);
    }
}

contract FwabolForkTest is FwabolForkBase {
    /// The whole point: buy through the adapter, and the FWA is the user's.
    function test_buyDeliversFwaToTheUserNotTheAdapter() public {
        uint256 before = IERC20(FWA).balanceOf(user);

        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp + 300);

        uint256 got = IERC20(FWA).balanceOf(user) - before;
        assertGt(got, 0, "user received FWA");
        assertEq(
            IERC20(FWA).balanceOf(address(fwabol)), 0, "adapter holds none - it could never pass it on"
        );
        emit log_named_decimal_uint("FWA out for 0.001 ETH", got, 18);
    }

    /// The retention question, answered as a delta so a pre-existing balance
    /// cannot masquerade as a refund and a real refund cannot hide behind one.
    ///
    /// Both halves matter. The adapter's ETH delta being zero says nothing is
    /// left resting for the next caller to sweep; the user's being exactly
    /// -msg.value says the pool consumed the whole input, so there was nothing
    /// to refund in the first place. If the hook ever starts leaving a
    /// remainder, the second assertion breaks and the sweep is what keeps the
    /// first one true.
    function test_adapterEthDeltaIsZero() public {
        uint256 adapterBefore = address(fwabol).balance;
        uint256 userBefore = user.balance;

        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp + 300);

        assertEq(address(fwabol).balance, adapterBefore, "no ETH rests in the adapter");
        assertEq(userBefore - user.balance, 0.001 ether, "the pool consumed the whole input");
        assertEq(UR.balance, 0, "nothing left in the router either");
    }

    /// ETH that was already at the address - or force-sent there - is not the
    /// swapper's to take. `base` is a snapshot, not a zero-check, and this is
    /// the difference: the stray wei stays put while the swap still settles.
    function test_preExistingEthIsNotSweptToTheSwapper() public {
        vm.deal(address(fwabol), 1 ether);
        uint256 userBefore = user.balance;

        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp + 300);

        assertEq(address(fwabol).balance, 1 ether, "the stray ETH is untouched");
        assertEq(userBefore - user.balance, 0.001 ether, "and none of it reached the swapper");
    }

    /// A caller naming the adapter would strand the output forever, so it is
    /// refused before the swap rather than discovered after it.
    function test_adapterCannotBeNamedAsRecipient() public {
        vm.prank(user);
        vm.expectRevert(Fwabol.BadRecipient.selector);
        fwabol.swapEthForFwa{value: 0.001 ether}(address(fwabol), 1, block.timestamp + 300);
    }

    function test_zeroRecipientRefused() public {
        vm.prank(user);
        vm.expectRevert(Fwabol.BadRecipient.selector);
        fwabol.swapEthForFwa{value: 0.001 ether}(address(0), 1, block.timestamp + 300);
    }

    function test_emptySwapRefused() public {
        vm.prank(user);
        vm.expectRevert(Fwabol.NothingIn.selector);
        fwabol.swapEthForFwa(user, 1, block.timestamp + 300);
    }

    /// The floor is the pool's, not the adapter's - so an unreachable one has
    /// to surface as the pool's own revert rather than a silent shortfall.
    function test_unreachableMinOutReverts() public {
        vm.prank(user);
        vm.expectRevert();
        fwabol.swapEthForFwa{value: 0.001 ether}(user, type(uint128).max, block.timestamp + 300);
    }

    /// A floor one wei above the true output must fail, and the true output
    /// itself must pass. Anything looser than that pair would also pass with
    /// the floor silently ignored - which is what an exact-amount TAKE would
    /// have produced, and how a broken guard looks from outside.
    function test_minOutIsEnforcedAtTheBoundary() public {
        uint256 quoted = _quote(0.001 ether);

        vm.prank(user);
        vm.expectRevert();
        fwabol.swapEthForFwa{value: 0.001 ether}(user, uint128(quoted + 1), block.timestamp + 300);

        uint256 before = IERC20(FWA).balanceOf(user);
        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(user, uint128(quoted), block.timestamp + 300);
        assertGe(IERC20(FWA).balanceOf(user) - before, quoted, "the exact floor clears");
    }

    /// An expired deadline is the router's to reject, and it must reach it -
    /// a swallowed deadline is a swap that can be held and executed later.
    function test_expiredDeadlineReverts() public {
        vm.prank(user);
        vm.expectRevert();
        fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp - 1);
    }

    /// Buying for someone else is the whole shape zRouter needs: the payer and
    /// the recipient are different accounts, and the FWA follows the recipient.
    function test_buyerAndRecipientCanDiffer() public {
        address beneficiary = makeAddr("beneficiary");
        uint256 before = IERC20(FWA).balanceOf(beneficiary);

        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(beneficiary, 1, block.timestamp + 300);

        assertGt(IERC20(FWA).balanceOf(beneficiary) - before, 0, "the named account got the FWA");
        assertEq(IERC20(FWA).balanceOf(user), 0, "the payer got none of it");
    }

    /// The token pays the recipient DIRECTLY from the PoolManager. Asserting
    /// the balance alone would also pass if the adapter had taken delivery and
    /// forwarded - which for FWA is impossible, so proving the shape is what
    /// proves the design. One Transfer, PoolManager -> user, and no other.
    function test_theOnlyFwaTransferIsPoolManagerToUser() public {
        vm.recordLogs();
        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp + 300);

        bytes32 TRANSFER = keccak256("Transfer(address,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 toUser;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != FWA || logs[i].topics[0] != TRANSFER) continue;
            address from = address(uint160(uint256(logs[i].topics[1])));
            address to = address(uint160(uint256(logs[i].topics[2])));
            assertTrue(
                from != address(fwabol) && to != address(fwabol), "no FWA transfer touches the adapter"
            );
            if (from == POOL_MANAGER && to == user) ++toUser;
        }
        assertEq(toUser, 1, "exactly one PoolManager -> user payment");
    }

    /// The adapter is not a place to leave ETH. The only sender it accepts is
    /// the router, and only because a refund would arrive that way mid-call.
    function test_receiveRejectsEveryoneButTheRouter() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(fwabol).call{value: 1 wei}("");
        assertFalse(ok, "a stranger cannot fund the adapter");

        vm.deal(UR, 1 ether);
        vm.prank(UR);
        (ok,) = address(fwabol).call{value: 1 wei}("");
        assertTrue(ok, "the router can, which is what the refund path needs");
    }

    function test_constructorRejectsNonContractRouter() public {
        vm.expectRevert(Fwabol.BadRouter.selector);
        new Fwabol(address(0));
        vm.expectRevert(Fwabol.BadRouter.selector);
        new Fwabol(makeAddr("not a router"));
    }

    /// Size independence, and the reason a quote must be per-amount: the hook
    /// prices the trade, so the output is not linear in the input. The unit
    /// price is allowed to move - what must hold at every size is that the FWA
    /// reaches the user and none of it, or of the ETH, sticks to the adapter.
    function test_holdsAcrossTradeSizes() public {
        uint256[4] memory sizes = [uint256(1 wei), 0.0001 ether, 0.01 ether, 1 ether];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 before = IERC20(FWA).balanceOf(user);
            uint256 ethBefore = user.balance;

            vm.prank(user);
            try fwabol.swapEthForFwa{value: sizes[i]}(user, 1, block.timestamp + 300) {
                assertGt(IERC20(FWA).balanceOf(user) - before, 0, "output at this size");
                assertEq(ethBefore - user.balance, sizes[i], "input fully consumed at this size");
            } catch {
                // A size the pool refuses outright is fine - a dust trade may
                // round to nothing. What is not fine is a partial success, and
                // a revert leaves nothing behind to be partial about.
                emit log_named_uint("pool refused size", sizes[i]);
            }
            assertEq(IERC20(FWA).balanceOf(address(fwabol)), 0, "adapter clean at every size");
            assertEq(address(fwabol).balance, 0, "adapter clean at every size");
        }
    }

    /// The SWEEP command earns its byte only if the hook ever stops consuming
    /// the whole input. Today it must move nothing - if this starts failing,
    /// the sweep is doing real work and the assumptions above need rereading.
    function test_theSweepIsANoOpWhileTheHookConsumesEverything() public {
        uint256 userBefore = user.balance;
        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp + 300);
        assertEq(userBefore - user.balance, 0.001 ether, "nothing came back, because nothing was left");
    }

    /// But it does work, and this is where the ETH would otherwise have gone.
    /// Unspent input is left in the ROUTER, not in the adapter - a place the
    /// adapter's own balance check cannot see and the next caller of the
    /// Universal Router can take. Standing ETH in the router stands in for that
    /// remainder: the sweep sends it to the user, in the same transaction.
    function test_sweepRecoversEthLeftInTheRouter() public {
        vm.deal(UR, 0.5 ether);
        uint256 userBefore = user.balance;

        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp + 300);

        assertEq(UR.balance, 0, "the router keeps none of it");
        assertEq(address(fwabol).balance, 0, "and it does not pass through the adapter");
        assertEq(user.balance, userBefore - 0.001 ether + 0.5 ether, "the user got it");
    }

    /// Named recipient, not inferred - the sweep has the same requirement as
    /// the TAKE, for the same reason. ETH left over from a buy made on someone
    /// else's behalf follows the FWA, and never rests here.
    function test_sweepFollowsTheNamedRecipient() public {
        address beneficiary = makeAddr("beneficiary2");
        vm.deal(UR, 0.5 ether);

        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(beneficiary, 1, block.timestamp + 300);

        assertEq(beneficiary.balance, 0.5 ether, "the sweep went where the FWA went");
        assertEq(address(fwabol).balance, 0, "not to the adapter");
    }

    /// Any amount the pool will price must behave identically. The fuzz is over
    /// the input, and the invariants are the ones that would cost money to
    /// break: the FWA is the user's, the adapter keeps nothing of either asset.
    function testFuzz_adapterNeverAccumulates(uint96 amountIn, address recipient) public {
        amountIn = uint96(bound(amountIn, 1, 5 ether));
        vm.assume(recipient != address(0) && recipient != address(fwabol));
        vm.assume(recipient.code.length == 0 && uint160(recipient) > 0xffff);
        vm.assume(recipient != user);

        vm.deal(user, uint256(amountIn) + 1 ether);
        uint256 before = IERC20(FWA).balanceOf(recipient);

        vm.prank(user);
        try fwabol.swapEthForFwa{value: amountIn}(recipient, 1, block.timestamp + 300) {
            assertGt(IERC20(FWA).balanceOf(recipient) - before, 0, "the recipient was paid");
        } catch {}
        assertEq(IERC20(FWA).balanceOf(address(fwabol)), 0, "no FWA ever rests here");
        assertEq(address(fwabol).balance, 0, "no ETH ever rests here");
    }

    /// A recipient that cannot take ETH is not a problem until there is ETH to
    /// give it, and then it is a loud one rather than a silent forfeit. The
    /// SWEEP reverts inside the router, so the whole swap unwinds - the user
    /// keeps their ETH instead of the adapter keeping their change.
    function test_recipientThatRejectsEthFailsLoudlyRatherThanForfeiting() public {
        address hostile = address(new RejectsEth());

        // Nothing to sweep: a contract recipient is fine.
        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(hostile, 1, block.timestamp + 300);
        assertGt(IERC20(FWA).balanceOf(hostile), 0, "it can still be paid in FWA");

        // Something to sweep: the transaction fails rather than stranding it.
        vm.deal(UR, 0.5 ether);
        uint256 userBefore = user.balance;
        vm.prank(user);
        vm.expectRevert();
        fwabol.swapEthForFwa{value: 0.001 ether}(hostile, 1, block.timestamp + 300);
        assertEq(user.balance, userBefore, "the user's ETH is untouched");
        assertEq(address(fwabol).balance, 0, "and nothing was left behind here");
    }

    /// Re-entry is not defended against here because it cannot happen: the ETH
    /// callback the sweep triggers lands inside the Universal Router's own
    /// `execute`, which is behind a lock, so the nested call dies on
    /// `ContractLocked()` and takes the whole transaction with it.
    ///
    /// That is the airtight answer rather than a lucky one - the adapter holds
    /// no state a re-entrant call could corrupt, and `base` is read fresh on
    /// every entry, so even without the router's lock there is nothing to win.
    /// What this test pins is that the attempt cannot half-succeed: nothing is
    /// left in the adapter, and the caller keeps their ETH.
    function test_reentryIsRefusedByTheRoutersLock() public {
        Reenterer r = new Reenterer(fwabol);
        vm.deal(UR, 0.5 ether); // give the sweep something to trigger the callback with
        vm.deal(address(r), 1 ether);
        uint256 before = address(r).balance;

        // The nested `execute` reverts `ContractLocked()` (0x6f5ffb7e); that
        // bubbles out of the recipient's `receive`, so what the outer call sees
        // is the sweep's own ETH_TRANSFER_FAILED. Either way it is a full unwind.
        //
        // The nested attempt is asserted rather than assumed: `reentered` is a
        // storage flag and the revert rolls it back, so the proof that the
        // callback fired has to be the call itself. Two entries into
        // `swapEthForFwa` - the outer one and the one from `receive`.
        vm.expectCall(
            address(fwabol),
            abi.encodeCall(Fwabol.swapEthForFwa, (address(r), 1, block.timestamp + 300)),
            2
        );
        vm.expectRevert();
        r.go();

        assertEq(address(r).balance, before, "the caller lost nothing trying");
        assertEq(address(fwabol).balance, 0, "adapter clean");
        assertEq(IERC20(FWA).balanceOf(address(fwabol)), 0, "and holds no FWA");
    }

    /// The flip side of the lock: nothing persists between calls, so ordinary
    /// back-to-back buys are unaffected by any of the above.
    function test_sequentialSwapsAreIndependent() public {
        for (uint256 i; i < 3; ++i) {
            uint256 before = IERC20(FWA).balanceOf(user);
            vm.prank(user);
            fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp + 300);
            assertGt(IERC20(FWA).balanceOf(user) - before, 0, "each buy stands alone");
            assertEq(address(fwabol).balance, 0, "and leaves nothing behind");
        }
    }

    /// FWA as the LAST leg of a route. There is no USDC/FWA pool and there does
    /// not need to be - the first leg is an ordinary swap to ETH, the second is
    /// this adapter, and no intermediate ever custodies FWA.
    ///
    /// @dev THIS DOES NOT PROVE ATOMIC COMPOSITION, and the ETH is dealt rather
    ///      than swapped for to keep that honest. `zRouter.snwap` funds its
    ///      executor from `msg.value` alone, so ETH a previous leg parked in the
    ///      router cannot reach this adapter, and sweeping it here would hit the
    ///      `receive()` gate. A token -> FWA buy is therefore two transactions.
    ///      What this test does establish is the half that matters for the last
    ///      leg: given ETH in hand, the FWA lands on the user.
    function test_fwaWorksAsTheFinalLegGivenEthInHand() public {
        vm.deal(user, user.balance + 0.001 ether);

        uint256 before = IERC20(FWA).balanceOf(user);
        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp + 300);

        assertGt(IERC20(FWA).balanceOf(user) - before, 0, "the ETH leg feeds the FWA leg");
        assertEq(IERC20(FWA).balanceOf(address(fwabol)), 0, "still nothing stuck mid-route");
    }

    function _quote(uint256 amountIn) internal returns (uint256 out) {
        (, out) = new V4QuoteLens().quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, amountIn);
        assertGt(out, 0, "the lens quoted the pool");
    }
}

/// @notice The quote a user is shown has to be the amount they receive.
///
/// This is the half that local math cannot do. `zQuoterV4` reads slot0 and
/// liquidity and steps the curve; this pool's hook returns its own delta, so
/// that reimplementation is quoting a pool that is not the one trading. The
/// lens runs the real hook through PoolManager.unlock instead, and the test is
/// simply: quote it, execute it, and require the two to be equal to the wei.
contract FwabolQuoteTest is FwabolForkBase {
    V4QuoteLens lens;

    function setUp() public override {
        super.setUp();
        lens = new V4QuoteLens();
    }

    function test_quoterAddressIsTheRealOne() public view {
        assertGt(lens.V4_QUOTER().code.length, 0, "the quoter is deployed");
        assertEq(
            IPoolManagerOwned(lens.V4_QUOTER()).poolManager(),
            POOL_MANAGER,
            "and it quotes against the PoolManager these pools live in"
        );
    }

    /// Exact to the wei, at four sizes spanning four orders of magnitude.
    function test_quoteMatchesExecutionExactly() public {
        uint256[4] memory sizes = [uint256(0.0001 ether), 0.001 ether, 0.1 ether, 1 ether];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();

            (uint256 inQ, uint256 outQ) =
                lens.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, sizes[i]);
            assertEq(inQ, sizes[i], "exact-in quotes back its own input");
            assertGt(outQ, 0, "the pool quoted");

            uint256 before = IERC20(FWA).balanceOf(user);
            vm.prank(user);
            fwabol.swapEthForFwa{value: sizes[i]}(user, uint128(outQ), block.timestamp + 300);
            assertEq(IERC20(FWA).balanceOf(user) - before, outQ, "quote == received, to the wei");

            vm.revertToState(snap);
        }
    }

    /// The hook's price is not a constant, which is the reason the page cannot
    /// quote one size and scale it. 1000x the input must not be 1000x the out.
    function test_theHookIsNotLinearSoEachSizeNeedsItsOwnQuote() public {
        (, uint256 small) = lens.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, 0.001 ether);
        (, uint256 big) = lens.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, 1 ether);
        assertLt(big, small * 1000, "scaling a single quote would over-promise");
        emit log_named_decimal_uint("FWA per ETH at 0.001 ETH", (small * 1e18) / 0.001 ether, 18);
        emit log_named_decimal_uint("FWA per ETH at 1 ETH", (big * 1e18) / 1 ether, 18);
    }

    /// A batch is only useful if it is the same number N times over, and the
    /// per-size quotes are what a page renders next to each preset amount.
    function test_batchMatchesTheSingleQuotes() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 0.001 ether;
        amounts[1] = 0.01 ether;
        amounts[2] = 0.1 ether;

        (, uint256[] memory outs) =
            lens.quoteV4HookedBatch(false, address(0), FWA, 0, 60, HOOK, amounts);
        for (uint256 i; i < amounts.length; ++i) {
            (, uint256 single) = lens.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, amounts[i]);
            assertEq(outs[i], single, "batch leg equals its own single quote");
            assertGt(outs[i], 0, "and it is a real quote");
        }
    }

    /// THIS HOOK HAS NO EXACT-OUT. Asked "what does exactly N FWA cost", the
    /// hook reverts (HookDeltaExceedsSwapAmount) rather than pricing it - a
    /// custom-curve hook that only implements the exact-in direction. The lens
    /// reports that as no route, and a page must not offer an exact-output
    /// field for this pool; there is no amount it could put in it.
    ///
    /// The failure is silent by design - (0, 0), not a revert - so it cannot
    /// take down a sweep across other pools. The cost is that "cannot quote
    /// exact-out" and "no liquidity" look identical to a caller. For a routing
    /// sweep that is the same decision either way; a UI that wants to explain
    /// itself should probe exact-in first and treat a live exact-in with a dead
    /// exact-out as this case.
    function test_exactOutIsUnsupportedByThisHookAndReadsAsNoRoute() public {
        (, uint256 out) = lens.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, 0.01 ether);
        assertGt(out, 0, "exact-in works");

        (uint256 costIn, uint256 target) = lens.quoteV4Hooked(true, address(0), FWA, 0, 60, HOOK, out);
        assertEq(costIn, 0, "exact-out does not price");
        assertEq(target, 0, "and says so as no route rather than reverting");
    }

    /// A pool that does not exist must read as "no route", not as free money
    /// and not as a revert that takes the whole quote sweep down with it.
    function test_deadPoolQuotesZeroInsteadOfReverting() public {
        (uint256 aIn, uint256 aOut) =
            lens.quoteV4Hooked(false, address(0), FWA, 3000, 60, address(0), 0.001 ether);
        assertEq(aIn, 0, "uninitialised pool: no input");
        assertEq(aOut, 0, "uninitialised pool: no output");

        (, uint256 zero) = lens.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, 0);
        assertEq(zero, 0, "a zero-size quote is zero, not a revert");

        (, uint256 tooBig) = lens.quoteV4Hooked(
            false, address(0), FWA, 0, 60, HOOK, uint256(type(uint128).max) + 1
        );
        assertEq(tooBig, 0, "an amount that does not fit uint128 is refused, not truncated");
    }

    /// Currency order is derived, not supplied. Quoting the same pool from the
    /// FWA side must key the same pool - a lens that got this backwards would
    /// return zero for one direction and look merely illiquid.
    function test_bothDirectionsFindThePool() public {
        (, uint256 buy) = lens.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, 0.001 ether);
        (, uint256 sell) = lens.quoteV4Hooked(false, FWA, address(0), 0, 60, HOOK, 1e18);
        assertGt(buy, 0, "ETH -> FWA quotes");
        assertGt(sell, 0, "FWA -> ETH quotes the same pool from the other side");
    }
}

interface IPoolManagerOwned {
    function poolManager() external view returns (address);
}

/// @dev Takes FWA happily, refuses ETH.
contract RejectsEth {
    receive() external payable {
        revert("no ETH here");
    }
}

/// @dev Re-enters the adapter from the ETH callback the sweep triggers.
contract Reenterer {
    Fwabol immutable fwabol;
    bool public reentered;

    constructor(Fwabol f) {
        fwabol = f;
    }

    function go() external {
        fwabol.swapEthForFwa{value: 0.001 ether}(address(this), 1, block.timestamp + 300);
    }

    /// The sweep pays ETH here mid-swap; buy again from inside that callback.
    receive() external payable {
        if (reentered) return;
        reentered = true;
        fwabol.swapEthForFwa{value: 0.001 ether}(address(this), 1, block.timestamp + 300);
    }
}

/// @notice Drives PoolManager.swap directly, with no quoter and no router in
///         the way, so a revert can be attributed to the hook and nothing else.
///
/// @dev Every probe ends in a revert on purpose. A swap that succeeds leaves an
///      unsettled delta, and v4 refuses to close the lock with one - so the
///      callback reports its result by reverting with `Probe` either way, and
///      the lock never has to be closed at all.
contract ExactOutProbe {
    IPoolManagerSwap constant PM = IPoolManagerSwap(0x000000000004444c5dc75cB358380D2e3dE08A90);
    uint160 constant MIN_SQRT_PLUS_ONE = 4295128740;
    uint160 constant MAX_SQRT_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    error Probe(bool reverted, bytes data);

    /// @return reverted Whether the swap itself failed.
    /// @return data     The raw revert bytes when it did.
    function probe(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        external
        returns (bool reverted, bytes memory data)
    {
        try PM.unlock(abi.encode(key, zeroForOne, amountSpecified)) returns (bytes memory) {
            revert("unreachable: the callback always reverts");
        } catch (bytes memory raw) {
            // Strip the 4-byte `Probe` selector and decode the payload.
            require(bytes4(raw) == Probe.selector, "not our probe: v4 rejected the unlock itself");
            bytes memory body = new bytes(raw.length - 4);
            for (uint256 i; i < body.length; ++i) {
                body[i] = raw[i + 4];
            }
            return abi.decode(body, (bool, bytes));
        }
    }

    function unlockCallback(bytes calldata encoded) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified) =
            abi.decode(encoded, (PoolKey, bool, int256));
        try PM.swap(
            key,
            SwapParams(zeroForOne, amountSpecified, zeroForOne ? MIN_SQRT_PLUS_ONE : MAX_SQRT_MINUS_ONE),
            ""
        ) returns (int256) {
            revert Probe(false, "");
        } catch (bytes memory e) {
            revert Probe(true, e);
        }
    }
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerSwap {
    function unlock(bytes calldata) external returns (bytes memory);
    function swap(PoolKey memory, SwapParams memory, bytes calldata) external returns (int256);
}

/// @notice Where the exact-out refusal actually comes from.
///
/// Reading a `(0, 0)` out of the lens and concluding "the hook has no exact-out"
/// would be an inference from a silence - a malformed pool key, a bad currency
/// order, or a quirk of V4Quoter would look exactly the same. These tests take
/// the quoter and the router out of the picture entirely and call
/// PoolManager.swap directly, so what is left is the hook.
contract FwaHookExactOutTest is FwabolForkBase {
    ExactOutProbe probe;

    function setUp() public override {
        super.setUp();
        probe = new ExactOutProbe();
    }

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey(address(0), FWA, 0, 60, HOOK);
    }

    /// The control. Same pool, same key, same probe - a NEGATIVE
    /// `amountSpecified` is exact-in, and it goes through. Without this, a
    /// failing exact-out proves only that the probe is broken.
    function test_exactInThroughTheSameProbeSucceeds() public {
        (bool reverted, bytes memory data) = probe.probe(_key(), true, -0.01 ether);
        assertFalse(reverted, "exact-in swaps fine through the identical path");
        assertEq(data.length, 0, "and returns no error");
    }

    /// The finding. A POSITIVE `amountSpecified` is exact-out, and the hook
    /// rejects it - at every size, in both directions, with the same error.
    ///
    /// The revert is a v4 `WrappedError` naming the hook address and the
    /// `afterSwap` selector, which is v4-core's way of saying "this hook's
    /// afterSwap reverted". It is not the PoolManager declining, not the
    /// quoter, and not the encoding: the control above shares all three.
    function test_exactOutIsRefusedByTheHookItself() public {
        int256[3] memory outs = [int256(1e18), 100e18, 10_000e18];
        bytes4 WRAPPED_ERROR = bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)"));
        bytes4 AFTER_SWAP = bytes4(
            keccak256(
                "afterSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),int256,bytes)"
            )
        );

        for (uint256 i; i < outs.length; ++i) {
            (bool reverted, bytes memory data) = probe.probe(_key(), true, outs[i]);
            assertTrue(reverted, "buying an exact amount of FWA is refused");
            assertEq(bytes4(data), WRAPPED_ERROR, "and refused as a wrapped hook error");

            (address who, bytes4 which,,) = abi.decode(_body(data), (address, bytes4, bytes, bytes));
            assertEq(who, HOOK, "the hook is the one reverting");
            assertEq(which, AFTER_SWAP, "inside afterSwap");
        }

        // The other direction too - this is a property of the hook, not of the
        // side of the pool being bought.
        (bool sellReverted,) = probe.probe(_key(), false, 0.001 ether);
        assertTrue(sellReverted, "exact-out ETH for FWA is refused as well");
    }

    /// The workaround, end to end: ask for "at least N FWA", get an input, and
    /// spend exactly that input through Fwabol - and receive at least N.
    ///
    /// The overshoot is what makes this usable rather than merely correct. A
    /// solver that answered "spend 10 ETH, you will certainly clear 100 FWA"
    /// would satisfy the assertion and be useless in the UI, so the input is
    /// held to within 0.1% of the target's worth.
    function test_solveExactOutStandsInForTheMissingDirection() public {
        V4QuoteLens lens = new V4QuoteLens();
        uint256 target = 500e18; // FWA

        (uint256 needIn, uint256 solvedOut) =
            lens.solveExactOut(address(0), FWA, 0, 60, HOOK, target, 1 ether, 60);
        assertGt(needIn, 0, "the solver found an input");
        assertGe(solvedOut, target, "which clears the target");

        uint256 before = IERC20(FWA).balanceOf(user);
        vm.prank(user);
        fwabol.swapEthForFwa{value: needIn}(user, uint128(target), block.timestamp + 300);
        uint256 got = IERC20(FWA).balanceOf(user) - before;

        assertEq(got, solvedOut, "the solved quote is the executed amount, to the wei");
        assertGe(got, target, "and the user got at least what they asked for");
        assertLe(got - target, target / 1000, "without overshooting by more than 0.1%");
        emit log_named_decimal_uint("ETH needed for 500 FWA", needIn, 18);
    }

    /// A target the ceiling cannot reach is no route, not a silent truncation
    /// to "here is what your ceiling buys" - that would quietly fill an order
    /// far short of what the user typed.
    function test_solveExactOutRefusesAnUnreachableTarget() public {
        V4QuoteLens lens = new V4QuoteLens();
        (uint256 needIn, uint256 out) =
            lens.solveExactOut(address(0), FWA, 0, 60, HOOK, 1_000_000e18, 0.001 ether, 40);
        assertEq(needIn, 0, "no input is offered");
        assertEq(out, 0, "and no output is implied");
    }

    /// And the same conclusion arrives through the lens, which is the path
    /// zSwap will actually use: exact-in prices, exact-out is no route.
    function test_theLensReportsWhatTheProbeProves() public {
        V4QuoteLens lens = new V4QuoteLens();
        (, uint256 exactIn) = lens.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, 0.01 ether);
        (uint256 exactOut,) = lens.quoteV4Hooked(true, address(0), FWA, 0, 60, HOOK, 100e18);
        assertGt(exactIn, 0, "exact-in: a price");
        assertEq(exactOut, 0, "exact-out: no route, matching the hook's own refusal");
    }

    function _body(bytes memory raw) internal pure returns (bytes memory body) {
        body = new bytes(raw.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = raw[i + 4];
        }
    }
}
