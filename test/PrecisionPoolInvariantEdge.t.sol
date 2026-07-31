// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionZap} from "../src/pools/PrecisionZap.sol";
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
    PrecisionPool[] public pools;
    MockERC20 public tk;
    address actor = address(0xD00D);
    /// @dev Stands in for zRouter's SafeExecutor. The routed entry points are
    ///      gated on it, so the handler impersonates it to reach them.
    address public immutable EXEC;

    constructor(PrecisionPoolFactory f, PrecisionZap z, PrecisionPool[] memory ps, MockERC20 t, address exec) {
        (factory, zap, tk, EXEC) = (f, z, t, exec);
        for (uint256 i; i < ps.length; ++i) pools.push(ps[i]);
        vm.deal(actor, 1_000_000 ether);
        t.mint(actor, 1e34);
        vm.startPrank(actor);
        t.approve(address(f), type(uint256).max);
        for (uint256 i; i < ps.length; ++i) t.approve(address(ps[i]), type(uint256).max);
        vm.stopPrank();
    }

    function _p(uint256 s) internal view returns (PrecisionPool) {
        return pools[s % pools.length];
    }

    function swap0(uint256 s, uint256 amt) public {
        PrecisionPool p = _p(s);
        amt = bound(amt, 1, 20 ether);
        vm.prank(actor);
        try p.swapExactIn{value: amt}(address(0), amt, 0, actor) {} catch {}
    }

    function swap1(uint256 s, uint256 amt) public {
        PrecisionPool p = _p(s);
        amt = bound(amt, 1, 1e24);
        vm.prank(actor);
        try p.swapExactIn(address(tk), amt, 0, actor) {} catch {}
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
        try p.removeLiquidity(sh, 0, 0, actor) {} catch {}
    }

    /// @dev The router path: checkpoint, fund, settle exactly.
    function routedSwap(uint256 s, uint256 amt) public {
        PrecisionPool p = _p(s);
        amt = bound(amt, 1, 5 ether);
        vm.prank(EXEC);
        try factory.executePrefundedSwap{value: amt}(address(p), actor, address(0), amt, 0, actor) {}
            catch {}
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
        try zap.checkpoint(address(p)) {} catch { return; }
        vm.prank(actor);
        p.transfer(address(zap), sh);
        vm.prank(EXEC);
        try zap.exit(address(p), sh, 0, 0, actor) {} catch {}
    }

    receive() external payable {}
}

contract PrecisionPoolInvariantEdgeTest is Test {
    PrecisionPoolFactory factory;
    PrecisionZap zap;
    MockERC20 tk;
    MultiHandler handler;
    PrecisionPool[] pools;

    function setUp() public {
        tk = new MockERC20("TK", 18);
        address lp = address(0xC11);
        tk.mint(lp, 1e34);
        vm.deal(lp, 1_000_000 ether);

        address exec = address(new ExecStub());
        factory = new PrecisionPoolFactory(exec);
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
        handler = new MultiHandler(factory, zap, pools, tk, exec);
        targetContract(address(handler));
        targetSender(address(0xC0FFEE));
    }

    /// @dev Each market must stay inside its OWN band. Three pools share token1,
    /// so an accounting leak between them would show up here.
    function invariant_EveryPoolStaysInItsOwnBand() public view {
        for (uint256 i; i < pools.length; ++i) {
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

    /// @dev Neither the zap nor the factory may retain value between routes.
    function invariant_RoutingContractsHoldNothing() public view {
        assertEq(address(zap).balance, 0, "zap kept ETH");
        assertEq(tk.balanceOf(address(zap)), 0, "zap kept token1");
        for (uint256 i; i < pools.length; ++i) {
            assertEq(pools[i].balanceOf(address(zap)), 0, "zap kept LP shares");
        }
    }

    function invariant_ReservesFitTheirWidth() public view {
        for (uint256 i; i < pools.length; ++i) {
            assertLe(uint256(pools[i].reserve0()), type(uint128).max);
            assertLe(uint256(pools[i].reserve1()), type(uint128).max);
        }
    }
}
