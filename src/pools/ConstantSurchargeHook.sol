// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";

/// @title ConstantSurchargeHook
/// @notice A flat swap tax for PrecisionPool, shared by every market that
///         wants one. This is the launchpad shape: the creator earns on volume
///         without touching what LPs are owed.
///
/// @dev    WHY A TAX AND NOT A SPLIT. A pool's `creatorFeeBps` divides the fee
///         the pool already charges, so it costs the taker nothing and the LP
///         everything. A surcharge does the reverse - the taker pays more, the
///         LP is untouched, and the pool's quote gets worse. Neither is
///         strictly better: a launch token whose only venue is its own pool
///         can tax freely because there is nothing to route around, while an
///         established pair that taxes simply loses the route. Both mechanisms
///         exist so the choice can be made per market rather than by whoever
///         wrote the contract.
///
///         ONE DEPLOYMENT SERVES EVERY POOL. The pool is the `msg.sender` of
///         the `feeFor` staticcall, so rates are keyed by pool and no market
///         needs its own hook contract.
///
///         AND NOBODY CAN STEAL A MARKET'S RATE. The obvious version of a
///         shared hook lets anyone register any pool, which is a race the
///         creator loses to whoever is watching the mempool - and pool
///         addresses are deterministic, so they are visible before deployment.
///         Here the authority is the pool's own immutable `feeRecipient`,
///         fixed when the market was created. There is no window in which
///         somebody else can claim it, because there is no claiming: an
///         unconfigured pool charges nothing, and only the address named at
///         deployment can change that.
///
///         COLLECTION IS PERMISSIONLESS. `collect` pays the pool's
///         `feeRecipient` and nowhere else, so letting anyone call it is safe
///         and means a creator's earnings can be swept by a keeper.
contract ConstantSurchargeHook {
    /// @dev Well past anything a market would bear, and the pool clamps to its
    ///      own ceiling regardless. This only catches a units mistake.
    uint256 constant MAX_SURCHARGE = 100_000; // 10%

    /// @notice Surcharge in pips, per pool. Zero means untaxed.
    mapping(address pool => uint256 pips) public surchargeOf;

    error NotCreator();
    error Bad();

    event SurchargeSet(address indexed pool, uint256 pips);

    /// @notice Set this market's tax. Only the pool's `feeRecipient` may.
    function setSurcharge(address pool, uint256 pips) external {
        if (msg.sender != PrecisionPool(payable(pool)).feeRecipient()) revert NotCreator();
        if (pips > MAX_SURCHARGE) revert Bad();
        surchargeOf[pool] = pips;
        emit SurchargeSet(pool, pips);
    }

    /// @notice The pool asks what to add; `msg.sender` identifies the market.
    /// @dev View, as the interface requires, so a lens quoting this pool gets
    ///      the same answer the swap will use.
    function feeFor(address, address, uint256) external view returns (uint256) {
        return surchargeOf[msg.sender];
    }

    /// @dev Nothing to observe: the tax is already accounted for by the pool.
    function afterSwap(address, address, uint256, uint256, address) external {}

    /// @notice Sweep a pool's accrued tax to its creator. Callable by anyone.
    function collect(address pool) external returns (uint256 a0, uint256 a1) {
        PrecisionPool p = PrecisionPool(payable(pool));
        return p.collectHookFees(p.feeRecipient());
    }
}
