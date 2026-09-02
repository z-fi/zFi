// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// zRouterLiteBase — Uniswap V2/V3/V4, Aerodrome and zAMM on Base (8453).
//
// A rewrite of the zRouter deployed at 0x0000000000404FECAf36E6184245475eE1254835,
// not a copy. Same venue coverage and the same swap selectors, but with the
// extensions that deployment predates: an owner, `trust`/`execute`, `snwap` over
// a SafeExecutor, EIP-2612 and Permit2 legs, and the transient callback lock that
// `execute` requires. `ensureAllowance` is owner-gated here; on that deployment it
// is callable by anyone.
//
// ERC6909 ids stay, unlike the Robinhood build: zAMM issues them, so `deposit`,
// `sweep` and the transient balances all have to address them.
//
// `swapV4Router` is not carried over. It forwarded arbitrary calldata to a v4
// periphery router, which is `execute` with no trust check and no lock.
contract zRouterLiteBase {
    error BadSwap();
    error Expired();
    error Slippage();
    error Unauthorized();
    error InvalidMsgVal();
    error ETHTransferFailed();
    error SnwapSlippage(address token, uint256 received, uint256 minimum);

    event OwnershipTransferred(address indexed from, address indexed to);

    SafeExecutor public immutable safeExecutor;

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, Expired());
        _;
    }

    /// @dev `tx.origin`, not `msg.sender`: deployed through the CREATE2 factory,
    /// `msg.sender` is the factory.
    constructor() payable {
        safeExecutor = new SafeExecutor();
        emit OwnershipTransferred(address(0), _owner = tx.origin);
    }

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
                    amountIn = ethIn ? msg.value : _selfAmount(tokenIn);
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
            depositFor(tokenOut, 0, amountOut, to);
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
                swapAmount = ethIn ? msg.value : _selfAmount(tokenIn);
                if (swapAmount == 0) revert BadSwap();
            }
            (int256 a0, int256 a1) = IV3Pool(pool)
                .swap(
                    ethOut ? address(this) : to,
                    zeroForOne,
                    exactOut ? -(int256(swapAmount)) : int256(swapAmount),
                    sqrtPriceLimitX96,
                    abi.encodePacked(ethIn, ethOut, false, msg.sender, tokenIn, tokenOut, to, swapFee)
                );

            if (amountLimit != 0) {
                if (exactOut) require(uint256(zeroForOne ? a0 : a1) <= amountLimit, Slippage());
                else require(uint256(-(zeroForOne ? a1 : a0)) >= amountLimit, Slippage());
            }

            // An exact-out swap can come up short: the pool stops at the price
            // limit or runs out of liquidity and fills only part of the request.
            // `amountLimit` bounds the INPUT on this branch, so without this the
            // caller pays up to their maximum and silently receives less than the
            // amount they asked for.
            if (exactOut) {
                require(uint256(-(zeroForOne ? a1 : a0)) >= swapAmount, Slippage());
            }

            (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
            amountIn = dIn >= 0 ? uint256(dIn) : uint256(-dIn);
            amountOut = dOut <= 0 ? uint256(-dOut) : uint256(dOut);

            if (ethIn) {
                if ((swapAmount = address(this).balance) != 0 && to != address(this)) {
                    _safeTransferETH(msg.sender, swapAmount);
                }
            }
            if (!ethOut) {
                depositFor(tokenOut, 0, amountOut, to);
            }
        }
    }

    /// @dev `uniswapV3SwapCallback`. The lock refuses it outright while `execute`
    /// has an arbitrary call outstanding; otherwise the caller must be the pool
    /// re-derived from the callback data.
    fallback() external payable {
        assembly ("memory-safe") {
            if gt(tload(0x00), 0) { revert(0, 0) }
        }
        unchecked {
            int256 amount0Delta;
            int256 amount1Delta;
            bool ethIn;
            bool ethOut;
            bool isAeroCL;
            address payer;
            address tokenIn;
            address tokenOut;
            address to;
            uint24 feeOrSpacing;
            assembly ("memory-safe") {
                amount0Delta := calldataload(0x4)
                amount1Delta := calldataload(0x24)
                ethIn := byte(0, calldataload(0x84))
                ethOut := byte(0, calldataload(add(0x84, 1)))
                isAeroCL := byte(0, calldataload(add(0x84, 2)))
                payer := shr(96, calldataload(add(0x84, 3)))
                tokenIn := shr(96, calldataload(add(0x84, 23)))
                tokenOut := shr(96, calldataload(add(0x84, 43)))
                to := shr(96, calldataload(add(0x84, 63)))
                feeOrSpacing := and(shr(232, calldataload(add(0x84, 83))), 0xFFFFFF)
            }
            require(amount0Delta != 0 || amount1Delta != 0, BadSwap());
            (address pool, bool zeroForOne) = isAeroCL
                ? _aeroCLPoolFor(tokenIn, tokenOut, int24(feeOrSpacing))
                : _v3PoolFor(tokenIn, tokenOut, feeOrSpacing);
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
            swapAmount = tokenIn == address(0) ? msg.value : _selfAmount(tokenIn);
            if (swapAmount == 0) revert BadSwap();
        }
        (amountIn, amountOut) = abi.decode(
            IV4PoolManager(V4_POOL_MANAGER)
                .unlock(
                    abi.encode(msg.sender, to, exactOut, swapFee, tickSpace, tokenIn, tokenOut, swapAmount, amountLimit)
                ),
            (uint256, uint256)
        );
        depositFor(tokenOut, 0, amountOut, to);
    }

    /// @dev V4 swap callback. Hookless pools only.
    function unlockCallback(bytes calldata callbackData) public payable returns (bytes memory result) {
        require(msg.sender == V4_POOL_MANAGER, Unauthorized());

        assembly ("memory-safe") {
            if gt(tload(0x00), 0) { revert(0, 0) }
        }

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
                    safeTransfer(tokenIn, msg.sender, amountIn);
                }
            } else if (!ethIn) {
                safeTransferFrom(tokenIn, payer, msg.sender, amountIn);
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

    // ** AERODROME (V2-shaped, volatile or stable)

    /// @dev Exact-in only. The stable curve has no closed-form inverse, so an
    /// exact-out would have to be solved by search — the quoter does that off to
    /// the side and sends the solved input here.
    function swapAero(
        address to,
        bool stable,
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

        (address pool, bool zeroForOne) = _aeroPoolFor(tokenIn, tokenOut, stable);

        amountIn = swapAmount;
        if (amountIn == 0) {
            amountIn = ethIn ? msg.value : _selfAmount(tokenIn);
            if (amountIn == 0) revert BadSwap();
        }
        amountOut = IAeroPool(pool).getAmountOut(amountIn, tokenIn);
        require(amountLimit == 0 || amountOut >= amountLimit, Slippage());

        if (!_useTransientBalance(pool, tokenIn, 0, amountIn)) {
            if (_useTransientBalance(address(this), tokenIn, 0, amountIn)) {
                safeTransfer(tokenIn, pool, amountIn);
            } else if (ethIn) {
                wrapETH(pool, amountIn);
                if (to != address(this) && msg.value > amountIn) {
                    _safeTransferETH(msg.sender, msg.value - amountIn);
                }
            } else {
                safeTransferFrom(tokenIn, msg.sender, pool, amountIn);
            }
        }

        if (zeroForOne) IAeroPool(pool).swap(0, amountOut, ethOut ? address(this) : to, "");
        else IAeroPool(pool).swap(amountOut, 0, ethOut ? address(this) : to, "");

        if (ethOut) {
            unwrapETH(amountOut);
            _safeTransferETH(to, amountOut);
        } else {
            depositFor(tokenOut, 0, amountOut, to);
        }
    }

    // ** AERODROME SLIPSTREAM (concentrated liquidity)

    /// @dev A v3 fork keyed by tick spacing rather than fee tier, and it calls
    /// back with the same `uniswapV3SwapCallback` selector — which is why the
    /// callback data carries a flag saying which factory to re-derive against.
    function swapAeroCL(
        address to,
        bool exactOut,
        int24 tickSpacing,
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

        (address pool, bool zeroForOne) = _aeroCLPoolFor(tokenIn, tokenOut, tickSpacing);

        unchecked {
            if (!exactOut && swapAmount == 0) {
                swapAmount = ethIn ? msg.value : _selfAmount(tokenIn);
                if (swapAmount == 0) revert BadSwap();
            }
            (int256 a0, int256 a1) = IV3Pool(pool)
                .swap(
                    ethOut ? address(this) : to,
                    zeroForOne,
                    exactOut ? -(int256(swapAmount)) : int256(swapAmount),
                    zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
                    abi.encodePacked(
                        ethIn, ethOut, true, msg.sender, tokenIn, tokenOut, to, uint24(tickSpacing)
                    )
                );

            if (amountLimit != 0) {
                if (exactOut) require(uint256(zeroForOne ? a0 : a1) <= amountLimit, Slippage());
                else require(uint256(-(zeroForOne ? a1 : a0)) >= amountLimit, Slippage());
            }

            // An exact-out swap can come up short: the pool stops at the price
            // limit or runs out of liquidity and fills only part of the request.
            // `amountLimit` bounds the INPUT on this branch, so without this the
            // caller pays up to their maximum and silently receives less than the
            // amount they asked for.
            if (exactOut) {
                require(uint256(-(zeroForOne ? a1 : a0)) >= swapAmount, Slippage());
            }

            (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
            amountIn = dIn >= 0 ? uint256(dIn) : uint256(-dIn);
            amountOut = dOut <= 0 ? uint256(-dOut) : uint256(dOut);

            if (ethIn) {
                if ((swapAmount = address(this).balance) != 0 && to != address(this)) {
                    _safeTransferETH(msg.sender, swapAmount);
                }
            }
            if (!ethOut) depositFor(tokenOut, 0, amountOut, to);
        }
    }

    // ** ZAMM

    /// @dev zAMM settles to `to` itself and takes payment from this contract, so
    /// the input is pulled in first. `idIn`/`idOut` are ERC6909 ids; zero means
    /// the ERC20 side of the same address.
    function swapVZ(
        address to,
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        (address token0, address token1, bool zeroForOne) = _sortTokens(tokenIn, tokenOut);
        (uint256 id0, uint256 id1) = tokenIn == token0 ? (idIn, idOut) : (idOut, idIn);
        PoolKey memory key = PoolKey(id0, id1, token0, token1, feeOrHook);

        bool ethIn = tokenIn == address(0);
        uint256 pull = !exactOut ? swapAmount : amountLimit;

        if (!ethIn && !_useTransientBalance(address(this), tokenIn, idIn, pull)) {
            if (idIn == 0) safeTransferFrom(tokenIn, msg.sender, address(this), pull);
            else IERC6909(tokenIn).transferFrom(msg.sender, address(this), idIn, pull);
        }

        // zAMM settles by pulling from this contract, so it needs standing
        // authority. Granted on demand rather than primed by the owner: otherwise
        // every zAMM route the quoter picks reverts until someone remembers to
        // call `ensureAllowance` for that token.
        if (!ethIn) {
            if (idIn == 0) {
                if (allowance(tokenIn, address(this), ZAMM) < pull) {
                    safeApprove(tokenIn, ZAMM, type(uint256).max);
                }
            } else {
                IERC6909(tokenIn).setOperator(ZAMM, true);
            }
        }

        uint256 result = exactOut
            ? IZAMM(ZAMM).swapExactOut{value: ethIn ? amountLimit : 0}(
                key, swapAmount, amountLimit, zeroForOne, to, deadline
            )
            : IZAMM(ZAMM).swapExactIn{value: ethIn ? swapAmount : 0}(
                key, swapAmount, amountLimit, zeroForOne, to, deadline
            );

        (amountIn, amountOut) = exactOut ? (result, swapAmount) : (swapAmount, result);

        // Exact-out overpays by construction; hand the remainder back. The third
        // arm is not optional: with `idIn` set, the overpayment is an ERC6909
        // balance, and reading `balanceOf(address)` on a pure-6909 issuer returns
        // nothing — the helper reports zero and the refund is silently skipped,
        // stranding the remainder for the next passer-by to sweep.
        if (exactOut && to != address(this)) {
            uint256 refund;
            if (ethIn) {
                refund = address(this).balance;
                if (refund != 0) _safeTransferETH(msg.sender, refund);
            } else if (idIn == 0) {
                refund = balanceOf(tokenIn);
                if (refund != 0) safeTransfer(tokenIn, msg.sender, refund);
            } else {
                refund = IERC6909(tokenIn).balanceOf(address(this), idIn);
                if (refund != 0) IERC6909(tokenIn).transfer(msg.sender, idIn, refund);
            }
        }
        depositFor(tokenOut, idOut, amountOut, to);
    }

    /// @dev For use after `deposit` or a swap leg has funded this contract.
    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) public payable returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        return IZAMM(ZAMM)
            .addLiquidity{value: poolKey.token0 == address(0) ? amount0Desired : 0}(
                poolKey, amount0Desired, amount1Desired, amount0Min, amount1Min, to, deadline
            );
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

    /// @dev Four total cases, one per funding source. Ether must actually be
    /// attached to be credited — the deployed router credits a bare
    /// `deposit(address(0), 0, n)` with ether it never received.
    function deposit(address token, uint256 id, uint256 amount) public payable {
        if (token == address(0)) {
            require(id == 0 && msg.value == amount, InvalidMsgVal());
        } else if (token == WETH && msg.value != 0) {
            require(id == 0 && msg.value == amount, InvalidMsgVal());
            _safeTransferETH(WETH, amount); // wrap
        } else {
            require(msg.value == 0, InvalidMsgVal());
            if (id == 0) safeTransferFrom(token, msg.sender, address(this), amount);
            else IERC6909(token).transferFrom(msg.sender, address(this), id, amount);
        }
        depositFor(token, id, amount, address(this));
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

    /// @dev What a previous leg actually credited, falling back to the raw balance
    /// when there is no credit. `swapAmount == 0` means "spend what the last leg
    /// produced"; reading the balance for that is wrong, because anyone can send
    /// the router a single wei and the leg then tries to spend one wei more than
    /// it was credited — which either pulls a second full payment from the caller
    /// or reverts the whole chain.
    function _selfAmount(address token) internal view returns (uint256 amount) {
        amount = _creditOf(address(this), token);
        if (amount == 0) amount = balanceOf(token);
    }

    function _creditOf(address user, address token) internal view returns (uint256 bal) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x00, user)
            mstore(0x20, token)
            mstore(0x40, 0)
            bal := tload(keccak256(0x00, 0x60))
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
        if (token == address(0)) {
            _safeTransferETH(to, amount == 0 ? address(this).balance : amount);
        } else if (id == 0) {
            safeTransfer(token, to, amount == 0 ? balanceOf(token) : amount);
        } else {
            IERC6909(token).transfer(to, id, amount == 0 ? IERC6909(token).balanceOf(address(this), id) : amount);
        }
    }

    // ** WETH HELPERS

    function wrap(uint256 amount) public payable {
        amount = amount == 0 ? address(this).balance : amount;
        _safeTransferETH(WETH, amount);
        depositFor(WETH, 0, amount, address(this));
    }

    /// @dev Consumes the WETH credit and re-credits the ether, so a chained
    /// WETH -> ETH leg hands the next leg something to spend. Without this the
    /// WETH credit outlives the WETH and the ether arrives uncredited.
    function unwrap(uint256 amount) public payable {
        if (amount == 0) amount = _selfAmount(WETH);
        _useTransientBalance(address(this), WETH, 0, amount);
        unwrapETH(amount);
        depositFor(address(0), 0, amount, address(this));
    }

    // ** PERMIT HELPERS
    //
    // Both are meant to be a `multicall` leg: sign, then permit and swap in one
    // transaction. `multicall` delegatecalls, so `msg.sender` here is the signer.

    function permit(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public payable {
        IERC2612(token).permit(msg.sender, address(this), value, deadline, v, r, s);
    }

    /// @dev SignatureTransfer, not AllowanceTransfer: nothing is left approved.
    /// The pull is credited transiently for the next leg to spend.
    function permit2TransferFrom(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) public payable {
        IPermit2(PERMIT2)
            .permitTransferFrom(
                IPermit2.PermitTransferFrom({
                    permitted: IPermit2.TokenPermissions({token: token, amount: amount}),
                    nonce: nonce,
                    deadline: deadline
                }),
                IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
                msg.sender,
                signature
            );
        depositFor(token, 0, amount, address(this));
    }

    // ** APPROVALS

    function ensureAllowance(address token, bool is6909, address to) public payable onlyOwner {
        if (is6909) IERC6909(token).setOperator(to, true);
        else safeApprove(token, to, type(uint256).max);
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

    /// @dev The `mstore(0x35, ...)` pair overlaps the free memory pointer at 0x40
    /// and looks like it corrupts it. It does not: the pointer is under 2**88, so
    /// it lives entirely in bytes 0x55-0x5f, which neither store touches.
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

    /// @dev Aerodrome pools are minimal-proxy clones, so this hashes the clone
    /// initcode rather than a pool init-code hash. Salt is packed for the classic
    /// factory and abi-encoded for Slipstream — the two differ, deliberately.
    function _aeroPoolFor(address tokenA, address tokenB, bool stable)
        internal
        pure
        returns (address pool, bool zeroForOne)
    {
        (address token0, address token1, bool zF1) = _sortTokens(tokenA, tokenB);
        zeroForOne = zF1;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, stable));
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x38), AERO_FACTORY)
            mstore(add(ptr, 0x24), 0x5af43d82803e903d91602b57fd5bf3ff)
            mstore(add(ptr, 0x14), AERO_IMPLEMENTATION)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73)
            mstore(add(ptr, 0x58), salt)
            mstore(add(ptr, 0x78), keccak256(add(ptr, 0x0c), 0x37))
            pool := keccak256(add(ptr, 0x43), 0x55)
        }
    }

    function _aeroCLPoolFor(address tokenA, address tokenB, int24 tickSpacing)
        internal
        pure
        returns (address pool, bool zeroForOne)
    {
        (address token0, address token1, bool zF1) = _sortTokens(tokenA, tokenB);
        zeroForOne = zF1;
        bytes32 salt = keccak256(abi.encode(token0, token1, tickSpacing));
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, AERO_CL_IMPLEMENTATION))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf3ff00000000000000000000000000000000)
            mstore(add(ptr, 0x38), shl(0x60, AERO_CL_FACTORY))
            mstore(add(ptr, 0x4c), salt)
            mstore(add(ptr, 0x6c), keccak256(ptr, 0x37))
            pool := keccak256(add(ptr, 0x37), 0x55)
        }
    }

    function _sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1, bool zeroForOne)
    {
        (token0, token1) = (zeroForOne = tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // ** EXECUTE EXTENSIONS

    address _owner;

    modifier onlyOwner() {
        require(msg.sender == _owner, Unauthorized());
        _;
    }

    mapping(address target => bool) _isTrustedForCall;

    function owner() public view returns (address) {
        return _owner;
    }

    function isTrustedForCall(address target) public view returns (bool) {
        return _isTrustedForCall[target];
    }

    function trust(address target, bool ok) public payable onlyOwner {
        _isTrustedForCall[target] = ok;
    }

    function transferOwnership(address newOwner) public payable onlyOwner {
        emit OwnershipTransferred(msg.sender, _owner = newOwner);
    }

    /// @dev Calls out AS the router, so it is both trust-gated and wrapped in the
    /// callback lock — otherwise the target could drive a swap naming someone
    /// else as `payer`.
    function execute(address target, uint256 value, bytes calldata data) public payable returns (bytes memory result) {
        require(_isTrustedForCall[target], Unauthorized());
        assembly ("memory-safe") {
            tstore(0x00, 1) // lock callback (V3/V4)
            result := mload(0x40)
            calldatacopy(result, data.offset, data.length)
            if iszero(call(gas(), target, value, result, data.length, codesize(), 0x00)) {
                returndatacopy(result, 0x00, returndatasize())
                revert(result, returndatasize())
            }
            mstore(result, returndatasize())
            let o := add(result, 0x20)
            returndatacopy(o, 0x00, returndatasize())
            mstore(0x40, add(o, returndatasize()))
            tstore(0x00, 0) // unlock callback
        }
    }

    // ** SNWAP - GENERIC EXECUTOR

    /// @dev Permissionless, unlike `execute`: the call is made by `safeExecutor`,
    /// which holds no approvals and no balances, so an arbitrary `executor` gains
    /// nothing. Payment is a before/after balance delta on `recipient` — only
    /// what lands is paid for.
    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) public payable returns (uint256 amountOut) {
        uint256 initialBalance = tokenOut == address(0) ? recipient.balance : balanceOfAccount(tokenOut, recipient);

        if (tokenIn != address(0)) {
            if (amountIn != 0) {
                safeTransferFrom(tokenIn, msg.sender, executor, amountIn);
            } else {
                unchecked {
                    uint256 bal = balanceOf(tokenIn);
                    if (bal > 1) safeTransfer(tokenIn, executor, bal - 1);
                }
            }
        }

        safeExecutor.execute{value: msg.value}(executor, executorData);

        uint256 finalBalance = tokenOut == address(0) ? recipient.balance : balanceOfAccount(tokenOut, recipient);
        amountOut = finalBalance - initialBalance;
        if (amountOut < amountOutMin) revert SnwapSlippage(tokenOut, amountOut, amountOutMin);
        if (recipient == address(this)) depositFor(tokenOut, 0, amountOut, address(this));
    }

    function snwapMulti(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address[] calldata tokensOut,
        uint256[] calldata amountsOutMin,
        address executor,
        bytes calldata executorData
    ) public payable returns (uint256[] memory amountsOut) {
        uint256 len = tokensOut.length;
        uint256[] memory initBals = new uint256[](len);
        for (uint256 i; i != len; ++i) {
            initBals[i] = tokensOut[i] == address(0) ? recipient.balance : balanceOfAccount(tokensOut[i], recipient);
        }

        if (tokenIn != address(0)) {
            if (amountIn != 0) {
                safeTransferFrom(tokenIn, msg.sender, executor, amountIn);
            } else {
                unchecked {
                    uint256 bal = balanceOf(tokenIn);
                    if (bal > 1) safeTransfer(tokenIn, executor, bal - 1);
                }
            }
        }

        safeExecutor.execute{value: msg.value}(executor, executorData);

        amountsOut = new uint256[](len);
        for (uint256 i; i != len; ++i) {
            uint256 finalBal =
                tokensOut[i] == address(0) ? recipient.balance : balanceOfAccount(tokensOut[i], recipient);
            amountsOut[i] = finalBal - initBals[i];
            if (amountsOut[i] < amountsOutMin[i]) {
                revert SnwapSlippage(tokensOut[i], amountsOut[i], amountsOutMin[i]);
            }
            if (recipient == address(this)) {
                depositFor(tokensOut[i], 0, amountsOut[i], address(this));
            }
        }
    }
}

