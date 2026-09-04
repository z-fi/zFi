// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title V4PortL2
/// @notice One venue for every Uniswap v4 pool, hooked or not, in both
///         directions, without the swapper's tokens ever resting here.
///
/// @dev WHY THIS EXISTS AT ALL. v4 pools that are priced by a hook have no
///      execution path through zRouter, and tokens with transfer restrictions
///      have none anywhere: FWAToken reverts every transfer that does not touch
///      the PoolManager, its owner or a distributor, so an ordinary adapter -
///      which takes delivery of the output and forwards it - freezes the token
///      at its own address permanently. `Fwabol` was the answer for that one
///      token. This is the same answer for all of them.
///
/// @dev THE MECHANISM. Settling in v4 is `sync()`, get the tokens to the
///      PoolManager by ANY means, `settle()`: the credit is the measured
///      balance change and the payer need not be the locker. So the swapper
///      pays the PoolManager DIRECTLY and the PoolManager pays the recipient
///      DIRECTLY. Nothing is ever owed to this contract, which is what makes a
///      restricted token work - both hops touch the PoolManager, the one
///      counterparty such tokens are written to permit.
///
///      That is also why this is not the Universal Router. UR's `SETTLE` pays
///      from `_msgSender()`, which through an adapter is the adapter, so the
///      adapter would have to hold the token first.
///
/// @dev WHY AN ARBITRARY PoolKey IS SAFE. The safety here is not that a pool is
///      hardcoded - it is that the only funds this contract can move are the
///      CALLER'S, and the only account it can pay is the named recipient:
///
///        - the input is pulled with `transferFrom(msg.sender, PoolManager, …)`,
///          never from a third party, so an allowance granted to this contract
///          is not a standing option anyone else can exercise;
///        - native input is `msg.value`, which is the caller's by definition;
///        - the output goes to `recipient` and is floored by `minOut`.
///
///      None of that depends on which pool was named. A hostile key buys the
///      caller a bad trade for their own money, bounded by their own `minOut` -
///      which is what any router with a caller-supplied route already permits,
///      and what a front end choosing routes is trusted not to do. Hardcoding
///      the pool would defend against nothing that `minOut` does not.
///
/// @dev FEE-ON-TRANSFER TOKENS FAIL LOUDLY. `settle()` credits what the
///      PoolManager actually received, so a token that skims a transfer
///      under-settles and v4 reverts on the unsettled delta. Wrong, not lossy.
contract V4PortL2 {
    /// @dev Set at construction, not hardcoded. The PoolManager sits at a
    ///      different address on every chain, and CREATE3 derives an address
    ///      from the deployer and salt alone — never from the initcode — so one
    ///      source deployed with three arguments lands on one address.
    address internal immutable PM;

    constructor(address poolManager) {
        PM = poolManager;
    }

    /// @dev One tick inside each end of v4's range, so a swap is bounded by its
    ///      own amount rather than by the price limit.
    uint160 internal constant MIN_SQRT_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    error BadRecipient();
    error Deadline();
    error NothingIn();
    error NotPoolManager();
    error Slippage(uint256 got, uint256 min);
    error RefundFailed();
    error ValueMismatch();

    /// @notice Swap `amountIn` of one side of `key` for the other, exact-in.
    /// @param key         The pool. Any pool - the hook, if there is one, prices
    ///                    it and this contract does not care how.
    /// @param zeroForOne  True to sell `currency0` for `currency1`.
    /// @param amountIn    Input amount. Must equal `msg.value` when the input
    ///                    currency is native, and is pulled from the caller
    ///                    otherwise.
    /// @param minOut      Floor on the output, enforced here against the pool's
    ///                    actual delta rather than trusted from a quote.
    /// @param recipient   Who receives the output. Never this contract: the
    ///                    whole point is that nothing is owed here.
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) public payable returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Deadline();
        if (recipient == address(0) || recipient == address(this)) revert BadRecipient();
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert NothingIn();

        address currencyIn = zeroForOne ? key.currency0 : key.currency1;
        // Native input must be exactly what was sent. Accepting a smaller
        // `amountIn` than `msg.value` would silently leave the difference to be
        // refunded, and accepting a larger one would spend a previous caller's
        // dust; requiring equality removes both readings.
        if (currencyIn == address(0)) {
            if (msg.value != amountIn) revert ValueMismatch();
        } else if (msg.value != 0) {
            revert ValueMismatch();
        }

        amountOut = abi.decode(
            IPoolManager(PM).unlock(
                abi.encode(key, zeroForOne, amountIn, minOut, msg.sender, recipient)
            ),
            (uint256)
        );

        // An exact-in swap consumes what it is given, so this is normally zero.
        // It is here because that is the pool's behaviour, not a promise, and
        // change belongs to whoever paid it in.
        uint256 left = address(this).balance;
        if (left != 0) {
            (bool sent,) = msg.sender.call{value: left}("");
            if (!sent) revert RefundFailed();
        }
    }

    function unlockCallback(bytes calldata data) public returns (bytes memory) {
        if (msg.sender != PM) revert NotPoolManager();
        (
            PoolKey memory key,
            bool zeroForOne,
            uint256 amountIn,
            uint256 minOut,
            address payer,
            address recipient
        ) = abi.decode(data, (PoolKey, bool, uint256, uint256, address, address));

        int256 packed = IPoolManager(PM).swap(
            key,
            SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? MIN_SQRT_PLUS_ONE : MAX_SQRT_MINUS_ONE),
            ""
        );
        // BalanceDelta packs amount0 in the high 128 bits, amount1 in the low.
        // Negative is owed by us, positive is owed to us.
        int128 delta0 = int128(packed >> 128);
        int128 delta1 = int128(packed);
        (int128 deltaIn, int128 deltaOut) = zeroForOne ? (delta0, delta1) : (delta1, delta0);
        (address currencyIn, address currencyOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        // Pay what the swap says we owe - not what the caller asked to spend.
        // A hook may consume less than the exact-in amount, and settling the
        // request rather than the debt would overpay it into the pool.
        uint256 owed = uint256(uint128(-deltaIn));
        IPoolManager(PM).sync(currencyIn);
        if (currencyIn == address(0)) {
            IPoolManager(PM).settle{value: owed}();
        } else {
            // Straight from the payer to the PoolManager. This contract is
            // never an intermediate holder, which is the property that lets a
            // transfer-restricted token be traded at all.
            safeTransferFrom(currencyIn, payer, PM, owed);
            IPoolManager(PM).settle();
        }

        uint256 out = uint256(uint128(deltaOut));
        if (out < minOut) revert Slippage(out, minOut);
        IPoolManager(PM).take(currencyOut, recipient, out);
        return abi.encode(out);
    }

    /// @dev Bubbles the token's own revert - for a restricted token that reason
    ///      is the only informative part. Treats an empty return as success and
    ///      a `false` return as failure, since tokens disagree about which they
    ///      do.
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        require(ret.length == 0 || abi.decode(ret, (bool)), "transferFrom returned false");
    }

    /// @dev ETH arrives only as the PoolManager paying out a swap in progress.
    receive() external payable {
        if (msg.sender != PM) revert NotPoolManager();
    }
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata) external returns (bytes memory);
    function swap(PoolKey memory, SwapParams memory, bytes calldata) external returns (int256);
    function sync(address) external;
    function settle() external payable returns (uint256);
    function take(address, address, uint256) external;
}
