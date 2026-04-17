// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title PrecisionOraclePool (ETH/USDC)
/// @notice Oracle-priced pool — Chainlink sets the price, not a bonding curve.
/// @dev Swaps execute at oracle price ± dynamic fee. No AMM curve.
///      Eliminates curve-based LVR; residual adverse selection is bounded
///      by Chainlink's deviation threshold and mitigated by sandwich protection.
///      Fee ramps from BASE_FEE (1 bps, fresh oracle) to 50 bps (at heartbeat).
///      First swap after an oracle price change pays max fee to block sandwich attacks.
///
///      Prior art: DODO's PMM uses oracle-priced pools with configurable
///      parameters stored in contract storage. This takes the precision approach:
///      - Oracle address, deviation threshold, heartbeat are compile-time constants
///      - Dynamic fee is calibrated to the specific feed's deviation threshold
///      - Price math uses compile-time-known decimals (ETH 18, oracle 8, USDC 6)
///      - No factory, no adapter, no storage reads for pool configuration
///
///      Designed for atomic integration: EIP-7702 batch, zRouter snwap, or
///      multisig executeBatch. Uses the balance-delta pattern (transfer-then-call)
///      common to Uniswap V2 pair contracts — not safe for non-atomic direct calls.
contract PrecisionOraclePool {
    address constant TOKEN1 = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC (6 dec)
    address constant ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // Chainlink ETH/USD (8 dec)

    uint256 constant BASE_FEE = 100; // 1 bps — fee floor when oracle is fresh.
    uint256 constant STALENESS_PREMIUM = 4900; // Ramps to 50 bps at HEARTBEAT (0.5% deviation threshold).
    uint256 constant HEARTBEAT = 3600; // 1 hour max staleness.
    uint256 constant PRICE_SCALE = 1e20; // 10^(18 + 8 - 6).

    string public constant name = "Precision Oracle LP (ETH/USDC)";
    string public constant symbol = "poLP-ETH-USDC";
    uint8 public constant decimals = 18;

    error Reentrancy();
    error ZeroAmount();
    error StaleOracle();
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
    uint128 public lastPrice; // Last seen oracle price — detects oracle updates.
    uint128 public totalSupply;
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

        (uint256 price, uint256 elapsed) = _oraclePriceAndElapsed();
        uint256 fee;
        uint256 stored = lastPrice;
        if (stored != 0 && price != stored) {
            // Oracle price changed — first swap after a price change pays max fee.
            // Prevents sandwich attacks around oracle update transactions.
            fee = BASE_FEE + STALENESS_PREMIUM;
            lastPrice = uint128(price);
        } else {
            fee = BASE_FEE + (elapsed * STALENESS_PREMIUM / HEARTBEAT);
            if (stored == 0) lastPrice = uint128(price);
        }

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
            uint256 inAfterFee = amountIn - (amountIn * fee / 1000000); // Safe: fee <= 5000 pips.
            amountOut = zeroForOne
                ? inAfterFee * price / PRICE_SCALE  // Safe: uint128 * uint128 fits uint256.
                : inAfterFee * PRICE_SCALE / price;
        }

        if (amountOut == 0 || amountOut > rOut) revert InsufficientOutput();
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
        (uint256 price,) = _oraclePriceAndElapsed();
        if (lastPrice == 0) lastPrice = uint128(price);

        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        uint256 bal0 = address(this).balance;
        uint256 bal1 = _balanceOf(TOKEN1);

        uint256 supply = totalSupply;
        if (supply == 0) {
            // Value deposit in USDC terms using oracle price, scaled to 18 dec.
            lp = ((bal0 * price / PRICE_SCALE) + bal1) * 1e12 - 1000;
            totalSupply = uint128(lp + 1000);
            balanceOf[address(0)] = 1000;
        } else {
            // Proportional to oracle-denominated pool value.
            uint256 poolValue = (r0 * price / PRICE_SCALE) + r1;
            uint256 depositValue = ((bal0 - r0) * price / PRICE_SCALE) + (bal1 - r1);
            lp = depositValue * supply / poolValue;
            totalSupply = uint128(supply + lp);
        }

        if (lp == 0 || lp < minLP) revert InsufficientLiquidity();

        reserve0 = uint128(bal0);
        reserve1 = uint128(bal1);
        balanceOf[to] += lp;

        emit Transfer(address(0), to, lp);
        emit AddLiquidity(to, bal0 - r0, bal1 - r1, lp);
    }

    /// @notice Withdraw proportional reserves. No oracle needed — always available.
    function removeLiquidity(uint256 lp, uint256 minAmount0, uint256 minAmount1, address to)
        public
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (lp == 0) revert ZeroAmount();

        uint256 supply = totalSupply;
        unchecked {
            amount0 = lp * uint256(reserve0) / supply;
            amount1 = lp * uint256(reserve1) / supply;
        }

        if (amount0 < minAmount0 || amount1 < minAmount1) revert InsufficientLPBurned();

        balanceOf[msg.sender] -= lp;
        unchecked {
            totalSupply = uint128(supply - lp);
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

    // ── ORACLE ───────────────────────────────────────────────────────

    /// @dev Read Chainlink latestRoundData. Returns price (8 dec) and seconds since update.
    ///      Reverts StaleOracle on: failed call, zero/negative price, or elapsed > HEARTBEAT.
    function _oraclePriceAndElapsed() internal view returns (uint256 price, uint256 elapsed) {
        uint256 updatedAt;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xfeaf968c00000000000000000000000000000000000000000000000000000000)
            if iszero(staticcall(gas(), ORACLE, m, 0x04, m, 0xa0)) {
                mstore(0x00, 0x88cce429) // StaleOracle()
                revert(0x1c, 0x04)
            }
            price := mload(add(m, 0x20))
            updatedAt := mload(add(m, 0x60))
        }
        if (price == 0 || price > 1e18) revert StaleOracle(); // 1e18 = $10B at 8 dec
        elapsed = block.timestamp - updatedAt;
        if (elapsed > HEARTBEAT) revert StaleOracle();
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
