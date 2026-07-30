// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {ERC20} from "../../lib/solady/src/tokens/ERC20.sol";
import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PrecisionPool
/// @notice Concentrated constant-product pool over one pair and one fixed price
///         range, with ERC-20 LP shares. Generalises PrecisionRangePool, whose
///         pair, range and fee are compile-time constants, into a clone target
///         the factory can stamp out per market.
///
/// @dev    Real reserves x (token0) and y (token1) are concentrated by virtual
///         reserves, so the pool trades as if it held far more than it does:
///
///             X = x + L/sqrtPHigh      Y = y + L*sqrtPLow      X * Y = L^2
///
///         Liquidity L is the LP share supply, so `totalSupply` is literally
///         the pool's liquidity and the virtual offsets follow from it. There
///         is no separate accounting to keep in step.
///
///         PRICES ARE IN RAW UNITS AND DECIMALS NEVER APPEAR HERE. `sqrtPLow`
///         and `sqrtPHigh` are the square roots of a price quoted in raw token1
///         per raw token0, scaled by 1e18. A pool over an 18-decimal token0 and
///         a 6-decimal token1 therefore carries a range that already has the
///         1e12 in it. This is deliberate: doing decimal adjustment on-chain
///         would mean reading and trusting two `decimals()` calls and carrying
///         the conversion through every price expression, which is exactly
///         where concentrated-liquidity implementations acquire their rounding
///         bugs. The factory and the frontend compute the adjusted bounds once,
///         off-chain, where they can be checked by eye.
///
///         SEEDING TAKES A PRICE RATHER THAN INFERRING ONE. The first deposit
///         names the price it is seeding at, and liquidity comes from two
///         independent divisions - one per side, smaller wins, remainder
///         refunded. Inferring the price from the deposit ratio instead means
///         solving (1 - ab)L^2 - (bx + ay)L - xy = 0, whose discriminant
///         carries a `B^2` term; with the range fixed at deploy time that term
///         is safely bounded, but once the range is a parameter `B` reaches
///         ~1e50 for pairs whose token1 has more decimals than token0, and the
///         square overflows a uint256 before any realistic deposit size. Naming
///         the price keeps every intermediate inside 256 bits.
///
///         A BAND SEEDED AT ITS OWN EDGE IS A LIMIT ORDER THAT EARNS. One
///         side of the requirement vanishes at each bound, so a deposit made
///         there is entirely token0 or entirely token1, and the pool converts
///         it as the price crosses the band. Unlike a resting order it is paid
///         the swap fee throughout, and unlike a managed position its claim is
///         an ordinary fungible token. It needs no separate code path - see
///         _seed, where only two divisors have to be sidestepped.
///
///         WHAT A SEED PRICE CAN AND CANNOT DO. It sets where the pool starts
///         quoting, so a seeder who names a price the market disagrees with is
///         arbitraged for the difference - the same exposure the first deposit
///         into any pool carries, and paid by the seeder rather than by anyone
///         who follows. It cannot be used against later depositors: once the
///         supply is nonzero the argument is ignored entirely and deposits are
///         struck at the pool's own reserve ratio.
///
///         EXCESS IS REFUNDED, NOT ABSORBED. Both deposit paths take what the
///         binding side supports and return the rest. Keeping the overage would
///         quietly pay it to existing holders, which turns a mis-sized deposit
///         into a transfer between users rather than a rounding detail.
///
///         BOUNDARIES ARE REAL. A swap that would take more than a side holds
///         is refused rather than clamped: past the edge of the range the pool
///         is entirely in one asset and there is nothing left to sell. The
///         caller finds out instead of silently receiving less.
///
///         PARAMETERS ARE IMMUTABLES, AND THE POOL IS DEPLOYED IN FULL. A
///         clone would make each market ~45k gas instead of ~1.6M, but it puts
///         a delegatecall and a read out of the proxy's own bytecode in front
///         of every swap forever, and it forbids `immutable` - which fails
///         silently, by reading zero, rather than loudly. Ranges are curated
///         rather than freeform precisely so that pools are few and deep, and
///         with few pools the deployer paying once beats every future taker
///         paying a little. The saving crosses over around 2,300 swaps.
///
///         THE HOOK OBSERVES AND NOTHING MORE. An optional `hook` is called
///         once, after a swap has already settled, and neither its return
///         value nor its success is read. It cannot set the fee, bend the
///         curve, veto a trade or see funds: what a taker pays and what an LP
///         is owed are decided entirely by the code above, before the hook is
///         ever reached.
///
///         That restraint is forced by immutability. There is no upgrade path
///         here, so a hook able to revert would brick its pool permanently and
///         a hook able to burn gas would tax every swap forever. The call is
///         therefore gas-capped and its failure discarded - the pool keeps
///         working whatever the hook does. A hook that must not be missed does
///         not belong behind this interface.
///
///         Uses that fit: fee accounting for a creator, reward accrual, a TWAP
///         or analytics feed. Uses that do not: dynamic fees, custom curves,
///         access control. Those change what a trade costs and belong in the
///         parameters, or in a different implementation.
///
///         EXTENSION IS OTHERWISE BY IMPLEMENTATION. A pool that must price
///         differently is a different contract behind the same factory, so
///         nothing that decides a price is ever injected at runtime.
/// @notice Advisory observer invoked after a swap settles.
/// @dev Called with a fixed gas budget, and its outcome is ignored. A hook
///      cannot influence price, block a trade, or make one fail.
interface IPrecisionHook {
    /// @notice Additional fee, in pips, on top of the pool's own.
    /// @dev Deliberately `view`. A stateful pricing callback would make a
    ///      quote unreproducible - the lens could not ask what a swap will
    ///      cost without performing it - and quoting exactly is what lets
    ///      these pools be compared against other venues before routing.
    function feeFor(address sender, address tokenIn, uint256 amountIn) external view returns (uint256 extraFee);

