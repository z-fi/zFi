// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Fwabol as FwabolV2} from "../src/forwarders/FwabolV2.sol";
import {Fwabol as FwabolV1} from "../src/forwarders/Fwabol.sol";
import {V4QuoteLens} from "../src/V4QuoteLens.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice The new Fwabol against the real pool, both directions.
///
/// @dev Balances are compared as DELTAS and the adapter is etched to a named
///      address, because mainnet already holds ETH at the addresses Foundry
///      deploys test contracts to - a pre-existing balance there once got read
///      as a fund-loss bug that did not exist.
abstract contract FwabolV2ForkBase is Test {
    address constant PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address constant HOOK = 0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444;
    address constant UR = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    FwabolV2 fw;
    address user = makeAddr("user");

    function setUp() public virtual {
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);

        fw = new FwabolV2();
        vm.etch(makeAddr("fwabol2"), address(fw).code);
        fw = FwabolV2(payable(makeAddr("fwabol2")));
        assertEq(address(fw).balance, 0, "the adapter starts empty");

        vm.deal(user, 100 ether);
    }

    function _buy(uint256 amount) internal returns (uint256 out) {
        vm.prank(user);
        return fw.buy{value: amount}(user, 1, block.timestamp + 300);
    }
}

contract FwabolV2ForkTest is FwabolV2ForkBase {
    // ---- buying ----------------------------------------------------------

    function test_buyPaysTheUserNotTheAdapter() public {
        uint256 before = IERC20(FWA).balanceOf(user);
        uint256 out = _buy(0.01 ether);

        assertGt(out, 0, "the buy returned an amount");
        assertEq(IERC20(FWA).balanceOf(user) - before, out, "and it is what the user received");
        assertEq(IERC20(FWA).balanceOf(address(fw)), 0, "the adapter holds no FWA");
        assertEq(address(fw).balance, 0, "and no ETH");
        emit log_named_decimal_uint("FWA for 0.01 ETH", out, 18);
    }

    /// No router in the path means no router to leave change in. The input is
    /// consumed exactly, and the adapter's balance is not merely swept to zero -
    /// there is never anything in it to sweep.
    function test_buyConsumesExactlyTheInput() public {
        uint256 userBefore = user.balance;
        _buy(0.01 ether);
        assertEq(userBefore - user.balance, 0.01 ether, "spent exactly what was sent");
        assertEq(address(fw).balance, 0, "nothing rests in the adapter");
        assertEq(PM.balance > 0, true, "the ETH went to the PoolManager");
    }

    function test_buyRespectsItsFloor() public {
        V4QuoteLens lens = new V4QuoteLens();
        (, uint256 quoted) = lens.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, 0.01 ether);

        vm.prank(user);
        vm.expectRevert();
        fw.buy{value: 0.01 ether}(user, uint128(quoted + 1), block.timestamp + 300);

        uint256 before = IERC20(FWA).balanceOf(user);
        vm.prank(user);
        fw.buy{value: 0.01 ether}(user, uint128(quoted), block.timestamp + 300);
        assertGe(IERC20(FWA).balanceOf(user) - before, quoted, "the exact floor clears");
    }

    // ---- selling ---------------------------------------------------------

    /// The half the old adapter could not do at all.
    function test_sellPaysTheUserAndTheAdapterNeverHoldsFwa() public {
        uint256 held = _buy(0.05 ether);
        uint128 amountIn = uint128(held / 2);

        vm.prank(user);
        IERC20(FWA).approve(address(fw), type(uint256).max);

        uint256 ethBefore = user.balance;
        uint256 fwaBefore = IERC20(FWA).balanceOf(user);

        vm.prank(user);
        uint256 ethOut = fw.sell(amountIn, user, 1, block.timestamp + 300);

        assertGt(ethOut, 0, "the sell returned ETH");
        assertEq(user.balance - ethBefore, ethOut, "and it reached the seller");
        assertEq(fwaBefore - IERC20(FWA).balanceOf(user), amountIn, "the FWA left the seller");
        assertEq(IERC20(FWA).balanceOf(address(fw)), 0, "the adapter never held any");
        assertEq(address(fw).balance, 0, "nor any ETH");
        emit log_named_decimal_uint("ETH out for half the position", ethOut, 18);
    }

    /// Round trip. The loss is the pool's spread and the hook's fee, not the
    /// adapter's - so it has to be a few percent, not a few tens of percent.
    function test_buyThenSellEverythingRoundTrips() public {
        uint256 spent = 0.05 ether;
        uint256 held = _buy(spent);

        vm.startPrank(user);
        IERC20(FWA).approve(address(fw), type(uint256).max);
        uint256 back = fw.sell(uint128(held), user, 1, block.timestamp + 300);
        vm.stopPrank();

        assertEq(IERC20(FWA).balanceOf(user), 0, "the whole position was sold");
        assertLt(back, spent, "a round trip costs the spread");
        assertGt(back, (spent * 90) / 100, "but only the spread - within 10%");
        emit log_named_decimal_uint("round trip out of 0.05 ETH", back, 18);
    }

    function test_sellRespectsItsFloor() public {
        uint256 held = _buy(0.05 ether);
        vm.prank(user);
        IERC20(FWA).approve(address(fw), type(uint256).max);

        vm.prank(user);
        vm.expectRevert();
        fw.sell(uint128(held), user, type(uint128).max, block.timestamp + 300);

        // And the position is untouched by the failed attempt.
        assertEq(IERC20(FWA).balanceOf(user), held, "nothing was sold");
    }

    /// THE ONE THAT MATTERS. The seller is `msg.sender`, so an allowance to
    /// this contract is not a standing option anyone else can exercise. A
    /// third party calling `sell` sells THEIR OWN FWA - of which they have
    /// none - and cannot reach the victim's.
    function test_anApprovalCannotBeExercisedByAThirdParty() public {
        uint256 held = _buy(0.05 ether);
        vm.prank(user);
        IERC20(FWA).approve(address(fw), type(uint256).max);

        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);

        vm.prank(attacker);
        vm.expectRevert();
        fw.sell(uint128(held), attacker, 1, block.timestamp + 300);

        assertEq(IERC20(FWA).balanceOf(user), held, "the victim's position is intact");
        assertEq(IERC20(FWA).balanceOf(attacker), 0, "and the attacker got nothing");
    }

    /// Routed through snwap the caller would be SafeExecutor, which holds no
    /// FWA and has no allowance - so a routed sell fails rather than selling
    /// someone else's position. Documented as the safe failure it is.
    function test_aSellFromAContractWithoutAllowanceReverts() public {
        uint256 held = _buy(0.05 ether);
        vm.prank(user);
        IERC20(FWA).approve(address(fw), type(uint256).max);

        Caller proxy = new Caller();
        vm.expectRevert();
        proxy.sellVia(fw, uint128(held), user);
        assertEq(IERC20(FWA).balanceOf(user), held, "untouched");
    }

    /// Selling more than you hold is the token's refusal, and it must not be
    /// swallowed into a partial fill.
    function test_sellingMoreThanHeldReverts() public {
        uint256 held = _buy(0.01 ether);
        vm.prank(user);
        IERC20(FWA).approve(address(fw), type(uint256).max);

        vm.prank(user);
        vm.expectRevert();
        fw.sell(uint128(held * 2), user, 1, block.timestamp + 300);
        assertEq(IERC20(FWA).balanceOf(user), held, "still holds exactly what it had");
    }

    // ---- shared guards ---------------------------------------------------

    function test_deadlinesAreEnforcedOnBothSides() public {
        vm.prank(user);
        vm.expectRevert(FwabolV2.Deadline.selector);
        fw.buy{value: 0.001 ether}(user, 1, block.timestamp - 1);

        vm.prank(user);
        vm.expectRevert(FwabolV2.Deadline.selector);
        fw.sell(1e18, user, 1, block.timestamp - 1);
    }

    function test_badRecipientsAreRefusedOnBothSides() public {
        vm.startPrank(user);
        vm.expectRevert(FwabolV2.BadRecipient.selector);
        fw.buy{value: 0.001 ether}(address(0), 1, block.timestamp + 300);
        vm.expectRevert(FwabolV2.BadRecipient.selector);
        fw.buy{value: 0.001 ether}(address(fw), 1, block.timestamp + 300);
        vm.expectRevert(FwabolV2.BadRecipient.selector);
        fw.sell(1e18, address(0), 1, block.timestamp + 300);
        vm.expectRevert(FwabolV2.BadRecipient.selector);
        fw.sell(1e18, address(fw), 1, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_emptyTradesAreRefused() public {
        vm.startPrank(user);
        vm.expectRevert(FwabolV2.NothingIn.selector);
        fw.buy(user, 1, block.timestamp + 300);
        vm.expectRevert(FwabolV2.NothingIn.selector);
        fw.sell(0, user, 1, block.timestamp + 300);
        vm.stopPrank();
    }

    /// The callback moves other people's tokens. Only the PoolManager, holding
    /// the lock, may reach it.
    function test_unlockCallbackIsPoolManagerOnly() public {
        vm.prank(user);
        vm.expectRevert(FwabolV2.NotPoolManager.selector);
        fw.unlockCallback(abi.encode(false, user, user, uint128(1e18), uint128(0)));
    }

    function test_receiveRejectsEveryoneButThePoolManager() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(fw).call{value: 1 wei}("");
        assertFalse(ok, "a stranger cannot fund the adapter");

        vm.deal(PM, 1 ether);
        vm.prank(PM);
        (ok,) = address(fw).call{value: 1 wei}("");
        assertTrue(ok, "the PoolManager can, which the swap payout needs");
    }

    /// Any size the pool will price, in either direction, leaves the adapter
    /// holding nothing.
    function testFuzz_adapterNeverAccumulates(uint96 amountIn) public {
        amountIn = uint96(bound(amountIn, 1e12, 5 ether));
        vm.deal(user, uint256(amountIn) + 10 ether);

        vm.prank(user);
        try fw.buy{value: amountIn}(user, 1, block.timestamp + 300) returns (uint256 got) {
            vm.startPrank(user);
            IERC20(FWA).approve(address(fw), type(uint256).max);
            try fw.sell(uint128(got), user, 1, block.timestamp + 300) {} catch {}
            vm.stopPrank();
        } catch {}

        assertEq(IERC20(FWA).balanceOf(address(fw)), 0, "no FWA ever rests here");
        assertEq(address(fw).balance, 0, "no ETH ever rests here");
    }

    /// The lens quotes this adapter as well as it quoted the old one - it is
    /// the same pool, and the adapter adds nothing to the price.
    function test_theLensStillQuotesBuysToTheWei() public {
        V4QuoteLens lens = new V4QuoteLens();
        (, uint256 quoted) = lens.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, 0.01 ether);
        assertEq(_buy(0.01 ether), quoted, "quote == delivery");
    }

    /// And it quotes the SELL direction too, which is newly useful now that
    /// the sell can actually be executed.
    function test_theLensQuotesSellsToTheWei() public {
        uint256 held = _buy(0.05 ether);
        V4QuoteLens lens = new V4QuoteLens();
        (, uint256 quoted) = lens.quoteV4Hooked(false, FWA, address(0), 0, 60, HOOK, held);
        assertGt(quoted, 0, "the sell side quotes");

        vm.startPrank(user);
        IERC20(FWA).approve(address(fw), type(uint256).max);
        uint256 got = fw.sell(uint128(held), user, 1, block.timestamp + 300);
        vm.stopPrank();

        assertEq(got, quoted, "quote == delivery on the way out too");
    }

    /// The new Fwabol must price a buy identically to the deployed Fwabol - same pool,
    /// same block. If these ever disagree, one of them is routing somewhere
    /// unintended.
    function test_agreesWithTheDeployedAdapterOnBuys() public {
        FwabolV1 old = new FwabolV1(UR);
        vm.etch(makeAddr("old"), address(old).code);
        old = FwabolV1(payable(makeAddr("old")));

        uint256 snap = vm.snapshotState();
        uint256 viaNew = _buy(0.01 ether);
        vm.revertToState(snap);

        address other = makeAddr("other");
        vm.deal(other, 1 ether);
        vm.prank(other);
        old.swapEthForFwa{value: 0.01 ether}(other, 1, block.timestamp + 300);

        assertEq(IERC20(FWA).balanceOf(other), viaNew, "both adapters buy the same amount");
    }
}

contract Caller {
    function sellVia(FwabolV2 fw, uint128 amountIn, address recipient) external {
        fw.sell(amountIn, recipient, 1, block.timestamp + 300);
    }
}
