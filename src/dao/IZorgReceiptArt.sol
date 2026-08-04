// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Interface for a replaceable, onchain receipt metadata provider.
interface IZorgReceiptArt {
    function tokenURI(address governor, uint256 receiptId) external view returns (string memory);
}
