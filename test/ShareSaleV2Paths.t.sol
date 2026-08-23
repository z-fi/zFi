// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "../lib/forge-std/src/Test.sol";
import {ShareSaleV2} from "../src/dao/ShareSaleV2.sol";

interface IMolochX {
    function shares() external view returns (address);
    function loot() external view returns (address);
    function setAllowance(address spender, address token, uint256 amount) external;
    function ragequit(address[] calldata t, uint256 s, uint256 l) external;
}
interface IERC20X {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// The paths the grief tests never touched: ERC20 payment, loot, deadline, refund,
/// reentrancy, and the boundaries of configure().
contract PathsTest is Test {
    address constant DAO = 0xD5dcE9BEE03e69362981afE48323A657fCceB8bE;
    uint256 constant PRICE = 333_000_000_000;
    ShareSaleV2 v2;
    IERC20X sh;
    address buyer = address(0xB0B);

    function setUp() public {
        // Needs a fork at or after this DAO's summon; foundry.toml pins earlier.
        if (DAO.code.length == 0) { vm.skip(true); return; }
        sh = IERC20X(IMolochX(DAO).shares());
        v2 = new ShareSaleV2();
        vm.prank(DAO);
        IMolochX(DAO).setAllowance(address(v2), DAO, type(uint256).max);
    }

    function _cfgEth(uint40 dl) internal {
        uint256 cap = sh.totalSupply() + 1_000_000e18; // hoisted: would eat the prank
        vm.prank(DAO);
        v2.configure(DAO, address(0), PRICE, dl, cap);
    }

    function test_overpaymentIsRefunded() public {
        _cfgEth(0);
        vm.deal(buyer, 10 ether);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        v2.buy{value: 1 ether}(DAO, 1000e18);
        uint256 spent = before - buyer.balance;
        console.log("cost      :", 1000 * PRICE);
        console.log("spent     :", spent);
        assertEq(spent, 1000 * PRICE, "overpayment not refunded");
    }

    function test_underpaymentReverts() public {
        _cfgEth(0);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        (bool ok,) = address(v2).call{value: 1000 * PRICE - 1}(
            abi.encodeWithSignature("buy(address,uint256)", DAO, uint256(1000e18)));
        assertFalse(ok, "underpayment accepted");
    }

    function test_deadlineIsEnforced() public {
        _cfgEth(uint40(block.timestamp + 1 days));
        vm.deal(buyer, 10 ether);
        vm.warp(block.timestamp + 2 days);
        vm.prank(buyer);
        (bool ok,) = address(v2).call{value: 1000 * PRICE}(
            abi.encodeWithSignature("buy(address,uint256)", DAO, uint256(1000e18)));
        assertFalse(ok, "sold past deadline");
    }

    function test_ethSentToAnErc20SaleReverts() public {
        uint256 cap = sh.totalSupply() + 1000e18;
        vm.prank(DAO);
        v2.configure(DAO, address(sh), PRICE, 0, cap);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        (bool ok,) = address(v2).call{value: 1 ether}(
            abi.encodeWithSignature("buy(address,uint256)", DAO, uint256(1e18)));
        assertFalse(ok, "ETH accepted on an ERC20 sale");
    }

    function test_lootSentinelResolves() public {
        address lootAddr = IMolochX(DAO).loot();
        vm.prank(DAO);
        IMolochX(DAO).setAllowance(address(v2), address(1007), type(uint256).max);
        vm.prank(DAO);
        v2.configure(address(1007), address(0), PRICE, 0, 5000e18);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        v2.buy{value: 1000 * PRICE}(DAO, 1000e18);
        console.log("loot to buyer:", IERC20X(lootAddr).balanceOf(buyer) / 1e18);
        assertEq(IERC20X(lootAddr).balanceOf(buyer), 1000e18, "loot not delivered");
    }

    function test_configureRejectsZeroes() public {
        vm.startPrank(DAO);
        vm.expectRevert(ShareSaleV2.ZeroPrice.selector);
        v2.configure(DAO, address(0), 0, 0, 1000e18);
        vm.expectRevert(ShareSaleV2.ZeroCap.selector);
        v2.configure(DAO, address(0), PRICE, 0, 0);
        vm.stopPrank();
    }

    function test_outsiderCannotConfigureAnotherDao() public {
        _cfgEth(0);
        vm.prank(address(0xBAD));
        v2.configure(DAO, address(0), 1, 0, type(uint256).max); // writes sales[0xBAD]
        vm.deal(buyer, 10 ether);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        v2.buy{value: 1 ether}(DAO, 1000e18);
        assertEq(before - buyer.balance, 1000 * PRICE, "attacker repriced the DAO's sale");
    }

    function test_capBelowSupplyIsInert() public {
        vm.prank(DAO);
        v2.configure(DAO, address(0), PRICE, 0, 1e18); // cap under current supply
        assertEq(v2.remaining(DAO), 0, "should be zero");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        (bool ok,) = address(v2).call{value: PRICE}(
            abi.encodeWithSignature("buy(address,uint256)", DAO, uint256(1e18)));
        assertFalse(ok, "minted under an already-exceeded cap");
    }

    function test_reentrantBuyerCannotMintFree() public {
        _cfgEth(0);
        Reenter atk = new Reenter(v2, DAO);
        vm.deal(address(atk), 20 ether);
        uint256 supply0 = sh.totalSupply();
        atk.go(1000, 5 ether);
        uint256 minted = sh.totalSupply() - supply0;
        uint256 paid = 20 ether - address(atk).balance;
        console.log("minted:", minted / 1e18, " got:", sh.balanceOf(address(atk)) / 1e18);
        console.log("paid  :", paid);
        assertEq(sh.balanceOf(address(atk)), minted, "shares stranded or duplicated");
        assertGe(paid, minted / 1e18 * PRICE, "got shares for free");
    }
}

contract Reenter {
    ShareSaleV2 immutable v2; address immutable dao; uint256 public depth;
    constructor(ShareSaleV2 a, address d) { v2 = a; dao = d; }
    function go(uint256 n, uint256 over) external {
        v2.buy{value: n * 333_000_000_000 + over}(dao, n * 1e18);
    }
    receive() external payable {
        if (depth == 0 && address(this).balance > 1 ether) {
            depth = 1;
            try v2.buy{value: 500 * 333_000_000_000}(dao, 500e18) {} catch {}
        }
    }
}
