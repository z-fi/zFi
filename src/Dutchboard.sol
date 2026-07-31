// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {ERC721} from "../lib/solady/src/tokens/ERC721.sol";

/// @title Dutchboard
/// @notice Decaying, partially fillable orders for ERC-20s and NFTs.
/// @dev A maker escrows the sell asset and chooses a payment asset. The total
///      price decays from `startPrice` to `endPrice`; partial ERC-20 fills use
///      the original lot size so fill history does not change the schedule.
///      Address(0) denotes native ETH. Exact balance-delta checks reject
///      fee-on-transfer and no-op tokens; rebasing, reflection, upgradeable,
///      and otherwise non-standard tokens are outside the security model.
///
///      Each partial fill rounds its own quote cost upward, so splitting one
///      purchase can cost more than taking the same quantity in one fill. UIs
///      must use `costOf` and show that exact result, especially for low-decimal
///      quote assets. A listing remains live after its duration at `endPrice`;
///      `endPrice == 0` therefore deliberately creates a free terminal fill.
///      Native-ETH listings require the seller to accept ETH, and `to` should
///      be an NFT-safe destination when the sold asset is an ERC-721.
///      Listings do not auto-expire, and seller self-fills are permitted; indexers
///      should not treat every `Filled` event as an arm's-length sale.
contract Dutchboard is ERC721 {
    /// @dev Canonical WETH for this deployment; used for wrapping and unwrapping.
    address public immutable weth;

    constructor(address _weth) {
        if (_weth == address(0) || _weth.code.length == 0) revert Bad();
        weth = _weth;
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
    error NotWETH(address expected, address actual);
    error NotSeller();
    error Reentrancy();
    error CostExceeded(uint256 cost, uint256 maxCost);
    error Insufficient();
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
        id = _listERC20(msg.sender, token, quote, amount, startPrice, endPrice, startTime, duration);
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
        _checkAssets(token, quote);
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
        l.token = token;
        l.quote = quote;
        l.startPrice = sp;
        l.endPrice = ep;
        l.initial = amount;
        l.remaining = amount;
        _pullEscrowToken(token, msg.sender, amount);
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

    // ------------------------------------------------------ POSITION RECEIPTS

    function name() public pure override returns (string memory) {
        return "Dutchboard Position";
    }

    function symbol() public pure override returns (string memory) {
        return "DBPOS";
    }

    /// @dev Empty by design: a listing is fully readable through `listings`, so
    ///      a URI would either rot or restate what a caller can already fetch.
    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    /// @dev Ownership IS sellership. Keeping the stored `seller` in step on
    ///      transfer means fill payouts and cancellation keep working exactly
    ///      as before, with one source of truth rather than two. Burning is a
    ///      close, and must not rewrite `seller`, because a deleted listing is
    ///      recognised by its zero seller.
    function _afterTokenTransfer(address from, address to, uint256 id) internal override {
        if (from != address(0) && to != address(0)) {
            if (to == address(this) || to == weth) revert Bad();
            listings[id].seller = to;
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

    /// @notice List one NFT pushed with `safeTransferFrom` and encoded `PushTerms`.
    /// @dev Requires exactly one token and verifies that this board owns it before
    ///      creating the listing. Malformed data or unsolicited transfers revert.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        nonReentrant
        returns (bytes4)
    {
        if (data.length != 160) revert Bad();
        PushTerms memory t = abi.decode(data, (PushTerms));

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
        l.token = token;
        l.quote = t.quote;
        l.startPrice = sp;
        l.endPrice = ep;
        l.ids.push(tokenId);

        emit Created(id, from, token, t.quote);
        return this.onERC721Received.selector;
    }

    /// @dev Require contract addresses for token and non-native quote assets.
    function _checkAssets(address token, address quote) internal view {
        if (token == address(0) || token.code.length == 0) revert Bad();
        if (quote != address(0) && quote.code.length == 0) revert Bad();
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
    function costOf(uint256 id, uint128 take) public view returns (uint256) {
        Listing storage l = listings[id];
        if (l.seller == address(0)) return 0;
        if (block.timestamp < l.startTime) return 0;
        uint256 price = _priceOf(l);
        if (l.isNFT) {
            uint256 n = l.ids.length;
            if (take != 0 && take != n) return 0;
            return price;
        }
        if (take == 0 || take > l.remaining) return 0;
        return _cost(price, take, l.initial);
    }

    /// @dev Round up so a positive-price fill cannot round to zero. This is
    ///      intentionally applied independently per fill; splitting a lot can
    ///      therefore cost more than one fill for the same aggregate quantity.
    function _cost(uint256 price, uint128 take, uint128 initial) internal pure returns (uint256) {
        unchecked {
            return (price * take + initial - 1) / initial;
        }
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

    /// @dev Settle one leg and return the ETH forwarded to its seller. `ethAvailable`
    ///      is the remaining batch value; refunds happen once in the caller.
    function _settle(uint256 id, uint128 take, address to, uint256 maxCost, uint256 ethAvailable)
        internal
        returns (uint256 ethUsed)
    {
        Listing storage l = listings[id];
        address seller = l.seller;
        if (seller == address(0)) revert Bad();
        // Do not send a lot to this board or its WETH wrapper.
        if (to == address(0) || to == address(this) || to == weth) revert Bad();
        // A scheduled listing cannot be filled before its start time.
        if (block.timestamp < l.startTime) revert Bad();

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
            _burn(id);
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
                if (newRem == 0) {
                    delete listings[id];
                    _burn(id);
                } else {
                    l.remaining = newRem;
                }
            }
            _sendEscrowToken(token, to, take);
        }

        // Update the listing before giving the quote asset control.
        if (quote == address(0)) {
            // Check the remaining batch value, not the original msg.value.
            if (ethAvailable < cost) revert Insufficient();
            // A zero-price leg needs no ETH call.
            if (cost != 0) safeTransferETH(seller, cost);
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
            _burn(id);
            for (uint256 i; i < ids.length; ++i) {
                _returnNFT(token, msg.sender, ids[i]);
            }
        } else {
            uint256 rem = l.remaining;
            delete listings[id];
            _burn(id);
            if (rem != 0) _sendEscrowToken(token, msg.sender, rem);
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
        delete listings[id];
        _burn(id);
        _unwrapETH(rem);
        safeTransferETH(msg.sender, rem);
        emit Cancelled(id);
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
    function _payQuoteToken(address token, address from, address to, uint256 amount) internal {
        if (amount == 0 || from == to) return;
        uint256 fromBefore = IERC20(token).balanceOf(from);
        uint256 toBefore = IERC20(token).balanceOf(to);
        safeTransferFromERC20(token, from, to, amount);

        uint256 spent = _decrease(fromBefore, IERC20(token).balanceOf(from));
        if (spent != amount) revert BalanceDeltaMismatch(token, from, amount, spent);

        uint256 received = _increase(toBefore, IERC20(token).balanceOf(to));
        if (received != amount) revert BalanceDeltaMismatch(token, to, amount, received);
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