    function afterSwap(address sender, address tokenIn, uint256 amountIn, uint256 amountOut, address to) external;
}

contract PrecisionPool is ERC20 {
    using SafeTransferLib for address;

    uint256 constant WAD = 1e18;
    uint256 constant FEE_DENOM = 1_000_000; // fee is in pips

    /// @dev Burned on the seed so share price cannot be inflated against a
    ///      one-wei supply.
    uint256 constant MIN_LIQUIDITY = 1000;

    /// @dev Ceiling on the creator's share OF THE FEE, not of volume. Half is
    ///      already aggressive; the cap exists so the parameter cannot be set
    ///      somewhere an LP would never knowingly deposit into.
    uint256 constant MAX_CREATOR_SHARE = 5_000; // 50% of the fee
    uint256 constant BPS = 10_000;

    /// @dev Ceiling on base plus hook fee. A hook cannot price a pool below
    ///      its stated fee, and cannot price it above this; between the two it
    ///      is free, and a taker's own minOut is the backstop.
    uint256 constant MAX_TOTAL_FEE = 100_000; // 10%

    /// @dev Budget for the advisory hook. Enough for accounting and an event,
    ///      far too little to make a swap meaningfully more expensive.
    uint256 constant HOOK_GAS = 150_000;

    /// @dev `uint32(bytes4(keccak256("Reentrancy()")))`. A named slot rather
    ///      than slot zero, which is where an inherited library would most
    ///      plausibly collide.
    uint256 constant _REENTRANCY_SLOT = 0xab143c06;

    /// @notice Pair, range and fee. Fixed at deployment and free to read.
    address public immutable token0;
    address public immutable token1;
    /// @notice The only contract permitted to settle a prefunded factory route.
    /// @dev Direct callers use `swapExactIn` and `addLiquidityExact`, which
    ///      pull their assets in the same call. Keeping the balance-delta
    ///      settlement private to the factory prevents a later caller from
    ///      claiming assets somebody else transferred in an earlier transaction.
    address public immutable factory;
    uint256 public immutable sqrtPLow;
    uint256 public immutable sqrtPHigh;
    uint256 public immutable fee;

    /// @notice Advisory post-swap observer, address(0) for none.
    address public immutable hook;

    /// @notice The pool's creator: recipient of any fee split, and the
    ///         authority a surcharge hook checks. address(0) = none.
    /// @dev A fixed split of the pool's own fee rather than an addition to it,
    ///      so it changes nothing about what a taker pays or what the pool
    ///      quotes - only who keeps the proceeds. That is why it may reduce an
    ///      LP's take where a hook may not: this is an immutable term, visible
    ///      before anyone deposits, rather than a price a third party sets at
    ///      runtime. The launchpad case needs no hook contract at all.
    address public immutable feeRecipient;

    /// @notice Creator's share of the fee, in bps OF THE FEE.
    uint256 public immutable creatorFeeBps;

    uint128 public reserve0;
    uint128 public reserve1;

    /// @notice Fees earned by the hook and not yet collected.
    /// @dev Held here rather than pushed on each swap. Pushing would let a
    ///      hook that cannot receive its own fee revert the swap, which is the
    ///      one power this design refuses to grant. Accrued balances are netted
    ///      out of `_available`, so they are never mistaken for a deposit or a
    ///      swap input.
    uint128 public hookOwed0;
    uint128 public hookOwed1;

    /// @notice Fees earned by the creator and not yet collected. Held and
    ///         netted out exactly as the hook's are.
    uint128 public creatorOwed0;
    uint128 public creatorOwed1;

    error Bad();
    error Overflow();
    error Reentrancy();
    error ZeroAmount();
    error InvalidToken();
    error NotHook();
    error NotFeeRecipient();
    error NotFactory();
    error LegacyPrefundDisabled();
    error BalanceDeficit();
    error UnsupportedToken();
    error PriceOutOfRange();
    error InsufficientOutput();
    error InsufficientLiquidity();

    event Swap(address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to);
    event HookFee(address indexed tokenIn, uint256 amount, uint256 extraFee);
    event HookFeeCollected(address indexed to, uint256 amount0, uint256 amount1);
    event CreatorFeeCollected(address indexed to, uint256 amount0, uint256 amount1);
    /// @dev Emitted when the advisory call failed, so a silently broken hook
    ///      is visible on-chain to whoever operates it.
    event HookCallFailed(address indexed hook);
    event AddLiquidity(address indexed provider, uint256 amount0, uint256 amount1, uint256 lp);
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

    /// @dev The factory validates these; see PrecisionPoolFactory. They are
    ///      re-checked here so a pool deployed by hand cannot divide by zero.
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
        if (factory_ == address(0)) revert Bad();
        if (token0_ >= token1_ || token1_ == address(0)) revert Bad();
        if (sqrtPLow_ == 0 || sqrtPHigh_ <= sqrtPLow_) revert Bad();
        // `extraFee` reserves the difference up to `MAX_TOTAL_FEE`; permitting
        // a direct deployment above that ceiling would underflow that room.
        if (fee_ >= MAX_TOTAL_FEE) revert Bad();
        (factory, token0, token1, sqrtPLow, sqrtPHigh, fee) = (factory_, token0_, token1_, sqrtPLow_, sqrtPHigh_, fee_);
        hook = hook_;
        // A share with nobody to pay would burn the fee, so it is refused. The
        // reverse is legitimate and deliberately allowed: a pool may name its
        // creator while taking no split at all, which is how a surcharge hook
        // learns who to pay and who may configure it.
        if (creatorFeeBps_ > MAX_CREATOR_SHARE) revert Bad();
        if (creatorFeeBps_ != 0 && feeRecipient_ == address(0)) revert Bad();
        (feeRecipient, creatorFeeBps) = (feeRecipient_, creatorFeeBps_);
    }

    /// @dev Native input is accepted only by an exact-input entry point. A
    ///      naked transfer would otherwise become anonymous balance surplus.
    receive() external payable {
        revert Bad();
    }

    /// @notice Current price as a sqrt, raw token1 per raw token0, scaled 1e18.
    /// @dev Derived from the virtual reserves, so it is the price a marginal
    ///      trade actually executes against rather than a stored number that
    ///      could drift from them.
    function sqrtPriceCurrent() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        uint256 vX = _virtual0(supply, sqrtPHigh) + reserve0;
        if (vX == 0) return 0;
        return
            FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(_virtual1(supply, sqrtPLow) + reserve1, WAD * WAD, vX));
    }

    function _virtual0(uint256 liquidity, uint256 hi) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(liquidity, WAD, hi);
    }

    function _virtual1(uint256 liquidity, uint256 lo) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(liquidity, lo, WAD);
    }

    // -------------------------------------------------------------------- SWAP

    /// @notice Disabled legacy balance-delta entry point.
    /// @dev A standalone ERC-20 transfer followed by this call can be
    ///      front-run by a different caller. Use `swapExactIn` directly or the
    ///      factory's atomic executor path instead.
    function swap(address tokenIn, uint256 minOut, address to) public payable returns (uint256 amountOut) {
        (tokenIn, minOut, to);
        revert LegacyPrefundDisabled();
    }

    /// @notice Pull exactly `amountIn` from the caller and settle the swap.
    /// @dev The safe direct path. ERC-20 input and accounting occur in one
    ///      transaction, so no untrusted caller can claim a prefunded balance.
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
        return _swapExact(tokenIn, zeroForOne, amountIn, minOut, to);
    }

    /// @notice Settle an exact amount already forwarded by this pool's factory.
    /// @dev Used by `PrecisionPoolFactory` as a zRouter executor. The factory
    ///      transfers or forwards exactly the amount and this function never
    ///      treats older balance surplus as a new trade.
    function swapFromFactory(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.sender != factory) revert NotFactory();
        bool zeroForOne = _direction(tokenIn);
        if (amountIn == 0) revert ZeroAmount();
        if (zeroForOne && token0 == address(0)) {
            if (msg.value != amountIn) revert Bad();
        } else if (msg.value != 0) {
            revert Bad();
        }
        return _swapExact(tokenIn, zeroForOne, amountIn, minOut, to);
    }

    function _swapExact(address tokenIn, bool zeroForOne, uint256 amountIn, uint256 minOut, address to)
        internal
        returns (uint256 amountOut)
    {
        if (to == address(0) || to == address(this)) revert Bad();
        _assertBacked();

        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        uint256 supply = totalSupply();
        if (supply == 0) revert InsufficientLiquidity();

        (uint256 rIn, uint256 rOut, uint256 vIn, uint256 vOut) = zeroForOne
            ? (r0, r1, _virtual0(supply, sqrtPHigh), _virtual1(supply, sqrtPLow))
            : (r1, r0, _virtual1(supply, sqrtPLow), _virtual0(supply, sqrtPHigh));

        // Surplus from a forced or mistaken transfer is deliberately left
        // unaccounted. Only the exact amount authenticated by the caller or
        // factory is eligible to move the curve.
        if (_available(zeroForOne ? token0 : token1) < rIn + amountIn) revert BalanceDeficit();

        // The hook is paid only the slice it asked for, off the top; the pool
        // then charges its own fee on what remains, so an LP's terms are
        // exactly what the pool advertises no matter what the hook does.
        uint256 hookCut = FixedPointMathLib.fullMulDiv(amountIn, _extraFee(tokenIn, amountIn), FEE_DENOM);
        uint256 net = amountIn - hookCut;

        // The creator's cut comes out of the fee the pool already charges, so
        // `inAfterFee` - and therefore the price - is untouched by it.
        uint256 feeAmount = FixedPointMathLib.fullMulDiv(net, fee, FEE_DENOM);
        uint256 creatorCut = FixedPointMathLib.fullMulDiv(feeAmount, creatorFeeBps, BPS);

        uint256 inAfterFee = net - feeAmount;
        amountOut = FixedPointMathLib.fullMulDiv(inAfterFee, rOut + vOut, rIn + vIn + inAfterFee);

        // Past the edge of the range the pool holds only one asset. Refuse
        // rather than clamp, so the caller learns the range is exhausted.
        if (amountOut > rOut) revert InsufficientOutput();
        if (amountOut < minOut) revert InsufficientOutput();

        if (hookCut != 0) _accrueHookFee(zeroForOne, hookCut, tokenIn, amountIn);
        if (creatorCut != 0) _accrueCreatorFee(zeroForOne, creatorCut);

        // Reserves keep the input less both cuts. Since each cut is bounded by
        // the fee, what remains is still at least `inAfterFee`, so the pool
        // never grows by less than the price it just quoted assumed.
        uint256 kept = net - creatorCut;
        if (zeroForOne) {
            _setReserves(rIn + kept, rOut - amountOut);
            _pay(token1, to, amountOut);
        } else {
            _setReserves(rOut - amountOut, rIn + kept);
            _pay(token0, to, amountOut);
        }

        emit Swap(tokenIn, amountIn, amountOut, to);
        _afterSwap(tokenIn, amountIn, amountOut, to);
    }

    function _direction(address tokenIn) internal view returns (bool zeroForOne) {
        zeroForOne = tokenIn == token0;
        if (!zeroForOne && tokenIn != token1) revert InvalidToken();
    }

    /// @notice The hook's surcharge for this trade, in pips, already clamped.
    /// @dev Gas-capped and failure-tolerant, exactly like the observer: a hook
    ///      that reverts, burns its budget, or answers with a short word is
    ///      read as charging nothing rather than as a reason to fail the swap.
    ///      The clamp is what bounds a hostile answer - and a hook that wants
    ///      to turn flow away can simply price at the ceiling, which is access
    ///      control without the power to brick anything.
    function extraFee(address sender, address tokenIn, uint256 amountIn) public view returns (uint256) {
        address h = hook;
        if (h == address(0)) return 0;
        bytes memory data = abi.encodeCall(IPrecisionHook.feeFor, (sender, tokenIn, amountIn));
        uint256 budget = HOOK_GAS;
        bool ok;
        uint256 answer;
        assembly ("memory-safe") {
            let m := mload(0x40)
            ok := staticcall(budget, h, add(data, 0x20), mload(data), m, 0x20)
            ok := and(ok, eq(returndatasize(), 0x20))
            answer := mload(m)
        }
        if (!ok) return 0;
        uint256 room = MAX_TOTAL_FEE - fee;
        return answer > room ? room : answer;
    }

    function _extraFee(address tokenIn, uint256 amountIn) internal view returns (uint256) {
        return extraFee(msg.sender, tokenIn, amountIn);
    }

    function _accrueHookFee(bool zeroForOne, uint256 cut, address tokenIn, uint256 amountIn) internal {
        if (zeroForOne) {
            uint256 owed = hookOwed0 + cut;
            if (owed > type(uint128).max) revert Overflow();
            hookOwed0 = uint128(owed);
        } else {
            uint256 owed = hookOwed1 + cut;
            if (owed > type(uint128).max) revert Overflow();
            hookOwed1 = uint128(owed);
        }
        emit HookFee(tokenIn, cut, FixedPointMathLib.fullMulDiv(cut, FEE_DENOM, amountIn));
    }

    function _accrueCreatorFee(bool zeroForOne, uint256 cut) internal {
        if (zeroForOne) {
            uint256 owed = creatorOwed0 + cut;
            if (owed > type(uint128).max) revert Overflow();
            creatorOwed0 = uint128(owed);
        } else {
            uint256 owed = creatorOwed1 + cut;
            if (owed > type(uint128).max) revert Overflow();
            creatorOwed1 = uint128(owed);
        }
    }

    /// @notice Recipient-only. Sweeps the creator's accrued share.
    function collectCreatorFees(address to) external nonReentrant returns (uint256 a0, uint256 a1) {
        if (msg.sender != feeRecipient) revert NotFeeRecipient();
        if (to == address(0) || to == address(this)) revert Bad();
        _assertBacked();
        (a0, a1) = (creatorOwed0, creatorOwed1);
        (creatorOwed0, creatorOwed1) = (0, 0);
        if (a0 != 0) _pay(token0, to, a0);
        if (a1 != 0) _pay(token1, to, a1);
        emit CreatorFeeCollected(to, a0, a1);
    }

    /// @notice Hook-only. Sweeps what the hook has earned.
    /// @dev Pulled rather than pushed, so the pool never depends on the hook
    ///      being able to receive anything.
    function collectHookFees(address to) external nonReentrant returns (uint256 a0, uint256 a1) {
        if (msg.sender != hook) revert NotHook();
        if (to == address(0) || to == address(this)) revert Bad();
        _assertBacked();
        (a0, a1) = (hookOwed0, hookOwed1);
        (hookOwed0, hookOwed1) = (0, 0);
        if (a0 != 0) _pay(token0, to, a0);
        if (a1 != 0) _pay(token1, to, a1);
        emit HookFeeCollected(to, a0, a1);
    }

    /// @dev Reached only once the swap is fully settled - reserves written and
    ///      output paid - and still inside the reentrancy guard, so a hook that
    ///      calls back cannot re-enter. Success is deliberately not checked:
    ///      see the note on immutability in the contract header.
    function _afterSwap(address tokenIn, uint256 amountIn, uint256 amountOut, address to) internal {
        address h = hook;
        if (h == address(0)) return;
        bytes memory data = abi.encodeCall(IPrecisionHook.afterSwap, (msg.sender, tokenIn, amountIn, amountOut, to));
        uint256 budget = HOOK_GAS;
        bool ok;
        assembly ("memory-safe") {
            ok := call(budget, h, 0, add(data, 0x20), mload(data), codesize(), 0x00)
        }
        if (!ok) emit HookCallFailed(h);
    }

    // --------------------------------------------------------------- LIQUIDITY

    /// @notice Disabled legacy balance-delta deposit entry point.
    /// @dev Use `addLiquidityExact` directly or `PrecisionPoolFactory.seed`.
    function addLiquidity(uint256 sqrtPriceInit, uint256 minLP, address to, address refundTo)
        public
        payable
        returns (uint256 lp, uint256 used0, uint256 used1)
    {
        (sqrtPriceInit, minLP, to, refundTo);
        revert LegacyPrefundDisabled();
    }

    /// @notice Pull both sides from the caller and mint LP shares atomically.
    /// @param amount0 Exact token0 amount to pull (or exact `msg.value` when
    ///        token0 is native ETH).
    /// @param amount1 Exact token1 amount to pull.
    /// @notice Deposit both sides and mint LP shares.
    /// @param sqrtPriceInit Price to seed at, read only while the pool is empty
    ///        and ignored entirely afterwards.
    /// @param to Receives the LP shares.
    function addLiquidityExact(uint256 sqrtPriceInit, uint256 amount0, uint256 amount1, uint256 minLP, address to)
        external
        payable
        nonReentrant
        returns (uint256 lp, uint256 used0, uint256 used1)
    {
        if (to == address(0) || to == address(this)) revert Bad();
        if (token0 == address(0)) {
            if (msg.value != amount0) revert Bad();
        } else {
            if (msg.value != 0) revert Bad();
            _pullExact(token0, msg.sender, amount0);
        }
        _pullExact(token1, msg.sender, amount1);
        return _addLiquidity(sqrtPriceInit, amount0, amount1, minLP, to, msg.sender);
    }

    /// @notice Mint against assets forwarded atomically by the factory.
    /// @dev The factory transfers both declared ERC-20 amounts and forwards
    ///      the declared native amount in this same call.
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
        _assertBacked();

        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        // A forced or mistaken transfer is not part of this mint. As with
        // swaps, crediting generic balance surplus would let a later caller
        // convert somebody else's donation into LP shares.
        uint256 in0 = amount0;
        uint256 in1 = amount1;
        if (_available(token0) < r0 + in0 || _available(token1) < r1 + in1) {
            revert BalanceDeficit();
        }

        uint256 supply = totalSupply();
        if (supply == 0) {
            // Inclusive, unlike a strict interior check: seeding AT a bound is
            // the one-sided case, and it is a feature rather than a degenerate
            // input. See _seed.
            if (sqrtPriceInit < sqrtPLow || sqrtPriceInit > sqrtPHigh) revert PriceOutOfRange();
            (lp, used0, used1) = _seed(in0, in1, sqrtPLow, sqrtPHigh, sqrtPriceInit);
            if (lp <= MIN_LIQUIDITY) revert InsufficientLiquidity();
            unchecked {
                lp -= MIN_LIQUIDITY;
            }
            _mint(address(0xdead), MIN_LIQUIDITY);
        } else {
            (lp, used0, used1) = _proportional(in0, in1, r0, r1, supply);
        }

        if (lp < minLP) revert InsufficientLiquidity();
        _setReserves(r0 + used0, r1 + used1);
        _mint(to, lp);

        // Refund after reserves are written, so a token or recipient that
        // calls back sees books that already account for the deposit. The
        // reentrancy guard is still held here.
        if (in0 > used0) _pay(token0, refundTo, in0 - used0);
        if (in1 > used1) _pay(token1, refundTo, in1 - used1);

        emit AddLiquidity(to, used0, used1, lp);
    }

    /// @dev L from each side independently; the smaller binds. Every step is a
    ///      mulDiv whose operands stay inside 256 bits for any range the
    ///      factory will accept.
    ///
    ///      SEEDING AT A BOUND IS A ONE-SIDED POSITION, AND IS SUPPORTED. At
    ///      `sl` the token1 requirement is zero and the pool holds only
    ///      token0, which it will sell as the price rises through the band; at
    ///      `sh` the mirror. That is a limit order - except that it collects
    ///      the swap fee for as long as it waits, and its claim is a fungible
    ///      ERC-20 rather than a position that has to be managed.
    ///
    ///      The general expressions below already yield zero on the unused
    ///      side, so only their divisors need avoiding: `s - sl` is zero at the
    ///      low bound and `sh - s` at the high one. Nothing else is special
    ///      about the edges.
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

        // Round the requirement up, so the pool is never left short of the
        // liquidity it just minted against.
        // Both go to zero of their own accord at the corresponding bound.
        used0 = FixedPointMathLib.fullMulDivUp(FixedPointMathLib.fullMulDivUp(lp, sh - s, sh), WAD, s);
        used1 = FixedPointMathLib.fullMulDivUp(lp, s - sl, WAD);
        if (used0 > in0 || used1 > in1) revert InsufficientLiquidity();
    }

    /// @dev Struck at the pool's own reserve ratio, so a deposit cannot move
    ///      the price and the seed argument is irrelevant here.
    function _proportional(uint256 in0, uint256 in1, uint256 r0, uint256 r1, uint256 supply)
        internal
        pure
        returns (uint256 lp, uint256 used0, uint256 used1)
    {
        // At a range boundary one side is empty and cannot bind.
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
        _assertBacked();

        uint256 supply = totalSupply();
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;

        // Rounds down, so the dust stays with the holders who remain.
        amount0 = FixedPointMathLib.fullMulDiv(lp, r0, supply);
        amount1 = FixedPointMathLib.fullMulDiv(lp, r1, supply);
        if (amount0 < min0 || amount1 < min1) revert InsufficientOutput();

        _burn(msg.sender, lp);
        _setReserves(r0 - amount0, r1 - amount1);

        if (amount0 != 0) _pay(token0, to, amount0);
        if (amount1 != 0) _pay(token1, to, amount1);

        emit RemoveLiquidity(msg.sender, lp, amount0, amount1);
    }

    // ----------------------------------------------------------------- ERC-20

    /// @dev One implementation per market would let these name the pair, but
    ///      building strings on-chain means trusting two `symbol()` calls that
    ///      may be missing or bytes32. The pair is `token0`/`token1`; a
    ///      frontend reads them and labels the position itself.
    function name() public pure override returns (string memory) {
        return "Precision LP";
    }

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

    function _assertBacked() internal view {
        uint256 required0 = uint256(reserve0) + hookOwed0 + creatorOwed0;
        uint256 required1 = uint256(reserve1) + hookOwed1 + creatorOwed1;
        if (_balance(token0) < required0 || _balance(token1) < required1) revert BalanceDeficit();
    }

    /// @dev What the pool may treat as its own. Fees the hook has earned sit
    ///      in the same balance until collected, and counting them as a
    ///      deposit or a swap input would pay them out twice.
    function _available(address token) internal view returns (uint256) {
        uint256 owed = token == token0 ? uint256(hookOwed0) + creatorOwed0 : uint256(hookOwed1) + creatorOwed1;
        return _balance(token) - owed;
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (to == address(0) || to == address(this)) revert Bad();
        if (token == address(0)) {
            to.safeTransferETH(amount);
            return;
        }

        uint256 senderBefore = token.balanceOf(address(this));
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
