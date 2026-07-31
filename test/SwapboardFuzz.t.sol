// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "../lib/solady/src/utils/FixedPointMathLib.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// The two properties every settlement path rests on, fuzzed rather than
/// enumerated: an order can never pay out more tokenA than its maker escrowed,
/// and a fill is always funded by the taker rather than by somebody else's
/// escrow. Both have concrete counterexamples in the suite's history - the
/// second is the ETH-underpayment bug - so they are worth stating as invariants
/// instead of as the handful of cases that happened to be found.
contract SwapboardFuzzTest is Test {
    Swapboard sb;
    MockWETH weth;
    MockERC20 A;
    MockERC20 B;

    address maker = address(0xA11CE);
    address taker = address(0xB0B);
    address victim = address(0xBEEF);

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        A = new MockERC20("AAA", 18);
        B = new MockERC20("BBB", 6);
        vm.prank(maker);
        A.approve(address(sb), type(uint256).max);
        vm.prank(taker);
        B.approve(address(sb), type(uint256).max);
    }

    /// Any sequence of partial fills against one order: the board never releases
    /// more tokenA than it took in, the maker is credited exactly what the takers
    /// paid, a live order is always still backed by both sides, and settling in
    /// full delivers the whole escrow for the whole ask - no dust left behind on
    /// either side.
    function testFuzz_PartialFillsConserveTheEscrow(uint128 amtA, uint128 amtB, uint64[6] memory bids) public {
        amtA = uint128(bound(amtA, 1, 1e30));
        amtB = uint128(bound(amtB, 1, 1e30));
        A.mint(maker, amtA);
        B.mint(taker, amtB);

        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), amtA, address(B), amtB, true, 0, false, false, address(0));
        assertEq(A.balanceOf(address(sb)), amtA, "escrow taken in full");

        uint256 paid;
        for (uint256 i; i < bids.length; ++i) {
            (, bool active,,,,,,, uint256 remA,, uint256 remB) = sb.orders(id);
            if (!active) break;

            assertGt(remA, 0, "a live order is still backed");
            assertGt(remB, 0, "a live order still wants something");
            // The resting remainder is never priced worse than the original ask:
            // rounding down on each fill leaves the dust with the order.
            assertGe(uint256(remA) * amtB, uint256(amtA) * remB, "remainder never worse than posted");

            uint256 bid = bound(uint256(bids[i]), 1, remB);
            // A bid too small to move any tokenA is refused by design; skip it
            // rather than assert on a revert the sequence does not depend on.
            if (bid < remB && FixedPointMathLib.fullMulDiv(bid, remA, remB) == 0) continue;

            vm.prank(taker);
            sb.fillOrder(id, 0, bid, 0, address(0));
            paid += bid;
        }

        uint256 out = A.balanceOf(taker);
        assertLe(out, amtA, "never pays out more than was escrowed");
        assertEq(A.balanceOf(address(sb)), amtA - out, "board holds exactly the remainder");
        assertEq(B.balanceOf(maker), paid, "maker credited exactly what was paid");

        (, bool live,,,,,,,,,) = sb.orders(id);
        if (!live) {
            assertEq(out, amtA, "a settled order delivers the whole escrow");
            assertEq(paid, amtB, "for the whole ask");
        }
    }

    /// The ETH path wraps before it settles, so the payment is already sitting in
    /// the board when _fill decides how much the maker is owed. Whatever the ask
    /// and whatever is sent: either the call reverts, or the maker is paid
    /// exactly what the taker sent and unrelated WETH escrow is untouched.
    function testFuzz_EthFillIsFundedByTheTakerNotTheEscrow(uint96 ask, uint96 sent, bool partialFill) public {
        uint256 parked = 100 ether;
        vm.deal(victim, parked);
        vm.startPrank(victim);
        weth.deposit{value: parked}();
        weth.approve(address(sb), type(uint256).max);
        sb.createOrder(address(weth), parked, address(B), 1e6, false, 0, false, false, address(0));
        vm.stopPrank();
        assertEq(weth.balanceOf(address(sb)), parked, "victim escrow parked");

        ask = uint96(bound(ask, 1, 1e24));
        sent = uint96(bound(sent, 0, 2e24));

        A.mint(maker, 50e18);
        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 50e18, address(weth), ask, partialFill, 0, false, false, address(0));

        vm.deal(taker, sent);
        vm.prank(taker);
        try sb.fillOrderWithEth{value: sent}(id, 0, 0, address(0)) {
            assertEq(weth.balanceOf(address(sb)), parked, "victim escrow untouched");
            assertEq(weth.balanceOf(maker), sent, "maker paid exactly what arrived");
            assertLe(A.balanceOf(taker), 50e18, "and never more escrow than the order held");
        } catch {
            assertEq(weth.balanceOf(address(sb)), parked, "nothing moved");
            assertEq(weth.balanceOf(maker), 0, "maker paid nothing");
        }
    }
}
