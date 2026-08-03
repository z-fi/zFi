// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

/// @title Collectol
/// @notice zRouter snwap forwarder for a zFi collector DAO, so the continuous
///         share sale and the DAO's zAMM pool can be bought in one atomic route
///         - and so any ERC-20, not just ETH, can reach either of them.
///
/// @dev WHY THIS EXISTS. A collector DAO sells shares two ways: a continuous
///      sale that mints at a fixed rate against a DAO allowance, and an ordinary
///      zAMM pool whose price moves with size. Neither is strictly better. The
///      sale is a flat line; the pool is a curve that can sit below that line
///      after someone sells into it. The best execution is therefore usually a
///      split - take the pool down to the sale's rate, then mint the remainder -
///      and a split has to happen inside one call to be atomic.
///
///      Both venues are ETH-priced. An ERC-20 route is the caller's ordinary
///      zQuoter leg to ETH in front of this one; no token pricing happens here.
///      Funding arrives as native value or as WETH - see below for why both.
///
///      THE TRUST MODEL IS zROUTER'S, NOT THIS CONTRACT'S. snwap funds this
///      executor, calls it through SafeExecutor (which holds no approvals), then
///      measures `recipient`'s tokenOut balance and reverts unless it grew by at
///      least amountOutMin. A bug or a hostile venue can at worst under-deliver,
///      and the router rejects that. `minTotalOut` below is a second, local copy
///      of the same check so a direct caller who is not going through snwap is
///      protected too.
///
///      THERE ARE NO CALLDATA-CHOSEN TARGETS. Sibling forwarders take a venue
///      address and validate it against immutable bindings. Here both venues -
///      the sale and the ZAMM singleton - are fixed at construction, and the
///      pool is derived from `shares` read off the sale itself. Calldata selects
///      only amounts. That removes the whole class of "relabel an arbitrary
///      contract as the venue" argument, so no selector firewall is needed.
///
///      NO APPROVALS ARE EVER GRANTED. Input is ETH and output is an ERC-20 the
///      venues push to this contract. Nothing here can be pulled, so unlike
///      Swapbol there is no scoped-approval dance to get right.
///
///      WETH IS ACCEPTED AS FUNDING BECAUSE snwap CANNOT SEND ETH TWICE. snwap
///      funds a native-input route from `msg.value`, and every delegatecalled
///      entry in a zRouter multicall observes the same `msg.value` - which is
///      zero when the user is paying an ERC-20. Its other funding path, the one
///      that hands the executor the router's own balance, moves ERC-20s. So a
///      token route can only reach this contract as WETH: leg 1 converts to ETH,
///      the router wraps it, and `snwap(WETH, 0, ...)` sweeps it here. Everything
///      held in WETH is unwrapped on entry and spent as ETH.
///
///      Both venues are still ETH-priced; WETH is purely how the funds arrive.
///
///      OUTPUT IS MEASURED, NOT ASSUMED. The sale's rate is a bytecode constant
///      with no getter on the deployed instance, so this contract never computes
///      what it should receive - it takes both legs' output to itself and pays
///      out the measured balance delta. Shares donated to this address before
///      the call are outside the delta and stay stuck here rather than being
///      swept to whoever calls next.
///
///      REENTRANCY. The sale transfers a Moloch shares token and zAMM pays out
///      the same token; neither should hand control to an attacker, and both
///      have their own guards. The transient guard is kept anyway because the
///      sweeps below pay a caller-supplied recipient, which is exactly the shape
///      that turns a stray callback into a theft of mid-settlement funds.
contract Collectol {
    /// @dev zAMM v1 (hooked). A deployment trust root, not a calldata hint.
    address constant ZAMM = 0x000000000000040470635EB91b7CE4D132D616eD;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Continuous share sale. `buy()` is payable, mints at a fixed rate
    ///         against the DAO's allowance, and pays `msg.sender` - this contract.
    address public immutable sale;

    /// @notice The DAO's shares token: this route's only output.
    address public immutable shares;

    /// @notice feeOrHook of the (ETH, shares) zAMM pool. 30 for an ordinary
    ///         30bps pool; a hooked pool packs its hook address here.
    uint256 public immutable feeOrHook;

    /// @notice Precomputed zAMM pool id for (ETH, shares, feeOrHook).
    uint256 public immutable poolId;

    /// @dev Transient reentrancy flag. `uint32(bytes4(keccak256("Reentrancy()")))`.
    uint256 constant REENTRANCY_GUARD_SLOT = 0xab143c06;

    error Reentrancy();
    error ETHTransferFailed();

    error BadPlan();
    error BadVenue();
    error DeadlineExpired();
    error InsufficientOutput(uint256 expected, uint256 actual);
    error InputMismatch(uint256 expected, uint256 actual);

    /// @param sale_ The collector DAO's continuous sale.
    /// @param feeOrHook_ The (ETH, shares) zAMM pool's feeOrHook.
    /// @dev `shares` is read from the sale rather than passed in, so the two can
    ///      never disagree. The pool is required to exist at construction: a
    ///      pool-leg amount against an empty pool would revert anyway, and
    ///      catching it here means a misconfigured deployment cannot be used at
    ///      all rather than failing later on one path only.
    constructor(address sale_, uint256 feeOrHook_) {
        if (sale_ == address(0) || sale_.code.length == 0) revert BadVenue();
        address shares_ = IContinuousSale(sale_).shares();
        if (shares_ == address(0) || shares_.code.length == 0) revert BadVenue();

        sale = sale_;
        shares = shares_;
        feeOrHook = feeOrHook_;

        // ETH is address(0), so it always sorts as token0 and both ids are 0.
        uint256 id = uint256(keccak256(abi.encode(uint256(0), uint256(0), address(0), shares_, feeOrHook_)));
        (uint112 reserve0, uint112 reserve1,,,,,) = IZAMM(ZAMM).pools(id);
        if (reserve0 == 0 || reserve1 == 0) revert BadVenue();
        poolId = id;
    }

    /// @notice Buy shares from the continuous sale, the zAMM pool, or both.
    /// @dev Call through zRouter.snwap, with `tokenOut` = `shares` and
    ///      `amountOutMin` = the protected total. On a native route pass
    ///      `tokenIn` = address(0) and `amountIn` = the plan's ETH budget. On a
    ///      token route wrap leg 1's output and pass `tokenIn` = WETH with
    ///      `amountIn` = 0, which sweeps the router's WETH here. The split itself
    ///      is quoted off-chain (see CollectolLens): this contract executes a
    ///      plan, it does not choose one.
    ///
    ///      Both legs deliver here and the payout is one measured transfer, so
    ///      the caller's guarantee is over the total rather than per venue. That
    ///      matters for the split: `poolLimit` alone would let a sandwiched pool
    ///      leg pass its own check while the combined output still came up short.
    ///
    /// @param ethToSale     ETH minted through `sale.buy()`. Zero to skip the leg
    ///                      - which is what a caller must pass while the sale is
    ///                      paused, past its deadline, or out of DAO allowance.
    /// @param poolAmount    Exact ETH in for an exact-in pool leg, or exact
    ///                      shares out for an exact-out one. Zero skips the leg.
    /// @param poolLimit     Minimum shares out (exact-in) or maximum ETH in
    ///                      (exact-out). Per-leg protection; see above for why
    ///                      `minTotalOut` is the one that actually binds.
    /// @param poolExactOut  Which of the two shapes `poolAmount` is.
    /// @param minTotalOut   Minimum shares delivered across both legs.
    /// @param recipient     Final owner of the shares.
    /// @param refundTo      Where unspent ETH goes. Deliberately independent of
    ///                      `recipient`: on an exact-out route the change belongs
    ///                      to whoever funded it, who is not always the payee.
    /// @param deadline      Passed to zAMM and checked here. Must be non-zero.
    function buy(
        uint256 ethToSale,
        uint256 poolAmount,
        uint256 poolLimit,
        bool poolExactOut,
        uint256 minTotalOut,
        address recipient,
        address refundTo,
        uint256 deadline
    ) public payable {
        _enter();
        // No open-ended deadline. Sibling forwarders read zero as "unbounded",
        // but zAMM reads it as expired, so accepting it here would leave the
        // pool leg dead on a value the caller was told meant no limit.
        if (deadline == 0 || block.timestamp > deadline) revert DeadlineExpired();
        if (
            recipient == address(0) || recipient == address(this) || refundTo == address(0) || refundTo == address(this)
                || (ethToSale == 0 && poolAmount == 0)
        ) revert BadPlan();

        // Measured before the unwrap, so ETH already sitting here stays out of
        // this call's budget and is not spendable as someone else's change.
        uint256 ethBase = address(this).balance - msg.value;
        uint256 outputBase = balanceOf(shares);

        // snwap hands over WETH rather than value on a token route. Unwrapping
        // the whole balance rather than a caller-declared amount keeps this
        // ungriefable: an exact-match requirement would let anyone break every
        // route by donating a single wei. The cost of that choice is that WETH
        // donated here funds the next caller's trade instead of sitting idle -
        // a gift to a stranger, never a loss to a user, and any part of it left
        // unspent leaves with the ETH refund below.
        _unwrapAllWETH();

        // Exact-out spends up to `poolLimit`; zAMM refunds the difference, which
        // the ETH sweep returns to `refundTo`. Budgeting the maximum keeps the
        // value bound to the plan either way: this contract never spends ETH it
        // was not handed for this call.
        uint256 poolBudget;
        if (poolAmount != 0) poolBudget = poolExactOut ? poolLimit : poolAmount;
        else if (poolLimit != 0) revert BadPlan();

        // Funding is whatever arrived for this call, from either door: `msg.value`
        // on a native route, unwrapped WETH on a token route. It only has to
        // cover the plan - the overshoot from leg 1 landing above its quoted
        // floor is normal, and `_sendEthDelta` returns it to `refundTo` rather
        // than letting it be spent on a bigger position than was quoted.
        uint256 available = address(this).balance - ethBase;
        uint256 planned = ethToSale + poolBudget;
        if (available < planned) revert InputMismatch(planned, available);

        // All-or-nothing against the DAO's remaining share allowance: the sale
        // reverts rather than filling what it can, so a leg sized past that
        // ceiling takes the pool leg down with it. Whoever quotes the split caps
        // it (CollectolLens.maxSaleEth). Someone else draining the allowance
        // between quote and execution therefore costs a failed transaction, not
        // funds - the same exposure as any pool that moves under a quote.
        if (ethToSale != 0) IContinuousSale(sale).buy{value: ethToSale}();

        if (poolAmount != 0) {
            // token0 = ETH, token1 = shares, so buying shares is zeroForOne.
            IZAMM.PoolKey memory key =
                IZAMM.PoolKey({id0: 0, id1: 0, token0: address(0), token1: shares, feeOrHook: feeOrHook});
            if (poolExactOut) {
                IZAMM(ZAMM).swapExactOut{value: poolBudget}(key, poolAmount, poolLimit, true, address(this), deadline);
            } else {
                IZAMM(ZAMM).swapExactIn{value: poolBudget}(key, poolAmount, poolLimit, true, address(this), deadline);
            }
        }

        uint256 current = balanceOf(shares);
        if (current < outputBase) revert InsufficientOutput(outputBase, current);
        uint256 delta = current - outputBase;
        if (delta < minTotalOut) revert InsufficientOutput(minTotalOut, delta);
        if (delta != 0) safeTransfer(shares, recipient, delta);

        _sendEthDelta(ethBase, refundTo);
        _leave();
    }

    /// @dev Converts every WETH held here to ETH. Reverts if the withdrawal does
    ///      not deliver what it claimed, so a non-canonical or broken WETH cannot
    ///      quietly leave the route underfunded and let the plan proceed anyway.
    function _unwrapAllWETH() internal {
        uint256 amount = balanceOf(WETH);
        if (amount == 0) return;
        uint256 ethBefore = address(this).balance;
        IWETH(WETH).withdraw(amount);
        if (address(this).balance - ethBefore != amount) {
            revert InputMismatch(amount, address(this).balance - ethBefore);
        }
    }

    function _sendEthDelta(uint256 ethBase, address to) internal {
        uint256 amount = address(this).balance > ethBase ? address(this).balance - ethBase : 0;
        if (amount == 0) return;
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
                revert(0x1c, 0x04)
            }
        }
    }

    function _enter() internal {
        assembly ("memory-safe") {
            if tload(REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_GUARD_SLOT, 1)
        }
    }

    function _leave() internal {
        assembly ("memory-safe") {
            tstore(REENTRANCY_GUARD_SLOT, 0)
        }
    }

    receive() external payable {}
}

interface IWETH {
    function withdraw(uint256 amount) external;
}

interface IContinuousSale {
    function shares() external view returns (address);
    function paused() external view returns (bool);
    function buy() external payable;
}

interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function pools(uint256 poolId) external view returns (uint112, uint112, uint32, uint256, uint256, uint256, uint256);

    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    function swapExactOut(
        PoolKey calldata poolKey,
        uint256 amountOut,
        uint256 amountInMax,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountIn);
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

function balanceOf(address token) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, address())
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(mload(0x20), and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20)))
    }
}
