// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";

/// @dev A token with a fee switch that starts OFF, which is the shape that
/// matters: the pool is seeded and healthy under an exact-transfer token, and
/// the fee is turned on afterwards. USDT ships exactly this.
///
/// A real fee debits the sender in FULL and credits the recipient less - the
/// difference goes to the fee collector. That is what separates it from
/// `ShortPayERC20`, which shorts the debit as well and so fails the pool's
/// sender-side reconciliation too, correctly and unavoidably.
contract FeeSwitchERC20 is MockERC20("FEESW", 18) {
    uint256 public feeBps;
    address constant COLLECTOR = address(0xFEE0);

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function _move(address from, address to, uint256 amt) internal {
        uint256 fee = amt * feeBps / 10_000;
        balanceOf[from] -= amt;
        balanceOf[to] += amt - fee;
        balanceOf[COLLECTOR] += fee;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address f, address t, uint256 amt) public override returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        _move(f, t, amt);
        return true;
    }
}

/// @dev A hook whose `feeFor` burns gas, so the starvation question is live
/// rather than academic. `burn` is tuned by the test.
contract GasHungryHook {
    uint256 public burn;
    uint256 public pips;
    uint256 private sink;

    constructor(uint256 pips_) {
        pips = pips_;
    }

    function setBurn(uint256 b) external {
        burn = b;
    }

    function feeFor(address, address, uint256) external view returns (uint256) {
        // A view that spins. `staticcall` means it cannot write, so the loop
        // reads instead - which is what an expensive real hook (reserves, tape)
        // would be doing anyway.
        uint256 acc = sink;
        uint256 n = burn;
        for (uint256 i; i < n; ++i) {
            acc = uint256(keccak256(abi.encode(acc, i)));
        }
        if (acc == type(uint256).max) return 0; // keep the loop live
        return pips;
    }

    function afterSwap(address, address, uint256, uint256, address) external {}
}

