// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";

/// @title zSolverExec
/// @notice The hand that touches the untrusted route. Owns nothing, is
///         approved by nobody, and answers only to the zSolverFill that
///         created it.
///
/// WHY THIS IS A SEPARATE CONTRACT
///   An earlier version of this design executed the solver's route from the
///   same contract users approve. That was wrong, and the way it was wrong is
///   worth writing down, because the mistake looks safe: the caller supplies
///   `target` and `data`, so the contract guarded them - `target` may not be
///   `tokenIn`, `tokenOut` or itself. But THE CALLER ALSO SUPPLIES `tokenIn`
///   AND `tokenOut`. A guard that compares the target against this call's
///   assets excludes nothing when the attacker picks this call's assets: pass
///   `tokenIn = ETH`, `amountIn = 0`, `minOut = 0` and a `tokenOut` whose
///   balance never moves, and every check passes, the measurement compares
///   zero against zero, and the contract makes an arbitrary call for anyone
///   who asks. Whatever standing allowance a user had granted it - and the
///   universal front-end habit is an infinite one - is then spendable by that
///   arbitrary call, because the spender is the contract itself.
///
///   No blacklist fixes that; the parameters it would have to constrain are
///   the attacker's to choose. What fixes it is SEPARATING THE ALLOWANCE FROM
///   THE ARBITRARY CALL. Users approve zSolverFill, which never calls anything
///   but this contract. This contract makes the untrusted call, and holds no
///   allowance from anyone, ever - so reaching it and steering it, which
///   remains possible, reaches nothing worth stealing.
///
/// WHAT AN ATTACKER STILL GETS, AND WHY IT IS SURVIVABLE
///   A funded `fill` can still steer this contract's `call` at an address of
///   the attacker's choosing, so `msg.sender == address(this)` is a signature
///   anyone can produce. Nothing should ever grant this address anything on
///   that basis.
///
///   BE PRECISE ABOUT WHAT IS AND IS NOT SWEPT, because an earlier version of
///   this comment overclaimed and the overclaim hid a bug. What `run` returns
///   to FILL is the DELTA it produced in `tokenOut`, the input it did not
///   spend, and ETH. What it does not touch is anything else: a third token
///   the arbitrary call acquired, or a token somebody transferred here, stays
///   put, and an allowance the arbitrary call granted on some unrelated token
///   stays granted. So this contract can hold balances and allowances between
///   calls. What matters is that NONE OF IT IS CREDITED TO A FILL - the delta
///   measurement above is what makes a fill's output attributable to its own
///   route - and that nothing here is ever a user's: no user approves this
///   address, and it is never a `to`.
///
///   `fill` also refuses a zero `amountIn` and a zero `minOut`. That raises
///   the price of producing the signature above zero; it does not make it
///   expensive, and it never did. Do not rely on it.
contract zSolverExec {
    using SafeTransferLib for address;

    /// @notice The only address that may call `run`.
    /// @dev Set to the deployer, which is zSolverFill's constructor. There is
    ///      no setter and no second constructor argument: an executor whose
    ///      caller could be re-pointed would be an executor an attacker could
    ///      adopt.
    address public immutable FILL;

    error NotFill();

    constructor() {
        FILL = msg.sender;
    }

    /// @notice Approve, execute the route, and sweep everything back to FILL.
    /// @dev Everything this touches is untrusted except `msg.sender`. It ends
    ///      holding nothing, which is the invariant the whole split exists to
    ///      preserve - a balance left here is a balance the next arbitrary
    ///      call could hand to whoever asked for it.
    /// @return got The `tokenOut` this route actually produced, measured here
    ///         and RETURNED rather than left for the caller to infer from a
    ///         balance. That distinction is the whole fix for the hole below.
    function run(
        address target,
        address spender,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        bytes calldata data
    ) public payable returns (uint256 got) {
        if (msg.sender != FILL) revert NotFill();

        // SNAPSHOT BEFORE THE ROUTE RUNS, AND SWEEP ONLY THE DIFFERENCE. An
        // earlier version swept this contract's whole `tokenOut` balance, which
        // credited the fill with anything that happened to be sitting here -
        // and anyone can put something here with a plain transfer. One wei
        // planted in an earlier transaction then read as a complete fill, so a
        // route that did nothing at all (or a `target` with no code) could
        // clear a bound of one wei and commit whatever the arbitrary call had
        // done. Measuring the delta is what makes the output attributable to
        // THIS route rather than to the balance of a contract nobody guards.
        uint256 outBefore = tokenOut == address(0) ? address(this).balance - msg.value : tokenOut.balanceOf(address(this));

        // Exact, not infinite: an allowance larger than the route needs is an
        // allowance the route can keep.
        if (tokenIn != address(0)) tokenIn.safeApproveWithRetry(spender, amountIn);

        bool ok;
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, data.offset, data.length)
            ok := call(gas(), target, callvalue(), p, data.length, codesize(), 0x00)
            if iszero(ok) {
                // Bubble the router's own revert so an aggregator's error
                // survives the hop - but CAPPED. Copying unbounded returndata
                // is a gas bomb a hostile target can hand any integrator that
                // forwards a bounded gas budget.
                let n := returndatasize()
                if gt(n, 0x100) { n := 0x100 }
                returndatacopy(p, 0x00, n)
                revert(p, n)
            }
        }
        // Zero the approval whether or not the route spent it, then leave with
        // empty hands. `to` is FILL, not the user: FILL is the only party that
        // can tell fill output from anything else, because it is the only one
        // holding the before-measurement.
        if (tokenIn != address(0)) {
            tokenIn.safeApproveWithRetry(spender, 0);
            // Capped at what we were handed. Returning more than that would be
            // handing this fill a balance that belongs to no fill at all.
            uint256 dust = tokenIn.balanceOf(address(this));
            if (dust > amountIn) dust = amountIn;
            if (dust != 0) tokenIn.safeTransfer(FILL, dust);
        }
        if (tokenOut != address(0)) {
            got = tokenOut.balanceOf(address(this)) - outBefore;
            if (got != 0) tokenOut.safeTransfer(FILL, got);
            // Unspent ETH on a token-out route is change, and all of it goes
            // back: the caller sent it, and FILL returns it from there.
            uint256 eth = address(this).balance;
            if (eth != 0) FILL.safeTransferETH(eth);
        } else {
            got = address(this).balance - outBefore;
            if (got != 0) FILL.safeTransferETH(got);
        }
    }

    /// @dev Routers refund ETH here mid-route. Anything that arrives outside a
    ///      route is swept to FILL by the next one and credited to whoever is
    ///      filling then - this contract is not custody and never was.
    receive() external payable {}
}

