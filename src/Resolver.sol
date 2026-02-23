// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*//////////////////////////////////////////////////////////////
                          DEV NOTES
//////////////////////////////////////////////////////////////

CONDITION TYPES:
  - Scalar: value = staticcall(target, callData), decoded as uint256
  - Ratio:  value = (A * 1e18) / B, where A and B are uint256 reads
            Threshold must be 1e18-scaled:
              1.5x = 1.5e18, 2x = 2e18, 50% = 0.5e18, 100x = 100e18
            If B == 0, value = type(uint256).max (prevents bricked markets)
  - ETH Balance: pass empty callData ("") and target = account to check
                 Returns account.balance in wei

BOOLEAN SUPPORT:
  - Functions returning bool work natively (ABI encodes bool as 32-byte word)
  - false decodes to 0, true decodes to 1
  - Use Op.EQ with threshold=1 for "is true", threshold=0 for "is false"
  - Example: isActive() == true => Op.EQ, threshold=1

RESOLUTION SEMANTICS:
  - Evaluated when resolveMarket() is called, NOT at close time
  - YES wins: condition is true when resolved
  - NO wins:  condition is false when resolved (callable only after close, unless canClose early-resolved)
  - canClose = true: allows early resolution once condition becomes true
  - canClose = false: must wait until close time regardless of condition

COLLATERAL:
  - ETH:
      - pass address(0) as collateral
      - For *AndSeed:      msg.value = seed.collateralIn
      - For *SeedAndBuy:   msg.value = seed.collateralIn + swap.collateralForSwap
  - ERC20:
      - user must approve resolver (or use permit externally)
      - msg.value must be 0
  - Any collateral amount works (1:1 shares, no dust)

SEED + BUY:
  - *SeedAndBuy functions do NOT set target odds
  - They seed LP then execute buyYes/buyNo to take an initial position
  - Resulting odds depend on pool size, swap amount, and fees

MULTICALL:
  - Supports batching multiple operations in one transaction
  - ETH multicall with multiple seed / buy ops is NOT supported
    (each ETH function enforces strict msg.value expectations)
  - Use separate transactions for multiple ETH markets, or use ERC20

//////////////////////////////////////////////////////////////*/

interface IPAMM {
    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) external returns (uint256 marketId, uint256 noId);

    function splitAndAddLiquidity(
        uint256 marketId,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minLiquidity,
        address to,
        uint256 deadline
    ) external payable returns (uint256 shares, uint256 liquidity);

    function buyYes(
        uint256 marketId,
        uint256 collateralIn,
        uint256 minYesOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 yesOut);

    function buyNo(
        uint256 marketId,
        uint256 collateralIn,
        uint256 minNoOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) external payable returns (uint256 noOut);

    function closeMarket(uint256 marketId) external;
    function resolve(uint256 marketId, bool outcome) external;

    function getMarket(uint256 marketId)
        external
        view
        returns (
            address resolver,
            address collateral,
            bool resolved,
            bool outcome,
            bool canClose,
            uint64 close,
            uint256 collateralLocked,
            uint256 yesSupply,
            uint256 noSupply,
            string memory description
        );

    function getNoId(uint256 marketId) external pure returns (uint256);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
}

