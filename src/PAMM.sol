// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Minimal ERC6909-style multi-token base for YES/NO shares.
abstract contract ERC6909Minimal {
    event OperatorSet(address indexed owner, address indexed operator, bool approved);
    event Approval(
        address indexed owner, address indexed spender, uint256 indexed id, uint256 amount
    );
    event Transfer(
        address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount
    );

    mapping(address => mapping(address => bool)) public isOperator;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

    function transfer(address receiver, uint256 id, uint256 amount) public returns (bool) {
        balanceOf[msg.sender][id] -= amount;
        unchecked {
            balanceOf[receiver][id] += amount; // Safe: totalSupply is tracked
        }
        emit Transfer(msg.sender, msg.sender, receiver, id, amount);
        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    function setOperator(address operator, bool approved) public returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x0f632fb3;
    }

    function _mint(address receiver, uint256 id, uint256 amount) internal {
        unchecked {
            balanceOf[receiver][id] += amount; // Safe: totalSupply is tracked
        }
        emit Transfer(msg.sender, address(0), receiver, id, amount);
    }

    function _burn(address sender, uint256 id, uint256 amount) internal {
        balanceOf[sender][id] -= amount;
        emit Transfer(msg.sender, sender, address(0), id, amount);
    }
}

/// @notice ZAMM interface for LP operations.
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

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);

    function deposit(address token, uint256 id, uint256 amount) external payable;

    function recoverTransientBalance(address token, uint256 id, address to)
        external
        returns (uint256 amount);

    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function swapExactOut(
        PoolKey calldata poolKey,
        uint256 amountOut,
        uint256 amountInMax,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external returns (uint256 amountIn);

    function removeLiquidity(
        PoolKey calldata poolKey,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    function transferFrom(address from, address to, uint256 id, uint256 amount)
        external
        returns (bool);
}

/// @title PAMM V1
/// @notice Prediction-market collateral vault with per-market collateral:
///         - Supports ETH (address(0)) and any ERC20 with varying decimals
///         - Fully-collateralised YES/NO shares (ERC6909)
///         - Shares are 1:1 with collateral wei (1 share = 1 wei of collateral)
/// @dev Trading/LP happens on a separate AMM (e.g. ZAMM).
contract PAMM is ERC6909Minimal {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Reentrancy();
    error AmountZero();
    error FeeOverflow();
    error NotClosable();
    error InvalidClose();
    error MarketClosed();
    error MarketExists();
    error OnlyResolver();
    error TransferFailed();
    error ExcessiveInput();
    error MarketNotFound();
    error DeadlineExpired();
    error InvalidReceiver();
    error InvalidResolver();
    error AlreadyResolved();
    error MarketNotClosed();
    error InvalidETHAmount();
    error ETHTransferFailed();
    error InvalidSwapAmount();
    error InsufficientOutput();
    error TransferFromFailed();
    error WrongCollateralType();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Created(
        uint256 indexed marketId,
        uint256 indexed noId,
        string description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    );
    event Closed(uint256 indexed marketId, uint256 ts, address indexed by);
    event Split(
        address indexed user, uint256 indexed marketId, uint256 shares, uint256 collateralIn
    );
    event Merged(
        address indexed user, uint256 indexed marketId, uint256 shares, uint256 collateralOut
    );
    event Resolved(uint256 indexed marketId, bool outcome);
    event Claimed(address indexed user, uint256 indexed marketId, uint256 shares, uint256 payout);
    event ResolverFeeSet(address indexed resolver, uint16 bps);

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Market {
        address resolver; // who can resolve (20 bytes)
        bool resolved; // outcome set? (1 byte)
        bool outcome; // YES wins if true (1 byte)
        bool canClose; // resolver can early-close (1 byte)
        uint64 close; // resolve allowed after (8 bytes) -- slot 1: 31 bytes
        address collateral; // collateral token (address(0) = ETH) -- slot 2
        uint256 collateralLocked; // collateral locked for market -- slot 3
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice ETH sentinel value.
    address constant ETH = address(0);

    /// @notice ZAMM singleton for liquidity pools.
    IZAMM public constant ZAMM = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice All market ids.
    uint256[] public allMarkets;

    /// @notice Market by YES-id.
    mapping(uint256 => Market) public markets;

    /// @notice Description per market.
    mapping(uint256 => string) public descriptions;

    /// @notice Supply per token id (YES or NO).
    mapping(uint256 => uint256) public totalSupplyId;

    /// @notice Resolver fee in basis points (max 1000 = 10%).
    mapping(address => uint16) public resolverFeeBps;

    /*//////////////////////////////////////////////////////////////
                               METADATA
    //////////////////////////////////////////////////////////////*/

    /// @notice Token name for ERC6909 metadata.
    function name(uint256 id) public pure returns (string memory) {
        return string(abi.encodePacked("PAMM-", _toString(id)));
    }

    /// @notice Token symbol for ERC6909 metadata.
    function symbol(uint256) public pure returns (string memory) {
        return "PAMM";
    }

    /// @notice NFT-compatible metadata URI for a token id.
    /// @dev Returns data URI with JSON. Works for YES (marketId) tokens; NO tokens return minimal info.
    function tokenURI(uint256 id) public view returns (string memory) {
        Market storage m = markets[id];

        // YES token - has full market info
        if (m.resolver != address(0)) {
            string memory status = m.resolved ? (m.outcome ? "YES wins" : "NO wins") : "Pending";
            return string(
                abi.encodePacked(
                    "data:application/json;utf8,{\"name\":\"YES: ",
                    descriptions[id],
                    "\",\"description\":\"Prediction market YES share\",\"attributes\":[{\"trait_type\":\"Status\",\"value\":\"",
                    status,
                    "\"},{\"trait_type\":\"Close\",\"value\":",
                    _toString(m.close),
                    "}]}"
                )
            );
        }

        // NO token or unknown - check if supply exists
        if (totalSupplyId[id] == 0) revert MarketNotFound();

        return "data:application/json;utf8,{\"name\":\"PAMM NO Share\",\"description\":\"Prediction market NO share\"}";
    }

    /// @dev Converts uint256 to string (from Solady).
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

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() payable {}

    /// @dev Override to skip allowance check for ZAMM pulling from this contract.
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        returns (bool)
    {
        // ZAMM pulls from address(this) - skip SLOAD for isOperator/allowance
        if (msg.sender != sender && !(msg.sender == address(ZAMM) && sender == address(this))) {
            if (!isOperator[sender][msg.sender]) {
                uint256 allowed = allowance[sender][msg.sender][id];
                if (allowed != type(uint256).max) {
                    allowance[sender][msg.sender][id] = allowed - amount;
                }
            }
        }
        balanceOf[sender][id] -= amount;
        unchecked {
            balanceOf[receiver][id] += amount; // Safe: totalSupply is tracked
        }
        emit Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                               MULTICALL
    //////////////////////////////////////////////////////////////*/

    /// @notice Batch multiple calls in a single transaction.
    function multicall(bytes[] calldata data) public returns (bytes[] memory results) {
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

    /// @notice EIP-2612 permit for ERC20 tokens (use in multicall before split).
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

    /// @notice DAI-style permit (use in multicall before split).
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
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    uint256 constant REENTRANCY_SLOT = 0x929eee149b4bd21268;

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
                             ID DERIVATION
    //////////////////////////////////////////////////////////////*/

    /// @notice YES-id from (description, resolver, collateral).
    function getMarketId(string calldata description, address resolver, address collateral)
        public
        pure
        returns (uint256)
    {
        return uint256(
            keccak256(abi.encodePacked("PMARKET:YES", description, resolver, collateral))
        );
    }

    /// @notice NO-id from YES-id.
    function getNoId(uint256 marketId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("PMARKET:NO", marketId)));
    }

    /*//////////////////////////////////////////////////////////////
                            MARKET LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new YES/NO market.
    /// @dev Description is stored as-is and used in tokenURI JSON. Avoid special characters
    ///      (quotes, backslashes, newlines) as they are not escaped and may break metadata rendering.
    /// @param description Used in id derivation and tokenURI metadata
    /// @param resolver Can call resolve()
    /// @param collateral Collateral token (address(0) for ETH)
    /// @param close Resolve allowed after this timestamp
    /// @param canClose If true, resolver can early-close
    function createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) public nonReentrant returns (uint256 marketId, uint256 noId) {
        (marketId, noId) = _createMarket(description, resolver, collateral, close, canClose);
    }

    /// @notice Create a market and seed it with initial liquidity in one tx.
    /// @dev For ETH markets, send ETH with the call (collateralIn can be 0 or must equal msg.value).
    ///      Description is stored as-is; avoid special characters (quotes, backslashes, newlines).
    /// @param description Used in id derivation and tokenURI metadata
    /// @param resolver Can call resolve()
    /// @param collateral Collateral token (address(0) for ETH)
    /// @param close Resolve allowed after this timestamp
    /// @param canClose If true, resolver can early-close
    /// @param collateralIn Amount of collateral to split into shares
    /// @param feeOrHook Pool fee tier (bps) or hook address
    /// @param minLiquidity Minimum LP tokens to receive
    /// @param to Recipient of LP tokens
    /// @param deadline Timestamp after which the tx reverts
    function createMarketAndSeed(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 minLiquidity,
        address to,
        uint256 deadline
    ) public payable nonReentrant returns (uint256 marketId, uint256 noId, uint256 liquidity) {
        (marketId, noId) = _createMarket(description, resolver, collateral, close, canClose);
        (, liquidity) = _splitAndAddLiquidity(
            marketId, collateralIn, feeOrHook, 0, 0, minLiquidity, to, deadline
        );
    }

    /// @dev Internal create logic (no reentrancy guard).
    function _createMarket(
        string calldata description,
        address resolver,
        address collateral,
        uint64 close,
        bool canClose
    ) internal returns (uint256 marketId, uint256 noId) {
        if (resolver == address(0)) revert InvalidResolver();
        if (close <= block.timestamp) revert InvalidClose();

        marketId = getMarketId(description, resolver, collateral);
        if (markets[marketId].resolver != address(0)) revert MarketExists();

        noId = getNoId(marketId);

        markets[marketId] = Market({
            resolver: resolver,
            collateral: collateral,
            resolved: false,
            outcome: false,
            canClose: canClose,
            close: close,
            collateralLocked: 0
        });

        descriptions[marketId] = description;
        allMarkets.push(marketId);

        emit Created(marketId, noId, description, resolver, collateral, close, canClose);
    }

    /// @notice Early-close a market (only resolver, only if canClose).
    function closeMarket(uint256 marketId) public nonReentrant {
        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (msg.sender != m.resolver) revert OnlyResolver();
        if (!m.canClose) revert NotClosable();
        if (m.resolved) revert AlreadyResolved();
        if (block.timestamp >= m.close) revert MarketClosed();

        m.close = uint64(block.timestamp);
        emit Closed(marketId, block.timestamp, msg.sender);
    }

    /// @notice Set winning outcome (only resolver, after close).
    function resolve(uint256 marketId, bool outcome) public nonReentrant {
        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (msg.sender != m.resolver) revert OnlyResolver();
        if (m.resolved) revert AlreadyResolved();
        if (block.timestamp < m.close) revert MarketNotClosed();

        m.resolved = true;
        m.outcome = outcome;

        emit Resolved(marketId, outcome);
    }

    /// @notice Set resolver fee (caller sets their own fee).
    /// @param bps Fee in basis points (max 1000 = 10%).
    function setResolverFeeBps(uint16 bps) public {
        if (bps > 1000) revert FeeOverflow();
        resolverFeeBps[msg.sender] = bps;
        emit ResolverFeeSet(msg.sender, bps);
    }

    /*//////////////////////////////////////////////////////////////
                         SPLIT / MERGE / CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock collateral -> mint YES+NO pair (1:1).
    /// @dev For ETH markets, send ETH with the call.
    function split(uint256 marketId, uint256 collateralIn, address to)
        public
        payable
        nonReentrant
        returns (uint256 shares, uint256 used)
    {
        if (to == address(0)) revert InvalidReceiver();

        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (m.resolved || block.timestamp >= m.close) revert MarketClosed();

        address collateral = m.collateral;

        if (collateral == ETH) {
            if (collateralIn != 0 && collateralIn != msg.value) revert InvalidETHAmount();
            shares = msg.value;
        } else {
            if (msg.value != 0) revert WrongCollateralType();
            if (collateralIn == 0) revert AmountZero();
            shares = collateralIn;
            safeTransferFrom(collateral, msg.sender, address(this), shares);
        }

        if (shares == 0) revert AmountZero();
        used = shares;

        m.collateralLocked += used;

        uint256 noId = getNoId(marketId);
        _mint(to, marketId, shares);
        _mint(to, noId, shares);
        totalSupplyId[marketId] += shares;
        totalSupplyId[noId] += shares;

        emit Split(to, marketId, shares, used);
    }

    /// @notice Burn YES+NO pair -> unlock collateral.
    /// @dev Allowed until market is resolved (not just until close). Merges min(shares, yesBalance, noBalance).
    function merge(uint256 marketId, uint256 shares, address to)
        public
        nonReentrant
        returns (uint256 merged, uint256 collateralOut)
    {
        if (shares == 0) revert AmountZero();
        if (to == address(0)) revert InvalidReceiver();

        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (m.resolved) revert MarketClosed();

        uint256 noId = getNoId(marketId);
        uint256 yesBal = balanceOf[msg.sender][marketId];
        uint256 noBal = balanceOf[msg.sender][noId];

        merged = shares;
        if (yesBal < merged) merged = yesBal;
        if (noBal < merged) merged = noBal;
        if (merged == 0) revert AmountZero();

        _burn(msg.sender, marketId, merged);
        _burn(msg.sender, noId, merged);
        unchecked {
            totalSupplyId[marketId] -= merged; // Safe: burn succeeded so supply >= merged
            totalSupplyId[noId] -= merged;
        }

        collateralOut = merged;
        m.collateralLocked -= collateralOut;

        address collateral = m.collateral;
        if (collateral == ETH) {
            safeTransferETH(to, collateralOut);
        } else {
            safeTransfer(collateral, to, collateralOut);
        }

        emit Merged(to, marketId, merged, collateralOut);
    }

    /// @notice Burn winning shares -> collateral (minus resolver fee).
    function claim(uint256 marketId, address to)
        public
        nonReentrant
        returns (uint256 shares, uint256 payout)
    {
        if (to == address(0)) revert InvalidReceiver();
        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (!m.resolved) revert MarketNotClosed();
        (shares, payout) = _claimCore(m, marketId, to);
        if (shares == 0) revert AmountZero();
    }

    /// @notice Batch claim from multiple resolved markets.
    /// @dev Skips markets where user has no winning balance (no revert).
    /// @param marketIds Array of market ids to claim from
    /// @param to Recipient of all payouts
    function claimMany(uint256[] calldata marketIds, address to)
        public
        nonReentrant
        returns (uint256 totalPayout)
    {
        if (to == address(0)) revert InvalidReceiver();
        for (uint256 i; i < marketIds.length; ++i) {
            Market storage m = markets[marketIds[i]];
            if (m.resolver == address(0)) continue; // Skip invalid
            if (!m.resolved) continue; // Skip unresolved
            (, uint256 payout) = _claimCore(m, marketIds[i], to);
            totalPayout += payout;
        }
        if (totalPayout == 0) revert AmountZero();
    }

    /// @dev Core claim logic - returns (0,0) if no balance.
    function _claimCore(Market storage m, uint256 marketId, address to)
        internal
        returns (uint256 shares, uint256 payout)
    {
        address resolver = m.resolver;
        uint256 winId = m.outcome ? marketId : getNoId(marketId);
        shares = balanceOf[msg.sender][winId];
        if (shares == 0) return (0, 0);

        uint256 gross = shares;
        uint16 feeBps = resolverFeeBps[resolver];
        uint256 fee = (feeBps != 0) ? (gross * feeBps) / 10_000 : 0;
        payout = gross - fee;

        _burn(msg.sender, winId, shares);
        unchecked {
            totalSupplyId[winId] -= shares;
        }
        m.collateralLocked -= gross;

        address collateral = m.collateral;
        if (collateral == ETH) {
            if (fee != 0) safeTransferETH(resolver, fee);
            safeTransferETH(to, payout);
        } else {
            if (fee != 0) safeTransfer(collateral, resolver, fee);
            safeTransfer(collateral, to, payout);
        }

        emit Claimed(to, marketId, shares, payout);
    }

    /*//////////////////////////////////////////////////////////////
                          ZAMM POOL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Pull shares from msg.sender into contract with Transfer event.
    function _pullToThis(uint256 id, uint256 amount) internal {
        balanceOf[msg.sender][id] -= amount; // Checked: reverts if insufficient
        unchecked {
            balanceOf[address(this)][id] += amount; // Safe: bounded by totalSupply
        }
        emit Transfer(msg.sender, msg.sender, address(this), id, amount);
    }

    /// @notice PoolKey for market's YES/NO pair.
    function poolKey(uint256 marketId, uint256 feeOrHook)
        public
        view
        returns (IZAMM.PoolKey memory key)
    {
        key = _poolKey(marketId, getNoId(marketId), feeOrHook);
    }

    /// @dev Internal poolKey with pre-computed noId to avoid redundant hashing.
    function _poolKey(uint256 marketId, uint256 noId, uint256 feeOrHook)
        internal
        view
        returns (IZAMM.PoolKey memory key)
    {
        (uint256 id0, uint256 id1) = marketId < noId ? (marketId, noId) : (noId, marketId);
        key = IZAMM.PoolKey({
            id0: id0, id1: id1, token0: address(this), token1: address(this), feeOrHook: feeOrHook
        });
    }

    /// @notice Split collateral -> YES+NO -> LP in one tx.
    /// @dev Seeds new pool or adds to existing. Unused tokens returned.
    /// @param marketId The market to add liquidity for
    /// @param collateralIn Amount of collateral to split
    /// @param feeOrHook Pool fee tier (bps) or hook address
    /// @param amount0Min Minimum amount of token0 to add (slippage protection)
    /// @param amount1Min Minimum amount of token1 to add (slippage protection)
    /// @param minLiquidity Minimum LP tokens to receive
    /// @param to Recipient of LP tokens
    /// @param deadline Timestamp after which the tx reverts (0 = current block)
    function splitAndAddLiquidity(
        uint256 marketId,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minLiquidity,
        address to,
        uint256 deadline
    ) public payable nonReentrant returns (uint256 shares, uint256 liquidity) {
        (shares, liquidity) = _splitAndAddLiquidity(
            marketId, collateralIn, feeOrHook, amount0Min, amount1Min, minLiquidity, to, deadline
        );
    }

    /// @dev Internal splitAndAddLiquidity logic (no reentrancy guard).
    function _splitAndAddLiquidity(
        uint256 marketId,
        uint256 collateralIn,
        uint256 feeOrHook,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minLiquidity,
        address to,
        uint256 deadline
    ) internal returns (uint256 shares, uint256 liquidity) {
        if (to == address(0)) revert InvalidReceiver();

        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (m.resolved || block.timestamp >= m.close) revert MarketClosed();

        shares = _splitInternal(m, marketId, collateralIn);

        uint256 noId = getNoId(marketId);
        IZAMM.PoolKey memory key = _poolKey(marketId, noId, feeOrHook);
        ZAMM.deposit(address(this), key.id0, shares);
        ZAMM.deposit(address(this), key.id1, shares);

        uint256 dl = deadline == 0 ? block.timestamp : deadline;
        (,, liquidity) = ZAMM.addLiquidity(key, shares, shares, amount0Min, amount1Min, to, dl);
        if (liquidity < minLiquidity) revert InsufficientOutput();

        ZAMM.recoverTransientBalance(address(this), key.id0, msg.sender);
        ZAMM.recoverTransientBalance(address(this), key.id1, msg.sender);
    }

    /// @dev Internal split logic for buy helpers - mints to address(this).
    function _splitInternal(Market storage m, uint256 marketId, uint256 collateralIn)
        internal
        returns (uint256 shares)
    {
        if (m.collateral == ETH) {
            if (collateralIn != 0 && collateralIn != msg.value) revert InvalidETHAmount();
            shares = msg.value;
        } else {
            if (msg.value != 0) revert WrongCollateralType();
            if (collateralIn == 0) revert AmountZero();
            shares = collateralIn;
            safeTransferFrom(m.collateral, msg.sender, address(this), shares);
        }

        if (shares == 0) revert AmountZero();

        m.collateralLocked += shares;

        uint256 noId = getNoId(marketId);
        _mint(address(this), marketId, shares);
        _mint(address(this), noId, shares);
        totalSupplyId[marketId] += shares;
        totalSupplyId[noId] += shares;

        emit Split(msg.sender, marketId, shares, shares);
    }

    /// @notice Remove LP position and convert to collateral in one tx.
    /// @dev User must approve PAMM on ZAMM to pull LP tokens (via ZAMM.setOperator or approve).
    ///      - Unresolved markets: Burns balanced YES/NO pairs, refunds leftover shares.
    ///      - Resolved markets: Claims winning shares, refunds losing shares as dust.
    /// @param marketId The market to remove liquidity from
    /// @param feeOrHook Pool fee tier (bps) or hook address
    /// @param liquidity Amount of LP tokens to burn
    /// @param amount0Min Minimum amount of token0 from LP removal (slippage protection)
    /// @param amount1Min Minimum amount of token1 from LP removal (slippage protection)
    /// @param minCollateralOut Minimum collateral to receive (merged amount or claim payout)
    /// @param to Recipient of collateral
    /// @param deadline Timestamp after which the tx reverts (0 = current block)
    function removeLiquidityToCollateral(
        uint256 marketId,
        uint256 feeOrHook,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minCollateralOut,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 collateralOut, uint256 leftoverYes, uint256 leftoverNo) {
        if (to == address(0)) revert InvalidReceiver();
        if (liquidity == 0) revert AmountZero();

        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();

        uint256 noId = getNoId(marketId);
        IZAMM.PoolKey memory key = _poolKey(marketId, noId, feeOrHook);

        // Compute pool id (LP token id) and pull LP tokens from user
        uint256 poolId =
            uint256(keccak256(abi.encode(key.id0, key.id1, key.token0, key.token1, key.feeOrHook)));
        ZAMM.transferFrom(msg.sender, address(this), poolId, liquidity);

        uint256 dl = deadline == 0 ? block.timestamp : deadline;
        (uint256 a0, uint256 a1) =
            ZAMM.removeLiquidity(key, liquidity, amount0Min, amount1Min, address(this), dl);

        // Map to YES/NO amounts based on pool ordering
        (uint256 yesAmt, uint256 noAmt) = key.id0 == marketId ? (a0, a1) : (a1, a0);

        if (m.resolved) {
            // Resolved: claim winning side, losing side is dust
            (uint256 winAmt, uint256 winId, uint256 loseAmt, uint256 loseId) =
                m.outcome ? (yesAmt, marketId, noAmt, noId) : (noAmt, noId, yesAmt, marketId);

            if (winAmt != 0) {
                uint16 feeBps = resolverFeeBps[m.resolver];
                uint256 fee = (feeBps != 0) ? (winAmt * feeBps) / 10_000 : 0;
                collateralOut = winAmt - fee;

                _burn(address(this), winId, winAmt);
                unchecked {
                    totalSupplyId[winId] -= winAmt;
                }
                m.collateralLocked -= winAmt;

                if (m.collateral == ETH) {
                    if (fee != 0) safeTransferETH(m.resolver, fee);
                    safeTransferETH(to, collateralOut);
                } else {
                    if (fee != 0) safeTransfer(m.collateral, m.resolver, fee);
                    safeTransfer(m.collateral, to, collateralOut);
                }

                emit Claimed(to, marketId, winAmt, collateralOut);
            }

            if (collateralOut < minCollateralOut) revert InsufficientOutput();

            // Refund losing shares as dust (worthless)
            if (loseAmt != 0) {
                balanceOf[address(this)][loseId] -= loseAmt;
                unchecked {
                    balanceOf[msg.sender][loseId] += loseAmt;
                }
                emit Transfer(msg.sender, address(this), msg.sender, loseId, loseAmt);
            }

            // Return values: leftoverYes/No indicate dust
            (leftoverYes, leftoverNo) = m.outcome ? (uint256(0), loseAmt) : (loseAmt, uint256(0));
        } else {
            // Unresolved: merge balanced pairs
            uint256 merged = yesAmt < noAmt ? yesAmt : noAmt;

            _burn(address(this), marketId, merged);
            _burn(address(this), noId, merged);
            unchecked {
                totalSupplyId[marketId] -= merged;
                totalSupplyId[noId] -= merged;
            }

            collateralOut = merged;
            if (collateralOut < minCollateralOut) revert InsufficientOutput();
            m.collateralLocked -= collateralOut;

            if (m.collateral == ETH) {
                safeTransferETH(to, collateralOut);
            } else {
                safeTransfer(m.collateral, to, collateralOut);
            }

            // Refund leftover shares to msg.sender
            leftoverYes = yesAmt - merged;
            leftoverNo = noAmt - merged;
            if (leftoverYes != 0) {
                balanceOf[address(this)][marketId] -= leftoverYes;
                unchecked {
                    balanceOf[msg.sender][marketId] += leftoverYes;
                }
                emit Transfer(msg.sender, address(this), msg.sender, marketId, leftoverYes);
            }
            if (leftoverNo != 0) {
                balanceOf[address(this)][noId] -= leftoverNo;
                unchecked {
                    balanceOf[msg.sender][noId] += leftoverNo;
                }
                emit Transfer(msg.sender, address(this), msg.sender, noId, leftoverNo);
            }

            emit Merged(to, marketId, merged, collateralOut);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          BUY / SELL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy YES shares with collateral (split + swap NO→YES).
    /// @param marketId The market to buy YES for
    /// @param collateralIn Amount of collateral to spend
    /// @param minYesOut Minimum total YES shares to receive
    /// @param minSwapOut Minimum YES from swap leg (sandwich protection)
    /// @param feeOrHook Pool fee tier (bps) or hook address
    /// @param to Recipient of YES shares
    /// @param deadline Timestamp after which the tx reverts (0 = no deadline)
    function buyYes(
        uint256 marketId,
        uint256 collateralIn,
        uint256 minYesOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public payable nonReentrant returns (uint256 yesOut) {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        if (to == address(0)) revert InvalidReceiver();

        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (m.resolved || block.timestamp >= m.close) revert MarketClosed();

        // Split collateral into YES+NO
        uint256 shares = _splitInternal(m, marketId, collateralIn);

        // Swap all NO for YES
        uint256 noId = getNoId(marketId);
        IZAMM.PoolKey memory key = _poolKey(marketId, noId, feeOrHook);
        bool zeroForOne = key.id0 == noId;

        uint256 dl = deadline == 0 ? block.timestamp : deadline;
        ZAMM.deposit(address(this), noId, shares);
        uint256 yesFromSwap =
            ZAMM.swapExactIn(key, shares, minSwapOut, zeroForOne, address(this), dl);
        ZAMM.recoverTransientBalance(address(this), noId, address(this));

        // Total YES = split shares + swap output
        yesOut = shares + yesFromSwap;
        if (yesOut < minYesOut) revert InsufficientOutput();

        // Transfer YES to recipient
        balanceOf[address(this)][marketId] -= yesOut;
        unchecked {
            balanceOf[to][marketId] += yesOut; // Safe: bounded by totalSupply
        }
        emit Transfer(msg.sender, address(this), to, marketId, yesOut);
    }

    /// @notice Buy NO shares with collateral (split + swap YES→NO).
    /// @param marketId The market to buy NO for
    /// @param collateralIn Amount of collateral to spend
    /// @param minNoOut Minimum total NO shares to receive
    /// @param minSwapOut Minimum NO from swap leg (sandwich protection)
    /// @param feeOrHook Pool fee tier (bps) or hook address
    /// @param to Recipient of NO shares
    /// @param deadline Timestamp after which the tx reverts (0 = no deadline)
    function buyNo(
        uint256 marketId,
        uint256 collateralIn,
        uint256 minNoOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public payable nonReentrant returns (uint256 noOut) {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        if (to == address(0)) revert InvalidReceiver();

        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (m.resolved || block.timestamp >= m.close) revert MarketClosed();

        // Split collateral into YES+NO
        uint256 shares = _splitInternal(m, marketId, collateralIn);

        // Swap all YES for NO
        uint256 noId = getNoId(marketId);
        IZAMM.PoolKey memory key = _poolKey(marketId, noId, feeOrHook);
        bool zeroForOne = key.id0 == marketId;

        uint256 dl = deadline == 0 ? block.timestamp : deadline;
        ZAMM.deposit(address(this), marketId, shares);
        uint256 noFromSwap =
            ZAMM.swapExactIn(key, shares, minSwapOut, zeroForOne, address(this), dl);
        ZAMM.recoverTransientBalance(address(this), marketId, address(this));

        // Total NO = split shares + swap output
        noOut = shares + noFromSwap;
        if (noOut < minNoOut) revert InsufficientOutput();

        // Transfer NO to recipient
        balanceOf[address(this)][noId] -= noOut;
        unchecked {
            balanceOf[to][noId] += noOut; // Safe: bounded by totalSupply
        }
        emit Transfer(msg.sender, address(this), to, noId, noOut);
    }

    /// @notice Sell YES shares for collateral (swap some YES→NO + merge).
    /// @param marketId The market to sell YES from
    /// @param yesAmount Amount of YES shares to sell
    /// @param swapAmount Amount of YES to swap (0 = default 50%)
    /// @param minCollateralOut Minimum collateral to receive
    /// @param minSwapOut Minimum NO from swap leg (sandwich protection)
    /// @param feeOrHook Pool fee tier (bps) or hook address
    /// @param to Recipient of collateral
    /// @param deadline Timestamp after which the tx reverts (0 = no deadline)
    function sellYes(
        uint256 marketId,
        uint256 yesAmount,
        uint256 swapAmount,
        uint256 minCollateralOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 collateralOut) {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        if (yesAmount == 0) revert AmountZero();
        if (to == address(0)) revert InvalidReceiver();

        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (m.resolved || block.timestamp >= m.close) revert MarketClosed();

        _pullToThis(marketId, yesAmount);

        // Swap YES for NO (default 50% if swapAmount is 0)
        uint256 yesToSwap = swapAmount == 0 ? yesAmount / 2 : swapAmount;
        if (yesToSwap > yesAmount) revert InvalidSwapAmount();
        uint256 noId = getNoId(marketId);
        IZAMM.PoolKey memory key = _poolKey(marketId, noId, feeOrHook);
        bool zeroForOne = key.id0 == marketId;

        uint256 dl = deadline == 0 ? block.timestamp : deadline;
        ZAMM.deposit(address(this), marketId, yesToSwap);
        uint256 noFromSwap =
            ZAMM.swapExactIn(key, yesToSwap, minSwapOut, zeroForOne, address(this), dl);
        ZAMM.recoverTransientBalance(address(this), marketId, address(this));

        // Merge pairs: min(YES remaining, NO from swap)
        uint256 yesRemaining = yesAmount - yesToSwap;
        uint256 merged = yesRemaining < noFromSwap ? yesRemaining : noFromSwap;

        // Compute leftovers deterministically from this call
        uint256 leftoverYes = yesRemaining - merged;
        uint256 leftoverNo = noFromSwap - merged;

        // Burn merged pairs
        _burn(address(this), marketId, merged);
        _burn(address(this), noId, merged);
        unchecked {
            totalSupplyId[marketId] -= merged; // Safe: burn succeeded so supply >= merged
            totalSupplyId[noId] -= merged;
        }

        collateralOut = merged;
        m.collateralLocked -= collateralOut;

        if (collateralOut < minCollateralOut) revert InsufficientOutput();

        // Transfer collateral
        if (m.collateral == ETH) {
            safeTransferETH(to, collateralOut);
        } else {
            safeTransfer(m.collateral, to, collateralOut);
        }

        // Refund only this-call leftovers
        if (leftoverYes != 0) {
            balanceOf[address(this)][marketId] -= leftoverYes;
            unchecked {
                balanceOf[msg.sender][marketId] += leftoverYes; // Safe: bounded by totalSupply
            }
            emit Transfer(msg.sender, address(this), msg.sender, marketId, leftoverYes);
        }
        if (leftoverNo != 0) {
            balanceOf[address(this)][noId] -= leftoverNo;
            unchecked {
                balanceOf[msg.sender][noId] += leftoverNo; // Safe: bounded by totalSupply
            }
            emit Transfer(msg.sender, address(this), msg.sender, noId, leftoverNo);
        }

        emit Merged(to, marketId, merged, collateralOut);
    }

    /// @notice Sell NO shares for collateral (swap some NO→YES + merge).
    /// @param marketId The market to sell NO from
    /// @param noAmount Amount of NO shares to sell
    /// @param swapAmount Amount of NO to swap (0 = default 50%)
    /// @param minCollateralOut Minimum collateral to receive
    /// @param minSwapOut Minimum YES from swap leg (sandwich protection)
    /// @param feeOrHook Pool fee tier (bps) or hook address
    /// @param to Recipient of collateral
    /// @param deadline Timestamp after which the tx reverts (0 = no deadline)
    function sellNo(
        uint256 marketId,
        uint256 noAmount,
        uint256 swapAmount,
        uint256 minCollateralOut,
        uint256 minSwapOut,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 collateralOut) {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        if (noAmount == 0) revert AmountZero();
        if (to == address(0)) revert InvalidReceiver();

        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (m.resolved || block.timestamp >= m.close) revert MarketClosed();

        uint256 noId = getNoId(marketId);
        _pullToThis(noId, noAmount);

        // Swap NO for YES (default 50% if swapAmount is 0)
        uint256 noToSwap = swapAmount == 0 ? noAmount / 2 : swapAmount;
        if (noToSwap > noAmount) revert InvalidSwapAmount();
        IZAMM.PoolKey memory key = _poolKey(marketId, noId, feeOrHook);
        bool zeroForOne = key.id0 == noId;

        uint256 dl = deadline == 0 ? block.timestamp : deadline;
        ZAMM.deposit(address(this), noId, noToSwap);
        uint256 yesFromSwap =
            ZAMM.swapExactIn(key, noToSwap, minSwapOut, zeroForOne, address(this), dl);
        ZAMM.recoverTransientBalance(address(this), noId, address(this));

        // Merge pairs: min(NO remaining, YES from swap)
        uint256 noRemaining = noAmount - noToSwap;
        uint256 merged = noRemaining < yesFromSwap ? noRemaining : yesFromSwap;

        // Compute leftovers deterministically from this call
        uint256 leftoverNo = noRemaining - merged;
        uint256 leftoverYes = yesFromSwap - merged;

        // Burn merged pairs
        _burn(address(this), marketId, merged);
        _burn(address(this), noId, merged);
        unchecked {
            totalSupplyId[marketId] -= merged; // Safe: burn succeeded so supply >= merged
            totalSupplyId[noId] -= merged;
        }

        collateralOut = merged;
        m.collateralLocked -= collateralOut;

        if (collateralOut < minCollateralOut) revert InsufficientOutput();

        // Transfer collateral
        if (m.collateral == ETH) {
            safeTransferETH(to, collateralOut);
        } else {
            safeTransfer(m.collateral, to, collateralOut);
        }

        // Refund only this-call leftovers
        if (leftoverYes != 0) {
            balanceOf[address(this)][marketId] -= leftoverYes;
            unchecked {
                balanceOf[msg.sender][marketId] += leftoverYes; // Safe: bounded by totalSupply
            }
            emit Transfer(msg.sender, address(this), msg.sender, marketId, leftoverYes);
        }
        if (leftoverNo != 0) {
            balanceOf[address(this)][noId] -= leftoverNo;
            unchecked {
                balanceOf[msg.sender][noId] += leftoverNo; // Safe: bounded by totalSupply
            }
            emit Transfer(msg.sender, address(this), msg.sender, noId, leftoverNo);
        }

        emit Merged(to, marketId, merged, collateralOut);
    }

    /// @notice Sell YES shares for exact collateral amount (swap YES→NO using exactOut + merge).
    /// @param marketId The market to sell YES from
    /// @param collateralOut Exact collateral amount to receive
    /// @param maxYesIn Maximum YES shares willing to spend
    /// @param maxSwapIn Maximum YES to swap (slippage protection on swap leg)
    /// @param feeOrHook Pool fee tier (bps) or hook address
    /// @param to Recipient of collateral
    /// @param deadline Timestamp after which the tx reverts (0 = no deadline)
    function sellYesForExactCollateral(
        uint256 marketId,
        uint256 collateralOut,
        uint256 maxYesIn,
        uint256 maxSwapIn,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 yesSpent) {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        if (collateralOut == 0) revert AmountZero();
        if (to == address(0)) revert InvalidReceiver();

        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (m.resolved || block.timestamp >= m.close) revert MarketClosed();

        uint256 merged = collateralOut;
        if (maxSwapIn > maxYesIn) revert ExcessiveInput();

        uint256 noId = getNoId(marketId);
        IZAMM.PoolKey memory key = _poolKey(marketId, noId, feeOrHook);
        bool zeroForOne = key.id0 == marketId;

        // Swap YES for exactly `merged` NO shares
        _pullToThis(marketId, maxYesIn);

        uint256 dl = deadline == 0 ? block.timestamp : deadline;
        ZAMM.deposit(address(this), marketId, maxYesIn);
        uint256 yesSwapped =
            ZAMM.swapExactOut(key, merged, maxSwapIn, zeroForOne, address(this), dl);
        ZAMM.recoverTransientBalance(address(this), marketId, address(this));

        // Total YES spent = swapped + merged (for the merge)
        yesSpent = yesSwapped + merged;
        if (yesSpent > maxYesIn) revert ExcessiveInput();

        // Burn merged pairs
        _burn(address(this), marketId, merged);
        _burn(address(this), noId, merged);
        unchecked {
            totalSupplyId[marketId] -= merged; // Safe: burn succeeded so supply >= merged
            totalSupplyId[noId] -= merged;
        }

        m.collateralLocked -= merged;

        // Transfer collateral
        if (m.collateral == ETH) {
            safeTransferETH(to, merged);
        } else {
            safeTransfer(m.collateral, to, merged);
        }

        // Refund unused YES
        uint256 leftoverYes = maxYesIn - yesSpent;
        if (leftoverYes != 0) {
            balanceOf[address(this)][marketId] -= leftoverYes;
            unchecked {
                balanceOf[msg.sender][marketId] += leftoverYes; // Safe: bounded by totalSupply
            }
            emit Transfer(msg.sender, address(this), msg.sender, marketId, leftoverYes);
        }

        emit Merged(to, marketId, merged, merged);
    }

    /// @notice Sell NO shares for exact collateral amount (swap NO→YES using exactOut + merge).
    /// @param marketId The market to sell NO from
    /// @param collateralOut Exact collateral amount to receive
    /// @param maxNoIn Maximum NO shares willing to spend
    /// @param maxSwapIn Maximum NO to swap (slippage protection on swap leg)
    /// @param feeOrHook Pool fee tier (bps) or hook address
    /// @param to Recipient of collateral
    /// @param deadline Timestamp after which the tx reverts (0 = no deadline)
    function sellNoForExactCollateral(
        uint256 marketId,
        uint256 collateralOut,
        uint256 maxNoIn,
        uint256 maxSwapIn,
        uint256 feeOrHook,
        address to,
        uint256 deadline
    ) public nonReentrant returns (uint256 noSpent) {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        if (collateralOut == 0) revert AmountZero();
        if (to == address(0)) revert InvalidReceiver();

        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        if (m.resolved || block.timestamp >= m.close) revert MarketClosed();

        uint256 merged = collateralOut;
        if (maxSwapIn > maxNoIn) revert ExcessiveInput();

        uint256 noId = getNoId(marketId);
        IZAMM.PoolKey memory key = _poolKey(marketId, noId, feeOrHook);
        bool zeroForOne = key.id0 == noId;

        // Swap NO for exactly `merged` YES shares
        _pullToThis(noId, maxNoIn);

        uint256 dl = deadline == 0 ? block.timestamp : deadline;
        ZAMM.deposit(address(this), noId, maxNoIn);
        uint256 noSwapped = ZAMM.swapExactOut(key, merged, maxSwapIn, zeroForOne, address(this), dl);
        ZAMM.recoverTransientBalance(address(this), noId, address(this));

        // Total NO spent = swapped + merged (for the merge)
        noSpent = noSwapped + merged;
        if (noSpent > maxNoIn) revert ExcessiveInput();

        // Burn merged pairs
        _burn(address(this), marketId, merged);
        _burn(address(this), noId, merged);
        unchecked {
            totalSupplyId[marketId] -= merged; // Safe: burn succeeded so supply >= merged
            totalSupplyId[noId] -= merged;
        }

        m.collateralLocked -= merged;

        // Transfer collateral
        if (m.collateral == ETH) {
            safeTransferETH(to, merged);
        } else {
            safeTransfer(m.collateral, to, merged);
        }

        // Refund unused NO
        uint256 leftoverNo = maxNoIn - noSpent;
        if (leftoverNo != 0) {
            balanceOf[address(this)][noId] -= leftoverNo;
            unchecked {
                balanceOf[msg.sender][noId] += leftoverNo; // Safe: bounded by totalSupply
            }
            emit Transfer(msg.sender, address(this), msg.sender, noId, leftoverNo);
        }

        emit Merged(to, marketId, merged, merged);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of markets.
    function marketCount() public view returns (uint256) {
        return allMarkets.length;
    }

    /// @notice Check if market is open for trading (split/buy/sell allowed).
    /// @dev Merge is allowed until resolved, not just until close.
    function tradingOpen(uint256 marketId) public view returns (bool) {
        Market storage m = markets[marketId];
        return m.resolver != address(0) && !m.resolved && block.timestamp < m.close;
    }

    /// @notice Winning token id (0 if unresolved or not found).
    function winningId(uint256 marketId) public view returns (uint256) {
        Market storage m = markets[marketId];
        if (m.resolver == address(0) || !m.resolved) return 0;
        return m.outcome ? marketId : getNoId(marketId);
    }

    /// @notice Full market state.
    function getMarket(uint256 marketId)
        public
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
        )
    {
        Market storage m = markets[marketId];
        if (m.resolver == address(0)) revert MarketNotFound();
        resolver = m.resolver;
        collateral = m.collateral;
        resolved = m.resolved;
        outcome = m.outcome;
        canClose = m.canClose;
        close = m.close;
        collateralLocked = m.collateralLocked;
        yesSupply = totalSupplyId[marketId];
        noSupply = totalSupplyId[getNoId(marketId)];
        description = descriptions[marketId];
    }

    /// @notice Pool reserves and implied probability.
    function getPoolState(uint256 marketId, uint256 feeOrHook)
        public
        view
        returns (uint256 rYes, uint256 rNo, uint256 pYesNum, uint256 pYesDen)
    {
        IZAMM.PoolKey memory key = poolKey(marketId, feeOrHook);
        uint256 pid =
            uint256(keccak256(abi.encode(key.id0, key.id1, key.token0, key.token1, key.feeOrHook)));
        (uint112 r0, uint112 r1,,,,,) = ZAMM.pools(pid);

        (rYes, rNo) = key.id0 == marketId ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        pYesNum = rNo;
        pYesDen = rYes + rNo;
    }

    /// @notice Paginated batch read of all markets.
    function getMarkets(uint256 start, uint256 count)
        public
        view
        returns (
            uint256[] memory marketIds,
            address[] memory resolvers,
            address[] memory collaterals,
            uint8[] memory states,
            uint64[] memory closes,
            uint256[] memory collateralAmounts,
            uint256[] memory yesSupplies,
            uint256[] memory noSupplies,
            string[] memory descs,
            uint256 next
        )
    {
        uint256 len = allMarkets.length;
        if (start >= len) {
            return (
                new uint256[](0),
                new address[](0),
                new address[](0),
                new uint8[](0),
                new uint64[](0),
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                new string[](0),
                0
            );
        }

        uint256 end = start + count;
        if (end > len) end = len;
        uint256 n = end - start;

        marketIds = new uint256[](n);
        resolvers = new address[](n);
        collaterals = new address[](n);
        states = new uint8[](n);
        closes = new uint64[](n);
        collateralAmounts = new uint256[](n);
        yesSupplies = new uint256[](n);
        noSupplies = new uint256[](n);
        descs = new string[](n);

        for (uint256 i; i != n; ++i) {
            uint256 mId = allMarkets[start + i];
            Market storage m = markets[mId];

            marketIds[i] = mId;
            resolvers[i] = m.resolver;
            collaterals[i] = m.collateral;
            states[i] = (m.resolved ? 1 : 0) | (m.outcome ? 2 : 0) | (m.canClose ? 4 : 0);
            closes[i] = m.close;
            collateralAmounts[i] = m.collateralLocked;
            yesSupplies[i] = totalSupplyId[mId];
            noSupplies[i] = totalSupplyId[getNoId(mId)];
            descs[i] = descriptions[mId];
        }

        next = (end < len) ? end : 0;
    }

    /// @notice Batch read specific markets by ID.
    /// @dev Skips invalid market IDs (resolver == address(0)).
    function getMarketsByIds(uint256[] calldata ids)
        public
        view
        returns (
            address[] memory resolvers,
            address[] memory collaterals,
            uint8[] memory states,
            uint64[] memory closes,
            uint256[] memory collateralAmounts,
            uint256[] memory yesSupplies,
            uint256[] memory noSupplies,
            string[] memory descs
        )
    {
        uint256 n = ids.length;
        resolvers = new address[](n);
        collaterals = new address[](n);
        states = new uint8[](n);
        closes = new uint64[](n);
        collateralAmounts = new uint256[](n);
        yesSupplies = new uint256[](n);
        noSupplies = new uint256[](n);
        descs = new string[](n);

        for (uint256 i; i != n; ++i) {
            uint256 mId = ids[i];
            Market storage m = markets[mId];
            if (m.resolver == address(0)) continue;

            resolvers[i] = m.resolver;
            collaterals[i] = m.collateral;
            states[i] = (m.resolved ? 1 : 0) | (m.outcome ? 2 : 0) | (m.canClose ? 4 : 0);
            closes[i] = m.close;
            collateralAmounts[i] = m.collateralLocked;
            yesSupplies[i] = totalSupplyId[mId];
            noSupplies[i] = totalSupplyId[getNoId(mId)];
            descs[i] = descriptions[mId];
        }
    }

    /// @notice Paginated batch read of user positions.
    function getUserPositions(address user, uint256 start, uint256 count)
        public
        view
        returns (
            uint256[] memory marketIds,
            uint256[] memory noIds,
            address[] memory collaterals,
            uint256[] memory yesBalances,
            uint256[] memory noBalances,
            uint256[] memory claimables,
            bool[] memory isResolved,
            bool[] memory isOpen,
            uint256 next
        )
    {
        uint256 len = allMarkets.length;
        if (start >= len) {
            return (
                new uint256[](0),
                new uint256[](0),
                new address[](0),
                new uint256[](0),
                new uint256[](0),
                new uint256[](0),
                new bool[](0),
                new bool[](0),
                0
            );
        }

        uint256 end = start + count;
        if (end > len) end = len;
        uint256 n = end - start;

        marketIds = new uint256[](n);
        noIds = new uint256[](n);
        collaterals = new address[](n);
        yesBalances = new uint256[](n);
        noBalances = new uint256[](n);
        claimables = new uint256[](n);
        isResolved = new bool[](n);
        isOpen = new bool[](n);

        for (uint256 i; i != n; ++i) {
            uint256 mId = allMarkets[start + i];
            uint256 nId = getNoId(mId);
            Market storage m = markets[mId];

            marketIds[i] = mId;
            noIds[i] = nId;
            collaterals[i] = m.collateral;

            uint256 yesBal = balanceOf[user][mId];
            uint256 noBal = balanceOf[user][nId];
            yesBalances[i] = yesBal;
            noBalances[i] = noBal;

            bool resolved = m.resolved;
            isResolved[i] = resolved;
            isOpen[i] = m.resolver != address(0) && !resolved && block.timestamp < m.close;

            if (resolved) {
                uint256 gross = m.outcome ? yesBal : noBal;
                uint16 feeBps = resolverFeeBps[m.resolver];
                claimables[i] = gross - ((feeBps != 0) ? (gross * feeBps) / 10_000 : 0);
            }
        }

        next = (end < len) ? end : 0;
    }
}

/// @dev Low-level transfer helpers (free functions for simplicity).

function safeTransferETH(address to, uint256 amount) {
    assembly ("memory-safe") {
        if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
            mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
            revert(0x1c, 0x04)
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
                mstore(0x00, 0x90b8ec18) // TransferFailed()
                revert(0x1c, 0x04)
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
                mstore(0x00, 0x7939f424) // TransferFromFailed()
                revert(0x1c, 0x04)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}
