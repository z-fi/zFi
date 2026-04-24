// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title OwnedTarget
/// @notice Minimal ERC-173 owner stub. Pair with HTMLRegistry as a target
///         whose owner() returns your EOA, so the EOA can publish HTML for it.
///         Transfer to address(0) to renounce.
contract OwnedTarget {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
