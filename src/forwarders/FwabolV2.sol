// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title Fwabol
/// @notice Buys AND sells FWAToken, by talking to the v4 PoolManager directly.
///
/// @dev WHAT THIS SUPERSEDES. the first Fwabol (0x000000F2303C64Ad38956B38917Ade68b7a604FE)
///      routes buys through the Uniswap Universal Router, and every awkward part of it is a workaround for that choice: `TAKE` instead of `TAKE_ALL`
///      because the router infers a recipient from its own caller; a `SWEEP`
///      command because unspent input would otherwise rest in the router; a
///      balance snapshot and a refund hop because the router pays change to ITS
///      caller. And it could only ever buy, because the router's `SETTLE` pays
///      from `_msgSender()` - which through an adapter is the adapter, and an
///      adapter that holds FWA has bricked it.
///
///      None of that is v4's rule. Settling in v4 is `sync()`, get the tokens to
///      the PoolManager by ANY means, `settle()`; the credit comes from the
///      measured balance change, and the payer need not be the locker. Unlock
///      the PoolManager directly and the entire workaround evaporates - both
///      directions work, nothing is inferred, and no ETH can rest anywhere this
///      contract cannot see.
///
/// @dev WHY FWA NEEDS AN ADAPTER AT ALL. FWAToken's `_afterTokenTransfer`
///      reverts `InvalidTransfer()` on every transfer except mint/burn, ones
///      touching the owner or a distributor, and ones touching the PoolManager -
///      the last only up to a transient allowance the hook raises during a swap.
///      So FWA may move PoolManager -> user, or user -> PoolManager, but never
///      user -> adapter -> anywhere. This contract therefore never takes
///      delivery of FWA in either direction: on a buy the PoolManager pays the
///      recipient, and on a sell the seller pays the PoolManager. FWA is never
///      owed to this address at any point in the transaction.
///
/// @dev THE SELLER IS `msg.sender`, NEVER A PARAMETER. A sell has to pull FWA
///      from someone, which means an allowance. Were the payer an argument, any
///      caller could sell any approving account's FWA at a moment and price of
///      their choosing - an approval to this contract would become a standing
///      option written against the holder. Taking the seller from `msg.sender`
///      makes that unrepresentable rather than merely unlikely.
///
///      The cost is that a sell cannot be wrapped in `zRouter.snwap`, whose
///      executor sees `SafeExecutor` as its caller: routed that way the pull
///      finds no allowance and the sell reverts, which is the safe failure. A
///      routed sell wants a per-trade Permit2 signature instead, and that is a
///      deliberate later addition, not an oversight.
contract Fwabol {
    address internal constant PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address internal constant HOOK = 0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444;
    uint24 internal constant FEE = 0;
    int24 internal constant TICK_SPACING = 60;

    /// @dev v4's price bounds, one tick inside each end so the swap is limited
    ///      by its own amount rather than by the range.
    uint160 internal constant MIN_SQRT_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    error BadRecipient();
    error Deadline();
    error NothingIn();
    error NotPoolManager();
    error Slippage(uint256 got, uint256 min);
    error RefundFailed();

    /// @notice Spend the attached ETH on FWA, delivered straight to `recipient`.
    /// @return fwaOut FWA received by `recipient`.
    function buy(address recipient, uint128 minOut, uint256 deadline)
        public
        payable
        returns (uint256 fwaOut)
    {
        if (block.timestamp > deadline) revert Deadline();
        if (recipient == address(0) || recipient == address(this)) revert BadRecipient();
        if (msg.value == 0) revert NothingIn();

        fwaOut = abi.decode(
            IPoolManager(PM).unlock(
                abi.encode(true, msg.sender, recipient, uint128(msg.value), minOut)
            ),
            (uint256)
        );

        // An exact-in swap consumes exactly what it was given, so this is
        // normally zero. It is here because "normally" is the pool's behaviour
        // today, not a promise, and change belongs to whoever paid it in.
        uint256 left = address(this).balance;
        if (left != 0) {
            (bool sent,) = msg.sender.call{value: left}("");
            if (!sent) revert RefundFailed();
        }
    }

    /// @notice Sell `amountIn` of the CALLER's FWA for ETH.
    /// @dev Requires `amountIn` of ERC20 allowance from the caller to this
    ///      contract. The FWA moves caller -> PoolManager in one hop; it is
    ///      never held here.
    /// @return ethOut ETH received by `recipient`.
    function sell(uint128 amountIn, address recipient, uint128 minOut, uint256 deadline)
        public
        returns (uint256 ethOut)
    {
        if (block.timestamp > deadline) revert Deadline();
        if (recipient == address(0) || recipient == address(this)) revert BadRecipient();
        if (amountIn == 0) revert NothingIn();

        return abi.decode(
            IPoolManager(PM).unlock(abi.encode(false, msg.sender, recipient, amountIn, minOut)),
            (uint256)
        );
    }

    /// @dev The PoolManager calls back here holding the lock. Only it can:
    ///      everything below moves someone else's tokens, and outside the lock
    ///      none of it would be authorised anyway - but a cheap explicit check
    ///      beats reasoning about what `settle` would do to a stray caller.
    function unlockCallback(bytes calldata data) public returns (bytes memory) {
        if (msg.sender != PM) revert NotPoolManager();
        (bool isBuy, address payer, address recipient, uint128 amountIn, uint128 minOut) =
            abi.decode(data, (bool, address, address, uint128, uint128));

        // Exact-in, so the specified amount is negative. currency0 is native
        // ETH and currency1 is FWA, so a buy is zeroForOne.
        int256 packed = IPoolManager(PM).swap(
            PoolKey(address(0), FWA, FEE, TICK_SPACING, HOOK),
            SwapParams(isBuy, -int256(uint256(amountIn)), isBuy ? MIN_SQRT_PLUS_ONE : MAX_SQRT_MINUS_ONE),
            ""
        );
        // BalanceDelta packs amount0 in the high 128 bits and amount1 in the
        // low. Negative is owed by us, positive is owed to us.
        int128 ethDelta = int128(packed >> 128);
        int128 fwaDelta = int128(packed);

        if (isBuy) {
            // Pay ETH, then have the PoolManager pay the recipient in FWA. That
            // second leg is the one transfer shape the token permits on the way
            // out, and it is why the recipient is named rather than inferred.
            uint256 owed = uint256(uint128(-ethDelta));
            IPoolManager(PM).sync(address(0));
            IPoolManager(PM).settle{value: owed}();

            uint256 out = uint256(uint128(fwaDelta));
            if (out < minOut) revert Slippage(out, minOut);
            IPoolManager(PM).take(FWA, recipient, out);
            return abi.encode(out);
        }

        // Selling: the seller pays the PoolManager DIRECTLY. `settle` credits
        // the balance change it measures, so this contract never has to hold -
        // or even be owed - a single unit of FWA.
        uint256 owedFwa = uint256(uint128(-fwaDelta));
        IPoolManager(PM).sync(FWA);
        safeTransferFrom(FWA, payer, PM, owedFwa);
        IPoolManager(PM).settle();

        uint256 ethOut = uint256(uint128(ethDelta));
        if (ethOut < minOut) revert Slippage(ethOut, minOut);
        IPoolManager(PM).take(address(0), recipient, ethOut);
        return abi.encode(ethOut);
    }

    /// @dev Bubbles the token's own revert - for FWA that is `InvalidTransfer()`,
    ///      the only informative thing about a failed move. Also treats an
    ///      empty return as success and a `false` return as failure, since FWA
    ///      returns a bool and other tokens are inconsistent about it.
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

    /// @dev ETH arrives here only as the PoolManager paying out a swap this
    ///      contract is in the middle of settling.
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
