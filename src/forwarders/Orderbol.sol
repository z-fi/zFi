// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

/// @title Orderbol
/// @notice Stateless zRouter executor for creating funded Swapboard and
///         Dutchboard orders without making the router their owner.
///
/// @dev zRouter.snwap transfers the maker's input to this executor before the
///      call. Orderbol grants the deployment-bound board an exact, call-scoped
///      allowance and invokes its `...For` entry point. The board pulls from
///      Orderbol but records `maker`, so fill proceeds, cancellation rights,
///      and returned escrow all stay with the user.
///
///      The explicit maker does not need a second signature: it is not a source
///      of funds. A caller that names somebody else can only buy that address a
///      fully-funded order. Permit, Permit2, existing zRouter allowance,
///      wallet batching, and legacy approval remain funding choices at zRouter.
///
///      ERC-20 funding is prepared with `checkpoint` immediately before zRouter
///      transfers the lot here. Placement consumes that transient checkpoint
///      and requires the balance increase to equal the escrow exactly. Looking
///      only at this contract's total balance would let a later caller turn
///      donated or stranded tokens into an order they own; the checkpoint makes
///      pre-existing balances unavailable without introducing signatures.
contract Orderbol {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Deployment trust roots. Order creation has no token-output
    /// postcondition for zRouter to measure, so accepting an arbitrary board
    /// would let it consume the full escrow while returning a fake id.
    address public immutable swapboard;
    address public immutable dutchboard;

    uint256 constant REENTRANCY_GUARD_SLOT = 0x8c463a67;
    uint256 constant CHECKPOINT_SEED = 0x7a8bde8e;

    /// @dev Reverted from assembly by selector; declared so the ABI carries them.
    error Reentrancy();
    error ETHTransferFailed();

    error BadOrder();
    error DeadlineExpired();
    error InputMismatch(uint256 expected, uint256 actual);

    constructor(address swapboard_, address dutchboard_) {
        if (
            swapboard_ == address(0) || dutchboard_ == address(0) || swapboard_ == dutchboard_
                || swapboard_.code.length == 0 || dutchboard_.code.length == 0
        ) revert BadOrder();
        swapboard = swapboard_;
        dutchboard = dutchboard_;
    }

    /// @notice Snapshot an ERC-20 balance immediately before funding.
    /// @dev The same immediate caller must consume this checkpoint in the same
    ///      transaction. It is transient, single-use, and cleared before either
    ///      the token or a board receives control.
    function checkpoint(address token) external {
        if (token == address(0) || token.code.length == 0) revert BadOrder();
        bytes32 slot = _checkpointSlot(token);
        uint256 active;
        assembly ("memory-safe") {
            active := tload(slot)
        }
        if (active != 0) revert BadOrder();
        uint256 tokenBalance = balanceOf(token);
        assembly ("memory-safe") {
            tstore(slot, 1)
            tstore(add(slot, 1), tokenBalance)
        }
    }

    /// @notice Create a fungible current-Swapboard order.
    /// @param tokenA address(0) means native ETH; the board wraps it to WETH.
    /// @param deadline Optional placement deadline; zero disables it.
    function placeSwapboard(
        address board,
        address maker,
        address refundTo,
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        bool partialFill,
        uint64 expiry,
        address counterparty,
        uint256 deadline
    ) external payable returns (uint256 orderId) {
        _enter();
        uint256 ethBase = address(this).balance - msg.value;
        if (
            board != swapboard || maker == address(0) || maker == address(this) || maker == WETH
                || refundTo == address(0) || refundTo == address(this) || refundTo == WETH
                || refundTo == swapboard || refundTo == dutchboard || amountA == 0 || amountB == 0
                || tokenB == address(0) || tokenB.code.length == 0
        ) revert BadOrder();
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();

        address escrowToken = tokenA == address(0) ? WETH : tokenA;
        if (escrowToken == tokenB || (tokenA != address(0) && tokenA.code.length == 0)) revert BadOrder();

        if (tokenA == address(0)) {
            if (msg.value != amountA) revert InputMismatch(amountA, msg.value);
            orderId = IRelayedSwapboard(swapboard).createOrderWithEthFor{value: amountA}(
                maker, tokenB, amountB, partialFill, expiry, false, counterparty
            );
            _checkSwapboardOrder(orderId, maker, WETH, amountA, tokenB, amountB, partialFill, expiry, counterparty);
        } else {
            if (msg.value != 0) revert InputMismatch(0, msg.value);
            uint256 base = _consumeFunding(tokenA, amountA);
            safeApprove(tokenA, swapboard, amountA);
            orderId = IRelayedSwapboard(swapboard)
                .createOrderFor(
                    maker, tokenA, amountA, tokenB, amountB, partialFill, expiry, false, false, counterparty
                );
            safeApprove(tokenA, swapboard, 0);
            uint256 actual = balanceOf(tokenA);
            if (actual != base) revert InputMismatch(base, actual);
            _checkSwapboardOrder(orderId, maker, tokenA, amountA, tokenB, amountB, partialFill, expiry, counterparty);
        }

        _sweepETH(refundTo, ethBase);
        _leave();
    }

    /// @notice Create a fungible Dutchboard listing.
    /// @param token address(0) means native ETH, wrapped here to canonical WETH
    ///              before the board escrows it.
    /// @param deadline Optional placement deadline; zero disables it.
    function placeDutch(
        address board,
        address seller,
        address refundTo,
        address token,
        address quote,
        uint128 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration,
        uint256 deadline
    ) external payable returns (uint256 listingId) {
        _enter();
        uint256 ethBase = address(this).balance - msg.value;
        if (
            board != dutchboard || seller == address(0) || seller == address(this) || seller == WETH
                || refundTo == address(0) || refundTo == address(this) || refundTo == WETH
                || refundTo == swapboard || refundTo == dutchboard || amount == 0
        ) {
            revert BadOrder();
        }
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();

        if (startPrice == 0 || startPrice < endPrice || startPrice > type(uint96).max || endPrice > type(uint96).max) {
            revert BadOrder();
        }
        if (duration == 0 || (startTime != 0 && startTime < block.timestamp)) revert BadOrder();
        if (token != address(0) && token.code.length == 0) revert BadOrder();
        if (quote != address(0) && quote.code.length == 0) revert BadOrder();
        address escrowToken = token == address(0) ? WETH : token;
        if (escrowToken == quote) revert BadOrder();

        uint256 escrowBase;
        if (token == address(0)) {
            if (msg.value != amount) revert InputMismatch(amount, msg.value);
            escrowBase = balanceOf(WETH);
            IWETH(WETH).deposit{value: amount}();
            uint256 received = balanceOf(WETH) - escrowBase;
            if (received != amount) revert InputMismatch(amount, received);
            escrowToken = WETH;
        } else {
            if (msg.value != 0) revert InputMismatch(0, msg.value);
            escrowBase = _consumeFunding(token, amount);
        }

        safeApprove(escrowToken, board, amount);
        listingId = IRelayedDutchboard(dutchboard)
            .listERC20For(seller, escrowToken, quote, amount, startPrice, endPrice, startTime, duration);
        safeApprove(escrowToken, dutchboard, 0);

        uint256 actual = balanceOf(escrowToken);
        if (actual != escrowBase) revert InputMismatch(escrowBase, actual);
        _checkDutchListing(listingId, seller, escrowToken, quote, amount, startPrice, endPrice, startTime, duration);
        _sweepETH(refundTo, ethBase);
        _leave();
    }

    function _consumeFunding(address token, uint256 amount) internal returns (uint256 base) {
        bytes32 slot = _checkpointSlot(token);
        uint256 active;
        assembly ("memory-safe") {
            active := tload(slot)
            base := tload(add(slot, 1))
            tstore(slot, 0)
            tstore(add(slot, 1), 0)
        }
        if (active == 0) revert BadOrder();
        uint256 current = balanceOf(token);
        if (current < base) revert BadOrder();
        uint256 funded = current - base;
        if (funded != amount) revert InputMismatch(amount, funded);
    }

    function _checkSwapboardOrder(
        uint256 orderId,
        address maker,
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        bool partialFill,
        uint64 expiry,
        address counterparty
    ) internal view {
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        IRelayedSwapboardView.Order[] memory orders = IRelayedSwapboardView(swapboard).getOrders(ids);
        if (orders.length != 1) revert BadOrder();
        IRelayedSwapboardView.Order memory o = orders[0];
        if (
            !o.active || o.maker != maker || o.tokenA != tokenA || o.amountA != amountA || o.tokenB != tokenB
                || o.amountB != amountB || o.partialFill != partialFill || o.expiry != expiry || o.nftA || o.nftB
                || o.counterparty != counterparty
        ) revert BadOrder();
    }

    function _checkDutchListing(
        uint256 listingId,
        address seller,
        address token,
        address quote,
        uint128 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration
    ) internal view {
        IRelayedDutchboardView.ListingView memory l = IRelayedDutchboardView(dutchboard).getListing(listingId);
        if (
            l.id != listingId || l.seller != seller || l.token != token || l.quote != quote || l.isNFT
                || l.duration != duration || l.startPrice != startPrice || l.endPrice != endPrice || l.initial != amount
                || l.remaining != amount || l.ids.length != 0
                || l.startTime != (startTime == 0 ? uint40(block.timestamp) : startTime)
        ) revert BadOrder();
    }

    function _checkpointSlot(address token) internal view returns (bytes32 slot) {
        uint256 seed = CHECKPOINT_SEED;
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(0x00, caller())
            mstore(0x20, token)
            mstore(0x40, seed)
            slot := keccak256(0x00, 0x60)
            mstore(0x40, free)
        }
    }

    /// @dev Forced or previously donated ETH is never part of the current
    ///      routed order. Only value created/refunded during this call may move.
    function _sweepETH(address to, uint256 base) internal {
        uint256 current = address(this).balance;
        if (current < base) revert InputMismatch(base, current);
        uint256 amount = current - base;
        if (amount == 0) return;
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
                revert(0x1c, 0x04)
            }
        }
    }

    function _enter() internal {
        assembly ("memory-safe") {
            if tload(REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_GUARD_SLOT, 1)
        }
    }

    function _leave() internal {
        assembly ("memory-safe") {
            tstore(REENTRANCY_GUARD_SLOT, 0)
        }
    }

    receive() external payable {}
}

