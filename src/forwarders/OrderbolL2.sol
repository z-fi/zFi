// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

/// @title OrderbolL2
/// @notice Stateless zRouter executor for creating funded Swapboard orders,
///         Dutchboard listings and Floorboard bids without making the router
///         their owner.
///
/// @dev All three boards are opened through the same funding waterfall - permit,
///      Permit2, an existing zRouter allowance, wallet batching, or a plain
///      approval - rather than one of them needing a direct wallet approval to
///      the board while the other two go through zRouter.
///
///      A bid escrows the PAYMENT, not the lot, which is the one structural
///      difference the funding path has to respect: the amount transferred here
///      is `endPrice` in the quote asset - the most the bid can ever owe - and
///      not anything derived from `want`. See `placeFloor`.
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
/// @dev L2 VARIANT. Identical to Orderbol except that the canonical WETH is an
///      immutable constructor argument rather than a source constant, so one
///      source serves every chain the boards are mirrored to. Mainnet keeps the
///      original Orderbol, whose deployed bytecode still reproduces from its
///      own source; nothing here is meant to replace it there.
///
contract OrderbolL2 {
    /// @dev Canonical WETH of the chain this instance is deployed on.
    address public immutable WETH;

    /// @dev Deployment trust roots. Order creation has no token-output
    /// postcondition for zRouter to measure, so accepting an arbitrary board
    /// would let it consume the full escrow while returning a fake id.
    address public immutable swapboard;
    address public immutable dutchboard;
    address public immutable floorboard;

    uint256 constant REENTRANCY_GUARD_SLOT = 0x8c463a67;
    uint256 constant CHECKPOINT_SEED = 0x7a8bde8e;

    /// @dev Reverted from assembly by selector; declared so the ABI carries them.
    error Reentrancy();
    error ETHTransferFailed();

    error BadOrder();
    error DeadlineExpired();
    error InputMismatch(uint256 expected, uint256 actual);

    /// @dev Every board must be a distinct, deployed contract. A pairwise loop
    ///      rather than a flat conjunction: a third binding takes that from one
    ///      comparison to three, which is where a hand-written chain starts
    ///      silently missing one.
    constructor(address swapboard_, address dutchboard_, address floorboard_, address weth_) {
        if (weth_ == address(0) || weth_.code.length == 0) revert BadOrder();
        WETH = weth_;
        address[3] memory boards = [swapboard_, dutchboard_, floorboard_];
        for (uint256 i; i < 3; ++i) {
            if (boards[i] == address(0) || boards[i].code.length == 0) revert BadOrder();
            for (uint256 j = i + 1; j < 3; ++j) {
                if (boards[i] == boards[j]) revert BadOrder();
            }
        }
        swapboard = swapboard_;
        dutchboard = dutchboard_;
        floorboard = floorboard_;
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
                || refundTo == swapboard || refundTo == dutchboard || refundTo == floorboard || amountA == 0 || amountB == 0
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
    /// @param expiry Hard stop on the fill window, or 0 to rest at the floor
    ///               forever. THIS USED TO BE HARDCODED TO ZERO. Dutchboard has
    ///               always taken it - the struct stores it, `_checkExpiry`
    ///               validates it, `_isExpired` enforces it - and this adapter
    ///               simply had nowhere to put one, so every lot placed through
    ///               it rested forever whether or not the seller meant to.
    ///
    ///               That is the wrong default to be unable to change. A Dutch
    ///               lot is the one order whose premise is that time changes
    ///               what the seller will accept, and it was the only one that
    ///               could not be given an end - while a fixed Swapboard order,
    ///               which commits to a single price, could. A standing offer at
    ///               a stale floor is what gets picked off after a price move.
    ///
    ///               Zero remains meaningful and remains the resting behaviour,
    ///               so a caller that wants it asks for it.
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
        uint40 expiry,
        uint256 deadline
    ) external payable returns (uint256 listingId) {
        _enter();
        uint256 ethBase = address(this).balance - msg.value;
        if (
            board != dutchboard || seller == address(0) || seller == address(this) || seller == WETH
                || refundTo == address(0) || refundTo == address(this) || refundTo == WETH
                || refundTo == swapboard || refundTo == dutchboard || refundTo == floorboard || amount == 0
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

        // `dutchboard`, not `board`: they are provably equal (the guard above
        // reverts otherwise), but naming the immutable on both the grant and the
        // revoke keeps the scoped-allowance argument readable from one line
        // rather than from two lines plus a check thirty lines up.
        safeApprove(escrowToken, dutchboard, amount);
        listingId = IRelayedDutchboard(dutchboard)
            .listERC20For(seller, escrowToken, quote, amount, startPrice, endPrice, startTime, duration, expiry);
        safeApprove(escrowToken, dutchboard, 0);

        uint256 actual = balanceOf(escrowToken);
        if (actual != escrowBase) revert InputMismatch(escrowBase, actual);
        _checkDutchListing(listingId, seller, escrowToken, quote, amount, startPrice, endPrice, startTime, duration, expiry);
        _sweepETH(refundTo, ethBase);
        _leave();
    }

    /// @notice Create a fungible Floorboard bid.
    /// @dev The escrow is `endPrice` in `quote` - the ceiling of the climb, and
    ///      the most the bid can ever owe - NOT a function of `want`. Sizing the
    ///      transfer off `want` or `startPrice` is the one mistake this entry
    ///      point exists to make impossible for a caller: the board would revert
    ///      on the shortfall, but only after the route had already been funded.
    ///
    ///      `bidder` IS A GIFT RECIPIENT, exactly as on `Floorboard.bidFor`. The
    ///      caller pays the whole escrow and keeps no claim on it: the bidder
    ///      holds the receipt, every refund path pays the holder, and they may
    ///      cancel in the next block and keep all of it. A frontend must present
    ///      a `bidder` other than the payer as "fund a bid for X and hand X the
    ///      money", never as "bid on X's behalf".
    /// @param quote address(0) means native ETH; the board wraps it to canonical
    ///              WETH, and the bid is WETH-quoted from the moment it opens.
    /// @param deadline Optional placement deadline; zero disables it.
    function placeFloor(
        address board,
        address bidder,
        address refundTo,
        address token,
        address quote,
        uint128 want,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration,
        uint256 deadline
    ) external payable returns (uint256 bidId) {
        _enter();
        uint256 ethBase = address(this).balance - msg.value;
        // Eleven parameters is one more than this frame can hold alongside the
        // call and its checks, so the terms are built FIRST and everything
        // downstream reads them from memory. Passing the flat list on to the
        // guard and the verifier instead is what put this one slot too deep.
        IRelayedFloorboard.Terms memory terms = IRelayedFloorboard.Terms({
            token: token,
            quote: quote,
            want: want,
            startPrice: startPrice,
            endPrice: endPrice,
            startTime: startTime,
            duration: duration,
            isNFT: false,
            ids: new uint256[](0)
        });
        _checkFloorTerms(board, bidder, refundTo, deadline, terms);

        if (terms.quote == address(0)) {
            // The board does the wrapping here, unlike `placeDutch` where the
            // escrow is the lot and has to arrive as a token. It demands the
            // exact ceiling as value and refunds nothing, so pass it straight
            // through rather than sweeping a remainder that cannot exist.
            if (msg.value != terms.endPrice) revert InputMismatch(terms.endPrice, msg.value);
            bidId = IRelayedFloorboard(floorboard).bidFor{value: terms.endPrice}(bidder, terms);
        } else {
            if (msg.value != 0) revert InputMismatch(0, msg.value);
            uint256 base = _consumeFunding(terms.quote, terms.endPrice);
            safeApprove(terms.quote, floorboard, terms.endPrice);
            bidId = IRelayedFloorboard(floorboard).bidFor(bidder, terms);
            safeApprove(terms.quote, floorboard, 0);
            uint256 actual = balanceOf(terms.quote);
            if (actual != base) revert InputMismatch(base, actual);
        }

        _checkFloorBid(bidId, bidder, terms);
        _sweepETH(refundTo, ethBase);
        _leave();
    }

    function _checkFloorTerms(
        address board,
        address bidder,
        address refundTo,
        uint256 deadline,
        IRelayedFloorboard.Terms memory t
    ) internal view {
        if (
            board != floorboard || bidder == address(0) || bidder == address(this) || bidder == WETH
                || refundTo == address(0) || refundTo == address(this) || refundTo == WETH
                || refundTo == swapboard || refundTo == dutchboard || refundTo == floorboard || t.want == 0
        ) {
            revert BadOrder();
        }
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();

        // The climb is NONDECREASING - the mirror of Dutchboard's decay, and the
        // one comparison that flips between `placeDutch` and this. Only the
        // ceiling has to fit the uint96 escrow width, because it IS the escrow.
        if (t.startPrice == 0 || t.endPrice < t.startPrice || t.endPrice > type(uint96).max) revert BadOrder();
        if (t.duration == 0 || (t.startTime != 0 && t.startTime < block.timestamp)) revert BadOrder();
        if (t.token == address(0) || t.token.code.length == 0) revert BadOrder();
        if (t.quote != address(0) && t.quote.code.length == 0) revert BadOrder();
        if (_escrowOf(t) == t.token) revert BadOrder();
    }

    /// @dev An ETH-quoted bid is WETH-quoted the moment it opens, so the escrow
    ///      token is what the board will actually hold, not what was asked for.
    function _escrowOf(IRelayedFloorboard.Terms memory t) internal view returns (address) {
        return t.quote == address(0) ? WETH : t.quote;
    }

    function _checkFloorBid(uint256 bidId, address bidder, IRelayedFloorboard.Terms memory t) internal view {
        IRelayedFloorboardView.BidView memory b = IRelayedFloorboardView(floorboard).getBid(bidId);
        if (
            b.id != bidId || b.bidder != bidder || b.token != t.token || b.quote != _escrowOf(t) || b.isNFT
                || b.duration != t.duration || b.startPrice != t.startPrice || b.endPrice != t.endPrice
                || b.locked != t.endPrice || b.initial != t.want || b.remaining != t.want || b.ids.length != 0
                || b.startTime != (t.startTime == 0 ? uint40(block.timestamp) : t.startTime)
        ) revert BadOrder();
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
        uint40 duration,
        uint40 expiry
    ) internal view {
        IRelayedDutchboardView.ListingView memory l = IRelayedDutchboardView(dutchboard).getListing(listingId);
        if (
            l.id != listingId || l.seller != seller || l.token != token || l.quote != quote || l.isNFT
                || l.duration != duration || l.startPrice != startPrice || l.endPrice != endPrice || l.initial != amount
                || l.remaining != amount || l.ids.length != 0 || l.expiry != expiry
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
    /// @dev Dutchboard's shorter overloads were removed - the optimizer inlined
    ///      the whole listing body into each of them, which is what put the
    ///      contract over EIP-170. `expiry == 0` is the resting-floor behaviour
    ///      this relay has always created.
    function listERC20For(
        address seller,
        address token,
        address quote,
        uint128 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration,
        uint40 expiry
    ) external returns (uint256 id);
}

interface IRelayedDutchboardView {
    /// @dev MUST match `Dutchboard.ListingView` field for field. `ids` is a
    ///      dynamic array, so the struct is ABI-encoded with an offset head: a
    ///      missing field does not read as zero, it shifts every later field by
    ///      one word and decodes an offset as data. This copy had fallen two
    ///      fields behind (`expiry`, `takeable`), which made `_checkDutchListing`
    ///      compare `ids.length` against a misaligned word.
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
        uint40 expiry;
        uint256[] ids;
        uint256 price;
        bool takeable;
    }

    function getListing(uint256 id) external view returns (ListingView memory);
}

interface IRelayedFloorboard {
    /// @dev MUST match `Floorboard.Terms` field for field and in order.
    struct Terms {
        address token;
        address quote;
        uint128 want;
        uint256 startPrice;
        uint256 endPrice;
        uint40 startTime;
        uint40 duration;
        bool isNFT;
        uint256[] ids;
    }

    function bidFor(address bidder, Terms calldata terms) external payable returns (uint256 id);
}

interface IRelayedFloorboardView {
    /// @dev MUST match `Floorboard.BidView` field for field. `ids` is a dynamic
    ///      array, so the struct is ABI-encoded with an offset head: a missing
    ///      field does not read as zero, it shifts every later field by one word
    ///      and decodes an offset as data. This is the bug the Dutchboard copy
    ///      below carried for two fields; keep the two structs in lockstep with
    ///      their originals whenever either board changes.
    struct BidView {
        uint256 id;
        address bidder;
        address token;
        address quote;
        bool isNFT;
        uint40 startTime;
        uint40 duration;
        uint96 startPrice;
        uint96 endPrice;
        uint96 locked;
        uint128 initial;
        uint128 remaining;
        uint256[] ids;
        uint256 price;
        bool takeable;
    }

    function getBid(uint256 id) external view returns (BidView memory);
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

        // USDT-style tokens require a zero transition before a new nonzero
        // allowance. Clearing first preserves the call-scoped allowance model
        // while remaining compatible with that common approval convention.
        if amount {
            mstore(0x34, 0)
            let reset := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), reset)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), reset)) {
                    mstore(0x00, 0x3e3f8f73)
                    revert(0x1c, 0x04)
                }
            }
            // The reset call wrote its return data over 0x00..0x20, and the
            // calldata being reused lives at 0x10..0x54 - so that write lands
            // on the selector. Without rebuilding it here the approve below
            // ships whatever the reset returned as its selector, which is why
            // this path failed against every ordinary ERC-20 rather than only
            // the USDT-style tokens it exists for.
            mstore(0x14, to)
            mstore(0x00, 0x095ea7b3000000000000000000000000)
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
