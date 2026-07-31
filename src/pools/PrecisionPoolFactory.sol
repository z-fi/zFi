// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";
import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";

/// @title PrecisionPoolFactory
/// @notice Deploys one PrecisionPool for each complete immutable market tuple.
/// @dev CREATE2 derives each pool address from the factory, market tuple, and
///      pool init code. Pools are indexed globally and by pair, token, and
///      creator. Token order is canonical (`token0 < token1`), and price bounds
///      use raw token units with decimals already included.
contract PrecisionPoolFactory {
    using SafeTransferLib for address;

    /// @notice Everything that defines a market and its CREATE2 address.
    struct Market {
        address token0;
        address token1;
        uint256 sqrtPLow;
        uint256 sqrtPHigh;
        uint256 fee;
        address hook;
        address feeRecipient;
        uint256 creatorFeeBps;
    }

    /// @dev `fee` is in pips; hook and creator-fee settings are also immutable.
    uint256 constant MAX_FEE = 100_000; // 10%, in pips
    uint256 constant MAX_CREATOR_SHARE = 5_000; // 50% of the base fee
    uint256 constant MAX_PAGE_SIZE = 128;
    uint256 constant MAX_SQRT_PRICE = 1e36;
    uint256 constant CHECKPOINT_NAMESPACE = 1 << 255;

    /// @dev Transient slot guarding the prefunded route.
    uint256 constant _ROUTE_SLOT = 0x9e7d1a3c;

    error Bad();
    error Exists();
    error Reentrancy();
    error NoPool();
    error NotCreator();
    error NotExecutor();
    error BadCheckpoint();

    /// @notice Executor allowed to use the checkpointed prefunded route.
    ///         Address(0) disables that route.
    /// @dev ERC-20 settlement also checks a transient balance checkpoint, so
    ///      pre-existing factory balances cannot be spent by a route.
    address public immutable trustedExecutor;

    /// @dev Every pool ever created, in creation order.
    address[] public allPools;
    mapping(address pool => bool) public isPool;

    /// @dev Pools per canonical pair.
    mapping(address token0 => mapping(address token1 => address[])) internal _byPair;

    /// @dev Pools containing a token, in either position.
    mapping(address token => address[]) internal _byToken;

    /// @dev Pools with a nonzero fee recipient.
    mapping(address creator => address[]) internal _byCreator;

    event PoolCreated(address indexed pool, address indexed token0, address indexed token1, uint256 fee);

    /// @dev Serialises the prefunded route. Each checkpoint is already cleared
    ///      before its own token receives control, so the same funding cannot
    ///      be spent twice. This closes the cross-token case: if an executor
    ///      ever holds two live checkpoints, a callback from a token, the
    ///      recipient, or `afterSwap` must not be able to re-enter and settle
    ///      against the other one. The executor is external and immutable here,
    ///      so the factory does not rely on it to be well behaved. A route is
    ///      never legitimately nested - hops are sequential calls.
    modifier routeLocked() {
        assembly ("memory-safe") {
            if tload(_ROUTE_SLOT) {
                mstore(0x00, 0xab143c06) // `Reentrancy()`.
                revert(0x1c, 0x04)
            }
            tstore(_ROUTE_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(_ROUTE_SLOT, 0)
        }
    }

    /// @param trustedExecutor_ Router allowed to call `executePrefundedSwap`.
    ///        Set to address(0) when only direct exact-input swaps are wanted.
    constructor(address trustedExecutor_) {
        if (trustedExecutor_ != address(0) && trustedExecutor_.code.length == 0) revert Bad();
        trustedExecutor = trustedExecutor_;
    }

    /// @notice Deploy the pool for this market.
    /// @param m Bounds are sqrt prices in raw token1 per raw token0 scaled
    ///        1e18, `fee` is in pips (500 = 0.05%), and `creatorFeeBps` is a
    ///        share of that fee rather than an addition to it.
    /// @dev If `feeRecipient` is nonzero, it must create the pool.
    function createPool(Market calldata m) public returns (address pool) {
        _check(m);
        _checkCreator(m);
        bytes32 salt = _marketSalt(m);
        bytes memory initCode = _poolInitCode(m);
        address predicted = _poolAddress(salt, keccak256(initCode));
        if (predicted.code.length != 0) revert Exists();

        assembly ("memory-safe") {
            pool := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(pool) {
                let size := returndatasize()
                if iszero(size) {
                    mstore(0x00, 0x846ec056) // `Exists()`.
                    revert(0x1c, 0x04)
                }
                returndatacopy(0, 0, size)
                revert(0, size)
            }
        }

        _index(pool, m);
        emit PoolCreated(pool, m.token0, m.token1, m.fee);
    }

    /// @dev Indexing at creation keeps these lists complete; they cannot be
    ///      backfilled from this contract later.
    function _index(address pool, Market calldata m) internal {
        allPools.push(pool);
        isPool[pool] = true;
        _byPair[m.token0][m.token1].push(pool);
        _byToken[m.token0].push(pool);
        _byToken[m.token1].push(pool);
        if (m.feeRecipient != address(0)) _byCreator[m.feeRecipient].push(pool);
    }

    // -------------------------------------------------------------- DISCOVERY

    /// @notice Number of pools created by this factory.
    function poolCount() external view returns (uint256) {
        return allPools.length;
    }

    /// @notice Number of pools for a canonical token pair.
    function poolsForPairCount(address token0, address token1) external view returns (uint256) {
        return _byPair[token0][token1].length;
    }

    /// @notice Number of pools containing `token`.
    function poolsForTokenCount(address token) external view returns (uint256) {
        return _byToken[token].length;
    }

    /// @notice Number of pools indexed for `creator`.
    function poolsForCreatorCount(address creator) external view returns (uint256) {
        return _byCreator[creator].length;
    }

    /// @notice Return a bounded page of all pools in creation order.
    /// @dev A start beyond the end returns an empty array.
    function poolsSlice(uint256 start, uint256 count) external view returns (address[] memory out) {
        return _slice(allPools, start, count);
    }

    /// @notice Return a bounded page of pools for a canonical pair.
    function poolsForPairSlice(address token0, address token1, uint256 start, uint256 count)
        external
        view
        returns (address[] memory)
    {
        return _slice(_byPair[token0][token1], start, count);
    }

    /// @notice Return a bounded page of pools containing `token`.
    function poolsForTokenSlice(address token, uint256 start, uint256 count) external view returns (address[] memory) {
        return _slice(_byToken[token], start, count);
    }

    /// @notice Return a bounded page of pools created by `creator`.
    function poolsForCreatorSlice(address creator, uint256 start, uint256 count)
        external
        view
        returns (address[] memory)
    {
        return _slice(_byCreator[creator], start, count);
    }

    function _slice(address[] storage pools, uint256 start, uint256 count)
        internal
        view
        returns (address[] memory out)
    {
        if (count > MAX_PAGE_SIZE) revert Bad();
        uint256 total = pools.length;
        if (start >= total || count == 0) return out;
        uint256 size = count;
        uint256 remaining = total - start;
        if (size > remaining) size = remaining;
        out = new address[](size);
        for (uint256 i; i < size;) {
            unchecked {
                out[i] = pools[start + i];
                ++i;
            }
        }
    }

    /// @notice Create and seed a market in one transaction.
    /// @dev Assets are forwarded directly to the pool. The pool refunds any
    ///      unused amount to the caller.
    /// @param m Market configuration.
    /// @param sqrtPriceInit Initial sqrt price; used only for an empty pool.
    /// @param amount0 Maximum token0 amount, or `msg.value` for native token0.
    /// @param amount1 Maximum token1 amount.
    /// @param minLP Minimum LP shares to mint.
    /// @param to LP share recipient.
    function createAndSeed(
        Market calldata m,
        uint256 sqrtPriceInit,
        uint256 amount0,
        uint256 amount1,
        uint256 minLP,
        address to
    ) external payable returns (address pool, uint256 lp, uint256 used0, uint256 used1) {
        pool = createPool(m);
        (lp, used0, used1) = _fund(pool, m.token0, m.token1, amount0, amount1, sqrtPriceInit, minLP, to);
    }

    /// @notice Add liquidity to an existing market.
    /// @dev The pool is resolved from the complete market tuple. If it is
    ///      empty, `sqrtPriceInit` sets its initial price; otherwise it is ignored.
    /// @param m Market configuration.
    /// @param sqrtPriceInit Initial sqrt price for an empty pool.
    /// @param amount0 Maximum token0 amount, or `msg.value` for native token0.
    /// @param amount1 Maximum token1 amount.
    /// @param minLP Minimum LP shares to mint.
    /// @param to LP share recipient.
    function seed(Market calldata m, uint256 sqrtPriceInit, uint256 amount0, uint256 amount1, uint256 minLP, address to)
        external
        payable
        returns (address pool, uint256 lp, uint256 used0, uint256 used1)
    {
        pool = poolFor(m);
        if (!isPool[pool]) revert NoPool();
        // A named market can only be initialized by its fee recipient.
        if (PrecisionPool(payable(pool)).totalSupply() == 0) _checkCreator(m);
        (lp, used0, used1) = _fund(pool, m.token0, m.token1, amount0, amount1, sqrtPriceInit, minLP, to);
    }

    /// @dev Moves both sides from the caller to the pool, then mints and
    ///      refunds any unused amount to the caller.
    function _fund(
        address pool,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 sqrtPriceInit,
        uint256 minLP,
        address to
    ) internal returns (uint256 lp, uint256 used0, uint256 used1) {
        if (token0 == address(0)) {
            if (msg.value != amount0) revert Bad();
        } else {
            if (msg.value != 0) revert Bad();
            _pullExact(token0, msg.sender, pool, amount0);
        }
        _pullExact(token1, msg.sender, pool, amount1);

        return PrecisionPool(payable(pool)).addLiquidityFromFactory{value: token0 == address(0) ? amount0 : 0}(
            sqrtPriceInit, amount0, amount1, minLP, to, msg.sender
        );
    }

    /// @notice Snapshot an ERC-20 balance before a prefunded swap.
    /// @dev Must be followed in the same transaction by `executePrefundedSwap`.
    ///      The transient checkpoint binds settlement to the newly funded amount.
    function checkpoint(address token) external routeLocked {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (token == address(0) || token.code.length == 0) revert Bad();

        bytes32 slot = _checkpointSlot(token);
        uint256 encoded;
        assembly ("memory-safe") {
            encoded := tload(slot)
        }
        if (encoded != 0) revert BadCheckpoint();

        uint256 checkpointBalance = token.balanceOf(address(this));
        if (checkpointBalance == type(uint256).max) revert BadCheckpoint();
        unchecked {
            encoded = checkpointBalance + 1;
        }
        assembly ("memory-safe") {
            tstore(slot, encoded)
        }
    }

    /// @notice Settle a swap after the trusted executor has funded this factory.
    /// @dev ERC-20 input requires a same-transaction `checkpoint`; native input
    ///      is authenticated by `msg.value`.
    /// @param originator Reported to the pool's hook as the trader. NOT
    ///        authenticated: snwap reaches this contract through a public
    ///        executor that does not forward the payer, so no party on this
    ///        path can prove who is trading. It exists so a hook sees something
    ///        other than this factory on every routed swap, which would
    ///        otherwise make sender-keyed hook logic uniformly wrong. Hooks
    ///        must treat it as a label, never as authority.
    function executePrefundedSwap(
        address pool,
        address originator,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address to
    )
        external
        payable
        routeLocked
        returns (uint256 amountOut)
    {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (!isPool[pool]) revert NoPool();
        PrecisionPool p = PrecisionPool(payable(pool));
        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert Bad();
            return p.swapFromFactory{value: amountIn}(originator, tokenIn, amountIn, minOut, to);
        }
        if (msg.value != 0) revert Bad();
        uint256 senderBefore = _consumeCheckpoint(tokenIn, amountIn);
        _transferExact(tokenIn, pool, amountIn, senderBefore);
        return p.swapFromFactory(originator, tokenIn, amountIn, minOut, to);
    }

    function _consumeCheckpoint(address token, uint256 amount) internal returns (uint256 current) {
        bytes32 slot = _checkpointSlot(token);
        uint256 encoded;
        assembly ("memory-safe") {
            encoded := tload(slot)
            // Clear before the token receives control. A reentrant call cannot
            // consume the same route funding twice.
            tstore(slot, 0)
        }
        if (encoded == 0) revert BadCheckpoint();

        uint256 base;
        unchecked {
            base = encoded - 1;
        }
        current = token.balanceOf(address(this));
        if (current < base || current - base != amount) revert BadCheckpoint();
    }

    function _checkpointSlot(address token) internal pure returns (bytes32) {
        return bytes32(CHECKPOINT_NAMESPACE | uint256(uint160(token)));
    }

    function _pullExact(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(to);
        SafeTransferLib.safeTransferFrom(token, from, to, amount);
        uint256 afterBalance = token.balanceOf(to);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert Bad();
    }

    function _transferExact(address token, address to, uint256 amount, uint256 senderBefore) internal {
        if (amount == 0) return;
        uint256 recipientBefore = token.balanceOf(to);
        SafeTransferLib.safeTransfer(token, to, amount);
        uint256 senderAfter = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(to);
        if (
            senderAfter > senderBefore || senderBefore - senderAfter != amount || recipientAfter < recipientBefore
                || recipientAfter - recipientBefore != amount
        ) revert Bad();
    }

    /// @notice Return the pool address for a market, whether deployed or not.
    function poolFor(Market calldata m) public view returns (address) {
        return _poolAddress(_marketSalt(m), keccak256(_poolInitCode(m)));
    }

    function _poolInitCode(Market calldata m) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(PrecisionPool).creationCode,
            abi.encode(
                address(this),
                m.token0,
                m.token1,
                m.sqrtPLow,
                m.sqrtPHigh,
                m.fee,
                m.hook,
                m.feeRecipient,
                m.creatorFeeBps
            )
        );
    }

    function _marketSalt(Market calldata m) internal pure returns (bytes32) {
        return keccak256(abi.encode(m));
    }

    function _poolAddress(bytes32 salt, bytes32 initHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    function _check(Market calldata m) internal view {
        // Canonical ordering; address(0) is native ETH and sorts first, which
        // is what makes it always token0.
        if (m.token0 >= m.token1) revert Bad();
        if (m.token1.code.length == 0 || (m.token0 != address(0) && m.token0.code.length == 0)) revert Bad();
        // Bounds must be nonzero and ordered. The upper bound combines with the
        // pool's liquidity cap to keep virtual-reserve arithmetic in range.
        if (m.sqrtPLow == 0 || m.sqrtPHigh <= m.sqrtPLow || m.sqrtPHigh > MAX_SQRT_PRICE) revert Bad();
        if (m.fee >= MAX_FEE) revert Bad();
        if (m.creatorFeeBps > MAX_CREATOR_SHARE) revert Bad();
        if (m.creatorFeeBps != 0 && m.feeRecipient == address(0)) revert Bad();
        if (m.hook != address(0) && m.hook.code.length == 0) revert Bad();
    }

    function _checkCreator(Market calldata m) internal view {
        if (m.feeRecipient != address(0) && msg.sender != m.feeRecipient) revert NotCreator();
    }
}
