// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";
import {PrecisionPoolFactory} from "./PrecisionPoolFactory.sol";

/// @title PrecisionZap
/// @notice Redeems PrecisionPool LP shares inside a zRouter route, so exiting
///         a band and swapping the proceeds settle in one transaction.
/// @dev The trusted executor checkpoints this contract's share balance before
///      funding. `exit` consumes the exact new balance and calls
///      `removeLiquidity`, preventing earlier share balances from being spent.
contract PrecisionZap {
    uint256 constant CHECKPOINT_NAMESPACE = 1 << 255;
    uint256 constant REENTRANCY_SLOT = 1 << 254;
    /// @dev Disjoint from both of the above for any 160-bit token address.
    uint256 constant INTENT_NAMESPACE = (1 << 255) | (1 << 253);

    /// @notice The only immediate caller permitted to drive a prefunded redemption.
    /// @dev This is the executor that dispatches the route, not the router.
    ///      The live executor is publicly callable, so this restriction is a
    ///      call-path invariant rather than end-user authentication. Security
    ///      comes from consuming only the exact fresh checkpoint delta.
    address public immutable trustedExecutor;

    /// @notice Used only to confirm a pool is one this factory deployed.
    PrecisionPoolFactory public immutable factory;

    error Bad();
    error NoPool();
    error Reentrancy();
    error NotExecutor();
    error BadCheckpoint();
    error IntentMismatch();

    event Exited(address indexed pool, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);

    constructor(PrecisionPoolFactory factory_, address trustedExecutor_) {
        if (address(factory_).code.length == 0 || trustedExecutor_.code.length == 0) revert Bad();
        (factory, trustedExecutor) = (factory_, trustedExecutor_);
    }

    /// @dev Also prevents an output-recipient callback from creating or
    ///      consuming checkpoint state while an exit is still settling.
    modifier nonReentrant() {
        uint256 active;
        uint256 slot = REENTRANCY_SLOT;
        assembly ("memory-safe") {
            active := tload(slot)
            tstore(slot, 1)
        }
        if (active != 0) revert Reentrancy();
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    /// @notice Snapshot this contract's share balance before the executor funds it.
    /// @dev The transient checkpoint is single-use and keyed by pool. There is
    ///      only one permitted immediate caller for this deployment.
    ///
    ///      `intent` is `keccak256` of the exact `exit` calldata this checkpoint
    ///      is for, and `exit` will not consume a checkpoint that does not
    ///      match it. The balance snapshot alone is not enough: it says how MUCH
    ///      may be spent, not what for. The shares arrive between these two
    ///      calls, `nonReentrant` clears when each returns rather than spanning
    ///      the gap, and the executor is publicly callable - so without this a
    ///      callback firing during the funding transfer could call `exit` with
    ///      the same fresh delta and a recipient of its own choosing. With it,
    ///      the only exit that can consume the funding is the one that was
    ///      already authorized.
    ///
    ///      WHY A PER-CALL GUARD IS ENOUGH HERE, when `PrecisionRoute` and the
    ///      factory both had to hold a lock ACROSS the funding gap instead. Their
    ///      input is an arbitrary caller-named ERC-20, so a callback-capable
    ///      token gets control inside the gap and something has to be holding the
    ///      door. This contract's funding asset is not arbitrary: `isPool` above
    ///      pins it to a pool this factory deployed, and those LP shares are
    ///      Solady ERC-20 with no transfer hook, so nothing executes between
    ///      `checkpoint` returning and `exit` being called. The gap is empty
    ///      rather than guarded.
    ///
    ///      That makes the `isPool` check load-bearing for REENTRANCY, not only
    ///      for pointing `removeLiquidity` at something real. Relaxing it to
    ///      admit any share-like token would reopen the interval the intent
    ///      commitment then has to carry alone.
    function checkpoint(address token, bytes32 intent) external nonReentrant {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (token == address(0) || token.code.length == 0) revert Bad();
        if (intent == bytes32(0)) revert Bad();
        if (!factory.isPool(token)) revert NoPool();

        bytes32 slot = _checkpointSlot(token);
        uint256 encoded;
        assembly ("memory-safe") {
            encoded := tload(slot)
        }
        if (encoded != 0) revert BadCheckpoint();

        uint256 snapshot = PrecisionPool(payable(token)).balanceOf(address(this));
        if (snapshot == type(uint256).max) revert BadCheckpoint();
        unchecked {
            encoded = snapshot + 1;
        }
        bytes32 intentSlot = _intentSlot(token);
        assembly ("memory-safe") {
            tstore(slot, encoded)
            tstore(intentSlot, intent)
        }
    }

    /// @notice Burn prefunded shares and deliver both sides to `to`.
    /// @dev The LP token IS the pool, so one address identifies both the
    ///      market and the asset being redeemed.
    function exit(address pool, uint256 shares, uint256 min0, uint256 min1, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (!factory.isPool(pool)) revert NoPool();
        if (to == address(0) || to == address(this) || to == pool) revert Bad();
        if (shares == 0) revert Bad();

        _consumeCheckpoint(pool, shares);

        // Burns from this contract and pays `to` directly, so nothing is left
        // here for a later caller to sweep.
        (amount0, amount1) = PrecisionPool(payable(pool)).removeLiquidity(shares, min0, min1, to);
        emit Exited(pool, to, shares, amount0, amount1);
    }

    /// @dev Cleared before the pool receives control, so a reentrant call
    ///      cannot spend the same route funding twice. The committed intent is
    ///      this call's own calldata, so the checkpoint can only be spent by
    ///      the exit it was taken for.
    function _consumeCheckpoint(address token, uint256 amount) internal {
        bytes32 slot = _checkpointSlot(token);
        bytes32 intentSlot = _intentSlot(token);
        uint256 encoded;
        bytes32 intent;
        assembly ("memory-safe") {
            encoded := tload(slot)
            intent := tload(intentSlot)
            tstore(slot, 0)
            tstore(intentSlot, 0)
        }
        if (encoded == 0) revert BadCheckpoint();
        if (intent != keccak256(msg.data)) revert IntentMismatch();

        uint256 base;
        unchecked {
            base = encoded - 1;
        }
        uint256 current = PrecisionPool(payable(token)).balanceOf(address(this));
        if (current < base || current - base != amount) revert BadCheckpoint();
    }

    /// @dev The high-bit namespace cannot collide for distinct 160-bit token
    ///      addresses and is disjoint from the reentrancy slot.
    function _checkpointSlot(address token) internal pure returns (bytes32) {
        return bytes32(CHECKPOINT_NAMESPACE | uint256(uint160(token)));
    }

    function _intentSlot(address token) internal pure returns (bytes32) {
        return bytes32(INTENT_NAMESPACE | uint256(uint160(token)));
    }
}
