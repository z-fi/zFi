// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title Fwabol
/// @notice zRouter adapter for FWAToken, which cannot be forwarded.
///
/// @dev WHY THIS IS NOT A PASS-THROUGH. Every other venue adapter here takes
///      delivery of the output and forwards it to the recipient. FWAToken makes
///      that impossible, and not by accident - `_afterTokenTransfer` reverts
///      `InvalidTransfer()` on every transfer except four:
///
///        from == 0 || to == 0                  mint / burn
///        isDistributor[from] || [to]           owner-managed distributors
///        from == owner()  || to == owner()
///        from == poolManager || to == pm       and ONLY up to a transient
///                                              allowance the hook raises
///                                              during the swap
///
///      A pass-through does PoolManager -> adapter -> recipient. That second hop
///      has neither side equal to the PoolManager, the owner, or a distributor,
///      so it hits the final `revert`. Any adapter that takes delivery of FWA
///      freezes it at its own address permanently.
///
///      The direct payload works because `TAKE_ALL` resolves its recipient to
///      the Universal Router's `_msgSender()`, which for an EOA call is the
///      user - so the PoolManager pays them and the pm branch is satisfied.
///      Route that same payload through a contract and `_msgSender()` becomes
///      the contract. This adapter therefore builds `TAKE` (0x0e), which names
///      a recipient explicitly, instead of `TAKE_ALL` (0x0f), which infers one.
///      FWA is never owed to this contract at any point in the transaction.
///
/// @dev SUPERSEDED BY `Fwabol2`, AND THE PARAGRAPH BELOW IS WRONG. It reasons
///      from the Universal Router's rules as though they were v4's. Settling in
///      v4 is `sync()`, get the tokens to the PoolManager by any means,
///      `settle()` - the credit comes from the measured balance change, and the
///      payer need not be the locker. Unlock the PoolManager directly and a
///      sell works fine without the adapter ever holding FWA: the seller pays
///      the PoolManager in one hop, which is a shape the token permits. That is
///      what `Fwabol2` does, in both directions, and it is proven on a fork in
///      `Fwabol2Fork.t.sol`. This contract remains live and correct for buys;
///      it is simply doing through a router what it never needed a router for.
///      The text below is kept as written because it is deployed.
///
/// @dev BUY ONLY, AND THAT IS NOT A LIMITATION THIS CONTRACT CHOSE. Selling FWA
///      needs the FWA to move user -> PoolManager, and v4's SETTLE pays from the
///      router's `_msgSender()`. Through an adapter that is the ADAPTER, so the
///      adapter would have to hold FWA before settling - which is the exact
///      thing the token forbids. There is no recipient-style escape hatch on the
///      paying side the way `TAKE` provides one on the receiving side. FWA sells
///      must therefore go straight from the user to the Universal Router, with
///      Permit2, as the live sell payload does; they cannot be batched through
///      zRouter. Buys can, and this contract is that half.
///
/// @dev A CONSEQUENCE WORTH HAVING. Because the recipient is the user, zRouter's
///      `snwap` balance-delta postcondition still measures the right account, so
///      FWA swaps keep a real `amountOutMin` guard. Cowol had to give that up.
contract Fwabol {
    /// @dev Uniswap Universal Router, bound once - a caller-supplied router
    ///      would let anyone pair this contract's ETH with arbitrary calldata.
    ///      Mainnet is 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af, read off the
    ///      Permit2 spender in the live sell payload rather than guessed.
    address public immutable router;

    /// @dev The pool is fixed: ETH / FWA, fee 0, tickSpacing 60, and the hook
    ///      that prices it. Hardcoded rather than passed, so a caller cannot
    ///      point this at a different hook and have it settle anyway. Fee zero
    ///      with a hook is the tell that pricing lives in the hook.
    address internal constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address internal constant HOOK = 0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444;
    uint24 internal constant FEE = 0;
    int24 internal constant TICK_SPACING = 60;

    /// @dev Universal Router command and v4-periphery action ids.
    ///
    ///      V4_SWAP then SWEEP. The sweep is the answer to the one way ETH could
    ///      go missing that this contract cannot otherwise see: if the pool ever
    ///      consumes less than the exact-in amount, `SETTLE_ALL` pays only what
    ///      is owed and the remainder is left sitting in the ROUTER, not here -
    ///      where this contract's own balance check would never find it, and
    ///      where the next caller of the Universal Router would take it. Today
    ///      the hook consumes the whole input and the sweep moves zero (see
    ///      `test_theSweepIsANoOpWhileTheHookConsumesEverything`), so this is
    ///      insurance against the hook's behaviour changing, bought for one
    ///      command byte. Like `TAKE`, `SWEEP` names its recipient, so the
    ///      remainder goes to the user rather than through this contract.
    bytes internal constant COMMANDS = hex"1004"; // V4_SWAP, SWEEP
    bytes internal constant ACTIONS = hex"060c0e"; // SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE

    error BadRecipient();
    error BadRouter();
    error NothingIn();
    /// @dev No `RouterFailed`: a failing router call bubbles the router's own
    ///      revert instead, which is the only part with any information in it.
    error RefundFailed();

    constructor(address _router) {
        if (_router == address(0) || _router.code.length == 0) revert BadRouter();
        router = _router;
    }

    /// @notice Swap the attached ETH for FWA, delivered straight to `recipient`.
    /// @param recipient Who receives the FWA. Never this contract - see above,
    ///                  it would be unrecoverable rather than merely wrong.
    /// @param minOut    Floor on FWA out, enforced by the pool.
    /// @param deadline  Passed through to the router.
    function swapEthForFwa(address recipient, uint128 minOut, uint256 deadline) external payable {
        if (recipient == address(0) || recipient == address(this)) revert BadRecipient();
        if (msg.value == 0) revert NothingIn();

        bytes[] memory params = new bytes[](3);
        // SWAP_EXACT_IN_SINGLE. currency0 is native ETH, so zeroForOne buys FWA.
        //
        // `uint128(msg.value)` cannot silently truncate into a smaller swap:
        // uint128 tops out at 3.4e38 wei, some twelve orders of magnitude above
        // the entire ETH supply. Were it somehow reached, SETTLE_ALL would owe
        // the untruncated `msg.value` against a smaller swap and v4 would revert
        // on the unsettled delta - loud, not lossy.
        params[0] = abi.encode(
            PoolKey(address(0), FWA, FEE, TICK_SPACING, HOOK), true, uint128(msg.value), minOut, bytes("")
        );
        // SETTLE_ALL: pay the ETH this call arrived with.
        params[1] = abi.encode(address(0), msg.value);
        // TAKE: the whole reason this contract exists. `TAKE_ALL` would infer
        // the recipient from the router's caller - this contract - and strand
        // the output. Naming the user makes the PoolManager pay them directly,
        // which is the one transfer shape FWAToken permits.
        //
        // The amount is OPEN_DELTA (zero), meaning "everything this swap is
        // owed", NOT `minOut`. TAKE moves an EXACT amount, so passing the floor
        // takes the floor and leaves the surplus owing - and v4 refuses to close
        // the lock with an unsettled delta, so every swap that did better than
        // its own minimum reverted. The floor is not lost by this: it is
        // enforced by `amountOutMinimum` inside the swap itself, above.
        params[2] = abi.encode(FWA, recipient, uint256(0));

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ACTIONS, params);
        // SWEEP(native, recipient, minAmount 0): hand back anything the swap did
        // not spend. A zero minimum makes it a no-op when there is nothing to
        // sweep, which is the normal case.
        inputs[1] = abi.encode(address(0), recipient, uint256(0));

        uint256 base = address(this).balance - msg.value;
        (bool ok, bytes memory ret) = router.call{value: msg.value}(
            abi.encodeWithSelector(0x3593564c, COMMANDS, inputs, deadline)
        );
        if (!ok) {
            // Bubble the router's own revert; a generic failure here would hide
            // the hook's reason, which is the only useful part.
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        // If the router ever refunds unspent ETH it refunds to ITS caller,
        // which is this contract, so anything above the balance the call
        // started with goes on to the recipient. On the live pool that refund
        // is measured at zero: the hook prices the swap and consumes the whole
        // exact-in amount, and `SETTLE_ALL` pays exactly that. An earlier read
        // of this code claimed 0.000577 ETH of a 0.001 ETH buy was retained;
        // that number was the balance mainnet already holds at the address
        // Foundry deploys test contracts to, not a refund - see
        // `test_adapterEthDeltaIsZero`. The sweep stays because "the hook
        // consumes it all" is the pool's behaviour today, not a guarantee, and
        // because `base` is a snapshot rather than a zero-check: pre-existing
        // or force-sent ETH is excluded from the refund instead of being
        // handed to whoever swaps next.
        uint256 refund = address(this).balance - base;
        if (refund != 0) {
            (bool sent,) = recipient.call{value: refund}("");
            if (!sent) revert RefundFailed();
        }
    }

    /// @dev Nothing should ever rest here. FWA cannot, by construction; ETH can
    ///      only arrive as a router refund mid-call.
    receive() external payable {
        if (msg.sender != router) revert BadRouter();
    }
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}
