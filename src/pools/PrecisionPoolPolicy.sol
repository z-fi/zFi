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
///      explicit approval, while `Blocked` always denies routing.
///
///      THIS IS AN ORACLE, NOT A CONTROL, AND NOTHING ON-CHAIN CONSULTS IT.
///      Neither `PrecisionPoolFactory` nor `PrecisionRoute` reads `isRoutable`;
///      pools and generic router calls stay permissionless whatever this
///      contract says. That is deliberate and is the reason it is not wired in:
///      the route is an immutable contract anyone can call, and giving an owner
///      the power to refuse a hop would put a kill switch on the one path that
///      currently has none - a strictly worse trade than the curation it buys.
///      What this serves is the layer that can legitimately decline to route:
///      frontends, aggregators, and anyone assembling a `pools` array off-chain.
///      Read it there. Do not read a routable answer as a safety claim; it is
///      one owner's opinion about one factory's pools.
///
///      `Approved` overrides the hook default and does NOT re-evaluate. A hooked
///      pool approved while its surcharge is benign stays approved if the hook
///      later schedules an increase to the cap - the owner has to `Blocked` it
///      back. Any hooked pool can charge `MAX_TOTAL_FEE - fee` at any block, so
///      an approval is a statement about the hook's operator, not about a rate.
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
        // Probe the registry so a wrong-interface address fails at deploy time
        // rather than making every later `isRoutable` revert.
        try factory_.isPool(address(0)) returns (bool listed) {
            if (listed) revert InvalidFactory();
        } catch {
            revert InvalidFactory();
        }
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

    /// @notice Routability for a batch of pools, in the given order.
    /// @dev Single read for routers and interfaces filtering a candidate set.
    function isRoutableBatch(address[] calldata pools) external view returns (bool[] memory out) {
        out = new bool[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            out[i] = isRoutable(pools[i]);
        }
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
