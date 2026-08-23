// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ShareOffering
/// @notice Sells DAO shares or loot at a fixed price, up to a ceiling on total supply.
///
/// The ceiling is a supply target, not a spend budget:
///
///     remaining = cap - token.totalSupply()
///
/// It is read at every buy, so redeemed shares return their room to the offering. How
/// much may be issued and how much is currently held stay independent, which is what a
/// refundable raise wants — otherwise every refund quietly shrinks the offering.
///
/// Setup, as DAO initCalls or a proposal:
///   1. dao.setAllowance(offering, token, headroom)
///   2. offering.configure(token, payToken, price, deadline, cap)   // called BY the dao
///
/// `token` is a mint sentinel: the DAO's own address for shares, address(1007) for loot.
/// A supply ceiling only describes a token this contract is the one minting, so
/// configure() admits nothing else.
///
/// `headroom` must exceed `cap`. Minting spends Moloch allowance and burning does not
/// return it, so the allowance is the outer bound on everything this contract may ever
/// mint, and the cap is the live one. The multiple is how many times the offering can be
/// sold out and fully redeemed before it needs topping up. type(uint256).max makes that
/// unlimited and leaves this contract's own arithmetic as the only limit, so it is a
/// choice to make deliberately.
///
/// Pricing is 1e18-scaled: cost = amount * price / 1e18, rounded up.
contract ShareOffering {
    error InsufficientPayment();
    error NotConfigured();
    error UnexpectedETH();
    error ZeroAmount();
    error ZeroPrice();
    error ZeroCap();
    error NotMintable();
    error Reentrancy();
    error Expired();

    event Configured(
        address indexed dao, address token, address payToken, uint256 price, uint40 deadline, uint256 cap
    );
    event Purchase(address indexed dao, address indexed buyer, uint256 amount, uint256 cost);

    struct Sale {
        address token; // allowance sentinel: dao = mint shares, address(1007) = mint loot
        address payToken; // address(0) = ETH
        uint40 deadline; // unix timestamp after which buys revert (0 = no deadline)
        uint256 price; // cost per whole token, 1e18-scaled
        uint256 cap; // ceiling on the sold token's TOTAL SUPPLY, not a spend budget
    }

    mapping(address dao => Sale) public sales;

    /// @dev buy() hands control to the caller twice before it is finished: once when it
    ///      refunds excess ETH, and once when it delivers the token. Neither can be used
    ///      to mint past the cap — the allowance is already spent and totalSupply already
    ///      raised by then — but a guard costs one transient slot and removes the need to
    ///      re-derive that every time this is read. Same slot pattern as Moloch.
    uint256 constant _REENTRANCY_GUARD_SLOT = 0x929eee149b4bd21268;

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(_REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06) // Reentrancy()
                revert(0x1c, 0x04)
            }
            tstore(_REENTRANCY_GUARD_SLOT, address())
        }
        _;
        assembly ("memory-safe") {
            tstore(_REENTRANCY_GUARD_SLOT, 0)
        }
    }

    constructor() payable {}

    /// @notice Configure a sale. Must be called by the DAO, which keys it to msg.sender.
    /// @param cap Ceiling on the sold token's total supply. Founder shares minted at
    ///            summon count toward it, so set it to the final supply you want, not to
    ///            the number of shares you intend to sell.
    function configure(address token, address payToken, uint256 price, uint40 deadline, uint256 cap)
        public
    {
        if (price == 0) revert ZeroPrice();
        if (cap == 0) revert ZeroCap();
        // A supply ceiling is only meaningful for a token this sale mints.
        if (token != msg.sender && token != address(1007)) revert NotMintable();
        sales[msg.sender] = Sale(token, payToken, deadline, price, cap);
        emit Configured(msg.sender, token, payToken, price, deadline, cap);
    }

    /// @notice Shares still sellable: the gap to the cap, bounded by the DAO's allowance.
    function remaining(address dao) public view returns (uint256) {
        Sale memory s = sales[dao];
        if (s.price == 0) return 0;
        uint256 supply = totalSupplyOf(_resolve(dao, s.token));
        uint256 room = s.cap > supply ? s.cap - supply : 0;
        uint256 allowed = IMoloch(dao).allowance(s.token, address(this));
        return room < allowed ? room : allowed;
    }

    /// @notice Buy shares or loot. Caps to `remaining`; pass type(uint256).max for all of it.
    function buy(address dao, uint256 amount) public payable nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Sale memory s = sales[dao];
        if (s.price == 0) revert NotConfigured();
        if (s.deadline != 0 && block.timestamp > s.deadline) revert Expired();

        address tokenAddr = _resolve(dao, s.token);

        // Read live: a burn since the last buy has already returned the room.
        uint256 supply = totalSupplyOf(tokenAddr);
        uint256 room = s.cap > supply ? s.cap - supply : 0;
        uint256 allowed = IMoloch(dao).allowance(s.token, address(this));
        if (room > allowed) room = allowed;
        if (amount > room) amount = room;
        if (amount == 0) revert ZeroAmount();

        uint256 cost = (amount * s.price + 1e18 - 1) / 1e18; // round up: no dust

        // Judge the payment before minting against it. The transaction would revert
        // either way, but nothing should mint on a path already known to fail.
        bool native = s.payToken == address(0);
        if (native) {
            if (msg.value < cost) revert InsufficientPayment();
        } else if (msg.value != 0) {
            revert UnexpectedETH();
        }

        // EFFECTS before INTERACTIONS.
        IMoloch(dao).spendAllowance(s.token, amount);

        if (native) {
            safeTransferETH(dao, cost);
            if (msg.value > cost) {
                unchecked {
                    safeTransferETH(msg.sender, msg.value - cost);
                }
            }
        } else {
            safeTransferFrom(s.payToken, dao, cost);
        }

        safeTransfer(tokenAddr, msg.sender, amount);
        emit Purchase(dao, msg.sender, amount, cost);
    }

    /// @dev configure() admits only the two sentinels, so this is total.
    function _resolve(address dao, address token) internal view returns (address) {
        return token == dao ? address(IMoloch(dao).shares()) : address(IMoloch(dao).loot());
    }
}

interface IMoloch {
    function spendAllowance(address token, uint256 amount) external;
    function allowance(address token, address spender) external view returns (uint256);
    function shares() external view returns (address);
    function loot() external view returns (address);
}

function totalSupplyOf(address token) view returns (uint256 s) {
    assembly ("memory-safe") {
        mstore(0x00, 0x18160ddd) // totalSupply()
        if iszero(staticcall(gas(), token, 0x1c, 0x04, 0x00, 0x20)) { revert(0x00, 0x00) }
        s := mload(0x00)
    }
}

function safeTransferETH(address to, uint256 amount) {
    assembly ("memory-safe") {
        if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
            mstore(0x00, 0xb12d13eb)
            revert(0x1c, 0x04)
        }
    }
}

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

function safeTransferFrom(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x60, amount)
        mstore(0x40, to)
        mstore(0x2c, shl(96, caller()))
        mstore(0x0c, 0x23b872dd000000000000000000000000)
        let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x7939f424)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}