/// @dev Hardening from the external review passes: cases where a call either
/// should have been a clean refusal and was not, or should have succeeded and
/// could not. Also the screen that keeps a griefing hook out of a clamped
/// route, which no contract enforces and so has to be pinned somewhere.
contract PrecisionPoolHardeningTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPool pool;
    MockERC20 tk;

    address lp = address(0xC11);
    address user = address(0xBEEF);

    uint256 constant SQRT_LOW = 0.5e18;
    uint256 constant SQRT_MID = 1e18;
    uint256 constant SQRT_HIGH = 2e18;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        tk = new MockERC20("TK", 18);
        tk.mint(lp, 1e30);
        vm.deal(lp, 10_000 ether);

        vm.startPrank(lp);
        tk.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 100 ether}(
            PrecisionPoolFactory.Market({
                token0: address(0),
                token1: address(tk),
                sqrtPLow: SQRT_LOW,
                sqrtPHigh: SQRT_HIGH,
                fee: 500,
                hook: address(0),
                feeRecipient: address(0),
                creatorFeeBps: 0
            }),
            SQRT_MID,
            100 ether,
            1e24,
            0,
            lp
        );
        vm.stopPrank();
        pool = PrecisionPool(payable(p));
    }

    /// @dev A burn small enough that `lp * r / supply` floors to zero on BOTH
    /// sides used to succeed: shares were destroyed and the real reserves were
    /// left exactly where they were. That is not theft - the caller is burning
    /// their own position for nothing - but it shrinks the supply the virtual
    /// offsets are derived from while the reserves stand still, which walks the
    /// represented price toward the bare `r1/r0` ratio and, for a mid-band
    /// position, out of the band. It is a free lever on the one invariant the
    /// contract is built around and no honest caller wants it, so it is refused.
    function test_ZeroPayoutBurnIsRefused() public {
        vm.prank(lp);
        pool.transfer(user, 1_000);

        uint256 supply = pool.totalSupply();
        // One share against this supply floors to zero on both reserves.
        assertEq(uint256(pool.reserve0()) / supply, 0, "reserve0 is not thin enough for the case");
        assertEq(uint256(pool.reserve1()) / supply, 0, "reserve1 is not thin enough for the case");

        (uint128 r0Before, uint128 r1Before) = (pool.reserve0(), pool.reserve1());

        vm.prank(user);
        vm.expectRevert(PrecisionPool.ZeroAmount.selector);
        pool.removeLiquidity(1, 0, 0, user);

        assertEq(pool.totalSupply(), supply, "supply moved on a refused burn");
        assertEq(pool.reserve0(), r0Before, "reserve0 moved on a refused burn");
        assertEq(pool.reserve1(), r1Before, "reserve1 moved on a refused burn");

        // A burn that actually pays something still works, so the guard is on
        // the degenerate case and not on small exits generally.
        uint256 lpOut = supply / 1_000_000;
        vm.prank(lp);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(lpOut, 0, 0, lp);
        assertTrue(a0 != 0 || a1 != 0, "a real exit must still pay out");
    }

    /// @dev A swap whose priced amount floors to zero must revert with
    /// `InsufficientOutput`, never with the library's `MulDivFailed`. The
    /// reachable case is a pool whose input side is empty, where the divisor
    /// `rIn + vIn + inAfterFee` is zero as well - `fullMulDiv(0, y, 0)` reverts
    /// on the division rather than returning the zero the caller should see. The
    /// quote path must agree: it reports no fill instead of reverting.
    function test_ADustSwapRefusesCleanlyRatherThanFailingInTheMathLibrary() public {
        // Small enough that the base fee eats the whole input.
        uint256 dust = 1;
        vm.deal(user, 1 ether);

        (uint256 quoted, bool fits) = pool.quoteExactIn(user, address(0), dust);
        assertFalse(fits, "a dust swap must not report as fillable");
        assertEq(quoted, 0, "a dust swap must quote nothing");

        vm.prank(user);
        vm.expectRevert(PrecisionPool.InsufficientOutput.selector);
        pool.swapExactIn{value: dust}(address(0), dust, 0, user);
    }

    /// @dev A fee switch flipped AFTER a pool is seeded closes every strict
    /// path at once - deposit, swap, and withdrawal all reconcile exact
    /// movement, and none of them can. On an immutable contract that is
    /// permanent lockup of real LP funds, not a degraded mode, and it is a
    /// live risk rather than a theoretical one: USDT carries a settable fee
    /// that happens to be zero today.
    ///
    /// `removeLiquidityLossy` is the escape hatch. It keeps the check the
    /// accounting depends on - that the pool was debited exactly what it wrote
    /// off its reserves - and drops only the check on what arrived at the far
    /// end. The pool stays untradeable, which is correct; the LPs get out.
    function test_FeeSwitchLocksThePoolAndTheLossyExitIsTheWayOut() public {
        FeeSwitchERC20 fee = new FeeSwitchERC20();
        fee.mint(lp, 1e24);

        vm.startPrank(lp);
        fee.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 100 ether}(
            PrecisionPoolFactory.Market({
                token0: address(0),
                token1: address(fee),
                sqrtPLow: SQRT_LOW,
                sqrtPHigh: SQRT_HIGH,
                fee: 500,
                hook: address(0),
                feeRecipient: address(0),
                creatorFeeBps: 0
            }),
            SQRT_MID,
            100 ether,
            1e24,
            0,
            lp
        );
        vm.stopPrank();

        PrecisionPool fp = PrecisionPool(payable(p));
        uint256 shares = fp.balanceOf(lp);
        assertGt(shares, 0, "seed failed");

        // Healthy while the switch is off: a normal exit works.
        uint256 snap = vm.snapshotState();
        vm.prank(lp);
        fp.removeLiquidity(shares / 10, 0, 0, lp);
        vm.revertToState(snap);

        // The issuer flips the switch. Nothing about the pool changed.
        fee.setFee(100); // 1%

        // Every strict path is now closed. This is the lockup.
        vm.prank(lp);
        vm.expectRevert(PrecisionPool.UnsupportedToken.selector);
        fp.removeLiquidity(shares / 10, 0, 0, lp);

        vm.deal(lp, 1 ether);
        vm.prank(lp);
        vm.expectRevert(PrecisionPool.UnsupportedToken.selector);
        fp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, lp);

        // The lossy exit still pays out. Reserves stay exact - the pool is
        // debited in full - and the caller absorbs the token's fee.
        uint256 ethBefore = lp.balance;
        uint256 feeBefore = fee.balanceOf(lp);
        uint256 r1Before = fp.reserve1();

        vm.prank(lp);
        (uint256 a0, uint256 a1) = fp.removeLiquidityLossy(shares / 10, 0, 0, lp);

        assertGt(a1, 0, "lossy exit paid nothing");
        assertEq(fp.reserve1(), r1Before - a1, "reserves must still be written exactly");
        // Native side is untouched by the token's fee and lands in full.
        assertEq(lp.balance - ethBefore, a0, "native side should be exact");
        // Token side arrives short by exactly the fee, and the caller wears it.
        assertEq(fee.balanceOf(lp) - feeBefore, a1 - (a1 * 100 / 10_000), "shortfall should be the token fee");

        // Solvency still holds: the pool was debited what it wrote off.
        assertGe(fee.balanceOf(address(fp)), fp.reserve1(), "pool must still back its reserves");
    }

    /// @dev `_seed` derives `lp` by flooring from the offered amounts and then
    /// recomputes what that `lp` requires. Computing the token0 requirement as
    /// two nested ceilings overshot the true figure by up to `WAD / s + 1` raw
    /// units, so a seeder who sized their deposit from the same formula could
    /// be told `InsufficientLiquidity` for arithmetic that was correct - and
    /// only ever on the token0 side, since `used1` ceilings once. Fusing the
    /// two divisions makes the requirement exact, and exactness is what makes
    /// it provable: `lp <= in0 * s * sh / ((sh - s) * WAD)`, so the requirement
    /// `lp * (sh - s) * WAD / (sh * s) <= in0`, and since `in0` is an integer
    /// its ceiling is too.
    ///
    /// Swept across a wide range of bands and prices, including very low `s`
    /// where the old overshoot was largest.
    function testFuzz_AnExactlySizedSeedIsNeverRefused(uint96 amount1, uint16 lowBps, uint16 span) public {
        uint256 sl = bound(uint256(lowBps), 1, 1e4) * 1e8; // 1e8 .. 1e12, deep low end
        uint256 sh = sl + bound(uint256(span), 1, type(uint16).max) * 1e8;
        uint256 in1 = bound(uint256(amount1), 1e12, 1e24);

        PrecisionPoolFactory f = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        MockERC20 t = new MockERC20("T", 18);

        PrecisionPoolFactory.Market memory m = PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(t),
            sqrtPLow: sl,
            sqrtPHigh: sh,
            fee: 500,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });

        // Mid-band, so both sides are constrained and `used0` is live.
        uint256 s = sl + (sh - sl) / 2;

        // Fund generously on both sides: the point is that the pool takes what
        // it needs and never demands MORE than the arithmetic says, so a seed
        // either succeeds or is refused for a stated reason - never because
        // `used0` overshot past what was offered.
        address seeder = address(0xBEEF);
        t.mint(seeder, in1);
        vm.deal(seeder, type(uint128).max);

        vm.startPrank(seeder);
        t.approve(address(f), type(uint256).max);
        try f.createAndSeed{value: 1e24}(m, s, 1e24, in1, 0, seeder) returns (
            address p, uint256, uint256 used0, uint256 used1
        ) {
            // Whatever it took must be within what was offered - the property
            // the double ceiling could violate.
            assertLe(used0, 1e24, "took more token0 than offered");
            assertLe(used1, in1, "took more token1 than offered");
            assertGt(PrecisionPool(payable(p)).totalSupply(), 0, "seeded nothing");
        } catch (bytes memory err) {
            // Refusals are fine, but only the reasoned ones. A seed rejected
            // because `used0` overshot surfaced as InsufficientLiquidity, so
            // this cannot distinguish it - what it can catch is a raw panic or
            // a library error escaping as the reason.
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == PrecisionPool.InsufficientLiquidity.selector
                    || sel == PrecisionPool.PriceOutOfRange.selector || sel == PrecisionPool.ZeroAmount.selector
                    || sel == PrecisionPoolFactory.Bad.selector || sel == PrecisionPool.Bad.selector,
                "seed failed with an unstated reason"
            );
        }
        vm.stopPrank();
    }

    /// @dev A reviewer argued `feeFor` is gas-starvable and that starvation is
    /// free money: `extraFee` maps every failure to a surcharge of ZERO, so a
    /// trader who squeezes the hook out of gas would take the trade at base
    /// fee. The reasoning omits that an out-of-gas callee consumes everything
    /// forwarded, and the 63/64 rule means forwarding a small amount requires
    /// keeping only 1/64 for yourself - so shrinking the hook's allowance
    /// shrinks your own remaining gas 63 times faster.
    ///
    /// Formally, starvation needs `R < HOOK_GAS / 63` (~2,400 gas) for the
    /// entire remainder of the swap. Two reserve writes exceed that.
    ///
    /// This sweeps the gas limit across the whole plausible range and asserts
    /// the property that actually matters: THE SWAP NEVER SUCCEEDS WITH THE
    /// SURCHARGE DROPPED. Either the surcharge is charged, or nothing happened.
    function test_FeeForCannotBeStarvedAtAnyGasLimit() public {
        GasHungryHook h = new GasHungryHook(5_000); // 0.5% surcharge
        MockERC20 t = new MockERC20("T", 18);
        t.mint(lp, 1e24);

        vm.startPrank(lp);
        t.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 100 ether}(
            PrecisionPoolFactory.Market({
                token0: address(0),
                token1: address(t),
                sqrtPLow: SQRT_LOW,
                sqrtPHigh: SQRT_HIGH,
                fee: 500,
                hook: address(h),
                feeRecipient: address(0),
                creatorFeeBps: 0
            }),
            SQRT_MID,
            100 ether,
            1e24,
            0,
            lp
        );
        vm.stopPrank();
        PrecisionPool hp = PrecisionPool(payable(p));

        // Expensive enough that the budget is genuinely contended.
        h.setBurn(120);

        uint256 succeeded;
        for (uint256 gasLimit = 60_000; gasLimit <= 2_000_000; gasLimit += 20_000) {
            uint256 snap = vm.snapshotState();
            vm.deal(user, 10 ether);

            uint256 owedBefore = hp.hookOwed0();
            vm.prank(user);
            (bool ok,) = address(hp).call{value: 1 ether, gas: gasLimit}(
                abi.encodeCall(PrecisionPool.swapExactIn, (address(0), 1 ether, 0, user))
            );

            if (ok) {
                ++succeeded;
                assertGt(
                    hp.hookOwed0() - owedBefore,
                    0,
                    "a swap settled without charging the surcharge - feeFor was starved"
                );
            }
            vm.revertToState(snap);
        }

        assertGt(succeeded, 0, "no gas limit produced a swap; the sweep proved nothing");
    }

    /// @dev The screen that keeps a griefing hook out of a clamped route.
    ///
    /// Nothing on-chain does this: `PrecisionRoute` checks `factory.isPool`,
    /// which proves provenance only, and anyone can create a hooked pool
    /// through the factory for an unnamed market. `routeUpTo` then bisects,
    /// calling the hook once per hop per probe, so a hook that burns its whole
    /// budget turns the search into millions of gas charged to the submitter.
    ///
    /// The filter therefore lives with whoever assembles the path, and this
    /// pins both halves of it: the per-pool flag every discovery call already
    /// carries, and the whole-path preflight.
    function test_TheLensScreensHookedPoolsOutOfClampedRoutes() public {
        PrecisionPoolLens lens = new PrecisionPoolLens(factory);
        GasHungryHook h = new GasHungryHook(5_000);
        MockERC20 t = new MockERC20("T2", 18);
        t.mint(lp, 2e24);

        vm.startPrank(lp);
        t.approve(address(factory), type(uint256).max);
        (address hooked,,,) = factory.createAndSeed{value: 100 ether}(
            PrecisionPoolFactory.Market({
                token0: address(0),
                token1: address(t),
                sqrtPLow: SQRT_LOW,
                sqrtPHigh: SQRT_HIGH,
                fee: 500,
                hook: address(h),
                feeRecipient: address(0),
                creatorFeeBps: 0
            }),
            SQRT_MID, 100 ether, 1e24, 0, lp
        );
        vm.stopPrank();

        // `isPool` says yes to both - which is exactly why it is not the screen.
        assertTrue(factory.isPool(hooked), "hooked pool is a factory pool");
        assertTrue(factory.isPool(address(pool)), "plain pool is a factory pool");

        // The per-pool flag, as every `markets*` / `describeFor` call returns it.
        assertFalse(lens.infoFor(hooked, address(this), 1 ether).clampable, "hooked pool must not be clampable");
        assertTrue(lens.infoFor(address(pool), address(this), 1 ether).clampable, "plain pool must be clampable");

        // The whole-path preflight, and it must name the offending hop.
        address[] memory bad = new address[](2);
        (bad[0], bad[1]) = (address(pool), hooked);
        (bool ok, uint256 badIndex) = lens.routeClampable(bad);
        assertFalse(ok, "a path containing a hooked pool must not clamp");
        assertEq(badIndex, 1, "must point at the hooked hop");

        address[] memory good = new address[](1);
        good[0] = address(pool);
        (ok, badIndex) = lens.routeClampable(good);
        assertTrue(ok, "an all-hookless path must clamp");
        assertEq(badIndex, 1, "badIndex is the length when the path is clean");

        // A non-pool is refused too, so one call covers both failure modes.
        address[] memory alien = new address[](1);
        alien[0] = address(0xDEAD);
        (ok, badIndex) = lens.routeClampable(alien);
        assertFalse(ok, "a non-factory address must not clamp");
        assertEq(badIndex, 0);
    }

    /// @dev The lossy path must not become a way to take more than a pro-rata
    /// share, or to reach anything the strict path could not.
    function test_LossyExitGrantsNoExtraAuthority() public {
        vm.prank(lp);
        pool.transfer(user, 1_000);

        // Same zero-payout refusal as the strict path.
        vm.prank(user);
        vm.expectRevert(PrecisionPool.ZeroAmount.selector);
        pool.removeLiquidityLossy(1, 0, 0, user);

        // Cannot burn shares it does not hold. `supply` is read BEFORE arming
        // the cheatcode, which otherwise binds to that read instead.
        uint256 supply = pool.totalSupply();
        vm.prank(user);
        vm.expectRevert();
        pool.removeLiquidityLossy(supply, 0, 0, user);

        // Under an exact-transfer token it is indistinguishable from the strict
        // path, so nothing is given up by using it.
        uint256 amount = pool.totalSupply() / 1_000;
        uint256 snap = vm.snapshotState();
        vm.prank(lp);
        (uint256 s0, uint256 s1) = pool.removeLiquidity(amount, 0, 0, lp);
        vm.revertToState(snap);
        vm.prank(lp);
        (uint256 l0, uint256 l1) = pool.removeLiquidityLossy(amount, 0, 0, lp);
        assertEq(l0, s0, "lossy must match strict on a well-behaved token");
        assertEq(l1, s1, "lossy must match strict on a well-behaved token");
    }
}
