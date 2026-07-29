// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {Multicallable} from "../lib/solady/src/utils/Multicallable.sol";
import {SafeTransferLib} from "../lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "../lib/solady/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "../lib/solady/src/utils/ReentrancyGuardTransient.sol";

/// @title Swapboard
/// @notice Escrowed peer-to-peer orders. Either side may be an ERC-20 or an
///         ERC-721, with optional partial fills, an optional maker-side expiry
///         and an optional named counterparty.
///
/// @dev Extends the audited Swapboard deployed by the Ethereum Community
///      Foundation (0x000000fF3D7A2d373615141d7489Ca66683DbecF). The escrow
///      model is unchanged: a maker deposits tokenA on creation, a taker pays
///      tokenB on fill, and cancellation returns the remainder. Everything
///      below is what this adds, and what each addition costs.
///
/// EXPIRY
///   An order without a lifetime is a free option written to the market: the
///   escrow rests at a fixed price, and if the market moves, anyone may take
///   the stale side until the maker pays gas to cancel. `expiry` bounds that.
///   0 means never expires, preserving the original behaviour by default.
///
///   Note this is distinct from the `deadline` argument carried on every fill,
///   which is a TAKER-side guard against a stale mempool transaction and says
///   nothing about how long the order rests.
///
/// PARTIAL FILLS
///   A taker may take part of an order when the maker allows it, leaving the
///   remainder resting. Amounts divide with full-precision mulDiv rounding
///   toward the maker, and a fill too small to move any tokenA is rejected.
///   Partial fills are what make this a limit book rather than an OTC board,
///   and expiry is what makes them safe: a remainder cannot rest indefinitely.
///
/// NFT SIDES
///   `nftA` / `nftB` mark a side as an ERC-721, where the matching amount is a
///   tokenId. tokenId 0 is legitimate, so the zero-amount check is skipped for
///   that side. Partial fills are refused whenever either side is an NFT,
///   because an ERC-721 is indivisible.
///
///   NFTs move with transferFrom, never safeTransferFrom. safeTransferFrom
///   invokes onERC721Received on a contract recipient, opening a callback into
///   the middle of settlement and locking out any contract taker that does not
///   implement the hook. Storage is written before every transfer and every
///   entry point is nonReentrant, so the callback buys nothing here. Escrow
///   coming in is pulled with transferFrom and then confirmed with ownerOf,
///   which is stronger than trusting a return value.
///
/// PRIVATE ORDERS
///   `counterparty` restricts a fill to one address; 0 leaves the order public.
///
/// RECIPIENT
///   Every fill takes a `recipient`, so an aggregator can settle straight to
///   its user instead of receiving and forwarding. It is a delivery address and
///   never authorisation: `counterparty` is still tested against msg.sender,
///   because a caller-supplied recipient could otherwise be set to the intended
///   counterparty and drain every private order. The consequence is that
///   private orders are direct-fill only and cannot be routed.
///
/// SWEEPING
///   Expired orders may be swept by anyone. Escrow always returns to the maker,
///   so nothing is capturable; it exists so funds are never stranded behind an
///   absent maker. cancelExpired is strict, trySweepExpired skips what it
///   cannot settle - a keeper's list is read before it is mined, and anything
///   filled in between would otherwise abort the whole batch.
///
/// BATCHING
///   Typed batch entry points cover the common cases: createOrders, fillOrders,
///   tryFillOrders, cancelOrders, cancelExpired, trySweepExpired. multicall
///   covers the rest by composing them in one transaction - repricing, for
///   instance, is cancelOrder followed by createOrder, which no single entry
///   point expresses. Every entry point is nonReentrant and the guard clears
///   between sub-calls, so they compose in sequence.
///
///   multicall refuses a non-zero msg.value, since forwarding one value to
///   several calls would let it be spent more than once. The payable paths
///   (createOrderWithEth, fillOrderWithEth) are therefore outside it: reprice a
///   WETH order with cancelOrder + createOrder rather than the unwrap variants.
///
/// STORAGE
///   maker(160) + active(8) + partialFill(8) + expiry(64) + nftA(8) + nftB(8)
///   is exactly 256 bits, so expiry and both NFT flags cost no extra storage.
///   `counterparty` cannot fit a remaining gap (the widest is 96 bits) and
///   takes a slot of its own, paid only by orders that use it.
contract Swapboard is ReentrancyGuardTransient, Multicallable {
    using SafeTransferLib for address;

    /// @dev maker/active/partialFill/expiry/nftA/nftB fill slot 0 exactly.
    ///      For an NFT side the matching amount is a tokenId, so tokenId 0 is
    ///      legitimate and the zero-amount check is skipped for that side.
    struct Order {
        address maker;
        bool active;
        bool partialFill;
        uint64 expiry; // 0 = never expires
        bool nftA;
        bool nftB;
        address counterparty; // 0 = anyone may fill
        address tokenA;
        uint256 amountA; // tokenId when nftA
        address tokenB;
        uint256 amountB; // tokenId when nftB
    }

    struct CreateOrderParams {
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
        bool partialFill;
        uint64 expiry;
        bool nftA;
        bool nftB;
        address counterparty;
    }

    address public immutable weth;
    uint256 public nextOrderId;
    mapping(uint256 orderId => Order order) public orders;

    event OrderCreated(
        uint256 indexed orderId,
        address indexed maker,
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        bool partialFill,
        uint64 expiry,
        bool nftA,
        bool nftB,
        address counterparty
    );
    event OrderFilled(
        uint256 indexed orderId, address indexed taker, address indexed maker, uint256 amountA, uint256 amountB
    );
    event OrderPartiallyFilled(
        uint256 indexed orderId,
        address indexed taker,
        address indexed maker,
        uint256 amountA,
        uint256 amountB,
        uint256 remainingA,
        uint256 remainingB
    );
    event OrderCanceled(uint256 indexed orderId, address indexed maker);
    event OrderExpiredSwept(uint256 indexed orderId, address indexed maker, address indexed caller);

    error ZeroETH();
    error SameToken();
    error ZeroAmount();
    error ZeroAddress();
    error BadRecipient();
    error LengthMismatch();
    error ZeroFillAmount();
    error DeadlineExpired();
    error NFTNotDivisible();
    error ExpiryInPast(uint64 expiry);
    error NotAContract(address token);
    error OrderExpired(uint256 orderId);
    error OrderNotFound(uint256 orderId);
    error OrderNotActive(uint256 orderId);
    error OrderNotExpired(uint256 orderId);
    error PartialFillNotAllowed(uint256 orderId);
    error NotWETH(address expected, address actual);
    error NFTEscrowFailed(address token, uint256 tokenId);
    error ETHAmountMismatch(uint256 required, uint256 sent);
    error BalanceMismatch(uint256 expected, uint256 received);
    error NotMaker(uint256 orderId, address caller, address maker);
    error NotCounterparty(uint256 orderId, address caller, address counterparty);

    constructor(address _weth) payable {
        if (_weth == address(0)) revert ZeroAddress();
        if (_weth.code.length == 0) revert NotAContract(_weth);
        weth = _weth;
    }

    /// @dev Only WETH may push ETH here, via withdraw() during an unwrap.
    receive() external payable {
        if (msg.sender != weth) revert NotWETH(weth, msg.sender);
    }

    /// @dev Lets the board accept an ERC-721 sent with safeTransferFrom. Orders
    /// are escrowed with transferFrom, so this is only for robustness.
    /// @notice ERC-721 receiver hook, so the board can accept a direct
    ///         safeTransferFrom. Orders escrow with transferFrom, so this is
    ///         only for robustness.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ----------------------------------------------------------------- CREATE

    function createOrder(
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        bool partialFill,
        uint64 expiry,
        bool nftA,
        bool nftB,
        address counterparty
    ) external nonReentrant returns (uint256 orderId) {
        orderId = _createOrder(tokenA, amountA, tokenB, amountB, partialFill, expiry, nftA, nftB, counterparty);
    }

    /// @dev Atomic: if any creation reverts, the whole batch reverts.
    /// @notice Create several orders in one transaction.
    function createOrders(CreateOrderParams[] calldata params)
        external
        nonReentrant
        returns (uint256[] memory orderIds)
    {
        orderIds = new uint256[](params.length);
        for (uint256 i; i < params.length; ++i) {
            orderIds[i] = _createOrder(
                params[i].tokenA,
                params[i].amountA,
                params[i].tokenB,
                params[i].amountB,
                params[i].partialFill,
                params[i].expiry,
                params[i].nftA,
                params[i].nftB,
                params[i].counterparty
            );
        }
    }

    /// @dev tokenA is always WETH here, so nftA is necessarily false.
    function createOrderWithEth(
        address tokenB,
        uint256 amountB,
        bool partialFill,
        uint64 expiry,
        bool nftB,
        address counterparty
    ) external payable nonReentrant returns (uint256 orderId) {
        if (msg.value == 0) revert ZeroETH();
        if (tokenB == address(0)) revert ZeroAddress();
        if (!nftB && amountB == 0) revert ZeroAmount();
        if (nftB && partialFill) revert NFTNotDivisible();
        if (tokenB == weth) revert SameToken();
        if (tokenB.code.length == 0) revert NotAContract(tokenB);
        _checkExpiry(expiry);

        IWETH(weth).deposit{value: msg.value}();
        orderId = _store(msg.sender, weth, msg.value, tokenB, amountB, partialFill, expiry, false, nftB, counterparty);
    }

    function _createOrder(
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        bool partialFill,
        uint64 expiry,
        bool nftA,
        bool nftB,
        address counterparty
    ) internal returns (uint256 orderId) {
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        // tokenId 0 is a legitimate NFT, so only fungible sides are checked.
        if (!nftA && amountA == 0) revert ZeroAmount();
        if (!nftB && amountB == 0) revert ZeroAmount();
        // An ERC-721 cannot be split, so it cannot rest as a partial order.
        if ((nftA || nftB) && partialFill) revert NFTNotDivisible();
        if (tokenA == tokenB && !(nftA || nftB)) revert SameToken();
        if (tokenA.code.length == 0) revert NotAContract(tokenA);
        if (tokenB.code.length == 0) revert NotAContract(tokenB);
        _checkExpiry(expiry);

        if (nftA) {
            IERC721(tokenA).transferFrom(msg.sender, address(this), amountA);
            // Confirm custody rather than trust the call: a non-standard 721
            // could no-op and leave the order backed by nothing.
            if (IERC721(tokenA).ownerOf(amountA) != address(this)) {
                revert NFTEscrowFailed(tokenA, amountA);
            }
        } else {
            // A fee-on-transfer token would leave the escrow short of amountA,
            // so what actually arrived is measured rather than assumed.
            uint256 before = tokenA.balanceOf(address(this));
            tokenA.safeTransferFrom(msg.sender, address(this), amountA);
            unchecked {
                uint256 received = tokenA.balanceOf(address(this)) - before;
                if (received != amountA) revert BalanceMismatch(amountA, received);
            }
        }

        orderId = _store(msg.sender, tokenA, amountA, tokenB, amountB, partialFill, expiry, nftA, nftB, counterparty);
    }

    /// @dev An expiry already past would create an order nobody can fill and
    /// only the sweep can clear, so it is refused at creation.
    function _checkExpiry(uint64 expiry) internal view {
        if (expiry != 0 && expiry <= block.timestamp) revert ExpiryInPast(expiry);
    }

    function _store(
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
    ) internal returns (uint256 orderId) {
        unchecked {
            orderId = nextOrderId++;
        }
        orders[orderId] =
            Order(maker, true, partialFill, expiry, nftA, nftB, counterparty, tokenA, amountA, tokenB, amountB);
        emit OrderCreated(
            orderId, maker, tokenA, amountA, tokenB, amountB, partialFill, expiry, nftA, nftB, counterparty
        );
    }

    // ------------------------------------------------------------------- FILL

    /// @param recipient Where tokenA is delivered. address(0) means the caller.
    ///        This is a delivery address only - it is NEVER used for
    ///        authorisation. `counterparty` is still checked against msg.sender,
    ///        because a caller-supplied recipient could otherwise be set to the
    ///        intended counterparty and drain every private order.
    function fillOrder(uint256 orderId, uint256 deadline, uint256 fillAmountB, address recipient)
        external
        nonReentrant
    {
        _checkDeadline(deadline);
        _fill(orderId, fillAmountB, false, false, _to(recipient));
    }

    /// @dev Atomic: if any fill reverts, the whole batch reverts.
    /// @notice Fill several orders atomically; any failure aborts the batch.
    ///         Use tryFillOrders to skip rather than revert.
    function fillOrders(
        uint256[] calldata orderIds,
        uint256 deadline,
        uint256[] calldata fillAmountsB,
        address recipient
    ) external nonReentrant {
        _checkDeadline(deadline);
        if (orderIds.length != fillAmountsB.length) revert LengthMismatch();
        address to = _to(recipient);
        for (uint256 i; i < orderIds.length; ++i) {
            _fill(orderIds[i], fillAmountsB[i], false, false, to);
        }
    }

    /// @dev Skips orders that are inactive, missing, expired, or reserved for a
    /// different counterparty. Every other revert path still aborts the batch.
    function tryFillOrders(
        uint256[] calldata orderIds,
        uint256 deadline,
        uint256[] calldata fillAmountsB,
        address recipient
    ) external nonReentrant returns (bool[] memory filled) {
        _checkDeadline(deadline);
        if (orderIds.length != fillAmountsB.length) revert LengthMismatch();
        address to = _to(recipient);
        filled = new bool[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            Order storage o = orders[orderIds[i]];
            address cp = o.counterparty;
            if (o.active && !_expired(o.expiry) && (cp == address(0) || cp == msg.sender)) {
                _fill(orderIds[i], fillAmountsB[i], false, false, to);
                filled[i] = true;
            }
        }
    }

    /// @notice Fill and receive tokenA as ETH rather than WETH. Reverts unless
    ///         tokenA is WETH; ignored when tokenA is an NFT.
    function fillOrderUnwrap(uint256 orderId, uint256 deadline, uint256 fillAmountB, address recipient)
        external
        nonReentrant
    {
        _checkDeadline(deadline);
        _fill(orderId, fillAmountB, true, false, _to(recipient));
    }

    /// @dev msg.value is the fill amount and is wrapped before settlement, so a
    /// value above the remaining amountB is refused rather than refunded.
    ///
    /// The underpayment check is what makes this path safe. Everywhere else the
    /// taker's side is pulled during settlement, so _fill can round a short
    /// fillAmountB up to the full amountB and still charge for it. Here the
    /// payment already happened, at msg.value — so any order _fill treats as
    /// all-or-nothing (NFT on either side, or partialFill off) must arrive
    /// exactly paid, or _fill would settle the full amount out of WETH the board
    /// is holding as escrow for OTHER orders.
    function fillOrderWithEth(uint256 orderId, uint256 deadline, address recipient)
        external
        payable
        nonReentrant
    {
        _checkDeadline(deadline);
        if (msg.value == 0) revert ZeroETH();
        Order storage order = orders[orderId];
        if (order.tokenB != weth) revert NotWETH(weth, order.tokenB);
        // amountB is a tokenId when nftB, so it is not a price to pay in ETH and
        // the wrapped value would be stranded while the 721 leg pulled instead.
        if (order.nftB) revert NFTNotDivisible();
        uint256 owed = order.amountB;
        if (msg.value > owed) revert ETHAmountMismatch(owed, msg.value);
        if (msg.value < owed && (order.nftA || !order.partialFill)) {
            revert ETHAmountMismatch(owed, msg.value);
        }
        IWETH(weth).deposit{value: msg.value}();
        _fill(orderId, msg.value, false, true, _to(recipient));
    }

    function _fill(uint256 orderId, uint256 fillAmountB, bool unwrap, bool prepaid, address to) internal {
        Order storage order = orders[orderId];
        address maker = order.maker;
        if (maker == address(0)) revert OrderNotFound(orderId);
        if (!order.active) revert OrderNotActive(orderId);
        // Maker-side expiry. Distinct from the `deadline` argument above, which
        // guards the taker against a stale mempool transaction.
        if (_expired(order.expiry)) revert OrderExpired(orderId);

        address cp = order.counterparty;
        if (cp != address(0) && cp != msg.sender) revert NotCounterparty(orderId, msg.sender, cp);

        address tokenA = order.tokenA;
        address tokenB = order.tokenB;
        bool nftA = order.nftA;
        bool nftB = order.nftB;
        uint256 amountA = order.amountA;
        uint256 amountB = order.amountB;

        // amountB is a tokenId when nftB, so the >= comparison used to detect a
        // full fill is meaningless: require an exact match or the 0 sentinel.
        if (nftB && fillAmountB != 0 && fillAmountB != amountB) revert PartialFillNotAllowed(orderId);

        uint256 outA;
        bool full;
        if (nftA || nftB || fillAmountB == 0 || fillAmountB >= amountB) {
            order.active = false;
            order.amountA = 0;
            order.amountB = 0;
            (outA, fillAmountB, full) = (amountA, amountB, true);
        } else {
            if (!order.partialFill) revert PartialFillNotAllowed(orderId);
            // Rounds down, favouring the maker. Full precision so large
            // 18-decimal amounts cannot overflow the intermediate product.
            outA = FixedPointMathLib.fullMulDiv(fillAmountB, amountA, amountB);
            if (outA == 0) revert ZeroFillAmount();
            order.amountA = amountA - outA;
            order.amountB = amountB - fillAmountB;
        }

        // tokenB to the maker. On the ETH path it is already wrapped and held here.
        if (nftB) IERC721(tokenB).transferFrom(msg.sender, maker, fillAmountB);
        else if (prepaid) tokenB.safeTransfer(maker, fillAmountB);
        else tokenB.safeTransferFrom(msg.sender, maker, fillAmountB);

        // tokenA to the taker.
        if (nftA) {
            IERC721(tokenA).transferFrom(address(this), to, outA);
        } else if (unwrap) {
            if (tokenA != weth) revert NotWETH(weth, tokenA);
            IWETH(weth).withdraw(outA);
            to.safeTransferETH(outA);
        } else {
            tokenA.safeTransfer(to, outA);
        }

        if (full) emit OrderFilled(orderId, msg.sender, maker, outA, fillAmountB);
        else {
            emit OrderPartiallyFilled(orderId, msg.sender, maker, outA, fillAmountB, order.amountA, order.amountB);
        }
    }

    // ----------------------------------------------------------------- CANCEL

    /// @notice Maker-only. Returns the unfilled escrow and closes the order.
    function cancelOrder(uint256 orderId) external nonReentrant {
        _cancel(orderId, false);
    }

    /// @notice Maker-only, all-or-nothing: one bad id aborts the batch.
    function cancelOrders(uint256[] calldata orderIds) external nonReentrant {
        for (uint256 i; i < orderIds.length; ++i) {
            _cancel(orderIds[i], false);
        }
    }

    /// @notice Cancel and take the escrow back as ETH. Requires tokenA = WETH.
    function cancelOrderUnwrap(uint256 orderId) external nonReentrant {
        _cancel(orderId, true);
    }

    /// @notice Sweeps expired orders, returning each escrow to its maker.
    /// @dev Permissionless: funds go to the maker, so there is nothing to
    /// capture. It exists so an expired order's escrow is never stranded behind
    /// a maker who stopped watching, and so the book can be kept clean without
    /// the maker paying to tidy it.
    function cancelExpired(uint256[] calldata orderIds) external nonReentrant {
        for (uint256 i; i < orderIds.length; ++i) {
            uint256 orderId = orderIds[i];
            Order storage order = orders[orderId];
            address maker = order.maker;
            if (maker == address(0)) revert OrderNotFound(orderId);
            if (!order.active) revert OrderNotActive(orderId);
            if (!_expired(order.expiry)) revert OrderNotExpired(orderId);

            address tokenA = order.tokenA;
            uint256 amountA = order.amountA;
            bool nftA = order.nftA;
            order.active = false;
            order.amountA = 0;
            order.amountB = 0;

            if (nftA) IERC721(tokenA).transferFrom(address(this), maker, amountA);
            else tokenA.safeTransfer(maker, amountA);
            emit OrderExpiredSwept(orderId, maker, msg.sender);
        }
    }

    /// @notice Sweep variant that skips entries it cannot settle instead of
    ///         reverting the batch.
    /// @dev A keeper reads the sweepable set, then submits; anything filled or
    /// swept in between would abort an all-or-nothing sweep and clean nothing.
    /// Same reasoning as tryFillOrders. Returns which ids were actually swept.
    function trySweepExpired(uint256[] calldata orderIds) external nonReentrant returns (bool[] memory swept) {
        swept = new bool[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            uint256 orderId = orderIds[i];
            Order storage order = orders[orderId];
            address maker = order.maker;
            if (maker == address(0) || !order.active || !_expired(order.expiry)) continue;

            address tokenA = order.tokenA;
            uint256 amountA = order.amountA;
            bool nftA = order.nftA;
            order.active = false;
            order.amountA = 0;
            order.amountB = 0;

            if (nftA) IERC721(tokenA).transferFrom(address(this), maker, amountA);
            else tokenA.safeTransfer(maker, amountA);
            emit OrderExpiredSwept(orderId, maker, msg.sender);
            swept[i] = true;
        }
    }

    function _cancel(uint256 orderId, bool unwrap) internal {
        Order storage order = orders[orderId];
        address maker = order.maker;
        if (maker == address(0)) revert OrderNotFound(orderId);
        if (!order.active) revert OrderNotActive(orderId);
        if (msg.sender != maker) revert NotMaker(orderId, msg.sender, maker);

        address tokenA = order.tokenA;
        uint256 amountA = order.amountA;
        bool nftA = order.nftA;
        order.active = false;
        order.amountA = 0;
        order.amountB = 0;

        if (nftA) {
            IERC721(tokenA).transferFrom(address(this), maker, amountA);
        } else if (unwrap) {
            if (tokenA != weth) revert NotWETH(weth, tokenA);
            IWETH(weth).withdraw(amountA);
            maker.safeTransferETH(amountA);
        } else {
            tokenA.safeTransfer(maker, amountA);
        }
        emit OrderCanceled(orderId, maker);
    }

    // ------------------------------------------------------------------- VIEW

    /// @notice Batch read. Unknown ids come back zeroed rather than reverting,
    ///         so a stale id in a scan does not sink the whole page.
    function getOrders(uint256[] calldata orderIds) external view returns (Order[] memory out) {
        out = new Order[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            out[i] = orders[orderIds[i]];
        }
    }

    /// @notice True when `taker` may fill `orderId` right now.
    /// @dev Pass address(0) to ask only whether the order is live and public.
    function isFillableBy(uint256 orderId, address taker) external view returns (bool) {
        Order storage o = orders[orderId];
        if (o.maker == address(0) || !o.active || _expired(o.expiry)) return false;
        address cp = o.counterparty;
        return cp == address(0) || cp == taker;
    }

    /// @dev address(0) is shorthand for the caller. Two addresses are refused
    /// outright: the board itself, where a payout would be stranded in escrow
    /// accounting, and WETH, where an unwrapped payout would be re-wrapped to
    /// the board and lost. Both are user error rather than attack, but this is
    /// an immutable contract and neither mistake is recoverable.
    function _to(address recipient) internal view returns (address) {
        if (recipient == address(0)) return msg.sender;
        if (recipient == address(this) || recipient == weth) revert BadRecipient();
        return recipient;
    }

    function _expired(uint64 expiry) internal view returns (bool) {
        return expiry != 0 && block.timestamp > expiry;
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
    }
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IERC721 {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}
