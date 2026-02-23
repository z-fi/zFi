// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

// File-level error selectors (matches PMHookRouter)
bytes4 constant ERR_TRANSFER = 0x2929f974; // TransferError(uint8)
bytes4 constant ERR_REENTRANCY = 0xab143c06; // Reentrancy()
bytes4 constant ERR_VALIDATION = 0x077a9c33; // ValidationError(uint8)
bytes4 constant ERR_APPROVE = 0x3e3f8f73; // ApproveFailed()

interface IPMHookRouter {
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
        external
        payable
        returns (uint256 marketId, uint256 poolId, uint256 lpShares, uint256 sharesOut);

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
}

interface IResolver {
    enum Op {
        LT,
        GT,
        LTE,
        GTE,
        EQ,
        NEQ,
        BETWEEN
    }

    function registerConditionForExistingMarket(
        uint256 marketId,
        address target,
        bytes calldata callData,
        Op op,
        uint256 threshold
    ) external;

    function registerBetweenConditionForExistingMarket(
        uint256 marketId,
        address target,
        bytes calldata callData,
        uint256 lower,
        uint256 upper
    ) external;
}

interface IMasterRouter {
    function createBidPool(
        uint256 marketId,
        uint256 collateralIn,
        bool buyYes,
        uint256 priceInBps,
        address to
    ) external payable returns (bytes32 bidPoolId);
}

interface IPAMM {
    function getMarketId(string calldata description, address resolver, address collateral)
        external
        pure
        returns (uint256);
}

/// @dev Minimal ERC20 interface for selector usage
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Chainlink price feed interface for selector usage
interface IChainlinkFeed {
    function latestAnswer() external view returns (int256);
}

