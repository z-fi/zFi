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
    function checkpoint(PrecisionZap zap, address pool, bytes32 intent) external {
        zap.checkpoint(pool, intent);
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
                abi.encodeCall(
                    ZapExecutorMock.execute,
                    (address(zap), abi.encodeCall(PrecisionZap.checkpoint, (pool, bytes32(uint256(1)))))
                )
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
        factory = new PrecisionPoolFactory(address(executor), type(PrecisionPool).creationCode);
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

    /// @dev The exit a checkpoint commits to, as the zap hashes it.
    function _exitIntent(uint256 shares, uint256 min0, uint256 min1, address to)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodeCall(PrecisionZap.exit, (address(pool), shares, min0, min1, to)));
    }

    /// @dev Checkpoint for a specific exit, then fund it. The intent defaults to
    ///      the plain full-value exit most tests then perform.
    function _fund(uint256 shares) internal {
        _fund(shares, _exitIntent(shares, 0, 0, recipient));
    }

    function _fund(uint256 shares, bytes32 intent) internal {
        executor.checkpoint(zap, address(pool), intent);
        vm.prank(lp);
        pool.transfer(address(zap), shares);
    }

    function test_ConstructorRejectsExecutorWithoutCode() public {
        vm.expectRevert(PrecisionZap.Bad.selector);
        new PrecisionZap(factory, address(0xE0A));
    }

    function test_CheckpointRequiresExecutorAndRegisteredPool() public {
        bytes32 intent = _exitIntent(1, 0, 0, recipient);
        vm.expectRevert(PrecisionZap.NotExecutor.selector);
        zap.checkpoint(address(pool), intent);

        vm.expectRevert(PrecisionZap.NoPool.selector);
        executor.checkpoint(zap, address(token), intent);

        vm.expectRevert(PrecisionZap.Bad.selector);
        executor.checkpoint(zap, address(pool), bytes32(0));
    }

    function test_CheckpointCannotBeOverwritten() public {
        bytes32 intent = _exitIntent(1, 0, 0, recipient);
        executor.checkpoint(zap, address(pool), intent);
        vm.expectRevert(PrecisionZap.BadCheckpoint.selector);
        executor.checkpoint(zap, address(pool), intent);
    }

    /// @dev The zap's H-01 analogue. The shares arrive between `checkpoint` and
    /// `exit`, the executor is public, and its guard clears when each call
    /// returns - so the checkpoint has to name the exit it is for. Otherwise a
    /// callback during the funding transfer could spend the same fresh delta on
    /// an exit paying itself.
    function test_FundedCheckpointCannotBeSpentOnAnotherExit() public {
        uint256 shares = pool.balanceOf(lp) / 4;
        _fund(shares, _exitIntent(shares, 0, 0, recipient));

        address thief = address(0xBAD);
        uint256 before = thief.balance;

        vm.expectRevert(PrecisionZap.IntentMismatch.selector);
        executor.exit(zap, address(pool), shares, 0, 0, thief);

        assertEq(thief.balance, before, "exit was redirected");

        // The committed exit still works, so the binding costs nothing.
        executor.exit(zap, address(pool), shares, 0, 0, recipient);
        assertEq(pool.balanceOf(address(zap)), 0);
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

        _fund(shares, _exitIntent(shares, expected0, expected1, recipient));
        (uint256 amount0, uint256 amount1) = executor.exit(zap, address(pool), shares, expected0, expected1, recipient);

        assertEq(amount0, expected0);
        assertEq(amount1, expected1);
        assertEq(recipient.balance - ethBefore, expected0);
        assertEq(token.balanceOf(recipient) - tokenBefore, expected1);
        assertEq(pool.balanceOf(address(zap)), dust, "old balance must not be swept");
    }

    /// @dev An exit for the wrong amount is refused and takes nothing with it.
    /// The checkpoint now names the amount too, so this is caught as a
    /// mismatched intent before the balance delta is even compared.
    function test_MismatchedAmountRevertsWithoutDestroyingCheckpoint() public {
        uint256 shares = pool.balanceOf(lp) / 10;
        _fund(shares + 1, _exitIntent(shares + 1, 0, 0, recipient));

        vm.expectRevert(PrecisionZap.IntentMismatch.selector);
        executor.exit(zap, address(pool), shares, 0, 0, recipient);

        executor.exit(zap, address(pool), shares + 1, 0, 0, recipient);
        assertEq(pool.balanceOf(address(zap)), 0);
    }

    /// @dev A pool-level revert inside the COMMITTED exit must not consume the
    /// funding or the checkpoint - the transient clears are rolled back with
    /// everything else, so the same call can be attempted again and behaves
    /// identically rather than finding its checkpoint gone.
    function test_PoolSlippageRevertPreservesFundingAndCheckpoint() public {
        uint256 shares = pool.balanceOf(lp) / 10;
        _fund(shares, _exitIntent(shares, type(uint256).max, 0, recipient));

        vm.expectRevert(PrecisionPool.InsufficientOutput.selector);
        executor.exit(zap, address(pool), shares, type(uint256).max, 0, recipient);

        assertEq(pool.balanceOf(address(zap)), shares, "funding was consumed by a failed exit");

        vm.expectRevert(PrecisionPool.InsufficientOutput.selector);
        executor.exit(zap, address(pool), shares, type(uint256).max, 0, recipient);

        assertEq(pool.balanceOf(address(zap)), shares, "checkpoint did not survive the revert");
    }

    function test_RecipientCannotMutateCheckpointDuringExitCallback() public {
        uint256 shares = pool.balanceOf(lp) / 4;
        ReentrantZapRecipient receiver = new ReentrantZapRecipient(executor, zap, address(pool));
        _fund(shares, _exitIntent(shares, 0, 0, address(receiver)));

        executor.exit(zap, address(pool), shares, 0, 0, address(receiver));

        assertTrue(receiver.attempted(), "native payout must exercise callback");
        assertFalse(receiver.succeeded(), "callback must not enter checkpoint");
        assertEq(pool.balanceOf(address(zap)), 0);
    }
}
