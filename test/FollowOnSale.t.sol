// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {FollowOnSale} from "../src/FollowOnSale.sol";

interface IMoloch {
    function setAllowance(address spender, address token, uint256 amount) external payable;
}

interface IShares {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IMinter {
    function mintFromBalance(uint256 quantity) external returns (uint256[] memory);
    function deadline() external view returns (uint256);
}

contract FollowOnSaleTest is Test {
    address constant DAO = 0xE7Aa6cA3a9Ca3fe92a425dFeaD24900B9BF49853;
    address constant SHARES = 0x883d646d0C8202Aa23F01d4aF45E4E73804c3a49;
    address payable constant MINTER = payable(0xB3B3f4f1535305c5f40F9c0d6bCaf38032bF7F8e);

    FollowOnSale sale;
    uint256 deadline;
    address buyer;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        deadline = IMinter(MINTER).deadline();
        vm.warp(deadline - 30 days);

        sale = new FollowOnSale(DAO, SHARES, MINTER, deadline);

        vm.prank(DAO);
        IMoloch(DAO).setAllowance(address(sale), DAO, 10_000_000e18);

        buyer = makeAddr("buyer");
        vm.deal(buyer, 100 ether);
    }

    function test_buy() public {
        uint256 minterBefore = MINTER.balance;

        vm.prank(buyer);
        sale.buy{value: 1 ether}();

        assertEq(IShares(SHARES).balanceOf(buyer), 1_000_000e18, "1M shares");
        assertEq(MINTER.balance - minterBefore, 1 ether, "ETH to minter");
    }

    function test_buyFractional() public {
        vm.prank(buyer);
        sale.buy{value: 0.5 ether}();
        assertEq(IShares(SHARES).balanceOf(buyer), 500_000e18, "500k shares");
    }

    function test_mintFromBalanceAfterBuy() public {
        vm.prank(buyer);
        sale.buy{value: 1 ether}();

        assertGe(MINTER.balance, 1 ether);
        IMinter(MINTER).mintFromBalance(1);
    }

    function test_buyFailsAfterDeadline() public {
        vm.warp(deadline + 1);
        vm.prank(buyer);
        vm.expectRevert(FollowOnSale.Expired.selector);
        sale.buy{value: 1 ether}();
    }

    function test_buyFailsWhenAllowanceExhausted() public {
        vm.prank(DAO);
        IMoloch(DAO).setAllowance(address(sale), DAO, 1_000_000e18);

        vm.prank(buyer);
        sale.buy{value: 1 ether}();

        vm.prank(buyer);
        vm.expectRevert();
        sale.buy{value: 1 ether}();
    }

    function test_buyFailsZeroValue() public {
        vm.prank(buyer);
        vm.expectRevert();
        sale.buy{value: 0}();
    }

    function test_pauseBlocksBuys() public {
        sale.setPaused(true);

        vm.prank(buyer);
        vm.expectRevert(FollowOnSale.Paused.selector);
        sale.buy{value: 1 ether}();

        sale.setPaused(false);

        vm.prank(buyer);
        sale.buy{value: 1 ether}();
        assertEq(IShares(SHARES).balanceOf(buyer), 1_000_000e18, "works after unpause");
    }

    function test_onlyOwnerCanPause() public {
        vm.prank(buyer);
        vm.expectRevert(FollowOnSale.OnlyOwner.selector);
        sale.setPaused(true);
    }

    function test_multipleBuyers() public {
        address buyer2 = makeAddr("buyer2");
        vm.deal(buyer2, 10 ether);

        vm.prank(buyer);
        sale.buy{value: 1 ether}();
        vm.prank(buyer2);
        sale.buy{value: 2 ether}();

        assertEq(IShares(SHARES).balanceOf(buyer), 1_000_000e18, "buyer1 = 1M");
        assertEq(IShares(SHARES).balanceOf(buyer2), 2_000_000e18, "buyer2 = 2M");
    }

    function test_noFundsStuckInContract() public {
        uint256 saleBefore = address(sale).balance;

        vm.prank(buyer);
        sale.buy{value: 3 ether}();

        assertEq(address(sale).balance, saleBefore, "no ETH stuck");
        assertEq(IShares(SHARES).balanceOf(address(sale)), 0, "no shares stuck");
    }

    function test_largeBuyFullCap() public {
        // Buy 9 ETH = 9M shares (within 10M cap)
        vm.prank(buyer);
        sale.buy{value: 9 ether}();
        assertEq(IShares(SHARES).balanceOf(buyer), 9_000_000e18, "9M shares");
    }

    function test_partialCapOverflow() public {
        // Set 2M cap, buy 1 ETH, then try 2 ETH (only 1M left)
        vm.prank(DAO);
        IMoloch(DAO).setAllowance(address(sale), DAO, 2_000_000e18);

        vm.prank(buyer);
        sale.buy{value: 1 ether}();

        vm.prank(buyer);
        vm.expectRevert(); // underflow in allowance -= amount
        sale.buy{value: 2 ether}();
    }

    function test_cannotSendEthDirectly() public {
        vm.prank(buyer);
        (bool ok,) = address(sale).call{value: 1 ether}("");
        assertFalse(ok, "no receive/fallback");
    }
}
