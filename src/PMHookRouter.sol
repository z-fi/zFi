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

    function deposit(address token, uint256 id, uint256 amount) external payable;

    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

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

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    function recoverTransientBalance(address token, uint256 id, address to)
        external
        returns (uint256 amount);
}

interface IPAMM {
    function balanceOf(address account, uint256 id) external view returns (uint256);

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

    function getNoId(uint256 marketId) external pure returns (uint256);

    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);

    function setOperator(address operator, bool approved) external returns (bool);

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool);

    function split(uint256 marketId, uint256 amount, address to) external payable;
    function merge(uint256 marketId, uint256 amount, address to) external;

    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);

    function claim(uint256 marketId, address to) external returns (uint256 shares, uint256 payout);
}

interface IPMFeeHook {
    function registerMarket(uint256 marketId) external returns (uint256 poolId);
    function getCurrentFeeBps(uint256 poolId) external view returns (uint256);
    function getCloseWindow(uint256 marketId) external view returns (uint256);
}

bytes4 constant ERR_TRANSFER = 0x2929f974;
bytes4 constant ERR_APPROVE_FAILED = 0x3e3f8f73;
bytes4 constant ERR_COMPUTATION = 0x05832717;

/// @title PMHookRouter
/// @notice Prediction market router with vault market-making
/// @dev Execution: best of (vault OTC vs AMM) first, then remainder to other venue, then mint fallback
///      LPs earn principal (seller-side) + spread fees (90% when balanced, 70% when imbalanced).
///      Only markets created via bootstrapMarket() are supported.
/// @dev REQUIRES EIP-1153 (transient storage) - only deploy on chains with Cancun support
contract PMHookRouter {
    address constant ETH = address(0);

    uint256 constant FLAG_BEFORE = 1 << 255;
    uint256 constant FLAG_AFTER = 1 << 254;

    // Error selectors (ERR_TRANSFER, ERR_APPROVE_FAILED, ERR_COMPUTATION are file-level)
    bytes4 constant ERR_SHARES = 0x9325dafd;
    bytes4 constant ERR_VALIDATION = 0x077a9c33;
    bytes4 constant ERR_TIMING = 0x3703bac9;
    bytes4 constant ERR_STATE = 0xd06e7808;
    bytes4 constant ERR_REENTRANCY = 0xab143c06;
    bytes4 constant ERR_WITHDRAWAL_TOO_SOON = 0xff56d9bd;

    // pools(uint256) = 0xac4afa38 = bytes4(keccak256("pools(uint256)"))
    // markets(uint256) = 0xb1283e77 = bytes4(keccak256("markets(uint256)"))
    uint256 constant SELECTOR_POOLS_SHIFTED = 0xac4afa38 << 224;
    uint256 constant SELECTOR_MARKETS_SHIFTED = 0xb1283e77 << 224;

    // Transient storage slots (EIP-1153)
    uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268;
    uint256 constant ETH_SPENT_SLOT = 0x929eee149b4bd21269;
    uint256 constant MULTICALL_DEPTH_SLOT = 0x929eee149b4bd2126a;

    // Source tags (precomputed to save bytecode vs bytes4("xxx"))
    bytes4 constant SRC_OTC = 0x6f746300; // "otc\0"
    bytes4 constant SRC_AMM = 0x616d6d00; // "amm\0"
    bytes4 constant SRC_MINT = 0x6d696e74; // "mint"
    bytes4 constant SRC_MULT = 0x6d756c74; // "mult"

    IZAMM constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    function _guardEnter() internal {
        assembly ("memory-safe") {
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, ERR_REENTRANCY)
                revert(0x00, 0x04)
            }
            tstore(REENTRANCY_SLOT, address())
        }
    }

    function _guardExit() internal {
        assembly ("memory-safe") {
            tstore(REENTRANCY_SLOT, 0)
            // Note: ETH_SPENT_SLOT is only used in multicall context and cleared there
        }
    }

    // ============ Helper Functions ============

    /// @dev Helper to derive pool ID from key
    function _derivePoolId(IZAMM.PoolKey memory k) internal pure returns (uint256 id) {
        assembly ("memory-safe") {
            // PoolKey: 5 × 32-byte words = 160 bytes (0xa0)
            id := keccak256(k, 0xa0)
        }
    }

    /// @dev Helper to check uint112 overflow
    function _checkU112Overflow(uint256 a, uint256 b) internal pure {
        if (a + b > MAX_UINT112) _revert(ERR_SHARES, 3); // SharesOverflow
    }

    /// @dev Generic revert helper - consolidated for bytecode savings
    function _revert(bytes4 selector, uint8 code) internal pure {
        assembly ("memory-safe") {
            mstore(0x00, selector)
            mstore(0x04, code)
            revert(0x00, 0x24)
        }
    }

    /// @dev Low-level staticcall helper for uint256 returns (avoids try/catch overhead)
    function _staticUint(address target, bytes4 sel, uint256 arg)
        internal
        view
        returns (bool ok, uint256 out)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, sel) // bytes4 is already left-aligned (high bytes), no shift needed
            mstore(add(m, 0x04), arg)
            ok := staticcall(gas(), target, m, 0x24, m, 0x20)
            // Gate ok on correct return size - fallback with no return should be treated as failure
            ok := and(ok, eq(returndatasize(), 0x20))
            if ok { out := mload(m) }
        }
    }

    /// @dev Low-level staticcall helper for ZAMM.pools (avoids try/catch overhead)
    function _staticPools(uint256 poolId)
        internal
        view
        returns (
            bool ok,
            uint112 r0,
            uint112 r1,
            uint32 blockTimestampLast,
            uint256 price0,
            uint256 price1
        )
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, SELECTOR_POOLS_SHIFTED)
            mstore(add(m, 0x04), poolId)
            ok := staticcall(gas(), 0x000000000000040470635EB91b7CE4D132D616eD, m, 0x24, m, 0xe0)
            // Gate ok on correct return size for defensive coding
            ok := and(ok, eq(returndatasize(), 0xe0))
            if ok {
                r0 := mload(m)
                r1 := mload(add(m, 0x20))
                blockTimestampLast := mload(add(m, 0x40))
                price0 := mload(add(m, 0x60))
                price1 := mload(add(m, 0x80))
            }
        }
    }

    /// @dev Low-level staticcall helper for PAMM.markets (avoids tuple destructuring overhead)
    function _staticMarkets(uint256 marketId)
        internal
        view
        returns (bool resolved, bool outcome, bool canClose, uint64 close, address collateral)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, SELECTOR_MARKETS_SHIFTED)
            mstore(add(m, 0x04), marketId)
            // 7 return words = 0xe0 bytes
            let ok :=
                staticcall(gas(), 0x000000000044bfe6c2BBFeD8862973E0612f07C0, m, 0x24, m, 0xe0)
            if iszero(and(ok, eq(returndatasize(), 0xe0))) {
                mstore(0x00, ERR_STATE)
                mstore(0x04, 2)
                revert(0x00, 0x24)
            }
            // resolver @ 0x00 (unused)
            // resolved @ 0x20
            // outcome @ 0x40
            // canClose @ 0x60
            // close @ 0x80
            // collateral @ 0xa0
            // collateralLocked @ 0xc0 (unused)
            resolved := mload(add(m, 0x20))
            outcome := mload(add(m, 0x40))
            canClose := mload(add(m, 0x60))
            close := mload(add(m, 0x80))
            collateral := mload(add(m, 0xa0))
        }
    }

    function _refundExcessETH(address collateral, uint256 amountValidated) internal {
        assembly ("memory-safe") {
            // Only process if collateral == ETH (address(0))
            if iszero(collateral) {
                // Skip refund if we're inside a multicall (depth > 0)
                // Multicall will handle the final refund
                if iszero(tload(MULTICALL_DEPTH_SLOT)) {
                    // Standalone refund: use amountValidated (the single required amount for this call)
                    // ETH_SPENT_SLOT is only tracked in multicall; multicall handles refund separately
                    if gt(callvalue(), amountValidated) {
                        // Note: Reentrancy guard already active from _guardEnter
                        // No need to modify REENTRANCY_SLOT here
                        if iszero(
                            call(
                                gas(),
                                caller(),
                                sub(callvalue(), amountValidated),
                                codesize(),
                                0x00,
                                codesize(),
                                0x00
                            )
                        ) {
                            mstore(0x00, ERR_TRANSFER)
                            mstore(0x04, 2)
                            revert(0x00, 0x24)
                        }
                    }
                }
            }
        }
    }

    function _validateETHAmount(address collateral, uint256 requiredAmount) internal {
        assembly ("memory-safe") {
            if iszero(collateral) {
                switch tload(MULTICALL_DEPTH_SLOT)
                case 0 {
                    // Standalone call: simple validation against msg.value
                    if lt(callvalue(), requiredAmount) {
                        mstore(0x00, ERR_VALIDATION)
                        mstore(0x04, 6)
                        revert(0x00, 0x24)
                    }
                }
                default {
                    // Multicall: track cumulative ETH requirement
                    let prev := tload(ETH_SPENT_SLOT)
                    let cumulativeRequired := add(prev, requiredAmount)
                    // Check for overflow (only when adding non-zero amount)
                    if mul(requiredAmount, lt(cumulativeRequired, prev)) {
                        mstore(0x00, ERR_VALIDATION)
                        mstore(0x04, 0)
                        revert(0x00, 0x24)
                    }
                    if lt(callvalue(), cumulativeRequired) {
                        mstore(0x00, ERR_VALIDATION)
                        mstore(0x04, 6)
                        revert(0x00, 0x24)
                    }
                    tstore(ETH_SPENT_SLOT, cumulativeRequired)
                }
            }
            // If non-ETH collateral but ETH sent, revert (unless in multicall)
            if and(iszero(iszero(collateral)), iszero(iszero(callvalue()))) {
                if iszero(tload(MULTICALL_DEPTH_SLOT)) {
                    mstore(0x00, ERR_VALIDATION)
                    mstore(0x04, 6)
                    revert(0x00, 0x24)
                }
            }
        }
    }

    /// @dev Helper to transfer collateral (handles ETH vs ERC20)
    function _transferCollateral(address collateral, address to, uint256 amount) internal {
        if (collateral == ETH) safeTransferETH(to, amount);
        else safeTransfer(collateral, to, amount);
    }

    /// @dev Refund unused collateral to caller, adjusting multicall ETH tracking
    /// @dev Use this when returning collateral that was previously validated via _validateETHAmount
    function _refundCollateralToCaller(address collateral, uint256 amount) internal {
        if (collateral == ETH) {
            assembly ("memory-safe") {
                switch tload(MULTICALL_DEPTH_SLOT)
                case 0 {
                    // Not in multicall: transfer immediately
                    if iszero(call(gas(), caller(), amount, codesize(), 0x00, codesize(), 0x00)) {
                        mstore(0x00, ERR_TRANSFER)
                        mstore(0x04, 2)
                        revert(0x00, 0x24)
                    }
                }
                default {
                    // In multicall: decrement tracking only, defer actual transfer to multicall exit
                    let spent := tload(ETH_SPENT_SLOT)
                    if spent {
                        let decrement := amount
                        if gt(decrement, spent) { decrement := spent }
                        tstore(ETH_SPENT_SLOT, sub(spent, decrement))
                    }
                }
            }
        } else {
            safeTransfer(collateral, msg.sender, amount);
        }
    }

    /// @dev Helper to split shares via PAMM (handles ETH vs ERC20)
    function _splitShares(uint256 marketId, uint256 amount, address collateral) internal {
        if (collateral != ETH) ensureApproval(collateral, address(PAMM));
        PAMM.split{value: collateral == ETH ? amount : 0}(marketId, amount, address(this));
    }

    /// @notice Calculate LP vs budget allocation based on imbalance
    /// @param preYes YES inventory
    /// @param preNo NO inventory
    /// @param buyYes Side being bought
    /// @param close Market close timestamp
    /// @param feeAmount Amount to split
    /// @return toLPs Amount allocated to LPs
    /// @return toRemaining Amount allocated to budget
    function _calculateFeeSplit(
        uint112 preYes,
        uint112 preNo,
        bool buyYes,
        uint64 close,
        uint256 feeAmount
    ) internal view returns (uint256 toLPs, uint256 toRemaining) {
        (, uint256 imbalanceBps) = _calculateDynamicSpread(preYes, preNo, buyYes, close);
        uint256 lpSplitBps =
            imbalanceBps > 7500 ? LP_FEE_SPLIT_BPS_IMBALANCED : LP_FEE_SPLIT_BPS_BALANCED;
        toLPs = mulDiv(feeAmount, lpSplitBps, BPS_DENOM);
        unchecked {
            toRemaining = feeAmount - toLPs;
        }
    }

    /// @notice Split fees between LPs and rebalance budget using pre-trade snapshot
    /// @param marketId Market ID
    /// @param feeAmount Total fees to distribute
    /// @param preYes Pre-merge YES inventory
    /// @param preNo Pre-merge NO inventory
    /// @param twap P(YES) = NO/(YES+NO) from TWAP [1-9999]
    function _distributeFeesSplit(
        uint256 marketId,
        uint256 feeAmount,
        uint112 preYes,
        uint112 preNo,
        uint256 twap
    ) internal {
        // Dynamic budget split based on inventory imbalance
        uint64 close = _getClose(marketId);
        // Use yesScarce as fake "buyYes" to compute symmetric imbalance for non-directional fees
        bool yesScarce = preYes < preNo;
        (uint256 toLPs, uint256 toRebalance) =
            _calculateFeeSplit(preYes, preNo, yesScarce, close, feeAmount);
        if (!_addVaultFeesSymmetricWithSnapshot(marketId, toLPs, preYes, preNo, twap)) {
            unchecked {
                rebalanceCollateralBudget[marketId] += toLPs + toRebalance;
                return;
            }
        }
        unchecked {
            rebalanceCollateralBudget[marketId] += toRebalance;
        }
    }

    /// @notice Split OTC proceeds into principal and spread
    /// @param marketId Market ID
    /// @param buyYes True for YES, false for NO
    /// @param sharesOut Shares sold by vault
    /// @param collateralUsed Total collateral paid
    /// @param pYes P(YES) = NO/(YES+NO) from TWAP [1-9999]
    /// @param preYesInv YES inventory before trade
    /// @param preNoInv NO inventory before trade
    /// @return principal Fair value at TWAP
    /// @return spreadFee Spread above TWAP
    function _accountVaultOTCProceeds(
        uint256 marketId,
        bool buyYes,
        uint256 sharesOut,
        uint256 collateralUsed,
        uint256 pYes,
        uint112 preYesInv,
        uint112 preNoInv
    ) internal returns (uint256 principal, uint256 spreadFee) {
        if (pYes == 0) _revert(ERR_COMPUTATION, 3); // TWAPRequired
        if (pYes >= 10000) pYes = 9999;

        assembly ("memory-safe") {
            // Fair principal: buyYes ? pYes : (10000 - pYes)
            let fairBps := xor(pYes, mul(xor(pYes, sub(10000, pYes)), iszero(buyYes)))
            principal := div(add(mul(sharesOut, fairBps), 9999), BPS_DENOM)
        }

        if (collateralUsed < principal) _revert(ERR_VALIDATION, 0); // Underpayment (guards unchecked sub)
        unchecked {
            spreadFee = collateralUsed - principal;
        }

        // Principal to seller-side LPs
        uint256 sellerLP = buyYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];

        _addVaultFeesWithSnapshot(marketId, buyYes, principal, sellerLP);

        if (spreadFee == 0) return (principal, 0);

        // Dynamic budget split based on inventory imbalance
        uint64 close = _getClose(marketId);
        (uint256 toLPs, uint256 toBudget) =
            _calculateFeeSplit(preYesInv, preNoInv, buyYes, close, spreadFee);

        if (!_distributeOtcSpreadScarcityCapped(marketId, toLPs, preYesInv, preNoInv)) {
            unchecked {
                toBudget += toLPs;
            }
        }

        unchecked {
            rebalanceCollateralBudget[marketId] += toBudget;
        }
    }

    function _depositToVaultSide(uint256 marketId, bool isYes, uint256 shares, address receiver)
        internal
        returns (uint256 vaultSharesMinted)
    {
        BootstrapVault storage vault = bootstrapVaults[marketId];
        uint256 totalVaultShares =
            isYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];
        uint256 totalAssets = isYes ? vault.yesShares : vault.noShares;

        // VaultDepleted (4): totalVaultShares != 0 && totalAssets == 0
        // OrphanedAssets (5): totalVaultShares == 0 && totalAssets != 0
        assembly ("memory-safe") {
            let tvsZero := iszero(totalVaultShares)
            let taZero := iszero(totalAssets)
            if xor(tvsZero, taZero) {
                mstore(0x00, ERR_STATE)
                mstore(0x04, add(4, tvsZero)) // 4 if depleted, 5 if orphaned
                revert(0x00, 0x24)
            }
            if gt(shares, MAX_UINT112) {
                mstore(0x00, ERR_SHARES)
                mstore(0x04, 3)
                revert(0x00, 0x24)
            }
        }

        if ((totalVaultShares | totalAssets) == 0) {
            vaultSharesMinted = shares;
        } else {
            vaultSharesMinted = fullMulDiv(shares, totalVaultShares, totalAssets);
        }

        assembly ("memory-safe") {
            // ZeroVaultShares (1) or VaultSharesOverflow (4)
            if or(iszero(vaultSharesMinted), gt(vaultSharesMinted, MAX_UINT112)) {
                mstore(0x00, ERR_SHARES)
                mstore(0x04, add(1, mul(3, gt(vaultSharesMinted, 0)))) // 1 if zero, 4 if overflow
                revert(0x00, 0x24)
            }
        }

        UserVaultPosition storage position = vaultPositions[marketId][receiver];

        // Capture existing vault shares before updating (for weighted cooldown)
        uint256 existingVaultShares;
        unchecked {
            existingVaultShares = uint256(position.yesVaultShares) + uint256(position.noVaultShares); // Safe: 2 * uint112 fits uint256
        }

        // Update vault shares with overflow check and packed struct update
        {
            uint256 currentVaultShares = isYes ? vault.yesShares : vault.noShares;
            uint256 currentPosShares = isYes ? position.yesVaultShares : position.noVaultShares;
            _checkU112Overflow(currentVaultShares, shares);
            _checkU112Overflow(currentPosShares, vaultSharesMinted);

            // Update vault packed struct
            _addVaultShares(vault, isYes, shares);

            unchecked {
                if (isYes) {
                    totalYesVaultShares[marketId] += vaultSharesMinted;
                    position.yesVaultShares += uint112(vaultSharesMinted);
                    position.yesRewardDebt += mulDiv(
                        vaultSharesMinted, accYesCollateralPerShare[marketId], 1e18
                    );
                } else {
                    totalNoVaultShares[marketId] += vaultSharesMinted;
                    position.noVaultShares += uint112(vaultSharesMinted);
                    position.noRewardDebt += mulDiv(
                        vaultSharesMinted, accNoCollateralPerShare[marketId], 1e18
                    );
                }
            }
        }

        // Cooldown logic: Always update receiver's cooldown to prevent bypass
        // - First deposit: set cooldown to current timestamp
        // - Existing position: use weighted average (or reset in final window)
        // Note: Third-party deposits will update receiver's cooldown (prevents cooldown bypass)
        if (existingVaultShares == 0) {
            position.lastDepositTime = uint32(block.timestamp);
        } else {
            uint64 close = _getClose(marketId);
            bool inFinalWindow = block.timestamp > close || (close - block.timestamp) < 43200;

            if (inFinalWindow && msg.sender == receiver) {
                position.lastDepositTime = uint32(block.timestamp);
            } else {
                uint256 oldTime = position.lastDepositTime;
                // HARDENING: Prevent cooldown bypass via zero timestamp in corrupted state
                // If existingShares > 0 but timestamp == 0, set to current time
                if (oldTime == 0) oldTime = block.timestamp;
                unchecked {
                    uint256 newTotal = existingVaultShares + vaultSharesMinted; // Safe: bounded by uint112 inputs
                    uint256 weightedTime =
                        (existingVaultShares * oldTime + vaultSharesMinted * block.timestamp)
                            / newTotal;
                    position.lastDepositTime = uint32(weightedTime);
                }
            }
        }

        // Update vault lastActivity
        vault.lastActivity = uint32(block.timestamp);
    }

    // ============ Bootstrap Vault Storage ============

    struct BootstrapVault {
        uint112 yesShares;
        uint112 noShares;
        uint32 lastActivity;
    }

    // poolId != 0 indicates registered market
    mapping(uint256 => uint256) public canonicalPoolId;
    mapping(uint256 => uint256) public canonicalFeeOrHook;
    mapping(uint256 => BootstrapVault) public bootstrapVaults;
    mapping(uint256 => uint256) public rebalanceCollateralBudget;

    // ============ TWAP Tracking ============
    // Two-observation sliding window (minimum 30min) using ZAMM pool cumulatives
    // Updates: permissionless after 30min, or opportunistic during trades
    // Reader uses obs0->obs1 if obs1 is recent, or obs1->current if obs1 is stale

    struct TWAPObservations {
        uint32 timestamp0; // Older checkpoint (4 bytes) \
        uint32 timestamp1; // Newer checkpoint (4 bytes)  |
        uint32 cachedTwapBps; // Cached TWAP value [1-9999] or 0 if unavailable (4 bytes) |-- packed in slot 0
        uint32 cacheBlockNum; // Block number of cache (4 bytes)       /
        uint256 cumulative0; // ZAMM's cumulative at timestamp0 (slot 1: 32 bytes)
        uint256 cumulative1; // ZAMM's cumulative at timestamp1 (slot 2: 32 bytes)
    }

    mapping(uint256 => TWAPObservations) public twapObservations;

    uint32 constant MIN_TWAP_UPDATE_INTERVAL = 30 minutes;

    // ============ Vault LP Accounting ============
    // ERC4626-style accounting with reward debt pattern
    // OTC principal -> seller-side LPs; spread -> LPs (90% balanced, 70% imbalanced) + budget

    struct UserVaultPosition {
        uint112 yesVaultShares; // 14 bytes  \
        uint112 noVaultShares; // 14 bytes   |-- packed in slot 0
        uint32 lastDepositTime; // 4 bytes   /
        uint256 yesRewardDebt; // 32 bytes -- slot 1
        uint256 noRewardDebt; // 32 bytes -- slot 2
    }

    mapping(uint256 => uint256) public totalYesVaultShares;
    mapping(uint256 => uint256) public totalNoVaultShares;
    mapping(uint256 => uint256) public accYesCollateralPerShare;
    mapping(uint256 => uint256) public accNoCollateralPerShare;
    mapping(uint256 => mapping(address => UserVaultPosition)) public vaultPositions;

    event VaultDeposit(
        uint256 indexed marketId,
        address indexed user,
        bool isYes,
        uint256 sharesDeposited,
        uint256 vaultSharesMinted
    );

    event VaultWithdraw(
        uint256 indexed marketId,
        address indexed user,
        bool isYes,
        uint256 vaultSharesBurned,
        uint256 sharesReturned,
        uint256 feesEarned
    );

    event VaultFeesHarvested(
        uint256 indexed marketId, address indexed user, bool isYes, uint256 feesEarned
    );

    event VaultOTCFill(
        uint256 indexed marketId,
        address indexed trader,
        address recipient,
        bool buyYes,
        uint256 collateralIn,
        uint256 sharesOut,
        uint256 effectivePriceBps,
        uint256 principal,
        uint256 spreadFee
    );

    event BudgetSettled(uint256 indexed marketId, uint256 budgetDistributed, uint256 sharesMerged);

    event VaultWinningSharesRedeemed(
        uint256 indexed marketId, bool outcome, uint256 sharesRedeemed, uint256 payoutToDAO
    );

    event MarketFinalized(
        uint256 indexed marketId,
        uint256 totalToDAO,
        uint256 sharesRedeemed,
        uint256 budgetDistributed
    );

    event Rebalanced(
        uint256 indexed marketId, uint256 collateralUsed, uint256 sharesAcquired, bool yesWasLower
    );

    // Economic Parameters
    // Vault OTC spread: 1% base + up to 4% imbalance boost + up to 2% time boost = 7% theoretical max
    // Capped at 5% to keep vault competitive with AMM for larger trades
    uint256 constant MIN_ABSOLUTE_SPREAD_BPS = 20; // 0.2% minimum absolute spread
    uint256 constant MAX_SPREAD_BPS = 500; // 5% cap (binds when imbalance+time boosts exceed 4%)
    uint256 constant DEFAULT_FEE_BPS = 30; // 0.3% fallback AMM fee
    uint256 constant LP_FEE_SPLIT_BPS_BALANCED = 9000; // 90% to LPs when balanced
    uint256 constant LP_FEE_SPLIT_BPS_IMBALANCED = 7000; // 70% to LPs when imbalanced
    uint256 constant BOOTSTRAP_WINDOW = 4 hours; // Mint path disabled within this window of close

    uint256 constant BPS_DENOM = 10_000;
    uint256 constant MAX_COLLATERAL_IN = type(uint256).max / BPS_DENOM;
    uint256 constant MAX_ACC_PER_SHARE = type(uint256).max / type(uint112).max;
    // 28 hex digits (112/4=28): verified equal to type(uint112).max
    uint256 constant MAX_UINT112 = 0xffffffffffffffffffffffffffff;
    uint256 constant MASK_LOWER_224 =
        0x00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    error WithdrawalTooSoon(uint256 remainingSeconds);
    error ComputationError(uint8 code);
    error ValidationError(uint8 code);
    error TransferError(uint8 code);
    error TimingError(uint8 code);
    error SharesError(uint8 code);
    error StateError(uint8 code);
    error ApproveFailed();
    error Reentrancy();

    constructor() payable {
        PAMM.setOperator(address(ZAMM), true);
    }

    receive() external payable {}

    // ============ Validation Helpers (Bytecode Optimization) ============

    /// @dev Revert if market is not registered
    function _requireRegistered(uint256 marketId) internal view {
        if (canonicalPoolId[marketId] == 0) _revert(ERR_STATE, 2); // MarketNotRegistered
    }

    /// @dev Revert if market is resolved or closed, return close time and collateral
    function _requireMarketOpen(uint256 marketId)
        internal
        view
        returns (uint64 close, address collateral)
    {
        bool resolved;
        (resolved,,, close, collateral) = _staticMarkets(marketId);
        if (resolved) _revert(ERR_STATE, 0); // MarketResolved
        // Check if market exists (close == 0 indicates nonexistent market)
        if (close == 0) _revert(ERR_STATE, 2); // MarketNotRegistered
        if (block.timestamp >= close) _revert(ERR_TIMING, 2); // MarketClosed
    }

    /// @dev Revert if deadline expired
    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) _revert(ERR_TIMING, 0); // Expired
    }

    /// @dev Check withdrawal cooldown (shared by withdraw and harvest)
    /// @dev Normal deposits: 6h cooldown. Late deposits (within 12h of close): 24h cooldown
    /// @dev Enforced even after market close to prevent end-of-market fee sniping
    function _checkWithdrawalCooldown(uint256 marketId) internal view {
        uint256 depositTime = vaultPositions[marketId][msg.sender].lastDepositTime;
        if (depositTime != 0) {
            uint64 close = _getClose(marketId);
            assembly ("memory-safe") {
                let inFinalWindow := or(gt(depositTime, close), lt(sub(close, depositTime), 43200))
                let elapsed := sub(timestamp(), depositTime)
                let required := mul(21600, add(1, mul(3, inFinalWindow)))
                if lt(elapsed, required) {
                    mstore(0x00, ERR_WITHDRAWAL_TOO_SOON)
                    mstore(0x04, sub(required, elapsed))
                    revert(0x00, 0x24)
                }
            }
        }
    }

    /// @dev Get NO token ID matching PAMM's formula: keccak256("PMARKET:NO", marketId)
    function _getNoId(uint256 marketId) internal pure returns (uint256 noId) {
        assembly ("memory-safe") {
            // keccak256(abi.encodePacked("PMARKET:NO", marketId))
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, marketId)
            noId := keccak256(0x00, 0x2a)
        }
    }

    /// @dev Get collateral address for a market
    function _getCollateral(uint256 marketId) internal view returns (address collateral) {
        (,,,, collateral) = _staticMarkets(marketId);
    }

    /// @dev Get close time for a market
    function _getClose(uint256 marketId) internal view returns (uint64 close) {
        (,,, close,) = _staticMarkets(marketId);
    }

    /// @dev Get pool reserves
    function _getReserves(uint256 poolId) internal view returns (uint112 r0, uint112 r1) {
        (, r0, r1,,,) = _staticPools(poolId);
    }

    /// @dev Helper to get shift and mask for vault shares based on isYes flag
    function _getShiftMask(bool isYes) internal pure returns (uint256 shift, uint256 mask) {
        assembly ("memory-safe") {
            shift := mul(iszero(isYes), 112)
            mask := shl(shift, MAX_UINT112)
        }
    }

    /// @dev Add shares to vault (isYes ? yesShares : noShares)
    function _addVaultShares(BootstrapVault storage vault, bool isYes, uint256 amount) internal {
        (uint256 shift, uint256 mask) = _getShiftMask(isYes);
        assembly ("memory-safe") {
            let vaultSlot := vault.slot
            let vaultData := sload(vaultSlot)
            let current := and(shr(shift, vaultData), MAX_UINT112)
            vaultData := or(and(vaultData, not(mask)), shl(shift, add(current, amount)))
            sstore(vaultSlot, vaultData)
        }
    }

    /// @dev Subtract shares from vault (isYes ? yesShares : noShares)
    function _subVaultShares(BootstrapVault storage vault, bool isYes, uint256 amount) internal {
        (uint256 shift, uint256 mask) = _getShiftMask(isYes);
        assembly ("memory-safe") {
            let vaultSlot := vault.slot
            let vaultData := sload(vaultSlot)
            let current := and(shr(shift, vaultData), MAX_UINT112)
            // Guard against underflow
            if gt(amount, current) {
                mstore(0x00, ERR_STATE)
                mstore(0x04, 5) // VaultUnderflow
                revert(0x00, 0x24)
            }
            vaultData := or(and(vaultData, not(mask)), shl(shift, sub(current, amount)))
            sstore(vaultSlot, vaultData)
        }
    }

    /// @dev Decrement both yes and no shares (for merge operations)
    function _decrementBothShares(BootstrapVault storage vault, uint256 amount) internal {
        assembly ("memory-safe") {
            let vaultSlot := vault.slot
            let vaultData := sload(vaultSlot)
            let yes := and(vaultData, MAX_UINT112)
            let no := and(shr(112, vaultData), MAX_UINT112)
            // Guard against underflow on both sides
            if or(gt(amount, yes), gt(amount, no)) {
                mstore(0x00, ERR_STATE)
                mstore(0x04, 5) // VaultUnderflow
                revert(0x00, 0x24)
            }
            vaultData := shl(224, shr(224, vaultData))
            vaultData := or(vaultData, sub(yes, amount))
            vaultData := or(vaultData, shl(112, sub(no, amount)))
            sstore(vaultSlot, vaultData)
        }
    }

    /// @dev Revert if market is not resolved, return outcome and collateral
    function _requireResolved(uint256 marketId)
        internal
        view
        returns (bool outcome, address collateral)
    {
        bool resolved;
        (resolved, outcome,,, collateral) = _staticMarkets(marketId);
        if (!resolved) _revert(ERR_STATE, 1); // MarketNotResolved
    }

    /// @dev Check if market is in close window
    /// @dev Uses hook's closeWindow if available and non-zero, otherwise defaults to 1 hour
    function _isInCloseWindow(uint256 marketId) internal view returns (bool inWindow) {
        uint64 close = _getClose(marketId);
        if (block.timestamp >= close) return false;

        uint256 closeWindow = 3600; // Default 1 hour (applied when hook returns 0 or unavailable)
        uint256 feeOrHook = canonicalFeeOrHook[marketId];
        if ((feeOrHook & (FLAG_BEFORE | FLAG_AFTER)) != 0) {
            (bool ok, uint256 hookWindow) =
                _staticUint(address(uint160(feeOrHook)), 0x5f598ac3, marketId);
            if (ok && hookWindow != 0) closeWindow = hookWindow;
        }

        assembly ("memory-safe") {
            inWindow := lt(sub(close, timestamp()), closeWindow)
        }
    }

    // ============ Multicall ============

    /// @notice Execute multiple calls in a single transaction
    function multicall(bytes[] calldata data) public payable returns (bytes[] memory results) {
        // Increment depth counter to prevent premature ETH refunds
        assembly ("memory-safe") {
            // Prevent reentrant entry into multicall while a guarded function is executing
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, ERR_REENTRANCY)
                revert(0x00, 0x04)
            }

            let depth := tload(MULTICALL_DEPTH_SLOT)
            tstore(MULTICALL_DEPTH_SLOT, add(depth, 1))
            // If entering outermost multicall, reset ETH tracking
            if iszero(depth) { tstore(ETH_SPENT_SLOT, 0) }
        }

        results = new bytes[](data.length);
        for (uint256 i; i != data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            assembly ("memory-safe") {
                if iszero(ok) { revert(add(result, 0x20), mload(result)) }
            }
            results[i] = result;
        }

        // Decrement depth and handle final ETH refund if exiting outermost multicall
        assembly ("memory-safe") {
            let depth := sub(tload(MULTICALL_DEPTH_SLOT), 1)
            tstore(MULTICALL_DEPTH_SLOT, depth)

            // Only the outermost multicall does final refund + clears ETH tracking
            if iszero(depth) {
                let totalSpent := tload(ETH_SPENT_SLOT)
                tstore(ETH_SPENT_SLOT, 0)

                // Only refund if we received more ETH than spent
                if gt(callvalue(), totalSpent) {
                    // Set reentrancy lock before external call
                    tstore(REENTRANCY_SLOT, address())
                    if iszero(
                        call(
                            gas(),
                            caller(),
                            sub(callvalue(), totalSpent),
                            codesize(),
                            0x00,
                            codesize(),
                            0x00
                        )
                    ) {
                        // Clear lock before revert
                        tstore(REENTRANCY_SLOT, 0)
                        mstore(0x00, ERR_TRANSFER)
                        mstore(0x04, 2)
                        revert(0x00, 0x24)
                    }
                    // Clear reentrancy lock after successful call
                    tstore(REENTRANCY_SLOT, 0)
                }
            }
        }
    }

    // ============ Permit ============

    /// @notice EIP-2612 permit for ERC20 tokens (use in multicall before operations)
    /// @param token The ERC20 token with permit support
    /// @param owner The token owner who signed the permit
    /// @param value Amount to approve to this contract
    /// @param deadline Permit deadline
    /// @param v Signature v
    /// @param r Signature r
    /// @param s Signature s
    function permit(
        address token,
        address owner,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        _guardEnter();
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xd505accf00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), value)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), v)
            mstore(add(m, 0xa4), r)
            mstore(add(m, 0xc4), s)

            let ok := call(gas(), token, 0, m, 0xe4, 0, 0)
            if iszero(ok) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }

            // Check return value (some tokens return bool)
            switch returndatasize()
            case 0 {} // No return data is fine
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) } // Returned false
            }
            default { revert(0, 0) } // Unexpected return size

            mstore(0x40, add(m, 0x100)) // Update free memory pointer (32-byte aligned)
        }
        _guardExit();
    }

    /// @notice DAI-style permit (use in multicall before operations)
    /// @param token The DAI-like token with permit support
    /// @param owner The token owner who signed the permit
    /// @param nonce Owner's current nonce
    /// @param deadline Permit deadline (0 = no expiry)
    /// @param allowed True to approve max, false to revoke
    /// @param v Signature v
    /// @param r Signature r
    /// @param s Signature s
    function permitDAI(
        address token,
        address owner,
        uint256 nonce,
        uint256 deadline,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        _guardEnter();
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x8fcbaf0c00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), nonce)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), allowed)
            mstore(add(m, 0xa4), v)
            mstore(add(m, 0xc4), r)
            mstore(add(m, 0xe4), s)

            let ok := call(gas(), token, 0, m, 0x104, 0, 0)
            if iszero(ok) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }

            // Check return value (some tokens return bool)
            switch returndatasize()
            case 0 {} // No return data is fine
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) } // Returned false
            }
            default { revert(0, 0) } // Unexpected return size

            mstore(0x40, add(m, 0x120)) // Update free memory pointer (32-byte aligned)
        }
        _guardExit();
    }

    // ============ Hook Integration ============

    function _buildKey(uint256 yesId, uint256 noId, uint256 feeOrHook)
        internal
        pure
        returns (IZAMM.PoolKey memory k, bool yesIsId0)
    {
        address pamm = address(PAMM);
        assembly ("memory-safe") {
            yesIsId0 := lt(yesId, noId)
            // k is at memory location k (returned as pointer)
            // PoolKey: id0, id1, token0, token1, feeOrHook
            mstore(k, xor(noId, mul(xor(noId, yesId), yesIsId0))) // id0
            mstore(add(k, 0x20), xor(yesId, mul(xor(yesId, noId), yesIsId0))) // id1
            mstore(add(k, 0x40), pamm) // token0
            mstore(add(k, 0x60), pamm) // token1
            mstore(add(k, 0x80), feeOrHook) // feeOrHook
        }
    }

    /// @dev Helper to select token IDs based on buy direction
    function _selectTokenIds(uint256 yesId, uint256 noId, bool buyYes)
        internal
        pure
        returns (uint256 swapId, uint256 desiredId)
    {
        assembly ("memory-safe") {
            swapId := xor(yesId, mul(xor(yesId, noId), buyYes))
            desiredId := xor(noId, mul(xor(noId, yesId), buyYes))
        }
    }

    function _registerMarket(address hook, uint256 marketId)
        internal
        returns (uint256 poolId, uint256 feeOrHook)
    {
        if (canonicalPoolId[marketId] != 0) _revert(ERR_STATE, 3); // MarketAlreadyRegistered

        poolId = IPMFeeHook(hook).registerMarket(marketId);
        feeOrHook = uint256(uint160(hook)) | FLAG_BEFORE | FLAG_AFTER;

        (IZAMM.PoolKey memory k,) = _buildKey(marketId, _getNoId(marketId), feeOrHook);
        uint256 derivedPoolId = _derivePoolId(k);
        if (poolId != derivedPoolId) _revert(ERR_COMPUTATION, 6); // HookInvalidPoolId

        canonicalPoolId[marketId] = poolId;
        canonicalFeeOrHook[marketId] = feeOrHook;
    }

    /// @notice Bootstrap market with initial liquidity and optional trade
    /// @param collateralForLP Liquidity for 50/50 AMM pool
    /// @param collateralForBuy Optional initial trade
    function bootstrapMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose,
        address hook,
        uint256 collateralForLP,
        bool buyYes,
        uint256 collateralForBuy,
        uint256 minSharesOut,
        address to,
        uint256 deadline
    )
        public
        payable
        returns (uint256 marketId, uint256 poolId, uint256 lpShares, uint256 sharesOut)
    {
        _guardEnter();
        _checkDeadline(deadline);
        if (block.timestamp >= close) _revert(ERR_VALIDATION, 7); // InvalidCloseTime
        if (collateralForLP == 0) _revert(ERR_VALIDATION, 1); // AmountZero

        assembly { if iszero(to) { to := caller() } }

        uint256 totalCollateral = collateralForLP + collateralForBuy;

        _validateETHAmount(collateral, totalCollateral);
        if (collateral != ETH && totalCollateral != 0) {
            safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
            ensureApproval(collateral, address(PAMM));
        }

        (marketId,) = PAMM.createMarket(description, resolver, collateral, close, canClose);

        (poolId,) = _registerMarket(hook, marketId);

        if (collateralForLP != 0) {
            _splitShares(marketId, collateralForLP, collateral);

            uint256 yesId = marketId;
            uint256 noId = _getNoId(marketId);

            ZAMM.deposit(address(PAMM), yesId, collateralForLP);
            ZAMM.deposit(address(PAMM), noId, collateralForLP);

            (IZAMM.PoolKey memory k,) =
                _buildKey(yesId, noId, uint256(uint160(hook)) | FLAG_BEFORE | FLAG_AFTER);

            (,, lpShares) =
                ZAMM.addLiquidity(k, collateralForLP, collateralForLP, 0, 0, to, deadline);

            ZAMM.recoverTransientBalance(address(PAMM), yesId, to);
            ZAMM.recoverTransientBalance(address(PAMM), noId, to);

            (uint256 initialCumulative, bool success) = _getCurrentCumulative(marketId);
            if (!success) _revert(ERR_COMPUTATION, 4); // TWAPInitFailed

            twapObservations[marketId] = TWAPObservations({
                timestamp0: uint32(block.timestamp),
                timestamp1: uint32(block.timestamp),
                cachedTwapBps: 0,
                cacheBlockNum: 0,
                cumulative0: initialCumulative,
                cumulative1: initialCumulative
            });
        }

        if (collateralForBuy != 0) {
            sharesOut = _bootstrapBuy(
                marketId, hook, collateral, buyYes, collateralForBuy, minSharesOut, to, deadline
            );
        }

        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    function _bootstrapBuy(
        uint256 marketId,
        address hook,
        address collateral,
        bool buyYes,
        uint256 collateralForBuy,
        uint256 minSharesOut,
        address to,
        uint256 deadline
    ) internal returns (uint256 sharesOut) {
        // Cache token IDs
        uint256 yesId = marketId;
        uint256 noId = _getNoId(marketId);

        _splitShares(marketId, collateralForBuy, collateral);

        (uint256 swapTokenId, uint256 desiredTokenId) = _selectTokenIds(yesId, noId, buyYes);

        ZAMM.deposit(address(PAMM), swapTokenId, collateralForBuy);

        (IZAMM.PoolKey memory k, bool yesIsId0) =
            _buildKey(yesId, noId, uint256(uint160(hook)) | FLAG_BEFORE | FLAG_AFTER);
        bool zeroForOne = buyYes ? !yesIsId0 : yesIsId0;

        // Require minimum 1 output to prevent value-destroying swaps where split shares are donated
        uint256 swappedShares =
            ZAMM.swapExactIn(k, collateralForBuy, 1, zeroForOne, address(this), deadline);

        sharesOut = collateralForBuy + swappedShares;
        if (sharesOut < minSharesOut) _revert(ERR_VALIDATION, 3); // InsufficientOutput
        PAMM.transfer(to, desiredTokenId, sharesOut);
    }

    /// @notice Buy shares via best-execution routing: (vault OTC vs AMM) => remainder => mint fallback
    /// @param marketId Market ID
    /// @param buyYes True for YES, false for NO
    /// @param collateralIn Collateral to spend
    /// @param minSharesOut Minimum shares (all venues combined)
    /// @param to Recipient
    /// @param deadline Deadline
    /// @return sharesOut Total shares acquired
    /// @return source Venue used ("otc"/"mint"/"amm"/"mult")
    /// @return vaultSharesMinted Vault shares from mint path
    function buyWithBootstrap(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        address to,
        uint256 deadline
    ) public payable returns (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted) {
        _guardEnter();
        (, address collateral) = _requireMarketOpen(marketId);
        _checkDeadline(deadline);
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1); // AmountZero
        if (collateralIn > MAX_COLLATERAL_IN) _revert(ERR_VALIDATION, 0); // Overflow
        assembly { if iszero(to) { to := caller() } }

        uint256 feeOrHook = canonicalFeeOrHook[marketId];
        uint256 poolId = canonicalPoolId[marketId];
        if (poolId == 0) _revert(ERR_STATE, 2); // MarketNotRegistered
        uint256 feeBps = _getPoolFeeBps(feeOrHook, poolId);
        if (feeBps >= 10000) _revert(ERR_TIMING, 2); // MarketClosed (halt mode)
        uint256 maxImpactBps = _getMaxPriceImpactBps(marketId);
        uint256 noId = _getNoId(marketId);
        // Take collateral from user (cached from _requireMarketOpen)
        _validateETHAmount(collateral, collateralIn);
        if (collateral != ETH && collateralIn != 0) {
            safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            ensureApproval(collateral, address(PAMM));
        }

        // Track remaining collateral and total output across venues
        uint256 remainingCollateral = collateralIn;
        uint256 totalSharesOut;
        uint8 venueCount; // Track how many venues were used

        BootstrapVault storage vault = bootstrapVaults[marketId];

        // Get quotes from both vault and AMM to determine best execution
        uint256 pYes = _getTWAPPrice(marketId);
        (uint256 vaultQuoteShares, uint256 vaultQuoteCollateral, bool vaultFillable) =
            _tryVaultOTCFill(marketId, buyYes, remainingCollateral, pYes);

        uint256 ammQuoteShares = _quoteAMMBuy(marketId, buyYes, remainingCollateral);

        // Determine venue priority based on best execution (total shares)
        // Compare: AMM-only vs (vault + AMM on remainder)
        // If vault is better: try vault first, then AMM, then mint
        // If AMM is better: try AMM first, then vault, then mint
        bool tryVaultFirst = false;
        if (vaultFillable && vaultQuoteShares != 0) {
            if (ammQuoteShares == 0) {
                // Only vault available
                tryVaultFirst = true;
            } else {
                // Quote AMM on remaining collateral after vault fill
                uint256 ammAfterVault = (vaultQuoteCollateral < remainingCollateral)
                    ? _quoteAMMBuy(marketId, buyYes, remainingCollateral - vaultQuoteCollateral)
                    : 0;

                // Compare total execution: vault+AMM vs AMM-only
                tryVaultFirst = (vaultQuoteShares + ammAfterVault >= ammQuoteShares);
            }
        }

        // Execute venues in order: primary -> secondary -> mint
        // tryVaultFirst: OTC -> AMM | !tryVaultFirst: AMM -> OTC
        for (uint256 pass; pass < 2; ++pass) {
            bool doOTC = (pass == 0) == tryVaultFirst;

            if (doOTC) {
                // Vault OTC
                if (remainingCollateral != 0 && (pass == 0 || vaultFillable)) {
                    (uint256 otcShares, uint256 otcCollateralUsed, uint8 otcVenue) =
                        _executeVaultOTCFill(marketId, buyYes, remainingCollateral, pYes, to, noId);
                    if (otcVenue != 0) {
                        unchecked {
                            totalSharesOut += otcShares;
                            remainingCollateral -= otcCollateralUsed;
                            venueCount += otcVenue;
                        }
                        if (source == bytes4(0)) source = SRC_OTC;
                    }
                }
            } else {
                // AMM - recompute quote on current remainder (original quote may be stale after OTC)
                uint256 ammQuoteNow = _quoteAMMBuy(marketId, buyYes, remainingCollateral);
                if (remainingCollateral != 0 && ammQuoteNow != 0) {
                    uint256 safeAMMCollateral = maxImpactBps != 0
                        ? _findMaxAMMUnderImpact(
                            marketId, buyYes, remainingCollateral, feeBps, maxImpactBps
                        )
                        : remainingCollateral;

                    if (safeAMMCollateral != 0) {
                        uint256 ammSharesOut = _executeAMMSwap(
                            marketId,
                            buyYes,
                            safeAMMCollateral,
                            to,
                            deadline,
                            noId,
                            feeOrHook,
                            collateral
                        );
                        unchecked {
                            totalSharesOut += ammSharesOut;
                            ++venueCount;
                            if (source == bytes4(0)) source = SRC_AMM;
                            remainingCollateral -= safeAMMCollateral;
                        }
                    }
                }
            }
        }

        // Mint (fallback if no AMM liquidity or specific conditions met)
        bool mintCanSatisfyMin = (minSharesOut <= totalSharesOut + remainingCollateral);
        if (
            remainingCollateral != 0 && mintCanSatisfyMin
                && _shouldUseVaultMint(marketId, vault, buyYes)
        ) {
            uint256 oppositeVaultShares =
                !buyYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];
            uint256 oppositeAssets = !buyYes ? vault.yesShares : vault.noShares;

            // Only proceed if invariant holds: both zero (first deposit) OR both non-zero (normal deposit)
            // Prevents orphaned (shares=0, assets!=0) and depleted (shares!=0, assets=0) states
            bool tvsZero = (oppositeVaultShares == 0);
            bool taZero = (oppositeAssets == 0);
            if (tvsZero == taZero) {
                _splitShares(marketId, remainingCollateral, collateral);

                PAMM.transfer(to, buyYes ? marketId : noId, remainingCollateral);

                unchecked {
                    uint256 vaultSharesCreated =
                        _depositToVaultSide(marketId, !buyYes, remainingCollateral, to);
                    vaultSharesMinted += vaultSharesCreated;
                    emit VaultDeposit(
                        marketId, to, !buyYes, remainingCollateral, vaultSharesCreated
                    );
                    totalSharesOut += remainingCollateral;
                    remainingCollateral = 0;
                    ++venueCount;
                }
                if (source == bytes4(0)) source = SRC_MINT;
            }
        }

        if (totalSharesOut < minSharesOut) _revert(ERR_VALIDATION, 2); // Slippage

        if (venueCount > 1) source = SRC_MULT;

        if (remainingCollateral != 0) {
            _refundCollateralToCaller(collateral, remainingCollateral);
        }

        _refundExcessETH(collateral, collateralIn);

        _guardExit();
        return (totalSharesOut, source, vaultSharesMinted);
    }

    /// @notice Sell shares with optimal routing: compares vault OTC vs AMM
    /// @return collateralOut Total collateral received
    /// @return source Execution source ("otc", "amm", or "mult")
    function sellWithBootstrap(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256 minOut,
        address to,
        uint256 deadline
    ) public returns (uint256 collateralOut, bytes4 source) {
        _guardEnter();
        (, address collateral) = _requireMarketOpen(marketId);
        _checkDeadline(deadline);
        if (sharesIn == 0) _revert(ERR_VALIDATION, 1);
        assembly ("memory-safe") { if iszero(to) { to := caller() } }

        uint256 noId = _getNoId(marketId);
        PAMM.transferFrom(msg.sender, address(this), sellYes ? marketId : noId, sharesIn);

        BootstrapVault storage vault = bootstrapVaults[marketId];
        uint256 remaining = sharesIn;

        // Try vault OTC first if we're on scarce side AND budget has collateral
        // Block vault OTC in close window (protects TWAP-based pricing near close)
        if (sellYes == (vault.yesShares < vault.noShares) && !_isInCloseWindow(marketId)) {
            uint256 budget = rebalanceCollateralBudget[marketId];
            uint256 pYes = budget != 0 ? _getTWAPPrice(marketId) : 0;
            // Block vault OTC if market halted (feeBps >= 10000 signals halt, consistent with buy-side)
            if (
                pYes != 0
                    && _getPoolFeeBps(canonicalFeeOrHook[marketId], canonicalPoolId[marketId])
                        >= 10000
            ) {
                pYes = 0;
            }
            if (pYes != 0) {
                uint256 p;
                uint256 s;
                uint256 cap;
                uint256 filled;
                unchecked {
                    p = sellYes ? pYes : (10000 - pYes);
                    s = p / 50;
                    if (s < 10) s = 10;
                }
                if (p > s) {
                    unchecked {
                        cap = (sellYes ? vault.noShares : vault.yesShares) * 3 / 10;
                        filled = remaining < cap ? remaining : cap;
                        collateralOut = filled * (p - s) / BPS_DENOM;
                    }
                    if (collateralOut > budget) {
                        unchecked {
                            // Cap by budget, then recalc filled, then recalc collateralOut for fairness
                            filled = (budget * BPS_DENOM) / (p - s);
                            collateralOut = filled * (p - s) / BPS_DENOM;
                        }
                    }

                    // Safety check: prevent 0-collateral fills (protects sellers from donating shares)
                    if (collateralOut == 0) filled = 0;

                    // Safety check: prevent OrphanedAssets - only allow OTC fill if LP shares exist on vault's buying side
                    if (filled != 0) {
                        uint256 vaultLPShares =
                            sellYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];
                        if (vaultLPShares == 0) {
                            filled = 0;
                            collateralOut = 0;
                        }
                    }

                    if (filled != 0) {
                        (uint256 shift, uint256 shiftMask) = _getShiftMask(sellYes);
                        assembly ("memory-safe") {
                            // Update vault shares: sellYes ? yesShares : noShares
                            let vaultSlot := vault.slot
                            let vaultData := sload(vaultSlot)
                            let mask := 0xffffffffffffffffffffffffffff // uint112 mask
                            let current := and(shr(shift, vaultData), mask)
                            let updated := add(current, filled)
                            // Check for uint112 overflow
                            if gt(updated, mask) {
                                mstore(0x00, ERR_SHARES)
                                mstore(0x04, 3) // SharesOverflow
                                revert(0x00, 0x24)
                            }
                            let clearMask := not(shiftMask)
                            vaultData := or(
                                and(vaultData, clearMask),
                                shl(shift, and(updated, mask))
                            )
                            // Update lastActivity (bits 224-255)
                            vaultData := or(and(vaultData, MASK_LOWER_224), shl(224, timestamp()))
                            sstore(vaultSlot, vaultData)
                        }
                        unchecked {
                            rebalanceCollateralBudget[marketId] = budget - collateralOut;
                            remaining -= filled;
                        }
                        source = SRC_OTC;
                        emit VaultOTCFill(
                            marketId,
                            msg.sender,
                            to,
                            !sellYes, // vault is buying
                            collateralOut,
                            filled,
                            p - s, // effectivePriceBps
                            collateralOut, // principal (all collateral paid)
                            0 // spreadFee (implicit in share discount)
                        );
                    }
                }
            }
        }

        // AMM fallback for remainder (hook enforces impact limit)
        // Strategy: swap partial shares to balance for merge, keeping some to pair with swap output
        uint256 poolId = canonicalPoolId[marketId];
        if (remaining != 0 && poolId != 0) {
            uint256 feeOrHook = canonicalFeeOrHook[marketId];
            (IZAMM.PoolKey memory key, bool yesIsId0) = _buildKey(marketId, noId, feeOrHook);

            // Get reserves and fee to calculate optimal swap amount
            (uint112 r0, uint112 r1) = _getReserves(poolId);
            uint256 feeBps = _getPoolFeeBps(feeOrHook, poolId);

            // Determine reserves based on swap direction
            // sellYes + yesIsId0: swapping token0 for token1, so rIn=r0, rOut=r1
            bool zeroForOne = yesIsId0 == sellYes;
            (uint256 rIn, uint256 rOut) =
                zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

            // Calculate how much to swap to end up with balanced amounts for merge
            uint256 swapAmount = _calcSwapAmountForMerge(remaining, rIn, rOut, feeBps);

            if (swapAmount != 0 && swapAmount < remaining) {
                // Require minimum 1 output to prevent value-destroying swaps from rounding
                uint256 swapOut =
                    ZAMM.swapExactIn(key, swapAmount, 1, zeroForOne, address(this), deadline);
                uint256 keptShares = remaining - swapAmount;

                // Merge the minimum of kept shares and received shares
                uint256 toMerge;
                assembly ("memory-safe") {
                    toMerge := xor(
                        keptShares,
                        mul(xor(keptShares, swapOut), gt(keptShares, swapOut))
                    )
                }

                if (toMerge != 0) {
                    PAMM.merge(marketId, toMerge, address(this));
                    collateralOut += toMerge;

                    // Return any excess shares to user
                    uint256 excessKept;
                    uint256 excessSwapped;
                    assembly ("memory-safe") {
                        excessKept := mul(sub(keptShares, toMerge), gt(keptShares, toMerge))
                        excessSwapped := mul(sub(swapOut, toMerge), gt(swapOut, toMerge))
                    }
                    if (excessKept != 0) {
                        PAMM.transfer(to, sellYes ? marketId : noId, excessKept);
                    }
                    if (excessSwapped != 0) {
                        PAMM.transfer(to, sellYes ? noId : marketId, excessSwapped);
                    }
                    source = source != 0 ? SRC_MULT : SRC_AMM;
                } else {
                    // Edge case: swap succeeded but can't merge (keptShares or swapOut is 0)
                    // Return both token types to user to prevent stuck funds
                    if (keptShares != 0) {
                        PAMM.transfer(to, sellYes ? marketId : noId, keptShares);
                    }
                    if (swapOut != 0) {
                        PAMM.transfer(to, sellYes ? noId : marketId, swapOut);
                    }
                }
                remaining = 0; // AMM path processed all shares (merged or returned)
            }
        }

        // Return any remaining shares that couldn't be sold (AMM path failed or was skipped)
        if (remaining != 0) {
            PAMM.transfer(to, sellYes ? marketId : noId, remaining);
        }

        if (collateralOut < minOut) _revert(ERR_VALIDATION, 2);
        _transferCollateral(collateral, to, collateralOut);
        _guardExit();
    }

    /// @return totalShares Shares from split + swap
    function _quoteAMMBuy(uint256 marketId, bool buyYes, uint256 collateralIn)
        internal
        view
        returns (uint256 totalShares)
    {
        uint256 poolId = canonicalPoolId[marketId];
        if (poolId == 0) return 0;
        (uint112 r0, uint112 r1) = _getReserves(poolId);
        if (uint256(r0) * r1 == 0) return 0;

        uint256 feeBps = _getPoolFeeBps(canonicalFeeOrHook[marketId], poolId);
        if (feeBps >= 10000) return 0; // Market halted
        uint256 noId = _getNoId(marketId);

        bool zeroForOne = (marketId < noId) != buyYes;
        uint256 rIn = zeroForOne ? r0 : r1;
        uint256 rOut = zeroForOne ? r1 : r0;

        uint256 amountInWithFee = collateralIn * (10000 - feeBps);

        // Guard against denominator overflow: rIn * 10000 + amountInWithFee
        // rIn <= 2^112, so rIn * 10000 <= 2^125 (safe)
        uint256 rInScaled = rIn * 10000;
        // But amountInWithFee can be up to ~2^256, so addition could overflow
        if (amountInWithFee > type(uint256).max - rInScaled) {
            return 0; // Would overflow - indicates impossibly large trade
        }
        uint256 denominator = rInScaled + amountInWithFee;

        // Use fullMulDiv to prevent overflow: amountInWithFee * rOut can overflow uint256
        uint256 swapped = fullMulDiv(amountInWithFee, rOut, denominator);

        // Only return non-zero if swap actually produces output
        // Returning collateralIn when swapped=0 would cause AMM selection that donates shares
        if (swapped != 0 && swapped < rOut) {
            totalShares = collateralIn + swapped;
        }
    }

    /// @notice Find maximum collateral for AMM that stays under price impact limit
    /// @dev Uses binary search with cached reserves (16 iterations = precision to 1/65536)
    /// @return safeCollateral Max collateral that keeps impact <= maxImpactBps (0 if none)
    function _findMaxAMMUnderImpact(
        uint256 marketId,
        bool buyYes,
        uint256 maxCollateral,
        uint256 feeBps,
        uint256 maxImpactBps
    ) internal view returns (uint256 safeCollateral) {
        if (maxImpactBps == 0) return 0;

        uint256 poolId = canonicalPoolId[marketId];
        if (poolId == 0) return 0;

        (uint112 r0, uint112 r1) = _getReserves(poolId);
        if (uint256(r0) * r1 == 0) return 0;

        uint256 noId = _getNoId(marketId);

        // Inline binary search with cached reserves
        assembly ("memory-safe") {
            // Wrap in function to enable `leave`
            function search(mId, nId, bYes, maxColl, fBps, maxImp, rZero, rOne) -> result {
                let yesIsId0 := lt(mId, nId)
                let yesRes := xor(rZero, mul(xor(rZero, rOne), iszero(yesIsId0)))
                let noRes := xor(rOne, mul(xor(rOne, rZero), iszero(yesIsId0)))
                let pBefore := div(mul(noRes, 10000), add(yesRes, noRes))
                let feeMult := sub(10000, fBps)

                // Inline impact calc: |pAfter - pBefore| or 10001 if would drain
                function calcImp(coll, bY, yR, nR, pB, fM) -> imp {
                    let rIn := xor(nR, mul(xor(nR, yR), iszero(bY)))
                    let rOut := xor(yR, mul(xor(yR, nR), iszero(bY)))
                    let amtWithFee := mul(coll, fM)
                    // Check overflow before multiplying: if amtWithFee > (2^256-1)/rOut, flag as drain
                    let swapOut := 0
                    if or(iszero(rOut), gt(amtWithFee, div(not(0), rOut))) {
                        // Would overflow or drain - signal max impact
                        imp := 10001
                        leave
                    }
                    // Guard denominator overflow: rIn*10000 + amtWithFee
                    let rInScaled := mul(rIn, 10000)
                    if gt(amtWithFee, sub(not(0), rInScaled)) {
                        imp := 10001
                        leave
                    }
                    swapOut := div(mul(amtWithFee, rOut), add(rInScaled, amtWithFee))
                    switch lt(swapOut, rOut)
                    case 0 { imp := 10001 }
                    default {
                        let yA :=
                            xor(
                                sub(yR, swapOut),
                                mul(xor(sub(yR, swapOut), add(yR, coll)), iszero(bY))
                            )
                        let nA :=
                            xor(
                                add(nR, coll),
                                mul(xor(add(nR, coll), sub(nR, swapOut)), iszero(bY))
                            )
                        let pA := div(mul(nA, 10000), add(yA, nA))
                        let d := sub(pA, pB)
                        imp := xor(d, mul(xor(d, sub(pB, pA)), sgt(pB, pA)))
                    }
                }

                // Quick check: full amount under limit?
                let impact := calcImp(maxColl, bYes, yesRes, noRes, pBefore, feeMult)
                if iszero(gt(impact, maxImp)) {
                    result := maxColl
                    leave
                }

                // Quick check: even 1 unit exceeds?
                if lt(maxColl, 2) { leave }
                impact := calcImp(1, bYes, yesRes, noRes, pBefore, feeMult)
                if gt(impact, maxImp) { leave }

                // Binary search (16 iterations = 1/65536 precision)
                let lo := 1
                let hi := maxColl
                for { let i := 0 } lt(i, 16) { i := add(i, 1) } {
                    let mid := shr(1, add(lo, hi))
                    if eq(mid, lo) { break }
                    impact := calcImp(mid, bYes, yesRes, noRes, pBefore, feeMult)
                    switch gt(impact, maxImp)
                    case 0 { lo := mid }
                    default { hi := mid }
                }
                // Safety margin: shave 1 to avoid cap-edge reverts from rounding
                result := sub(lo, gt(lo, 0))
            }

            safeCollateral := search(
                marketId,
                noId,
                buyYes,
                maxCollateral,
                feeBps,
                maxImpactBps,
                r0,
                r1
            )
        }
    }

    /// @notice Get max price impact limit from hook (0 if disabled or no hook)
    function _getMaxPriceImpactBps(uint256 marketId) internal view returns (uint256) {
        uint256 feeOrHook = canonicalFeeOrHook[marketId];
        bool isHook = (feeOrHook & (FLAG_BEFORE | FLAG_AFTER)) != 0;
        if (!isHook) return 0; // No hook = no impact limit

        address hook = address(uint160(feeOrHook));
        (bool ok, uint256 maxImpact) = _staticUint(hook, 0x9e9feaae, marketId); // getMaxPriceImpactBps
        return ok ? maxImpact : 0;
    }

    // ============ Vault LP Functions ============

    function depositToVault(
        uint256 marketId,
        bool isYes,
        uint256 shares,
        address receiver,
        uint256 deadline
    ) public returns (uint256 vaultSharesMinted) {
        _guardEnter();
        _requireMarketOpen(marketId);
        _checkDeadline(deadline);
        _requireRegistered(marketId);
        if (shares == 0) _revert(ERR_SHARES, 0); // ZeroShares
        assembly { if iszero(receiver) { receiver := caller() } }

        PAMM.transferFrom(msg.sender, address(this), isYes ? marketId : _getNoId(marketId), shares);

        vaultSharesMinted = _depositToVaultSide(marketId, isYes, shares, receiver);

        emit VaultDeposit(marketId, receiver, isYes, shares, vaultSharesMinted);
        _guardExit();
    }

    /// @notice Withdraw vault shares and claim fees
    function withdrawFromVault(
        uint256 marketId,
        bool isYes,
        uint256 vaultSharesToRedeem,
        address receiver,
        uint256 deadline
    ) public returns (uint256 sharesReturned, uint256 feesEarned) {
        _guardEnter();
        _checkDeadline(deadline);
        _requireRegistered(marketId);
        _checkWithdrawalCooldown(marketId);

        if (vaultSharesToRedeem == 0) _revert(ERR_SHARES, 1); // ZeroVaultShares
        assembly { if iszero(receiver) { receiver := caller() } }

        UserVaultPosition storage position = vaultPositions[marketId][msg.sender];
        uint256 userVaultShares = isYes ? position.yesVaultShares : position.noVaultShares;
        if (userVaultShares < vaultSharesToRedeem) _revert(ERR_VALIDATION, 5); // InsufficientVaultShares

        BootstrapVault storage vault = bootstrapVaults[marketId];
        uint256 totalVaultShares =
            isYes ? totalYesVaultShares[marketId] : totalNoVaultShares[marketId];
        if (totalVaultShares == 0) _revert(ERR_SHARES, 2); // NoVaultShares

        uint256 totalShares = isYes ? vault.yesShares : vault.noShares;
        sharesReturned = mulDiv(vaultSharesToRedeem, totalShares, totalVaultShares);

        unchecked {
            uint256 accPerShare =
                isYes ? accYesCollateralPerShare[marketId] : accNoCollateralPerShare[marketId];
            uint256 debt = isYes ? position.yesRewardDebt : position.noRewardDebt;
            uint256 acc = mulDiv(userVaultShares, accPerShare, 1e18);
            assembly ("memory-safe") { feesEarned := mul(gt(acc, debt), sub(acc, debt)) }
            uint256 newDebt = mulDiv(userVaultShares - vaultSharesToRedeem, accPerShare, 1e18);

            // Update vault packed struct (yesShares | noShares << 112 | lastActivity << 224)
            _subVaultShares(vault, isYes, sharesReturned);
            // Update position packed struct and reward debt
            (uint256 shift, uint256 mask) = _getShiftMask(isYes);
            assembly ("memory-safe") {
                let posSlot := position.slot
                let posData := sload(posSlot)
                let current := and(shr(shift, posData), MAX_UINT112)
                posData := or(
                    and(posData, not(mask)),
                    shl(shift, sub(current, vaultSharesToRedeem))
                )
                sstore(posSlot, posData)
                // Update reward debt: slot+1 for yes, slot+2 for no
                sstore(add(add(posSlot, 1), iszero(isYes)), newDebt)
            }
            if (isYes) {
                totalYesVaultShares[marketId] -= vaultSharesToRedeem;
            } else {
                totalNoVaultShares[marketId] -= vaultSharesToRedeem;
            }
        }

        if (sharesReturned != 0) {
            PAMM.transfer(receiver, isYes ? marketId : _getNoId(marketId), sharesReturned);
        }

        // Transfer fees if any earned
        if (feesEarned != 0) _transferCollateral(_getCollateral(marketId), receiver, feesEarned);

        emit VaultWithdraw(
            marketId, receiver, isYes, vaultSharesToRedeem, sharesReturned, feesEarned
        );
        _guardExit();
    }

    /// @notice Claim pending fees without withdrawing vault shares
    function harvestVaultFees(uint256 marketId, bool isYes) public returns (uint256 feesEarned) {
        _guardEnter();
        _requireRegistered(marketId);
        _checkWithdrawalCooldown(marketId);

        UserVaultPosition storage position = vaultPositions[marketId][msg.sender];
        uint256 userVaultShares;
        uint256 debt;
        assembly ("memory-safe") {
            // Load packed slot 0: yesVaultShares (bits 0-111) | noVaultShares (bits 112-223) | lastDepositTime (bits 224-255)
            let slot0 := sload(position.slot)

            // Extract vault shares based on isYes flag
            // if isYes: userVaultShares = slot0 & 0xffffffffffffffffffffffffffff (bits 0-111)
            // if !isYes: userVaultShares = (slot0 >> 112) & 0xffffffffffffffffffffffffffff (bits 112-223)
            userVaultShares := and(shr(mul(112, iszero(isYes)), slot0), MAX_UINT112)

            // Load debt from slot 1 (yesRewardDebt) or slot 2 (noRewardDebt)
            // if isYes: debt = sload(position.slot + 1)
            // if !isYes: debt = sload(position.slot + 2)
            let debtSlot := add(add(position.slot, 1), iszero(isYes))
            debt := sload(debtSlot)
        }

        uint256 accPerShare =
            isYes ? accYesCollateralPerShare[marketId] : accNoCollateralPerShare[marketId];
        uint256 acc = mulDiv(userVaultShares, accPerShare, 1e18);

        assembly ("memory-safe") {
            feesEarned := mul(gt(acc, debt), sub(acc, debt))
        }

        if (feesEarned != 0) {
            // Update reward debt: slot+1 for yes, slot+2 for no
            assembly ("memory-safe") {
                sstore(add(add(position.slot, 1), iszero(isYes)), acc)
            }

            _transferCollateral(_getCollateral(marketId), msg.sender, feesEarned);

            emit VaultFeesHarvested(marketId, msg.sender, isYes, feesEarned);
        }
        _guardExit();
    }

    /// @notice Split collateral and provide liquidity to vaults and/or AMM
    /// @param marketId Market ID
    /// @param collateralAmount Collateral to split
    /// @param vaultYesShares YES shares to deposit to vault
    /// @param vaultNoShares NO shares to deposit to vault
    /// @param ammLPShares YES+NO shares to add to AMM
    /// @param minAmount0 Minimum amount0 (lower token ID) to AMM
    /// @param minAmount1 Minimum amount1 (higher token ID) to AMM
    /// @param receiver Recipient
    /// @param deadline Deadline
    function provideLiquidity(
        uint256 marketId,
        uint256 collateralAmount,
        uint256 vaultYesShares,
        uint256 vaultNoShares,
        uint256 ammLPShares,
        uint256 minAmount0,
        uint256 minAmount1,
        address receiver,
        uint256 deadline
    )
        public
        payable
        returns (uint256 yesVaultSharesMinted, uint256 noVaultSharesMinted, uint256 ammLiquidity)
    {
        _guardEnter();
        (, address collateral) = _requireMarketOpen(marketId);
        _checkDeadline(deadline);
        _requireRegistered(marketId);
        if (collateralAmount == 0) _revert(ERR_VALIDATION, 1); // AmountZero
        assembly { if iszero(receiver) { receiver := caller() } }

        // Load canonical feeOrHook for this market
        uint256 feeOrHook = canonicalFeeOrHook[marketId];

        if (vaultYesShares > collateralAmount || vaultNoShares > collateralAmount) {
            _revert(ERR_VALIDATION, 4); // InsufficientShares
        }

        uint256 yesRemaining;
        uint256 noRemaining;
        unchecked {
            yesRemaining = collateralAmount - vaultYesShares;
            noRemaining = collateralAmount - vaultNoShares;
        }

        if (ammLPShares > yesRemaining || ammLPShares > noRemaining) {
            _revert(ERR_VALIDATION, 4); // InsufficientShares
        }

        // Validate and take collateral, split into YES + NO shares
        _validateETHAmount(collateral, collateralAmount);
        if (collateral != ETH && collateralAmount != 0) {
            safeTransferFrom(collateral, msg.sender, address(this), collateralAmount);
            ensureApproval(collateral, address(PAMM));
        }
        _splitShares(marketId, collateralAmount, collateral);

        // Deposit YES shares to vault
        if (vaultYesShares != 0) {
            yesVaultSharesMinted = _depositToVaultSide(marketId, true, vaultYesShares, receiver);
            emit VaultDeposit(marketId, receiver, true, vaultYesShares, yesVaultSharesMinted);
        }

        // Deposit NO shares to vault
        if (vaultNoShares != 0) {
            noVaultSharesMinted = _depositToVaultSide(marketId, false, vaultNoShares, receiver);
            emit VaultDeposit(marketId, receiver, false, vaultNoShares, noVaultSharesMinted);
        }

        // Add AMM liquidity
        uint256 yesId = marketId;
        uint256 noId = _getNoId(marketId);
        if (ammLPShares != 0) {
            ZAMM.deposit(address(PAMM), yesId, ammLPShares);
            ZAMM.deposit(address(PAMM), noId, ammLPShares);

            (IZAMM.PoolKey memory k,) = _buildKey(yesId, noId, feeOrHook);

            // Add liquidity with user-specified slippage protection
            (,, ammLiquidity) = ZAMM.addLiquidity(
                k, ammLPShares, ammLPShares, minAmount0, minAmount1, receiver, deadline
            );

            ZAMM.recoverTransientBalance(address(PAMM), yesId, receiver);
            ZAMM.recoverTransientBalance(address(PAMM), noId, receiver);
        }

        // Return leftover shares to receiver
        unchecked {
            uint256 leftoverYes = yesRemaining - ammLPShares;
            uint256 leftoverNo = noRemaining - ammLPShares;

            if (leftoverYes != 0) PAMM.transfer(receiver, yesId, leftoverYes);
            if (leftoverNo != 0) PAMM.transfer(receiver, noId, leftoverNo);
        }

        // Refund excess ETH
        _refundExcessETH(collateral, collateralAmount);
        _guardExit();
    }

    /// @notice Settle rebalance budget by distributing to LPs
    function settleRebalanceBudget(uint256 marketId)
        public
        returns (uint256 budgetDistributed, uint256 sharesMerged)
    {
        _guardEnter();
        _requireRegistered(marketId);
        // Check market close time or early resolution
        (bool resolved,,, uint64 close,) = _staticMarkets(marketId);
        if (!resolved && block.timestamp < close) _revert(ERR_TIMING, 3); // MarketNotClosed

        BootstrapVault storage vault = bootstrapVaults[marketId];

        // Capture pre-merge inventory for probability-weighted fee distribution
        uint112 preMergeYes = vault.yesShares;
        uint112 preMergeNo = vault.noShares;
        uint256 twapBps = _getTWAPPrice(marketId);

        // First, merge any balanced inventory to convert to collateral (only if not resolved)
        sharesMerged = vault.yesShares < vault.noShares ? vault.yesShares : vault.noShares;
        if (!resolved && sharesMerged != 0) {
            PAMM.merge(marketId, sharesMerged, address(this));
            // Decrement both shares by sharesMerged
            _decrementBothShares(vault, sharesMerged);
            unchecked {
                rebalanceCollateralBudget[marketId] += sharesMerged;
            }
        }

        uint256 budgetToProcess = rebalanceCollateralBudget[marketId];
        rebalanceCollateralBudget[marketId] = 0;

        if (budgetToProcess != 0) {
            if (_addVaultFeesSymmetricWithSnapshot(
                    marketId, budgetToProcess, preMergeYes, preMergeNo, twapBps
                )) {
                budgetDistributed = budgetToProcess;
            } else {
                // No LPs to distribute to - reinvest into protocol vault depth
                unchecked {
                    rebalanceCollateralBudget[marketId] += budgetToProcess;
                }
                budgetDistributed = 0;
            }
        }

        emit BudgetSettled(marketId, budgetDistributed, sharesMerged);
        _guardExit();
    }

    /// @dev Helper to clear vault winning shares - called by redeem and finalize
    function _clearVaultWinningShares(uint256 marketId, bool outcome)
        internal
        returns (uint256 payout, uint256 winningShares)
    {
        BootstrapVault storage vault = bootstrapVaults[marketId];
        winningShares = PAMM.balanceOf(address(this), outcome ? marketId : _getNoId(marketId));
        if (winningShares != 0) (, payout) = PAMM.claim(marketId, DAO);
        vault.yesShares = 0;
        vault.noShares = 0;
        totalYesVaultShares[marketId] = 0;
        totalNoVaultShares[marketId] = 0;
    }

    /// @notice Redeem vault winning shares and send to DAO
    /// @dev Requires no user LPs exist
    /// @param marketId Market ID
    /// @return payout Collateral sent to DAO
    function redeemVaultWinningShares(uint256 marketId) public returns (uint256 payout) {
        _guardEnter();
        _requireRegistered(marketId);
        (bool outcome,) = _requireResolved(marketId);

        // Only allow cleanup if no user LPs remain
        if ((totalYesVaultShares[marketId] | totalNoVaultShares[marketId]) != 0) {
            _revert(ERR_STATE, 6); // CirculatingLPsExist
        }

        uint256 winningShares;
        (payout, winningShares) = _clearVaultWinningShares(marketId, outcome);

        emit VaultWinningSharesRedeemed(marketId, outcome, winningShares, payout);
        _guardExit();
    }

    /// @notice Finalize market - extract all vault value to DAO
    /// @dev Returns 0 silently if user LPs still exist (vs redeemVaultWinningShares which reverts).
    ///      This allows batch finalization where some markets are ready and others aren't.
    /// @param marketId Market to finalize
    /// @return totalToDAO Collateral sent to DAO (0 if LPs exist or nothing to finalize)
    function finalizeMarket(uint256 marketId) public returns (uint256 totalToDAO) {
        _guardEnter();
        totalToDAO = _finalizeMarket(marketId);
        _guardExit();
    }

    function _finalizeMarket(uint256 marketId) internal returns (uint256 totalToDAO) {
        _requireRegistered(marketId);
        (bool outcome, address collateral) = _requireResolved(marketId);

        // Only finalize if no user LPs remain
        if ((totalYesVaultShares[marketId] | totalNoVaultShares[marketId]) != 0) return 0;

        uint256 winningShares;
        (totalToDAO, winningShares) = _clearVaultWinningShares(marketId, outcome);

        // Step 2: Distribute budget to LPs or send to DAO
        uint256 budget = rebalanceCollateralBudget[marketId];
        uint256 budgetDistributed;

        if (budget != 0) {
            rebalanceCollateralBudget[marketId] = 0;
            _transferCollateral(collateral, DAO, budget);
            budgetDistributed = budget;
            unchecked {
                totalToDAO += budget;
            }
        }

        emit MarketFinalized(marketId, totalToDAO, winningShares, budgetDistributed);
    }

    struct RebalanceValidation {
        uint256 twapBps;
        uint256 yesReserve;
        uint256 noReserve;
    }

    /// @notice Validate TWAP and spot price for rebalancing
    function _validateRebalanceConditions(uint256 marketId, uint256 canonical, uint256 twapBps)
        internal
        view
        returns (RebalanceValidation memory validation)
    {
        validation.twapBps = twapBps;

        // Read spot reserves for deviation check (safety valve against manipulation)
        (uint112 r0, uint112 r1) = _getReserves(canonical);
        if (uint256(r0) * r1 == 0) _revert(ERR_TIMING, 4); // PoolNotReady

        uint256 noId = _getNoId(marketId);
        bool yesIsId0 = marketId < noId;

        validation.yesReserve = yesIsId0 ? uint256(r0) : uint256(r1);
        validation.noReserve = yesIsId0 ? uint256(r1) : uint256(r0);

        // Compute spot P(YES) = NO/(YES+NO) to match TWAP convention
        uint256 spotPYesBps;
        unchecked {
            spotPYesBps =
                (validation.noReserve * BPS_DENOM) / (validation.yesReserve + validation.noReserve);
        }

        assembly ("memory-safe") {
            if iszero(spotPYesBps) { spotPYesBps := 1 }
            if gt(spotPYesBps, 9999) { spotPYesBps := 9999 }
        }

        // Calculate deviation and check against max
        uint256 deviation;
        assembly ("memory-safe") {
            // Calculate absolute difference: |spotPYesBps - twapBps|
            let diff := sub(spotPYesBps, twapBps)
            deviation := xor(
                diff,
                mul(xor(diff, sub(twapBps, spotPYesBps)), sgt(twapBps, spotPYesBps))
            )
        }
        if (deviation > 500) _revert(ERR_COMPUTATION, 5); // SpotDeviantFromTWAP
    }

    /// @notice Calculate minimum swap output for rebalance
    function _calculateRebalanceMinOut(
        uint256 collateralUsed,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256 minOut) {
        // ZAMM constant-product: amountOut = (amountIn * (1-fee) * reserveOut) / (reserveIn + amountIn * (1-fee))
        uint256 amountInWithFee;
        uint256 expectedSwapOut;
        unchecked {
            amountInWithFee = collateralUsed * (BPS_DENOM - feeBps);
            expectedSwapOut =
                mulDiv(amountInWithFee, reserveOut, (reserveIn * BPS_DENOM) + amountInWithFee);
        }

        if (expectedSwapOut == 0) return 0;

        assembly ("memory-safe") {
            // Apply tight slippage tolerance to swap output only
            minOut := div(mul(expectedSwapOut, sub(10000, 75)), 10000) // 0.75% slippage
            // Prevent truncation to 0 and subtract 1 for rounding tolerance
            switch minOut
            case 0 { minOut := 1 }
            default {
                if gt(minOut, 1) { minOut := sub(minOut, 1) }
            }
        }
    }

    /// @notice Get fee basis points for a pool
    function _getPoolFeeBps(uint256 feeOrHook, uint256 canonical)
        internal
        view
        returns (uint256 feeBps)
    {
        bool isHook = (feeOrHook & (FLAG_BEFORE | FLAG_AFTER)) != 0;
        if (isHook) {
            address hook = address(uint160(feeOrHook));
            (bool ok, uint256 fee) = _staticUint(hook, 0xb9056dbd, canonical); // getCurrentFeeBps
            feeBps = ok ? fee : DEFAULT_FEE_BPS; // Propagate 10001 sentinel for halted markets
        } else {
            feeBps = feeOrHook;
        }

        assembly ("memory-safe") {
            if gt(feeBps, 10001) {
                feeBps := DEFAULT_FEE_BPS
            }
        }
    }

    /// @dev Calculate optimal swap amount to balance shares for merge
    /// Given `sharesIn` of one type, calculates how much to swap to end up with
    /// approximately equal amounts of both types (for merging back to collateral).
    /// Uses quadratic formula to solve: sharesIn - X = X * rOut * fm / (rIn * 10000 + X * fm)
    /// where fm = 10000 - feeBps (fee multiplier)
    function _calcSwapAmountForMerge(uint256 sharesIn, uint256 rIn, uint256 rOut, uint256 feeBps)
        internal
        pure
        returns (uint256 swapAmount)
    {
        if (sharesIn == 0 || rIn == 0 || rOut == 0 || feeBps >= BPS_DENOM) return 0;

        // fm = 10000 - feeBps (fee multiplier in basis points)
        // Quadratic: a*X^2 + b*X + c = 0
        // a = fm
        // b = rIn * 10000 + fm * (rOut - sharesIn)  [can be negative if sharesIn > rOut]
        // c = -sharesIn * rIn * 10000
        // X = (-b + sqrt(b^2 - 4ac)) / (2a)
        // Since c < 0, discriminant = b^2 + 4*a*|c| is always positive

        assembly ("memory-safe") {
            function calc(sIn, rI, rO, fBps) -> result {
                let fm := sub(10000, fBps)
                // Guard rI*10000 overflow
                if gt(rI, div(not(0), 10000)) {
                    result := 0
                    leave
                }
                let rIn10k := mul(rI, 10000)

                // b = rIn * 10000 + fm * (rOut - sharesIn)
                // Handle potential negative (rOut - sharesIn) carefully
                let bPositive := 1
                let b
                switch gt(rO, sIn)
                case 1 {
                    // rOut > sharesIn: b = rIn10k + fm * (rOut - sharesIn)
                    b := add(rIn10k, mul(fm, sub(rO, sIn)))
                }
                default {
                    // rOut <= sharesIn: need to check if fm*(sharesIn-rOut) > rIn10k
                    let diff := sub(sIn, rO)
                    // Guard against overflow in fm*diff
                    if and(iszero(iszero(diff)), gt(fm, div(not(0), diff))) {
                        result := 0
                        leave
                    }
                    let fmDiff := mul(fm, diff)
                    switch gt(fmDiff, rIn10k)
                    case 1 {
                        // b is negative
                        b := sub(fmDiff, rIn10k)
                        bPositive := 0
                    }
                    default {
                        // b is positive or zero
                        b := sub(rIn10k, fmDiff)
                    }
                }

                // |c| = sharesIn * rIn * 10000
                // Guard against overflow: if sharesIn > (2^256-1)/rIn10k, abort
                // rIn10k is always nonzero here (rIn == 0 guarded above), so no need for iszero(iszero())
                if gt(sIn, div(not(0), rIn10k)) {
                    result := 0
                    leave
                }
                let absC := mul(sIn, rIn10k)

                // discriminant = b^2 + 4*fm*|c| (since c is negative, -4ac = +4a|c|)
                // Guard against overflow in b^2
                if and(iszero(iszero(b)), gt(b, div(not(0), b))) {
                    result := 0
                    leave
                }
                let bSquared := mul(b, b)
                // Guard against overflow in fm*absC
                if and(iszero(iszero(absC)), gt(fm, div(not(0), absC))) {
                    result := 0
                    leave
                }
                let fmAbsC := mul(fm, absC)
                // Guard against overflow in shl(2, fmAbsC): check if fmAbsC > max/4
                if gt(fmAbsC, shr(2, not(0))) {
                    result := 0
                    leave
                }
                let fourAC := shl(2, fmAbsC)
                // Guard against overflow in final addition
                if lt(add(bSquared, fourAC), bSquared) {
                    result := 0
                    leave
                }
                let discriminant := add(bSquared, fourAC)

                // sqrt via Newton's method
                let sqrtD := discriminant
                if gt(sqrtD, 0) {
                    let x := add(shr(1, sqrtD), 1)
                    for {} gt(x, 0) {} {
                        let xNew := shr(1, add(x, div(sqrtD, x)))
                        if iszero(lt(xNew, x)) { break }
                        x := xNew
                    }
                    sqrtD := x
                }

                // X = (-b + sqrt(discriminant)) / (2*fm)
                // If b is positive: X = (sqrtD - b) / (2*fm)
                // If b is negative: X = (sqrtD + |b|) / (2*fm)
                let numerator
                switch bPositive
                case 1 {
                    // Only valid if sqrtD >= b
                    switch gt(sqrtD, b)
                    case 1 { numerator := sub(sqrtD, b) }
                    default { numerator := 0 }
                }
                default {
                    numerator := add(sqrtD, b)
                }

                let denominator := shl(1, fm)
                switch denominator
                case 0 { result := 0 }
                default {
                    result := div(numerator, denominator)
                    // Ensure we don't swap more than we have
                    if gt(result, sIn) { result := sIn }
                }
            }

            swapAmount := calc(sharesIn, rIn, rOut, feeBps)
        }
    }

    /// @notice Rebalance vault using budget collateral
    function rebalanceBootstrapVault(uint256 marketId, uint256 deadline)
        public
        returns (uint256 collateralUsed)
    {
        _guardEnter();
        collateralUsed = _rebalanceBootstrapVault(marketId, deadline);
        _guardExit();
    }

    function _rebalanceBootstrapVault(uint256 marketId, uint256 deadline)
        internal
        returns (uint256 collateralUsed)
    {
        (, address collateral) = _requireMarketOpen(marketId);
        _checkDeadline(deadline);

        // Opportunistically update TWAP (non-reverting, inlined)
        {
            TWAPObservations storage obs = twapObservations[marketId];
            if (
                obs.timestamp1 != 0 && uint256(obs.timestamp1) <= block.timestamp
                    && block.timestamp - uint256(obs.timestamp1) >= MIN_TWAP_UPDATE_INTERVAL
            ) {
                (uint256 currentCumulative, bool success) = _getCurrentCumulative(marketId);
                if (success && currentCumulative >= obs.cumulative1) {
                    _updateTWAPObservation(obs, currentCumulative);
                }
            }
        }
        if (_isInCloseWindow(marketId)) return 0;

        BootstrapVault storage vault = bootstrapVaults[marketId];

        uint256 canonical = canonicalPoolId[marketId];
        if (canonical == 0) _revert(ERR_STATE, 2); // MarketNotRegistered

        uint256 feeOrHook = canonicalFeeOrHook[marketId];

        uint256 twapBps = _getTWAPPrice(marketId);
        if (twapBps == 0) return 0;

        RebalanceValidation memory validation =
            _validateRebalanceConditions(marketId, canonical, twapBps);

        uint256 totalYes = totalYesVaultShares[marketId];
        uint256 totalNo = totalNoVaultShares[marketId];

        if ((totalYes | totalNo) == 0) return 0;

        uint256 noId = _getNoId(marketId);

        bool yesIsLower = vault.yesShares < vault.noShares;

        if ((yesIsLower ? totalYes : totalNo) == 0) return 0;

        uint112 preMergeYes = vault.yesShares;
        uint112 preMergeNo = vault.noShares;

        uint256 mergeAmount = yesIsLower ? vault.yesShares : vault.noShares;
        if (mergeAmount != 0) {
            PAMM.merge(marketId, mergeAmount, address(this));
            // Decrement both shares by mergeAmount
            _decrementBothShares(vault, mergeAmount);
            _distributeFeesSplit(marketId, mergeAmount, preMergeYes, preMergeNo, validation.twapBps);
        }

        uint256 availableCollateral = rebalanceCollateralBudget[marketId];
        if (availableCollateral == 0) return 0;

        uint256 collateralForSwap;
        uint256 bounty;
        unchecked {
            uint256 maxCollateralNeeded =
                ((yesIsLower
                                ? (vault.noShares - vault.yesShares)
                                : (vault.yesShares - vault.noShares))
                        * (yesIsLower ? validation.twapBps : (10_000 - validation.twapBps)))
                    / 10_000;
            collateralUsed = availableCollateral < maxCollateralNeeded
                ? availableCollateral
                : maxCollateralNeeded;

            // Reserve bounty from collateralUsed (0.1%)
            bounty = mulDiv(collateralUsed, 10, 10_000); // 0.1% bounty
            collateralForSwap = collateralUsed - bounty;
        }
        if (collateralForSwap == 0) return 0;

        (IZAMM.PoolKey memory k, bool keyYesIsId0) = _buildKey(marketId, noId, feeOrHook);
        if (_derivePoolId(k) != canonical) _revert(ERR_COMPUTATION, 7); // NonCanonicalPool

        uint256 feeBps = _getPoolFeeBps(feeOrHook, canonical);
        if (feeBps >= 10000) return 0; // Market halted

        uint256 reserveIn;
        uint256 reserveOut;
        assembly ("memory-safe") {
            let yesRes := mload(add(validation, 0x20)) // validation.yesReserve at offset 1
            let noRes := mload(add(validation, 0x40)) // validation.noReserve at offset 2
            reserveIn := xor(noRes, mul(xor(noRes, yesRes), iszero(yesIsLower)))
            reserveOut := xor(yesRes, mul(xor(yesRes, noRes), iszero(yesIsLower)))
        }
        uint256 minOut = _calculateRebalanceMinOut(collateralForSwap, reserveIn, reserveOut, feeBps);
        bool zeroForOne = yesIsLower ? !keyYesIsId0 : keyYesIsId0;
        if (minOut == 0) return 0;

        // Now safe to proceed with state changes
        _splitShares(marketId, collateralForSwap, collateral);

        uint256 swapTokenId = yesIsLower ? noId : marketId;
        ZAMM.deposit(address(PAMM), swapTokenId, collateralForSwap);

        uint256 swappedShares =
            ZAMM.swapExactIn(k, collateralForSwap, minOut, zeroForOne, address(this), deadline);

        uint256 currentShares = yesIsLower ? vault.yesShares : vault.noShares;
        uint256 totalAcquired;
        unchecked {
            totalAcquired = collateralForSwap + swappedShares;
        }
        _checkU112Overflow(currentShares, totalAcquired);

        // Update vault shares and lastActivity
        (uint256 shift, uint256 mask) = _getShiftMask(yesIsLower);
        assembly ("memory-safe") {
            let vaultSlot := vault.slot
            let vaultData := sload(vaultSlot)
            let current := and(shr(shift, vaultData), MAX_UINT112)
            vaultData := or(and(vaultData, not(mask)), shl(shift, add(current, totalAcquired)))
            // Update lastActivity (bits 224-255)
            vaultData := or(and(vaultData, MASK_LOWER_224), shl(224, timestamp()))
            sstore(vaultSlot, vaultData)
        }
        unchecked {
            rebalanceCollateralBudget[marketId] -= collateralUsed;
        }

        // Pay small bounty to caller to incentivize permissionless rebalancing
        if (bounty != 0) {
            _transferCollateral(collateral, msg.sender, bounty);
        }

        emit Rebalanced(marketId, collateralUsed, totalAcquired, yesIsLower);
    }

    /// @dev Execute vault OTC fill and account proceeds
    function _executeVaultOTCFill(
        uint256 marketId,
        bool buyYes,
        uint256 remainingCollateral,
        uint256 pYes,
        address to,
        uint256 noId
    ) internal returns (uint256 sharesOut, uint256 collateralUsed, uint8 venueIncrement) {
        BootstrapVault storage vault = bootstrapVaults[marketId];
        (uint256 otcShares, uint256 otcCollateralUsed, bool otcFilled) =
            _tryVaultOTCFill(marketId, buyYes, remainingCollateral, pYes);

        if (!otcFilled || otcShares == 0) return (0, 0, 0);

        uint112 preYesInv = vault.yesShares;
        uint112 preNoInv = vault.noShares;

        // Update vault shares
        _subVaultShares(vault, buyYes, otcShares);
        PAMM.transfer(to, buyYes ? marketId : noId, otcShares);

        (uint256 principal, uint256 spreadFee) = _accountVaultOTCProceeds(
            marketId, buyYes, otcShares, otcCollateralUsed, pYes, preYesInv, preNoInv
        );
        vault.lastActivity = uint32(block.timestamp);

        unchecked {
            uint256 effectivePriceBps = mulDiv(otcCollateralUsed, BPS_DENOM, otcShares);
            emit VaultOTCFill(
                marketId,
                msg.sender,
                to,
                buyYes,
                otcCollateralUsed,
                otcShares,
                effectivePriceBps,
                principal,
                spreadFee
            );
        }

        return (otcShares, otcCollateralUsed, 1);
    }

    /// @dev Execute AMM swap
    function _executeAMMSwap(
        uint256 marketId,
        bool buyYes,
        uint256 collateralToSwap,
        address to,
        uint256 deadline,
        uint256 noId,
        uint256 feeOrHook,
        address collateral
    ) internal returns (uint256 ammSharesOut) {
        _splitShares(marketId, collateralToSwap, collateral);

        (uint256 swapTokenId, uint256 desiredTokenId) = _selectTokenIds(marketId, noId, buyYes);

        ZAMM.deposit(address(PAMM), swapTokenId, collateralToSwap);

        (IZAMM.PoolKey memory k, bool yesIsId0) = _buildKey(marketId, noId, feeOrHook);
        bool zeroForOne = buyYes ? !yesIsId0 : yesIsId0;

        // Require minimum 1 output to prevent value-destroying swaps where split shares are donated
        // for nothing. This matches sell-side behavior and prevents zero-output donation attacks.
        uint256 swappedShares =
            ZAMM.swapExactIn(k, collateralToSwap, 1, zeroForOne, address(this), deadline);

        ammSharesOut = collateralToSwap + swappedShares;
        PAMM.transfer(to, desiredTokenId, ammSharesOut);
    }

    function _shouldUseVaultMint(uint256 marketId, BootstrapVault memory vault, bool buyYes)
        internal
        view
        returns (bool)
    {
        uint64 close = _getClose(marketId);
        unchecked {
            if (close < block.timestamp + BOOTSTRAP_WINDOW) return false;
        }

        uint256 yesShares = vault.yesShares;
        uint256 noShares = vault.noShares;

        // If both sides are empty, allow mint for initial bootstrapping
        if ((yesShares | noShares) == 0) return true;

        // If one side is empty (but not both), only allow mint that REPLENISHES the scarce side.
        // Mint gives buyer their desired token and deposits the opposite into vault.
        // e.g., yesShares=0 means YES is scarce; allow NO buys (user gets NO, vault gets YES).
        if (yesShares == 0) return !buyYes;
        if (noShares == 0) return buyYes;

        // Check 2x imbalance ratio and equal case
        uint256 larger;
        uint256 smaller;
        assembly ("memory-safe") {
            let yesGtNo := gt(yesShares, noShares)
            larger := xor(noShares, mul(xor(noShares, yesShares), yesGtNo))
            smaller := xor(yesShares, mul(xor(yesShares, noShares), yesGtNo))
        }

        if (larger > smaller << 1) return false; // Max 2x imbalance for mint
        if (yesShares == noShares) return true;

        // Allow only if buying from the abundant side
        return buyYes != (yesShares < noShares);
    }

    // ============ TWAP Functions ============

    /// @notice Get current cumulative price from ZAMM pool
    /// @return cumulative Cumulative price in UQ112x112
    /// @return success Whether computation succeeded
    function _getCurrentCumulative(uint256 marketId)
        internal
        view
        returns (uint256 cumulative, bool success)
    {
        uint256 poolId = canonicalPoolId[marketId];
        if (poolId == 0) return (0, false);

        (
            bool ok,
            uint112 r0,
            uint112 r1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast
        ) = _staticPools(poolId);

        if (!ok || uint256(r0) * r1 == 0) return (0, false);

        {
            // Get canonical NO token ID (inline for gas efficiency)
            uint256 noId = _getNoId(marketId);
            bool yesIsId0 = marketId < noId;

            // Consolidate cumulative calculation in assembly
            assembly ("memory-safe") {
                // Select cumulative: yesIsId0 ? price0CumulativeLast : price1CumulativeLast
                let poolCumulative :=
                    xor(
                        price0CumulativeLast,
                        mul(xor(price0CumulativeLast, price1CumulativeLast), iszero(yesIsId0))
                    )

                // Compute timeElapsed (wrap-safe uint32 arithmetic)
                let timeElapsed :=
                    and(sub(and(timestamp(), 0xffffffff), blockTimestampLast), 0xffffffff)

                switch timeElapsed
                case 0 {
                    // If timeElapsed == 0, return poolCumulative
                    cumulative := poolCumulative
                    success := 1
                }
                default {
                    // Select reserves based on token ordering
                    let yesRes := xor(r0, mul(xor(r0, r1), iszero(yesIsId0)))
                    let noRes := xor(r1, mul(xor(r1, r0), iszero(yesIsId0)))

                    // Compute NO/YES ratio in UQ112x112: (noReserve << 112) / yesReserve
                    let currentPrice := div(shl(112, noRes), yesRes)

                    // Compute prod = currentPrice * timeElapsed with overflow check
                    let prod := mul(currentPrice, timeElapsed)

                    // Check for overflow: prod / timeElapsed == currentPrice
                    switch eq(div(prod, timeElapsed), currentPrice)
                    case 0 {
                        // Overflow detected
                        cumulative := 0
                        success := 0
                    }
                    default {
                        // Compute sum = poolCumulative + prod
                        let sum := add(poolCumulative, prod)

                        // Check for overflow: sum >= poolCumulative
                        switch lt(sum, poolCumulative)
                        case 1 {
                            // Overflow detected
                            cumulative := 0
                            success := 0
                        }
                        default {
                            cumulative := sum
                            success := 1
                        }
                    }
                }
            }
        }
    }

    /// @notice Update TWAP observation (permissionless)
    /// @param marketId Market ID
    function updateTWAPObservation(uint256 marketId) public {
        _guardEnter();
        TWAPObservations storage obs = twapObservations[marketId];

        if (obs.timestamp1 == 0) _revert(ERR_COMPUTATION, 3); // TWAPRequired
        if (uint256(obs.timestamp1) > block.timestamp) _revert(ERR_COMPUTATION, 2); // TWAPCorrupt

        if (block.timestamp - uint256(obs.timestamp1) < MIN_TWAP_UPDATE_INTERVAL) {
            _revert(ERR_TIMING, 1); // TooSoon
        }

        (uint256 currentCumulative, bool success) = _getCurrentCumulative(marketId);
        if (!success) _revert(ERR_TIMING, 4); // PoolNotReady

        if (currentCumulative < obs.cumulative1) _revert(ERR_TIMING, 4); // PoolNotReady

        _updateTWAPObservation(obs, currentCumulative);
        _guardExit();
    }

    /// @notice Get TWAP P(YES) for a market
    /// @return twapBps P(YES) = NO/(YES+NO) in basis points [1-9999], or 0 if unavailable
    function _getTWAPPrice(uint256 marketId) internal view returns (uint256 twapBps) {
        TWAPObservations storage obs = twapObservations[marketId];

        if (obs.cacheBlockNum == uint32(block.number) && obs.cachedTwapBps != 0) {
            return obs.cachedTwapBps;
        }

        if (obs.timestamp1 == 0) return 0;

        if (block.timestamp < obs.timestamp1) return 0;
        if (obs.timestamp1 < obs.timestamp0) return 0;

        uint256 timeElapsed;
        uint256 twapUQ112x112;

        if (block.timestamp - obs.timestamp1 < MIN_TWAP_UPDATE_INTERVAL) {
            unchecked {
                timeElapsed = obs.timestamp1 - obs.timestamp0;
            }
            if (timeElapsed == 0) return 0;

            if (obs.cumulative1 < obs.cumulative0) return 0;

            unchecked {
                twapUQ112x112 = (obs.cumulative1 - obs.cumulative0) / timeElapsed;
            }
            return _convertUQ112x112ToBps(twapUQ112x112);
        }

        (uint256 currentCumulative, bool success) = _getCurrentCumulative(marketId);
        if (!success || currentCumulative < obs.cumulative1) return 0;

        unchecked {
            timeElapsed = block.timestamp - obs.timestamp1;
        }
        if (timeElapsed == 0) return 0;

        unchecked {
            twapUQ112x112 = (currentCumulative - obs.cumulative1) / timeElapsed;
        }
        return _convertUQ112x112ToBps(twapUQ112x112);
    }

    /// @dev Update TWAP observation with new cumulative value
    function _updateTWAPObservation(TWAPObservations storage obs, uint256 currentCumulative)
        internal
    {
        obs.timestamp0 = obs.timestamp1;
        obs.cumulative0 = obs.cumulative1;
        obs.timestamp1 = uint32(block.timestamp);
        obs.cumulative1 = currentCumulative;

        uint256 timeElapsed = uint32(block.timestamp) - obs.timestamp0;
        if (timeElapsed != 0 && obs.cumulative1 >= obs.cumulative0) {
            uint256 twapUQ112x112 = (obs.cumulative1 - obs.cumulative0) / timeElapsed;
            obs.cachedTwapBps = uint32(_convertUQ112x112ToBps(twapUQ112x112));
            obs.cacheBlockNum = uint32(block.number);
        } else {
            obs.cachedTwapBps = 0;
            obs.cacheBlockNum = 0;
        }
    }

    /// @notice Convert UQ112x112 NO/YES ratio to P(YES) in basis points
    /// @dev Formula: 10000 * r / (1 + r) = 10000 * NO / (YES + NO), where r = NO/YES
    /// @dev This matches PMFeeHook._getProbability: P(YES) = NO_reserve / total
    /// @param twapUQ112x112 NO/YES ratio in UQ112x112 fixed-point format
    /// @return twapBps P(YES) in basis points [1-9999]
    function _convertUQ112x112ToBps(uint256 twapUQ112x112) internal pure returns (uint256 twapBps) {
        // Compute P(YES) = NO/(YES+NO) = (10000 * r) / (2^112 + r), where r = NO/YES in UQ112x112
        assembly ("memory-safe") {
            let denom := add(shl(112, 1), twapUQ112x112)
            twapBps := div(mul(10000, twapUQ112x112), denom)
            if iszero(twapBps) { twapBps := 1 }
            if gt(twapBps, 9999) { twapBps := 9999 }
        }
    }

    // ============ Vault Internal Functions ============

    function _addVaultFeesWithSnapshot(
        uint256 marketId,
        bool isYes,
        uint256 feeAmount,
        uint256 totalSharesSnapshot
    ) internal {
        if (feeAmount == 0) return;
        if (totalSharesSnapshot == 0) {
            assembly ("memory-safe") {
                mstore(0x00, marketId)
                mstore(0x20, rebalanceCollateralBudget.slot)
                let slot := keccak256(0x00, 0x40)
                sstore(slot, add(sload(slot), feeAmount))
            }
            return;
        }

        uint256 accPerShare = fullMulDiv(feeAmount, 1e18, totalSharesSnapshot);
        uint256 distributed = fullMulDiv(accPerShare, totalSharesSnapshot, 1e18);
        uint256 maxAcc = MAX_ACC_PER_SHARE;

        assembly ("memory-safe") {
            let dust := sub(feeAmount, distributed)
            if dust {
                mstore(0x00, marketId)
                mstore(0x20, rebalanceCollateralBudget.slot)
                let slot := keccak256(0x00, 0x40)
                sstore(slot, add(sload(slot), dust))
            }

            mstore(0x00, marketId)
            let accSlot :=
                xor(
                    accYesCollateralPerShare.slot,
                    mul(
                        xor(accYesCollateralPerShare.slot, accNoCollateralPerShare.slot),
                        iszero(isYes)
                    )
                )
            mstore(0x20, accSlot)
            let slot := keccak256(0x00, 0x40)
            let newAcc := add(sload(slot), accPerShare)
            // MAX_ACC_PER_SHARE = type(uint256).max / type(uint112).max
            if gt(newAcc, maxAcc) {
                mstore(0x00, ERR_VALIDATION)
                mstore(0x04, 0)
                revert(0x00, 0x24)
            }
            sstore(slot, newAcc)
        }
    }

    /// @notice Distribute OTC spread with scarcity weighting (40-60% cap)
    /// @param marketId Market ID
    /// @param amount Spread to distribute
    /// @param preYesInv YES inventory before trade
    /// @param preNoInv NO inventory before trade
    /// @return distributed True if LPs exist
    function _distributeOtcSpreadScarcityCapped(
        uint256 marketId,
        uint256 amount,
        uint112 preYesInv,
        uint112 preNoInv
    ) internal returns (bool distributed) {
        if (amount == 0) return false;

        uint256 yesLP = totalYesVaultShares[marketId];
        uint256 noLP = totalNoVaultShares[marketId];

        if ((yesLP | noLP) == 0) return false;

        if (yesLP == 0) {
            _addVaultFeesWithSnapshot(marketId, false, amount, noLP);
            return true;
        }
        if (noLP == 0) {
            _addVaultFeesWithSnapshot(marketId, true, amount, yesLP);
            return true;
        }

        uint256 denom = uint256(preYesInv) + uint256(preNoInv);

        if (denom == 0) {
            uint256 half = amount >> 1;
            _addVaultFeesWithSnapshot(marketId, true, half, yesLP);
            unchecked {
                _addVaultFeesWithSnapshot(marketId, false, amount - half, noLP);
            }
            return true;
        }

        uint256 wYesBps = mulDiv(uint256(preNoInv), 10_000, denom);

        assembly ("memory-safe") {
            if lt(wYesBps, 4000) { wYesBps := 4000 } // 40% minimum
            if gt(wYesBps, 6000) { wYesBps := 6000 } // 60% maximum
        }

        uint256 yesFee = mulDiv(amount, wYesBps, 10_000);
        _addVaultFeesWithSnapshot(marketId, true, yesFee, yesLP);

        unchecked {
            _addVaultFeesWithSnapshot(marketId, false, amount - yesFee, noLP);
        }

        return true;
    }

    /// @notice Distribute fees symmetrically using pre-trade snapshot
    /// @param marketId Market ID
    /// @param feeAmount Fees to distribute
    /// @param yesInv Pre-trade YES inventory
    /// @param noInv Pre-trade NO inventory
    /// @param pYes P(YES) = NO/(YES+NO) in bps [1-9999]
    function _addVaultFeesSymmetricWithSnapshot(
        uint256 marketId,
        uint256 feeAmount,
        uint112 yesInv,
        uint112 noInv,
        uint256 pYes
    ) internal returns (bool distributed) {
        if (feeAmount == 0) return false;

        uint256 yesLP = totalYesVaultShares[marketId];
        uint256 noLP = totalNoVaultShares[marketId];

        if ((yesLP | noLP) == 0) return false;

        if (yesLP == 0) {
            _addVaultFeesWithSnapshot(marketId, false, feeAmount, noLP);
            return true;
        }
        if (noLP == 0) {
            _addVaultFeesWithSnapshot(marketId, true, feeAmount, yesLP);
            return true;
        }

        if (pYes == 0) {
            uint256 half = feeAmount >> 1;
            _addVaultFeesWithSnapshot(marketId, true, half, yesLP);
            unchecked {
                _addVaultFeesWithSnapshot(marketId, false, feeAmount - half, noLP);
            }
            return true;
        }

        if (pYes >= 10_000) pYes = 9_999;

        uint256 yesNotional;
        uint256 noNotional;
        uint256 denom;
        unchecked {
            yesNotional = uint256(yesInv) * pYes;
            noNotional = uint256(noInv) * (10_000 - pYes);
            denom = yesNotional + noNotional;
        }

        if (denom == 0) {
            uint256 half = feeAmount >> 1;
            _addVaultFeesWithSnapshot(marketId, true, half, yesLP);
            unchecked {
                _addVaultFeesWithSnapshot(marketId, false, feeAmount - half, noLP);
            }
            return true;
        }

        uint256 yesFee;
        unchecked {
            yesFee = mulDiv(feeAmount, yesNotional, denom);
        }
        _addVaultFeesWithSnapshot(marketId, true, yesFee, yesLP);
        unchecked {
            _addVaultFeesWithSnapshot(marketId, false, feeAmount - yesFee, noLP);
        }
        return true;
    }

    /// @notice Calculate dynamic spread based on inventory imbalance
    /// @dev Returns relative spread boosts that will be applied multiplicatively
    /// @param yesShares YES inventory
    /// @param noShares NO inventory
    /// @param buyYes True if buying YES
    /// @param close Market close time
    /// @return relativeSpreadBps Relative spread to apply (base + boosts)
    /// @return imbalanceBps Inventory imbalance in bps (for dynamic budget split)
    function _calculateDynamicSpread(uint256 yesShares, uint256 noShares, bool buyYes, uint64 close)
        internal
        view
        returns (uint256 relativeSpreadBps, uint256 imbalanceBps)
    {
        relativeSpreadBps = 100; // 1% base relative spread

        uint256 totalShares;
        assembly ("memory-safe") {
            totalShares := add(yesShares, noShares)
        }
        if (totalShares != 0) {
            bool yesScarce;
            bool consumingScarce;
            assembly ("memory-safe") {
                yesScarce := lt(yesShares, noShares)
                consumingScarce := or(
                    and(buyYes, yesScarce),
                    and(iszero(buyYes), iszero(yesScarce))
                )
            }

            if (consumingScarce) {
                assembly ("memory-safe") {
                    let larger :=
                        xor(yesShares, mul(xor(yesShares, noShares), gt(noShares, yesShares)))
                    imbalanceBps := div(mul(larger, 10000), totalShares)
                }

                uint256 midpoint = 5000; // 50% balance point
                if (imbalanceBps > midpoint) {
                    uint256 maxSpread = 400; // 4% max imbalance spread
                    assembly ("memory-safe") {
                        let excessImbalance := sub(imbalanceBps, midpoint)
                        let imbalanceBoost := div(mul(maxSpread, excessImbalance), midpoint)
                        relativeSpreadBps := add(relativeSpreadBps, imbalanceBoost)
                    }
                }
            }
        }

        assembly ("memory-safe") {
            if lt(timestamp(), close) {
                let timeToClose := sub(close, timestamp())

                if lt(timeToClose, 86400) {
                    let timeBoost := div(mul(200, sub(86400, timeToClose)), 86400) // 2% max time boost
                    relativeSpreadBps := add(relativeSpreadBps, timeBoost)
                }
            }

            if gt(relativeSpreadBps, MAX_SPREAD_BPS) {
                relativeSpreadBps := MAX_SPREAD_BPS
            }
        }
    }

    /// @notice Try vault OTC fill (supports partial)
    /// @param pYesTwapBps P(YES) = NO/(YES+NO) from TWAP [1-9999]
    /// @return sharesOut Shares filled (0 if none)
    /// @return collateralUsed Collateral consumed (0 if none)
    /// @return filled True if vault participated
    function _tryVaultOTCFill(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 pYesTwapBps
    ) internal view returns (uint256 sharesOut, uint256 collateralUsed, bool filled) {
        if (collateralIn == 0 || collateralIn > MAX_COLLATERAL_IN) return (0, 0, false);

        if (pYesTwapBps == 0) return (0, 0, false);

        if (_isInCloseWindow(marketId)) return (0, 0, false);

        BootstrapVault memory vault = bootstrapVaults[marketId];
        uint256 availableShares = buyYes ? vault.yesShares : vault.noShares;
        if (availableShares == 0) return (0, 0, false);

        uint256 canonical = canonicalPoolId[marketId];
        if (canonical == 0) return (0, 0, false);

        {
            (bool ok, uint112 r0, uint112 r1,,,) = _staticPools(canonical);
            if (!ok || uint256(r0) * r1 == 0) return (0, 0, false);

            uint256 noId = _getNoId(marketId);
            uint256 deviation;

            assembly ("memory-safe") {
                let yesIsId0 := lt(marketId, noId)
                let yesRes := xor(r0, mul(xor(r0, r1), iszero(yesIsId0)))
                let noRes := xor(r1, mul(xor(r1, r0), iszero(yesIsId0)))

                // Compute spot P(YES) = NO/(YES+NO) to match TWAP convention
                let total := add(yesRes, noRes)
                let spotPYesBps := div(mul(noRes, 10000), total)

                if iszero(spotPYesBps) { spotPYesBps := 1 }

                let diff := sub(spotPYesBps, pYesTwapBps)
                deviation := xor(
                    diff,
                    mul(xor(diff, sub(pYesTwapBps, spotPYesBps)), sgt(pYesTwapBps, spotPYesBps))
                )
            }

            if (deviation > 500) return (0, 0, false);
        }
        uint64 close = _getClose(marketId);
        (uint256 relativeSpreadBps,) =
            _calculateDynamicSpread(vault.yesShares, vault.noShares, buyYes, close);

        assembly ("memory-safe") {
            let sharePriceBps :=
                xor(pYesTwapBps, mul(xor(pYesTwapBps, sub(10000, pYesTwapBps)), iszero(buyYes)))

            // Hybrid spread: max(minAbsolute, fairPrice * relativeSpread / 10000)
            let relativeSpread := div(mul(sharePriceBps, relativeSpreadBps), 10000)
            let spreadBps := relativeSpread
            if lt(spreadBps, MIN_ABSOLUTE_SPREAD_BPS) {
                spreadBps := MIN_ABSOLUTE_SPREAD_BPS
            }

            let effectivePriceBps := add(sharePriceBps, spreadBps)
            if gt(effectivePriceBps, 10000) { effectivePriceBps := 10000 }

            let rawShares := div(mul(collateralIn, 10000), effectivePriceBps)

            let maxSharesFromVault := div(mul(availableShares, 3000), 10000) // 30% max vault depletion
            // Ensure at least 1 share when vault has inventory and raw fill is nonzero
            // Use iszero(iszero(x)) for boolean AND - bitwise and(x,y) can be 0 even when both nonzero
            if and(
                iszero(iszero(availableShares)),
                and(iszero(iszero(rawShares)), iszero(maxSharesFromVault))
            ) {
                maxSharesFromVault := 1
            }

            sharesOut := rawShares
            if gt(sharesOut, maxSharesFromVault) { sharesOut := maxSharesFromVault }
            if gt(sharesOut, availableShares) { sharesOut := availableShares }

            collateralUsed := collateralIn
            if iszero(eq(sharesOut, rawShares)) {
                collateralUsed := div(add(mul(sharesOut, effectivePriceBps), 9999), 10000)
            }

            filled := gt(sharesOut, 0)
        }
    }
}

