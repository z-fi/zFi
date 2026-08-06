// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {ClassicalCurveSale, IZAMM, ZAMM, ERC20} from "../src/dao/ClassicalCurveSale.sol";

/// @notice Post-graduation routed swaps against the LIVE deployed sale contract.
///
///         No coin has graduated on mainnet yet, so every branch below is unexercised
///         in production. The sale custodies ETH for all curves in one balance, so the
///         invariant that actually matters is that a routed swap never settles using
///         more ETH or tokens than it brought in -- otherwise it eats another curve's
///         escrow. Each test pins a foreign curve's escrow underneath and asserts it
///         is untouched, and that the router keeps nothing for itself.
contract ClassicalCurveSaleRoutedTest is Test {
    ClassicalCurveSale constant SALE = ClassicalCurveSale(payable(0x000000005d9b18764E12E5aeefD6dA73110F85eb));

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CAP = 800_000_000e18;
    uint256 constant START_PRICE = 1_666_666_667;
    uint256 constant END_PRICE = 26_666_666_672;
    uint256 constant LP_TOKENS = 200_000_000e18;

    address creator = makeAddr("creator");
    address ben = makeAddr("beneficiary");
    address alice = makeAddr("alice");
    address recipient = makeAddr("recipient");

    address token;
    IZAMM.PoolKey key;
    uint256 baseETH;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FOUNDRY_ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        // On a fork these labels can land on addresses that already hold code. One of
        // them forwards any ETH it receives, which silently drains a refund out of the
        // balance under assertion and reads as a missing refund. Force plain EOAs.
        vm.etch(creator, "");
        vm.etch(alice, "");
        vm.etch(ben, "");
        vm.etch(recipient, "");
        vm.deal(creator, 1000 ether);
        vm.deal(alice, 1000 ether);
    }

    function _graduate(uint16 buyBps, uint16 sellBps, bool buyOnInput, bool sellOnInput, bytes32 salt) internal {
        vm.prank(creator);
        token = SALE.launch(
            creator,
            "Routed",
            "RTD",
            "",
            SUPPLY,
            salt,
            CAP,
            START_PRICE,
            END_PRICE,
            100,
            0,
            LP_TOKENS,
            address(0),
            25,
            0,
            0,
            0,
            ClassicalCurveSale.CreatorFee(ben, buyBps, sellBps, buyOnInput, sellOnInput),
            0,
            0
        );
        vm.prank(alice);
        SALE.buy{value: 20 ether}(token, CAP, 0, block.timestamp + 1);
        SALE.graduate(token);
        (key,) = SALE.poolKeyOf(token);

        // The sale is now holding only other curves' escrow. Nothing this test does
        // should move it by a single wei.
        baseETH = address(SALE).balance;
    }

    /// The sale must not be left holding ETH or tokens once a routed swap settles.
    function _assertNoLeak(string memory what) internal view {
        require(address(SALE).balance == baseETH, string.concat(what, ": router leaked/consumed ETH escrow"));
        require(ERC20(token).balanceOf(address(SALE)) == 0, string.concat(what, ": router retained tokens"));
    }

    // ── swapExactIn ──

    function test_routed_swapExactIn_buy_feeOnInput() public {
        _graduate(500, 500, true, false, bytes32(uint256(11)));
        uint256 benBefore = ben.balance;
        vm.prank(alice);
        uint256 out = SALE.swapExactIn{value: 1 ether}(key, 1 ether, 0, true, recipient, block.timestamp + 1);
        assertEq(ben.balance - benBefore, 0.05 ether, "5% of ETH input to beneficiary");
        assertEq(ERC20(token).balanceOf(recipient), out, "output delivered to recipient");
        _assertNoLeak("buy/onInput");
    }

    function test_routed_swapExactIn_buy_feeOnOutput() public {
        _graduate(500, 500, false, false, bytes32(uint256(12)));
        vm.prank(alice);
        uint256 out = SALE.swapExactIn{value: 1 ether}(key, 1 ether, 0, true, recipient, block.timestamp + 1);
        assertEq(ERC20(token).balanceOf(recipient), out, "net delivered");
        assertApproxEqRel(ERC20(token).balanceOf(ben), out * 500 / 9500, 1e15, "~5% of token output to beneficiary");
        _assertNoLeak("buy/onOutput");
    }

    function test_routed_swapExactIn_sell_feeOnOutput() public {
        _graduate(500, 500, true, false, bytes32(uint256(13)));
        uint256 bal = ERC20(token).balanceOf(alice) / 100;
        uint256 benBefore = ben.balance;
        uint256 recBefore = recipient.balance;
        vm.prank(alice);
        uint256 out = SALE.swapExactIn(key, bal, 0, false, recipient, block.timestamp + 1);
        assertEq(recipient.balance - recBefore, out, "net ETH delivered");
        assertGt(ben.balance - benBefore, 0, "beneficiary paid from ETH output");
        _assertNoLeak("sell/onOutput");
    }

    function test_routed_swapExactIn_sell_feeOnInput() public {
        _graduate(500, 500, true, true, bytes32(uint256(14)));
        uint256 bal = ERC20(token).balanceOf(alice) / 100;
        vm.prank(alice);
        uint256 out = SALE.swapExactIn(key, bal, 0, false, recipient, block.timestamp + 1);
        assertEq(recipient.balance, out, "ETH delivered");
        assertEq(ERC20(token).balanceOf(ben), bal * 500 / 10_000, "5% of token input to beneficiary");
        _assertNoLeak("sell/onInput");
    }

    // ── swapExactOut ── the branch that depends on ZAMM refunding unspent ETH.

    function test_routed_swapExactOut_buy_feeOnInput() public {
        _graduate(500, 500, true, false, bytes32(uint256(15)));
        uint256 want = 1_000_000e18;
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        uint256 spent = SALE.swapExactOut{value: 5 ether}(key, want, 5 ether, true, recipient, block.timestamp + 1);
        assertEq(ERC20(token).balanceOf(recipient), want, "exact output delivered");
        assertEq(aliceBefore - alice.balance, spent, "unspent ETH refunded to caller");
        assertLt(spent, 5 ether, "did not consume the whole max");
        _assertNoLeak("exactOut buy/onInput");
    }

    function test_routed_swapExactOut_buy_feeOnOutput() public {
        _graduate(500, 500, false, false, bytes32(uint256(16)));
        uint256 want = 1_000_000e18;
        vm.prank(alice);
        SALE.swapExactOut{value: 5 ether}(key, want, 5 ether, true, recipient, block.timestamp + 1);
        assertEq(ERC20(token).balanceOf(recipient), want, "exact net output delivered");
        assertGt(ERC20(token).balanceOf(ben), 0, "beneficiary took the gross-up");
        _assertNoLeak("exactOut buy/onOutput");
    }

    function test_routed_swapExactOut_sell_feeOnOutput() public {
        _graduate(500, 500, true, false, bytes32(uint256(17)));
        uint256 maxIn = ERC20(token).balanceOf(alice) / 100;
        uint256 want = 0.01 ether;
        uint256 recBefore = recipient.balance;
        vm.prank(alice);
        SALE.swapExactOut(key, want, maxIn, false, recipient, block.timestamp + 1);
        assertEq(recipient.balance - recBefore, want, "exact ETH delivered");
        _assertNoLeak("exactOut sell/onOutput");
    }

    function test_routed_swapExactOut_sell_feeOnInput() public {
        _graduate(500, 500, true, true, bytes32(uint256(18)));
        uint256 maxIn = ERC20(token).balanceOf(alice) / 100;
        uint256 want = 0.01 ether;
        uint256 recBefore = recipient.balance;
        vm.prank(alice);
        SALE.swapExactOut(key, want, maxIn, false, recipient, block.timestamp + 1);
        assertEq(recipient.balance - recBefore, want, "exact ETH delivered");
        _assertNoLeak("exactOut sell/onInput");
    }

    /// A routed swap must not be able to reach a pool that isn't a graduated curve,
    /// which is the only thing standing between an attacker and the shared ETH balance.
    function test_routed_rejectsForeignPool() public {
        _graduate(500, 500, true, false, bytes32(uint256(19)));

        IZAMM.PoolKey memory bad = key;
        bad.token0 = address(0xBEEF); // non-ETH token0
        vm.prank(alice);
        vm.expectRevert();
        SALE.swapExactIn{value: 1 ether}(bad, 1 ether, 0, true, alice, block.timestamp + 1);

        bad = key;
        bad.feeOrHook = 30; // plain-fee pool rather than this hook
        vm.prank(alice);
        vm.expectRevert();
        SALE.swapExactIn{value: 1 ether}(bad, 1 ether, 0, true, alice, block.timestamp + 1);

        bad = key;
        bad.id1 = 1; // ERC-6909 id rather than the ERC-20 pool
        vm.prank(alice);
        vm.expectRevert();
        SALE.swapExactIn{value: 1 ether}(bad, 1 ether, 0, true, alice, block.timestamp + 1);

        assertEq(address(SALE).balance, baseETH, "foreign-pool attempts moved no escrow");
    }
}
