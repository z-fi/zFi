// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title CollectorVault - Reusable collector DAO vault (clone-compatible)
/// @notice Two modes:
///   Mode 0 (Fixed Call): Accumulates ETH, anyone calls execute() to fire a
///         preconfigured call `quantity` times. Tracks callsMade vs maxCalls.
///   Mode 1 (Token Fill): Open bid — ETH accumulates, anyone calls fill() to
///         deliver a token/NFT (via transferFrom) and claim all ETH. One-shot.
///
///   Share burning is handled by the ShareBurner singleton (separate contract).
///   The factory wires a permit at deploy time so anyone can call
///   ShareBurner.closeSale(dao, shares, deadline, nonce) after the deadline.
///
///   Deployed as minimal proxy clones via CollectorVaultFactory.
contract CollectorVault {
    /*//////////////////////////////////////////////////////////////
                          CONFIG (set once via init)
    //////////////////////////////////////////////////////////////*/

    address constant DAICO = 0x000000000033e92DB97B4B3beCD2c255126C60aC;

    constructor() {
        dao = address(0xdead);
    }

    uint8 public mode;
    address public dao;
    uint256 public deadline; // 0 = no deadline

    // Mode 0 — Fixed Call
    address public target;
    uint256 public ethPerCall;
    uint256 public maxCalls; // 0 = unlimited

    // Mode 1 — Token Fill
    address public token;
    uint256 public minBalance; // ERC20 amount or ERC721 tokenId
    bool public specificId; // true = ERC721 specific tokenId

    // Shares token (set by factory)
    address public shares;

    // Allowance-based share sale (0 = buy disabled)
    uint256 public shareRate;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    bytes _callData; // set once in init
    uint256 public callsMade; // Mode 0 counter
    bool public filled; // Mode 1 flag

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error WrongMode();
    error NoFunds();
    error MaxReached();
    error AlreadyFilled();
    error NotDAO();
    error BadQuantity();
    error AlreadyInitialized();
    error BuyDisabled();

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event Executed(uint256 quantity, uint256 ethSpent);
    event Filled(address indexed caller, uint256 ethPaid);
    event Clawback(uint256 amount);
    event TapClaimed(uint256 amount);
    event Buy(address indexed buyer, uint256 ethPaid, uint256 sharesAmount);

    /*//////////////////////////////////////////////////////////////
                             MODIFIERS
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                          INIT (called once by factory)
    //////////////////////////////////////////////////////////////*/

    function init(
        uint8 _mode,
        address _dao,
        uint256 _deadline,
        address _target,
        uint256 _ethPerCall,
        uint256 _maxCalls,
        bytes calldata _payload,
        address _token,
        uint256 _minBalance,
        bool _specificId,
        address _shares,
        uint256 _shareRate
    ) public payable {
        if (dao != address(0)) revert AlreadyInitialized();
        require(_dao != address(0));

        mode = _mode;
        dao = _dao;
        deadline = _deadline;
        target = _target;
        ethPerCall = _ethPerCall;
        maxCalls = _maxCalls;
        token = _token;
        minBalance = _minBalance;
        specificId = _specificId;
        shares = _shares;
        shareRate = _shareRate;

        if (_payload.length != 0) _callData = _payload;
    }

    /*//////////////////////////////////////////////////////////////
                       MODE 0 — FIXED CALL
    //////////////////////////////////////////////////////////////*/

    /// @notice Fire the preconfigured call `quantity` times.
    function execute(uint256 quantity) public nonReentrant {
        _execute(quantity);
    }

    /// @notice Claim DAICO tap then execute (Mode 0 only).
    function executeFromTap(uint256 quantity) public nonReentrant {
        uint256 claimed = IDAICO(DAICO).claimTap(dao);
        if (claimed != 0) emit TapClaimed(claimed);
        _execute(quantity);
    }

    function _execute(uint256 quantity) internal {
        if (mode != 0) revert WrongMode();
        if (quantity == 0) revert BadQuantity();

        uint256 totalCost = quantity * ethPerCall;
        if (address(this).balance < totalCost) revert NoFunds();

        if (maxCalls != 0 && callsMade + quantity > maxCalls) revert MaxReached();
        callsMade += quantity;

        bytes memory data = _callData;
        for (uint256 i; i != quantity; ++i) {
            (bool ok,) = target.call{value: ethPerCall}(data);
            require(ok);
        }

        emit Executed(quantity, totalCost);
    }

    /// @notice How many calls can be made from current balance.
    function executable() public view returns (uint256) {
        if (mode != 0 || ethPerCall == 0) return 0;
        uint256 fromBal = address(this).balance / ethPerCall;
        if (maxCalls == 0) return fromBal;
        uint256 remaining = maxCalls > callsMade ? maxCalls - callsMade : 0;
        return fromBal < remaining ? fromBal : remaining;
    }

    /// @notice How many calls can be made including claimable tap.
    function executableFromTap() public view returns (uint256) {
        if (mode != 0 || ethPerCall == 0) return 0;
        uint256 totalBal = address(this).balance + IDAICO(DAICO).claimableTap(dao);
        uint256 fromBal = totalBal / ethPerCall;
        if (maxCalls == 0) return fromBal;
        uint256 remaining = maxCalls > callsMade ? maxCalls - callsMade : 0;
        return fromBal < remaining ? fromBal : remaining;
    }

    /*//////////////////////////////////////////////////////////////
                     MODE 1 — TOKEN FILL (OPEN BID)
    //////////////////////////////////////////////////////////////*/

    /// @notice Deliver token/NFT, claim all ETH. Caller must have approved this contract.
    function fill() public nonReentrant {
        if (mode != 1) revert WrongMode();
        if (filled) revert AlreadyFilled();

        uint256 bal = address(this).balance;
        if (bal == 0) revert NoFunds();

        filled = true;

        if (specificId) {
            IERC721(token).transferFrom(msg.sender, address(this), minBalance);
        } else {
            safeTransferFrom(token, minBalance);
        }

        safeTransferETH(msg.sender, bal);

        emit Filled(msg.sender, bal);
    }

    /// @notice Whether the token condition has been met.
    function isFilled() public view returns (bool) {
        if (mode != 1) return false;
        if (filled) return true;
        if (specificId) {
            try IERC721(token).ownerOf(minBalance) returns (address owner) {
                return owner == address(this);
            } catch {
                return false;
            }
        } else {
            return balanceOfThis(token) >= minBalance;
        }
    }

    /*//////////////////////////////////////////////////////////////
                       DAICO TAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim vested tap from DAICO factory.
    function claimTap() public returns (uint256 claimed) {
        claimed = IDAICO(DAICO).claimTap(dao);
        if (claimed != 0) emit TapClaimed(claimed);
    }

    /// @notice View claimable tap amount.
    function claimableTap() public view returns (uint256) {
        return IDAICO(DAICO).claimableTap(dao);
    }

    /*//////////////////////////////////////////////////////////////
                   ALLOWANCE-BASED SHARE SALE
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy shares with ETH (only when shareRate != 0).
    ///         ETH stays in vault to fund calls/fills. Remainder goes to DAO via clawback.
    ///         Disabled after deadline, when all calls are spent, or after fill.
    function buy() public payable nonReentrant {
        if (shareRate == 0) revert BuyDisabled();
        if (deadline != 0 && block.timestamp >= deadline) revert BuyDisabled();
        if (mode == 0 && maxCalls != 0 && callsMade >= maxCalls) revert BuyDisabled();
        if (mode == 1 && filled) revert BuyDisabled();
        require(msg.value != 0);

        uint256 sharesAmt = msg.value * shareRate / 1e18;
        require(sharesAmt != 0);

        IMoloch(dao).spendAllowance(dao, sharesAmt);
        require(IShares(shares).transfer(msg.sender, sharesAmt));

        emit Buy(msg.sender, msg.value, sharesAmt);
    }

    /*//////////////////////////////////////////////////////////////
                            CLAWBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Send remaining ETH to DAO. Permissionless after deadline, when all
    ///         calls are spent, or after fill. Otherwise DAO-only.
    function clawback() public nonReentrant {
        if (deadline != 0 && block.timestamp >= deadline) {
            // permissionless after deadline
        } else if (mode == 0 && maxCalls != 0 && callsMade >= maxCalls) {
            // permissionless when all calls spent
        } else if (mode == 1 && filled) {
            // permissionless after fill
        } else {
            if (msg.sender != dao) revert NotDAO();
        }

        uint256 bal = address(this).balance;
        if (bal == 0) revert NoFunds();

        safeTransferETH(dao, bal);

        emit Clawback(bal);
    }

    /*//////////////////////////////////////////////////////////////
                             RECEIVE
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) public pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/*//////////////////////////////////////////////////////////////
                    SOLADY-STYLE FREE FUNCTIONS
//////////////////////////////////////////////////////////////*/

function safeTransferETH(address to, uint256 amount) {
    assembly ("memory-safe") {
        if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
            mstore(0x00, 0xb12d13eb) // ETHTransferFailed()
            revert(0x1c, 0x04)
        }
    }
}

function safeTransferFrom(address token, uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x60, amount)
        mstore(0x40, address())
        mstore(0x2c, shl(96, caller()))
        mstore(0x0c, 0x23b872dd000000000000000000000000)
        let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x7939f424) // TransferFromFailed()
                revert(0x1c, 0x04)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}

function balanceOfThis(address token) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, address())
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(mload(0x20), and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20)))
    }
}

/*//////////////////////////////////////////////////////////////
                         INTERFACES
//////////////////////////////////////////////////////////////*/

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IMoloch {
    function spendAllowance(address token, uint256 amount) external;
}

interface IDAICO {
    function claimTap(address dao) external returns (uint256 claimed);
    function claimableTap(address dao) external view returns (uint256);
}

interface IShares {
    function transfer(address to, uint256 amount) external returns (bool);
}
