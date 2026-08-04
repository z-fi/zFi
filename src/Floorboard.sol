// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {ERC721} from "../lib/solady/src/tokens/ERC721.sol";
import {PositionSVG} from "./utils/PositionSVG.sol";
import {FloorboardMetadata} from "./utils/FloorboardMetadata.sol";

/// @title Floorboard
/// @notice Climbing, partially fillable BIDS for ERC-20s and NFT collections.
/// @dev The buy-side mirror of Dutchboard. A bidder escrows the PAYMENT asset
///      and names what they want to buy; the bid climbs from `startPrice` to
///      `endPrice`, and any seller may hit it by delivering the asset. Where
///      Dutchboard asks "how far must my price fall before someone buys",
///      Floorboard asks "how far must my bid rise before someone sells" — the
///      underbid-the-floor case, where a buyer starts below the floor and lets
///      the bid ratchet up to a capped ceiling rather than chasing it manually.
///
///      Three deliberate departures from Dutchboard, each forced by the side
///      flip rather than chosen:
///
///      1. BIDS EXPIRE. A Dutchboard listing rests at `endPrice` forever, which
///         is safe because the maker's escrow is the thing being sold and its
///         price only ever gets better for them. A resting bid is the opposite:
///         it is a standing obligation to buy at the maker's WORST price, and
///         leaving it live indefinitely is exactly the babysitting burden that
///         makes people not use bid boards. A bid is takeable only inside
///         `[startTime, startTime + duration)`. After that anyone may `sweep`
///         it, returning the escrow to its holder without the holder needing to
///         be watching.
///
///      2. ESCROW IS THE QUOTE ASSET, AND IS SIZED AT `endPrice` — the most the
///         bid can ever owe. The board is therefore always able to honour every
///         live bid at once; there is no partially-funded state. Unspent escrow
///         comes back on close.
///
///      3. PROCEEDS ROUND DOWN, and a zero-proceeds hit reverts. Dutchboard
///         rounds each fill's cost UP because the taker chooses the split and
///         must not round a positive price to zero. Here the SELLER chooses the
///         split, so the same reasoning points the other way: rounding down
///         keeps any sequence of partial hits inside the escrow, and the
///         explicit zero check keeps a dust hit from donating the asset.
///
///      NFT bids carry an optional allow-list. `Terms.ids` empty is a FLOOR bid
///      — the bidder wants `want` tokens from the collection and the seller
///      chooses which. A non-empty `ids` narrows the same bid to a named set
///      while `want` keeps meaning "how many", so one field pair expresses the
///      whole range: a floor bid, a bid on one specific token, and "any two of
///      these five". `want` is units on the ERC-20 path and a count on the NFT
///      path; `ids` is the thing that changes meaning, not `want`.
///
///      Exact balance-delta checks reject fee-on-transfer and no-op tokens;
///      rebasing, reflection, upgradeable, and otherwise non-standard tokens are
///      outside the security model. The sell side is always a token: a bidder
///      paying in ETH passes `quote == address(0)`, which wraps the attached value into a
///      canonical-WETH escrow, and `cancelUnwrap` returns the remainder as ETH.
///      Sellers may take their proceeds as ETH via the `unwrap` flag on `hit`.
///      Bidder self-hits are permitted; indexers should not treat every `Hit`
///      event as an arm's-length sale.
contract Floorboard is ERC721 {
    /// @dev Canonical WETH for this deployment; used for wrapping and unwrapping.
    address public immutable weth;

    /// @dev Deployed once, by this board, and never replaceable.
    FloorboardMetadata public immutable METADATA_RENDERER;

    constructor(address _weth) {
        if (_weth == address(0) || _weth.code.length == 0) revert Bad();
        weth = _weth;
        METADATA_RENDERER = new FloorboardMetadata();
    }

    struct Bid {
        address bidder;
        bool isNFT;
        uint40 startTime;
        uint40 duration;
        address token; // what the bidder wants to buy
        uint96 startPrice; // total for the full initial lot, in `quote`
        address quote; // what the bidder pays in; always a token, never native
        uint96 endPrice;
        uint96 locked; // quote still escrowed for this bid
        uint128 initial; // units wanted at creation (NFT: a count)
        uint128 remaining; // units still wanted
        uint256[] ids; // NFT only: the ALLOWED id set, empty for a collection bid
    }

    /// @notice Terms for a new bid.
    /// @dev Grouped rather than flattened because the creation entry
    ///      points would otherwise carry nine positional arguments each, and a
    ///      transposed price pair is not something the type system would catch.
    struct Terms {
        address token;
        address quote; // address(0) means native ETH, escrowed as canonical WETH
        uint128 want; // ERC-20 units, or NFT count
        uint256 startPrice;
        uint256 endPrice;
        uint40 startTime; // 0 starts immediately
        uint40 duration;
        bool isNFT;
        // NFT bids only: the ids this bid will accept. Empty means ANY id from
        // the collection — a floor bid. Non-empty narrows it to a named set,
        // and `want` still says how many of them to buy, so `want == 1` against
        // a five-id set is "any one of these five" and `want == ids.length` is
        // "all of them". Must be empty for ERC-20 bids, where `want` is units.
        uint256[] ids;
    }

    /// @dev Flattened snapshot for frontends. `bidder == address(0)` marks a
    ///      slot that never existed or has closed (cancelled / swept / filled).
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

    uint256 public nextId;
    mapping(uint256 => Bid) public bids;

    /// @notice Quote escrow this board owes to live bids, per token.
    /// @dev Escrow is POOLED: every bid in a given quote asset shares one board
    ///      balance, so a single bid's `locked` says nothing about what the
    ///      board owes overall. Solvency is `balanceOf(this) >= escrowed[token]`.
    mapping(address token => uint256 amount) public escrowed;

    /// @dev Terminal bids retain display data; this distinguishes a bid that was
    ///      bought out in full from one that was cancelled or swept.
    mapping(uint256 id => bool) public settled;

    /// @notice Units the bidder has withdrawn from a live bid.
    /// @dev Only written when a withdrawal happens, so bids that never shrink
    ///      pay nothing for it. Read back by `tokenURI` so a bid the holder
    ///      shrank is not rendered as a bid that sellers filled.
    mapping(uint256 id => uint128 amount) public withdrawn;

    /// @dev The last live instant of a terminal receipt. Metadata uses it to
    ///      render the curve position at close instead of letting a spent
    ///      receipt drift to the end of the schedule over wall-clock time.
    mapping(uint256 id => uint40 timestamp) internal closedAt;

    /// @dev `decimals + 1`, zero for the explicit raw fallback. Snapshotted at
    ///      creation so tokenURI never calls untrusted token code.
    mapping(address token => uint8 snapshot) public tokenDecimals;

    /// @dev Optional, sanitised ERC-721 symbol captured at bid time.
    mapping(address token => string symbol) internal tokenSymbols;

    event Created(uint256 indexed id, address indexed bidder, address indexed token, address quote);
    event Hit(uint256 indexed id, address indexed bidder, address indexed seller, uint256 amount, uint256 paid);
    event Cancelled(uint256 indexed id, bool swept);
    event Withdrawn(uint256 indexed id, uint256 amount, uint256 refund);

    error Bad();
    error NotBidder();
    error Reentrancy();
    error Expired();
    error NotWETH(address expected, address actual);
    error ProceedsBelowMin(uint256 proceeds, uint256 minProceeds);
    error ZeroProceeds();
    error NotTargeted(address token, uint256 tokenId);
    error NFTTransferFailed(address token, uint256 tokenId);
    error BalanceDeltaMismatch(address token, address account, uint256 expected, uint256 actual);

    /// @dev EIP-1153 transient slot for the reentrancy guard.
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
        if (msg.sender != weth) revert NotWETH(weth, msg.sender);
    }

    // ----------------------------------------------------------------- BIDDING

    /// @notice Open a climbing bid, escrowing `endPrice` of `terms.quote`.
    /// @dev `terms.quote == address(0)` means NATIVE ETH — the same convention
    ///      Dutchboard uses on its quote side. The attached value is wrapped and
    ///      escrowed as canonical WETH, and must equal `endPrice` exactly, since
    ///      that is the whole liability the bid can ever incur. The board
    ///      escrows tokens rather than native balance so escrow keeps one asset
    ///      model and one set of exact-delta invariants.
    function bid(Terms calldata terms) public payable nonReentrant returns (uint256 id) {
        id = _open(msg.sender, terms);
    }

    /// @notice Open a bid funded by the caller while assigning bidder rights to
    ///         `bidder`, who receives the asset and may cancel.
    function bidFor(address bidder, Terms calldata terms) public payable nonReentrant returns (uint256 id) {
        id = _open(bidder, terms);
    }

    function _open(address bidder, Terms calldata t) internal returns (uint256 id) {
        (uint96 sp, uint96 ep) = _checkPrices(t.startPrice, t.endPrice);
        bool fromETH = t.quote == address(0);
        address quote = fromETH ? weth : t.quote;

        // Escrow has no native branch: an ETH bid becomes a WETH bid here.
        if (quote.code.length == 0 || _isERC721(quote)) revert Bad();
        // Value is only ever meaningful on the wrapping path, and there it must
        // be the exact ceiling. Anything else is a mistake worth rejecting
        // rather than refunding.
        if (msg.value != (fromETH ? ep : 0)) revert Bad();
        if (t.token == address(0) || t.token.code.length == 0) revert Bad();
        // An ERC-721 must never reach the fungible path: it shares `balanceOf`
        // and `transferFrom(address,address,uint256)` with ERC-20, so token id 1
        // would satisfy every exact-delta check this board makes.
        if (!t.isNFT && _isERC721(t.token)) revert Bad();
        // This board is an ERC-721 now; a bid for its own receipts would have
        // the board brokering claims on itself.
        if (
            bidder == address(0) || bidder == address(this) || bidder == weth || t.want == 0 || t.duration == 0
                || t.token == quote || t.token == address(this)
                || (t.startTime != 0 && t.startTime < block.timestamp)
        ) revert Bad();
        // `want` is a quantity on both paths; `ids`, when present, only narrows
        // WHICH tokens satisfy it. An ERC-20 bid has no id set at all.
        if (t.isNFT) {
            if (t.ids.length > 100) revert Bad();
            if (t.ids.length != 0 && t.want > t.ids.length) revert Bad();
        } else if (t.ids.length != 0) {
            revert Bad();
        }

        unchecked {
            id = nextId++;
        }
        Bid storage b = bids[id];
        b.bidder = bidder;
        _mint(bidder, id);
        b.isNFT = t.isNFT;
        b.startTime = t.startTime == 0 ? uint40(block.timestamp) : t.startTime;
        b.duration = t.duration;
        b.token = t.token;
        b.quote = quote;
        b.startPrice = sp;
        b.endPrice = ep;
        b.locked = ep;
        b.initial = t.want;
        b.remaining = t.want;
        if (t.ids.length != 0) b.ids = t.ids;

        if (t.isNFT) _rememberSymbol(t.token);
        else _rememberDecimals(t.token);
        _rememberDecimals(quote);

        unchecked {
            escrowed[quote] += ep;
        }
        if (fromETH) _wrapETH(ep);
        else _pullEscrowToken(quote, msg.sender, ep);

        emit Created(id, bidder, t.token, quote);
    }

    /// @dev Check the price range before narrowing to uint96. The single line
    ///      that inverts Dutchboard: the schedule must be NONDECREASING, and the
    ///      ceiling — not the floor — is what has to fit the escrow width.
    function _checkPrices(uint256 startPrice, uint256 endPrice) internal pure returns (uint96 sp, uint96 ep) {
        if (startPrice == 0 || endPrice < startPrice || endPrice > type(uint96).max) revert Bad();
        (sp, ep) = (uint96(startPrice), uint96(endPrice));
    }

    // ---------------------------------------------------------------- HITTING

    /// @notice Sell `give` ERC-20 units into bid `id`.
    /// @param minProceeds Minimum acceptable payment; 0 for no bound.
    /// @param unwrap Take proceeds as native ETH. Only valid for WETH-quoted bids.
    function hit(uint256 id, uint128 give, uint256 minProceeds, bool unwrap)
        public
        nonReentrant
        returns (uint256 proceeds)
    {
        proceeds = _take(id, give, _emptyIds(), minProceeds, unwrap);
    }

    /// @notice Sell `ids` from the bid's collection into NFT bid `id`.
    /// @dev The bidder named a collection and a count, not specific ids; the
    ///      seller chooses which to deliver.
    function hitNFT(uint256 id, uint256[] calldata ids, uint256 minProceeds, bool unwrap)
        public
        nonReentrant
        returns (uint256 proceeds)
    {
        if (ids.length == 0 || ids.length > 100) revert Bad();
        proceeds = _take(id, uint128(ids.length), ids, minProceeds, unwrap);
    }

    /// @notice Hit several ERC-20 bids atomically. Proceeds are paid in each
    ///         bid's own quote asset, never unwrapped.
    function hitMany(uint256[] calldata ids, uint128[] calldata gives, uint256[] calldata minProceeds)
        public
        nonReentrant
        returns (uint256[] memory proceeds)
    {
        uint256 n = ids.length;
        if (n == 0 || n != gives.length || n != minProceeds.length) revert Bad();
        proceeds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            proceeds[i] = _take(ids[i], gives[i], _emptyIds(), minProceeds[i], false);
        }
    }

    /// @notice Hit several ERC-20 bids, stepping over legs that are no longer
    ///         takeable instead of aborting the batch.
    /// @dev The counterpart to Dutchboard's `tryFillMany`, and needed for the
    ///      same reason: a seller distributing size across a book read one block
    ///      earlier will find that some legs were taken, cancelled, expired, or
    ///      have not climbed to their `minProceeds` entry yet. Only STALE-STATE
    ///      refusals are skipped; a transfer that fails once started still
    ///      aborts everything, because a failing transfer is a broken asset
    ///      rather than a race.
    function tryHitMany(uint256[] calldata ids, uint128[] calldata gives, uint256[] calldata minProceeds)
        public
        nonReentrant
        returns (bool[] memory hits, uint256[] memory proceeds)
    {
        uint256 n = ids.length;
        if (n == 0 || n != gives.length || n != minProceeds.length) revert Bad();
        hits = new bool[](n);
        proceeds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (bool ok, uint256 pay) = _quote(ids[i], gives[i]);
            if (!ok || pay < minProceeds[i]) continue;
            proceeds[i] = _take(ids[i], gives[i], _emptyIds(), minProceeds[i], false);
            hits[i] = true;
        }
    }

    /// @dev Settle one leg: move the asset from the seller to the bid holder,
    ///      then release the matching escrow to the seller.
    function _take(uint256 id, uint128 give, uint256[] memory ids, uint256 minProceeds, bool unwrap)
        internal
        returns (uint256 proceeds)
    {
        Bid storage b = bids[id];
        address bidder = b.bidder;
        if (bidder == address(0)) revert Bad();
        if (block.timestamp < b.startTime) revert Bad();
        // The departure from Dutchboard: a bid outside its window is dead, not
        // resting at its terminal price.
        unchecked {
            if (block.timestamp >= uint256(b.startTime) + b.duration) revert Expired();
        }

        uint128 rem = b.remaining;
        if (give == 0 || give > rem) revert Bad();
        if (b.isNFT != (ids.length != 0)) revert Bad();

        proceeds = _proceeds(_priceOf(b), give, b.initial);
        // Rounding down must never let a hit donate the asset outright.
        if (proceeds == 0) revert ZeroProceeds();
        if (proceeds < minProceeds) revert ProceedsBelowMin(proceeds, minProceeds);

        address token = b.token;
        address quote = b.quote;

        // Update the bid before giving any asset control away.
        // Checked on purpose: escrow conservation must never wrap. `proceeds`
        // fits uint96 because it never exceeds `endPrice`.
        b.locked -= uint96(proceeds);
        escrowed[quote] -= proceeds;

        uint256 refund;
        unchecked {
            uint128 newRem = rem - give;
            // A partial hit leaves the bid live, so its receipt survives with a
            // smaller claim; only exhaustion closes it. Not burned on
            // exhaustion: a holder may be a contract that reads `ownerOf`, and
            // burning under it strands whatever it holds. The receipt survives
            // as a spent ticket.
            if (newRem == 0) {
                // The escrow was sized at `endPrice`, but a bid bought out
                // before it finished climbing spent less than that. The
                // difference belongs to the bidder and must leave with the
                // close — `_close` zeroes `locked`, so nothing later can
                // reclaim it.
                refund = b.locked;
                escrowed[quote] -= refund;
                _close(id, true);
            } else {
                b.remaining = newRem;
            }
        }

        // Deliver what was bought to the position holder.
        if (b.isNFT) {
            uint256[] memory allowed = b.ids;
            for (uint256 i; i < ids.length; ++i) {
                // An empty allow-list is a floor bid: any id from the
                // collection settles it. A non-empty one is a named set, and
                // anything outside it is simply not what was bid for.
                if (allowed.length != 0 && !_isAllowed(allowed, ids[i])) revert NotTargeted(token, ids[i]);
                _deliverNFT(token, msg.sender, bidder, ids[i], id);
            }
        } else {
            _deliverERC20(token, msg.sender, bidder, give, id);
        }

        // Then pay the seller out of escrow.
        if (unwrap) {
            if (quote != weth) revert NotWETH(weth, quote);
            _unwrapETH(proceeds);
            safeTransferETH(msg.sender, proceeds);
        } else {
            _sendEscrowToken(quote, msg.sender, proceeds);
        }

        // Finally, hand the bidder back whatever the climb never spent.
        if (refund != 0) _deliverERC20Escrow(quote, bidder, refund, id);

        emit Hit(id, bidder, msg.sender, give, proceeds);
    }

    /// @dev Linear scan over an allow-list capped at 100. A mapping would make
    ///      this O(1) at the cost of an SSTORE per allowed id at creation, which
    ///      is the wrong trade: the set is written once and read at most `want`
    ///      times, and the array has to exist anyway for `getBid` to show a
    ///      taker what the bid will accept.
    function _isAllowed(uint256[] memory allowed, uint256 tokenId) internal pure returns (bool) {
        for (uint256 i; i < allowed.length; ++i) {
            if (allowed[i] == tokenId) return true;
        }
        return false;
    }

    /// @dev Round DOWN. See the contract-level note: the seller picks the split
    ///      here, so any sequence of partial hits must stay inside the escrow.
    function _proceeds(uint256 price, uint128 give, uint128 initial) internal pure returns (uint256) {
        unchecked {
            return (price * give) / initial;
        }
    }

    // ---------------------------------------------------------------- CLOSING

    /// @notice Bidder closes the bid and reclaims the unspent escrow.
    function cancel(uint256 id) public nonReentrant {
        Bid storage b = bids[id];
        if (b.bidder != msg.sender) revert NotBidder();
        _release(id, false, false);
    }

    /// @notice Bidder closes a WETH-quoted bid and receives the unspent escrow
    ///         as native ETH.
    function cancelUnwrap(uint256 id) external nonReentrant {
        Bid storage b = bids[id];
        if (b.bidder != msg.sender) revert NotBidder();
        if (b.quote != weth) revert NotWETH(weth, b.quote);
        _release(id, false, true);
    }

    /// @notice Bidder shrinks a live bid, reclaiming the escrow that backed the
    ///         part they no longer want.
    /// @dev The mirror of Dutchboard's `withdraw`, and safe for the same reason:
    ///      it moves `remaining` without touching `initial`, and `initial` is
    ///      the denominator every payment divides by (`_proceeds`). The per-unit
    ///      bid a seller sees is therefore unchanged; the only thing that can
    ///      happen to a racing seller is that their `give` no longer fits and
    ///      the hit reverts, which `tryHitMany` already treats as a stale-state
    ///      skip.
    ///
    ///      The refund is whatever escrow the shrunken bid can no longer owe.
    ///      `locked` must always cover the worst case for what is still wanted —
    ///      every remaining unit filling at `endPrice` — and because each
    ///      payment floors, that bound is `endPrice * remaining / initial`.
    ///      Anything above it is released here.
    /// @param amount Units to stop bidding for. Must leave a nonzero remainder —
    ///        use `cancel` to close the bid outright.
    /// @param unwrap Take the refund as native ETH; WETH-quoted bids only.
    function withdraw(uint256 id, uint128 amount, bool unwrap) external nonReentrant {
        Bid storage b = bids[id];
        address holder = b.bidder;
        if (holder != msg.sender) revert NotBidder();

        uint128 rem = b.remaining;
        if (amount == 0 || amount >= rem) revert Bad();

        uint128 newRem;
        unchecked {
            newRem = rem - amount;
        }
        b.remaining = newRem;

        // Worst-case future outlay for what is still wanted. Each `_proceeds`
        // floors, and a sum of floors is an integer no greater than the real
        // total, so the floor of that total is a sound reserve.
        uint256 required = (uint256(b.endPrice) * newRem) / b.initial;
        uint256 refund = uint256(b.locked) - required;
        b.locked = uint96(required);
        withdrawn[id] += amount;

        address quote = b.quote;
        if (refund != 0) {
            escrowed[quote] -= refund;
            if (unwrap) {
                if (quote != weth) revert NotWETH(weth, quote);
                _unwrapETH(refund);
                safeTransferETH(msg.sender, refund);
            } else {
                _sendEscrowToken(quote, msg.sender, refund);
            }
        }
        emit Withdrawn(id, amount, refund);
    }

    /// @notice Anyone may close an EXPIRED bid, returning the escrow to its
    ///         holder.
    /// @dev The whole point of the expiry rule. A bidder should not have to
    ///      watch a board to stop offering to buy: once the window closes the
    ///      bid is unhittable anyway, so letting anyone reclaim it on the
    ///      holder's behalf turns a standing obligation into a self-clearing
    ///      one. Keepers, the bidder's own automation, or the next seller to
    ///      notice can all do it, and none of them can do anything but return
    ///      the escrow to whoever holds the receipt.
    function sweep(uint256 id) external nonReentrant {
        Bid storage b = bids[id];
        if (b.bidder == address(0)) revert Bad();
        unchecked {
            if (block.timestamp < uint256(b.startTime) + b.duration) revert Bad();
        }
        _release(id, true, false);
    }

    function _release(uint256 id, bool swept, bool unwrap) internal {
        Bid storage b = bids[id];
        address holder = b.bidder;
        address quote = b.quote;
        uint256 refund = b.locked;
        _close(id, false);
        if (refund != 0) {
            escrowed[quote] -= refund;
            if (unwrap) {
                _unwrapETH(refund);
                safeTransferETH(holder, refund);
            } else {
                _deliverERC20Escrow(quote, holder, refund, id);
            }
        }
        emit Cancelled(id, swept);
    }

    /// @dev Retain immutable display terms after a receipt is spent. A zero
    ///      bidder remains the sole liveness marker used everywhere else.
    function _close(uint256 id, bool filled) internal {
        Bid storage b = bids[id];
        b.bidder = address(0);
        b.locked = 0;
        closedAt[id] = uint40(block.timestamp);
        if (filled) {
            settled[id] = true;
            b.remaining = 0;
        }
    }

    // ------------------------------------------------------ POSITION RECEIPTS

    /// @dev Same reasoning as Dutchboard's, including where the guard goes. A
    ///      bid transfer hands the claim over BEFORE the recipient's
    ///      `onERC721Received` runs, so the safe variants are guarded; plain
    ///      `transferFrom` makes no external call and is not, because solady
    ///      routes the safe variants THROUGH it and guarding both would nest and
    ///      revert as reentrancy on every safe transfer.
    function safeTransferFrom(address from, address to, uint256 id) public payable override nonReentrant {
        super.safeTransferFrom(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data)
        public
        payable
        override
        nonReentrant
    {
        super.safeTransferFrom(from, to, id, data);
    }

    /// @dev Marks this collection as a LIVE CLAIM rather than an inert
    ///      collectible: `bytes4(keccak256("LiveOrderPosition()"))`.
    ///
    ///      A bid can be hit by anyone at any time, which delivers the bought
    ///      asset to whoever holds the receipt and consumes the escrow. That is
    ///      fine for a wallet and wrong for an escrow: a contract holding the
    ///      position as inert collateral receives assets it has no accounting
    ///      for. Floorboard brackets every delivery to a contract holder in the
    ///      same before/after proceeds callbacks Dutchboard uses, so an escrow
    ///      can attribute the arrival instead of finding an unexplained balance.
    bytes4 internal constant LIVE_ORDER_POSITION = 0x28a93a2e;

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == LIVE_ORDER_POSITION || super.supportsInterface(interfaceId);
    }

    function name() public pure override returns (string memory) {
        return "Floorboard Position";
    }

    function symbol() public pure override returns (string memory) {
        return "FBPOS";
    }

    /// @notice Live, self-contained terminal metadata for the bid receipt.
    function tokenURI(uint256 id) public view override returns (string memory) {
        address holder = ownerOf(id);
        Bid storage b = bids[id];
        bool live = b.bidder != address(0);
        return METADATA_RENDERER.tokenURI(
            FloorboardMetadata.RenderParams({
                id: id,
                bidder: live ? b.bidder : holder,
                token: b.token,
                quote: b.quote,
                remaining: b.remaining,
                locked: b.locked,
                price: live ? _priceOf(b) : 0,
                startPrice: b.startPrice,
                endPrice: b.endPrice,
                startTime: b.startTime,
                duration: b.duration,
                fillProgress: _bidFillProgress(id, b, live),
                climbProgress: _climbProgress(id, b, live),
                tokenDecimals: b.isNFT ? 0 : tokenDecimals[b.token],
                quoteDecimals: tokenDecimals[b.quote],
                tokenSymbol: tokenSymbols[b.token],
                isNFT: b.isNFT,
                live: live,
                settled: settled[id]
            })
        );
    }

    /// @dev Measured against the bid NET of withdrawals, so a holder who shrank
    ///      their bid is not shown as one that sellers filled.
    function _bidFillProgress(uint256 id, Bid storage b, bool live) internal view returns (uint256) {
        if (!live && settled[id]) return 10_000;
        if (b.initial == 0) return 0;
        uint256 offered = uint256(b.initial) - withdrawn[id];
        if (offered == 0) return 0;
        return ((offered - b.remaining) * 10_000) / offered;
    }

    function _climbProgress(uint256 id, Bid storage b, bool live) internal view returns (uint256) {
        uint256 progressTime = live ? block.timestamp : closedAt[id];
        if (progressTime <= b.startTime) return 0;
        uint256 elapsed = progressTime - b.startTime;
        if (elapsed >= b.duration) return 10_000;
        return (elapsed * 10_000) / b.duration;
    }

    function _rememberDecimals(address token) internal {
        if (tokenDecimals[token] != 0) return;
        (bool known, uint8 decimals) = PositionSVG.readDecimals(token);
        if (known) tokenDecimals[token] = decimals + 1;
    }

    function _rememberSymbol(address token) internal {
        if (bytes(tokenSymbols[token]).length == 0) tokenSymbols[token] = PositionSVG.readSymbol(token);
    }

    /// @dev Ownership IS bidder-ship. Keeping the stored `bidder` in step on
    ///      transfer means deliveries and cancellation keep working exactly as
    ///      before, with one source of truth rather than two. Closing must not
    ///      rewrite `bidder`, because a closed bid is recognised by its zero
    ///      bidder.
    function _afterTokenTransfer(address from, address to, uint256 id) internal override {
        if (from != address(0) && to != address(0)) {
            if (to == address(this) || to == weth) revert Bad();
            if (bids[id].bidder != address(0)) bids[id].bidder = to;
        }
    }

    // ----------------------------------------------------------------- QUOTES

    /// @notice Current total bid for the full initial lot at `block.timestamp`.
    ///         Returns 0 for unknown/closed bids.
    function priceOf(uint256 id) public view returns (uint256) {
        Bid storage b = bids[id];
        if (b.bidder == address(0)) return 0;
        return _priceOf(b);
    }

    /// @dev Callers check that the bid is live before calling this helper.
    ///      The other line that inverts Dutchboard: the schedule climbs.
    function _priceOf(Bid storage b) internal view returns (uint256) {
        if (block.timestamp <= b.startTime) return b.startPrice;
        unchecked {
            uint256 elapsed = block.timestamp - b.startTime;
            if (elapsed >= b.duration) return b.endPrice;
            return b.startPrice + ((uint256(b.endPrice) - b.startPrice) * elapsed) / b.duration;
        }
    }

    /// @notice Whether `give` units can be sold into `id` right now, and for
    ///         how much — the mirror of Dutchboard's `quoteFill`.
    /// @dev Returns `(false, 0)` for every stale-state refusal `_take` makes:
    ///      closed, not yet started, EXPIRED, wrong lot kind, `give == 0`,
    ///      `give > remaining`, or a split that rounds the payment to zero.
    function quoteHit(uint256 id, uint128 give) public view returns (bool takeable, uint256 proceeds) {
        return _quote(id, give);
    }

    function _quote(uint256 id, uint128 give) internal view returns (bool, uint256) {
        Bid storage b = bids[id];
        if (b.bidder == address(0)) return (false, 0);
        if (block.timestamp < b.startTime) return (false, 0);
        unchecked {
            if (block.timestamp >= uint256(b.startTime) + b.duration) return (false, 0);
        }
        if (give == 0 || give > b.remaining) return (false, 0);
        uint256 proceeds = _proceeds(_priceOf(b), give, b.initial);
        if (proceeds == 0) return (false, 0);
        return (true, proceeds);
    }

    /// @notice Smallest quantity that pays at least `wantProceeds`, and what it
    ///         actually pays.
    /// @dev The exact-output primitive a router needs and cannot get from
    ///      `quoteHit`: a seller with a revenue target has to invert a climbing,
    ///      round-down curve to find the quantity, and doing that off chain is
    ///      where a route drifts into `ProceedsBelowMin`. Passing the returned
    ///      `give` straight into `hit` always yields `proceeds >= wantProceeds`.
    ///      Returns `(0, 0)` when the whole remainder is not worth that much.
    function giveFor(uint256 id, uint256 wantProceeds) public view returns (uint128 give, uint256 proceeds) {
        Bid storage b = bids[id];
        (bool takeable, uint256 full) = _quote(id, b.remaining);
        if (!takeable || full < wantProceeds) return (0, 0);
        if (wantProceeds == 0) return (0, 0);

        uint128 initial = b.initial;
        uint256 price = _priceOf(b);
        // ceil(wantProceeds * initial / price) is the first quantity whose
        // floored payment can reach the target; the floor can shave at most one
        // unit of quote, so step up once if it did.
        unchecked {
            uint256 units = (wantProceeds * initial + price - 1) / price;
            if (units == 0) units = 1;
            if (units > b.remaining) units = b.remaining;
            give = uint128(units);
        }
        proceeds = _proceeds(price, give, initial);
        if (proceeds < wantProceeds && give < b.remaining) {
            unchecked {
                give += 1;
            }
            proceeds = _proceeds(price, give, initial);
        }
        if (proceeds < wantProceeds) return (0, 0);
    }

    /// @notice One packed read of everything an executor needs to route a leg.
    function legOf(uint256 id)
        external
        view
        returns (address bidder, address token, address quote, bool isNFT, uint128 remaining, uint256 price)
    {
        Bid storage b = bids[id];
        bidder = b.bidder;
        if (bidder == address(0)) return (address(0), address(0), address(0), false, 0, 0);
        token = b.token;
        quote = b.quote;
        isNFT = b.isNFT;
        remaining = b.remaining;
        price = _priceOf(b);
    }

    /// @notice Quote asset for a bid, or address(0) for an empty slot.
    function quoteOf(uint256 id) external view returns (address) {
        return bids[id].quote;
    }

    /// @notice Asset a bid wants to buy, or address(0) for an empty slot.
    function tokenOf(uint256 id) external view returns (address) {
        return bids[id].token;
    }

    /// @notice Whether a bid targets an ERC-721 collection rather than an ERC-20.
    function isNFTOf(uint256 id) external view returns (bool) {
        return bids[id].isNFT;
    }

    /// @notice The instant after which a bid is unhittable and sweepable.
    function expiryOf(uint256 id) public view returns (uint256) {
        Bid storage b = bids[id];
        unchecked {
            return uint256(b.startTime) + b.duration;
        }
    }

    /// @notice ERC-20 balance this board holds against no escrow liability.
    /// @dev Reverts if the board is ever insolvent for `token`, which makes the
    ///      conservation invariant `balanceOf >= escrowed` enforced rather than
    ///      merely monitored.
    function freeBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this)) - escrowed[token];
    }

    // ---------------------------------------------------------- ASSET MOVEMENT

    /// @dev ERC-165 probe for the ERC-721 interface id. Used only to REJECT, so
    ///      a collection that does not implement ERC-165 is not made unbiddable.
    function _isERC721(address token) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            token.staticcall{gas: 30_000}(abi.encodeWithSelector(0x01ffc9a7, bytes4(0x80ac58cd)));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    function _emptyIds() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    /// @dev Require the caller and board balances to change by exactly `amount`.
    function _pullEscrowToken(address token, address from, uint256 amount) internal {
        uint256 fromBefore = IERC20(token).balanceOf(from);
        uint256 boardBefore = IERC20(token).balanceOf(address(this));
        safeTransferFromERC20(token, from, address(this), amount);

        uint256 spent = _decrease(fromBefore, IERC20(token).balanceOf(from));
        if (spent != amount) revert BalanceDeltaMismatch(token, from, amount, spent);

        uint256 received = _increase(boardBefore, IERC20(token).balanceOf(address(this)));
        if (received != amount) revert BalanceDeltaMismatch(token, address(this), amount, received);
    }

    /// @dev Confirm the board debit and recipient credit for pooled escrow.
    function _sendEscrowToken(address token, address to, uint256 amount) internal {
        uint256 boardBefore = IERC20(token).balanceOf(address(this));
        uint256 toBefore = IERC20(token).balanceOf(to);
        safeTransfer(token, to, amount);

        uint256 spent = _decrease(boardBefore, IERC20(token).balanceOf(address(this)));
        if (spent != amount) revert BalanceDeltaMismatch(token, address(this), amount, spent);

        uint256 received = _increase(toBefore, IERC20(token).balanceOf(to));
        if (received != amount) revert BalanceDeltaMismatch(token, to, amount, received);
    }

    /// @dev Escrow leaving the board toward the position HOLDER — a refund — so
    ///      it is bracketed by the proceeds callbacks like any other delivery.
    function _deliverERC20Escrow(address token, address to, uint256 amount, uint256 id) internal {
        bool notify = _notifyBeforeProceeds(to, id, token, amount, false);
        _sendEscrowToken(token, to, amount);
        if (notify) _notifyAfterProceeds(to, id, token, amount, false);
    }

    /// @dev Confirm exact seller debit and holder credit; self-hits need no
    ///      transfer. When the holder is an escrow contract, the delivery is
    ///      bracketed by its proceeds callbacks so it can attribute the arrival
    ///      instead of finding an unexplained balance it cannot release.
    function _deliverERC20(address token, address from, address to, uint256 amount, uint256 id) internal {
        if (amount == 0 || from == to) return;
        bool notify = _notifyBeforeProceeds(to, id, token, amount, false);

        uint256 fromBefore = IERC20(token).balanceOf(from);
        uint256 toBefore = IERC20(token).balanceOf(to);
        safeTransferFromERC20(token, from, to, amount);

        uint256 spent = _decrease(fromBefore, IERC20(token).balanceOf(from));
        if (spent != amount) revert BalanceDeltaMismatch(token, from, amount, spent);

        uint256 received = _increase(toBefore, IERC20(token).balanceOf(to));
        if (received != amount) revert BalanceDeltaMismatch(token, to, amount, received);

        if (notify) _notifyAfterProceeds(to, id, token, amount, false);
    }

    /// @dev The NFT half of the same delivery. The board never takes custody:
    ///      the token moves seller to holder in one hop, so there is no
    ///      board-held NFT to double-book and no custody index to maintain.
    function _deliverNFT(address token, address from, address to, uint256 tokenId, uint256 id) internal {
        bool notify = from == to ? false : _notifyBeforeProceeds(to, id, token, tokenId, true);
        _moveNFT(token, from, to, tokenId);
        if (notify) _notifyAfterProceeds(to, id, token, tokenId, true);
    }

    /// @dev Confirm the exact WETH credit from wrapping. The native debit is not
    ///      checked against a snapshot: ETH can be force-fed into this board
    ///      without executing `receive()`, so only the token side is a sound
    ///      invariant — the same asymmetry `_unwrapETH` documents.
    function _wrapETH(uint256 amount) internal {
        uint256 beforeBalance = IERC20(weth).balanceOf(address(this));
        IWETH(weth).deposit{value: amount}();
        uint256 received = _increase(beforeBalance, IERC20(weth).balanceOf(address(this)));
        if (received != amount) revert BalanceDeltaMismatch(weth, address(this), amount, received);
    }

    /// @dev Confirm both the WETH debit and native ETH credit.
    function _unwrapETH(uint256 amount) internal {
        uint256 wethBefore = IERC20(weth).balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        IWETH(weth).withdraw(amount);

        uint256 spent = _decrease(wethBefore, IERC20(weth).balanceOf(address(this)));
        if (spent != amount) revert BalanceDeltaMismatch(weth, address(this), amount, spent);

        uint256 received = _increase(ethBefore, address(this).balance);
        if (received != amount) revert BalanceDeltaMismatch(address(0), address(this), amount, received);
    }

    /// @dev The same opt-in probe Dutchboard makes, in the same direction: a
    ///      bounded static call, and only an affirmative answer turns on the
    ///      stateful callbacks. Reverts inside an accepted callback bubble up —
    ///      an escrow that opted in and then refused the accounting must not be
    ///      paid anyway.
    function _notifyBeforeProceeds(address to, uint256 id, address token, uint256 amount, bool nft)
        internal
        returns (bool)
    {
        if (to.code.length == 0) return false;
        (bool ok, bytes memory ret) = to.staticcall{gas: 30_000}(abi.encodeWithSelector(0x33dbef94, id));
        if (!ok || ret.length != 32 || !abi.decode(ret, (bool))) return false;
        (ok, ret) = to.call(abi.encodeWithSelector(0x8d27ed3f, id, token, amount, nft));
        if (!ok) _bubbleRevert(ret);
        return ret.length == 32 && abi.decode(ret, (bool));
    }

    function _notifyAfterProceeds(address to, uint256 id, address token, uint256 amount, bool nft) internal {
        (bool ok, bytes memory ret) = to.call(abi.encodeWithSelector(0x2814c622, id, token, amount, nft));
        if (!ok) _bubbleRevert(ret);
    }

    function _bubbleRevert(bytes memory ret) internal pure {
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    /// @dev Confirm ownership before and after `transferFrom`.
    function _moveNFT(address token, address from, address to, uint256 tokenId) internal {
        if (IERC721(token).ownerOf(tokenId) != from) revert NFTTransferFailed(token, tokenId);
        IERC721(token).transferFrom(from, to, tokenId);
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

    /// @notice Flattened snapshot of bid `id` (fields + current price + liveness).
    /// @dev `v.bidder == address(0)` is the SOLE liveness marker: the slot was
    ///      never bid, or the bid has closed. A closed bid keeps its historical
    ///      terms on purpose — token, quote, times and prices stay populated so
    ///      a spent receipt still renders and indexers can report what was
    ///      bought; only `bidder`, `locked` and `price` come back zero.
    ///      `takeable` folds in the expiry and start-time windows, which
    ///      `bidder` alone cannot express.
    function getBid(uint256 id) public view returns (BidView memory v) {
        Bid storage b = bids[id];
        v.id = id;
        v.bidder = b.bidder;
        v.token = b.token;
        v.quote = b.quote;
        v.isNFT = b.isNFT;
        v.startTime = b.startTime;
        v.duration = b.duration;
        v.startPrice = b.startPrice;
        v.endPrice = b.endPrice;
        v.locked = b.locked;
        v.initial = b.initial;
        v.remaining = b.remaining;
        v.ids = b.ids;
        v.price = v.bidder == address(0) ? 0 : _priceOf(b);
        (v.takeable,) = _quote(id, b.remaining);
    }

    /// @notice Paginated book helper: snapshots for ids in `[start, end)`. `end`
    ///         is clamped to `nextId`.
    function getBids(uint256 start, uint256 end) public view returns (BidView[] memory out) {
        if (end > nextId) end = nextId;
        uint256 n = start < end ? end - start : 0;
        out = new BidView[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = getBid(start + i);
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
    function deposit() external payable;
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

function safeTransferFromERC20(address token, address from, address to, uint256 amount) {
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
