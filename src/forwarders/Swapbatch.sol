// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

/// @title Swapbatch
/// @notice Fill several Swapboard orders in one transaction paying native ETH. Takes the
///         ETH, wraps exactly what the batch owes into WETH, runs the board's existing
///         batch fill, and returns everything left over as ETH.
///
/// @dev    WHY A HELPER AND NOT `multicall`. Swapboard inherits Solady's Multicallable,
///         whose `multicall` reverts on any non-zero `msg.value`:
///
///             if (msg.value != 0) revert();   // Paradigm's "two rights might make a wrong"
///
///         That is not a missing feature to be patched around — every delegatecall in a
///         multicall observes the SAME `msg.value`, and `fillOrderWithEth` both treats
///         `msg.value` as the amount paid and wraps it out of the CONTRACT's balance.
///         Overriding `multicall` to accept value would let one `msg.value` settle N
///         orders, underwritten by any ETH resting in the board. The board's `receive()`
///         is gated to WETH so ETH cannot be donated, but `selfdestruct` bypasses
///         `receive()` and a counterfactual address can be pre-funded, so "resting ETH"
///         is reachable rather than hypothetical.
///
///         So the value accounting lives here, out of delegatecall's way, where
///         `msg.value` is counted exactly once:
///
///             total = Σ fillAmountsB;  require(msg.value >= total);  wrap(total)
///
///         See test/SwapboardMulticallValue.t.sol, which pins the guard this replaces.
///
///         HOLDS NOTHING BETWEEN CALLS. Every entry point is public, so whatever this
///         contract holds or has granted when a call returns belongs to whoever calls it
///         next. Both sweeps below are therefore unconditional, and the approval is
///         scoped to the call.
///
///         APPROVALS ARE SCOPED. `board` is a parameter — there are three Swapboard
///         deployments and this should serve all of them — so the lazy infinite approval
///         the sibling forwarders use against hardcoded aggregators would let any caller
///         plant a permanent allowance to an address they control. The approval here is
///         for exactly the batch total and is revoked before returning.
///
///         REENTRANCY. A fill hands control to maker-chosen code (tokenA, tokenB, or a
///         721 hook). Without a guard that code could re-enter and point the sweeps —
///         which pay a caller-supplied recipient — at itself, taking the unspent ETH this
///         contract is holding mid-batch.
///
///         WHICH BOARD DECIDES WHERE tokenA LANDS. The deployed board does NOT take a
///         recipient, and pays tokenA to ITS msg.sender - this contract:
///
///           deployed  0x00000000CC3915a0f5F98CBdC558Ac1a8e85B831
///                     fillOrders(uint256[],uint256,uint256[])          <- no recipient
///                     tryFillOrders(uint256[],uint256,uint256[])
///                     (no `multicall` either, so ETH batching there is
///                      impossible today without this helper)
///           current   fillOrders(uint256[],uint256,uint256[],address)  <- pays direct
///                     tryFillOrders(uint256[],uint256,uint256[],address)
///
///         So on a legacy board the `tokensOut` sweep is not a safety net, it is the
///         DELIVERY PATH, and the whole purchase sits here until it runs. Omitting a
///         bought asset from `tokensOut` against a legacy board strands it permanently:
///         nothing else in this contract can move an arbitrary token. `legacyBoard`
///         therefore requires a non-empty `tokensOut`, so the mistake reverts instead of
///         silently eating the batch.
///
///         An order whose tokenA is WETH delivers WETH, not ETH; the board's unwrap
///         variants are single-order only and batching them is out of scope here.
contract Swapbatch {
    /// @dev Canonical wrapper, fixed at deployment. A deployment trust root: a lying
    ///      wrapper could misreport `balanceOf` and defeat the leftover sweep.
    address public immutable weth;

    /// @dev Transient reentrancy flag. `uint32(bytes4(keccak256("Reentrancy()")))`.
    uint256 constant REENTRANCY_GUARD_SLOT = 0xab143c07;

    /// @dev Batch-fill selectors, verified against the deployed board's bytecode.
    bytes4 constant FILL_LEGACY = 0x0a81e15f; // fillOrders(uint256[],uint256,uint256[])
    bytes4 constant TRY_LEGACY = 0x562f64eb; // tryFillOrders(uint256[],uint256,uint256[])
    bytes4 constant FILL_MODERN = 0x86ba4707; // fillOrders(uint256[],uint256,uint256[],address)
    bytes4 constant TRY_MODERN = 0xec4b6520; // tryFillOrders(uint256[],uint256,uint256[],address)

    error Reentrancy();
    error LengthMismatch();
    error NoOrders();
    error InsufficientValue(uint256 required, uint256 sent);
    error ZeroAddress();
    error NotAContract(address token);
    error TokensOutRequired();
    error BoardCallFailed();

    constructor(address _weth) {
        if (_weth == address(0)) revert ZeroAddress();
        if (_weth.code.length == 0) revert NotAContract(_weth);
        weth = _weth;
    }

    /// @notice Fill `orderIds` on `board`, paying with the ETH attached to this call.
    /// @param  board         Swapboard holding the orders (v2 onward).
    /// @param  orderIds      Orders to fill.
    /// @param  fillAmountsB  WETH paid to each order's maker; must align with `orderIds`.
    /// @param  deadline      Passed through to the board's staleness check.
    /// @param  recipient     Receives tokenA from every leg, plus all refunds.
    ///                       address(0) means the caller.
    /// @param  skipFailures  false uses `fillOrders` (atomic: any bad order aborts the
    ///                       batch). true uses `tryFillOrders`, which skips orders that
    ///                       are inactive, missing, expired, or reserved for someone
    ///                       else — the ETH for a skipped leg comes back as a refund.
    /// @param  legacyBoard   true for a board without a `recipient` argument, which pays
    ///                       tokenA to this contract. `tokensOut` then MUST list every
    ///                       bought asset, because that sweep is the only way out.
    /// @param  tokensOut     Assets to sweep to `recipient` after the batch. Required
    ///                       when `legacyBoard`; a belt-and-braces no-op otherwise, and
    ///                       may be empty against a board that pays direct.
    /// @return filled        Per-order outcome; all true on the atomic path.
    function fillOrdersWithEth(
        address board,
        uint256[] calldata orderIds,
        uint256[] calldata fillAmountsB,
        address[] calldata tokensOut,
        uint256 deadline,
        address recipient,
        bool skipFailures,
        bool legacyBoard
    ) public payable returns (bool[] memory filled) {
        assembly ("memory-safe") {
            if tload(REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_GUARD_SLOT, 1)
        }

        uint256 n = orderIds.length;
        if (n == 0) revert NoOrders();
        if (n != fillAmountsB.length) revert LengthMismatch();
        // On a legacy board the sweep IS the delivery path, so an empty list would mean
        // buying assets this contract cannot subsequently move.
        if (legacyBoard && tokensOut.length == 0) revert TokensOutRequired();

        // Never address(0): the board maps a zero recipient to ITS msg.sender, which is
        // this contract, and the bought tokenA would land here for the next caller.
        address to = recipient == address(0) ? msg.sender : recipient;

        // msg.value is counted exactly once, against the sum of the legs. This is the
        // whole reason this contract exists.
        uint256 total;
        for (uint256 i; i < n; ++i) {
            total += fillAmountsB[i];
        }
        if (msg.value < total) revert InsufficientValue(total, msg.value);

        // Wrap only what the batch owes, so any excess stays as ETH to refund.
        IWETH(weth).deposit{value: total}();
        safeApprove(weth, board, total);

        // The legacy encoding simply omits the trailing recipient word; both generations
        // otherwise take the same arguments in the same order.
        bytes memory callData = legacyBoard
            ? abi.encodeWithSelector(
                skipFailures ? TRY_LEGACY : FILL_LEGACY, orderIds, deadline, fillAmountsB
            )
            : abi.encodeWithSelector(
                skipFailures ? TRY_MODERN : FILL_MODERN, orderIds, deadline, fillAmountsB, to
            );

        (bool ok, bytes memory ret) = board.call(callData);
        if (!ok) {
            // Bubble the board's own revert; a bare failure here would hide OrderExpired,
            // NotCounterparty and friends behind a useless generic error.
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        if (skipFailures) {
            filled = abi.decode(ret, (bool[]));
        } else {
            filled = new bool[](n);
            for (uint256 i; i < n; ++i) {
                filled[i] = true; // atomic path: reaching here means every leg settled
            }
        }

        // Nothing may outlive the call, and `tryFillOrders` leaves the allowance for any
        // skipped leg unspent.
        safeApprove(weth, board, 0);

        // Deliver the bought assets. On a legacy board this is the whole purchase; on a
        // modern one the board already paid `to` and this moves nothing. Sweeping the
        // full balance means stray tokens go to this caller too — this is not a vault.
        for (uint256 i; i < tokensOut.length; ++i) {
            address t = tokensOut[i];
            if (t == weth) continue; // handled by the unwrap below, never sent as WETH
            uint256 bal = balanceOf(t, address(this));
            if (bal != 0) safeTransfer(t, to, bal);
        }

        // Skipped legs leave wrapped ETH here. Unwrap it rather than handing back WETH:
        // the caller paid in ETH and a silent asset change would strand it for anyone
        // integrating this as a router leg. Sweeps the whole balance, so stray WETH is
        // collected by this caller too — this contract is not a vault.
        uint256 left = balanceOf(weth, address(this));
        if (left != 0) IWETH(weth).withdraw(left);

        // Excess value plus anything just unwrapped, in one transfer.
        assembly ("memory-safe") {
            if selfbalance() {
                if iszero(call(gas(), to, selfbalance(), codesize(), 0x00, codesize(), 0x00)) {
                    mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
                    revert(0x1c, 0x04)
                }
            }
            tstore(REENTRANCY_GUARD_SLOT, 0)
        }
    }

    /// @notice ETH required for a set of legs — the sum the batch will wrap. Anything
    ///         sent above this comes back, so a caller may safely overpay.
    function totalRequired(uint256[] calldata fillAmountsB) public pure returns (uint256 total) {
        for (uint256 i; i < fillAmountsB.length; ++i) {
            total += fillAmountsB[i];
        }
    }

    /// @dev Only WETH may push ETH here, and only during `withdraw`. Refusing everything
    ///      else keeps the sweep's "whatever is here belongs to this caller" rule from
    ///      being a way to donate into someone else's batch.
    receive() external payable {
        if (msg.sender != weth) revert NotAContract(msg.sender);
    }
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

// Solady safe transfer helpers:

error TransferFailed();

function safeTransfer(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0xa9059cbb000000000000000000000000)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x90b8ec18)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x34, 0)
    }
}

error ApproveFailed();

function safeApprove(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0x095ea7b3000000000000000000000000)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x3e3f8f73)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x34, 0)
    }
}

function balanceOf(address token, address account) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, account)
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(mload(0x20), and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20)))
    }
}
