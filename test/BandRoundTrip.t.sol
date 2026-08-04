// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Does a band driven to its edge stay dead, or does it come back?
contract BandRoundTripTest is Test {
    PrecisionPoolFactory factory;
    MockERC20 usdc;
    PrecisionPool pool;

    address lp = address(0xA11CE);
    address trader = address(0xB0B);

    uint256 constant SQRT_LOW = 42426406871192; // $1800
    uint256 constant SQRT_MID = 44721359549995; // $2000
    uint256 constant SQRT_HIGH = 46904157598234; // $2200

    function _mkt() internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(usdc),
            sqrtPLow: SQRT_LOW,
            sqrtPHigh: SQRT_HIGH,
            fee: 3000,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        usdc = new MockERC20("USDC", 6);
        usdc.mint(lp, 100_000_000e6);
        usdc.mint(trader, 100_000_000e6);
        vm.deal(lp, 10_000 ether);
        vm.deal(trader, 10_000 ether);

        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 10 ether}(_mkt(), SQRT_MID, 10 ether, 30_000e6, 0, lp);
        vm.stopPrank();
        pool = PrecisionPool(payable(p));

        vm.prank(trader);
        usdc.approve(address(pool), type(uint256).max);
    }

    /// @dev Buy until the band refuses, then sell back. If the pool were
    /// bricked at its edge the return leg would revert too.
    function test_BandDrivenToItsEdgeStillTradesBack() public {
        uint256 bought;
        // Walk the price up to the ceiling in slices until no slice clears.
        for (uint256 i; i < 200; ++i) {
            vm.prank(trader);
            try pool.swapExactIn(address(usdc), 1_000e6, 0, trader) returns (uint256 out) {
                bought += out;
            } catch {
                break;
            }
        }
        assertGt(bought, 0, "the band sold into the rally");

        uint256 atEdge = pool.sqrtPriceCurrent();
        assertApproxEqRel(atEdge, SQRT_HIGH, 0.01e18, "parked at the upper bound");
        emit log_named_uint("reserve0 (ETH) at edge", pool.reserve0());
        emit log_named_uint("reserve1 (USDC) at edge", pool.reserve1());

        // Another buy is refused: it would leave the band.
        vm.prank(trader);
        vm.expectRevert();
        pool.swapExactIn(address(usdc), 1_000e6, 0, trader);

        // But the opposite direction is not refused. The pool is inert, not dead.
        vm.prank(trader);
        uint256 back = pool.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertGt(back, 0, "the band buys again on the way down");
        assertLt(pool.sqrtPriceCurrent(), atEdge, "and the price walks back into the range");

        // And it keeps working all the way back down to the far bound.
        for (uint256 i; i < 200; ++i) {
            vm.prank(trader);
            try pool.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader) {} catch {
                break;
            }
        }
        assertApproxEqRel(pool.sqrtPriceCurrent(), SQRT_LOW, 0.01e18, "walked to the opposite bound");

        // Round trip complete: sell back up again from the floor.
        vm.prank(trader);
        assertGt(pool.swapExactIn(address(usdc), 1_000e6, 0, trader), 0, "still a two-way market");
    }

    /// @dev LPs are never trapped at the edge either.
    function test_LPCanExitAtTheEdge() public {
        for (uint256 i; i < 200; ++i) {
            vm.prank(trader);
            try pool.swapExactIn(address(usdc), 1_000e6, 0, trader) {} catch {
                break;
            }
        }
        uint256 shares = pool.balanceOf(lp);
        vm.prank(lp);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(shares, 0, 0, lp);
        emit log_named_uint("withdrew ETH", a0);
        emit log_named_uint("withdrew USDC", a1);
        assertGt(a0 + a1, 0, "exit works at the boundary");
    }
}