/// @title Bootstrapper
/// @notice Helper contract to create prediction markets with PMHookRouter and register conditions with Resolver
/// @dev Batches bootstrapMarket() + registerConditionForExistingMarket() + optional orderbook bids
/// @dev Supports ERC20 collateral via permit + multicall pattern
contract Bootstrapper {
    address constant ETH = address(0);

    // Transient storage slots (EIP-1153)
    uint256 constant REENTRANCY_SLOT = 0xb00757a9949b4bd21268;
    uint256 constant MULTICALL_DEPTH_SLOT = 0xb00757a9949b4bd21269;

    IPAMM constant PAMM = IPAMM(0x000000000044bfe6c2BBFeD8862973E0612f07C0);
    IPMHookRouter constant hookRouter = IPMHookRouter(0x0000000000Ff22a7FFEf88639d95C03183c5093C);
    IResolver constant resolver = IResolver(0x0000000000FF0Dc62d07e220F273fe8cDd324127);
    IMasterRouter constant masterRouter = IMasterRouter(0x000000000088Ec6Ab5CA97A354Ce4C57dBA5B88a);

    /// @notice Orderbook bid order specification
    struct BidOrder {
        bool buyYes; // True = bid for YES shares, false = bid for NO shares
        uint256 priceInBps; // Price in basis points (1-9999)
        uint256 amount; // Collateral amount for this bid
        uint256 minShares; // Minimum expected shares if filled (0 = no check)
    }

    /// @notice Vault OTC deposit parameters
    /// @dev collateralForVault is split into YES+NO shares, then vaultYesShares/vaultNoShares are deposited
    struct VaultParams {
        uint256 collateralForVault; // Collateral to split for vault deposits
        uint256 vaultYesShares; // YES shares from split to deposit to vault (max: collateralForVault)
        uint256 vaultNoShares; // NO shares from split to deposit to vault (max: collateralForVault)
    }

    /// @notice Initial buy parameters to skew market odds at creation
    /// @dev No slippage protection needed - atomic with pool creation
    struct InitialBuy {
        bool buyYes; // True = buy YES shares, false = buy NO shares
        uint256 collateralForBuy; // Collateral for initial swap (0 = no initial buy)
    }

    // ============ Reentrancy Guard ============

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
        }
    }

    // ============ Multicall ============

    /// @notice Execute multiple calls in a single transaction
    /// @dev Use with permit() to approve ERC20 tokens before bootstrapping
    function multicall(bytes[] calldata data) public payable returns (bytes[] memory results) {
        assembly ("memory-safe") {
            if tload(REENTRANCY_SLOT) {
                mstore(0x00, ERR_REENTRANCY)
                revert(0x00, 0x04)
            }
            tstore(MULTICALL_DEPTH_SLOT, add(tload(MULTICALL_DEPTH_SLOT), 1))
        }

        results = new bytes[](data.length);
        for (uint256 i; i != data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            assembly ("memory-safe") {
                if iszero(ok) { revert(add(result, 0x20), mload(result)) }
            }
            results[i] = result;
        }

        assembly ("memory-safe") {
            let depth := sub(tload(MULTICALL_DEPTH_SLOT), 1)
            tstore(MULTICALL_DEPTH_SLOT, depth)

            // Refund remaining balance at top-level completion
            if iszero(depth) {
                let bal := selfbalance()
                if bal {
                    tstore(REENTRANCY_SLOT, address())
                    if iszero(call(gas(), caller(), bal, codesize(), 0x00, codesize(), 0x00)) {
                        tstore(REENTRANCY_SLOT, 0)
                        mstore(0x00, ERR_TRANSFER)
                        mstore(0x04, 2)
                        revert(0x00, 0x24)
                    }
                    tstore(REENTRANCY_SLOT, 0)
                }
            }
        }
    }

    // ============ Permit Helpers ============

    /// @notice EIP-2612 permit for ERC20 tokens (use in multicall before bootstrap)
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

            switch returndatasize()
            case 0 {}
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) }
            }
            default { revert(0, 0) }

            mstore(0x40, add(m, 0x100))
        }
        _guardExit();
    }

    /// @notice DAI-style permit (use in multicall before bootstrap)
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

            switch returndatasize()
            case 0 {}
            case 32 {
                returndatacopy(m, 0, 32)
                if iszero(mload(m)) { revert(0, 0) }
            }
            default { revert(0, 0) }

            mstore(0x40, add(m, 0x120))
        }
        _guardExit();
    }

    // ============ Open Resolver Bootstrap ============

    /// @notice Bootstrap market with any resolver (no condition registration)
    /// @dev For UMA, Reality.eth, manual EOA, or other custom resolvers
    function bootstrapMarket(
        string calldata description,
        address resolverAddr,
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

        uint256 totalCollateral = collateralForLP + collateralForBuy;

        if (collateral != ETH && totalCollateral != 0) {
            _safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
            _ensureApproval(collateral, address(hookRouter));
        }

        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? totalCollateral : 0
        }(
            description,
            resolverAddr,
            collateral,
            close,
            canClose,
            hook,
            collateralForLP,
            buyYes,
            collateralForBuy,
            minSharesOut,
            to,
            deadline
        );

        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap market with any resolver + orderbook bids
    /// @dev For UMA, Reality.eth, manual EOA, or other custom resolvers
    function bootstrapMarketWithBids(
        string calldata description,
        address resolverAddr,
        address collateral,
        uint64 close,
        bool canClose,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        BidOrder[] calldata bids
    ) public payable returns (uint256 marketId, uint256 poolId, uint256 lpShares) {
        _guardEnter();

        uint256 totalBidCollateral;
        for (uint256 i; i < bids.length; ++i) {
            totalBidCollateral += bids[i].amount;
        }
        uint256 totalCollateral = collateralForLP + totalBidCollateral;

        if (collateral != ETH && totalCollateral != 0) {
            _safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
            _ensureApproval(collateral, address(hookRouter));
            _ensureApproval(collateral, address(masterRouter));
        }

        (marketId, poolId, lpShares,) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? collateralForLP : 0
        }(
            description,
            resolverAddr,
            collateral,
            close,
            canClose,
            hook,
            collateralForLP,
            false,
            0,
            0,
            to,
            deadline
        );

        for (uint256 i; i < bids.length; ++i) {
            _createBidWithValidation(marketId, collateral, bids[i], to);
        }

        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap market with any resolver + vault OTC deposits + optional initial buy
    /// @dev Creates market via PMHookRouter, then deposits to vault via provideLiquidity
    function bootstrapMarketWithVault(
        string calldata description,
        address resolverAddr,
        address collateral,
        uint64 close,
        bool canClose,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        VaultParams calldata vault,
        InitialBuy calldata buy
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();

        uint256 totalCollateral = collateralForLP + vault.collateralForVault + buy.collateralForBuy;

        if (collateral != ETH && totalCollateral != 0) {
            _safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
            _ensureApproval(collateral, address(hookRouter));
        }

        // Create market + AMM liquidity + optional initial buy (minSharesOut=0, atomic so no slippage)
        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            resolverAddr,
            collateral,
            close,
            canClose,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0, // minSharesOut - no slippage check needed for atomic init buy
            to,
            deadline
        );

        // Add vault deposits (ammLPShares=0 since we already added AMM liquidity)
        if (vault.collateralForVault != 0) {
            (yesVaultShares, noVaultShares,) = hookRouter.provideLiquidity{
                value: collateral == ETH ? vault.collateralForVault : 0
            }(
                marketId,
                vault.collateralForVault,
                vault.vaultYesShares,
                vault.vaultNoShares,
                0,
                0,
                0,
                to,
                deadline
            );
        }

        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap market with any resolver + vault OTC deposits + orderbook bids + optional initial buy
    function bootstrapMarketWithVaultAndBids(
        string calldata description,
        address resolverAddr,
        address collateral,
        uint64 close,
        bool canClose,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        VaultParams calldata vault,
        InitialBuy calldata buy,
        BidOrder[] calldata bids
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();

        uint256 totalBidCollateral;
        for (uint256 i; i < bids.length; ++i) {
            totalBidCollateral += bids[i].amount;
        }
        uint256 totalCollateral =
            collateralForLP + vault.collateralForVault + buy.collateralForBuy + totalBidCollateral;

        if (collateral != ETH && totalCollateral != 0) {
            _safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
            _ensureApproval(collateral, address(hookRouter));
            _ensureApproval(collateral, address(masterRouter));
        }

        // Create market + AMM liquidity + optional initial buy
        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            resolverAddr,
            collateral,
            close,
            canClose,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0,
            to,
            deadline
        );

        // Add vault deposits
        if (vault.collateralForVault != 0) {
            (yesVaultShares, noVaultShares,) = hookRouter.provideLiquidity{
                value: collateral == ETH ? vault.collateralForVault : 0
            }(
                marketId,
                vault.collateralForVault,
                vault.vaultYesShares,
                vault.vaultNoShares,
                0,
                0,
                0,
                to,
                deadline
            );
        }

        // Add orderbook bids
        for (uint256 i; i < bids.length; ++i) {
            _createBidWithValidation(marketId, collateral, bids[i], to);
        }

        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    // ============ Resolver.sol Bootstrap ============

    /// @notice Create a market via PMHookRouter and register its condition with Resolver atomically
    function bootstrapWithCondition(
        string calldata description,
        address collateral,
        uint64 close,
        bool canClose,
        address hook,
        uint256 collateralForLP,
        bool buyYes,
        uint256 collateralForBuy,
        uint256 minSharesOut,
        address to,
        uint256 deadline,
        address target,
        bytes calldata callData,
        IResolver.Op op,
        uint256 threshold
    )
        public
        payable
        returns (uint256 marketId, uint256 poolId, uint256 lpShares, uint256 sharesOut)
    {
        _guardEnter();

        uint256 totalCollateral = collateralForLP + collateralForBuy;

        if (collateral != ETH && totalCollateral != 0) {
            _safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
            _ensureApproval(collateral, address(hookRouter));
        }

        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? totalCollateral : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            canClose,
            hook,
            collateralForLP,
            buyYes,
            collateralForBuy,
            minSharesOut,
            to,
            deadline
        );

        resolver.registerConditionForExistingMarket(marketId, target, callData, op, threshold);

        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Create market with arbitrary condition + orderbook bids
    function bootstrapWithConditionAndBids(
        string calldata description,
        address collateral,
        uint64 close,
        bool canClose,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address target,
        bytes calldata callData,
        IResolver.Op op,
        uint256 threshold,
        BidOrder[] calldata bids
    ) public payable returns (uint256 marketId, uint256 poolId, uint256 lpShares) {
        _guardEnter();

        uint256 totalBidCollateral;
        for (uint256 i; i < bids.length; ++i) {
            totalBidCollateral += bids[i].amount;
        }
        uint256 totalCollateral = collateralForLP + totalBidCollateral;

        if (collateral != ETH && totalCollateral != 0) {
            _safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
            _ensureApproval(collateral, address(hookRouter));
            _ensureApproval(collateral, address(masterRouter));
        }

        (marketId, poolId, lpShares,) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? collateralForLP : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            canClose,
            hook,
            collateralForLP,
            false,
            0,
            0,
            to,
            deadline
        );

        resolver.registerConditionForExistingMarket(marketId, target, callData, op, threshold);

        for (uint256 i; i < bids.length; ++i) {
            _createBidWithValidation(marketId, collateral, bids[i], to);
        }

        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Create market with arbitrary condition + vault OTC deposits + optional initial buy
    function bootstrapWithConditionAndVault(
        string calldata description,
        address collateral,
        uint64 close,
        bool canClose,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address target,
        bytes calldata callData,
        IResolver.Op op,
        uint256 threshold,
        VaultParams calldata vault,
        InitialBuy calldata buy
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();

        uint256 totalCollateral = collateralForLP + vault.collateralForVault + buy.collateralForBuy;

        if (collateral != ETH && totalCollateral != 0) {
            _safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
            _ensureApproval(collateral, address(hookRouter));
        }

        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            canClose,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0,
            to,
            deadline
        );

        resolver.registerConditionForExistingMarket(marketId, target, callData, op, threshold);

        if (vault.collateralForVault != 0) {
            (yesVaultShares, noVaultShares,) = hookRouter.provideLiquidity{
                value: collateral == ETH ? vault.collateralForVault : 0
            }(
                marketId,
                vault.collateralForVault,
                vault.vaultYesShares,
                vault.vaultNoShares,
                0,
                0,
                0,
                to,
                deadline
            );
        }

        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Create market with arbitrary condition + vault OTC deposits + orderbook bids + optional initial buy
    function bootstrapWithConditionAndVaultAndBids(
        string calldata description,
        address collateral,
        uint64 close,
        bool canClose,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address target,
        bytes calldata callData,
        IResolver.Op op,
        uint256 threshold,
        VaultParams calldata vault,
        InitialBuy calldata buy,
        BidOrder[] calldata bids
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();

        uint256 totalBidCollateral;
        for (uint256 i; i < bids.length; ++i) {
            totalBidCollateral += bids[i].amount;
        }
        uint256 totalCollateral =
            collateralForLP + vault.collateralForVault + buy.collateralForBuy + totalBidCollateral;

        if (collateral != ETH && totalCollateral != 0) {
            _safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
            _ensureApproval(collateral, address(hookRouter));
            _ensureApproval(collateral, address(masterRouter));
        }

        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            canClose,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0,
            to,
            deadline
        );

        resolver.registerConditionForExistingMarket(marketId, target, callData, op, threshold);

        if (vault.collateralForVault != 0) {
            (yesVaultShares, noVaultShares,) = hookRouter.provideLiquidity{
                value: collateral == ETH ? vault.collateralForVault : 0
            }(
                marketId,
                vault.collateralForVault,
                vault.vaultYesShares,
                vault.vaultNoShares,
                0,
                0,
                0,
                to,
                deadline
            );
        }

        for (uint256 i; i < bids.length; ++i) {
            _createBidWithValidation(marketId, collateral, bids[i], to);
        }

        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap market for native ETH balance condition
    function bootstrapETHBalanceMarket(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address account,
        IResolver.Op op,
        uint256 balanceThreshold
    ) public payable returns (uint256 marketId, uint256 poolId, uint256 lpShares) {
        _guardEnter();
        _prepareCollateral(collateral, collateralForLP, false);
        (marketId, poolId, lpShares,) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? collateralForLP : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            false,
            0,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(marketId, account, "", op, balanceThreshold);
        _refundExcessETH(collateral, collateralForLP);
        _guardExit();
    }

    /// @notice Bootstrap market for ERC20 token balance condition
    function bootstrapTokenBalanceMarket(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address token,
        address account,
        IResolver.Op op,
        uint256 balanceThreshold
    ) public payable returns (uint256 marketId, uint256 poolId, uint256 lpShares) {
        _guardEnter();
        _prepareCollateral(collateral, collateralForLP, false);
        (marketId, poolId, lpShares,) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? collateralForLP : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            false,
            0,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(
            marketId,
            token,
            abi.encodeWithSelector(IERC20.balanceOf.selector, account),
            op,
            balanceThreshold
        );
        _refundExcessETH(collateral, collateralForLP);
        _guardExit();
    }

    /// @notice Bootstrap token balance market with vault OTC deposits + optional initial buy
    function bootstrapTokenBalanceMarketWithVault(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address token,
        address account,
        IResolver.Op op,
        uint256 balanceThreshold,
        VaultParams calldata vault,
        InitialBuy calldata buy
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + vault.collateralForVault + buy.collateralForBuy;
        _prepareCollateral(collateral, totalCollateral, false);
        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(
            marketId,
            token,
            abi.encodeWithSelector(IERC20.balanceOf.selector, account),
            op,
            balanceThreshold
        );
        (yesVaultShares, noVaultShares) =
            _addVaultDeposits(marketId, collateral, vault, to, deadline);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap ETH balance market with vault OTC deposits + optional initial buy
    function bootstrapETHBalanceMarketWithVault(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address account,
        IResolver.Op op,
        uint256 balanceThreshold,
        VaultParams calldata vault,
        InitialBuy calldata buy
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + vault.collateralForVault + buy.collateralForBuy;
        _prepareCollateral(collateral, totalCollateral, false);
        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(marketId, account, "", op, balanceThreshold);
        (yesVaultShares, noVaultShares) =
            _addVaultDeposits(marketId, collateral, vault, to, deadline);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap ETH balance market with orderbook bids
    function bootstrapETHBalanceMarketWithBids(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address account,
        IResolver.Op op,
        uint256 balanceThreshold,
        BidOrder[] calldata bids
    ) public payable returns (uint256 marketId, uint256 poolId, uint256 lpShares) {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + _sumBidCollateral(bids);
        _prepareCollateral(collateral, totalCollateral, true);
        (marketId, poolId, lpShares,) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? collateralForLP : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            false,
            0,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(marketId, account, "", op, balanceThreshold);
        _processBids(marketId, collateral, bids, to);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap token balance market with orderbook bids
    function bootstrapTokenBalanceMarketWithBids(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address token,
        address account,
        IResolver.Op op,
        uint256 balanceThreshold,
        BidOrder[] calldata bids
    ) public payable returns (uint256 marketId, uint256 poolId, uint256 lpShares) {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + _sumBidCollateral(bids);
        _prepareCollateral(collateral, totalCollateral, true);
        (marketId, poolId, lpShares,) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? collateralForLP : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            false,
            0,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(
            marketId,
            token,
            abi.encodeWithSelector(IERC20.balanceOf.selector, account),
            op,
            balanceThreshold
        );
        _processBids(marketId, collateral, bids, to);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap ETH balance market + vault + bids
    function bootstrapETHBalanceMarketWithVaultAndBids(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address account,
        IResolver.Op op,
        uint256 balanceThreshold,
        VaultParams calldata vault,
        InitialBuy calldata buy,
        BidOrder[] calldata bids
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + vault.collateralForVault + buy.collateralForBuy
            + _sumBidCollateral(bids);
        _prepareCollateral(collateral, totalCollateral, true);
        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(marketId, account, "", op, balanceThreshold);
        (yesVaultShares, noVaultShares) =
            _addVaultDeposits(marketId, collateral, vault, to, deadline);
        _processBids(marketId, collateral, bids, to);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap token balance market + vault + bids
    function bootstrapTokenBalanceMarketWithVaultAndBids(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address token,
        address account,
        IResolver.Op op,
        uint256 balanceThreshold,
        VaultParams calldata vault,
        InitialBuy calldata buy,
        BidOrder[] calldata bids
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + vault.collateralForVault + buy.collateralForBuy
            + _sumBidCollateral(bids);
        _prepareCollateral(collateral, totalCollateral, true);
        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(
            marketId,
            token,
            abi.encodeWithSelector(IERC20.balanceOf.selector, account),
            op,
            balanceThreshold
        );
        (yesVaultShares, noVaultShares) =
            _addVaultDeposits(marketId, collateral, vault, to, deadline);
        _processBids(marketId, collateral, bids, to);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap price market
    function bootstrapPriceMarket(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address priceFeed,
        IResolver.Op op,
        uint256 priceThreshold
    ) public payable returns (uint256 marketId, uint256 poolId, uint256 lpShares) {
        _guardEnter();
        _prepareCollateral(collateral, collateralForLP, false);
        (marketId, poolId, lpShares,) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? collateralForLP : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            false,
            0,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(
            marketId,
            priceFeed,
            abi.encodeWithSelector(IChainlinkFeed.latestAnswer.selector),
            op,
            priceThreshold
        );

        _refundExcessETH(collateral, collateralForLP);
        _guardExit();
    }

    /// @notice Bootstrap price market with bids
    function bootstrapPriceMarketWithBids(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address priceFeed,
        IResolver.Op op,
        uint256 priceThreshold,
        BidOrder[] calldata bids
    ) public payable returns (uint256 marketId, uint256 poolId, uint256 lpShares) {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + _sumBidCollateral(bids);
        _prepareCollateral(collateral, totalCollateral, true);
        (marketId, poolId, lpShares,) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? collateralForLP : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            false,
            0,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(
            marketId,
            priceFeed,
            abi.encodeWithSelector(IChainlinkFeed.latestAnswer.selector),
            op,
            priceThreshold
        );
        _processBids(marketId, collateral, bids, to);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap price market + vault + optional initial buy
    function bootstrapPriceMarketWithVault(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address priceFeed,
        IResolver.Op op,
        uint256 priceThreshold,
        VaultParams calldata vault,
        InitialBuy calldata buy
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + vault.collateralForVault + buy.collateralForBuy;
        _prepareCollateral(collateral, totalCollateral, false);
        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(
            marketId,
            priceFeed,
            abi.encodeWithSelector(IChainlinkFeed.latestAnswer.selector),
            op,
            priceThreshold
        );
        (yesVaultShares, noVaultShares) =
            _addVaultDeposits(marketId, collateral, vault, to, deadline);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap price market + vault + bids
    function bootstrapPriceMarketWithVaultAndBids(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address priceFeed,
        IResolver.Op op,
        uint256 priceThreshold,
        VaultParams calldata vault,
        InitialBuy calldata buy,
        BidOrder[] calldata bids
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + vault.collateralForVault + buy.collateralForBuy
            + _sumBidCollateral(bids);
        _prepareCollateral(collateral, totalCollateral, true);
        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0,
            to,
            deadline
        );
        resolver.registerConditionForExistingMarket(
            marketId,
            priceFeed,
            abi.encodeWithSelector(IChainlinkFeed.latestAnswer.selector),
            op,
            priceThreshold
        );
        (yesVaultShares, noVaultShares) =
            _addVaultDeposits(marketId, collateral, vault, to, deadline);
        _processBids(marketId, collateral, bids, to);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    // ============ Price Range (BETWEEN) Markets ============

    /// @notice Bootstrap price range market (YES if price is between lower and upper bounds)
    /// @dev Creates market via PMHookRouter, registers BETWEEN condition with Resolver
    /// @param description Market description
    /// @param collateral Collateral token (address(0) for ETH)
    /// @param close Resolution timestamp
    /// @param hook Hook address for AMM
    /// @param collateralForLP Collateral for initial AMM liquidity
    /// @param to Recipient of LP shares
    /// @param deadline Transaction deadline
    /// @param priceFeed Chainlink price feed address
    /// @param lowerBound Lower price bound (inclusive)
    /// @param upperBound Upper price bound (inclusive)
    function bootstrapPriceRangeMarket(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address priceFeed,
        uint256 lowerBound,
        uint256 upperBound
    ) public payable returns (uint256 marketId, uint256 poolId, uint256 lpShares) {
        _guardEnter();
        _prepareCollateral(collateral, collateralForLP, false);
        (marketId, poolId, lpShares,) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? collateralForLP : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            false,
            0,
            0,
            to,
            deadline
        );
        resolver.registerBetweenConditionForExistingMarket(
            marketId,
            priceFeed,
            abi.encodeWithSelector(IChainlinkFeed.latestAnswer.selector),
            lowerBound,
            upperBound
        );

        _refundExcessETH(collateral, collateralForLP);
        _guardExit();
    }

    /// @notice Bootstrap price range market with orderbook bids
    function bootstrapPriceRangeMarketWithBids(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address priceFeed,
        uint256 lowerBound,
        uint256 upperBound,
        BidOrder[] calldata bids
    ) public payable returns (uint256 marketId, uint256 poolId, uint256 lpShares) {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + _sumBidCollateral(bids);
        _prepareCollateral(collateral, totalCollateral, true);
        (marketId, poolId, lpShares,) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? collateralForLP : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            false,
            0,
            0,
            to,
            deadline
        );
        resolver.registerBetweenConditionForExistingMarket(
            marketId,
            priceFeed,
            abi.encodeWithSelector(IChainlinkFeed.latestAnswer.selector),
            lowerBound,
            upperBound
        );
        _processBids(marketId, collateral, bids, to);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap price range market with vault deposits
    function bootstrapPriceRangeMarketWithVault(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address priceFeed,
        uint256 lowerBound,
        uint256 upperBound,
        VaultParams calldata vault,
        InitialBuy calldata buy
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + vault.collateralForVault + buy.collateralForBuy;
        _prepareCollateral(collateral, totalCollateral, false);
        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0,
            to,
            deadline
        );
        resolver.registerBetweenConditionForExistingMarket(
            marketId,
            priceFeed,
            abi.encodeWithSelector(IChainlinkFeed.latestAnswer.selector),
            lowerBound,
            upperBound
        );
        (yesVaultShares, noVaultShares) =
            _addVaultDeposits(marketId, collateral, vault, to, deadline);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    /// @notice Bootstrap price range market with vault deposits and orderbook bids
    function bootstrapPriceRangeMarketWithVaultAndBids(
        string calldata description,
        address collateral,
        uint64 close,
        address hook,
        uint256 collateralForLP,
        address to,
        uint256 deadline,
        address priceFeed,
        uint256 lowerBound,
        uint256 upperBound,
        VaultParams calldata vault,
        InitialBuy calldata buy,
        BidOrder[] calldata bids
    )
        public
        payable
        returns (
            uint256 marketId,
            uint256 poolId,
            uint256 lpShares,
            uint256 sharesOut,
            uint256 yesVaultShares,
            uint256 noVaultShares
        )
    {
        _guardEnter();
        uint256 totalCollateral = collateralForLP + vault.collateralForVault + buy.collateralForBuy
            + _sumBidCollateral(bids);
        _prepareCollateral(collateral, totalCollateral, true);
        (marketId, poolId, lpShares, sharesOut) = hookRouter.bootstrapMarket{
            value: collateral == ETH ? (collateralForLP + buy.collateralForBuy) : 0
        }(
            description,
            address(resolver),
            collateral,
            close,
            true,
            hook,
            collateralForLP,
            buy.buyYes,
            buy.collateralForBuy,
            0,
            to,
            deadline
        );
        resolver.registerBetweenConditionForExistingMarket(
            marketId,
            priceFeed,
            abi.encodeWithSelector(IChainlinkFeed.latestAnswer.selector),
            lowerBound,
            upperBound
        );
        (yesVaultShares, noVaultShares) =
            _addVaultDeposits(marketId, collateral, vault, to, deadline);
        _processBids(marketId, collateral, bids, to);
        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    // ============ Orderbook Liquidity ============

    /// @notice Add orderbook bid liquidity to an existing market
    /// @dev Can be used in multicall after bootstrapPriceMarket, or standalone
    /// @param marketId Market to add liquidity to
    /// @param collateral Collateral token (must match market's collateral)
    /// @param bids Array of bid orders to place
    /// @param to Recipient of bid positions
    function addOrderbookBids(
        uint256 marketId,
        address collateral,
        BidOrder[] calldata bids,
        address to
    ) public payable {
        _guardEnter();

        uint256 totalCollateral;
        for (uint256 i; i < bids.length; ++i) {
            totalCollateral += bids[i].amount;
        }

        if (collateral != ETH && totalCollateral != 0) {
            _safeTransferFrom(collateral, msg.sender, address(this), totalCollateral);
            _ensureApproval(collateral, address(masterRouter));
        }

        for (uint256 i; i < bids.length; ++i) {
            _createBidWithValidation(marketId, collateral, bids[i], to);
        }

        _refundExcessETH(collateral, totalCollateral);
        _guardExit();
    }

    // ============ View Helpers ============

    /// @notice Compute marketId for any resolver
    function computeMarketId(string calldata description, address resolverAddr, address collateral)
        public
        pure
        returns (uint256)
    {
        return PAMM.getMarketId(description, resolverAddr, collateral);
    }

    /// @notice Compute marketId using the Resolver constant
    function computeMarketIdResolver(string calldata description, address collateral)
        public
        pure
        returns (uint256)
    {
        return PAMM.getMarketId(description, address(resolver), collateral);
    }

    // ============ Internal Helpers ============

    /// @dev Prepare collateral: transfer from sender + approve routers
    function _prepareCollateral(address collateral, uint256 amount, bool needsMasterRouter)
        internal
    {
        if (collateral != ETH && amount != 0) {
            _safeTransferFrom(collateral, msg.sender, address(this), amount);
            _ensureApproval(collateral, address(hookRouter));
            if (needsMasterRouter) _ensureApproval(collateral, address(masterRouter));
        }
    }

    /// @dev Add vault deposits via provideLiquidity
    function _addVaultDeposits(
        uint256 marketId,
        address collateral,
        VaultParams calldata vault,
        address to,
        uint256 deadline
    ) internal returns (uint256 yesVaultShares, uint256 noVaultShares) {
        if (vault.collateralForVault != 0) {
            (yesVaultShares, noVaultShares,) = hookRouter.provideLiquidity{
                value: collateral == ETH ? vault.collateralForVault : 0
            }(
                marketId,
                vault.collateralForVault,
                vault.vaultYesShares,
                vault.vaultNoShares,
                0,
                0,
                0,
                to,
                deadline
            );
        }
    }

    /// @dev Sum collateral required for bids
    function _sumBidCollateral(BidOrder[] calldata bids) internal pure returns (uint256 total) {
        for (uint256 i; i < bids.length; ++i) {
            total += bids[i].amount;
        }
    }

    /// @dev Process all bids
    function _processBids(
        uint256 marketId,
        address collateral,
        BidOrder[] calldata bids,
        address to
    ) internal {
        for (uint256 i; i < bids.length; ++i) {
            _createBidWithValidation(marketId, collateral, bids[i], to);
        }
    }

    function _createBidWithValidation(
        uint256 marketId,
        address collateral,
        BidOrder calldata bid,
        address to
    ) internal {
        if (bid.amount == 0 || bid.priceInBps == 0) return;

        // Validate slippage: expectedShares = amount * 10000 / priceInBps
        if (bid.minShares != 0) {
            uint256 expectedShares = (bid.amount * 10000) / bid.priceInBps;
            if (expectedShares < bid.minShares) {
                assembly ("memory-safe") {
                    mstore(0x00, ERR_VALIDATION)
                    mstore(0x04, 3) // error code 3 = slippage
                    revert(0x00, 0x24)
                }
            }
        }

        masterRouter.createBidPool{value: collateral == ETH ? bid.amount : 0}(
            marketId, bid.amount, bid.buyYes, bid.priceInBps, to
        );
    }

    function _refundExcessETH(address collateral, uint256 amountUsed) internal {
        if (collateral == ETH) {
            assembly ("memory-safe") {
                if iszero(tload(MULTICALL_DEPTH_SLOT)) {
                    if gt(callvalue(), amountUsed) {
                        if iszero(
                            call(
                                gas(),
                                caller(),
                                sub(callvalue(), amountUsed),
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

    function _ensureApproval(address token, address spender) internal {
        assembly ("memory-safe") {
            // Save free memory pointer (0x40) and scratch space (0x60) before overwriting
            let m := mload(0x40)
            let n := mload(0x60)

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
                        mstore(0x00, ERR_APPROVE)
                        revert(0x00, 0x04)
                    }
                }
            }

            // Restore free memory pointer and scratch space
            mstore(0x40, m)
            mstore(0x60, n)
        }
    }

    receive() external payable {}
}
