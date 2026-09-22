// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PM} from "../src/PM.sol";

interface IZR {
    function swapV2(address, bool, address, address, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256);
    function swapV3(address, bool, uint24, address, address, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256);
    function swapV4(address, bool, uint24, int24, address, address, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256);
    function swapVZ(address, bool, uint256, address, address, uint256, uint256, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256);
    function snwap(address, uint256, address, address, uint256, address, bytes calldata)
        external
        payable
        returns (uint256);
    function sweep(address, uint256, uint256, address) external payable;
    function permit(address, uint256, uint256, uint8, bytes32, bytes32) external payable;
    function permit2TransferFrom(address, uint256, uint256, uint256, bytes calldata) external payable;
    function deposit(address, uint256, uint256) external payable;
    function multicall(bytes[] calldata) external payable returns (bytes[] memory);
    function exactETHToWSTETH(address) external payable returns (uint256);
    function execute(address, uint256, bytes calldata) external payable returns (bytes memory);
    function unwrap(uint256) external payable;
}

interface IE20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

address constant ZR = 0x000000000000FB114709235f1ccBFfb925F600e4;
address constant WSTE = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
address constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

contract PMStake {
    function stake(address to) external payable {
        (bool ok,) = WSTE.call{value: msg.value}("");
        require(ok);
        IE20(WSTE).transfer(to, IE20(WSTE).balanceOf(address(this)));
    }
}

/// Executor that sends part of its ETH straight to PM mid-route and the rest to wstETH.
contract PMTipper {
    function run(address pm, uint256 tip) external payable {
        (bool ok,) = pm.call{value: tip}("");
        require(ok, "tip");
        (ok,) = WSTE.call{value: msg.value - tip}("");
        require(ok);
        IE20(WSTE).transfer(pm, IE20(WSTE).balanceOf(address(this)));
    }
}

/// Executor that plays with ERC6909 mid-route (the unlocked surface).
contract PMMover {
    function run(PM pm, uint256 id, address to) external {
        pm.setOperator(to, true);
        pm.approve(to, id, 1);
        // cannot move PM's own shares: msg.sender is PMMover, not PM
        pm.transferFrom(address(pm), to, id, 1);
    }
}

contract PMBoom {
    constructor(address to) payable {
        selfdestruct(payable(to));
    }
}

