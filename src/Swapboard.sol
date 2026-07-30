// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {Multicallable} from "../lib/solady/src/utils/Multicallable.sol";
import {SafeTransferLib} from "../lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "../lib/solady/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "../lib/solady/src/utils/ReentrancyGuardTransient.sol";

/// @title Swapboard
/// @notice Escrowed peer-to-peer orders. Either side may be an ERC-20 or an
///         ERC-721, with optional partial fills, an optional maker-side expiry
///         and an optional named counterparty.
///
/// @dev Extends the audited Swapboard deployed by the Ethereum Community
///      Foundation (0x000000fF3D7A2d373615141d7489Ca66683DbecF). The escrow
///      model is unchanged: a maker deposits tokenA on creation, a taker pays
///      tokenB on fill, and cancellation returns the remainder. Everything
///      below documents the additions and their security or compatibility
///      trade-offs.
///
/// EXPIRY
///   An order without a lifetime is a free option written to the market: the
///   escrow rests at a fixed price, and if the market moves, anyone may take
///   the stale side until the maker pays gas to cancel. `expiry` bounds that.
///   0 means never expires, preserving the original behaviour by default.
///
///   Note this is distinct from the `deadline` argument carried on every fill,
///   which is a TAKER-side guard against a stale mempool transaction and says
///   nothing about how long the order rests. Both bounds are inclusive: an order
///   is fillable at its `expiry` timestamp and expires once block.timestamp is
///   greater; a transaction is valid at its `deadline` timestamp.
///
/// PARTIAL FILLS
///   A taker may take part of an order when the maker allows it, leaving the
///   remainder resting. Amounts divide with full-precision mulDiv rounding
///   toward the maker, and a fill too small to move any tokenA is rejected.
///   Partial fills are what make this a limit book rather than an OTC board,
///   and a nonzero expiry keeps a remainder from resting indefinitely.
///
/// NFT SIDES
///   `nftA` / `nftB` mark a side as an ERC-721, where the matching amount is a
///   tokenId. tokenId 0 is legitimate, so the zero-amount check is skipped for
///   that side. Partial fills are refused whenever either side is an NFT,
///   because an ERC-721 is indivisible, and an NFT order settles only at its
///   full ask - a short bid is refused rather than quietly billed in full.
///
///   NFTs move with transferFrom, never safeTransferFrom. safeTransferFrom
///   invokes onERC721Received on a contract recipient, opening a callback into
///   the middle of settlement and refusing recipients that do not implement the
///   hook. Settlement state is written before its external transfer legs, and
///   every state-mutating order entry point is nonReentrant.
///
///   transferFrom returns nothing, so a collection that no-ops an unauthorised
///   transfer instead of reverting - an `if` where the standard requires a
///   `require`, which real collections have shipped - is indistinguishable from
///   one that settled. Every leg therefore confirms with ownerOf rather than
///   trusting the call, and confirms BOTH ends: asking only where the token
///   ended up would accept one that was already sitting there, which is how a
///   fresh order could be backed by an NFT the board is holding for somebody
///   else. The one exception is the return leg (cancel and sweep), where an NFT
///   already at the maker means the return is complete rather than failed.
///
/// WHAT THE ESCROW MEASURES, AND WHAT IT DOES NOT
///   Fungible tokenA is balance-measured on both entry and exit. Entry must
///   credit the board by exactly amountA; exit must debit the board and credit
///   the recipient by exactly the settled amount. This rejects fee-on-transfer,
///   rebasing-during-transfer and true-returning no-op tokens before they can
///   leave an active order undercollateralised or close an order without paying
///   its owner. NFT ownership is verified as described above. Elastic-supply
///   tokens can still rebase pooled custody between transactions and are
///   therefore unsupported.
///
///   Fungible tokenB is not measured on an ordinary fill: it goes straight from
///   taker to maker and never touches the board's books, so a token that skims
///   on transfer would pay the maker less than amountB. Measuring it would cost
///   two balance reads on every fill and would refuse such tokens outright
///   rather than merely disclosing them, so it is left to the maker: pricing an
///   order in a fee-on-transfer token prices in its fee. NFT-B ownership is
///   verified. The ETH path is different: its WETH passes through the board, so
///   wrap, transfer and unwrap deltas are all confirmed exactly to keep
///   unrelated WETH escrow isolated.
///
/// PRIVATE ORDERS
///   `counterparty` restricts a fill to one address; 0 leaves the order public.
///
/// RECIPIENT
///   Every fill takes a `recipient`, so an aggregator can settle straight to
///   its user instead of receiving and forwarding. It is a delivery address and
///   never authorisation: `counterparty` is still tested against msg.sender,
///   because a caller-supplied recipient could otherwise be set to the intended
///   counterparty and drain every private order. A private order can be routed
///   only when the router itself is the named counterparty; naming an end user
///   does not authorize a third-party router.
///
///   Both the `recipient` of a fill and the `maker` of a sponsored order are
///   payout addresses, and both refuse the board itself and the wrapper. An
///   unwrapped payout to WETH would be re-wrapped to the board and lost, and
///   anything sent to the board sits outside the escrow it accounts for. This
///   contract is immutable and neither mistake is recoverable.
///
/// SWEEPING
///   Expired orders may be swept by anyone. Escrow always returns to the maker,
///   so nothing is capturable; it exists so funds are never stranded behind an
///   absent maker. cancelExpired is strict, trySweepExpired skips stale entries
///   - a keeper's list is read before it is mined, and anything filled in
///   between would otherwise abort the whole batch. Stale is the only thing it
///   skips: a settlement that reverts still aborts the batch, because a sweep
///   that quietly closed an order it could not pay out would discard the very
///   claim it exists to protect.
///
/// BATCHING
///   Typed batch entry points cover the common cases: createOrders, fillOrders,
///   tryFillOrders, replaceOrders, cancelOrders, cancelExpired,
///   trySweepExpired. multicall
///   covers the rest by composing them in one transaction. Repricing has its
///   own entry point, replaceOrder, because cancel-then-create moves the whole
///   escrow twice and rewrites storage under a new id to express a change of
///   two numbers; see its docs. Every state-mutating order entry point is
///   nonReentrant, and the guard clears between sub-calls, so they compose in
///   sequence.
///
///   multicall refuses a non-zero msg.value, since forwarding one value to
///   several calls would let it be spent more than once. The payable paths
///   (createOrderWithEth, fillOrderWithEth) are therefore outside it: reprice a
///   WETH order with cancelOrder + createOrder rather than the unwrap variants.
///
/// STORAGE
///   maker(160) + active(8) + partialFill(8) + expiry(64) + nftA(8) + nftB(8)
///   is exactly 256 bits, so expiry and both NFT flags cost no extra storage.
///   `counterparty` cannot fit a remaining gap (the widest is 96 bits) and
///   takes a slot of its own, paid only by orders that use it.
contract Swapboard is ReentrancyGuardTransient, Multicallable {
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

    error BadMaker();
    error ZeroETH();
    error SameToken();
    error ZeroAmount();
    error ZeroAddress();
    error BadRecipient();
    error LengthMismatch();
    error ZeroFillAmount();
    error DeadlineExpired();
    error NFTNotDivisible();
    error NFTNotReplaceable(uint256 orderId);
    error DirectNFTTransfer();
    error ExpiryInPast(uint64 expiry);
    error NotAContract(address token);
    error OrderExpired(uint256 orderId);
    error OrderNotFound(uint256 orderId);
    error OrderNotActive(uint256 orderId);
    error OrderNotExpired(uint256 orderId);
    error PartialFillNotAllowed(uint256 orderId);
    error NotWETH(address expected, address actual);
    error NFTTransferFailed(address token, uint256 tokenId);
    error ETHAmountMismatch(uint256 required, uint256 sent);
    error BalanceMismatch(uint256 expected, uint256 received);
    error BalanceDeltaMismatch(address token, address account, uint256 expected, uint256 actual);
    error NotMaker(uint256 orderId, address caller, address maker);
    error NotCounterparty(uint256 orderId, address caller, address counterparty);

    /// @dev `_weth` is a deployment trust root. Exact balance deltas are checked
    /// at runtime, but a malicious wrapper can also lie through `balanceOf`;
    /// deployments must still use the chain's canonical, immutable wrapper.
    constructor(address _weth) {
        if (_weth == address(0)) revert ZeroAddress();
        if (_weth.code.length == 0) revert NotAContract(_weth);
        weth = _weth;
    }

    /// @dev Only WETH may send ETH here through an ordinary call, via withdraw()
    /// during an unwrap. Forced ETH can still arrive without executing receive().
    receive() external payable {
        if (msg.sender != weth) revert NotWETH(weth, msg.sender);
    }

    /// @dev Refuse unsolicited safeTransferFrom deposits. Orders escrow with
    /// transferFrom, so accepting direct 721 sends would only create untracked
    /// inventory with no safe owner-authenticated rescue path.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert DirectNFTTransfer();
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

    /// @notice Create a fully-funded order owned by `maker`.
    /// @dev The caller supplies the escrow, while cancellation rights, returned
    ///      escrow, and fill proceeds belong to `maker`. This is the routed
    ///      creation primitive: a zRouter-funded executor can receive the
    ///      maker's asset, approve this contract for the exact amount, and call
    ///      here without becoming the on-book maker itself.
    ///
    ///      No maker signature is required because the caller cannot debit the
    ///      named maker: it pays from its own balance. Naming somebody else can
    ///      only gift that address a funded order. It cannot, however, be used to
    ///      post an order nobody can be paid through - see _checkMaker. An
    ///      integrator must not read `maker` as evidence that the named address
    ///      asked for the order; it evidences only who will be paid.
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

    /// @dev Moves an ERC-721 and proves it moved. transferFrom returns nothing,
    /// so a collection that no-ops an unauthorised transfer rather than
    /// reverting looks exactly like one that settled.
    ///
    /// Both ends are checked, and the first check is the load-bearing one.
    /// Confirming only the destination answers "does `to` hold it now", which is
    /// already true whenever the token was sitting there beforehand: against
    /// such a collection anyone could escrow an NFT the board is holding for
    /// another maker - the transfer does nothing, the destination check passes -
    /// and then cancel that order to walk off with it.
    function _moveNFT(address token, address from, address to, uint256 tokenId) internal {
        if (IERC721(token).ownerOf(tokenId) != from) revert NFTTransferFailed(token, tokenId);
        IERC721(token).transferFrom(from, to, tokenId);
        if (IERC721(token).ownerOf(tokenId) != to) revert NFTTransferFailed(token, tokenId);
    }

    /// @dev Return leg of the escrow, for cancel and sweep. An NFT already back
    /// with the maker means the return is complete, not failed. Otherwise the board
    /// must still own it before the transfer, and the maker must own it after.
    /// This preflight is important: a collection may allow the token to find
    /// its way home through a sticky approval yet correctly revert a later
    /// transfer whose declared `from` is no longer the owner.
    function _returnNFT(address token, address to, uint256 tokenId) internal {
        address owner = IERC721(token).ownerOf(tokenId);
        if (owner == to) return;
        if (owner != address(this)) revert NFTTransferFailed(token, tokenId);
        IERC721(token).transferFrom(address(this), to, tokenId);
        if (IERC721(token).ownerOf(tokenId) != to) revert NFTTransferFailed(token, tokenId);
    }

    /// @dev Transfers escrowed fungible tokens without trusting the token's
    /// boolean return value alone. Both deltas matter: an exact recipient credit
    /// catches a true-returning no-op or recipient-side tax, while an exact
    /// board debit prevents a sender-paid fee from consuming another order's
    /// pooled escrow. A revert restores both the order state and the token call.
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

    /// @dev The board pools WETH escrow across orders, so a successful-looking
    /// deposit that under-mints must not let this call spend somebody else's
    /// backing.
    function _wrapETH(uint256 amount) internal {
        uint256 beforeBalance = weth.balanceOf(address(this));
        IWETH(weth).deposit{value: amount}();
        uint256 received = _increase(beforeBalance, weth.balanceOf(address(this)));
        if (received != amount) {
            revert BalanceDeltaMismatch(weth, address(this), amount, received);
        }
    }

    /// @dev Confirms both sides of the wrapper redemption. Exact WETH debit
    /// prevents an over-burning wrapper from consuming another order; exact ETH
    /// receipt prevents forced or donated ETH from subsidising a short unwrap.
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

    /// @dev A maker is a payout address, not merely a label: returned escrow and
    /// fill proceeds are both sent there. `_to` refuses the board and the wrapper
    /// as a delivery address for that reason, and the same two are refused here.
    ///
    /// Naming the board is the worse of the two, and the only one a fill does not
    /// simply revert on. Such an order can never be cancelled - msg.sender is
    /// never the board - and the sweep cannot credit the board from its own
    /// balance, so the escrow is locked. A fill, however, SUCCEEDS: the ordinary
    /// tokenB leg goes straight from taker to maker and is deliberately not
    /// balance-measured, so it lands on the board as untracked inventory with no
    /// owner and no rescue path. The order looks live and public on-book, so that
    /// loss falls on the taker rather than on whoever funded the mistake.
    function _checkMaker(address maker) internal view {
        if (maker == address(0)) revert ZeroAddress();
        if (maker == address(this) || maker == weth) revert BadMaker();
    }

    /// @dev Creation requires every nonzero expiry to be strictly in the future.
    /// Fill and sweep use the inclusive boundary documented in the contract header.
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
        emit OrderCreated(
            orderId, maker, tokenA, amountA, tokenB, amountB, partialFill, expiry, nftA, nftB, counterparty
        );
    }

    // ------------------------------------------------------------------- FILL

    /// @param recipient Where tokenA is delivered. address(0) means the caller.
    ///        This is a delivery address only - it is NEVER used for
    ///        authorisation. `counterparty` is still checked against msg.sender,
    ///        because a caller-supplied recipient could otherwise be set to the
    ///        intended counterparty and drain every private order.
    function fillOrder(uint256 orderId, uint256 deadline, uint256 fillAmountB, address recipient)
        external
        nonReentrant
    {
        _checkDeadline(deadline);
        _fill(orderId, fillAmountB, false, false, _to(recipient));
    }

    /// @dev Atomic: if any fill reverts, the whole batch reverts.
    /// @notice Fill several orders atomically; any failure aborts the batch.
    ///         Use tryFillOrders to skip rather than revert.
    function fillOrders(
        uint256[] calldata orderIds,
        uint256 deadline,
        uint256[] calldata fillAmountsB,
        address recipient
    ) external nonReentrant {
        _checkDeadline(deadline);
        if (orderIds.length != fillAmountsB.length) revert LengthMismatch();
        address to = _to(recipient);
        for (uint256 i; i < orderIds.length; ++i) {
            _fill(orderIds[i], fillAmountsB[i], false, false, to);
        }
    }

    /// @dev Skips orders that are inactive, missing, expired, or reserved for a
    /// different counterparty. Every other revert path still aborts the batch.
    function tryFillOrders(
        uint256[] calldata orderIds,
        uint256 deadline,
        uint256[] calldata fillAmountsB,
        address recipient
    ) external nonReentrant returns (bool[] memory filled) {
        _checkDeadline(deadline);
        if (orderIds.length != fillAmountsB.length) revert LengthMismatch();
        address to = _to(recipient);
        filled = new bool[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            Order storage o = orders[orderIds[i]];
            address cp = o.counterparty;
            if (o.active && !_expired(o.expiry) && (cp == address(0) || cp == msg.sender)) {
                _fill(orderIds[i], fillAmountsB[i], false, false, to);
                filled[i] = true;
            }
        }
    }

    /// @notice Fill and receive tokenA as ETH rather than WETH. Reverts unless
    ///         tokenA is WETH; ignored when tokenA is an NFT.
    function fillOrderUnwrap(uint256 orderId, uint256 deadline, uint256 fillAmountB, address recipient)
        external
        nonReentrant
    {
        _checkDeadline(deadline);
        _fill(orderId, fillAmountB, true, false, _to(recipient));
    }

    /// @dev msg.value is the fill amount and is wrapped before settlement, so a
    /// value above the remaining amountB is refused rather than refunded.
    ///
    /// The prepaid path accepts a short payment only for a divisible partial
    /// order. NFT-A and all-or-nothing orders must arrive exactly paid. _fill
    /// independently rejects those short fills; checking here gives the ETH path
    /// its specific ETHAmountMismatch error before wrapping the caller's value.
    function fillOrderWithEth(uint256 orderId, uint256 deadline, address recipient) external payable nonReentrant {
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
        _fill(orderId, msg.value, false, true, _to(recipient));
    }

    function _fill(uint256 orderId, uint256 fillAmountB, bool unwrap, bool prepaid, address to) internal {
        Order storage order = orders[orderId];
        address maker = order.maker;
        if (maker == address(0)) revert OrderNotFound(orderId);
        if (!order.active) revert OrderNotActive(orderId);
        // Maker-side expiry. Distinct from the `deadline` argument above, which
        // guards the taker against a stale mempool transaction.
        if (_expired(order.expiry)) revert OrderExpired(orderId);

        address cp = order.counterparty;
        if (cp != address(0) && cp != msg.sender) revert NotCounterparty(orderId, msg.sender, cp);

        address tokenA = order.tokenA;
        address tokenB = order.tokenB;
        bool nftA = order.nftA;
        bool nftB = order.nftB;
        uint256 amountA = order.amountA;
        uint256 amountB = order.amountB;

        // An NFT order always settles in full. Zero is the explicit full-fill
        // sentinel; any nonzero value must not authorize more than it names:
        //   nftB - amountB is a tokenId, so the >= comparison used to detect a
        //          full fill is meaningless. Exact match, or the 0 sentinel.
        //   nftA - amountB is a price. An overbid still clamps to the ask, as
        //          it does for any order, but a short bid must not be billed at
        //          the full ask; that is the same hazard fillOrderWithEth
        //          already refuses, reached through the ERC-20 leg instead.
        if (fillAmountB != 0) {
            if (nftB && fillAmountB != amountB) revert PartialFillNotAllowed(orderId);
            if (nftA && fillAmountB < amountB) revert PartialFillNotAllowed(orderId);
        }

        uint256 outA;
        bool full;
        if (nftA || nftB || fillAmountB == 0 || fillAmountB >= amountB) {
            order.active = false;
            order.amountA = 0;
            order.amountB = 0;
            (outA, fillAmountB, full) = (amountA, amountB, true);
        } else {
            if (!order.partialFill) revert PartialFillNotAllowed(orderId);
            // Rounds down, favouring the maker. Full precision so large
            // 18-decimal amounts cannot overflow the intermediate product.
            outA = FixedPointMathLib.fullMulDiv(fillAmountB, amountA, amountB);
            if (outA == 0) revert ZeroFillAmount();
            order.amountA = amountA - outA;
            order.amountB = amountB - fillAmountB;
        }

        // tokenB to the maker. On the ETH path it is already wrapped and held here.
        // The 721 leg is the maker's payment, so it is confirmed rather than
        // assumed: an unconfirmed no-op would hand the escrow over for nothing.
        if (nftB) _moveNFT(tokenB, msg.sender, maker, fillAmountB);
        else if (prepaid) _sendEscrowToken(tokenB, maker, fillAmountB);
        else tokenB.safeTransferFrom(msg.sender, maker, fillAmountB);

        // tokenA to the taker. Confirmed at both ends too: escrow can go missing
        // between creation and fill on a collection that leaves a stale approval
        // behind, and the taker has already paid by this point.
        if (nftA) {
            _moveNFT(tokenA, address(this), to, outA);
        } else if (unwrap) {
            if (tokenA != weth) revert NotWETH(weth, tokenA);
            _unwrapETH(outA);
            to.safeTransferETH(outA);
        } else {
            _sendEscrowToken(tokenA, to, outA);
        }

        if (full) {
            emit OrderFilled(orderId, msg.sender, maker, outA, fillAmountB);
        } else {
            emit OrderPartiallyFilled(orderId, msg.sender, maker, outA, fillAmountB, order.amountA, order.amountB);
        }
    }

    // ---------------------------------------------------------------- REPLACE

    /// @notice Maker-only. Reprice and resize a live fungible order in place.
    /// @dev Repricing is cancelOrder followed by createOrder, which works but
    ///      pays for it twice: the whole escrow makes a round trip through the
    ///      maker, and the new order writes fresh storage under a fresh id.
    ///      For a human repricing occasionally that is noise. For a programmatic
    ///      maker - a pool quoting a two-sided market that must reprice after
    ///      every fill - it is the dominant cost, and it is pure overhead,
    ///      since the order that comes back is the same order at a new price.
    ///
    ///      Only the three things a reprice actually changes may change:
    ///      amounts and expiry. Tokens, the NFT flags, partialFill, the
    ///      counterparty and the maker are all fixed, so the id remains a
    ///      stable handle - an integrator holding it keeps a claim on the same
    ///      pair, the same permissions and the same owner. Changing any of
    ///      those is a different order and must be created as one.
    ///
    ///      Escrow moves by the difference only, and in the same directions the
    ///      rest of the contract already measures: growing pulls from the maker
    ///      and confirms exactly what arrived, shrinking returns through
    ///      _sendEscrowToken and confirms both ends. Fee-on-transfer and
    ///      no-op-transfer tokens are refused here exactly as they are at
    ///      creation, so a replace cannot leave an order undercollateralised.
    ///
    ///      Growing writes storage after the pull and shrinking writes it
    ///      before the return, mirroring _createOrder and _returnEscrow
    ///      respectively: at no point during an external call does the recorded
    ///      escrow exceed what the board actually holds for this order.
    ///
    ///      NFT orders are refused. Their amounts are tokenIds rather than
    ///      quantities, so there is no difference to move, and a "resize" would
    ///      silently mean a different token.
    ///
    ///      An expired order may still be replaced: it is the maker's own
    ///      escrow, and cancelOrder + createOrder would let them do it anyway.
    ///      Growing an order funded through createOrderWithEth pulls WETH, not
    ///      ETH: this entry point is deliberately not payable, since forwarding
    ///      one msg.value across a batch would let it be spent more than once,
    ///      the same reason multicall refuses value. Top such an order up in
    ///      WETH, or cancel and recreate it through the payable path.
    function replaceOrder(uint256 orderId, uint256 newAmountA, uint256 newAmountB, uint64 newExpiry)
        external
        nonReentrant
    {
        _replace(orderId, newAmountA, newAmountB, newExpiry);
    }

    /// @notice Reprice several orders in one transaction.
    /// @dev Atomic, like createOrders: one bad id aborts the batch. A quoting
    ///      maker reprices every rung it has resting at once, and a partially
    ///      applied ladder would leave some rungs on the old price and some on
    ///      the new - a book the maker never intended to show.
    function replaceOrders(ReplaceOrderParams[] calldata params) external nonReentrant {
        for (uint256 i; i < params.length; ++i) {
            _replace(params[i].orderId, params[i].amountA, params[i].amountB, params[i].expiry);
        }
    }

    function _replace(uint256 orderId, uint256 newAmountA, uint256 newAmountB, uint64 newExpiry)
        internal
    {
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

            _returnEscrow(order, maker, false);
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

            _returnEscrow(order, maker, false);
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

        _returnEscrow(order, maker, unwrap);
        emit OrderCanceled(orderId, maker);
    }

    /// @dev Closes an order and sends what is left of the escrow back to the
    /// maker. Shared by cancel and both sweeps: the three differ only in who may
    /// call them and how a stale id is treated, and the settlement itself must
    /// not drift apart between them. Storage is cleared before the transfer.
    ///
    /// A sweep that hits a transfer it cannot complete reverts rather than
    /// skipping. `swept[i] = false` means the entry was stale - already settled,
    /// not yet expired, never created - which is what a keeper's list goes
    /// stale with; a token that will not move is not a stale entry, and a batch
    /// that quietly closed such an order would discard the maker's claim.
    function _returnEscrow(Order storage order, address maker, bool unwrap) internal {
        address tokenA = order.tokenA;
        uint256 amountA = order.amountA;
        bool nftA = order.nftA;
        order.active = false;
        order.amountA = 0;
        order.amountB = 0;

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