interface IRelayedSwapboard {
    function createOrderFor(
        address maker,
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        bool partialFill,
        uint64 expiry,
        bool nftA,
        bool nftB,
        address counterparty
    ) external returns (uint256 orderId);

    function createOrderWithEthFor(
        address maker,
        address tokenB,
        uint256 amountB,
        bool partialFill,
        uint64 expiry,
        bool nftB,
        address counterparty
    ) external payable returns (uint256 orderId);
}

interface IRelayedSwapboardView {
    struct Order {
        address maker;
        bool active;
        bool partialFill;
        uint64 expiry;
        bool nftA;
        bool nftB;
        address counterparty;
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
    }

    function getOrders(uint256[] calldata orderIds) external view returns (Order[] memory);
}

interface IRelayedDutchboard {
    function listERC20For(
        address seller,
        address token,
        address quote,
        uint128 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration
    ) external returns (uint256 id);
}

interface IRelayedDutchboardView {
    struct ListingView {
        uint256 id;
        address seller;
        address token;
        address quote;
        bool isNFT;
        uint40 startTime;
        uint40 duration;
        uint96 startPrice;
        uint96 endPrice;
        uint128 initial;
        uint128 remaining;
        uint256[] ids;
        uint256 price;
    }

    function getListing(uint256 id) external view returns (ListingView memory);
}

interface IWETH {
    function deposit() external payable;
}

error ApproveFailed();

function safeApprove(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0x095ea7b3000000000000000000000000)

        if amount {
            mstore(0x34, 0)
            let reset := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), reset)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), reset)) {
                    mstore(0x00, 0x3e3f8f73)
                    revert(0x1c, 0x04)
                }
            }
        }

        mstore(0x34, amount)
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

function balanceOf(address token) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, address())
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(mload(0x20), and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20)))
    }
}
