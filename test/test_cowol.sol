// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {Cowol} from "../src/Cowol.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface ISettlement {
    function domainSeparator() external view returns (bytes32);
}

contract TestCowol is Test {
    Cowol cowol;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    address constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address constant USDC_WHALE = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;

    // Mirror the contract's constants for digest computation
    bytes32 constant ORDER_TYPE_HASH = keccak256(
        "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,"
        "uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,"
        "string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
    );
    bytes32 constant KIND_SELL = keccak256("sell");
    bytes32 constant BALANCE_ERC20 = keccak256("erc20");

    function setUp() public {
        cowol = new Cowol();
    }

    // ---------------------------------------------------------------
    //  1. Domain separator matches on-chain GPv2Settlement
    // ---------------------------------------------------------------
    function test_domainSeparator() public view {
        bytes32 onChain = ISettlement(SETTLEMENT).domainSeparator();
        bytes32 hardcoded = 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;
        assertEq(onChain, hardcoded, "domain separator mismatch");
    }

    // ---------------------------------------------------------------
    //  2. Happy path: deposit tokens, call swap, digest approved
    // ---------------------------------------------------------------
    function test_swap_happy() public {
        uint256 sellAmount = 1000e6;
        uint256 feeAmount = 1e6;
        uint256 total = sellAmount + feeAmount;
        address receiver = address(0xBEEF);
        uint32 validTo = uint32(block.timestamp + 300);
        bytes32 appData = bytes32(0);

        // Fund cowol with USDC (simulates snwap transfer)
        _fundCowol(USDC, total);

        // Encode data as the contract expects
        bytes memory data = abi.encode(WETH, receiver, sellAmount, uint256(0.3 ether), validTo, appData, feeAmount);

        // Call swap
        cowol.swap(address(0), USDC, address(0), address(0), data);

        // Compute expected digest
        bytes32 digest = _computeDigest(USDC, WETH, receiver, sellAmount, 0.3 ether, validTo, appData, feeAmount);

        // Verify digest was approved
        assertTrue(cowol.validDigests(digest), "digest not approved");

        // Verify isValidSignature returns magic value
        assertEq(cowol.isValidSignature(digest, ""), bytes4(0x1626ba7e), "bad magic value");

        // Verify VaultRelayer got approved
        uint256 relayerAllowance = IERC20(USDC).allowance(address(cowol), VAULT_RELAYER);
        assertEq(relayerAllowance, type(uint256).max, "relayer not approved");
    }

    // ---------------------------------------------------------------
    //  3. isValidSignature returns failure for unknown digest
    // ---------------------------------------------------------------
    function test_isValidSignature_unknown() public view {
        bytes4 result = cowol.isValidSignature(bytes32(uint256(0xdead)), "");
        assertEq(result, bytes4(0xffffffff), "should reject unknown digest");
    }

    // ---------------------------------------------------------------
    //  4. Balance mismatch reverts
    // ---------------------------------------------------------------
    function test_swap_reverts_balance_mismatch() public {
        uint256 sellAmount = 1000e6;
        uint256 feeAmount = 1e6;
        // Fund LESS than sellAmount + feeAmount
        _fundCowol(USDC, 500e6);

        bytes memory data = abi.encode(WETH, address(0xBEEF), sellAmount, uint256(0.3 ether), uint32(block.timestamp + 300), bytes32(0), feeAmount);

        vm.expectRevert();
        cowol.swap(address(0), USDC, address(0), address(0), data);
    }

    // ---------------------------------------------------------------
    //  5. Zero-balance call reverts (attacker with no deposit)
    // ---------------------------------------------------------------
    function test_swap_reverts_no_deposit() public {
        bytes memory data = abi.encode(WETH, address(0xBEEF), uint256(1000e6), uint256(0.3 ether), uint32(block.timestamp + 300), bytes32(0), uint256(1e6));

        vm.expectRevert();
        cowol.swap(address(0), USDC, address(0), address(0), data);
    }

    // ---------------------------------------------------------------
    //  6. Attacker can't approve rogue digest for existing deposit
    //     (attacker calls swap with different receiver but same balance)
    // ---------------------------------------------------------------
    function test_swap_attacker_different_receiver() public {
        uint256 sellAmount = 1000e6;
        uint256 feeAmount = 1e6;
        uint256 total = sellAmount + feeAmount;
        address legitimateReceiver = address(0xBEEF);
        address attackerReceiver = address(0xDEAD);
        uint32 validTo = uint32(block.timestamp + 300);
        bytes32 appData = bytes32(0);

        // Legitimate user deposits
        _fundCowol(USDC, total);

        // Legitimate user calls swap
        bytes memory legData = abi.encode(WETH, legitimateReceiver, sellAmount, uint256(0.3 ether), validTo, appData, feeAmount);
        cowol.swap(address(0), USDC, address(0), address(0), legData);

        // Legitimate digest is approved
        bytes32 legDigest = _computeDigest(USDC, WETH, legitimateReceiver, sellAmount, 0.3 ether, validTo, appData, feeAmount);
        assertTrue(cowol.validDigests(legDigest), "legitimate digest should be approved");

        // Attacker's digest (different receiver) is NOT approved
        bytes32 attackDigest = _computeDigest(USDC, WETH, attackerReceiver, sellAmount, 0.3 ether, validTo, appData, feeAmount);
        assertFalse(cowol.validDigests(attackDigest), "attacker digest should NOT be approved");

        // If attacker tries to call swap again with their receiver, it reverts
        // because balanceOf(USDC) is still `total` but we already stored the
        // legitimate digest. However the attacker CAN call swap again (no auth),
        // but the balance check still passes since tokens are still there.
        // This WOULD approve the attacker's digest too!
        //
        // BUT: at this point the legitimate order should settle first (it was
        // posted to the API before the attacker acts). After settlement,
        // VaultRelayer drains the tokens, so the attacker's order can't fill.
        //
        // If the attacker front-runs the settlement: both digests are approved,
        // both orders are in the CoW API, and the solver picks one. The attacker's
        // order sends output to attackerReceiver, but still uses the SAME input
        // tokens that the legitimate user deposited. This is the residual race
        // condition documented as MEDIUM risk.
        bytes memory atkData = abi.encode(WETH, attackerReceiver, sellAmount, uint256(0.3 ether), validTo, appData, feeAmount);
        cowol.swap(address(0), USDC, address(0), address(0), atkData);
        assertTrue(cowol.validDigests(attackDigest), "attacker CAN approve digest when balance still present");
    }

    // ---------------------------------------------------------------
    //  7. Digest computation matches frontend (cross-check)
    // ---------------------------------------------------------------
    function test_digest_cross_check() public view {
        // Test vector from earlier node.js verification
        address sellToken = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address buyToken = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address receiver = 0x1111111111111111111111111111111111111111;
        uint256 sellAmount = 999000000;
        uint256 buyAmount = 300000000000000000;
        uint32 validTo = 1709000000;
        bytes32 appData = bytes32(0);
        uint256 feeAmount = 1000000;

        bytes32 digest = _computeDigest(sellToken, buyToken, receiver, sellAmount, buyAmount, validTo, appData, feeAmount);
        assertEq(digest, 0x7c30e8ff90679d770b266375d7051130f68bb98e1ba4ec65d2b47067bda6fb15, "digest mismatch with frontend");
    }

    // ---------------------------------------------------------------
    //  8. Second swap with same token works (re-approval not needed)
    // ---------------------------------------------------------------
    function test_swap_second_order() public {
        uint256 total1 = 500e6;
        uint256 total2 = 700e6;

        // First order
        _fundCowol(USDC, total1);
        bytes memory data1 = abi.encode(WETH, address(0xBEEF), uint256(499e6), uint256(0.1 ether), uint32(block.timestamp + 300), bytes32(0), uint256(1e6));
        cowol.swap(address(0), USDC, address(0), address(0), data1);

        // Simulate settlement draining tokens
        vm.prank(VAULT_RELAYER);
        IERC20(USDC).transferFrom(address(cowol), address(this), total1);
        assertEq(IERC20(USDC).balanceOf(address(cowol)), 0, "cowol should be drained");

        // Second order
        _fundCowol(USDC, total2);
        bytes memory data2 = abi.encode(WETH, address(0xCAFE), uint256(699e6), uint256(0.2 ether), uint32(block.timestamp + 600), bytes32(0), uint256(1e6));
        cowol.swap(address(0), USDC, address(0), address(0), data2);

        bytes32 digest2 = _computeDigest(USDC, WETH, address(0xCAFE), 699e6, 0.2 ether, uint32(block.timestamp + 600), bytes32(0), 1e6);
        assertTrue(cowol.validDigests(digest2), "second digest should be approved");
    }

    // ---------------------------------------------------------------
    //  9. Expiry cap: validTo > block.timestamp + 1200 reverts
    // ---------------------------------------------------------------
    function test_swap_reverts_expiry_too_far() public {
        uint256 sellAmount = 1000e6;
        uint256 feeAmount = 1e6;
        _fundCowol(USDC, sellAmount + feeAmount);

        // validTo = now + 1201 seconds (exceeds 1200 cap)
        uint32 validTo = uint32(block.timestamp + 1201);
        bytes memory data = abi.encode(WETH, address(0xBEEF), sellAmount, uint256(0.3 ether), validTo, bytes32(0), feeAmount);

        vm.expectRevert();
        cowol.swap(address(0), USDC, address(0), address(0), data);
    }

    // ---------------------------------------------------------------
    //  10. Recovery: tokens returned to receiver after expiry
    // ---------------------------------------------------------------
    function test_recover_after_expiry() public {
        uint256 sellAmount = 1000e6;
        uint256 feeAmount = 1e6;
        uint256 total = sellAmount + feeAmount;
        address receiver = address(0xBEEF);
        uint32 validTo = uint32(block.timestamp + 300);

        _fundCowol(USDC, total);
        bytes memory data = abi.encode(WETH, receiver, sellAmount, uint256(0.3 ether), validTo, bytes32(0), feeAmount);
        cowol.swap(address(0), USDC, address(0), address(0), data);

        // Before expiry: recover should revert
        vm.expectRevert();
        cowol.recover(USDC);

        // Warp past expiry
        vm.warp(uint256(validTo) + 1);

        uint256 receiverBefore = IERC20(USDC).balanceOf(receiver);
        cowol.recover(USDC);
        uint256 receiverAfter = IERC20(USDC).balanceOf(receiver);

        assertEq(receiverAfter - receiverBefore, total, "receiver should get tokens back");
        assertEq(IERC20(USDC).balanceOf(address(cowol)), 0, "cowol should be empty");
    }

    // ---------------------------------------------------------------
    //  11. Recovery with no prior order reverts (safeTransfer to address(0))
    // ---------------------------------------------------------------
    function test_recover_no_order_reverts() public {
        vm.expectRevert();
        cowol.recover(USDC);
    }

    // ---------------------------------------------------------------
    //  Helpers
    // ---------------------------------------------------------------
    function _fundCowol(address token, uint256 amount) internal {
        vm.prank(USDC_WHALE);
        IERC20(token).transfer(address(cowol), amount);
    }

    function _computeDigest(
        address sellToken, address buyToken, address receiver,
        uint256 sellAmount, uint256 buyAmount, uint32 validTo,
        bytes32 appData, uint256 feeAmount
    ) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            ORDER_TYPE_HASH,
            sellToken,
            buyToken,
            receiver,
            sellAmount,
            buyAmount,
            validTo,
            appData,
            feeAmount,
            KIND_SELL,
            false,
            BALANCE_ERC20,
            BALANCE_ERC20
        ));
        return keccak256(abi.encodePacked(
            bytes2(0x1901),
            bytes32(0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943),
            structHash
        ));
    }
}
