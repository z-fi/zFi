// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

/// Minimal ERC-20: returns a bool and exposes symbol/decimals so the lens's
/// metadata pass has something to read.
contract MockERC20 {
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) public virtual returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address t, uint256 amt) public virtual returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[t] += amt;
        return true;
    }
}

contract MockWETH is MockERC20("WETH", 18) {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amt) external {
        balanceOf[msg.sender] -= amt;
        payable(msg.sender).transfer(amt);
    }
}

contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    string public symbol = "NFT";

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address f, address t, uint256 id) external {
        require(ownerOf[id] == f, "not owner");
        require(msg.sender == f || isApprovedForAll[f][msg.sender], "not approved");
        ownerOf[id] = t;
    }
}

/// @dev Alias kept so tests can name the 721 either way.
contract MockERC721 is MockNFT {}

/// @dev Skims 1% on transferFrom, so the escrow receives less than promised.
contract FeeToken is MockERC20("FEE", 18) {
    function transferFrom(address f, address t, uint256 v) public override returns (bool) {
        uint256 fee = v / 100;
        balanceOf[f] -= v;
        balanceOf[t] += v - fee;
        return true;
    }
}

/// @dev Accepts transferFrom and never moves the token, so an order would be
/// left backed by nothing unless custody is confirmed afterwards.
contract LyingERC721 {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address, bool) external {}

    function transferFrom(address, address, uint256) external {}
}

/// @dev An ERC-721 written with an `if` where the standard requires a `require`:
/// an unauthorised transfer returns quietly instead of reverting, and the
/// per-token approval survives a transfer instead of being cleared. Both are
/// bugs real collections have shipped, and both are invisible to a caller that
/// trusts `transferFrom` rather than confirming custody afterwards.
contract SloppyERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function approve(address to, uint256 id) external {
        getApproved[id] = to;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address from, address to, uint256 id) external {
        address owner = ownerOf[id];
        if (owner != from) return; // silent no-op instead of a revert
        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender] && getApproved[id] != msg.sender) {
            return; // and again
        }
        ownerOf[id] = to; // getApproved is never cleared
    }
}

/// @dev Reports failure by returning false rather than reverting - the pre-0.8
/// convention, still shipped by tokens in use. Read through an interface with no
/// return value, that false is indistinguishable from success.
contract SoftFailERC20 is MockERC20("SOFT", 18) {
    function transferFrom(address f, address t, uint256 v) public override returns (bool) {
        if (balanceOf[f] < v) return false;
        uint256 a = allowance[f][msg.sender];
        if (a < v) return false;
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        return true;
    }
}

/// @dev Accepts escrow honestly through transferFrom, then claims that an
/// outbound transfer succeeded without changing either balance.
contract NoOpTransferERC20 is MockERC20("NOOP", 18) {
    function transfer(address, uint256) public pure override returns (bool) {
        return true;
    }
}

/// @dev Credits the recipient exactly `v`, but charges the sender one extra
/// unit. When the sender is a pooled escrow, that unit belongs to another order.
contract SenderFeeERC20 is MockERC20("SENDER_FEE", 18) {
    function transfer(address to, uint256 v) public override returns (bool) {
        balanceOf[msg.sender] -= v + 1;
        balanceOf[to] += v;
        return true;
    }
}

/// @dev Debits the requested amount but credits one unit less, modelling an
/// outbound-only recipient tax that an honest inbound transferFrom cannot
/// reveal at order creation.
contract RecipientTaxERC20 is MockERC20("RECIPIENT_TAX", 18) {
    function transfer(address to, uint256 v) public override returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v - 1;
        return true;
    }
}

/// @dev A wrapper-shaped contract whose deposit accepts ETH but mints nothing.
/// Without a post-deposit delta check, nominal ETH fills spend pooled WETH that
/// backs unrelated orders.
contract NoMintWETH is MockERC20("NO_MINT_WETH", 18) {
    function deposit() external payable {}

    function withdraw(uint256 v) external {
        balanceOf[msg.sender] -= v;
        payable(msg.sender).transfer(v);
    }
}

/// @dev Redeems the requested ETH but burns one extra unit of WETH from the
/// caller, which would otherwise be socialised across pooled WETH orders.
contract OverburnWETH is MockERC20("OVERBURN_WETH", 18) {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 v) external {
        balanceOf[msg.sender] -= v + 1;
        payable(msg.sender).transfer(v);
    }
}

/// @dev Strictly validates `from`, but deliberately retains per-token approval
/// after a transfer. The sticky approval lets an NFT find its way home from
/// escrow; a second board->maker transfer must then be skipped, not attempted.
contract StickyStrictERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function approve(address to, uint256 id) external {
        require(msg.sender == ownerOf[id], "not owner");
        getApproved[id] = to;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address from, address to, uint256 id) external {
        address owner = ownerOf[id];
        require(owner == from, "wrong from");
        require(
            msg.sender == owner || isApprovedForAll[owner][msg.sender] || getApproved[id] == msg.sender, "not approved"
        );
        ownerOf[id] = to; // deliberately does not clear getApproved
    }
}

/// @dev Calls back into the board while being transferred, to prove the
/// reentrancy guard holds through settlement.
contract EvilERC20 is MockERC20("EVIL", 18) {
    address public board;
    uint256 public target;
    bool armed;

    function arm(address b, uint256 t) external {
        board = b;
        target = t;
        armed = true;
    }

    function transfer(address to, uint256 v) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok,) = board.call(
                abi.encodeWithSignature("fillOrder(uint256,uint256,uint256,address)", target, 0, 0, address(0))
            );
            require(!ok, "REENTERED");
        }
        return super.transfer(to, v);
    }
}