function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z) {
    assembly ("memory-safe") {
        z := mul(x, y)
        if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
            mstore(0x00, ERR_COMPUTATION)
            mstore(0x04, 0)
            revert(0x00, 0x24)
        }
        z := div(z, d)
    }
}

function fullMulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z) {
    assembly ("memory-safe") {
        z := mul(x, y)
        for {} 1 {} {
            if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                let mm := mulmod(x, y, not(0))
                let p1 := sub(mm, add(z, lt(mm, z)))
                let r := mulmod(x, y, d)
                let t := and(d, sub(0, d))
                if iszero(gt(d, p1)) {
                    mstore(0x00, ERR_COMPUTATION)
                    mstore(0x04, 1)
                    revert(0x00, 0x24)
                }
                d := div(d, t)
                let inv := xor(2, mul(3, d))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                inv := mul(inv, sub(2, mul(d, inv)))
                z := mul(
                    or(mul(sub(p1, gt(r, z)), add(div(sub(0, t), t), 1)), div(sub(z, r), t)),
                    mul(sub(2, mul(d, inv)), inv)
                )
                break
            }
            z := div(z, d)
            break
        }
    }
}

/// @dev Sets max approval once if allowance <= uint128.max
function ensureApproval(address token, address spender) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x00, 0xdd62ed3e000000000000000000000000)
        mstore(0x14, address())
        mstore(0x34, spender)
        let success := staticcall(gas(), token, 0x10, 0x44, 0x00, 0x20)

        let needsApproval := 1
        if and(success, eq(returndatasize(), 32)) {
            if gt(mload(0x00), 0xffffffffffffffffffffffffffffffff) {
                needsApproval := 0
            }
        }

        if needsApproval {
            mstore(0x14, spender)
            mstore(0x34, not(0))
            mstore(0x00, 0x095ea7b3000000000000000000000000)
            success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, ERR_APPROVE_FAILED)
                    revert(0x00, 0x04)
                }
            }
        }
        mstore(0x40, m)
    }
}

function safeTransferETH(address to, uint256 amount) {
    assembly ("memory-safe") {
        if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
            mstore(0x00, ERR_TRANSFER)
            mstore(0x04, 2)
            revert(0x00, 0x24)
        }
    }
}

function safeTransfer(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0xa9059cbb000000000000000000000000) // transfer(address,uint256)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, ERR_TRANSFER)
                mstore(0x04, 0)
                revert(0x00, 0x24)
            }
        }
        mstore(0x34, 0)
    }
}

function safeTransferFrom(address token, address from, address to, uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x60, amount)
        mstore(0x40, to)
        mstore(0x2c, shl(96, from))
        mstore(0x0c, 0x23b872dd000000000000000000000000) // transferFrom(address,address,uint256)
        let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, ERR_TRANSFER)
                mstore(0x04, 1)
                revert(0x00, 0x24)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}
