// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice PAMM interface
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

    function tradingOpen(uint256 marketId) external view returns (bool);
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool);
    function setOperator(address operator, bool approved) external returns (bool);
    function split(uint256 marketId, uint256 amount, address to) external payable;
}

/// @notice PMHookRouter vault interface
interface IPMHookRouter {
    function depositToVault(
        uint256 marketId,
        bool isYes,
        uint256 shares,
        address receiver,
        uint256 deadline
    ) external returns (uint256 vaultShares);

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
        external
        payable
        returns (uint256 yesVaultSharesMinted, uint256 noVaultSharesMinted, uint256 ammLiquidity);

    function buyWithBootstrap(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        address to,
        uint256 deadline
    ) external payable returns (uint256 sharesOut, bytes4 source, uint256 vaultSharesMinted);

    function sellWithBootstrap(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        address to,
        uint256 deadline
    ) external returns (uint256 collateralOut, bytes4 source);
}

/// @title MasterRouter - Complete Abstraction Layer
/// @notice Pooled orderbook + vault integration for prediction markets
/// @dev Accumulator-based accounting prevents late joiner theft
contract MasterRouter {
    address constant ETH = address(0);
    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IPMHookRouter constant PM_HOOK_ROUTER =
        IPMHookRouter(0x0000000000Ff22a7FFEf88639d95C03183c5093C);

    uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268;
    uint256 constant ETH_SPENT_SLOT = 0x929eee149b4bd21269;
    uint256 constant MULTICALL_DEPTH_SLOT = 0x929eee149b4bd2126a;
    uint256 constant BPS_DENOM = 10000;
    uint256 constant ACC = 1e18; // Accumulator precision

    bytes4 constant ERR_VALIDATION = 0x077a9c33;
    bytes4 constant ERR_STATE = 0xd06e7808;
    bytes4 constant ERR_TRANSFER = 0x2929f974;
    bytes4 constant ERR_REENTRANCY = 0xab143c06;
    bytes4 constant ERR_LIQUIDITY = 0x4dae90b0;
    bytes4 constant ERR_TIMING = 0x3703bac9;
    bytes4 constant ERR_COMPUTATION = 0x05832717;

    /*//////////////////////////////////////////////////////////////
                        POOLED ORDERBOOK EVENTS
    //////////////////////////////////////////////////////////////*/

    event MintAndPool(
        uint256 indexed marketId,
        address indexed user,
        bytes32 indexed poolId,
        uint256 collateralIn,
        bool keepYes,
        uint256 priceInBps
    );

    event PoolFilled(
        bytes32 indexed poolId, address indexed taker, uint256 sharesFilled, uint256 collateralPaid
    );

    event ProceedsClaimed(bytes32 indexed poolId, address indexed user, uint256 collateralClaimed);

    event SharesWithdrawn(bytes32 indexed poolId, address indexed user, uint256 sharesWithdrawn);

    event SharesDeposited(
        uint256 indexed marketId,
        address indexed user,
        bytes32 indexed poolId,
        uint256 sharesIn,
        uint256 priceInBps
    );

    // Bid pool events (collateral pools buying shares)
    event BidPoolCreated(
        uint256 indexed marketId,
        address indexed user,
        bytes32 indexed bidPoolId,
        uint256 collateralIn,
        bool buyYes,
        uint256 priceInBps
    );

    event BidPoolFilled(
        bytes32 indexed bidPoolId,
        address indexed seller,
        uint256 sharesSold,
        uint256 collateralPaid
    );

    event BidSharesClaimed(bytes32 indexed bidPoolId, address indexed user, uint256 sharesClaimed);

    event BidCollateralWithdrawn(
        bytes32 indexed bidPoolId, address indexed user, uint256 collateralWithdrawn
    );

    /*//////////////////////////////////////////////////////////////
                        VAULT INTEGRATION EVENTS
    //////////////////////////////////////////////////////////////*/

    event LiquidityProvided(
        uint256 indexed marketId,
        address indexed user,
        uint256 yesVaultShares,
        uint256 noVaultShares,
        uint256 ammLiquidity
    );

    event MintAndVault(
        uint256 indexed marketId,
        address indexed user,
        uint256 collateralIn,
        bool keepYes,
        uint256 sharesKept,
        uint256 vaultShares
    );

    event MintAndSellOther(
        uint256 indexed marketId,
        address indexed user,
        uint256 collateralIn,
        bool keepYes,
        uint256 collateralRecovered
    );

    /*//////////////////////////////////////////////////////////////
                    ACCUMULATOR-BASED POOL STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool state with accumulator accounting
    /// @dev Uses LP units (scaled) + reward debt pattern to prevent late joiner theft
    struct Pool {
        uint256 totalShares; // Remaining PM shares available to buy
        uint256 totalScaled; // Total LP units issued
        uint256 accCollPerScaled; // Cumulative collateral per LP unit (scaled by 1e18)
        uint256 collateralEarned; // Total collateral collected (optional tracking)
    }

    /// @notice User position in a pool
    struct UserPosition {
        uint256 scaled; // LP units owned
        uint256 collDebt; // Reward debt (scaled * accCollPerScaled at last update)
    }

    // Pool ID => Pool data (ASK pools - selling shares for collateral)
    mapping(bytes32 => Pool) public pools;

    // Pool ID => User => Position
    mapping(bytes32 => mapping(address => UserPosition)) public positions;

    /*//////////////////////////////////////////////////////////////
                    BID POOL STRUCTS (BUY-SIDE LIQUIDITY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Bid pool state - collateral pool buying shares
    /// @dev Mirror of Pool struct but collateral in, shares out
    struct BidPool {
        uint256 totalCollateral; // Remaining collateral available to spend
        uint256 totalScaled; // Total LP units issued
        uint256 accSharesPerScaled; // Cumulative shares per LP unit (scaled by 1e18)
        uint256 sharesAcquired; // Total shares bought (optional tracking)
    }

    /// @notice User position in a bid pool
    struct BidPosition {
        uint256 scaled; // LP units owned
        uint256 sharesDebt; // Reward debt (scaled * accSharesPerScaled at last update)
    }

    // Bid Pool ID => BidPool data
    mapping(bytes32 => BidPool) public bidPools;

    // Bid Pool ID => User => Position
    mapping(bytes32 => mapping(address => BidPosition)) public bidPositions;

    /*//////////////////////////////////////////////////////////////
                    PRICE BITMAP FOR BEST BID/ASK DISCOVERY
    //////////////////////////////////////////////////////////////*/

    /// @dev Bitmap tracking active price levels
    /// Key: keccak256(marketId, isYes, isAsk) => 40 uint256s covering prices 0-10239
    /// Each bit represents whether a pool exists at that price (1-9999 valid range)
    mapping(bytes32 => uint256[40]) public priceBitmap;

    constructor() payable {
        PAMM.setOperator(address(PM_HOOK_ROUTER), true);
    }

    receive() external payable {}

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, ERR_REENTRANCY)
                revert(0x00, 0x04)
            }
            tstore(REENTRANCY_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(REENTRANCY_SLOT, 0)
        }
    }

    function _revert(bytes4 selector, uint8 code) internal pure {
        assembly ("memory-safe") {
            mstore(0x00, selector)
            mstore(0x04, code)
            revert(0x00, 0x24)
        }
    }

    /// @dev Validate ETH amount with multicall-aware cumulative tracking
    function _validateETHAmount(address collateral, uint256 requiredAmount) internal {
        assembly ("memory-safe") {
            if iszero(collateral) {
                switch tload(MULTICALL_DEPTH_SLOT)
                case 0 {
                    // Standalone call: simple validation against msg.value
                    if iszero(eq(callvalue(), requiredAmount)) {
                        mstore(0x00, ERR_VALIDATION)
                        mstore(0x04, 3)
                        revert(0x00, 0x24)
                    }
                }
                default {
                    // Multicall: track cumulative ETH requirement
                    let prev := tload(ETH_SPENT_SLOT)
                    let cumulativeRequired := add(prev, requiredAmount)
                    // Check for overflow
                    if mul(requiredAmount, lt(cumulativeRequired, prev)) {
                        mstore(0x00, ERR_VALIDATION)
                        mstore(0x04, 0)
                        revert(0x00, 0x24)
                    }
                    if lt(callvalue(), cumulativeRequired) {
                        mstore(0x00, ERR_VALIDATION)
                        mstore(0x04, 3)
                        revert(0x00, 0x24)
                    }
                    tstore(ETH_SPENT_SLOT, cumulativeRequired)
                }
            }
            // If non-ETH collateral but ETH sent, revert (unless in multicall where other calls may need it)
            if and(iszero(iszero(collateral)), iszero(iszero(callvalue()))) {
                if iszero(tload(MULTICALL_DEPTH_SLOT)) {
                    mstore(0x00, ERR_VALIDATION)
                    mstore(0x04, 4)
                    revert(0x00, 0x24)
                }
            }
        }
    }

    /// @dev Refund ETH to caller, deferring actual transfer if in multicall
    function _refundETHToCaller(uint256 amount) internal {
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
    }

    /*//////////////////////////////////////////////////////////////
                    POOLED ORDERBOOK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getPoolId(uint256 marketId, bool isYes, uint256 priceInBps)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(marketId, isYes, priceInBps));
    }

    /// @dev Get NO token ID using PAMM's formula
    function _getNoId(uint256 marketId) internal pure returns (uint256 noId) {
        assembly ("memory-safe") {
            mstore(0x00, 0x504d41524b45543a4e4f00000000000000000000000000000000000000000000)
            mstore(0x0a, marketId)
            noId := keccak256(0x00, 0x2a)
        }
    }

    function _getTokenId(uint256 marketId, bool isYes) internal pure returns (uint256) {
        return isYes ? marketId : _getNoId(marketId);
    }

    /// @notice Get user's position in a pool
    /// @dev Uses accumulator model: pending = (scaled * acc) / 1e18 - debt
    function getUserPosition(uint256 marketId, bool isYes, uint256 priceInBps, address user)
        public
        view
        returns (
            uint256 userScaled,
            uint256 userWithdrawableShares,
            uint256 userPendingCollateral,
            uint256 userCollateralDebt
        )
    {
        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage pool = pools[poolId];
        UserPosition storage pos = positions[poolId][user];

        userScaled = pos.scaled;
        if (userScaled == 0) return (0, 0, 0, 0);

        // Withdrawable shares = user's portion of remaining pool shares
        if (pool.totalScaled > 0) {
            userWithdrawableShares = mulDiv(pos.scaled, pool.totalShares, pool.totalScaled);
        }

        // Pending collateral = accumulated - debt
        uint256 accumulated = mulDiv(pos.scaled, pool.accCollPerScaled, ACC);
        userPendingCollateral = accumulated > pos.collDebt ? accumulated - pos.collDebt : 0;

        userCollateralDebt = pos.collDebt;
    }

    /// @notice Mint shares and pool one side at a specific price
    /// @dev Uses accumulator model to prevent late joiner theft
    function mintAndPool(
        uint256 marketId,
        uint256 collateralIn,
        bool keepYes,
        uint256 priceInBps,
        address to
    ) public payable nonReentrant returns (bytes32 poolId) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1);
        if (priceInBps == 0 || priceInBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        _validateETHAmount(collateral, collateralIn);
        if (collateral != ETH) {
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            _ensureApproval(collateral, address(PAMM));
        }

        PAMM.split{value: collateral == ETH ? collateralIn : 0}(
            marketId, collateralIn, address(this)
        );

        uint256 keepId = _getTokenId(marketId, keepYes);
        bool success = PAMM.transfer(to, keepId, collateralIn);
        if (!success) _revert(ERR_TRANSFER, 0);

        bool poolIsYes = !keepYes;
        poolId = getPoolId(marketId, poolIsYes, priceInBps);

        Pool storage pool = pools[poolId];
        bool wasEmpty = pool.totalShares == 0;

        _deposit(pool, positions[poolId][to], collateralIn);

        // Set bitmap if this is first deposit to this pool
        if (wasEmpty) {
            _setPriceBit(marketId, poolIsYes, true, priceInBps, true);
        }

        emit MintAndPool(marketId, msg.sender, poolId, collateralIn, keepYes, priceInBps);
    }

    /// @notice Deposit existing PM shares to an ASK pool at a specific price
    /// @dev Use this to migrate positions or add shares you already own to a pool
    /// @param marketId Market ID
    /// @param isYes True to deposit YES shares, false for NO shares
    /// @param sharesIn Amount of shares to deposit
    /// @param priceInBps Price to sell at (in basis points, 1-9999)
    /// @param to Recipient of pool position (LP units)
    /// @return poolId The pool identifier
    function depositSharesToPool(
        uint256 marketId,
        bool isYes,
        uint256 sharesIn,
        uint256 priceInBps,
        address to
    ) public nonReentrant returns (bytes32 poolId) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (sharesIn == 0) _revert(ERR_VALIDATION, 1);
        if (priceInBps == 0 || priceInBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);

        // Transfer shares from user
        uint256 tokenId = _getTokenId(marketId, isYes);
        bool success = PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);
        if (!success) _revert(ERR_TRANSFER, 1);

        poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage pool = pools[poolId];
        bool wasEmpty = pool.totalShares == 0;

        _deposit(pool, positions[poolId][to], sharesIn);

        if (wasEmpty) {
            _setPriceBit(marketId, isYes, true, priceInBps, true);
        }

        emit SharesDeposited(marketId, msg.sender, poolId, sharesIn, priceInBps);
    }

    /// @notice Migrate ASK pool position to a new price (no external share custody)
    /// @dev More gas-efficient than withdraw + deposit - shares stay in contract
    /// @param marketId Market ID
    /// @param isYes True for YES pool, false for NO pool
    /// @param oldPriceInBps Current price level to migrate from
    /// @param newPriceInBps New price level to migrate to
    /// @param sharesToMigrate Amount of shares to migrate (0 = all)
    /// @param to Recipient of new position and any claimed collateral
    /// @return sharesMigrated Shares moved to new pool
    /// @return collateralClaimed Pending collateral from old pool fills
    function migrateAskPosition(
        uint256 marketId,
        bool isYes,
        uint256 oldPriceInBps,
        uint256 newPriceInBps,
        uint256 sharesToMigrate,
        address to
    ) public nonReentrant returns (uint256 sharesMigrated, uint256 collateralClaimed) {
        if (to == address(0)) to = msg.sender;
        if (oldPriceInBps == 0 || oldPriceInBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);
        if (newPriceInBps == 0 || newPriceInBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);
        if (oldPriceInBps == newPriceInBps) _revert(ERR_VALIDATION, 7);

        bytes32 oldPoolId = getPoolId(marketId, isYes, oldPriceInBps);
        Pool storage oldPool = pools[oldPoolId];
        UserPosition storage oldPos = positions[oldPoolId][msg.sender];

        // Claim pending collateral from old pool
        collateralClaimed = _claim(oldPool, oldPos);

        // Withdraw shares (stay in contract)
        sharesMigrated = _withdraw(oldPool, oldPos, sharesToMigrate);

        // Clear old bitmap if empty
        if (oldPool.totalShares == 0) {
            _setPriceBit(marketId, isYes, true, oldPriceInBps, false);
        }

        // Deposit to new pool
        bytes32 newPoolId = getPoolId(marketId, isYes, newPriceInBps);
        Pool storage newPool = pools[newPoolId];
        bool wasEmpty = newPool.totalShares == 0;

        _deposit(newPool, positions[newPoolId][to], sharesMigrated);

        if (wasEmpty) {
            _setPriceBit(marketId, isYes, true, newPriceInBps, true);
        }

        // Transfer claimed collateral
        if (collateralClaimed > 0) {
            address collateral;
            (,,,,, collateral,) = PAMM.markets(marketId);
            if (collateral == ETH) {
                _safeTransferETH(to, collateralClaimed);
            } else {
                _safeTransfer(collateral, to, collateralClaimed);
            }
            emit ProceedsClaimed(oldPoolId, msg.sender, collateralClaimed);
        }

        emit SharesWithdrawn(oldPoolId, msg.sender, sharesMigrated);
        emit SharesDeposited(marketId, msg.sender, newPoolId, sharesMigrated, newPriceInBps);
    }

    /// @notice Migrate BID pool position to a different price level
    /// @dev Mirror of migrateAskPosition for BID pools
    function migrateBidPosition(
        uint256 marketId,
        bool buyYes,
        uint256 oldPriceInBps,
        uint256 newPriceInBps,
        uint256 collateralToMigrate,
        address to
    ) public nonReentrant returns (uint256 collateralMigrated, uint256 sharesClaimed) {
        if (to == address(0)) to = msg.sender;
        if (oldPriceInBps == 0 || oldPriceInBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);
        if (newPriceInBps == 0 || newPriceInBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);
        if (oldPriceInBps == newPriceInBps) _revert(ERR_VALIDATION, 7);

        bytes32 oldPoolId = getBidPoolId(marketId, buyYes, oldPriceInBps);
        BidPool storage oldPool = bidPools[oldPoolId];
        BidPosition storage oldPos = bidPositions[oldPoolId][msg.sender];

        // Claim pending shares from old pool
        sharesClaimed = _claimBidShares(oldPool, oldPos);

        // Withdraw collateral (stay in contract)
        collateralMigrated = _withdrawFromBidPool(oldPool, oldPos, collateralToMigrate);

        // Clear old bitmap if empty
        if (oldPool.totalCollateral == 0) {
            _setPriceBit(marketId, buyYes, false, oldPriceInBps, false);
        }

        // Deposit to new pool
        bytes32 newPoolId = getBidPoolId(marketId, buyYes, newPriceInBps);
        BidPool storage newPool = bidPools[newPoolId];
        bool wasEmpty = newPool.totalCollateral == 0;

        _depositToBidPool(newPool, bidPositions[newPoolId][to], collateralMigrated);

        if (wasEmpty) {
            _setPriceBit(marketId, buyYes, false, newPriceInBps, true);
        }

        // Transfer claimed shares
        if (sharesClaimed > 0) {
            uint256 tokenId = _getTokenId(marketId, buyYes);
            if (!PAMM.transfer(to, tokenId, sharesClaimed)) _revert(ERR_TRANSFER, 0);
            emit BidSharesClaimed(oldPoolId, msg.sender, sharesClaimed);
        }

        emit BidCollateralWithdrawn(oldPoolId, msg.sender, collateralMigrated);
        emit BidPoolCreated(
            marketId, msg.sender, newPoolId, collateralMigrated, buyYes, newPriceInBps
        );
    }

    /// @notice Internal: Deposit shares into pool (accumulator model)
    function _deposit(Pool storage p, UserPosition storage u, uint256 sharesIn) internal {
        uint256 mintScaled;
        if (p.totalScaled == 0) {
            // First depositor: 1:1 ratio
            mintScaled = sharesIn;
        } else if (p.totalShares == 0) {
            // Pool exhausted but LPs haven't withdrawn - no valid exchange rate
            _revert(ERR_STATE, 2);
        } else {
            // Buy in at current exchange rate
            // Round DOWN to favor existing LPs (safe direction)
            mintScaled = mulDiv(sharesIn, p.totalScaled, p.totalShares);
            if (mintScaled == 0) _revert(ERR_VALIDATION, 10); // Deposit too small
        }

        p.totalShares += sharesIn;
        p.totalScaled += mintScaled;

        u.scaled += mintScaled;
        // Add debt only for NEW units - preserves pending rewards from existing units
        u.collDebt += mulDiv(mintScaled, p.accCollPerScaled, ACC);
    }

    /// @notice Fill shares from a pool
    /// @param marketId Market ID
    /// @param isYes True to buy YES shares, false for NO
    /// @param priceInBps Price level in basis points
    /// @param sharesWanted Amount of shares to buy
    /// @param maxCollateral Maximum collateral willing to pay (slippage protection)
    /// @param to Recipient of shares
    /// @param deadline Transaction deadline (0 = no deadline)
    function fillFromPool(
        uint256 marketId,
        bool isYes,
        uint256 priceInBps,
        uint256 sharesWanted,
        uint256 maxCollateral,
        address to,
        uint256 deadline
    ) public payable nonReentrant returns (uint256 sharesBought, uint256 collateralPaid) {
        if (to == address(0)) to = msg.sender;
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (sharesWanted == 0) _revert(ERR_VALIDATION, 1);

        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage pool = pools[poolId];

        if (sharesWanted > pool.totalShares) _revert(ERR_LIQUIDITY, 0);

        sharesBought = sharesWanted;
        // Use CEILING division to protect sellers
        collateralPaid = mulDivUp(sharesWanted, priceInBps, BPS_DENOM);
        if (collateralPaid == 0) _revert(ERR_VALIDATION, 5);
        if (maxCollateral != 0 && collateralPaid > maxCollateral) _revert(ERR_VALIDATION, 9);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        _validateETHAmount(collateral, collateralPaid);
        if (collateral != ETH) {
            _safeTransferFrom(collateral, msg.sender, address(this), collateralPaid);
        }

        _fill(pool, sharesBought, collateralPaid);

        // Clear bitmap if pool is now empty
        if (pool.totalShares == 0) {
            _setPriceBit(marketId, isYes, true, priceInBps, false);
        }

        uint256 tokenId = _getTokenId(marketId, isYes);
        bool success = PAMM.transfer(to, tokenId, sharesBought);
        if (!success) _revert(ERR_TRANSFER, 0);

        emit PoolFilled(poolId, msg.sender, sharesBought, collateralPaid);
    }

    /// @notice Internal: Fill from pool (accumulator model)
    function _fill(Pool storage p, uint256 sharesOut, uint256 collateralIn) internal {
        if (p.totalScaled == 0) _revert(ERR_STATE, 1); // Empty pool

        // Remove shares from pool
        p.totalShares -= sharesOut;

        // Add to cumulative earnings per LP unit
        p.collateralEarned += collateralIn;
        p.accCollPerScaled += mulDiv(collateralIn, ACC, p.totalScaled);
    }

    /// @notice Claim collateral proceeds from pool fills
    function claimProceeds(uint256 marketId, bool isYes, uint256 priceInBps, address to)
        public
        nonReentrant
        returns (uint256 collateralClaimed)
    {
        if (to == address(0)) to = msg.sender;

        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage pool = pools[poolId];
        UserPosition storage pos = positions[poolId][msg.sender];

        collateralClaimed = _claim(pool, pos);

        if (collateralClaimed > 0) {
            address collateral;
            (,,,,, collateral,) = PAMM.markets(marketId);

            if (collateral == ETH) {
                _safeTransferETH(to, collateralClaimed);
            } else {
                _safeTransfer(collateral, to, collateralClaimed);
            }

            emit ProceedsClaimed(poolId, msg.sender, collateralClaimed);
        }
    }

    /// @notice Internal: Claim proceeds (accumulator model)
    function _claim(Pool storage p, UserPosition storage u) internal returns (uint256 claimable) {
        uint256 accumulated = mulDiv(u.scaled, p.accCollPerScaled, ACC);
        if (accumulated <= u.collDebt) return 0;

        claimable = accumulated - u.collDebt;
        u.collDebt = accumulated;
    }

    /// @notice Withdraw unfilled shares from pool
    /// @dev Auto-claims any pending proceeds before withdrawing to prevent loss
    function withdrawFromPool(
        uint256 marketId,
        bool isYes,
        uint256 priceInBps,
        uint256 sharesToWithdraw,
        address to
    ) public nonReentrant returns (uint256 sharesWithdrawn, uint256 collateralClaimed) {
        if (to == address(0)) to = msg.sender;

        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage pool = pools[poolId];
        UserPosition storage pos = positions[poolId][msg.sender];

        // Auto-claim pending proceeds first to prevent loss
        collateralClaimed = _claim(pool, pos);

        sharesWithdrawn = _withdraw(pool, pos, sharesToWithdraw);

        // Clear bitmap if pool is now empty
        if (pool.totalShares == 0) {
            _setPriceBit(marketId, isYes, true, priceInBps, false);
        }

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        // Transfer claimed proceeds
        if (collateralClaimed > 0) {
            if (collateral == ETH) {
                _safeTransferETH(to, collateralClaimed);
            } else {
                _safeTransfer(collateral, to, collateralClaimed);
            }
            emit ProceedsClaimed(poolId, msg.sender, collateralClaimed);
        }

        // Transfer withdrawn shares
        uint256 tokenId = _getTokenId(marketId, isYes);
        bool success = PAMM.transfer(to, tokenId, sharesWithdrawn);
        if (!success) _revert(ERR_TRANSFER, 0);

        emit SharesWithdrawn(poolId, msg.sender, sharesWithdrawn);
    }

    /// @notice Exit a depleted ASK pool - burn LP units when no shares remain
    /// @dev Use when pool is fully filled (totalShares=0) but you still have scaled position
    /// @param marketId Market ID
    /// @param isYes True for YES pool, false for NO pool
    /// @param priceInBps Price level in basis points
    /// @param to Recipient of any remaining collateral proceeds
    /// @return collateralClaimed Collateral claimed from pending proceeds
    function exitDepletedAskPool(uint256 marketId, bool isYes, uint256 priceInBps, address to)
        public
        nonReentrant
        returns (uint256 collateralClaimed)
    {
        if (to == address(0)) to = msg.sender;

        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage p = pools[poolId];
        UserPosition storage u = positions[poolId][msg.sender];

        // Only allowed when pool is depleted (no shares left to withdraw)
        if (p.totalShares != 0) _revert(ERR_STATE, 3);
        if (u.scaled == 0) _revert(ERR_VALIDATION, 6);

        // Claim any pending proceeds first
        collateralClaimed = _claim(p, u);

        // Burn all user's LP units
        uint256 burnScaled = u.scaled;
        u.scaled = 0;
        u.collDebt = 0;
        p.totalScaled -= burnScaled;

        // Clear bitmap if pool is fully exited (no shares and no LPs)
        if (p.totalScaled == 0) {
            _setPriceBit(marketId, isYes, true, priceInBps, false);
        }

        // Transfer claimed proceeds
        if (collateralClaimed > 0) {
            address collateral;
            (,,,,, collateral,) = PAMM.markets(marketId);

            if (collateral == ETH) {
                _safeTransferETH(to, collateralClaimed);
            } else {
                _safeTransfer(collateral, to, collateralClaimed);
            }

            emit ProceedsClaimed(poolId, msg.sender, collateralClaimed);
        }
    }

    /// @notice Internal: Withdraw shares (accumulator model)
    function _withdraw(Pool storage p, UserPosition storage u, uint256 sharesWanted)
        internal
        returns (uint256 sharesOut)
    {
        // User's maximum withdrawable shares
        uint256 userMax = p.totalScaled > 0 ? mulDiv(u.scaled, p.totalShares, p.totalScaled) : 0;
        if (userMax == 0) _revert(ERR_VALIDATION, 6);

        sharesOut = (sharesWanted == 0) ? userMax : sharesWanted;
        if (sharesOut > userMax) _revert(ERR_VALIDATION, 8);

        // Burn corresponding LP units (round UP for safety)
        uint256 burnScaled = mulDivUp(sharesOut, p.totalScaled, p.totalShares);
        if (burnScaled > u.scaled) burnScaled = u.scaled; // Safety cap

        // Update pool
        p.totalShares -= sharesOut;
        p.totalScaled -= burnScaled;

        // Update user - subtract proportional debt to preserve pending
        uint256 debtToRemove = mulDiv(burnScaled, p.accCollPerScaled, ACC);
        u.scaled -= burnScaled;
        u.collDebt = u.collDebt > debtToRemove ? u.collDebt - debtToRemove : 0;
    }

    /*//////////////////////////////////////////////////////////////
                    VAULT INTEGRATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint shares and deposit one side to PMHookRouter vault
    function mintAndVault(uint256 marketId, uint256 collateralIn, bool keepYes, address to)
        public
        payable
        nonReentrant
        returns (uint256 sharesKept, uint256 vaultShares)
    {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        _validateETHAmount(collateral, collateralIn);
        if (collateral != ETH) {
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            _ensureApproval(collateral, address(PAMM));
        }

        PAMM.split{value: collateral == ETH ? collateralIn : 0}(
            marketId, collateralIn, address(this)
        );

        uint256 keepId = _getTokenId(marketId, keepYes);
        sharesKept = collateralIn;
        bool success = PAMM.transfer(to, keepId, sharesKept);
        if (!success) _revert(ERR_TRANSFER, 0);

        vaultShares =
            PM_HOOK_ROUTER.depositToVault(marketId, !keepYes, collateralIn, to, type(uint256).max);

        emit MintAndVault(marketId, msg.sender, collateralIn, keepYes, sharesKept, vaultShares);
    }

    /// @notice Mint and sell other side into bid pools, then PMHookRouter
    /// @dev Recovers collateral instead of vault LP position
    function mintAndSellOther(
        uint256 marketId,
        uint256 collateralIn,
        bool keepYes,
        uint256 minPriceBps,
        address to,
        uint256 deadline
    ) public payable nonReentrant returns (uint256 sharesKept, uint256 collateralRecovered) {
        if (to == address(0)) to = msg.sender;
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1);
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        _validateETHAmount(collateral, collateralIn);
        if (collateral != ETH) {
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
            _ensureApproval(collateral, address(PAMM));
        }

        // Mint both sides
        PAMM.split{value: collateral == ETH ? collateralIn : 0}(
            marketId, collateralIn, address(this)
        );

        // Transfer kept side to user
        sharesKept = collateralIn;
        {
            uint256 keepId = _getTokenId(marketId, keepYes);
            if (!PAMM.transfer(to, keepId, sharesKept)) _revert(ERR_TRANSFER, 0);
        }

        // Sell other side
        bool sellYes = !keepYes;
        uint256 remaining = collateralIn;
        uint256 poolColl; // Track pool collateral separately (needs transfer from MasterRouter)

        // Sweep bid pools from highest price down
        if (minPriceBps > 0) {
            bytes32 bitmapKey = _getBitmapKey(marketId, sellYes, false);

            for (uint256 b; b < 40 && remaining > 0; ++b) {
                uint256 bucket = 39 - b;
                uint256 word = priceBitmap[bitmapKey][bucket];

                while (word != 0 && remaining > 0) {
                    uint256 bit = _highestSetBit(word);
                    uint256 price = (bucket << 8) | bit;
                    word &= ~(1 << bit);

                    if (price < minPriceBps) continue;

                    bytes32 bidPoolId = getBidPoolId(marketId, sellYes, price);
                    BidPool storage bp = bidPools[bidPoolId];
                    uint256 depth = bp.totalCollateral;
                    if (depth == 0) continue;

                    uint256 maxShares = mulDiv(depth, BPS_DENOM, price);
                    uint256 toSell;
                    uint256 toReceive;

                    if (remaining >= maxShares) {
                        toSell = maxShares;
                        toReceive = depth;
                    } else {
                        toSell = remaining;
                        toReceive = mulDivUp(toSell, price, BPS_DENOM);
                    }

                    if (toSell == 0) continue;

                    _fillBidPool(bp, toSell, toReceive);

                    if (bp.totalCollateral == 0) {
                        _setPriceBit(marketId, sellYes, false, price, false);
                    }

                    poolColl += toReceive;
                    remaining -= toSell;

                    emit BidPoolFilled(bidPoolId, msg.sender, toSell, toReceive);
                }
            }
        }

        collateralRecovered = poolColl;

        // Route remainder through PMHookRouter (sends collateral directly to `to`)
        if (remaining > 0) {
            (uint256 pmColl,) = PM_HOOK_ROUTER.sellWithBootstrap(
                marketId, sellYes, remaining, 0, to, deadline == 0 ? type(uint256).max : deadline
            );
            collateralRecovered += pmColl;
        }

        // Transfer pool collateral to user (PMHookRouter already sent its portion)
        if (poolColl > 0) {
            if (collateral == ETH) {
                _safeTransferETH(to, poolColl);
            } else {
                _safeTransfer(collateral, to, poolColl);
            }
        }

        emit MintAndSellOther(marketId, msg.sender, collateralIn, keepYes, collateralRecovered);
    }

    /// @notice Buy shares with multi-price sweep (fills best-priced pools first)
    /// @dev Sweeps ASK pools from lowest price up to maxPriceBps, then routes remainder to PMHookRouter
    /// @param marketId Market to buy in
    /// @param buyYes True to buy YES shares, false for NO shares
    /// @param collateralIn Amount of collateral to spend
    /// @param minSharesOut Minimum shares to receive (slippage protection)
    /// @param maxPriceBps Maximum price willing to pay from pools (0 = skip pools, use PMHookRouter only)
    /// @param to Recipient of shares
    /// @param deadline Transaction deadline (0 = no deadline)
    /// @return totalSharesOut Total shares received
    /// @return poolSharesOut Shares filled from pools
    /// @return poolLevelsFilled Number of price levels touched
    /// @return sources Execution sources used
    function buyWithSweep(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 minSharesOut,
        uint256 maxPriceBps,
        address to,
        uint256 deadline
    )
        public
        payable
        nonReentrant
        returns (
            uint256 totalSharesOut,
            uint256 poolSharesOut,
            uint256 poolLevelsFilled,
            bytes4[] memory sources
        )
    {
        if (to == address(0)) to = msg.sender;
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);
        if (deadline == 0) deadline = type(uint256).max;
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1);
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        _validateETHAmount(collateral, collateralIn);
        if (collateral != ETH) {
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
        }

        uint256 remainingCollateral = collateralIn;

        // Step 1: Sweep pools from lowest price up to maxPriceBps
        if (maxPriceBps > 0 && maxPriceBps < BPS_DENOM) {
            bytes32 bitmapKey = _getBitmapKey(marketId, buyYes, true);
            uint256 tokenId = _getTokenId(marketId, buyYes);

            // Scan from lowest price upward
            for (uint256 bucket; bucket < 40 && remainingCollateral > 0; ++bucket) {
                uint256 word = priceBitmap[bitmapKey][bucket];
                while (word != 0 && remainingCollateral > 0) {
                    uint256 bit = _lowestSetBit(word);
                    uint256 price = (bucket << 8) | bit;
                    word &= ~(1 << bit);

                    // Skip invalid prices or prices above max
                    if (price == 0 || price > maxPriceBps) continue;

                    bytes32 poolId = getPoolId(marketId, buyYes, price);
                    Pool storage pool = pools[poolId];
                    uint256 depth = pool.totalShares;
                    if (depth == 0) continue;

                    // Calculate fill amount
                    uint256 costToFill = mulDivUp(depth, price, BPS_DENOM);
                    uint256 sharesToBuy;
                    uint256 collateralNeeded;

                    if (remainingCollateral >= costToFill) {
                        // Fill entire pool
                        sharesToBuy = depth;
                        collateralNeeded = costToFill;
                    } else {
                        // Partial fill
                        sharesToBuy = mulDiv(remainingCollateral, BPS_DENOM, price);
                        if (sharesToBuy == 0) continue;
                        collateralNeeded = mulDivUp(sharesToBuy, price, BPS_DENOM);
                    }

                    // Execute fill
                    _fill(pool, sharesToBuy, collateralNeeded);

                    // Clear bitmap if pool is now empty
                    if (pool.totalShares == 0) {
                        _setPriceBit(marketId, buyYes, true, price, false);
                    }

                    // Transfer shares to recipient
                    bool success = PAMM.transfer(to, tokenId, sharesToBuy);
                    if (!success) _revert(ERR_TRANSFER, 0);

                    emit PoolFilled(poolId, msg.sender, sharesToBuy, collateralNeeded);

                    poolSharesOut += sharesToBuy;
                    totalSharesOut += sharesToBuy;
                    remainingCollateral -= collateralNeeded;
                    ++poolLevelsFilled;
                }
            }
        }

        // Step 2: Route remaining through PMHookRouter
        if (remainingCollateral > 0) {
            if (collateral != ETH) {
                _ensureApproval(collateral, address(PM_HOOK_ROUTER));
            }

            uint256 balanceBefore =
                collateral == ETH ? address(this).balance : _getBalance(collateral, address(this));

            (uint256 additionalShares, bytes4 pmSource,) = PM_HOOK_ROUTER.buyWithBootstrap{
                value: collateral == ETH ? remainingCollateral : 0
            }(
                marketId,
                buyYes,
                remainingCollateral,
                minSharesOut > totalSharesOut ? minSharesOut - totalSharesOut : 0,
                to,
                deadline
            );

            totalSharesOut += additionalShares;

            // Refund any collateral returned by PMHookRouter
            {
                uint256 balanceAfter = collateral == ETH
                    ? address(this).balance
                    : _getBalance(collateral, address(this));
                uint256 expectedBalance = balanceBefore - remainingCollateral;
                if (balanceAfter > expectedBalance) {
                    uint256 refund = balanceAfter - expectedBalance;
                    if (collateral == ETH) {
                        _refundETHToCaller(refund);
                    } else {
                        _safeTransfer(collateral, msg.sender, refund);
                    }
                }
            }

            // Build sources array
            if (poolLevelsFilled > 0) {
                sources = new bytes4[](2);
                sources[0] = bytes4(keccak256("POOL"));
                sources[1] = pmSource;
            } else {
                sources = new bytes4[](1);
                sources[0] = pmSource;
            }
        } else if (poolLevelsFilled > 0) {
            sources = new bytes4[](1);
            sources[0] = bytes4(keccak256("POOL"));
        }

        if (totalSharesOut < minSharesOut) _revert(ERR_VALIDATION, 9);
    }

    /// @dev Internal: sweep ASK pools up to maxPriceBps, returns shares bought and remaining collateral
    function _sweepAskPools(
        uint256 marketId,
        bool buyYes,
        uint256 rem,
        uint256 maxPriceBps,
        address to
    ) internal returns (uint256 sharesOut, uint256 remaining) {
        remaining = rem;
        if (maxPriceBps == 0 || maxPriceBps >= BPS_DENOM) return (0, remaining);
        uint256 tid = _getTokenId(marketId, buyYes);
        bytes32 bk = _getBitmapKey(marketId, buyYes, true);
        for (uint256 b; b < 40 && remaining > 0; ++b) {
            uint256 w = priceBitmap[bk][b];
            while (w != 0 && remaining > 0) {
                uint256 bit = _lowestSetBit(w);
                uint256 p = (b << 8) | bit;
                w &= ~(1 << bit);
                if (p == 0 || p > maxPriceBps) continue;
                Pool storage pl = pools[getPoolId(marketId, buyYes, p)];
                uint256 d = pl.totalShares;
                if (d == 0) continue;
                uint256 cost = mulDivUp(d, p, BPS_DENOM);
                uint256 s;
                uint256 c;
                if (remaining >= cost) {
                    s = d;
                    c = cost;
                } else {
                    s = mulDiv(remaining, BPS_DENOM, p);
                    if (s == 0) continue;
                    c = mulDivUp(s, p, BPS_DENOM);
                }
                _fill(pl, s, c);
                if (pl.totalShares == 0) _setPriceBit(marketId, buyYes, true, p, false);
                if (!PAMM.transfer(to, tid, s)) _revert(ERR_TRANSFER, 0);
                emit PoolFilled(getPoolId(marketId, buyYes, p), msg.sender, s, c);
                unchecked {
                    sharesOut += s;
                    remaining -= c;
                }
            }
        }
    }

    /// @notice Buy with ASK pool sweep, deposit unfilled collateral to BID pool as limit order
    function buyWithBidFallback(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 maxSweepPriceBps,
        uint256 bidPriceBps,
        address to,
        uint256 deadline
    ) public payable nonReentrant returns (uint256 sharesOut, bytes32 bidPoolId) {
        assembly { if iszero(to) { to := caller() } }
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1);
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (bidPriceBps == 0 || bidPriceBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);

        address coll;
        (,,,,, coll,) = PAMM.markets(marketId);
        _validateETHAmount(coll, collateralIn);
        if (coll != ETH) _safeTransferFrom(coll, msg.sender, address(this), collateralIn);

        uint256 rem;
        (sharesOut, rem) = _sweepAskPools(marketId, buyYes, collateralIn, maxSweepPriceBps, to);

        // Deposit remaining collateral to BID pool as limit order
        if (rem > 0) {
            bidPoolId = getBidPoolId(marketId, buyYes, bidPriceBps);
            BidPool storage bp = bidPools[bidPoolId];
            bool empty = bp.totalCollateral == 0;
            _depositToBidPool(bp, bidPositions[bidPoolId][to], rem);
            if (empty) _setPriceBit(marketId, buyYes, false, bidPriceBps, true);
            emit BidPoolCreated(marketId, to, bidPoolId, rem, buyYes, bidPriceBps);
        }
    }

    /// @notice Sweep ASK pools, mint with remainder, pool other side as ASK liquidity
    function sweepMintAndPool(
        uint256 marketId,
        bool buyYes,
        uint256 collateralIn,
        uint256 maxSweepPriceBps,
        uint256 askPriceBps,
        address to,
        uint256 deadline
    ) public payable nonReentrant returns (uint256 sharesOut, bytes32 poolId) {
        assembly {
            if iszero(to) { to := caller() }
        }
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);
        if (collateralIn == 0 || askPriceBps == 0 || askPriceBps >= BPS_DENOM) {
            _revert(ERR_VALIDATION, 1);
        }
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        address coll;
        (,,,,, coll,) = PAMM.markets(marketId);
        _validateETHAmount(coll, collateralIn);
        if (coll != ETH) {
            _safeTransferFrom(coll, msg.sender, address(this), collateralIn);
            _ensureApproval(coll, address(PAMM));
        }

        uint256 rem;
        (sharesOut, rem) = _sweepAskPools(marketId, buyYes, collateralIn, maxSweepPriceBps, to);

        // Mint with remainder and pool other side
        if (rem > 0) {
            PAMM.split{value: coll == ETH ? rem : 0}(marketId, rem, address(this));
            if (!PAMM.transfer(to, _getTokenId(marketId, buyYes), rem)) _revert(ERR_TRANSFER, 0);
            unchecked {
                sharesOut += rem;
            }
            poolId = getPoolId(marketId, !buyYes, askPriceBps);
            Pool storage pool = pools[poolId];
            bool empty = pool.totalShares == 0;
            _deposit(pool, positions[poolId][to], rem);
            if (empty) _setPriceBit(marketId, !buyYes, true, askPriceBps, true);
            emit SharesDeposited(marketId, to, poolId, rem, askPriceBps);
        }
    }

    /// @notice Sell with BID pool sweep, deposit unsold to ASK pool
    function sellWithAskFallback(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256 minPriceBps,
        uint256 askPriceBps,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 collOut, bytes32 askPoolId) {
        assembly {
            if iszero(to) {
                to := caller()
            }
        }
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);
        if (sharesIn == 0 || askPriceBps == 0 || askPriceBps >= BPS_DENOM) {
            _revert(ERR_VALIDATION, 1);
        }
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        uint256 tid = _getTokenId(marketId, sellYes);
        if (!PAMM.transferFrom(msg.sender, address(this), tid, sharesIn)) _revert(ERR_TRANSFER, 1);
        address coll;
        (,,,,, coll,) = PAMM.markets(marketId);
        uint256 rem = sharesIn;
        if (minPriceBps > 0 && minPriceBps < BPS_DENOM) {
            bytes32 bk = _getBitmapKey(marketId, sellYes, false);
            for (uint256 b; b < 40 && rem > 0; ++b) {
                uint256 w = priceBitmap[bk][39 - b];
                while (w != 0 && rem > 0) {
                    uint256 bit = _highestSetBit(w);
                    uint256 p = ((39 - b) << 8) | bit;
                    w &= ~(1 << bit);
                    if (p == 0 || p < minPriceBps) continue;
                    BidPool storage bp = bidPools[getBidPoolId(marketId, sellYes, p)];
                    uint256 d = bp.totalCollateral;
                    if (d == 0) continue;
                    uint256 maxS = mulDiv(d, BPS_DENOM, p);
                    uint256 s = rem >= maxS ? maxS : rem;
                    uint256 c = rem >= maxS ? d : mulDivUp(s, p, BPS_DENOM);
                    _fillBidPool(bp, s, c);
                    if (bp.totalCollateral == 0) _setPriceBit(marketId, sellYes, false, p, false);
                    if (coll == ETH) payable(to).transfer(c);
                    else _safeTransfer(coll, to, c);
                    emit BidPoolFilled(getBidPoolId(marketId, sellYes, p), msg.sender, s, c);
                    unchecked {
                        collOut += c;
                        rem -= s;
                    }
                }
            }
        }
        if (rem > 0) {
            askPoolId = getPoolId(marketId, sellYes, askPriceBps);
            Pool storage pool = pools[askPoolId];
            bool empty = pool.totalShares == 0;
            _deposit(pool, positions[askPoolId][to], rem);
            if (empty) _setPriceBit(marketId, sellYes, true, askPriceBps, true);
            emit SharesDeposited(marketId, to, askPoolId, rem, askPriceBps);
        }
    }

    /// @notice Sell shares with multi-price sweep (fills best-priced bid pools first)
    /// @dev Sweeps BID pools from highest price down to minPriceBps, then routes remainder to PMHookRouter
    /// @param marketId Market to sell in
    /// @param sellYes True to sell YES shares, false for NO shares
    /// @param sharesIn Amount of shares to sell
    /// @param minCollateralOut Minimum collateral to receive (slippage protection)
    /// @param minPriceBps Minimum price willing to accept from bid pools (0 = skip pools, use PMHookRouter only)
    /// @param to Recipient of collateral
    /// @param deadline Transaction deadline (0 = no deadline)
    /// @return totalCollateralOut Total collateral received
    /// @return poolCollateralOut Collateral from bid pools
    /// @return poolLevelsFilled Number of price levels touched
    /// @return sources Execution sources used
    function sellWithSweep(
        uint256 marketId,
        bool sellYes,
        uint256 sharesIn,
        uint256 minCollateralOut,
        uint256 minPriceBps,
        address to,
        uint256 deadline
    )
        public
        nonReentrant
        returns (
            uint256 totalCollateralOut,
            uint256 poolCollateralOut,
            uint256 poolLevelsFilled,
            bytes4[] memory sources
        )
    {
        if (to == address(0)) to = msg.sender;
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);
        if (deadline == 0) deadline = type(uint256).max;
        if (sharesIn == 0) _revert(ERR_VALIDATION, 1);
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);

        // Transfer shares from seller to this contract
        uint256 tokenId = _getTokenId(marketId, sellYes);
        bool success = PAMM.transferFrom(msg.sender, address(this), tokenId, sharesIn);
        if (!success) _revert(ERR_TRANSFER, 1);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        uint256 remainingShares = sharesIn;

        // Step 1: Sweep bid pools from highest price down to minPriceBps
        if (minPriceBps > 0 && minPriceBps < BPS_DENOM) {
            bytes32 bitmapKey = _getBitmapKey(marketId, sellYes, false); // false = BID pools

            // Scan from highest price downward
            for (uint256 b; b < 40 && remainingShares > 0; ++b) {
                uint256 bucket = 39 - b;
                uint256 word = priceBitmap[bitmapKey][bucket];
                while (word != 0 && remainingShares > 0) {
                    uint256 bit = _highestSetBit(word);
                    uint256 price = (bucket << 8) | bit;
                    word &= ~(1 << bit);

                    // Skip invalid prices or prices below minimum
                    if (price == 0 || price < minPriceBps) continue;

                    bytes32 bidPoolId = getBidPoolId(marketId, sellYes, price);
                    BidPool storage bidPool = bidPools[bidPoolId];
                    uint256 collateralDepth = bidPool.totalCollateral;
                    if (collateralDepth == 0) continue;

                    // Calculate fill amount
                    // Max shares this pool can buy at its price
                    uint256 maxShares = mulDiv(collateralDepth, BPS_DENOM, price);
                    uint256 sharesToSell;
                    uint256 collateralToReceive;

                    if (remainingShares >= maxShares) {
                        // Fill entire pool
                        sharesToSell = maxShares;
                        collateralToReceive = collateralDepth;
                    } else {
                        // Partial fill
                        sharesToSell = remainingShares;
                        collateralToReceive = mulDivUp(sharesToSell, price, BPS_DENOM);
                    }

                    if (sharesToSell == 0 || collateralToReceive == 0) continue;

                    // Execute fill
                    _fillBidPool(bidPool, sharesToSell, collateralToReceive);

                    // Clear bitmap if bid pool is now empty
                    if (bidPool.totalCollateral == 0) {
                        _setPriceBit(marketId, sellYes, false, price, false);
                    }

                    // Transfer collateral to seller
                    if (collateral == ETH) {
                        _safeTransferETH(to, collateralToReceive);
                    } else {
                        _safeTransfer(collateral, to, collateralToReceive);
                    }

                    emit BidPoolFilled(bidPoolId, msg.sender, sharesToSell, collateralToReceive);

                    poolCollateralOut += collateralToReceive;
                    totalCollateralOut += collateralToReceive;
                    remainingShares -= sharesToSell;
                    ++poolLevelsFilled;
                }
            }
        }

        // Step 2: Route remaining through PMHookRouter
        if (remainingShares > 0) {
            bytes4 pmSource;
            uint256 pmCollateral;
            (pmCollateral, pmSource) = PM_HOOK_ROUTER.sellWithBootstrap(
                marketId,
                sellYes,
                remainingShares,
                minCollateralOut > totalCollateralOut ? minCollateralOut - totalCollateralOut : 0,
                to,
                deadline
            );

            totalCollateralOut += pmCollateral;

            // Build sources array
            if (poolLevelsFilled > 0) {
                sources = new bytes4[](2);
                sources[0] = bytes4(keccak256("BIDPOOL"));
                sources[1] = pmSource;
            } else {
                sources = new bytes4[](1);
                sources[0] = pmSource;
            }
        } else if (poolLevelsFilled > 0) {
            sources = new bytes4[](1);
            sources[0] = bytes4(keccak256("BIDPOOL"));
        }

        if (totalCollateralOut < minCollateralOut) _revert(ERR_VALIDATION, 9);
    }

    /*//////////////////////////////////////////////////////////////
                    BID POOL FUNCTIONS (BUY-SIDE LIQUIDITY)
    //////////////////////////////////////////////////////////////*/

    /// @notice Get bid pool ID for a market/side/price combination
    function getBidPoolId(uint256 marketId, bool buyYes, uint256 priceInBps)
        public
        pure
        returns (bytes32)
    {
        // Use different prefix to avoid collision with ask pools
        return keccak256(abi.encode("BID", marketId, buyYes, priceInBps));
    }

    /// @notice Get user's position in a bid pool
    function getBidPosition(uint256 marketId, bool buyYes, uint256 priceInBps, address user)
        public
        view
        returns (
            uint256 userScaled,
            uint256 userWithdrawableCollateral,
            uint256 userPendingShares,
            uint256 userSharesDebt
        )
    {
        bytes32 bidPoolId = getBidPoolId(marketId, buyYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];
        BidPosition storage pos = bidPositions[bidPoolId][user];

        userScaled = pos.scaled;
        if (userScaled == 0) return (0, 0, 0, 0);

        // Withdrawable collateral = user's portion of remaining pool collateral
        if (bidPool.totalScaled > 0) {
            userWithdrawableCollateral =
                mulDiv(pos.scaled, bidPool.totalCollateral, bidPool.totalScaled);
        }

        // Pending shares = accumulated - debt
        uint256 accumulated = mulDiv(pos.scaled, bidPool.accSharesPerScaled, ACC);
        userPendingShares = accumulated > pos.sharesDebt ? accumulated - pos.sharesDebt : 0;

        userSharesDebt = pos.sharesDebt;
    }

    /// @notice Create a bid pool - deposit collateral to buy shares at a specific price
    /// @param marketId Market to bid on
    /// @param collateralIn Collateral to deposit
    /// @param buyYes True to bid for YES shares, false for NO shares
    /// @param priceInBps Price willing to pay in basis points (1-9999)
    /// @param to Recipient of position (and eventually shares)
    function createBidPool(
        uint256 marketId,
        uint256 collateralIn,
        bool buyYes,
        uint256 priceInBps,
        address to
    ) public payable nonReentrant returns (bytes32 bidPoolId) {
        if (to == address(0)) to = msg.sender;
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (collateralIn == 0) _revert(ERR_VALIDATION, 1);
        if (priceInBps == 0 || priceInBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        _validateETHAmount(collateral, collateralIn);
        if (collateral != ETH) {
            _safeTransferFrom(collateral, msg.sender, address(this), collateralIn);
        }

        bidPoolId = getBidPoolId(marketId, buyYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];
        bool wasEmpty = bidPool.totalCollateral == 0;

        _depositToBidPool(bidPool, bidPositions[bidPoolId][to], collateralIn);

        // Set bitmap if this is first deposit to this pool
        if (wasEmpty) {
            _setPriceBit(marketId, buyYes, false, priceInBps, true);
        }

        emit BidPoolCreated(marketId, msg.sender, bidPoolId, collateralIn, buyYes, priceInBps);
    }

    /// @notice Internal: Deposit collateral into bid pool
    function _depositToBidPool(BidPool storage p, BidPosition storage u, uint256 collateralIn)
        internal
    {
        uint256 mintScaled;
        if (p.totalScaled == 0) {
            mintScaled = collateralIn;
        } else if (p.totalCollateral == 0) {
            // Pool exhausted but LPs haven't withdrawn - no valid exchange rate
            _revert(ERR_STATE, 2);
        } else {
            mintScaled = mulDiv(collateralIn, p.totalScaled, p.totalCollateral);
            if (mintScaled == 0) _revert(ERR_VALIDATION, 10);
        }

        p.totalCollateral += collateralIn;
        p.totalScaled += mintScaled;

        u.scaled += mintScaled;
        // Add debt only for NEW units - preserves pending shares from existing units
        u.sharesDebt += mulDiv(mintScaled, p.accSharesPerScaled, ACC);
    }

    /// @notice Sell shares directly to a bid pool at the pool's price
    /// @param marketId Market ID
    /// @param isYes True to sell YES shares, false for NO
    /// @param priceInBps Price level in basis points
    /// @param sharesWanted Amount of shares to sell
    /// @param minCollateral Minimum collateral to receive (slippage protection)
    /// @param to Recipient of collateral
    /// @param deadline Transaction deadline (0 = no deadline)
    function sellToPool(
        uint256 marketId,
        bool isYes,
        uint256 priceInBps,
        uint256 sharesWanted,
        uint256 minCollateral,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 sharesSold, uint256 collateralReceived) {
        if (to == address(0)) to = msg.sender;
        if (deadline != 0 && block.timestamp > deadline) _revert(ERR_TIMING, 0);
        if (!PAMM.tradingOpen(marketId)) _revert(ERR_STATE, 0);
        if (sharesWanted == 0) _revert(ERR_VALIDATION, 1);
        if (priceInBps == 0 || priceInBps >= BPS_DENOM) _revert(ERR_VALIDATION, 2);

        bytes32 bidPoolId = getBidPoolId(marketId, isYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];

        // Calculate max shares pool can buy
        uint256 maxShares = mulDiv(bidPool.totalCollateral, BPS_DENOM, priceInBps);
        if (sharesWanted > maxShares) _revert(ERR_LIQUIDITY, 0);

        sharesSold = sharesWanted;
        collateralReceived = mulDivUp(sharesWanted, priceInBps, BPS_DENOM);
        if (collateralReceived == 0) _revert(ERR_VALIDATION, 5);
        if (minCollateral != 0 && collateralReceived < minCollateral) _revert(ERR_VALIDATION, 9);

        // Take shares from seller
        uint256 tokenId = _getTokenId(marketId, isYes);
        bool success = PAMM.transferFrom(msg.sender, address(this), tokenId, sharesSold);
        if (!success) _revert(ERR_TRANSFER, 1);

        // Fill bid pool
        _fillBidPool(bidPool, sharesSold, collateralReceived);

        // Clear bitmap if bid pool is now empty
        if (bidPool.totalCollateral == 0) {
            _setPriceBit(marketId, isYes, false, priceInBps, false);
        }

        // Pay seller
        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);
        if (collateral == ETH) {
            _safeTransferETH(to, collateralReceived);
        } else {
            _safeTransfer(collateral, to, collateralReceived);
        }

        emit BidPoolFilled(bidPoolId, msg.sender, sharesSold, collateralReceived);
    }

    /// @notice Internal: Fill bid pool (spend collateral, receive shares)
    function _fillBidPool(BidPool storage p, uint256 sharesIn, uint256 collateralOut) internal {
        if (p.totalScaled == 0) _revert(ERR_STATE, 1);

        p.totalCollateral -= collateralOut;
        p.sharesAcquired += sharesIn;
        p.accSharesPerScaled += mulDiv(sharesIn, ACC, p.totalScaled);
    }

    /// @notice Claim shares from bid pool fills
    function claimBidShares(uint256 marketId, bool isYes, uint256 priceInBps, address to)
        public
        nonReentrant
        returns (uint256 sharesClaimed)
    {
        if (to == address(0)) to = msg.sender;

        bytes32 bidPoolId = getBidPoolId(marketId, isYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];
        BidPosition storage pos = bidPositions[bidPoolId][msg.sender];

        sharesClaimed = _claimBidShares(bidPool, pos);

        if (sharesClaimed > 0) {
            uint256 tokenId = _getTokenId(marketId, isYes);
            bool success = PAMM.transfer(to, tokenId, sharesClaimed);
            if (!success) _revert(ERR_TRANSFER, 0);

            emit BidSharesClaimed(bidPoolId, msg.sender, sharesClaimed);
        }
    }

    /// @notice Internal: Claim shares from bid pool
    function _claimBidShares(BidPool storage p, BidPosition storage u)
        internal
        returns (uint256 claimable)
    {
        uint256 accumulated = mulDiv(u.scaled, p.accSharesPerScaled, ACC);
        if (accumulated <= u.sharesDebt) return 0;

        claimable = accumulated - u.sharesDebt;
        u.sharesDebt = accumulated;
    }

    /// @notice Withdraw unfilled collateral from bid pool
    /// @dev Auto-claims any pending shares before withdrawing to prevent loss
    function withdrawFromBidPool(
        uint256 marketId,
        bool isYes,
        uint256 priceInBps,
        uint256 collateralToWithdraw,
        address to
    ) public nonReentrant returns (uint256 collateralWithdrawn, uint256 sharesClaimed) {
        if (to == address(0)) to = msg.sender;

        bytes32 bidPoolId = getBidPoolId(marketId, isYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];
        BidPosition storage pos = bidPositions[bidPoolId][msg.sender];

        // Auto-claim pending shares first to prevent loss
        sharesClaimed = _claimBidShares(bidPool, pos);

        collateralWithdrawn = _withdrawFromBidPool(bidPool, pos, collateralToWithdraw);

        // Clear bitmap if bid pool is now empty
        if (bidPool.totalCollateral == 0) {
            _setPriceBit(marketId, isYes, false, priceInBps, false);
        }

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        // Transfer claimed shares
        if (sharesClaimed > 0) {
            uint256 tokenId = _getTokenId(marketId, isYes);
            bool success = PAMM.transfer(to, tokenId, sharesClaimed);
            if (!success) _revert(ERR_TRANSFER, 0);
            emit BidSharesClaimed(bidPoolId, msg.sender, sharesClaimed);
        }

        // Transfer withdrawn collateral
        if (collateral == ETH) {
            _safeTransferETH(to, collateralWithdrawn);
        } else {
            _safeTransfer(collateral, to, collateralWithdrawn);
        }

        emit BidCollateralWithdrawn(bidPoolId, msg.sender, collateralWithdrawn);
    }

    /// @notice Exit a depleted BID pool - burn LP units when no collateral remains
    /// @dev Use when pool is fully spent (totalCollateral=0) but you still have scaled position
    /// @param marketId Market ID
    /// @param isYes True for YES bid pool, false for NO bid pool
    /// @param priceInBps Price level in basis points
    /// @param to Recipient of any pending shares
    /// @return sharesClaimed Shares claimed from pending fills
    function exitDepletedBidPool(uint256 marketId, bool isYes, uint256 priceInBps, address to)
        public
        nonReentrant
        returns (uint256 sharesClaimed)
    {
        if (to == address(0)) to = msg.sender;

        bytes32 bidPoolId = getBidPoolId(marketId, isYes, priceInBps);
        BidPool storage p = bidPools[bidPoolId];
        BidPosition storage u = bidPositions[bidPoolId][msg.sender];

        // Only allowed when pool is depleted (no collateral left to withdraw)
        if (p.totalCollateral != 0) _revert(ERR_STATE, 3);
        if (u.scaled == 0) _revert(ERR_VALIDATION, 6);

        // Claim any pending shares first
        sharesClaimed = _claimBidShares(p, u);

        // Burn all user's LP units
        uint256 burnScaled = u.scaled;
        u.scaled = 0;
        u.sharesDebt = 0;
        p.totalScaled -= burnScaled;

        // Clear bitmap if pool is fully exited (no collateral and no LPs)
        if (p.totalScaled == 0) {
            _setPriceBit(marketId, isYes, false, priceInBps, false);
        }

        // Transfer claimed shares
        if (sharesClaimed > 0) {
            uint256 tokenId = _getTokenId(marketId, isYes);
            bool success = PAMM.transfer(to, tokenId, sharesClaimed);
            if (!success) _revert(ERR_TRANSFER, 0);

            emit BidSharesClaimed(bidPoolId, msg.sender, sharesClaimed);
        }
    }

    /// @notice Internal: Withdraw from bid pool
    function _withdrawFromBidPool(
        BidPool storage p,
        BidPosition storage u,
        uint256 collateralWanted
    ) internal returns (uint256 collateralOut) {
        uint256 userMax = p.totalScaled > 0 ? mulDiv(u.scaled, p.totalCollateral, p.totalScaled) : 0;
        if (userMax == 0) _revert(ERR_VALIDATION, 6);

        collateralOut = (collateralWanted == 0) ? userMax : collateralWanted;
        if (collateralOut > userMax) _revert(ERR_VALIDATION, 8);

        uint256 burnScaled = mulDivUp(collateralOut, p.totalScaled, p.totalCollateral);
        if (burnScaled > u.scaled) burnScaled = u.scaled;

        p.totalCollateral -= collateralOut;
        p.totalScaled -= burnScaled;

        // Update user - subtract proportional debt to preserve pending
        uint256 debtToRemove = mulDiv(burnScaled, p.accSharesPerScaled, ACC);
        u.scaled -= burnScaled;
        u.sharesDebt = u.sharesDebt > debtToRemove ? u.sharesDebt - debtToRemove : 0;
    }

    /*//////////////////////////////////////////////////////////////
                    VAULT LIFECYCLE WRAPPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Provide liquidity to vault and/or AMM in one transaction
    /// @dev Splits collateral, deposits to vaults and AMM as specified
    function provideLiquidity(
        uint256 marketId,
        uint256 collateralAmount,
        uint256 vaultYesShares,
        uint256 vaultNoShares,
        uint256 ammLPShares,
        uint256 minAmount0,
        uint256 minAmount1,
        address to,
        uint256 deadline
    )
        public
        payable
        nonReentrant
        returns (uint256 yesVaultSharesMinted, uint256 noVaultSharesMinted, uint256 ammLiquidity)
    {
        if (to == address(0)) to = msg.sender;

        address collateral;
        (,,,,, collateral,) = PAMM.markets(marketId);

        _validateETHAmount(collateral, collateralAmount);
        if (collateral != ETH) {
            _safeTransferFrom(collateral, msg.sender, address(this), collateralAmount);
            _ensureApproval(collateral, address(PM_HOOK_ROUTER));
        }

        (yesVaultSharesMinted, noVaultSharesMinted, ammLiquidity) = PM_HOOK_ROUTER.provideLiquidity{
            value: collateral == ETH ? collateralAmount : 0
        }(
            marketId,
            collateralAmount,
            vaultYesShares,
            vaultNoShares,
            ammLPShares,
            minAmount0,
            minAmount1,
            to,
            deadline
        );

        emit LiquidityProvided(
            marketId, msg.sender, yesVaultSharesMinted, noVaultSharesMinted, ammLiquidity
        );
    }

    /*//////////////////////////////////////////////////////////////
                        MULTICALL & PERMIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute multiple calls in a single transaction
    /// @dev Tracks cumulative ETH usage to prevent msg.value double-spend attacks
    function multicall(bytes[] calldata data) public payable returns (bytes[] memory results) {
        // Increment depth counter to enable cumulative ETH tracking
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

    /// @notice Standard ERC-2612 permit
    function permit(
        address token,
        address owner,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public nonReentrant {
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

            switch returndatasize()
            case 0 {} // No return data is fine
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) }
            }
            default { revert(0, 0) }

            mstore(0x40, add(m, 0x100))
        }
    }

    /// @notice DAI-style permit
    function permitDAI(
        address token,
        address owner,
        uint256 nonce,
        uint256 deadline,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public nonReentrant {
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

            switch returndatasize()
            case 0 {} // No return data is fine
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) }
            }
            default { revert(0, 0) }

            mstore(0x40, add(m, 0x120))
        }
    }

    /*//////////////////////////////////////////////////////////////
                        POOL DISCOVERABILITY (VIEW FUNCTIONS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Get ASK pool depths at multiple price levels for a market/side
    /// @param marketId The market ID
    /// @param isYes True for YES pools, false for NO pools
    /// @param pricesInBps Array of prices to query (in basis points)
    /// @return depths Array of available shares at each price level
    function getPoolDepths(uint256 marketId, bool isYes, uint256[] calldata pricesInBps)
        public
        view
        returns (uint256[] memory depths)
    {
        depths = new uint256[](pricesInBps.length);
        for (uint256 i; i < pricesInBps.length; ++i) {
            bytes32 poolId = getPoolId(marketId, isYes, pricesInBps[i]);
            depths[i] = pools[poolId].totalShares;
        }
    }

    /// @notice Get BID pool depths at multiple price levels for a market/side
    /// @param marketId The market ID
    /// @param buyYes True for YES bid pools, false for NO bid pools
    /// @param pricesInBps Array of prices to query (in basis points)
    /// @return depths Array of available collateral at each price level
    function getBidPoolDepths(uint256 marketId, bool buyYes, uint256[] calldata pricesInBps)
        public
        view
        returns (uint256[] memory depths)
    {
        depths = new uint256[](pricesInBps.length);
        for (uint256 i; i < pricesInBps.length; ++i) {
            bytes32 bidPoolId = getBidPoolId(marketId, buyYes, pricesInBps[i]);
            depths[i] = bidPools[bidPoolId].totalCollateral;
        }
    }

    /// @notice Get full orderbook view for a market side
    /// @dev Returns both ASK (shares for sale) and BID (collateral to buy) depths
    /// @param marketId The market ID
    /// @param isYes True for YES side, false for NO side
    /// @param pricesInBps Array of prices to query
    /// @return askDepths Shares available for sale at each price (ASK pools)
    /// @return bidDepths Collateral available to buy at each price (BID pools)
    function getOrderbook(uint256 marketId, bool isYes, uint256[] calldata pricesInBps)
        public
        view
        returns (uint256[] memory askDepths, uint256[] memory bidDepths)
    {
        askDepths = new uint256[](pricesInBps.length);
        bidDepths = new uint256[](pricesInBps.length);

        for (uint256 i; i < pricesInBps.length; ++i) {
            bytes32 askPoolId = getPoolId(marketId, isYes, pricesInBps[i]);
            bytes32 bidPoolId = getBidPoolId(marketId, isYes, pricesInBps[i]);

            askDepths[i] = pools[askPoolId].totalShares;
            bidDepths[i] = bidPools[bidPoolId].totalCollateral;
        }
    }

    /// @notice Get detailed pool info for a specific ASK pool
    /// @return totalShares Remaining shares available
    /// @return totalScaled Total LP units issued
    /// @return collateralEarned Total collateral collected from fills
    function getPoolInfo(uint256 marketId, bool isYes, uint256 priceInBps)
        public
        view
        returns (uint256 totalShares, uint256 totalScaled, uint256 collateralEarned)
    {
        bytes32 poolId = getPoolId(marketId, isYes, priceInBps);
        Pool storage pool = pools[poolId];
        return (pool.totalShares, pool.totalScaled, pool.collateralEarned);
    }

    /// @notice Get detailed bid pool info for a specific BID pool
    /// @return totalCollateral Remaining collateral available
    /// @return totalScaled Total LP units issued
    /// @return sharesAcquired Total shares bought from fills
    function getBidPoolInfo(uint256 marketId, bool buyYes, uint256 priceInBps)
        public
        view
        returns (uint256 totalCollateral, uint256 totalScaled, uint256 sharesAcquired)
    {
        bytes32 bidPoolId = getBidPoolId(marketId, buyYes, priceInBps);
        BidPool storage bidPool = bidPools[bidPoolId];
        return (bidPool.totalCollateral, bidPool.totalScaled, bidPool.sharesAcquired);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Compute bitmap key for a market/side/type
    function _getBitmapKey(uint256 marketId, bool isYes, bool isAsk)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(marketId, isYes, isAsk));
    }

    /// @dev Set or clear a price bit in the bitmap
    function _setPriceBit(uint256 marketId, bool isYes, bool isAsk, uint256 priceInBps, bool active)
        internal
    {
        bytes32 key = _getBitmapKey(marketId, isYes, isAsk);
        uint256 bucket = priceInBps >> 8;
        uint256 bit = priceInBps & 0xff;

        if (active) {
            priceBitmap[key][bucket] |= (1 << bit);
        } else {
            priceBitmap[key][bucket] &= ~(1 << bit);
        }
    }

    /// @dev Find position of lowest set bit (0-255)
    function _lowestSetBit(uint256 x) internal pure returns (uint256) {
        // Isolate lowest bit and find its position
        return _highestSetBit(x & (~x + 1));
    }

    /// @dev Find position of highest set bit (0-255)
    function _highestSetBit(uint256 x) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            if gt(x, 0xffffffffffffffffffffffffffffffff) {
                x := shr(128, x)
                r := 128
            }
            if gt(x, 0xffffffffffffffff) {
                x := shr(64, x)
                r := or(r, 64)
            }
            if gt(x, 0xffffffff) {
                x := shr(32, x)
                r := or(r, 32)
            }
            if gt(x, 0xffff) {
                x := shr(16, x)
                r := or(r, 16)
            }
            if gt(x, 0xff) {
                x := shr(8, x)
                r := or(r, 8)
            }
            if gt(x, 0xf) {
                x := shr(4, x)
                r := or(r, 4)
            }
            if gt(x, 0x3) {
                x := shr(2, x)
                r := or(r, 2)
            }
            if gt(x, 0x1) { r := or(r, 1) }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Multiply then divide with overflow check
    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
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

    /// @dev Returns `ceil(x * y / d)`. Reverts if `x * y` overflows, or `d` is zero.
    /// @dev From Solady (https://github.com/Vectorized/solady)
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            z := mul(x, y)
            if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                mstore(0x00, 0xad251c27) // `MulDivFailed()`.
                revert(0x1c, 0x04)
            }
            z := add(iszero(iszero(mod(z, d))), div(z, d))
        }
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER HELPERS
    //////////////////////////////////////////////////////////////*/

    function _safeTransfer(address token, address to, uint256 amount) internal {
        assembly ("memory-safe") {
            mstore(0x14, to)
            mstore(0x34, amount)
            mstore(0x00, 0xa9059cbb000000000000000000000000)
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

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x60, amount)
            mstore(0x40, to)
            mstore(0x2c, shl(96, from))
            mstore(0x0c, 0x23b872dd000000000000000000000000)
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

    function _safeTransferETH(address to, uint256 amount) internal {
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, ERR_TRANSFER)
                mstore(0x04, 2)
                revert(0x00, 0x24)
            }
        }
    }

    function _getBalance(address token, address account) internal view returns (uint256 bal) {
        assembly ("memory-safe") {
            mstore(0x14, account)
            mstore(0x00, 0x70a08231000000000000000000000000)
            bal := mul(
                mload(0x20),
                and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20))
            )
        }
    }

    function _ensureApproval(address token, address spender) internal {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x00, 0xdd62ed3e000000000000000000000000)
            mstore(0x14, address())
            mstore(0x34, spender)
            let success := staticcall(gas(), token, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(success, gt(mload(0x00), 0xffffffffffffffffffffffffffffffff))) {
                mstore(0x14, spender)
                mstore(0x34, not(0))
                mstore(0x00, 0x095ea7b3000000000000000000000000)
                success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
                if iszero(and(eq(mload(0x00), 1), success)) {
                    if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                        mstore(0x00, 0x3e3f8f73)
                        revert(0x00, 0x04)
                    }
                }
            }
            mstore(0x40, m)
        }
    }
}
