// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title DutchAuction
/// @notice Dutch auction (linear price decay) for a single NFT, a bundle of NFTs,
///         or an ERC20 amount, settled in ETH. Partial fills are supported for
///         ERC20 listings (useful as a price-discovery token sale). Seller can
///         cancel and reclaim the unsold portion at any time.
/// @dev    Assets are escrowed on listing. `startPrice` must be >= `endPrice`;
///         the listed `startPrice`/`endPrice` is the total ETH for the full initial
///         lot; the price decays linearly from `startPrice` at `startTime` to
///         `endPrice` at `startTime+duration` and is flat outside that window
///         (`endPrice` may be 0, so a lot can decay to free). ERC20 fills cost
///         `ceil(priceOf(id) * take / initial)` — rounded up so a buy with a
///         positive price can't round to 0 when `initial` is much larger than
///         the current price.
contract DutchAuction {
    struct Auction {
        // slot 0: seller(20) + isNFT(1) + startTime(5) + duration(5) = 31, 1 free.
        // Packing `isNFT` and the time fields alongside `seller` lets `_priceOf` and the
        // NFT/ERC20 discriminator hit slot 0 for free after the initial seller SLOAD.
        address seller;
        bool isNFT;
        uint40 startTime;
        uint40 duration;
        address token; // slot 1
        uint128 startPrice; // slot 2
        uint128 endPrice;
        uint128 initial; // slot 3; ERC20 only, 0 for NFT
        uint128 remaining; // slot 3; ERC20 only, 0 for NFT
        uint256[] ids; // slot 4; NFT only, empty for ERC20
    }

    /// @dev Flattened snapshot for frontends: raw listing fields plus the current price
    ///      and an `isNFT` flag. `seller == address(0)` marks a slot that never existed
    ///      or has closed (cancelled / fully filled).
    struct AuctionView {
        uint256 id;
        address seller;
        address token;
        bool isNFT;
        uint40 startTime;
        uint40 duration;
        uint128 startPrice;
        uint128 endPrice;
        uint128 initial;
        uint128 remaining;
        uint256[] ids;
        uint256 price;
    }

    uint256 public nextId;
    mapping(uint256 => Auction) public auctions;

    event Created(uint256 indexed id, address indexed seller, address indexed token);
    event Filled(uint256 indexed id, address indexed seller, address indexed buyer, uint256 amount, uint256 paid);
    event Cancelled(uint256 indexed id);

    error Bad();
    error NotSeller();
    error Reentrancy();
    error Insufficient();

    /// @dev Transient-storage slot (EIP-1153) for the reentrancy guard. Requires a
    ///      Cancun-era EVM. Arbitrary high slot chosen to avoid colliding with any
    ///      EIP-1967-style or application-defined transient slots.
    uint256 constant _REENTRANCY_GUARD_SLOT = 0x929eee149b4bd21268;

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

    /// @notice List one or more NFTs (max 100) from a single ERC721 contract as one lot.
    ///         Caller must have approved this contract for every id in `ids` (per-id
    ///         `approve` or `setApprovalForAll` both work).
    ///         Pass `startTime == 0` to start immediately; any non-zero `startTime` must
    ///         not be in the past. `startPrice` must be non-zero and >= `endPrice`.
    function listNFT(
        address token,
        uint256[] calldata ids,
        uint128 startPrice,
        uint128 endPrice,
        uint40 startTime,
        uint40 duration
    ) public nonReentrant returns (uint256 id) {
        if (
            ids.length == 0 || ids.length > 100 || duration == 0 || startPrice == 0 || startPrice < endPrice
                || (startTime != 0 && startTime < block.timestamp)
        ) revert Bad();
        unchecked {
            id = nextId++;
        }
        Auction storage a = auctions[id];
        a.seller = msg.sender;
        a.isNFT = true;
        a.startTime = startTime == 0 ? uint40(block.timestamp) : startTime;
        a.duration = duration;
        a.token = token;
        a.startPrice = startPrice;
        a.endPrice = endPrice;
        a.ids = ids;
        for (uint256 i; i < ids.length; ++i) {
            IERC721(token).transferFrom(msg.sender, address(this), ids[i]);
        }
        emit Created(id, msg.sender, token);
    }

    /// @notice List an ERC20 amount for sale. Partial fills are allowed.
    ///         Caller must approve this contract for `amount`. Only plain ERC20s
    ///         are supported; fee-on-transfer and rebasing tokens are out of scope.
    ///         Pass `startTime == 0` to start immediately; any non-zero `startTime` must
    ///         not be in the past. `startPrice` must be non-zero and >= `endPrice`.
    function listERC20(
        address token,
        uint128 amount,
        uint128 startPrice,
        uint128 endPrice,
        uint40 startTime,
        uint40 duration
    ) public nonReentrant returns (uint256 id) {
        if (
            amount == 0 || duration == 0 || startPrice == 0 || startPrice < endPrice
                || (startTime != 0 && startTime < block.timestamp)
        ) revert Bad();
        unchecked {
            id = nextId++;
        }
        Auction storage a = auctions[id];
        a.seller = msg.sender;
        a.startTime = startTime == 0 ? uint40(block.timestamp) : startTime;
        a.duration = duration;
        a.token = token;
        a.startPrice = startPrice;
        a.endPrice = endPrice;
        a.initial = amount;
        a.remaining = amount;
        safeTransferFrom(token, msg.sender, address(this), amount);
        emit Created(id, msg.sender, token);
    }

    /// @notice Current total price for the full initial lot at `block.timestamp`.
    ///         Returns 0 for unknown/closed listings.
    function priceOf(uint256 id) public view returns (uint256) {
        Auction storage a = auctions[id];
        if (a.seller == address(0)) return 0;
        return _priceOf(a);
    }

    /// @dev Callers must have already confirmed the slot is live (seller != 0); skipping the
    ///      guard avoids a duplicate slot-0 SLOAD and, for internal callers, a redundant
    ///      keccak for the mapping lookup.
    function _priceOf(Auction storage a) internal view returns (uint256) {
        if (block.timestamp <= a.startTime) return a.startPrice;
        unchecked {
            uint256 elapsed = block.timestamp - a.startTime;
            if (elapsed >= a.duration) return a.endPrice;
            return a.startPrice - ((uint256(a.startPrice) - a.endPrice) * elapsed) / a.duration;
        }
    }

    /// @notice Fill a listing with ETH.
    /// @dev    NFT bundles: pass `take == 0` or `take == ids.length`; the whole lot is
    ///         bought at `priceOf`. Mismatched `take` reverts to avoid buyer confusion.
    ///         ERC20: buys `take` units for `ceil(priceOf * take / initial)`.
    function fill(uint256 id, uint128 take) public payable nonReentrant {
        Auction storage a = auctions[id];
        address seller = a.seller;
        if (seller == address(0)) revert Bad();
        uint256 price = _priceOf(a);
        address token = a.token;

        if (a.isNFT) {
            uint256[] memory ids = a.ids;
            uint256 n = ids.length;
            if (take != 0 && take != n) revert Bad();
            if (msg.value < price) revert Insufficient();
            delete auctions[id];
            for (uint256 i; i < n; ++i) {
                IERC721(token).transferFrom(address(this), msg.sender, ids[i]);
            }
            safeTransferETH(seller, price);
            unchecked {
                if (msg.value > price) safeTransferETH(msg.sender, msg.value - price);
            }
            emit Filled(id, seller, msg.sender, n, price);
        } else {
            uint128 rem = a.remaining;
            uint128 initial = a.initial;
            if (take == 0 || take > rem) revert Bad();
            uint256 cost;
            unchecked {
                // Ceiling division: prevents a positive-price buy from rounding to cost=0
                // when `initial` is much larger than the current price.
                cost = (price * take + initial - 1) / initial;
            }
            if (msg.value < cost) revert Insufficient();
            unchecked {
                uint128 newRem = rem - take;
                if (newRem == 0) delete auctions[id];
                else a.remaining = newRem;
            }
            safeTransfer(token, msg.sender, take);
            safeTransferETH(seller, cost);
            unchecked {
                if (msg.value > cost) safeTransferETH(msg.sender, msg.value - cost);
            }
            emit Filled(id, seller, msg.sender, take, cost);
        }
    }

    /// @notice Seller closes the listing and reclaims escrowed assets: the full NFT
    ///         bundle, or the unsold remainder of an ERC20 lot.
    function cancel(uint256 id) public nonReentrant {
        Auction storage a = auctions[id];
        if (a.seller != msg.sender) revert NotSeller();
        address token = a.token;
        if (a.isNFT) {
            uint256[] memory ids = a.ids;
            delete auctions[id];
            for (uint256 i; i < ids.length; ++i) {
                IERC721(token).transferFrom(address(this), msg.sender, ids[i]);
            }
        } else {
            uint256 rem = a.remaining;
            delete auctions[id];
            if (rem != 0) safeTransfer(token, msg.sender, rem);
        }
        emit Cancelled(id);
    }

    /// @notice ETH cost to take `take` units of `id` at the current price — mirrors `fill`.
    ///         NFT bundles: pass `take == 0` or the full bundle size; returns the lot price.
    ///         ERC20: returns `ceil(priceOf(id) * take / initial)`.
    ///         Returns 0 for anything the UI should treat as non-fillable: closed listing,
    ///         NFT with mismatched `take`, or ERC20 with `take == 0` or `take > remaining`.
    function costOf(uint256 id, uint128 take) public view returns (uint256) {
        Auction storage a = auctions[id];
        if (a.seller == address(0)) return 0;
        uint256 price = _priceOf(a);
        if (a.isNFT) {
            uint256 n = a.ids.length;
            if (take != 0 && take != n) return 0;
            return price;
        }
        if (take == 0 || take > a.remaining) return 0;
        unchecked {
            return (price * take + a.initial - 1) / a.initial;
        }
    }

    /// @notice Flattened snapshot of listing `id` for a UI (listing fields + current price
    ///         + `isNFT`). `v.id` echoes the input; every other field is zero if `id` was
    ///         never listed or has closed (check `v.seller == address(0)`).
    function getAuction(uint256 id) public view returns (AuctionView memory v) {
        Auction storage a = auctions[id];
        v.id = id;
        v.seller = a.seller;
        v.token = a.token;
        v.isNFT = a.isNFT;
        v.startTime = a.startTime;
        v.duration = a.duration;
        v.startPrice = a.startPrice;
        v.endPrice = a.endPrice;
        v.initial = a.initial;
        v.remaining = a.remaining;
        v.ids = a.ids;
        v.price = v.seller == address(0) ? 0 : _priceOf(a);
    }

    /// @notice Paginated gallery helper: returns snapshots for ids in `[start, end)`.
    ///         `end` is clamped to `nextId`. Closed/cancelled slots come back zeroed
    ///         (seller == address(0)) so the caller can correlate index to id.
    function getAuctions(uint256 start, uint256 end) public view returns (AuctionView[] memory out) {
        if (end > nextId) end = nextId;
        uint256 n = start < end ? end - start : 0;
        out = new AuctionView[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = getAuction(start + i);
        }
    }
}

interface IERC721 {
    function transferFrom(address from, address to, uint256 id) external;
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
