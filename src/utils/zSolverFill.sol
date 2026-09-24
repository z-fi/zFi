// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";

/// @title zSolverFill
/// @notice Executor for off-chain solver routes, run as the `executor` of zRouter's `snwap`.
/// @dev zRouter pulls the payer's input (allowance or Permit2) into this contract, calls
///      `fill` through its SafeExecutor, and reverts unless `recipient` gained at least
///      `amountOutMin` of `tokenOut`. This contract adds what an aggregator route needs:
///      an exact, single-use approval for the solver's spender, and forwarding of the
///      output this route produced. No one approves this contract and it holds nothing
///      between calls, so the solver-supplied `target`, `spender` and `data` reach no
///      user funds. Solver calldata must name this contract as taker and receiver.
contract zSolverFill {
    using SafeTransferLib for address;

    address internal constant ETH = address(0);

    /// @dev Transient reentrancy lock, `keccak256("zSolverFill.lock")`.
    bytes32 internal constant LOCK = 0x59895352ebcc107737439479a84629478b2b9e50df57410ef238a409a55ba965;

    error BadTarget();
    error SameToken();
    error NoOutput();
    error Reentrancy();

    /// @notice A route ran. `spent` is the input consumed; `amountOut` is what was
    ///         forwarded to `to`. Compare against the lane's quote to curate lanes.
    event Filled(
        address indexed target,
        address indexed tokenIn,
        address indexed tokenOut,
        address to,
        uint256 spent,
        uint256 amountOut
    );

    /// @notice Run a solver route with this contract's `tokenIn` balance (or `msg.value`).
    /// @param target   The router the solver named. Untrusted.
    /// @param spender  The address that pulls `tokenIn`. Ignored for ETH input.
    /// @param tokenIn  Input token, `address(0)` for ETH.
    /// @param tokenOut Output token, `address(0)` for ETH.
    /// @param to       Receives the output.
    /// @param refundTo Receives unspent input.
    /// @param data     The solver's calldata.
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
                mstore(0x00, 0xab143c06) // `Reentrancy()`.
                revert(0x1c, 0x04)
            }
            tstore(LOCK, 1)
        }
        if (tokenIn == tokenOut) revert SameToken();
        if (
            target == address(this) || target == tokenIn || target == tokenOut || spender == address(this)
                || spender == tokenIn || spender == tokenOut || to == address(this) || refundTo == address(this)
        ) revert BadTarget();

        bool ethIn = tokenIn == ETH;
        uint256 amountIn = ethIn ? msg.value : tokenIn.balanceOf(address(this));
        uint256 outBefore = tokenOut == ETH ? address(this).balance - msg.value : tokenOut.balanceOf(address(this));

        if (!ethIn) tokenIn.safeApproveWithRetry(spender, amountIn);

        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, data.offset, data.length)
            if iszero(call(gas(), target, callvalue(), p, data.length, codesize(), 0x00)) {
                // Bubble the route's revert, capped against returndata bombs.
                let n := returndatasize()
                if gt(n, 0x100) { n := 0x100 }
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

        if (tokenOut == ETH) {
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

    /// @dev Routers refund ETH here mid-route.
    receive() external payable {}
}
