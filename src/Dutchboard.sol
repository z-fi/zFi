// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {ERC721} from "../lib/solady/src/tokens/ERC721.sol";
import {PositionSVG} from "./utils/PositionSVG.sol";
import {DutchboardMetadata} from "./utils/DutchboardMetadata.sol";

/// @title Dutchboard
/// @notice Decaying, partially fillable orders for ERC-20s and NFTs.
/// @dev A maker escrows the sell asset and chooses a payment asset. The total
///      price decays from `startPrice` to `endPrice`; partial ERC-20 fills use
///      the original lot size so fill history does not change the schedule.
///      Address(0) denotes native ETH on the QUOTE side, where takers pay in
///      raw value and change is refunded. The SELL side is always a token, so
///      selling ETH goes through `listETH`, which wraps the attached value into
///      a canonical-WETH lot; `cancelUnwrap` returns the remainder as ETH. Exact balance-delta checks reject
///      fee-on-transfer and no-op tokens; rebasing, reflection, upgradeable,
///      and otherwise non-standard tokens are outside the security model.
///
///      Each partial fill rounds its own quote cost upward, so splitting one
///      purchase can cost more than taking the same quantity in one fill. UIs
///      must use `costOf` and show that exact result, especially for low-decimal
///      quote assets. A listing with no expiry remains live after its duration
///      at `endPrice`; `endPrice == 0` therefore deliberately creates a free
///      terminal fill, and that resting floor is exactly why `expiry` exists:
///      it is a hard stop on the fill window, independent of the decay
///      schedule, after which anyone may `sweepExpired` the escrow back to its
///      holder. `expiry == 0` keeps the original resting behaviour.
///      Native-ETH listings require the seller to accept ETH, and `to` should
///      be an NFT-safe destination when the sold asset is an ERC-721.
///      Listings auto-expire only when a maker sets `expiry`; seller self-fills
///      are permitted; indexers
///      should not treat every `Filled` event as an arm's-length sale.
contract Dutchboard is ERC721 {
    /// @dev Canonical WETH for this deployment; used for wrapping and unwrapping.
    address public immutable weth;

    /// @dev Deployed once, by this board, and never replaceable. Presentation
    ///      code is most of the bytecode and none of the risk, so it lives
    ///      outside the EIP-170 budget without becoming upgradeable.
    DutchboardMetadata public immutable METADATA_RENDERER;

    constructor(address _weth) {
        if (_weth == address(0) || _weth.code.length == 0) revert Bad();
        weth = _weth;
        METADATA_RENDERER = new DutchboardMetadata();
    }

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
        uint40 expiry; // 0 = never expires, as on Swapboard
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
        uint40 expiry;
        uint256[] ids;
        uint256 price;
        bool takeable; // folds in start time, expiry and `frozen`
    }

    uint256 public nextId;
    mapping(uint256 => Listing) public listings;

    /// @notice ERC-20 escrow this board owes to live listings, per token.
    /// @dev Escrow is POOLED: every listing in a given token shares one board
    ///      balance, so a single listing's `remaining` says nothing about what
    ///      the board owes overall. It is used to maintain the conservation
    ///      invariant across fills and cancellations.
    ///      NFT lots are held by id and never counted here.
    mapping(address token => uint256 amount) public escrowed;

    /// @dev Proceeds that a settling position contract has proven arrived for an
    ///      escrowed position.
    mapping(uint256 id => mapping(address token => uint256 amount)) public claimableProceeds;
    mapping(uint256 id => mapping(address token => mapping(uint256 tokenId => bool))) public claimableNFTProceeds;

    /// @notice Sum of `claimableProceeds` across every listing, per token.
    /// @dev The second half of the board's ERC-20 liability. Solvency is
    ///      `balanceOf(this) >= escrowed[token] + totalClaimable[token]`, and
    ///      the proceeds callbacks measure the difference — the UNALLOCATED
    ///      balance — rather than the raw balance, so a deposit that also
    ///      creates a liability (a new listing) cannot be counted as an arrival.
    mapping(address token => uint256 amount) public totalClaimable;

    /// @dev True while an NFT sits in this board as credited proceeds rather
    ///      than as listing escrow. Keeps the two custody states disjoint: one
    ///      board-held NFT backs exactly one liability.
    mapping(address token => mapping(uint256 tokenId => bool)) public heldAsProceeds;

    /// @notice A listing whose underlying live position has settled, so its
    ///         terms no longer describe what a buyer would receive.
    /// @dev Frozen listings are unfillable but still live: their proceeds
    ///      registration survives, further settlement callbacks keep crediting
    ///      them, and the seller can `cancel` to recover the escrow.
    mapping(uint256 id => bool) public frozen;

    /// @dev `listing id + 1` for each escrowed NFT — the board's NFT custody
    ///      index, and the authority list for proceeds callbacks. The paired
    ///      callbacks are bound to the exact `(caller, orderId, token, amount,
    ///      nft)` tuple, so a collection cannot credit assets it did not deliver.
    mapping(address board => mapping(uint256 orderId => uint256 listingPlusOne)) internal liveClaimListing;

    /// @dev Terminal listings retain display data; this distinguishes a full
    ///      settlement from a maker cancellation.
    mapping(uint256 id => bool) public settled;

    /// @notice Units the seller has reclaimed from a live lot via `withdraw`.
    /// @dev Only written when a withdrawal actually happens, so listings that
    ///      never use the feature pay nothing for it. Kept out of the packed
    ///      `Listing` for that reason, and read back by `tokenURI` so reclaimed
    ///      inventory is not rendered as filled inventory.
    mapping(uint256 id => uint128 amount) public withdrawn;

    /// @dev The last live instant of a terminal receipt. Metadata uses it to
    /// render the curve position at settlement/cancellation instead of letting
    /// a spent receipt drift to the end of the schedule over wall-clock time.
    mapping(uint256 id => uint40 timestamp) internal closedAt;

    /// @dev `decimals + 1`, zero for the explicit raw fallback. Snapshotted at
    ///      creation so tokenURI never calls untrusted token code.
    mapping(address token => uint8 snapshot) public tokenDecimals;

    /// @dev Optional, sanitised ERC-721 symbol captured at listing time.
    mapping(address token => string symbol) internal tokenSymbols;

    event Created(uint256 indexed id, address indexed seller, address indexed token, address quote);
    event Filled(uint256 indexed id, address indexed seller, address indexed buyer, uint256 amount, uint256 paid);
    event Cancelled(uint256 indexed id);
    event Withdrawn(uint256 indexed id, uint256 amount);
    event Frozen(uint256 indexed id);
    event ProceedsCredited(
        uint256 indexed id, address indexed source, uint256 indexed sourceOrderId, address token, uint256 amount, bool nft
    );
    event ProceedsClaimed(uint256 indexed id, address indexed token, address indexed to, uint256 amount, bool nft);

    error Bad();
    error Expired();
    error NotExpired();
    error NotSeller();
    error Reentrancy();
    error Insufficient();
    error NotWETH(address expected, address actual);
    error CostExceeded(uint256 cost, uint256 maxCost);
    error NFTTransferFailed(address token, uint256 tokenId);
    error BalanceDeltaMismatch(address token, address account, uint256 expected, uint256 actual);
    error ProceedsInFlight(address token);
    error InvalidProceedsCallback();
    error NoClaimableProceeds();

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

    // ------------------------------------------------------------------- LISTING

    /// @notice List an ERC-20 amount priced in `quote`; partial fills are allowed.
    /// @dev `startTime == 0` starts immediately. Prices must be nonzero and
    ///      nonincreasing; `endPrice` may be zero, which makes the lot free
    ///      after the decay completes unless the seller cancels first.
    /// @param quote Payment asset, or address(0) for native ETH.
    function listERC20(
        address token,
        address quote,
        uint128 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration
    ) public nonReentrant returns (uint256 id) {
        id = _listERC20(msg.sender, token, quote, amount, startPrice, endPrice, startTime, duration, 0, false);
    }

    /// @notice `listERC20` with a hard expiry after which the lot is unfillable
    ///         and permissionlessly sweepable.
    /// @dev Expiry is opt-in rather than the default because it changes what a
    ///      resting listing MEANS, and existing callers wrote their listings
    ///      expecting the resting floor. `0` keeps the original behaviour, which
    ///      is the same `0 = never` convention Swapboard uses.
    function listERC20(
        address token,
        address quote,
        uint128 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration,
        uint40 expiry
    ) public nonReentrant returns (uint256 id) {
        id = _listERC20(msg.sender, token, quote, amount, startPrice, endPrice, startTime, duration, expiry, false);
    }

    /// @notice List escrow supplied by the caller while assigning seller rights
    ///         to `seller`.
    /// @dev The caller supplies the escrow; fills and cancellation remain owned
    ///      by `seller`.
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
        id = _listERC20(seller, token, quote, amount, startPrice, endPrice, startTime, duration, 0, false);
    }

    /// @notice `listERC20For` with a hard expiry.
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
    ) public nonReentrant returns (uint256 id) {
        id = _listERC20(seller, token, quote, amount, startPrice, endPrice, startTime, duration, expiry, false);
    }

    /// @notice Sell native ETH: the attached value is wrapped and listed as a
    ///         canonical-WETH lot priced in `quote`.
    /// @dev The board escrows tokens, not native balance, so the sell side has
    ///      one asset model and one set of exact-delta invariants. Wrapping at
    ///      the boundary is what lets a seller deposit raw ETH without that
    ///      model growing a second, weaker branch on every transfer path.
    ///      `cancelUnwrap` is the matching exit: the unsold remainder leaves as
    ///      native ETH again. Buy-side ETH already needs no wrapper - pass
    ///      `quote == address(0)` and takers pay `fill` in native value.
    function listETH(
        address quote,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration
    ) public payable nonReentrant returns (uint256 id) {
        id = _listETH(msg.sender, quote, startPrice, endPrice, startTime, duration, 0);
    }

    /// @notice `listETH` with a hard expiry. Sweeping an expired WETH lot
    ///         returns canonical WETH; use `cancelUnwrap` to exit as native ETH.
    function listETH(
        address quote,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration,
        uint40 expiry
    ) public payable nonReentrant returns (uint256 id) {
        id = _listETH(msg.sender, quote, startPrice, endPrice, startTime, duration, expiry);
    }

    /// @notice Wrap and list the caller's ETH while assigning seller rights to
    ///         `seller`.
    function listETHFor(
        address seller,
        address quote,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration
    ) public payable nonReentrant returns (uint256 id) {
        id = _listETH(seller, quote, startPrice, endPrice, startTime, duration, 0);
    }

    /// @notice `listETHFor` with a hard expiry.
    function listETHFor(
        address seller,
        address quote,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration,
        uint40 expiry
    ) public payable nonReentrant returns (uint256 id) {
        id = _listETH(seller, quote, startPrice, endPrice, startTime, duration, expiry);
    }

    /// @dev `msg.value` is the lot size, so a zero value falls through to the
    ///      shared `amount == 0` rejection rather than minting an empty lot.
    ///      A native-ETH quote would make this a WETH/ETH listing of itself,
    ///      which the shared `token == quote` check does not catch because the
    ///      sold asset is recorded as WETH; reject it explicitly.
    function _listETH(
        address seller,
        address quote,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration,
        uint40 expiry
    ) internal returns (uint256 id) {
        if (quote == address(0) || msg.value > type(uint128).max) revert Bad();
        id = _listERC20(
            seller, weth, quote, uint128(msg.value), startPrice, endPrice, startTime, duration, expiry, true
        );
    }

    function _listERC20(
        address seller,
        address token,
        address quote,
        uint128 amount,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration,
        uint40 expiry,
        bool fromETH
    ) internal returns (uint256 id) {
        (uint96 sp, uint96 ep) = _checkPrices(startPrice, endPrice);
        _checkAssets(token, quote);
        if (_isERC721(token)) revert Bad(); // M-01: never through the fungible path
        if (
            seller == address(0) || seller == address(this) || seller == weth || amount == 0 || duration == 0
                || token == quote || (startTime != 0 && startTime < block.timestamp)
        ) {
            revert Bad();
        }
        unchecked {
            id = nextId++;
        }
        Listing storage l = listings[id];
        l.seller = seller;
        _mint(seller, id);
        l.startTime = startTime == 0 ? uint40(block.timestamp) : startTime;
        l.duration = duration;
        l.expiry = _checkExpiry(l.startTime, expiry);
        l.token = token;
        l.quote = quote;
        l.startPrice = sp;
        l.endPrice = ep;
        l.initial = amount;
        l.remaining = amount;
        _rememberDecimals(token);
        if (quote != address(0)) _rememberDecimals(quote);
        unchecked {
            escrowed[token] += amount;
        }
        if (fromETH) {
            _wrapETH(amount);
        } else {
            _pullEscrowToken(token, msg.sender, amount);
        }
        emit Created(id, seller, token, quote);
    }

    /// @notice List up to 100 NFTs from one ERC-721 collection as one full-fill lot.
    /// @dev The caller must approve every token. Use `onERC721Received` for a
    ///      single NFT when an approval-free push is preferred.
    function listNFT(
        address token,
        address quote,
        uint256[] calldata ids,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration
    ) public returns (uint256 id) {
        id = listNFT(token, quote, ids, startPrice, endPrice, startTime, duration, 0);
    }

    /// @notice `listNFT` with a hard expiry.
    function listNFT(
        address token,
        address quote,
        uint256[] calldata ids,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration,
        uint40 expiry
    ) public nonReentrant returns (uint256 id) {
        (uint96 sp, uint96 ep) = _checkPrices(startPrice, endPrice);
        _checkAssets(token, quote);
        if (
            ids.length == 0 || ids.length > 100 || duration == 0 || token == quote
                || (startTime != 0 && startTime < block.timestamp)
        ) revert Bad();
        unchecked {
            id = nextId++;
        }
        Listing storage l = listings[id];
        l.seller = msg.sender;
        _mint(msg.sender, id);
        l.isNFT = true;
        l.startTime = startTime == 0 ? uint40(block.timestamp) : startTime;
        l.duration = duration;
        l.expiry = _checkExpiry(l.startTime, expiry);
        l.token = token;
        l.quote = quote;
        l.startPrice = sp;
        l.endPrice = ep;
        l.ids = ids;
        _rememberSymbol(token);
        if (quote != address(0)) _rememberDecimals(quote);
        for (uint256 i; i < ids.length; ++i) {
            _moveNFT(token, msg.sender, address(this), ids[i]);
            _registerLiveClaim(token, ids[i], id);
        }
        emit Created(id, msg.sender, token, quote);
    }

    // ------------------------------------------------------ POSITION RECEIPTS

    /// @dev Same reasoning as Swapboard's, including where the guard goes. A
    ///      listing transfer hands sellership over BEFORE the recipient's
    ///      `onERC721Received` runs, so the safe variants are guarded; plain
    ///      `transferFrom` makes no external call and is not, because solady
    ///      routes the safe variants THROUGH it and guarding both would nest
    ///      and revert as reentrancy on every safe transfer.
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
    ///      A position can be filled by anyone at any time, which pays its
    ///      proceeds to whoever holds it and closes it. That is fine for a
    ///      wallet and wrong for an escrow: a contract holding the position as
    ///      inert collateral receives tokens it has no accounting for, and
    ///      finds the token it was holding has ceased to exist. Dutchboard uses
    ///      exact before/after proceeds callbacks to account for settlement
    ///      instead of treating board-wide balances as receipt-attributable.
    bytes4 internal constant LIVE_ORDER_POSITION = 0x28a93a2e;

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == LIVE_ORDER_POSITION || super.supportsInterface(interfaceId);
    }

    function name() public pure override returns (string memory) {
        return "Dutchboard Position";
    }

    function symbol() public pure override returns (string memory) {
        return "DBPOS";
    }

    /// @notice Live, self-contained terminal metadata for the listing receipt.
    /// @dev Rendered by the immutable renderer this board deployed. Every
    ///      untrusted read is already snapshotted in storage, so assembling the
    ///      params calls no third-party code.
    function tokenURI(uint256 id) public view override returns (string memory) {
        address holder = ownerOf(id);
        Listing storage l = listings[id];
        bool live = l.seller != address(0);
        return METADATA_RENDERER.tokenURI(
            DutchboardMetadata.RenderParams({
                id: id,
                seller: live ? l.seller : holder,
                token: l.token,
                quote: l.quote,
                lotSize: l.ids.length,
                remaining: l.remaining,
                price: live ? _priceOf(l) : 0,
                startPrice: l.startPrice,
                endPrice: l.endPrice,
                startTime: l.startTime,
                duration: l.duration,
                fillProgress: _listingFillProgress(id, l, live),
                decayProgress: _decayProgress(id, l, live),
                expiry: l.expiry,
                tokenDecimals: l.isNFT ? 0 : _decimalsOf(l.token),
                quoteDecimals: l.quote == address(0) ? 19 : _decimalsOf(l.quote),
                tokenSymbol: tokenSymbols[l.token],
                isNFT: l.isNFT,
                live: live,
                settled: settled[id],
                frozen: frozen[id]
            })
        );
    }

    /// @dev Measured against the lot NET of withdrawals. `initial - remaining`
    ///      alone counts reclaimed units as sold, which would show a seller who
    ///      pulled half their lot as being half filled.
    function _listingFillProgress(uint256 id, Listing storage l, bool live) internal view returns (uint256) {
        if (!live && settled[id]) return 10_000;
        if (l.isNFT || l.initial == 0) return 0;
        uint256 offered = uint256(l.initial) - withdrawn[id];
        if (offered == 0) return 0;
        return ((offered - l.remaining) * 10_000) / offered;
    }

    function _decimalsOf(address token) internal view returns (uint8 snapshot) {
        snapshot = tokenDecimals[token];
        if (snapshot == 0 && token == weth) snapshot = 19;
    }

    function _rememberDecimals(address token) internal {
        if (tokenDecimals[token] != 0) return;
        (bool known, uint8 decimals) = PositionSVG.readDecimals(token);
        if (known) tokenDecimals[token] = decimals + 1;
    }

    function _rememberSymbol(address token) internal {
        if (bytes(tokenSymbols[token]).length == 0) tokenSymbols[token] = PositionSVG.readSymbol(token);
    }

    function _decayProgress(uint256 id, Listing storage l, bool live) internal view returns (uint256) {
        uint256 progressTime = live ? block.timestamp : closedAt[id];
        if (progressTime <= l.startTime) return 0;
        uint256 elapsed = progressTime - l.startTime;
        if (elapsed >= l.duration) return 10_000;
        return (elapsed * 10_000) / l.duration;
    }

    /// @dev Ownership IS sellership. Keeping the stored `seller` in step on
    ///      transfer means fill payouts and cancellation keep working exactly
    ///      as before, with one source of truth rather than two. Burning is a
    ///      close, and must not rewrite `seller`, because a deleted listing is
    ///      recognised by its zero seller.
    function _afterTokenTransfer(address from, address to, uint256 id) internal override {
        if (from != address(0) && to != address(0)) {
            if (to == address(this) || to == weth) revert Bad();
            // Only a LIVE listing tracks its holder. Receipts outlive their
            // listings now, and a closed one is recognised by its zero seller -
            // writing here unconditionally would resurrect a deleted record
            // every time a spent ticket changed hands, putting a phantom
            // listing back into `getListings` and back in front of takers.
            if (listings[id].seller != address(0)) listings[id].seller = to;
        }
    }

    /// @notice Curve parameters carried in push-listing transfer data.
    struct PushTerms {
        address quote;
        uint256 startPrice;
        uint256 endPrice;
        uint40 startTime;
        uint40 duration;
    }

    /// @notice `PushTerms` plus a hard expiry.
    /// @dev A separate struct rather than a sixth field on `PushTerms`, because
    ///      the push path identifies its payload BY LENGTH and a 160-byte blob
    ///      cannot be decoded as a six-field tuple. Encoding either one is
    ///      valid: 160 bytes keeps the resting-floor behaviour, 192 bytes opts
    ///      into expiry.
    struct PushTermsExpiring {
        address quote;
        uint256 startPrice;
        uint256 endPrice;
        uint40 startTime;
        uint40 duration;
        uint40 expiry;
    }

    /// @notice List one NFT pushed with `safeTransferFrom` and encoded `PushTerms`.
    /// @dev Requires exactly one token and verifies that this board owns it before
    ///      creating the listing. Malformed data or unsolicited transfers revert.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        nonReentrant
        returns (bytes4)
    {
        PushTermsExpiring memory t;
        if (data.length == 160) {
            PushTerms memory legacy = abi.decode(data, (PushTerms));
            t = PushTermsExpiring(legacy.quote, legacy.startPrice, legacy.endPrice, legacy.startTime, legacy.duration, 0);
        } else if (data.length == 192) {
            t = abi.decode(data, (PushTermsExpiring));
        } else {
            revert Bad();
        }

        address token = msg.sender; // the collection, established by the call itself
        // This board is an ERC-721 now, so a position pushed back here would
        // try to escrow its own receipt against itself.
        if (token == address(this)) revert Bad();
        (uint96 sp, uint96 ep) = _checkPrices(t.startPrice, t.endPrice);
        _checkAssets(token, t.quote);
        if (
            from == address(0) || from == address(this) || from == weth || token == t.quote || t.duration == 0
                || (t.startTime != 0 && t.startTime < block.timestamp)
        ) revert Bad();

        // Verify, do not move: a direct caller transferring nothing must not be able to
        // mint a listing over escrow that is already backing someone else's.
        if (IERC721(token).ownerOf(tokenId) != address(this)) revert NFTTransferFailed(token, tokenId);
        // ...nor over an NFT the board already owes out as credited proceeds.
        // `_registerLiveClaim` below rejects the listing-escrow half of this.
        if (heldAsProceeds[token][tokenId]) revert Bad();

        uint256 id;
        unchecked {
            id = nextId++;
        }
        Listing storage l = listings[id];
        l.seller = from;
        _mint(from, id);
        l.isNFT = true;
        l.startTime = t.startTime == 0 ? uint40(block.timestamp) : t.startTime;
        l.duration = t.duration;
        l.expiry = _checkExpiry(l.startTime, t.expiry);
        l.token = token;
        l.quote = t.quote;
        l.startPrice = sp;
        l.endPrice = ep;
        l.ids.push(tokenId);
        _registerLiveClaim(token, tokenId, id);
        _rememberSymbol(token);
        if (t.quote != address(0)) _rememberDecimals(t.quote);

        emit Created(id, from, token, t.quote);
        return this.onERC721Received.selector;
    }

    /// @notice Claim ERC-20 proceeds proven to have arrived for this position.
    /// @dev Kept under its existing selector. Unlike the former board-wide
    ///      surplus sweep, this can release only a balance credited by the
    ///      before/after settlement callbacks below.
    function claimSurplus(uint256 id, address token, address to) external nonReentrant returns (uint256 amount) {
        if (ownerOf(id) != msg.sender) revert NotSeller();
        if (to == address(0) || to == address(this)) revert Bad();
        amount = claimableProceeds[id][token];
        if (amount == 0) revert NoClaimableProceeds();
        claimableProceeds[id][token] = 0;
        totalClaimable[token] -= amount;
        _sendEscrowToken(token, to, amount);
        emit ProceedsClaimed(id, token, to, amount, false);
    }

    /// @notice Claim an ERC-721 payment proven to have arrived for this position.
    function claimNFTProceeds(uint256 id, address token, uint256 tokenId, address to) external nonReentrant {
        if (ownerOf(id) != msg.sender) revert NotSeller();
        if (to == address(0) || to == address(this) || to == weth) revert Bad();
        if (!claimableNFTProceeds[id][token][tokenId]) revert NoClaimableProceeds();
        claimableNFTProceeds[id][token][tokenId] = false;
        heldAsProceeds[token][tokenId] = false;
        _moveNFT(token, address(this), to, tokenId);
        emit ProceedsClaimed(id, token, to, tokenId, true);
    }

    /// @dev Require contract addresses for token and non-native quote assets.
    ///      An ERC-721 must never reach a fungible path: it shares `balanceOf`
    ///      and `transferFrom(address,address,uint256)` with ERC-20, so token id
    ///      1 would satisfy every exact-delta check this board makes while the
    ///      matching `transfer(address,uint256)` does not exist — locking the
    ///      NFT on the sell side, and silently moving id 1 on the quote side.
    function _checkAssets(address token, address quote) internal view {
        if (token == address(0) || token.code.length == 0) revert Bad();
        if (quote != address(0)) {
            if (quote.code.length == 0 || _isERC721(quote)) revert Bad();
        }
    }

    /// @dev ERC-165 probe for the ERC-721 interface id. Used only to REJECT, so
    ///      a collection that does not implement ERC-165 is not made unlistable;
    ///      it simply keeps the pre-existing "do not list weird assets" posture.
    function _isERC721(address token) internal view returns (bool) {
        (bool ok, bytes memory ret) = token.staticcall{gas: 30_000}(abi.encodeWithSelector(0x01ffc9a7, bytes4(0x80ac58cd)));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }

    /// @dev Index every escrowed NFT. This is the board's NFT custody map: it
    ///      makes double-listing one token id impossible, and it is the
    ///      authority list for proceeds callbacks. A collection cannot credit
    ///      unrelated funds because the paired callbacks are bound to one exact
    ///      tuple and measure an exact arrival.
    function _registerLiveClaim(address token, uint256 orderId, uint256 listingId) internal {
        if (liveClaimListing[token][orderId] != 0 || heldAsProceeds[token][orderId]) revert Bad();
        liveClaimListing[token][orderId] = listingId + 1;
    }

    /// @notice True only while `msg.sender` has an NFT position actively
    ///         escrowed by this board. Swapboard probes this before callbacks.
    function acceptsOrderProceeds(uint256 orderId) external view returns (bool) {
        return _hasLiveClaimListing(msg.sender, orderId);
    }

    /// @notice Snapshot the destination immediately before a position contract
    ///         pays an escrowed position. Callable only by its registered
    ///         collection, and bound to one exact settlement.
    /// @dev Two properties do the work here.
    ///
    ///      The transient slot is keyed by the WHOLE tuple
    ///      `(msg.sender, orderId, token, amount, nft)`. Nothing the `after`
    ///      leg reports can differ from what the `before` leg was measured
    ///      against, so "some NFT left" and "some NFT arrived" can no longer be
    ///      two different NFTs.
    ///
    ///      The fungible snapshot is the UNALLOCATED balance, not the raw one.
    ///      Every ordinary board operation moves balance and liability
    ///      together — a listing deposit raises `escrowed`, a cancel or fill
    ///      lowers it, a claim lowers `totalClaimable` — so no interleaved call
    ///      can manufacture an apparent arrival. Only a genuinely unaccounted
    ///      inbound transfer moves this number.
    function beforeOrderProceeds(uint256 orderId, address token, uint256 amount, bool nft)
        external
        nonReentrant
        returns (bool accepted)
    {
        if (!_hasLiveClaimListing(msg.sender, orderId)) return false;
        bytes32 slot = _proceedsSlot(msg.sender, orderId, token, amount, nft);
        if (_tload(slot) != 0) revert ProceedsInFlight(token);
        if (nft) {
            // This board's own receipts are minted, not escrowed; an inbound
            // "arrival" of one would be a fabrication.
            if (token == address(this)) revert InvalidProceedsCallback();
            if (IERC721(token).ownerOf(amount) == address(this)) revert InvalidProceedsCallback();
            _tstore(slot, 1);
        } else {
            uint256 free = _freeBalance(token);
            if (free > type(uint256).max - 2) revert InvalidProceedsCallback();
            _tstore(slot, free + 2);
        }
        return true;
    }

    /// @notice Verify and credit the corresponding settlement payment.
    /// @dev Crediting also FREEZES the outer listing. A live position that has
    ///      settled — fully or partially — is no longer the thing the listing
    ///      advertised: its proceeds now belong to the receipt holder, not to
    ///      whoever buys the spent underlying next. Freezing rather than
    ///      closing keeps the registration alive, so later partial settlements
    ///      still credit here instead of stranding, and the seller can `cancel`
    ///      to take the changed position back and relist it.
    function afterOrderProceeds(uint256 orderId, address token, uint256 amount, bool nft) external nonReentrant {
        uint256 listingId = _proceedsListing(msg.sender, orderId);
        bytes32 slot = _proceedsSlot(msg.sender, orderId, token, amount, nft);
        uint256 snapshot = _tload(slot);
        if (snapshot == 0) revert InvalidProceedsCallback();
        _tstore(slot, 0);

        if (nft) {
            if (snapshot != 1 || IERC721(token).ownerOf(amount) != address(this)) revert InvalidProceedsCallback();
            claimableNFTProceeds[listingId][token][amount] = true;
            heldAsProceeds[token][amount] = true;
        } else {
            if (snapshot == 1 || _freeBalance(token) != snapshot - 2 + amount) revert InvalidProceedsCallback();
            claimableProceeds[listingId][token] += amount;
            totalClaimable[token] += amount;
        }
        if (!frozen[listingId]) {
            frozen[listingId] = true;
            emit Frozen(listingId);
        }
        emit ProceedsCredited(listingId, msg.sender, orderId, token, amount, nft);
    }

    /// @notice ERC-20 balance this board holds against no liability.
    /// @dev Reverts if the board is ever insolvent for `token`, which makes the
    ///      conservation invariant `balanceOf >= escrowed + totalClaimable`
    ///      enforced rather than merely monitored.
    function freeBalance(address token) external view returns (uint256) {
        return _freeBalance(token);
    }

    function _freeBalance(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(address(this)) - escrowed[token] - totalClaimable[token];
    }

    function _proceedsListing(address board, uint256 orderId) internal view returns (uint256 listingId) {
        uint256 encoded = liveClaimListing[board][orderId];
        if (encoded == 0) revert InvalidProceedsCallback();
        unchecked {
            listingId = encoded - 1;
        }
        if (listings[listingId].seller == address(0)) revert InvalidProceedsCallback();
    }

    function _hasLiveClaimListing(address board, uint256 orderId) internal view returns (bool) {
        uint256 encoded = liveClaimListing[board][orderId];
        if (encoded == 0) return false;
        unchecked {
            return listings[encoded - 1].seller != address(0);
        }
    }

    bytes32 internal constant _PROCEEDS_TRANSIENT_BASE = keccak256("Dutchboard.proceeds.snapshot");

    /// @dev Bind the complete callback context. Anything the `after` leg varies
    ///      lands on a different, empty slot and reverts.
    function _proceedsSlot(address board, uint256 orderId, address token, uint256 amount, bool nft)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_PROCEEDS_TRANSIENT_BASE, board, orderId, token, amount, nft));
    }

    function _tload(bytes32 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /// @dev `0` means the listing never expires, preserving the resting-floor
    ///      behaviour every pre-expiry caller was written against. A nonzero
    ///      expiry must be in the future and after the listing opens, since an
    ///      expiry at or before `startTime` would mint something that could
    ///      never be filled at all.
    function _checkExpiry(uint40 startTime, uint40 expiry) internal view returns (uint40) {
        if (expiry == 0) return 0;
        if (expiry <= block.timestamp || expiry <= startTime) revert Bad();
        return expiry;
    }

    /// @dev Whether a listing's fill window has closed. Expiry is INCLUSIVE, as
    ///      on Swapboard: a fill landing exactly at `expiry` still settles.
    function _isExpired(Listing storage l) internal view returns (bool) {
        uint40 expiry = l.expiry;
        return expiry != 0 && block.timestamp > expiry;
    }

    /// @dev Check the price range before narrowing to uint96.
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

    /// @notice Whether a listing is an ERC-721 bundle rather than an ERC-20 lot.
    /// @dev Kept narrow so atomic executors can reject NFT listings before they
    ///      attempt ERC-20 balance accounting.
    function isNFTOf(uint256 id) external view returns (bool) {
        return listings[id].isNFT;
    }

    /// @dev Callers check that the listing is live before calling this helper.
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
    ///         a listing whose window has not opened, NFT with mismatched `take`, ERC20
    ///         with `take == 0` or `take > remaining`.
    ///         Because zero is also a legitimate price for a fully decayed lot,
    ///         prefer `quoteFill`, which separates the two meanings.
    function costOf(uint256 id, uint128 take) public view returns (uint256 cost) {
        (, cost) = _quote(id, take);
    }

    /// @dev Round up so a positive-price fill cannot round to zero. This is
    ///      intentionally applied independently per fill; splitting a lot can
    ///      therefore cost more than one fill for the same aggregate quantity.
    function _cost(uint256 price, uint128 take, uint128 initial) internal pure returns (uint256) {
        unchecked {
            return (price * take + initial - 1) / initial;
        }
    }

    // ------------------------------------------------------------- SPLIT QUOTE

    /// @notice Whether `take` units of `id` can be filled right now, and at what
    ///         cost — the unambiguous form of `costOf`.
    /// @dev `costOf` answers with a single number, and zero has to mean two
    ///      different things there: "you cannot fill this" and "this lot is
    ///      genuinely free". Both are reachable - a decayed listing with
    ///      `endPrice == 0` costs nothing, which is documented behaviour rather
    ///      than an edge case - so a router reading `costOf` alone either skips
    ///      free lots or submits doomed legs for closed ones. Splitting the
    ///      answer in two is the fix; `costOf` is kept as it was for existing
    ///      callers.
    function quoteFill(uint256 id, uint128 take) public view returns (bool fillable, uint256 cost) {
        return _quote(id, take);
    }

    /// @dev Every stale-state refusal in `_settle`, in one view. Deliberately
    ///      NOT including `maxCost` or the recipient: those are the caller's own
    ///      arguments rather than something the book can go stale on.
    function _quote(uint256 id, uint128 take) internal view returns (bool fillable, uint256 cost) {
        Listing storage l = listings[id];
        if (l.seller == address(0) || frozen[id]) return (false, 0);
        if (block.timestamp < l.startTime || _isExpired(l)) return (false, 0);
        uint256 price = _priceOf(l);
        if (l.isNFT) {
            if (take != 0 && take != l.ids.length) return (false, 0);
            return (true, price);
        }
        if (take == 0 || take > l.remaining) return (false, 0);
        return (true, _cost(price, take, l.initial));
    }

    /// @notice Largest quantity of `id` buyable for at most `maxSpend`, and what
    ///         it actually costs.
    /// @dev The exact-input primitive a splitter needs and could not previously
    ///      get: allocating a budget across a book means asking each venue "how
    ///      much does this much money buy", and inverting a decaying,
    ///      round-up-per-fill curve off chain is where a route drifts into
    ///      `CostExceeded`. Passing the returned `take` straight into `fill`
    ///      always costs `cost <= maxSpend`.
    ///
    ///      NFT lots are indivisible, so the answer is the whole bundle or
    ///      nothing. A fully decayed free lot is affordable at any budget,
    ///      including zero, which is the same terminal behaviour `fill` has.
    function takeFor(uint256 id, uint256 maxSpend) public view returns (uint128 take, uint256 cost) {
        Listing storage l = listings[id];
        if (l.seller == address(0) || frozen[id] || block.timestamp < l.startTime || _isExpired(l)) return (0, 0);

        uint256 price = _priceOf(l);
        if (l.isNFT) {
            if (price > maxSpend) return (0, 0);
            return (uint128(l.ids.length), price);
        }

        uint128 rem = l.remaining;
        uint128 initial = l.initial;
        if (rem == 0) return (0, 0);

        // Whole remainder first. This is also the only branch a free lot can
        // reach, so the division below never sees a zero price.
        uint256 full = _cost(price, rem, initial);
        if (full <= maxSpend) return (rem, full);

        // maxSpend < full <= price here, and price fits uint96 while initial
        // fits uint128, so the product cannot overflow.
        unchecked {
            uint256 units = (maxSpend * initial) / price;
            if (units == 0) return (0, 0);
            if (units > rem) units = rem;
            take = uint128(units);
        }
        // ceil(price * take / initial) <= ceil(maxSpend * initial / initial),
        // so this is affordable by construction.
        cost = _cost(price, take, initial);
    }

    /// @notice One packed read of everything an executor needs to route a leg.
    /// @dev Replaces the three separate staticcalls (`isNFTOf`, `quoteOf`,
    ///      `tokenOf`) an executor currently makes per leg, which is both three
    ///      times the gas and three chances to read a listing that changed
    ///      between them. `lotSize` is the NFT bundle size, zero for ERC-20 lots.
    function legOf(uint256 id)
        external
        view
        returns (
            address seller,
            address token,
            address quote,
            bool isNFT,
            uint128 remaining,
            uint256 lotSize,
            uint256 price
        )
    {
        Listing storage l = listings[id];
        seller = l.seller;
        if (seller == address(0) || frozen[id] || _isExpired(l)) {
            return (address(0), address(0), address(0), false, 0, 0, 0);
        }
        token = l.token;
        quote = l.quote;
        isNFT = l.isNFT;
        remaining = l.remaining;
        lotSize = l.ids.length;
        price = _priceOf(l);
    }

    /// @notice Fill a listing, paying in its `quote`.
    /// @param take ERC20 units to buy; for NFTs, pass 0 or the full bundle size.
    /// @param to Recipient of the lot. For NFTs, use an address that can safely
    ///        hold an ERC-721; delivery uses `transferFrom`, not a receiver hook.
    /// @param maxCost Maximum payment; use `type(uint256).max` for no bound.
    function fill(uint256 id, uint128 take, address to, uint256 maxCost) public payable nonReentrant {
        // Reject ETH attached to an ERC20-quoted single fill.
        if (msg.value != 0 && listings[id].quote != address(0)) revert Bad();

        uint256 ethUsed = _settle(id, take, to, maxCost, msg.value);
        unchecked {
            if (msg.value > ethUsed) safeTransferETH(msg.sender, msg.value - ethUsed);
        }
    }

    /// @notice Fill several listings atomically.
    /// @dev ETH legs share `msg.value`; unused value is refunded once at the end.
    ///      Each leg is bounded by its `maxCosts` entry.
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

    /// @notice Fill several listings, stepping over legs that are no longer
    ///         takeable instead of aborting the batch.
    /// @dev The counterpart to Swapboard's `tryFillOrders`, and the reason a
    ///      split route needs one: a router carves an order across several
    ///      listings from a book it read one block earlier, and against a public
    ///      book any single leg may be taken, cancelled, or decayed past its
    ///      `maxCosts` entry before inclusion. Under `fillMany` that one leg
    ///      reverts the whole route and the taker gets nothing; here the rest of
    ///      the plan still executes and `filled` reports what landed.
    ///
    ///      Only STALE-STATE refusals are skipped - closed, not yet started,
    ///      quantity no longer available, priced above the leg's bound, or more
    ///      ETH than the batch has left. A settlement that reverts once started
    ///      still aborts everything, exactly as on Swapboard: a failing transfer
    ///      is a broken asset rather than a race, and swallowing it would leave
    ///      the board's escrow accounting behind.
    /// @return filled Which legs settled, positionally.
    /// @return ethSpent Total ETH forwarded to sellers across the batch.
    function tryFillMany(uint256[] calldata ids, uint128[] calldata takes, uint256[] calldata maxCosts, address to)
        public
        payable
        nonReentrant
        returns (bool[] memory filled, uint256 ethSpent)
    {
        uint256 n = ids.length;
        if (n == 0) revert Bad();
        if (n != takes.length || n != maxCosts.length) revert Bad();
        // Checked once, up front. A bad recipient is the caller's own error, not
        // something the book went stale on, so it must fail loudly rather than
        // skip every leg and report an empty fill as success.
        if (to == address(0) || to == address(this) || to == weth) revert Bad();

        filled = new bool[](n);
        for (uint256 i; i < n; ++i) {
            uint256 available;
            unchecked {
                available = msg.value - ethSpent;
            }
            (bool ok, uint256 cost) = _quote(ids[i], takes[i]);
            if (!ok || cost > maxCosts[i]) continue;
            if (listings[ids[i]].quote == address(0) && cost > available) continue;

            unchecked {
                ethSpent += _settle(ids[i], takes[i], to, maxCosts[i], available);
            }
            filled[i] = true;
        }

        unchecked {
            if (msg.value > ethSpent) safeTransferETH(msg.sender, msg.value - ethSpent);
        }
    }

    /// @dev Settle one leg and return the ETH forwarded to its seller. `ethAvailable`
    ///      is the remaining batch value; refunds happen once in the caller.
    function _settle(uint256 id, uint128 take, address to, uint256 maxCost, uint256 ethAvailable)
        internal
        returns (uint256 ethUsed)
    {
        Listing storage l = listings[id];
        address seller = l.seller;
        if (seller == address(0)) revert Bad();
        // The underlying live position settled while escrowed: its terms no
        // longer describe what a buyer would receive, so only `cancel` remains.
        if (frozen[id]) revert Bad();
        // Do not send a lot to this board or its WETH wrapper.
        if (to == address(0) || to == address(this) || to == weth) revert Bad();
        // A scheduled listing cannot be filled before its start time.
        if (block.timestamp < l.startTime) revert Bad();
        // ...nor after a maker-set expiry, which unlike the decay schedule is a
        // hard stop rather than a floor to rest at.
        if (_isExpired(l)) revert Expired();

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
            _close(id, true);
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
                // A partial fill leaves the listing live, so its receipt
                // survives with a smaller claim; only exhaustion burns it.
                // Not burned on exhaustion: a holder may be a contract that
                // reads `ownerOf`, and burning under it strands whatever it
                // holds. The receipt survives as a spent ticket.
                if (newRem == 0) _close(id, true);
                else l.remaining = newRem;
            }
            // Checked on purpose: escrow conservation must never wrap.
            escrowed[token] -= take;
            _sendEscrowToken(token, to, take);
        }

        // Update the listing before giving the quote asset control.
        if (quote == address(0)) {
            // Check the remaining batch value, not the original msg.value.
            if (ethAvailable < cost) revert Insufficient();
            // A zero-price leg needs no ETH call.
            if (cost != 0) _payQuoteETH(seller, id, cost);
            ethUsed = cost;
        } else {
            _payQuoteToken(quote, msg.sender, seller, cost, id);
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
            _close(id, false);
            for (uint256 i; i < ids.length; ++i) {
                _returnNFT(token, msg.sender, ids[i]);
            }
        } else {
            uint256 rem = l.remaining;
            _close(id, false);
            if (rem != 0) {
                escrowed[token] -= rem;
                _sendEscrowToken(token, msg.sender, rem);
            }
        }
        emit Cancelled(id);
    }

    /// @notice Seller reclaims part of an unsold ERC-20 lot without closing the
    ///         listing.
    /// @dev The safe half of "editing" a live order, and the reason it is safe
    ///      is that it moves `remaining` WITHOUT touching `initial`. Price is
    ///      defined as the total for the full INITIAL lot and every fill divides
    ///      by `initial` (`_cost`), so leaving that denominator alone leaves the
    ///      per-unit price of every remaining unit exactly as advertised. A
    ///      taker racing this withdrawal can therefore never be repriced; the
    ///      worst case is that their `take` no longer fits and the fill reverts,
    ///      which `tryFillMany` already classifies as a stale-state skip.
    ///
    ///      The reverse edit — topping the lot back up — is deliberately absent:
    ///      it would have to raise `initial`, which silently reprices every
    ///      remaining unit downward, so it needs a pro-rata price rescale rather
    ///      than a mirror of this function.
    ///
    ///      NFT lots are excluded. A bundle is sold whole (`_settle` requires
    ///      `take == ids.length`) and its price is the bundle price, so removing
    ///      an id would change what the remaining lot IS, not merely how much of
    ///      it is left.
    /// @param amount Units to reclaim. Must leave a nonzero remainder — use
    ///        `cancel` to close the listing outright.
    /// @param unwrap Take the withdrawal as native ETH; canonical-WETH lots only.
    function withdraw(uint256 id, uint128 amount, bool unwrap) external nonReentrant {
        Listing storage l = listings[id];
        if (l.seller != msg.sender) revert NotSeller();
        if (l.isNFT) revert Bad();

        uint128 rem = l.remaining;
        // A withdrawal that empties the lot is a cancellation, and must go
        // through `cancel` so the receipt closes rather than resting at zero.
        if (amount == 0 || amount >= rem) revert Bad();

        address token = l.token;
        unchecked {
            l.remaining = rem - amount;
        }
        // Tracked separately so `tokenURI` does not report reclaimed inventory
        // as though takers had bought it.
        withdrawn[id] += amount;
        escrowed[token] -= amount;

        if (unwrap) {
            if (token != weth) revert NotWETH(weth, token);
            _unwrapETH(amount);
            safeTransferETH(msg.sender, amount);
        } else {
            _sendEscrowToken(token, msg.sender, amount);
        }
        emit Withdrawn(id, amount);
    }

    /// @notice Anyone may close an EXPIRED listing, returning the escrow to its
    ///         holder.
    /// @dev The half of expiry that actually removes the babysitting, and the
    ///      counterpart to Swapboard's `sweepExpired`. Once the window has
    ///      closed the listing is unfillable anyway, so letting anyone reclaim
    ///      it on the holder's behalf turns a dead-but-funded slot into a
    ///      self-clearing one. Escrow goes to the RECORDED SELLER — which
    ///      tracks the receipt owner — never to the caller, so the only thing a
    ///      sweeper can do is return assets to the person owed them.
    ///
    ///      Deliberately not gated on `frozen`: a frozen listing that also
    ///      expired is doubly dead, and the seller should not be the only one
    ///      able to unstick it.
    function sweepExpired(uint256 id) external nonReentrant {
        Listing storage l = listings[id];
        address holder = l.seller;
        if (holder == address(0)) revert Bad();
        if (!_isExpired(l)) revert NotExpired();

        address token = l.token;
        if (l.isNFT) {
            uint256[] memory ids = l.ids;
            _close(id, false);
            for (uint256 i; i < ids.length; ++i) {
                _returnNFT(token, holder, ids[i]);
            }
        } else {
            uint256 rem = l.remaining;
            _close(id, false);
            if (rem != 0) {
                escrowed[token] -= rem;
                _sendEscrowToken(token, holder, rem);
            }
        }
        emit Cancelled(id);
    }

    /// @notice Seller closes a fungible canonical-WETH listing and receives its
    ///         unsold remainder as native ETH.
    /// @dev Delete storage before unwrapping and paying the seller.
    function cancelUnwrap(uint256 id) external nonReentrant {
        Listing storage l = listings[id];
        if (l.seller != msg.sender) revert NotSeller();
        if (l.isNFT) revert Bad();
        address token = l.token;
        if (token != weth) revert NotWETH(weth, token);

        uint256 rem = l.remaining;
        _close(id, false);
        escrowed[token] -= rem;
        _unwrapETH(rem);
        safeTransferETH(msg.sender, rem);
        emit Cancelled(id);
    }

    /// @dev Retain immutable display terms after a receipt is spent. A zero
    ///      seller remains the sole liveness marker used everywhere else.
    function _close(uint256 id, bool filled) internal {
        Listing storage l = listings[id];
        if (l.isNFT) {
            uint256[] storage ids = l.ids;
            for (uint256 i; i < ids.length; ++i) {
                delete liveClaimListing[l.token][ids[i]];
            }
        }
        l.seller = address(0);
        closedAt[id] = uint40(block.timestamp);
        if (filled) {
            settled[id] = true;
            l.remaining = 0;
        }
    }

    // ---------------------------------------------------------- ASSET MOVEMENT

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

    /// @dev Confirm the exact WETH credit from wrapping. The native debit is
    ///      not checked against a snapshot: ETH can be force-fed into this
    ///      board without executing `receive()`, so only the token side is a
    ///      sound invariant - the same asymmetry `_unwrapETH` documents.
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
        if (spent != amount) {
            revert BalanceDeltaMismatch(weth, address(this), amount, spent);
        }

        uint256 received = _increase(ethBefore, address(this).balance);
        if (received != amount) {
            revert BalanceDeltaMismatch(address(0), address(this), amount, received);
        }
    }

    /// @dev Confirm exact taker debit and seller credit; self-fills need no transfer.
    ///      When the seller is itself an escrow holding this receipt, the payment
    ///      is bracketed by its proceeds callbacks so it can attribute the
    ///      arrival instead of finding an unexplained balance it cannot release.
    function _payQuoteToken(address token, address from, address to, uint256 amount, uint256 id) internal {
        if (amount == 0 || from == to) return;
        bool notify = _notifyBeforeProceeds(to, id, token, amount);

        uint256 fromBefore = IERC20(token).balanceOf(from);
        uint256 toBefore = IERC20(token).balanceOf(to);
        safeTransferFromERC20(token, from, to, amount);

        uint256 spent = _decrease(fromBefore, IERC20(token).balanceOf(from));
        if (spent != amount) revert BalanceDeltaMismatch(token, from, amount, spent);

        uint256 received = _increase(toBefore, IERC20(token).balanceOf(to));
        if (received != amount) revert BalanceDeltaMismatch(token, to, amount, received);

        if (notify) _notifyAfterProceeds(to, id, token, amount);
    }

    /// @dev Native-ETH proceeds owed to an escrow are delivered as canonical
    ///      WETH. An escrow holding this receipt is a contract that accounts for
    ///      arrivals by token; a bare ETH send would either bounce off its
    ///      `receive` or land as unattributable, unrecoverable dust. Ordinary
    ///      sellers are unaffected and still receive native ETH.
    function _payQuoteETH(address seller, uint256 id, uint256 cost) internal {
        if (_notifyBeforeProceeds(seller, id, weth, cost)) {
            IWETH(weth).deposit{value: cost}();
            _sendEscrowToken(weth, seller, cost);
            _notifyAfterProceeds(seller, id, weth, cost);
        } else {
            safeTransferETH(seller, cost);
        }
    }

    /// @dev The same opt-in probe Swapboard makes of this board, in the other
    ///      direction: a bounded static call, and only an affirmative answer
    ///      turns on the stateful callbacks. Reverts inside an accepted callback
    ///      bubble up — an escrow that opted in and then refused the accounting
    ///      must not be paid anyway.
    function _notifyBeforeProceeds(address to, uint256 id, address token, uint256 amount)
        internal
        returns (bool)
    {
        if (to.code.length == 0) return false;
        (bool ok, bytes memory ret) = to.staticcall{gas: 30_000}(abi.encodeWithSelector(0x33dbef94, id));
        if (!ok || ret.length != 32 || !abi.decode(ret, (bool))) return false;
        (ok, ret) = to.call(abi.encodeWithSelector(0x8d27ed3f, id, token, amount, false));
        if (!ok) _bubbleRevert(ret);
        return ret.length == 32 && abi.decode(ret, (bool));
    }

    function _notifyAfterProceeds(address to, uint256 id, address token, uint256 amount) internal {
        (bool ok, bytes memory ret) = to.call(abi.encodeWithSelector(0x2814c622, id, token, amount, false));
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

    /// @dev Treat an NFT already returned to its seller as complete; otherwise
    ///      require the board to own it before transferring it back.
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
    /// @dev `v.seller == address(0)` is the SOLE liveness marker: the slot was
    ///      never listed, or the listing has closed. A closed listing keeps its
    ///      historical terms on purpose — token, quote, times, prices and NFT
    ///      ids stay populated so a spent receipt still renders and indexers can
    ///      report what was sold; only `seller` and `price` come back zero.
    ///      `frozen[id]` marks a still-open listing that is no longer fillable.
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
        v.expiry = l.expiry;
        v.ids = l.ids;
        v.price = v.seller == address(0) ? 0 : _priceOf(l);
        (v.takeable,) = _quote(id, l.isNFT ? 0 : l.remaining);
    }

    /// @notice Paginated book helper: snapshots for ids in `[start, end)`. `end` is
    ///         clamped to `nextId`. Closed slots come back with a zero `seller`
    ///         and their historical terms intact, so a caller can still correlate
    ///         index to id — see `getListing`.
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
    function deposit() external payable;
}

// Solady safe transfer helpers:

error TransferFailed();

error ETHTransferFailed();

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

function safeTransferETH(address to, uint256 amount) {
    assembly ("memory-safe") {
        if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
            mstore(0x00, 0xb12d13eb)
            revert(0x1c, 0x04)
        }
    }
}