/// @title Resolver
/// @notice On-chain oracle for PAMM markets based on arbitrary staticcall reads.
/// @dev Scalar: value = staticcall(target, callData). Ratio: value = A * 1e18 / B.
///      Outcome determined by condition value when resolveMarket() is called.
///      canClose=true allows early resolution when condition becomes true.
contract Resolver {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unknown();
    error Pending();
    error Reentrancy();
    error MulDivFailed();
    error InvalidTarget();
    error ApproveFailed();
    error MarketResolved();
    error TransferFailed();
    error ConditionExists();
    error InvalidDeadline();
    error InvalidETHAmount();
    error TargetCallFailed();
    error ETHTransferFailed();
    error NotResolverMarket();
    error TransferFromFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address public constant PAMM = 0x000000000044bfe6c2BBFeD8862973E0612f07C0;

    receive() external payable {}

    constructor() payable {}

    /*//////////////////////////////////////////////////////////////
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21269;

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(REENTRANCY_SLOT, 0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                               MULTICALL
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                                PERMIT
    //////////////////////////////////////////////////////////////*/

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
            // token.permit(owner, address(this), value, deadline, v, r, s)
            let m := mload(0x40)
            mstore(m, 0xd505accf00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), owner)
            mstore(add(m, 0x24), address())
            mstore(add(m, 0x44), value)
            mstore(add(m, 0x64), deadline)
            mstore(add(m, 0x84), v)
            mstore(add(m, 0xa4), r)
            mstore(add(m, 0xc4), s)
            if iszero(call(gas(), token, 0, m, 0xe4, 0x00, 0x00)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

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
            // token.permit(owner, address(this), nonce, deadline, allowed, v, r, s)
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
            if iszero(call(gas(), token, 0, m, 0x104, 0x00, 0x00)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             TYPES & STORAGE
    //////////////////////////////////////////////////////////////*/

    enum Op {
        LT,
        GT,
        LTE,
        GTE,
        EQ,
        NEQ
    }

    struct Condition {
        address targetA;
        address targetB;
        Op op;
        bool isRatio;
        uint256 threshold;
        bytes callDataA;
        bytes callDataB;
    }

    struct SeedParams {
        uint256 collateralIn;
        uint256 feeOrHook;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 minLiquidity;
        address lpRecipient;
        uint256 deadline;
    }

    struct SwapParams {
        uint256 collateralForSwap;
        uint256 minOut;
        bool yesForNo; // true = buyNo, false = buyYes
        address recipient; // recipient of swapped shares (use address(0) for msg.sender)
    }

    mapping(uint256 marketId => Condition) public conditions;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ConditionCreated(
        uint256 indexed marketId,
        address indexed targetA,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose,
        bool isRatio,
        string description
    );

    event ConditionRegistered(
        uint256 indexed marketId,
        address indexed targetA,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose,
        bool isRatio
    );

    event MarketSeeded(
        uint256 indexed marketId,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 shares,
        uint256 liquidity,
        address lpRecipient
    );

    /*//////////////////////////////////////////////////////////////
                        MARKET CREATION (SCALAR, NO LP)
    //////////////////////////////////////////////////////////////*/

    function createNumericMarketSimple(
        string calldata observable,
        address collateral,
        address target,
        bytes4 selector,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose
    ) public returns (uint256 marketId, uint256 noId) {
        bytes memory cd = abi.encodeWithSelector(selector);
        (marketId, noId) = _createNumericMarket(
            observable, collateral, target, cd, op, threshold, close, canClose
        );
    }

    function createNumericMarket(
        string calldata observable,
        address collateral,
        address target,
        bytes calldata callData,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose
    ) public returns (uint256 marketId, uint256 noId) {
        (marketId, noId) = _createNumericMarket(
            observable, collateral, target, callData, op, threshold, close, canClose
        );
    }

    function _createNumericMarket(
        string calldata observable,
        address collateral,
        address target,
        bytes memory callData,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose
    ) internal returns (uint256 marketId, uint256 noId) {
        if (target == address(0)) revert InvalidTarget();
        if (callData.length != 0 && target.code.length == 0) revert InvalidTarget();
        if (close <= block.timestamp) revert InvalidDeadline();

        string memory description = _buildDescription(observable, op, threshold, close, canClose);
        (marketId, noId) =
            IPAMM(PAMM).createMarket(description, address(this), collateral, close, canClose);
        conditions[marketId] = Condition(target, address(0), op, false, threshold, callData, "");
        emit ConditionCreated(marketId, target, op, threshold, close, canClose, false, description);
    }

    /*//////////////////////////////////////////////////////////////
                  MARKET CREATION + LP SEED (SCALAR)
    //////////////////////////////////////////////////////////////*/

    function createNumericMarketAndSeedSimple(
        string calldata observable,
        address collateral,
        address target,
        bytes4 selector,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose,
        SeedParams calldata seed
    )
        public
        payable
        nonReentrant
        returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity)
    {
        (marketId, noId) = _createNumericMarket(
            observable,
            collateral,
            target,
            abi.encodeWithSelector(selector),
            op,
            threshold,
            close,
            canClose
        );
        (shares, liquidity) = _seedLiquidity(collateral, marketId, seed, 0);
        _flushLeftoverShares(marketId);
        _refundDust(collateral);
        emit MarketSeeded(
            marketId, seed.collateralIn, seed.feeOrHook, shares, liquidity, seed.lpRecipient
        );
    }

    function createNumericMarketAndSeed(
        string calldata observable,
        address collateral,
        address target,
        bytes calldata callData,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose,
        SeedParams calldata seed
    )
        public
        payable
        nonReentrant
        returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity)
    {
        (marketId, noId) = _createNumericMarket(
            observable, collateral, target, callData, op, threshold, close, canClose
        );
        (shares, liquidity) = _seedLiquidity(collateral, marketId, seed, 0);
        _flushLeftoverShares(marketId);
        _refundDust(collateral);
        emit MarketSeeded(
            marketId, seed.collateralIn, seed.feeOrHook, shares, liquidity, seed.lpRecipient
        );
    }

    /*//////////////////////////////////////////////////////////////
                        MARKET CREATION (RATIO, NO LP)
    //////////////////////////////////////////////////////////////*/

    function createRatioMarketSimple(
        string calldata observable,
        address collateral,
        address targetA,
        bytes4 selectorA,
        address targetB,
        bytes4 selectorB,
        Op op,
        uint256 threshold, // 1e18-scaled
        uint64 close,
        bool canClose
    ) public returns (uint256 marketId, uint256 noId) {
        bytes memory cdA = abi.encodeWithSelector(selectorA);
        bytes memory cdB = abi.encodeWithSelector(selectorB);
        (marketId, noId) = _createRatioMarket(
            observable, collateral, targetA, cdA, targetB, cdB, op, threshold, close, canClose
        );
    }

    function createRatioMarket(
        string calldata observable,
        address collateral,
        address targetA,
        bytes calldata callDataA,
        address targetB,
        bytes calldata callDataB,
        Op op,
        uint256 threshold, // 1e18-scaled
        uint64 close,
        bool canClose
    ) public returns (uint256 marketId, uint256 noId) {
        (marketId, noId) = _createRatioMarket(
            observable,
            collateral,
            targetA,
            callDataA,
            targetB,
            callDataB,
            op,
            threshold,
            close,
            canClose
        );
    }

    function _createRatioMarket(
        string calldata observable,
        address collateral,
        address targetA,
        bytes memory callDataA,
        address targetB,
        bytes memory callDataB,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose
    ) internal returns (uint256 marketId, uint256 noId) {
        if (targetA == address(0) || targetB == address(0)) revert InvalidTarget();
        if (callDataA.length != 0 && targetA.code.length == 0) revert InvalidTarget();
        if (callDataB.length != 0 && targetB.code.length == 0) revert InvalidTarget();
        if (close <= block.timestamp) revert InvalidDeadline();

        string memory description = _buildDescription(observable, op, threshold, close, canClose);
        (marketId, noId) =
            IPAMM(PAMM).createMarket(description, address(this), collateral, close, canClose);
        conditions[marketId] =
            Condition(targetA, targetB, op, true, threshold, callDataA, callDataB);
        emit ConditionCreated(marketId, targetA, op, threshold, close, canClose, true, description);
    }

    /*//////////////////////////////////////////////////////////////
               MARKET CREATION + LP SEED (RATIO CONDITIONS)
    //////////////////////////////////////////////////////////////*/

    function createRatioMarketAndSeedSimple(
        string calldata observable,
        address collateral,
        address targetA,
        bytes4 selectorA,
        address targetB,
        bytes4 selectorB,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose,
        SeedParams calldata seed
    )
        public
        payable
        nonReentrant
        returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity)
    {
        (marketId, noId) = _createRatioMarket(
            observable,
            collateral,
            targetA,
            abi.encodeWithSelector(selectorA),
            targetB,
            abi.encodeWithSelector(selectorB),
            op,
            threshold,
            close,
            canClose
        );
        (shares, liquidity) = _seedLiquidity(collateral, marketId, seed, 0);
        _flushLeftoverShares(marketId);
        _refundDust(collateral);
        emit MarketSeeded(
            marketId, seed.collateralIn, seed.feeOrHook, shares, liquidity, seed.lpRecipient
        );
    }

    function createRatioMarketAndSeed(
        string calldata observable,
        address collateral,
        address targetA,
        bytes calldata callDataA,
        address targetB,
        bytes calldata callDataB,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose,
        SeedParams calldata seed
    )
        public
        payable
        nonReentrant
        returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity)
    {
        (marketId, noId) = _createRatioMarket(
            observable,
            collateral,
            targetA,
            callDataA,
            targetB,
            callDataB,
            op,
            threshold,
            close,
            canClose
        );
        (shares, liquidity) = _seedLiquidity(collateral, marketId, seed, 0);
        _flushLeftoverShares(marketId);
        _refundDust(collateral);
        emit MarketSeeded(
            marketId, seed.collateralIn, seed.feeOrHook, shares, liquidity, seed.lpRecipient
        );
    }

    /*//////////////////////////////////////////////////////////////
               CREATE + SEED + INITIAL BUY (SKEWS ODDS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates market, seeds LP, and executes buyYes/buyNo to take initial position.
    /// @dev Does NOT set a specific target probability. The resulting odds depend on
    ///      pool size, swap amount, and fees. Use for convenience when you want to
    ///      seed liquidity and immediately take a position in one transaction.
    function createNumericMarketSeedAndBuy(
        string calldata observable,
        address collateral,
        address target,
        bytes calldata callData,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose,
        SeedParams calldata seed,
        SwapParams calldata swap
    )
        public
        payable
        nonReentrant
        returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity, uint256 swapOut)
    {
        (marketId, noId) = _createNumericMarket(
            observable, collateral, target, callData, op, threshold, close, canClose
        );
        (shares, liquidity) = _seedLiquidity(collateral, marketId, seed, swap.collateralForSwap);
        swapOut = _buyToSkewOdds(collateral, marketId, seed.feeOrHook, seed.deadline, swap);
        _flushLeftoverShares(marketId);
        _refundDust(collateral);
        emit MarketSeeded(
            marketId, seed.collateralIn, seed.feeOrHook, shares, liquidity, seed.lpRecipient
        );
    }

    /// @notice Creates ratio market, seeds LP, and executes buyYes/buyNo to take initial position.
    /// @dev Does NOT set a specific target probability. The resulting odds depend on
    ///      pool size, swap amount, and fees. Use for convenience when you want to
    ///      seed liquidity and immediately take a position in one transaction.
    function createRatioMarketSeedAndBuy(
        string calldata observable,
        address collateral,
        address targetA,
        bytes calldata callDataA,
        address targetB,
        bytes calldata callDataB,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose,
        SeedParams calldata seed,
        SwapParams calldata swap
    )
        public
        payable
        nonReentrant
        returns (uint256 marketId, uint256 noId, uint256 shares, uint256 liquidity, uint256 swapOut)
    {
        (marketId, noId) = _createRatioMarket(
            observable,
            collateral,
            targetA,
            callDataA,
            targetB,
            callDataB,
            op,
            threshold,
            close,
            canClose
        );
        (shares, liquidity) = _seedLiquidity(collateral, marketId, seed, swap.collateralForSwap);
        swapOut = _buyToSkewOdds(collateral, marketId, seed.feeOrHook, seed.deadline, swap);
        _flushLeftoverShares(marketId);
        _refundDust(collateral);
        emit MarketSeeded(
            marketId, seed.collateralIn, seed.feeOrHook, shares, liquidity, seed.lpRecipient
        );
    }

    /*//////////////////////////////////////////////////////////////
                     REGISTER FOR EXISTING PAMM MARKET
    //////////////////////////////////////////////////////////////*/

    function registerConditionForExistingMarket(
        uint256 marketId,
        address target,
        bytes calldata callData,
        Op op,
        uint256 threshold
    ) public {
        _registerScalarCondition(marketId, target, callData, op, threshold);
    }

    function registerConditionForExistingMarketSimple(
        uint256 marketId,
        address target,
        bytes4 selector,
        Op op,
        uint256 threshold
    ) public {
        bytes memory cd = abi.encodeWithSelector(selector);
        _registerScalarCondition(marketId, target, cd, op, threshold);
    }

    function _registerScalarCondition(
        uint256 marketId,
        address target,
        bytes memory callData,
        Op op,
        uint256 threshold
    ) internal {
        if (target == address(0)) revert InvalidTarget();
        if (callData.length != 0 && target.code.length == 0) revert InvalidTarget();
        if (conditions[marketId].targetA != address(0)) revert ConditionExists();

        (address resolver,, bool resolved,, bool canClose, uint64 close,,,,) =
            IPAMM(PAMM).getMarket(marketId);
        if (resolver != address(this)) revert NotResolverMarket();
        if (resolved) revert MarketResolved();

        conditions[marketId] = Condition(target, address(0), op, false, threshold, callData, "");
        emit ConditionRegistered(marketId, target, op, threshold, close, canClose, false);
    }

    function registerRatioConditionForExistingMarket(
        uint256 marketId,
        address targetA,
        bytes calldata callDataA,
        address targetB,
        bytes calldata callDataB,
        Op op,
        uint256 threshold
    ) public {
        _registerRatioCondition(marketId, targetA, callDataA, targetB, callDataB, op, threshold);
    }

    function registerRatioConditionForExistingMarketSimple(
        uint256 marketId,
        address targetA,
        bytes4 selectorA,
        address targetB,
        bytes4 selectorB,
        Op op,
        uint256 threshold
    ) public {
        bytes memory cdA = abi.encodeWithSelector(selectorA);
        bytes memory cdB = abi.encodeWithSelector(selectorB);
        _registerRatioCondition(marketId, targetA, cdA, targetB, cdB, op, threshold);
    }

    function _registerRatioCondition(
        uint256 marketId,
        address targetA,
        bytes memory callDataA,
        address targetB,
        bytes memory callDataB,
        Op op,
        uint256 threshold
    ) internal {
        if (targetA == address(0) || targetB == address(0)) {
            revert InvalidTarget();
        }
        if (callDataA.length != 0 && targetA.code.length == 0) revert InvalidTarget();
        if (callDataB.length != 0 && targetB.code.length == 0) revert InvalidTarget();
        if (conditions[marketId].targetA != address(0)) revert ConditionExists();

        (address resolver,, bool resolved,, bool canClose, uint64 close,,,,) =
            IPAMM(PAMM).getMarket(marketId);
        if (resolver != address(this)) revert NotResolverMarket();
        if (resolved) revert MarketResolved();

        conditions[marketId] =
            Condition(targetA, targetB, op, true, threshold, callDataA, callDataB);
        emit ConditionRegistered(marketId, targetA, op, threshold, close, canClose, true);
    }

    /*//////////////////////////////////////////////////////////////
                               RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function resolveMarket(uint256 marketId) public nonReentrant {
        Condition storage c = conditions[marketId];
        if (c.targetA == address(0)) revert Unknown();

        (address resolver,, bool resolved,, bool canClose, uint64 close,,,,) =
            IPAMM(PAMM).getMarket(marketId);
        if (resolver != address(this)) revert NotResolverMarket();
        if (resolved) revert MarketResolved();

        uint256 value = _currentValue(c);
        bool condTrue = _compare(value, c.op, c.threshold);

        if (condTrue) {
            if (block.timestamp < close) {
                if (!canClose) revert Pending();
                IPAMM(PAMM).closeMarket(marketId);
            }
            IPAMM(PAMM).resolve(marketId, true);
        } else {
            if (block.timestamp < close) revert Pending();
            IPAMM(PAMM).resolve(marketId, false);
        }

        delete conditions[marketId];
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function preview(uint256 marketId)
        public
        view
        returns (uint256 value, bool condTrue, bool ready)
    {
        Condition storage c = conditions[marketId];
        if (c.targetA == address(0)) return (0, false, false);

        (,,,, bool canClose, uint64 close,,,,) = IPAMM(PAMM).getMarket(marketId);
        value = _currentValue(c);
        condTrue = _compare(value, c.op, c.threshold);
        ready = (block.timestamp >= close) || (condTrue && canClose);
    }

    function buildDescription(
        string calldata observable,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose
    ) public pure returns (string memory) {
        return _buildDescription(observable, op, threshold, close, canClose);
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _currentValue(Condition storage c) internal view returns (uint256 value) {
        if (!c.isRatio) {
            value = _readUint(c.targetA, c.callDataA);
        } else {
            uint256 a = _readUint(c.targetA, c.callDataA);
            uint256 b = _readUint(c.targetB, c.callDataB);
            if (b == 0) return type(uint256).max; // Undefined ratio = max (prevents bricked markets)
            value = mulDiv(a, 1e18, b);
        }
    }

    function _readUint(address target, bytes memory callData) internal view returns (uint256 v) {
        // Empty callData = ETH balance check (target is the address to query)
        if (callData.length == 0) {
            return target.balance;
        }
        (bool ok, bytes memory data) = target.staticcall(callData);
        if (!ok || data.length < 32) revert TargetCallFailed();
        v = abi.decode(data, (uint256));
    }

    function _compare(uint256 value, Op op, uint256 threshold) internal pure returns (bool) {
        if (op == Op.LT) return value < threshold;
        if (op == Op.GT) return value > threshold;
        if (op == Op.LTE) return value <= threshold;
        if (op == Op.GTE) return value >= threshold;
        if (op == Op.EQ) return value == threshold;
        return value != threshold; // NEQ is only remaining case
    }

    function _opSymbol(Op op) internal pure returns (string memory) {
        if (op == Op.LT) return "<";
        if (op == Op.GT) return ">";
        if (op == Op.LTE) return "<=";
        if (op == Op.GTE) return ">=";
        if (op == Op.EQ) return "==";
        return "!="; // NEQ is only remaining case
    }

    function _buildDescription(
        string calldata observable,
        Op op,
        uint256 threshold,
        uint64 close,
        bool canClose
    ) internal pure returns (string memory) {
        string memory opSym = _opSymbol(op);
        string memory tStr = _toString(threshold);
        string memory closeStr = _toString(uint256(close));

        if (canClose) {
            return string(
                abi.encodePacked(
                    observable,
                    " ",
                    opSym,
                    " ",
                    tStr,
                    " by ",
                    closeStr,
                    " Unix time. ",
                    "Note: market may close early once condition is met."
                )
            );
        } else {
            return string(
                abi.encodePacked(observable, " ", opSym, " ", tStr, " by ", closeStr, " Unix time.")
            );
        }
    }

    function _seedLiquidity(
        address collateral,
        uint256 marketId,
        SeedParams calldata p,
        uint256 extraETH
    ) internal returns (uint256 shares, uint256 liquidity) {
        if (collateral == address(0)) {
            if (msg.value != p.collateralIn + extraETH) revert InvalidETHAmount();
            (shares, liquidity) = IPAMM(PAMM).splitAndAddLiquidity{value: p.collateralIn}(
                marketId,
                p.collateralIn,
                p.feeOrHook,
                p.amount0Min,
                p.amount1Min,
                p.minLiquidity,
                p.lpRecipient,
                p.deadline
            );
        } else {
            if (msg.value != 0) revert InvalidETHAmount();
            safeTransferFrom(collateral, msg.sender, address(this), p.collateralIn);
            ensureApproval(collateral, PAMM);
            (shares, liquidity) = IPAMM(PAMM)
                .splitAndAddLiquidity(
                    marketId,
                    p.collateralIn,
                    p.feeOrHook,
                    p.amount0Min,
                    p.amount1Min,
                    p.minLiquidity,
                    p.lpRecipient,
                    p.deadline
                );
        }
    }

    function _flushLeftoverShares(uint256 marketId) internal {
        uint256 yesLeft = IPAMM(PAMM).balanceOf(address(this), marketId);
        if (yesLeft != 0) {
            IPAMM(PAMM).transfer(msg.sender, marketId, yesLeft);
        }

        uint256 noIdLocal = IPAMM(PAMM).getNoId(marketId);
        uint256 noLeft = IPAMM(PAMM).balanceOf(address(this), noIdLocal);
        if (noLeft != 0) {
            IPAMM(PAMM).transfer(msg.sender, noIdLocal, noLeft);
        }
    }

    /// @dev Refunds any dust collateral (ETH or ERC20) to msg.sender.
    function _refundDust(address collateral) internal {
        if (collateral == address(0)) {
            uint256 dust = address(this).balance;
            if (dust != 0) {
                safeTransferETH(msg.sender, dust);
            }
        } else {
            uint256 dust = getBalance(collateral, address(this));
            if (dust != 0) {
                safeTransfer(collateral, msg.sender, dust);
            }
        }
    }

    /// @dev Executes buyYes or buyNo to skew pool odds. Does NOT set a target probability.
    function _buyToSkewOdds(
        address collateral,
        uint256 marketId,
        uint256 feeOrHook,
        uint256 deadline,
        SwapParams calldata s
    ) internal returns (uint256 amountOut) {
        if (s.collateralForSwap == 0) return 0;

        if (collateral != address(0)) {
            safeTransferFrom(collateral, msg.sender, address(this), s.collateralForSwap);
            ensureApproval(collateral, PAMM);
        }

        // Use specified recipient or fallback to msg.sender
        address to = s.recipient == address(0) ? msg.sender : s.recipient;

        if (s.yesForNo) {
            amountOut = collateral != address(0)
                ? IPAMM(PAMM)
                    .buyNo(marketId, s.collateralForSwap, s.minOut, 0, feeOrHook, to, deadline)
                : IPAMM(PAMM).buyNo{value: s.collateralForSwap}(
                    marketId, 0, s.minOut, 0, feeOrHook, to, deadline
                );
        } else {
            amountOut = collateral != address(0)
                ? IPAMM(PAMM)
                    .buyYes(marketId, s.collateralForSwap, s.minOut, 0, feeOrHook, to, deadline)
                : IPAMM(PAMM).buyYes{value: s.collateralForSwap}(
                    marketId, 0, s.minOut, 0, feeOrHook, to, deadline
                );
        }
    }

    function _toString(uint256 value) internal pure returns (string memory result) {
        assembly ("memory-safe") {
            result := add(mload(0x40), 0x80)
            mstore(0x40, add(result, 0x20))
            mstore(result, 0)
            let end := result
            let w := not(0)
            for { let temp := value } 1 {} {
                result := add(result, w)
                mstore8(result, add(48, mod(temp, 10)))
                temp := div(temp, 10)
                if iszero(temp) { break }
            }
            let n := sub(end, result)
            result := sub(result, 0x20)
            mstore(result, n)
        }
    }
}

/// @dev Returns `floor(x * y / d)`. Reverts if `x * y` overflows, or `d` is zero.
function mulDiv(uint256 x, uint256 y, uint256 d) pure returns (uint256 z) {
    assembly ("memory-safe") {
        z := mul(x, y)
        if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
            mstore(0x00, 0xad251c27) // MulDivFailed()
            revert(0x1c, 0x04)
        }
        z := div(z, d)
    }
}

/// @dev Transfers tokens using transferFrom, reverts on failure.
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
                mstore(0x00, 0x7939f424) // TransferFromFailed()
                revert(0x1c, 0x04)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}

/// @dev Sets max approval once if allowance <= uint128.max. Does NOT support tokens requiring approve(0) first.
function ensureApproval(address token, address spender) {
    assembly ("memory-safe") {
        mstore(0x00, 0xdd62ed3e000000000000000000000000) // allowance(address,address)
        mstore(0x14, address())
        mstore(0x34, spender)
        let success := staticcall(gas(), token, 0x10, 0x44, 0x00, 0x20)
        // If allowance <= uint128.max, set max approval
        if iszero(and(success, gt(mload(0x00), 0xffffffffffffffffffffffffffffffff))) {
            mstore(0x14, spender)
            mstore(0x34, not(0))
            mstore(0x00, 0x095ea7b3000000000000000000000000)
            success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, 0x3e3f8f73)
                    revert(0x1c, 0x04)
                }
            }
        }
        mstore(0x34, 0)
    }
}

/// @dev Sends ETH to `to`, reverts on failure.
function safeTransferETH(address to, uint256 amount) {
    assembly ("memory-safe") {
        if iszero(call(gas(), to, amount, 0, 0, 0, 0)) {
            mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
            revert(0x1c, 0x04)
        }
    }
}

/// @dev Transfers tokens using transfer (not transferFrom), reverts on failure.
function safeTransfer(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0xa9059cbb000000000000000000000000) // transfer(address,uint256)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x90b8ec18) // TransferFailed()
                revert(0x1c, 0x04)
            }
        }
        mstore(0x34, 0)
    }
}

/// @dev Returns the ERC20 balance of an account.
function getBalance(address token, address account) view returns (uint256 bal) {
    assembly ("memory-safe") {
        mstore(0x14, account)
        mstore(0x00, 0x70a08231000000000000000000000000) // balanceOf(address)
        bal := mul(
            mload(0x20),
            and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20))
        )
    }
}
