// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Ownable} from "../../lib/solady/src/auth/Ownable.sol";

interface IPrecisionPoolFactoryRegistry {
    function isPool(address pool) external view returns (bool);
}

interface IPrecisionPoolPolicyView {
    function hook() external view returns (address);
}

/// @title PrecisionPoolPolicy
/// @notice Onchain routing policy for frontends and quoters using one
///         PrecisionPoolFactory.
///
/// @dev    Factory provenance and zSwap endorsement are deliberately separate:
///         the permissionless factory records every canonical pool, while this
///         contract decides which of those pools zSwap should route through.
///
///         An unhooked factory pool is routable by default. A hooked pool is
///         denied until the owner approves that exact pool address. Blocking
///         overrides both rules and deliberately erases prior approval, so an
///         incident requires a fresh review before a hooked pool returns.
///
///         This contract is a policy oracle, not custody or hard enforcement.
///         Direct pool and generic zRouter calls remain permissionless. A
///         client must check `isRoutable` before quoting and again immediately
///         before submission, or include `requireRoutable` in an atomic route.
///
///         The owner should be a Safe or timelock. Hook addresses are immutable
///         on pools, but a proxy hook can still change behavior; approval of
///         such a pool remains an active governance trust decision.
contract PrecisionPoolPolicy is Ownable {
    enum Policy {
        Default,
        Approved,
        Blocked
    }

    IPrecisionPoolFactoryRegistry public immutable factory;

    /// @notice Explicit policy for a factory pool.
    /// @dev `Default` allows unhooked pools and denies hooked pools.
    mapping(address pool => Policy) public policyOf;

    error InvalidFactory();
    error InvalidOwner();
    error NotFactoryPool();
    error UnhookedPool();
    error PoolNotRoutable();
    error RenounceDisabled();

    event PoolPolicySet(address indexed pool, Policy oldPolicy, Policy newPolicy);

    constructor(IPrecisionPoolFactoryRegistry factory_, address initialOwner) {
        if (address(factory_).code.length == 0) revert InvalidFactory();
        if (initialOwner == address(0)) revert InvalidOwner();
        factory = factory_;
        _initializeOwner(initialOwner);
    }

    /// @notice Whether zSwap should quote and route through `pool`.
    function isRoutable(address pool) public view returns (bool) {
        if (!factory.isPool(pool)) return false;

        Policy policy = policyOf[pool];
        if (policy == Policy.Blocked) return false;
        if (IPrecisionPoolPolicyView(pool).hook() == address(0)) return true;
        return policy == Policy.Approved;
    }

    /// @notice Revert unless `pool` is currently routable.
    /// @dev Useful when a route can include an atomic policy preflight.
    function requireRoutable(address pool) external view {
        if (!isRoutable(pool)) revert PoolNotRoutable();
    }

    /// @notice Set the policy for one canonical factory pool.
    /// @dev `Approved` is meaningful only for hooked pools. Setting `Blocked`
    ///      over an approval discards it; restoring a hooked pool therefore
    ///      requires setting `Approved`, not merely `Default`.
    function setPoolPolicy(address pool, Policy newPolicy) external onlyOwner {
        if (!factory.isPool(pool)) revert NotFactoryPool();
        if (newPolicy == Policy.Approved && IPrecisionPoolPolicyView(pool).hook() == address(0)) {
            revert UnhookedPool();
        }

        Policy oldPolicy = policyOf[pool];
        if (oldPolicy == newPolicy) return;
        policyOf[pool] = newPolicy;
        emit PoolPolicySet(pool, oldPolicy, newPolicy);
    }

    /// @dev A routing policy must retain an accountable owner so compromised
    ///      or mutable hooked pools can always be blocked.
    function renounceOwnership() public payable override onlyOwner {
        revert RenounceDisabled();
    }
}
