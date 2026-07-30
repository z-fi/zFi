// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title Dutchboard
/// @notice Decaying, partially-fillable limit orders over an arbitrary pair. A maker
///         escrows a lot (an ERC20 amount, one NFT, or a bundle) and names the asset
///         they want paid in; the asking price decays linearly from `startPrice` to
///         `endPrice` and is flat outside that window. Takers fill at whatever the
///         schedule says at their block. Sellers can cancel and reclaim the unsold
///         remainder at any time.
///
/// @dev    Generalises DutchAuction, whose payment asset is always native ETH. That
///         restriction makes the most common retail limit order inexpressible: ETH can
///         only be the asset you receive, never the asset you pay, so "sell 10 ETH for
///         USDC at 4200" cannot be listed at all. Here `quote` is a parameter, and
///         `quote == address(0)` reproduces DutchAuction's ETH behaviour exactly.
///
///         WHY THIS AND NOT A DECAYING ORDER BOOK. The invariant that makes decay and
///         partial fills safe together is that unit price is a pure function of time:
///         `initial` is kept alongside `remaining` and every fill costs
///         `ceil(priceOf * take / initial)`, so no fill history can change what the
///         next taker pays. An order book that decrements the two sides of the pair in
///         place loses the reference ratio after its first partial fill and has nothing
///         left to reprice the remainder against.
///
///         PRICES ARE READ FROM A SCHEDULE, NEVER FROM A POOL. `_priceOf` is monotone
///         non-increasing and touches no external state, so a pending fill can never be
///         repriced against the taker and no amount of pool displacement moves the cost.
///         Anchoring the schedule to a live AMM quote at fill time would hand a filler
///         the ability to depress the quote, take the whole lot, and restore it; makers
///         anchor off-chain at listing time and relist to re-anchor.
///
///         STORAGE. uint96 prices are what make the extra `quote` address free:
///           slot 0  seller(160) + isNFT(8) + startTime(40) + duration(40)  = 248
///           slot 1  token(160)  + startPrice(96)                           = 256
///           slot 2  quote(160)  + endPrice(96)                             = 256
///           slot 3  initial(128) + remaining(128)                          = 256
///           slot 4  ids[]                                                  NFT only
///         Four slots plus the array — one fewer than DutchAuction spends without a
///         quote asset. The ceiling is ~7.9e28 base units of `quote` for a whole lot,
///         checked at listing rather than silently truncated.
///
///         The narrowing buys packing only, NOT overflow safety: DutchAuction's uint128
///         prices are already safe in the same expression, since
///         `(2^128-1)^2 + (2^128-1) - 1 == 2^256 - 2^128 - 1` clears the modulus.
///         See test/DutchAuctionCostBounds.t.sol, which pins that bound at the maxima.
///
///         Only plain ERC20s are supported for either leg. Exact balance-delta checks
///         reject fee-on-transfer and successful-looking no-op transfers; rebasing
///         tokens remain out of scope because custody is pooled between transactions.
contract Dutchboard {
    /// @dev Dutchboard is a mainnet primitive. Keeping the canonical wrapper as
    ///      a constant avoids introducing a deployment parameter solely for the
    ///      optional cancellation convenience.
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    struct Listing {
        address seller;
        bool isNFT;
        uint40 startTime;
        uint40 duration;
        address token; // what is being sold
        uint96 startPrice; // total for the full initial lot, in `quote`
        address quote; // what the seller is paid in; address(0) = native ETH
        uint96 endPrice;
        uint128 initial; // ERC20 only, 0 for NFT
        uint128 remaining; // ERC20 only, 0 for NFT
        uint256[] ids; // NFT only, empty for ERC20
    }

    /// @dev Flattened snapshot for frontends. `seller == address(0)` marks a slot that
    ///      never existed or has closed (cancelled / fully filled).
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

    uint256 public nextId;
    mapping(uint256 => Listing) public listings;

    event Created(uint256 indexed id, address indexed seller, address indexed token, address quote);
    event Filled(uint256 indexed id, address indexed seller, address indexed buyer, uint256 amount, uint256 paid);
    event Cancelled(uint256 indexed id);

    error Bad();
    error NotSeller();
    error Reentrancy();
    error Insufficient();
    error CostExceeded(uint256 cost, uint256 maxCost);
    error NotWETH(address expected, address actual);
    error NFTTransferFailed(address token, uint256 tokenId);
    error BalanceDeltaMismatch(address token, address account, uint256 expected, uint256 actual);

    /// @dev Transient-storage slot (EIP-1153) for the reentrancy guard. Requires a
    ///      Cancun-era EVM. Both legs can be caller-chosen contracts here — the lot
    ///      token, the quote token, an NFT receiver hook — so the guard is load-bearing,
    ///      not defensive: without it a hostile quote token could reenter `fill` mid
    ///      settlement. State is also written before every external call below, so a
    ///      reentrant read sees the post-fill remainder either way.
    uint256 constant _REENTRANCY_GUARD_SLOT = 0x929eee149b4bd21269;

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(_REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(_REENTRANCY_GUARD_SLOT, address())
        }
        _;
        assembly ("memory-safe") {
            tstore(_REENTRANCY_GUARD_SLOT, 0)
        }
    }

    /// @dev Only canonical WETH may deliver ETH through an ordinary empty call,
    ///      as WETH9 does during withdraw(). ETH can still be forced in without
    ///      executing receive(), so unwrap accounting relies on exact deltas.
    receive() external payable {
        if (msg.sender != WETH) revert NotWETH(WETH, msg.sender);
    }

    // ------------------------------------------------------------------- LISTING

    /// @notice List an ERC20 amount, priced in `quote`. Partial fills are allowed.
    ///         Caller must approve this contract for `amount`.
    ///         `startTime == 0` starts immediately; any non-zero `startTime` must not be
    ///         in the past. `startPrice` must be non-zero and >= `endPrice`; `endPrice`
    ///         may be 0, so a lot can decay to free.
    /// @param  quote Payment asset, or address(0) for native ETH. Must differ from `token`.
    function listERC20(
        address token,
        address quote,
        uint128 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration
    ) public nonReentrant returns (uint256 id) {
        id = _listERC20(msg.sender, token, quote, amount, startPrice, endPrice, startTime, duration);
    }

    /// @notice List escrow supplied by the caller while assigning seller rights
    ///         to `seller`.
    /// @dev This is the routed-order counterpart to listERC20. A zRouter-funded
    ///      executor can approve the exact lot and call here; fills, cancellation,
    ///      and returned escrow still belong to `seller`. Since funds are pulled
    ///      from msg.sender, naming another seller can only sponsor that seller's
    ///      order and cannot debit them.
    function listERC20For(
        address seller,
        address token,
        address quote,
        uint128 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration
    ) public nonReentrant returns (uint256 id) {
        id = _listERC20(seller, token, quote, amount, startPrice, endPrice, startTime, duration);
    }

    function _listERC20(
        address seller,
        address token,
        address quote,
        uint128 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration
    ) internal returns (uint256 id) {
        (uint96 sp, uint96 ep) = _checkPrices(startPrice, endPrice);
        if (
            seller == address(0) || seller == address(this) || seller == WETH || token == address(0) || amount == 0
                || duration == 0 || token == quote || (startTime != 0 && startTime < block.timestamp)
        ) {
            revert Bad();
        }
        unchecked {
            id = nextId++;
        }
        Listing storage l = listings[id];
        l.seller = seller;
        l.startTime = startTime == 0 ? uint40(block.timestamp) : startTime;
        l.duration = duration;
        l.token = token;
        l.quote = quote;
        l.startPrice = sp;
        l.endPrice = ep;
        l.initial = amount;
        l.remaining = amount;
        _pullEscrowToken(token, msg.sender, amount);
        emit Created(id, seller, token, quote);
    }

    /// @notice List one or more NFTs (max 100) from a single ERC721 as one lot, priced
    ///         in `quote`. Settles in full only. Caller must have approved this contract
    ///         for every id (per-id `approve` or `setApprovalForAll`).
    /// @dev    For a single NFT, prefer `onERC721Received` — pushing the token in with
    ///         `safeTransferFrom` lists it without granting any approval at all. This
    ///         entry point remains the only way to list a bundle as one lot.
    ///
    ///         There is deliberately no `listNFTFor`. The `For` variant exists so a
    ///         router-funded executor can escrow a lot on a seller's behalf, and zRouter
    ///         pulls only ERC-20s and native ETH — its sole ERC-721 contact is a
    ///         hardcoded NameNFT reveal, not a generic collection transfer. An NFT
    ///         counterpart would have no caller until zRouter itself learns to pull
    ///         arbitrary ERC-721s, and an unreachable entry point widens the escrow
    ///         surface for nothing. Note that the push path above does let a third party
    ///         open a listing owned by someone else, but only by transferring a token
    ///         they already control: `from` has provably parted with it by the time the
    ///         hook runs, so naming them seller is the only non-lossy choice, and no
    ///         approval over their remaining tokens is ever involved.
    function listNFT(
        address token,
        address quote,
        uint256[] calldata ids,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration
    ) public nonReentrant returns (uint256 id) {
        (uint96 sp, uint96 ep) = _checkPrices(startPrice, endPrice);
        if (
            ids.length == 0 || ids.length > 100 || duration == 0 || token == quote
                || (startTime != 0 && startTime < block.timestamp)
        ) revert Bad();
        unchecked {
            id = nextId++;
        }
        Listing storage l = listings[id];
        l.seller = msg.sender;
        l.isNFT = true;
        l.startTime = startTime == 0 ? uint40(block.timestamp) : startTime;
        l.duration = duration;
        l.token = token;
        l.quote = quote;
        l.startPrice = sp;
        l.endPrice = ep;
        l.ids = ids;
        for (uint256 i; i < ids.length; ++i) {
            _moveNFT(token, msg.sender, address(this), ids[i]);
        }
        emit Created(id, msg.sender, token, quote);
    }

    /// @notice Curve parameters carried in a push listing's `safeTransferFrom` data.
    /// @dev A named struct rather than five loose values so the encoding a frontend has
    ///      to produce is readable from the ABI: `abi.encode(PushTerms(...))`.
    struct PushTerms {
        address quote;
        uint256 startPrice;
        uint256 endPrice;
        uint40 startTime;
        uint40 duration;
    }

    /// @notice List a single NFT by sending it here with `safeTransferFrom`, carrying the
    ///         decay curve in the transfer's `data` as an encoded `PushTerms`.
    ///
    /// @dev    The point is not the saved transaction, it is the approval that never
    ///         happens. `listNFT` requires the seller to grant this contract per-id
    ///         `approve` or a blanket `setApprovalForAll`, and the blanket form leaves a
    ///         standing authority over every token in the collection that outlives the
    ///         listing. A push hands over exactly one token and grants nothing.
    ///
    ///         Single NFT only. `safeTransferFrom` delivers one token per call, so a
    ///         bundle would need either one call per id or a mutable half-assembled
    ///         listing sitting in storage with its own fill and cancel semantics. Bundle
    ///         sellers are already paying for an approval, so they keep using `listNFT`.
    ///
    ///         `msg.sender` IS the collection and is the only trustworthy source of that
    ///         address — a caller-supplied one would let anyone claim any token. Anyone
    ///         can also call this directly while transferring nothing, so ownership is
    ///         re-verified rather than inferred from the fact that we were called: with
    ///         no check, a listing could be minted against escrow another seller already
    ///         has here, and cancelled to steal it. Escrow is already in hand by now, so
    ///         this deliberately does not route through `_moveNFT`, whose precondition is
    ///         that the board does NOT yet hold the token.
    ///
    ///         Malformed or absent `data` reverts. A stray transfer to this address must
    ///         bounce rather than mint a listing on terms decoded out of zero bytes.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        nonReentrant
        returns (bytes4)
    {
        if (data.length != 160) revert Bad();
        PushTerms memory t = abi.decode(data, (PushTerms));

        address token = msg.sender; // the collection, established by the call itself
        (uint96 sp, uint96 ep) = _checkPrices(t.startPrice, t.endPrice);
        if (
            from == address(0) || from == address(this) || from == WETH || token == t.quote || t.duration == 0
                || (t.startTime != 0 && t.startTime < block.timestamp)
        ) revert Bad();

        // Verify, do not move: a direct caller transferring nothing must not be able to
        // mint a listing over escrow that is already backing someone else's.
        if (IERC721(token).ownerOf(tokenId) != address(this)) revert NFTTransferFailed(token, tokenId);

        uint256 id;
        unchecked {
            id = nextId++;
        }
        Listing storage l = listings[id];
        l.seller = from;
        l.isNFT = true;
        l.startTime = t.startTime == 0 ? uint40(block.timestamp) : t.startTime;
        l.duration = t.duration;
        l.token = token;
        l.quote = t.quote;
        l.startPrice = sp;
        l.endPrice = ep;
        l.ids.push(tokenId);

        emit Created(id, from, token, t.quote);
        return this.onERC721Received.selector;
    }

    /// @dev Narrowing to uint96 is checked, not silent: a price a maker cannot express
    ///      must fail at listing rather than escrow a lot at a truncated ask.
    function _checkPrices(uint256 startPrice, uint256 endPrice) internal pure returns (uint96 sp, uint96 ep) {
        if (startPrice == 0 || startPrice < endPrice || startPrice > type(uint96).max) revert Bad();
        (sp, ep) = (uint96(startPrice), uint96(endPrice));
    }

    // ---------------------------------------------------------------------- FILL

    /// @notice Current total price for the full initial lot at `block.timestamp`.
    ///         Returns 0 for unknown/closed listings.
    function priceOf(uint256 id) public view returns (uint256) {
        Listing storage l = listings[id];
        if (l.seller == address(0)) return 0;
        return _priceOf(l);
    }

    /// @notice Payment asset for a listing, or address(0) for native ETH.
    /// @dev A narrow accessor lets atomic executors distinguish native-ETH
    ///      listings from WETH listings without decoding the dynamic NFT array.
    function quoteOf(uint256 id) external view returns (address) {
        return listings[id].quote;
    }

    /// @notice Asset being sold by a listing, or address(0) for an empty slot.
    /// @dev Kept alongside `quoteOf` so atomic executors can validate a pair
    ///      without decoding the public getter's full packed listing tuple.
    function tokenOf(uint256 id) external view returns (address) {
        return listings[id].token;
    }

    /// @dev Callers must have already confirmed the slot is live (seller != 0); skipping
    ///      the guard avoids a duplicate slot-0 SLOAD and a redundant mapping keccak.
    function _priceOf(Listing storage l) internal view returns (uint256) {
        if (block.timestamp <= l.startTime) return l.startPrice;
        unchecked {
            uint256 elapsed = block.timestamp - l.startTime;
            if (elapsed >= l.duration) return l.endPrice;
            return l.startPrice - ((uint256(l.startPrice) - l.endPrice) * elapsed) / l.duration;
        }
    }

    /// @notice `quote` cost to take `take` units of `id` right now — mirrors `fill`.
    ///         NFT lots: pass `take == 0` or the full bundle size; returns the lot price.
    ///         Returns 0 for anything a UI should treat as non-fillable: closed listing,
    ///         NFT with mismatched `take`, ERC20 with `take == 0` or `take > remaining`.
    function costOf(uint256 id, uint128 take) public view returns (uint256) {
        Listing storage l = listings[id];
        if (l.seller == address(0)) return 0;
        uint256 price = _priceOf(l);
        if (l.isNFT) {
            uint256 n = l.ids.length;
            if (take != 0 && take != n) return 0;
            return price;
        }
        if (take == 0 || take > l.remaining) return 0;
        return _cost(price, take, l.initial);
    }

    /// @dev Rounds up, so a positive-price buy cannot round to zero when `initial` is
    ///      much larger than the current price. uint96 price x uint128 take is at most
    ///      2^224, so the sum cannot overflow.
    function _cost(uint256 price, uint128 take, uint128 initial) internal pure returns (uint256) {
        unchecked {
            return (price * take + initial - 1) / initial;
        }
    }

    /// @notice Fill a listing, paying in the listing's `quote`.
    /// @param  take    ERC20: units to buy. NFT: 0, or the whole bundle size.
    /// @param  to      Recipient of the lot. Named explicitly rather than assuming
    ///                 msg.sender, so a router or forwarder can settle straight to the
    ///                 end user instead of taking custody and sweeping.
    /// @param  maxCost Taker's bound on what they pay. Required for the ERC20 path,
    ///                 where cost is pulled by `transferFrom` and cannot be bounded by
    ///                 attaching an exact value; pass `type(uint256).max` to waive.
    ///                 The schedule only ever decays, so this can only bind if the
    ///                 taker's own quote was stale in their favour.
    function fill(uint256 id, uint128 take, address to, uint256 maxCost) public payable nonReentrant {
        // Single fills keep the strict guard: value attached to an ERC20-quoted listing
        // buys nothing, and rejecting it flags a mis-encoded call rather than quietly
        // handing the ETH straight back. `fillMany` cannot be this strict — a mixed batch
        // legitimately carries value for its ETH legs — so it refunds the unspent
        // remainder instead, which protects against stranding just as well.
        if (msg.value != 0 && listings[id].quote != address(0)) revert Bad();

        uint256 ethUsed = _settle(id, take, to, maxCost, msg.value);
        unchecked {
            if (msg.value > ethUsed) safeTransferETH(msg.sender, msg.value - ethUsed);
        }
    }

    /// @notice Fill several listings in one transaction. Each leg is bounded by its own
    ///         `maxCosts` entry, and legs may be quoted in different assets.
    /// @dev    ETH-quoted legs draw from `msg.value`, counted ONCE across the batch:
    ///         `_settle` is told how much remains unspent and refuses a leg that would
    ///         exceed it, so no leg can be paid twice out of the same value. Anything
    ///         unspent — the excess, or the whole of it when every leg is ERC20-quoted —
    ///         is refunded, so ETH can never be stranded here.
    ///
    ///         Atomic: a leg that reverts aborts the batch. There is no skip-on-failure
    ///         variant because the schedule only decays, so the usual reason a leg fails
    ///         is that someone else took it first, and silently paying more for the rest
    ///         of a plan is rarely what a taker wants.
    /// @return ethSpent Total ETH forwarded to sellers across the batch.
    function fillMany(uint256[] calldata ids, uint128[] calldata takes, uint256[] calldata maxCosts, address to)
        public
        payable
        nonReentrant
        returns (uint256 ethSpent)
    {
        uint256 n = ids.length;
        if (n == 0) revert Bad();
        if (n != takes.length || n != maxCosts.length) revert Bad();

        for (uint256 i; i < n; ++i) {
            unchecked {
                ethSpent += _settle(ids[i], takes[i], to, maxCosts[i], msg.value - ethSpent);
            }
        }

        unchecked {
            if (msg.value > ethSpent) safeTransferETH(msg.sender, msg.value - ethSpent);
        }
    }

    /// @dev One leg. Returns the ETH forwarded to the seller, which is 0 for an
    ///      ERC20-quoted listing. `ethAvailable` is the caller's UNSPENT value; bounding
    ///      each leg by it is what stops one `msg.value` settling several ETH legs.
    ///
    ///      Refunds are deliberately NOT issued here — the caller nets them once at the
    ///      end, so a batch cannot pay out mid-loop into a reentrant recipient.
    function _settle(uint256 id, uint128 take, address to, uint256 maxCost, uint256 ethAvailable)
        internal
        returns (uint256 ethUsed)
    {
        Listing storage l = listings[id];
        address seller = l.seller;
        if (seller == address(0)) revert Bad();
        if (to == address(0) || to == address(this)) revert Bad();

        uint256 price = _priceOf(l);
        address token = l.token;
        address quote = l.quote;

        uint256 cost;
        uint256 amount;
        if (l.isNFT) {
            uint256[] memory ids = l.ids;
            amount = ids.length;
            if (take != 0 && take != amount) revert Bad();
            cost = price;
            if (cost > maxCost) revert CostExceeded(cost, maxCost);
            delete listings[id];
            for (uint256 i; i < ids.length; ++i) {
                _moveNFT(token, address(this), to, ids[i]);
            }
        } else {
            uint128 rem = l.remaining;
            uint128 initial = l.initial;
            if (take == 0 || take > rem) revert Bad();
            cost = _cost(price, take, initial);
            if (cost > maxCost) revert CostExceeded(cost, maxCost);
            amount = take;
            unchecked {
                uint128 newRem = rem - take;
                if (newRem == 0) delete listings[id];
                else l.remaining = newRem;
            }
            _sendEscrowToken(token, to, take);
        }

        // Paying the seller last keeps the write-before-call ordering intact for both
        // branches: by the time a caller-chosen quote token gets control, the lot is
        // already gone from escrow and `remaining` already reflects this fill.
        if (quote == address(0)) {
            // Against UNSPENT value, not msg.value: in a batch the same msg.value would
            // otherwise cover every ETH leg independently.
            if (ethAvailable < cost) revert Insufficient();
            safeTransferETH(seller, cost);
            ethUsed = cost;
        } else {
            _payQuoteToken(quote, msg.sender, seller, cost);
        }

        emit Filled(id, seller, msg.sender, amount, cost);
    }

    // -------------------------------------------------------------------- CANCEL

    /// @notice Seller closes the listing and reclaims escrow: the full NFT bundle, or
    ///         the unsold remainder of an ERC20 lot.
    function cancel(uint256 id) public nonReentrant {
        Listing storage l = listings[id];
        if (l.seller != msg.sender) revert NotSeller();
        address token = l.token;
        if (l.isNFT) {
            uint256[] memory ids = l.ids;
            delete listings[id];
            for (uint256 i; i < ids.length; ++i) {
                _returnNFT(token, msg.sender, ids[i]);
            }
        } else {
            uint256 rem = l.remaining;
            delete listings[id];
            if (rem != 0) _sendEscrowToken(token, msg.sender, rem);
        }
        emit Cancelled(id);
    }

    /// @notice Seller closes a fungible canonical-WETH listing and receives its
    ///         unsold remainder as native ETH.
    /// @dev Storage is deleted before either WETH or the seller receives control.
    ///      Exact wrapper debit and ETH credit checks keep unrelated pooled WETH
    ///      and forced ETH from subsidising a malformed withdrawal.
    function cancelUnwrap(uint256 id) external nonReentrant {
        Listing storage l = listings[id];
        if (l.seller != msg.sender) revert NotSeller();
        if (l.isNFT) revert Bad();
        address token = l.token;
        if (token != WETH) revert NotWETH(WETH, token);

        uint256 rem = l.remaining;
        delete listings[id];
        _unwrapETH(rem);
        safeTransferETH(msg.sender, rem);
        emit Cancelled(id);
    }

    // ---------------------------------------------------------- ASSET MOVEMENT

    /// @dev Enforces the documented plain-ERC20 assumption at the escrow boundary.
    ///      Exact board credit prevents a short or successful-looking no-op deposit
    ///      from creating a listing backed by another maker's pooled balance.
    function _pullEscrowToken(address token, address from, uint256 amount) internal {
        uint256 fromBefore = IERC20(token).balanceOf(from);
        uint256 boardBefore = IERC20(token).balanceOf(address(this));
        safeTransferFrom(token, from, address(this), amount);

        uint256 spent = _decrease(fromBefore, IERC20(token).balanceOf(from));
        if (spent != amount) revert BalanceDeltaMismatch(token, from, amount, spent);

        uint256 received = _increase(boardBefore, IERC20(token).balanceOf(address(this)));
        if (received != amount) revert BalanceDeltaMismatch(token, address(this), amount, received);
    }

    /// @dev Confirms both sides of an escrow payout. The board can hold the same token
    ///      for many listings, so an over-debit must revert instead of consuming the
    ///      next maker's lot; an under-credit must not charge the taker for less output.
    function _sendEscrowToken(address token, address to, uint256 amount) internal {
        uint256 boardBefore = IERC20(token).balanceOf(address(this));
        uint256 toBefore = IERC20(token).balanceOf(to);
        safeTransfer(token, to, amount);

        uint256 spent = _decrease(boardBefore, IERC20(token).balanceOf(address(this)));
        if (spent != amount) revert BalanceDeltaMismatch(token, address(this), amount, spent);

        uint256 received = _increase(toBefore, IERC20(token).balanceOf(to));
        if (received != amount) revert BalanceDeltaMismatch(token, to, amount, received);
    }

    /// @dev Confirms both sides of canonical WETH redemption. The contract can
    ///      hold pooled WETH escrow and forced ETH, so either balance alone is
    ///      insufficient evidence that this listing redeemed exactly.
    function _unwrapETH(uint256 amount) internal {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        IWETH(WETH).withdraw(amount);

        uint256 spent = _decrease(wethBefore, IERC20(WETH).balanceOf(address(this)));
        if (spent != amount) {
            revert BalanceDeltaMismatch(WETH, address(this), amount, spent);
        }

        uint256 received = _increase(ethBefore, address(this).balance);
        if (received != amount) {
            revert BalanceDeltaMismatch(address(0), address(this), amount, received);
        }
    }

    /// @dev Payment never rests on the board, but both deltas still matter: the taker
    ///      must spend exactly `amount` and the seller must receive exactly `amount`.
    ///      A self-fill is already a no-op economically and needs no token round-trip.
    function _payQuoteToken(address token, address from, address to, uint256 amount) internal {
        if (amount == 0 || from == to) return;
        uint256 fromBefore = IERC20(token).balanceOf(from);
        uint256 toBefore = IERC20(token).balanceOf(to);
        safeTransferFrom(token, from, to, amount);

        uint256 spent = _decrease(fromBefore, IERC20(token).balanceOf(from));
        if (spent != amount) revert BalanceDeltaMismatch(token, from, amount, spent);

        uint256 received = _increase(toBefore, IERC20(token).balanceOf(to));
        if (received != amount) revert BalanceDeltaMismatch(token, to, amount, received);
    }

    /// @dev ERC-721 transferFrom has no return value. Source and destination ownership
    ///      checks prevent a quietly-no-op transfer from creating unbacked escrow,
    ///      duplicating an NFT already held for another listing, or charging a buyer
    ///      without delivering the bundle.
    function _moveNFT(address token, address from, address to, uint256 tokenId) internal {
        if (IERC721(token).ownerOf(tokenId) != from) revert NFTTransferFailed(token, tokenId);
        IERC721(token).transferFrom(from, to, tokenId);
        if (IERC721(token).ownerOf(tokenId) != to) revert NFTTransferFailed(token, tokenId);
    }

    /// @dev If a broken collection's sticky approval already let an NFT return home,
    ///      cancellation may close the stale listing. Otherwise the board must still
    ///      own the NFT and the return transfer must be observable through ownerOf.
    function _returnNFT(address token, address to, uint256 tokenId) internal {
        address owner = IERC721(token).ownerOf(tokenId);
        if (owner == to) return;
        if (owner != address(this)) revert NFTTransferFailed(token, tokenId);
        IERC721(token).transferFrom(address(this), to, tokenId);
        if (IERC721(token).ownerOf(tokenId) != to) revert NFTTransferFailed(token, tokenId);
    }

    function _increase(uint256 beforeBalance, uint256 afterBalance) internal pure returns (uint256 delta) {
        if (afterBalance >= beforeBalance) {
            unchecked {
                delta = afterBalance - beforeBalance;
            }
        }
    }

    function _decrease(uint256 beforeBalance, uint256 afterBalance) internal pure returns (uint256 delta) {
        if (beforeBalance >= afterBalance) {
            unchecked {
                delta = beforeBalance - afterBalance;
            }
        }
    }

    // --------------------------------------------------------------------- VIEWS

    /// @notice Flattened snapshot of listing `id` (fields + current price + `isNFT`).
    ///         `v.id` echoes the input; every other field is zero if `id` was never
    ///         listed or has closed (check `v.seller == address(0)`).
    function getListing(uint256 id) public view returns (ListingView memory v) {
        Listing storage l = listings[id];
        v.id = id;
        v.seller = l.seller;
        v.token = l.token;
        v.quote = l.quote;
        v.isNFT = l.isNFT;
        v.startTime = l.startTime;
        v.duration = l.duration;
        v.startPrice = l.startPrice;
        v.endPrice = l.endPrice;
        v.initial = l.initial;
        v.remaining = l.remaining;
        v.ids = l.ids;
        v.price = v.seller == address(0) ? 0 : _priceOf(l);
    }

    /// @notice Paginated book helper: snapshots for ids in `[start, end)`. `end` is
    ///         clamped to `nextId`. Closed slots come back zeroed so a caller can still
    ///         correlate index to id.
    function getListings(uint256 start, uint256 end) public view returns (ListingView[] memory out) {
        if (end > nextId) end = nextId;
        uint256 n = start < end ? end - start : 0;
        out = new ListingView[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = getListing(start + i);
        }
    }
}

interface IERC721 {
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH {
    function withdraw(uint256 amount) external;
}

// Solady safe transfer helpers:

error TransferFailed();

function safeTransfer(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0xa9059cbb000000000000000000000000)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x90b8ec18)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x34, 0)
    }
}

error TransferFromFailed();

function safeTransferFrom(address token, address from, address to, uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x60, amount)
        mstore(0x40, to)
        mstore(0x2c, shl(96, from))
        mstore(0x0c, 0x23b872dd000000000000000000000000)
        let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x7939f424)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}

error ETHTransferFailed();

function safeTransferETH(address to, uint256 amount) {
    assembly ("memory-safe") {
        if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
            mstore(0x00, 0xb12d13eb)
            revert(0x1c, 0x04)
        }
    }
}
