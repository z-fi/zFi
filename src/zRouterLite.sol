// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// zRouterLite (Robinhood Chain, id 4663)
//
// The mainnet zRouter is a multi-venue router: Uniswap V2/V3/V4, zAMM, Sushi,
// Curve, a Lido staker, a generic solver executor and an owner-gated `execute`.
// Robinhood Chain has exactly one liquidity family on it — Uniswap V2, V3 and
// V4, all at canonical init-code hashes — so everything else in that contract
// would be dead weight that still has to be deployed, audited and reasoned about.
//
// WHAT WAS DROPPED, AND WHY EACH IS SAFE TO DROP HERE
//  - swapVZ / addLiquidity / ERC6909: zAMM is not deployed on 4663.
//  - swapCurve and the Curve interface zoo: no Curve pools on 4663.
//  - exactETHToSTETH and friends: no Lido, no stETH, no wstETH.
//  - The Sushi branch of `_v2PoolFor`: no Sushi factory. This also frees the
//    `deadline == type(uint256).max` sentinel, which on mainnet means "Sushi";
//    here a max deadline simply means no deadline, which is what it reads like.
//  - snwap / snwapMulti / SafeExecutor: solver fills need a solver network.
//  - owner, `trust`, `execute`: their only purpose was gating that executor.
//  - The `tload(0x00)` callback lock: its sole writer was `execute`. With no
//    arbitrary outbound call in the contract there is nothing to lock against,
//    and the callbacks still authenticate — V3 against the pool address it
//    re-derives, V4 against the singleton PoolManager.
//  - permit / permitDAI / permit2*: the zSwap front end approves ERC20 directly.
//    Permit2 is deployed on 4663 if this is ever wanted back.
//
// WHAT WAS KEPT VERBATIM: the transient-balance credit system. It is what lets
// `multicall` chain a wrap into a swap into a sweep, and the quoter's
// `buildBestSwap` emits exactly those sequences for the ETH<->WETH path.
//
// ABI: `swapV2`, `swapV3`, `swapV4`, `multicall`, `deposit`, `sweep`, `wrap` and
// `unwrap` keep the mainnet zRouter's exact selectors and argument order —
// including the `id` argument on `deposit`/`sweep`, which is required to be zero
// here but is kept so calldata built for one chain is valid on the other.
contract zRouterLite {
    error BadSwap();
    error Expired();
    error Slippage();
    error InvalidId();
    error Unauthorized();
    error InvalidMsgVal();
    error ETHTransferFailed();

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, Expired());
        _;
    }

    constructor() payable {}

    // ** UNISWAP V2

    function swapV2(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        bool ethIn = tokenIn == address(0);
        bool ethOut = tokenOut == address(0);

        if (ethIn) tokenIn = WETH;
        if (ethOut) tokenOut = WETH;

        (address pool, bool zeroForOne) = _v2PoolFor(tokenIn, tokenOut);
        (uint112 r0, uint112 r1,) = IV2Pool(pool).getReserves();
        (uint256 resIn, uint256 resOut) = zeroForOne ? (r0, r1) : (r1, r0);

        unchecked {
            if (exactOut) {
                amountOut = swapAmount; // target
                uint256 n = resIn * amountOut * 1000;
                uint256 d = (resOut - amountOut) * 997;
                amountIn = (n + d - 1) / d; // ceil-div
                require(amountLimit == 0 || amountIn <= amountLimit, Slippage());
            } else {
                if (swapAmount == 0) {
                    amountIn = ethIn ? msg.value : balanceOf(tokenIn);
                    if (amountIn == 0) revert BadSwap();
                } else {
                    amountIn = swapAmount;
                }
                amountOut = (amountIn * 997 * resOut) / (resIn * 1000 + amountIn * 997);
                require(amountLimit == 0 || amountOut >= amountLimit, Slippage());
            }
            if (!_useTransientBalance(pool, tokenIn, 0, amountIn)) {
                if (_useTransientBalance(address(this), tokenIn, 0, amountIn)) {
                    safeTransfer(tokenIn, pool, amountIn);
                } else if (ethIn) {
                    wrapETH(pool, amountIn);
                    if (to != address(this)) {
                        if (msg.value > amountIn) {
                            _safeTransferETH(msg.sender, msg.value - amountIn);
                        }
                    }
                } else {
                    safeTransferFrom(tokenIn, msg.sender, pool, amountIn);
                }
            }
        }

        if (zeroForOne) {
            IV2Pool(pool).swap(0, amountOut, ethOut ? address(this) : to, "");
        } else {
            IV2Pool(pool).swap(amountOut, 0, ethOut ? address(this) : to, "");
        }

        if (ethOut) {
            unwrapETH(amountOut);
            _safeTransferETH(to, amountOut);
        } else {
            depositFor(tokenOut, 0, amountOut, to); // marks output target
        }
    }

    // ** UNISWAP V3

    function swapV3(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        bool ethIn = tokenIn == address(0);
        bool ethOut = tokenOut == address(0);

        if (ethIn) tokenIn = WETH;
        if (ethOut) tokenOut = WETH;

        (address pool, bool zeroForOne) = _v3PoolFor(tokenIn, tokenOut, swapFee);
        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE;

        unchecked {
            if (!exactOut && swapAmount == 0) {
                swapAmount = ethIn ? msg.value : balanceOf(tokenIn);
                if (swapAmount == 0) revert BadSwap();
            }
            (int256 a0, int256 a1) = IV3Pool(pool)
                .swap(
                    ethOut ? address(this) : to,
                    zeroForOne,
                    exactOut ? -(int256(swapAmount)) : int256(swapAmount),
                    sqrtPriceLimitX96,
                    abi.encodePacked(ethIn, ethOut, msg.sender, tokenIn, tokenOut, to, swapFee)
                );

            if (amountLimit != 0) {
                if (exactOut) require(uint256(zeroForOne ? a0 : a1) <= amountLimit, Slippage());
                else require(uint256(-(zeroForOne ? a1 : a0)) >= amountLimit, Slippage());
            }

            // ── translate pool deltas to user-facing amounts ─
            (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
            amountIn = dIn >= 0 ? uint256(dIn) : uint256(-dIn);
            amountOut = dOut <= 0 ? uint256(-dOut) : uint256(dOut);

            // Handle ETH input refund (separate from output tracking)
            if (ethIn) {
                if ((swapAmount = address(this).balance) != 0 && to != address(this)) {
                    _safeTransferETH(msg.sender, swapAmount);
                }
            }
            // Handle output tracking for chaining (must always run when !ethOut)
            if (!ethOut) {
                depositFor(tokenOut, 0, amountOut, to);
            }
        }
    }

    /// @dev `uniswapV3SwapCallback`. Authenticated by re-deriving the pool from
    /// the tokens and fee carried in the callback data: only the pool a `swapV3`
    /// in this transaction could have called can satisfy it.
    fallback() external payable {
        unchecked {
            int256 amount0Delta;
            int256 amount1Delta;
            bool ethIn;
            bool ethOut;
            address payer;
            address tokenIn;
            address tokenOut;
            address to;
            uint24 swapFee;
            assembly ("memory-safe") {
                amount0Delta := calldataload(0x4)
                amount1Delta := calldataload(0x24)
                ethIn := byte(0, calldataload(0x84))
                ethOut := byte(0, calldataload(add(0x84, 1)))
                payer := shr(96, calldataload(add(0x84, 2)))
                tokenIn := shr(96, calldataload(add(0x84, 22)))
                tokenOut := shr(96, calldataload(add(0x84, 42)))
                to := shr(96, calldataload(add(0x84, 62)))
                swapFee := and(shr(232, calldataload(add(0x84, 82))), 0xFFFFFF)
            }
            require(amount0Delta != 0 || amount1Delta != 0, BadSwap());
            (address pool, bool zeroForOne) = _v3PoolFor(tokenIn, tokenOut, swapFee);
            require(msg.sender == pool, Unauthorized());
            uint256 amountRequired = uint256(zeroForOne ? amount0Delta : amount1Delta);

            if (_useTransientBalance(address(this), tokenIn, 0, amountRequired)) {
                safeTransfer(tokenIn, pool, amountRequired);
            } else if (ethIn) {
                wrapETH(pool, amountRequired);
            } else {
                safeTransferFrom(tokenIn, payer, pool, amountRequired);
            }
            if (ethOut) {
                uint256 amountOut = uint256(-(zeroForOne ? amount1Delta : amount0Delta));
                unwrapETH(amountOut);
                _safeTransferETH(to, amountOut);
            }
        }
    }

    // ** UNISWAP V4

    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        if (!exactOut && swapAmount == 0) {
            swapAmount = tokenIn == address(0) ? msg.value : balanceOf(tokenIn);
            if (swapAmount == 0) revert BadSwap();
        }
        (amountIn, amountOut) = abi.decode(
            IV4PoolManager(V4_POOL_MANAGER)
                .unlock(
                    abi.encode(msg.sender, to, exactOut, swapFee, tickSpace, tokenIn, tokenOut, swapAmount, amountLimit)
                ),
            (uint256, uint256)
        );
        depositFor(tokenOut, 0, amountOut, to); // marks output target
    }

    /// @dev Handle V4 PoolManager swap callback - hookless default.
    function unlockCallback(bytes calldata callbackData) public payable returns (bytes memory result) {
        require(msg.sender == V4_POOL_MANAGER, Unauthorized());

        (
            address payer,
            address to,
            bool exactOut,
            uint24 swapFee,
            int24 tickSpace,
            address tokenIn,
            address tokenOut,
            uint256 swapAmount,
            uint256 amountLimit
        ) = abi.decode(callbackData, (address, address, bool, uint24, int24, address, address, uint256, uint256));

        bool zeroForOne = tokenIn < tokenOut;
        bool ethIn = tokenIn == address(0);

        V4PoolKey memory key =
            V4PoolKey(zeroForOne ? tokenIn : tokenOut, zeroForOne ? tokenOut : tokenIn, swapFee, tickSpace, address(0));

        unchecked {
            int256 delta = _swap(swapAmount, key, zeroForOne, exactOut);
            uint256 takeAmount = zeroForOne
                ? (!exactOut ? uint256(uint128(delta.amount1())) : uint256(uint128(-delta.amount0())))
                : (!exactOut ? uint256(uint128(delta.amount0())) : uint256(uint128(-delta.amount1())));

            IV4PoolManager(msg.sender).sync(tokenIn);
            uint256 amountIn = !exactOut ? swapAmount : takeAmount;

            if (_useTransientBalance(address(this), tokenIn, 0, amountIn)) {
                if (tokenIn != address(0)) {
                    safeTransfer(tokenIn, msg.sender, amountIn); // V4_POOL_MANAGER
                }
            } else if (!ethIn) {
                safeTransferFrom(tokenIn, payer, msg.sender, amountIn); // V4_POOL_MANAGER
            }

            uint256 amountOut = !exactOut ? takeAmount : swapAmount;
            if (amountLimit != 0 && (exactOut ? takeAmount > amountLimit : amountOut < amountLimit)) {
                revert Slippage();
            }

            IV4PoolManager(msg.sender).settle{value: ethIn ? (exactOut ? takeAmount : swapAmount) : 0}();
            IV4PoolManager(msg.sender).take(tokenOut, to, amountOut);

            result = abi.encode(amountIn, amountOut);

            if (ethIn) {
                uint256 ethRefund = address(this).balance;
                if (ethRefund != 0 && to != address(this)) {
                    _safeTransferETH(payer, ethRefund);
                }
            }
        }
    }

    function _swap(uint256 swapAmount, V4PoolKey memory key, bool zeroForOne, bool exactOut)
        internal
        returns (int256 delta)
    {
        unchecked {
            delta = IV4PoolManager(msg.sender)
                .swap(
                    key,
                    V4SwapParams(
                        zeroForOne,
                        exactOut ? int256(swapAmount) : -int256(swapAmount),
                        zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE
                    ),
                    ""
                );
        }
    }

    // ** MULTISWAP HELPER

    function multicall(bytes[] calldata data) public payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i != data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }

    // ** TRANSIENT STORAGE

    /// @dev `id` is kept in the signature for calldata parity with mainnet zRouter
    /// and must be zero: there is no ERC6909 venue on this chain to address.
    function deposit(address token, uint256 id, uint256 amount) public payable {
        require(id == 0, InvalidId());
        if (msg.value != 0) {
            if (token == WETH) {
                require(msg.value == amount, InvalidMsgVal());
                _safeTransferETH(WETH, amount); // wrap to WETH
            } else {
                require(msg.value == (token == address(0) ? amount : 0), InvalidMsgVal());
            }
        }
        if (token != address(0) && msg.value == 0) {
            safeTransferFrom(token, msg.sender, address(this), amount);
        }
        depositFor(token, 0, amount, address(this)); // transient storage tracker
    }

    function _useTransientBalance(address user, address token, uint256 id, uint256 amount)
        internal
        returns (bool credited)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x00, user)
            mstore(0x20, token)
            mstore(0x40, id)
            let slot := keccak256(0x00, 0x60)
            let bal := tload(slot)
            if iszero(lt(bal, amount)) {
                tstore(slot, sub(bal, amount))
                credited := 1
            }
            mstore(0x40, m)
        }
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        if (to == address(this)) {
            depositFor(address(0), 0, amount, to);
            return;
        }
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb)
                revert(0x1c, 0x04)
            }
        }
    }

    // ** RECEIVER & SWEEPER

    receive() external payable {}

    function sweep(address token, uint256 id, uint256 amount, address to) public payable {
        require(id == 0, InvalidId());
        if (token == address(0)) {
            _safeTransferETH(to, amount == 0 ? address(this).balance : amount);
        } else {
            safeTransfer(token, to, amount == 0 ? balanceOf(token) : amount);
        }
    }

    // ** WETH HELPERS

    function wrap(uint256 amount) public payable {
        amount = amount == 0 ? address(this).balance : amount;
        _safeTransferETH(WETH, amount);
        depositFor(WETH, 0, amount, address(this));
    }

    function unwrap(uint256 amount) public payable {
        unwrapETH(amount == 0 ? balanceOf(WETH) : amount);
    }

    // ** POOL HELPERS

    function _v2PoolFor(address tokenA, address tokenB) internal pure returns (address v2pool, bool zeroForOne) {
        unchecked {
            (address token0, address token1, bool zF1) = _sortTokens(tokenA, tokenB);
            zeroForOne = zF1;
            v2pool = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                V2_FACTORY,
                                keccak256(abi.encodePacked(token0, token1)),
                                V2_POOL_INIT_CODE_HASH
                            )
                        )
                    )
                )
            );
        }
    }

    function _v3PoolFor(address tokenA, address tokenB, uint24 fee)
        internal
        pure
        returns (address v3pool, bool zeroForOne)
    {
        (address token0, address token1, bool zF1) = _sortTokens(tokenA, tokenB);
        zeroForOne = zF1;
        v3pool = _computeV3pool(token0, token1, fee);
    }

    function _computeV3pool(address token0, address token1, uint24 fee) internal pure returns (address v3pool) {
        bytes32 salt = _hash(token0, token1, fee);
        assembly ("memory-safe") {
            mstore8(0x00, 0xff)
            mstore(0x35, V3_POOL_INIT_CODE_HASH)
            mstore(0x01, shl(96, V3_FACTORY))
            mstore(0x15, salt)
            v3pool := keccak256(0x00, 0x55)
            mstore(0x35, 0)
        }
    }

    function _hash(address value0, address value1, uint24 value2) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, value0)
            mstore(add(m, 0x20), value1)
            mstore(add(m, 0x40), value2)
            result := keccak256(m, 0x60)
        }
    }

    function _sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1, bool zeroForOne)
    {
        (token0, token1) = (zeroForOne = tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}

// ** ROBINHOOD CHAIN (4663) CONSTANTS
//
// Every address below was read off the chain rather than copied from a docs page:
// WETH agrees between SwapRouter02.WETH9() and UniswapV2Router02.WETH(); both
// init-code hashes were confirmed by CREATE2-reconstructing a live pool from its
// factory; the PoolManager is the one StateView.poolManager() points at.

address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

address constant V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
bytes32 constant V2_POOL_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
bytes32 constant V3_POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

interface IV2Pool {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
}

interface IV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct V4SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IV4PoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(V4PoolKey memory key, V4SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

using BalanceDeltaLibrary for int256;

library BalanceDeltaLibrary {
    function amount0(int256 balanceDelta) internal pure returns (int128 _amount0) {
        assembly ("memory-safe") {
            _amount0 := sar(128, balanceDelta)
        }
    }

    function amount1(int256 balanceDelta) internal pure returns (int128 _amount1) {
        assembly ("memory-safe") {
            _amount1 := signextend(15, balanceDelta)
        }
    }
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

error TransferFromFailed();

function safeTransferFrom(address token, address from, address to, uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x60, amount)
        mstore(0x40, to)
        mstore(0x2c, shl(96, from))
        mstore(0x0c, 0x23b872dd000000000000000000000000)
        let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x7939f424)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}

function balanceOf(address token) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, address())
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(mload(0x20), and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20)))
    }
}

// Low-level WETH helpers - we know WETH so we can make assumptions:

function wrapETH(address pool, uint256 amount) {
    assembly ("memory-safe") {
        pop(call(gas(), WETH, amount, codesize(), 0x00, codesize(), 0x00))
        mstore(0x14, pool)
        mstore(0x34, amount)
        mstore(0x00, 0xa9059cbb000000000000000000000000)
        pop(call(gas(), WETH, 0, 0x10, 0x44, codesize(), 0x00))
        mstore(0x34, 0)
    }
}

function unwrapETH(uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x00, 0x2e1a7d4d)
        mstore(0x20, amount)
        pop(call(gas(), WETH, 0, 0x1c, 0x24, codesize(), 0x00))
    }
}

// ** TRANSIENT DEPOSIT

function depositFor(address token, uint256 id, uint256 amount, address _for) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x00, _for)
        mstore(0x20, token)
        mstore(0x40, id)
        let slot := keccak256(0x00, 0x60)
        tstore(slot, add(tload(slot), amount))
        mstore(0x40, m)
    }
}
