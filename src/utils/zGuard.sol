// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title zGuard
/// @notice Checks a router multicall runs as its own legs: a deadline, and an
///         end-to-end floor on what the recipient actually received.
///
/// WHY A LEG AND NOT A FORWARDER
///   The routes that most need a deadline cannot be wrapped. PrecisionRoute
///   answers only the router's SafeExecutor (`trustedExecutor`), so a
///   forwarder standing between the router and the route is refused, and one
///   that took custody to get around that would add a contract holding user
///   funds mid-swap. A leg does neither. The router reaches it the way it
///   reaches every executor - `snwap` with a zero amount, through
///   SafeExecutor - and it only reads the clock and balances, then returns or
///   reverts the whole transaction.
///
/// THE ETHER EVERY LEG IS HANDED
///   `snwap` forwards the transaction's entire `msg.value` to its executor,
///   and inside a multicall every leg sees the same `msg.value`. A guard leg
///   placed ahead of a native-ETH swap is therefore sent that ether too, from
///   the router's balance, and the swap leg after it needs the router to still
///   hold it. So every function here returns whatever it was sent to `back`,
///   which the caller sets to the router. All three routers accept plain
///   ether through `receive()`. Nothing is ever kept: this contract holds no
///   balance between calls, and a caller who names some other `back` only
///   redirects their own ether.
///
///   The same forwarding fixes WHERE a guard leg may sit in a native bundle:
///   before the swap leg, never after it. Once the swap leg has spent the
///   router's ether, a later leg is sent `msg.value` the router no longer
///   holds and the whole transaction runs out of funds. So a native bundle
///   carries `deadline` (and may `snap`) up front, and its output is bound by
///   the swap leg's own `snwap` minimum. An ERC-20 bundle has no `msg.value`
///   and may place legs anywhere, which is where `floor` runs.
///
/// THE FLOOR
///   Two-hop routes size the second leg on the first leg's minimum, so the
///   floor the user actually gets compounds to roughly out*(1-s)^2, and split
///   routes widen their bound to cover several legs. `snap` at the start and
///   `floor` at the end bound the whole bundle once, at the user's own
///   slippage, whatever path the middle takes. The snapshot lives in transient
///   storage, so it exists only inside the transaction that took it. It is
///   keyed by the caller as well as by token and account, so only calls
///   arriving through the same SafeExecutor share it, and it cannot be
///   overwritten, so nothing running later in the transaction can move the
///   baseline.
///
/// NO OWNER, NO STORAGE, NO UPGRADE. Deployed at one CREATE2 address on every
/// chain the page serves.
contract zGuard {
    error Expired();
    error BelowFloor(uint256 got, uint256 min);
    error NoSnapshot();
    error SnapshotTaken();
    error BounceFailed();
    error BadToken();

    uint256 private constant SEED = uint256(keccak256("zGuard.snap.v1"));

    /// @notice Reverts once `by` has passed. Returns any ether sent to `back`.
    function deadline(uint256 by, address back) external payable {
        if (block.timestamp > by) revert Expired();
        _bounce(back);
    }

    /// @notice Records `who`'s balance of `token` (address(0) for ether) for a
    ///         later `floor` in this transaction. Returns any ether sent to `back`.
    /// @dev Ether sent here is returned BEFORE the balance is read, so a
    ///      snapshot of `back` itself is not skewed by the bounce.
    function snap(address token, address who, address back) external payable {
        _bounce(back);
        bytes32 k = _key(token, who);
        uint256 prior;
        assembly ("memory-safe") {
            prior := tload(k)
        }
        if (prior != 0) revert SnapshotTaken();
        uint256 b = _bal(token, who);
        assembly ("memory-safe") {
            tstore(k, add(b, 1))
        }
    }

    /// @notice Reverts unless `who`'s balance of `token` rose by at least `min`
    ///         since `snap`. Consumes the snapshot. Returns any ether sent to `back`.
    function floor(address token, address who, uint256 min, address back) external payable returns (uint256 got) {
        _bounce(back);
        bytes32 k = _key(token, who);
        uint256 s;
        assembly ("memory-safe") {
            s := tload(k)
            tstore(k, 0)
        }
        if (s == 0) revert NoSnapshot();
        uint256 b = _bal(token, who);
        unchecked {
            got = b > s - 1 ? b - (s - 1) : 0;
        }
        if (got < min) revert BelowFloor(got, min);
    }

    function _bounce(address back) internal {
        if (msg.value == 0) return;
        (bool ok,) = back.call{value: msg.value}("");
        if (!ok) revert BounceFailed();
    }

    function _key(address token, address who) internal view returns (bytes32 k) {
        uint256 seed = SEED;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, seed)
            mstore(add(m, 0x20), caller())
            mstore(add(m, 0x40), token)
            mstore(add(m, 0x60), who)
            k := keccak256(m, 0x80)
        }
    }

    function _bal(address token, address who) internal view returns (uint256 b) {
        if (token == address(0)) return who.balance;
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSelector(0x70a08231, who));
        if (!ok || r.length < 32) revert BadToken();
        b = abi.decode(r, (uint256));
    }
}
