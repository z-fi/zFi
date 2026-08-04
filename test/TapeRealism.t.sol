// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PriceTape} from "../src/pools/PriceTape.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Does the on-chain tape actually hold enough to draw the chart the dapp
///      draws? This trades a real pool for a simulated day — irregular sizes,
///      both directions, and long quiet stretches — then emits exactly what
///      `tape()` returns so the real client decoder can be run against it.
///
///      Run: forge test --match-path test/TapeRealism.t.sol -vv
contract TapeRealismTest is Test {
    PrecisionPoolFactory factory;
    MockERC20 a;
    MockERC20 b;
    PrecisionPool pool;

    address lp = address(0xC11);
    address trader = address(0x7AD);

    uint256 internal t;
    uint256 internal seed = 20260801;

    function _rnd(uint256 mod) internal returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed)));
        return seed % mod;
    }

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

        PrecisionPoolFactory.Market memory m = PrecisionPoolFactory.Market({
            token0: address(a),
            token1: address(b),
            sqrtPLow: 1e18,
            sqrtPHigh: 3e18,
            fee: 3000,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
        vm.prank(lp);
        (address p,,,) = factory.createAndSeed(m, 2e18, 2_000_000e18, 8_000_000e18, 0, lp);
        pool = PrecisionPool(payable(p));

        vm.startPrank(trader);
        a.approve(address(pool), type(uint256).max);
        b.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        t = 1_767_225_600; // a fixed wall clock; the optimiser folds block.timestamp
        vm.warp(t);
    }

    function _warp(uint256 dt) internal {
        t += dt;
        vm.warp(t);
    }

    /// @dev A quiet pool: a handful of trades a day. The honest floor — how
    ///      thin does the chart get when almost nothing happens?
    function test_EmitSparseTape() public {
        uint256 swaps;
        for (uint256 i; i < 288; ++i) {
            if (_rnd(100) < 4) {
                vm.prank(trader);
                pool.swapExactIn(address(a), 1e18 + _rnd(500e18), 0, trader);
                ++swaps;
            }
            _warp(5 minutes);
        }
        emit log_named_uint("sparse swaps", swaps);
        emit log_named_bytes("FINE", abi.encode(pool.tape(pool.FINE_PERIOD(), 256)));
        emit log_named_bytes("COARSE", abi.encode(pool.tape(pool.COARSE_PERIOD(), 128)));
    }

    /// @dev Three weeks of trading, to see whether the coarse ring really does
    ///      carry the daily candles the fine ring can never reach.
    function test_EmitThreeWeekTape() public {
        for (uint256 i; i < 6048; ++i) {   // 21 days of five-minute buckets
            if (_rnd(100) < 30) {
                vm.prank(trader);
                if (_rnd(2) == 0) pool.swapExactIn(address(a), 1e18 + _rnd(3000e18), 0, trader);
                else pool.swapExactIn(address(b), 2e18 + _rnd(6000e18), 0, trader);
            }
            _warp(5 minutes);
        }
        emit log_named_bytes("FINE", abi.encode(pool.tape(pool.FINE_PERIOD(), 256)));
        emit log_named_bytes("COARSE", abi.encode(pool.tape(pool.COARSE_PERIOD(), 128)));
    }

    /// @dev A day of trading at a plausible cadence, then the raw tape returns.
    function test_EmitRealTape() public {
        uint256 swaps;
        // 288 five-minute buckets is 24 hours: longer than the 256-bar fine
        // ring, so this also exercises the wrap.
        for (uint256 i; i < 288; ++i) {
            // Roughly half the buckets see no trade at all, which is what a real
            // pool looks like and what leaves holes in the chart.
            if (_rnd(100) < 45) {
                uint256 n = 1 + _rnd(3);
                for (uint256 k; k < n; ++k) {
                    uint256 size = (1e18 + _rnd(4000e18));
                    vm.prank(trader);
                    if (_rnd(2) == 0) pool.swapExactIn(address(a), size, 0, trader);
                    else pool.swapExactIn(address(b), size * 2, 0, trader);
                    ++swaps;
                }
            }
            _warp(5 minutes);
        }

        emit log_named_uint("swaps executed", swaps);
        emit log_named_uint("now", t);
        emit log_named_bytes("FINE", abi.encode(pool.tape(pool.FINE_PERIOD(), 256)));
        emit log_named_bytes("COARSE", abi.encode(pool.tape(pool.COARSE_PERIOD(), 128)));
    }
}
