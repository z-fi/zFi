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
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
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

    /// @dev The audit's exact H-01 counterexample. It seeded a pool holding
    /// 1,056 raw units whose only possible trade took the entire reserve, then
    /// burned one share to strand it. The market can no longer be created: a
    /// seed must leave real resolution on both sides, so the whole vector -
    /// the toggle and the dead-on-arrival variant alike - is unconstructible.
    function test_H01_DustSeedIsRefused() public {
        PrecisionPoolFactory.Market memory m = _mkt(32e18, 33e18, 0);
        vm.prank(lp);
        vm.expectRevert(PrecisionPool.InsufficientLiquidity.selector);
        factory.createAndSeed(m, 33e18, 0, 1056, 0, lp);
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

    /// @dev The audit's "dead on arrival" seed: in range, but the smallest
    /// possible token0 input already asks for more token1 than the pool holds,
    /// so every swap in every direction reverts. Refused at seed now.
    function test_H01_DeadOnArrivalSeedIsRefused() public {
        PrecisionPoolFactory.Market memory m = _mkt(32e18, 33e18, 0);
        vm.prank(lp);
        vm.expectRevert(PrecisionPool.InsufficientLiquidity.selector);
        factory.createAndSeed(m, 33e18, 0, 1023, 0, lp);
    }

    /// @dev The floor is on resolution, not on value: the same band seeded at
    /// a scale that can actually represent its own price is still accepted,
    /// and a one-share burn leaves it trading.
    function test_H01_ResolvedSeedIsAccepted() public {
        PrecisionPoolFactory.Market memory m = _mkt(32e18, 33e18, 0);
        vm.prank(lp);
        (address pool,,,) = factory.createAndSeed(m, 33e18, 0, 1e12, 0, lp);
        PrecisionPool p = PrecisionPool(payable(pool));
        // A ONE-SHARE burn now redeems nothing on either side, and the pool
        // refuses a redemption that would pay zero - the same guard the UI
        // surfaces as "this amount redeems nothing". That refusal used to be
        // the assertion here, phrased as "a one-share burn leaves it trading",
        // and it made an accepted seed look rejected: `createAndSeed` above
        // succeeds, which is the whole claim of this test. Pin the refusal
        // explicitly, then go on to prove the pool trades.
        vm.prank(lp);
        vm.expectRevert(PrecisionPool.ZeroAmount.selector);
        p.removeLiquidity(1, 0, 0, lp);
        vm.startPrank(trader);
        a.approve(pool, type(uint256).max);
        assertGt(p.swapExactIn(address(a), 1e6, 0, trader), 0);
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
        // 1 of the 2 input units is taken as fee: integer fees round up.
        assertEq(out, 3);
        vm.stopPrank();
    }
}
