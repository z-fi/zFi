// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function pools(uint256 poolId)
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast,
            uint256 kLast,
            uint256 supply
        );

    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    function swapExactOut(
        PoolKey calldata poolKey,
        uint256 amountOut,
        uint256 amountInMax,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountIn);

    function swap(
        PoolKey calldata poolKey,
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;
}

interface IPAMM {
    function markets(uint256 marketId)
        external
        view
        returns (
            address resolver,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,
            address collateral,
            uint256 collateralLocked
        );

    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function poolKey(uint256 marketId, uint256 feeOrHook) external view returns (PoolKey memory);
}

interface IZAMMHook {
    function beforeAction(bytes4 sig, uint256 poolId, address sender, bytes calldata data)
        external
        payable
        returns (uint256 feeBps);

    function afterAction(
        bytes4 sig,
        uint256 poolId,
        address sender,
        int256 d0,
        int256 d1,
        int256 dLiq,
        bytes calldata data
    ) external payable;
}

/// @notice Dynamic-fee hook for prediction markets
/// @dev Features: bootstrap decay, skew protection, asymmetric fees, volatility fees, price impact limits
/// @dev Hook design: Always uses FLAG_BEFORE | FLAG_AFTER for stable poolId. Config toggles features.
/// @dev Close modes: 0=halt, 1=fixed fee, 2=min fee, 3=dynamic. Swaps respect close/resolution, LPs always allowed.
/// @dev SECURITY: Requires registered pools only. Unregistered pools revert on swaps to prevent post-resolution trading.
/// @dev REQUIRES: EIP-1153 (transient storage) - only deploy on chains with Cancun/Dencun support
contract PMFeeHook is IZAMMHook {
    // ═══════════════════════════════════════════════════════════
    //                         CONSTANTS
    // ═══════════════════════════════════════════════════════════

    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;
    uint256 constant BPS_DENOMINATOR = 10_000;
    uint256 constant BPS_SQUARED = 100_000_000; // 10_000^2
    uint256 constant BPS_CUBED = 1_000_000_000_000; // 10_000^3
    uint256 constant BPS_QUARTIC = 10_000_000_000_000_000; // 10_000^4

    // Transient storage slot for reentrancy guard (EIP-1153)
    uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268;

    // Transient storage for reserve caching (avoids duplicate ZAMM.pools() calls)
    // Domain separator for keccak-based slot derivation (prevents adversarial collision)
    uint256 constant TS_RESERVES_DOMAIN =
        0x7f9c2e2f7d8a4c6b3a1d9e0f11223344556677889900aabbccddeeff00112233;
    uint256 constant TS_RESERVES_PRESENT_BIT = 1 << 224; // marker bit

    // Transient storage for Meta caching (avoids duplicate meta[poolId] SLOAD in afterAction)
    uint256 constant TS_META_DOMAIN =
        0x8e1d3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2;

    // Transient storage for flags caching (avoids duplicate c.flags SLOAD in afterAction)
    uint256 constant TS_FLAGS_DOMAIN =
        0x9f2e4f5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3;

    // ZAMM swap function selectors (from actual interface)
    bytes4 constant SWAP_EXACT_IN = IZAMM.swapExactIn.selector;
    bytes4 constant SWAP_EXACT_OUT = IZAMM.swapExactOut.selector;
    bytes4 constant SWAP_LOWLEVEL = IZAMM.swap.selector;

    // Config flag bit masks
    uint16 constant FLAG_SKEW = 0x01; // bit 0: skew fee enabled
    uint16 constant FLAG_BOOTSTRAP = 0x02; // bit 1: bootstrap fee enabled
    uint16 constant FLAG_ASYMMETRIC = 0x10; // bit 4: asymmetric fee enabled
    uint16 constant FLAG_PRICE_IMPACT = 0x20; // bit 5: price impact check enabled
    uint16 constant FLAG_VOLATILITY = 0x40; // bit 6: volatility fee enabled

    // Combined mask for flags that require reserve data
    uint16 constant FLAG_NEEDS_RESERVES = FLAG_SKEW | FLAG_ASYMMETRIC; // 0x11

    // ═══════════════════════════════════════════════════════════
    //                     EXTERNAL CONTRACTS
    // ═══════════════════════════════════════════════════════════

    IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IPAMM public constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address public constant REGISTRAR = 0x0000000000Ff22a7FFEf88639d95C03183c5093C; // Router

    // ═══════════════════════════════════════════════════════════
    //                         ERRORS
    // ═══════════════════════════════════════════════════════════

    error Reentrancy();
    error MarketClosed();
    error Unauthorized();
    error InvalidConfig();
    error InvalidMarket();
    error InvalidPoolId();
    error AlreadyRegistered();
    error PriceImpactTooHigh();
    error InvalidBootstrapStart();

    // ═══════════════════════════════════════════════════════════
    //                         EVENTS
    // ═══════════════════════════════════════════════════════════

    event BootstrapStartAdjusted(uint256 indexed poolId, uint64 oldStart, uint64 newStart);
    event MarketRegistered(uint256 indexed marketId, uint256 indexed poolId, uint64 close);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ConfigUpdated(uint256 indexed marketId, Config config);
    event DefaultConfigUpdated(Config config);

    // ═══════════════════════════════════════════════════════════
    //                         STRUCTS
    // ═══════════════════════════════════════════════════════════

    struct Meta {
        uint64 start; // When hook registered (bootstrap starts here)
        bool active; // Market is registered
        bool yesIsToken0; // True if YES token is token0 (cached to avoid recomputing)
    }

    /// @notice Fee config (perfectly packed into 32 bytes). All fees in bps.
    struct Config {
        uint16 minFeeBps; // Steady-state fee
        uint16 maxFeeBps; // Bootstrap starting fee
        uint16 maxSkewFeeBps; // Max skew fee
        uint16 feeCapBps; // Total fee ceiling
        uint16 skewRefBps; // Skew threshold (0, 5000]
        uint16 asymmetricFeeBps; // Linear imbalance fee
        uint16 closeWindow; // Close window duration (seconds). 0 = no close window logic in hook (router may apply its own default)
        uint16 closeWindowFeeBps; // Mode 1 close fee
        uint16 maxPriceImpactBps; // Max impact (requires FLAG_PRICE_IMPACT)
        uint32 bootstrapWindow; // Decay duration (seconds)
        uint16 volatilityFeeBps; // High volatility penalty
        uint32 volatilityWindow; // Volatility staleness window (seconds, 0=no staleness check)
        uint16 flags; // Bits: 0=skew, 1=bootstrap, 2-3=closeMode, 4=asymmetric, 5=priceImpact, 6=volatility, 7-15=reserved
        uint16 extraFlags; // Bits: 0-1=skewCurve, 2-3=decayMode, 4-15=reserved
    }

    // ═══════════════════════════════════════════════════════════
    //                         STORAGE
    // ═══════════════════════════════════════════════════════════

    mapping(uint256 poolId => uint256 marketId) public poolToMarket;
    mapping(uint256 poolId => Meta) public meta;

    Config internal defaultConfig;
    // Market-specific configs: Uses feeCapBps==0 as sentinel for "use default" (validated to never be 0)
    mapping(uint256 marketId => Config) internal marketConfig;

    // Volatility tracking: circular buffer of recent prices (stores last 10 prices)
    struct PriceSnapshot {
        uint64 timestamp;
        uint32 priceBps; // Price in basis points (0-10000)
    }
    mapping(uint256 poolId => PriceSnapshot[10]) public priceHistory;
    mapping(uint256 poolId => uint8) public priceHistoryIndex; // Current write position
    mapping(uint256 poolId => uint256) public lastSnapshotBlock; // MEV protection: one snapshot per block

    // Cached pool data to avoid repeated external calls
    struct PoolData {
        uint112 reserve0;
        uint112 reserve1;
        bool valid;
    }

    // ═══════════════════════════════════════════════════════════
    //                         CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor() payable {
        // Note: tx.origin sets owner to deploying EOA (not factory address if deployed via factory)
        // This preserves CREATE2 determinism but requires EOA deployment or factory-aware setup
        // IMPORTANT: Factory deployment still sets owner to origin EOA, not the factory contract
        owner = tx.origin;
        emit OwnershipTransferred(address(0), tx.origin);

        // Default config: Optimized for router-first architecture with $100-10k pools
        // Fee context: Router vault charges 1-5% spread, so AMM at 0.2-0.75% is competitive
        // Price impact @ 12% is the real constraint: $100 pool->~$10 trades, $1k pool->~$100 trades
        defaultConfig.minFeeBps = 20; // 0.20% steady-state (sustainable for small pools)
        defaultConfig.maxFeeBps = 75; // 0.75% bootstrap (competitive with vault)
        defaultConfig.maxSkewFeeBps = 80; // 0.80% at 90/10+ (anti-manipulation)
        defaultConfig.feeCapBps = 300; // 3% cap (rarely binds)
        defaultConfig.skewRefBps = 4000; // 90/10 split (tight for small pools)
        defaultConfig.asymmetricFeeBps = 20; // 0.20% directional component
        defaultConfig.closeWindow = 1 hours;
        defaultConfig.closeWindowFeeBps = 40; // 0.40% fixed fee during close window
        defaultConfig.maxPriceImpactBps = 1200; // 12% CRITICAL - protects TWAP for router vault pricing
        defaultConfig.bootstrapWindow = 2 days; // Elevated fees for 29% of 1-week, 7% of 1-month
        defaultConfig.volatilityFeeBps = 0;
        defaultConfig.volatilityWindow = 0;
        // flags 0x37: skew + bootstrap + closeWindowMode=1 + asymmetric + priceImpact (no volatility)
        // closeWindowMode=1: AMM still allows trading with fixed 0.40% fee in close window,
        // while router independently disables vault OTC (reads hook's closeWindow via getCloseWindow)
        defaultConfig.flags = 0x37;
        defaultConfig.extraFlags = 0x01; // Quadratic skew curve, linear bootstrap decay
    }

    // ═══════════════════════════════════════════════════════════
    //                     ADMIN CONFIGURATION
    // ═══════════════════════════════════════════════════════════

    address public owner;

    function setDefaultConfig(Config calldata cfg) public payable onlyOwner {
        _validateConfig(cfg);
        defaultConfig = cfg;
        emit DefaultConfigUpdated(cfg);
    }

    function setMarketConfig(uint256 marketId, Config calldata cfg) public payable onlyOwner {
        _validateConfig(cfg);
        marketConfig[marketId] = cfg;
        emit ConfigUpdated(marketId, cfg);
    }

    function clearMarketConfig(uint256 marketId) public payable onlyOwner {
        delete marketConfig[marketId]; // All fields become 0, feeCapBps==0 signals "use default"
        emit ConfigUpdated(marketId, defaultConfig);
    }

    /// @notice Adjust bootstrap start time for a pool (owner only)
    /// @dev Can only delay start (oldStart <= newStart <= block.timestamp), requires zero liquidity
    /// @param poolId The pool to adjust
    /// @param newStart New bootstrap start timestamp
    function adjustBootstrapStart(uint256 poolId, uint64 newStart) public payable onlyOwner {
        Meta storage m = meta[poolId];
        if (!m.active) revert InvalidPoolId();

        uint64 oldStart = m.start;
        uint256 marketId = poolToMarket[poolId];

        if (newStart < oldStart) revert InvalidBootstrapStart();
        if (newStart > block.timestamp) revert InvalidBootstrapStart();

        (, bool resolved,,, uint64 liveClose,,) = PAMM.markets(marketId);
        if (resolved) revert MarketClosed();
        if (liveClose != 0 && block.timestamp >= liveClose) revert MarketClosed();
        if (liveClose != 0 && newStart >= liveClose) revert InvalidBootstrapStart();

        // Require zero liquidity to prevent fee reset on active markets
        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
        if (r0 != 0 || r1 != 0) revert InvalidBootstrapStart();

        m.start = newStart;

        emit BootstrapStartAdjusted(poolId, oldStart, newStart);
    }

    function getMarketConfig(uint256 marketId) public view returns (Config memory) {
        return _cfg(marketId);
    }

    function getDefaultConfig() public view returns (Config memory) {
        return defaultConfig;
    }

    /// @notice Get close window for a market
    /// @dev Returns the hook's close window setting. 0 = no close window logic in hook.
    ///      Router may read this value and apply its own default (typically 1 hour) when 0.
    function getCloseWindow(uint256 marketId) public view returns (uint256) {
        Config storage c = _cfg(marketId);
        return uint256(c.closeWindow);
    }

    /// @notice Get max price impact for a market (0 if disabled)
    /// @dev Returns 0 if price impact check is disabled (FLAG_PRICE_IMPACT not set)
    function getMaxPriceImpactBps(uint256 marketId) public view returns (uint256) {
        Config storage c = _cfg(marketId);
        bool enabled = (c.flags & FLAG_PRICE_IMPACT) != 0;
        return enabled ? uint256(c.maxPriceImpactBps) : 0;
    }

    /// @notice Transfer ownership (ERC173)
    function transferOwnership(address newOwner) public payable onlyOwner {
        if (newOwner == address(0)) revert Unauthorized();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // ═══════════════════════════════════════════════════════════
    //                     HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    /// @notice Get canonical feeOrHook value (always FLAG_BEFORE | FLAG_AFTER for stable poolId)
    function feeOrHook() public view returns (uint256) {
        return uint256(uint160(address(this))) | FLAG_BEFORE | FLAG_AFTER;
    }

    /// @notice Register market (router or owner only)
    function registerMarket(uint256 marketId) public returns (uint256 poolId) {
        if (msg.sender != REGISTRAR && msg.sender != owner) revert Unauthorized();

        (address resolver, bool resolved,,, uint64 close,,) = PAMM.markets(marketId);
        if (resolver == address(0)) revert InvalidMarket();
        if (resolved) revert MarketClosed();
        if (close != 0 && close <= block.timestamp) revert MarketClosed();

        uint256 feeHook = feeOrHook();

        IPAMM.PoolKey memory k = PAMM.poolKey(marketId, feeHook);
        poolId = uint256(keccak256(abi.encode(k.id0, k.id1, k.token0, k.token1, k.feeOrHook)));

        if (meta[poolId].active) revert AlreadyRegistered();

        uint256 yesId = marketId;
        uint256 noId = _getNoId(marketId);
        bool yesIsToken0 = yesId < noId;
        poolToMarket[poolId] = marketId;
        meta[poolId] =
            Meta({start: uint64(block.timestamp), active: true, yesIsToken0: yesIsToken0});

        emit MarketRegistered(marketId, poolId, close);
    }

    /// @notice View current fee for a pool (returns 10001 sentinel if halted)
    function getCurrentFeeBps(uint256 poolId) public view returns (uint256) {
        return _computeFee(poolId);
    }

    // ═══════════════════════════════════════════════════════════
    //                         MODIFIERS
    // ═══════════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, 0xab143c06) // `Reentrancy()`
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_SLOT, address()) // Uses contract address as nonzero sentinel
        }
        _;
        assembly ("memory-safe") {
            tstore(REENTRANCY_SLOT, 0)
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                  TRANSIENT STORAGE HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @dev Collision-resistant transient slot via keccak(poolId, domain)
    function _reservesSlot(uint256 poolId) internal pure returns (uint256 slot) {
        assembly ("memory-safe") {
            mstore(0x00, poolId)
            mstore(0x20, TS_RESERVES_DOMAIN)
            slot := keccak256(0x00, 0x40)
        }
    }

    /// @dev Get transient slot for Meta cache
    function _metaSlot(uint256 poolId) internal pure returns (uint256 slot) {
        assembly ("memory-safe") {
            mstore(0x00, poolId)
            mstore(0x20, TS_META_DOMAIN)
            slot := keccak256(0x00, 0x40)
        }
    }

    /// @dev Store Meta to transient storage (packs into single uint256)
    /// @dev Layout: bits 0-63: start, bit 64: active, bit 65: yesIsToken0
    function _tstoreMeta(uint256 poolId, Meta memory m) internal {
        uint256 packed = uint256(m.start) | (uint256(m.active ? 1 : 0) << 64)
            | (uint256(m.yesIsToken0 ? 1 : 0) << 65);
        uint256 slot = _metaSlot(poolId);
        assembly ("memory-safe") {
            tstore(slot, packed)
        }
    }

    /// @dev Load Meta from transient storage
    function _tloadMeta(uint256 poolId) internal view returns (Meta memory m) {
        uint256 slot = _metaSlot(poolId);
        uint256 packed;
        assembly ("memory-safe") {
            packed := tload(slot)
        }
        m.start = uint64(packed);
        m.active = ((packed >> 64) & 1) == 1;
        m.yesIsToken0 = ((packed >> 65) & 1) == 1;
    }

    /// @dev Get transient slot for flags cache
    function _flagsSlot(uint256 poolId) internal pure returns (uint256 slot) {
        assembly ("memory-safe") {
            mstore(0x00, poolId)
            mstore(0x20, TS_FLAGS_DOMAIN)
            slot := keccak256(0x00, 0x40)
        }
    }

    /// @dev Store flags to transient storage
    function _tstoreFlags(uint256 poolId, uint16 flags) internal {
        uint256 slot = _flagsSlot(poolId);
        assembly ("memory-safe") {
            tstore(slot, flags)
        }
    }

    /// @dev Load flags from transient storage
    function _tloadFlags(uint256 poolId) internal view returns (uint16 flags) {
        uint256 slot = _flagsSlot(poolId);
        assembly ("memory-safe") {
            flags := tload(slot)
        }
    }

    /// @dev Store reserves to transient storage
    function _tstoreReservesAt(uint256 slot, uint112 r0, uint112 r1) internal {
        uint256 v = uint256(r0) | (uint256(r1) << 112) | TS_RESERVES_PRESENT_BIT;
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    /// @dev Load cached reserves from transient storage
    /// @return ok True if cached reserves found
    /// @return r0 Reserve0
    /// @return r1 Reserve1
    function _tloadReservesAt(uint256 slot)
        internal
        view
        returns (bool ok, uint112 r0, uint112 r1)
    {
        uint256 v;
        assembly ("memory-safe") {
            v := tload(slot)
        }
        ok = (v & TS_RESERVES_PRESENT_BIT) != 0;
        if (ok) {
            r0 = uint112(v);
            r1 = uint112(v >> 112);
        }
    }

    /// @dev Wrapper that computes slot and loads
    function _tloadReserves(uint256 poolId)
        internal
        view
        returns (bool ok, uint112 r0, uint112 r1)
    {
        return _tloadReservesAt(_reservesSlot(poolId));
    }

    // ═══════════════════════════════════════════════════════════
    //                     HOOK INTERFACE
    // ═══════════════════════════════════════════════════════════

    function beforeAction(
        bytes4 sig,
        uint256 poolId,
        address,
        /* sender */
        bytes calldata /* data */
    )
        public
        payable
        override(IZAMMHook)
        nonReentrant
        returns (uint256 feeBps)
    {
        if (msg.sender != address(ZAMM)) revert Unauthorized();

        // LP operations (addLiquidity/removeLiquidity) are allowed without fees or active check
        // INTENTIONAL: Allows emergency LP removal from unregistered/resolved pools
        if (!_isSwap(sig)) return 0;

        // Load pool metadata only for swaps (avoids SLOADs on LP operations)
        Meta memory m = meta[poolId];

        // Swaps require registered pools (prevents post-resolution trading)
        if (!m.active) revert InvalidPoolId();

        // Cache Meta in transient storage for afterAction (saves ~2000 gas SLOAD)
        _tstoreMeta(poolId, m);

        uint256 marketId = poolToMarket[poolId];

        // Load config (uses sentinel check: feeCapBps==0 means "use default")
        Config storage c = _cfg(marketId);

        // Single PAMM.markets() call - reused for enforceOpen and computeFee
        (, bool resolved,,, uint64 close,,) = PAMM.markets(marketId);

        // Read flags once to avoid repeated SLOADs
        uint16 flags = c.flags;

        // Cache flags in transient storage for afterAction (saves ~100 gas SLOAD)
        _tstoreFlags(poolId, flags);

        // Enforce market is open (reverts or returns fee based on closeWindowMode)
        _enforceOpenCached(c, flags, resolved, close);

        // Optimization: Manage transient reserve cache to avoid duplicate ZAMM.pools() calls
        // CRITICAL: Always write fresh reserves OR explicitly clear to prevent stale cache
        // from previous swaps in the same transaction
        bool feeNeedsReserves = (flags & FLAG_NEEDS_RESERVES) != 0;
        bool afterNeedsReserves = (flags & (FLAG_PRICE_IMPACT | FLAG_VOLATILITY)) != 0;

        // Compute transient slot once if needed (saves keccak in afterAction)
        uint256 slot;
        if (feeNeedsReserves || afterNeedsReserves) {
            slot = _reservesSlot(poolId);
        }

        PoolData memory poolData;
        bool hasPoolData;

        if (feeNeedsReserves) {
            // Fee path needs reserves: fetch, cache, and pass to fee calc
            // Passing poolData directly avoids redundant transient read in fee computation
            (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
            _tstoreReservesAt(slot, r0, r1);
            poolData = PoolData({reserve0: r0, reserve1: r1, valid: (r0 > 0 && r1 > 0)});
            hasPoolData = true;
        } else if (afterNeedsReserves) {
            // afterAction needs reserves but fee doesn't: clear cache to prevent stale reads
            assembly ("memory-safe") {
                tstore(slot, 0)
            }
        }
        // else: neither needs reserves, cache state doesn't matter

        // Compute and return dynamic fee (using pre-loaded poolData and flags)
        feeBps = _computeFeeCachedWithPoolData(
            poolId, m, c, flags, resolved, close, poolData, hasPoolData
        );

        // CRITICAL SAFETY: Ensure fee never exceeds 10,000 bps (would cause underflow in ZAMM)
        // This should be unreachable (_enforceOpenCached reverts first), but defense in depth
        if (feeBps > BPS_DENOMINATOR) revert InvalidConfig();

        return feeBps;
    }

    /// @notice Post-trade hook: enforces price impact limits and records volatility
    /// @dev Deltas: positive = added to pool, negative = removed
    function afterAction(
        bytes4 sig,
        uint256 poolId,
        address, /* sender */
        int256 d0,
        int256 d1,
        int256, /* dLiq */
        bytes calldata /* data */
    ) public payable override(IZAMMHook) nonReentrant {
        if (msg.sender != address(ZAMM)) revert Unauthorized();

        // Skip all checks for non-swap operations (LP operations)
        if (!_isSwap(sig)) return;

        // Load pool metadata from transient cache (set by beforeAction, saves ~2000 gas SLOAD)
        // SECURITY: Revert (not return) to block after-only shadow pools
        Meta memory m = _tloadMeta(poolId);
        if (!m.active) revert InvalidPoolId();

        // Read flags from transient cache (set by beforeAction, saves ~100 gas SLOAD)
        uint16 flags = _tloadFlags(poolId);

        uint256 marketId = poolToMarket[poolId];
        Config storage c = _cfg(marketId);

        bool doImpact = (flags & FLAG_PRICE_IMPACT) != 0;
        bool doVol = (flags & FLAG_VOLATILITY) != 0;
        bool feeNeedsReserves = (flags & FLAG_NEEDS_RESERVES) != 0;

        // Compute transient slot once and reuse for both tload and clear (saves keccak)
        uint256 slot;
        if (doImpact || doVol || feeNeedsReserves) {
            slot = _reservesSlot(poolId);
        }

        // Optimization: Use cached pre-swap reserves + deltas to compute post-swap reserves
        // This avoids a second ZAMM.pools() call when beforeAction cached the reserves
        uint112 r0After;
        uint112 r1After;

        if (doImpact || doVol) {
            (bool ok, uint112 r0Before, uint112 r1Before) = _tloadReservesAt(slot);

            if (ok) {
                // Cached reserves available: compute post-swap reserves from deltas
                // Formula: after = before + delta (positive delta = added to pool)
                // ASSUMPTION: ZAMM delta convention matches: trader sells -> positive delta (pool gains)
                // If ZAMM changes convention, defensive fallback below will catch invalid results
                int256 a0 = int256(uint256(r0Before)) + d0;
                int256 a1 = int256(uint256(r1Before)) + d1;

                // Defensive: if weird deltas, fallback to ZAMM.pools()
                if (
                    a0 > 0 && a1 > 0 && uint256(a0) <= type(uint112).max
                        && uint256(a1) <= type(uint112).max
                ) {
                    r0After = uint112(uint256(a0));
                    r1After = uint112(uint256(a1));
                } else {
                    // Fallback: deltas produced invalid reserves
                    (r0After, r1After,,,,,) = ZAMM.pools(poolId);
                }
            } else {
                // No cache available (caching condition wasn't met in beforeAction)
                (r0After, r1After,,,,,) = ZAMM.pools(poolId);
            }
        }

        // Check price impact if enabled
        if (doImpact) {
            uint256 impact =
                _calculatePriceImpactFromReserves(m.yesIsToken0, r0After, r1After, d0, d1);
            if (impact > uint256(c.maxPriceImpactBps)) revert PriceImpactTooHigh();
        }

        // Record post-trade price snapshot for volatility tracking if enabled
        if (doVol) {
            PoolData memory poolData = PoolData({
                reserve0: r0After, reserve1: r1After, valid: (r0After > 0 && r1After > 0)
            });
            _recordPriceSnapshot(poolId, m.yesIsToken0, poolData);
        }

        // Clear transient cache to prevent stale reads in subsequent swaps within same tx
        // (Note: transient storage auto-clears at tx end, so this only matters for multi-swap txs)
        // Only clear if cache was potentially written (avoids unnecessary tstore when unused)
        if (doImpact || doVol || feeNeedsReserves) {
            assembly ("memory-safe") {
                tstore(slot, 0)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                     CONFIG FLAG HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @dev Extract closeWindowMode from bits 2-3 of flags (0-3)
    function _getCloseWindowMode(uint16 flags) internal pure returns (uint8) {
        return uint8((flags >> 2) & 0x03);
    }

    /// @dev Extract skew curve exponent from bits 0-1 of extraFlags (0-3)
    function _getSkewCurveExponent(Config storage c) internal view returns (uint8) {
        return uint8(c.extraFlags & 0x03);
    }

    /// @dev Extract bootstrap decay mode from bits 2-3 of extraFlags (0-3)
    function _getBootstrapDecayMode(Config storage c) internal view returns (uint8) {
        return uint8((c.extraFlags >> 2) & 0x03);
    }

    // ═══════════════════════════════════════════════════════════
    //                     MARKET HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @dev Get NO token ID matching PAMM's formula: keccak256("PMARKET:NO", marketId)
    function _getNoId(uint256 marketId) internal pure returns (uint256 noId) {
        assembly ("memory-safe") {
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, marketId)
            noId := keccak256(0x00, 0x2a)
        }
    }

    /// @dev Get YES/NO reserves based on ZAMM's canonical ordering (id0 < id1)
    /// @dev Takes yesIsToken0 from caller to avoid redundant storage reads
    function _getReserves(bool yesIsToken0, uint256 r0, uint256 r1)
        internal
        pure
        returns (uint256 yesReserve, uint256 noReserve)
    {
        yesReserve = yesIsToken0 ? r0 : r1;
        noReserve = yesIsToken0 ? r1 : r0;
    }

    /// @dev Calculate market probability in basis points (P(YES) = NO_reserve / total)
    function _getProbability(uint256 yesReserve, uint256 noReserve)
        internal
        pure
        returns (uint256)
    {
        uint256 total = yesReserve + noReserve;
        return total == 0 ? 5000 : (noReserve * BPS_DENOMINATOR) / total;
    }

    // ═══════════════════════════════════════════════════════════
    //                     FEE COMPUTATION
    // ═══════════════════════════════════════════════════════════

    /// @dev Check if selector is a swap operation
    /// @dev Assumes ZAMM is immutable with only these 3 swap entrypoints (swapExactIn, swapExactOut, swap)
    /// @dev Non-swap operations (addLiquidity/removeLiquidity) return 0 fee and skip enforcement
    function _isSwap(bytes4 sig) internal pure returns (bool) {
        return sig == SWAP_EXACT_IN || sig == SWAP_EXACT_OUT || sig == SWAP_LOWLEVEL;
    }

    function _cfg(uint256 marketId) internal view returns (Config storage c) {
        Config storage mc = marketConfig[marketId];
        // Use feeCapBps==0 as sentinel: 0 means "use default" (validated to never be 0 for custom configs)
        if (mc.feeCapBps != 0) return mc;
        return defaultConfig;
    }

    /// @dev Reverts if market closed/resolved, or in close window with mode 0
    function _enforceOpenCached(Config storage c, uint16 flags, bool resolved, uint64 close)
        internal
        view
    {
        uint256 nowTs = block.timestamp;

        // Always halt if market is closed or resolved
        if (resolved || (close != 0 && nowTs >= uint256(close))) {
            revert MarketClosed();
        }

        // Check close window based on mode:
        // Mode 0: halt (revert)
        // Mode 1: charge closeWindowFeeBps (don't revert, handled in fee computation)
        // Mode 2: charge minFeeBps (don't revert, handled in fee computation)
        // Mode 3: dynamic (continue to normal fee calculation)
        uint8 closeWindowMode = _getCloseWindowMode(flags);
        if (
            closeWindowMode == 0 && c.closeWindow != 0 && close > 0
                && nowTs + uint256(c.closeWindow) >= uint256(close)
        ) {
            revert MarketClosed();
        }
    }

    function _computeFee(uint256 poolId) internal view returns (uint256) {
        Meta memory m = meta[poolId];
        if (!m.active) return BPS_DENOMINATOR + 1; // Sentinel: unregistered = halted

        uint256 marketId = poolToMarket[poolId];
        (, bool resolved,,, uint64 close,,) = PAMM.markets(marketId);

        return _computeFeeWithMarketData(poolId, m, marketId, resolved, close);
    }

    /// @dev Fee computation with pre-loaded PAMM market data (avoids redundant external call)
    function _computeFeeWithMarketData(
        uint256 poolId,
        Meta memory m,
        uint256 marketId,
        bool resolved,
        uint64 close
    ) internal view returns (uint256) {
        Config storage c = _cfg(marketId);
        uint256 nowTs = block.timestamp;

        // Return sentinel if market closed or resolved (trading halted)
        if (resolved || (close != 0 && nowTs >= uint256(close))) return BPS_DENOMINATOR + 1;

        // Read flags once to avoid repeated storage access
        uint16 flags = c.flags;

        // Check if in close window
        bool inCloseWindow =
            c.closeWindow != 0 && close > 0 && nowTs + uint256(c.closeWindow) >= uint256(close);

        if (inCloseWindow) {
            uint8 closeWindowMode = _getCloseWindowMode(flags);
            if (closeWindowMode == 0) return BPS_DENOMINATOR + 1; // Sentinel for halted
            if (closeWindowMode == 1) {
                return _min(uint256(c.closeWindowFeeBps), uint256(c.feeCapBps));
            }
            if (closeWindowMode == 2) return c.minFeeBps;
            // Mode 3: continue to dynamic calculation
        }

        // Fetch pool data only if needed for skew or asymmetric fees
        PoolData memory poolData;
        if ((flags & FLAG_NEEDS_RESERVES) != 0) poolData = _getPoolData(poolId);

        uint256 total;
        unchecked {
            total = (flags & FLAG_BOOTSTRAP) != 0
                ? _bootstrapFee(uint256(m.start), nowTs, c)
                : c.minFeeBps;
            if ((flags & FLAG_SKEW) != 0) total += _skewFee(m.yesIsToken0, c, poolData);
            if ((flags & FLAG_ASYMMETRIC) != 0) {
                total += _asymmetricFee(m.yesIsToken0, c, poolData);
            }
            if ((flags & FLAG_VOLATILITY) != 0) total += _volatilityFee(poolId, c);
        }

        return total > c.feeCapBps ? c.feeCapBps : total;
    }

    /// @dev Optimized fee computation that accepts pre-loaded pool data and flags
    /// @dev Avoids redundant c.flags SLOAD and transient cache reads
    /// @dev Used by beforeAction after reserves are cached
    function _computeFeeCachedWithPoolData(
        uint256 poolId,
        Meta memory m,
        Config storage c,
        uint16 flags,
        bool resolved,
        uint64 close,
        PoolData memory poolData,
        bool hasPoolData
    ) internal view returns (uint256) {
        uint256 nowTs = block.timestamp;

        // Return sentinel if market closed or resolved (trading halted)
        if (resolved || (close != 0 && nowTs >= uint256(close))) return BPS_DENOMINATOR + 1;

        // Check if in close window
        bool inCloseWindow =
            c.closeWindow != 0 && close > 0 && nowTs + uint256(c.closeWindow) >= uint256(close);

        if (inCloseWindow) {
            uint8 closeWindowMode = _getCloseWindowMode(flags);
            // Note: mode 0 not handled here because _enforceOpenCached() already reverted for it
            if (closeWindowMode == 1) {
                return _min(uint256(c.closeWindowFeeBps), uint256(c.feeCapBps));
            }
            if (closeWindowMode == 2) return c.minFeeBps;
            // Mode 3: fall through to dynamic calculation
        }

        // Compute dynamic fee, using pre-loaded poolData if available
        // Only fetch reserves if needed and not already provided
        if ((flags & FLAG_NEEDS_RESERVES) != 0 && !hasPoolData) {
            poolData = _getPoolData(poolId);
        }

        uint256 total;
        unchecked {
            total = (flags & FLAG_BOOTSTRAP) != 0
                ? _bootstrapFee(uint256(m.start), nowTs, c)
                : c.minFeeBps;
            if ((flags & FLAG_SKEW) != 0) total += _skewFee(m.yesIsToken0, c, poolData);
            if ((flags & FLAG_ASYMMETRIC) != 0) {
                total += _asymmetricFee(m.yesIsToken0, c, poolData);
            }
            if ((flags & FLAG_VOLATILITY) != 0) total += _volatilityFee(poolId, c);
        }

        return total > c.feeCapBps ? c.feeCapBps : total;
    }

    /// @dev Fetch pool data once to avoid multiple external calls
    /// @dev Prefers transient cache if available (set in beforeAction when afterAction will also need reserves)
    function _getPoolData(uint256 poolId) internal view returns (PoolData memory data) {
        (bool ok, uint112 r0, uint112 r1) = _tloadReserves(poolId);
        if (!ok) {
            (r0, r1,,,,,) = ZAMM.pools(poolId);
        }
        data.reserve0 = r0;
        data.reserve1 = r1;
        // ZAMM guarantees both reserves > 0 for swappable pools (checked via InsufficientLiquidity)
        data.valid = (r0 > 0 && r1 > 0);
    }

    /// @dev Bootstrap fee with configurable decay curve (linear/cubic/sqrt/ease-in)
    function _bootstrapFee(uint256 start, uint256 nowTs, Config storage c)
        internal
        view
        returns (uint256)
    {
        if (c.bootstrapWindow == 0) return c.minFeeBps;
        if (nowTs <= start) return c.maxFeeBps;

        unchecked {
            uint256 elapsed = nowTs - start; // Safe: nowTs > start
            if (elapsed >= uint256(c.bootstrapWindow)) return c.minFeeBps;

            uint256 range = uint256(c.maxFeeBps) - uint256(c.minFeeBps); // Safe: validated
            uint256 progressBps = (elapsed * 10000) / uint256(c.bootstrapWindow);

            // Apply decay curve: 0=linear, 1=cubic, 2=sqrt, 3=ease-in
            uint8 mode = _getBootstrapDecayMode(c);
            uint256 ratio;

            if (mode == 0) {
                ratio = progressBps; // Linear
            } else if (mode == 1) {
                // Cubic decay: ratio = 1 - (1-x)^3, where x = progressBps/10000
                // r = (1-x) * 10000, so ratio = 10000 - r^3 / 10000^2
                uint256 r = 10000 - progressBps;
                ratio = 10000 - (r * r * r) / BPS_SQUARED;
            } else if (mode == 2) {
                ratio = _sqrt(progressBps * 10000); // Sqrt: fast start, slow end
            } else {
                ratio = 10000 - _sqrt((10000 - progressBps) * 10000); // Ease-in: slow start, fast end
            }

            return uint256(c.maxFeeBps) - ((range * ratio) / 10000);
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            z := 181
            let r := shl(7, lt(0xffffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffffff, shr(r, x))))
            z := shl(shr(1, r), z)
            z := shr(18, mul(z, add(shr(r, x), 65536)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := sub(z, lt(div(x, z), z))
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Skew fee with configurable curve (linear/quadratic/cubic/quartic)
    function _skewFee(bool yesIsToken0, Config storage c, PoolData memory poolData)
        internal
        view
        returns (uint256)
    {
        if (!poolData.valid) return 0;

        (uint256 yesReserve, uint256 noReserve) =
            _getReserves(yesIsToken0, uint256(poolData.reserve0), uint256(poolData.reserve1));
        uint256 pBps = _getProbability(yesReserve, noReserve);

        // All arithmetic is safe: pBps ∈ [0,10000], maxSkewFeeBps ≤ 10000, ratio ≤ 10000
        unchecked {
            uint256 skew = pBps > 5000 ? (pBps - 5000) : (5000 - pBps);
            uint256 ref = uint256(c.skewRefBps);
            if (skew >= ref) return c.maxSkewFeeBps;

            uint256 ratio = (skew * 10000) / ref;
            uint8 exp = _getSkewCurveExponent(c);

            // Apply curve: 0=linear, 1=quadratic, 2=cubic, 3=quartic
            if (exp == 0) return (uint256(c.maxSkewFeeBps) * ratio) / 10000;
            if (exp == 1) return (uint256(c.maxSkewFeeBps) * ratio * ratio) / BPS_SQUARED;
            if (exp == 2) {
                return (uint256(c.maxSkewFeeBps) * ratio * ratio * ratio) / BPS_CUBED;
            }
            return (uint256(c.maxSkewFeeBps) * ratio * ratio * ratio * ratio) / BPS_QUARTIC;
        }
    }

    /// @dev Linear fee scaling with pool imbalance (complements non-linear skewFee)
    function _asymmetricFee(bool yesIsToken0, Config storage c, PoolData memory poolData)
        internal
        view
        returns (uint256)
    {
        if (!poolData.valid) return 0;

        (uint256 yesReserve, uint256 noReserve) =
            _getReserves(yesIsToken0, uint256(poolData.reserve0), uint256(poolData.reserve1));
        uint256 pBps = _getProbability(yesReserve, noReserve);

        // Safe: pBps ∈ [0,10000], asymmetricFeeBps ≤ 10000, deviation ≤ 5000
        // Max product: 10000 * 5000 = 50,000,000
        unchecked {
            uint256 deviation = pBps > 5000 ? (pBps - 5000) : (5000 - pBps);
            return (uint256(c.asymmetricFeeBps) * deviation) / 5000;
        }
    }

    /// @dev Extra fee during high volatility (uses recent snapshots within volatilityWindow)
    /// @dev Optimized: single-pass assembly scan (10 SLOADs) with algebraic variance formula
    /// @dev Assumes PriceSnapshot packing: uint64 timestamp (bits 0-63) + uint32 priceBps (bits 64-95)
    function _volatilityFee(uint256 poolId, Config storage c) internal view returns (uint256) {
        // Calculate cutoff timestamp (0 = no staleness check, use all snapshots)
        uint256 vw = uint256(c.volatilityWindow);
        uint256 cutoff = (vw == 0 || vw > block.timestamp) ? 0 : block.timestamp - vw;

        uint256 count;
        uint256 sum;
        uint256 sumSq;

        // Single pass over 10 snapshots, reading each slot once:
        // - count = number of included snapshots
        // - sum   = Σ priceBps
        // - sumSq = Σ priceBps²
        assembly ("memory-safe") {
            // Compute base slot: keccak256(abi.encode(poolId, priceHistory.slot))
            mstore(0x00, poolId)
            mstore(0x20, priceHistory.slot)
            let base := keccak256(0x00, 0x40)

            for { let i := 0 } lt(i, 10) { i := add(i, 1) } {
                let w := sload(add(base, i))

                // PriceSnapshot layout in single slot:
                // timestamp: uint64 in bits [0..63]
                // priceBps:  uint32 in bits [64..95]
                let ts := and(w, 0xFFFFFFFFFFFFFFFF)
                if ts {
                    // Include if cutoff == 0 OR ts >= cutoff
                    if or(iszero(cutoff), iszero(lt(ts, cutoff))) {
                        let p := and(shr(64, w), 0xFFFFFFFF)
                        sum := add(sum, p)
                        sumSq := add(sumSq, mul(p, p))
                        count := add(count, 1)
                    }
                }
            }
        }

        if (count < 3) return 0;

        uint256 mean = sum / count;
        if (mean == 0) return 0;

        // Algebraic variance formula:
        // Σ(p-mean)² = sumSq - 2*mean*sum + count*mean²
        // Note: Integer division in mean may cause intermediate underflow in unchecked block,
        // but modular arithmetic (mod 2^256) produces correct variance result. Mathematically,
        // variance ≥ 0 always holds, and even if wraparound occurs, the final fee is safely
        // capped by volatilityFeeBps.
        uint256 varianceSum;
        unchecked {
            varianceSum = sumSq - (2 * mean * sum) + (count * mean * mean);
        }
        uint256 variance = varianceSum / count;

        // Safe: sqrt(variance) ≤ 10000 (max priceBps), so * 100 ≤ 1,000,000
        uint256 volatilityPct;
        unchecked {
            volatilityPct = (_sqrt(variance) * 100) / mean;
        }

        if (volatilityPct >= 10) return c.volatilityFeeBps;
        if (volatilityPct <= 2) return 0;

        unchecked {
            return (uint256(c.volatilityFeeBps) * (volatilityPct - 2)) / 8;
        }
    }

    /// @dev Record current price snapshot for volatility tracking (with MEV protection)
    /// @dev Only records one snapshot per block to prevent intra-block manipulation
    function _recordPriceSnapshot(uint256 poolId, bool yesIsToken0, PoolData memory poolData)
        internal
    {
        if (!poolData.valid) return;

        // MEV protection: Only record once per block
        if (lastSnapshotBlock[poolId] == block.number) {
            return; // Already recorded a snapshot this block
        }

        (uint256 yesReserve, uint256 noReserve) =
            _getReserves(yesIsToken0, uint256(poolData.reserve0), uint256(poolData.reserve1));
        uint256 priceBps = _getProbability(yesReserve, noReserve);

        uint8 idx = priceHistoryIndex[poolId];
        priceHistory[poolId][idx] =
            PriceSnapshot({timestamp: uint64(block.timestamp), priceBps: uint32(priceBps)});

        // Advance circular buffer index (avoid modulo: cheaper conditional)
        uint8 nextIdx = idx == 9 ? 0 : idx + 1;
        priceHistoryIndex[poolId] = nextIdx;
        lastSnapshotBlock[poolId] = block.number;
    }

    /// @dev Calculate price impact as probability delta from provided reserves
    /// @param yesIsToken0 Whether YES token is token0 (from Meta)
    /// @param r0 Current reserve0 (after trade)
    /// @param r1 Current reserve1 (after trade)
    /// @param d0 Reserve0 change (positive=added, negative=removed)
    /// @param d1 Reserve1 change (positive=added, negative=removed)
    /// @return impact Impact in bps
    function _calculatePriceImpactFromReserves(
        bool yesIsToken0,
        uint112 r0,
        uint112 r1,
        int256 d0,
        int256 d1
    ) internal pure returns (uint256) {
        if ((d0 == 0 && d1 == 0) || r0 == 0 || r1 == 0) return 0;

        // Reconstruct reserves before trade: Before = After - delta
        // Positive delta means tokens added to pool, negative means removed
        // Note: No unchecked block for robustness against unexpected ZAMM deltas
        int256 b0_signed = int256(uint256(r0)) - d0;
        int256 b1_signed = int256(uint256(r1)) - d1;

        // If reconstruction fails (invalid deltas), return max impact to block trade
        // Returning 0 would bypass the impact check, which is unsafe
        if (b0_signed <= 0 || b1_signed <= 0) return type(uint256).max;

        uint256 b0 = uint256(b0_signed);
        uint256 b1 = uint256(b1_signed);

        // Convert to YES/NO reserves and calculate probability delta
        (uint256 yesAfter, uint256 noAfter) = _getReserves(yesIsToken0, uint256(r0), uint256(r1));
        (uint256 yesBefore, uint256 noBefore) = _getReserves(yesIsToken0, b0, b1);

        uint256 pBefore = _getProbability(yesBefore, noBefore);
        uint256 pAfter = _getProbability(yesAfter, noAfter);

        // Return absolute probability change in basis points
        unchecked {
            return pAfter > pBefore ? (pAfter - pBefore) : (pBefore - pAfter);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                     VIEW HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @notice Get market probability in basis points
    function getMarketProbability(uint256 poolId) public view returns (uint256 probabilityBps) {
        if (!meta[poolId].active) return BPS_DENOMINATOR + 1; // Sentinel for unregistered pool
        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);
        bool yesIsToken0 = meta[poolId].yesIsToken0;
        (uint256 yesReserve, uint256 noReserve) =
            _getReserves(yesIsToken0, uint256(r0), uint256(r1));
        return _getProbability(yesReserve, noReserve);
    }

    /// @notice Get poolId for a marketId (reverse of poolToMarket mapping)
    /// @dev Computes the canonical poolId using this hook's feeOrHook value
    /// @param marketId The market to query
    /// @return poolId The computed pool ID (0 if market not registered with this hook)
    function getPoolIdForMarket(uint256 marketId) public view returns (uint256 poolId) {
        uint256 feeHook = feeOrHook();
        IPAMM.PoolKey memory k = PAMM.poolKey(marketId, feeHook);
        poolId = uint256(keccak256(abi.encode(k.id0, k.id1, k.token0, k.token1, k.feeOrHook)));
        // Return 0 if not registered (caller can check meta[poolId].active if needed)
        if (!meta[poolId].active) return 0;
    }

    /// @notice Get bootstrap period progress for a pool
    /// @dev Returns timing info for bootstrap fee decay. Useful for UIs showing decay progress.
    /// @param poolId The pool to query
    /// @return startTime Bootstrap start timestamp (when pool was registered)
    /// @return windowSeconds Total bootstrap window duration
    /// @return progressBps Progress through bootstrap (0=just started, 10000=complete)
    /// @return currentFeeBps Current bootstrap fee component (decays from maxFeeBps to minFeeBps)
    function getBootstrapProgress(uint256 poolId)
        public
        view
        returns (uint64 startTime, uint32 windowSeconds, uint16 progressBps, uint16 currentFeeBps)
    {
        Meta memory m = meta[poolId];
        if (!m.active) return (0, 0, 0, 0);

        uint256 marketId = poolToMarket[poolId];
        Config storage c = _cfg(marketId);

        startTime = m.start;
        windowSeconds = c.bootstrapWindow;

        // If bootstrap not enabled or no window, return complete
        if ((c.flags & FLAG_BOOTSTRAP) == 0 || windowSeconds == 0) {
            return (startTime, windowSeconds, 10000, c.minFeeBps);
        }

        uint256 nowTs = block.timestamp;
        if (nowTs <= startTime) {
            return (startTime, windowSeconds, 0, c.maxFeeBps);
        }

        uint256 elapsed = nowTs - startTime;
        if (elapsed >= windowSeconds) {
            return (startTime, windowSeconds, 10000, c.minFeeBps);
        }

        // Calculate progress and current fee
        progressBps = uint16((elapsed * 10000) / windowSeconds);
        currentFeeBps = uint16(_bootstrapFee(startTime, nowTs, c));
    }

    /// @notice Get breakdown of fee components for transparency
    /// @dev Shows each fee component separately. Useful for debugging and UI display.
    /// @param poolId The pool to query
    /// @return baseFee Base fee (minFeeBps when not in bootstrap)
    /// @return bootstrapFee Additional bootstrap fee component (decays over time)
    /// @return skewFee Skew-based fee component
    /// @return asymmetricFee Asymmetric/directional fee component
    /// @return volatilityFee Volatility-based fee component
    /// @return totalFee Sum of all components (capped at feeCapBps)
    /// @return feeCapBps Maximum fee cap
    function getFeeBreakdown(uint256 poolId)
        public
        view
        returns (
            uint16 baseFee,
            uint16 bootstrapFee,
            uint16 skewFee,
            uint16 asymmetricFee,
            uint16 volatilityFee,
            uint16 totalFee,
            uint16 feeCapBps
        )
    {
        Meta memory m = meta[poolId];
        if (!m.active) return (0, 0, 0, 0, 0, 0, 0);

        uint256 marketId = poolToMarket[poolId];
        Config storage c = _cfg(marketId);
        uint16 flags = c.flags;
        feeCapBps = c.feeCapBps;

        // Check if market is halted (return zeros except feeCapBps)
        (, bool resolved,,, uint64 close,,) = PAMM.markets(marketId);
        uint256 nowTs = block.timestamp;
        if (resolved || (close != 0 && nowTs >= uint256(close))) {
            return (0, 0, 0, 0, 0, 0, feeCapBps);
        }

        // Base fee
        baseFee = c.minFeeBps;

        // Bootstrap component (on top of base)
        if ((flags & FLAG_BOOTSTRAP) != 0) {
            uint256 fullBootstrap = _bootstrapFee(uint256(m.start), nowTs, c);
            // bootstrapFee is the amount above minFeeBps
            if (fullBootstrap > baseFee) {
                bootstrapFee = uint16(fullBootstrap - baseFee);
            }
        }

        // Skew and asymmetric fees need reserves
        PoolData memory poolData;
        if ((flags & FLAG_NEEDS_RESERVES) != 0) {
            poolData = _getPoolData(poolId);
        }

        if ((flags & FLAG_SKEW) != 0) {
            skewFee = uint16(_skewFee(m.yesIsToken0, c, poolData));
        }

        if ((flags & FLAG_ASYMMETRIC) != 0) {
            asymmetricFee = uint16(_asymmetricFee(m.yesIsToken0, c, poolData));
        }

        if ((flags & FLAG_VOLATILITY) != 0) {
            volatilityFee = uint16(_volatilityFee(poolId, c));
        }

        // Total (capped)
        uint256 sum = uint256(baseFee) + bootstrapFee + skewFee + asymmetricFee + volatilityFee;
        totalFee = sum > feeCapBps ? feeCapBps : uint16(sum);
    }

    /// @notice Get volatility price history for a pool
    /// @param poolId The pool to query
    /// @return timestamps Array of 10 snapshot timestamps (0 = empty slot)
    /// @return prices Array of 10 snapshot prices in bps (0-10000)
    /// @return currentIndex Current write position in circular buffer
    /// @return validCount Number of non-empty snapshots
    function getPriceHistory(uint256 poolId)
        public
        view
        returns (
            uint64[10] memory timestamps,
            uint32[10] memory prices,
            uint8 currentIndex,
            uint8 validCount
        )
    {
        currentIndex = priceHistoryIndex[poolId];
        for (uint8 i; i != 10; ++i) {
            PriceSnapshot memory snap = priceHistory[poolId][i];
            timestamps[i] = snap.timestamp;
            prices[i] = snap.priceBps;
            if (snap.timestamp != 0) ++validCount;
        }
    }

    /// @notice Get volatility metrics for a pool
    /// @param poolId The pool to query
    /// @return volatilityPct Coefficient of variation as percentage (0-100+)
    /// @return snapshotCount Number of snapshots used in calculation
    /// @return meanPriceBps Mean price in basis points
    function getVolatility(uint256 poolId)
        public
        view
        returns (uint256 volatilityPct, uint8 snapshotCount, uint256 meanPriceBps)
    {
        if (!meta[poolId].active) return (0, 0, 0);

        uint256 marketId = poolToMarket[poolId];
        Config storage c = _cfg(marketId);

        uint256 vw = uint256(c.volatilityWindow);
        uint256 cutoff = (vw == 0 || vw > block.timestamp) ? 0 : block.timestamp - vw;

        uint256 sum;
        uint256 sumSq;

        assembly ("memory-safe") {
            mstore(0x00, poolId)
            mstore(0x20, priceHistory.slot)
            let base := keccak256(0x00, 0x40)

            for { let i := 0 } lt(i, 10) { i := add(i, 1) } {
                let w := sload(add(base, i))
                let ts := and(w, 0xFFFFFFFFFFFFFFFF)
                if ts {
                    if or(iszero(cutoff), iszero(lt(ts, cutoff))) {
                        let p := and(shr(64, w), 0xFFFFFFFF)
                        sum := add(sum, p)
                        sumSq := add(sumSq, mul(p, p))
                        snapshotCount := add(snapshotCount, 1)
                    }
                }
            }
        }

        if (snapshotCount < 3) return (0, snapshotCount, 0);

        meanPriceBps = sum / snapshotCount;
        if (meanPriceBps == 0) return (0, snapshotCount, 0);

        // Algebraic variance formula (same as _volatilityFee): safe despite potential underflow
        uint256 varianceSum;
        unchecked {
            varianceSum =
                sumSq - (2 * meanPriceBps * sum) + (snapshotCount * meanPriceBps * meanPriceBps);
        }
        uint256 variance = varianceSum / snapshotCount;

        unchecked {
            volatilityPct = (_sqrt(variance) * 100) / meanPriceBps;
        }
    }

    /// @notice Calculate expected price impact for a hypothetical trade as probability delta
    /// @param poolId The pool to check
    /// @param amountIn Amount of input tokens
    /// @param zeroForOne Direction of swap (true = sell token0 for token1)
    /// @param feeBps Fee in basis points to use for calculation
    /// @return impactBps Probability change in basis points (10000 = 100%), or sentinel (10001) if fee is invalid
    function simulatePriceImpact(uint256 poolId, uint256 amountIn, bool zeroForOne, uint256 feeBps)
        public
        view
        returns (uint256 impactBps)
    {
        if (!meta[poolId].active) return BPS_DENOMINATOR + 1; // Sentinel for unregistered pool
        // Guard against invalid fees to prevent underflow in amountInWithFee calculation
        if (feeBps > BPS_DENOMINATOR) return BPS_DENOMINATOR + 1; // Return sentinel for invalid/halted
        if (feeBps == BPS_DENOMINATOR) return 0; // 100% fee = no output = no trade possible

        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(poolId);

        if (amountIn == 0 || r0 == 0 || r1 == 0) return 0;

        // Load yesIsToken0 once for all _getReserves calls
        bool yesIsToken0 = meta[poolId].yesIsToken0;

        // Compute probability BEFORE trade (from current reserves)
        (uint256 yesBefore, uint256 noBefore) = _getReserves(yesIsToken0, uint256(r0), uint256(r1));
        uint256 pBefore = _getProbability(yesBefore, noBefore);

        // Simulate AFTER reserves and compute probability
        uint256 amountOut;
        uint256 r0After;
        uint256 r1After;

        if (zeroForOne) {
            amountOut = _getAmountOutView(amountIn, r0, r1, feeBps);
            if (amountOut == 0 || amountOut >= r1) return 0;
            // Safe: amountOut < r1 validated above
            unchecked {
                r0After = uint256(r0) + amountIn;
                r1After = uint256(r1) - amountOut;
            }
        } else {
            amountOut = _getAmountOutView(amountIn, r1, r0, feeBps);
            if (amountOut == 0 || amountOut >= r0) return 0;
            // Safe: amountOut < r0 validated above
            unchecked {
                r0After = uint256(r0) - amountOut;
                r1After = uint256(r1) + amountIn;
            }
        }

        (uint256 yesAfter, uint256 noAfter) = _getReserves(yesIsToken0, r0After, r1After);
        uint256 pAfter = _getProbability(yesAfter, noAfter);

        // Return absolute probability change
        unchecked {
            return pAfter > pBefore ? (pAfter - pBefore) : (pBefore - pAfter);
        }
    }

    /// @dev View-only version of ZAMM's _getAmountOut for price impact simulation
    function _getAmountOutView(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 amountInWithFee = amountIn * (BPS_DENOMINATOR - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * BPS_DENOMINATOR) + amountInWithFee;
        return numerator / denominator;
    }

    /// @notice Check if market is open for trading
    function isMarketOpen(uint256 poolId) public view returns (bool) {
        Meta memory m = meta[poolId];
        if (!m.active) return false; // Unregistered pools not allowed

        uint256 marketId = poolToMarket[poolId];
        Config storage c = _cfg(marketId);

        (, bool resolved,,, uint64 close,,) = PAMM.markets(marketId);
        uint256 nowTs = block.timestamp;

        // Market closed/resolved halt
        if (resolved || (close != 0 && nowTs >= uint256(close))) {
            return false;
        }

        // Close window: only halt if mode is 0 (halt mode)
        // Modes 1, 2, and 3 still allow trading (with fixed/min/dynamic fees)
        uint16 flags = c.flags;
        uint8 closeWindowMode = _getCloseWindowMode(flags);
        bool inCloseWindow =
            c.closeWindow != 0 && close > 0 && nowTs + uint256(c.closeWindow) >= uint256(close);

        if (inCloseWindow && closeWindowMode == 0) {
            return false;
        }

        return true;
    }

    /// @notice Get market status bundle (for router to avoid multiple PAMM.markets() calls)
    /// @param marketId The market ID to query
    /// @return active True if hook has registered pool for this market
    /// @return resolved True if market is resolved
    /// @return close Market close timestamp
    /// @return closeWindow Close window duration in seconds
    /// @return closeMode Close window mode (0=halt, 1=fixed, 2=min, 3=dynamic)
    function getMarketStatus(uint256 marketId)
        public
        view
        returns (bool active, bool resolved, uint64 close, uint16 closeWindow, uint8 closeMode)
    {
        // Check if market is registered
        uint256 feeHook = feeOrHook();
        IPAMM.PoolKey memory k = PAMM.poolKey(marketId, feeHook);
        uint256 poolId =
            uint256(keccak256(abi.encode(k.id0, k.id1, k.token0, k.token1, k.feeOrHook)));
        active = meta[poolId].active;

        // Get PAMM market data
        (, resolved,,, close,,) = PAMM.markets(marketId);

        // Get hook config
        Config storage c = _cfg(marketId);
        closeWindow = c.closeWindow;
        closeMode = _getCloseWindowMode(c.flags);
    }

    /// @notice Get pool state for UIs
    function getPoolState(uint256 poolId)
        public
        view
        returns (
            uint256 marketId,
            uint112 reserve0,
            uint112 reserve1,
            uint256 currentFeeBps,
            uint64 closeTime,
            bool isActive
        )
    {
        marketId = poolToMarket[poolId];
        (reserve0, reserve1,,,,,) = ZAMM.pools(poolId);
        Meta memory m = meta[poolId];
        isActive = m.active;

        if (isActive) {
            // Single PAMM call for both closeTime and fee computation
            (, bool resolved,,, uint64 liveClose,,) = PAMM.markets(marketId);
            closeTime = liveClose;
            currentFeeBps = _computeFeeWithMarketData(poolId, m, marketId, resolved, liveClose);
        } else {
            currentFeeBps = BPS_DENOMINATOR + 1; // Sentinel for unregistered
        }
    }

    // ═══════════════════════════════════════════════════════════
    //                     INTERNAL VALIDATION
    // ═══════════════════════════════════════════════════════════

    function _validateConfig(Config calldata cfg) internal pure {
        // Core fee validations
        if (cfg.minFeeBps > BPS_DENOMINATOR) revert InvalidConfig();
        if (cfg.maxFeeBps > BPS_DENOMINATOR) revert InvalidConfig();
        if (cfg.maxSkewFeeBps > BPS_DENOMINATOR) revert InvalidConfig();
        if (cfg.minFeeBps > cfg.maxFeeBps) revert InvalidConfig();
        if (cfg.feeCapBps == 0) revert InvalidConfig(); // 0 is reserved as sentinel for "use default config"
        if (cfg.feeCapBps >= BPS_DENOMINATOR) revert InvalidConfig(); // Must be < 10000 (100% fee would halt trading)
        if (cfg.skewRefBps == 0 || cfg.skewRefBps > 5000) revert InvalidConfig(); // Must be (0, 5000]

        // Additional fee validations (uint16 types, max 65535 bps = 655.35%)
        if (cfg.asymmetricFeeBps > BPS_DENOMINATOR) revert InvalidConfig();
        if (cfg.maxPriceImpactBps > BPS_DENOMINATOR) revert InvalidConfig();
        if (cfg.volatilityFeeBps > BPS_DENOMINATOR) revert InvalidConfig();
        if (cfg.closeWindowFeeBps > BPS_DENOMINATOR) revert InvalidConfig();

        // feeCapBps must be at least minFeeBps to be meaningful
        // Note: Cap can be lower than theoretical max fee sum - it will bind and limit total fees
        if (cfg.feeCapBps < cfg.minFeeBps) revert InvalidConfig();

        // Validate closeWindowMode from flags (bits 2-3)
        uint16 closeWindowMode = (cfg.flags >> 2) & 0x03;
        // Mode 1 requires closeWindowFeeBps to be set
        if (closeWindowMode == 1 && cfg.closeWindowFeeBps == 0) revert InvalidConfig();
        // closeWindow is uint16 with max value 65535 seconds (~18 hours), no need for upper bound check

        // Validate extraFlags curve modes (bits 0-3, values 0-3 each, automatically valid)
        // No validation needed for skewCurveExponent and bootstrapDecayMode as they're 2-bit values (0-3)
    }
}
