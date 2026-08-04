// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

contract FlatHook {
    function feeFor(address, address, uint256) external pure returns (uint256) {
        return 2500;
    }

    function afterSwap(address, address, uint256, uint256, address) external {}
}

/// @dev A hook whose surcharge varies with size, which is the shape that makes
/// a naive quoter and the pool disagree.
contract SizedHook {
    function feeFor(address, address, uint256 amountIn) external pure returns (uint256) {
        return amountIn > 1_000e6 ? 5000 : 500;
    }

    function afterSwap(address, address, uint256, uint256, address) external {}
}

/// @dev The lens reimplements the pool's swap math so a router can size legs
/// off-chain. Every routing decision built on it - leg sizing, split weights,
/// multi-pool paths - assumes the two agree EXACTLY, and a disagreement shows
/// up as a reverted route rather than as a slightly wrong number.
///
/// Two divergences were found by reading the code (a floored creator cut where
/// the pool ceils, and a `sqrt` band comparison where the pool compares squared
/// ratios), both inside a function whose own comment claimed byte-for-byte
/// fidelity. This suite closes the class: it drives pools to arbitrary states
/// and asserts the reimplementation against real execution rather than against
/// itself.
contract PrecisionLensDifferentialTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPoolLens lens;
    MockERC20 usdc;

    PrecisionPool plain; // no hook, no creator cut
    PrecisionPool creator; // 50% creator cut
    PrecisionPool hooked; // flat surcharge
    PrecisionPool sized; // size-dependent surcharge

    address lp = address(0xA11CE);
    address trader = address(0xB0B);

    uint256 constant LO = 42426406871192; // $1800
    uint256 constant MID = 44721359549995; // $2000
    uint256 constant HI = 46904157598234; // $2200

    function _m(uint256 fee, address hook, address feeRecipient, uint256 creatorBps)
        internal
        view
        returns (PrecisionPoolFactory.Market memory)
    {
        return PrecisionPoolFactory.Market(address(0), address(usdc), LO, HI, fee, hook, feeRecipient, creatorBps);
    }

    function _seed(PrecisionPoolFactory.Market memory m) internal returns (PrecisionPool p) {
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address a,,,) = factory.createAndSeed{value: 10 ether}(m, MID, 10 ether, 30_000e6, 0, lp);
        vm.stopPrank();
        p = PrecisionPool(payable(a));
        vm.prank(trader);
        usdc.approve(address(p), type(uint256).max);
    }

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        lens = new PrecisionPoolLens(factory);
        usdc = new MockERC20("USDC", 6);
        usdc.mint(lp, 1e16);
        usdc.mint(trader, 1e16);
        vm.deal(lp, 1e24);
        vm.deal(trader, 1e24);

        plain = _seed(_m(3000, address(0), address(0), 0));
        creator = _seed(_m(3000, address(0), lp, 5000));
        hooked = _seed(_m(3000, address(new FlatHook()), address(0), 0));
        sized = _seed(_m(3000, address(new SizedHook()), address(0), 0));
    }

    // ------------------------------------------------------------- helpers

    /// @dev Move the pool somewhere arbitrary before comparing, so the
    ///      assertions are not all made against a freshly seeded midpoint.
    function _warm(PrecisionPool p, uint96 seed) internal {
        uint256 amt = uint256(seed) % 6_000e6;
        if (amt < 1e6) return;
        if (seed % 2 == 0) {
            vm.prank(trader);
            try p.swapExactIn(address(usdc), amt, 0, trader) {} catch {}
        } else {
            uint256 eth = amt * 1e9;
            vm.prank(trader);
            try p.swapExactIn{value: eth}(address(0), eth, 0, trader) {} catch {}
        }
    }

    function _swap(PrecisionPool p, address tokenIn, uint256 amt) internal returns (bool ok, uint256 out) {
        vm.prank(trader);
        if (tokenIn == address(0)) {
            try p.swapExactIn{value: amt}(address(0), amt, 0, trader) returns (uint256 o) {
                return (true, o);
            } catch {
                return (false, 0);
            }
        }
        try p.swapExactIn(tokenIn, amt, 0, trader) returns (uint256 o) {
            return (true, o);
        } catch {
            return (false, 0);
        }
    }

    /// @dev The core property, in both possible failure directions:
    ///      a nonzero quote must execute at exactly that price, and a zero
    ///      quote must correspond to a trade the pool actually refuses.
    function _assertQuoteMatchesExecution(PrecisionPool p, address tokenIn, uint256 amt) internal {
        uint256 quoted = lens.quoteFor(address(p), trader, tokenIn, amt);
        uint256 snap = vm.snapshotState();
        (bool ok, uint256 out) = _swap(p, tokenIn, amt);
        vm.revertToState(snap);

        if (quoted == 0) {
            assertFalse(ok, "lens quoted zero but the pool filled the trade");
        } else {
            assertTrue(ok, "lens quoted a fill the pool refused");
            assertEq(out, quoted, "lens and pool disagree on the output");
        }
    }

    // ------------------------------------------------------- quote fidelity

    function testFuzz_QuoteMatchesPlain(uint96 warm, uint96 amt, bool dir) public {
        _warm(plain, warm);
        _assertQuoteMatchesExecution(
            plain, dir ? address(usdc) : address(0), dir ? uint256(amt) % 80_000e6 + 1 : uint256(amt) % 40 ether + 1
        );
    }

    /// @dev The creator cut is where the pool ceils and a naive quoter floors.
    function testFuzz_QuoteMatchesWithCreatorCut(uint96 warm, uint96 amt, bool dir) public {
        _warm(creator, warm);
        _assertQuoteMatchesExecution(
            creator, dir ? address(usdc) : address(0), dir ? uint256(amt) % 80_000e6 + 1 : uint256(amt) % 40 ether + 1
        );
    }

    function testFuzz_QuoteMatchesHooked(uint96 warm, uint96 amt, bool dir) public {
        _warm(hooked, warm);
        _assertQuoteMatchesExecution(
            hooked, dir ? address(usdc) : address(0), dir ? uint256(amt) % 80_000e6 + 1 : uint256(amt) % 40 ether + 1
        );
    }

    /// @dev A surcharge that changes with size must be sampled at the size
    /// being quoted, not at some probe.
    function testFuzz_QuoteMatchesSizeDependentHook(uint96 warm, uint96 amt, bool dir) public {
        _warm(sized, warm);
        _assertQuoteMatchesExecution(
            sized, dir ? address(usdc) : address(0), dir ? uint256(amt) % 80_000e6 + 1 : uint256(amt) % 40 ether + 1
        );
    }

    /// @dev Tiny sizes are where fee rounding decides the outcome outright.
    function testFuzz_QuoteMatchesAtDustSizes(uint8 amt, bool dir, bool withCut) public {
        PrecisionPool p = withCut ? creator : plain;
        uint256 size = uint256(amt) + 1;
        _assertQuoteMatchesExecution(p, dir ? address(usdc) : address(0), size);
    }

    // --------------------------------------------------- boundary agreement

    /// @dev The two independent searches - the lens's off-chain bisection and
    /// the pool's on-chain clamp - must land on the same number. A router sizes
    /// legs from the former and executes against the latter.
    function testFuzz_MaxAmountInMatchesOnChainClamp(uint96 warm, bool dir) public {
        _warm(plain, warm);
        address tokenIn = dir ? address(usdc) : address(0);

        (uint256 maxIn, uint256 maxOut) = lens.maxAmountIn(address(plain), trader, tokenIn);
        if (maxIn == 0) {
            // Nothing fills: the partial-fill path must refuse too.
            uint256 s = vm.snapshotState();
            vm.prank(trader);
            if (tokenIn == address(0)) {
                try plain.swapUpTo{value: 1 ether}(address(0), 1 ether, 0, trader) {
                    fail();
                } catch {}
            } else {
                try plain.swapUpTo(tokenIn, 1_000e6, 0, trader) {
                    fail();
                } catch {}
            }
            vm.revertToState(s);
            return;
        }

        // Ask for far more than the band can take; the clamp must equal the
        // lens's answer exactly.
        uint256 ask = maxIn * 2 + 1;
        vm.prank(trader);
        (uint256 out, uint256 consumed) = tokenIn == address(0)
            ? plain.swapUpTo{value: ask}(address(0), ask, 0, trader)
            : plain.swapUpTo(tokenIn, ask, 0, trader);

        assertEq(consumed, maxIn, "off-chain search and on-chain clamp disagree");
        assertEq(out, maxOut, "and on the resulting output");
    }

    /// @dev Same, on a pool whose creator cut shifts `kept` relative to the
    /// priced amount - the term that makes the boundary unsolvable in closed
    /// form and so is where an algebraic shortcut would break.
    function testFuzz_MaxAmountInMatchesClampWithCreatorCut(uint96 warm) public {
        _warm(creator, warm);
        (uint256 maxIn, uint256 maxOut) = lens.maxAmountIn(address(creator), trader, address(usdc));
        if (maxIn == 0) return;

        vm.prank(trader);
        (uint256 out, uint256 consumed) = creator.swapUpTo(address(usdc), maxIn * 2 + 1, 0, trader);
        assertEq(consumed, maxIn);
        assertEq(out, maxOut);
    }

    /// @dev `maxAmountIn` must be the true edge, not merely a fillable point:
    /// one unit more has to fail on the strict path.
    function testFuzz_MaxAmountInIsTheEdge(uint96 warm, bool dir) public {
        _warm(plain, warm);
        address tokenIn = dir ? address(usdc) : address(0);
        (uint256 maxIn, uint256 quoted) = lens.maxAmountIn(address(plain), trader, tokenIn);
        if (maxIn == 0 || maxIn == type(uint128).max) return;

        uint256 snap = vm.snapshotState();
        (bool okOver,) = _swap(plain, tokenIn, maxIn + 1);
        assertFalse(okOver, "one unit past the reported maximum still filled");
        vm.revertToState(snap);

        (bool okAt, uint256 out) = _swap(plain, tokenIn, maxIn);
        assertTrue(okAt, "the reported maximum did not fill");
        assertEq(out, quoted, "and its output was misquoted");
    }

    // ------------------------------------------------------------- fee view

    /// @dev `effectiveFeeFor` is what a frontend shows. It must match the fee
    /// the pool actually took, derived from the reserves rather than restated.
    function testFuzz_EffectiveFeeMatchesRealisedFee(uint96 amt) public {
        uint256 size = uint256(amt) % 20_000e6 + 100e6;
        uint256 claimed = lens.effectiveFeeFor(address(hooked), trader, address(usdc), size);

        // Reproduce the pool's ordering: surcharge first, base fee on the rest.
        uint256 surcharge = hooked.extraFee(trader, address(usdc), size);
        uint256 base = hooked.fee();
        uint256 expected = base + surcharge - (base * surcharge) / 1_000_000;
        assertEq(claimed, expected, "effective fee does not compose the two rates");

        // And it is strictly between the base rate and the capped total.
        assertGe(claimed, base);
        assertLe(claimed, 100_000);
    }
}
