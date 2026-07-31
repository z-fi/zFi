// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {ERC20} from "../lib/solady/src/tokens/ERC20.sol";
import {SafeTransferLib} from "../lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "../lib/solady/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "../lib/solady/src/utils/ReentrancyGuardTransient.sol";

/// @title zPool
/// @notice SHELVED - not for deployment. Superseded by src/pools/PrecisionPool.
///
/// @dev    Kept for the evidence it produced rather than the code it is. This
///         was an attempt to provide passive liquidity as resting Swapboard
///         orders, and measuring it is what argued for a continuous curve
///         instead: a flat-priced rung is a free option whose cost scales with
///         how far a full take moves the pool's own price, which forces the
///         rung to stay narrower than the spread, which in turn caps depth per
///         repost and leaves keeper gas eating the edge. Those measurements are
///         in test/zPool.t.sol and are the reason PrecisionPool exists.
/// @notice A passive two-sided maker over Swapboard. Depositors pool a pair,
///         the pool rests one buy and one sell order around its own reserve
///         ratio, and the spread those orders earn accrues to the shares.
///
/// @dev WHY THE PRICE COMES FROM THE RESERVES AND NOT FROM ANYWHERE ELSE.
///      Every design that rests passive liquidity has to answer where its
///      price comes from, and every external answer is attackable: a quote
///      read from a pool at fill time can be depressed by the filler, taken,
///      and restored, which is exactly the hazard Dutchboard's schedule exists
///      to avoid. This contract has no external reference to move. Its price
///      is `reserveB / reserveA`, a ratio of balances it holds itself, so
///      manipulating it means trading against the pool at the pool's own
///      posted price - which is the thing the pool is for.
///
///      The ratio also supplies curvature for free. Selling A moves reserves
///      toward B, which raises the implied price, so the next ask is dearer.
///      A pool being drained on one side gets progressively less willing
///      without any explicit curve, bonding function, or rebalance logic.
///
///      WHAT THE FEE IS. There is no fee switch: the fee is the spread. The
///      ask rests at `r * (1 + fee)` and the bid at `r * (1 - fee)`, so a
///      round trip through the pool returns `2 * fee` of volume to reserves
///      and the share price rises. This is the AMM fee model expressed in
///      resting orders rather than in a curve.
///
///      RUNG SIZE IS THE RISK KNOB. Orders rest at a fixed price, so between
///      reposts the pool can be picked off on a genuine move - it is short a
///      free option for as long as an order rests. That exposure is bounded by
///      how much is resting, not by how long: `rungBps` caps each order at a
///      fraction of reserves, so the worst a stale price can cost is a fill of
///      that rung at a price the market has left behind. Small rung, safe and
///      shallow; large rung, deep and toxic. It is the same depth-versus-
///      adverse-selection trade an AMM makes, made explicit.
///
///      PARTIAL FILLS ARE LOAD-BEARING. One rung serves many takers without a
///      repost, which is what keeps the poke frequency (and its gas) low
///      enough for the spread to survive. It is also why this is built over
///      Swapboard rather than Dutchboard: the pool wants a fixed ask that
///      erodes as it is taken, not an ask that concedes on a clock.
///
///      REPOSTING IS PERMISSIONLESS AND PAID. Swapboard has no fill hook, so
///      nothing reposts the pool automatically, and an arbitrageur has every
///      reason to leave a stale price stale. `poke` therefore pays its caller
///      a share of the spread the fill actually earned - never a share of its
///      volume, which would hand the keeper a multiple of the pool's own
///      revenue - and reverts when nothing has filled and nothing has expired,
///      so it cannot be farmed by calling it in a loop.
///
///      Repricing normally goes through Swapboard's replaceOrder, which keeps
///      the order id and moves only the difference in escrow. Once per TTL the
///      pool deliberately recreates both sides under fresh ids: permanent old
///      ids eventually fall outside bounded newest-first book scans, so a small
///      periodic cost preserves discovery without paying it after every fill.
///
///      THE ORACLE, IF THERE IS ONE, MAY ONLY QUOTE AGAINST THE TAKER. The
///      reserve ratio has one weakness: the pool learns the price only by
///      being traded against, so it cannot step out of the way of a move it
///      has not yet been hit by. An optional oracle closes that, but it is
///      admitted under a strict asymmetry - it may raise the ask and lower the
///      bid, never the reverse:
///
///          ask = max(ratio, oracle) * (1 + fee)
///          bid = min(ratio, oracle) * (1 - fee)
///
///      So the pool never sells cheaper, nor buys dearer, than its own
///      reserves alone would have quoted. Whoever moves the feed can only make
///      the pool quote worse than it otherwise would: pushing it up raises an
///      ask they would have to pay, pushing it down lowers a bid they would
///      have to sell into, and pushing it to an extreme simply stops that side
///      quoting. Manipulation buys denial of service, never a better fill,
///      which is the property that makes an external price safe here when
///      reading one at fill time would not be.
///
///      It also lets the pool follow a real move rather than merely hide from
///      it: with the feed above the ratio the ask rests above the ratio too,
///      so a taker who lifts it pays more than the pool's own books asked and
///      the reserves - and with them the pool's price - catch up profitably.
///
///      A feed that reverts, is stale, or has no opinion returns zero and is
///      ignored, leaving exactly the reserve-ratio behaviour. That fallback is
///      the safe default precisely because it is the behaviour everything else
///      here is built and tested around.
///
///      SETTLEMENT RISK STAYS WITH THE BOARD. This contract never matches,
///      prices a taker, or holds a counterparty's funds. It escrows into
///      Swapboard and reads back what remains. Fee-on-transfer and no-op token
///      deposits are refused by this contract's balance-delta checks, and the
///      board repeats exact-delta checks on escrow entry and exit. Tokens that
///      rebase between transactions remain unsupported.
///
///      RESERVES ARE MEASURED, NOT TRACKED. `reserves` is idle balance plus
///      what the board still holds in escrow, read back from the board rather
///      than remembered, so a fill that happened since the last repost is
///      already reflected and share prices need no reconciliation. Filled
///      proceeds arrive here directly, since Swapboard pays tokenB to the
///      maker on fill. Only withdrawal retracts, because only withdrawal pays
///      out more than the idle balance can cover.
contract zPool is ERC20, ReentrancyGuardTransient {
    using SafeTransferLib for address;

    uint256 constant BPS = 10_000;
    uint256 constant WAD = 1e18;
    uint256 constant ORACLE_GAS = 50_000;

    /// @dev Burned on the first deposit so share price cannot be inflated by
    ///      donating to a one-wei supply.
    uint256 constant MIN_LIQUIDITY = 1000;

    address public immutable board;
    address public immutable tokenA;
    address public immutable tokenB;

    /// @dev Half-spread in bps. The round-trip edge is twice this.
    uint256 public immutable fee;

    /// @dev Fraction of reserves committed to each resting order, in bps.
    ///      Constrained to `<= fee`; see the constructor.
    uint256 public immutable rungBps;

    /// @dev Lifetime of a resting order. Bounds how long a stale price can
    ///      rest if nobody pokes; on expiry anyone may sweep the escrow back
    ///      here with Swapboard's trySweepExpired.
    uint64 public immutable orderTTL;

    /// @dev Optional price feed, address(0) for none. Constrained to quoting
    ///      against the taker only; see the contract header.
    address public immutable oracle;

    /// @dev Share of the REALISED SPREAD paid to whoever reposts, in bps. The
    ///      bounty on a fill is `filled * fee * bountyBps`, so it scales with
    ///      what the pool actually earned rather than with volume.
    uint256 public immutable bountyBps;

    /// @dev Live order ids. Swapboard numbers orders from zero, so the id is
    ///      not its own liveness flag; `postedAsk`/`postedBid` are, since both
    ///      are set on post and cleared on retract.
    uint256 public askId; // sells tokenA for tokenB
    uint256 public bidId; // sells tokenB for tokenA

    /// @dev What was escrowed at the last repost, so `poke` can tell how much
    ///      of each rung was taken since. Nonzero exactly while that side rests.
    uint256 public postedAsk;
    uint256 public postedBid;

    /// @dev Replacements retain their order ids, which is cheap but eventually
    ///      lets a busy board's bounded newest-first scans age the pool out.
    ///      Once per TTL both sides are therefore recreated under fresh ids.
    uint64 public rotationDeadline;

    error Bad();
    error NotStale();
    error Slippage();
    error BalanceMismatch(address token, uint256 expected, uint256 received);

    event Posted(uint256 askId, uint256 bidId, uint256 price);
    event Poked(address indexed caller, uint256 filledA, uint256 filledB);

    constructor(
        address board_,
        address tokenA_,
        address tokenB_,
        uint256 fee_,
        uint256 rungBps_,
        uint64 orderTTL_,
        uint256 bountyBps_,
        address oracle_
    ) {
        // A zero or 100% rung is not a configuration, and a fee at or above
        // BPS would price the bid at or below zero.
        if (
            board_ == address(0) || tokenA_ == tokenB_ || tokenA_ == address(0) || tokenB_ == address(0)
                || board_.code.length == 0 || tokenA_.code.length == 0 || tokenB_.code.length == 0
                || (oracle_ != address(0) && oracle_.code.length == 0)
        ) revert Bad();
        if (fee_ == 0 || fee_ >= BPS) revert Bad();
        // A one-sided fill changes both the numerator and denominator of the
        // reserve ratio, moving it by roughly 2*rungBps. The bid-to-ask band is
        // roughly 2*fee, so a rung wider than fee can jump clear through the
        // whole band and sell a price move for a fraction of what it is worth.
        // The loss grows faster than the rung: in
        // test/zPool.t.sol the same pool earns at rung 20bps and loses ~1750x
        // its stake-adjusted edge at rung 320bps against a 40bps spread. This
        // is the one parameter relationship that decides whether the design
        // makes money, so it is a constructor invariant rather than advice.
        if (rungBps_ == 0 || rungBps_ > fee_) revert Bad();
        if (orderTTL_ == 0 || bountyBps_ > BPS) revert Bad();
        (board, tokenA, tokenB) = (board_, tokenA_, tokenB_);
        (fee, rungBps, orderTTL, bountyBps) = (fee_, rungBps_, orderTTL_, bountyBps_);
        oracle = oracle_;
    }

    function name() public pure override returns (string memory) {
        return "zPool";
    }

    function symbol() public pure override returns (string memory) {
        return "zLP";
    }

    // ---------------------------------------------------------------- RESERVES

    /// @notice Total pool holdings: idle balance plus whatever is still
    ///         escrowed in the resting orders.
    /// @dev Escrow is read from the board rather than remembered, so a fill
    ///      that happened since the last post is reflected without a poke.
    function reserves() public view returns (uint256 rA, uint256 rB) {
        rA = tokenA.balanceOf(address(this)) + _escrowedAsk();
        rB = tokenB.balanceOf(address(this)) + _escrowedBid();
    }

    /// @notice Implied price of A in B, scaled by 1e18.
    function price() public view returns (uint256) {
        (uint256 rA, uint256 rB) = reserves();
        return _ratio(rA, rB);
    }

    function _escrowedAsk() internal view returns (uint256) {
        return postedAsk == 0 ? 0 : _escrowed(askId);
    }

    function _escrowedBid() internal view returns (uint256) {
        return postedBid == 0 ? 0 : _escrowed(bidId);
    }

    function _escrowed(uint256 id) internal view returns (uint256) {
        ISwapboard.Order memory o = _order(id);
        // A closed order holds nothing: fully filled and cancelled both zero
        // the escrow, and an expired-but-unswept one is still counted because
        // its escrow has not moved yet.
        return o.active ? o.amountA : 0;
    }

    function _order(uint256 id) internal view returns (ISwapboard.Order memory o) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        o = ISwapboard(board).getOrders(ids)[0];
    }

    // ------------------------------------------------------------- DEPOSIT

    /// @notice Deposit up to `maxA` and `maxB`, in the pool's current ratio.
    /// @dev The first deposit sets the ratio and therefore the initial price;
    ///      it should be seeded at a sane market rate, because arbitrage will
    ///      otherwise correct it at the depositor's expense.
    function deposit(uint256 maxA, uint256 maxB, uint256 minShares, address to)
        external
        nonReentrant
        returns (uint256 shares, uint256 usedA, uint256 usedB)
    {
        // No retract: `reserves` counts escrow, so shares price correctly
        // against the resting position and the rungs simply grow afterwards.
        uint256 supply = totalSupply();
        if (supply == 0) {
            (usedA, usedB) = (maxA, maxB);
            shares = _sqrtProduct(usedA, usedB);
            if (shares <= MIN_LIQUIDITY) revert Bad();
            shares -= MIN_LIQUIDITY;
            _mint(address(0xdead), MIN_LIQUIDITY);
        } else {
            (uint256 rA, uint256 rB) = reserves();
            if (rA == 0 || rB == 0) revert Bad();
            // Take the side that binds, then charge the other in proportion,
            // rounding up so a deposit never dilutes the existing holders.
            shares = FixedPointMathLib.min(
                FixedPointMathLib.fullMulDiv(maxA, supply, rA), FixedPointMathLib.fullMulDiv(maxB, supply, rB)
            );
            if (shares == 0) revert Bad();
            usedA = FixedPointMathLib.fullMulDivUp(shares, rA, supply);
            usedB = FixedPointMathLib.fullMulDivUp(shares, rB, supply);
        }

        if (shares < minShares) revert Slippage();
        _pullExact(tokenA, usedA);
        _pullExact(tokenB, usedB);
        _mint(to, shares);

        _reprice();
    }

    /// @notice Burn `shares` and take the matching slice of both reserves.
    function withdraw(uint256 shares, uint256 minA, uint256 minB, address to)
        external
        nonReentrant
        returns (uint256 outA, uint256 outB)
    {
        // Retract first, unlike deposit: a withdrawal can be the whole
        // position and is paid from idle balance, so the escrow has to come
        // home before it can be shared out.
        _retract();

        uint256 supply = totalSupply();
        (uint256 rA, uint256 rB) = reserves();
        // Rounds down, leaving any dust to the remaining holders.
        outA = FixedPointMathLib.fullMulDiv(shares, rA, supply);
        outB = FixedPointMathLib.fullMulDiv(shares, rB, supply);
        if (outA < minA || outB < minB) revert Slippage();

        _burn(msg.sender, shares);
        if (outA != 0) tokenA.safeTransfer(to, outA);
        if (outB != 0) tokenB.safeTransfer(to, outB);

        _reprice();
    }

    // ----------------------------------------------------------------- POKE

    /// @notice Reprice both rungs against current reserves.
    /// @dev Permissionless, and pays `bountyBps` of what was actually filled
    ///      since the last post. Refused when nothing has filled and nothing
    ///      has expired: repricing an untouched pool would return the same
    ///      numbers, so a bounty for it would be a pure withdrawal.
    function poke() external nonReentrant returns (uint256 filledA, uint256 filledB) {
        ISwapboard.Order memory ask = postedAsk == 0 ? _emptyOrder() : _order(askId);
        ISwapboard.Order memory bid = postedBid == 0 ? _emptyOrder() : _order(bidId);
        bool staleAsk;
        bool staleBid;
        (filledA, staleAsk) = _fillState(ask, postedAsk);
        (filledB, staleBid) = _fillState(bid, postedBid);
        bool rotate = _rotationDue();
        if (!staleAsk && !staleBid && !rotate) revert NotStale();

        // Paid out of the pool's realised edge, not out of principal. The
        // bounty is a share of the SPREAD the fill earned, never a share of
        // the volume: a rung only earns `fee` on what it sells, so a bounty
        // quoted against volume would pay the keeper a multiple of the pool's
        // own revenue and every extra fill would make holders poorer.
        uint256 payA = _bounty(filledA);
        uint256 payB = _bounty(filledB);
        if (payA != 0) tokenA.safeTransfer(msg.sender, payA);
        if (payB != 0) tokenB.safeTransfer(msg.sender, payB);

        // No retract first: `reserves` already counts escrow, so the new rungs
        // can be sized against the true position and each side adjusted by its
        // difference. Cancelling only to recreate would move the whole escrow
        // twice for nothing.
        _reprice(rotate);
        emit Poked(msg.sender, filledA, filledB);
    }

    /// @dev A live remainder tells us exactly what filled. A closed order is
    ///      unambiguous only through its expiry boundary: Swapboard cannot sweep
    ///      it at or before expiry, so closure there proves a full fill. After
    ///      expiry it may instead have been swept, and returned principal must
    ///      never be rewarded as volume; a late full fill simply forfeits its
    ///      bounty in favour of that safety.
    function _fillState(ISwapboard.Order memory o, uint256 posted) internal view returns (uint256 filled, bool stale) {
        if (posted == 0) return (0, true);
        if (o.active) {
            filled = posted - FixedPointMathLib.min(o.amountA, posted);
            stale = filled != 0 || _expired(o.expiry);
        } else {
            stale = true;
            if (o.maker == address(this) && o.expiry != 0 && block.timestamp <= o.expiry) filled = posted;
        }
    }

    function _bounty(uint256 filled) internal view returns (uint256) {
        uint256 spread = FixedPointMathLib.fullMulDiv(filled, fee, BPS);
        return FixedPointMathLib.fullMulDiv(spread, bountyBps, BPS);
    }

    function _rotationDue() internal view returns (bool) {
        uint64 deadline = rotationDeadline;
        return deadline != 0 && block.timestamp >= deadline;
    }

    function _expired(uint64 expiry) internal view returns (bool) {
        return expiry != 0 && block.timestamp > expiry;
    }

    function _emptyOrder() internal pure returns (ISwapboard.Order memory o) {
        return o;
    }

    // ---------------------------------------------------------- POST/RETRACT

    /// @dev Cancels whatever is still resting so reserves become fully idle
    ///      and measurable. An order that already closed - filled out, or
    ///      expired and swept - is skipped rather than cancelled.
    function _retract() internal {
        if (postedAsk != 0) _cancelIfLive(askId);
        if (postedBid != 0) _cancelIfLive(bidId);
        (postedAsk, postedBid) = (0, 0);
        rotationDeadline = 0;
    }

    function _cancelIfLive(uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        if (ISwapboard(board).getOrders(ids)[0].active) ISwapboard(board).cancelOrder(id);
    }

    /// @dev Brings both rungs to the current implied price, replacing them in
    ///      place where one already rests and creating one where it does not.
    ///      At rotationDeadline, both ids are deliberately refreshed.
    ///      A side with no reserve, or a rung that rounds to nothing, is left
    ///      unposted and any live rung there is withdrawn; the pool goes inert
    ///      rather than reverting, so a lopsided pool can still be exited.
    function _reprice() internal {
        _reprice(_rotationDue());
    }

    function _reprice(bool rotate) internal {
        (uint256 rA, uint256 rB) = reserves();
        if (rA == 0 || rB == 0) {
            _retract();
            return;
        }

        uint256 p = _ratio(rA, rB);
        if (p == 0) {
            _retract();
            return;
        }
        uint64 expiry = _newExpiry();

        (uint256 askPx, uint256 bidPx) = quotes(p);

        // Ask: give a rung of A, want it valued at the spread above mid.
        uint256 sizeA = FixedPointMathLib.fullMulDiv(rA, rungBps, BPS);
        uint256 wantB = _mulDivUpOrZero(sizeA, askPx, WAD);
        _sync(true, sizeA, wantB, expiry, rotate);

        // Bid: give a rung of B, want A valued at the spread below mid. Both
        // legs round the pool's ask up, so rounding never pays the taker.
        uint256 sizeB = FixedPointMathLib.fullMulDiv(rB, rungBps, BPS);
        uint256 wantA = _mulDivUpOrZero(sizeB, WAD, bidPx);
        _sync(false, sizeB, wantA, expiry, rotate);

        if (rotationDeadline == 0 || rotate) {
            rotationDeadline = postedAsk == 0 && postedBid == 0 ? 0 : expiry;
        }

        emit Posted(askId, bidId, p);
    }

    /// @notice The two prices the pool is willing to trade at, given a mid.
    /// @dev The oracle may only move each leg away from the mid. Both
    ///      comparisons are one-directional by construction, so no feed value
    ///      - honest, stale or hostile - can produce a quote better for the
    ///      taker than the reserve ratio alone would have.
    function quotes(uint256 mid) public view returns (uint256 askPx, uint256 bidPx) {
        uint256 o = _feed();
        uint256 askBase = o > mid ? o : mid;
        uint256 bidBase = o == 0 || mid < o ? mid : o;
        askPx = _scaledAskOrZero(askBase);
        bidPx = FixedPointMathLib.fullMulDiv(bidBase, BPS - fee, BPS);
    }

    /// @dev Zero means no opinion, which is also what a feed that reverts,
    ///      exceeds its gas stipend, or returns a non-canonical word resolves
    ///      to. The pool then quotes off reserves alone, so a broken oracle
    ///      degrades to the unguarded design rather than halting it.
    function _feed() internal view returns (uint256) {
        if (oracle == address(0)) return 0;
        address target = oracle;
        bytes4 selector = IZPoolOracle.peek.selector;
        bool ok;
        uint256 p;
        uint256 gasLimit = ORACLE_GAS;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            ok := staticcall(gasLimit, target, m, 0x04, m, 0x20)
            ok := and(ok, eq(returndatasize(), 0x20))
            p := mload(m)
        }
        return ok ? p : 0;
    }

    /// @dev Brings one side to `give`/`want`. Replacing keeps the order id, so
    ///      only the difference in escrow moves; a rung that was fully filled,
    ///      swept or never posted is created fresh.
    ///
    ///      Growing is always affordable: a rung is a fraction of reserves and
    ///      reserves are idle plus escrow, so the extra needed can never exceed
    ///      what is sitting idle.
    function _sync(bool isAsk, uint256 give, uint256 want, uint64 expiry, bool rotate) internal {
        uint256 id = isAsk ? askId : bidId;
        uint256 resting = isAsk ? _escrowedAsk() : _escrowedBid();
        address giveToken = isAsk ? tokenA : tokenB;

        if (rotate && resting != 0) {
            _cancelIfLive(id);
            resting = 0;
        }

        // Nothing postable on this side: withdraw whatever is still out there
        // rather than leaving a rung priced off a position that no longer
        // supports it.
        if (give == 0 || want == 0) {
            if (resting != 0) _cancelIfLive(id);
            if (isAsk) postedAsk = 0;
            else postedBid = 0;
            return;
        }

        if (resting != 0) {
            if (give > resting) giveToken.safeApproveWithRetry(board, give - resting);
            ISwapboard(board).replaceOrder(id, give, want, expiry);
            if (give > resting) giveToken.safeApproveWithRetry(board, 0);
        } else {
            uint256 fresh = _create(giveToken, give, isAsk ? tokenB : tokenA, want);
            if (isAsk) askId = fresh;
            else bidId = fresh;
        }

        if (isAsk) postedAsk = give;
        else postedBid = give;
    }

    /// @dev Exact, call-scoped approval. The board pulls the escrow inside
    ///      createOrder and nothing is left standing afterwards.
    function _create(address give, uint256 giveAmt, address want, uint256 wantAmt) internal returns (uint256 id) {
        give.safeApproveWithRetry(board, giveAmt);
        id = ISwapboard(board)
            .createOrder(
                give,
                giveAmt,
                want,
                wantAmt,
                true, // partialFill: one rung serves many takers
                _newExpiry(),
                false,
                false,
                address(0) // public: the cascade has to be able to route into it
            );
        give.safeApproveWithRetry(board, 0);
    }

    /// @dev Saturates an unrepresentable reserve ratio. At that boundary the
    ///      ask is disabled and the bid remains representable, so a pathological
    ///      balance cannot turn a withdrawal or repost into an arithmetic lock.
    function _ratio(uint256 rA, uint256 rB) internal pure returns (uint256) {
        if (rA == 0 || rB == 0) return 0;
        if (rA < WAD && rB > FixedPointMathLib.fullMulDiv(type(uint256).max, rA, WAD)) {
            return type(uint256).max;
        }
        return FixedPointMathLib.fullMulDiv(rB, WAD, rA);
    }

    function _scaledAskOrZero(uint256 base) internal view returns (uint256) {
        uint256 scale = BPS + fee;
        uint256 maxBase = FixedPointMathLib.fullMulDiv(type(uint256).max, BPS, scale);
        if (base > maxBase) return 0;
        return FixedPointMathLib.fullMulDiv(base, scale, BPS);
    }

    /// @dev Returns zero when ceil(x*y/d) cannot fit. Zero is the existing
    ///      "do not post this side" sentinel used by _sync.
    function _mulDivUpOrZero(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        if (x == 0 || y == 0 || d == 0) return 0;
        if (x > d && y > d) {
            uint256 maxY = FixedPointMathLib.fullMulDiv(type(uint256).max, d, x);
            if (y > maxY) return 0;
        }
        return FixedPointMathLib.fullMulDivUp(x, y, d);
    }

    function _newExpiry() internal view returns (uint64) {
        uint256 expiry = block.timestamp + uint256(orderTTL);
        return expiry > type(uint64).max ? type(uint64).max : uint64(expiry);
    }

    function _pullExact(address token, uint256 amount) internal {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 received = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        if (received != amount) revert BalanceMismatch(token, amount, received);
    }

    /// @dev floor(sqrt(x*y)) without forming the 512-bit product in one word.
    ///      Integer square roots give a cheap upper bound; Newton steps descend
    ///      from it to the exact floor.
    function _sqrtProduct(uint256 x, uint256 y) internal pure returns (uint256 z) {
        if (x == 0 || y == 0) return 0;
        uint256 sx = FixedPointMathLib.sqrt(x);
        uint256 sy = FixedPointMathLib.sqrt(y);
        uint256 seed = sx * sy;
        // x < (sx+1)^2 and y < (sy+1)^2, so this is an upper
        // bound for sqrt(x*y). Saturation handles max*max exactly.
        z = FixedPointMathLib.saturatingAdd(seed, sx + sy + 1);
        while (true) {
            uint256 q = FixedPointMathLib.fullMulDiv(x, y, z);
            uint256 next = (z & q) + ((z ^ q) >> 1);
            if (next >= z) return z;
            z = next;
        }
    }
}

/// @notice Optional price source for zPool.
/// @dev `peek` returns tokenB per tokenA scaled by 1e18, or zero for "no
///      opinion". It must not revert on staleness - returning zero is how a
///      feed declines - though zPool tolerates a revert as the same answer.
interface IZPoolOracle {
    function peek() external view returns (uint256);
}

interface ISwapboard {
    struct Order {
        address maker;
        bool active;
        bool partialFill;
        uint64 expiry;
        bool nftA;
        bool nftB;
        address counterparty;
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
    }

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
    ) external returns (uint256 orderId);

    function replaceOrder(uint256 orderId, uint256 newAmountA, uint256 newAmountB, uint64 newExpiry) external;

    function cancelOrder(uint256 orderId) external;

    function getOrders(uint256[] calldata orderIds) external view returns (Order[] memory);
}
