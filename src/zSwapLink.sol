// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

interface IzSwapLineage {
    function PREVIOUS() external view returns (address);
    function successor() external view returns (address);
}

/// @title zSwap link
/// @notice A version in the zSwap lineage whose page is served by another,
///         already-deployed zSwap contract.
/// @dev `PAGE` is an immutable zSwap whose `html()` can never change, so a
///      link to it is as fixed as a version that holds its own chunks. Every
///      call this contract does not define - `html()`, `request()`,
///      `resolveMode()`, `NAME()`, `VERSION()`, the chunk and roster getters -
///      is relayed to `PAGE` by `staticcall` and its answer returned verbatim.
///
///      The lineage interface is this contract's own, with the same rules as
///      zSwap: `PREVIOUS` must be the deployer, `DAO` carries over unchanged,
///      and `successor` is write-once, set only by `deployNext` after the same
///      three probes.
contract zSwapLink {
    /// @notice The deployed zSwap whose page this version serves.
    address public immutable PAGE;

    /// @notice The DAO permitted to deploy this version's successor.
    address public immutable DAO;

    /// @notice The version that deployed this one.
    address public immutable PREVIOUS;

    /// @notice The next version, once the DAO has deployed it.
    address public successor;

    /// @notice When `successor` was set, as a unix timestamp; zero until then.
    uint96 public succeededAt;

    error InvalidData();
    error NotDAO();
    error AlreadySucceeded();
    error DeployFailed();
    error NotASuccessor();

    /// @notice Emitted once per version, by the version that created it.
    event Succeeded(address indexed successor, uint256 indexed version);

    /// @param dao      Governance permitted to deploy the successor.
    /// @param previous The version deploying this one; must be `msg.sender`.
    /// @param page     A deployed zSwap that serves the page.
    constructor(address dao, address previous, address page) {
        if (previous != msg.sender || page.code.length == 0) revert InvalidData();
        DAO = dao;
        PREVIOUS = previous;
        PAGE = page;
    }

    /// @notice Deploy the next version, at an address known before it exists.
    /// @dev Identical to zSwap's: CREATE2 from this contract, then the
    ///      successor must answer `PREVIOUS() == this`, `successor() == 0` and
    ///      `DAO() == DAO`, each probe capped at 30,000 gas.
    function deployNext(bytes calldata initcode, bytes32 salt) external returns (address next) {
        if (msg.sender != DAO) revert NotDAO();
        if (successor != address(0)) revert AlreadySucceeded();
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, initcode.offset, initcode.length)
            next := create2(0, p, initcode.length, salt)
        }
        if (next == address(0)) revert DeployFailed();
        (bool ok, bytes memory ret) = next.staticcall{gas: 30_000}(abi.encodeWithSelector(bytes4(keccak256("PREVIOUS()"))));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) != address(this)) revert NotASuccessor();
        (ok, ret) = next.staticcall{gas: 30_000}(abi.encodeWithSelector(bytes4(keccak256("successor()"))));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) != address(0)) revert NotASuccessor();
        (ok, ret) = next.staticcall{gas: 30_000}(abi.encodeWithSelector(bytes4(keccak256("DAO()"))));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) != DAO) revert NotASuccessor();
        successor = next;
        succeededAt = uint96(block.timestamp);
        emit Succeeded(next, generation() + 1);
    }

    /// @notice How far along the chain this contract sits: 1 for v0.1.
    function generation() public view returns (uint256 n) {
        address cur = address(this);
        for (n = 1; n != 33; ++n) {
            address prev = IzSwapLineage(cur).PREVIOUS();
            if (prev == address(0)) return n;
            cur = prev;
        }
    }

    /// @notice The newest version reachable from here, following `successor`.
    function latest() external view returns (address tip) {
        tip = address(this);
        for (uint256 i; i != 32; ++i) {
            address next = IzSwapLineage(tip).successor();
            if (next == address(0)) return tip;
            tip = next;
        }
    }

    /// @dev Relays the call to `PAGE` and returns or reverts with its exact bytes.
    fallback() external {
        address page = PAGE;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := staticcall(gas(), page, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
