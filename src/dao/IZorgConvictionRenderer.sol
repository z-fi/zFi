// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Interface for a replaceable, onchain zOrg dashboard provider.
interface IZorgConvictionRenderer {
    function html(address conviction, address tokenList) external view returns (string memory);
}
