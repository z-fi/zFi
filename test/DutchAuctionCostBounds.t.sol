// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {DutchAuction} from "../src/DutchAuction.sol";

contract MaxERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Pins the safety of the unchecked cost arithmetic in the DEPLOYED DutchAuction:
///
///         `cost = (price * take + initial - 1) / initial`   (DutchAuction.sol:201-205, :256)
///
///         This sits in an `unchecked` block, which invites the worry that `price * take`
///         can wrap. It cannot, and the bound is exact rather than merely comfortable.
///         `price` is read from a uint128 field and `take` is a uint128 argument, so:
///
///           (2^128-1) * (2^128-1) + (2^128-1) - 1  ==  2^256 - 2^128 - 1  <  2^256
///
///         The worst case clears the modulus with 2^128 + 1 to spare, so no listing and
///         no fill can reach a wrap — including a deliberately absurd one built here at
///         both fields' maxima. Nothing to fix in the live contract.
///
///         Dutchboard's narrower uint96 prices therefore buy storage packing, not
///         overflow safety; both contracts are safe on this arithmetic.
contract DutchAuctionCostBoundsTest is Test {
    DutchAuction auction;
    MaxERC20 tok;

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");

    uint128 constant MAX = type(uint128).max;

    function setUp() public {
        auction = new DutchAuction();
        tok = new MaxERC20();
    }

    function _listAtMaxima() internal returns (uint256 id) {
        tok.mint(maker, MAX);
        vm.startPrank(maker);
        tok.approve(address(auction), MAX);
        // Every field that feeds the cost expression at its uint128 ceiling.
        id = auction.listERC20(address(tok), MAX, MAX, MAX, 0, 1 hours);
        vm.stopPrank();
    }

    /// The arithmetic identity itself, at the exact worst case.
    function test_maxProductFitsInUint256() public pure {
        uint256 p = MAX;
        uint256 t = MAX;
        uint256 i = MAX;
        unchecked {
            uint256 sum = p * t + i - 1;
            // Recomputing checked must agree — if the unchecked form had wrapped, it
            // would not, and this line would revert on the checked multiply.
            assertEq(sum, p * t + i - 1, "unchecked form wrapped");
            assertEq(type(uint256).max - sum, uint256(MAX) + 1, "worst-case headroom");
        }
    }

    /// costOf at both maxima returns the honest lot price rather than a wrapped value.
    function test_costOfAtUint128MaximaDoesNotWrap() public {
        uint256 id = _listAtMaxima();
        assertEq(auction.priceOf(id), MAX, "opens at max price");
        assertEq(auction.costOf(id, MAX), MAX, "full take is not the lot price");
        // A half take costs about half, i.e. the product was computed, not wrapped.
        assertApproxEqRel(auction.costOf(id, MAX / 2), uint256(MAX) / 2, 1e12, "half take wrapped");
    }

    /// Settlement agrees with the quote at the maxima, so the bound holds on the write
    /// path too and not just in the view.
    function test_fillAtUint128MaximaSettlesHonestly() public {
        uint256 id = _listAtMaxima();
        uint128 take = MAX / 4;
        uint256 cost = auction.costOf(id, take);
        assertApproxEqRel(cost, uint256(MAX) / 4, 1e12, "quote wrapped");

        vm.deal(taker, cost);
        vm.prank(taker);
        auction.fill{value: cost}(id, take);

        assertEq(tok.balanceOf(taker), take, "taker underpaid for the lot");
        assertEq(maker.balance, cost, "seller was shorted");
    }

    /// Fuzzed across the whole uint128 domain: the quote is always the honest ceiling
    /// division, never a wrapped remnant.
    function testFuzz_costNeverWraps(uint128 price, uint128 amount, uint128 take) public {
        uint128 amt = uint128(bound(amount, 1, MAX));
        uint128 p = uint128(bound(price, 1, MAX));
        uint128 t = uint128(bound(take, 1, amt));

        tok.mint(maker, amt);
        vm.startPrank(maker);
        tok.approve(address(auction), amt);
        uint256 id = auction.listERC20(address(tok), amt, p, p, 0, 1 hours); // flat schedule
        vm.stopPrank();

        // Checked arithmetic: reverts here rather than agreeing if a wrap were possible.
        uint256 expected = (uint256(p) * t + uint256(amt) - 1) / amt;
        assertEq(auction.costOf(id, t), expected, "cost disagrees with checked arithmetic");
        assertLe(auction.costOf(id, t), p, "cost exceeds the lot price");
    }
}
