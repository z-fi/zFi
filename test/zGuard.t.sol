// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zGuard} from "../src/utils/zGuard.sol";
import {zRouter} from "../src/zRouter.sol";
import {zRouterLiteBase} from "../src/zRouterLiteBase.sol";
import {zRouterLiteRobinhood} from "../src/zRouterLiteRobinhood.sol";
import {MockERC20} from "./SwapboardMocks.sol";

interface IRouter {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external payable returns (uint256);
    function safeExecutor() external view returns (address);
}

/// @dev Stands in for PrecisionRoute's native entry point, with the two rules
///      that make a guard leg dangerous if it got them wrong: only the router's
///      SafeExecutor may call, and msg.value must be exactly the amount.
contract NativeRoute {
    address public immutable trusted;
    MockERC20 public immutable out;

    constructor(address trusted_, MockERC20 out_) {
        (trusted, out) = (trusted_, out_);
    }

    function route(uint256 amountIn, uint256 amountOut, address to) external payable {
        require(msg.sender == trusted, "NotExecutor");
        require(msg.value == amountIn, "Bad");
        out.mint(to, amountOut);
    }
}

/// @dev PrecisionRoute's ERC-20 shape: the router has already moved `amountIn`
///      here, and the route pays out from it.
contract TokenRoute {
    address public immutable trusted;
    MockERC20 public immutable pay;
    MockERC20 public immutable out;

    constructor(address trusted_, MockERC20 pay_, MockERC20 out_) {
        (trusted, pay, out) = (trusted_, pay_, out_);
    }

    function route(uint256 amountIn, uint256 amountOut, address to) external {
        require(msg.sender == trusted, "NotExecutor");
        require(pay.balanceOf(address(this)) >= amountIn, "unfunded");
        out.mint(to, amountOut);
    }
}

/// @dev Takes ether and keeps it: the guard leg a router must NOT be handed.
contract Sink {
    function take() external payable {}
}

contract NoReceive {}

