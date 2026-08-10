// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

contract FlatHook {
    function feeFor(address, address, uint256) external pure returns (uint256) {
        return 1000;
    }

    function afterSwap(address, address, uint256, uint256, address) external {}
}

/// @dev The pool has always had `swapUpToFromFactory`, and until now the factory
/// had no entry point that reached it: every routed swap was all-or-nothing, so
/// a leg sized from a two-block-old quote reverted and took the whole route with
/// it. `executePrefundedSwapUpTo` is the missing counterpart. These tests drive
/// it the way a router does - this contract IS the trusted executor - and pin
/// the two properties the fix has to have: the clamp is exact, and the leftover
/// reaches the address the route committed to rather than staying anywhere.
contract PrecisionPoolRoutedPartialFillTest is Test {
    PrecisionPoolFactory factory;
    MockERC20 usdc;
    PrecisionPool pool;
    PrecisionPool hooked;

    address lp = address(0xA11CE);
    address trader = address(0xB0B);
    address refuge = address(0xCAFE);

    uint256 constant LO = 42426406871192; // $1800
    uint256 constant MID = 44721359549995; // $2000
    uint256 constant HI = 46904157598234; // $2200

    receive() external payable {}

    function _m(address hook) internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market(address(0), address(usdc), LO, HI, 3000, hook, address(0), 0);
    }

    function setUp() public {
        // This contract is the executor, so it can checkpoint and settle.
        factory = new PrecisionPoolFactory(address(this), type(PrecisionPool).creationCode);
        usdc = new MockERC20("USDC", 6);
        usdc.mint(lp, 1e15);
        usdc.mint(address(this), 1e15);
        vm.deal(lp, 1e23);
        vm.deal(address(this), 1e23);

        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 10 ether}(_m(address(0)), MID, 10 ether, 30_000e6, 0, lp);
        (address h,,,) =
            factory.createAndSeed{value: 10 ether}(_m(address(new FlatHook())), MID, 10 ether, 30_000e6, 0, lp);
        vm.stopPrank();
        pool = PrecisionPool(payable(p));
        hooked = PrecisionPool(payable(h));
    }

    /// @dev Returns a fresh struct every call. A `Route memory` assignment
    ///      ALIASES rather than copies, so mutating a "copy" to build a
    ///      mismatched route would silently corrupt the original and make the
    ///      intent test pass for the wrong reason.
    function _route(address target, address tokenIn, uint256 amountIn)
        internal
        view
        returns (PrecisionPoolFactory.Route memory)
    {
        return PrecisionPoolFactory.Route({
            pool: target,
            originator: trader,
            tokenIn: tokenIn,
            amountIn: amountIn,
            minOut: 0,
            to: trader,
            refundTo: refuge
        });
    }

    /// @dev The headline. An oversized ERC-20 leg is refused outright by the
    /// exact entry point and clamped by the new one, with the remainder landing
    /// at the committed `refundTo` and nothing left in the factory.
    function test_RoutedErc20LegClampsInsteadOfReverting() public {
        uint256 ask = 10_000_000e6; // far more than the band can absorb
        PrecisionPoolFactory.Route memory r = _route(address(pool), address(usdc), ask);

        // What routing does today: the whole leg reverts.
        factory.checkpoint(r);
        usdc.transfer(address(factory), ask);
        vm.expectRevert();
        factory.executePrefundedSwap(r);
        factory.abortCheckpoint(r);

        // And with the partial-fill settlement instead. Balances are compared as
        // DELTAS: the abort above already returned `ask` to `refuge`, and the
        // suite runs against a mainnet fork, so no address here starts at zero.
        uint256 poolEthBefore = address(pool).balance;
        uint256 traderEthBefore = trader.balance;
        uint256 refugeBefore = usdc.balanceOf(refuge);
        uint256 factoryBefore = usdc.balanceOf(address(factory));
        usdc.mint(address(this), ask);

        factory.checkpoint(r);
        usdc.transfer(address(factory), ask);
        (uint256 out, uint256 consumed) = factory.executePrefundedSwapUpTo(r);

        assertGt(out, 0, "produced no output");
        assertGt(consumed, 0, "consumed nothing");
        assertLt(consumed, ask, "should have clamped");
        // The leftover went to the committed refund address, not to the router.
        assertEq(usdc.balanceOf(refuge) - refugeBefore, ask - consumed, "refund misdirected");
        assertEq(usdc.balanceOf(address(factory)), factoryBefore, "factory retained input");
        // Output reached the recipient, priced out of the pool.
        assertEq(trader.balance - traderEthBefore, out, "output misdirected");
        assertEq(poolEthBefore - address(pool).balance, out, "pool accounting drifted");
    }

    /// @dev Native input takes the other branch: no checkpoint, authenticated by
    /// `msg.value`, and the remainder comes back as ETH.
    function test_RoutedNativeLegClampsAndRefundsEth() public {
        uint256 ask = 500 ether; // far past the band
        PrecisionPoolFactory.Route memory r = _route(address(pool), address(0), ask);

        vm.expectRevert();
        factory.executePrefundedSwap{value: ask}(r);

        uint256 refugeBefore = refuge.balance;
        uint256 traderBefore = usdc.balanceOf(trader);
        // Deltas, not absolutes: this address holds ETH on the forked mainnet
        // state the suite runs against, independently of anything the pool does.
        uint256 factoryBefore = address(factory).balance;
        (uint256 out, uint256 consumed) = factory.executePrefundedSwapUpTo{value: ask}(r);

        assertGt(out, 0, "produced no output");
        assertLt(consumed, ask, "should have clamped");
        assertEq(refuge.balance - refugeBefore, ask - consumed, "eth refund misdirected");
        assertEq(address(factory).balance, factoryBefore, "factory retained eth");
        assertEq(usdc.balanceOf(trader) - traderBefore, out, "output misdirected");
    }

    /// @dev A leg that fits is not clamped, and settles identically to the exact
    /// entry point. Partial fill must not cost anything on the common path.
    function test_FittingLegIsNotClamped() public {
        uint256 ask = 1_000e6;
        PrecisionPoolFactory.Route memory r = _route(address(pool), address(usdc), ask);

        factory.checkpoint(r);
        usdc.transfer(address(factory), ask);
        (uint256 out, uint256 consumed) = factory.executePrefundedSwapUpTo(r);

        assertEq(consumed, ask, "clamped a leg that fit");
        assertGt(out, 0, "produced no output");
        assertEq(usdc.balanceOf(refuge), 0, "refunded when nothing was left over");
    }

    /// @dev `minOut` still applies to what actually filled, so an executor that
    /// wants all-or-nothing keeps it. Partial fill must not weaken slippage.
    function test_MinOutStillBindsOnThePartialFill() public {
        uint256 ask = 10_000_000e6;
        PrecisionPoolFactory.Route memory r = _route(address(pool), address(usdc), ask);

        factory.checkpoint(r);
        usdc.transfer(address(factory), ask);
        (uint256 out,) = factory.executePrefundedSwapUpTo(r);

        // Demand more than the band could ever deliver and it refuses. `greedy`
        // is built fresh rather than copied from `r`, which would alias it.
        PrecisionPoolFactory.Route memory greedy = _route(address(pool), address(usdc), ask);
        greedy.minOut = out * 100;
        usdc.mint(address(this), ask);
        factory.checkpoint(greedy);
        usdc.transfer(address(factory), ask);
        vm.expectRevert();
        factory.executePrefundedSwapUpTo(greedy);
    }

    /// @dev Hooked pools keep all-or-nothing, because the surcharge is sampled
    /// at the requested size and would be wrong at the clamped one.
    function test_HookedPoolRefusesRoutedPartialFill() public {
        uint256 ask = 1_000e6;
        PrecisionPoolFactory.Route memory r = _route(address(hooked), address(usdc), ask);

        factory.checkpoint(r);
        usdc.transfer(address(factory), ask);
        vm.expectRevert(PrecisionPool.HookedNoPartialFill.selector);
        factory.executePrefundedSwapUpTo(r);
    }

    /// @dev Same authentication as the exact settlement: executor only, and an
    /// ERC-20 leg needs its own checkpoint.
    function test_AuthenticationMatchesExactSettlement() public {
        PrecisionPoolFactory.Route memory r = _route(address(pool), address(usdc), 1_000e6);

        vm.prank(trader);
        vm.expectRevert(PrecisionPoolFactory.NotExecutor.selector);
        factory.executePrefundedSwapUpTo(r);

        // No checkpoint taken, so there is no funding to settle against.
        vm.expectRevert(PrecisionPoolFactory.BadCheckpoint.selector);
        factory.executePrefundedSwapUpTo(r);
    }

    /// @dev The checkpoint commits to the whole route, and the commitment binds
    /// this settlement exactly as it binds the exact one - a substituted field
    /// cannot be settled even though the selector differs from the committed
    /// call's.
    function test_CommittedIntentBindsThePartialSettlement() public {
        uint256 ask = 1_000e6;
        PrecisionPoolFactory.Route memory r = _route(address(pool), address(usdc), ask);

        factory.checkpoint(r);
        usdc.transfer(address(factory), ask);

        // Built fresh, then redirected. Assigning `r` would alias it and mutate
        // the committed route along with the substitute.
        PrecisionPoolFactory.Route memory swapped = _route(address(pool), address(usdc), ask);
        swapped.to = address(0xDEAD); // redirect the output
        vm.expectRevert(PrecisionPoolFactory.IntentMismatch.selector);
        factory.executePrefundedSwapUpTo(swapped);

        // The route it did commit to still settles.
        (, uint256 consumed) = factory.executePrefundedSwapUpTo(r);
        assertEq(consumed, ask);
    }
}
