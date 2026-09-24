// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";

/// @title zSolverFill
/// @notice Executes an off-chain solver route as the executor of zRouter `snwap`.
/// @dev zRouter funds this contract and enforces the recipient's minimum output. This
///      contract approves `spender` for exactly its input, calls `target`, then forwards
///      the output the call produced and refunds the rest. It holds no approvals and no
///      balance between calls. Solver calldata must name this contract as taker.
contract zSolverFill {
    using SafeTransferLib for address;

    /// @dev keccak256("zSolverFill.lock")
    bytes32 internal constant LOCK = 0x59895352ebcc107737439479a84629478b2b9e50df57410ef238a409a55ba965;

    error BadTarget();
    error SameToken();
    error NoOutput();
    error Reentrancy();

    event Filled(
        address indexed target,
        address indexed tokenIn,
        address indexed tokenOut,
        address to,
        uint256 spent,
        uint256 amountOut
    );

    /// @param target   Solver router. Untrusted.
    /// @param spender  Address that pulls `tokenIn`. Unused for ETH.
    /// @param tokenIn  Input token, `address(0)` for ETH. The whole balance held here is spent.
    /// @param tokenOut Output token, `address(0)` for ETH.
    /// @param to       Output recipient.
    /// @param refundTo Recipient of unspent input.
    /// @param data     Solver calldata.
    /// @return out     Output forwarded to `to`.
    function fill(
        address target,
        address spender,
        address tokenIn,
        address tokenOut,
        address to,
        address refundTo,
        bytes calldata data
    ) public payable returns (uint256 out) {
        assembly ("memory-safe") {
            if tload(LOCK) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(LOCK, 1)
        }
        if (tokenIn == tokenOut) revert SameToken();
        if (
            target == address(this) || target == tokenIn || target == tokenOut || spender == address(this)
                || spender == tokenIn || spender == tokenOut || to == address(this) || to == address(0)
                || refundTo == address(this)
        ) revert BadTarget();

        bool ethIn = tokenIn == address(0);
        uint256 amountIn = ethIn ? msg.value : tokenIn.balanceOf(address(this));
        uint256 outBefore =
            tokenOut == address(0) ? address(this).balance - msg.value : tokenOut.balanceOf(address(this));

        if (!ethIn) tokenIn.safeApproveWithRetry(spender, amountIn);

        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, data.offset, data.length)
            if iszero(call(gas(), target, callvalue(), p, data.length, codesize(), 0x00)) {
                let n := returndatasize()
                if gt(n, 0x100) { n := 0x100 } // cap bubbled revert data
                returndatacopy(p, 0x00, n)
                revert(p, n)
            }
        }

        uint256 left;
        if (!ethIn) {
            tokenIn.safeApproveWithRetry(spender, 0);
            left = tokenIn.balanceOf(address(this));
            if (left > amountIn) left = amountIn;
            if (left != 0) tokenIn.safeTransfer(refundTo, left);
        }

        if (tokenOut == address(0)) {
            out = address(this).balance - outBefore;
            if (out == 0) revert NoOutput();
            to.safeTransferETH(out);
        } else {
            out = tokenOut.balanceOf(address(this)) - outBefore;
            if (out == 0) revert NoOutput();
            tokenOut.safeTransfer(to, out);
            uint256 eth = address(this).balance;
            if (eth != 0) {
                if (ethIn) left = eth < amountIn ? eth : amountIn;
                refundTo.forceSafeTransferETH(eth);
            }
        }

        emit Filled(target, tokenIn, tokenOut, to, amountIn - left, out);

        assembly ("memory-safe") {
            tstore(LOCK, 0)
        }
    }

    receive() external payable {}
}
