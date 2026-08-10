// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title PrecisionStablePool (USDT/USDC)
/// @notice NOT FOR DEPLOYMENT. Out of scope for the Precision release and
///         excluded from its audit; kept as a single-pair reference and gas
///         baseline alongside PrecisionOraclePool and PrecisionRangePool. It
///         has had no security review, and the two caveats below - the
///         balance-delta funding pattern and the missing imbalance fee - are
///         recorded rather than fixed for that reason.
/// @notice Stableswap pool for a single pair. Curve math, no generality.
/// @dev Integrates with zRouter via snwap (SafeExecutor calls `swap`).
///      Invariant (n=2): 4A(x + y) + D = 4AD + D^3 / (4xy)
///
///      USES THE BALANCE-DELTA PATTERN AND IS ONLY SAFE CALLED ATOMICALLY.
///      `swap` and `addLiquidity` take as their input whatever the balance
///      holds above the recorded reserve, exactly as a Uniswap V2 pair does.
///      Nothing authenticates who put it there, so funding this pool in one
///      transaction and calling it in another lets anyone settle that balance
///      in between and take the proceeds. Fund and call in a single
///      transaction - EIP-7702 batch, zRouter snwap, or a multisig batch -
///      or do not use this contract. The successor, PrecisionPool, pulls its
///      own input and has no such requirement.
///
///      IMBALANCED DEPOSITS ARE NOT CHARGED AN IMBALANCE FEE. `addLiquidity`
///      prices a deposit by the change in D while `removeLiquidity` pays out
///      proportionally, and Curve charges a fee on the difference precisely
///      because the two disagree for a one-sided deposit. At this A the gap is
///      second-order near the peg and the round trip is close to break-even,
///      but it widens as the pool leaves it. Deposit balanced.
contract PrecisionStablePool {
    address constant TOKEN0 = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address constant TOKEN1 = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // USDT

    uint256 constant ANN = 8000; // A * n^n = 2000 * 4.
    uint256 constant SWAP_FEE = 50; // 50 pips (0.005%).

    string public constant name = "Precision Stable LP (USDT/USDC)";
    string public constant symbol = "psLP-USDT-USDC";
    uint8 public constant decimals = 6;

    error Reentrancy();
    error ZeroAmount();
    error InvalidToken();
    error NoConvergence();
    error InsufficientOutput();
    error InsufficientLPBurned();
    error InsufficientLiquidity();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Swap(address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to);
    event AddLiquidity(address indexed provider, uint256 amount0, uint256 amount1, uint256 lp);
    event RemoveLiquidity(address indexed provider, uint256 lp, uint256 amount0, uint256 amount1);

    uint128 public reserve0;
    uint128 public reserve1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(0x00) {
                mstore(0x00, 0xab143c06)
                revert(0x1c, 0x04)
            }
            tstore(0x00, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(0x00, 0)
        }
    }

    function swap(address tokenIn, uint256 minOut, address to) public nonReentrant returns (uint256 amountOut) {
        bool zeroForOne = tokenIn == TOKEN0;
        if (!zeroForOne && tokenIn != TOKEN1) revert InvalidToken();

        uint256 balIn = _balanceOf(tokenIn);
        uint256 rIn = zeroForOne ? reserve0 : reserve1;
        uint256 rOut = zeroForOne ? reserve1 : reserve0;

        unchecked {
            uint256 amountIn = balIn - rIn; // Safe: balance >= reserve.
            if (amountIn == 0) revert ZeroAmount();

            uint256 inAfterFee = amountIn - (amountIn * SWAP_FEE / 1000000); // Safe: fee < input.
            uint256 d = _computeD(rIn, rOut);
            uint256 newOut = _computeY(rIn + inAfterFee, d);
            if (newOut > rOut) revert InsufficientOutput(); // Guard: degenerate state.
            amountOut = rOut - newOut;
            if (amountOut < minOut) revert InsufficientOutput();

            if (zeroForOne) {
                reserve0 = uint128(balIn);
                reserve1 -= uint128(amountOut); // Safe: amountOut <= rOut.
            } else {
                reserve0 -= uint128(amountOut);
                reserve1 = uint128(balIn);
            }

            _transfer(zeroForOne ? TOKEN1 : TOKEN0, to, amountOut);

            emit Swap(tokenIn, amountIn, amountOut, to);
        }
    }

    function addLiquidity(uint256 minLP, address to) public nonReentrant returns (uint256 lp) {
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        uint256 bal0 = _balanceOf(TOKEN0);
        uint256 bal1 = _balanceOf(TOKEN1);

        uint256 supply = totalSupply;
        if (supply == 0) {
            if (bal0 == 0 || bal1 == 0) revert ZeroAmount(); // Require both tokens.
            lp = _computeD(bal0, bal1) - 1000; // Checked: reverts on dust deposits.
            totalSupply = lp + 1000;
            balanceOf[address(0)] = 1000;
        } else {
            uint256 d0 = _computeD(r0, r1);
            unchecked {
                lp = (_computeD(bal0, bal1) - d0) * supply / d0; // Safe: new D >= old D, d0 > 0.
            }
            totalSupply = supply + lp;
        }

        if (lp < minLP) revert InsufficientLiquidity();

        reserve0 = uint128(bal0);
        reserve1 = uint128(bal1);
        balanceOf[to] += lp;

        emit Transfer(address(0), to, lp);
        unchecked {
            emit AddLiquidity(to, bal0 - r0, bal1 - r1, lp); // Safe: bal >= reserve.
        }
    }

    function removeLiquidity(uint256 lp, uint256 minAmount0, uint256 minAmount1, address to)
        public
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (lp == 0) revert ZeroAmount();

        uint256 supply = totalSupply;
        unchecked {
            amount0 = lp * uint256(reserve0) / supply; // Safe: uint128 * uint256 fits uint256.
            amount1 = lp * uint256(reserve1) / supply;
        }

        if (amount0 < minAmount0 || amount1 < minAmount1) revert InsufficientLPBurned();

        balanceOf[msg.sender] -= lp; // Checked: underflow is the balance guard.
        unchecked {
            totalSupply = supply - lp; // Safe: lp <= supply.
            reserve0 -= uint128(amount0); // Safe: amount0 is proportional fraction of reserve0.
            reserve1 -= uint128(amount1);
        }

        _transfer(TOKEN0, to, amount0);
        _transfer(TOKEN1, to, amount1);

        emit Transfer(msg.sender, address(0), lp);
        emit RemoveLiquidity(msg.sender, lp, amount0, amount1);
    }

    // ── ERC-20 ───────────────────────────────────────────────────────

    function transfer(address to, uint256 value) public returns (bool) {
        balanceOf[msg.sender] -= value;
        unchecked {
            balanceOf[to] += value;
        }
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        balanceOf[from] -= value;
        unchecked {
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
        return true;
    }

    // ── STABLESWAP MATH ──────────────────────────────────────────────

    /// @dev Compute invariant D. Newton: D = (ANN*S + 2*Dp) * D / ((ANN-1)*D + 3*Dp)
    ///
    ///      REVERTS IF IT DOES NOT CONVERGE. Eight iterations is ample for a
    ///      two-coin pool at this A near the peg, but "ample" is not "always",
    ///      and the loop body is `unchecked`. Accepting the last iterate when the
    ///      sequence has not settled means returning a D that is simply wrong,
    ///      and D feeds `_computeY` - so the error does not stay in the
    ///      invariant, it comes back out as a quoted output. Reverting a swap
    ///      that cannot be priced is the only safe answer.
    function _computeD(uint256 x, uint256 y) internal pure returns (uint256 d) {
        if (x == 0 || y == 0) return x + y; // Degenerate: no curve, just sum.
        uint256 s = x + y;
        d = s;
        unchecked {
            for (uint256 i; i < 255; ++i) {
                uint256 dp = d * d / (2 * x) * d / (2 * y);
                uint256 dPrev = d;
                d = (ANN * s + 2 * dp) * d / ((ANN - 1) * d + 3 * dp);
                if (d > dPrev ? d - dPrev <= 1 : dPrev - d <= 1) return d;
            }
        }
        revert NoConvergence();
    }

    /// @dev Compute reserve y given reserve x and invariant D.
    ///      Newton: y = (y^2 + c) / (2y + b - D)
    ///
    ///      REVERTS IF IT DOES NOT CONVERGE, and here the reason is sharper than
    ///      for `_computeD`. The caller does `amountOut = rOut - newOut` behind
    ///      only a `newOut > rOut` guard, so an iterate that has not settled and
    ///      lands BELOW the true root is not caught by anything - it reads as a
    ///      larger output and pays it, up to the whole output reserve. The
    ///      subtraction inside the denominator is `unchecked` as well, so a
    ///      wrapped intermediate produces a small `y` rather than a panic. The
    ///      convergence test is what stands between those two facts and a drain.
    function _computeY(uint256 xKnown, uint256 d) internal pure returns (uint256 y) {
        uint256 c = d * d / (2 * xKnown) * d / (2 * ANN);
        uint256 b = xKnown + d / ANN;
        y = d;
        unchecked {
            for (uint256 i; i < 255; ++i) {
                uint256 yPrev = y;
                y = (y * y + c) / (2 * y + b - d);
                if (y > yPrev ? y - yPrev <= 1 : yPrev - y <= 1) return y;
            }
        }
        revert NoConvergence();
    }

    // ── ASSEMBLY HELPERS ─────────────────────────────────────────────

    function _transfer(address token, address to, uint256 amount) internal {
        assembly ("memory-safe") {
            mstore(0x14, to)
            mstore(0x34, amount)
            mstore(0x00, 0xa9059cbb000000000000000000000000)
            if iszero(call(gas(), token, 0, 0x10, 0x44, codesize(), 0x00)) {
                revert(codesize(), 0x00)
            }
            mstore(0x34, 0)
        }
    }

    function _balanceOf(address token) internal view returns (uint256 amount) {
        assembly ("memory-safe") {
            mstore(0x14, address())
            mstore(0x00, 0x70a08231000000000000000000000000)
            pop(staticcall(gas(), token, 0x10, 0x24, 0x00, 0x20))
            amount := mload(0x00)
        }
    }
}
