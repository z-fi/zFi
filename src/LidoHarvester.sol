// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @notice Simple Lido stETH harvesting contract to utilize ETH yield.
/// @dev Accepts raw ETH (converts to stETH) or stETH deposits -
/// which increment basis counter to track yield - which can be converted
/// to ETH - which may then be used in withdraw() - optional condition
/// can be attached which ensures some sort of balance increase in ETH
/// or ERC20 asset occurs as a result of spending such ETH on withdraw().
contract LidoHarvester {
    event OwnershipTransferred(address indexed from, address indexed to);

    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    
    uint256 public staked;
    uint16 public slipBps;
    address public owner;

    address public asset;
    address public holder;

    error ConditionUnmet();
    error Unauthorized();
    error InvalidCall();

    function transferOwnership(address to) public payable {
        emit OwnershipTransferred(msg.sender, owner = to);
    }

    function setSlippage(uint16 _slipBps) public payable {
        require(msg.sender == owner, Unauthorized());
        slipBps = _slipBps;
    }

    function setCondition(address _asset, address _holder) public payable {
        require(msg.sender == owner, Unauthorized());
        (asset, holder) = (_asset, _holder);
    }

    constructor() payable {
        emit OwnershipTransferred(address(0), owner = msg.sender);
    }

    receive() external payable {
        uint256 stethBal = IERC20(STETH).balanceOf(address(this));
        (bool ok, ) = STETH.call{value: msg.value}("");
        require(ok);
        unchecked { staked += IERC20(STETH).balanceOf(address(this)) - stethBal; }
    }

    function deposit(uint256 amt) public payable {
        IERC20(STETH).transferFrom(msg.sender, address(this), amt);
        unchecked { staked += amt; }
    }

    function withdraw(address to, uint256 val, bytes calldata data) public payable {
        require(msg.sender == owner, Unauthorized());
        require(to != STETH, InvalidCall()); // no calls to stETH - outside bounds

        address _holder = holder;
        address _asset = asset;
        uint256 balBefore;
        bool conditioned = _holder != address(0);
        bool ethCondition = _asset == address(0);

        if (conditioned) balBefore = ethCondition ? _holder.balance : IERC20(_asset).balanceOf(_holder);

        (bool ok, ) = to.call{value: val}(data);
        require(ok);  

        if (conditioned) {
             uint256 balAfter = ethCondition ? _holder.balance : IERC20(_asset).balanceOf(_holder);
             require(balAfter > balBefore, ConditionUnmet());
        }

    }

    function harvest(address to, bytes calldata data) public payable returns (uint256 yield) {
        uint256 ethBal = address(this).balance; // how much eth is in contract before call
        uint256 stethBal = IERC20(STETH).balanceOf(address(this)); // how much steth is in contract before call
        unchecked { yield = (stethBal - staked); } // the yield amount in terms of steth accrued over deposits
        (bool ok, ) = to.call(data); // the call to any contract with any data
        require(ok); // the requirement that the call succeeds
        unchecked { require(address(this).balance >= (ethBal + yield) * (slipBps / 10000)); } 
        // the requirement that eth balance increased from the call adjusted for slippage bps
    }
}
