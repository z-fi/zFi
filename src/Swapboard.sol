// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {ERC721} from "../lib/solady/src/tokens/ERC721.sol";
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
///      taker-side and inclusive. ETH paths use the immutable canonical WETH.
///      Escrow transfers use exact balance or ownership checks.
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
    event OrderReplaced(
        uint256 indexed orderId, address indexed maker, uint256 amountA, uint256 amountB, uint64 expiry
    );
    event OrderCanceled(uint256 indexed orderId, address indexed maker);
    event OrderExpiredSwept(uint256 indexed orderId, address indexed maker, address indexed caller);

    error NotWETH(address expected, address actual);
    error ZeroETH();
    error BadMaker();
    error NotMaker(uint256 orderId, address caller, address maker);
    error SameToken();
    error ZeroAmount();
    error ZeroAddress();
    error BadRecipient();
    error ExpiryInPast(uint64 expiry);
    error NotAContract(address token);
    error OrderExpired(uint256 orderId);
    error OrderNotFound(uint256 orderId);
    error LengthMismatch();
    error OrderNotActive(uint256 orderId);
    error ZeroFillAmount();
    error BalanceMismatch(uint256 expected, uint256 received);
    error DeadlineExpired();
    error NFTNotDivisible();
    error NotCounterparty(uint256 orderId, address caller, address counterparty);
    error OrderNotExpired(uint256 orderId);
    error DirectNFTTransfer();
    error ETHAmountMismatch(uint256 required, uint256 sent);
    error NFTNotReplaceable(uint256 orderId);
    error NFTTransferFailed(address token, uint256 tokenId);
    error BalanceDeltaMismatch(address token, address account, uint256 expected, uint256 actual);
    error PartialFillNotAllowed(uint256 orderId);
    error InsufficientOutput(uint256 minimum, uint256 actual);

    /// @dev Use the chain's canonical WETH deployment.
    constructor(address _weth) {
        if (_weth == address(0)) revert ZeroAddress();
        if (_weth.code.length == 0) revert NotAContract(_weth);
        weth = _weth;
    }

    // ------------------------------------------------------ POSITION RECEIPTS

    function name() public pure override returns (string memory) {
        return "Swapboard Position";
    }

    function symbol() public pure override returns (string memory) {
        return "SBPOS";
    }

    /// @dev Deliberately empty. Everything about a position is already on
    ///      chain and readable through `orders`, so a URI would either point
    ///      somewhere that can rot or duplicate what a caller can already fetch.
    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    /// @dev Ownership IS makership. Rather than teach settlement to consult
    ///      `ownerOf`, the stored `maker` is kept in step on every transfer, so
    ///      payout, cancellation and repricing keep working exactly as before
    ///      and there is only ever one source of truth. Minting sets it in
    ///      `_store`; burning is a close, where it must not be cleared because
    ///      `maker == address(0)` is how a nonexistent order is recognised.
    function _afterTokenTransfer(address from, address to, uint256 id) internal override {
        if (from != address(0) && to != address(0)) {
            _checkMaker(to);
            orders[id].maker = to;
        }
    }

    /// @dev Only WETH may send ETH through an ordinary call.
    receive() external payable {
        if (msg.sender != weth) revert NotWETH(weth, msg.sender);
    }

    /// @notice Terms carried in a pushed NFT's transfer data.
    /// @dev Exactly five words. `tokenA` is not present: the collection is
    ///      established by the call itself, not by anything the sender writes.
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
    ///      transfer would be the bug. A caller that moved nothing must not be
    ///      able to mint an order over escrow that is already backing somebody
    ///      else's, which is exactly what checking `ownerOf` prevents. The same
    ///      reasoning as Dutchboard's push listing.
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
        if (data.length != 160) revert DirectNFTTransfer();
        PushOrder memory o = abi.decode(data, (PushOrder));

        address tokenA = msg.sender;
        // This board is itself an ERC-721 now, so a position pushed back here
        // would try to escrow the board's own receipt against itself.
        if (tokenA == address(this)) revert BadMaker();
        // `from` becomes the maker, and a maker is a payout address: the same
        // addresses refused at creation are refused here.
        _checkMaker(from);
        if (tokenA.code.length == 0) revert NotAContract(tokenA);
        if (o.tokenB == address(0)) revert ZeroAddress();
        if (o.tokenB.code.length == 0) revert NotAContract(o.tokenB);
        // tokenId 0 is a legitimate NFT, so only a fungible side is checked.
        if (!o.nftB && o.amountB == 0) revert ZeroAmount();
        // Two fungible legs in one token would be a no-op trade; here tokenA is
        // always an NFT, so a shared collection is a legitimate 721-for-721
        // swap and only the degenerate same-id case needs refusing - which the
        // payment leg's ownerOf preflight already does at fill time.
        _checkExpiry(o.expiry);

        if (IERC721(tokenA).ownerOf(tokenId) != address(this)) {
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
        if (tokenB.code.length == 0) revert NotAContract(tokenB);
        _checkExpiry(expiry);

        if (nftA) {
            _moveNFT(tokenA, msg.sender, address(this), amountA);
        } else {
            // A fee-on-transfer token would leave the escrow short of amountA,
            // so what actually arrived is measured rather than assumed.
            uint256 before = tokenA.balanceOf(address(this));
            tokenA.safeTransferFrom(msg.sender, address(this), amountA);
            uint256 received = _increase(before, tokenA.balanceOf(address(this)));
            if (received != amountA) revert BalanceMismatch(amountA, received);
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

    /// @dev Confirm exact board debit and recipient credit for pooled escrow.
    function _sendEscrowToken(address token, address to, uint256 amount) internal {
        uint256 boardBefore = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);

        uint256 spent = _decrease(boardBefore, token.balanceOf(address(this)));
        if (spent != amount) {
            revert BalanceDeltaMismatch(token, address(this), amount, spent);
        }

        uint256 received = _increase(recipientBefore, token.balanceOf(to));
        if (received != amount) {
            revert BalanceDeltaMismatch(token, to, amount, received);
        }
    }

    /// @dev Confirm that a direct fungible payment credits the maker by the
    ///      nominal amount. This rejects fee-on-transfer and other tokens that
    ///      debit the taker by one amount while crediting the maker by another.
    function _payToken(address token, address from, address to, uint256 amount) internal {
        uint256 recipientBefore = token.balanceOf(to);
        token.safeTransferFrom(from, to, amount);
        uint256 received = _increase(recipientBefore, token.balanceOf(to));
        if (received != amount) revert BalanceDeltaMismatch(token, to, amount, received);
    }

    /// @dev Confirm the exact WETH credit from wrapping.
    function _wrapETH(uint256 amount) internal {
        uint256 beforeBalance = weth.balanceOf(address(this));
        IWETH(weth).deposit{value: amount}();
        uint256 received = _increase(beforeBalance, weth.balanceOf(address(this)));
        if (received != amount) {
            revert BalanceDeltaMismatch(weth, address(this), amount, received);
        }
    }

    /// @dev Confirm exact WETH debit and native ETH credit.
    function _unwrapETH(uint256 amount) internal {
        uint256 wethBefore = weth.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        IWETH(weth).withdraw(amount);

        uint256 spent = _decrease(wethBefore, weth.balanceOf(address(this)));
        if (spent != amount) {
            revert BalanceDeltaMismatch(weth, address(this), amount, spent);
        }

        uint256 received = _increase(ethBefore, address(this).balance);
        if (received != amount) {
            revert BalanceDeltaMismatch(address(0), address(this), amount, received);
        }
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

    /// @dev Skips orders that are inactive, missing, expired, or reserved for a
    /// different counterparty. Every other revert path still aborts the batch;
    ///      minimum-output failures are not silently skipped.
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
            if (o.active && !_expired(o.expiry) && (cp == address(0) || cp == msg.sender)) {
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
    )
        external
        nonReentrant
    {
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
        Order storage order = orders[orderId];
        address maker = order.maker;
        if (maker == address(0)) revert OrderNotFound(orderId);
        if (!order.active) revert OrderNotActive(orderId);
        // Maker-side expiry. Distinct from the `deadline` argument above, which
        // guards the taker against a stale mempool transaction.
        if (_expired(order.expiry)) revert OrderExpired(orderId);

        address cp = order.counterparty;
        if (cp != address(0) && cp != msg.sender) revert NotCounterparty(orderId, msg.sender, cp);

        (uint256 outA, uint256 paidB, bool full) = _applyFill(orderId, order, fillAmountB);

        // A taker signs this floor before the transaction enters the public
        // mempool. It therefore remains protected if the maker reprices the
        // live order before this call executes. NFT token IDs are not amounts,
        // so the floor applies only to fungible tokenA legs.
        if (!order.nftA && outA < minAmountA) revert InsufficientOutput(minAmountA, outA);

        _settleFill(FillLegs(order.tokenA, order.tokenB, maker, to, outA, paidB, mode, order.nftA, order.nftB));

        if (full) {
            emit OrderFilled(orderId, msg.sender, maker, outA, paidB);
        } else {
            emit OrderPartiallyFilled(orderId, msg.sender, maker, outA, paidB, order.amountA, order.amountB);
        }
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

        // NFT orders always settle in full. Their amount fields may be token IDs,
        // so zero remains the explicit full-fill sentinel for either NFT side.
        // Fungible orders must receive an explicit payment amount: resolving zero
        // against the live order would let a maker reprice the taker's input after
        // the taker signed a transaction.
        if (fillAmountB == 0 && !order.nftA && !order.nftB) revert ZeroFillAmount();
        if (fillAmountB != 0) {
            if (order.nftB && fillAmountB != amountB) revert PartialFillNotAllowed(orderId);
            if (order.nftA && fillAmountB < amountB) revert PartialFillNotAllowed(orderId);
        }

        if (order.nftA || order.nftB || fillAmountB >= amountB) {
            order.active = false;
            order.amountA = 0;
            order.amountB = 0;
            // The position exists exactly while the order does. A PARTIAL fill
            // leaves the order live with a remainder, so its receipt survives
            // and its claim simply shrinks; only a closing fill burns it.
            _burn(orderId);
            return (amountA, amountB, true);
        }

        if (!order.partialFill) revert PartialFillNotAllowed(orderId);
        // Rounds down, favouring the maker. Full precision so large
        // 18-decimal amounts cannot overflow the intermediate product.
        outA = FixedPointMathLib.fullMulDiv(fillAmountB, amountA, amountB);
        if (outA == 0) revert ZeroFillAmount();
        order.amountA = amountA - outA;
        order.amountB = amountB - fillAmountB;
        return (outA, fillAmountB, false);
    }

    /// @dev Settlement arguments, grouped only so they occupy one stack slot
    ///      at the call site. `_fill` carries enough live locals that passing
    ///      these individually exhausts the stack under via-IR.
    struct FillLegs {
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
        if (f.nftB) _moveNFT(f.tokenB, msg.sender, f.maker, f.fillAmountB);
        else if ((f.mode & 2) != 0) _sendEscrowToken(f.tokenB, f.maker, f.fillAmountB);
        else _payToken(f.tokenB, msg.sender, f.maker, f.fillAmountB);

        // tokenA to the taker. Confirmed at both ends too: escrow can go
        // missing between creation and fill on a collection that leaves a stale
        // approval behind, and the taker has already paid by this point.
        if (f.nftA) {
            _moveNFT(f.tokenA, address(this), f.to, f.outA);
        } else if ((f.mode & 1) != 0) {
            if (f.tokenA != weth) revert NotWETH(weth, f.tokenA);
            _unwrapETH(f.outA);
            f.to.safeTransferETH(f.outA);
        } else {
            _sendEscrowToken(f.tokenA, f.to, f.outA);
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
        Order storage order = orders[orderId];
        address maker = order.maker;
        if (maker == address(0)) revert OrderNotFound(orderId);
        if (!order.active) revert OrderNotActive(orderId);
        if (msg.sender != maker) revert NotMaker(orderId, msg.sender, maker);
        if (order.nftA || order.nftB) revert NFTNotReplaceable(orderId);
        if (newAmountA == 0 || newAmountB == 0) revert ZeroAmount();
        _checkExpiry(newExpiry);

        address tokenA = order.tokenA;
        uint256 amountA = order.amountA;

        if (newAmountA > amountA) {
            uint256 delta;
            unchecked {
                delta = newAmountA - amountA;
            }
            uint256 before = tokenA.balanceOf(address(this));
            tokenA.safeTransferFrom(msg.sender, address(this), delta);
            uint256 received = _increase(before, tokenA.balanceOf(address(this)));
            if (received != delta) revert BalanceMismatch(delta, received);
            (order.amountA, order.amountB, order.expiry) = (newAmountA, newAmountB, newExpiry);
        } else {
            uint256 delta;
            unchecked {
                delta = amountA - newAmountA;
            }
            (order.amountA, order.amountB, order.expiry) = (newAmountA, newAmountB, newExpiry);
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
    function cancelExpired(uint256[] calldata orderIds) external nonReentrant {
        for (uint256 i; i < orderIds.length; ++i) {
            uint256 orderId = orderIds[i];
            Order storage order = orders[orderId];
            address maker = order.maker;
            if (maker == address(0)) revert OrderNotFound(orderId);
            if (!order.active) revert OrderNotActive(orderId);
            if (!_expired(order.expiry)) revert OrderNotExpired(orderId);

            _returnEscrow(orderId, order, maker, false);
            emit OrderExpiredSwept(orderId, maker, msg.sender);
        }
    }

    /// @notice Sweep variant that skips stale entries instead of reverting the
    ///         batch.
    /// @dev A keeper reads the sweepable set, then submits; anything filled or
    /// swept in between would abort an all-or-nothing sweep and clean nothing.
    /// Same reasoning as tryFillOrders. Returns which ids were actually swept.
    /// A settlement that reverts still aborts the batch - see _returnEscrow.
    function trySweepExpired(uint256[] calldata orderIds) external nonReentrant returns (bool[] memory swept) {
        swept = new bool[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            uint256 orderId = orderIds[i];
            Order storage order = orders[orderId];
            address maker = order.maker;
            if (maker == address(0) || !order.active || !_expired(order.expiry)) continue;

            _returnEscrow(orderId, order, maker, false);
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

        _returnEscrow(orderId, order, maker, unwrap);
        emit OrderCanceled(orderId, maker);
    }

    /// @dev Clear storage, then return the remaining escrow. Transfer failures
    /// revert; only stale sweep entries are skipped by the caller.
    function _returnEscrow(uint256 orderId, Order storage order, address maker, bool unwrap) internal {
        address tokenA = order.tokenA;
        uint256 amountA = order.amountA;
        bool nftA = order.nftA;
        order.active = false;
        order.amountA = 0;
        order.amountB = 0;
        _burn(orderId);

        if (nftA) {
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
