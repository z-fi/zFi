// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev A market tuple is a name: its address is CREATE2-derived, so it can be
/// deployed exactly once and never redeployed. These tests pin that an attacker
/// cannot take a tuple away from its rightful creator, and cannot leave any
/// tuple in a state that no longer works.
contract PrecisionPoolSquatTest is Test {
    PrecisionPoolFactory factory;
    MockERC20 a;
    MockERC20 b;

    address creator = address(0xC0DE);
    address attacker = address(0xBAD);
    address trader = address(0x7AD);

    uint256 constant SL = 1e18;
    uint256 constant SH = 3e18;
    uint256 constant MID = 2e18;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        a = new MockERC20("A", 18);
        b = new MockERC20("B", 18);
        if (address(a) > address(b)) (a, b) = (b, a);
        for (uint256 i; i < 3; ++i) {
            address who = [creator, attacker, trader][i];
            a.mint(who, 1e30);
            b.mint(who, 1e30);
            vm.startPrank(who);
            a.approve(address(factory), type(uint256).max);
            b.approve(address(factory), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _mkt(address feeRecipient, uint256 bps)
        internal
        view
        returns (PrecisionPoolFactory.Market memory)
    {
        return PrecisionPoolFactory.Market({
            token0: address(a),
            token1: address(b),
            sqrtPLow: SL,
            sqrtPHigh: SH,
            fee: 3000,
            hook: address(0),
            feeRecipient: feeRecipient,
            creatorFeeBps: bps
        });
    }

    // ------------------------------------------------------ NAMED MARKETS

    /// @dev A named market belongs to its fee recipient. Nobody else can take
    /// the tuple, empty or otherwise.
    function test_AttackerCannotCreateNamedMarket() public {
        PrecisionPoolFactory.Market memory m = _mkt(creator, 2500);
        vm.prank(attacker);
        vm.expectRevert(PrecisionPoolFactory.NotCreator.selector);
        factory.createPool(m);

        vm.prank(attacker);
        vm.expectRevert(PrecisionPoolFactory.NotCreator.selector);
        factory.createAndSeed(m, MID, 100e18, 100e18, 0, attacker);
    }

    /// @dev Nor can an attacker set the initial price of a named market that
    /// the creator deployed but has not seeded yet.
    function test_AttackerCannotSeedNamedMarket() public {
        PrecisionPoolFactory.Market memory m = _mkt(creator, 2500);
        vm.prank(creator);
        address pool = factory.createPool(m);

        vm.prank(attacker);
        vm.expectRevert(PrecisionPoolFactory.NotCreator.selector);
        factory.seed(m, MID, 100e18, 100e18, 0, attacker);

        // Not through the pool directly either.
        vm.startPrank(attacker);
        a.approve(pool, type(uint256).max);
        b.approve(pool, type(uint256).max);
        vm.expectRevert(PrecisionPool.NotFactory.selector);
        PrecisionPool(payable(pool)).addLiquidityExact(MID, 100e18, 100e18, 0, attacker);
        vm.stopPrank();

        // The creator still gets their market.
        vm.prank(creator);
        (, uint256 lp,,) = factory.seed(m, MID, 100e18, 100e18, 0, creator);
        assertGt(lp, 0);
    }

    // ---------------------------------------------------- UNNAMED MARKETS

    /// @dev Anyone may deploy an unnamed market, so a griefer can create the
    /// tuple first. That must not deny the tuple to the next caller: an empty
    /// pool is seedable, including through `createAndSeed`.
    function test_PreCreatedEmptyPoolDoesNotSquatTheTuple() public {
        PrecisionPoolFactory.Market memory m = _mkt(address(0), 0);
        vm.prank(attacker);
        address squatted = factory.createPool(m);

        vm.prank(creator);
        (address pool, uint256 lp,,) = factory.createAndSeed(m, MID, 100e18, 100e18, 0, creator);
        assertEq(pool, squatted, "same CREATE2 tuple");
        assertGt(lp, 0, "creator still seeded it");
    }

    /// @dev A pool that already holds liquidity is not silently re-seeded.
    function test_SeededPoolStillRejectsCreateAndSeed() public {
        PrecisionPoolFactory.Market memory m = _mkt(address(0), 0);
        vm.prank(creator);
        factory.createAndSeed(m, MID, 100e18, 100e18, 0, creator);

        vm.prank(attacker);
        vm.expectRevert(PrecisionPoolFactory.Exists.selector);
        factory.createAndSeed(m, MID, 100e18, 100e18, 0, attacker);
    }

    /// @dev The initial price is the one power a first seeder holds. Whatever
    /// they choose, the pool must be left working: in band and tradeable.
    function testFuzz_AnySeedLeavesAWorkingPool(uint256 priceInit, uint256 amt0, uint256 amt1) public {
        priceInit = bound(priceInit, SL, SH);
        amt0 = bound(amt0, 0, 1e26);
        amt1 = bound(amt1, 0, 1e26);
        PrecisionPoolFactory.Market memory m = _mkt(address(0), 0);

        vm.prank(attacker);
        try factory.createAndSeed(m, priceInit, amt0, amt1, 0, attacker) returns (
            address pool, uint256, uint256, uint256
        ) {
            PrecisionPool p = PrecisionPool(payable(pool));
            uint256 px = p.sqrtPriceCurrent();
            assertGe(px, SL, "seeded below floor");
            assertLe(px, SH, "seeded above ceiling");

            // At least one direction must actually execute.
            vm.startPrank(trader);
            a.approve(pool, type(uint256).max);
            b.approve(pool, type(uint256).max);
            uint256 r0 = p.reserve0();
            uint256 r1 = p.reserve1();
            bool traded;
            if (r1 != 0) {
                try p.swapExactIn(address(a), r0 / 4 + 1e6, 0, trader) returns (uint256 o) {
                    traded = traded || o > 0;
                } catch {}
            }
            if (!traded && r0 != 0) {
                try p.swapExactIn(address(b), r1 / 4 + 1e6, 0, trader) returns (uint256 o) {
                    traded = traded || o > 0;
                } catch {}
            }
            assertTrue(traded, "seeded a pool nobody can trade");
            vm.stopPrank();
        } catch {
            // Refusing the seed is always an acceptable outcome: the tuple stays
            // available to the next caller.
        }
    }

    // ------------------------------------------------------------ BRICKING

    /// @dev Supply can never return to zero, so the initial price cannot be
    /// re-set by anyone once the pool is live.
    function test_PriceCannotBeReinitialised() public {
        PrecisionPoolFactory.Market memory m = _mkt(address(0), 0);
        vm.prank(creator);
        (address pool,,,) = factory.createAndSeed(m, MID, 100e18, 100e18, 0, creator);
        PrecisionPool p = PrecisionPool(payable(pool));

        vm.startPrank(creator);
        p.removeLiquidity(p.balanceOf(creator), 0, 0, creator);
        vm.stopPrank();

        assertGe(p.totalSupply(), 1000, "dead shares survive");
        // A later deposit is proportional and cannot move the price.
        uint256 before = p.sqrtPriceCurrent();
        vm.startPrank(attacker);
        a.approve(pool, type(uint256).max);
        b.approve(pool, type(uint256).max);
        p.addLiquidityExact(SL, 1e18, 1e18, 0, attacker);
        vm.stopPrank();
        // Rounding at the dead-share floor moves it a hair; what matters is
        // that the attacker's requested SL is not honoured - the price is set
        // once, at the seed, and stays there.
        assertApproxEqRel(p.sqrtPriceCurrent(), before, 1e15, "deposit moved the price");
        assertGt(p.sqrtPriceCurrent(), SL + (MID - SL) / 2, "price was re-initialised");
    }

    /// @dev Draining a pool to its dead-share floor must leave it recoverable:
    /// still in band, and tradeable again once liquidity returns.
    function test_DrainToFloorLeavesPoolRecoverable() public {
        PrecisionPoolFactory.Market memory m = _mkt(address(0), 0);
        vm.prank(creator);
        (address pool,,,) = factory.createAndSeed(m, MID, 100e18, 100e18, 0, creator);
        PrecisionPool p = PrecisionPool(payable(pool));

        vm.startPrank(creator);
        for (uint256 i; i < 60; ++i) {
            uint256 bal = p.balanceOf(creator);
            if (bal == 0) break;
            try p.removeLiquidity(bal, 0, 0, creator) {} catch {
                break;
            }
        }
        vm.stopPrank();

        uint256 px = p.sqrtPriceCurrent();
        if (px != 0) {
            assertGe(px, SL, "drained below floor");
            assertLe(px, SH, "drained above ceiling");
        }

        // Liquidity can come back, and the pool trades again.
        vm.startPrank(attacker);
        a.approve(pool, type(uint256).max);
        b.approve(pool, type(uint256).max);
        p.addLiquidityExact(0, 50e18, 50e18, 0, attacker);
        vm.stopPrank();

        vm.startPrank(trader);
        a.approve(pool, type(uint256).max);
        assertGt(p.swapExactIn(address(a), 1e18, 0, trader), 0, "pool did not recover");
        vm.stopPrank();
    }
}
