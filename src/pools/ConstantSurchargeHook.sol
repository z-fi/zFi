// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";

interface IPrecisionPoolRegistry {
    function isPool(address pool) external view returns (bool);
}

/// @title ConstantSurchargeHook
/// @notice Shared per-pool surcharge hook for PrecisionPool.
/// @dev One hook can serve every pool from its immutable factory because
///      `feeFor` is keyed by the calling pool. Each pool's `feeRecipient`
///      controls its surcharge and may redirect collection when its own address
///      cannot receive an accrued asset. Decreases are immediate. Increases are
///      announced and then bounded on BOTH sides: they cannot apply before the
///      notice period, so takers and routers can observe them, and they cannot
///      apply after `INCREASE_WINDOW` past it, so an announcement cannot be
///      banked and exercised much later against a trade in flight.
contract ConstantSurchargeHook {
    /// @dev Maximum surcharge in pips (10%).
    uint256 public constant MAX_SURCHARGE = 100_000;

    /// @notice Minimum notice before a surcharge increase can become active.
    uint256 public constant INCREASE_DELAY = 1 days;

    /// @notice How long a matured increase stays applicable before it lapses.
    ///
    /// @dev The delay alone bounds only how SOON an increase can activate, not
    ///      when it actually does. `applySurchargeIncrease` is permissionless
    ///      and, without an upper bound, a matured increase never expires - so a
    ///      creator could schedule one to the cap, let it ripen, and sit on it
    ///      indefinitely as an option to be exercised at a moment of their
    ///      choosing, including in the same block as somebody else's swap. The
    ///      notice period would still have been served, and the header's promise
    ///      that takers and routers can observe an increase before it becomes
    ///      active would still be technically true, while being useless to
    ///      anyone reading `surchargeOf` rather than `pendingSurchargeOf`.
    ///
    ///      A window closes that. An increase must be applied while it is fresh
    ///      or be rescheduled - which restarts the notice - so the rate a pool
    ///      can charge is never more than this far ahead of what an observer saw
    ///      announced. Takers are not defenceless without it, since `minOut`
    ///      turns a surprise surcharge into a failed trade rather than a loss;
    ///      this makes the surprise itself short-lived.
    uint256 public constant INCREASE_WINDOW = 7 days;

    struct PendingSurcharge {
        uint256 pips;
        uint256 validAfter;
    }

    /// @notice Factory whose pools this hook accepts.
    IPrecisionPoolRegistry public immutable factory;

    /// @notice Surcharge in pips, per pool. Zero means untaxed.
    mapping(address pool => uint256 pips) public surchargeOf;

    /// @notice Scheduled surcharge increase and the time it becomes applicable.
    /// @dev Applicable from `validAfter` until `validAfter + INCREASE_WINDOW`.
    ///      A zero `validAfter` means none is scheduled; a stored entry past its
    ///      window is inert and must be scheduled again, which restarts notice.
    mapping(address pool => PendingSurcharge pending) public pendingSurchargeOf;

    error Bad();
    error NotCreator();
    error InvalidPool();
    error IncreaseExpired();
    error IncreaseNotReady();
    error NoPendingIncrease();
    error IncreaseRequiresDelay();

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

    /// @notice Activate a scheduled surcharge increase during its window.
    /// @dev Permissionless, so activation does not depend on the creator. It is
    ///      bounded on BOTH sides: not before the notice period, and not after
    ///      `INCREASE_WINDOW` past it. A lapsed increase must be scheduled
    ///      again, which serves the notice again.
    function applySurchargeIncrease(address pool) external {
        PendingSurcharge memory pending = pendingSurchargeOf[pool];
        if (pending.validAfter == 0) revert NoPendingIncrease();
        if (block.timestamp < pending.validAfter) revert IncreaseNotReady();
        unchecked {
            // `validAfter` is a timestamp plus a constant, so this cannot wrap.
            if (block.timestamp >= pending.validAfter + INCREASE_WINDOW) revert IncreaseExpired();
        }
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
