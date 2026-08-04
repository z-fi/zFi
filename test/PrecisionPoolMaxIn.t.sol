// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev `maxAmountIn` is only useful if it is EXACT. A router sizes a leg from
/// it, so an answer one unit high is a reverted route and an answer materially
/// low is liquidity left on the table. These tests pin both edges against real
/// execution rather than against the lens's own arithmetic.
contract PrecisionPoolMaxInTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPoolLens lens;
    MockERC20 usdc;
    PrecisionPool pool;

    address lp = address(0xA11CE);
    address trader = address(0xB0B);

    uint256 constant LO = 42426406871192; // $1800
    uint256 constant MID = 44721359549995; // $2000
    uint256 constant HI = 46904157598234; // $2200

    function _m(uint256 fee, address feeRecipient, uint256 creatorBps)
        internal
        view
        returns (PrecisionPoolFactory.Market memory)
    {
        return PrecisionPoolFactory.Market(address(0), address(usdc), LO, HI, fee, address(0), feeRecipient, creatorBps);
    }

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        lens = new PrecisionPoolLens(factory);
        usdc = new MockERC20("USDC", 6);
        usdc.mint(lp, 1e15);
        usdc.mint(trader, 1e15);
        vm.deal(lp, 1e23);
        vm.deal(trader, 1e23);

        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 10 ether}(_m(3000, address(0), 0), MID, 10 ether, 30_000e6, 0, lp);
        vm.stopPrank();
        pool = PrecisionPool(payable(p));

        vm.prank(trader);
        usdc.approve(address(pool), type(uint256).max);
    }

    /// @dev The reported maximum fills, and the very next unit does not.
    function test_MaxTokenInIsExactlyExecutable() public {
        (uint256 maxIn, uint256 quoted) = lens.maxAmountIn(address(pool), trader, address(usdc));
        assertGt(maxIn, 0, "a fresh mid-band pool can absorb something");

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        vm.expectRevert();
        pool.swapExactIn(address(usdc), maxIn + 1, 0, trader);
        vm.revertToState(snap);

        vm.prank(trader);
        uint256 got = pool.swapExactIn(address(usdc), maxIn, 0, trader);
        assertEq(got, quoted, "the quote at the maximum matches execution");
        assertGt(got, 0);
    }

    /// @dev Same on the other side of the book.
    function test_MaxEthInIsExactlyExecutable() public {
        (uint256 maxIn, uint256 quoted) = lens.maxAmountIn(address(pool), trader, address(0));
        assertGt(maxIn, 0);

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        vm.expectRevert();
        pool.swapExactIn{value: maxIn + 1}(address(0), maxIn + 1, 0, trader);
        vm.revertToState(snap);

        vm.prank(trader);
        uint256 got = pool.swapExactIn{value: maxIn}(address(0), maxIn, 0, trader);
        assertEq(got, quoted);
    }

    /// @dev Filling to the maximum should park the pool on its boundary, which
    /// is the property that makes a multi-pool route hand off correctly.
    function test_MaxFillLandsOnTheBoundary() public {
        (uint256 maxIn,) = lens.maxAmountIn(address(pool), trader, address(usdc));
        vm.prank(trader);
        pool.swapExactIn(address(usdc), maxIn, 0, trader);
        assertApproxEqRel(pool.sqrtPriceCurrent(), HI, 0.0001e18, "parked at the ceiling");

        // And the pool now reports no further capacity in that direction.
        (uint256 again,) = lens.maxAmountIn(address(pool), trader, address(usdc));
        assertEq(again, 0, "a maxed-out side reports zero capacity");
        // But the return leg is unaffected.
        (uint256 back,) = lens.maxAmountIn(address(pool), trader, address(0));
        assertGt(back, 0, "the other direction still has room");
    }

    /// @dev The creator-cut rounding is the divergence that used to make the
    /// lens quote trades the pool refuses. Pin it with a cut configured.
    function test_ExactWithCreatorCut() public {
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p,,,) =
            factory.createAndSeed{value: 5 ether}(_m(3000, lp, 5000), MID, 5 ether, 15_000e6, 0, lp);
        vm.stopPrank();
        PrecisionPool cp = PrecisionPool(payable(p));
        vm.prank(trader);
        usdc.approve(address(cp), type(uint256).max);

        (uint256 maxIn, uint256 quoted) = lens.maxAmountIn(address(cp), trader, address(usdc));
        assertGt(maxIn, 0);

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        vm.expectRevert();
        cp.swapExactIn(address(usdc), maxIn + 1, 0, trader);
        vm.revertToState(snap);

        vm.prank(trader);
        assertEq(cp.swapExactIn(address(usdc), maxIn, 0, trader), quoted);
    }

    /// @dev Exactness must survive arbitrary pool states, not just a fresh
    /// seed. Walk the pool somewhere random, then re-check both edges.
    function testFuzz_MaxIsExactFromAnyState(uint96 warmup, bool dir) public {
        uint256 amt = uint256(warmup) % 4_000e6 + 1e6;
        if (dir) {
            vm.prank(trader);
            try pool.swapExactIn(address(usdc), amt, 0, trader) {} catch {}
        } else {
            vm.prank(trader);
            try pool.swapExactIn{value: amt * 1e9}(address(0), amt * 1e9, 0, trader) {} catch {}
        }

        (uint256 maxIn, uint256 quoted) = lens.maxAmountIn(address(pool), trader, address(usdc));
        if (maxIn == 0) {
            // Zero must mean genuinely nothing fills, not a search that gave up.
            vm.prank(trader);
            vm.expectRevert();
            pool.swapExactIn(address(usdc), 1, 0, trader);
            return;
        }

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        vm.expectRevert();
        pool.swapExactIn(address(usdc), maxIn + 1, 0, trader);
        vm.revertToState(snap);

        vm.prank(trader);
        assertEq(pool.swapExactIn(address(usdc), maxIn, 0, trader), quoted, "quote matches execution");
    }

    /// @dev Marginal price is the solver's comparison key: it must sit between
    /// the pool's bounds and move the right way as the pool fills.
    function test_MarginalPriceTracksTheBand() public {
        uint256 before = lens.marginalOutPerIn(address(pool), trader, address(0), 1 ether);
        assertGt(before, 0);

        // Buying token1 with token0 makes token0 cheaper at the margin.
        vm.prank(trader);
        pool.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        uint256 afterFill = lens.marginalOutPerIn(address(pool), trader, address(0), 1 ether);
        assertLt(afterFill, before, "each fill worsens the next unit's price");

        // And the marginal price is below the fee-free spot, by the fee.
        uint256 spot = uint256(pool.sqrtPriceCurrent());
        uint256 spotPrice = spot * spot / 1e18;
        assertLt(afterFill, spotPrice, "marginal price is net of fees");
        assertGt(afterFill, spotPrice * 99 / 100, "and only by the fee");
    }
}
