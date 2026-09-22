// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PM} from "../src/PM.sol";

contract PMTok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 18;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract PMAuditAdversarial is Test {
    PM pm;
    PMTok tok;
    address resolver = makeAddr("resolver");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PM();
        tok = new PMTok();
    }

    function _bet(address who, uint256 m, bool yes, uint256 amt) internal returns (uint256 s) {
        tok.mint(who, amt);
        vm.startPrank(who);
        tok.approve(address(pm), amt);
        s = pm.bet(m, yes, amt, who, 0);
        vm.stopPrank();
    }

    // Full-precision mulDiv: huge-supply tokens claim and report positions without overflow.
    function test_claimOverflow_hugeSupplyToken() public {
        uint256 m = pm.createMarket("x", resolver, address(tok), uint48(block.timestamp + 1 days), false, 0, 0);
        uint256 big = 4e38;
        _bet(alice, m, true, big);
        _bet(bob, m, false, big);
        vm.warp(block.timestamp + 1 days);
        vm.prank(resolver);
        pm.resolve(m, true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = m;
        (,, uint256[] memory c) = pm.positions(alice, ids);
        assertEq(c[0], 2 * big);
        vm.prank(alice);
        assertEq(pm.claim(m, alice), 2 * big);
    }

    // Resolver can raise its fee in front of createMarket; creator has no bound.
    function test_resolverFrontrunsFee() public {
        vm.prank(resolver);
        pm.setResolverFeeBps(1_000);
        uint256 m = pm.createMarket("x", resolver, address(tok), uint48(block.timestamp + 1 days), false, 0, 0);
        assertEq(pm.getMarket(m).feeBps, 1_000);
    }

    // Odd (NO) ids are masked to their market in views.
    function test_oddIdViews() public {
        uint256 m = pm.createMarket("x", resolver, address(tok), uint48(block.timestamp + 1 days), false, 0, 0);
        _bet(alice, m, false, 1e18);
        PM.MarketView memory v = pm.getMarket(m | 1);
        assertEq(v.marketId, m);
        assertEq(v.yes, 0);
        assertEq(v.no, 1e18);
        assertEq(v.resolver, resolver);
        uint256[] memory ids = new uint256[](1);
        ids[0] = m | 1;
        (uint256[] memory y, uint256[] memory n,) = pm.positions(alice, ids);
        assertEq(y[0], 0);
        assertEq(n[0], 1e18);
    }

    // Shares sent to address(0) stay in `winners` and strand their pro-rata pot.
    function test_transferToZeroStrands() public {
        uint256 m = pm.createMarket("x", resolver, address(tok), uint48(block.timestamp + 1 days), false, 0, 0);
        _bet(alice, m, true, 1e18);
        _bet(bob, m, false, 1e18);
        vm.prank(alice);
        pm.transfer(address(0), m, 5e17);
        vm.warp(block.timestamp + 1 days);
        vm.prank(resolver);
        pm.resolve(m, true);
        vm.prank(alice);
        uint256 got = pm.claim(m, alice);
        assertEq(got, 1e18); // half of the 2e18 pot is stranded
    }

    // 1-wei-class bet on the empty side flips a would-be void into a full-pot option.
    function test_emptySideOption() public {
        uint256 m = pm.createMarket("x", resolver, address(tok), uint48(block.timestamp + 1 days), false, 0, 0);
        _bet(alice, m, true, 100e18);
        vm.warp(block.timestamp + 1 days - 1);
        _bet(bob, m, false, 1);
        vm.warp(block.timestamp + 1);
        vm.prank(resolver);
        pm.resolve(m, false);
        vm.prank(bob);
        assertEq(pm.claim(m, bob), 100e18 + 1);
    }

    // Far-future close: no arithmetic trouble at uint48 max.
    function test_maxClose() public {
        uint256 m = pm.createMarket("x", resolver, address(tok), type(uint48).max, true, 5_000, 5_000);
        uint256 s = _bet(alice, m, true, 1e40);
        assertEq(s, 1e40);
        vm.warp(uint256(type(uint48).max) - 1);
        vm.prank(alice);
        pm.exit(m, true, s, alice);
        vm.warp(uint256(type(uint48).max) + 30 days);
        pm.void(m);
    }

    function test_pageGas() public {
        bytes memory d = new bytes(1024);
        for (uint256 i; i < 1024; ++i) {
            d[i] = "a";
        }
        for (uint256 i; i < 400; ++i) {
            d[0] = bytes1(uint8(i % 250) + 1);
            d[1] = bytes1(uint8(i / 250) + 1);
            uint256 m =
                pm.createMarket(string(d), resolver, address(tok), uint48(block.timestamp + 1 days), false, 0, 0);
            _bet(alice, m, true, 1);
            _bet(bob, m, false, 1);
        }
        uint256[4] memory ns = [uint256(10), 50, 100, 400];
        for (uint256 k; k < 4; ++k) {
            vm.cool(address(pm));
            uint256 g = gasleft();
            pm.getMarkets(0, ns[k]);
            emit log_named_uint(string.concat("gas n=", vm.toString(ns[k])), g - gasleft());
        }
    }

    // Fees are full precision: a fee-bearing market whose pot exceeds max / feeBps still resolves and quotes.
    function test_hugePotWithFee_resolvesAndQuotes() public {
        vm.prank(resolver);
        pm.setResolverFeeBps(1_000);
        uint256 m = pm.createMarket("x", resolver, address(tok), uint48(block.timestamp + 1 days), false, 0, 0);
        uint256 big = type(uint256).max / 1_000;
        _bet(alice, m, true, big);
        _bet(bob, m, false, big);
        (uint256 s, uint256 p) = pm.quote(m, true, 1e18);
        assertEq(s, 1e18);
        assertGt(p, 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(resolver);
        pm.resolve(m, true);
        uint256 fee = (2 * big) / 10;
        assertEq(pm.feesOwed(resolver, address(tok)), fee);
        vm.prank(alice);
        assertEq(pm.claim(m, alice), 2 * big - fee);
    }
}
