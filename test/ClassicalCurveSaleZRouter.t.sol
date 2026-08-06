// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {ClassicalCurveSale, IZAMM, ZAMM, ERC20} from "../src/dao/ClassicalCurveSale.sol";

interface IZRouter {
    function swapVZ(
        address to,
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
    function execute(address target, uint256 value, bytes calldata data) external payable returns (bytes memory);
    function trust(address target, bool ok) external payable;
    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external payable returns (uint256 amountOut);
}

/// @notice Can zRouter reach a graduated curve coin?
///
///         The sale contract doubles as the pool's zAMM hook. When a creator fee is
///         active its beforeAction rejects any swap whose reported sender is not the
///         sale itself, so "who called zAMM" decides whether a trade is possible.
///         These tests pin exactly which routes survive that, against the live
///         zRouter, zAMM and sale contracts.
contract ClassicalCurveSaleZRouterTest is Test {
    ClassicalCurveSale constant SALE = ClassicalCurveSale(payable(0x000000005d9b18764E12E5aeefD6dA73110F85eb));
    IZRouter constant ZROUTER = IZRouter(0x000000000000FB114709235f1ccBFfb925F600e4);

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CAP = 800_000_000e18;
    uint256 constant START_PRICE = 1_666_666_667;
    uint256 constant END_PRICE = 26_666_666_672;
    uint256 constant LP_TOKENS = 200_000_000e18;

    address creator = makeAddr("creator");
    address alice = makeAddr("alice");

    address token;
    IZAMM.PoolKey key;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FOUNDRY_ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        vm.etch(creator, "");
        vm.etch(alice, "");
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
    }

    /// @param withCreatorFee whether the launch arms the routing-enforcement hook
    function _graduate(bool withCreatorFee, bytes32 salt) internal {
        ClassicalCurveSale.CreatorFee memory cf;
        if (withCreatorFee) cf = ClassicalCurveSale.CreatorFee(creator, 5, 5, true, false);

        vm.prank(creator);
        token = SALE.launch(
            creator, "Route", "RTE", "", SUPPLY, salt, CAP, START_PRICE, END_PRICE,
            100, 0, LP_TOKENS, address(0), 25, 0, 0, 0, cf, 0, 0
        );
        vm.prank(alice);
        SALE.buy{value: 20 ether}(token, CAP, 0, block.timestamp + 1);
        SALE.graduate(token);
        (key,) = SALE.poolKeyOf(token);
    }

    /// zRouter's native zAMM path calls zAMM directly, so the hook sees zRouter as the
    /// sender and refuses. This is the composability cost of arming the creator fee.
    function test_zRouter_nativePath_blocked_whenCreatorFeeActive() public {
        _graduate(true, bytes32(uint256(31)));

        // Hoisted: an external call left in the argument list is evaluated first, and
        // expectRevert would bind to that staticcall instead of the swap.
        uint256 feeOrHook = SALE.hookFeeOrHook();
        uint256 deadline = block.timestamp + 1;

        vm.prank(alice);
        vm.expectRevert();
        ZROUTER.swapVZ{value: 1 ether}(alice, false, feeOrHook, address(0), token, 0, 0, 1 ether, 0, deadline);
    }

    /// Without a creator fee the hook only supplies the pool fee, and zRouter's normal
    /// path works — the coin is an ordinary zAMM pool that anything can route into.
    function test_zRouter_nativePath_works_withoutCreatorFee() public {
        _graduate(false, bytes32(uint256(32)));

        uint256 feeOrHook = SALE.hookFeeOrHook();
        uint256 before = ERC20(token).balanceOf(alice); // alice already holds her curve buy

        vm.prank(alice);
        (, uint256 amountOut) = ZROUTER.swapVZ{value: 1 ether}(
            alice, false, feeOrHook, address(0), token, 0, 0, 1 ether, 0, block.timestamp + 1
        );
        assertGt(amountOut, 0, "zRouter routed into the graduated pool");
        assertEq(ERC20(token).balanceOf(alice) - before, amountOut, "output delivered by zRouter");
    }