contract zGuardTest is Test {
    zGuard guard;
    MockERC20 tok;
    address user = address(0xA11CE);

    function setUp() public {
        guard = new zGuard();
        tok = new MockERC20("OUT", 18);
    }

    // ---------------------------------------------------------------- unit

    function test_deadlineHoldsUpToAndIncludingItsSecond() public {
        vm.warp(1000);
        guard.deadline(1000, address(this));
        guard.deadline(2000, address(this));
        vm.expectRevert(zGuard.Expired.selector);
        guard.deadline(999, address(this));
    }

    function test_etherIsReturnedAndNeverKept() public {
        address back = address(0xBAC);
        uint256 held = address(guard).balance; // a forked address may hold dust
        vm.deal(address(this), 3 ether);
        guard.deadline{value: 1 ether}(block.timestamp, back);
        guard.snap{value: 1 ether}(address(tok), user, back);
        guard.floor{value: 1 ether}(address(tok), user, 0, back);
        assertEq(back.balance, 3 ether);
        assertEq(address(guard).balance, held);
    }

    function test_aBackThatRefusesEtherReverts() public {
        address nr = address(new NoReceive());
        vm.deal(address(this), 1 ether);
        vm.expectRevert(zGuard.BounceFailed.selector);
        guard.deadline{value: 1 ether}(block.timestamp, nr);
    }

    function test_floorMeasuresTheRiseSinceTheSnapshot() public {
        tok.mint(user, 7e18);
        guard.snap(address(tok), user, address(0));
        tok.mint(user, 5e18);
        assertEq(guard.floor(address(tok), user, 5e18, address(0)), 5e18);

        guard.snap(address(tok), user, address(0));
        tok.mint(user, 4e18);
        vm.expectRevert(abi.encodeWithSelector(zGuard.BelowFloor.selector, 4e18, 5e18));
        guard.floor(address(tok), user, 5e18, address(0));
    }

    function test_floorOnEther() public {
        vm.deal(user, 1 ether);
        guard.snap(address(0), user, address(0));
        vm.deal(user, 3 ether);
        assertEq(guard.floor(address(0), user, 2 ether, address(0)), 2 ether);
    }

    function test_aFallingBalanceIsZeroNotAnUnderflow() public {
        tok.mint(user, 5e18);
        guard.snap(address(tok), user, address(0));
        vm.prank(user);
        tok.transfer(address(1), 2e18);
        vm.expectRevert(abi.encodeWithSelector(zGuard.BelowFloor.selector, 0, 1));
        guard.floor(address(tok), user, 1, address(0));
    }

    function test_aZeroBalanceSnapshotIsStillASnapshot() public {
        guard.snap(address(tok), user, address(0));
        tok.mint(user, 1);
        assertEq(guard.floor(address(tok), user, 1, address(0)), 1);
    }

    function test_noFloorWithoutASnapshot() public {
        vm.expectRevert(zGuard.NoSnapshot.selector);
        guard.floor(address(tok), user, 0, address(0));
    }

    function test_theSnapshotIsSpentByTheFloor() public {
        guard.snap(address(tok), user, address(0));
        guard.floor(address(tok), user, 0, address(0));
        vm.expectRevert(zGuard.NoSnapshot.selector);
        guard.floor(address(tok), user, 0, address(0));
    }

    function test_theBaselineCannotBeMoved() public {
        guard.snap(address(tok), user, address(0));
        tok.mint(user, 1e18);
        vm.expectRevert(zGuard.SnapshotTaken.selector);
        guard.snap(address(tok), user, address(0));
    }

    function test_snapshotsAreKeyedByCaller() public {
        guard.snap(address(tok), user, address(0));
        vm.prank(address(0xE71));
        vm.expectRevert(zGuard.NoSnapshot.selector);
        guard.floor(address(tok), user, 0, address(0));
        vm.prank(address(0xE71));
        guard.snap(address(tok), user, address(0));
    }

    function test_aTokenThatCannotReportABalanceIsRefused() public {
        address notAToken = address(new NoReceive());
        vm.expectRevert(zGuard.BadToken.selector);
        guard.snap(notAToken, user, address(0));
    }

    // -------------------------------------------------- through each router

    function _routers() internal returns (IRouter[3] memory rs) {
        MockERC20 wsteth = new MockERC20("wstETH", 18);
        vm.etch(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, address(wsteth).code);
        rs[0] = IRouter(address(new zRouter()));
        rs[1] = IRouter(address(new zRouterLiteBase()));
        rs[2] = IRouter(address(new zRouterLiteRobinhood()));
    }

    function _guardLeg(IRouter r, bytes memory call_) internal view returns (bytes memory) {
        return abi.encodeCall(IRouter.snwap, (address(0), 0, user, address(0), 0, address(guard), call_));
    }

    function _routeLeg(IRouter r, NativeRoute nr, uint256 amt, uint256 out, uint256 min) internal view returns (bytes memory) {
        return abi.encodeCall(
            IRouter.snwap,
            (address(0), 0, user, address(tok), min, address(nr), abi.encodeCall(NativeRoute.route, (amt, out, user)))
        );
    }

    /// The case the ether bounce exists for: a native swap whose route demands
    /// msg.value == amountIn, behind a guard leg that is handed the same ether.
    function test_aGuardedNativeSwapSettlesOnEveryRouter() public {
        IRouter[3] memory rs = _routers();
        for (uint256 i; i < 3; ++i) {
            IRouter r = rs[i];
            NativeRoute nr = new NativeRoute(r.safeExecutor(), tok);
            uint256 before = tok.balanceOf(user);
            uint256 held = address(guard).balance;
            bytes[] memory legs = new bytes[](2);
            legs[0] = _guardLeg(r, abi.encodeCall(zGuard.deadline, (block.timestamp + 60, address(r))));
            legs[1] = _routeLeg(r, nr, 1 ether, 3000e18, 2990e18);
            vm.deal(user, 1 ether);
            vm.prank(user);
            r.multicall{value: 1 ether}(legs);
            assertEq(tok.balanceOf(user) - before, 3000e18, "the swap settled");
            assertEq(address(nr).balance, 1 ether, "the route got exactly its ether");
            assertEq(address(r).balance, 0, "nothing left in the router");
            assertEq(address(guard).balance, held, "nothing left in the guard");
        }
    }

    function test_anExpiredNativeSwapRevertsOnEveryRouter() public {
        IRouter[3] memory rs = _routers();
        vm.warp(10_000);
        for (uint256 i; i < 3; ++i) {
            IRouter r = rs[i];
            NativeRoute nr = new NativeRoute(r.safeExecutor(), tok);
            bytes[] memory legs = new bytes[](2);
            legs[0] = _guardLeg(r, abi.encodeCall(zGuard.deadline, (block.timestamp - 1, address(r))));
            legs[1] = _routeLeg(r, nr, 1 ether, 3000e18, 0);
            vm.deal(user, 1 ether);
            vm.prank(user);
            vm.expectRevert(zGuard.Expired.selector);
            r.multicall{value: 1 ether}(legs);
        }
    }

    /// Why the bounce is not optional: a leg that keeps the ether it is handed
    /// leaves the router unable to fund the swap after it.
    function test_withoutTheBounceTheSwapBehindCannotBeFunded() public {
        IRouter r = _routers()[0];
        NativeRoute nr = new NativeRoute(r.safeExecutor(), tok);
        Sink sink = new Sink();
        bytes[] memory legs = new bytes[](2);
        legs[0] = abi.encodeCall(IRouter.snwap, (address(0), 0, user, address(0), 0, address(sink), abi.encodeCall(Sink.take, ())));
        legs[1] = _routeLeg(r, nr, 1 ether, 3000e18, 0);
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert();
        r.multicall{value: 1 ether}(legs);
    }

    /// One floor for the whole bundle: every per-leg minimum can be loose, and
    /// the user still gets exactly the bound they chose. ERC-20 input, which
    /// is where a floor can run: the bundle carries no msg.value.
    function test_anEndToEndFloorBindsAnErc20BundleOnEveryRouter() public {
        IRouter[3] memory rs = _routers();
        MockERC20 pay = new MockERC20("PAY", 18);
        for (uint256 i; i < 3; ++i) {
            IRouter r = rs[i];
            TokenRoute tr = new TokenRoute(r.safeExecutor(), pay, tok);
            pay.mint(user, 2e18);
            vm.prank(user);
            pay.approve(address(r), type(uint256).max);
            bytes[] memory legs = new bytes[](3);
            legs[0] = _guardLeg(r, abi.encodeCall(zGuard.snap, (address(tok), user, address(r))));
            legs[1] = abi.encodeCall(IRouter.snwap, (address(pay), 1e18, user, address(tok), 0, address(tr),
                abi.encodeCall(TokenRoute.route, (1e18, 3000e18, user))));
            legs[2] = _guardLeg(r, abi.encodeCall(zGuard.floor, (address(tok), user, 3000e18, address(r))));
            vm.prank(user);
            r.multicall(legs);

            legs[2] = _guardLeg(r, abi.encodeCall(zGuard.floor, (address(tok), user, 3000e18 + 1, address(r))));
            vm.prank(user);
            vm.expectRevert(abi.encodeWithSelector(zGuard.BelowFloor.selector, 3000e18, 3000e18 + 1));
            r.multicall(legs);
        }
    }

    /// Why a native bundle cannot END with a guard leg: every snwap forwards
    /// msg.value from the router's balance, and the swap leg has spent it. The
    /// page therefore places guard legs only BEFORE a native swap, and relies
    /// on that swap leg's own minimum for the output.
    function test_aGuardLegAfterANativeSwapCannotBeFunded() public {
        IRouter r = _routers()[0];
        NativeRoute nr = new NativeRoute(r.safeExecutor(), tok);
        bytes[] memory legs = new bytes[](2);
        legs[0] = _routeLeg(r, nr, 1 ether, 3000e18, 0);
        legs[1] = _guardLeg(r, abi.encodeCall(zGuard.deadline, (block.timestamp, address(r))));
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert();
        r.multicall{value: 1 ether}(legs);
    }

    /// An ERC-20 swap hands the guard no ether at all; the leg is a pure check.
    function test_aGuardLegWithNoEtherIsAPureCheck() public {
        IRouter r = _routers()[0];
        vm.warp(500);
        vm.prank(user);
        r.snwap(address(0), 0, user, address(0), 0, address(guard), abi.encodeCall(zGuard.deadline, (500, address(r))));
        vm.prank(user);
        vm.expectRevert(zGuard.Expired.selector);
        r.snwap(address(0), 0, user, address(0), 0, address(guard), abi.encodeCall(zGuard.deadline, (499, address(r))));
    }
}
