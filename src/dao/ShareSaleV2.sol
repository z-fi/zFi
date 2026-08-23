// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ShareSaleV2
/// @notice Singleton for selling DAO shares or loot, with the sale's ceiling expressed
///         as a target supply rather than a spend budget.
///
/// WHY THIS EXISTS
///
/// The original ShareSale meters a sale with a Moloch allowance. Allowance is spent at
/// mint and is never restored, so a share that is minted and then redeemed removes that
/// much capacity from the sale permanently. On a live cause that cost 1,891,891 shares —
/// 0.63 ETH of a 3.33 ETH raise — and shut the sale eight days early.
///
/// That is also an attack. Buying and immediately ragequitting returns nearly all of the
/// ETH (a flat price means treasury-per-share is the price), so for gas plus a little
/// vesting drift anyone can burn a sale's whole allowance and deny the raise. Reopening
/// by vote does not help: the same trick works on the new allowance.
///
/// The fix is to stop treating capacity as a budget that drains. `cap` here is a ceiling
/// on the sold token's total supply, checked live at every buy:
///
///     remaining = cap - token.totalSupply()
///
/// A burn lowers totalSupply, so capacity comes back on its own. Round-tripping returns
/// the shares and returns the capacity with them; a griefer can churn but cannot deny.
///
/// THE ALLOWANCE IS STILL THERE, AND STILL DRAINS
///
/// Minting goes through Moloch.spendAllowance, which decrements. So the DAO must grant
/// this contract more allowance than the cap, or the allowance becomes the binding
/// constraint again and the old behaviour returns. Grant a multiple of the cap: it is
/// the number of times the sale can be fully round-tripped before needing a top-up, and
/// it bounds what a bug in this contract could ever mint. Do not grant type(uint256).max
/// for the convenience of never thinking about it — that is an unbounded mint permit.
contract ShareSaleV2 {
    error InsufficientPayment();
    error NotConfigured();
    error UnexpectedETH();
    error ZeroAmount();
    error ZeroPrice();
    error ZeroCap();
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
    function buy(address dao, uint256 amount) public payable {
        if (amount == 0) revert ZeroAmount();
        Sale memory s = sales[dao];
        if (s.price == 0) revert NotConfigured();
        if (s.deadline != 0 && block.timestamp > s.deadline) revert Expired();

        address tokenAddr = _resolve(dao, s.token);

        // Derived live, so a burn since the last buy has already given the room back.
        uint256 supply = totalSupplyOf(tokenAddr);
        uint256 room = s.cap > supply ? s.cap - supply : 0;
        uint256 allowed = IMoloch(dao).allowance(s.token, address(this));
        if (room > allowed) room = allowed;
        if (amount > room) amount = room;
        if (amount == 0) revert ZeroAmount();

        uint256 cost = (amount * s.price + 1e18 - 1) / 1e18; // round up: no dust

        // EFFECTS before INTERACTIONS.
        IMoloch(dao).spendAllowance(s.token, amount);

        if (s.payToken == address(0)) {
            if (msg.value < cost) revert InsufficientPayment();
            safeTransferETH(dao, cost);
            if (msg.value > cost) {
                unchecked {
                    safeTransferETH(msg.sender, msg.value - cost);
                }
            }
        } else {
            if (msg.value != 0) revert UnexpectedETH();
            safeTransferFrom(s.payToken, dao, cost);
        }

        safeTransfer(tokenAddr, msg.sender, amount);
        emit Purchase(dao, msg.sender, amount, cost);
    }

    function _resolve(address dao, address token) internal view returns (address) {
        if (token == dao) return address(IMoloch(dao).shares());
        if (token == address(1007)) return address(IMoloch(dao).loot());
        return token;
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
