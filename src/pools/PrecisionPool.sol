// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {PriceTape, IPriceTape} from "./PriceTape.sol";
import {ERC20} from "../../lib/solady/src/tokens/ERC20.sol";
import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";

/// @title IPrecisionHook
/// @notice Hook interface for a bounded fee surcharge and post-swap callback.
/// @dev The pool caps the fee and does not revert on callback failure.
///
///      DO NOT BUILD A CONTROLLER THAT DEPENDS ON `afterSwap` FOR ACCOUNTING.
///      `feeFor` is `view`, so a hook whose rate depends on accumulated history
///      has to write that history in `afterSwap` — and `afterSwap` is
///      best-effort: it runs under `HOOK_GAS` and the pool swallows its failure
///      (`if (!ok) emit HookCallFailed(h)`). A caller can therefore starve the
///      callback while the swap itself still succeeds, freezing the hook's
///      counters. Any rate derived from them then drifts in the attacker's
///      favour, which is worst for exactly the flow-responsive designs that
///      want history in the first place — dynamic fees, inventory targeting,
///      anything VRGDA-shaped.
///
///      Derive the rate from state the POOL owns and `feeFor` can read
///      directly — reserves, LP supply, the price tape — rather than from a
///      private counter. Reserves in particular already ARE the inventory
///      signal an inventory-targeting hook wants, and no callback can starve
///      them. Treat `afterSwap` as notification, never as bookkeeping.
interface IPrecisionHook {
    /// @notice Additional fee in pips, on top of the pool's base fee.
    /// @dev This is `view` so the lens can reproduce the swap's fee.
    function feeFor(address sender, address tokenIn, uint256 amountIn) external view returns (uint256 extraFee);

    function afterSwap(address sender, address tokenIn, uint256 amountIn, uint256 amountOut, address to) external;
}

