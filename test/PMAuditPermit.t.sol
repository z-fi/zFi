// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PM} from "../src/PM.sol";

interface ITok {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function nonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external;
}

interface IP2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract PMAuditPermit is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant P2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    PM pm;
    address alice;
    uint256 aliceKey;
    address mallory = address(0xBAD);
    address resolver = address(0x5E50);
    uint256 usdcA;
    uint256 usdcB;
    uint256 wethId;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
        pm = new PM();
        (alice, aliceKey) = makeAddrAndKey("audit-alice");
        vm.etch(alice, "");
        vm.etch(mallory, "");
        uint48 c = uint48(block.timestamp + 1 days);
        usdcA = pm.createMarket("A", resolver, USDC, c, true, 0, 0);
        usdcB = pm.createMarket("B", resolver, USDC, c, true, 0, 0);
        wethId = pm.createMarket("W", resolver, WETH, c, true, 0, 0);
        deal(USDC, alice, 1_000e6);
        deal(USDC, mallory, 1_000e6);
        deal(WETH, alice, 10 ether);
    }

    function _sig2612(uint256 value) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 d = keccak256(
            abi.encodePacked(
                "\x19\x01",
                ITok(USDC).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        alice,
                        address(pm),
                        value,
                        ITok(USDC).nonces(alice),
                        block.timestamp
                    )
                )
            )
        );
        return vm.sign(aliceKey, d);
    }

    function _sigP2(uint256 amount, uint256 nonce) internal view returns (bytes memory) {
        bytes32 tp = keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), USDC, amount));
        bytes32 st = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
                ),
                tp,
                address(pm),
                nonce,
                block.timestamp
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(aliceKey, keccak256(abi.encodePacked("\x19\x01", IP2(P2).DOMAIN_SEPARATOR(), st)));
        return abi.encodePacked(r, s, v);
    }

    /// Mallory front-runs the permit; Alice's bet still lands on the allowance it created.
    function test_permitFrontrun_noGrief() public {
        (uint8 v, bytes32 r, bytes32 s) = _sig2612(100e6);
        vm.prank(mallory);
        ITok(USDC).permit(alice, address(pm), 100e6, block.timestamp, v, r, s);
        vm.prank(alice);
        assertEq(pm.betWithPermit(usdcA, true, 100e6, alice, 0, block.timestamp, v, r, s), 100e6);
    }

    /// WETH has no permit; its fallback deposit() makes the try succeed silently. Without an
    /// allowance the pull still fails; with one it works. No value moves on the permit call.
    function test_wethFallbackPermit_silentNoop() public {
        vm.prank(alice);
        vm.expectRevert(); // TransferFromFailed: silent permit granted nothing
        pm.betWithPermit(wethId, true, 1 ether, alice, 0, 0, 27, bytes32(0), bytes32(0));
        vm.prank(alice);
        ITok(WETH).approve(address(pm), 1 ether);
        vm.prank(alice);
        assertEq(pm.betWithPermit(wethId, true, 1 ether, alice, 0, 0, 27, bytes32(0), bytes32(0)), 1 ether);
    }

    /// Permit2: signature binds owner (msg.sender) and spender (PM); others can't use it, nonce
    /// can't replay. It does not bind market/side/recipient: Alice alone may aim it anywhere.
    function test_permit2_binding() public {
        vm.prank(alice);
        ITok(USDC).approve(P2, type(uint256).max);
        bytes memory sig = _sigP2(100e6, 7);
        vm.prank(mallory);
        vm.expectRevert();
        pm.betWithPermit2(usdcA, true, 100e6, mallory, 0, 7, block.timestamp, sig);
        vm.prank(alice);
        pm.betWithPermit2(usdcB, false, 100e6, alice, 0, 7, block.timestamp, sig);
        vm.prank(alice);
        vm.expectRevert(); // InvalidNonce
        pm.betWithPermit2(usdcA, true, 100e6, alice, 0, 7, block.timestamp, sig);
        assertEq(pm.balanceOf(alice, usdcB | 1), 100e6);
    }
}
