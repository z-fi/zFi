// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";

interface IPrecisionPoolRegistry {
    function isPool(address pool) external view returns (bool);
}

/// @title ConstantSurchargeHook
/// @notice Shared per-pool surcharge hook for PrecisionPool.
/// @dev One hook can serve every pool from its immutable factory because
///      `feeFor` is keyed by the calling pool. Each pool's `feeRecipient`
///      controls its surcharge and may redirect collection when its own address
///      cannot receive an accrued asset. Increases are delayed so takers and
///      routers can observe them before they become active; decreases are
///      immediate.
contract ConstantSurchargeHook {
    /// @dev Maximum surcharge in pips (10%).
    uint256 public constant MAX_SURCHARGE = 100_000;

    /// @notice Minimum notice before a surcharge increase can become active.
    uint256 public constant INCREASE_DELAY = 1 days;

    struct PendingSurcharge {
        uint256 pips;
        uint256 validAfter;
    }

    /// @notice Factory whose pools this hook accepts.
    IPrecisionPoolRegistry public immutable factory;

    /// @notice Surcharge in pips, per pool. Zero means untaxed.
    mapping(address pool => uint256 pips) public surchargeOf;

    /// @notice Scheduled surcharge increase and its earliest activation time.
    mapping(address pool => PendingSurcharge pending) public pendingSurchargeOf;

    error Bad();
    error InvalidPool();
    error NotCreator();
    error IncreaseRequiresDelay();
    error NoPendingIncrease();
    error IncreaseNotReady();

    event SurchargeSet(address indexed pool, uint256 pips);
    event SurchargeIncreaseScheduled(address indexed pool, uint256 pips, uint256 validAfter);
    event SurchargeIncreaseCancelled(address indexed pool, uint256 pips);

    constructor(address factory_) {
        if (factory_.code.length == 0) revert Bad();
        factory = IPrecisionPoolRegistry(factory_);
    }

    /// @notice Reduce or disable a pool's surcharge immediately.
    /// @dev Increases must use `scheduleSurchargeIncrease` and the delay below.
    /// @param pool Pool whose surcharge is being set.
    /// @param pips Surcharge in pips; zero disables it.
    function setSurcharge(address pool, uint256 pips) external {
        if (pips > MAX_SURCHARGE) revert Bad();
        _requireCreator(pool);
        if (pips > surchargeOf[pool]) revert IncreaseRequiresDelay();
        _cancelIncrease(pool);
        surchargeOf[pool] = pips;
        emit SurchargeSet(pool, pips);
    }

    /// @notice Schedule a surcharge increase with advance notice.
    /// @dev Scheduling a replacement restarts the delay. Anyone may activate a
    ///      mature increase, so its application does not depend on the creator.
    function scheduleSurchargeIncrease(address pool, uint256 pips) external {
        if (pips > MAX_SURCHARGE) revert Bad();
        _requireCreator(pool);
        if (pips <= surchargeOf[pool]) revert Bad();
        uint256 validAfter = block.timestamp + INCREASE_DELAY;
        pendingSurchargeOf[pool] = PendingSurcharge({pips: pips, validAfter: validAfter});
        emit SurchargeIncreaseScheduled(pool, pips, validAfter);
    }

    /// @notice Activate a scheduled surcharge increase after its notice period.
    function applySurchargeIncrease(address pool) external {
        PendingSurcharge memory pending = pendingSurchargeOf[pool];
        if (pending.validAfter == 0) revert NoPendingIncrease();
        if (block.timestamp < pending.validAfter) revert IncreaseNotReady();
        delete pendingSurchargeOf[pool];
        surchargeOf[pool] = pending.pips;
        emit SurchargeSet(pool, pending.pips);
    }

    /// @notice Cancel a scheduled increase without changing the active rate.
    function cancelSurchargeIncrease(address pool) external {
        _requireCreator(pool);
        if (pendingSurchargeOf[pool].validAfter == 0) revert NoPendingIncrease();
        _cancelIncrease(pool);
    }

    /// @notice Return the surcharge configured for the calling pool.
    /// @dev The pool is `msg.sender`; the other arguments are unused.
    function feeFor(address, address, uint256) external view returns (uint256) {
        return surchargeOf[msg.sender];
    }

    /// @dev No post-swap state is needed; the pool already accounts for the fee.
    function afterSwap(address, address, uint256, uint256, address) external {}

    /// @notice Sweep a pool's accrued surcharge to its fee recipient.
    /// @dev Callable by anyone.
    function collect(address pool) external returns (uint256 a0, uint256 a1) {
        PrecisionPool p = _pool(pool);
        return p.collectHookFees(p.feeRecipient());
    }

    /// @notice Sweep accrued surcharge to an alternate recipient.
    /// @dev Only the pool's fee recipient may redirect payment. This recovery
    ///      path supports contract recipients that cannot receive native ETH.
    function collectTo(address pool, address to) external returns (uint256 a0, uint256 a1) {
        PrecisionPool p = _pool(pool);
        if (msg.sender != p.feeRecipient()) revert NotCreator();
        return p.collectHookFees(to);
    }

    function _requireCreator(address pool) internal view {
        PrecisionPool p = _pool(pool);
        if (msg.sender != p.feeRecipient()) revert NotCreator();
    }

    function _pool(address pool) internal view returns (PrecisionPool p) {
        if (!factory.isPool(pool)) revert InvalidPool();
        p = PrecisionPool(payable(pool));
        if (p.hook() != address(this)) revert InvalidPool();
    }

    function _cancelIncrease(address pool) internal {
        uint256 pending = pendingSurchargeOf[pool].pips;
        if (pending == 0) return;
        delete pendingSurchargeOf[pool];
        emit SurchargeIncreaseCancelled(pool, pending);
    }
}
