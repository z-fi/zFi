# DutchAuction
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/DutchAuction.sol)

**Title:**
DutchAuction

Dutch auction (linear price decay) for a single NFT, a bundle of NFTs,
or an ERC20 amount, settled in ETH. Partial fills are supported for
ERC20 listings (useful as a price-discovery token sale). Seller can
cancel and reclaim the unsold portion at any time.

Assets are escrowed on listing. `startPrice` must be >= `endPrice`;
the listed `startPrice`/`endPrice` is the total ETH for the full initial
lot; the price decays linearly from `startPrice` at `startTime` to
`endPrice` at `startTime+duration` and is flat outside that window
(`endPrice` may be 0, so a lot can decay to free). ERC20 fills cost
`ceil(priceOf(id) * take / initial)` — rounded up so a buy with a
positive price can't round to 0 when `initial` is much larger than
the current price.


## State Variables
### nextId

```solidity
uint256 public nextId
```


### auctions

```solidity
mapping(uint256 => Auction) public auctions
```


### _REENTRANCY_GUARD_SLOT
Transient-storage slot (EIP-1153) for the reentrancy guard. Requires a
Cancun-era EVM. Arbitrary high slot chosen to avoid colliding with any
EIP-1967-style or application-defined transient slots.


```solidity
uint256 constant _REENTRANCY_GUARD_SLOT = 0x929eee149b4bd21268
```


## Functions
### nonReentrant


```solidity
modifier nonReentrant() ;
```

### listNFT

List one or more NFTs (max 100) from a single ERC721 contract as one lot.
Caller must have approved this contract for every id in `ids` (per-id
`approve` or `setApprovalForAll` both work).
Pass `startTime == 0` to start immediately; any non-zero `startTime` must
not be in the past. `startPrice` must be non-zero and >= `endPrice`.


```solidity
function listNFT(
    address token,
    uint256[] calldata ids,
    uint128 startPrice,
    uint128 endPrice,
    uint40 startTime,
    uint40 duration
) public nonReentrant returns (uint256 id);
```

### listERC20

List an ERC20 amount for sale. Partial fills are allowed.
Caller must approve this contract for `amount`. Only plain ERC20s
are supported; fee-on-transfer and rebasing tokens are out of scope.
Pass `startTime == 0` to start immediately; any non-zero `startTime` must
not be in the past. `startPrice` must be non-zero and >= `endPrice`.


```solidity
function listERC20(
    address token,
    uint128 amount,
    uint128 startPrice,
    uint128 endPrice,
    uint40 startTime,
    uint40 duration
) public nonReentrant returns (uint256 id);
```

### priceOf

Current total price for the full initial lot at `block.timestamp`.
Returns 0 for unknown/closed listings.


```solidity
function priceOf(uint256 id) public view returns (uint256);
```

### _priceOf

Callers must have already confirmed the slot is live (seller != 0); skipping the
guard avoids a duplicate slot-0 SLOAD and, for internal callers, a redundant
keccak for the mapping lookup.


```solidity
function _priceOf(Auction storage a) internal view returns (uint256);
```

### fill

Fill a listing with ETH.

NFT bundles: pass `take == 0` or `take == ids.length`; the whole lot is
bought at `priceOf`. Mismatched `take` reverts to avoid buyer confusion.
ERC20: buys `take` units for `ceil(priceOf * take / initial)`.


```solidity
function fill(uint256 id, uint128 take) public payable nonReentrant;
```

### cancel

Seller closes the listing and reclaims escrowed assets: the full NFT
bundle, or the unsold remainder of an ERC20 lot.


```solidity
function cancel(uint256 id) public nonReentrant;
```

### costOf

ETH cost to take `take` units of `id` at the current price — mirrors `fill`.
NFT bundles: pass `take == 0` or the full bundle size; returns the lot price.
ERC20: returns `ceil(priceOf(id) * take / initial)`.
Returns 0 for anything the UI should treat as non-fillable: closed listing,
NFT with mismatched `take`, or ERC20 with `take == 0` or `take > remaining`.


```solidity
function costOf(uint256 id, uint128 take) public view returns (uint256);
```

### getAuction

Flattened snapshot of listing `id` for a UI (listing fields + current price
+ `isNFT`). `v.id` echoes the input; every other field is zero if `id` was
never listed or has closed (check `v.seller == address(0)`).


```solidity
function getAuction(uint256 id) public view returns (AuctionView memory v);
```

### getAuctions

Paginated gallery helper: returns snapshots for ids in `[start, end)`.
`end` is clamped to `nextId`. Closed/cancelled slots come back zeroed
(seller == address(0)) so the caller can correlate index to id.


```solidity
function getAuctions(uint256 start, uint256 end) public view returns (AuctionView[] memory out);
```

## Events
### Created

```solidity
event Created(uint256 indexed id, address indexed seller, address indexed token);
```

### Filled

```solidity
event Filled(uint256 indexed id, address indexed seller, address indexed buyer, uint256 amount, uint256 paid);
```

### Cancelled

```solidity
event Cancelled(uint256 indexed id);
```

## Errors
### Bad

```solidity
error Bad();
```

### NotSeller

```solidity
error NotSeller();
```

### Reentrancy

```solidity
error Reentrancy();
```

### Insufficient

```solidity
error Insufficient();
```

## Structs
### Auction

```solidity
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
```

### AuctionView
Flattened snapshot for frontends: raw listing fields plus the current price
and an `isNFT` flag. `seller == address(0)` marks a slot that never existed
or has closed (cancelled / fully filled).


```solidity
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
```

