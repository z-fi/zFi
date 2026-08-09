// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice CoW Protocol adapter for zFi. Holds sell-side tokens while a CoW
///         batch-auction order is live and implements ERC-1271 so the CoW
///         settlement contract can verify the order on-chain.
///
///         Unlike the synchronous adapters (Matcha, Parasol, Kyberol), Cowol
///         holds tokens between deposit and async CoW settlement. To prevent
///         a third party from approving rogue order digests via the public
///         SafeExecutor, swap() recomputes the EIP-712 order digest on-chain
///         and enforces that sellAmount + feeAmount equals the FRESH deposit -
///         this contract's balance net of what earlier live orders already claim.
///
///         EVERYTHING IS KEYED BY ORDER DIGEST, NEVER BY TOKEN. The previous
///         revision kept `expiry[token]` and `recipient[token]`, both
///         last-writer-wins, and matched each deposit against the contract's
///         WHOLE balance. Because `swap` is reachable by anyone through the
///         public zRouter.snwap -> SafeExecutor path and `recover` was
///         permissionless, an attacker could add one wei of a token somebody
///         else's order was resting on, write themselves in as that token's
///         recipient with an immediate expiry, and recover the entire balance.
///         No solver, no race with settlement. Custody is per-order or it is not
///         custody at all: `orders[digest]` owns an exact amount and an exact
///         receiver, `committed[token]` reserves it against later deposits, and
///         `recover` pays out that order's amount alone.
///
///         WHAT THIS STILL ASSUMES: that every deposit is registered in the same
///         transaction that transfers it, which is what snwap does - a refused
///         `swap` unwinds the transfer with it. A deposit that somehow rested
///         here unregistered would be unowned, and the next order to expire
///         would absorb it, because balance-based custody cannot attribute
///         tokens no order ever claimed.
///
///         RECOVERY ALSO REVOKES THE SIGNATURE. `isValidSignature` answers from
///         the same mapping `recover` clears, so tokens cannot be returned to
///         the depositor and then still be pulled by a solver filling the order
///         that was just unwound.
contract Cowol {
    address constant SAFE_EXECUTOR = 0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db;
    address constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110; // GPv2VaultRelayer

    /// EIP-712 constants for GPv2Order digest computation.
    bytes32 constant ORDER_TYPE_HASH = keccak256(
        "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,"
        "uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,"
        "string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
    );
    bytes32 constant KIND_SELL = keccak256("sell");
    bytes32 constant BALANCE_ERC20 = keccak256("erc20");
    bytes32 constant DOMAIN_SEPARATOR = 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;

    uint32 constant MAX_EXPIRY = 1200; // 20 minutes max order lifetime

    /// @dev A live order. `amount` is sellAmount + feeAmount, the exact deposit
    ///      this order owns, and is what makes the struct non-empty.
    struct Order {
        address sellToken;
        address receiver;
        uint32 validTo;
        uint256 amount;
    }

    /// @dev order digest → approved. Read by `isValidSignature`, cleared by
    ///      `recover` so an unwound order cannot still be settled.
    mapping(bytes32 => bool) public validDigests;
    /// @dev order digest → the deposit that order owns.
    mapping(bytes32 => Order) public orders;
    /// @dev token → sum of `amount` over live orders. Deposits are measured net
    ///      of this, so a new order can never be written against tokens an
    ///      existing one is already holding.
    mapping(address => uint256) public committed;

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
        require(msg.sender == SAFE_EXECUTOR);
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
            uint32 validTo,
            bytes32 appData,
            uint256 feeAmount
        ) = abi.decode(data, (address, address, uint256, uint256, uint32, bytes32, uint256));

        // Measured against the FRESH deposit, not the whole balance: whatever
        // earlier live orders already claim is not this order's to sell.
        //
        // `committed` is clamped to the balance first because a filled order
        // leaves its reservation behind - CoW pulls the tokens through
        // VaultRelayer without telling this contract - and a stale reservation
        // would otherwise wedge the token until somebody reaped it. Clamping is
        // safe precisely because orders are `partiallyFillable = false`: a
        // balance that dropped means an order settled in full, so the
        // reservation it left really is gone.
        uint256 balance = balanceOf(tokenIn);
        uint256 reserved = committed[tokenIn];
        if (reserved > balance) reserved = balance;
        uint256 total = sellAmount + feeAmount;
        require(total == balance - reserved);

        require(receiver != address(0));
        // Strictly in the future, so an order cannot be born recoverable, and
        // capped so a deposit cannot be parked here indefinitely.
        require(validTo > block.timestamp && validTo <= uint32(block.timestamp) + MAX_EXPIRY);

        // Compute the EIP-712 struct hash → order digest on-chain.
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPE_HASH,
                tokenIn, // sellToken
                buyToken,
                receiver,
                sellAmount,
                buyAmount,
                validTo,
                appData,
                feeAmount,
                KIND_SELL, // only sell orders supported
                false, // partiallyFillable = false
                BALANCE_ERC20, // sellTokenBalance
                BALANCE_ERC20 // buyTokenBalance
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(bytes2(0x1901), DOMAIN_SEPARATOR, structHash));

        // Identical parameters would otherwise overwrite a live order's record
        // while leaving its reservation double-counted.
        require(orders[digest].amount == 0);
        orders[digest] = Order(tokenIn, receiver, validTo, total);
        committed[tokenIn] += total;
        validDigests[digest] = true;
    }

    /// @notice ERC-1271 signature validation. GPv2Settlement calls this to
    ///         verify that Cowol authorised the order.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return validDigests[hash] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    /// @notice Recover one expired order's deposit, to that order's own
    ///         receiver. Permissionless by design - the destination is fixed at
    ///         deposit time, so there is nothing for a caller to choose.
    /// @dev Also reaps the reservation of an order that already SETTLED, which
    ///      pays out nothing (the balance is gone) but frees the token for new
    ///      deposits. That is why the payout is clamped rather than assumed.
    function recover(bytes32 digest) external {
        Order memory o = orders[digest];
        require(o.amount != 0);
        require(block.timestamp > o.validTo);

        // Cleared before the transfer, and the signature with it: returning the
        // deposit must also stop a solver from filling the order it belonged to.
        delete orders[digest];
        delete validDigests[digest];
        uint256 reserved = committed[o.sellToken];
        committed[o.sellToken] = reserved > o.amount ? reserved - o.amount : 0;

        uint256 balance = balanceOf(o.sellToken);
        uint256 payout = o.amount < balance ? o.amount : balance;
        if (payout != 0) safeTransfer(o.sellToken, o.receiver, payout);
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
