// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionZap} from "../src/pools/PrecisionZap.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Models zRouter's public SafeExecutor while returning returndata to make
///      focused zap assertions convenient.
contract ZapExecutorMock {
    function checkpoint(PrecisionZap zap, address pool) external {
        zap.checkpoint(pool);
    }

    function exit(PrecisionZap zap, address pool, uint256 shares, uint256 min0, uint256 min1, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        return zap.exit(pool, shares, min0, min1, to);
    }

    function execute(address target, bytes calldata data) external payable returns (bytes memory result) {
        (bool ok, bytes memory returned) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returned, 0x20), mload(returned))
            }
        }
        return returned;
    }
}

contract ReentrantZapRecipient {
    ZapExecutorMock immutable executor;
    PrecisionZap immutable zap;
    address immutable pool;

    bool public attempted;
    bool public succeeded;

    constructor(ZapExecutorMock executor_, PrecisionZap zap_, address pool_) {
        (executor, zap, pool) = (executor_, zap_, pool_);
    }

    receive() external payable {
        attempted = true;
        (succeeded,) = address(executor)
            .call(
                abi.encodeCall(ZapExecutorMock.execute, (address(zap), abi.encodeCall(PrecisionZap.checkpoint, (pool))))
            );
    }
}

contract PrecisionZapAuditTest is Test {
    uint256 constant SQRT_LOW = 42426406871192;
    uint256 constant SQRT_MID = 44721359549995;
    uint256 constant SQRT_HIGH = 46904157598234;

    ZapExecutorMock executor;
    PrecisionPoolFactory factory;
    PrecisionZap zap;
    PrecisionPool pool;
    MockERC20 token;

    address lp = address(0xC11);
    address recipient = address(0xBEEF);

    function setUp() public {
        executor = new ZapExecutorMock();
        factory = new PrecisionPoolFactory(address(executor));
        zap = new PrecisionZap(factory, address(executor));
        token = new MockERC20("USD", 6);

        token.mint(lp, 1_000_000e6);
        vm.deal(lp, 100 ether);
        vm.startPrank(lp);
        token.approve(address(factory), type(uint256).max);
        (address deployed,,,) = factory.createAndSeed{value: 20 ether}(
            PrecisionPoolFactory.Market({
                token0: address(0),
                token1: address(token),
                sqrtPLow: SQRT_LOW,
                sqrtPHigh: SQRT_HIGH,
                fee: 500,
                hook: address(0),
                feeRecipient: address(0),
                creatorFeeBps: 0
            }),
            SQRT_MID,
            20 ether,
            60_000e6,
            0,
            lp
        );
        vm.stopPrank();
        pool = PrecisionPool(payable(deployed));
    }

    function _fund(uint256 shares) internal {
        executor.checkpoint(zap, address(pool));
        vm.prank(lp);
        pool.transfer(address(zap), shares);
    }

    function test_ConstructorRejectsExecutorWithoutCode() public {
        vm.expectRevert(PrecisionZap.Bad.selector);
        new PrecisionZap(factory, address(0xE0A));
    }

    function test_CheckpointRequiresExecutorAndRegisteredPool() public {
        vm.expectRevert(PrecisionZap.NotExecutor.selector);
        zap.checkpoint(address(pool));

        vm.expectRevert(PrecisionZap.NoPool.selector);
        executor.checkpoint(zap, address(token));
    }

    function test_CheckpointCannotBeOverwritten() public {
        executor.checkpoint(zap, address(pool));
        vm.expectRevert(PrecisionZap.BadCheckpoint.selector);
        executor.checkpoint(zap, address(pool));
    }

    function test_ExitConsumesOnlyFreshSharesAndPreservesEarlierDust() public {
        uint256 dust = 777;
        uint256 shares = pool.balanceOf(lp) / 3;
        vm.prank(lp);
        pool.transfer(address(zap), dust);

        uint256 supply = pool.totalSupply();
        uint256 expected0 = uint256(pool.reserve0()) * shares / supply;
        uint256 expected1 = uint256(pool.reserve1()) * shares / supply;
        uint256 ethBefore = recipient.balance;
        uint256 tokenBefore = token.balanceOf(recipient);

        _fund(shares);
        (uint256 amount0, uint256 amount1) = executor.exit(zap, address(pool), shares, expected0, expected1, recipient);

        assertEq(amount0, expected0);
        assertEq(amount1, expected1);
        assertEq(recipient.balance - ethBefore, expected0);
        assertEq(token.balanceOf(recipient) - tokenBefore, expected1);
        assertEq(pool.balanceOf(address(zap)), dust, "old balance must not be swept");
    }

    function test_MismatchedAmountRevertsWithoutDestroyingCheckpoint() public {
        uint256 shares = pool.balanceOf(lp) / 10;
        _fund(shares + 1);

        vm.expectRevert(PrecisionZap.BadCheckpoint.selector);
        executor.exit(zap, address(pool), shares, 0, 0, recipient);

        executor.exit(zap, address(pool), shares + 1, 0, 0, recipient);
        assertEq(pool.balanceOf(address(zap)), 0);
    }

    function test_PoolSlippageRevertPreservesFundingAndCheckpoint() public {
        uint256 shares = pool.balanceOf(lp) / 10;
        _fund(shares);

        vm.expectRevert(PrecisionPool.InsufficientOutput.selector);
        executor.exit(zap, address(pool), shares, type(uint256).max, 0, recipient);

        executor.exit(zap, address(pool), shares, 0, 0, recipient);
        assertEq(pool.balanceOf(address(zap)), 0);
    }

    function test_RecipientCannotMutateCheckpointDuringExitCallback() public {
        uint256 shares = pool.balanceOf(lp) / 4;
        _fund(shares);
        ReentrantZapRecipient receiver = new ReentrantZapRecipient(executor, zap, address(pool));

        executor.exit(zap, address(pool), shares, 0, 0, address(receiver));

        assertTrue(receiver.attempted(), "native payout must exercise callback");
        assertFalse(receiver.succeeded(), "callback must not enter checkpoint");
        assertEq(pool.balanceOf(address(zap)), 0);
    }
}
