// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";
import {PrecisionPoolFactory} from "./PrecisionPoolFactory.sol";
import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";

/// @title PrecisionRouteL2
/// @notice Executes a multi-pool route as a SINGLE zRouter executor call.
///
/// @dev    WHY THIS EXISTS. A route composed as several snwap legs runs into
///         two properties of the router that are easy to get wrong and only
///         fail at submission:
///
///           - snwap forwards `msg.value` to every leg, so a multicall that
///             carries native ETH can contain at most one of them. Routes
///             starting in ETH could not be chained at all.
///           - a chained leg is funded from the router's balance and snwap
///             forwards `balance - 1`, retaining a wei. The factory settles an
///             exact declared amount, so the caller had to subtract that wei by
///             hand or be rejected.
///
///         Collapsing the route into one leg removes both. The router funds
///         this contract once, this contract walks the hops itself, and only
///         the final output is measured at the recipient - which is also the
///         only place slippage needs checking.
///
///         IT USES THE PUBLIC POOL ENTRY POINT. Hops go through
///         `swapExactIn`, which pulls exactly what it is told from this
///         contract. The factory-only settlements - `swapFromFactory` and
///         `swapUpToFromFactory` - are deliberately not used: this contract is
///         replaceable and should not need to be trusted by the pools. Note
///         `routeUpTo` does not reach for the pool's own `swapUpTo` either,
///         and for a separate reason: clamping per hop strands intermediates.
///         See `routeUpTo`.
///
///         FUNDING IS CHECKPOINTED AND BOUND, as everywhere else here. snwap
///         sends the input before calling, so a bare balance is not evidence of
///         this route's funding; a transient single-use checkpoint taken
///         immediately before makes only the fresh delta spendable, and it
///         commits to the hash of the call that will spend it, so the delta
///         cannot be diverted into a different route by anything that gets
///         control while the funding is in flight.
///
///         INTERMEDIATES NEVER REST HERE. Each hop pays the next, and the last
///         pays the recipient. A balance left behind would be claimable by
///         whoever routed next, so the checkpoint is what makes that safe even
///         if a token misbehaves.
///
///         THE LOCK SPANS THE WHOLE ROUTE, not each call within it - the same
///         arrangement the factory uses, for the same reason. The dangerous
///         interval is the one BETWEEN `checkpoint` and the call that consumes
///         it: the input arrives in that gap, and a callback-capable token gets
///         control there. A guard that clears when `checkpoint` returns leaves
///         the contract open for exactly that transfer. So `checkpoint` opens
///         the route and only the call that spends it closes it; while a route
///         is open, a native-funded entry - which consumes no checkpoint and so
///         would otherwise be unconstrained - is refused outright, and an
///         ERC-20-funded one must still match the committed intent. Nothing
///         reentrant can run while funds are resting here.
/// @dev L2 VARIANT. Identical to PrecisionRoute except that WETH is an immutable
///      constructor argument rather than a source constant, so one source serves
///      every chain the pool suite is mirrored to. It is still bound once, at
///      deployment, and never read from a caller - the property the constant
///      existed to guarantee is kept by the immutable. Mainnet keeps the original
///      PrecisionRoute, whose deployed bytecode still reproduces from its own
///      source; nothing here is meant to replace it there.
///
contract PrecisionRouteL2 {
    using SafeTransferLib for address;

    uint256 constant CHECKPOINT_SEED = 0x51c0de17;

    /// @dev Route lifecycle, held in transient storage for the transaction.
    ///      IDLE -> OPEN on `checkpoint`, -> SETTLING for the body of the call
    ///      that spends it, -> IDLE when that call returns. A native-funded
    ///      entry runs IDLE -> SETTLING -> IDLE with no checkpoint at all.
    uint256 constant _ROUTE_SLOT = 0x51c0de18;
    uint256 constant _ROUTE_IDLE = 0;
    uint256 constant _ROUTE_OPEN = 1;
    uint256 constant _ROUTE_SETTLING = 2;

    address public immutable trustedExecutor;
    PrecisionPoolFactory public immutable factory;

    /// @dev Canonical wrapper. A constant rather than an argument: taking it
    ///      from the caller would turn `routeFromWETH` into "call withdraw on
    ///      an address of your choosing".
    address public immutable WETH;

    error Bad();
    error NoPool();
    error Reentrancy();
    error NotExecutor();
    error BadCheckpoint();
    error HookedNoClamp();
    error WrongTokenOut();
    error IntentMismatch();
    error InsufficientOutput();

    event Routed(address indexed to, uint256 hops, uint256 amountIn, uint256 amountOut);

    constructor(PrecisionPoolFactory factory_, address trustedExecutor_, address weth_) {
        // The executor must be a contract. On an immutable deployment a
        // mistyped executor is unrecoverable, and an EOA there is never valid.
        // The same holds for WETH: `routeFromWETH` calls `withdraw` on it.
        if (address(factory_).code.length == 0 || trustedExecutor_.code.length == 0 || weth_.code.length == 0) {
            revert Bad();
        }
        (factory, trustedExecutor, WETH) = (factory_, trustedExecutor_, weth_);
    }

    /// @dev Open because the route legitimately receives ETH mid-walk: a hop
    ///      whose output is native pays this contract, and `routeUpTo` refunds
    ///      from here. It cannot distinguish those from an unsolicited send, so
    ///      ETH pushed in by anyone is STRANDED - inert, but unrecoverable.
    ///
    ///      DELIBERATELY NOT GIVEN A RESCUE PATH. The obvious fix, a sweep, is
    ///      the exact bug `zapIn` was fixed for: this contract holds other
    ///      people's funding during the interval between `checkpoint` and the
    ///      call that spends it, so anything that moves a raw balance out is a
    ///      way to take it. Gating a sweep on IDLE and on a privileged caller
    ///      would work, but it buys back dust by introducing an actor and an
    ///      invariant that the rest of this contract does not need - and the
    ///      safety story here is precisely that nothing rests and nobody is
    ///      trusted with what does. Stranded is the cheaper failure.
    ///
    ///      Nothing resting here affects a route. Every entry point spends what
    ///      it authenticated - `msg.value`, or a checkpointed delta - and
    ///      `zapIn`'s sweep is floored at the pre-call balance, so a stray
    ///      balance is never picked up and never paid out.
    receive() external payable {}

    function _routeState() internal view returns (uint256 state) {
        assembly ("memory-safe") {
            state := tload(_ROUTE_SLOT)
        }
    }

    function _setRouteState(uint256 state) internal {
        assembly ("memory-safe") {
            tstore(_ROUTE_SLOT, state)
        }
    }

    /// @dev Claims the route for the body of a funded entry point and releases
    ///      it on return. `needsCheckpoint` is true when the caller is funded by
    ///      an ERC-20 transfer that happened before this call: that requires an
    ///      open route, and `_consume` then checks the intent. A native-funded
    ///      caller consumes nothing, so it is only admissible from IDLE -
    ///      otherwise it could run during somebody else's funding gap.
    ///      SETTLING is never admissible: routes are not legitimately
    ///      concurrent, hops are sequential calls.
    modifier claimsRoute(bool needsCheckpoint) {
        uint256 state = _routeState();
        if (state != (needsCheckpoint ? _ROUTE_OPEN : _ROUTE_IDLE)) revert Reentrancy();
        _setRouteState(_ROUTE_SETTLING);
        _;
        _setRouteState(_ROUTE_IDLE);
    }

    /// @notice Snapshot this contract's balance before the executor funds it.
    /// @param intent `keccak256` of the exact `route` or `zapIn` calldata this
    ///        checkpoint is taken for.
    /// @param refundTo Where `abortCheckpoint` returns the funding if this
    ///        route is opened and then abandoned. Committed HERE rather than
    ///        supplied at abort time, which is what stops the abort from being
    ///        a redirection primitive; see `abortCheckpoint`.
    /// @dev The snapshot bounds HOW MUCH the next call may spend; the intent
    ///      bounds WHAT it may spend it on. Both are needed, because the input
    ///      arrives between this call and the one that consumes it: the
    ///      executor is publicly callable and holds no lock across that gap, so
    ///      a callback firing during the funding transfer could otherwise
    ///      consume this exact delta through `route` with pools, slippage and a
    ///      recipient of its own choosing - or through `zapIn`, which is a
    ///      different function entirely and would have been just as acceptable
    ///      to a checkpoint that only remembers a balance. Committing to the
    ///      calldata covers the entry point and every argument at once.
    function checkpoint(address token, bytes32 intent, address refundTo) external {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (token == address(0) || token.code.length == 0) revert Bad();
        if (intent == bytes32(0)) revert Bad();
        if (refundTo == address(0) || refundTo == address(this)) revert Bad();
        // At most one route exists at a time, so a reentrant checkpoint - or a
        // checkpoint taken while a route is mid-settlement - is rejected here
        // rather than relying on the per-token flag below to notice.
        if (_routeState() != _ROUTE_IDLE) revert Reentrancy();
        bytes32 slot = _slot(token);
        uint256 active;
        assembly ("memory-safe") {
            active := tload(slot)
        }
        if (active != 0) revert BadCheckpoint();
        _setRouteState(_ROUTE_OPEN);
        uint256 snap = token.balanceOf(address(this));
        assembly ("memory-safe") {
            tstore(slot, 1)
            tstore(add(slot, 1), snap)
            tstore(add(slot, 2), intent)
            tstore(add(slot, 3), refundTo)
        }
    }

    /// @notice Close an open route without spending it, returning the funding.
    /// @dev The counterpart to a settlement that cannot be made. Without it, an
    ///      executor that checkpoints, funds this contract, and then finds it
    ///      cannot call `route` - a hop that would revert, a clamp that came
    ///      back zero, a slippage bound it would rather handle than bubble -
    ///      has no way to give the tokens back. The transient checkpoint
    ///      disappears at the end of the transaction and the balance simply
    ///      stays here: inert, because every later route bases its own
    ///      checkpoint on the raised balance and `zapIn`'s sweep is floored, but
    ///      also unrecoverable. `PrecisionPoolFactory.abortCheckpoint` exists
    ///      for exactly this and this contract had the identical gap.
    ///
    ///      It refunds the balance delta observed since the checkpoint and
    ///      nothing else, so it returns this route's own funding and cannot
    ///      reach a pre-existing or stranded balance.
    ///
    ///      THE DESTINATION IS THE ONE COMMITTED AT CHECKPOINT, not an address
    ///      passed here. That is the whole reason `checkpoint` takes
    ///      `refundTo`: this function is reachable during the funding transfer
    ///      by anything the input token hands control to, so if it chose its own
    ///      recipient it would be a strictly easier theft than the settlement
    ///      path the intent commitment was built to close. As it stands, an
    ///      early abort can only hand the funding back to the party the route
    ///      already named, and it makes the outer `route` fail on a consumed
    ///      checkpoint - a revert rather than a loss.
    ///
    ///      Native-funded entries open no checkpoint and so have nothing to
    ///      abort; their input arrives with the settling call.
    /// @param token The input token checkpointed for the open route.
    /// @return refunded Amount handed back to the committed `refundTo`.
    function abortCheckpoint(address token) external returns (uint256 refunded) {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (_routeState() != _ROUTE_OPEN) revert BadCheckpoint();
        _setRouteState(_ROUTE_SETTLING);

        bytes32 slot = _slot(token);
        uint256 active;
        uint256 base;
        address to;
        assembly ("memory-safe") {
            active := tload(slot)
            base := tload(add(slot, 1))
            to := tload(add(slot, 3))
            tstore(slot, 0)
            tstore(add(slot, 1), 0)
            tstore(add(slot, 2), 0)
            tstore(add(slot, 3), 0)
        }
        if (active == 0) revert BadCheckpoint();

        uint256 current = token.balanceOf(address(this));
        if (current < base) revert BadCheckpoint();
        unchecked {
            refunded = current - base;
        }
        if (refunded != 0) token.safeTransfer(to, refunded);
        _setRouteState(_ROUTE_IDLE);
    }

    /// @notice Walk `pools` in order, starting from `amountIn` of `tokenIn`.
    /// @dev Native input arrives as msg.value; ERC-20 input must have been
    ///      checkpointed and then transferred here in the same transaction.
    /// @param tokenOut The asset the last hop must deliver. NOT redundant with
    ///        `pools`: the output token is otherwise implicit in the path, so a
    ///        reordered or off-by-one `pools` array silently delivers a
    ///        different asset and `minOut` is then denominated in the wrong
    ///        units - a 1e18 threshold against a 6-decimal token passes
    ///        trivially, and the slippage check protects nothing. Naming the
    ///        output makes the two agree or the call revert.
    /// @notice Route a WETH input into a NATIVE path, unwrapping on the way in.
    /// @dev THE ONE CONVERSION A CALLER CANNOT DO FOR THEMSELVES IN THE SAME
    ///      TRANSACTION. A market on ETH/TOKEN holds ether and cannot accept a
    ///      WETH allowance, so a holder of WETH had to unwrap in a transaction
    ///      of their own and then swap - two signatures for one trade, and the
    ///      page had to explain why the first one existed.
    ///
    ///      zRouter cannot bridge that gap either, and the reason is worth
    ///      recording because it looks like it should: `unwrap(uint256)` does
    ///      exist there and works, but `snwap` forwards `msg.value` to the
    ///      executor and nothing else - `safeExecutor.execute{value: msg.value}`
    ///      - so ether the router is holding after an in-multicall unwrap never
    ///      reaches this contract. Measured against the deployed router: deposit
    ///      + unwrap + snwap reverts `Bad()` here, on `msg.value != amountIn`.
    ///
    ///      What `snwap` DOES do is deliver an ERC-20 to the executor it was
    ///      told to call. So WETH arrives here as an ordinary token input, and
    ///      this unwraps it. One call, one signature, no conversion the user has
    ///      to be told about.
    ///
    ///      Checkpointed exactly as `route` is, and in the same order: the
    ///      snapshot is consumed - which is where the intent is checked against
    ///      the keccak of THIS calldata - BEFORE any ether exists. A caller who
    ///      could unwrap first and consume second would have a contract holding
    ///      ether against an unverified claim.
    ///
    ///      `WETH` is a constant, not an argument. Taking it from the caller
    ///      would make this "call withdraw on an address of your choosing",
    ///      which is a different and much worse function.
    function routeFromWETH(
        address[] calldata pools,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address to
    ) external claimsRoute(true) returns (uint256 amountOut) {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (pools.length == 0 || amountIn == 0) revert Bad();
        if (to == address(0) || to == address(this)) revert Bad();
        // Consume first: the intent covers this exact call, arguments included.
        _consume(WETH, amountIn);
        // Now it is ether, and `_walk` already knows how to spend that.
        (bool okw,) = WETH.call(abi.encodeWithSelector(0x2e1a7d4d, amountIn));
        if (!okw) revert Bad();

        address delivered;
        (amountOut, delivered) = _walk(pools, address(0), amountIn, to);
        if (delivered != tokenOut) revert WrongTokenOut();
        if (amountOut < minOut) revert InsufficientOutput();
        emit Routed(to, pools.length, amountIn, amountOut);
    }

    function route(
        address[] calldata pools,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address to
    ) external payable claimsRoute(tokenIn != address(0)) returns (uint256 amountOut) {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (pools.length == 0 || amountIn == 0) revert Bad();
        if (to == address(0) || to == address(this)) revert Bad();

        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert Bad();
        } else {
            if (msg.value != 0) revert Bad();
            _consume(tokenIn, amountIn);
        }

        address delivered;
        (amountOut, delivered) = _walk(pools, tokenIn, amountIn, to);
        if (delivered != tokenOut) revert WrongTokenOut();
        if (amountOut < minOut) revert InsufficientOutput();
        emit Routed(to, pools.length, amountIn, amountOut);
    }

    /// @notice Route AT MOST `amountIn`, filling to the tightest band on the
    ///         path and returning the remainder to `refundTo`.
    ///
    /// @dev The chained counterpart to the pool's `swapUpTo`, and the reason it
    ///      is not simply that function applied per hop.
    ///
    ///      CLAMP ONCE, AT THE FRONT. Letting each hop clamp itself is the
    ///      obvious construction and it is wrong: clamping hop `i>1` strands an
    ///      INTERMEDIATE token, something the caller never asked to hold and
    ///      cannot unwind without another transaction. Returning it converts a
    ///      clean revert into a silent bad position; swapping it back pays a
    ///      second fee and moves the price twice to undo work just done. So the
    ///      search runs over the ROUTE instead: find the largest starting
    ///      amount for which EVERY hop fits, then execute that route whole. The
    ///      remainder is then always `tokenIn`, and the intermediate case is not
    ///      handled so much as made unrepresentable.
    ///
    ///      Found by bisection, for the same reason `PrecisionPool._maxIn`
    ///      bisects rather than solving: composing per-hop boundary conditions
    ///      closed-form is worse than intractable, it is fragile.
    ///
    ///      What is bisected is the BAND, not executability. A pool's `fits` is
    ///      NOT monotone - it is the conjunction of a band condition that closes
    ///      as size grows and a zero-output refusal that opens as size grows, so
    ///      the fillable set is an interval and halving against it can step over
    ///      that interval entirely. Only the band half is monotone decreasing,
    ///      and it composes: each hop's room is monotone decreasing in its
    ///      input, output is monotone increasing in input, so hop `i`'s input is
    ///      monotone increasing in the route's and its room monotone decreasing
    ///      in it. See `_maxRouteIn`.
    ///
    ///      It is paid only on the clamping path: a route that fits whole
    ///      returns on the first probe. When it does bisect, it costs about
    ///      log2(amountIn) view walks of the path.
    ///
    ///      HOOKS. Each probe samples the hook at the size it is probing, and
    ///      execution then runs at exactly the size that was probed, so the
    ///      model is exact where the pool's own `_maxIn` had to refuse. A hook
    ///      whose surcharge is not monotone in size can still make the search
    ///      return a valid but suboptimal fill, and one that answers
    ///      differently between the probe and the swap makes the route revert -
    ///      no loss, and a property of a pool the caller chose.
    ///
    /// @param tokenOut The asset the last hop must deliver; see `route`.
    function routeUpTo(
        address[] calldata pools,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address to,
        address refundTo
    ) external payable claimsRoute(tokenIn != address(0)) returns (uint256 amountOut, uint256 consumed) {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (pools.length == 0 || amountIn == 0) revert Bad();
        if (to == address(0) || to == address(this)) revert Bad();
        if (refundTo == address(0) || refundTo == address(this)) revert Bad();

        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert Bad();
        } else {
            if (msg.value != 0) revert Bad();
            _consume(tokenIn, amountIn);
        }

        consumed = _maxRouteIn(pools, tokenIn, amountIn);
        if (consumed == 0) revert InsufficientOutput();

        address delivered;
        (amountOut, delivered) = _walk(pools, tokenIn, consumed, to);
        if (delivered != tokenOut) revert WrongTokenOut();
        if (amountOut < minOut) revert InsufficientOutput();

        // Always the caller's own input token, never an intermediate.
        if (consumed < amountIn) {
            unchecked {
                uint256 back = amountIn - consumed;
                if (tokenIn == address(0)) refundTo.safeTransferETH(back);
                else tokenIn.safeTransfer(refundTo, back);
            }
        }

        emit Routed(to, pools.length, consumed, amountOut);
    }

    /// @dev The hop loop, shared by `route` and `routeUpTo` so the executed
    ///      path cannot differ between them.
    /// @return amt The final hop's output amount.
    /// @return tin The asset that output is denominated in, returned rather
    ///         than assumed so the caller can hold the path to a named
    ///         `tokenOut`.
    function _walk(address[] calldata pools, address tokenIn, uint256 amountIn, address to)
        internal
        returns (uint256 amt, address tin)
    {
        tin = tokenIn;
        amt = amountIn;
        for (uint256 i; i < pools.length; ++i) {
            address pool = pools[i];
            if (!factory.isPool(pool)) revert NoPool();
            PrecisionPool p = PrecisionPool(payable(pool));

            address t0 = p.token0();
            address tout = tin == t0 ? p.token1() : t0;
            // The last hop pays the recipient; the rest pay this contract, so
            // no intermediate is ever left resting.
            address dst = i + 1 == pools.length ? to : address(this);

            if (tin == address(0)) {
                amt = p.swapExactIn{value: amt}(tin, amt, 0, dst);
            } else {
                tin.safeApproveWithRetry(pool, amt);
                amt = p.swapExactIn(tin, amt, 0, dst);
                tin.safeApproveWithRetry(pool, 0);
            }
            tin = tout;
        }
    }

    /// @dev Largest starting amount at or below `amountIn` that every hop
    ///      admits. Zero when even the smallest useful trade cannot clear the
    ///      path.
    ///
    ///      BISECTS THE BAND ALONE, NOT EXECUTABILITY. Whether a hop fills is
    ///      the conjunction of two conditions running in opposite directions:
    ///      the band closes as size grows, and the zero-output refusal opens as
    ///      size grows. The fillable set is therefore an INTERVAL `[a,b]`, not a
    ///      prefix, and halving against the conjunction can step straight over
    ///      it - probing above `b`, then below `a`, and concluding nothing fills
    ///      while every size in between would have. `PrecisionPool` documents
    ///      the same trap on `_transitionAt` and avoids it the same way.
    ///
    ///      So: bisect `_routeRoom`, which is monotone decreasing and genuinely
    ///      true at zero, to find `b`. Then test the zero-output half ONCE
    ///      there. Output is monotone increasing in size, so a zero at `b` means
    ///      no smaller size fills either, and `b` is the answer whenever any
    ///      size does.
    ///
    ///      THE TOKEN PATH IS RESOLVED ONCE, up front, and handed to every
    ///      probe. `token0`/`token1` are immutable per pool and the sequence of
    ///      assets a route touches does not depend on the size being probed, so
    ///      reading them inside the search would pay two cold external calls per
    ///      hop per probe - up to ~256 of them on a two-hop clamp, for answers
    ///      that cannot have changed. The probes then make exactly one call per
    ///      hop, the quote itself.
    function _maxRouteIn(address[] calldata pools, address tokenIn, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        address[] memory path = _path(pools, tokenIn);

        // Fast path: the whole request fits, so there is nothing to clamp.
        if (_routeOut(pools, path, amountIn) != 0) return amountIn;

        // The band admits the full size, so the only thing that stopped it was
        // a zero output - which only gets worse as the size falls.
        if (_routeRoom(pools, path, amountIn)) return 0;

        // Invariant: `lo` has room, `hi` does not. Zero has room.
        uint256 lo;
        uint256 hi = amountIn;
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_routeRoom(pools, path, mid)) lo = mid;
            else hi = mid;
        }
        if (lo == 0) return 0;
        // The largest size the band takes is only useful if it also produces
        // something. `_routeOut` folds in every hop's zero-output refusal.
        return _routeOut(pools, path, lo) == 0 ? 0 : lo;
    }

    /// @dev The asset entering each hop: `path[0]` is `tokenIn` and `path[i]`
    ///      is whatever hop `i-1` produced. Size-independent, so the search
    ///      resolves it once. Membership is not checked here for the same
    ///      reason `_routeOut` does not check it: this only feeds a view search
    ///      whose result `_walk` re-derives against `factory.isPool`.
    function _path(address[] calldata pools, address tokenIn) internal view returns (address[] memory path) {
        path = new address[](pools.length);
        address tin = tokenIn;
        for (uint256 i; i < pools.length; ++i) {
            PrecisionPool p = PrecisionPool(payable(pools[i]));
            // Membership is checked HERE rather than left to `_walk`, for two
            // reasons. A non-pool would otherwise fail the `token0()` call
            // below with no reason data - `routeUpTo` reporting nothing where
            // `route` says `NoPool` - and the hook check underneath needs a
            // real pool to ask.
            if (!factory.isPool(pools[i])) revert NoPool();
            // NO HOOKED POOL MAY APPEAR IN A CLAMPED ROUTE.
            //
            // The pool refuses partial fill on itself for a modelling reason
            // (`HookedNoPartialFill`); this refuses it for two more, and both
            // are worse. First, gas: the search bisects up to ~256 times and
            // every probe pays `HOOK_GAS` per hooked hop, so three hooked hops
            // is on the order of 115M gas - past the block limit, with the cost
            // falling on whoever submitted the route. Second, correctness: the
            // search quotes every hop against PRE-ROUTE state, and a hooked
            // pool at position i gets control in `afterSwap` between hops, so
            // it can move hop i+1's price and invalidate the clamp the search
            // just computed. The route then reverts on the band - a cheap,
            // repeatable grief rather than a one-off.
            //
            // The exact `route` path keeps hooked pools: it walks each hop once
            // at a size the caller fixed, so neither problem arises there.
            // `PrecisionPoolLens.routeClampable` is the off-chain screen for
            // this, and now the contract enforces what it advises.
            if (p.hook() != address(0)) revert HookedNoClamp();
            path[i] = tin;
            address t0 = p.token0();
            tin = tin == t0 ? p.token1() : t0;
        }
    }

    /// @dev Whether every hop's BAND admits the route at this size, ignoring
    ///      whether the outputs round to zero. Monotone decreasing in
    ///      `amountIn`, which is what makes it bisectable: each hop's own room
    ///      is monotone decreasing in its input, and its input is monotone
    ///      increasing in the route's, so the conjunction is too.
    ///
    ///      Chains `amountOut` even when it is zero. A hop handed nothing simply
    ///      does not move its own price, so it reports room - and the caller's
    ///      single zero-output check at the end is what rejects that size.
    function _routeRoom(address[] calldata pools, address[] memory path, uint256 amountIn)
        internal
        view
        returns (bool)
    {
        uint256 amt = amountIn;
        for (uint256 i; i < pools.length; ++i) {
            (uint256 out, bool hasRoom) =
                PrecisionPool(payable(pools[i])).quoteTransition(address(this), path[i], amt);
            if (!hasRoom) return false;
            amt = out;
        }
        return true;
    }

    /// @dev Replays the path as a view, chaining each hop's exact output into
    ///      the next. Zero means some hop cannot fill, which is the predicate
    ///      the search bisects.
    ///
    ///      `address(this)` is passed as the sender because that is who the
    ///      pool sees during `_walk` - a hook keying on it must be sampled at
    ///      the same address the swap will present.
    ///
    ///      Pool membership is checked in `_walk`, not here: this is a view over
    ///      caller-supplied addresses, so a non-pool can only return junk that
    ///      makes the search pick a size `_walk` then rejects outright.
    ///
    ///      EVERY HOP IS QUOTED AGAINST PRE-ROUTE STATE, which is exact only
    ///      because distinct pools do not move each other. A path that names the
    ///      SAME pool twice breaks that: execution applies the first visit
    ///      before the second, while this quotes both against the state before
    ///      either. The clamp can then choose a size that reverts, and an exact
    ///      `route` can return less than quoted - caught by its `minOut` rather
    ///      than here. Nothing is at risk either way, so the path is not
    ///      rejected: a duplicate hop is a strictly worse route than not taking
    ///      it, paying two fees to move one price back and forth, and screening
    ///      for it would charge every honest route a quadratic scan to prevent
    ///      a caller from wasting their own money.
    function _routeOut(address[] calldata pools, address[] memory path, uint256 amountIn)
        internal
        view
        returns (uint256 amt)
    {
        amt = amountIn;
        for (uint256 i; i < pools.length; ++i) {
            (uint256 out, bool fits) = PrecisionPool(payable(pools[i])).quoteExactIn(address(this), path[i], amt);
            if (!fits) return 0;
            amt = out;
        }
    }

    /// @notice Enter a band holding only ONE of its assets: swap part of the
    ///         input, then deposit both sides, in a single call.
    ///
    /// @dev The common UX. `factory.seed` already handles a two-asset entry,
    ///      but a user holding one asset would otherwise swap, work out what
    ///      they received, and deposit in a second transaction - with the price
    ///      moving in between.
    ///
    ///      `swapPortion` is supplied rather than derived. The optimal split
    ///      depends on the band, the live price and the fee, and computing it
    ///      on-chain would charge every caller gas to reproduce arithmetic a
    ///      frontend does for free. Whatever cannot be deposited at the pool's
    ///      ratio is refunded, so an imperfect split costs only the swap fee on
    ///      the portion actually traded.
    ///
    ///      Leftovers are always returned. This contract must never retain
    ///      value between routes or the next caller could sweep it.
    /// @param to LP share recipient.
    /// @param refundTo Where leftovers go. SEPARATE FROM `to`, as everywhere
    ///        else here. This used to sweep to the share recipient, which is
    ///        wrong twice over: a frontend depositing on a user's behalf sent
    ///        that user its own leftover input, and a recipient that holds
    ///        ERC-20 shares but has no payable receive - an ordinary vault or
    ///        smart-account shape - reverted the whole zap on the native sweep
    ///        AFTER the swap and the deposit had already run.
    ///
    /// @dev THE SWAP LEG RUNS AT `minOut = 0`; `minLP` is the only slippage
    ///      bound on this call. That is the right guard in principle - a
    ///      sandwiched swap returns less, so fewer shares, so `minLP` catches
    ///      it - but `minLP` is denominated in shares whose value depends on
    ///      the post-manipulation reserves, so it cannot be derived from the
    ///      ideal split arithmetically. Take it from a simulation of this exact
    ///      call, not from a closed form. The band bounds the damage either
    ///      way: the pool refuses a swap that would leave its range, so an
    ///      attacker's room is the band width rather than the whole curve.
    function zapIn(
        address pool,
        address tokenIn,
        uint256 amountIn,
        uint256 swapPortion,
        uint256 minLP,
        address to,
        address refundTo
    ) external payable claimsRoute(tokenIn != address(0)) returns (uint256 lp) {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (!factory.isPool(pool)) revert NoPool();
        if (to == address(0) || to == address(this)) revert Bad();
        if (refundTo == address(0) || refundTo == address(this)) revert Bad();
        if (amountIn == 0 || swapPortion > amountIn) revert Bad();
        // Swapping the WHOLE input leaves nothing for the other side of the
        // deposit, so `_proportional` mints zero and the pool reverts
        // `ZeroAmount()` from two calls away. "Zap all of it" is a reasonable
        // thing for a frontend to send, so say so here instead.
        if (swapPortion == amountIn) revert Bad();

        PrecisionPool p = PrecisionPool(payable(pool));
        address t0 = p.token0();
        address t1 = p.token1();
        if (tokenIn != t0 && tokenIn != t1) revert Bad();

        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert Bad();
        } else {
            if (msg.value != 0) revert Bad();
            _consume(tokenIn, amountIn);
        }

        // What was already here before this zap was funded. The trailing sweep
        // returns leftovers, and a leftover is what this call brought in and
        // could not deposit - NOT whatever happens to be resting. Sweeping the
        // raw balance would hand a caller any in-flight funding or mid-route
        // intermediate belonging to somebody else, which is precisely what the
        // checkpoint exists to prevent; the sweep must not opt out of it.
        // Both cases already include `amountIn` at this point: native as
        // `msg.value`, ERC-20 as the transfer `_consume` just verified.
        uint256 pre0 = _bal(t0);
        uint256 pre1 = _bal(t1);
        unchecked {
            if (tokenIn == t0) pre0 -= amountIn;
            else pre1 -= amountIn;
        }

        uint256 received;
        if (swapPortion != 0) {
            if (tokenIn == address(0)) {
                received = p.swapExactIn{value: swapPortion}(tokenIn, swapPortion, 0, address(this));
            } else {
                tokenIn.safeApproveWithRetry(pool, swapPortion);
                received = p.swapExactIn(tokenIn, swapPortion, 0, address(this));
                tokenIn.safeApproveWithRetry(pool, 0);
            }
        }

        uint256 keep = amountIn - swapPortion;
        (uint256 a0, uint256 a1) = tokenIn == t0 ? (keep, received) : (received, keep);

        // Canonical ordering puts address(0) first, so only `t0` can be native
        // and `t1` is always an ERC-20.
        uint256 value;
        if (t0 == address(0)) value = a0;
        else t0.safeApproveWithRetry(pool, a0);
        t1.safeApproveWithRetry(pool, a1);

        // `sqrtPriceInit` is ignored once the pool has supply, so a zap into an
        // unseeded band is refused rather than silently choosing its price.
        (lp,,) = p.addLiquidityExact{value: value}(0, a0, a1, minLP, to);

        if (t0 != address(0)) t0.safeApproveWithRetry(pool, 0);
        t1.safeApproveWithRetry(pool, 0);

        _sweep(t0, pre0, refundTo);
        _sweep(t1, pre1, refundTo);
    }

    /// @dev Returns what this call brought in and the deposit could not take at
    ///      the pool's ratio: the balance above `floor`, never the balance
    ///      itself. `floor` is what was already resting before this call was
    ///      funded, and it stays where it is.
    function _sweep(address token, uint256 floor, address to) internal {
        uint256 bal = _bal(token);
        if (bal <= floor) return;
        unchecked {
            bal -= floor;
        }
        if (token == address(0)) to.safeTransferETH(bal);
        else token.safeTransfer(to, bal);
    }

    function _bal(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : token.balanceOf(address(this));
    }

    function _consume(address token, uint256 amount) internal {
        bytes32 slot = _slot(token);
        uint256 active;
        uint256 base;
        bytes32 intent;
        assembly ("memory-safe") {
            active := tload(slot)
            base := tload(add(slot, 1))
            intent := tload(add(slot, 2))
            tstore(slot, 0)
            tstore(add(slot, 1), 0)
            tstore(add(slot, 2), 0)
            // The committed refund address, cleared with the rest so a spent
            // checkpoint leaves nothing behind for a later abort to read.
            tstore(add(slot, 3), 0)
        }
        if (active == 0) revert BadCheckpoint();
        // The committed call is this one, arguments included.
        if (intent != keccak256(msg.data)) revert IntentMismatch();
        uint256 current = token.balanceOf(address(this));
        if (current < base || current - base != amount) revert BadCheckpoint();
    }

    /// @dev Keyed by token only. There is exactly one permitted caller, so
    ///      mixing `caller()` in would isolate nothing while implying a
    ///      multi-executor design this contract does not have.
    function _slot(address token) internal pure returns (bytes32 slot) {
        uint256 seed = CHECKPOINT_SEED;
        assembly ("memory-safe") {
            mstore(0x00, token)
            mstore(0x20, seed)
            slot := keccak256(0x00, 0x40)
        }
    }
}
