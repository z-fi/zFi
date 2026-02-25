// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice CoW Protocol adapter for zFi. Holds sell-side tokens while a CoW
///         batch-auction order is live and implements ERC-1271 so the CoW
///         settlement contract can verify the order on-chain.
///
///         Unlike the synchronous adapters (Matcha, Parasol, Kyberol), Cowol
///         holds tokens between deposit and async CoW settlement. To prevent
///         a third party from approving rogue order digests via the public
///         SafeExecutor, swap() recomputes the EIP-712 order digest on-chain
///         and enforces that sellAmount + feeAmount equals the contract's full
///         token balance (the deposit that snwap just transferred in).
contract Cowol {
    address constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110; // GPv2VaultRelayer

    /// EIP-712 constants for GPv2Order digest computation.
    bytes32 constant ORDER_TYPE_HASH = keccak256(
        "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,"
        "uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,"
        "string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
    );
    bytes32 constant KIND_SELL     = keccak256("sell");
    bytes32 constant BALANCE_ERC20 = keccak256("erc20");
    bytes32 constant DOMAIN_SEPARATOR = 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;

    uint32 constant MAX_EXPIRY = 1200; // 20 minutes max order lifetime

    /// @dev order digest → approved.
    mapping(bytes32 => bool) public validDigests;
    /// @dev token → expiry timestamp for recovery.
    mapping(address => uint32)  public expiry;
    /// @dev token → receiver for recovery.
    mapping(address => address) public recipient;

    /// @notice Called via SafeExecutor from zRouter.snwap(). Tokens are already
    ///         in this contract (transferred by snwap before this call).
    ///
    ///         Computes the EIP-712 order digest on-chain from the provided
    ///         parameters and validates that sellAmount + feeAmount equals this
    ///         contract's entire balance of tokenIn (the freshly-deposited amount).
    ///
    /// @param data abi.encode(buyToken, receiver, sellAmount, buyAmount,
    ///                        validTo, appData, feeAmount)
    function swap(address, address tokenIn, address, address, bytes calldata data) public payable {
        // Lazy-approve VaultRelayer to pull sell tokens.
        if (allowance(tokenIn, address(this), VAULT_RELAYER) == 0) {
            safeApprove(tokenIn, VAULT_RELAYER, type(uint256).max);
        }

        // Decode order parameters from data.
        (
            address buyToken,
            address receiver,
            uint256 sellAmount,
            uint256 buyAmount,
            uint32  validTo,
            bytes32 appData,
            uint256 feeAmount
        ) = abi.decode(data, (address, address, uint256, uint256, uint32, bytes32, uint256));

        // The deposit must match sellAmount + feeAmount exactly.
        require(sellAmount + feeAmount == balanceOf(tokenIn));

        // Cap expiry and store recovery info.
        require(validTo <= uint32(block.timestamp) + MAX_EXPIRY);
        expiry[tokenIn]    = validTo;
        recipient[tokenIn] = receiver;

        // Compute the EIP-712 struct hash → order digest on-chain.
        bytes32 structHash = keccak256(abi.encode(
            ORDER_TYPE_HASH,
            tokenIn,        // sellToken
            buyToken,
            receiver,
            sellAmount,
            buyAmount,
            validTo,
            appData,
            feeAmount,
            KIND_SELL,      // only sell orders supported
            false,          // partiallyFillable = false
            BALANCE_ERC20,  // sellTokenBalance
            BALANCE_ERC20   // buyTokenBalance
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            bytes2(0x1901),
            DOMAIN_SEPARATOR,
            structHash
        ));
        validDigests[digest] = true;
    }

    /// @notice ERC-1271 signature validation. GPv2Settlement calls this to
    ///         verify that Cowol authorised the order.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return validDigests[hash] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    /// @notice Recover tokens after an order expires unfilled.
    function recover(address token) external {
        require(block.timestamp > expiry[token]);
        safeTransfer(token, recipient[token], balanceOf(token));
    }

    receive() external payable {}
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
        mstore(0x34, amount)
        mstore(0x00, 0x095ea7b3000000000000000000000000)
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

function allowance(address token, address owner, address spender) view returns (uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x40, spender)
        mstore(0x2c, shl(96, owner))
        mstore(0x0c, 0xdd62ed3e000000000000000000000000)
        amount := mul(mload(0x20), and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x1c, 0x44, 0x20, 0x20)))
        mstore(0x40, m)
    }
}
