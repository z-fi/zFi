// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "../lib/forge-std/src/Test.sol";

interface IMoloch {
    function shares() external view returns (address);
    function allowance(address token, address spender) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IShareSale {
    function buy(address dao, uint256 amount) external payable;
    function buyExactIn(address dao) external payable;
    function configure(address token, address payToken, uint256 price, uint40 deadline) external;
}

/// Reenters buy() from the ETH-refund callback — the one moment ShareSale hands
/// control back to the caller while still holding freshly minted shares.
contract ReentrantBuyer {
    IShareSale immutable sale;
    address immutable dao;
    uint256 public depth;
    uint256 public spent;
    bool public reentryReverted;

    constructor(IShareSale s, address d) payable { sale = s; dao = d; }

    function attack(uint256 amount, uint256 overpay) external {
        spent += amount * 333_000_000_000 + overpay;
        sale.buy{value: amount * 333_000_000_000 + overpay}(dao, amount * 1e18);
    }

    receive() external payable {
        // Only reenter once, on the refund from the outer buy.
        if (depth == 0 && address(this).balance > 1 ether) {
            depth = 1;
            try sale.buy{value: 1000 * 333_000_000_000}(dao, 1000e18) {}
            catch { reentryReverted = true; }
        }
    }
}

contract ShareSaleSecurityTest is Test {
    address constant DAO = 0xD5dcE9BEE03e69362981afE48323A657fCceB8bE;
    IShareSale constant SALE = IShareSale(0x0000000021ea5069B532CeE09058aB9e02EA60f9);
    uint256 constant PRICE = 333_000_000_000;

    IERC20 sh;

    function setUp() public {
        if (DAO.code.length == 0) { vm.skip(true); return; }
        sh = IERC20(IMoloch(DAO).shares());
    }

    /// Conservation: allowance burned == supply minted == shares delivered.
    function test_noDoubleMint() public {
        uint256 a0 = IMoloch(DAO).allowance(DAO, address(SALE));
        uint256 s0 = sh.totalSupply();
        uint256 saleHeld0 = sh.balanceOf(address(SALE));

        address buyer = address(0xB0B);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        SALE.buy{value: 50_000 * PRICE}(DAO, 50_000e18);

        uint256 burned = a0 - IMoloch(DAO).allowance(DAO, address(SALE));
        uint256 minted = sh.totalSupply() - s0;
        uint256 got = sh.balanceOf(buyer);
        console.log("allowance burned :", burned);
        console.log("supply minted    :", minted);
        console.log("buyer received   :", got);
        console.log("stuck in sale    :", sh.balanceOf(address(SALE)) - saleHeld0);
        assertEq(burned, minted, "minted more than the allowance permitted");
        assertEq(minted, got, "minted shares did not all reach the buyer");
        assertEq(sh.balanceOf(address(SALE)), saleHeld0, "shares stranded in the sale");
    }

    /// The cap holds even against a reentrant buyer using the refund callback.
    function test_reentrancyCannotMintFree() public {
        ReentrantBuyer atk = new ReentrantBuyer(SALE, DAO);
        vm.deal(address(atk), 100 ether);

        uint256 a0 = IMoloch(DAO).allowance(DAO, address(SALE));
        uint256 s0 = sh.totalSupply();
        uint256 daoEth0 = DAO.balance;
        uint256 atkEth0 = address(atk).balance;

        atk.attack(10_000, 5 ether); // deliberate overpay to force a refund

        uint256 burned = a0 - IMoloch(DAO).allowance(DAO, address(SALE));
        uint256 minted = sh.totalSupply() - s0;
        uint256 got = sh.balanceOf(address(atk));
        uint256 paid = atkEth0 - address(atk).balance;
        console.log("reentered?       :", atk.depth() == 1);
        console.log("reentry reverted :", atk.reentryReverted());
        console.log("allowance burned :", burned);
        console.log("supply minted    :", minted);
        console.log("attacker holds   :", got);
        console.log("attacker paid    :", paid);
        console.log("DAO received     :", DAO.balance - daoEth0);

        assertEq(burned, minted, "reentrancy minted beyond the allowance");
        assertEq(minted, got, "reentrancy stranded or duplicated shares");
        // Every share must have been paid for at the configured price.
        assertGe(paid, got / 1e18 * PRICE, "ATTACKER GOT SHARES FOR FREE");
        assertEq(DAO.balance - daoEth0, paid, "DAO did not receive every wei paid");
    }

    /// type(uint256).max is documented as "buy all remaining" — it must not overflow.
    function test_maxAmountClampsToRemaining() public {
        uint256 remaining = IMoloch(DAO).allowance(DAO, address(SALE));
        address whale = address(0x1234);
        vm.deal(whale, 100 ether);
        vm.prank(whale);
        SALE.buy{value: 10 ether}(DAO, type(uint256).max);

        console.log("remaining before :", remaining);
        console.log("whale received   :", sh.balanceOf(whale));
        console.log("allowance after  :", IMoloch(DAO).allowance(DAO, address(SALE)));
        assertEq(sh.balanceOf(whale), remaining, "max did not clamp to remaining");
        assertEq(IMoloch(DAO).allowance(DAO, address(SALE)), 0, "allowance not fully consumed");
        assertFalse(whale.balance == 100 ether - 10 ether, "no refund issued");
    }

    /// Nobody but the DAO can retarget its own sale.
    function test_outsiderCannotReconfigureTheSale() public {
        address attacker = address(0xBAD);
        vm.prank(attacker);
        SALE.configure(DAO, address(0), 1, 0); // writes sales[attacker], not sales[DAO]

        uint256 a0 = IMoloch(DAO).allowance(DAO, address(SALE));
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        SALE.buy{value: 1 ether}(DAO, 1000e18); // still at the DAO's real price

        uint256 paid = 1 ether - attacker.balance;
        console.log("attacker paid    :", paid);
        console.log("at real price    :", 1000 * PRICE);
        assertEq(paid, 1000 * PRICE, "attacker bought at a price they set themselves");
        assertEq(a0 - IMoloch(DAO).allowance(DAO, address(SALE)), 1000e18, "wrong amount minted");
    }
}
