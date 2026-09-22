// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PM} from "../src/PM.sol";

/// Configurable hostile ERC20. Balances stored as "shares" scaled by `num/den` for rebasing.
contract PMHostile {
    enum Mode {
        Normal,
        NoReturn,
        FalseReturn,
        FeeOnTransfer,
        RevertZero,
        LyingBalance,
        Hook
    }

    Mode public mode;
    mapping(address => uint256) public raw;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;
    uint256 public num = 1;
    uint256 public den = 1;
    address public hookTarget;
    bytes public hookData;
    bool public lie;
    uint8 decMode; // 0 normal, 1 revert, 2 returns 300, 3 short return

    constructor(Mode m) {
        mode = m;
    }

    function setDec(uint8 d) external {
        decMode = d;
    }

    function decimals() external view returns (uint256) {
        if (decMode == 1) revert();
        if (decMode == 2) return 300;
        if (decMode == 3) {
            assembly {
                mstore(0, 6)
                return(0, 1)
            }
        }
        return 6;
    }

    function setHook(address t, bytes calldata d) external {
        hookTarget = t;
        hookData = d;
    }

    function setLie(bool l) external {
        lie = l;
    }

    function rebase(uint256 n, uint256 d) external {
        num = n;
        den = d;
    }

    function block_(address a, bool b) external {
        blocked[a] = b;
    }

    function mint(address to, uint256 a) external {
        raw[to] += a * den / num;
    }

    function balanceOf(address a) external view returns (uint256) {
        if (lie) return type(uint128).max;
        return raw[a] * num / den;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function _move(address f, address t, uint256 a) internal {
        require(!blocked[f] && !blocked[t], "blocked");
        if (mode == Mode.RevertZero) require(a != 0, "zero");
        uint256 r = a * den / num;
        raw[f] -= r;
        uint256 recv = mode == Mode.FeeOnTransfer ? r * 99 / 100 : r;
        raw[t] += recv;
        if (mode == Mode.Hook && hookTarget != address(0)) {
            (bool ok, bytes memory ret) = hookTarget.call(hookData);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }

    function _ret(bool v) internal view {
        if (mode == Mode.NoReturn) {
            assembly {
                return(0, 0)
            }
        }
        if (mode == Mode.FalseReturn) v = false;
        assembly {
            mstore(0, v)
            return(0, 32)
        }
    }

    function transfer(address t, uint256 a) external returns (bool) {
        _move(msg.sender, t, a);
        _ret(true);
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        _move(f, t, a);
        _ret(true);
    }
}

/// Recipient whose hook reenters PM.
contract PMReenter {
    PM pm;
    uint256 id;

    constructor(PM p, uint256 i) {
        pm = p;
        id = i;
    }

    function again() external {
        pm.claim(id, address(this));
    }

    function betAgain() external {
        pm.bet(id, true, 1, address(this), 0);
    }
}

contract PMAuditTokens is Test {
    PM pm;
    PMHostile good; // control ERC20
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address resolver = address(0x5E50);
    uint48 close;
    uint256 goodId;
    uint256 ethId;

    function setUp() public {
        pm = new PM();
        close = uint48(block.timestamp + 1 days);
        good = new PMHostile(PMHostile.Mode.Normal);
        goodId = pm.createMarket("good", resolver, address(good), close, true, 0, 0);
        ethId = pm.createMarket("eth", resolver, address(0), close, true, 0, 0);
        vm.deal(alice, 100 ether);
        good.mint(alice, 1000e6);
        vm.startPrank(alice);
        good.approve(address(pm), type(uint256).max);
        pm.bet(goodId, true, 1000e6, alice, 0);
        pm.betETH{value: 10 ether}(ethId, false, alice, 0, "");
        vm.stopPrank();
    }

    function _mk(PMHostile.Mode m) internal returns (PMHostile t, uint256 id) {
        t = new PMHostile(m);
        id = pm.createMarket("h", resolver, address(t), close, true, 1_000, 0);
        t.mint(alice, 1000e6);
        t.mint(bob, 1000e6);
        vm.prank(alice);
        t.approve(address(pm), type(uint256).max);
        vm.prank(bob);
        t.approve(address(pm), type(uint256).max);
    }

    function _controlsIntact() internal {
        assertEq(good.balanceOf(address(pm)), 1000e6);
        assertEq(address(pm).balance, 10 ether);
        vm.warp(close);
        vm.startPrank(resolver);
        pm.void(goodId);
        pm.void(ethId);
        vm.stopPrank();
        vm.startPrank(alice);
        assertEq(pm.claim(goodId, alice), 1000e6);
        assertEq(pm.claim(ethId, alice), 10 ether);
        vm.stopPrank();
    }

    function test_noReturnToken_worksEndToEnd() public {
        (PMHostile t, uint256 id) = _mk(PMHostile.Mode.NoReturn);
        vm.prank(alice);
        pm.bet(id, true, 100e6, alice, 0);
        vm.prank(alice);
        assertEq(pm.exit(id, true, 50e6, alice), 45e6);
        assertEq(t.balanceOf(address(pm)), 55e6);
        _controlsIntact();
    }

    function test_falseReturnToken_reverts() public {
        (, uint256 id) = _mk(PMHostile.Mode.FalseReturn);
        vm.prank(alice);
        vm.expectRevert();
        pm.bet(id, true, 100e6, alice, 0);
        _controlsIntact();
    }

    function test_feeOnTransfer_creditsArrival() public {
        (PMHostile t, uint256 id) = _mk(PMHostile.Mode.FeeOnTransfer);
        vm.prank(alice);
        uint256 s = pm.bet(id, true, 100e6, alice, 0);
        assertEq(s, 99e6);
        vm.prank(bob);
        pm.bet(id, false, 100e6, bob, 0);
        vm.warp(close);
        vm.prank(resolver);
        pm.void(id);
        vm.prank(alice);
        pm.claim(id, alice);
        vm.prank(bob);
        pm.claim(id, bob);
        assertEq(t.balanceOf(address(pm)), 0);
        vm.warp(block.timestamp - 1); // restore for controls helper
        _controlsIntact();
    }

    function test_rebaseDown_firstComeAcrossSameTokenMarkets_isolated() public {
        (PMHostile t, uint256 id) = _mk(PMHostile.Mode.Normal);
        uint256 id2 = pm.createMarket("h2", resolver, address(t), close, true, 0, 0);
        vm.prank(alice);
        pm.bet(id, true, 100e6, alice, 0);
        vm.prank(bob);
        pm.bet(id2, true, 100e6, bob, 0);
        t.rebase(1, 2); // halves every balance
        vm.warp(close);
        vm.startPrank(resolver);
        pm.void(id);
        pm.void(id2);
        vm.stopPrank();
        vm.prank(alice);
        assertEq(pm.claim(id, alice), 100e6); // takes bob's market's collateral too
        vm.prank(bob);
        vm.expectRevert();
        pm.claim(id2, bob);
        vm.warp(block.timestamp - 1);
        _controlsIntact();
    }

    function test_rebaseUp_surplusStranded() public {
        (PMHostile t, uint256 id) = _mk(PMHostile.Mode.Normal);
        vm.prank(alice);
        pm.bet(id, true, 100e6, alice, 0);
        t.rebase(2, 1);
        vm.warp(close);
        vm.prank(resolver);
        pm.void(id);
        vm.prank(alice);
        assertEq(pm.claim(id, alice), 100e6);
        assertEq(t.balanceOf(address(pm)), 100e6); // no sweep path
    }

    function test_hookReentry_locked() public {
        (PMHostile t, uint256 id) = _mk(PMHostile.Mode.Hook);
        PMReenter r = new PMReenter(pm, id);
        vm.prank(alice);
        pm.bet(id, true, 100e6, address(r), 0);
        // hook during bet's transferFrom -> reenter bet
        t.setHook(address(r), abi.encodeCall(PMReenter.betAgain, ()));
        vm.prank(bob);
        vm.expectRevert(bytes4(0x7939f424)); // inner Locked() surfaces as TransferFromFailed()
        pm.bet(id, false, 100e6, bob, 0);
        // hook during claim's transfer -> reenter claim
        t.setHook(address(0), "");
        vm.prank(bob);
        pm.bet(id, false, 100e6, bob, 0);
        vm.warp(close);
        vm.prank(resolver);
        pm.void(id);
        t.setHook(address(r), abi.encodeCall(PMReenter.again, ()));
        vm.prank(address(r));
        vm.expectRevert(bytes4(0x90b8ec18)); // inner Locked() surfaces as TransferFailed()
        pm.claim(id, address(r));
    }

    function test_blacklist_pmFreezesOnlyThatToken_userRedirects() public {
        (PMHostile t, uint256 id) = _mk(PMHostile.Mode.Normal);
        vm.prank(alice);
        pm.bet(id, true, 100e6, alice, 0);
        vm.prank(bob);
        pm.bet(id, false, 100e6, bob, 0);
        t.block_(alice, true);
        vm.warp(close);
        vm.prank(resolver);
        pm.void(id);
        vm.prank(alice);
        vm.expectRevert();
        pm.claim(id, alice);
        vm.prank(alice);
        pm.claim(id, address(0xCAFE)); // blacklisted user claims elsewhere
        t.block_(address(pm), true);
        vm.prank(bob);
        vm.expectRevert();
        pm.claim(id, bob);
        vm.warp(block.timestamp - 1);
        _controlsIntact();
    }

    function test_lyingBalance_mintsOnlyInItsOwnMarket() public {
        (PMHostile t, uint256 id) = _mk(PMHostile.Mode.Hook);
        t.setHook(address(t), abi.encodeCall(PMHostile.setLie, (true)));
        vm.prank(alice);
        uint256 s = pm.bet(id, true, 1e6, alice, 0);
        assertGt(s, 1e30); // absurd shares, but only against this token's pot
        t.setHook(address(0), "");
        t.setLie(false);
        vm.warp(close);
        vm.prank(resolver);
        pm.void(id);
        vm.prank(alice);
        vm.expectRevert(); // pot > real balance: claim just fails in that token
        pm.claim(id, alice);
        vm.warp(block.timestamp - 1);
        _controlsIntact();
    }

    function test_revertOnZero_noZeroSends() public {
        (, uint256 id) = _mk(PMHostile.Mode.RevertZero);
        vm.prank(alice);
        pm.bet(id, true, 100e6, alice, 0);
        vm.prank(bob);
        pm.bet(id, false, 100e6, bob, 0);
        vm.warp(close);
        vm.prank(resolver);
        pm.resolve(id, true); // fee 0 -> no fee send; claims nonzero
        vm.prank(alice);
        assertEq(pm.claim(id, alice), 200e6);
    }

    function test_decimals_garbage() public {
        (PMHostile t, uint256 id) = _mk(PMHostile.Mode.Normal);
        assertEq(pm.decimals(id), 6);
        t.setDec(1);
        assertEq(pm.decimals(id), 18);
        t.setDec(2);
        assertEq(pm.decimals(id), 18); // out of range falls back to 18
        t.setDec(3);
        assertEq(pm.decimals(id), 18);
    }
}
