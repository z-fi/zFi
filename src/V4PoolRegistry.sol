// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title V4PoolRegistry
/// @notice The list of v4 pools zSwap can route through, kept onchain so the
///         page never has to be redeployed to learn about a new one.
///
/// @dev WHY THIS IS NOT A CONSTANT IN THE PAGE. zSwap's UI is contract code -
///      permanent, immutable bytecode. A pool key baked into the HTML would
///      mean that the day a second popular hooked pool appears, the entire page
///      has to be rebuilt, re-chunked and redeployed to trade it. A hooked
///      pool cannot be discovered by search either: the fee and tick spacing
///      could be enumerated, but the hook address is 20 unguessable bytes, and
///      the hook is the part that prices the pool.
///
///      So the page holds ONE address - this registry - and reads the rest at
///      runtime. Adding a pool is a transaction, not a deployment.
///
/// @dev WHAT IT DELIBERATELY IS NOT. It stores no prices, quotes nothing and
///      holds no funds; `V4QuoteLens` prices what is listed here and `V4Port`
///      executes it. Listing is therefore not an endorsement of a pool, and a
///      caller may swap through `V4Port` with a key that was never listed - the
///      registry is a menu, not a gate. That keeps a compromised owner from
///      being able to block trading, only to mislead a front end that trusts
///      the menu, which is the same trust any token list already carries.
contract V4PoolRegistry {
    /// @dev The DAO, or whoever it later hands off to.
    address public owner;

    /// @dev Insertion-ordered. `id` is the v4 pool id - keccak of the key - so
    ///      the same pool cannot be listed twice under two spellings.
    bytes32[] internal _ids;
    mapping(bytes32 => Pool) internal _pools;
    mapping(bytes32 => uint256) internal _indexPlusOne;

    event Listed(bytes32 indexed id, PoolKey key, string label);
    event Delisted(bytes32 indexed id);
    event OwnerChanged(address indexed from, address indexed to);

    error Unauthorized();
    error NotListed();
    error AlreadyListed();
    error BadKey();

    struct Pool {
        PoolKey key;
        string label;
    }

    constructor(address _owner) {
        if (_owner == address(0)) revert BadKey();
        owner = _owner;
        emit OwnerChanged(address(0), _owner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function transferOwnership(address to) public onlyOwner {
        if (to == address(0)) revert BadKey();
        emit OwnerChanged(owner, to);
        owner = to;
    }

    /// @notice Add a pool to the menu.
    /// @param label A human name for the pair, shown by the page. Not trusted
    ///              for anything but display - the key is what routes.
    function list(PoolKey calldata key, string calldata label) public onlyOwner returns (bytes32 id) {
        // v4 requires currency0 < currency1, and a key that does not sort is a
        // key that addresses no pool. Rejecting it here turns a silent
        // never-matches listing into a failed transaction.
        if (uint160(key.currency0) >= uint160(key.currency1)) revert BadKey();
        id = poolId(key);
        if (_indexPlusOne[id] != 0) revert AlreadyListed();
        _ids.push(id);
        _indexPlusOne[id] = _ids.length;
        _pools[id] = Pool(key, label);
        emit Listed(id, key, label);
    }

    /// @notice Remove a pool. The swap path does not consult this registry, so
    ///         delisting hides a pool from the page rather than freezing it.
    function delist(bytes32 id) public onlyOwner {
        uint256 idx = _indexPlusOne[id];
        if (idx == 0) revert NotListed();
        uint256 last = _ids.length - 1;
        if (idx - 1 != last) {
            bytes32 moved = _ids[last];
            _ids[idx - 1] = moved;
            _indexPlusOne[moved] = idx;
        }
        _ids.pop();
        delete _indexPlusOne[id];
        delete _pools[id];
        emit Delisted(id);
    }

    /// @notice Every listed pool, in one call - the page reads this at load.
    function all() public view returns (bytes32[] memory ids, Pool[] memory pools) {
        ids = _ids;
        pools = new Pool[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            pools[i] = _pools[ids[i]];
        }
    }

    function count() public view returns (uint256) {
        return _ids.length;
    }

    function get(bytes32 id) public view returns (Pool memory) {
        if (_indexPlusOne[id] == 0) revert NotListed();
        return _pools[id];
    }

    /// @notice v4's pool id: the keccak of the key struct.
    function poolId(PoolKey calldata key) public pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}