    /// The escape hatch: zRouter.execute() can call the sale's own router, which then
    /// calls zAMM as itself and satisfies the hook. But execute() is allowlist-gated,
    /// so this only works if the zRouter owner has trusted the sale contract.
    function test_zRouter_execute_needsTheSaleToBeTrusted() public {
        _graduate(true, bytes32(uint256(33)));

        bytes memory inner = abi.encodeWithSelector(
            SALE.swapExactIn.selector, key, uint256(1 ether), uint256(0), true, alice, block.timestamp + 1
        );

        // As things stand on mainnet today.
        vm.prank(alice);
        (bool okBefore,) =
            address(ZROUTER).call{value: 1 ether}(abi.encodeWithSelector(IZRouter.execute.selector, address(SALE), uint256(1 ether), inner));
        emit log_named_string("execute() works untrusted", okBefore ? "yes" : "no (allowlist)");

        // After the owner trusts it, the hop goes through.
        address owner = address(uint160(uint256(vm.load(address(ZROUTER), bytes32(uint256(_ownerSlot()))))));
        emit log_named_address("zRouter owner", owner);
        vm.prank(owner);
        ZROUTER.trust(address(SALE), true);

        uint256 balBefore = ERC20(token).balanceOf(alice);
        vm.prank(alice);
        ZROUTER.execute{value: 1 ether}(address(SALE), 1 ether, inner);
        assertGt(ERC20(token).balanceOf(alice) - balBefore, 0, "hop through the sale's router delivered tokens");
    }

    /// snwap is the generic executor and, unlike execute(), carries no allowlist. It
    /// hands the call to SafeExecutor, which calls the sale, which calls zAMM as itself
    /// -- so the hook is satisfied and the buy side needs no owner action at all.
    function test_zRouter_snwap_buy_reachesGraduatedCoin() public {
        _graduate(true, bytes32(uint256(34)));

        bytes memory inner = abi.encodeWithSelector(
            SALE.swapExactIn.selector, key, uint256(1 ether), uint256(0), true, alice, block.timestamp + 1
        );
        uint256 before = ERC20(token).balanceOf(alice);

        vm.prank(alice);
        uint256 out = ZROUTER.snwap{value: 1 ether}(
            address(0), 0, alice, token, 0, address(SALE), inner
        );

        assertGt(out, 0, "snwap routed into a creator-fee pool");
        assertEq(ERC20(token).balanceOf(alice) - before, out, "delta measured against the recipient");
    }

    /// The sell side does not compose the same way. snwap forwards the input tokens to
    /// the executor, but the sale pulls its input from whoever called it -- SafeExecutor,
    /// which holds nothing. It reverts as a whole rather than stranding the tokens, so
    /// selling through zRouter needs an adapter rather than the sale as the raw executor.
    function test_zRouter_snwap_sell_needsAnAdapter() public {
        _graduate(true, bytes32(uint256(35)));

        uint256 amt = ERC20(token).balanceOf(alice) / 100;
        bytes memory inner = abi.encodeWithSelector(
            SALE.swapExactIn.selector, key, amt, uint256(0), false, alice, block.timestamp + 1
        );

        vm.prank(alice);
        vm.expectRevert();
        ZROUTER.snwap(token, amt, alice, address(0), 0, address(SALE), inner);

        // Nothing was left behind in the sale by the failed attempt.
        assertEq(ERC20(token).balanceOf(address(SALE)), 0, "no tokens stranded in the sale");
    }

    /// Brute-force the owner slot rather than guessing at the storage layout.
    function _ownerSlot() internal view returns (uint256) {
        for (uint256 i; i < 64; ++i) {
            address a = address(uint160(uint256(vm.load(address(ZROUTER), bytes32(i)))));
            if (a != address(0) && uint256(vm.load(address(ZROUTER), bytes32(i))) >> 160 == 0) return i;
        }
        revert("owner slot not found");
    }
}
