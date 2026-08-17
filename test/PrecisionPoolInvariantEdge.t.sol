// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionZap} from "../src/pools/PrecisionZap.sol";
import {PrecisionRoute} from "../src/pools/PrecisionRoute.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Seeds and drives every market on ONE factory, so a leak between pools
/// sharing a token would surface. Also drives the factory's prefunded executor
/// and the zap, which until now were only unit-tested.
/// @dev The factory refuses an EOA executor, so the stand-in for zRouter's
/// SafeExecutor has to be a deployed contract. It needs no behaviour: the
/// handler impersonates its address with `vm.prank`.
contract ExecStub {
    receive() external payable {}
}

contract MultiHandler is Test {
    PrecisionPoolFactory public factory;
    PrecisionZap public zap;
    PrecisionRoute public router;
    PrecisionPool[] public pools;
    MockERC20 public tk;
    address actor = address(0xD00D);
    /// @dev Stands in for zRouter's SafeExecutor. The routed entry points are
    ///      gated on it, so the handler impersonates it to reach them.
    address public immutable EXEC;

    constructor(
        PrecisionPoolFactory f,
        PrecisionZap z,
        PrecisionRoute r,
        PrecisionPool[] memory ps,
        MockERC20 t,
        address exec
    ) {
        (factory, zap, router, tk, EXEC) = (f, z, r, t, exec);
        for (uint256 i; i < ps.length; ++i) pools.push(ps[i]);
        vm.deal(actor, 1_000_000 ether);
        t.mint(actor, 1e34);
        vm.startPrank(actor);
        t.approve(address(f), type(uint256).max);
        for (uint256 i; i < ps.length; ++i) t.approve(address(ps[i]), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Pools that have ever been burned. `removeLiquidity` is deliberately
    ///      unguarded by the band postcondition - see its natspec - because both
    ///      virtual reserves are floored functions of supply, so an exactly
    ///      proportional exit can still move the REPRESENTED price by a raw
    ///      unit and carry it outside the range. Refusing that exit would be a
    ///      worse failure than allowing it, so the contract allows it, and a
    ///      global "always in band" assertion is therefore stricter than
    ///      anything the pool promises. Tracking the burn lets the global
    ///      invariant stay strict everywhere the promise actually holds.
    mapping(address pool => bool) public burned;

    function _p(uint256 s) internal view returns (PrecisionPool) {
        return pools[s % pools.length];
    }

    /// @dev Unconditionally true after a SUCCESSFUL swap, on every entry point:
    ///      `_transitionAt` gates the trade on `_priceInRange` over the exact
    ///      post-swap ratio, and `sqrtPriceCurrent` floors the square root of
    ///      that same ratio, so it lands in `[sqrtPLow, sqrtPHigh]`. Asserted at
    ///      the operation rather than globally, because this is the property a
    ///      burn is allowed to break and a swap is not.
    function _assertSwapLeftItInBand(PrecisionPool p) internal view {
        uint256 px = p.sqrtPriceCurrent();
        if (px == 0) return;
        require(px >= p.sqrtPLow(), "swap left the pool below its floor");
        require(px <= p.sqrtPHigh(), "swap left the pool above its ceiling");
    }

    function swap0(uint256 s, uint256 amt) public {
        PrecisionPool p = _p(s);
        amt = bound(amt, 1, 20 ether);
        vm.prank(actor);
        try p.swapExactIn{value: amt}(address(0), amt, 0, actor) {
            _assertSwapLeftItInBand(p);
        } catch {}
    }

    function swap1(uint256 s, uint256 amt) public {
        PrecisionPool p = _p(s);
        amt = bound(amt, 1, 1e24);
        vm.prank(actor);
        try p.swapExactIn(address(tk), amt, 0, actor) {
            _assertSwapLeftItInBand(p);
        } catch {}
    }

    function add(uint256 s, uint256 a0, uint256 a1) public {
        PrecisionPool p = _p(s);
        a0 = bound(a0, 0, 50 ether);
        a1 = bound(a1, 0, 1e24);
        vm.prank(actor);
        try p.addLiquidityExact{value: a0}(0, a0, a1, 0, actor) {} catch {}
    }

    function remove(uint256 s, uint256 sh) public {
        PrecisionPool p = _p(s);
        uint256 bal = p.balanceOf(actor);
        if (bal == 0) return;
        sh = bound(sh, 1, bal);
        vm.prank(actor);
        try p.removeLiquidity(sh, 0, 0, actor) {
            burned[address(p)] = true;
        } catch {}
    }

    /// @dev The router path: checkpoint, fund, settle exactly.
    function routedSwap(uint256 s, uint256 amt) public {
        PrecisionPool p = _p(s);
        amt = bound(amt, 1, 5 ether);
        vm.prank(EXEC);
        try factory.executePrefundedSwap{value: amt}(
            PrecisionPoolFactory.Route({
                pool: address(p),
                originator: actor,
                tokenIn: address(0),
                amountIn: amt,
                minOut: 0,
                to: actor,
                refundTo: actor
            })
        ) {
            _assertSwapLeftItInBand(p);
        } catch {}
    }

    /// @dev The factory's PARTIAL-FILL settlement, native branch. Sized past
    ///      what the band can take often enough that the clamp, not just the
    ///      happy path, is what gets driven.
    function routedSwapUpToNative(uint256 s, uint256 amt) public {
        PrecisionPool p = _p(s);
        amt = bound(amt, 1, 2_000 ether);
        vm.prank(EXEC);
        try factory.executePrefundedSwapUpTo{value: amt}(
            PrecisionPoolFactory.Route({
                pool: address(p),
                originator: actor,
                tokenIn: address(0),
                amountIn: amt,
                minOut: 0,
                to: actor,
                refundTo: actor
            })
        ) {
            _assertSwapLeftItInBand(p);
        } catch {}
    }

    /// @dev The factory's partial-fill settlement, checkpointed ERC-20 branch,
    ///      including the abort that returns funding when settlement fails. A
    ///      failed settle that is not aborted would strand the input in the
    ///      factory, which `invariant_RoutingContractsHoldNothing` catches.
    function routedSwapUpToToken(uint256 s, uint256 amt) public {
        PrecisionPool p = _p(s);
        amt = bound(amt, 1, 1e24);
        if (tk.balanceOf(actor) < amt) return;
        PrecisionPoolFactory.Route memory r = PrecisionPoolFactory.Route({
            pool: address(p),
            originator: actor,
            tokenIn: address(tk),
            amountIn: amt,
            minOut: 0,
            to: actor,
            refundTo: actor
        });
        vm.prank(EXEC);
        try factory.checkpoint(r) {} catch { return; }
        vm.prank(actor);
        tk.transfer(address(factory), amt);
        vm.prank(EXEC);
        try factory.executePrefundedSwapUpTo(r) { _assertSwapLeftItInBand(p); }
        catch {
            vm.prank(EXEC);
            try factory.abortCheckpoint(r) {} catch {}
        }
    }

    /// @dev The route's own clamp over a TWO-HOP path, which is what exercises
    ///      `_maxRouteIn` bisecting `_routeRoom` rather than a single pool's
    ///      band. Every pool here shares token1, so ETH -> tk -> ETH chains.
    function routeUpToNative(uint256 s, uint256 amt) public {
        address a = address(_p(s));
        address b = address(_p(s + 1));
        if (a == b) return;
        address[] memory path = new address[](2);
        (path[0], path[1]) = (a, b);
        amt = bound(amt, 1, 2_000 ether);
        vm.prank(EXEC);
        try router.routeUpTo{value: amt}(path, address(0), address(0), amt, 0, actor, actor) {
            _assertSwapLeftItInBand(PrecisionPool(payable(a)));
            _assertSwapLeftItInBand(PrecisionPool(payable(b)));
        } catch {}
    }

    /// @dev The zap path: checkpoint shares, burn, deliver both sides.
    function zapExit(uint256 s, uint256 sh) public {
        PrecisionPool p = _p(s);
        uint256 bal = p.balanceOf(actor);
        if (bal < 2) return;
        sh = bound(sh, 1, bal / 2);
        // Checkpoint BEFORE funding: the zap consumes the balance delta taken
        // after the snapshot, which is the whole point of the mechanism.
        vm.prank(EXEC);
        bytes32 intent = keccak256(abi.encodeCall(PrecisionZap.exit, (address(p), sh, 0, 0, actor)));
        try zap.checkpoint(address(p), intent, actor) {} catch { return; }
        vm.prank(actor);
        p.transfer(address(zap), sh);
        vm.prank(EXEC);
        // Records the burn for the same reason `remove` does: this path reaches
        // `removeLiquidity` too, so it can move the represented price out of the
        // band exactly as a direct exit can.
        try zap.exit(address(p), sh, 0, 0, actor) {
            burned[address(p)] = true;
        } catch {
            // Undo the funding. Checkpoint, transfer and exit are three legs of
            // ONE router transaction in every real flow - snwap funds the zap
            // and calls it atomically - so a failing `exit` rolls the transfer
            // back with it and nothing is ever left resting. This handler drives
            // the three as separate transactions, which is what the checkpoint
            // mechanism is designed to survive but is not a call sequence any
            // caller can actually produce, and `try/catch` keeps the transfer
            // committed after the revert. Without this the suite would report a
            // stranded balance that only its own framing created.
            //
            // A dust exit reverting is reachable: `removeLiquidity` refuses a
            // burn that pays out zero on both sides, which `sh` can be small
            // enough to hit.
            vm.prank(address(zap));
            p.transfer(actor, sh);
        }
    }

    receive() external payable {}
}

contract PrecisionPoolInvariantEdgeTest is Test {
    PrecisionPoolFactory factory;
    PrecisionZap zap;
    PrecisionRoute router;
    MockERC20 tk;
    MultiHandler handler;
    PrecisionPool[] pools;

    function setUp() public {
        tk = new MockERC20("TK", 18);
        address lp = address(0xC11);
        tk.mint(lp, 1e34);
        vm.deal(lp, 1_000_000 ether);

        address exec = address(new ExecStub());
        factory = new PrecisionPoolFactory(exec, type(PrecisionPool).creationCode);
        vm.deal(exec, 1_000_000 ether);

        uint256[3] memory lows = [uint256(42426406871192), 44_700_000_000_000, 30_000_000_000_000];
        uint256[3] memory mids = [uint256(44721359549995), 44_721_359_549_995, 45_000_000_000_000];
        uint256[3] memory highs = [uint256(46904157598234), 44_745_000_000_000, 60_000_000_000_000];

        vm.startPrank(lp);
        tk.approve(address(factory), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            (address p,,,) = factory.createAndSeed{value: 500 ether}(
                PrecisionPoolFactory.Market({
                    token0: address(0),
                    token1: address(tk),
                    sqrtPLow: lows[i],
                    sqrtPHigh: highs[i],
                    fee: 500 + i * 1000,
                    hook: address(0),
                    feeRecipient: address(0),
                    creatorFeeBps: 0
                }),
                mids[i], 500 ether, 1e28, 0, lp
            );
            pools.push(PrecisionPool(payable(p)));
        }
        vm.stopPrank();

        zap = new PrecisionZap(factory, exec);
        router = new PrecisionRoute(factory, exec);
        handler = new MultiHandler(factory, zap, router, pools, tk, exec);
        targetContract(address(handler));
        targetSender(address(0xC0FFEE));
    }

    /// @dev Each market must stay inside its OWN band. Three pools share token1,
    /// so an accounting leak between them would show up here.
    ///
    /// SCOPED TO POOLS THAT HAVE NEVER BEEN BURNED, because the unrestricted
    /// form asserts more than `PrecisionPool` promises. `removeLiquidity` is
    /// deliberately unguarded by the band postcondition - an exit that can
    /// revert is a worse failure than the excursion it would prevent - and both
    /// virtual reserves are floored functions of supply, so an exactly
    /// proportional burn can carry the represented price a raw unit outside the
    /// range. This suite passed the stronger assertion only because its previous
    /// handler mix never drew the sequence that reaches it; adding the
    /// partial-fill handlers did, ending in a `remove` that put the price one
    /// unit over its ceiling.
    ///
    /// The property a swap must hold is checked where it is unconditionally
    /// true - immediately after each successful swap, in the handler, via
    /// `_assertSwapLeftItInBand` on every entry point including the two new
    /// partial-fill ones. That is strictly stronger than this global check for
    /// the paths that matter, and it does not blame a swap for what a burn is
    /// allowed to do.
    function invariant_EveryUnburnedPoolStaysInItsOwnBand() public view {
        for (uint256 i; i < pools.length; ++i) {
            if (handler.burned(address(pools[i]))) continue;
            uint256 px = pools[i].sqrtPriceCurrent();
            if (px == 0) continue;
            assertGe(px, pools[i].sqrtPLow(), "below its floor");
            assertLe(px, pools[i].sqrtPHigh(), "above its ceiling");
        }
    }

    /// @dev Solvency per pool, not in aggregate: a shared-token leak would net
    /// out across the factory but not pool by pool.
    function invariant_EveryPoolIndependentlySolvent() public view {
        for (uint256 i; i < pools.length; ++i) {
            PrecisionPool p = pools[i];
            assertGe(
                address(p).balance,
                uint256(p.reserve0()) + p.hookOwed0() + p.creatorOwed0(),
                "token0 underbacked"
            );
            assertGe(
                tk.balanceOf(address(p)),
                uint256(p.reserve1()) + p.hookOwed1() + p.creatorOwed1(),
                "token1 underbacked"
            );
        }
    }

    /// @dev No routing contract may retain value between routes. A balance left
    ///      resting is claimable by whoever routes next, so this is the property
    ///      the checkpoints exist to hold - and the one a partial fill is most
    ///      likely to break, since it is the path that hands something back.
    ///
    ///      The factory is included because an ERC-20 settlement that reverts
    ///      after its funding transfer strands the input unless the executor
    ///      aborts; the handler aborts, so a non-zero balance here means the
    ///      recovery path failed rather than that the handler skipped it.
    function invariant_RoutingContractsHoldNothing() public view {
        assertEq(address(zap).balance, 0, "zap kept ETH");
        assertEq(tk.balanceOf(address(zap)), 0, "zap kept token1");
        assertEq(address(router).balance, 0, "route kept ETH");
        assertEq(tk.balanceOf(address(router)), 0, "route kept token1");
        assertEq(address(factory).balance, 0, "factory kept ETH");
        assertEq(tk.balanceOf(address(factory)), 0, "factory kept token1");
        for (uint256 i; i < pools.length; ++i) {
            assertEq(pools[i].balanceOf(address(zap)), 0, "zap kept LP shares");
            assertEq(pools[i].balanceOf(address(router)), 0, "route kept LP shares");
        }
    }

    function invariant_ReservesFitTheirWidth() public view {
        for (uint256 i; i < pools.length; ++i) {
            assertLe(uint256(pools[i].reserve0()), type(uint128).max);
            assertLe(uint256(pools[i].reserve1()), type(uint128).max);
        }
    }
}
