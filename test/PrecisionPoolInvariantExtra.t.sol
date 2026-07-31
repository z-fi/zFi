// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {ConstantSurchargeHook} from "../src/pools/ConstantSurchargeHook.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Stateful driver shared by the configurations below.
contract XHandler is Test {
    PrecisionPool public pool;
    MockERC20 public tk;
    address[] actors;

    constructor(PrecisionPool p, MockERC20 t) {
        pool = p;
        tk = t;
        for (uint256 i; i < 3; ++i) {
            address a = address(uint160(0xB000 + i));
            actors.push(a);
            vm.deal(a, 10_000 ether);
            t.mint(a, 1e34);
            vm.prank(a);
            t.approve(address(p), type(uint256).max);
        }
    }

    function _a(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function swap0(uint256 s, uint256 amt) public {
        amt = bound(amt, 1, 50 ether);
        address a = _a(s);
        vm.prank(a);
        try pool.swapExactIn{value: amt}(address(0), amt, 0, a) {} catch {}
    }

    function swap1(uint256 s, uint256 amt) public {
        amt = bound(amt, 1, 1e26);
        address a = _a(s);
        vm.prank(a);
        try pool.swapExactIn(address(tk), amt, 0, a) {} catch {}
    }

    function add(uint256 s, uint256 a0, uint256 a1) public {
        a0 = bound(a0, 0, 100 ether);
        a1 = bound(a1, 0, 1e26);
        address a = _a(s);
        vm.prank(a);
        try pool.addLiquidityExact{value: a0}(0, a0, a1, 0, a) {} catch {}
    }

    function remove(uint256 s, uint256 sh) public {
        address a = _a(s);
        uint256 bal = pool.balanceOf(a);
        if (bal == 0) return;
        sh = bound(sh, 1, bal);
        vm.prank(a);
        try pool.removeLiquidity(sh, 0, 0, a) {} catch {}
    }

    /// @dev Sweeping mid-run matters: collection moves real balance out while
    /// reserves stay put, so solvency must hold across it too.
    function collectHook(uint256) public {
        try ConstantSurchargeHook(pool.hook()).collect(address(pool)) {} catch {}
    }

    function collectCreator(uint256) public {
        address r = pool.feeRecipient();
        if (r == address(0)) return;
        vm.prank(r);
        try pool.collectCreatorFees(r) {} catch {}
    }
}

abstract contract XBase is Test {
    PrecisionPoolFactory factory;
    PrecisionPool pool;
    MockERC20 tk;
    XHandler handler;
    uint256 sl;
    uint256 sh;

    function _boot(
        uint256 low,
        uint256 mid,
        uint256 high,
        uint8 decimals,
        address hook,
        address creator,
        uint256 creatorBps
    ) internal {
        (sl, sh) = (low, high);
        if (address(factory) == address(0)) factory = new PrecisionPoolFactory(address(0));
        tk = new MockERC20("TK", decimals);

        address maker = creator == address(0) ? address(0xC11) : creator;
        tk.mint(maker, 1e34);
        vm.deal(maker, 100_000 ether);

        vm.startPrank(maker);
        tk.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 1_000 ether}(
            PrecisionPoolFactory.Market({
                token0: address(0),
                token1: address(tk),
                sqrtPLow: low,
                sqrtPHigh: high,
                fee: 3000,
                hook: hook,
                feeRecipient: creator,
                creatorFeeBps: creatorBps
            }),
            mid,
            1_000 ether,
            1e30,
            0,
            maker
        );
        vm.stopPrank();
        pool = PrecisionPool(payable(p));

        handler = new XHandler(pool, tk);
        targetContract(address(handler));
        targetSender(address(0xC0FFEE));
    }

    function invariant_PriceInBand() public view {
        uint256 px = pool.sqrtPriceCurrent();
        if (px == 0) return;
        assertGe(px, sl, "below floor");
        assertLe(px, sh, "above ceiling");
    }

    function invariant_Solvent() public view {
        assertGe(
            address(pool).balance,
            uint256(pool.reserve0()) + pool.hookOwed0() + pool.creatorOwed0(),
            "token0 underbacked"
        );
        assertGe(
            tk.balanceOf(address(pool)),
            uint256(pool.reserve1()) + pool.hookOwed1() + pool.creatorOwed1(),
            "token1 underbacked"
        );
    }

    function invariant_MinLiquidity() public view {
        uint256 s = pool.totalSupply();
        if (s != 0) assertGe(s, 1000, "supply below MIN_LIQUIDITY");
    }
}

/// @dev A pool that charges on every axis at once: hook surcharge plus creator
/// split. The plain configuration never exercises fee accrual statefully.
contract PrecisionPoolInvariantFeesTest is XBase {
    function setUp() public {
        factory = new PrecisionPoolFactory(address(0));
        ConstantSurchargeHook h = new ConstantSurchargeHook(address(factory));
        address creator = address(0xC0DE);
        _boot(42426406871192, 44721359549995, 46904157598234, 18, address(h), creator, 2500);
        vm.prank(creator);
        h.scheduleSurchargeIncrease(address(pool), 20_000); // 2%
        vm.warp(block.timestamp + h.INCREASE_DELAY());
        h.applySurchargeIncrease(address(pool));
    }
}

/// @dev A band roughly 0.2% wide. Rounding headroom shrinks with band width,
/// and that is precisely where H-01 lived.
contract PrecisionPoolInvariantNarrowBandTest is XBase {
    function setUp() public {
        _boot(44_700_000_000_000, 44_721_359_549_995, 44_745_000_000_000, 18, address(0), address(0), 0);
    }
}

/// @dev An extreme decimal gap: 18-decimal token0 against a 2-decimal token1
/// pushes the raw-unit price far from 1 and stresses the same arithmetic.
contract PrecisionPoolInvariantDecimalGapTest is XBase {
    function setUp() public {
        // sqrt(raw price) for ~2000 units of a 2-decimal token per 1e18 wei.
        _boot(400_000_000, 447_213_595, 500_000_000, 2, address(0), address(0), 0);
    }
}
