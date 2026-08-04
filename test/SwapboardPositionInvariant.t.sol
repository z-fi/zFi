// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @dev Positions had only unit tests. The pool's H-01 showed that unit tests
/// pass while sequences break, so this drives random create / transfer / fill /
/// cancel and asserts the properties that make a position mean anything.
contract PositionHandler is Test {
    Swapboard public sb;
    MockERC20 public tka;
    MockERC20 public tkb;
    uint256[] public created;
    address[] actors;

    constructor(Swapboard s, MockERC20 a, MockERC20 b) {
        (sb, tka, tkb) = (s, a, b);
        for (uint256 i; i < 3; ++i) {
            address x = address(uint160(0xE000 + i));
            actors.push(x);
            a.mint(x, 1e30);
            b.mint(x, 1e30);
            vm.startPrank(x);
            a.approve(address(s), type(uint256).max);
            b.approve(address(s), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _a(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function count() external view returns (uint256) {
        return created.length;
    }

    function create(uint256 seed, uint256 amtA, uint256 amtB) public {
        amtA = bound(amtA, 1e6, 1e24);
        amtB = bound(amtB, 1e6, 1e24);
        address who = _a(seed);
        vm.prank(who);
        try sb.createOrder(address(tka), amtA, address(tkb), amtB, true, 0, false, false, address(0))
        returns (uint256 id) {
            created.push(id);
        } catch {}
    }

    function transfer(uint256 seed, uint256 idx) public {
        if (created.length == 0) return;
        uint256 id = created[idx % created.length];
        address to = _a(seed);
        address from;
        try sb.ownerOf(id) returns (address o) {
            from = o;
        } catch {
            return;
        }
        if (from == to) return;
        vm.prank(from);
        try sb.transferFrom(from, to, id) {} catch {}
    }

    function fill(uint256 seed, uint256 idx, uint256 amt) public {
        if (created.length == 0) return;
        uint256 id = created[idx % created.length];
        amt = bound(amt, 1, 1e24);
        address who = _a(seed);
        vm.prank(who);
        try sb.fillOrder(id, block.timestamp, amt, 0, who) {} catch {}
    }

    function cancel(uint256 idx) public {
        if (created.length == 0) return;
        uint256 id = created[idx % created.length];
        address owner;
        try sb.ownerOf(id) returns (address o) {
            owner = o;
        } catch {
            return;
        }
        vm.prank(owner);
        try sb.cancelOrder(id) {} catch {}
    }
}

contract SwapboardPositionInvariantTest is Test {
    Swapboard sb;
    MockWETH weth;
    MockERC20 tka;
    MockERC20 tkb;
    PositionHandler handler;

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        tka = new MockERC20("A", 18);
        tkb = new MockERC20("B", 18);
        handler = new PositionHandler(sb, tka, tkb);
        targetContract(address(handler));
        targetSender(address(0xC0FFEE));
    }

    /// @dev A receipt, once minted, is never destroyed. It was previously
    /// burned on close, which left any contract holding it pointing at a
    /// nonexistent token - stranding whatever that contract held. `active` is
    /// what carries liveness now; existence is permanent.
    function invariant_EveryCreatedPositionStillExists() public view {
        uint256 n = handler.count();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.created(i);
            bool exists;
            try sb.ownerOf(id) returns (address) {
                exists = true;
            } catch {}
            assertTrue(exists, "a receipt was destroyed");
        }
    }

    /// @dev The sync that lets settlement keep using `maker` untouched. If
    /// these ever diverge, payouts go to the wrong address.
    function invariant_OwnerAlwaysMatchesStoredMaker() public view {
        uint256 n = handler.count();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.created(i);
            try sb.ownerOf(id) returns (address owner) {
                (address maker,,,,,,,,,,) = sb.orders(id);
                assertEq(owner, maker, "position owner and stored maker diverged");
            } catch {}
        }
    }

    /// @dev No position may come to rest where its escrow could never be paid.
    function invariant_NoPositionAtAnUnpayableAddress() public view {
        assertEq(sb.balanceOf(address(sb)), 0, "board holds a position");
        assertEq(sb.balanceOf(address(weth)), 0, "wrapper holds a position");
    }

    /// @dev Escrow solvency: the board must hold at least what every live
    /// order still promises.
    function invariant_EscrowCoversEveryLiveOrder() public view {
        uint256 owed;
        uint256 n = handler.count();
        for (uint256 i; i < n; ++i) {
            (, bool active,,,,,,, uint256 amountA,,) = sb.orders(handler.created(i));
            if (active) owed += amountA;
        }
        assertGe(tka.balanceOf(address(sb)), owed, "escrow does not cover live orders");
    }
}
