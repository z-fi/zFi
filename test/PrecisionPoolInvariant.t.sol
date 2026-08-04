// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Drives random add / remove / swap sequences. The unit and fuzz tests
/// check one operation at a time from a clean seed; H-01 showed the failures
/// live in sequences and in degenerate amounts, which only a stateful run
/// reaches.
contract Handler is Test {
    PrecisionPool public pool;
    MockERC20 public tk;
    address[] actors;
    uint256 public swaps;
    uint256 public adds;
    uint256 public removes;

    constructor(PrecisionPool p, MockERC20 t) {
        pool = p;
        tk = t;
        for (uint256 i; i < 3; ++i) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            vm.deal(a, 10_000 ether);
            t.mint(a, 1e30);
            vm.prank(a);
            t.approve(address(p), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function swap0(uint256 seed, uint256 amt) public {
        amt = bound(amt, 1, 50 ether);
        address a = _actor(seed);
        vm.prank(a);
        try pool.swapExactIn{value: amt}(address(0), amt, 0, a) {
            ++swaps;
        } catch {}
    }

    function swap1(uint256 seed, uint256 amt) public {
        amt = bound(amt, 1, 1e24);
        address a = _actor(seed);
        vm.prank(a);
        try pool.swapExactIn(address(tk), amt, 0, a) {
            ++swaps;
        } catch {}
    }

    function add(uint256 seed, uint256 a0, uint256 a1) public {
        a0 = bound(a0, 0, 100 ether);
        a1 = bound(a1, 0, 1e24);
        address a = _actor(seed);
        vm.prank(a);
        try pool.addLiquidityExact{value: a0}(0, a0, a1, 0, a) {
            ++adds;
        } catch {}
    }

    function remove(uint256 seed, uint256 shares) public {
        address a = _actor(seed);
        uint256 bal = pool.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(a);
        try pool.removeLiquidity(shares, 0, 0, a) {
            ++removes;
        } catch {}
    }
}

contract PrecisionPoolInvariantTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPool pool;
    MockERC20 tk;
    Handler handler;

    uint256 constant SQRT_LOW = 42426406871192;
    uint256 constant SQRT_MID = 44721359549995;
    uint256 constant SQRT_HIGH = 46904157598234;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        tk = new MockERC20("TK", 18);
        address lp = address(0xC11);
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
            SQRT_MID, 100 ether, 1e24, 0, lp
        );
        vm.stopPrank();
        pool = PrecisionPool(payable(p));

        handler = new Handler(pool, tk);
        targetContract(address(handler));

        // Pin the senders. Left unrestricted the runner invents thousands of
        // random addresses, and under this repo's global fork every one of them
        // is an RPC account lookup - which the public endpoint rate-limits long
        // before the run finishes. The handler picks its own actors internally,
        // so caller identity here adds nothing.
        targetSender(address(0xC0FFEE));
    }

    /// @dev The postcondition H-01 broke: no sequence of liquidity or swap
    /// operations may leave the pool priced outside its immutable band.
    function invariant_PriceStaysInsideTheBand() public view {
        uint256 px = pool.sqrtPriceCurrent();
        if (px == 0) return; // fully drained pool has no price
        assertGe(px, SQRT_LOW, "price below the floor");
        assertLe(px, SQRT_HIGH, "price above the ceiling");
    }

    /// @dev Solvency: real balances must always cover reserves plus everything
    /// accrued to the hook and creator.
    function invariant_BalancesBackReservesAndFees() public view {
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

    /// @dev The permanent minimum can never be burned away.
    function invariant_MinLiquidityIsPermanent() public view {
        uint256 supply = pool.totalSupply();
        if (supply != 0) assertGe(supply, 1000, "supply fell below MIN_LIQUIDITY");
        assertEq(pool.balanceOf(address(0xdead)), 1000, "locked shares moved");
    }

    /// @dev Reserves must stay inside the width they are stored in.
    function invariant_ReservesFitTheirWidth() public view {
        assertLe(uint256(pool.reserve0()), type(uint128).max);
        assertLe(uint256(pool.reserve1()), type(uint128).max);
    }
}
