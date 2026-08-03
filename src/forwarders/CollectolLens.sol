// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";

/// @title CollectolLens
/// @notice Quotes the best split between a collector DAO's continuous sale and
///         its zAMM pool, and returns it in the exact argument shape Collectol
///         takes. Read-only: it plans, Collectol executes.
///
/// @dev WHY A SPLIT AND NOT A PICK. The sale mints at a flat rate; the pool is a
///      constant-product curve. Buying entirely from whichever looks better at
///      spot is wrong in both directions. If the pool is cheaper at spot, size
///      eventually pushes it past the sale's flat rate, and everything bought
///      after that crossing point was overpaid. If the sale is cheaper at spot,
///      the pool is worse at every size and gets nothing. The optimum is the
///      crossing point itself: take the pool down to the sale's rate, mint the
///      rest. Both plans below solve for that point in closed form.
///
///      THE SALE RATE IS NOT READABLE. The deployed sale keeps its rate as a
///      bytecode constant with no getter, so `saleRate` - shares per 1e18 wei -
///      is an input here. Callers get it from `probeSaleRate` below, or from the
///      DAO's published terms. Feeding in a wrong rate cannot cost anyone funds:
///      it only produces a worse split, and Collectol's `minTotalOut` (echoed
///      back here as `minTotalOut`) is derived from the pool leg's real curve
///      plus the rate actually used, so a route that cannot deliver reverts.
///
///      PASS saleRate = 0 when the sale is paused or past its deadline. The
///      plans then route everything through the pool.
///
///      THE SALE IS ALL-OR-NOTHING AGAINST A DAO ALLOWANCE. `buy()` calls
///      `spendAllowance` for the full amount and reverts when the DAO has less
///      left, rather than filling what it can. A sale leg sized past that
///      ceiling therefore takes down the whole route, including a pool leg that
///      would have been fine on its own. `maxSaleEth` is that ceiling expressed
///      in ETH - remaining allowance divided by the rate - and both plans spill
///      everything above it into the pool. Pass type(uint256).max only when the
///      allowance is known not to bind.
contract CollectolLens {
    address constant ZAMM = 0x000000000000040470635EB91b7CE4D132D616eD;

    /// @dev zAMM takes feeOrHook as basis points out of BPS for an ordinary pool.
    uint256 constant BPS = 10000;

    error PoolMissing();
    error NoRoute();

    struct Plan {
        uint256 ethToSale;
        uint256 poolAmount;
        uint256 poolLimit;
        bool poolExactOut;
        uint256 minTotalOut;
        // Unprotected figures, for display only.
        uint256 totalOut;
        uint256 totalIn;
    }

    /// @notice Plan a buy of exactly `ethIn` wei.
    /// @param slippageBps Applied to the pool leg's output and to `minTotalOut`.
    ///        The sale leg is a fixed rate and cannot slip, so no allowance is
    ///        added for it - which is why a sale-heavy route keeps a tight bound
    ///        even at a slippage setting chosen for the pool.
    function planExactIn(
        address shares,
        uint256 feeOrHook,
        uint256 ethIn,
        uint256 saleRate,
        uint256 maxSaleEth,
        uint256 slippageBps
    ) public view returns (Plan memory plan) {
        (uint256 reserve0, uint256 reserve1) = reserves(shares, feeOrHook);
        if (ethIn == 0) revert NoRoute();

        uint256 ethToPool = _optimalPoolIn(reserve0, reserve1, feeOrHook, saleRate);
        if (ethToPool > ethIn) ethToPool = ethIn;
        // No sale to fall back on: the pool takes the whole order regardless of
        // where its marginal rate ends up.
        if (saleRate == 0) ethToPool = ethIn;
        // Allowance ceiling. The spill goes to the pool at whatever the curve
        // gives, which is worse than the flat rate but is the only fill left.
        if (ethIn - ethToPool > maxSaleEth) ethToPool = ethIn - maxSaleEth;

        uint256 poolOut = ethToPool == 0 ? 0 : _amountOut(ethToPool, reserve0, reserve1, feeOrHook);
        uint256 ethToSale = ethIn - ethToPool;
        uint256 saleOut = ethToSale * saleRate / 1e18;
        if (poolOut + saleOut == 0) revert NoRoute();

        plan.ethToSale = ethToSale;
        plan.poolAmount = ethToPool;
        plan.poolLimit = poolOut - (poolOut * slippageBps / BPS);
        plan.poolExactOut = false;
        plan.minTotalOut = saleOut + plan.poolLimit;
        plan.totalOut = saleOut + poolOut;
        plan.totalIn = ethIn;
    }

    /// @notice Plan a buy of exactly `sharesOut` shares.
    /// @dev The returned `totalIn` is the ETH to hand snwap: the sale leg is
    ///      exact, and the pool leg carries its own `poolLimit` maximum, so the
    ///      two sum to a real budget rather than an estimate. zAMM refunds the
    ///      unspent part of the pool leg and Collectol returns it to `refundTo`.
    function planExactOut(
        address shares,
        uint256 feeOrHook,
        uint256 sharesOut,
        uint256 saleRate,
        uint256 maxSaleEth,
        uint256 slippageBps
    ) public view returns (Plan memory plan) {
        (uint256 reserve0, uint256 reserve1) = reserves(shares, feeOrHook);
        if (sharesOut == 0) revert NoRoute();

        uint256 fromPool = _optimalPoolOut(reserve0, reserve1, feeOrHook, saleRate);
        if (fromPool > sharesOut) fromPool = sharesOut;
        if (saleRate == 0) fromPool = sharesOut;
        // Allowance ceiling, in shares this time. Rounding the mintable amount
        // down keeps the sale leg inside the allowance after the divUp below.
        if (saleRate != 0) {
            uint256 mintable = maxSaleEth == type(uint256).max
                ? type(uint256).max
                : FixedPointMathLib.fullMulDiv(maxSaleEth, saleRate, 1e18);
            if (sharesOut - fromPool > mintable) fromPool = sharesOut - mintable;
        }
        // Never quote out more than the curve can physically deliver.
        if (fromPool >= reserve1) revert NoRoute();

        uint256 poolIn = fromPool == 0 ? 0 : _amountIn(fromPool, reserve0, reserve1, feeOrHook);
        uint256 fromSale = sharesOut - fromPool;
        if (fromSale != 0 && saleRate == 0) revert NoRoute();
        // Round the sale leg up: minting `fromSale` at `saleRate` must not come
        // up a wei short of the requested total.
        uint256 ethToSale = fromSale == 0 ? 0 : FixedPointMathLib.divUp(fromSale * 1e18, saleRate);

        plan.ethToSale = ethToSale;
        plan.poolAmount = fromPool;
        plan.poolLimit = poolIn + (poolIn * slippageBps / BPS);
        plan.poolExactOut = true;
        plan.minTotalOut = sharesOut;
        plan.totalOut = sharesOut;
        plan.totalIn = ethToSale + plan.poolLimit;
    }

    /// @notice Measure the sale's shares-per-1e18-wei rate by buying and looking.
    /// @dev NOT a view: it spends ETH. Call it through `eth_call` with a balance
    ///      override on this address - the rate is a bytecode constant with no
    ///      getter, so simulating a purchase is the only way to read it. `probe`
    ///      should be small but not dust; the rate is linear, so any size that
    ///      the DAO allowance covers gives the same answer.
    function probeSaleRate(address sale, uint256 probe) public returns (uint256 rate) {
        if (probe == 0) revert NoRoute();
        address shares = IContinuousSale(sale).shares();
        uint256 before = IERC20(shares).balanceOf(address(this));
        IContinuousSale(sale).buy{value: probe}();
        rate = (IERC20(shares).balanceOf(address(this)) - before) * 1e18 / probe;
    }

    /// @notice How much ETH the sale can still absorb: the DAO's remaining share
    ///         allowance to the sale, converted at `saleRate`. Feed this to the
    ///         plans as `maxSaleEth`.
    /// @dev Rounds down, so the sale leg stays strictly inside the allowance.
    ///      Returns zero while the sale is paused - a paused sale absorbs nothing
    ///      no matter what the DAO has authorised.
    function maxSaleEth(address sale, uint256 saleRate) public view returns (uint256) {
        if (saleRate == 0 || IContinuousSale(sale).paused()) return 0;
        address dao = IContinuousSale(sale).dao();
        // Moloch keys share allowances under the DAO's own address as `token`.
        uint256 remaining = IMoloch(dao).allowance(dao, sale);
        return FixedPointMathLib.fullMulDiv(remaining, 1e18, saleRate);
    }

    /// @notice (ETH, shares) pool reserves. Reverts if the pool is empty, since
    ///         every plan below divides by them.
    function reserves(address shares, uint256 feeOrHook) public view returns (uint256 reserve0, uint256 reserve1) {
        uint256 poolId = uint256(keccak256(abi.encode(uint256(0), uint256(0), address(0), shares, feeOrHook)));
        (uint112 r0, uint112 r1,,,,,) = IZAMM(ZAMM).pools(poolId);
        if (r0 == 0 || r1 == 0) revert PoolMissing();
        (reserve0, reserve1) = (uint256(r0), uint256(r1));
    }

    /// @dev ETH into the pool at which its marginal rate falls to the sale's flat
    ///      rate. Solving d(out)/dx = saleRate/1e18 for x gives
    ///
    ///          x = (sqrt(f * BPS * r0 * r1 * 1e18 / saleRate) - BPS * r0) / f
    ///
    ///      where f = BPS - feeOrHook. A pool already at or above the sale's rate
    ///      makes the numerator negative, which is the "sale wins outright" case
    ///      and returns zero.
    ///
    ///      Every product under the root is taken with `fullMulDiv`, which keeps
    ///      the 512-bit intermediate. Written the obvious way this expression
    ///      overflows: reserves are uint112, so r0 * r1 alone reaches 2^224, and
    ///      the leading f * BPS factor of ~1e8 carries it past uint256. Ordering
    ///      the divide by `saleRate` before the multiply by 1e18 would avoid the
    ///      overflow but truncate the rate to zero for any realistic pool.
    function _optimalPoolIn(uint256 reserve0, uint256 reserve1, uint256 feeOrHook, uint256 saleRate)
        internal
        pure
        returns (uint256)
    {
        if (saleRate == 0) return 0;
        uint256 f = BPS - feeOrHook;
        uint256 inner = FixedPointMathLib.fullMulDiv(f * BPS * reserve0, reserve1 * 1e18, saleRate);
        uint256 root = FixedPointMathLib.sqrt(inner);
        uint256 base = BPS * reserve0;
        if (root <= base) return 0;
        return (root - base) / f;
    }

    /// @dev Shares out of the pool at which its marginal cost rises to the sale's
    ///      flat cost. Solving dx/dy = 1e18/saleRate for y gives
    ///
    ///          y = r1 - sqrt(BPS * r0 * r1 * saleRate / (f * 1e18))
    ///
    ///      Rounding the root up biases `y` down, so the split leans on the flat
    ///      sale rather than overshooting into the curve - the safe direction,
    ///      since only the pool leg can come back worse than quoted.
    function _optimalPoolOut(uint256 reserve0, uint256 reserve1, uint256 feeOrHook, uint256 saleRate)
        internal
        pure
        returns (uint256)
    {
        if (saleRate == 0) return 0;
        uint256 f = BPS - feeOrHook;
        uint256 inner = FixedPointMathLib.fullMulDiv(BPS * reserve0, reserve1 * saleRate, f * 1e18);
        uint256 root = FixedPointMathLib.sqrt(inner) + 1;
        if (root >= reserve1) return 0;
        return reserve1 - root;
    }

    function _amountOut(uint256 amountIn, uint256 reserve0, uint256 reserve1, uint256 feeOrHook)
        internal
        pure
        returns (uint256)
    {
        uint256 inAfterFee = amountIn * (BPS - feeOrHook);
        return FixedPointMathLib.fullMulDiv(inAfterFee, reserve1, reserve0 * BPS + inAfterFee);
    }

    function _amountIn(uint256 amountOut, uint256 reserve0, uint256 reserve1, uint256 feeOrHook)
        internal
        pure
        returns (uint256)
    {
        return FixedPointMathLib.fullMulDivUp(reserve0, amountOut * BPS, (reserve1 - amountOut) * (BPS - feeOrHook));
    }
}

interface IContinuousSale {
    function shares() external view returns (address);
    function dao() external view returns (address);
    function paused() external view returns (bool);
    function buy() external payable;
}

interface IMoloch {
    function allowance(address token, address spender) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IZAMM {
    function pools(uint256 poolId)
        external
        view
        returns (uint112, uint112, uint32, uint256, uint256, uint256, uint256);
}
