// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import "../src/SwapboardView.sol";

contract SwapboardViewTest is Test {
    SwapboardView view_;
    address constant SWAPBOARD_V1 = 0x000000fF3D7A2d373615141d7489Ca66683DbecF;
    address constant SWAPBOARD_V2 = 0x00000000CC3915a0f5F98CBdC558Ac1a8e85B831;

    function setUp() public {
        vm.createSelectFork("https://ethereum.publicnode.com");
        view_ = new SwapboardView();
    }

    function test_getAllActiveOrders() public {
        // Use explicit gas to simulate real eth_call (30M+)
        (bool ok, bytes memory data) = address(view_).staticcall{gas: 20_000_000}(
            abi.encodeCall(view_.getAllActiveOrders, (SWAPBOARD_V1, SWAPBOARD_V2))
        );
        assertTrue(ok, "staticcall should succeed");
        SwapboardView.OrderView[] memory orders = abi.decode(data, (SwapboardView.OrderView[]));
        bool hasV1;
        bool hasV2;
        for (uint256 i; i < orders.length; i++) {
            assertTrue(orders[i].maker != address(0));
            assertTrue(orders[i].tokenA != address(0));
            assertTrue(orders[i].tokenB != address(0));
            assertTrue(orders[i].decimalsA > 0);
            assertTrue(orders[i].decimalsB > 0);
            if (orders[i].board == SWAPBOARD_V1) {
                hasV1 = true;
                assertFalse(orders[i].partialFill);
            }
            if (orders[i].board == SWAPBOARD_V2) hasV2 = true;
        }
    }

    function test_getAllActiveOrdersPaged() public {
        (bool ok, bytes memory data) = address(view_).staticcall{gas: 20_000_000}(
            abi.encodeCall(view_.getAllActiveOrdersPaged, (SWAPBOARD_V1, SWAPBOARD_V2, 0, 0, 5, 100))
        );
        assertTrue(ok, "staticcall should succeed");
        (SwapboardView.OrderView[] memory v1Orders,, SwapboardView.OrderView[] memory v2Orders,) =
            abi.decode(data, (SwapboardView.OrderView[], uint256, SwapboardView.OrderView[], uint256));
        assertTrue(v1Orders.length <= 5);
        assertTrue(v2Orders.length <= 5);
        for (uint256 i; i < v1Orders.length; i++) {
            assertEq(v1Orders[i].board, SWAPBOARD_V1);
            assertFalse(v1Orders[i].partialFill);
            assertTrue(bytes(v1Orders[i].symbolA).length > 0);
        }
        for (uint256 i; i < v2Orders.length; i++) {
            assertEq(v2Orders[i].board, SWAPBOARD_V2);
        }
    }
}
