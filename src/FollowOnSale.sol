// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Follow-on share sale for the FW S02 collector DAO.
///         Accepts ETH, mints shares via Moloch allowance, forwards ETH to the
///         FundingWorksMinter so it's immediately available for FW mints (not
///         ragequittable). Governance must first call setAllowance(sale, dao, cap).
contract FollowOnSale {
    address public immutable dao;
    address public immutable shares;
    address payable public immutable minter;
    uint256 public immutable deadline;
    address public immutable owner;

    bool public paused;

    error Paused();
    error Expired();
    error OnlyOwner();

    event Buy(address indexed buyer, uint256 ethPaid, uint256 sharesMinted);
    event SetPaused(bool paused);

    constructor(address _dao, address _shares, address payable _minter, uint256 _deadline) payable {
        dao = _dao;
        shares = _shares;
        minter = _minter;
        deadline = _deadline;
        owner = msg.sender;
    }

    function setPaused(bool _paused) public {
        if (msg.sender != owner) revert OnlyOwner();
        paused = _paused;
        emit SetPaused(_paused);
    }

    /// @notice Buy shares with ETH. 1 ETH = 1M shares (18-decimal).
    function buy() public payable {
        if (paused) revert Paused();
        if (block.timestamp > deadline) revert Expired();
        require(msg.value != 0);

        uint256 sharesAmt = msg.value * 1_000_000;

        IMoloch(dao).spendAllowance(dao, sharesAmt);
        require(IShares(shares).transfer(msg.sender, sharesAmt));
        (bool ok,) = minter.call{value: msg.value}("");
        require(ok);

        emit Buy(msg.sender, msg.value, sharesAmt);
    }
}

interface IMoloch {
    function spendAllowance(address token, uint256 amount) external;
}

interface IShares {
    function transfer(address to, uint256 amount) external returns (bool);
}
