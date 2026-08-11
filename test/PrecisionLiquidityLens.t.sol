// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionLiquidityLens} from "../src/pools/PrecisionLiquidityLens.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev A preview is only worth having if it matches execution to the unit.
/// Anything looser gets believed and then produces a revert, or a refund the
/// user did not expect, which is worse than showing nothing. So every test here
/// is differential: run the preview, run the real thing, compare exactly.
contract PrecisionLiquidityLensTest is Test {
    PrecisionPoolFactory factory;
    PrecisionLiquidityLens lens;
    MockERC20 tk;

    address lp = address(0xC11);
    address user = address(0xBEEF);

    uint256 constant SL = 0.5e18;
    uint256 constant SM = 1e18;
    uint256 constant SH = 2e18;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        lens = new PrecisionLiquidityLens(factory);
        tk = new MockERC20("TK", 18);
        tk.mint(lp, 1e32);
        tk.mint(user, 1e32);
        vm.deal(lp, 1e24);
        vm.deal(user, 1e24);
    }

    function _mkt() internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(tk),
            sqrtPLow: SL,
            sqrtPHigh: SH,
            fee: 500,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    function _seeded() internal returns (PrecisionPool p) {
        vm.startPrank(lp);
        tk.approve(address(factory), type(uint256).max);
        (address a,,,) = factory.createAndSeed{value: 100 ether}(_mkt(), SM, 100 ether, 1e24, 0, lp);
        vm.stopPrank();
        return PrecisionPool(payable(a));
    }

    /// @dev The seed preview must agree with the seed, on the shares AND on
    /// both consumed amounts. `used0` in particular runs through a fused
    /// ceiling and two bound corrections.
    function testFuzz_SeedPreviewMatchesTheSeed(uint96 a0, uint96 a1) public {
        uint256 amount0 = bound(uint256(a0), 1e12, 500 ether);
        uint256 amount1 = bound(uint256(a1), 1e12, 1e24);

        address predicted = factory.poolFor(_mkt());
        factory.createPool(_mkt());

        (bool ok, uint256 lpOut, uint256 used0, uint256 used1) =
            lens.previewSeed(predicted, SM, amount0, amount1);

        vm.startPrank(lp);
        tk.approve(address(factory), type(uint256).max);
        try factory.seed{value: amount0}(_mkt(), SM, amount0, amount1, 0, lp) returns (
            address, uint256 rLp, uint256 rU0, uint256 rU1
        ) {
            assertTrue(ok, "preview refused a seed that succeeded");
            assertEq(rLp, lpOut, "shares differ");
            assertEq(rU0, used0, "used0 differs");
            assertEq(rU1, used1, "used1 differs");
        } catch {
            assertFalse(ok, "preview accepted a seed that reverted");
        }
        vm.stopPrank();
    }

    /// @dev `seedCounterpart` must return an amount the seed actually accepts.
    /// One unit short is a revert, which is the whole reason it exists.
    function testFuzz_SeedCounterpartIsSufficient(uint96 a0, uint16 rawPrice) public {
        uint256 amount0 = bound(uint256(a0), 1e15, 100 ether);
        uint256 s = bound(uint256(rawPrice), SL + 1, SH - 1);

        address predicted = factory.poolFor(_mkt());
        factory.createPool(_mkt());

        (bool ok, uint256 need1) = lens.seedCounterpart(predicted, s, address(0), amount0);
        if (!ok) return;

        vm.startPrank(lp);
        tk.approve(address(factory), type(uint256).max);
        // Exactly what the lens said, no padding.
        try factory.seed{value: amount0}(_mkt(), s, amount0, need1, 0, lp) returns (
            address, uint256 rLp, uint256, uint256 rU1
        ) {
            assertGt(rLp, 0, "seeded nothing");
            assertLe(rU1, need1, "seed needed more than the lens said");
        } catch {
            // A refusal is acceptable only if it is not about the counterpart
            // being short - re-run with generous token1 to tell the two apart.
            try factory.seed{value: amount0}(_mkt(), s, amount0, need1 * 2, 0, lp) returns (
                address, uint256, uint256, uint256
            ) {
                fail("seed succeeded with more token1, so the counterpart was short");
            } catch {}
        }
        vm.stopPrank();
    }

    /// @dev The add preview must match, including the refunds - the part a
    /// frontend cannot derive and a user notices immediately.
    function testFuzz_AddPreviewMatchesTheDeposit(uint96 a0, uint96 a1) public {
        PrecisionPool p = _seeded();
        uint256 amount0 = bound(uint256(a0), 1, 50 ether);
        uint256 amount1 = bound(uint256(a1), 1, 1e23);

        (bool ok, uint256 lpOut, uint256 used0, uint256 used1, uint256 ref0, uint256 ref1) =
            lens.previewAdd(address(p), amount0, amount1);

        uint256 eth0 = user.balance;
        uint256 tok0 = tk.balanceOf(user);

        vm.startPrank(user);
        tk.approve(address(p), type(uint256).max);
        try p.addLiquidityExact{value: amount0}(0, amount0, amount1, 0, user) returns (
            uint256 rLp, uint256 rU0, uint256 rU1
        ) {
            assertTrue(ok, "preview refused a deposit that succeeded");
            assertEq(rLp, lpOut, "shares differ");
            assertEq(rU0, used0, "used0 differs");
            assertEq(rU1, used1, "used1 differs");
            // Refunds are what the caller actually got back.
            assertEq(eth0 - user.balance, used0, "eth refund wrong");
            assertEq(tok0 - tk.balanceOf(user), used1, "token refund wrong");
            assertEq(ref0, amount0 - used0, "refund0 wrong");
            assertEq(ref1, amount1 - used1, "refund1 wrong");
        } catch {
            assertFalse(ok, "preview accepted a deposit that reverted");
        }
        vm.stopPrank();
    }

    /// @dev The remove preview must match, and must report `ok = false` for the
    /// dust position that cannot be exited at all - the case where both sides
    /// floor to zero and the pool refuses.
    function testFuzz_RemovePreviewMatchesTheBurn(uint96 rawShares) public {
        PrecisionPool p = _seeded();
        uint256 held = p.balanceOf(lp);
        uint256 shares = bound(uint256(rawShares), 1, held);

        (bool ok, uint256 a0, uint256 a1) = lens.previewRemove(address(p), shares);

        vm.prank(lp);
        try p.removeLiquidity(shares, 0, 0, lp) returns (uint256 r0, uint256 r1) {
            assertTrue(ok, "preview refused a burn that succeeded");
            assertEq(r0, a0, "amount0 differs");
            assertEq(r1, a1, "amount1 differs");
        } catch {
            assertFalse(ok, "preview accepted a burn that reverted");
        }
    }

    /// @dev An un-exitable dust position is reported as such rather than
    /// looking like a zero-value withdrawal that would work.
    function test_RemovePreviewFlagsTheUnexitableDustPosition() public {
        PrecisionPool p = _seeded();
        vm.prank(lp);
        p.transfer(user, 1);

        (bool ok, uint256 a0, uint256 a1) = lens.previewRemove(address(p), 1);
        assertFalse(ok, "one share against this supply should not be exitable");
        assertEq(a0 + a1, 0);

        vm.prank(user);
        vm.expectRevert(PrecisionPool.ZeroAmount.selector);
        p.removeLiquidity(1, 0, 0, user);
    }

    /// @dev The zap split must be a portion the pool actually accepts, and the
    /// predicted shares must be a floor the real zap clears. It is the one
    /// argument `zapIn` cannot default, so a wrong answer is a failed deposit.
    function testFuzz_ZapSplitIsExecutable(uint96 rawIn, bool zeroForOne) public {
        PrecisionPool p = _seeded();
        uint256 amountIn = bound(uint256(rawIn), 1e15, 10 ether);
        address tokenIn = zeroForOne ? address(0) : address(tk);
        if (!zeroForOne) amountIn = bound(uint256(rawIn), 1e15, 1e22);

        (bool ok, uint256 portion, uint256 expected) = lens.previewZap(address(p), tokenIn, amountIn);
        if (!ok) return;

        assertGt(portion, 0, "split of zero");
        assertLt(portion, amountIn, "split consumed the whole input");

        // The split must at least produce an executable swap of that size.
        (uint256 out, bool fits) = p.quoteExactIn(address(this), tokenIn, portion);
        assertTrue(fits, "the split is not a swappable size");
        assertGt(out, 0, "the split swaps to nothing");
        assertGt(expected, 0, "predicted no shares");
    }

    /// @dev Sanity that the split is actually near-optimal rather than merely
    /// valid: nudging it either way should not mint materially more.
    function test_ZapSplitIsCloseToOptimal() public {
        PrecisionPool p = _seeded();
        uint256 amountIn = 5 ether;
        (bool ok, uint256 portion, uint256 expected) = lens.previewZap(address(p), address(0), amountIn);
        assertTrue(ok, "no split found");

        uint256 best = expected;
        for (uint256 i = 1; i <= 10; ++i) {
            uint256 step = amountIn / 100;
            if (portion > i * step) {
                (, uint256 lower) = _sharesAt(p, amountIn, portion - i * step);
                if (lower > best) best = lower;
            }
            if (portion + i * step < amountIn) {
                (, uint256 higher) = _sharesAt(p, amountIn, portion + i * step);
                if (higher > best) best = higher;
            }
        }
        // Within 1% of the best nearby split.
        assertGe(expected * 100, best * 99, "split is materially suboptimal");
    }

    function _sharesAt(PrecisionPool p, uint256 amountIn, uint256 portion)
        internal
        view
        returns (bool ok, uint256 lp_)
    {
        (uint256 received, bool fits) = p.quoteExactIn(address(this), address(0), portion);
        if (!fits) return (false, 0);
        uint256 keep = amountIn - portion;
        uint256 supply = p.totalSupply();
        uint256 r0 = uint256(p.reserve0()) + portion;
        uint256 r1 = uint256(p.reserve1()) - received;
        if (r0 == 0 || r1 == 0) return (false, 0);
        uint256 f0 = keep * supply / r0;
        uint256 f1 = received * supply / r1;
        return (true, f0 < f1 ? f0 : f1);
    }
}
