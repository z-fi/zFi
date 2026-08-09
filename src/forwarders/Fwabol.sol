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
    bytes internal constant CMD_V4_SWAP = hex"10";
    bytes internal constant ACTIONS = hex"060c0e"; // SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE

    error BadRecipient();
    error BadRouter();
    error NothingIn();
    error RouterFailed();

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
        params[0] = abi.encode(
            PoolKey(address(0), FWA, FEE, TICK_SPACING, HOOK), true, uint128(msg.value), minOut, bytes("")
        );
        // SETTLE_ALL: pay the ETH this call arrived with.
        params[1] = abi.encode(address(0), msg.value);
        // TAKE: the whole reason this contract exists. `TAKE_ALL` would infer
        // the recipient from the router's caller - this contract - and strand
        // the output. Naming the user makes the PoolManager pay them directly,
        // which is the one transfer shape FWAToken permits.
        params[2] = abi.encode(FWA, recipient, uint256(minOut));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ACTIONS, params);

        (bool ok, bytes memory ret) = router.call{value: msg.value}(
            abi.encodeWithSelector(0x3593564c, CMD_V4_SWAP, inputs, deadline)
        );
        if (!ok) {
            // Bubble the router's own revert; a generic failure here would hide
            // the hook's reason, which is the only useful part.
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
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