/// @title PrecisionPool
/// @notice Concentrated constant-product pool for one pair and fixed price
///         range, with ERC-20 LP shares.
/// @dev Real reserves are combined with virtual reserves derived from LP
///      supply. Bounds are raw token1/token0 prices, represented as square
///      roots scaled by 1e18; token decimals must already be reflected in them.
///      The first deposit supplies an initial price; later deposits are
///      proportional and unused amounts are refunded. Boundary seeds are
///      supported. Swaps that leave the range are rejected.
///
///      FEES STAY IN THE RESERVES, SO THE CURVE IS NOT EXACT. Output is priced
///      on the input net of fees, but the reserves keep the LP portion of that
///      fee. The effective product therefore grows above L-squared over time
///      while the virtual offsets, derived from an unchanged LP supply, do not
///      follow it. Two consequences integrators must model rather than assume
///      away:
///
///        - `totalSupply` is the liquidity the offsets are built from, NOT
///          sqrt(XY) of the live reserves, and the two diverge with volume;
///        - a position reaching a range boundary is not guaranteed to have
///          converted entirely into one asset. It may sit at the bound still
///          holding some of the other side - that residue is retained fees and
///          belongs to the LPs.
///
///      This is auto-compounding growing-K behaviour, deliberately: fees
///      accrue to share value with no separate accumulator and no harvest
///      call. Quoters and any limit-order-style integration should compute
///      terminal inventory from the reserves rather than from the idealised
///      curve. See test_RetainedFeesOvercollateraliseWithoutBreakingTheBand.
contract PrecisionPool is ERC20, IPriceTape {
    using SafeTransferLib for address;

    uint256 constant WAD = 1e18;
    /// @dev Fee denominator; fees are expressed in pips.
    uint256 constant FEE_DENOM = 1_000_000;

    /// @dev Sent to the dead address on the initial mint to prevent share-price
    ///      inflation against a tiny supply.
    uint256 constant MIN_LIQUIDITY = 1000;

    /// @dev Maximum creator share of the base fee (50%).
    uint256 constant MAX_CREATOR_SHARE = 5_000;
    uint256 constant BPS = 10_000; // basis points

    /// @dev Minimum virtual reserve on each side of a newly seeded pool.
    ///      Both virtual reserves are floored functions of supply, so a pool
    ///      seeded with only a handful of raw units on one side has no
    ///      resolution to represent its own price. Withdrawals floor too, and
    ///      on such a pool they retain the thin side disproportionately: the
    ///      price then drifts genuinely - not as a rounding artifact - until it
    ///      leaves the band for good, because a proportional deposit preserves
    ///      the ratio and a swap cannot re-enter the band in one step from an
    ///      emptied reserve. Requiring real resolution at creation keeps pools
    ///      out of that regime, and a seed is the only moment the pool can
    ///      refuse without stranding anyone.
    uint256 constant MIN_RESOLUTION = 1e6;

    /// @dev Maximum combined base fee and hook surcharge (10%).
    ///
    ///      THIS BOUNDS THE RATE, NOT THE PROPORTION ANY SINGLE TRADE PAYS.
    ///      Both fees are taken as the difference from a floored remainder,
    ///      which rounds the charge UP - deliberately, because flooring the fee
    ///      lets a trade split finely enough pay nothing at all. The cost is
    ///      that a trade of a few raw units pays a whole unit: two raw units at
    ///      a nominal 1 pip pay one unit, an effective 50%, and a hook
    ///      surcharge on top of that can reach two thirds. The absolute
    ///      overcharge is bounded by one raw unit of the input token per fee
    ///      class per swap and is negligible at any size worth trading, but a
    ///      frontend quoting only the nominal pip rate will misstate it. Quote
    ///      the fee from `extraFee` and this rate rather than assuming the
    ///      nominal proportion holds at raw-unit sizes.
    uint256 constant MAX_TOTAL_FEE = 100_000;

    /// @dev Reciprocal of the tolerance allowed between the requested seed
    ///      price and the price the pool actually opens at (100 = 1%).
    uint256 constant SEED_PRICE_TOLERANCE = 100;

    /// @dev Upper bound for WAD-scaled square-root prices. Together with the
    ///      liquidity cap, it keeps virtual-reserve arithmetic bounded.
    uint256 constant MAX_SQRT_PRICE = 1e36;

    /// @dev LP supply is the curve liquidity; the cap keeps virtual reserves
    ///      within uint256 arithmetic.
    uint256 constant MAX_LIQUIDITY = type(uint128).max;

    /// @dev Gas limit for each hook callback.
    uint256 constant HOOK_GAS = 150_000;

    /// @dev Price-history resolution. The fine tape is written by trades; the
    ///      coarse tape is folded from finished fine bars, so a swap pays for
    ///      one live bar regardless of how many timeframes are kept. Every
    ///      other timeframe a chart wants is an exact client-side aggregation.
    uint256 public constant FINE_PERIOD = 5 minutes;
    uint256 public constant COARSE_PERIOD = 4 hours;
    /// @dev ~21 hours of five-minute bars and ~42 days of four-hour bars.
    ///      Both rings are `PriceTape.BARS` deep; the depth is fixed in the
    ///      library so the index is a mask rather than a length read.
    uint256 constant FINE_BARS = PriceTape.BARS;
    uint256 constant COARSE_BARS = PriceTape.BARS;

    /// @dev Transient slot used by the reentrancy guard.
    uint256 constant _REENTRANCY_SLOT = 0xab143c06;

    /// @notice Canonical token pair; address(0) represents native ETH.
    address public immutable token0;
    address public immutable token1;
    /// @notice The only contract permitted to settle a prefunded factory route.
    /// @dev Direct callers use `swapExactIn` and `addLiquidityExact`, which
    ///      pull their assets in the same call. Keeping the balance-delta
    ///      settlement private to the factory prevents a later caller from
    ///      claiming assets somebody else transferred in an earlier transaction.
    address public immutable factory;
    /// @notice Lower bound of the raw token1/token0 price range, sqrt-scaled by 1e18.
    uint256 public immutable sqrtPLow;
    /// @notice Upper bound of the raw token1/token0 price range, sqrt-scaled by 1e18.
    uint256 public immutable sqrtPHigh;
    /// @notice Base swap fee in pips.
    uint256 public immutable fee;

    /// @notice Bounded surcharge provider and post-swap observer; zero if none.
    address public immutable hook;

    /// @notice Recipient of the creator fee share and hook configuration.
    ///         Address(0) means no recipient is configured.
    address public immutable feeRecipient;

    /// @notice Creator's share of the base fee, in basis points.
    uint256 public immutable creatorFeeBps;

    uint128 public reserve0;
    uint128 public reserve1;

    /// @notice Hook fees earned but not yet collected.
    /// @dev Accrued fees are excluded from balances available to LPs and swaps.
    uint256 public hookOwed0;
    uint256 public hookOwed1;

    /// @notice Creator fees earned but not yet collected.
    uint256 public creatorOwed0;
    uint256 public creatorOwed1;

    /// @dev Fine and coarse price history. Two tapes, not five: coarse candles
    ///      are exact aggregations of fine ones and are rolled up by the client,
    ///      so a trade only ever writes the fine tape's single live bar.
    ///      FINE_PERIOD * FINE_BARS of history at five-minute resolution, and
    ///      COARSE_PERIOD * COARSE_BARS at four-hour, per pool.
    PriceTape.Tape private _fine;
    PriceTape.Tape private _coarse;

    error Bad();
    error NotHook();
    error Overflow();
    error NotFactory();
    error Reentrancy();
    error ZeroAmount();
    error InvalidToken();
    error BalanceDeficit();
    error NotFeeRecipient();
    error PriceOutOfRange();
    error UnsupportedToken();
    error InsufficientOutput();
    error InsufficientLiquidity();

    event Swap(address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to);
    event HookFee(address indexed tokenIn, uint256 amount, uint256 extraFee);
    event HookFeeCollected(address indexed to, uint256 amount0, uint256 amount1);
    event CreatorFeeCollected(address indexed to, uint256 amount0, uint256 amount1);
    /// @dev Emitted when the post-swap callback fails.
    event HookCallFailed(address indexed hook);
    /// @dev The indexed address is the LP share recipient, which need not be
    ///      the payer or the refund recipient.
    event AddLiquidity(address indexed recipient, uint256 amount0, uint256 amount1, uint256 lp);
    event RemoveLiquidity(address indexed provider, uint256 lp, uint256 amount0, uint256 amount1);

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(_REENTRANCY_SLOT) {
                mstore(0x00, 0xab143c06)
                revert(0x1c, 0x04)
            }
            tstore(_REENTRANCY_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(_REENTRANCY_SLOT, 0)
        }
    }

    /// @dev Repeats the factory's dependency and arithmetic checks for direct
    ///      deployments.
    constructor(
        address factory_,
        address token0_,
        address token1_,
        uint256 sqrtPLow_,
        uint256 sqrtPHigh_,
        uint256 fee_,
        address hook_,
        address feeRecipient_,
        uint256 creatorFeeBps_
    ) {
        if (factory_.code.length == 0) revert Bad();
        if (token0_ >= token1_) revert Bad();
        if (token1_.code.length == 0 || (token0_ != address(0) && token0_.code.length == 0)) revert Bad();
        if (hook_ != address(0) && hook_.code.length == 0) revert Bad();
        if (sqrtPLow_ == 0 || sqrtPHigh_ <= sqrtPLow_ || sqrtPHigh_ > MAX_SQRT_PRICE) revert Bad();
        // Reserve room for the hook surcharge.
        if (fee_ >= MAX_TOTAL_FEE) revert Bad();
        (factory, token0, token1, sqrtPLow, sqrtPHigh, fee) = (factory_, token0_, token1_, sqrtPLow_, sqrtPHigh_, fee_);
        hook = hook_;
        // A nonzero creator share requires a recipient. A recipient without a
        // share is allowed so a surcharge hook can identify its controller.
        if (creatorFeeBps_ > MAX_CREATOR_SHARE) revert Bad();
        if (creatorFeeBps_ != 0 && feeRecipient_ == address(0)) revert Bad();
        (feeRecipient, creatorFeeBps) = (feeRecipient_, creatorFeeBps_);
    }

    /// @dev Native input is accepted only by an exact-input entry point. A
    ///      naked transfer would otherwise become anonymous balance surplus.
    ///
    ///      The constructor is deliberately NOT payable for the same reason. A
    ///      payable one lets a deployment endow the pool with ETH before any
    ///      entry point exists to credit it through, and the no-sweep policy
    ///      below then strands it for good. The factory always deploys with
    ///      zero value, but the factory is not a chokepoint: this constructor is
    ///      public, direct deployment is a supported path (see its own note),
    ///      and a pool with no `feeRecipient` can be seeded without the factory
    ///      ever being involved. So the guarantee has to hold here, not upstream.
    ///
    ///      Payable is the cheaper of the two, and by almost nothing: measured
    ///      A/B, it saves 15 gas and 5 bytes of creation code against the
    ///      3,883,913 a `createPool` costs - 0.0004%, once, at deployment.
    ///      Constructor code is never part of the runtime, so no swap and no
    ///      deposit pays the difference either way. Recorded because that
    ///      number is the whole argument for the other choice, and the next
    ///      person to weigh it should not have to measure it again.
    ///
    ///      Closing this does NOT make the balance unforgeable: `selfdestruct`
    ///      and block rewards reach a contract without calling it, so a
    ///      native-token0 pool can still hold ETH no entry point ever credited.
    ///      That surplus is stranded rather than stealable, and deliberately so
    ///      - every entry point ties the amount it credits to `msg.value` or to
    ///      a pull it performed itself, never to the balance it happens to find,
    ///      so nobody can claim it by declaring it. The alternative, a sweep,
    ///      would be a permission to move funds out of an otherwise
    ///      permissionless immutable contract, which is a strictly worse thing
    ///      to hold than the dust it recovers.
    receive() external payable {
        revert Bad();
    }

    /// @notice Current sqrt price in raw token1/token0, scaled by 1e18.
    /// @dev Derived from the pool's virtual and real reserves.
    function sqrtPriceCurrent() public view returns (uint256) {
        return _sqrtPrice(totalSupply(), reserve0, reserve1);
    }

    function _sqrtPrice(uint256 supply, uint256 r0, uint256 r1) internal view returns (uint256) {
        if (supply == 0) return 0;
        uint256 vX = _virtual0(supply, sqrtPHigh) + r0;
        if (vX == 0) return 0;
        return FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(_virtual1(supply, sqrtPLow) + r1, WAD * WAD, vX));
    }

    /// @dev Checks the price ratio directly, avoiding a square-root operation.
    function _priceInRange(uint256 vX, uint256 vY) internal view returns (bool) {
        if (vX == 0) return false;
        uint256 ratio = FixedPointMathLib.fullMulDiv(vY, WAD * WAD, vX);
        uint256 lo = sqrtPLow;
        uint256 hiExclusive = sqrtPHigh + 1;
        unchecked {
            return ratio >= lo * lo && ratio < hiExclusive * hiExclusive;
        }
    }

    /// @dev Squared price as the range check sees it. Zero X reads as zero so
    ///      an empty side compares as far below the floor rather than reverting.
    function _ratio(uint256 vX, uint256 vY) internal pure returns (uint256) {
        if (vX == 0) return 0;
        return FixedPointMathLib.fullMulDiv(vY, WAD * WAD, vX);
    }

    /// @dev How far a squared price sits outside the band; zero when inside.
    ///      Used to let a deposit into an out-of-band pool through only when it
    ///      does not make the excursion worse.
    function _bandMiss(uint256 ratio) internal view returns (uint256) {
        uint256 lo = sqrtPLow;
        uint256 hiExclusive = sqrtPHigh + 1;
        unchecked {
            uint256 floorSq = lo * lo;
            uint256 ceilSq = hiExclusive * hiExclusive;
            if (ratio < floorSq) return floorSq - ratio;
            if (ratio >= ceilSq) return ratio - ceilSq + 1;
            return 0;
        }
    }

    /// @dev True when at least one direction admits a swap that would actually
    ///      succeed. This mirrors `_swapExact` rather than approximating it:
    ///      the smallest gross input that survives fee rounding, the real
    ///      output formula, a strictly positive output within the real reserve,
    ///      and the post-swap range check. A one-unit fee-free quote is not
    ///      equivalent - it treats a zero output as executable, and it ignores
    ///      that the retained input includes the LP fee and so moves the price
    ///      further than the priced amount does.
    /// @dev Fees are taken at the worst case a future trade could see, so a
    ///      hooked pool must be executable even under the maximum surcharge the
    ///      hook is ever allowed to return.
    function _tradeable(uint256 x, uint256 y, uint256 r0, uint256 r1) internal view returns (bool) {
        // The hook's surcharge is taken FIRST and the base fee applies to what
        // is left, so the two cannot be collapsed into one aggregate rate: the
        // real transition floors twice, and a single combined rate floors once.
        uint256 surcharge = hook != address(0) ? MAX_TOTAL_FEE - fee : 0;
        if (r1 != 0 && _executable(x, y, r0, r1, surcharge, true)) return true;
        if (r0 != 0 && _executable(y, x, r1, r0, surcharge, false)) return true;
        return false;
    }

    /// @param augIn Augmented reserve on the input side, `augOut` on the output.
    /// @param surcharge Worst-case hook surcharge in pips; zero without a hook.
    /// @param zeroForOne Which way round to reassemble the post-swap pair.
    /// @dev Reproduces `_swapExact` exactly on the smallest input that can
    ///      clear it: surcharge, then base fee, then creator cut, each with the
    ///      same rounding, and the same reserve-room and range tests against
    ///      the same quantities the swap uses.
    function _executable(
        uint256 augIn,
        uint256 augOut,
        uint256 rIn,
        uint256 rOut,
        uint256 surcharge,
        bool zeroForOne
    ) internal view returns (bool) {
        if (augOut <= 1) return false;
        // Smallest priced amount that does not round its output to zero:
        // floor(a * augOut / (augIn + a)) >= 1  <=>  a * (augOut - 1) >= augIn.
        // Testing a one-unit input instead would reject pools whose smallest
        // executable trade is simply larger than one unit.
        uint256 need = FixedPointMathLib.divUp(augIn, augOut - 1);
        if (need == 0) need = 1;
        if (need > type(uint128).max) return false;
        // Invert the two floors in the order the swap applies them: the base
        // fee acts on `net`, and the surcharge acts on the gross input that
        // produces that `net`.
        uint256 netMin = FixedPointMathLib.fullMulDivUp(need, FEE_DENOM, FEE_DENOM - fee);
        if (netMin > type(uint128).max) return false;
        uint256 gross = FixedPointMathLib.fullMulDivUp(netMin, FEE_DENOM, FEE_DENOM - surcharge);
        if (gross > type(uint128).max) return false;

        // Now replay the transition forward on that input, with the nested
        // floors the swap actually performs rather than a single combined one.
        uint256 net = FixedPointMathLib.fullMulDiv(gross, FEE_DENOM - surcharge, FEE_DENOM);
        uint256 priced = FixedPointMathLib.fullMulDiv(net, FEE_DENOM - fee, FEE_DENOM);
        if (priced == 0) return false;
        uint256 creatorCut;
        uint256 creatorBps = creatorFeeBps;
        if (creatorBps != 0) {
            creatorCut = FixedPointMathLib.fullMulDivUp(net - priced, creatorBps, BPS);
        }
        // Only what stays in the reserves is checked for room, and only what
        // stays in them moves the price - the hook and creator cuts do neither.
        uint256 kept = net - creatorCut;
        if (kept > type(uint128).max - rIn) return false;

        uint256 out = FixedPointMathLib.fullMulDiv(priced, augOut, augIn + priced);
        if (out == 0 || out > rOut) return false;

        unchecked {
            return zeroForOne
                ? _priceInRange(augIn + kept, augOut - out)
                : _priceInRange(augOut - out, augIn + kept);
        }
    }

    function _virtual0(uint256 liquidity, uint256 hi) internal pure returns (uint256) {
        // The factory caps liquidity and the price range so this product fits.
        unchecked {
            return liquidity * WAD / hi;
        }
    }

    function _virtual1(uint256 liquidity, uint256 lo) internal pure returns (uint256) {
        // The factory caps liquidity and the price range so this product fits.
        unchecked {
            return liquidity * lo / WAD;
        }
    }

    // -------------------------------------------------------------------- SWAP

    /// @notice Pull exactly `amountIn` from the caller and settle the swap.
    /// @dev Pulls and settles the input in the same transaction.
    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        bool zeroForOne = _direction(tokenIn);
        if (amountIn == 0) revert ZeroAmount();
        if (zeroForOne && token0 == address(0)) {
            if (msg.value != amountIn) revert Bad();
        } else {
            if (msg.value != 0) revert Bad();
            _pullExact(tokenIn, msg.sender, amountIn);
        }
        (amountOut,) = _swapExact(msg.sender, tokenIn, zeroForOne, amountIn, minOut, to, false, address(0));
    }

    /// @notice Swap AT MOST `amountIn`, filling to the band's edge and
    ///         returning the remainder to the caller.
    /// @dev The routing counterpart to `swapExactIn`. A band refuses a trade
    ///      that would leave its range rather than clamping, which makes a
    ///      quote that was correct at block N a revert at block N+2 and gives
    ///      an aggregator nothing to route around. This entry point fills what
    ///      the band can take and hands back the rest, so a leg sized from a
    ///      stale quote degrades to a partial fill at a price the caller
    ///      already accepted instead of failing.
    ///
    ///      `minOut` applies to the output actually produced, so a caller that
    ///      wants all-or-nothing behaviour can still demand it. Callers
    ///      chaining across pools should check the returned `consumed`.
    ///
    ///      NOT AVAILABLE ON A HOOKED POOL: see `_swapExact`.
    function swapUpTo(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        payable
        nonReentrant
        returns (uint256 amountOut, uint256 consumed)
    {
        bool zeroForOne = _direction(tokenIn);
        if (amountIn == 0) revert ZeroAmount();
        if (zeroForOne && token0 == address(0)) {
            if (msg.value != amountIn) revert Bad();
        } else {
            if (msg.value != 0) revert Bad();
            _pullExact(tokenIn, msg.sender, amountIn);
        }
        return _swapExact(msg.sender, tokenIn, zeroForOne, amountIn, minOut, to, true, msg.sender);
    }

    /// @notice Partial-fill settlement of an amount already forwarded by the
    ///         factory, refunding the unconsumed input to `refundTo`.
    /// @dev Same authentication and `originator` caveats as `swapFromFactory`.
    function swapUpToFromFactory(
        address originator,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address to,
        address refundTo
    ) external payable nonReentrant returns (uint256 amountOut, uint256 consumed) {
        if (msg.sender != factory) revert NotFactory();
        if (refundTo == address(0) || refundTo == address(this)) revert Bad();
        bool zeroForOne = _direction(tokenIn);
        if (amountIn == 0) revert ZeroAmount();
        if (zeroForOne && token0 == address(0)) {
            if (msg.value != amountIn) revert Bad();
        } else if (msg.value != 0) {
            revert Bad();
        }
        return _swapExact(originator, tokenIn, zeroForOne, amountIn, minOut, to, true, refundTo);
    }

    /// @notice Settle an exact amount already forwarded by the factory.
    /// @dev Callable only by the factory after it has forwarded exactly the
    ///      declared input amount.
    /// @param originator Who the factory says is trading. On a routed swap the
    ///        immediate caller is the factory, so without this every routed
    ///        trade would present the factory to the hook - a sender-keyed
    ///        discount would leak to everyone routing, or be denied to them all.
    ///
    ///        IT IS NOT AUTHENTICATED. The router reaches the factory through a
    ///        public executor that does not forward the payer, so nobody in
    ///        this path can prove who the trader is. Treat it as a label for
    ///        accounting and analytics. A hook that grants privilege on it is
    ///        unsafe, and that is a property of the routing topology rather
    ///        than something this contract can fix.
    function swapFromFactory(
        address originator,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address to
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (msg.sender != factory) revert NotFactory();
        bool zeroForOne = _direction(tokenIn);
        if (amountIn == 0) revert ZeroAmount();
        if (zeroForOne && token0 == address(0)) {
            if (msg.value != amountIn) revert Bad();
        } else if (msg.value != 0) {
            revert Bad();
        }
        (amountOut,) = _swapExact(originator, tokenIn, zeroForOne, amountIn, minOut, to, false, address(0));
    }

    /// @dev One swap transition against already-loaded state.
    ///
    ///      Shared by the executing path and the partial-fill search so the two
    ///      cannot drift: a search that models the transition even slightly
    ///      differently from the swap will hand back a size that reverts, which
    ///      is the exact failure partial fill exists to remove.
    ///
    ///      Take the hook surcharge first, then apply the base fee to the rest.
    ///      Both are derived as a DIFFERENCE from a rounded-down remainder
    ///      rather than computed and floored directly. Flooring the fee rounds
    ///      in the trader's favour, and below `FEE_DENOM/rate` raw units it
    ///      floors to zero outright - so a trade split finely enough pays no
    ///      fee at all. Nothing carries a remainder between calls and the
    ///      reentrancy guard clears each time, so plain batching was sufficient
    ///      to exploit it. Rounding the remainder down and taking the fee as
    ///      what is left over means every nonzero trade pays at least one raw
    ///      unit, or produces no executable output and reverts.
    ///
    ///      The creator share comes from the base fee and does not change the
    ///      amount used for pricing. It rounds UP, for the same reason the fees
    ///      themselves do: flooring it sends the whole share to zero whenever
    ///      the base fee is a single raw unit, which a trade split finely
    ///      enough can arrange for every slice - the fee is still paid, but
    ///      none of it reaches the configured recipient. Rounding up removes
    ///      that entirely at no storage cost. The bias it introduces runs the
    ///      other way and is bounded by one raw unit of the input token per
    ///      swap, which lands with the LPs' side of a fee they only ever get a
    ///      configured fraction of. Ceiling can never exceed the fee itself,
    ///      since the share is capped at half of it.
    ///
    /// @dev `hasRoom` reports whether the reserve, overflow, and band
    ///      constraints hold. It is MONOTONE DECREASING in `amountIn` and is
    ///      what the partial-fill search bisects. A zero `amountOut` is a
    ///      SEPARATE condition running the opposite way - it turns on as size
    ///      grows - so the fillable set is an interval rather than a prefix or
    ///      a suffix, and the caller checks that half itself. Bisecting the
    ///      conjunction finds nothing.
    function _transitionAt(Transition memory t, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, uint256 kept, uint256 hookCut, uint256 creatorCut, bool hasRoom)
    {
        if (amountIn == 0) return (0, 0, 0, 0, true);

        if (hook != address(0)) {
            hookCut = amountIn - FixedPointMathLib.fullMulDiv(amountIn, FEE_DENOM - t.surcharge, FEE_DENOM);
        }
        uint256 net = amountIn - hookCut;

        uint256 feeAmount = net - FixedPointMathLib.fullMulDiv(net, FEE_DENOM - fee, FEE_DENOM);
        uint256 creatorBps = creatorFeeBps;
        if (creatorBps != 0) creatorCut = FixedPointMathLib.fullMulDivUp(feeAmount, creatorBps, BPS);
        kept = net - creatorCut;
        if (kept > type(uint128).max - t.rIn) return (0, 0, 0, 0, false);

        uint256 inAfterFee = net - feeAmount;
        amountOut = FixedPointMathLib.fullMulDiv(inAfterFee, t.rOut + t.vOut, t.rIn + t.vIn + inAfterFee);
        if (amountOut > t.rOut) return (0, 0, 0, 0, false);

        uint256 nextIn = t.rIn + t.vIn + kept;
        uint256 nextOut = t.rOut + t.vOut - amountOut;
        hasRoom = t.zeroForOne ? _priceInRange(nextIn, nextOut) : _priceInRange(nextOut, nextIn);
    }

    /// @dev Loaded swap state, grouped so the search can replay a transition
    ///      without repeating the storage reads.
    struct Transition {
        bool zeroForOne;
        uint256 rIn;
        uint256 rOut;
        uint256 vIn;
        uint256 vOut;
        uint256 surcharge;
    }

    /// @dev Largest input at or below `amountIn` that the band still admits.
    ///
    ///      Found by bisection, not algebra. The obvious closed form - reserve
    ///      room out to the bound - is WRONG: the input reserve grows by
    ///      `kept`, which retains the LP fee, while the output is priced on
    ///      `inAfterFee`, which does not. The two sides of the post-swap ratio
    ///      therefore advance under different quantities and the boundary
    ///      condition does not separate into anything a uint256 can solve
    ///      without a 512-bit square root.
    ///
    ///      Bisection over `[0, amountIn]` costs about log2(amountIn) replays
    ///      of pure memory arithmetic, and is only ever paid on the clamping
    ///      path - a swap that fits inside the band returns on the first probe.
    function _maxIn(Transition memory t, uint256 amountIn) internal view returns (uint256) {
        (,,,, bool roomAtFull) = _transitionAt(t, amountIn);
        if (roomAtFull) return amountIn;

        // Invariant: `lo` has room, `hi` does not. Zero trivially has room.
        uint256 lo;
        uint256 hi = amountIn;
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            (,,,, bool roomMid) = _transitionAt(t, mid);
            if (roomMid) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    /// @notice Output for `amountIn`, and whether the band admits it.
    ///
    /// @dev The quote a CHAINED caller needs. `_maxIn` clamps one pool against
    ///      its own band, which is the whole problem when the pool is hop `i`
    ///      of a route: the input arriving here is whatever the previous hop
    ///      produced, so a router cannot size this leg without first knowing
    ///      what every leg does. Exposing the transition lets the router search
    ///      the ROUTE and clamp once, at the front, where the leftover is still
    ///      the caller's own input token rather than an intermediate nobody
    ///      asked to hold.
    ///
    ///      This runs `_transitionAt` - the same function `_swapExact` runs, not
    ///      a reimplementation of it - so the quote cannot drift from execution.
    ///      That property is the point: a search modelling the transition even
    ///      slightly differently hands back a size that reverts, which is the
    ///      exact failure a partial fill exists to remove.
    ///
    ///      `fits` folds in the zero-output refusal as well as the band, so it
    ///      is the whole executability predicate for this size. Pass the address
    ///      the pool will SEE at execution as `sender`, not the end user: a
    ///      hook may key its surcharge on it, and the quote must sample the same
    ///      rate the swap will.
    ///
    ///      DO NOT BISECT `fits`. It is the conjunction of two conditions that
    ///      run in OPPOSITE directions - the band closes as size grows, the
    ///      zero-output refusal opens - so the fillable set is an interval, and
    ///      a search that halves against `fits` can step over that interval
    ///      entirely and report that nothing fills when something does. This is
    ///      the same trap `_transitionAt` documents for the pool's own `_maxIn`,
    ///      which is why that search bisects `hasRoom` alone. A chained caller
    ///      wanting to size a route must do the same, against
    ///      `quoteTransition` below, and check the zero-output half once at the
    ///      end. `fits` is for asking about ONE size, not for searching sizes.
    function quoteExactIn(address sender, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, bool fits)
    {
        bool hasRoom;
        (amountOut, hasRoom) = _quote(sender, tokenIn, amountIn);
        fits = hasRoom && amountOut != 0;
        if (!fits) amountOut = 0;
    }

    /// @notice The raw transition: the output for `amountIn`, and whether the
    ///         BAND alone admits it, with the zero-output refusal left to the
    ///         caller.
    ///
    /// @dev The searchable half of `quoteExactIn`. `hasRoom` is MONOTONE
    ///      DECREASING in `amountIn` - and true at zero - so it is the predicate
    ///      a partial-fill search over a route bisects, exactly as the pool's
    ///      own `_maxIn` bisects it for a single pool. Having found the largest
    ///      size the band admits, check `amountOut != 0` there once: output is
    ///      monotone increasing, so a zero at that size means no smaller size
    ///      fills either.
    ///
    ///      `amountOut` is returned unmasked here even when it is zero or the
    ///      band refuses, because a chained search needs the real figure to feed
    ///      the next hop. `quoteExactIn` masks it; this does not.
    function quoteTransition(address sender, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, bool hasRoom)
    {
        return _quote(sender, tokenIn, amountIn);
    }

    function _quote(address sender, address tokenIn, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, bool hasRoom)
    {
        bool zeroForOne = _direction(tokenIn);
        uint256 supply = totalSupply();
        if (supply == 0) return (0, false);
        // Matches `_transitionAt`: an empty trade leaves the price where it is,
        // so the band trivially admits it. `quoteExactIn` still reports it as
        // not fitting, via the zero output.
        if (amountIn == 0) return (0, true);

        Transition memory t;
        t.zeroForOne = zeroForOne;
        (t.rIn, t.rOut, t.vIn, t.vOut) = zeroForOne
            ? (uint256(reserve0), uint256(reserve1), _virtual0(supply, sqrtPHigh), _virtual1(supply, sqrtPLow))
            : (uint256(reserve1), uint256(reserve0), _virtual1(supply, sqrtPLow), _virtual0(supply, sqrtPHigh));
        if (hook != address(0)) t.surcharge = extraFee(sender, tokenIn, amountIn);

        (amountOut,,,, hasRoom) = _transitionAt(t, amountIn);
    }

    function _swapExact(
        address sender,
        address tokenIn,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minOut,
        address to,
        bool allowPartial,
        address refundTo
    ) internal returns (uint256 amountOut, uint256 consumed) {
        if (to == address(0) || to == address(this)) revert Bad();
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        (uint256 available0, uint256 available1, uint256 balance0, uint256 balance1) = _assertBacked(r0, r1);
        uint256 supply = totalSupply();
        if (supply == 0) revert InsufficientLiquidity();

        Transition memory t;
        t.zeroForOne = zeroForOne;
        (t.rIn, t.rOut, t.vIn, t.vOut) = zeroForOne
            ? (r0, r1, _virtual0(supply, sqrtPHigh), _virtual1(supply, sqrtPLow))
            : (r1, r0, _virtual1(supply, sqrtPLow), _virtual0(supply, sqrtPHigh));

        // Only the authenticated input amount may move the curve; other
        // balance surplus remains unaccounted.
        uint256 availableIn = zeroForOne ? available0 : available1;
        if (amountIn > availableIn - t.rIn) revert BalanceDeficit();

        if (hook != address(0)) t.surcharge = extraFee(sender, tokenIn, amountIn);

        consumed = amountIn;
        if (allowPartial) {
            // The surcharge is sampled once, at the requested size. On a hooked
            // pool the hook may return a different rate for the clamped size,
            // which would make the search's model wrong at exactly the boundary
            // it is searching for - so partial fill is refused there rather
            // than approximated. Hooked pools keep the all-or-nothing
            // behaviour and callers size them from the lens.
            if (hook != address(0)) revert UnsupportedToken();
            consumed = _maxIn(t, amountIn);
            if (consumed == 0) revert InsufficientOutput();
        }

        uint256 kept;
        uint256 hookCut;
        uint256 creatorCut;
        bool hasRoom;
        (amountOut, kept, hookCut, creatorCut, hasRoom) = _transitionAt(t, consumed);

        // Do not accept a rounded-zero output. Without `allowPartial` a trade
        // that leaves the band is refused outright rather than clamped.
        if (amountOut == 0 || !hasRoom) revert InsufficientOutput();
        if (amountOut < minOut) revert InsufficientOutput();

        uint256 next0 = zeroForOne ? t.rIn + kept : t.rOut - amountOut;
        uint256 next1 = zeroForOne ? t.rOut - amountOut : t.rIn + kept;

        if (hookCut != 0 || creatorCut != 0) {
            _accrueFees(zeroForOne, hookCut, creatorCut, tokenIn, t.surcharge);
        }

        // Keep the input less the hook and creator cuts in the reserves.
        _setReserves(next0, next1);
        _pay(zeroForOne ? token1 : token0, to, amountOut, zeroForOne ? balance1 : balance0);

        // Return the unconsumed input. Written after reserves are settled so a
        // callback-capable token sees committed state, and paid from the
        // balance measured before the output left, since that is the figure
        // `_pay` reconciles against.
        if (consumed < amountIn) {
            unchecked {
                _pay(tokenIn, refundTo, amountIn - consumed, zeroForOne ? balance0 : balance1);
            }
        }

        emit Swap(tokenIn, consumed, amountOut, to);
        _record(zeroForOne, consumed, amountOut);
        _afterSwap(sender, tokenIn, consumed, amountOut, to);
    }

    /// @dev Write the trade to the price tape. One storage write per swap; the
    ///      bucket rollover adds two more, once every FINE_PERIOD.
    ///
    ///      The price recorded is the EXECUTED price — output over input,
    ///      including fee and slippage — because a tape should show what
    ///      actually traded, not a mid nobody could have taken. It is raw
    ///      token1-per-token0 scaled by 1e18, the same convention as this
    ///      pool's own `sqrtPLow`/`sqrtPHigh`, so token decimals are NOT
    ///      normalised here and a reader applies them alongside the pair.
    ///
    ///      THE TAPE CANNOT REPRESENT A RAW PRICE BELOW 1e-18. The 1e18 scale is
    ///      fixed because it is what makes one chart client work against every
    ///      adopter of `IPriceTape`, so a pair whose raw token1-per-token0 price
    ///      is under that floor records bars of zero. Reaching it takes an
    ///      extreme decimal mismatch - roughly an 18-decimal token0 against a
    ///      token1 worth less than 1e-18 of it per raw unit - which the band
    ///      permits, since `sqrtPLow` only has to be nonzero. Nothing else is
    ///      affected: pricing, reserves, and the range check never consult the
    ///      tape, so such a pool trades correctly and merely charts flat. It is
    ///      recorded here rather than repaired because the repair would be a
    ///      per-pool scale factor, and a bar whose units depend on which pool
    ///      emitted it is worse for readers than a bar that is legibly empty.
    function _record(bool zeroForOne, uint256 amountIn, uint256 amountOut) internal {
        uint256 price = zeroForOne
            ? FixedPointMathLib.fullMulDiv(amountOut, 1e18, amountIn)
            : FixedPointMathLib.fullMulDiv(amountIn, 1e18, amountOut);
        // Volume is always quoted in token0 so bars from both directions add up.
        uint256 volume = zeroForOne ? amountIn : amountOut;
        uint256 done = PriceTape.print(_fine, price, volume, FINE_PERIOD);
        if (done != 0) PriceTape.fold(_coarse, done, FINE_PERIOD, COARSE_PERIOD);
    }

    // -------------------------------------------------------------- PRICE TAPE

    /// @inheritdoc IPriceTape
    function tapePeriods() external pure override returns (uint256[] memory periods) {
        periods = new uint256[](2);
        (periods[0], periods[1]) = (FINE_PERIOD, COARSE_PERIOD);
    }

    /// @inheritdoc IPriceTape
    function tapePair() external view override returns (address base, address quote) {
        (base, quote) = (token0, token1);
    }

    /// @inheritdoc IPriceTape
    /// @dev Any period other than the two recorded returns nothing rather than
    ///      guessing; a client aggregates fine bars for the timeframes between.
    function tape(uint256 period, uint256 count) external view override returns (uint256[] memory) {
        if (period == FINE_PERIOD) return PriceTape.recent(_fine, FINE_PERIOD, count);
        if (period == COARSE_PERIOD) return PriceTape.recent(_coarse, COARSE_PERIOD, count);
        return new uint256[](0);
    }

    function _direction(address tokenIn) internal view returns (bool zeroForOne) {
        zeroForOne = tokenIn == token0;
        if (!zeroForOne && tokenIn != token1) revert InvalidToken();
    }

    /// @notice Return the hook surcharge for a trade, clamped to the fee ceiling.
    /// @dev A revert, out-of-gas call, or invalid return is treated as zero.
    function extraFee(address sender, address tokenIn, uint256 amountIn) public view returns (uint256) {
        address h = hook;
        if (h == address(0)) return 0;
        uint256 budget = HOOK_GAS;
        bool ok;
        uint256 answer;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, shl(224, 0xc5096a69)) // `feeFor(address,address,uint256)`.
            mstore(add(m, 0x04), and(sender, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 0x24), and(tokenIn, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 0x44), amountIn)
            ok := staticcall(budget, h, m, 0x64, m, 0x20)
            ok := and(ok, eq(returndatasize(), 0x20))
            answer := mload(m)
        }
        if (!ok) return 0;
        uint256 room = MAX_TOTAL_FEE - fee;
        return answer > room ? room : answer;
    }

    function _accrueFees(bool zeroForOne, uint256 hookCut, uint256 creatorCut, address tokenIn, uint256 surcharge)
        internal
    {
        // Counters are uint256. Accrual is cumulative while reserves are not -
        // the same units can be traded back and forth indefinitely - so a
        // narrower counter is not bounded by reserve size and could saturate
        // after enough directional volume. Once saturated every further swap
        // in that direction reverts, permanently if the payee can no longer
        // collect. The backing balances are uint256 already, so nothing is
        // gained by narrowing the claim against them.
        if (hookCut != 0) {
            unchecked {
                if (zeroForOne) hookOwed0 += hookCut;
                else hookOwed1 += hookCut;
            }
            emit HookFee(tokenIn, hookCut, surcharge);
        }
        if (creatorCut != 0) {
            unchecked {
                if (zeroForOne) creatorOwed0 += creatorCut;
                else creatorOwed1 += creatorCut;
            }
        }
    }

    /// @notice Sweep accrued creator fees.
    /// @dev Callable only by `feeRecipient`.
    function collectCreatorFees(address to) external nonReentrant returns (uint256 a0, uint256 a1) {
        if (msg.sender != feeRecipient) revert NotFeeRecipient();
        if (to == address(0) || to == address(this)) revert Bad();
        (,, uint256 balance0, uint256 balance1) = _assertBacked(reserve0, reserve1);
        (a0, a1) = (creatorOwed0, creatorOwed1);
        (creatorOwed0, creatorOwed1) = (0, 0);
        if (a0 != 0) _pay(token0, to, a0, balance0);
        if (a1 != 0) _pay(token1, to, a1, balance1);
        emit CreatorFeeCollected(to, a0, a1);
    }

    /// @notice Sweep accrued hook fees.
    /// @dev Callable only by the configured hook.
    function collectHookFees(address to) external nonReentrant returns (uint256 a0, uint256 a1) {
        if (msg.sender != hook) revert NotHook();
        if (to == address(0) || to == address(this)) revert Bad();
        (,, uint256 balance0, uint256 balance1) = _assertBacked(reserve0, reserve1);
        (a0, a1) = (hookOwed0, hookOwed1);
        (hookOwed0, hookOwed1) = (0, 0);
        if (a0 != 0) _pay(token0, to, a0, balance0);
        if (a1 != 0) _pay(token1, to, a1, balance1);
        emit HookFeeCollected(to, a0, a1);
    }

    /// @dev Called after reserves and output are settled, while the reentrancy
    ///      guard is active. Failure is reported but does not revert the swap.
    function _afterSwap(address sender, address tokenIn, uint256 amountIn, uint256 amountOut, address to)
        internal
    {
        address h = hook;
        if (h == address(0)) return;
        uint256 budget = HOOK_GAS;
        bool ok;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, shl(224, 0x3da8b865)) // `afterSwap(address,address,uint256,uint256,address)`.
            mstore(add(m, 0x04), and(sender, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 0x24), and(tokenIn, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(m, 0x44), amountIn)
            mstore(add(m, 0x64), amountOut)
            mstore(add(m, 0x84), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            ok := call(budget, h, 0, m, 0xa4, codesize(), 0x00)
        }
        if (!ok) emit HookCallFailed(h);
    }

    // --------------------------------------------------------------- LIQUIDITY

    /// @notice Deposit both sides and mint LP shares.
    /// @dev Pulls exact amounts from the caller and refunds unused amounts.
    /// @param sqrtPriceInit Initial price for an empty pool; ignored afterwards.
    /// @param amount0 Token0 amount, or exact `msg.value` for native token0.
    /// @param amount1 Token1 amount.
    /// @param minLP Minimum LP shares to mint.
    /// @param to LP share recipient.
    function addLiquidityExact(uint256 sqrtPriceInit, uint256 amount0, uint256 amount1, uint256 minLP, address to)
        external
        payable
        nonReentrant
        returns (uint256 lp, uint256 used0, uint256 used1)
    {
        if (token0 == address(0)) {
            if (msg.value != amount0) revert Bad();
        } else {
            if (msg.value != 0) revert Bad();
            _pullExact(token0, msg.sender, amount0);
        }
        _pullExact(token1, msg.sender, amount1);
        return _addLiquidity(sqrtPriceInit, amount0, amount1, minLP, to, msg.sender);
    }

    /// @notice Mint against assets forwarded by the factory.
    /// @dev The factory transfers ERC-20 amounts and forwards native value in
    ///      the same call.
    function addLiquidityFromFactory(
        uint256 sqrtPriceInit,
        uint256 amount0,
        uint256 amount1,
        uint256 minLP,
        address to,
        address refundTo
    ) external payable nonReentrant returns (uint256 lp, uint256 used0, uint256 used1) {
        if (msg.sender != factory) revert NotFactory();
        if (token0 == address(0)) {
            // A zero value is valid for an upper-bound, token1-only seed.
            if (msg.value != amount0) revert Bad();
        } else if (msg.value != 0) {
            revert Bad();
        }
        return _addLiquidity(sqrtPriceInit, amount0, amount1, minLP, to, refundTo);
    }

    function _addLiquidity(
        uint256 sqrtPriceInit,
        uint256 amount0,
        uint256 amount1,
        uint256 minLP,
        address to,
        address refundTo
    ) internal returns (uint256 lp, uint256 used0, uint256 used1) {
        if (to == address(0) || to == address(this)) revert Bad();
        if (refundTo == address(0) || refundTo == address(this)) revert Bad();
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        (uint256 available0, uint256 available1, uint256 balance0, uint256 balance1) = _assertBacked(r0, r1);
        // Do not credit unrelated balance surplus to this deposit.
        if (amount0 > available0 - r0 || amount1 > available1 - r1) {
            revert BalanceDeficit();
        }

        uint256 supply = totalSupply();
        if (supply == 0) {
            // A named market must be initialized through the factory.
            if (feeRecipient != address(0) && msg.sender != factory) revert NotFactory();
            // Bounds are inclusive; a boundary seed is one-sided.
            if (sqrtPriceInit < sqrtPLow || sqrtPriceInit > sqrtPHigh) revert PriceOutOfRange();
            (lp, used0, used1) = _seed(amount0, amount1, sqrtPLow, sqrtPHigh, sqrtPriceInit);
            if (lp <= MIN_LIQUIDITY) revert InsufficientLiquidity();
            if (used0 == 0 && used1 == 0) revert InsufficientLiquidity();
            unchecked {
                lp -= MIN_LIQUIDITY;
            }
            _mint(address(0xdead), MIN_LIQUIDITY);
        } else {
            (lp, used0, used1) = _proportional(amount0, amount1, r0, r1, supply);
            if (lp > MAX_LIQUIDITY - supply) revert InsufficientLiquidity();
        }

        if (lp < minLP) revert InsufficientLiquidity();

        // The seed's two bound corrections run in sequence, and the upper one
        // can undo the lower one: zeroing `used1` to respect the ceiling can
        // leave the pool below its floor. Rounding in the proportional path can
        // nudge the price similarly. Neither is caught by the corrections
        // themselves, so the postcondition is asserted here against the state
        // actually about to be committed - the same one swaps already enforce.
        //
        // Without it a seed can pass every guard, mint shares, burn the
        // permanent minimum, and leave a pool priced outside its own range with
        // one side empty, which cannot trade in either direction. Refusing the
        // deposit is strictly better than creating that pool.
        //
        // Deliberately NOT applied to removals: making an exit conditional on a
        // price check could trap liquidity, which is a worse failure than the
        // one this prevents.
        {
            uint256 postSupply = supply == 0 ? lp + MIN_LIQUIDITY : supply + lp;
            uint256 postR0 = r0 + used0;
            uint256 postR1 = r1 + used1;
            uint256 postX = _virtual0(postSupply, sqrtPHigh) + postR0;
            uint256 postY = _virtual1(postSupply, sqrtPLow) + postR1;
            if (!_priceInRange(postX, postY)) {
                // A pool can be outside its band without anyone misbehaving:
                // both virtual reserves are floored functions of supply, so
                // burning liquidity down toward the dead minimum can leave a
                // state the band no longer contains. Refusing every deposit
                // there is what makes the excursion permanent - swaps must
                // land back inside the band in one step, which an emptied
                // output reserve cannot do, and a proportional deposit holds
                // the ratio and so fails this same check. The pool would keep
                // its reserves and never trade again.
                //
                // So a deposit into an already-out-of-band pool is allowed
                // when it does not push the price further out. That restores
                // the repair path - anyone can grow the pool back to a
                // resolution where the band holds - without giving anyone a
                // way to move a healthy pool out of its range: if the pool is
                // in band, `miss` is zero and only an in-band result passes.
                if (supply == 0) revert PriceOutOfRange();
                uint256 preMiss = _bandMiss(
                    _ratio(_virtual0(supply, sqrtPHigh) + r0, _virtual1(supply, sqrtPLow) + r1)
                );
                if (preMiss == 0) revert PriceOutOfRange();
                if (_bandMiss(_ratio(postX, postY)) > preMiss) revert PriceOutOfRange();
            }
            // Being inside the band is not the same as being tradeable. The
            // band is a property of the floored price representation; whether
            // an integer trade exists is a property of the reserves. A seed
            // whose whole output reserve is worth less than one raw unit of
            // the other token satisfies the first and fails the second: the
            // smallest possible swap already asks for more than the pool
            // holds, and output is monotone in input, so every swap reverts.
            // Such a pool is immutable and permanently inert, so refuse to
            // create it.
            if (supply == 0) {
                if (!_tradeable(postX, postY, postR0, postR1)) revert InsufficientLiquidity();
                if (
                    _virtual0(postSupply, sqrtPHigh) < MIN_RESOLUTION
                        || _virtual1(postSupply, sqrtPLow) < MIN_RESOLUTION
                ) revert InsufficientLiquidity();
                // `sqrtPriceInit` is an argument to the seed, not merely a hint
                // to it: liquidity is floored, the amounts it requires are
                // ceiled, and the two bound corrections below can move the
                // result again, so the price the pool actually opens at is not
                // the one that was asked for. Checking only the immutable band
                // is far too loose - a seed can succeed several percent away
                // from its own argument and hand the seeder an instant
                // arbitrage, with `minLP` constraining shares but nothing
                // constraining price. The resolution floor above bounds the
                // real rounding error to parts per million, so a band this wide
                // rejects nothing legitimate and catches the case where the
                // requested price was not honoured at all.
                unchecked {
                    uint256 wantSq = sqrtPriceInit * sqrtPriceInit;
                    uint256 gotSq = _ratio(postX, postY);
                    uint256 slack = wantSq / SEED_PRICE_TOLERANCE;
                    if (gotSq < wantSq - slack || gotSq > wantSq + slack) revert PriceOutOfRange();
                }
            } else {
                // A later deposit is proportional, but proportional is not the
                // same as liveness-preserving: both virtual reserves are
                // floored functions of supply, and minting shares moves them by
                // a different rounding than the real reserves it adds. A
                // deposit can therefore land a pool that had exactly one
                // executable trade in a state that has none, which on an
                // immutable market is permanent for as long as nobody repairs
                // it. Enlarging the reserves does not by itself rule that out.
                //
                // So preserve liveness rather than assert it: a deposit into a
                // tradeable pool must leave it tradeable, while a deposit into
                // a pool that already has no executable trade is allowed
                // through unconditionally. That keeps the repair path open -
                // growing a stuck pool back to a workable resolution is exactly
                // the deposit this check must not block - and it never lets a
                // healthy pool be deposited into the dead state. Reverting an
                // add strands nothing, which is why the same treatment is not
                // extended to removals.
                if (_tradeable(_virtual0(supply, sqrtPHigh) + r0, _virtual1(supply, sqrtPLow) + r1, r0, r1)) {
                    if (!_tradeable(postX, postY, postR0, postR1)) revert InsufficientLiquidity();
                }
            }
        }

        _setReserves(r0 + used0, r1 + used1);
        _mint(to, lp);

        // Write reserves before refunding so callbacks see settled state.
        if (amount0 > used0) _pay(token0, refundTo, amount0 - used0, balance0);
        if (amount1 > used1) _pay(token1, refundTo, amount1 - used1, balance1);

        emit AddLiquidity(to, used0, used1, lp);
    }

    /// @dev Compute liquidity from each side and use the smaller result.
    ///      Boundary prices are supported and produce one-sided liquidity.
    function _seed(uint256 in0, uint256 in1, uint256 sl, uint256 sh, uint256 s)
        internal
        pure
        returns (uint256 lp, uint256 used0, uint256 used1)
    {
        if (s == sl) {
            // x = L * (1/s - 1/sh)  ->  L = x * s * sh / (sh - s)
            lp = FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(in0, s, sh - s), sh, WAD);
        } else if (s == sh) {
            // y = L * (s - sl)      ->  L = y / (s - sl)
            lp = FixedPointMathLib.fullMulDiv(in1, WAD, s - sl);
        } else {
            uint256 lpFrom0 = FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(in0, s, sh - s), sh, WAD);
            uint256 lpFrom1 = FixedPointMathLib.fullMulDiv(in1, WAD, s - sl);
            lp = FixedPointMathLib.min(lpFrom0, lpFrom1);
        }
        if (lp == 0) revert ZeroAmount();
        if (lp > MAX_LIQUIDITY) revert InsufficientLiquidity();

        // Round requirements up so the pool is not underfunded.
        used0 = FixedPointMathLib.fullMulDivUp(FixedPointMathLib.fullMulDivUp(lp, sh - s, sh), WAD, s);
        used1 = FixedPointMathLib.fullMulDivUp(lp, s - sl, WAD);

        // Remove rounding excess if it would put the discrete price outside
        // the configured range.
        uint256 v0 = _virtual0(lp, sh);
        uint256 v1 = _virtual1(lp, sl);
        if (v0 == 0 || v1 == 0) revert InsufficientLiquidity();
        uint256 x = v0 + used0;
        uint256 y = v1 + used1;
        uint256 maxX = FixedPointMathLib.fullMulDiv(y, WAD * WAD, sl * sl);
        if (x > maxX) {
            used0 = maxX > v0 ? maxX - v0 : 0;
            x = v0 + used0;
        }
        uint256 maxY = FixedPointMathLib.fullMulDiv(x, sh * sh, WAD * WAD);
        if (y > maxY) used1 = maxY > v1 ? maxY - v1 : 0;

        if (used0 > in0 || used1 > in1) revert InsufficientLiquidity();
    }

    /// @dev Uses the pool's reserve ratio, so the deposit does not move price.
    function _proportional(uint256 in0, uint256 in1, uint256 r0, uint256 r1, uint256 supply)
        internal
        pure
        returns (uint256 lp, uint256 used0, uint256 used1)
    {
        // An empty side does not constrain the proportional amount.
        uint256 lpFrom0 = r0 == 0 ? type(uint256).max : FixedPointMathLib.fullMulDiv(in0, supply, r0);
        uint256 lpFrom1 = r1 == 0 ? type(uint256).max : FixedPointMathLib.fullMulDiv(in1, supply, r1);
        lp = FixedPointMathLib.min(lpFrom0, lpFrom1);
        if (lp == 0 || lp == type(uint256).max) revert ZeroAmount();

        used0 = r0 == 0 ? 0 : FixedPointMathLib.fullMulDivUp(lp, r0, supply);
        used1 = r1 == 0 ? 0 : FixedPointMathLib.fullMulDivUp(lp, r1, supply);
        if (used0 > in0 || used1 > in1) revert InsufficientLiquidity();
    }

    /// @notice Burn LP shares for a pro-rata slice of both reserves.
    /// @dev Deliberately unguarded by the range and tradeability postconditions
    ///      that `_addLiquidity` enforces: an exit that can revert is a worse
    ///      failure than the one a guard here would prevent. Both virtual
    ///      reserves are floored functions of supply, so a burn can move the
    ///      represented price by up to one raw unit of virtual reserve even
    ///      though the real withdrawal is exactly proportional. On any pool
    ///      whose reserves are large next to one raw unit that is dust and the
    ///      next swap prices normally; the pathological case is a pool holding
    ///      less than one input unit is worth, where a burn can leave the state
    ///      with no executable trade until someone deposits again. The seed
    ///      guard keeps pools out of that regime at creation, and the state is
    ///      repairable by anyone with a single unit of liquidity, so it is a
    ///      dust-scale liveness quirk rather than a fund risk.
    function removeLiquidity(uint256 lp, uint256 min0, uint256 min1, address to)
        public
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (lp == 0) revert ZeroAmount();
        if (to == address(0) || to == address(this)) revert Bad();
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        (,, uint256 balance0, uint256 balance1) = _assertBacked(r0, r1);
        uint256 supply = totalSupply();

        // Rounds down, so the dust stays with the holders who remain.
        amount0 = FixedPointMathLib.fullMulDiv(lp, r0, supply);
        amount1 = FixedPointMathLib.fullMulDiv(lp, r1, supply);
        if (amount0 < min0 || amount1 < min1) revert InsufficientOutput();

        _burn(msg.sender, lp);
        _setReserves(r0 - amount0, r1 - amount1);

        if (amount0 != 0) _pay(token0, to, amount0, balance0);
        if (amount1 != 0) _pay(token1, to, amount1, balance1);

        emit RemoveLiquidity(msg.sender, lp, amount0, amount1);
    }

    // ----------------------------------------------------------------- ERC-20

    /// @dev The name hash is fixed; pool address and chain ID still separate
    ///      each permit domain.
    function _constantNameHash() internal pure override returns (bytes32) {
        return 0x97afff290dde66c4a8458ec3623f0fe8e943ac845271886a6598e35deed20617;
    }

    /// @notice LP token name.
    function name() public pure override returns (string memory) {
        return "Precision LP";
    }

    /// @notice LP token symbol.
    function symbol() public pure override returns (string memory) {
        return "pLP";
    }

    /// @dev Canonical Permit2 holds an infinite allowance over LP shares.
    ///
    ///      This is Solady's default, and it is restated here so it is a
    ///      DECISION rather than something inherited from a dependency bump: an
    ///      immutable pool that silently trusts a third-party contract with
    ///      every holder's position is not something to discover from a diff.
    ///      Permit2 still requires the owner's signature, so this grants no
    ///      party the ability to move shares unilaterally; what it accepts is
    ///      that a bug in Permit2 would reach LP shares as it would reach any
    ///      other Permit2-enabled token.
    ///
    ///      Kept enabled because it matches the stack these shares live in -
    ///      zRouter and zSwap already fund swaps through Permit2, and the zap
    ///      exists so an LP position can be exited inside a route, which is
    ///      exactly the flow a signature-based transfer serves. Returning false
    ///      here is a one-line change and costs only that convenience.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return true;
    }

    // ---------------------------------------------------------------- HELPERS

    function _setReserves(uint256 r0, uint256 r1) internal {
        if (r0 > type(uint128).max || r1 > type(uint128).max) revert Overflow();
        (reserve0, reserve1) = (uint128(r0), uint128(r1));
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : token.balanceOf(address(this));
    }

    function _pullExact(address token, address from, uint256 amount) internal {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert UnsupportedToken();
    }

    function _assertBacked(uint256 r0, uint256 r1)
        internal
        view
        returns (uint256 available0, uint256 available1, uint256 balance0, uint256 balance1)
    {
        uint256 owed0;
        uint256 owed1;
        unchecked {
            if (hook != address(0)) {
                (owed0, owed1) = (hookOwed0, hookOwed1);
            }
            if (creatorFeeBps != 0) {
                owed0 += creatorOwed0;
                owed1 += creatorOwed1;
            }
        }
        balance0 = _balance(token0);
        balance1 = _balance(token1);
        unchecked {
            if (balance0 < r0 + owed0 || balance1 < r1 + owed1) revert BalanceDeficit();
            (available0, available1) = (balance0 - owed0, balance1 - owed1);
        }
    }

    function _pay(address token, address to, uint256 amount, uint256 senderBefore) private {
        if (token == address(0)) {
            to.safeTransferETH(amount);
            return;
        }

        uint256 recipientBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 senderAfter = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(to);
        if (
            senderAfter > senderBefore || senderBefore - senderAfter != amount || recipientAfter < recipientBefore
                || recipientAfter - recipientBefore != amount
        ) revert UnsupportedToken();
    }
}
