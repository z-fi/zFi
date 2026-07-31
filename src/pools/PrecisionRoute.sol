// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";
import {PrecisionPool} from "./PrecisionPool.sol";
import {PrecisionPoolFactory} from "./PrecisionPoolFactory.sol";

/// @title PrecisionRoute
/// @notice Executes a multi-pool route as a SINGLE zRouter executor call.
///
/// @dev    WHY THIS EXISTS. A route composed as several snwap legs runs into
///         two properties of the router that are easy to get wrong and only
///         fail at submission:
///
///           - snwap forwards `msg.value` to every leg, so a multicall that
///             carries native ETH can contain at most one of them. Routes
///             starting in ETH could not be chained at all.
///           - a chained leg is funded from the router's balance and snwap
///             forwards `balance - 1`, retaining a wei. The factory settles an
///             exact declared amount, so the caller had to subtract that wei by
///             hand or be rejected.
///
///         Collapsing the route into one leg removes both. The router funds
///         this contract once, this contract walks the hops itself, and only
///         the final output is measured at the recipient - which is also the
///         only place slippage needs checking.
///
///         IT USES THE PUBLIC POOL ENTRY POINT. Hops go through
///         `swapExactIn`, which pulls exactly what it is told from this
///         contract. The factory-only `swapFromFactory` is deliberately not
///         used: this contract is replaceable and should not need to be
///         trusted by the pools.
///
///         FUNDING IS CHECKPOINTED, as everywhere else here. snwap sends the
///         input before calling, so a bare balance is not evidence of this
///         route's funding; a transient single-use checkpoint taken
///         immediately before makes only the fresh delta spendable.
///
///         INTERMEDIATES NEVER REST HERE. Each hop pays the next, and the last
///         pays the recipient. A balance left behind would be claimable by
///         whoever routed next, so the checkpoint is what makes that safe even
///         if a token misbehaves.
contract PrecisionRoute {
    using SafeTransferLib for address;

    uint256 constant CHECKPOINT_SEED = 0x51c0de17;

    address public immutable trustedExecutor;
    PrecisionPoolFactory public immutable factory;

    error Bad();
    error NoPool();
    error NotExecutor();
    error BadCheckpoint();
    error InsufficientOutput();

    event Routed(address indexed to, uint256 hops, uint256 amountIn, uint256 amountOut);

    constructor(PrecisionPoolFactory factory_, address trustedExecutor_) {
        if (address(factory_).code.length == 0 || trustedExecutor_ == address(0)) revert Bad();
        (factory, trustedExecutor) = (factory_, trustedExecutor_);
    }

    receive() external payable {}

    function checkpoint(address token) external {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (token == address(0) || token.code.length == 0) revert Bad();
        bytes32 slot = _slot(token);
        uint256 active;
        assembly ("memory-safe") {
            active := tload(slot)
        }
        if (active != 0) revert BadCheckpoint();
        uint256 snap = token.balanceOf(address(this));
        assembly ("memory-safe") {
            tstore(slot, 1)
            tstore(add(slot, 1), snap)
        }
    }

    /// @notice Walk `pools` in order, starting from `amountIn` of `tokenIn`.
    /// @dev Native input arrives as msg.value; ERC-20 input must have been
    ///      checkpointed and then transferred here in the same transaction.
    function route(
        address[] calldata pools,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address to
    ) external payable returns (uint256 amountOut) {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (pools.length == 0 || amountIn == 0) revert Bad();
        if (to == address(0) || to == address(this)) revert Bad();

        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert Bad();
        } else {
            if (msg.value != 0) revert Bad();
            _consume(tokenIn, amountIn);
        }

        address tin = tokenIn;
        uint256 amt = amountIn;
        for (uint256 i; i < pools.length; ++i) {
            address pool = pools[i];
            if (!factory.isPool(pool)) revert NoPool();
            PrecisionPool p = PrecisionPool(payable(pool));

            address t0 = p.token0();
            address tout = tin == t0 ? p.token1() : t0;
            // The last hop pays the recipient; the rest pay this contract, so
            // no intermediate is ever left resting.
            address dst = i + 1 == pools.length ? to : address(this);

            if (tin == address(0)) {
                amt = p.swapExactIn{value: amt}(tin, amt, 0, dst);
            } else {
                tin.safeApproveWithRetry(pool, amt);
                amt = p.swapExactIn(tin, amt, 0, dst);
                tin.safeApproveWithRetry(pool, 0);
            }
            tin = tout;
        }

        if (amt < minOut) revert InsufficientOutput();
        amountOut = amt;
        emit Routed(to, pools.length, amountIn, amountOut);
    }

    /// @notice Enter a band holding only ONE of its assets: swap part of the
    ///         input, then deposit both sides, in a single call.
    ///
    /// @dev The common UX. `factory.seed` already handles a two-asset entry,
    ///      but a user holding one asset would otherwise swap, work out what
    ///      they received, and deposit in a second transaction - with the price
    ///      moving in between.
    ///
    ///      `swapPortion` is supplied rather than derived. The optimal split
    ///      depends on the band, the live price and the fee, and computing it
    ///      on-chain would charge every caller gas to reproduce arithmetic a
    ///      frontend does for free. Whatever cannot be deposited at the pool's
    ///      ratio is refunded, so an imperfect split costs only the swap fee on
    ///      the portion actually traded.
    ///
    ///      Leftovers are always returned. This contract must never retain
    ///      value between routes or the next caller could sweep it.
    function zapIn(
        address pool,
        address tokenIn,
        uint256 amountIn,
        uint256 swapPortion,
        uint256 minLP,
        address to
    ) external payable returns (uint256 lp) {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (!factory.isPool(pool)) revert NoPool();
        if (to == address(0) || to == address(this)) revert Bad();
        if (amountIn == 0 || swapPortion > amountIn) revert Bad();

        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert Bad();
        } else {
            if (msg.value != 0) revert Bad();
            _consume(tokenIn, amountIn);
        }

        PrecisionPool p = PrecisionPool(payable(pool));
        address t0 = p.token0();
        address t1 = p.token1();
        if (tokenIn != t0 && tokenIn != t1) revert Bad();

        uint256 received;
        if (swapPortion != 0) {
            if (tokenIn == address(0)) {
                received = p.swapExactIn{value: swapPortion}(tokenIn, swapPortion, 0, address(this));
            } else {
                tokenIn.safeApproveWithRetry(pool, swapPortion);
                received = p.swapExactIn(tokenIn, swapPortion, 0, address(this));
                tokenIn.safeApproveWithRetry(pool, 0);
            }
        }

        uint256 keep = amountIn - swapPortion;
        (uint256 a0, uint256 a1) = tokenIn == t0 ? (keep, received) : (received, keep);

        uint256 value;
        if (t0 == address(0)) value = a0;
        else t0.safeApproveWithRetry(pool, a0);
        if (t1 != address(0)) t1.safeApproveWithRetry(pool, a1);

        // `sqrtPriceInit` is ignored once the pool has supply, so a zap into an
        // unseeded band is refused rather than silently choosing its price.
        (lp,,) = p.addLiquidityExact{value: value}(0, a0, a1, minLP, to);

        if (t0 != address(0)) t0.safeApproveWithRetry(pool, 0);
        if (t1 != address(0)) t1.safeApproveWithRetry(pool, 0);

        _sweep(t0, to);
        _sweep(t1, to);
    }

    /// @dev Returns anything the deposit could not take at the pool's ratio.
    function _sweep(address token, address to) internal {
        uint256 bal = token == address(0) ? address(this).balance : token.balanceOf(address(this));
        if (bal == 0) return;
        if (token == address(0)) to.safeTransferETH(bal);
        else token.safeTransfer(to, bal);
    }

    function _consume(address token, uint256 amount) internal {
        bytes32 slot = _slot(token);
        uint256 active;
        uint256 base;
        assembly ("memory-safe") {
            active := tload(slot)
            base := tload(add(slot, 1))
            tstore(slot, 0)
            tstore(add(slot, 1), 0)
        }
        if (active == 0) revert BadCheckpoint();
        uint256 current = token.balanceOf(address(this));
        if (current < base || current - base != amount) revert BadCheckpoint();
    }

    function _slot(address token) internal view returns (bytes32 slot) {
        uint256 seed = CHECKPOINT_SEED;
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(0x00, caller())
            mstore(0x20, token)
            mstore(0x40, seed)
            slot := keccak256(0x00, 0x60)
            mstore(0x40, free)
        }
    }
}
