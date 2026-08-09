// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

/// @title Swapbol
/// @notice zRouter snwap forwarder for Swapboard and Dutchboard, so resting
///         liquidity and a zQuoter-built AMM remainder can settle atomically.
///
/// @dev The trust model is zRouter's, not this contract's. snwap sends tokenIn
///      here, calls this through SafeExecutor (which holds no approvals), then
///      measures the recipient's tokenOut balance and reverts unless it grew by
///      at least amountOutMin. So nothing here has to be trusted: a bug or a
///      hostile board can at worst make the fill produce too little, and the
///      router rejects it.
///
///      WHICH BOARD DECIDES HOW MUCH THIS CONTRACT TRANSITS. The current
///      Swapboard and Dutchboard take a recipient and pay the user directly;
///      the legacy v1 Swapboard pays msg.sender, which is this contract:
///
///        v1  0x000000fF3D7A2d373615141d7489Ca66683DbecF  fillOrder(uint256,uint256)
///        current replacement Swapboard                   fillOrder(uint256,uint256,uint256,uint256,address)
///        Dutchboard                                      fill(uint256,uint128,address,uint256)
///
///      So against v1 the sweep below is not a fallback for a refunded leg - it
///      is the delivery path, and the whole output sits here until it runs.
///      snwap's amountOutMin does catch output that never arrives, but that is
///      a check one contract away; the guard and the scoped approval below are
///      what stop the output being taken in the first place. `data` has to be
///      encoded per board version; current Swapboard and Dutchboard honour a
///      recipient inside it.
///
///      EVERY ENTRY POINT BINDS ITS VENUE TO IMMUTABLE DEPLOYMENT CONFIGURATION.
///      `fill` takes a board address, but only to select among the three
///      bindings - it is not a call target drawn from calldata. Its calldata
///      is decoded and reconstructed as one of the reviewed fill methods; a
///      creation, cancellation, approval, sweep, or arbitrary fallback call
///      is rejected before any approval is granted.
///
///      APPROVALS ARE SCOPED TO THE CALL. The sibling forwarders (Matcha,
///      Parasol, OneInch, ...) lazily grant an infinite approval and never
///      revoke it, which is safe for them because the spender is a hardcoded
///      constant - a known aggregator. Here the spender is one of three
///      immutable venues, and the approval is exact and revoked before
///      returning, so no capability survives the call.
///
///      Gating msg.sender would not substitute for this: zRouter.snwap is
///      itself public and forwards arbitrary executorData through SafeExecutor,
///      so an attacker reaches this contract through the front door either way.
///
///      ERC-20 FUNDING IS CHECKPOINTED. zRouter first calls `checkpoint(tokenIn)`
///      through its SafeExecutor, then transfers the exact route budget here
///      and calls the selected fill entry point through that same SafeExecutor.
///      The transient, same-caller checkpoint makes only that fresh balance
///      increase available to the route. Tokens donated before the checkpoint
///      are neither approved nor swept to the caller, and every checkpoint is
///      consumed before an external token or venue call can re-enter.
///
///      REENTRANCY. The board call can hand control to a token, an NFT, or a
///      maker chosen by whoever created the order. Without a guard that code
///      can call back into `fill` and point the sweeps - which pay a
///      caller-supplied recipient - at itself, taking the unspent input this
///      contract is holding for the user mid-settlement. snwap only measures
///      tokenOut at the recipient, so it cannot see that loss.
contract Swapbol {
    /// @dev The AMM calldata consumed by `fillPlanAndSwap` is produced by
    ///      zQuoter for this router. Keeping the target fixed preserves the
    ///      scoped-approval argument above: arbitrary calldata cannot choose
    ///      an arbitrary spender.
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev These are deployment trust roots, not calldata hints. Keeping the
    ///      venues immutable makes the "supported books only" property real:
    ///      a caller cannot relabel an arbitrary contract (or the deprecated
    ///      intermediate Swapboard) as `boardV1` for one invocation.
    address public immutable boardV1;
    address public immutable boardCurrent;
    address public immutable dutchboard;

    /// @notice Same ABI shape as SwapboardView.Fill. The board address selects
    ///         one of the immutable venue bindings; `isPartial` is quote
    ///         metadata and does not need to be trusted during execution.
    struct Fill {
        uint256 orderId;
        address board;
        uint256 payIn;
        uint256 getOut;
        bool isPartial;
    }

    /// @dev Transient reentrancy flag. `uint32(bytes4(keccak256("Reentrancy()")))`.
    uint256 constant REENTRANCY_GUARD_SLOT = 0xab143c06;
    uint256 constant CHECKPOINT_SEED = 0x5fb385da;

    /// @dev Reverted from assembly by selector; declared so the ABI carries them.
    error Reentrancy();
    error ETHTransferFailed();

    error BadPlan();
    error BadVenue();
    error BadCheckpoint();
    error AmountTooLarge();
    error DeadlineExpired();
    error UnknownBoard(address board);
    error InputMismatch(uint256 expected, uint256 actual);
    error WETHAmountMismatch(uint256 expected, uint256 actual);

    constructor(address boardV1_, address boardCurrent_, address dutchboard_) {
        if (
            boardV1_ == address(0) || boardCurrent_ == address(0) || dutchboard_ == address(0)
                || boardV1_ == boardCurrent_ || boardV1_ == dutchboard_ || boardCurrent_ == dutchboard_
                || boardV1_.code.length == 0 || boardCurrent_.code.length == 0 || dutchboard_.code.length == 0
        ) revert BadVenue();
        boardV1 = boardV1_;
        boardCurrent = boardCurrent_;
        dutchboard = dutchboard_;
    }

    /// @notice Snapshot an ERC-20 input balance immediately before funding.
    /// @dev The same immediate caller must consume this checkpoint later in the
    ///      transaction. zRouter does both calls through its immutable
    ///      SafeExecutor. The checkpoint is transient, single-use, and cleared
    ///      before either the token or a venue receives control.
    function checkpoint(address token) external {
        if (token == address(0) || token.code.length == 0) revert BadCheckpoint();
        bytes32 slot = _checkpointSlot(token);
        uint256 active;
        assembly ("memory-safe") {
            active := tload(slot)
        }
        if (active != 0) revert BadCheckpoint();
        uint256 tokenBalance = balanceOf(token);
        assembly ("memory-safe") {
            tstore(slot, 1)
            tstore(add(slot, 1), tokenBalance)
        }
    }

    /// @param board    Venue holding the order. Must be one of the immutable
    ///                 bindings. `data` must be the exact ABI for that venue's
    ///                 reviewed fill method; it is decoded and selector-checked.
    /// @param tokenIn  What the taker pays the maker; snwap has already sent it
    ///                 here. address(0) for ETH.
    /// @param tokenOut What the order pays out, swept if any lands here.
    /// @param recipient Final owner of the output, also passed to the board.
    /// @param refundTo Where unspent input goes. Deliberately independent of
    ///                 `recipient`, as in `fillPlan`: on an exact-output or
    ///                 relayed fill the change belongs to whoever funded the
    ///                 route, who is not always the party being paid out.
    /// @param data     Encoded fill call, e.g. fillOrder(id, deadline, amount, minAmountA, recipient).
    function fill(
        address board,
        address tokenIn,
        address tokenOut,
        address recipient,
        address refundTo,
        bytes calldata data
    ) public payable {
        _enter();
        uint256 ethBase = address(this).balance - msg.value;
        uint256 wethBase = balanceOf(WETH);
        if (board != boardV1 && board != boardCurrent && board != dutchboard) revert UnknownBoard(board);
        // `tokenIn == tokenOut` unconditionally, which `_checkPlan` already
        // requires and this guard used to exempt for the native/native case.
        // ETH in and ETH out leaves output and unspent change in ONE balance
        // with nothing to tell them apart, and `_sweep` resolves that tie by
        // paying the whole delta to `recipient` - so the change silently goes to
        // the party being paid out instead of the party who funded the route.
        // On a relayed or exact-output fill those are different people. There is
        // no accounting that splits it after the fact; the route shape has to go.
        if (
            recipient == address(0) || recipient == address(this) || refundTo == address(0)
                || refundTo == address(this) || tokenIn == tokenOut || (tokenIn == address(0) && tokenOut == WETH)
                || (tokenIn == WETH && tokenOut == address(0))
        ) revert BadPlan();

        _validateFillData(board, tokenIn, tokenOut, recipient, data);

        uint256 inputBase;
        uint256 outputBase = tokenOut == address(0) ? 0 : balanceOf(tokenOut);

        // The board pulls tokenIn with transferFrom, so it needs an allowance.
        // Granted for exactly what is being forwarded - never `type(uint256).max`,
        // so a board cannot pull more than the caller actually sent - and
        // revoked below, so no capability survives this call.
        uint256 approved;
        if (tokenIn != address(0)) {
            (inputBase, approved) = _consumeFunding(tokenIn);
            if (approved != 0) safeApprove(tokenIn, board, approved);
        }

        // Only what the caller sent. Using the whole balance would spend any
        // ETH that was already sitting here - donated, refunded by an earlier
        // leg, or simply present at the deployment address - on this caller's
        // behalf, which is the "ETH value not bound to actions" pattern.
        uint256 value = tokenIn == address(0) ? msg.value : 0;

        assembly ("memory-safe") {
            let m := mload(0x40)
            calldatacopy(m, data.offset, data.length)
            if iszero(call(gas(), board, value, m, data.length, codesize(), 0x00)) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }

        if (approved != 0) safeApprove(tokenIn, board, 0);

        _sweep(tokenIn, tokenOut, recipient, refundTo, ethBase, wethBase, inputBase, outputBase);
        _leave();
    }

    /// @notice Execute a mixed plan returned by SwapboardView in one snwap.
    /// @dev Only the repository's supported books are accepted: legacy v1,
    ///      current Swapboard, and Dutchboard. The deprecated intermediate
    ///      Swapboard generation is intentionally not an argument and cannot
    ///      be selected.
    ///
    ///      For a current Swapboard leg `payIn` is fillAmountB. For a
    ///      Dutchboard leg `getOut` is take and `payIn` is maxCost. Legacy v1
    ///      is all-or-nothing and ignores both values in calldata, but payIn
    ///      still scopes its token approval.
    ///
    ///      Call this through zRouter.snwap with amountIn equal to the sum of
    ///      payIn and amountOutMin set to the protected book output. Native ETH
    ///      pays native-quoted Dutchboard legs directly and is wrapped per leg
    ///      for Swapboard or WETH-quoted Dutchboard liquidity. `refundTo` is
    ///      deliberately independent of the output recipient so exact-output
    ///      and relayed calls cannot misdirect change.
    function fillPlan(
        address tokenIn,
        address tokenOut,
        address recipient,
        address refundTo,
        uint256 deadline,
        Fill[] calldata fills
    ) public payable {
        _enter();
        uint256 ethBase = address(this).balance - msg.value;
        uint256 wethBase = balanceOf(WETH);
        _checkPlan(tokenIn, tokenOut, recipient, refundTo, deadline, fills);

        uint256 plannedIn = _bookInput(fills);
        uint256 inputBase = _checkInput(tokenIn, plannedIn);
        uint256 outputBase = tokenOut == address(0) ? 0 : balanceOf(tokenOut);
        _fillLegs(tokenIn, tokenOut, recipient, deadline, fills);

        _sweep(tokenIn, tokenOut, recipient, refundTo, ethBase, wethBase, inputBase, outputBase);
        _leave();
    }

    /// @notice Execute book legs and a zQuoter-built AMM remainder inside one
    ///         protected zRouter snwap.
    /// @dev This is deliberately one executor call rather than two sibling
    ///      snwaps in zRouter.multicall. Delegatecalled multicall entries all
    ///      observe the same msg.value, so sibling native-input snwaps would
    ///      each see the whole ETH value. A single snwap forwards the route's
    ///      budget once; this function partitions it between exact book legs
    ///      and the AMM's exact-in amount or exact-out maximum.
    ///
    ///      For ERC-20 input, zRouter may fund the snwap either directly from
    ///      an allowance or from its transient balance after Permit2. In both
    ///      cases the tokens arrive here before this call. The AMM allowance is
    ///      exact and revoked immediately, just like every board allowance.
    ///
    /// @param ammIn   Exact AMM input for exact-in, or maximum AMM input for
    ///                exact-out. Must be zero exactly when ammData is empty.
    /// @param ammData Executable calldata returned by zQuoter for ZROUTER.
    function fillPlanAndSwap(
        address tokenIn,
        address tokenOut,
        address recipient,
        address refundTo,
        uint256 deadline,
        Fill[] calldata fills,
        uint256 ammIn,
        bytes calldata ammData
    ) public payable {
        _enter();
        uint256 ethBase = address(this).balance - msg.value;
        uint256 wethBase = balanceOf(WETH);
        _checkPlan(tokenIn, tokenOut, recipient, refundTo, deadline, fills);
        if ((ammIn == 0) != (ammData.length == 0)) revert BadPlan();
        if (ammData.length != 0) _validateAmmData(ammData);

        uint256 plannedIn = _bookInput(fills) + ammIn;
        uint256 inputBase = _checkInput(tokenIn, plannedIn);
        uint256 outputBase = tokenOut == address(0) ? 0 : balanceOf(tokenOut);
        _fillLegs(tokenIn, tokenOut, recipient, deadline, fills);

        if (ammIn != 0) {
            if (tokenIn != address(0)) safeApprove(tokenIn, ZROUTER, ammIn);
            _call(ZROUTER, tokenIn == address(0) ? ammIn : 0, ammData);
            if (tokenIn != address(0)) safeApprove(tokenIn, ZROUTER, 0);
        }

        _sweep(tokenIn, tokenOut, recipient, refundTo, ethBase, wethBase, inputBase, outputBase);
        _leave();
    }

    function _bookInput(Fill[] calldata fills) internal pure returns (uint256 plannedIn) {
        for (uint256 i; i < fills.length; ++i) {
            plannedIn += fills[i].payIn;
        }
    }

    function _checkPlan(
        address tokenIn,
        address tokenOut,
        address recipient,
        address refundTo,
        uint256 deadline,
        Fill[] calldata fills
    ) internal view {
        if (
            recipient == address(0) || recipient == address(this) || refundTo == address(0) || refundTo == address(this)
                || fills.length == 0 || tokenIn == tokenOut || (tokenIn == WETH && tokenOut == address(0))
        ) revert BadPlan();

        for (uint256 i; i < fills.length; ++i) {
            _validatePlanLeg(tokenIn, tokenOut, fills[i]);
        }

        // ETH -> WETH is normally a canonical wrap, so accepting arbitrary book
        // legs would blur input and output accounting (and could make same-asset
        // Swapboard orders look like price improvement). The useful exception is
        // Dutch liquidity that actually sells WETH for native ETH: every book leg
        // must therefore be on the immutable Dutchboard and quote literal ETH.
        // The AMM remainder may then be zQuoter's ordinary zRouter wrap calldata.
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
    }

    /// @dev zQuoter emits only zRouter's swap/settlement vocabulary. The target is
    /// immutable, but that alone is not enough: zRouter also exposes a generic
    /// `execute` entry point and owner/permit helpers. A caller-supplied AMM blob
    /// must not be able to turn this forwarder into a general zRouter executor.
    /// Multicalls are recursively checked because zQuoter wraps routes and sweeps
    /// in one or more `multicall` envelopes.
    function _validateAmmData(bytes memory data) internal pure {
        if (data.length < 4) revert BadPlan();
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }

        if (selector == _selector("multicall(bytes[])")) {
            bytes[] memory calls = abi.decode(_withoutSelector(data), (bytes[]));
            if (calls.length == 0) revert BadPlan();
            for (uint256 i; i < calls.length; ++i) {
                _validateAmmData(calls[i]);
            }
            return;
        }

        if (
            selector == _selector("swapV2(address,bool,address,address,uint256,uint256,uint256)")
                || selector == _selector("swapVZ(address,bool,uint256,address,address,uint256,uint256,uint256,uint256,uint256)")
                || selector == _selector("swapV3(address,bool,uint24,address,address,uint256,uint256,uint256)")
                || selector == _selector("swapV4(address,bool,uint24,int24,address,address,uint256,uint256,uint256)")
                || selector == _selector(
                    "swapCurve(address,bool,address[11],uint256[4][5],address[5],uint256,uint256,uint256)"
                )
                || selector == _selector("exactETHToSTETH(address)")
                || selector == _selector("exactETHToWSTETH(address)")
                || selector == _selector("ethToExactSTETH(address,uint256)")
                || selector == _selector("ethToExactWSTETH(address,uint256)")
                || selector == _selector("deposit(address,uint256,uint256)")
                || selector == _selector("wrap(uint256)")
                || selector == _selector("unwrap(uint256)")
                || selector == _selector("sweep(address,uint256,uint256,address)")
        ) return;

        revert BadPlan();
    }

    function _withoutSelector(bytes memory data) internal pure returns (bytes memory body) {
        body = new bytes(data.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = data[i + 4];
    }

    function _selector(string memory signature) internal pure returns (bytes4 result) {
        result = bytes4(keccak256(bytes(signature)));
    }

    function _checkInput(address tokenIn, uint256 plannedIn) internal returns (uint256 inputBase) {
        if (tokenIn == address(0)) {
            if (msg.value != plannedIn) revert InputMismatch(plannedIn, msg.value);
        } else {
            uint256 funded;
            (inputBase, funded) = _consumeFunding(tokenIn);
            if (funded != plannedIn) revert InputMismatch(plannedIn, funded);
        }
    }

    function _consumeFunding(address token) internal returns (uint256 base, uint256 funded) {
        bytes32 slot = _checkpointSlot(token);
        uint256 active;
        assembly ("memory-safe") {
            active := tload(slot)
            base := tload(add(slot, 1))
            tstore(slot, 0)
            tstore(add(slot, 1), 0)
        }
        if (active == 0) revert BadCheckpoint();
        uint256 current = balanceOf(token);
        // A balance below the checkpoint means the snapshot no longer describes
        // this call's funding. Fail here rather than encoding the failure as a
        // number: `fill` passes `funded` straight to safeApprove, so a sentinel
        // would briefly grant the venue an unbounded allowance.
        if (current < base) revert BadCheckpoint();
        funded = current - base;
    }

    function _checkpointSlot(address token) internal view returns (bytes32 slot) {
        uint256 seed = CHECKPOINT_SEED;
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(0x00, caller())
            mstore(0x20, token)
            mstore(0x40, seed)
            slot := keccak256(0x00, 0x60)
            mstore(0x40, free)
        }
    }

    /// @dev The generic entry point is retained for integrations that already
    /// use it, but it is a typed firewall rather than an arbitrary board call.
    /// Exact calldata lengths also prevent ABI-decoder-tolerated trailing data.
    function _validateFillData(
        address board,
        address tokenIn,
        address tokenOut,
        address recipient,
        bytes calldata data
    ) internal view {
        if (data.length < 4) revert BadPlan();
        bytes4 selector;
        assembly ("memory-safe") {
            selector := calldataload(data.offset)
        }

        if (board == boardV1) {
            if (selector != ISwapboardV1Fill.fillOrder.selector || data.length != 68 || tokenIn == address(0)) {
                revert BadPlan();
            }
            (uint256 orderId,) = abi.decode(data[4:], (uint256, uint256));
            _validateV1Order(orderId, tokenIn, tokenOut);
            return;
        }

        if (board == boardCurrent) {
            if (selector == ISwapboardCurrentFill.fillOrder.selector || selector == ISwapboardCurrentFill.fillOrderUnwrap.selector) {
                if (data.length != 164 || tokenIn == address(0)) revert BadPlan();
                (uint256 orderId,, , , address to) = abi.decode(data[4:], (uint256, uint256, uint256, uint256, address));
                if (to != address(0) && to != recipient) revert BadPlan();
                if (tokenOut == address(0)) {
                    if (selector != ISwapboardCurrentFill.fillOrderUnwrap.selector) revert BadPlan();
                } else if (selector != ISwapboardCurrentFill.fillOrder.selector) {
                    revert BadPlan();
                }
                _validateCurrentOrder(orderId, tokenIn, tokenOut);
                return;
            }
            if (selector == ISwapboardCurrentFill.fillOrderWithEth.selector) {
                if (data.length != 132 || tokenIn != address(0)) revert BadPlan();
                (uint256 orderId,, , address to) = abi.decode(data[4:], (uint256, uint256, uint256, address));
                if (to != address(0) && to != recipient) revert BadPlan();
                // fillOrderWithEth returns WETH. For a native output route the
                // output must land here so `_sweep` can unwrap it once.
                if (tokenOut == address(0) && to != address(0) && to != address(this)) revert BadPlan();
                _validateCurrentOrder(orderId, address(0), tokenOut);
                return;
            }
            revert BadPlan();
        }

        if (board == dutchboard) {
            if (selector != IDutchFill.fill.selector || data.length != 132) revert BadPlan();
            (uint256 orderId,, address to,) = abi.decode(data[4:], (uint256, uint128, address, uint256));
            if (to != address(0) && to != recipient) revert BadPlan();
            // A native-output Dutch listing pays WETH. It must pay this
            // contract, not the final recipient, so the output can be unwrapped.
            if (tokenOut == address(0) && to != address(0) && to != address(this)) revert BadPlan();
            _validateDutchListing(orderId, tokenIn, tokenOut);
            // `_validateDutchListing` accepts native input against a WETH-quoted
            // listing because `_fillLegs` WRAPS each leg's `payIn` first. This
            // entry point has no wrap step - it forwards `msg.value` as call
            // value - and Dutchboard rejects value on a non-native quote, so the
            // combination validated here and then reverted deep inside the board
            // with the board's error. Refuse it where the reason is legible.
            if (tokenIn == address(0)) {
                (,, address quote,,,,) = IDutchQuote(dutchboard).legOf(orderId);
                if (quote != address(0)) revert BadPlan();
            }
            return;
        }

        revert UnknownBoard(board);
    }

    function _validatePlanLeg(address tokenIn, address tokenOut, Fill calldata leg) internal view {
        if (leg.board == boardV1) {
            _validateV1Order(leg.orderId, tokenIn, tokenOut);
        } else if (leg.board == boardCurrent) {
            _validateCurrentOrder(leg.orderId, tokenIn, tokenOut);
        } else if (leg.board == dutchboard) {
            _validateDutchListing(leg.orderId, tokenIn, tokenOut);
        } else {
            revert UnknownBoard(leg.board);
        }
    }

    function _validateV1Order(uint256 orderId, address tokenIn, address tokenOut) internal view {
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        ISwapboardV1OrderView.Order[] memory orders = ISwapboardV1OrderView(boardV1).getOrders(ids);
        if (orders.length != 1 || !orders[0].active) revert BadPlan();
        if (orders[0].tokenA != _swapboardOutput(tokenOut) || orders[0].tokenB != _swapboardInput(tokenIn)) {
            revert BadPlan();
        }
    }

    function _validateCurrentOrder(uint256 orderId, address tokenIn, address tokenOut) internal view {
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        ISwapboardCurrentOrderView.Order[] memory orders = ISwapboardCurrentOrderView(boardCurrent).getOrders(ids);
        if (orders.length != 1 || !orders[0].active || orders[0].nftA || orders[0].nftB) revert BadPlan();
        if (orders[0].tokenA != _swapboardOutput(tokenOut) || orders[0].tokenB != _swapboardInput(tokenIn)) {
            revert BadPlan();
        }
    }

    /// @dev One packed read rather than three staticcalls. Three separate reads
    ///      of a live book are three chances to see a listing that changed
    ///      between them; `legOf` answers from a single storage view and reports
    ///      zeroes for a listing that is closed, frozen or expired, so a stale
    ///      leg fails validation here instead of at settlement.
    function _validateDutchListing(uint256 orderId, address tokenIn, address tokenOut) internal view {
        (, address token, address quote, bool isNFT,,,) = IDutchQuote(dutchboard).legOf(orderId);
        if (isNFT || token != _dutchOutput(tokenOut)) revert BadPlan();
        // Native input is WRAPPED at execution time, so a WETH-quoted listing is
        // payable with it - see the `quote == WETH` branch in the leg builder,
        // which wraps exactly `payIn`. Demanding `quote == tokenIn` here made
        // that branch unreachable and refused every native-in/WETH-quoted route.
        if (quote != tokenIn && !(tokenIn == address(0) && quote == WETH)) revert BadPlan();
    }

    function _swapboardInput(address token) internal pure returns (address) {
        return token == address(0) ? WETH : token;
    }

    function _swapboardOutput(address token) internal pure returns (address) {
        return token == address(0) ? WETH : token;
    }

    function _dutchOutput(address token) internal pure returns (address) {
        return token == address(0) ? WETH : token;
    }

    function _fillLegs(address tokenIn, address tokenOut, address recipient, uint256 deadline, Fill[] calldata fills)
        internal
    {
        // Native output is represented by WETH on every book. Route book
        // payouts here, then unwrap once after all legs. AMM calldata still
        // receives the user's native-output recipient directly.
        address bookRecipient = tokenOut == address(0) ? address(this) : recipient;

        for (uint256 i; i < fills.length; ++i) {
            Fill calldata leg = fills[i];
            address board = leg.board;
            bytes memory data;
            address payToken = tokenIn;
            uint256 value;

            if (board != address(0) && board == boardV1) {
                data = abi.encodeCall(ISwapboardV1Fill.fillOrder, (leg.orderId, deadline));
                if (tokenIn == address(0)) {
                    _wrapWETH(leg.payIn);
                    payToken = WETH;
                }
            } else if (board != address(0) && board == boardCurrent) {
                data = abi.encodeCall(
                    ISwapboardCurrentFill.fillOrder,
                    (leg.orderId, deadline, leg.payIn, leg.getOut, bookRecipient)
                );
                if (tokenIn == address(0)) {
                    _wrapWETH(leg.payIn);
                    payToken = WETH;
                }
            } else if (board != address(0) && board == dutchboard) {
                if (leg.getOut > type(uint128).max) revert AmountTooLarge();
                data = abi.encodeCall(IDutchFill.fill, (leg.orderId, uint128(leg.getOut), bookRecipient, leg.payIn));
                if (tokenIn == address(0)) {
                    (,, address quote,,,,) = IDutchQuote(dutchboard).legOf(leg.orderId);
                    if (quote == address(0)) {
                        value = leg.payIn;
                    } else if (quote == WETH) {
                        _wrapWETH(leg.payIn);
                        payToken = WETH;
                    } else {
                        revert BadPlan();
                    }
                }
            } else {
                revert UnknownBoard(board);
            }

            if (payToken != address(0) && leg.payIn != 0) safeApprove(payToken, board, leg.payIn);
            _call(board, value, data);
            if (payToken != address(0) && leg.payIn != 0) safeApprove(payToken, board, 0);
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

    function _call(address target, uint256 value, bytes memory data) internal {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _wrapWETH(uint256 amount) internal {
        if (amount == 0) return;
        uint256 beforeBalance = balanceOf(WETH);
        IWETH(WETH).deposit{value: amount}();
        uint256 received = balanceOf(WETH) - beforeBalance;
        if (received != amount) revert WETHAmountMismatch(amount, received);
    }

    function _unwrapWETHDelta(uint256 wethBase) internal {
        uint256 current = balanceOf(WETH);
        if (current < wethBase) revert InputMismatch(wethBase, current);
        if (current == wethBase) return;
        uint256 amount = current - wethBase;
        uint256 ethBefore = address(this).balance;
        IWETH(WETH).withdraw(amount);
        uint256 received = address(this).balance - ethBefore;
        if (received != amount) revert WETHAmountMismatch(amount, received);
    }

    function _sweep(
        address tokenIn,
        address tokenOut,
        address recipient,
        address refundTo,
        uint256 ethBase,
        uint256 wethBase,
        uint256 inputBase,
        uint256 outputBase
    ) internal {
        // WETH held here is intermediate - wrapped to pay a book leg, or a
        // native payout still in token form - so it unwraps back to ETH. Not
        // when WETH is the route's output: then a delta is the user's proceeds
        // landing here instead of at `recipient`, and it must be swept below as
        // tokenOut rather than converted and paid out as change.
        if (tokenOut != WETH && (tokenIn == address(0) || tokenOut == address(0))) _unwrapWETHDelta(wethBase);

        if (tokenOut != address(0)) {
            _sweepTokenDelta(tokenOut, outputBase, recipient);
        }
        if (tokenIn != address(0)) {
            _sweepTokenDelta(tokenIn, inputBase, refundTo);
        }

        _sendEthDelta(ethBase, tokenOut == address(0) ? recipient : refundTo);
    }

    function _sweepTokenDelta(address token, uint256 base, address to) internal {
        uint256 current = balanceOf(token);
        if (current < base) revert InputMismatch(base, current);
        uint256 amount = current - base;
        if (amount != 0) safeTransfer(token, to, amount);
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

    receive() external payable {}
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface ISwapboardV1Fill {
    function fillOrder(uint256 orderId, uint256 deadline) external;
}

interface ISwapboardCurrentFill {
    function fillOrder(uint256 orderId, uint256 deadline, uint256 fillAmountB, uint256 minAmountA, address recipient)
        external;

    function fillOrderUnwrap(
        uint256 orderId,
        uint256 deadline,
        uint256 fillAmountB,
        uint256 minAmountA,
        address recipient
    ) external;

    function fillOrderWithEth(uint256 orderId, uint256 deadline, uint256 minAmountA, address recipient)
        external
        payable;
}

interface ISwapboardV1OrderView {
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

interface ISwapboardCurrentOrderView {
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

    function getOrders(uint256[] calldata orderIds) external view returns (Order[] memory);
}

interface IDutchFill {
    function fill(uint256 id, uint128 take, address to, uint256 maxCost) external payable;
}

interface IDutchQuote {
    function legOf(uint256 id)
        external
        view
        returns (
            address seller,
            address token,
            address quote,
            bool isNFT,
            uint128 remaining,
            uint256 lotSize,
            uint256 price
        );
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

function balanceOf(address token) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, address())
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(mload(0x20), and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20)))
    }
}
