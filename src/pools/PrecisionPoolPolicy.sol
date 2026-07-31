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
/// @notice Routing policy for pools created by a PrecisionPoolFactory.
/// @dev Unhooked factory pools are routable by default. Hooked pools require
///      explicit approval, while `Blocked` always denies routing. This is a
///      policy oracle only; pools and generic router calls remain permissionless.
contract PrecisionPoolPolicy is Ownable {
    /// @notice Policy applied to a pool.
    enum Policy {
        Default,
        Approved,
        Blocked
    }

    /// @notice Factory whose pools this policy can approve or block.
    IPrecisionPoolFactoryRegistry public immutable factory;

    /// @notice Explicit policy for a factory pool.
    /// @dev `Default` allows unhooked pools and denies hooked pools.
    mapping(address pool => Policy) public policyOf;

    error InvalidOwner();
    error UnhookedPool();
    error InvalidFactory();
    error NotFactoryPool();
    error PoolNotRoutable();
    error RenounceDisabled();

    event PoolPolicySet(address indexed pool, Policy oldPolicy, Policy newPolicy);

    constructor(IPrecisionPoolFactoryRegistry factory_, address initialOwner) {
        if (address(factory_).code.length == 0) revert InvalidFactory();
        if (initialOwner == address(0)) revert InvalidOwner();
        factory = factory_;
        _initializeOwner(initialOwner);
    }

    /// @notice Whether the pool is routable.
    function isRoutable(address pool) public view returns (bool) {
        Policy policy = policyOf[pool];
        if (policy == Policy.Blocked) return false;
        if (!factory.isPool(pool)) return false;
        if (policy == Policy.Approved) return true;
        return IPrecisionPoolPolicyView(pool).hook() == address(0);
    }

    /// @notice Revert unless `pool` is currently routable.
    /// @dev Useful as an atomic preflight in a route.
    function requireRoutable(address pool) external view {
        if (!isRoutable(pool)) revert PoolNotRoutable();
    }

    /// @notice Set the policy for one factory pool.
    /// @dev `Approved` is valid only for hooked pools. A blocked hooked pool
    ///      must be explicitly approved again before it becomes routable.
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

    /// @dev Prevents explicit zero-owner renunciation. Prefer ownership
    ///      handover for later governance transfers.
    function renounceOwnership() public payable override onlyOwner {
        revert RenounceDisabled();
    }
}
