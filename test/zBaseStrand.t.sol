// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

address constant WETH = 0x4200000000000000000000000000000000000006;
address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

interface IRouter {
    function multicall(bytes[] calldata) external payable returns (bytes[] memory);
    function deposit(address, uint256) external payable;
    function swapV2(address, bool, address, address, uint256, uint256, uint256)
        external
        payable
        returns (uint256, uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function deposit() external payable;
}

/// @dev Against the REAL deployed Base router, to settle whether the swapV2
/// refund bug can actually strand a user's ether.
contract BaseStrandTest is Test {
    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")));
        vm.deal(alice, 100 ether);
    }

    function testCreditFundedEthLegStrandsMsgValue() public {
        assertGt(ZROUTER.code.length, 0, "router must be deployed");
        deal(USDC, alice, 5000e6);

        vm.startPrank(alice);
        IERC20(USDC).approve(ZROUTER, type(uint256).max);

        bytes[] memory calls = new bytes[](2);
        // Leg 1 lands WETH in the router, crediting (router, WETH).
        calls[0] = abi.encodeCall(
            IRouter.swapV2, (ZROUTER, false, USDC, WETH, 2000e6, 0, block.timestamp + 1)
        );
        // Leg 2 is ETH-in, so tokenIn maps to WETH and leg 1's credit pays for
        // it. The attached ether is then spent by nothing, and the refund sits
        // inside the `else if (ethIn)` branch that this path never enters.
        calls[1] = abi.encodeCall(
            IRouter.swapV2, (alice, false, address(0), USDC, 0.1 ether, 0, block.timestamp + 1)
        );

        uint256 routerBefore = ZROUTER.balance;
        IRouter(ZROUTER).multicall{value: 1 ether}(calls);
        vm.stopPrank();

        uint256 stranded = ZROUTER.balance - routerBefore;
        emit log_named_uint("ether stranded in the router (wei)", stranded);
        assertEq(stranded, 1 ether, "alice's attached ether is stuck and sweepable");
    }
}
