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
