// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

contract FlatHook {
    function feeFor(address, address, uint256) external pure returns (uint256) {
        return 1000;
    }

    function afterSwap(address, address, uint256, uint256, address) external {}
}

/// @dev `swapUpTo` exists so a leg sized from a stale quote degrades to a
/// partial fill instead of reverting. That is only true if the clamp is exact:
/// it must consume everything the band can take and not one unit more.
contract PrecisionPoolPartialFillTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPoolLens lens;
    MockERC20 usdc;
    PrecisionPool pool;

    address lp = address(0xA11CE);
    address trader = address(0xB0B);

    uint256 constant LO = 42426406871192; // $1800
    uint256 constant MID = 44721359549995; // $2000
    uint256 constant HI = 46904157598234; // $2200

    function _m(address hook) internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market(address(0), address(usdc), LO, HI, 3000, hook, address(0), 0);
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
        (address p,,,) = factory.createAndSeed{value: 10 ether}(_m(address(0)), MID, 10 ether, 30_000e6, 0, lp);
        vm.stopPrank();
        pool = PrecisionPool(payable(p));

        vm.prank(trader);
        usdc.approve(address(pool), type(uint256).max);
    }

    /// @dev The headline: an oversized leg fills to the edge instead of
    /// reverting, and the unconsumed input comes back.
    function test_OversizedTradeFillsToTheEdgeAndRefunds() public {
        uint256 ask = 10_000_000e6; // far more than the band can absorb
        uint256 before = usdc.balanceOf(trader);

        // The all-or-nothing entry point refuses it.
        vm.prank(trader);
        vm.expectRevert();
        pool.swapExactIn(address(usdc), ask, 0, trader);

        vm.prank(trader);
        (uint256 out, uint256 consumed) = pool.swapUpTo(address(usdc), ask, 0, trader);

        assertGt(out, 0, "it filled");
        assertLt(consumed, ask, "and clamped");
        assertEq(usdc.balanceOf(trader), before - consumed, "the remainder was refunded");
        assertApproxEqRel(pool.sqrtPriceCurrent(), HI, 0.0001e18, "parked on the boundary");
    }

    /// @dev The clamp must agree exactly with the lens's off-chain search, and
    /// with what the all-or-nothing path would have accepted.
    function test_ClampEqualsLensMaximum() public {
        (uint256 maxIn, uint256 maxOut) = lens.maxAmountIn(address(pool), trader, address(usdc));

        vm.prank(trader);
        (uint256 out, uint256 consumed) = pool.swapUpTo(address(usdc), maxIn * 3, 0, trader);

        assertEq(consumed, maxIn, "on-chain clamp matches the off-chain search");
        assertEq(out, maxOut, "and so does the output");
    }

    /// @dev A trade that already fits must not be clamped, refunded, or priced
    /// differently from the plain path.
    function test_InBandTradeIsUnchanged() public {
        uint256 amt = 1_000e6;
        uint256 snap = vm.snapshotState();

        vm.prank(trader);
        uint256 exactOut = pool.swapExactIn(address(usdc), amt, 0, trader);
        vm.revertToState(snap);

        uint256 before = usdc.balanceOf(trader);
        vm.prank(trader);
        (uint256 out, uint256 consumed) = pool.swapUpTo(address(usdc), amt, 0, trader);

        assertEq(consumed, amt, "nothing clamped");
        assertEq(out, exactOut, "identical pricing");
        assertEq(usdc.balanceOf(trader), before - amt, "no refund path taken");
    }

    /// @dev Native input refunds ETH, not a token.
    function test_NativeInputRefunds() public {
        uint256 ask = 5_000 ether;
        uint256 before = trader.balance;

        vm.prank(trader);
        (uint256 out, uint256 consumed) = pool.swapUpTo{value: ask}(address(0), ask, 0, trader);

        assertGt(out, 0);
        assertLt(consumed, ask);
        assertEq(trader.balance, before - consumed, "unused ETH returned");
        assertApproxEqRel(pool.sqrtPriceCurrent(), LO, 0.0001e18, "parked on the floor");
    }

    /// @dev `minOut` still governs, so all-or-nothing remains expressible.
    function test_MinOutStillApplies() public {
        (, uint256 maxOut) = lens.maxAmountIn(address(pool), trader, address(usdc));
        vm.prank(trader);
        vm.expectRevert(PrecisionPool.InsufficientOutput.selector);
        pool.swapUpTo(address(usdc), 10_000_000e6, maxOut + 1, trader);
    }

    /// @dev A pool already parked at its edge has nothing to give in that
    /// direction, and says so rather than filling zero.
    function test_ExhaustedSideReverts() public {
        vm.prank(trader);
        pool.swapUpTo(address(usdc), 10_000_000e6, 0, trader);

        vm.prank(trader);
        vm.expectRevert();
        pool.swapUpTo(address(usdc), 1_000e6, 0, trader);

        // The return leg is unaffected.
        vm.prank(trader);
        (uint256 out,) = pool.swapUpTo{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertGt(out, 0, "the other direction still fills");
    }

    /// @dev Partial fill is refused on a hooked pool rather than approximated,
    /// because the surcharge is sampled at the requested size and may differ at
    /// the clamped one.
    function test_HookedPoolRefusesPartialFill() public {
        FlatHook h = new FlatHook();
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 5 ether}(_m(address(h)), MID, 5 ether, 15_000e6, 0, lp);
        vm.stopPrank();
        PrecisionPool hp = PrecisionPool(payable(p));
        vm.prank(trader);
        usdc.approve(address(hp), type(uint256).max);

        vm.prank(trader);
        vm.expectRevert(PrecisionPool.HookedNoPartialFill.selector);
        hp.swapUpTo(address(usdc), 1_000e6, 0, trader);

        // The all-or-nothing path still works there.
        vm.prank(trader);
        assertGt(hp.swapExactIn(address(usdc), 1_000e6, 0, trader), 0);
    }

    /// @dev From any state and any size, the clamp is exact: what it consumed
    /// would have succeeded on the strict path, and one unit more would not.
    function testFuzz_ClampIsExact(uint96 warmup, uint96 ask) public {
        uint256 w = uint256(warmup) % 5_000e6;
        if (w > 1e6) {
            vm.prank(trader);
            try pool.swapExactIn(address(usdc), w, 0, trader) {} catch {}
        }
        uint256 want = uint256(ask) % 50_000e6 + 1;

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        try pool.swapUpTo(address(usdc), want, 0, trader) returns (uint256 out, uint256 consumed) {
            assertGt(out, 0, "a successful partial fill produces output");
            assertLe(consumed, want, "never consumes more than offered");
            vm.revertToState(snap);

            // Exactly `consumed` must clear the strict path with the same output.
            vm.prank(trader);
            assertEq(pool.swapExactIn(address(usdc), consumed, 0, trader), out, "clamp matches strict execution");
            vm.revertToState(snap);

            // And one more unit must not, unless nothing was clamped at all.
            if (consumed < want) {
                vm.prank(trader);
                vm.expectRevert();
                pool.swapExactIn(address(usdc), consumed + 1, 0, trader);
            }
        } catch {
            // The invariant is that partial fill never fails where the strict
            // path would have succeeded. A refusal here is allowed - a request
            // too small to round to one output unit is refused whatever the
            // band's remaining room - but it must not be a regression.
            vm.revertToState(snap);
            vm.prank(trader);
            vm.expectRevert();
            pool.swapExactIn(address(usdc), want, 0, trader);
        }
    }
}
