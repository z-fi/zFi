// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// zRouterLiteRobinhood — Uniswap V2/V3/V4 and the Deepstate CLOB on Robinhood Chain (4663).
//
// Two divergences from mainnet zRouter: `deadline == type(uint256).max` means
// "no deadline" rather than selecting Sushi, and `deposit`/`sweep`/
// `ensureAllowance` drop the ERC6909 argument. zQuoterRobinhood builds calldata
// for these signatures, so the two ship as a pair.
contract zRouterLiteRobinhood {
    error BadSwap();
    error Expired();
    error Slippage();
    error PermitFailed();
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

    /// @dev Only the seed is constant; `_owner` is storage and transferrable.
    /// Through CREATE3 neither `msg.sender` (the factory proxy) nor `tx.origin`
    /// (the deploy key) is the right initial owner.
    constructor() payable {
        safeExecutor = new SafeExecutor();
        emit OwnershipTransferred(address(0), _owner = INITIAL_OWNER);
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
        // No AMM leg runs mid-fill: the ether-funding and refund paths below
        // spend raw router balance, which belongs to the filling caller then.
        _requireBookIdle();
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
            if (!_useTransientBalance(pool, tokenIn, amountIn)) {
                if (_useTransientBalance(address(this), tokenIn, amountIn)) {
                    safeTransfer(tokenIn, pool, amountIn);
                } else if (ethIn) {
                    wrapETH(pool, amountIn);
                } else {
                    safeTransferFrom(tokenIn, msg.sender, pool, amountIn);
                }
            }

            // Refund whichever way the leg was funded, as v3 and v4 do: a
            // credit can pay for it, leaving msg.value entirely unspent.
            if (ethIn && to != address(this) && address(this).balance != 0) {
                _safeTransferETH(msg.sender, address(this).balance);
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
            depositFor(tokenOut, amountOut, to);
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
        _requireBookIdle();
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
                    abi.encodePacked(ethIn, ethOut, msg.sender, tokenIn, tokenOut, to, swapFee)
                );

            if (amountLimit != 0) {
                if (exactOut) require(uint256(zeroForOne ? a0 : a1) <= amountLimit, Slippage());
                else require(uint256(-(zeroForOne ? a1 : a0)) >= amountLimit, Slippage());
            }

            // `amountLimit` bounds the INPUT here, so a short fill would let
            // the caller pay their maximum and receive less than they asked.
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
                depositFor(tokenOut, amountOut, to);
            }
        }
    }

    /// @dev `uniswapV3SwapCallback`. The lock refuses it outright while `execute`
    /// has an arbitrary call outstanding or the book holds control (a direct
    /// pool.swap naming this router could otherwise spend its mid-fill balance);
    /// otherwise the caller must be the pool re-derived from the callback data.
    fallback() external payable {
        assembly ("memory-safe") {
            if gt(or(tload(0x00), tload(0x01)), 0) { revert(0, 0) }
        }
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

            if (_useTransientBalance(address(this), tokenIn, amountRequired)) {
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
        _requireBookIdle();
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
        depositFor(tokenOut, amountOut, to);
    }

    /// @dev V4 swap callback. Hookless pools only.
    function unlockCallback(bytes calldata callbackData) public payable returns (bytes memory result) {
        require(msg.sender == V4_POOL_MANAGER, Unauthorized());

        assembly ("memory-safe") {
            if gt(or(tload(0x00), tload(0x01)), 0) { revert(0, 0) }
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

            if (_useTransientBalance(address(this), tokenIn, amountIn)) {
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

    // ** DEEPSTATE (onchain CLOB)

    /// @notice Take against the Deepstate order book as a router-owned taker.
    /// @dev A limit book, not a curve: the caller names the book, the packed
    /// `price || quantity` order and a maximum input, and gets back what filled.
    /// Nothing rests — a resting order would be owned by this contract and
    /// nobody could cancel it. Both bounds are measured balance deltas, since
    /// `fill` returns only a resting-order handle.
    ///
    /// `token0`/`token1` must be sorted. A bid buys token0 with token1, an ask
    /// sells token0 for token1.
    function swapDeep(
        address to,
        address token0,
        address token1,
        uint256 epoch,
        bytes32 order,
        bool isBid,
        uint256 amountInMax,
        uint256 amountOutMin,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        (address tokenIn, address tokenOut) = isBid ? (token1, token0) : (token0, token1);
        bool ethIn = tokenIn == address(0);

        // Measured, not assumed: a fee-on-transfer `tokenIn` delivers less than
        // `amountInMax`, and refunding the difference would pay it out of
        // another leg's balance.
        uint256 received;

        // A call arriving while an outer fill holds the lock pays only for
        // itself: the credits sitting here mid-settlement belong to the outer
        // caller, not to whoever the book's token callbacks hand control.
        bool nested;
        assembly ("memory-safe") {
            nested := gt(tload(0x01), 0)
        }

        if (ethIn) {
            // Ether must be paid for too, or the fill spends whatever balance
            // is lying here and the attached value is left for `sweep`.
            if (nested || !_useTransientBalance(address(this), address(0), amountInMax)) {
                _claimMsgValue(amountInMax);
            }
            received = amountInMax;
        } else {
            if (!nested && _useTransientBalance(address(this), tokenIn, amountInMax)) {
                received = amountInMax; // already held; the credit paid for it
            } else {
                uint256 held = balanceOf(tokenIn);
                safeTransferFrom(tokenIn, msg.sender, address(this), amountInMax);
                unchecked {
                    received = balanceOf(tokenIn) - held;
                }
            }
            // Deepstate pulls from the taker, so it needs an allowance. Lazy,
            // so a book for an unapproved token still works. Reset first, or a
            // token refusing non-zero-to-non-zero approves bricks this book.
            if (allowance(tokenIn, address(this), DEEPSTATE) < amountInMax) {
                safeApprove(tokenIn, DEEPSTATE, 0);
                safeApprove(tokenIn, DEEPSTATE, type(uint256).max);
            }
        }

        uint256 inBefore = ethIn ? address(this).balance : balanceOf(tokenIn);
        uint256 outBefore = tokenOut == address(0) ? address(this).balance : balanceOf(tokenOut);

        // Nothing may move this contract's balances while the book has control:
        // a transfer callback during settlement could drain the router and widen
        // the delta the caller is billed for. Depth-counted, so a nested
        // `swapDeep` cannot clear it on its way out.
        uint256 lock;
        assembly ("memory-safe") {
            lock := tload(0x01)
            tstore(0x01, add(lock, 1))
        }

        IDeepstate(DEEPSTATE)
            .fill{value: ethIn ? amountInMax : 0}(
                IDeepstate.FillParams(token0, token1, epoch, order, isBid, true, false)
            );

        assembly ("memory-safe") {
            tstore(0x01, lock)
        }

        unchecked {
            amountIn = inBefore - (ethIn ? address(this).balance : balanceOf(tokenIn));
            amountOut = (tokenOut == address(0) ? address(this).balance : balanceOf(tokenOut)) - outBefore;
        }

        // Against `received`, not `amountInMax`: a fee-on-transfer token
        // delivers less than was pulled, the book can still draw on other
        // router-held balance up to its allowance, and the unchecked refund
        // below must never wrap.
        require(amountIn <= received, Slippage());
        require(amountOut >= amountOutMin, Slippage());

        // Hand back what the book did not take; a chained leg keeps it as a
        // credit so the next leg can spend it.
        unchecked {
            uint256 refund = received - amountIn;
            if (refund != 0) {
                if (to == address(this)) depositFor(tokenIn, refund, address(this));
                else if (ethIn) _safeTransferETH(msg.sender, refund);
                else safeTransfer(tokenIn, msg.sender, refund);
            }
        }

        if (tokenOut == address(0)) {
            _safeTransferETH(to, amountOut);
        } else {
            if (to != address(this)) safeTransfer(tokenOut, to, amountOut);
            depositFor(tokenOut, amountOut, to);
        }
    }

    // ** MULTISWAP HELPER

    function multicall(bytes[] calldata data) public payable returns (bytes[] memory results) {
        // Open a fresh msg.value tally for this batch. Transient storage lives
        // for the whole transaction, so without this a second router call in
        // the same transaction (a batcher, a 4337 wallet) would be charged for
        // ether the first call already claimed. Depth-counted for nesting.
        assembly ("memory-safe") {
            let d := tload(0x03)
            if iszero(d) { tstore(0x02, 0) }
            tstore(0x03, add(d, 1))
        }
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
        assembly ("memory-safe") {
            tstore(0x03, sub(tload(0x03), 1))
        }
    }

    // ** TRANSIENT STORAGE

    /// @dev One case per funding source. Ether must actually be attached to be
    /// credited; mainnet would credit a bare `deposit(address(0), n)`.
    function deposit(address token, uint256 amount) public payable {
        if (token == address(0)) {
            _claimMsgValue(amount);
        } else if (token == WETH && msg.value != 0) {
            _claimMsgValue(amount);
            _safeTransferETH(WETH, amount); // wrap
        } else {
            require(msg.value == 0, InvalidMsgVal());
            safeTransferFrom(token, msg.sender, address(this), amount);
        }
        depositFor(token, amount, address(this));
    }

    /// @dev Shut while Deepstate holds control. `swapDeep` bills the caller a
    /// measured balance delta, so every path that can move this contract's
    /// balances must check this — the outright drains (`sweep`, `snwap`), and
    /// equally the swap and wrap legs, which spend raw router balance that
    /// belongs to the filling caller for the length of the fill.
    function _requireBookIdle() internal view {
        assembly ("memory-safe") {
            if gt(tload(0x01), 0) { revert(0, 0) }
        }
    }

    /// @dev `multicall` delegatecalls, so every leg sees the same `msg.value`.
    /// Tally what has been claimed against it, or N legs each mint a credit for
    /// ether that arrived once. The tally is read only inside a multicall: a
    /// top-level entry point claims at most once against its own `msg.value`,
    /// and reading a stale tally from an earlier call in the same transaction
    /// would spuriously starve it.
    function _claimMsgValue(uint256 amount) internal {
        uint256 used;
        bool batched;
        assembly ("memory-safe") {
            batched := gt(tload(0x03), 0)
            if batched { used := tload(0x02) }
        }
        used += amount;
        // Inside a batch a later leg may still claim the rest, so only the
        // total is capped. Alone there is no later leg, and an overpayment
        // would sit here for the permissionless `sweep` to take.
        require(batched ? used <= msg.value : used == msg.value, InvalidMsgVal());
        assembly ("memory-safe") {
            tstore(0x02, used)
        }
    }

    /// @dev Keyed on (owner, token) — two words, so this stays in scratch space.
    function _useTransientBalance(address user, address token, uint256 amount) internal returns (bool credited) {
        assembly ("memory-safe") {
            mstore(0x00, user)
            mstore(0x20, token)
            let slot := keccak256(0x00, 0x40)
            let bal := tload(slot)
            if iszero(lt(bal, amount)) {
                tstore(slot, sub(bal, amount))
                credited := 1
            }
        }
    }

    /// @dev What the previous leg credited, falling back to the raw balance.
    /// `swapAmount == 0` means "spend what the last leg produced" — reading the
    /// balance instead lets anyone send one wei and break the chain.
    function _selfAmount(address token) internal view returns (uint256 amount) {
        amount = _creditOf(address(this), token);
        if (amount == 0) amount = balanceOf(token);
    }

    function _creditOf(address user, address token) internal view returns (uint256 bal) {
        assembly ("memory-safe") {
            mstore(0x00, user)
            mstore(0x20, token)
            bal := tload(keccak256(0x00, 0x40))
        }
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        if (to == address(this)) {
            depositFor(address(0), amount, to);
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

    function sweep(address token, uint256 amount, address to) public payable {
        _requireBookIdle();
        if (token == address(0)) {
            _safeTransferETH(to, amount == 0 ? address(this).balance : amount);
        } else {
            safeTransfer(token, to, amount == 0 ? balanceOf(token) : amount);
        }
    }

    // ** WETH HELPERS

    function wrap(uint256 amount) public payable {
        _requireBookIdle();
        amount = amount == 0 ? address(this).balance : amount;
        _safeTransferETH(WETH, amount);
        depositFor(WETH, amount, address(this));
    }

    /// @dev Consumes the WETH credit and re-credits the ether, so a chained
    /// WETH -> ETH leg hands the next leg something to spend.
    function unwrap(uint256 amount) public payable {
        _requireBookIdle();
        if (amount == 0) amount = _selfAmount(WETH);
        _useTransientBalance(address(this), WETH, amount);
        unwrapETH(amount);
        depositFor(address(0), amount, address(this));
    }

    // ** PERMIT HELPERS
    //
    // Both are meant to be a `multicall` leg: sign, then permit and swap in one
    // transaction. `multicall` delegatecalls, so `msg.sender` here is the signer.

    /// @dev Tolerates a burnt nonce. The signature is public in the mempool, so
    /// anyone can submit it standalone; the permit then reverts and would take
    /// the whole multicall with it, even though the allowance it wanted is
    /// already in place. Only a genuinely insufficient allowance fails here.
    function permit(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public payable {
        try IERC2612(token).permit(msg.sender, address(this), value, deadline, v, r, s) {}
        catch {
            require(allowance(token, msg.sender, address(this)) >= value, PermitFailed());
        }
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
        depositFor(token, amount, address(this));
    }

    // ** APPROVALS

    function ensureAllowance(address token, address to) public payable onlyOwner {
        safeApprove(token, to, type(uint256).max);
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

    /// @dev Calls out AS the router, so it is trust-gated and lock-wrapped;
    /// otherwise the target could drive a swap naming someone else as `payer`.
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

    /// @dev Permissionless, unlike `execute`: `safeExecutor` holds no approvals
    /// and no balances. Payment is a balance delta on `recipient`.
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
                // Same primitive as `sweep`, so it answers to the same lock.
                _requireBookIdle();
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
        if (recipient == address(this)) depositFor(tokenOut, amountOut, address(this));
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
                // Same primitive as `sweep`, so it answers to the same lock.
                _requireBookIdle();
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
                depositFor(tokensOut[i], amountsOut[i], address(this));
            }
        }
    }
}

// ** ROBINHOOD CHAIN (4663)
//
// Read off the chain, not a docs page: WETH agrees between SwapRouter02.WETH9()
// and UniswapV2Router02.WETH(), both init-code hashes were confirmed by
// rebuilding a live pool from its factory, and the PoolManager is the one
// StateView.poolManager() returns.

address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

address constant V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
bytes32 constant V2_POOL_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
bytes32 constant V3_POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

/// @dev Deepstate: a fully onchain CLOB, radix-tree book, price-time matching.
/// Takers pay a protocol fee out of matched output, so `amountOutMin` is measured
/// after it.
address constant DEEPSTATE = 0x6cf19308C22FC82ea620Fa0B3E94948d20f27B96;

interface IDeepstate {
    struct FillParams {
        address token0;
        address token1;
        uint256 epoch;
        bytes32 order;
        bool isBid;
        bool noRest;
        bool fillOrKill;
    }

    function fill(FillParams calldata params) external payable returns (bytes32 restingOrder);
    function roots(address token0, address token1, uint256 epoch)
        external
        view
        returns (bytes32 askRoot, bytes32 bidRoot);
    function poolEpoch(bytes32 poolId) external view returns (uint256);
    function poolId(address token0, address token1) external pure returns (bytes32);
}

address constant INITIAL_OWNER = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;

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
        // Not `pop`: `unwrap` credits what this returns, so a swallowed
        // failure would mint a credit against ether never received.
        if iszero(call(gas(), WETH, 0, 0x1c, 0x24, codesize(), 0x00)) {
            mstore(0x00, 0x90b8ec18) // `TransferFailed()`
            revert(0x1c, 0x04)
        }
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

function depositFor(address token, uint256 amount, address _for) {
    assembly ("memory-safe") {
        mstore(0x00, _for)
        mstore(0x20, token)
        let slot := keccak256(0x00, 0x40)
        tstore(slot, add(tload(slot), amount))
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