contract PMAuditRoute is Test {
    PM pm;
    address alice = address(0xA11CE);
    address mallory = address(0xBAD);
    address resolver = address(0x5E50);
    uint256 wstId;
    uint256 ethId;
    uint256 usdcId;
    uint256 wethId;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
        pm = new PM();
        vm.deal(address(pm), 0);
        vm.etch(alice, "");
        vm.etch(mallory, "");
        vm.deal(alice, 100 ether);
        vm.deal(mallory, 100 ether);
        uint48 c = uint48(block.timestamp + 1 days);
        wstId = pm.createMarket("a", resolver, WSTE, c, true, 0, 0);
        ethId = pm.createMarket("a", resolver, address(0), c, true, 0, 0);
        usdcId = pm.createMarket("a", resolver, USDC, c, true, 0, 0);
        wethId = pm.createMarket("a", resolver, WETH9, c, true, 0, 0);
        // Seed pots: ETH market, wstETH market, USDC market.
        vm.prank(alice);
        pm.betETH{value: 10 ether}(ethId, true, alice, 0, "");
        vm.prank(alice);
        pm.betETH{value: 10 ether}(wstId, true, alice, 0, "");
        deal(USDC, alice, 1_000_000e6);
        vm.startPrank(alice);
        (bool ok,) = USDC.call(abi.encodeWithSignature("approve(address,uint256)", address(pm), type(uint256).max));
        require(ok);
        pm.bet(usdcId, true, 1_000_000e6, alice, 0);
        vm.stopPrank();
    }

    function _snap() internal view returns (uint256 e, uint256 w, uint256 u) {
        return (address(pm).balance, IE20(WSTE).balanceOf(address(pm)), IE20(USDC).balanceOf(address(pm)));
    }

    function _tryRoute(uint256 market, uint256 value, bytes memory route) internal returns (bool ok) {
        vm.prank(mallory);
        (ok,) = address(pm).call{value: value}(abi.encodeCall(PM.betETH, (market, true, mallory, 0, route)));
    }

    /// Every zRouter entry that pulls from msg.sender (= PM) fails: PM grants no allowance, has no 1271.
    function test_routeCannotPullPMHoldings() public {
        (uint256 e0, uint256 w0, uint256 u0) = _snap();
        uint256 dl = block.timestamp + 1;
        bytes[] memory routes = new bytes[](10);
        routes[0] = abi.encodeCall(IZR.swapV2, (mallory, false, USDC, WETH9, 1e6, 0, dl));
        routes[1] = abi.encodeCall(IZR.swapV3, (mallory, false, 500, USDC, WETH9, 1e6, 0, dl));
        routes[2] = abi.encodeCall(IZR.swapV4, (mallory, false, 500, 10, USDC, address(0), 1e6, 0, dl));
        routes[3] = abi.encodeCall(IZR.swapVZ, (mallory, false, 30, USDC, address(0), 0, 0, 1e6, 0, dl));
        routes[4] = abi.encodeCall(IZR.snwap, (WSTE, 1 ether, mallory, WSTE, 0, mallory, ""));
        routes[5] = abi.encodeCall(IZR.deposit, (USDC, 0, 1e6));
        routes[6] = abi.encodeCall(IZR.permit2TransferFrom, (USDC, 1e6, 0, dl, new bytes(65)));
        routes[7] = abi.encodeCall(IZR.permit, (USDC, 1e6, dl, 27, bytes32(uint256(1)), bytes32(uint256(2))));
        routes[8] =
            abi.encodeCall(IZR.execute, (USDC, 0, abi.encodeWithSignature("transfer(address,uint256)", mallory, 1)));
        // PM shares as ERC6909 input: zRouter.transferFrom(PM, router, id) needs PM's allowance.
        routes[9] = abi.encodeCall(IZR.swapVZ, (mallory, false, 30, address(pm), address(0), wstId, 0, 1, 0, dl));
        for (uint256 i; i != routes.length; ++i) {
            assertFalse(_tryRoute(usdcId, 0, routes[i]), vm.toString(i));
            assertFalse(_tryRoute(wstId, 1, routes[i]), vm.toString(i));
        }
        (uint256 e1, uint256 w1, uint256 u1) = _snap();
        assertEq(e1, e0);
        assertEq(w1, w0);
        assertEq(u1, u0);
    }

    /// With msg.value 0 a route can credit router-held balances (anyone could sweep them anyway).
    function test_routeZeroValue_sweepsRouterDust() public {
        deal(USDC, ZR, IE20(USDC).balanceOf(ZR) + 500e6);
        uint256 dust = IE20(USDC).balanceOf(ZR);
        assertGt(dust, 0);
        vm.prank(mallory);
        vm.expectRevert(PM.AmountZero.selector);
        pm.betETH(usdcId, false, mallory, 0, abi.encodeCall(IZR.sweep, (USDC, 0, 0, address(pm))));
    }

    /// wstETH default route forwards the router's whole wstETH balance, not just the fresh mint.
    function test_defaultWstRoute_sweepsRouterWst() public {
        deal(WSTE, ZR, 3 ether);
        vm.prank(mallory);
        uint256 shares = pm.betETH{value: 1 ether}(wstId, false, mallory, 0, "");
        assertGt(shares, 3 ether);
    }

    /// ETH forced in before (selfdestruct) stays in PM; ETH an executor tips mid-route refunds to bettor;
    /// escrowed ETH-market pot never leaks.
    function test_refundMath_forcedAndTipped() public {
        new PMBoom{value: 1 ether}(address(pm));
        uint256 forced = address(pm).balance - 10 ether; // 1 ether (+ any mainnet dust at the PMBoom address)
        assertGe(forced, 1 ether);
        PMTipper t = new PMTipper();
        bytes memory route = abi.encodeCall(
            IZR.snwap,
            (address(0), 0, address(pm), WSTE, 0, address(t), abi.encodeCall(PMTipper.run, (address(pm), 0.3 ether)))
        );
        uint256 b0 = mallory.balance;
        vm.prank(mallory);
        pm.betETH{value: 1 ether}(wstId, true, mallory, 0, route);
        assertEq(b0 - mallory.balance, 0.7 ether);
        assertEq(address(pm).balance, 10 ether + forced);
        // ETH pot still fully claimable
        vm.warp(block.timestamp + 1 days);
        vm.prank(resolver);
        pm.void(ethId);
        vm.prank(alice);
        assertEq(pm.claim(ethId, alice), 10 ether);
        assertEq(address(pm).balance, forced); // forced ETH stranded, harmless
    }

    /// ERC6909 functions stay callable mid-route, but only on the caller's own balances.
    function test_midRoute6909_cannotMovePMShares() public {
        vm.prank(alice);
        pm.transfer(address(pm), wstId, 1);
        PMMover mv = new PMMover();
        bytes memory route = abi.encodeCall(
            IZR.snwap,
            (address(0), 0, address(pm), WSTE, 0, address(mv), abi.encodeCall(PMMover.run, (pm, wstId, mallory)))
        );
        assertFalse(_tryRoute(wstId, 0, route));
    }

    /// Route that refunds ETH to PM through zRouter's own refund logic works (receive under lock).
    function test_routeWethMarket_v2Refund() public {
        bytes memory route = abi.encodeCall(IZR.deposit, (WETH9, 0, 1 ether));
        // deposit wraps into router, not PM: bettor gets nothing and loses 1 ETH? -> AmountZero reverts
        assertFalse(_tryRoute(wethId, 1 ether, route));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IZR.deposit, (WETH9, 0, 1 ether));
        calls[1] = abi.encodeCall(IZR.sweep, (WETH9, 0, 0, address(pm)));
        vm.prank(mallory);
        uint256 s = pm.betETH{value: 1 ether}(wethId, true, mallory, 0, abi.encodeCall(IZR.multicall, (calls)));
        assertGe(s, 1 ether);
    }
}
