// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {ERC20} from "../../lib/solady/src/tokens/ERC20.sol";
import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";

/// @title IPrecisionHook
/// @notice Hook interface for a bounded fee surcharge and post-swap callback.
/// @dev The pool caps the fee and does not revert on callback failure.
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
contract PrecisionPool is ERC20 {
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

    /// @dev Maximum combined base fee and hook surcharge (10%).
    uint256 constant MAX_TOTAL_FEE = 100_000;

    /// @dev Upper bound for WAD-scaled square-root prices. Together with the
    ///      liquidity cap, it keeps virtual-reserve arithmetic bounded.
    uint256 constant MAX_SQRT_PRICE = 1e36;

    /// @dev LP supply is the curve liquidity; the cap keeps virtual reserves
    ///      within uint256 arithmetic.
    uint256 constant MAX_LIQUIDITY = type(uint128).max;

    /// @dev Gas limit for each hook callback.
    uint256 constant HOOK_GAS = 150_000;

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
    ) payable {
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

    /// @dev True when at least one direction admits an executable integer
    ///      trade: a one-unit input must price to an output the real reserve
    ///      can actually pay. Fees only shrink the priced input, so this is the
    ///      necessary granularity condition, checked against the augmented
    ///      reserves the swap itself uses.
    function _tradeable(uint256 x, uint256 y, uint256 r0, uint256 r1) internal pure returns (bool) {
        if (r1 != 0 && FixedPointMathLib.fullMulDiv(1, y, x + 1) <= r1) return true;
        if (r0 != 0 && FixedPointMathLib.fullMulDiv(1, x, y + 1) <= r0) return true;
        return false;
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
        return _swapExact(msg.sender, tokenIn, zeroForOne, amountIn, minOut, to);
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
        return _swapExact(originator, tokenIn, zeroForOne, amountIn, minOut, to);
    }

    function _swapExact(
        address sender,
        address tokenIn,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minOut,
        address to
    ) internal returns (uint256 amountOut) {
        if (to == address(0) || to == address(this)) revert Bad();
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        (uint256 available0, uint256 available1, uint256 balance0, uint256 balance1) = _assertBacked(r0, r1);
        uint256 supply = totalSupply();
        if (supply == 0) revert InsufficientLiquidity();

        (uint256 rIn, uint256 rOut, uint256 vIn, uint256 vOut) = zeroForOne
            ? (r0, r1, _virtual0(supply, sqrtPHigh), _virtual1(supply, sqrtPLow))
            : (r1, r0, _virtual1(supply, sqrtPLow), _virtual0(supply, sqrtPHigh));

        // Only the authenticated input amount may move the curve; other
        // balance surplus remains unaccounted.
        uint256 availableIn = zeroForOne ? available0 : available1;
        if (amountIn > availableIn - rIn) revert BalanceDeficit();

        // Take the hook surcharge first, then apply the base fee to the rest.
        //
        // Both are derived as a DIFFERENCE from a rounded-down remainder rather
        // than computed and floored directly. Flooring the fee rounds in the
        // trader's favour, and below `FEE_DENOM/rate` raw units it floors to
        // zero outright - so a trade split finely enough pays no fee at all.
        // Nothing carries a remainder between calls and the reentrancy guard
        // clears each time, so plain batching was sufficient to exploit it.
        // Rounding the remainder down and taking the fee as what is left over
        // means every nonzero trade pays at least one raw unit, or produces no
        // executable output and reverts.
        uint256 hookCut;
        uint256 surcharge;
        if (hook != address(0)) {
            surcharge = extraFee(sender, tokenIn, amountIn);
            hookCut = amountIn - FixedPointMathLib.fullMulDiv(amountIn, FEE_DENOM - surcharge, FEE_DENOM);
        }
        uint256 net = amountIn - hookCut;

        // The creator share comes from the base fee and does not change the
        // amount used for pricing.
        uint256 feeAmount = net - FixedPointMathLib.fullMulDiv(net, FEE_DENOM - fee, FEE_DENOM);
        uint256 creatorCut;
        uint256 creatorBps = creatorFeeBps;
        if (creatorBps != 0) creatorCut = FixedPointMathLib.fullMulDiv(feeAmount, creatorBps, BPS);
        uint256 kept = net - creatorCut;
        if (kept > type(uint128).max - rIn) revert Overflow();

        uint256 inAfterFee = net - feeAmount;
        amountOut = FixedPointMathLib.fullMulDiv(inAfterFee, rOut + vOut, rIn + vIn + inAfterFee);

        // Do not clamp at a range boundary or accept a rounded-zero output.
        if (amountOut == 0 || amountOut > rOut) revert InsufficientOutput();
        if (amountOut < minOut) revert InsufficientOutput();

        uint256 next0 = zeroForOne ? rIn + kept : rOut - amountOut;
        uint256 next1 = zeroForOne ? rOut - amountOut : rIn + kept;
        uint256 nextVX = (zeroForOne ? vIn : vOut) + next0;
        uint256 nextVY = (zeroForOne ? vOut : vIn) + next1;
        if (!_priceInRange(nextVX, nextVY)) revert InsufficientOutput();

        if (hookCut != 0 || creatorCut != 0) {
            _accrueFees(zeroForOne, hookCut, creatorCut, tokenIn, surcharge);
        }

        // Keep the input less the hook and creator cuts in the reserves.
        if (zeroForOne) {
            _setReserves(next0, next1);
            _pay(token1, to, amountOut, balance1);
        } else {
            _setReserves(next0, next1);
            _pay(token0, to, amountOut, balance0);
        }

        emit Swap(tokenIn, amountIn, amountOut, to);
        _afterSwap(sender, tokenIn, amountIn, amountOut, to);
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
            if (!_priceInRange(postX, postY)) revert PriceOutOfRange();
            // Being inside the band is not the same as being tradeable. The
            // band is a property of the floored price representation; whether
            // an integer trade exists is a property of the reserves. A seed
            // whose whole output reserve is worth less than one raw unit of
            // the other token satisfies the first and fails the second: the
            // smallest possible swap already asks for more than the pool
            // holds, and output is monotone in input, so every swap reverts.
            // Such a pool is immutable and permanently inert, so refuse to
            // create it. Only checked on the seed - later deposits are
            // proportional and only ever enlarge the reserves, and removals
            // must never be blocked.
            if (supply == 0 && !_tradeable(postX, postY, postR0, postR1)) revert InsufficientLiquidity();
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
