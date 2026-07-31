// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Reproduction of the second-round audit's H-01 and M-01/M-02 vectors.
contract AuditH01Round2Test is Test {
    PrecisionPoolFactory factory;
    MockERC20 a;
    MockERC20 b;

    address lp = address(0xC11);
    address trader = address(0x7AD);

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0));
        a = new MockERC20("A", 18);
        b = new MockERC20("B", 18);
        if (address(a) > address(b)) (a, b) = (b, a);
        a.mint(lp, 1e30);
        b.mint(lp, 1e30);
        a.mint(trader, 1e30);
        b.mint(trader, 1e30);
        vm.startPrank(lp);
        a.approve(address(factory), type(uint256).max);
        b.approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }

    function _mkt(uint256 sl, uint256 sh, uint256 fee) internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(a),
            token1: address(b),
            sqrtPLow: sl,
            sqrtPHigh: sh,
            fee: fee,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    /// @dev The audit's exact numbers: a 1,056-unit token1 seed at the upper
    /// bound, then a one-share burn. Establishes what actually happens.
    function test_H01_OneShareBurnOnDustPool() public {
        PrecisionPoolFactory.Market memory m = _mkt(32e18, 33e18, 0);
        vm.prank(lp);
        (address pool,,,) = factory.createAndSeed(m, 33e18, 0, 1056, 0, lp);
        PrecisionPool p = PrecisionPool(payable(pool));

        assertEq(p.totalSupply(), 1056);
        assertEq(p.reserve1(), 1056);
        emit log_named_uint("supply", p.totalSupply());

        // Pre-burn: the audit claims a 1-unit token0 input takes the whole
        // token1 reserve. Check whether the pool is tradeable at all.
        vm.startPrank(trader);
        a.approve(pool, type(uint256).max);
        uint256 snap = vm.snapshotState();
        try p.swapExactIn(address(a), 1, 0, trader) returns (uint256 out) {
            emit log_named_uint("pre-burn out", out);
        } catch {
            emit log("pre-burn swap REVERTS");
        }
        vm.revertToState(snap);
        vm.stopPrank();

        // Burn one share.
        vm.prank(lp);
        p.removeLiquidity(1, 0, 0, lp);
        assertEq(p.totalSupply(), 1055);

        vm.startPrank(trader);
        try p.swapExactIn(address(a), 1, 0, trader) returns (uint256 out) {
            emit log_named_uint("post-burn out", out);
        } catch {
            emit log("post-burn swap REVERTS");
        }
        vm.stopPrank();
    }

    /// @dev The same shape at a realistic scale: a one-share burn must not
    /// disable swapping.
    function test_H01_OneShareBurnCannotDisableRealPool() public {
        PrecisionPoolFactory.Market memory m = _mkt(32e18, 33e18, 3000);
        vm.prank(lp);
        (address pool,,,) = factory.createAndSeed(m, 33e18, 0, 1056e18, 0, lp);
        PrecisionPool p = PrecisionPool(payable(pool));

        vm.prank(lp);
        p.removeLiquidity(1, 0, 0, lp);

        vm.startPrank(trader);
        a.approve(pool, type(uint256).max);
        uint256 out = p.swapExactIn(address(a), 1e12, 0, trader);
        assertGt(out, 0);
        vm.stopPrank();
    }

    /// @dev M-01: with a 1-pip fee, does a 2-unit trade pay 50%?
    function test_M01_MinimumFeeUnitOnDustTrade() public {
        PrecisionPoolFactory.Market memory m = _mkt(1e18, 3e18, 1);
        vm.prank(lp);
        (address pool,,,) = factory.createAndSeed(m, 2e18, 1000e18, 10000e18, 0, lp);
        PrecisionPool p = PrecisionPool(payable(pool));

        vm.startPrank(trader);
        a.approve(pool, type(uint256).max);
        uint256 out = p.swapExactIn(address(a), 2, 0, trader);
        emit log_named_uint("out for 2 in at 1 pip", out);
        vm.stopPrank();
    }
}