// ** BASE (8453)
//
// Every derivation below was checked against its factory's own registry rather
// than trusted: `getPair`, `getPool` and the two Aerodrome clone factories all
// return the address these constants rebuild.

address constant WETH = 0x4200000000000000000000000000000000000006;

address constant V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
bytes32 constant V2_POOL_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

address constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
bytes32 constant V3_POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

address constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

address constant ZAMM = 0x000000000000040470635EB91b7CE4D132D616eD;

// Aerodrome deploys pools as minimal-proxy clones, so the pool address is a
// CREATE2 of the clone initcode rather than of the pool's own. Both
// implementations were read back off their factories.
address constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
address constant AERO_IMPLEMENTATION = 0xA4e46b4f701c62e14DF11B48dCe76A7d793CD6d7;
address constant AERO_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
address constant AERO_CL_IMPLEMENTATION = 0xeC8E5342B19977B4eF8892e02D8DAEcfa1315831;


uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

interface IV2Pool {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
}

interface IAeroPool {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook;
}

interface IZAMM {
    function swapExactIn(PoolKey calldata, uint256, uint256, bool, address, uint256)
        external
        payable
        returns (uint256);
    function swapExactOut(PoolKey calldata, uint256, uint256, bool, address, uint256)
        external
        payable
        returns (uint256);
    function addLiquidity(PoolKey calldata, uint256, uint256, uint256, uint256, address, uint256)
        external
        payable
        returns (uint256, uint256, uint256);
}

interface IERC6909 {
    function setOperator(address spender, bool approved) external returns (bool);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool);
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

// Solady:

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

function allowance(address token, address owner, address spender) view returns (uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x40, spender)
        mstore(0x2c, shl(96, owner))
        mstore(0x0c, 0xdd62ed3e000000000000000000000000)
        amount := mul(mload(0x20), and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x1c, 0x44, 0x20, 0x20)))
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

function balanceOfAccount(address token, address account) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, account)
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(mload(0x20), and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20)))
    }
}

// WETH is known, so these skip the return-value checks:

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

// ** PERMIT HELPERS

address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

interface IERC2612 {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
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

/// @dev Holds no approvals and no balances, so arbitrary calls made through it
/// carry no authority. Modified from 0xAC4c6e212A361c968F1725b4d055b47E63F80b75.
contract SafeExecutor {
    function execute(address target, bytes calldata data) public payable {
        assembly ("memory-safe") {
            let m := mload(0x40)
            calldatacopy(m, data.offset, data.length)
            if iszero(call(gas(), target, callvalue(), m, data.length, codesize(), 0x00)) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }
    }
}
