// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PositionSVG} from "./utils/PositionSVG.sol";
import {ERC721} from "../lib/solady/src/tokens/ERC721.sol";
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
///      outside the security model. Escrow is always a token, never native
///      balance: a bidder paying in ETH passes `quote == address(0)`, which
///      wraps the attached value into a canonical-WETH escrow, and
///      `cancelUnwrap` returns the remainder as ETH.
///      Sellers may take their proceeds as ETH via the `unwrap` flag on `hit`.
///      Bidder self-hits are permitted on the ERC-20 path, where the delivery
///      is a no-op and the escrow simply returns to the holder; indexers should
///      not treat every `Hit` event as an arm's-length sale. They are REFUSED on
///      the NFT path, where the same no-op would let one token be paid for
///      repeatedly — see `_take`.
///
///      Force-fed ETH and donated ERC-20s are unrecoverable: there is no rescue
///      path, by design, since one would be a claim on pooled escrow. Escrow
///      widths are `uint96`, which caps an 18-decimal quote asset at ~79bn units.
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
    error Expired();
    error NotBidder();
    error Reentrancy();
    error ZeroProceeds();
    error NotWETH(address expected, address actual);
    error NotTargeted(address token, uint256 tokenId);
    error NFTTransferFailed(address token, uint256 tokenId);
    error ProceedsBelowMin(uint256 proceeds, uint256 minProceeds);
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
    /// @dev THIS IS A GIFT, NOT A BID PLACED ON SOMEONE'S BEHALF. The caller
    ///      pays the whole escrow and keeps NO claim on it: `bidder` holds the
    ///      receipt, every refund path (`cancel`, `cancelUnwrap`, `withdraw`,
    ///      `sweep`, and the unspent remainder of a full fill) pays the HOLDER,
    ///      and `bidder` may cancel in the next block and keep 100% of what was
    ///      funded. Nothing here is recoverable by the payer. A frontend must
    ///      present this as "fund a bid for X and hand X the money", never as
    ///      "bid for X".
    ///
    ///      BIDDERSHIP IS ALSO UNSOLICITED. `bidder` does not consent, so a
    ///      receipt can appear in any wallet and a contract bidder can be made
    ///      the counterparty to terms it never chose. `ownerOf(id)` is true of
    ///      such a bid as well, so an integrating contract must key off its own
    ///      record of bids it opened rather than off makership alone. The
    ///      receipt is minted, not safe-minted: a contract that cannot call
    ///      `cancel` or move ERC-20s strands the escrow, since `sweep` returns
    ///      it to that same contract.
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
        //
        // THIS PROBE IS NOT A CLASSIFIER. It rejects only collections that
        // affirmatively answer `supportsInterface(0x80ac58cd)` inside 30k gas;
        // an ERC-721 without ERC-165, or with an expensive one, lands on the
        // fungible path, where `give == 1` moves token id 1 and passes every
        // delta check. The blast radius is one token per bid and the mistake is
        // the bidder's own, but a quote-asset and collection ALLOWLIST at the
        // dapp layer is what actually closes this, not the probe.
        if (!t.isNFT && _isERC721(t.token)) revert Bad();
        // A LIVE CLAIM is not a thing this board can buy, and the reason is the
        // one Swapboard's `_checkEscrowable` documents for its payment leg.
        //
        // A bid names an asset and escrows the quote for it; the asset is
        // DELIVERED BY THE SELLER, seller to holder in one hop, with no custody
        // step in between (see `_deliverNFT`). So the seller controls what the
        // position is still worth right up to the moment they hit the bid:
        // cancel it, or reprice it to dust, in the same transaction, hand over
        // the spent ticket, and take the escrow. Nothing here can price a claim
        // whose value its deliverer controls, so the bid is refused rather than
        // funded with a warning.
        //
        // Dutchboard deliberately does NOT make this check, and the difference
        // is custody: listing a position there moves it INTO escrow first, so
        // the board becomes its owner and the seller loses exactly the control
        // this check cannot verify. Buying without custody has no such moment.
        //
        // WHAT THIS CATCHES IS SIBLING BOARDS, AND ONLY THOSE. The custody
        // argument applies just as well to V3 LP NFTs, vault share receipts,
        // staked or locked positions, and ENS names with a pending change —
        // none of which declare this interface, all of which are biddable, and
        // any of which can be emptied in the same transaction that delivers the
        // ticket. Collection safety is a dapp allowlist decision; acceptance
        // here is not evidence of it.
        if (t.isNFT && _declares(t.token, LIVE_ORDER_POSITION)) revert Bad();
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
            // A repeated id makes the set smaller than it reads: `[1,1,1]` with
            // `want = 2` is a bid nobody but the holder can fill, since the
            // first delivery of token 1 is the only one `_moveNFT` will accept.
            // Rejecting it here keeps `ids.length` an honest upper bound on how
            // many distinct tokens can settle the bid, and costs nothing after
            // creation.
            for (uint256 i; i < t.ids.length; ++i) {
                for (uint256 j = i + 1; j < t.ids.length; ++j) {
                    if (t.ids[i] == t.ids[j]) revert Bad();
                }
            }
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

        _rememberSymbol(t.token);
        if (!t.isNFT) _rememberDecimals(t.token);
        _rememberDecimals(quote);
        _rememberSymbol(quote);

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
    ///      have not climbed to their `minProceeds` entry yet. Only refusals
    ///      the seller cannot act on are skipped — stale state, plus an NFT bid
    ///      that this fungible path could never have settled anyway. A transfer
    ///      that fails once started still aborts everything, because a failing
    ///      transfer is a broken asset rather than a race.
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
            // An NFT bid cannot be settled through the fungible path at all, so
            // it is a skip rather than an abort — `_take` would revert on the
            // lot-kind mismatch and take every other leg down with it.
            if (bids[ids[i]].isNFT) continue;
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
        // Checked at entry rather than at payout: the quote asset is known the
        // moment the bid is read, so a caller asking for ETH out of a bid that
        // is not WETH-quoted should not pay for the whole settlement first.
        address quote = b.quote;
        if (unwrap && quote != weth) revert NotWETH(weth, quote);
        // An NFT self-hit delivers nothing. Seller and holder are the same
        // address, so every `_moveNFT` is a no-op that passes its own
        // ownership checks — including on a token already "delivered" in an
        // earlier call, which is why a per-call duplicate scan could never
        // close this. All it can do is drain the bid's escrow against tokens
        // the hitter keeps, and under `bidFor` that escrow is someone else's.
        // `cancel` is the way for a holder to take their escrow back.
        if (b.isNFT && bidder == msg.sender) revert Bad();

        proceeds = _proceeds(_priceOf(b), give, b.initial);
        // Rounding down must never let a hit donate the asset outright.
        if (proceeds == 0) revert ZeroProceeds();
        if (proceeds < minProceeds) revert ProceedsBelowMin(proceeds, minProceeds);

        address token = b.token;

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
                refund = b.locked;
            } else {
                b.remaining = newRem;
            }
        }
        // The escrow was sized at `endPrice`, but a bid bought out before it
        // finished climbing spent less than that. The difference belongs to the
        // bidder and must leave with the close — `_close` zeroes `locked`, so
        // nothing later can reclaim it. Checked, like the debit above: escrow
        // conservation must never wrap, and an `unchecked` block around this
        // subtraction would have been the one place it could.
        if (refund != 0) {
            escrowed[quote] -= refund;
        }
        if (rem == give) _close(id, true);

        // Deliver what was bought to the position holder.
        if (b.isNFT) {
            uint256[] memory allowed = b.ids;
            // `give` is the COUNT of ids delivered, so a repeated id would be
            // paid for twice. `_moveNFT` catches that for free: the first move
            // flips ownership to the holder, and the second fails its
            // `ownerOf == from` check. The one case with no flip to catch it —
            // the self-hit, where seller and holder are the same address — is
            // refused outright above.
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
            _unwrapETH(proceeds);
            safeTransferETH(msg.sender, proceeds);
        } else {
            _sendEscrowToken(quote, msg.sender, proceeds);
        }

        // Finally, hand the bidder back whatever the climb never spent. Always
        // the QUOTE TOKEN, including for an ETH-funded bid, which is WETH-quoted
        // from the moment it opens: `cancelUnwrap` and `withdraw(unwrap: true)`
        // are the only paths that return native ETH.
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
            // AN ESCROW HOLDER IS PAID IN CANONICAL WETH EVEN WHEN THE CALLER
            // ASKED TO UNWRAP, which is the same choice Dutchboard's
            // `_payQuoteETH` makes and for the same reason: a contract holding
            // this receipt accounts for arrivals BY TOKEN, so native value
            // either bounces off its `receive` or lands as unattributable dust.
            //
            // This replaces bracketing the native send as `address(0)`. That
            // named the asset consistently with `_unwrapETH`'s delta error, but
            // it is not an address a counterparty's callback can DO anything
            // with: Dutchboard's `beforeOrderProceeds` reaches
            // `_freeBalance(address(0))`, staticcalls `balanceOf` on an empty
            // account, and reverts on the decode - so `cancelUnwrap` was
            // unusable for exactly the holders the bracket existed to serve.
            // Paying the token the escrow already tracks needs no convention.
            //
            // `quote == weth` is guaranteed here: `unwrap` is only ever true
            // from `cancelUnwrap`, which checks it.
            if (unwrap && !_accepts(holder, id)) {
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

    /// @dev Solady makes the ERC-721 mutators payable for the gas saving, and
    ///      `receive()`'s WETH-only rule does not apply when calldata selects a
    ///      payable function - so ETH attached to a transfer or an approval
    ///      lands here, where this board has no rescue path for it. Refuse it.
    ///
    ///      Guarding `transferFrom` covers all three transfer entry points:
    ///      solady's safe variants reach the move by calling this same function
    ///      in the SAME frame, where `msg.value` is still whatever the caller
    ///      attached. This is a VALUE check, not a reentrancy guard - that
    ///      distinction is what keeps it from bricking safe transfers.
    function transferFrom(address from, address to, uint256 id) public payable override {
        if (msg.value != 0) revert Bad();
        super.transferFrom(from, to, id);
    }

    function approve(address account, uint256 id) public payable override {
        if (msg.value != 0) revert Bad();
        super.approve(account, id);
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
    ///
    ///      The constant reads in both directions. `supportsInterface` DECLARES
    ///      it, for holders of this board's receipts; `_open` PROBES for it, to
    ///      refuse bidding on somebody else's live claims — see the custody
    ///      argument there.
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
                initial: b.initial,
                locked: b.locked,
                price: live ? _priceOf(b) : _priceAt(b, closedAt[id]),
                startPrice: b.startPrice,
                endPrice: b.endPrice,
                startTime: b.startTime,
                duration: b.duration,
                fillProgress: _bidFillProgress(id, b, live),
                climbProgress: _climbProgress(id, b, live),
                tokenDecimals: b.isNFT ? 0 : tokenDecimals[b.token],
                quoteDecimals: tokenDecimals[b.quote],
                tokenSymbol: tokenSymbols[b.token],
                quoteSymbol: tokenSymbols[b.quote],
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
        return _priceAt(b, block.timestamp);
    }

    /// @dev The climb evaluated at an arbitrary instant. `tokenURI` walks it back
    ///      to `closedAt` so a spent receipt can state the price its bid actually
    ///      ended at instead of a placeholder. Closing does not clear the terms,
    ///      so the curve is still there to be read.
    function _priceAt(Bid storage b, uint256 at) internal view returns (uint256) {
        if (at <= b.startTime) return b.startPrice;
        unchecked {
            uint256 elapsed = at - b.startTime;
            if (elapsed >= b.duration) return b.endPrice;
            return b.startPrice + ((uint256(b.endPrice) - b.startPrice) * elapsed) / b.duration;
        }
    }

    /// @notice Whether `give` units can be sold into `id` right now, and for
    ///         how much — the mirror of Dutchboard's `quoteFill`.
    /// @dev Returns `(false, 0)` for every stale-state refusal `_take` makes:
    ///      closed, not yet started, EXPIRED, `give == 0`, `give > remaining`,
    ///      or a split that rounds the payment to zero. Lot KIND is deliberately
    ///      not folded in: `give` is a count on the NFT path too, so this quotes
    ///      an NFT bid as usefully as a fungible one. Callers that can only
    ///      settle one kind — `tryHitMany` — screen on `isNFT` themselves.
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
        // `units = ceil(wantProceeds * initial / price)` already CLEARS the
        // target, it does not merely approach it: `price * units >= want *
        // initial`, so `price * units / initial >= want`, and flooring a value
        // at or above an integer cannot land below it. No step-up pass is
        // needed, and none is correct either — any `give` above this is simply
        // a worse answer to "the SMALLEST quantity that pays at least".
        //
        // The clamp is the one place the ceiling is overridden, and it is safe
        // for a different reason: `full >= wantProceeds` was checked above, and
        // `full` is what the whole remainder pays.
        unchecked {
            uint256 units = (wantProceeds * initial + price - 1) / price;
            if (units > b.remaining) units = b.remaining;
            give = uint128(units);
        }
        proceeds = _proceeds(price, give, initial);
        // Postcondition, not a fallback: the caller's guarantee is that feeding
        // `give` to `hit` clears `wantProceeds`, so never return a pair that
        // does not.
        if (proceeds < wantProceeds) return (0, 0);
    }

    /// @notice One packed read of everything an executor needs to route a leg.
    /// @dev Zeroes out for anything not hittable RIGHT NOW — closed, not yet
    ///      open, or past its window — so the refusals match `_quote`'s. A bid
    ///      outside its window still reported live terms and a climbing price
    ///      here, which read as routable to an executor and then reverted in
    ///      `hit`. Unlike `_quote` this does not fold in the per-leg quantity,
    ///      since the quantity is the caller's own argument.
    ///
    ///      `initial` is in the tuple because without it the read is not
    ///      actually enough to size a leg: `price` is the bid for the FULL
    ///      INITIAL LOT, and a leg of `give` units pays
    ///      `price * give / initial`, not `price * give / remaining`. Reading
    ///      `price` as the bid for `remaining` is the easy mistake, and it is
    ///      wrong for every bid the holder has already partly filled.
    function legOf(uint256 id)
        external
        view
        returns (
            address bidder,
            address token,
            address quote,
            bool isNFT,
            uint128 remaining,
            uint128 initial,
            uint256 price
        )
    {
        Bid storage b = bids[id];
        bidder = b.bidder;
        if (bidder == address(0) || block.timestamp < b.startTime) {
            return (address(0), address(0), address(0), false, 0, 0, 0);
        }
        unchecked {
            if (block.timestamp >= uint256(b.startTime) + b.duration) {
                return (address(0), address(0), address(0), false, 0, 0, 0);
            }
        }
        token = b.token;
        quote = b.quote;
        isNFT = b.isNFT;
        remaining = b.remaining;
        initial = b.initial;
        price = _priceOf(b);
    }

    /// @notice Quote asset a bid pays in. NOT a liveness test: a closed bid
    ///         keeps its terms, so this stays populated after cancel, sweep, or
    ///         a full fill, and only a slot that was never bid reads address(0).
    ///         `bids[id].bidder == address(0)` is the liveness marker.
    function quoteOf(uint256 id) external view returns (address) {
        return bids[id].quote;
    }

    /// @notice Asset a bid wants to buy. Populated for closed bids too — see
    ///         `quoteOf` on why this is not a liveness test.
    function tokenOf(uint256 id) external view returns (address) {
        return bids[id].token;
    }

    /// @notice Whether a bid targets an ERC-721 collection rather than an ERC-20.
    function isNFTOf(uint256 id) external view returns (bool) {
        return bids[id].isNFT;
    }

    /// @notice The instant AT which a bid becomes unhittable and sweepable. The
    ///         window is half-open: `_take` and `sweep` both compare with `>=`,
    ///         so the last hittable second is this value minus one.
    function expiryOf(uint256 id) public view returns (uint256) {
        Bid storage b = bids[id];
        unchecked {
            return uint256(b.startTime) + b.duration;
        }
    }

    /// @notice ERC-20 balance this board holds against no escrow liability.
    /// @dev Reverts if the board is insolvent for `token`, so this MONITORS the
    ///      conservation invariant `balanceOf >= escrowed` — a `view` enforces
    ///      nothing, and no settlement path consults it. It is also only exact
    ///      BETWEEN calls: `_open` credits `escrowed` before pulling the tokens
    ///      and `_take` debits it before sending them, so a token with transfer
    ///      hooks can observe this under-reporting or over-reporting mid-call.
    function freeBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this)) - escrowed[token];
    }

    // ---------------------------------------------------------- ASSET MOVEMENT

    /// @dev ERC-165 probe for the ERC-721 interface id. Used only to REJECT, so
    ///      a collection that does not implement ERC-165 is not made unbiddable.
    function _isERC721(address token) internal view returns (bool) {
        return _declares(token, 0x80ac58cd);
    }

    /// @dev A bounded ERC-165 probe, used only to REJECT, so a contract that
    ///      does not implement ERC-165 simply does not declare the interface.
    ///
    ///      The word is read as a NUMBER and compared to 1 rather than
    ///      `abi.decode`d as a bool, because the decoder REVERTS on a
    ///      noncanonical boolean - turning a malformed answer into a refusal of
    ///      the whole call, which is the opposite of this probe's leniency. Only
    ///      a clean 1 is affirmative. Same reading Swapboard's `_declares`
    ///      documents at length.
    function _declares(address token, bytes4 interfaceId) internal view returns (bool) {
        (bool ok, bytes memory ret) = token.staticcall{gas: 30_000}(abi.encodeWithSelector(0x01ffc9a7, interfaceId));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
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
    ///
    ///      A HOLDER THAT OPTS IN AND THEN REVERTS BRICKS ITS OWN BID: `cancel`,
    ///      `cancelUnwrap`, `sweep` and every `hit` fail for as long as the
    ///      callback fails, and the only escape is transferring the receipt to
    ///      an address that does not revert. This is the deliberate cost of
    ///      bubbling: paying an escrow that rejected its own accounting is the
    ///      worse failure. A contract holder must keep these callbacks total.
    ///      REVERT AND RETURN DATA ARE COPIED WITH A BOUND, which is why this is
    ///      assembly rather than a `.call` whose returndata Solidity copies in
    ///      full before anything can inspect its length. 32 bytes is the entire
    ///      answer and 256 is enough revert reason to debug with, so a holder
    ///      returning or reverting with a multi-megabyte blob no longer charges
    ///      the SELLER hitting the bid quadratic memory-expansion gas for a size
    ///      the holder chose. Gas is deliberately NOT capped: an honest escrow's
    ///      settlement accounting is real work, and a griefer who cannot burn gas
    ///      can simply revert to the same effect. Bounding the copy is the part
    ///      with no honest victim. Same treatment as Dutchboard's twin of this.
    ///
    ///      The reply word is read as a NUMBER and compared to 1, never
    ///      `abi.decode`d as a bool: a noncanonical boolean makes the decoder
    ///      REVERT, so a holder answering `2` would brick its own bid on every
    ///      path rather than simply declining the callbacks.
    function _notifyBeforeProceeds(address to, uint256 id, address token, uint256 amount, bool nft)
        internal
        returns (bool notify)
    {
        if (!_accepts(to, id)) return false;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x8d27ed3f)) // beforeOrderProceeds(uint256,address,uint256,bool)
            mstore(add(p, 4), id)
            mstore(add(p, 36), token)
            mstore(add(p, 68), amount)
            mstore(add(p, 100), nft)
            if iszero(call(gas(), to, 0, p, 0x84, 0x00, 0x20)) {
                let n := returndatasize()
                if gt(n, 256) { n := 256 }
                returndatacopy(p, 0, n)
                revert(p, n)
            }
            notify := and(eq(returndatasize(), 32), eq(mload(0x00), 1))
        }
    }

    /// @dev The bounded static half: does `to` opt into proceeds accounting for
    ///      `id` at all. Split out because `_release` has to know the answer
    ///      BEFORE it decides whether to unwrap - see the note there.
    function _accepts(address to, uint256 id) internal view returns (bool yes) {
        if (to.code.length == 0) return false;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x33dbef94)) // acceptsOrderProceeds(uint256)
            mstore(add(p, 4), id)
            // The staticcall is bound to its own variable first: Yul evaluates
            // an expression's arguments RIGHT TO LEFT, so folding it into
            // `and(staticcall(...), eq(returndatasize(), 32))` reads
            // `returndatasize()` from whatever call ran BEFORE this one.
            let ok := staticcall(30000, to, p, 0x24, 0x00, 0x20)
            yes := and(and(ok, eq(returndatasize(), 32)), eq(mload(0x00), 1))
        }
    }

    function _notifyAfterProceeds(address to, uint256 id, address token, uint256 amount, bool nft) internal {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x2814c622)) // afterOrderProceeds(uint256,address,uint256,bool)
            mstore(add(p, 4), id)
            mstore(add(p, 36), token)
            mstore(add(p, 68), amount)
            mstore(add(p, 100), nft)
            if iszero(call(gas(), to, 0, p, 0x84, 0x00, 0x00)) {
                let n := returndatasize()
                if gt(n, 256) { n := 256 }
                returndatacopy(p, 0, n)
                revert(p, n)
            }
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
