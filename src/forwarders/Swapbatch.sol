// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

/// @title Swapbatch
/// @notice Fill several Swapboard orders in one transaction paying native ETH. Takes the
///         ETH, wraps exactly what the batch owes into WETH, runs the board's existing
///         batch fill, and returns everything left over as ETH.
///
/// @dev    WHY A HELPER AND NOT `multicall`. Swapboard inherits Solady's Multicallable,
///         whose `multicall` reverts on any non-zero `msg.value`:
///
///             if (msg.value != 0) revert();   // Paradigm's "two rights might make a wrong"
///
///         That is not a missing feature to be patched around — every delegatecall in a
///         multicall observes the SAME `msg.value`, and `fillOrderWithEth` both treats
///         `msg.value` as the amount paid and wraps it out of the CONTRACT's balance.
///         Overriding `multicall` to accept value would let one `msg.value` settle N
///         orders, underwritten by any ETH resting in the board. The board's `receive()`
///         is gated to WETH so ETH cannot be donated, but `selfdestruct` bypasses
///         `receive()` and a counterfactual address can be pre-funded, so "resting ETH"
///         is reachable rather than hypothetical.
///
///         So the value accounting lives here, out of delegatecall's way, where
///         `msg.value` is counted exactly once:
///
///             total = Σ fillAmountsB;  require(msg.value >= total);  wrap(total)
///
///         See test/SwapboardMulticallValue.t.sol, which pins the guard this replaces.
///
///         HOLDS NOTHING BETWEEN CALLS. Every entry point is public, so whatever this
///         contract holds or has granted when a call returns belongs to whoever calls it
///         next. Legacy output delivery is therefore derived from the orders and transfers
///         only the balance delta created by this batch; it never sweeps a caller-listed
///         token's entire balance.
///
///         APPROVALS ARE SCOPED. The constructor binds one reviewed legacy board and one
///         reviewed modern board. The caller cannot pair an arbitrary board with a caller-
///         supplied ABI/version flag. The approval is exact and revoked before returning.
///
///         REENTRANCY. A fill hands control to maker-chosen code (tokenA, tokenB, or a
///         721 hook). Without a guard that code could re-enter and point the sweeps —
///         which pay a caller-supplied recipient — at itself, taking the unspent ETH this
///         contract is holding mid-batch.
///
///         WHICH BOARD DECIDES WHERE tokenA LANDS. The deployed board does NOT take a
///         recipient, and pays tokenA to ITS msg.sender - this contract:
///
///           legacy    0x000000fF3D7A2d373615141d7489Ca66683DbecF  (v1)
///                     fillOrders(uint256[],uint256,uint256[])          <- no recipient
///                     tryFillOrders(uint256[],uint256,uint256[])
///                     (no `multicall` either, so ETH batching there is
///                      impossible today without this helper)
///           current   0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b
///                     fillOrders(uint256[],uint256,uint256[],uint256[],address) <- pays direct
///                     tryFillOrders(uint256[],uint256,uint256[],uint256[],address)
///
///         WHICH OF THE FOUR BOARDS ARE HERE. `Swapbol` forwards to four - v1,
///         the current Swapboard, Dutchboard and Floorboard - and three of them
///         are bound here, each for a reason the others do not share:
///
///           v1          no batch fill and no `multicall`. Driven one order at a
///                       time by `fillOrdersWithEth`, which is the only way N
///                       fills there can share a transaction at all.
///           current     has a batch fill, but no payable one.
///           Dutchboard  batches ETH natively and is NOT routed here for that.
///                       Bound for the one shape it cannot serve: a listing
///                       quoted in WETH, which `fill` refuses to take ether for
///                       and `_settle` pays by pulling the quote asset from the
///                       caller. See `fillDutchWithEth`.
///
///         Floorboard is deliberately absent, and that is not an oversight to be
///         corrected later: `tryHitMany` is not payable because hitting a bid
///         runs the other way - the taker DELIVERS the asset and RECEIVES the
///         proceeds. There is no ETH leg to wrap, so a binding would be a
///         payable entry point with no payable work behind it.
///
///         So on a legacy board the `tokensOut` sweep is not a safety net, it is the
///         DELIVERY PATH, and the whole purchase sits here until it runs. Omitting a
///         bought asset from `tokensOut` against a legacy board would strand it permanently:
///         nothing else in this contract can move an arbitrary token. The helper therefore
///         requires one validated expected output per order and transfers only this batch's
///         balance delta.
///
///         An order whose tokenA is WETH delivers WETH, not ETH. Only unused WETH input
///         is unwrapped into the caller's ETH refund.
contract Swapbatch {
    /// @dev Canonical wrapper, fixed at deployment. A deployment trust root: a lying
    ///      wrapper could misreport `balanceOf` and defeat the leftover sweep.
    address public immutable weth;
    address public immutable legacyBoard;
    address public immutable modernBoard;
    /// @dev Dutchboard, for the one case it cannot serve itself. See
    ///      `fillDutchWithEth`. Zero disables that path.
    address public immutable dutchboard;

    /// @dev Transient reentrancy flag. One past the `Reentrancy()` selector, so the
    ///      slot and the error the guard reverts with cannot be confused for each
    ///      other. The comment here used to name the selector itself, which is the
    ///      value on the line below MINUS one.
    uint256 constant REENTRANCY_GUARD_SLOT = 0xab143c07;

    error NoOrders();
    error Reentrancy();
    error ZeroAddress();
    /// @dev Raised from assembly when the refund transfer fails. Declared so it is
    ///      in the ABI: a caller cannot decode a selector the contract never names,
    ///      and this one is the likeliest revert a contract recipient will hit.
    error ETHTransferFailed();
    /// @dev Only WETH may push ETH here. `NotAContract` used to stand in for this,
    ///      which told a caller their EOA was not a contract - true, and not the reason.
    error OnlyWETH();
    error BadRecipient();
    error InvalidResult();
    error LengthMismatch();
    error BoardCallFailed();
    error TokensOutRequired();
    error SlippageUnsupported();
    error TokensOutUnexpected();
    error BoardVersionMismatch();
    error TokensOutLengthMismatch();
    error NotAContract(address token);
    error UnknownBoard(address board);
    error ZeroFillAmount(uint256 index);
    error InsufficientValue(uint256 required, uint256 sent);
    error WETHAmountMismatch(uint256 expected, uint256 actual);
    error TokensOutMismatch(uint256 index, address expected, address actual);
    /// @dev v1 has no fill-amount argument; a leg there is all or nothing.
    error PartialFillUnsupported(uint256 index, uint256 orderAmountB, uint256 requested);
    /// @dev v1 leg whose tokenB is not WETH, so `msg.value` cannot pay for it.
    error NotWethQuoted(uint256 index, address tokenB);

    constructor(address _weth, address _legacyBoard, address _modernBoard, address _dutchboard) {
        if (_weth == address(0)) revert ZeroAddress();
        if (_weth.code.length == 0) revert NotAContract(_weth);
        if (_legacyBoard == address(0) && _modernBoard == address(0)) revert UnknownBoard(address(0));
        if (_legacyBoard != address(0) && _legacyBoard.code.length == 0) revert NotAContract(_legacyBoard);
        if (_modernBoard != address(0) && _modernBoard.code.length == 0) revert NotAContract(_modernBoard);
        if (_legacyBoard != address(0) && _legacyBoard == _modernBoard) revert UnknownBoard(_legacyBoard);
        if (_dutchboard != address(0)) {
            if (_dutchboard.code.length == 0) revert NotAContract(_dutchboard);
            // A board reachable through two different paths is a board whose ABI
            // the caller gets to choose, which is the thing `UnknownBoard` exists
            // to prevent.
            if (_dutchboard == _legacyBoard || _dutchboard == _modernBoard) revert UnknownBoard(_dutchboard);
        }
        weth = _weth;
        legacyBoard = _legacyBoard;
        modernBoard = _modernBoard;
        dutchboard = _dutchboard;
    }

    /// @notice Fill `orderIds` on `board`, paying with the ETH attached to this call.
    /// @param  board         One of the constructor-bound reviewed boards.
    /// @param  orderIds      Orders to fill.
    /// @param  fillAmountsB  WETH paid to each order's maker; must align with `orderIds`.
    /// @param  minAmountsA   Minimum tokenA output for each order; must align with `orderIds`.
    /// @param  deadline      Passed through to the board's staleness check.
    /// @param  recipient     Receives tokenA from every leg, plus all refunds.
    ///                       address(0) means the caller.
    /// @param  skipFailures  false uses `fillOrders` (atomic: any bad order aborts the
    ///                       batch). true uses `tryFillOrders`, which skips orders that
    ///                       are inactive, missing, expired, or reserved for someone
    ///                       else — the ETH for a skipped leg comes back as a refund.
    /// @param  legacyBoardMode true for the constructor-bound board without a `recipient` argument, which pays
    ///                       tokenA to this contract. `tokensOut` then MUST list every
    ///                       bought asset, because that sweep is the only way out.
    /// @param  tokensOut     For the legacy board, one expected tokenA per order, in the
    ///                       same order as `orderIds`; each is validated against the board
    ///                       before settlement. It must be empty for the modern board.
    /// @return filled        Per-order outcome; all true on the atomic path.
    function fillOrdersWithEth(
        address board,
        uint256[] calldata orderIds,
        uint256[] calldata fillAmountsB,
        uint256[] calldata minAmountsA,
        address[] calldata tokensOut,
        uint256 deadline,
        address recipient,
        bool skipFailures,
        bool legacyBoardMode
    ) public payable returns (bool[] memory filled) {
        assembly ("memory-safe") {
            if tload(REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_GUARD_SLOT, 1)
        }

        uint256 n = orderIds.length;
        if (n == 0) revert NoOrders();
        if (n != fillAmountsB.length || n != minAmountsA.length) revert LengthMismatch();
        bool isLegacy = legacyBoard != address(0) && board == legacyBoard;
        bool isModern = modernBoard != address(0) && board == modernBoard;
        if (!isLegacy && !isModern) revert UnknownBoard(board);
        if (legacyBoardMode != isLegacy) revert BoardVersionMismatch();
        if (isLegacy && tokensOut.length != n) revert TokensOutLengthMismatch();
        if (isModern && tokensOut.length != 0) revert TokensOutUnexpected();
        // The legacy board has no slippage argument. Do not advertise protected
        // execution while routing to it; callers must pass zero floors there.
        if (isLegacy) {
            for (uint256 i; i < n; ++i) {
                if (minAmountsA[i] != 0) revert SlippageUnsupported();
            }
        }

        for (uint256 i; i < n; ++i) {
            if (fillAmountsB[i] == 0) revert ZeroFillAmount(i);
        }

        // Never use the helper or WETH as an end recipient. The former strands direct
        // modern output; the latter is the wrapper trust root, not a user destination.
        address to = recipient == address(0) ? msg.sender : recipient;
        if (to == address(this) || to == weth || to == address(0)) revert BadRecipient();

        uint256 ethBase = address(this).balance - msg.value;
        uint256 wethBase = balanceOf(weth, address(this));
        ILegacyBatchOrderView.Order[] memory legacyOrders;
        uint256[] memory outputBases;
        if (isLegacy) {
            legacyOrders = _legacyOrders(board, orderIds);
            outputBases = new uint256[](n);
            for (uint256 i; i < n; ++i) {
                address expected = legacyOrders[i].tokenA;
                // `legacyBoardMode` was also tested here, but this whole block is
                // under `isLegacy` and line 150 already requires the two to agree,
                // so that half of the condition could never be true.
                if (expected == address(0)) {
                    if (tokensOut[i] != address(0)) revert TokensOutMismatch(i, expected, tokensOut[i]);
                } else if (tokensOut[i] != expected) {
                    revert TokensOutMismatch(i, expected, tokensOut[i]);
                }
                if (tokensOut[i] != address(0) && tokensOut[i] != weth) {
                    outputBases[i] = balanceOf(tokensOut[i], address(this));
                }
                // Only an order that still EXISTS can be asserted about. A dead
                // one - cancelled, already filled, never created - reads back as
                // all zeros, and both checks below would then reject the caller's
                // figure for disagreeing with a price the board no longer quotes.
                // That is exactly the leg `skipFailures` is for: it must reach the
                // loop and be skipped, not abort the batch here. On the atomic path
                // it still aborts, but at the board, with the board's own error.
                if (legacyOrders[i].active) {
                    // v1 takes the WHOLE order at the WHOLE price - it has no
                    // fill-amount argument to pass a smaller number to. So the caller's
                    // figure is not a request, it is an assertion about what this leg
                    // costs, and it has to match the board or the batch would wrap the
                    // wrong total and leave the difference stranded as allowance.
                    if (fillAmountsB[i] != legacyOrders[i].amountB) {
                        revert PartialFillUnsupported(i, legacyOrders[i].amountB, fillAmountsB[i]);
                    }
                    // Paying with ETH means paying in WETH. An order quoted in any
                    // other tokenB cannot be settled from `msg.value` at all, and
                    // would otherwise reach the board with an allowance it never uses.
                    if (legacyOrders[i].tokenB != weth) {
                        revert NotWethQuoted(i, legacyOrders[i].tokenB);
                    }
                }
            }
        }

        // msg.value is counted exactly once, against the sum of the legs. This is the
        // whole reason this contract exists.
        uint256 total;
        for (uint256 i; i < n; ++i) {
            total += fillAmountsB[i];
        }
        if (msg.value < total) revert InsufficientValue(total, msg.value);

        // Wrap only what the batch owes, so any excess stays as ETH to refund.
        IWETH(weth).deposit{value: total}();
        uint256 afterDeposit = balanceOf(weth, address(this));
        if (afterDeposit < wethBase) revert WETHAmountMismatch(wethBase, afterDeposit);
        uint256 wrapped = afterDeposit - wethBase;
        if (wrapped != total) revert WETHAmountMismatch(total, wrapped);
        safeApprove(weth, board, total);

        // The two generations settle differently, because v1 has no batch call to
        // make. The modern board takes the whole batch in one go; v1 is driven one
        // order at a time from here, which is the service this helper provides.
        if (isLegacy) {
            filled = new bool[](n);
            for (uint256 i; i < n; ++i) {
                (bool legOk, bytes memory legRet) =
                    board.call(abi.encodeCall(ILegacyOrderFill.fillOrder, (orderIds[i], deadline)));
                if (legOk) {
                    filled[i] = true;
                    continue;
                }
                // `skipFailures` has to be honoured leg by leg here. On the modern
                // board the board itself decides what to skip; on v1 there is no
                // `tryFillOrders` to ask, so this loop IS the try-semantics - and a
                // skipped leg simply leaves its share of the wrapped WETH unspent,
                // which the accounting below already refunds.
                if (!skipFailures) {
                    assembly ("memory-safe") {
                        revert(add(legRet, 0x20), mload(legRet))
                    }
                }
            }
        } else {
            bytes memory callData = skipFailures
                ? abi.encodeCall(IModernBatchFill.tryFillOrders, (orderIds, deadline, fillAmountsB, minAmountsA, to))
                : abi.encodeCall(IModernBatchFill.fillOrders, (orderIds, deadline, fillAmountsB, minAmountsA, to));

            (bool ok, bytes memory ret) = board.call(callData);
            if (!ok) {
                // Bubble the board's own revert; a bare failure here would hide OrderExpired,
                // NotCounterparty and friends behind a useless generic error.
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }

            if (skipFailures) {
                filled = abi.decode(ret, (bool[]));
                if (filled.length != n) revert InvalidResult();
            } else {
                filled = new bool[](n);
                for (uint256 i; i < n; ++i) {
                    filled[i] = true; // atomic path: reaching here means every leg settled
                }
            }
        }

        // Nothing may outlive the call, and `tryFillOrders` leaves the allowance for any
        // skipped leg unspent.
        safeApprove(weth, board, 0);

        // What the board did NOT take. It pulls exactly `fillAmountsB[i]` for each
        // leg it settles and nothing for one `tryFillOrders` skipped, so the unspent
        // input is known exactly rather than inferred from a balance.
        uint256 unspent = total;
        for (uint256 i; i < n; ++i) {
            if (filled[i]) unspent -= fillAmountsB[i];
        }

        uint256 currentWeth = balanceOf(weth, address(this));
        uint256 reserved = wethBase + unspent;
        if (currentWeth < reserved) revert WETHAmountMismatch(reserved, currentWeth);

        // Anything above the untouched base and the unspent input is WETH this batch
        // BOUGHT - measured, not predicted.
        //
        // The previous revision summed `legacyOrders[i].amountA`, the quote read
        // BEFORE the fill, and made two mistakes with it. That figure is the whole
        // order, not the part a partial fill actually buys. And it was reserved again
        // here, below, after `_deliverLegacy` had already paid it out. Either alone
        // breaks the path, so a legacy leg paying out WETH has never once settled: a
        // full fill died on the double count, a partial one on transferring more WETH
        // than it held. Nothing caught it because the mock legacy board in
        // `Swapbatch.t.sol` only ever quotes tokenA as a plain ERC-20, so no test
        // reaches this branch at all. See `SwapbatchWethLegProbe.t.sol`.
        //
        // Every other output is delivered by balance delta. This one now is too.
        if (isLegacy) {
            _deliverLegacy(legacyOrders, filled, tokensOut, outputBases, currentWeth - reserved, to);
        }

        // Only WETH left from the current input allocation is refunded as ETH.
        // Re-measured after delivery, so purchased WETH is already gone and
        // pre-existing WETH is never touched.
        uint256 left = balanceOf(weth, address(this)) - wethBase;
        if (left != 0) {
            IWETH(weth).withdraw(left);
            uint256 received = address(this).balance - (ethBase + (msg.value - total));
            if (received != left) revert WETHAmountMismatch(left, received);
        }

        // Excess value plus anything just unwrapped, in one transfer.
        if (address(this).balance < ethBase) revert InvalidResult();
        assembly ("memory-safe") {
            let refund := sub(selfbalance(), ethBase)
            if refund {
                if iszero(call(gas(), to, refund, codesize(), 0x00, codesize(), 0x00)) {
                    mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
                    revert(0x1c, 0x04)
                }
            }
            tstore(REENTRANCY_GUARD_SLOT, 0)
        }
    }

    /// @notice Batch-fill WETH-quoted Dutchboard listings, paying native ETH.
    /// @dev    NOT for native-ETH-quoted lots. Those are already batchable with
    ///         `msg.value` straight at the board, and routing them through here
    ///         would wrap ether the board will not spend. Every leg must be
    ///         quoted in WETH and is checked before anything is wrapped.
    ///
    ///         Unlike the legacy Swapboard path there is no `tokensOut` sweep:
    ///         Dutchboard takes a recipient and delivers the lot straight to it,
    ///         so this contract never holds the purchase. It holds only the
    ///         wrapped input, and only for the length of the call.
    /// @param  ids           Listings to fill.
    /// @param  takes         ERC20 units per listing; 0 (or the full bundle) for NFTs.
    /// @param  maxCosts      Per-leg payment bound. A decaying price is read at
    ///                       execution, so this - not the quote - is what the
    ///                       batch commits to, and their sum is what gets wrapped.
    /// @param  recipient     Receives every lot and all refunds; 0 means the caller.
    ///                       For an NFT lot this must be able to hold an ERC-721:
    ///                       delivery is `transferFrom`, with no receiver hook.
    /// @param  skipFailures  true uses `tryFillMany`, which steps over legs that
    ///                       went stale; their share of the wrapped input comes
    ///                       back as ETH.
    /// @return filled        Per-leg outcome; all true on the atomic path.
    function fillDutchWithEth(
        uint256[] calldata ids,
        uint128[] calldata takes,
        uint256[] calldata maxCosts,
        address recipient,
        bool skipFailures
    ) public payable returns (bool[] memory filled) {
        assembly ("memory-safe") {
            if tload(REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(REENTRANCY_GUARD_SLOT, 1)
        }

        address board = dutchboard;
        if (board == address(0)) revert UnknownBoard(address(0));
        uint256 n = ids.length;
        if (n == 0) revert NoOrders();
        if (n != takes.length || n != maxCosts.length) revert LengthMismatch();

        address to = recipient == address(0) ? msg.sender : recipient;
        if (to == address(this) || to == weth || to == address(0)) revert BadRecipient();

        // Every leg must be payable in the asset this contract is about to mint.
        // A native-quoted lot would be settled out of `msg.value` the board never
        // receives here, and any other ERC20 would be pulled from a balance this
        // contract does not hold - both revert, but neither says why.
        uint256 total;
        for (uint256 i; i < n; ++i) {
            if (maxCosts[i] == 0) revert ZeroFillAmount(i);
            (,,,,,, address quote,,,,) = IDutchListings(board).listings(ids[i]);
            if (quote != weth) revert NotWethQuoted(i, quote);
            total += maxCosts[i];
        }
        if (msg.value < total) revert InsufficientValue(total, msg.value);

        uint256 ethBase = address(this).balance - msg.value;
        uint256 wethBase = balanceOf(weth, address(this));

        // Wrap the BOUND, not the price. A decaying lot costs whatever it costs
        // when the block lands; the difference is refunded below.
        IWETH(weth).deposit{value: total}();
        uint256 afterDeposit = balanceOf(weth, address(this));
        if (afterDeposit < wethBase) revert WETHAmountMismatch(wethBase, afterDeposit);
        if (afterDeposit - wethBase != total) revert WETHAmountMismatch(total, afterDeposit - wethBase);
        safeApprove(weth, board, total);

        // No ETH is forwarded: these legs are ERC20-quoted, and Dutchboard's
        // single `fill` rejects value outright on one. The board pulls WETH.
        if (skipFailures) {
            (filled,) = IDutchBatchFill(board).tryFillMany(ids, takes, maxCosts, to);
            if (filled.length != n) revert InvalidResult();
        } else {
            IDutchBatchFill(board).fillMany(ids, takes, maxCosts, to);
            filled = new bool[](n);
            for (uint256 i; i < n; ++i) {
                filled[i] = true;
            }
        }

        safeApprove(weth, board, 0);

        // Whatever the board did not pull. Measured, not inferred: a decaying
        // price means the spend is not knowable before the call, and a skipped
        // leg spends nothing at all.
        uint256 left = balanceOf(weth, address(this));
        if (left < wethBase) revert WETHAmountMismatch(wethBase, left);
        left -= wethBase;
        if (left != 0) {
            IWETH(weth).withdraw(left);
            uint256 received = address(this).balance - (ethBase + (msg.value - total));
            if (received != left) revert WETHAmountMismatch(left, received);
        }

        if (address(this).balance < ethBase) revert InvalidResult();
        assembly ("memory-safe") {
            let refund := sub(selfbalance(), ethBase)
            if refund {
                if iszero(call(gas(), to, refund, codesize(), 0x00, codesize(), 0x00)) {
                    mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
                    revert(0x1c, 0x04)
                }
            }
            tstore(REENTRANCY_GUARD_SLOT, 0)
        }
    }

    function _legacyOrders(address board, uint256[] calldata orderIds)
        internal
        view
        returns (ILegacyBatchOrderView.Order[] memory orders)
    {
        orders = ILegacyBatchOrderView(board).getOrders(orderIds);
        if (orders.length != orderIds.length) revert InvalidResult();
    }

    function _deliverLegacy(
        ILegacyBatchOrderView.Order[] memory orders,
        bool[] memory filled,
        address[] calldata tokensOut,
        uint256[] memory outputBases,
        uint256 purchasedWeth,
        address to
    ) internal {
        bool sentWeth;
        for (uint256 i; i < orders.length; ++i) {
            if (!filled[i] || tokensOut[i] == address(0)) continue;
            if (tokensOut[i] == weth) {
                if (sentWeth) continue;
                if (purchasedWeth != 0) safeTransfer(weth, to, purchasedWeth);
                sentWeth = true;
                continue;
            }
            uint256 current = balanceOf(tokensOut[i], address(this));
            if (current < outputBases[i]) revert InvalidResult();
            uint256 delta = current - outputBases[i];
            if (delta != 0) safeTransfer(tokensOut[i], to, delta);
        }
    }

    /// @notice ETH required for a set of legs — the sum the batch will wrap. Anything
    ///         sent above this comes back, so a caller may safely overpay.
    function totalRequired(uint256[] calldata fillAmountsB) public pure returns (uint256 total) {
        for (uint256 i; i < fillAmountsB.length; ++i) {
            total += fillAmountsB[i];
        }
    }

    /// @dev Only WETH may push ETH here, and only during `withdraw`. Refusing everything
    ///      else keeps the sweep's "whatever is here belongs to this caller" rule from
    ///      being a way to donate into someone else's batch.
    receive() external payable {
        if (msg.sender != weth) revert OnlyWETH();
    }
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @dev v1 fills ONE ORDER AT A TIME. It has no batch entry point and no
///      `multicall`, which is the entire reason this helper is worth deploying
///      for it: N fills that cannot otherwise share a transaction.
///
///      `fillOrder(uint256,uint256)` is (orderId, deadline) - NOT an amount. v1
///      predates partial fills, so a fill takes the whole order at the whole
///      price, and it predates the payable entry point too, so the WETH has to
///      be approved rather than sent. Both are confirmed against the dapp, which
///      has been filling this board in production: see the `SEL_FILL1` encoding
///      in zSwap.html, which writes exactly `id` then `deadline`, and the comment
///      beside it that "a v1 board has no payable entry point at all".
interface ILegacyOrderFill {
    function fillOrder(uint256 orderId, uint256 deadline) external;
}

/// @dev Dutchboard batches ETH natively and needs no help doing it - `fillMany`
///      and `tryFillMany` are payable, thread `msg.value` across the legs and
///      refund the remainder once at the end. `fillDutchWithEth` exists for the
///      one shape it CANNOT serve: a listing quoted in WETH.
///
///      There, `fill` reverts `Bad()` if any ETH is attached, and `_settle`
///      pays with `_payQuoteToken(quote, msg.sender, ...)` - it pulls the quote
///      asset from the caller and never looks at `msg.value`. So a taker holding
///      only ether cannot fill a WETH-quoted lot at all: not in a batch, not one
///      at a time. Wrapping first is the whole job.
interface IDutchBatchFill {
    function fillMany(uint256[] calldata ids, uint128[] calldata takes, uint256[] calldata maxCosts, address to)
        external
        payable
        returns (uint256 ethSpent);
    function tryFillMany(uint256[] calldata ids, uint128[] calldata takes, uint256[] calldata maxCosts, address to)
        external
        payable
        returns (bool[] memory filled, uint256 ethSpent);
}

/// @dev The public mapping getter. Solidity omits the struct's trailing dynamic
///      `ids` array from an auto-generated getter, so this is eleven values, not
///      twelve - only `quote` is read here.
interface IDutchListings {
    function listings(uint256 id)
        external
        view
        returns (
            address seller,
            bool isNFT,
            uint40 startTime,
            uint40 duration,
            address token,
            uint96 startPrice,
            address quote,
            uint96 endPrice,
            uint128 initial,
            uint128 remaining,
            uint40 expiry
        );
}


interface IModernBatchFill {
    function fillOrders(
        uint256[] calldata orderIds,
        uint256 deadline,
        uint256[] calldata fillAmountsB,
        uint256[] calldata minAmountsA,
        address recipient
    ) external;

    function tryFillOrders(
        uint256[] calldata orderIds,
        uint256 deadline,
        uint256[] calldata fillAmountsB,
        uint256[] calldata minAmountsA,
        address recipient
    ) external returns (bool[] memory filled);
}

interface ILegacyBatchOrderView {
    /// @dev MUST match the bound board's struct WORD FOR WORD. A missing field
    ///      does not fail to decode - it slides every field after it one word
    ///      left, so `tokenA` reads a bool and `amountA` reads an address as a
    ///      number. Nothing reverts; the batch just settles against nonsense.
    ///
    ///      THREE BOARDS EXIST AND ALL THREE SHAPES DIFFER. They are told apart
    ///      by deployment date, not by name, which is what makes this easy to get
    ///      wrong. Measured from mainnet, not inferred:
    ///
    ///        v1   0x000000fF3D7A2d373615141d7489Ca66683DbecF   6 words
    ///        mid  0x00000000CC3915a0f5F98CBdC558Ac1a8e85B831   7 words (partialFill)
    ///        v2   0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b  11 words
    ///
    ///      THIS IS v1, and v1 is what "legacy" means everywhere else in the
    ///      system: `Swapbol.boardV1()` returns it, and the dapp lists it as its
    ///      legacy board while excluding the mid one as deprecated (see the
    ///      `BOARDS` table in zSwap.html, whose decoder reads 6 words for it).
    ///      v1 also holds the history worth batching - 139 orders against the mid
    ///      board's 3.
    ///
    ///      Verified by decoding a real order rather than by counting fields:
    ///      `getOrders([5])` on v1 returns six words that read as maker, active=1,
    ///      tokenA=WETH, amountA=0.02e18, tokenB=USDC, amountB=100e6. Addresses
    ///      land in the address slots and amounts in the amount slots, which they
    ///      would not under any other field ordering.
    struct Order {
        address maker;
        bool active;
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
    }

    function getOrders(uint256[] calldata orderIds) external view returns (Order[] memory);
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

error ApproveFailed();

function safeApprove(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x00, 0x095ea7b3000000000000000000000000)

        // USDT-style tokens require a zero transition before a new nonzero
        // allowance. Clearing first preserves the call-scoped allowance model
        // while remaining compatible with that common approval convention.
        if amount {
            mstore(0x34, 0)
            let reset := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), reset)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), reset)) {
                    mstore(0x00, 0x3e3f8f73)
                    revert(0x1c, 0x04)
                }
            }
            // The reset call wrote its return data over 0x00..0x20, and the
            // calldata being reused lives at 0x10..0x54 - so that write lands
            // on the selector. Without rebuilding it here the approve below
            // ships whatever the reset returned as its selector, which is why
            // this path failed against every ordinary ERC-20 rather than only
            // the USDT-style tokens it exists for.
            mstore(0x14, to)
            mstore(0x00, 0x095ea7b3000000000000000000000000)
        }

        mstore(0x34, amount)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x3e3f8f73)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x34, 0)
    }
}

function balanceOf(address token, address account) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, account)
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(mload(0x20), and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20)))
    }
}