/// @title zSolverFill
/// @notice Executes an off-chain solver's proposed route through zSolverExec
///         and pays out only what the recipient actually received, reverting
///         below the user's bound.
///
/// WHAT A SOLVER RETURNS, AND WHY IT CANNOT BE TRUSTED
///   An aggregator's quote endpoint hands back an address to call and a blob
///   of calldata to call it with. Neither is a promise. The endpoint may be
///   stale, degraded, rate-limited into nonsense, misconfigured, or hostile;
///   the page cannot tell which, and neither can this contract. So nothing
///   here reads the solver's claim about the outcome. The claim is discarded
///   and the outcome is MEASURED.
///
/// WHAT THIS CONTRACT GUARANTEES, STATED HONESTLY
///   `to` ends the call holding at least `minOut` more of `tokenOut` than it
///   started with, or the whole transaction reverts and the user keeps their
///   input. That is the entire promise, and it is deliberately narrower than
///   the one an earlier draft of this file made:
///
///   IT DOES NOT PROMISE THE PRICE WAS GOOD. `minOut` is supplied by the
///   caller, and on the page it is derived from the winning solver's OWN
///   quoted amount less the user's slippage. A solver that quotes high to win
///   the race and then settles at exactly the floor it induced extracts the
///   difference on every fill, and does so without ever tripping the check
///   below, because every one of those fills is a valid fill. Nothing in this
///   contract can see that, and nothing in it should pretend to. It is the
///   roster's problem: the handicap a lane must beat the on-chain best by has
///   to exceed the user's slippage, or the gap is a standing subsidy - and the
///   realized shortfall between what a lane quoted and what `Filled` records
///   is the evidence a curator should act on.
///
///   So: this contract bounds what a route may do once chosen. Choosing well
///   is somebody else's job, and saying otherwise here would be the kind of
///   overclaim that stops people from doing that job.
///
/// THE ARBITRARY CALL LIVES NEXT DOOR
///   `target`, `spender` and `data` come from the solver, and this contract
///   never passes them to anything but `EXEC` - a contract with no allowances,
///   no balances between calls and nothing to steal. See zSolverExec above for
///   why that separation is the fix and a target blacklist is not.
///
/// THE OUTPUT MUST BE ROUTED TO `EXEC`, NOT TO THE USER
///   Aggregator routers take a recipient. The page must set it to `EXEC()`.
///   A route that pays the user directly measures nothing here and reverts -
///   a safe failure, and a loud one, which is the intent.
///
/// APPROVE EXACTLY WHAT YOU ARE SELLING, FOR EXACTLY ONE TRANSACTION.
///   Never grant this contract an infinite allowance. The split above is what
///   makes a standing approval survivable rather than fatal; it is not a
///   reason to leave one lying around.
///
/// GOVERNANCE
///   There is none. No owner, no admin, no pause, no upgrade: this is the
///   fixed thing the mutable rosters are measured by, and a governable bound
///   check would put the bound under the same key that curates the endpoints
///   proposing routes through it. Changing behaviour means deploying a new
///   adapter and re-pointing a lane at it - a public, per-lane, reviewable act.
///
///   THE ROSTER NAMES THIS ADDRESS, WHICH IS WEAKER THAN IT SOUNDS. The page
///   learns which adapter to use by reading zSolverList through an RPC it also
///   learned from chain. A reader who controls that node controls both answers
///   and can name an adapter that is not this contract at all, in which case
///   none of the above applies because none of it ran. The page must therefore
///   pin the adapters it will accept - by address or by codehash - rather than
///   trusting the roster's answer. This contract cannot enforce that; it can
///   only refuse to imply the guarantee holds when it is bypassed.
contract zSolverFill {
    using SafeTransferLib for address;

    /// @dev ETH is `address(0)` throughout, as in zRouter.
    address internal constant ETH = address(0);

    /// @notice The stateless executor this contract routes every untrusted
    ///         call through. Created here, so its `FILL` is this address and
    ///         no third party could have adopted it first.
    address public immutable EXEC;

    /// @dev Transient reentrancy lock, `keccak256("zSolverFill.lock")`.
    bytes32 internal constant LOCK = 0x59895352ebcc107737439479a84629478b2b9e50df57410ef238a409a55ba965;

    /// @notice `to` did not end up with `minOut`. Carries both numbers, so a
    ///         failed fill says how far short it fell, not merely that it did.
    error Insufficient(uint256 got, uint256 minOut);
    /// @notice `target` or `spender` was one of the assets, the executor, or
    ///         this contract.
    error BadTarget();
    /// @notice `tokenIn == tokenOut`: no delta could distinguish fill from
    ///         refund, so there is no measurement to enforce a bound with.
    error SameToken();
    /// @notice `msg.value` did not match the input side: exactly `amountIn`
    ///         for an ETH input, exactly zero otherwise.
    error BadValue();
    /// @notice `amountIn` or `minOut` was zero. Neither is a swap, and a fill
    ///         that measures nothing against nothing is the free arbitrary
    ///         call this design exists to price.
    error NothingToDo();
    /// @notice Reentered mid-route.
    error Reentrancy();

    /// @notice A fill that cleared its bound, recorded with the MEASURED
    ///         output rather than the quoted one. The two are equal only when
    ///         nothing went wrong, and the gap between them - over many fills,
    ///         per lane - is the only honest evidence about whether a solver's
    ///         quotes mean anything. Curate on it.
    event Filled(
        address indexed target,
        address indexed tokenIn,
        address indexed tokenOut,
        address to,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor() {
        EXEC = address(new zSolverExec());
    }

    /// @notice Execute a solver's route and pay out the measured output.
    /// @param target   The router the solver named. Untrusted.
    /// @param spender  Who pulls `tokenIn` - usually `target`, sometimes a
    ///                 separate allowance holder. Ignored for an ETH input.
    /// @param tokenIn  What the user is selling; `address(0)` for ETH.
    /// @param amountIn How much. Pulled from `msg.sender`, who must have
    ///                 approved exactly this much, for exactly this call.
    /// @param tokenOut What the user is buying; `address(0)` for ETH.
    /// @param minOut   The user's bound, checked against what `to` RECEIVES.
    /// @param to       Who receives the output.
    /// @param data     The solver's calldata, passed through unread. It must
    ///                 route the output to `EXEC()`.
    /// @return out     What `to` actually received.
    function fill(
        address target,
        address spender,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        address to,
        bytes calldata data
    ) public payable returns (uint256 out) {
        assembly ("memory-safe") {
            if tload(LOCK) {
                mstore(0x00, 0xab143c06) // `Reentrancy()`.
                revert(0x1c, 0x04)
            }
            tstore(LOCK, 1)
        }

        if (tokenIn == tokenOut) revert SameToken();
        if (amountIn == 0 || minOut == 0) revert NothingToDo();
        address exec = EXEC;
        // Paying the measurement's own endpoints turns the bound into a
        // tautology: `to == exec` leaves the output where the next filler
        // sweeps it while reporting success, and `to == address(this)` measures
        // a self-transfer.
        if (to == exec || to == address(this) || to == address(0)) revert BadTarget();
        if (
            target == tokenIn || target == tokenOut || target == address(this) || target == exec
                || spender == tokenIn || spender == tokenOut || spender == address(this) || spender == exec
        ) revert BadTarget();

        bool ethIn = tokenIn == ETH;
        if (msg.value != (ethIn ? amountIn : 0)) revert BadValue();

        // MEASURE WHERE THE ROUTE CANNOT REACH. An earlier version took this
        // contract's own `tokenOut` balance before and after, which looked
        // equivalent and was not: `target` runs between those two reads and can
        // simply transfer `tokenOut` straight here, so a route that swapped
        // nothing could plant a wei, have it read as output, clear a bound of a
        // wei, and commit whatever else the arbitrary call did. The executor's
        // delta is the only number the route cannot forge - it is measured
        // around the call, inside the contract the call runs as - so `held` is
        // what `run` REPORTS, not what this balance says.
        if (!ethIn) tokenIn.safeTransferFrom(msg.sender, exec, amountIn);
        uint256 held =
            zSolverExec(payable(exec)).run{value: msg.value}(target, spender, tokenIn, amountIn, tokenOut, data);

        // REFUND THE INPUT BEFORE MEASURING THE OUTPUT. Ordering, not
        // decoration: if `tokenIn` and `tokenOut` are two addresses over one
        // ledger - a proxy pair, an aliased entry point - then unspent input
        // sitting here would read as output and a no-op route would "clear"
        // any bound up to `amountIn`. Returning it first means such a route
        // measures nothing and reverts, which is the honest answer.
        if (!ethIn) {
            uint256 dust = tokenIn.balanceOf(address(this));
            if (dust != 0) tokenIn.safeTransfer(msg.sender, dust);
        } else {
            // Only on the ETH-input path: when the OUTPUT is ETH this balance
            // is the fill, not change. `force` because a refund must never be
            // able to brick the contract - an integrator without a payable
            // receive would otherwise be one stray wei away from every fill
            // reverting, permanently, at an attacker's cost of one wei.
            uint256 back = address(this).balance;
            if (back != 0) msg.sender.forceSafeTransferETH(back);
        }

        if (held == 0) revert Insufficient(0, minOut);

        // THE BOUND IS CHECKED WHERE THE USER IS. Measuring only what arrived
        // HERE would promise "the adapter received minOut", which for a
        // fee-on-transfer or rebasing output is not the same sentence as "the
        // user received minOut" - and it is the second one people are relying
        // on.
        uint256 had = _balance(tokenOut, to);
        _pay(tokenOut, to, held);
        // CHECKED, DELIBERATELY. `unchecked` here saved about twenty gas and
        // disabled the only guarantee this contract makes: a `tokenOut` that
        // REDUCES the recipient's balance during transfer - reflection,
        // anti-whale, a forwarding hook - made this wrap to ~2**256 and sail
        // past `minOut` while the recipient ended the call poorer. The revert
        // on underflow is the correct answer to a token that does that.
        out = _balance(tokenOut, to) - had;
        if (out < minOut) revert Insufficient(out, minOut);

        emit Filled(target, tokenIn, tokenOut, to, amountIn, out);

        assembly ("memory-safe") {
            tstore(LOCK, 0)
        }
    }

    /// @dev ETH from `EXEC`'s sweep lands here mid-fill. Nothing is meant to
    ///      rest here between calls.
    receive() external payable {}

    function _balance(address token) internal view returns (uint256) {
        return _balance(token, address(this));
    }

    function _balance(address token, address who) internal view returns (uint256) {
        return token == ETH ? who.balance : token.balanceOf(who);
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (token == ETH) to.safeTransferETH(amount);
        else token.safeTransfer(to, amount);
    }
}
