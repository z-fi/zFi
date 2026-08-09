// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.36;

import {PositionSVG} from "./utils/PositionSVG.sol";
import {ERC721} from "../lib/solady/src/tokens/ERC721.sol";
import {SwapboardMetadata} from "./utils/SwapboardMetadata.sol";
import {Multicallable} from "../lib/solady/src/utils/Multicallable.sol";
import {SafeTransferLib} from "../lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "../lib/solady/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "../lib/solady/src/utils/ReentrancyGuardTransient.sol";

/// @title Swapboard
/// @notice Escrowed peer-to-peer orders. Either side may be an ERC-20 or an
///         ERC-721, with optional partial fills, an optional maker-side expiry
///         and an optional named counterparty.
///
/// @dev tokenA is escrowed on creation and returned on cancellation or fill;
///      tokenB is paid by the taker. ERC-721 amounts are token IDs and cannot be
///      partially filled. Expiry is maker-side and inclusive; fill deadlines are
///      taker-side and inclusive. Escrow transfers use exact balance or
///      ownership checks.
///
///      ETH is a boundary concern, not an order type: raw value enters through
///      `createOrderWithEth` / `fillOrderWithEth` and leaves through
///      `fillOrderUnwrap`, wrapped and unwrapped against the immutable canonical
///      WETH at the edge. Orders themselves only ever reference tokens, so
///      settlement keeps one asset model and one set of exact-delta invariants,
///      and permissionless paths like `cancelExpired` never make a value call to
///      arbitrary code. Integrators reading `tokenA`/`tokenB` see WETH where a
///      user deposited ETH; UIs should present that pair as ETH.
///
/// @dev Fungible tokenA transfers are measured on both sides, and direct
///      fungible tokenB payments are measured at the maker. NFT ownership and
///      WETH wrap/unwrap deltas are checked exactly. `counterparty` restricts
///      fills to one caller; recipient only controls delivery. Anyone may sweep
///      expired orders, and typed batch methods are atomic unless prefixed `try`.
///      Rebasing and reflection tokens remain unsupported because pooled escrow
///      balances can change between calls; integrators should allowlist assets.
contract Swapboard is ERC721, ReentrancyGuardTransient, Multicallable {
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

    struct ReplaceOrderParams {
        uint256 orderId;
        uint256 amountA;
        uint256 amountB;
        uint64 expiry;
    }

    address public immutable weth;
    /// @notice Per-board immutable renderer; it has no owner or upgrade path.
    SwapboardMetadata public immutable METADATA_RENDERER;
    uint256 public nextOrderId;
    mapping(uint256 orderId => Order order) public orders;

    /// @notice The ask this order was last written against.
    /// @dev The live SVG receipt needs a denominator for fill progress, and
    ///      `amountB` cannot be its own: it is decremented on every partial
    ///      fill. This is set at creation and reset by `replaceOrder`, which
    ///      restarts the order's fill progress along with its price. Public
    ///      because the renderer reads it for itself; see `tokenURI`.
    mapping(uint256 orderId => uint256 amount) public initialAmountB;

    /// @notice `decimals + 1`, zero for an unavailable/non-standard response.
    /// @dev Captured at creation so rendering never depends on token code, and
    ///      read by the renderer rather than passed to it; see `tokenURI`.
    mapping(address token => uint8 snapshot) public tokenDecimals;

    /// @notice Optional, sanitised symbol captured at order creation.
    /// @dev Read by the renderer rather than passed to it; see `tokenURI`.
    mapping(address token => string symbol) public tokenSymbols;

    /// @notice Whether this board is escrowing `tokenId` of `collection` for a
    ///         live order right now.
    /// @dev `ownerOf` answers "is the board holding this token", which is NOT
    ///      the question escrow solvency asks: a token the board is already
    ///      holding for somebody else's order answers it just as affirmatively
    ///      as one this call deposited. The push path moves nothing, so
    ///      `ownerOf` was the only thing standing between a collection that can
    ///      be induced to call the receiver hook with an arbitrary token id and
    ///      a second order minted over an existing order's backing - whose
    ///      cancellation hands the NFT away and leaves the first order
    ///      permanently unfillable and uncancellable. A collection weird enough
    ///      to produce the duplicate at all reaches that lock without anyone
    ///      intending an attack.
    ///
    ///      So the board keeps its own record of what it escrows and treats
    ///      that, not the collection's word, as the authority. Both creation
    ///      paths consult it: the push path, which has no other backstop, and
    ///      the pull path, where a collection whose `ownerOf` lies well enough
    ///      to pass `_moveNFT`'s before/after check twice could otherwise rest
    ///      two orders on one token.
    ///
    ///      A flag rather than the order id: nothing needs to know WHICH order
    ///      holds it - `orders` already says that - only whether the slot is
    ///      taken. One cold SSTORE per NFT order, cleared on the close that
    ///      releases the token: a full fill, or a return of escrow.
    mapping(address collection => mapping(uint256 tokenId => bool)) internal escrowedNFT;

    /// @notice Whether a closed order was closed BY A FILL that took the whole
    ///         thing, rather than cancelled.
    /// @dev Public because the renderer reads it for itself; see `tokenURI`.
    /// `Order` has no spare bit (slot 0 is exactly full), and the
    ///      distinction cannot be recovered from the legs: a full fill zeroes
    ///      both, but so does a CANCELLED order escrowing NFT token id 0 against
    ///      NFT token id 0, which the receipt then drew as FILLED at 100%.
    mapping(uint256 id => bool) public settled;

    /// @notice Orders soft-frozen against fills and repricing.
    /// @dev A position hands over an order's cash flows, but until it is frozen
    ///      the backing stays mutable by ANYONE: a taker can shrink the claim
    ///      with a partial fill, or close it out entirely, at any moment. That
    ///      makes an unfrozen position unsafe to escrow or auction - unlike a
    ///      Uniswap V3 position, where only the owner or an approved party can
    ///      reduce it, so no buyer diligence helps because the state can change
    ///      between simulation and inclusion.
    ///
    ///      Freezing is the owner's own act, and only the owner can undo it. An
    ///      escrow holding a frozen position therefore holds something inert
    ///      and complete: nobody can alter it while the sale is in flight, and
    ///      the buyer thaws it once they hold it.
    ///
    ///      A soft freeze is not a promise to a THIRD party, because the owner
    ///      can lift it and cancel; see `frozenUntil` for the binding form.
    ///
    ///      A separate mapping rather than a struct field: slot 0 is already
    ///      exactly full, and ordinary orders should not pay for a feature only
    ///      traded positions use.
    mapping(uint256 orderId => bool) internal _softFrozen;

    /// @notice Timestamp until which an order is BOUND: not fillable, not
    ///         sweepable, and - unlike a soft freeze - not cancellable,
    ///         repriceable or thawable by its own owner either.
    ///
    /// @dev A soft freeze is only worth what the owner's continued goodwill is
    ///      worth. Anyone buying a position OFF this board - a signed listing on
    ///      an ordinary ERC-721 marketplace, an OTC hand-off - commits to a
    ///      claim the seller can still empty out of from under them: cancel
    ///      returns the backing, the receipt stays transferable, and the sale
    ///      settles against a spent ticket. Custody-first escrows are immune
    ///      (taking the receipt makes the ESCROW the maker), but a generic
    ///      marketplace never takes custody before the buyer pays.
    ///
    ///      A commitment closes that window: while it stands the claim cannot
    ///      change by any path, including the owner's own. It is also IMMUTABLE
    ///      while it stands - not shortenable, and not lengthenable either - so
    ///      the timestamp a buyer reads is the exact end of the window and not
    ///      merely its floor. An extendable commitment would be a promise the
    ///      seller could rewrite: commit three days, list the receipt, then
    ///      front-run the buyer's purchase with a year, and the buyer settles
    ///      for a position nobody can touch for a year. `MAX_COMMITMENT` bounds
    ///      one window; unlimited re-extension would have made that bound
    ///      meaningless.
    ///
    ///      It RIDES WITH THE TOKEN. An earlier design cleared it on transfer to
    ///      a different owner, on the reasoning that a seller's only early exit
    ///      cost them the thing they had listed, so a stale sale would fail
    ///      rather than settle on an emptied claim. That reasoning was wrong:
    ///      ownership is recoverable and escrow is not. Hand the receipt to a
    ///      second wallet (clearing the commitment), cancel from there (taking
    ///      the backing), hand it back - three transactions, bundleable ahead of
    ///      the buyer's purchase, and the buyer pays for a spent ticket. The
    ///      commitment therefore survives every transfer and lapses only on its
    ///      own timestamp, which is the guarantee a buyer was reading in the
    ///      first place.
    ///
    ///      Because there is now no early exit at all, the window is CAPPED: an
    ///      unbounded commitment would be an irreversible burn of the escrow
    ///      rather than a promise about a sale.
    mapping(uint256 orderId => uint64 until) public frozenUntil;

    /// @dev The longest a commitment may run from the moment it is made. Long
    ///      enough to outlast any sale, short enough that a mistake is a wait
    ///      rather than a loss.
    uint64 public constant MAX_COMMITMENT = 365 days;

    /// @notice True when `orderId` cannot be filled or repriced right now, by
    ///         either a soft freeze or a live commitment.
    /// @dev Same name and signature as the mapping getter it replaces, so a
    ///      caller reading `frozen(id)` still gets the question they asked.
    ///
    ///      IT IS NOT A GUARANTEE TO A BUYER, and folding both states into one
    ///      boolean makes that easy to misread. A soft freeze can be lifted by
    ///      the owner in the same block a marketplace settles, followed by a
    ///      cancellation or a repricing down to dust. Anyone buying a position
    ///      off this board must read the exact `frozenUntil` timestamp
    ///      atomically at purchase and require it to cover the sale window -
    ///      never this boolean. Note also that a seller with no live commitment
    ///      can front-run a purchase with a fresh one: the buyer settles on a
    ///      position that cannot be filled, repriced or cancelled by anyone
    ///      until it lapses. That griefs rather than steals, and
    ///      `MAX_COMMITMENT` bounds the wait, but a marketplace flow should
    ///      pin the exact value it expects. Custody-first escrows - which take
    ///      the receipt and become the maker - are immune to both and are the
    ///      recommended path.
    function frozen(uint256 orderId) public view returns (bool) {
        return _softFrozen[orderId] || block.timestamp < frozenUntil[orderId];
    }

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
    event OrderReplaced(
        uint256 indexed orderId, address indexed maker, uint256 amountA, uint256 amountB, uint64 expiry
    );
    event OrderFreezeSet(uint256 indexed orderId, bool frozen);
    event OrderCommitmentSet(uint256 indexed orderId, uint64 until);
    event OrderCanceled(uint256 indexed orderId, address indexed maker);
    event OrderExpiredSwept(uint256 indexed orderId, address indexed maker, address indexed caller);

    error ZeroETH();
    error BadMaker();
    error SameToken();
    error ZeroAmount();
    error ZeroAddress();
    error BadRecipient();
    error UnexpectedETH();
    error LengthMismatch();
    error ZeroFillAmount();
    error DeadlineExpired();
    error NFTNotDivisible();
    error DirectNFTTransfer();
    error ExpiryInPast(uint64 expiry);
    error NotAContract(address token);
    error ExpectedERC20(address token);
    error OrderFrozen(uint256 orderId);
    error OrderExpired(uint256 orderId);
    error OrderNotFound(uint256 orderId);
    error OrderNotActive(uint256 orderId);
    error OrderNotExpired(uint256 orderId);
    error NFTNotReplaceable(uint256 orderId);
    error LiveClaimNotEscrowable(address token);
    error PartialFillNotAllowed(uint256 orderId);
    error NotWETH(address expected, address actual);
    error CommitmentTooLong(uint64 until, uint64 max);
    error CommitmentActive(uint256 orderId, uint64 until);
    error ETHAmountMismatch(uint256 required, uint256 sent);
    error NFTTransferFailed(address token, uint256 tokenId);
    error BalanceMismatch(uint256 expected, uint256 received);
    error InsufficientOutput(uint256 minimum, uint256 actual);
    error NotMaker(uint256 orderId, address caller, address maker);
    error NotCounterparty(uint256 orderId, address caller, address counterparty);
    error BalanceDeltaMismatch(address token, address account, uint256 expected, uint256 actual);

    /// @dev Use the chain's canonical WETH deployment.
    constructor(address _weth) {
        if (_weth == address(0)) revert ZeroAddress();
        if (_weth.code.length == 0) revert NotAContract(_weth);
        weth = _weth;
        METADATA_RENDERER = new SwapboardMetadata();
    }

    // ------------------------------------------------------ POSITION RECEIPTS

    /// @dev Marks this collection as a LIVE CLAIM rather than an inert
    ///      collectible: `bytes4(keccak256("LiveOrderPosition()"))`.
    ///
    ///      A position can be filled by anyone at any time, which pays its
    ///      proceeds to whoever holds it and closes it. That is fine for a
    ///      wallet and wrong for an escrow: a contract holding the position as
    ///      inert collateral receives tokens it has no accounting for, and
    ///      finds the token it was holding is now a spent ticket with no claim
    ///      left in it - the receipt survives a close, but its value does not.
    ///      An escrow that cannot recover proceeds should refuse anything
    ///      declaring this; Swapboard does so at creation, on both legs.
    bytes4 internal constant LIVE_ORDER_POSITION = 0x28a93a2e;

    /// @dev The ERC-721 interface id: the XOR of the interface's function
    ///      selectors, as ERC-165 defines it. NOT `keccak256("ERC721")`.
    bytes4 internal constant ERC721_INTERFACE = 0x80ac58cd;

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == LIVE_ORDER_POSITION || super.supportsInterface(interfaceId);
    }

    /// @dev A bounded ERC-165 probe. Anything that does not implement ERC-165
    ///      simply does not declare the interface, so a failed answer reads as
    ///      "no" rather than refusing every ordinary token. The word is read
    ///      directly rather than `abi.decode`d: a noncanonical boolean would
    ///      make the decoder REVERT, turning a malformed answer into a refusal
    ///      of the whole order - the opposite of the intended leniency. Only a
    ///      clean 1 is affirmative.
    function _declares(address token, bytes4 interfaceId) internal view returns (bool yes) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x01ffc9a7)) // supportsInterface(bytes4)
            mstore(add(p, 4), interfaceId)
            if staticcall(30000, token, p, 0x24, 0, 0x20) {
                yes := and(eq(returndatasize(), 32), eq(mload(0), 1))
            }
        }
    }

    /// @dev Refuse a live claim on EITHER leg, for the reason above.
    ///
    ///      tokenA is the obvious half: it is held by this board between
    ///      creation and settlement, and while it sits here anyone may fill the
    ///      underlying order - paying proceeds to this board, which has no
    ///      accounting for them, and emptying the very claim backing the
    ///      escrow.
    ///
    ///      tokenB is refused too, and it took an exploit to see why. An order
    ///      that ASKS for position P commits to P's claim as its price, but
    ///      settlement can only check that the token id moved - not what it was
    ///      still worth. The seller cancels P (or reprices it to dust) in the
    ///      same transaction, hands over the spent ticket, and takes the
    ///      escrow. Nothing on this board can price a claim whose value its
    ///      holder controls right up to the moment of delivery, so the trade is
    ///      refused rather than sold with a warning. A position still trades
    ///      fine where the buyer takes CUSTODY first - an escrow or auction
    ///      that holds the receipt becomes the maker, and the seller loses
    ///      exactly the control this check cannot verify.
    ///
    ///      WHAT THIS DOES NOT COVER. It catches contracts that VOLUNTARILY
    ///      declare the interface, which makes it a defence against accidents
    ///      between well-behaved boards and nothing more. The hazard it
    ///      describes is far wider than the set it detects: a Uniswap V3 or V4
    ///      LP NFT, a vault receipt, a staking or vesting position - any
    ///      value-bearing NFT - can be emptied by its holder right up to
    ///      delivery, and none of them declare anything here. A hostile board
    ///      simply would not declare it, and the 30,000 gas cap means even an
    ///      honest-looking one can force a `false` by making
    ///      `supportsInterface` expensive. Makers asking for an NFT as payment
    ///      must judge that asset themselves; a front end taking a
    ///      value-bearing NFT as `tokenB` needs an allowlist and a warning, not
    ///      this check.
    function _checkEscrowable(address token) internal view {
        if (_declares(token, LIVE_ORDER_POSITION)) revert LiveClaimNotEscrowable(token);
    }

    /// @dev Refuse an ERC-721 on a leg the caller declared fungible.
    ///
    ///      `nftA`/`nftB` are caller-supplied and were taken on trust. ERC-20
    ///      and ERC-721 share both `balanceOf(address)` and
    ///      `transferFrom(address,address,uint256)`, so escrowing token id 1 of
    ///      a collection with `nftA = false` PASSES the exact-delta check: the
    ///      board's holdings rise by one token, which is exactly the amount
    ///      asked for. The order then rests as a fungible one, and every exit
    ///      from it - fill, cancel, sweep, shrink - calls `transfer(address,
    ///      uint256)`, which no ERC-721 implements. The NFT is locked forever;
    ///      this board has no rescue path. One staticcall at creation is a
    ///      cheap price for that.
    ///
    ///      It only sees collections that implement ERC-165, so it is an
    ///      accident guard rather than a guarantee. When it misses, the lock it
    ///      describes is permanent and this board has no rescue path - which is
    ///      the other half of why assets belong on an allowlist.
    function _checkFungible(address token) internal view {
        if (_declares(token, ERC721_INTERFACE)) revert ExpectedERC20(token);
    }

    function name() public pure override returns (string memory) {
        return "Swapboard Position";
    }

    function symbol() public pure override returns (string memory) {
        return "SBPOS";
    }

    /// @notice Live, self-contained metadata for the order receipt.
    /// @dev The image deliberately uses raw base units and shortened asset
    ///      addresses: those are exact, chain-native facts which need no token
    ///      metadata call and cannot go stale. WNS is best-effort only.
    function tokenURI(uint256 orderId) public view override returns (string memory) {
        ownerOf(orderId); // Standard ERC-721 behaviour: nonexistent IDs have no metadata.
        // The renderer reads the order for itself through the getters above.
        // Assembling its twenty-field parameter struct HERE, and encoding two
        // dynamic strings into the call, cost 1,242 bytes of runtime code on
        // the one contract in this pair with no EIP-170 headroom to spend. It
        // is a view path either way; see `SwapboardMetadata.tokenURI`.
        return METADATA_RENDERER.tokenURI(address(this), orderId);
    }

    function _rememberDecimals(address token) internal {
        if (tokenDecimals[token] != 0) return;
        (bool known, uint8 decimals) = PositionSVG.readDecimals(token);
        if (known) tokenDecimals[token] = decimals + 1;
    }

    function _rememberSymbol(address token) internal {
        if (bytes(tokenSymbols[token]).length == 0) tokenSymbols[token] = PositionSVG.readSymbol(token);
    }

    /// @dev The transfer that hands control OUT is the one that needs guarding:
    ///      `safeTransferFrom` calls the recipient AFTER `_afterTokenTransfer`
    ///      has already made them the maker, inside the sender's transaction,
    ///      so an unguarded hook could act as maker mid-transfer. Nothing is
    ///      lost by it - the callee is the legitimate new owner - but it is one
    ///      fewer way to leave a marketplace holding surprising state.
    ///
    ///      The guard goes HERE ONLY, not on `transferFrom` as well. Solady's
    ///      safe variants reach the transfer through the public, virtual
    ///      `transferFrom`, so a guard on both would nest on every safe
    ///      transfer and revert as reentrancy - bricking every push listing and
    ///      every ERC-721-safe integration. A plain `transferFrom` makes no
    ///      external call and so has nothing to guard against; settlement
    ///      caches `maker` before it ever gives anyone control, which is what
    ///      makes a mid-flight change of owner harmless there.
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
    ///      lands here, where there is no rescue path for it. Refuse it.
    ///
    ///      Guarding `transferFrom` covers all three transfer entry points:
    ///      Solady's safe variants reach the move by calling this same function
    ///      in the SAME frame, where `msg.value` is still whatever the caller
    ///      attached. This is a value check, not a reentrancy guard - that
    ///      distinction is what keeps it from bricking safe transfers.
    function transferFrom(address from, address to, uint256 id) public payable override {
        if (msg.value != 0) revert UnexpectedETH();
        super.transferFrom(from, to, id);
    }

    function approve(address account, uint256 id) public payable override {
        if (msg.value != 0) revert UnexpectedETH();
        super.approve(account, id);
    }

    /// @dev Ownership IS makership. Rather than teach settlement to consult
    ///      `ownerOf`, the stored `maker` is kept in step on every transfer, so
    ///      payout, cancellation and repricing keep working exactly as before
    ///      and there is only ever one source of truth. Minting sets it in
    ///      `_store`; burning is a close, where it must not be cleared because
    ///      `maker == address(0)` is how a nonexistent order is recognised.
    ///
    ///      No separate event: makership changes exactly when the receipt
    ///      moves, so the ERC-721 `Transfer` log IS the maker-change log, and a
    ///      second one would be the same fact twice. Indexers should join
    ///      `Transfer` against order state rather than expect an order event.
    function _afterTokenTransfer(address from, address to, uint256 id) internal override {
        if (from != address(0) && to != address(0)) {
            _checkMaker(to);
            orders[id].maker = to;
            // `frozenUntil` is deliberately NOT cleared here; see its docs. A
            // commitment that ended with the seller's ownership could be voided
            // by round-tripping the receipt through a second wallet and
            // cancelling from there, which is exactly the move it exists to
            // rule out.
        }
    }

    /// @dev Only WETH may send ETH through an ordinary call.
    receive() external payable {
        if (msg.sender != weth) revert NotWETH(weth, msg.sender);
    }

    /// @dev The word a push payload must open with before this board reads the
    ///      rest of it as terms.
    ///
    ///      LENGTH ALONE IS NOT CONSENT. A wallet, bridge or marketplace that
    ///      attaches its own metadata to a `safeTransferFrom` and happens to
    ///      land on the right size would have it decoded as an order, and a
    ///      blob whose words happen to fall on a real `tokenB` with a small
    ///      `amountB` becomes a live order at a price its sender never chose.
    ///      Most such payloads revert on one of the checks below; "most" is not
    ///      the standard an irreversible escrow should be held to. A
    ///      domain-separated prefix makes the intent explicit and sends
    ///      everything else back to the original refusal.
    bytes32 internal constant PUSH_ORDER_MAGIC = keccak256("Swapboard.PushOrder.v1");

    /// @notice Terms carried in a pushed NFT's transfer data.
    /// @dev Exactly five words, behind `PUSH_ORDER_MAGIC`. `tokenA` is not
    ///      present: the collection is established by the call itself, not by
    ///      anything the sender writes.
    struct PushOrder {
        address tokenB;
        uint256 amountB;
        uint64 expiry;
        bool nftB;
        address counterparty;
    }

    /// @notice Create an order from an NFT pushed with `safeTransferFrom`,
    ///         carrying its terms in `data`. One transaction, no approval.
    ///
    /// @dev This board previously refused every incoming 721. It accepts one
    ///      now ONLY when the transfer carries well-formed terms, and an
    ///      unsolicited push still reverts with the original error - a token
    ///      sent here by mistake is rejected rather than silently escrowed with
    ///      no owner.
    ///
    ///      THE COLLECTION IS THE CALLER. `tokenA` is `msg.sender`, so the
    ///      sender cannot name a collection they do not control; the only way
    ///      to be a collection here is for the collection to make the call.
    ///
    ///      OWNERSHIP IS VERIFIED, NOT MOVED. The token is already here by the
    ///      time this runs, so there is nothing to transfer - and attempting a
    ///      transfer would be the bug. `ownerOf` establishes that the token
    ///      arrived at all; `escrowedNFT` establishes that THIS call is what
    ///      put it here rather than an earlier order, which is the part
    ///      `ownerOf` alone cannot answer. See that mapping for why the
    ///      difference matters.
    ///
    ///      A fabricated collection can of course report whatever it likes and
    ///      mint an order backed by its own worthless token. That is not an
    ///      attack on this board or on anyone's escrow: it is an order nobody
    ///      has to fill, indistinguishable from listing any other worthless
    ///      asset, and it is the taker's job to know what they are buying.
    ///
    ///      PARTIAL FILLS ARE REFUSED, as for any NFT-sided order: an ERC-721
    ///      is indivisible and settles only at its full ask.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        nonReentrant
        returns (bytes4)
    {
        // No terms means this was not a deliberate order, so keep the old
        // behaviour and refuse it.
        if (data.length != 192) revert DirectNFTTransfer();
        if (bytes32(data[:32]) != PUSH_ORDER_MAGIC) revert DirectNFTTransfer();
        PushOrder memory o = abi.decode(data[32:], (PushOrder));

        address tokenA = msg.sender;
        // This board is itself an ERC-721 now, so a position pushed back here
        // would try to escrow the board's own receipt against itself.
        if (tokenA == address(this)) revert BadMaker();
        // `from` becomes the maker, and a maker is a payout address: the same
        // addresses refused at creation are refused here.
        _checkMaker(from);
        if (tokenA.code.length == 0) revert NotAContract(tokenA);
        // A sibling board's position is a live claim, and this leg is escrowed.
        _checkEscrowable(tokenA);
        if (o.tokenB == address(0)) revert ZeroAddress();
        if (o.tokenB.code.length == 0) revert NotAContract(o.tokenB);
        // A live claim is no more acceptable as the price here than at creation.
        _checkEscrowable(o.tokenB);
        if (!o.nftB) _checkFungible(o.tokenB);
        // tokenId 0 is a legitimate NFT, so only a fungible side is checked.
        if (!o.nftB && o.amountB == 0) revert ZeroAmount();
        // Two fungible legs in one token would be a no-op trade; here tokenA is
        // always an NFT, so a shared collection is a legitimate 721-for-721
        // swap and only the degenerate same-id case needs refusing - which the
        // payment leg's ownerOf preflight already does at fill time.
        _checkExpiry(o.expiry);

        // Not already backing a live order here, and actually present.
        if (escrowedNFT[tokenA][tokenId] || IERC721(tokenA).ownerOf(tokenId) != address(this)) {
            revert NFTTransferFailed(tokenA, tokenId);
        }

        _store(from, tokenA, tokenId, o.tokenB, o.amountB, false, o.expiry, true, o.nftB, o.counterparty);
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
        orderId = _createOrder(
            msg.sender, tokenA, amountA, tokenB, amountB, partialFill, expiry, nftA, nftB, counterparty
        );
    }

    /// @notice Create a fully funded order owned by `maker`.
    /// @dev The caller supplies the escrow; cancellation and payouts go to `maker`.
    ///
    ///      MAKERSHIP IS UNSOLICITED HERE. `maker` does not consent, so a
    ///      position can appear in any wallet, and a contract maker that opts
    ///      into `acceptsOrderProceeds` will receive `beforeOrderProceeds` /
    ///      `afterOrderProceeds` for an order it never created, on a `tokenB`
    ///      and `amountB` the attacker chose. `ownerOf(orderId) == address(this)`
    ///      passes for that order too, so it is NOT a sufficient check: an
    ///      integrating escrow or vault must validate `orderId` against its own
    ///      records of orders it created, and treat anything else as a
    ///      donation.
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
    ) external nonReentrant returns (uint256 orderId) {
        orderId = _createOrder(maker, tokenA, amountA, tokenB, amountB, partialFill, expiry, nftA, nftB, counterparty);
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
                msg.sender,
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
        orderId = _createOrderWithEth(msg.sender, tokenB, amountB, partialFill, expiry, nftB, counterparty);
    }

    /// @notice Pay ETH from the caller while crediting the wrapped order to
    ///         `maker`. The same sponsorship semantics as createOrderFor apply.
    function createOrderWithEthFor(
        address maker,
        address tokenB,
        uint256 amountB,
        bool partialFill,
        uint64 expiry,
        bool nftB,
        address counterparty
    ) external payable nonReentrant returns (uint256 orderId) {
        orderId = _createOrderWithEth(maker, tokenB, amountB, partialFill, expiry, nftB, counterparty);
    }

    function _createOrderWithEth(
        address maker,
        address tokenB,
        uint256 amountB,
        bool partialFill,
        uint64 expiry,
        bool nftB,
        address counterparty
    ) internal returns (uint256 orderId) {
        _checkMaker(maker);
        if (msg.value == 0) revert ZeroETH();
        if (tokenB == address(0)) revert ZeroAddress();
        if (!nftB && amountB == 0) revert ZeroAmount();
        if (nftB && partialFill) revert NFTNotDivisible();
        if (tokenB == weth) revert SameToken();
        if (tokenB.code.length == 0) revert NotAContract(tokenB);
        _checkEscrowable(tokenB);
        if (!nftB) _checkFungible(tokenB);
        _checkExpiry(expiry);

        _wrapETH(msg.value);
        orderId = _store(maker, weth, msg.value, tokenB, amountB, partialFill, expiry, false, nftB, counterparty);
    }

    function _createOrder(
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
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        _checkMaker(maker);
        // tokenId 0 is a legitimate NFT, so only fungible sides are checked.
        if (!nftA && amountA == 0) revert ZeroAmount();
        if (!nftB && amountB == 0) revert ZeroAmount();
        // An ERC-721 cannot be split, so it cannot rest as a partial order.
        if ((nftA || nftB) && partialFill) revert NFTNotDivisible();
        // Two fungible legs in the same token are a no-op trade. One collection
        // on both sides is not: it is an NFT-for-NFT swap, and the two tokenIds
        // are what differ. The degenerate case where they are the same tokenId
        // needs no check here - the escrowed token is owned by the board by
        // then, so the payment leg's `ownerOf != from` preflight refuses it.
        if (tokenA == tokenB && !(nftA || nftB)) revert SameToken();
        if (tokenA.code.length == 0) revert NotAContract(tokenA);
        // tokenA is escrowed here until settlement, so it must be inert; tokenB
        // is the price, and a claim its seller can empty is not a price.
        _checkEscrowable(tokenA);
        if (tokenB.code.length == 0) revert NotAContract(tokenB);
        _checkEscrowable(tokenB);
        // The nft flags are the caller's word; a fungible leg has to earn it.
        if (!nftA) _checkFungible(tokenA);
        if (!nftB) _checkFungible(tokenB);
        _checkExpiry(expiry);

        if (nftA) {
            if (escrowedNFT[tokenA][amountA]) revert NFTTransferFailed(tokenA, amountA);
            _moveNFT(tokenA, msg.sender, address(this), amountA);
        } else {
            // A fee-on-transfer token would leave the escrow short of amountA,
            // so what actually arrived is measured rather than assumed - and
            // what left the payer with it.
            _pullToken(tokenA, address(this), amountA);
        }

        orderId = _store(maker, tokenA, amountA, tokenB, amountB, partialFill, expiry, nftA, nftB, counterparty);
    }

    /// @dev Confirm ownership before and after `transferFrom`.
    function _moveNFT(address token, address from, address to, uint256 tokenId) internal {
        if (IERC721(token).ownerOf(tokenId) != from) revert NFTTransferFailed(token, tokenId);
        IERC721(token).transferFrom(from, to, tokenId);
        if (IERC721(token).ownerOf(tokenId) != to) revert NFTTransferFailed(token, tokenId);
    }

    /// @dev An NFT already owned by the maker is treated as returned; otherwise
    ///      confirm board ownership before transferring it back.
    function _returnNFT(address token, address to, uint256 tokenId) internal {
        address owner = IERC721(token).ownerOf(tokenId);
        if (owner == to) return;
        if (owner != address(this)) revert NFTTransferFailed(token, tokenId);
        IERC721(token).transferFrom(address(this), to, tokenId);
        if (IERC721(token).ownerOf(tokenId) != to) revert NFTTransferFailed(token, tokenId);
    }

    /// @dev The balance of `account`, where `address(0)` means native ETH. One
    ///      reader so every leg below measures the same way.
    function _balanceOf(address token, address account) internal view returns (uint256) {
        return token == address(0) ? account.balance : token.balanceOf(account);
    }

    /// @dev "This balance moved by exactly `amount`, or revert" - the single
    ///      form of the check every transfer leg runs. Deltas are measured
    ///      rather than assumed because a fee-on-transfer token, on either
    ///      side, would otherwise leave pooled escrow short of what the orders
    ///      resting against it are owed.
    function _expectDelta(address token, address account, uint256 previous, uint256 amount, bool credit) internal view {
        uint256 current = _balanceOf(token, account);
        uint256 delta = credit ? _increase(previous, current) : _decrease(previous, current);
        if (delta != amount) revert BalanceDeltaMismatch(token, account, amount, delta);
    }

    /// @dev Confirm exact board debit and recipient credit for pooled escrow.
    function _sendEscrowToken(address token, address to, uint256 amount) internal {
        uint256 boardBefore = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);

        _expectDelta(token, address(this), boardBefore, amount, false);
        _expectDelta(token, to, recipientBefore, amount, true);
    }

    /// @dev Every fungible pull, measured on BOTH sides: the payer is debited by
    ///      the nominal amount and the recipient credited by it.
    ///
    ///      Measuring only the credit catches a receiver-tax token but not a
    ///      SENDER-tax one, which debits `amount + fee` and credits exactly
    ///      `amount` - the payer loses more than the amount they authorised
    ///      through this board's parameters, and the check waves it through.
    ///      Both ends are measured so the number in the order is the number
    ///      that leaves the payer's balance.
    ///
    ///      The arrival leg keeps `BalanceMismatch`, which is the error creation
    ///      and repricing have always reported for a short delivery; a
    ///      sender-side discrepancy is a `BalanceDeltaMismatch` naming the payer.
    ///
    ///      The payer is always `msg.sender` - this board never moves tokens
    ///      between two third parties.
    ///
    ///      A maker filling their OWN fungible order lands here with payer and
    ///      recipient equal, so the transfer nets to nothing and this reverts
    ///      with `BalanceMismatch(amount, 0)`. That is the correct outcome -
    ///      self-filling is a cancellation written the expensive way - but the
    ///      error names the symptom rather than the cause; front ends should
    ///      steer a maker to `cancelOrder` instead.
    function _pullToken(address token, address to, uint256 amount) internal {
        uint256 senderBefore = token.balanceOf(msg.sender);
        uint256 recipientBefore = token.balanceOf(to);
        token.safeTransferFrom(msg.sender, to, amount);

        uint256 received = _increase(recipientBefore, token.balanceOf(to));
        if (received != amount) revert BalanceMismatch(amount, received);

        _expectDelta(token, msg.sender, senderBefore, amount, false);
    }

    /// @dev Confirm the exact WETH credit from wrapping.
    function _wrapETH(uint256 amount) internal {
        uint256 beforeBalance = weth.balanceOf(address(this));
        IWETH(weth).deposit{value: amount}();
        _expectDelta(weth, address(this), beforeBalance, amount, true);
    }

    /// @dev Confirm exact WETH debit and native ETH credit.
    function _unwrapETH(uint256 amount) internal {
        uint256 wethBefore = weth.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        IWETH(weth).withdraw(amount);

        _expectDelta(weth, address(this), wethBefore, amount, false);
        _expectDelta(address(0), address(this), ethBefore, amount, true);
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

    /// @dev Maker receives escrow and fill proceeds, so the board and WETH are
    /// invalid maker addresses.
    function _checkMaker(address maker) internal view {
        if (maker == address(0)) revert ZeroAddress();
        if (maker == address(this) || maker == weth) revert BadMaker();
    }

    /// @dev Creation requires a nonzero expiry to be in the future.
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
        initialAmountB[orderId] = amountB;
        // The board's own record of what it holds, and for whom.
        if (nftA) escrowedNFT[tokenA][amountA] = true;
        // Both readings, for both legs. A ticker is what a reader recognises and
        // a scale is what makes the amount above it parseable; a fungible leg
        // used to carry only a truncated address and a decimal count.
        if (!nftA) _rememberDecimals(tokenA);
        _rememberSymbol(tokenA);
        if (!nftB) _rememberDecimals(tokenB);
        _rememberSymbol(tokenB);

        // The position itself is the receipt. Minted with `_mint`, never
        // `_safeMint`: a receiver hook here would hand control to the maker in
        // the middle of order creation, which is the callback-mid-settlement
        // hazard this board avoids everywhere else.
        _mint(maker, orderId);
        emit OrderCreated(
            orderId, maker, tokenA, amountA, tokenB, amountB, partialFill, expiry, nftA, nftB, counterparty
        );
    }

    // ------------------------------------------------------------------- FILL

    /// @param fillAmountB Fungible payment amount; it must be explicit and nonzero.
    ///        A zero full-fill sentinel is retained only for NFT orders, where an
    ///        amount can be token ID zero and NFT orders cannot be repriced.
    /// @param minAmountA Minimum fungible tokenA output; zero disables the floor.
    ///        Ignored for NFT tokenA, whose amount is a token ID.
    /// @param recipient Where tokenA is delivered. address(0) means the caller.
    ///        This is a delivery address only - it is NEVER used for
    ///        authorisation. `counterparty` is still checked against msg.sender,
    ///        because a caller-supplied recipient could otherwise be set to the
    ///        intended counterparty and drain every private order.
    function fillOrder(uint256 orderId, uint256 deadline, uint256 fillAmountB, uint256 minAmountA, address recipient)
        external
        nonReentrant
    {
        _checkDeadline(deadline);
        _fill(orderId, fillAmountB, minAmountA, 0, _to(recipient));
    }

    /// @dev Atomic: if any fill reverts, the whole batch reverts. Each
    ///      `minAmountsA[i]` protects the corresponding order.
    /// @notice Fill several orders atomically; any failure aborts the batch.
    ///         Use tryFillOrders to skip rather than revert.
    function fillOrders(
        uint256[] calldata orderIds,
        uint256 deadline,
        uint256[] calldata fillAmountsB,
        uint256[] calldata minAmountsA,
        address recipient
    ) external nonReentrant {
        _checkDeadline(deadline);
        if (orderIds.length != fillAmountsB.length || orderIds.length != minAmountsA.length) {
            revert LengthMismatch();
        }
        address to = _to(recipient);
        for (uint256 i; i < orderIds.length; ++i) {
            _fill(orderIds[i], fillAmountsB[i], minAmountsA[i], 0, to);
        }
    }

    /// @dev Skips orders that are inactive, missing, expired, frozen, or
    ///      reserved for a different counterparty.
    ///
    ///      IT DOES NOT MAKE A HOSTILE ORDER SAFE. Every other revert path
    ///      still aborts the batch, and a maker that opts into proceeds
    ///      notification gets a full-gas call during settlement whose revert
    ///      bubbles all the way out - so anyone willing to escrow a little dust
    ///      can plant an order that kills a router's whole batch. Catching that
    ///      needs an external self-call per leg, and this contract has no
    ///      EIP-170 headroom left to buy one; see the size note in
    ///      `foundry.toml`. Callers that fill orders they did not choose should
    ///      screen makers themselves, or fill one at a time.
    ///
    ///      Minimum-output failures are deliberately NOT skipped either: the
    ///      floor is the taker's own and silently stepping over it would turn a
    ///      slippage guarantee into a partial route.
    function tryFillOrders(
        uint256[] calldata orderIds,
        uint256 deadline,
        uint256[] calldata fillAmountsB,
        uint256[] calldata minAmountsA,
        address recipient
    ) external nonReentrant returns (bool[] memory filled) {
        _checkDeadline(deadline);
        if (orderIds.length != fillAmountsB.length || orderIds.length != minAmountsA.length) {
            revert LengthMismatch();
        }
        address to = _to(recipient);
        filled = new bool[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            Order storage o = orders[orderIds[i]];
            address cp = o.counterparty;
            // Frozen belongs with the other not-fillable-right-now states: it
            // is temporary and outside the taker's control, exactly what this
            // variant exists to step over rather than abort on.
            if (o.active && !_expired(o.expiry) && !frozen(orderIds[i]) && (cp == address(0) || cp == msg.sender)) {
                _fill(orderIds[i], fillAmountsB[i], minAmountsA[i], 0, to);
                filled[i] = true;
            }
        }
    }

    /// @notice Fill and receive tokenA as ETH rather than WETH. Reverts unless
    ///         tokenA is WETH; ignored when tokenA is an NFT.
    /// @param minAmountA Minimum WETH output; zero disables the floor.
    function fillOrderUnwrap(
        uint256 orderId,
        uint256 deadline,
        uint256 fillAmountB,
        uint256 minAmountA,
        address recipient
    ) external nonReentrant {
        _checkDeadline(deadline);
        _fill(orderId, fillAmountB, minAmountA, 1, _to(recipient));
    }

    /// @dev msg.value is the fill amount and is wrapped before settlement, so a
    /// value above the remaining amountB is refused rather than refunded.
    ///
    /// The prepaid path accepts a short payment only for a divisible partial
    /// order. NFT-A and all-or-nothing orders must arrive exactly paid. _fill
    /// independently rejects those short fills; checking here gives the ETH path
    /// its specific ETHAmountMismatch error before wrapping the caller's value.
    /// @param minAmountA Minimum fungible tokenA output; zero disables the floor.
    ///        Ignored for NFT tokenA.
    function fillOrderWithEth(uint256 orderId, uint256 deadline, uint256 minAmountA, address recipient)
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
        _wrapETH(msg.value);
        _fill(orderId, msg.value, minAmountA, 2, _to(recipient));
    }

    /// @dev mode bit 0 unwraps tokenA as ETH; mode bit 1 uses pre-wrapped WETH
    ///      for tokenB. Packing these path flags keeps this settlement routine
    ///      below the compiler's stack limit after adding the output floor.
    function _fill(uint256 orderId, uint256 fillAmountB, uint256 minAmountA, uint256 mode, address to) internal {
        (Order storage order, address maker) = _live(orderId);
        // Maker-side expiry. Distinct from the `deadline` argument above, which
        // guards the taker against a stale mempool transaction.
        if (_expired(order.expiry)) revert OrderExpired(orderId);
        if (frozen(orderId)) revert OrderFrozen(orderId);

        address cp = order.counterparty;
        if (cp != address(0) && cp != msg.sender) revert NotCounterparty(orderId, msg.sender, cp);

        (uint256 outA, uint256 paidB, bool full) = _applyFill(orderId, order, fillAmountB);

        // A taker signs this floor before the transaction enters the public
        // mempool. It therefore remains protected if the maker reprices the
        // live order before this call executes. NFT token IDs are not amounts,
        // so the floor applies only to fungible tokenA legs.
        if (!order.nftA && outA < minAmountA) revert InsufficientOutput(minAmountA, outA);

        _settleFill(
            FillLegs(orderId, order.tokenA, order.tokenB, maker, to, outA, paidB, mode, order.nftA, order.nftB)
        );

        if (full) {
            emit OrderFilled(orderId, msg.sender, maker, outA, paidB);
        } else {
            emit OrderPartiallyFilled(orderId, msg.sender, maker, outA, paidB, order.amountA, order.amountB);
        }
    }

    /// @dev Refusal codes from `_computeFill`, mapped to this board's errors by
    ///      settlement and to a zero quote by the view.
    uint256 internal constant FILL_OK = 0;
    uint256 internal constant FILL_ZERO = 1;
    uint256 internal constant FILL_INDIVISIBLE = 2;

    /// @dev The fill arithmetic, and the single place it is written. Settlement
    ///      and `quoteFill` both run it, so a splitter's plan cannot disagree
    ///      with what the fill actually pays - which is the whole point of
    ///      quoting on the board rather than rederiving the rounding off chain.
    ///      It touches no storage: the caller reads the terms and, if it is
    ///      settling, writes the result back.
    function _computeFill(uint256 amountA, uint256 amountB, bool nftA, bool nftB, bool partialFill, uint256 fillAmountB)
        internal
        pure
        returns (uint256 outA, uint256 paidB, bool full, uint256 err)
    {
        // NFT orders always settle in full. Their amount fields may be token IDs,
        // so zero remains the explicit full-fill sentinel for either NFT side.
        // Fungible orders must receive an explicit payment amount: resolving zero
        // against the live order would let a maker reprice the taker's input after
        // the taker signed a transaction.
        if (fillAmountB == 0 && !nftA && !nftB) return (0, 0, false, FILL_ZERO);
        if (fillAmountB != 0) {
            if (nftB && fillAmountB != amountB) return (0, 0, false, FILL_INDIVISIBLE);
            if (nftA && fillAmountB < amountB) return (0, 0, false, FILL_INDIVISIBLE);
        }
        if (nftA || nftB || fillAmountB >= amountB) return (amountA, amountB, true, FILL_OK);

        if (!partialFill) return (0, 0, false, FILL_INDIVISIBLE);
        // Rounds down, favouring the maker. Full precision so large
        // 18-decimal amounts cannot overflow the intermediate product.
        outA = FixedPointMathLib.fullMulDiv(fillAmountB, amountA, amountB);
        if (outA == 0) return (0, 0, false, FILL_ZERO);
        return (outA, fillAmountB, false, FILL_OK);
    }

    /// @dev Apply fill arithmetic and update the order before any external
    ///      transfer. Keeping this in its own frame avoids stack pressure in
    ///      the settlement routine, which also carries the slippage floor.
    function _applyFill(uint256 orderId, Order storage order, uint256 fillAmountB)
        internal
        returns (uint256 outA, uint256 paidB, bool full)
    {
        uint256 amountA = order.amountA;
        uint256 amountB = order.amountB;
        uint256 err;
        (outA, paidB, full, err) =
            _computeFill(amountA, amountB, order.nftA, order.nftB, order.partialFill, fillAmountB);
        if (err == FILL_ZERO) revert ZeroFillAmount();
        if (err != FILL_OK) revert PartialFillNotAllowed(orderId);

        if (full) {
            order.active = false;
            settled[orderId] = true;
            order.amountA = 0;
            order.amountB = 0;
            // Deliberately NOT burned. A holder may be a contract that reads
            // `ownerOf` - an escrow, a marketplace - and burning under it
            // leaves that contract pointing at a token which no longer exists,
            // with no path to recover whatever it was holding. The receipt
            // survives a close as a spent ticket instead; `active` is what says
            // whether it still has a claim.
        } else {
            order.amountA = amountA - outA;
            order.amountB = amountB - paidB;
        }
    }

    /// @dev Settlement arguments, grouped only so they occupy one stack slot
    ///      at the call site. `_fill` carries enough live locals that passing
    ///      these individually exhausts the stack under via-IR.
    struct FillLegs {
        uint256 orderId;
        address tokenA;
        address tokenB;
        address maker;
        address to;
        uint256 outA;
        uint256 fillAmountB;
        uint256 mode;
        bool nftA;
        bool nftB;
    }

    /// @dev Both transfer legs, in their own frame. Ordering and confirmation
    ///      are unchanged from when this was inline: tokenB reaches the maker
    ///      first, then tokenA reaches the taker, and every leg is verified
    ///      rather than assumed.
    function _settleFill(FillLegs memory f) internal {
        // tokenB to the maker. On the ETH path it is already wrapped and held
        // here. The 721 leg is the maker's payment, so it is confirmed rather
        // than assumed: an unconfirmed no-op would hand the escrow over for
        // nothing.
        bool notifyProceeds = _beforeOrderProceeds(f.maker, f.orderId, f.tokenB, f.fillAmountB, f.nftB);
        if (f.nftB) _moveNFT(f.tokenB, msg.sender, f.maker, f.fillAmountB);
        else if ((f.mode & 2) != 0) _sendEscrowToken(f.tokenB, f.maker, f.fillAmountB);
        else _pullToken(f.tokenB, f.maker, f.fillAmountB);
        if (notifyProceeds) _afterOrderProceeds(f.maker, f.orderId, f.tokenB, f.fillAmountB, f.nftB);

        // tokenA to the taker. Confirmed at both ends too: escrow can go
        // missing between creation and fill on a collection that leaves a stale
        // approval behind, and the taker has already paid by this point.
        if (f.nftA) {
            // An NFT leg always settles in full, so the escrow record is
            // released here, with the token it tracked.
            delete escrowedNFT[f.tokenA][f.outA];
            _moveNFT(f.tokenA, address(this), f.to, f.outA);
        } else if ((f.mode & 1) != 0) {
            if (f.tokenA != weth) revert NotWETH(weth, f.tokenA);
            _unwrapETH(f.outA);
            f.to.safeTransferETH(f.outA);
        } else {
            _sendEscrowToken(f.tokenA, f.to, f.outA);
        }
    }

    /// @dev Optional two-phase accounting for a maker that is also an escrow.
    ///      The bounded static probe preserves ordinary maker compatibility;
    ///      only an affirmative response opts into the stateful callbacks.
    ///
    ///      REVERT DATA IS COPIED WITH A BOUND. A maker that opts in and then
    ///      reverts takes the fill down either way, so the reason is only ever
    ///      read by a human - 256 bytes is enough to debug with, and copying
    ///      more charges the TAKER quadratic memory-expansion gas for a blob the
    ///      maker chose the size of. Bounding the copy is the part with no
    ///      honest victim; capping gas would not be, since a callback doing real
    ///      accounting needs it and a griefer who cannot burn gas can simply
    ///      revert instead. Dutchboard's `_notifyBeforeProceeds` bounds the same
    ///      copy for the same reason.
    function _beforeOrderProceeds(address maker, uint256 orderId, address token, uint256 amount, bool nft)
        internal
        returns (bool notify)
    {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x33dbef94)) // acceptsOrderProceeds(uint256)
            mstore(add(p, 4), orderId)
            let accepted := staticcall(30000, maker, p, 0x24, 0, 0x20)
            if and(accepted, eq(returndatasize(), 32)) {
                notify := eq(mload(0), 1)
            }
            if notify {
                mstore(p, shl(224, 0x8d27ed3f)) // beforeOrderProceeds(uint256,address,uint256,bool)
                mstore(add(p, 4), orderId)
                mstore(add(p, 36), token)
                mstore(add(p, 68), amount)
                mstore(add(p, 100), nft)
                if iszero(call(gas(), maker, 0, p, 0x84, 0, 0x20)) {
                    let n := returndatasize()
                    if gt(n, 256) { n := 256 }
                    returndatacopy(p, 0, n)
                    revert(p, n)
                }
                notify := and(eq(returndatasize(), 32), eq(mload(0), 1))
            }
        }
    }

    function _afterOrderProceeds(address maker, uint256 orderId, address token, uint256 amount, bool nft) internal {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0x2814c622)) // afterOrderProceeds(uint256,address,uint256,bool)
            mstore(add(p, 4), orderId)
            mstore(add(p, 36), token)
            mstore(add(p, 68), amount)
            mstore(add(p, 100), nft)
            if iszero(call(gas(), maker, 0, p, 0x84, 0, 0)) {
                let n := returndatasize()
                if gt(n, 256) { n := 256 }
                returndatacopy(p, 0, n)
                revert(p, n)
            }
        }
    }

    // ---------------------------------------------------------------- REPLACE

    /// @notice Maker-only repricing and resizing for a live fungible order.
    /// @dev Only amounts and expiry change; the order id, pair, permissions and
    ///      maker remain fixed. NFT orders are not replaceable. Escrow moves only
    ///      by the amount difference and uses the same exact transfer checks as
    ///      creation and cancellation. This method is not payable.
    function replaceOrder(uint256 orderId, uint256 newAmountA, uint256 newAmountB, uint64 newExpiry)
        external
        nonReentrant
    {
        _replace(orderId, newAmountA, newAmountB, newExpiry);
    }

    /// @notice Reprice several orders atomically.
    function replaceOrders(ReplaceOrderParams[] calldata params) external nonReentrant {
        for (uint256 i; i < params.length; ++i) {
            _replace(params[i].orderId, params[i].amountA, params[i].amountB, params[i].expiry);
        }
    }

    function _replace(uint256 orderId, uint256 newAmountA, uint256 newAmountB, uint64 newExpiry) internal {
        (Order storage order, address maker) = _liveOwned(orderId);
        if (order.nftA || order.nftB) revert NFTNotReplaceable(orderId);
        if (frozen(orderId)) revert OrderFrozen(orderId);
        if (newAmountA == 0 || newAmountB == 0) revert ZeroAmount();
        _checkExpiry(newExpiry);

        address tokenA = order.tokenA;
        uint256 amountA = order.amountA;

        if (newAmountA > amountA) {
            uint256 delta;
            unchecked {
                delta = newAmountA - amountA;
            }
            // Effects before the interaction. The exactness check below still
            // holds - a mismatch reverts, taking this write with it - so
            // ordering costs nothing and removes the need to reason about what
            // a token callback could observe. Previously this wrote after the
            // pull, safe only because every order-mutating entry point is
            // guarded and the ERC-721 methods do not touch amounts.
            (order.amountA, order.amountB, order.expiry) = (newAmountA, newAmountB, newExpiry);
            initialAmountB[orderId] = newAmountB;

            _pullToken(tokenA, address(this), delta);
        } else {
            uint256 delta;
            unchecked {
                delta = amountA - newAmountA;
            }
            (order.amountA, order.amountB, order.expiry) = (newAmountA, newAmountB, newExpiry);
            initialAmountB[orderId] = newAmountB;
            if (delta != 0) _sendEscrowToken(tokenA, maker, delta);
        }

        emit OrderReplaced(orderId, maker, newAmountA, newAmountB, newExpiry);
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
    ///
    /// A FROZEN order is exempt. The freeze exists so an escrowed position is
    /// inert while a sale is in flight, and that guarantee has to hold against
    /// every permissionless path, not just fills: a sweep would close the order
    /// under the escrow, return the backing to a holder with no accounting for
    /// it, and leave the buyer paying for a spent ticket. A soft freeze is the
    /// owner's own act and they can still cancel; a commitment lapses on its
    /// own timestamp, after which the sweep applies again. Nothing is stranded
    /// either way.
    function cancelExpired(uint256[] calldata orderIds) external nonReentrant {
        for (uint256 i; i < orderIds.length; ++i) {
            uint256 orderId = orderIds[i];
            (Order storage order, address maker) = _live(orderId);
            if (!_expired(order.expiry)) revert OrderNotExpired(orderId);
            if (frozen(orderId)) revert OrderFrozen(orderId);

            _returnEscrow(order, maker, false);
            emit OrderExpiredSwept(orderId, maker, msg.sender);
        }
    }

    /// @notice Sweep variant that skips stale entries instead of reverting the
    ///         batch.
    /// @dev A keeper reads the sweepable set, then submits; anything filled or
    /// swept in between would abort an all-or-nothing sweep and clean nothing.
    /// Same reasoning as tryFillOrders. Returns which ids were actually swept.
    /// A settlement that reverts still aborts the batch - an escrow that cannot
    /// be returned (a collection that refuses the transfer) strands the whole
    /// sweep. Same EIP-170 reason as tryFillOrders above.
    function trySweepExpired(uint256[] calldata orderIds) external nonReentrant returns (bool[] memory swept) {
        swept = new bool[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            uint256 orderId = orderIds[i];
            Order storage order = orders[orderId];
            address maker = order.maker;
            if (maker == address(0) || !order.active || !_expired(order.expiry) || frozen(orderId)) continue;

            _returnEscrow(order, maker, false);
            emit OrderExpiredSwept(orderId, maker, msg.sender);
            swept[i] = true;
        }
    }

    /// @notice Owner-only. Freeze an order so its claim cannot change.
    /// @dev Freezing is what turns a position into a self-contained asset: no
    ///      taker can fill it and the owner cannot reprice it, so what a buyer
    ///      simulates is what they receive. Cancellation stays available,
    ///      because that is the owner's own escape and cannot surprise anyone
    ///      else - and an escrow that has TAKEN CUSTODY of the position IS the
    ///      owner. Selling without custody wants `commitFrozen` instead, which
    ///      is the same guarantee made to someone who is not yet the owner.
    ///
    ///      A live commitment is not lifted by thawing here; it outranks this
    ///      flag until it lapses.
    function setFrozen(uint256 orderId, bool value) external nonReentrant {
        _liveOwned(orderId);
        _softFrozen[orderId] = value;
        emit OrderFreezeSet(orderId, value);
    }

    /// @notice Owner-only. BIND the order until `until`: no fill, no sweep, no
    ///         repricing, no cancellation - by anyone, the owner included.
    ///
    /// @dev The promise a soft freeze cannot make. A live commitment cannot be
    ///      touched at all - not by the owner, not by a later owner - so the
    ///      `frozenUntil` a buyer verifies is the whole window and not a floor
    ///      the seller can raise between simulation and settlement. It survives
    ///      transfer too, so it cannot be voided by handing the receipt to a
    ///      second wallet and cancelling from there. A new window may only be
    ///      opened once the previous one has lapsed.
    ///
    ///      Pick a window that outlasts the SALE, not the position, and pick it
    ///      RIGHT THE FIRST TIME: there is no early exit by any path, the
    ///      owner's included, and no way to lengthen it once made, so whatever
    ///      is committed here is genuinely immovable for exactly that long.
    ///      `MAX_COMMITMENT` bounds the damage of getting it wrong.
    function commitFrozen(uint256 orderId, uint64 until) external nonReentrant {
        _liveOwned(orderId);
        uint64 live = frozenUntil[orderId];
        if (block.timestamp < live) revert CommitmentActive(orderId, live);
        if (until <= block.timestamp) revert ExpiryInPast(until);
        uint64 max = uint64(block.timestamp) + MAX_COMMITMENT;
        if (until > max) revert CommitmentTooLong(until, max);
        frozenUntil[orderId] = until;
        emit OrderCommitmentSet(orderId, until);
    }

    /// @dev The cancellation path's commitment check. Repricing reaches the
    ///      same rule through `frozen`, which folds in the soft flag as well;
    ///      cancellation cannot use that helper because a soft freeze must
    ///      still leave the owner their own escape.
    function _checkNotCommitted(uint256 orderId) internal view {
        uint64 until = frozenUntil[orderId];
        if (block.timestamp < until) revert CommitmentActive(orderId, until);
    }

    function _cancel(uint256 orderId, bool unwrap) internal {
        (Order storage order, address maker) = _liveOwned(orderId);
        // A soft freeze leaves this open - it is the owner's own escape. A
        // commitment does not: cancelling under a buyer is the exact move it
        // exists to rule out.
        _checkNotCommitted(orderId);

        _returnEscrow(order, maker, unwrap);
        emit OrderCanceled(orderId, maker);
    }

    /// @dev Close the order, then return the remaining escrow. Keeping the
    ///      last live terms makes the non-fungible receipt a useful terminal
    ///      record; `active` alone gates every state-changing path.
    ///
    ///      The amounts are deliberately NOT zeroed, unlike a full fill. That
    ///      asymmetry is the only thing distinguishing the two closes: a filled
    ///      order has both legs at zero. The receipt no longer infers the
    ///      difference from that: slot 0 is exactly full, so the `settled` flag
    ///      lives in its own mapping and `SwapboardMetadata` is told outright
    ///      which kind of close this was. Integrators must read `active`, not
    ///      `amountA`, to decide whether a claim is live.
    function _returnEscrow(Order storage order, address maker, bool unwrap) internal {
        address tokenA = order.tokenA;
        uint256 amountA = order.amountA;
        bool nftA = order.nftA;
        order.active = false;

        if (nftA) {
            delete escrowedNFT[tokenA][amountA];
            _returnNFT(tokenA, maker, amountA);
        } else if (unwrap) {
            if (tokenA != weth) revert NotWETH(weth, tokenA);
            _unwrapETH(amountA);
            maker.safeTransferETH(amountA);
        } else {
            _sendEscrowToken(tokenA, maker, amountA);
        }
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

    /// @notice Batch read carrying the state that `orders` alone cannot report.
    /// @dev `getOrders` returns the packed struct, and `frozen` deliberately
    ///      lives outside it, so a caller reading only that getter cannot tell a
    ///      fillable order from a frozen one. A router that plans over the book
    ///      needs both in the same page or it builds routes whose legs revert;
    ///      returning them together is what keeps the quote and the fill
    ///      agreeing. `isExpired` is likewise derived state a caller would
    ///      otherwise recompute against a stale timestamp.
    function getOrdersWithState(uint256[] calldata orderIds)
        external
        view
        returns (Order[] memory out, bool[] memory isFrozen, bool[] memory isExpired)
    {
        out = new Order[](orderIds.length);
        isFrozen = new bool[](orderIds.length);
        isExpired = new bool[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            out[i] = orders[orderIds[i]];
            isFrozen[i] = frozen(orderIds[i]);
            isExpired[i] = _expired(out[i].expiry);
        }
    }

    /// @notice True when `taker` may fill `orderId` right now.
    /// @dev Pass address(0) to ask only whether the order is live and public.
    ///      Frozen is checked here because `_fill` checks it: an answer that
    ///      omitted it would tell a router an order is fillable and then revert
    ///      on the leg it planned.
    function isFillableBy(uint256 orderId, address taker) public view returns (bool) {
        Order storage o = orders[orderId];
        if (o.maker == address(0) || !o.active || _expired(o.expiry)) return false;
        if (frozen(orderId)) return false;
        address cp = o.counterparty;
        return cp == address(0) || cp == taker;
    }

    /// @notice Batch form of `isFillableBy`, for planners paging the book.
    function areFillableBy(uint256[] calldata orderIds, address taker) external view returns (bool[] memory out) {
        out = new bool[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            out[i] = isFillableBy(orderIds[i], taker);
        }
    }

    // ------------------------------------------------------------- SPLIT QUOTE

    /// @notice What paying `fillAmountB` into `orderId` yields right now.
    /// @dev The exact arithmetic and refusal set of `_applyFill`, in a view. A
    ///      splitter carving one swap across several resting orders has to know
    ///      each leg's output BEFORE it submits, and rederiving the rounding off
    ///      chain is how a route ends up one wei short of its own floor. Both
    ///      return zero for anything that would revert - closed, expired,
    ///      frozen, wrong counterparty is not considered here since it depends
    ///      on the caller, so pair this with `isFillableBy` for private orders.
    ///
    ///      For an NFT-sided order the returned pair is the whole lot, and
    ///      `outA` is a token ID rather than a quantity: NFT orders settle only
    ///      in full, which is exactly what makes them indivisible for a splitter.
    function quoteFill(uint256 orderId, uint256 fillAmountB) public view returns (uint256 outA, uint256 paidB) {
        Order storage o = orders[orderId];
        if (o.maker == address(0) || !o.active || _expired(o.expiry) || frozen(orderId)) return (0, 0);

        uint256 err;
        (outA, paidB,, err) = _computeFill(o.amountA, o.amountB, o.nftA, o.nftB, o.partialFill, fillAmountB);
        if (err != FILL_OK) return (0, 0);
    }

    /// @notice Smallest `fillAmountB` that buys at least `wantA` of tokenA.
    /// @dev The exact-output companion to `quoteFill`, and the reason it exists
    ///      on the board rather than in a router: `_applyFill` rounds the output
    ///      DOWN, so the input has to round UP or the leg lands just under the
    ///      amount the route was built around. Feeding the result back through
    ///      `quoteFill` always yields `outA >= wantA`.
    ///
    ///      Returns zero when no input can satisfy the request, and the full ask
    ///      for an NFT-sided order, which has only one possible payment.
    function quoteFillInput(uint256 orderId, uint256 wantA) public view returns (uint256 fillAmountB) {
        Order storage o = orders[orderId];
        if (o.maker == address(0) || !o.active || _expired(o.expiry) || frozen(orderId)) return 0;

        uint256 amountA = o.amountA;
        uint256 amountB = o.amountB;
        // An NFT leg is all-or-nothing; `wantA` cannot describe a fraction of
        // one, and for nftA it is a token ID rather than a quantity.
        if (o.nftA || o.nftB) return amountB;

        if (wantA == 0 || wantA > amountA) return 0;
        if (wantA == amountA) return amountB;
        if (!o.partialFill) return 0;

        fillAmountB = FixedPointMathLib.fullMulDivUp(wantA, amountB, amountA);
        if (fillAmountB > amountB) fillAmountB = amountB;
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

    /// @dev Every path that acts on an order starts here: it must exist and
    ///      still be live. `maker == address(0)` is how a nonexistent order is
    ///      recognised, which is why a close never clears it.
    function _live(uint256 orderId) internal view returns (Order storage order, address maker) {
        order = orders[orderId];
        maker = order.maker;
        if (maker == address(0)) revert OrderNotFound(orderId);
        if (!order.active) revert OrderNotActive(orderId);
    }

    /// @dev ...and every owner-only path additionally requires makership.
    ///      Ownership IS makership, so this is the receipt holder's authority.
    function _liveOwned(uint256 orderId) internal view returns (Order storage order, address maker) {
        (order, maker) = _live(orderId);
        if (msg.sender != maker) revert NotMaker(orderId, msg.sender, maker);
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
