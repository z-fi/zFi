// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title PrecisionRangePool (ETH/USDC $2200-$3000)
/// @notice Concentrated constant-product pool for a single pair and fixed price range.
/// @dev Integrates with zRouter via snwap. Uses native ETH (not WETH).
///      Virtual reserves concentrate liquidity into the hardcoded range.
///
///      Real reserves: x (ETH), y (USDC)
///      Virtual reserves: X = x + L/sqrt(pHigh), Y = y + L*sqrt(pLow)
///      Invariant: X * Y = L^2
contract PrecisionRangePool {
    address constant TOKEN1 = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC (6 dec)

    uint256 constant SWAP_FEE = 500; // 500 pips (0.05% / 5 bps).

    // Price range: $2200-$3000 USDC per ETH.
    // Decimal-adjusted sqrt prices scaled by 1e18:
    uint256 constant SQRT_P_LOW = 46904157598234; // sqrt($2200 adj) * 1e18
    uint256 constant SQRT_P_HIGH = 54772255750516; // sqrt($3000 adj) * 1e18

    // Precomputed from sqrt prices for the quadratic L solve:
    // a = 1e18 / SQRT_P_HIGH (virtual ETH offset per unit L)
    // b = SQRT_P_LOW / 1e18   (virtual USDC offset per unit L)
    // ONE_MINUS_AB = (1 - a*b) scaled by 1e18 = 1e18 - SQRT_P_LOW * 1e18 / SQRT_P_HIGH
    uint256 constant ONE_MINUS_AB = 143651161422320512; // (1 - ab) * 1e18

    string public constant name = "Precision Range LP (ETH/USDC 2200-3000)";
    string public constant symbol = "prLP-ETH-USDC-2200-3000";
    uint8 public constant decimals = 18;

    error Reentrancy();
    error ZeroAmount();
    error InvalidToken();
    error ETHTransferFailed();
    error InsufficientOutput();
    error InsufficientLPBurned();
    error InsufficientLiquidity();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Swap(address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to);
    event AddLiquidity(address indexed provider, uint256 amount0, uint256 amount1, uint256 lp);
    event RemoveLiquidity(address indexed provider, uint256 lp, uint256 amount0, uint256 amount1);

    uint128 public reserve0; // ETH (18 dec)
    uint128 public reserve1; // USDC (6 dec)
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

    receive() external payable {}

    /// @param tokenIn address(0) for ETH, TOKEN1 for USDC.
    function swap(address tokenIn, uint256 minOut, address to) public payable nonReentrant returns (uint256 amountOut) {
        bool zeroForOne = tokenIn == address(0);
        if (!zeroForOne && tokenIn != TOKEN1) revert InvalidToken();

        uint256 rIn;
        uint256 rOut;
        uint256 amountIn;

        if (zeroForOne) {
            rIn = reserve0;
            rOut = reserve1;
            amountIn = address(this).balance - rIn;
        } else {
            rIn = reserve1;
            rOut = reserve0;
            amountIn = _balanceOf(TOKEN1) - rIn;
        }
        if (amountIn == 0) revert ZeroAmount();

        unchecked {
            uint256 inAfterFee = amountIn - (amountIn * SWAP_FEE / 1000000);
            (uint256 vIn, uint256 vOut) =
                zeroForOne ? (_virtualReserve0(), _virtualReserve1()) : (_virtualReserve1(), _virtualReserve0());

            amountOut = inAfterFee * (rOut + vOut) / (rIn + vIn + inAfterFee);
            if (amountOut > rOut) revert InsufficientOutput(); // Would cross range boundary.
        }

        if (amountOut < minOut) revert InsufficientOutput();

        if (zeroForOne) {
            reserve0 = uint128(rIn + amountIn);
            reserve1 = uint128(rOut - amountOut);
            _transfer(TOKEN1, to, amountOut);
        } else {
            reserve0 = uint128(rOut - amountOut);
            reserve1 = uint128(rIn + amountIn);
            _transferETH(to, amountOut);
        }

        emit Swap(tokenIn, amountIn, amountOut, to);
    }

    function addLiquidity(uint256 minLP, address to) public payable nonReentrant returns (uint256 lp) {
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        uint256 bal0 = address(this).balance;
        uint256 bal1 = _balanceOf(TOKEN1);

        uint256 supply = totalSupply;
        if (supply == 0) {
            // Solve (1-ab)L^2 - (bx + ay)L - xy = 0 for L.
            // L = (B + sqrt(B^2 + 4*A*xy)) / (2*A)
            // where A = ONE_MINUS_AB (scaled 1e18), B = bx + ay (scaled 1e18).
            uint256 B = bal0 * SQRT_P_LOW + bal1 * 1e36 / SQRT_P_HIGH;
            uint256 disc = B * B + 4 * ONE_MINUS_AB * bal0 * bal1 * 1e18;
            lp = (B + _sqrt(disc)) / (2 * ONE_MINUS_AB) - 1000;
            totalSupply = lp + 1000;
            balanceOf[address(0)] = 1000;
        } else {
            uint256 amount0 = bal0 - r0;
            uint256 amount1 = bal1 - r1;

            // Proportional: LP credit based on whichever side contributes less.
            uint256 lp0 = r0 > 0 ? amount0 * supply / r0 : type(uint256).max;
            uint256 lp1 = r1 > 0 ? amount1 * supply / r1 : type(uint256).max;
            lp = lp0 < lp1 ? lp0 : lp1;
            totalSupply = supply + lp;
        }

        if (lp < minLP) revert InsufficientLiquidity();

        reserve0 = uint128(bal0);
        reserve1 = uint128(bal1);
        balanceOf[to] += lp;

        emit Transfer(address(0), to, lp);
        emit AddLiquidity(to, bal0 - r0, bal1 - r1, lp);
    }

    function removeLiquidity(uint256 lp, uint256 minAmount0, uint256 minAmount1, address to)
        public
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (lp == 0) revert ZeroAmount();

        uint256 supply = totalSupply;
        unchecked {
            amount0 = lp * reserve0 / supply;
            amount1 = lp * reserve1 / supply;
        }

        if (amount0 < minAmount0 || amount1 < minAmount1) revert InsufficientLPBurned();

        balanceOf[msg.sender] -= lp;
        unchecked {
            totalSupply = supply - lp;
            reserve0 -= uint128(amount0);
            reserve1 -= uint128(amount1);
        }

        _transferETH(to, amount0);
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

    // ── VIRTUAL RESERVES ─────────────────────────────────────────────

    function _virtualReserve0() internal view returns (uint256) {
        return totalSupply * 1e18 / SQRT_P_HIGH;
    }

    function _virtualReserve1() internal view returns (uint256) {
        return totalSupply * SQRT_P_LOW / 1e18;
    }

    // ── MATH ─────────────────────────────────────────────────────────

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = x / 2 + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }

    // ── HELPERS ──────────────────────────────────────────────────────

    function _transferETH(address to, uint256 amount) internal {
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb)
                revert(0x1c, 0x04)
            }
        }
    }

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
