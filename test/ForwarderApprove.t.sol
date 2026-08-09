// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {safeApprove as orderbolApprove} from "../src/forwarders/Orderbol.sol";
import {safeApprove as swapbatchApprove} from "../src/forwarders/Swapbatch.sol";
import {safeApprove as swapbolApprove} from "../src/forwarders/Swapbol.sol";

/// A completely ordinary ERC-20 approve: returns `true`.
///
/// @dev This is the whole regression. The zero-transition branch these helpers
///      grew for USDT-style tokens reuses one buffer for both approve calls, and
///      the reset call's return data lands ON the selector at 0x10 - so the
///      second call shipped a zeroed selector and every ordinary ERC-20 reverted
///      with ApproveFailed. Orderbol and Swapbatch could not approve ANYTHING;
///      Swapbol had already been fixed. A token that returns nothing would have
///      hidden it, so the mock here deliberately returns `true`.
contract PlainToken {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address to, uint256 amount) external returns (bool) {
        allowance[msg.sender][to] = amount;
        return true;
    }
}

/// The token the zero-transition branch actually exists for: returns nothing,
/// and refuses a nonzero -> nonzero allowance change.
contract UsdtStyleToken {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address to, uint256 amount) external {
        require(amount == 0 || allowance[msg.sender][to] == 0, "unsafe approve");
        allowance[msg.sender][to] = amount;
    }
}

contract ForwarderApprove is Test {
    PlainToken token;
    UsdtStyleToken usdt;
    address spender = address(0xBEEF);

    function setUp() public {
        token = new PlainToken();
        usdt = new UsdtStyleToken();
    }

    function test_orderbol_usdtStyleRepeatApproval() public {
        orderbolApprove(address(usdt), spender, 100);
        orderbolApprove(address(usdt), spender, 250);
        assertEq(usdt.allowance(address(this), spender), 250);
    }

    function test_swapbatch_usdtStyleRepeatApproval() public {
        swapbatchApprove(address(usdt), spender, 100);
        swapbatchApprove(address(usdt), spender, 250);
        assertEq(usdt.allowance(address(this), spender), 250);
    }

    function test_swapbol_usdtStyleRepeatApproval() public {
        swapbolApprove(address(usdt), spender, 100);
        swapbolApprove(address(usdt), spender, 250);
        assertEq(usdt.allowance(address(this), spender), 250);
    }

    function test_allThree_repeatApprovalOnPlainToken() public {
        orderbolApprove(address(token), spender, 100);
        orderbolApprove(address(token), spender, 250);
        swapbatchApprove(address(token), spender, 100);
        swapbatchApprove(address(token), spender, 250);
        swapbolApprove(address(token), spender, 100);
        swapbolApprove(address(token), spender, 250);
        assertEq(token.allowance(address(this), spender), 250);
    }

    function test_swapbol_works() public {
        swapbolApprove(address(token), spender, 100);
        assertEq(token.allowance(address(this), spender), 100);
    }

    function test_orderbol_works() public {
        orderbolApprove(address(token), spender, 100);
        assertEq(token.allowance(address(this), spender), 100);
    }

    function test_swapbatch_works() public {
        swapbatchApprove(address(token), spender, 100);
        assertEq(token.allowance(address(this), spender), 100);
    }
}
