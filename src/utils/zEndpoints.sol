// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title zEndpoints
/// @notice Every off-chain endpoint the page talks to that is not an Ethereum
///         read node, curated on chain so none of them is fixed into the
///         page's bytes.
///
/// WHY THIS EXISTS
///   zSwap's own trades touch nothing but the chain. The page around them does
///   reach a handful of services: read nodes for the L2s it runs on, a node
///   willing to serve the private pool's whole history, the prover that turns
///   a private note into a proof, a Bitcoin index for cBTC deposits, and the
///   WalletConnect relay. Baked into an immutable page, each of those is a
///   dependency in the strict sense - the day one moves, dies or turns
///   hostile, every copy of the page is stuck with it until a new version is
///   deployed and people move to it.
///
///   Here, each becomes a curated list read from chain. The page reads it once
///   per session, merges it AHEAD of the values it was built with, and falls
///   back to those values when this contract cannot be read. Nothing listed
///   here is needed for a swap to run, and none of it is trusted with a key.
///
/// KEYS
///   A list is named by `(service, chainId)`. `service` is a short ASCII name
///   packed into a bytes32, like the lane names of zSwapFlags. `chainId` is
///   the chain the endpoint SERVES, not the chain this contract sits on - one
///   mainnet deployment answers for every chain, the same shape as the RPC
///   roster and the flags, and for the same reason. Chain 0 is the fallback,
///   read when a chain has no list of its own. It is also the natural home for
///   services that belong to no EVM chain (Bitcoin, the WalletConnect relay).
///
///   The services the page reads today:
///     "rpc"   8453, 4663   read nodes for Base and Robinhood Chain
///     "logs"  1            nodes that serve wide eth_getLogs ranges
///     "tacit" 1            the private pool's prover and settle relay
///     "btc"   0            Esplora-compatible Bitcoin APIs
///     "wc"    0            the WalletConnect relay, wss://
///     "wcpid" 0            the WalletConnect project id (a string, not a URL)
///   Ethereum's own read nodes stay in zRpcList, which a version pins as
///   `RPCS` and which the page reads before it can read anything else -
///   including this contract.
///
/// TRUST
///   Every list is bounded by what the page does with it, and the page treats
///   every entry as untrusted input:
///     - A read node can misstate what it is asked. It never sees a key, and
///       the calldata the page builds targets addresses in the page's own
///       bytes.
///     - A logs node can hide history, which the page notices by checking the
///       pool's own storage. It cannot forge a note, because a spend is proved
///       against the pool's on-chain root.
///     - The prover sees what it proves, so a hostile one costs PRIVACY. It
///       cannot redirect funds, because the proof binds the recipients and the
///       fee. A viewer can also prove through a relay of their own choosing.
///       BE PRECISE ABOUT WHAT THIS BUYS. Proving and submitting are separate
///       jobs, and the page can already take the second one back: when a relay
///       will not carry an operation, it offers to send the transaction from
///       the viewer's own wallet instead. That removes the relay from the money
///       path and from the fee. It does NOT remove the prover, because the
///       proof itself still has to come from somewhere - so a prover that is
///       down, or serving a stale guest, takes both paths out at once. The
///       independence this list provides is the freedom to name a DIFFERENT
///       prover, not to do without one; the pool's settle() is permissionless,
///       so anyone running the published guest can be that prover.
///     - A Bitcoin API that lies produces a cBTC mint the pool's own Bitcoin
///       light client refuses.
///     - The WalletConnect relay carries end-to-end encrypted messages. It can
///       drop them, not read them.
///   So curating this is a liveness and privacy decision, never a custody one.
///   It is the same class of decision as the RPC roster's and is held on the
///   same terms.
contract zEndpoints {
    /// @notice Curation. Moves by the two-step handoff below.
    /// @dev Not a constant, for the reason zRpcList gives: the curator changes
    ///      hands more often than a page can be redeployed, and the bound
    ///      above is what keeps a mutable curator acceptable.
    address public owner;

    /// @notice The address offered ownership that has not yet accepted it.
    address public pendingOwner;

    /// @notice One list, as the constructor takes it.
    struct Seed {
        bytes32 service;
        uint256 chainId;
        string[] urls;
    }

    /// @dev service => chainId => entries, in preference order: the page tries
    ///      position 0 first and fails over down the list.
    mapping(bytes32 service => mapping(uint256 chainId => string[])) internal _lists;

    /// @notice Whether `(service, chainId)` has ever been written. `keys`
    ///         enumerates exactly these.
    mapping(bytes32 service => mapping(uint256 chainId => bool)) public known;

    bytes32[] internal _services;
    uint256[] internal _chains;

    error NotOwner();
    error BadIndex();
    error LengthMismatch();

    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    /// @dev Emitted by `set` BEFORE the replacement, with the length that was
    ///      discarded, so an indexer rebuilding a list from logs drops the
    ///      tail it would otherwise keep. See zRpcList's `Reset`.
    event Reset(bytes32 indexed service, uint256 indexed chainId, uint256 oldLength);
    event Added(bytes32 indexed service, uint256 indexed chainId, uint256 index, string url);
    event Removed(bytes32 indexed service, uint256 indexed chainId, uint256 index, string url);
    event Moved(bytes32 indexed service, uint256 indexed chainId, uint256 from, uint256 to);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier at(bytes32 service, uint256 chainId, uint256 i) {
        if (i >= _lists[service][chainId].length) revert BadIndex();
        _;
    }

    /// @param admin Who may curate from here.
    /// @param seeds The curation this contract is born holding. The page
    ///              carries its own values too and keeps them behind whatever
    ///              is here, so an empty list degrades to exactly the page
    ///              that cannot read this contract.
    constructor(address admin, Seed[] memory seeds) payable {
        owner = admin;
        emit OwnershipTransferred(address(0), admin);
        for (uint256 i; i != seeds.length; ++i) {
            for (uint256 j; j != seeds[i].urls.length; ++j) {
                _push(seeds[i].service, seeds[i].chainId, seeds[i].urls[j]);
            }
        }
    }

    // ------------------------------------------------------------- READS

    /// @notice The list for `service` on `chainId`: the chain's own if it has
    ///         entries, otherwise the fallback at chain 0.
    /// @dev An EMPTY chain list inherits rather than hides. The page keeps its
    ///      built-in values behind any list, so "none on this chain" would
    ///      read the same as "inherit" there anyway, and inheriting is what
    ///      lets one fallback write cover every chain.
    function listOf(bytes32 service, uint256 chainId) public view returns (string[] memory) {
        string[] storage own = _lists[service][chainId];
        return own.length != 0 ? own : _lists[service][0];
    }

    /// @notice Several lists in one call, each resolved as `listOf`. The page
    ///         reads everything it needs through this once per session.
    function listsOf(bytes32[] calldata services, uint256[] calldata chainIds)
        public
        view
        returns (string[][] memory out)
    {
        if (services.length != chainIds.length) revert LengthMismatch();
        out = new string[][](services.length);
        for (uint256 i; i != services.length; ++i) {
            out[i] = listOf(services[i], chainIds[i]);
        }
    }

    /// @notice The list stored under exactly `(service, chainId)`, with no
    ///         fallback. What the curation ops index into.
    function listAt(bytes32 service, uint256 chainId) public view returns (string[] memory) {
        return _lists[service][chainId];
    }

    /// @notice How many entries `(service, chainId)` holds, with no fallback.
    function count(bytes32 service, uint256 chainId) public view returns (uint256) {
        return _lists[service][chainId].length;
    }

    /// @notice One entry by position.
    function get(bytes32 service, uint256 chainId, uint256 i)
        public
        view
        at(service, chainId, i)
        returns (string memory)
    {
        return _lists[service][chainId][i];
    }

    /// @notice Every `(service, chainId)` ever written, in first-write order,
    ///         so a reader can audit the whole curation without replaying
    ///         logs. A list since emptied stays listed, with a count of zero.
    function keys() public view returns (bytes32[] memory services, uint256[] memory chainIds) {
        return (_services, _chains);
    }

    // -------------------------------------------------------- GOVERNANCE
    //
    // The same surgical ops as zRpcList, each scoped to one list: the smallest
    // write that does the job, with `set` as the escape hatch. Changes take
    // effect on a page's next read, never mid-session.

    /// @notice Append an entry at the end of a list's failover order.
    function add(bytes32 service, uint256 chainId, string calldata url) public onlyOwner {
        _push(service, chainId, url);
    }

    /// @notice Drop an entry, PRESERVING ORDER: the tail shifts down, because
    ///         order is the curation and a swap-and-pop would promote whatever
    ///         sat last.
    function remove(bytes32 service, uint256 chainId, uint256 i)
        public
        onlyOwner
        at(service, chainId, i)
    {
        string[] storage l = _lists[service][chainId];
        emit Removed(service, chainId, i, l[i]);
        uint256 last = l.length - 1;
        for (uint256 j = i; j < last; ++j) {
            l[j] = l[j + 1];
        }
        l.pop();
    }

    /// @notice Drop a list's last entry - the way an `add` is undone.
    function pop(bytes32 service, uint256 chainId) public onlyOwner {
        string[] storage l = _lists[service][chainId];
        if (l.length == 0) revert BadIndex();
        emit Removed(service, chainId, l.length - 1, l[l.length - 1]);
        l.pop();
    }

    /// @notice Move an entry to another position, shifting what lies between.
    function move(bytes32 service, uint256 chainId, uint256 from, uint256 to)
        public
        onlyOwner
        at(service, chainId, from)
        at(service, chainId, to)
    {
        if (from == to) return;
        string[] storage l = _lists[service][chainId];
        string memory v = l[from];
        if (from < to) {
            for (uint256 j = from; j < to; ++j) {
                l[j] = l[j + 1];
            }
        } else {
            for (uint256 j = from; j > to; --j) {
                l[j] = l[j - 1];
            }
        }
        l[to] = v;
        emit Moved(service, chainId, from, to);
    }

    /// @notice Replace one entry in place, keeping its position.
    function setAt(bytes32 service, uint256 chainId, uint256 i, string calldata url)
        public
        onlyOwner
        at(service, chainId, i)
    {
        string[] storage l = _lists[service][chainId];
        emit Removed(service, chainId, i, l[i]);
        l[i] = url;
        emit Added(service, chainId, i, url);
    }

    /// @notice Replace a whole list. An empty `next` clears it, which returns
    ///         the chain to the fallback.
    function set(bytes32 service, uint256 chainId, string[] calldata next) public onlyOwner {
        _note(service, chainId);
        emit Reset(service, chainId, _lists[service][chainId].length);
        delete _lists[service][chainId];
        for (uint256 i; i != next.length; ++i) {
            _push(service, chainId, next[i]);
        }
    }

    // ------------------------------------------------------------- OWNERSHIP

    /// @notice Offer ownership to `next`. Nothing changes until it is
    ///         accepted; offering `address(0)` withdraws an offer.
    /// @dev There is no renounce, for zRpcList's reason: an unowned list can
    ///      never drop an endpoint that has gone bad.
    function transferOwnership(address next) public onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    /// @notice Accept an ownership offer made to `msg.sender`.
    function acceptOwnership() public {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        delete pendingOwner;
    }

    // ------------------------------------------------------------- INTERNAL

    /// @dev No validation on chain, for zRpcList's reason: the page checks
    ///      every entry's shape per service anyway, and skips what it cannot
    ///      use, so a malformed write degrades to fewer endpoints, never none.
    function _push(bytes32 service, uint256 chainId, string memory url) internal {
        _note(service, chainId);
        string[] storage l = _lists[service][chainId];
        l.push(url);
        emit Added(service, chainId, l.length - 1, url);
    }

    function _note(bytes32 service, uint256 chainId) internal {
        if (known[service][chainId]) return;
        known[service][chainId] = true;
        _services.push(service);
        _chains.push(chainId);
    }
}
