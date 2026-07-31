// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";
import {PrecisionPoolFactory} from "./PrecisionPoolFactory.sol";

/// @title PrecisionZap
/// @notice Redeems PrecisionPool LP shares inside a zRouter route, so exiting
///         a band and swapping the proceeds settle in one transaction.
///
/// @dev    WHY REDEEM RATHER THAN TRADE. An LP share is not an asset in need
///         of price discovery; it is a claim whose redemption value is exactly
///         `shares * reserve / supply` on each side. Listing it would invite a
///         market that trades at a discount to something already known, and
///         would fragment liquidity to no purpose. Routing a position out is
///         therefore an unwrap, not a swap.
///
///         WHY IT NEEDS TO EXIST AT ALL. `removeLiquidity` burns from
///         msg.sender, so a redemption inside a route has to be performed by
///         whoever the router funded. zRouter reaches arbitrary targets only
///         through snwap's executor, so a redemption leg needs an executor -
///         this one.
///
///         IT UNWRAPS, IT DOES NOT ROUTE. Both sides are delivered straight to
///         the recipient and nothing is swapped here. Whichever leg the user
///         did not want becomes an ordinary swap in the next entry of the same
///         multicall, priced by zQuoter across every venue it already knows.
///         The consequence worth stating plainly: zQuoter never has to learn
///         what an LP share is. "Sell my band position for USDC" decomposes
///         into a redemption it does not model and a swap it already handles.
///         `snwapMulti` measures several outputs at the recipient, so the
///         redemption is a single leg producing two tokens.
///
///         ENTRY IS NOT HERE BECAUSE IT IS ALREADY ELSEWHERE. Adding to a band
///         with both assets is `PrecisionPoolFactory.seed`, which pulls from
///         the caller directly. A single-asset entry is a swap followed by
///         that call - again routing, and again the router's job.
///
///         FUNDING IS CHECKPOINTED. snwap sends the shares here and then calls
///         this contract, so the balance is already present when execution
///         begins. Treating a bare balance as the route's own would let anyone
///         claim shares that arrived by another path, which is the same hazard
///         the factory's executor and the Swapbol forwarders answer the same
///         way: a transient, single-use checkpoint taken immediately before
///         funding, consumed here, and required to match exactly.
contract PrecisionZap {
    uint256 constant CHECKPOINT_SEED = 0x9d2f1c33;

    /// @notice The only caller permitted to drive a prefunded redemption.
    /// @dev zRouter dispatches snwap through its SafeExecutor, so this is that
    ///      executor rather than the router itself.
    address public immutable trustedExecutor;

    /// @notice Used only to confirm a pool is one this factory deployed.
    PrecisionPoolFactory public immutable factory;

    error Bad();
    error NoPool();
    error NotExecutor();
    error BadCheckpoint();

    event Exited(
        address indexed pool, address indexed to, uint256 shares, uint256 amount0, uint256 amount1
    );

    constructor(PrecisionPoolFactory factory_, address trustedExecutor_) {
        if (address(factory_).code.length == 0 || trustedExecutor_ == address(0)) revert Bad();
        (factory, trustedExecutor) = (factory_, trustedExecutor_);
    }

    /// @notice Snapshot this contract's share balance immediately before the
    ///         router funds it.
    /// @dev Single-use and transient, and keyed by caller as well as token, so
    ///      one route cannot consume another's funding.
    function checkpoint(address token) external {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (token == address(0) || token.code.length == 0) revert Bad();

        bytes32 slot = _checkpointSlot(token);
        uint256 active;
        assembly ("memory-safe") {
            active := tload(slot)
        }
        if (active != 0) revert BadCheckpoint();

        // Named `snapshot`, not `balance`: the latter is a Yul builtin and
        // shadowing it inside the assembly block will not compile.
        uint256 snapshot = PrecisionPool(payable(token)).balanceOf(address(this));
        assembly ("memory-safe") {
            tstore(slot, 1)
            tstore(add(slot, 1), snapshot)
        }
    }

    /// @notice Burn prefunded shares and deliver both sides to `to`.
    /// @dev The LP token IS the pool, so one address identifies both the
    ///      market and the asset being redeemed.
    function exit(address pool, uint256 shares, uint256 min0, uint256 min1, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (!factory.isPool(pool)) revert NoPool();
        if (to == address(0) || to == address(this) || to == pool) revert Bad();
        if (shares == 0) revert Bad();

        _consumeCheckpoint(pool, shares);

        // Burns from this contract and pays `to` directly, so nothing is left
        // here for a later caller to sweep.
        (amount0, amount1) = PrecisionPool(payable(pool)).removeLiquidity(shares, min0, min1, to);
        emit Exited(pool, to, shares, amount0, amount1);
    }

    /// @dev Cleared before the pool receives control, so a reentrant call
    ///      cannot spend the same route funding twice.
    function _consumeCheckpoint(address token, uint256 amount) internal {
        bytes32 slot = _checkpointSlot(token);
        uint256 active;
        uint256 base;
        assembly ("memory-safe") {
            active := tload(slot)
            base := tload(add(slot, 1))
            tstore(slot, 0)
            tstore(add(slot, 1), 0)
        }
        if (active == 0) revert BadCheckpoint();

        uint256 current = PrecisionPool(payable(token)).balanceOf(address(this));
        if (current < base || current - base != amount) revert BadCheckpoint();
    }

    function _checkpointSlot(address token) internal view returns (bytes32 slot) {
        uint256 slotSeed = CHECKPOINT_SEED;
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(0x00, caller())
            mstore(0x20, token)
            mstore(0x40, slotSeed)
            slot := keccak256(0x00, 0x60)
            mstore(0x40, free)
        }
    }
}
