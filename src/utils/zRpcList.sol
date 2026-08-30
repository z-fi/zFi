// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title zRpcList
/// @notice The curated public RPC endpoints a walletless visitor reads
///         through, held on chain so the curation can change without a new
///         page.
///
/// WHY THIS EXISTS
///   The dapp can quote, list tokens and draw its chart before any wallet is
///   connected - but only through some node. Hardcoding endpoints in the page
///   would freeze that choice for the page's whole immutable life: an endpoint
///   that dies, degrades or turns hostile could not be dropped until the next
///   version. So the page reads the list from chain - from this contract, whose
///   address the version publishes as `RPCS()` - and merges it ahead of the
///   endpoints baked into the page, which remain as the bootstrap seeds and the fallback
///   for when this contract cannot be read (older versions, a page opened from
///   disk, a read that fails).
///
/// TRUST
///   A read endpoint sees queries but never keys: the page sends only
///   eth_call/eth_blockNumber-class reads here, and signing always goes to the
///   user's wallet. A lying endpoint can misstate a quote; it cannot redirect
///   funds, because the calldata the page builds targets constant contracts
///   and the router re-checks the user's bound at execution. Curating this
///   list is therefore the same class of decision as curating the token list,
///   held by the same DAO on the same terms.
///
/// WHY THIS IS NOT THE SOLVER ROSTER
///   zSolverList curates the off-chain solvers the page may race its own
///   venues against, and it looks superficially like this contract: a DAO, a
///   roster, the same surgical ops. They are deliberately separate deploys,
///   because they sit at opposite ends of the stack. THIS ROSTER IS THE
///   BOOTSTRAP: nothing the page displays - the token list, the chart, a
///   balance, or the solver roster itself - can be read until a node here
///   answers, and a node that lies misstates all of it. A solver sits at the
///   top of that stack, proposes one route on one screen, and is bounded at
///   execution by an adapter that measures what actually arrived. Different
///   layer, different failure class, different bar for the transaction that
///   changes it - and no reason for a curation call about routing economics to
///   share an admin surface and a storage layout with the read path
///   everything else depends on.
///
/// WHY A SATELLITE, NOT A FIELD ON zSwap
///   zSwap's pointers are the immutable, audited surface - the lineage walks
///   by them, and nothing else on that contract may move. Mutability lives
///   here, one `new` away, on the pattern the boards already use for their
///   metadata renderers: created by the parent, address published by an
///   immutable getter, maintained by the same DAO that deploys successors.
contract zRpcList {
    /// @notice Governance. Starts as whatever this deployment's parent passed
    ///         in - a multisig today, the DAO when it is ready - and moves by
    ///         the two-step handoff below.
    /// @dev NOT a constant, unlike the trust roots on zSwap itself. Curation
    ///      is an ongoing job, and the party doing it will change hands more
    ///      than once over a page that never can: a signer set rotates, a
    ///      multisig graduates to a governor contract, a compromised key has
    ///      to be abandoned in an afternoon. Freezing the admin here would
    ///      mean answering any of those with a new deploy of the satellite AND
    ///      a new deploy of the version that names it, which is the exact
    ///      rigidity this contract exists to relieve. What it costs is honest
    ///      to state: whoever holds this address can curate, and the trust
    ///      argument below - a bad entry misprices, it cannot take funds - is
    ///      what keeps that bounded.
    address public owner;

    /// @notice The address that has been offered ownership and has not yet
    ///         accepted it.
    /// @dev Two-step on purpose. A one-step transfer sends the only key this
    ///      contract has to an address that was typed once, and a typo is
    ///      unrecoverable: the roster freezes at whatever it held, forever,
    ///      with no way to drop a hostile entry. Requiring the recipient to
    ///      call `acceptOwnership` proves the address exists, is controlled,
    ///      and can transact - which is the whole of what could go wrong.
    address public pendingOwner;

    error NotOwner();

    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Offer ownership to `next`. Takes effect only when `next` calls
    ///         `acceptOwnership`; until then the current owner still governs
    ///         and can re-offer or withdraw by offering elsewhere.
    /// @dev Passing the zero address withdraws a pending offer. It cannot
    ///      RENOUNCE ownership, and there is no function that can: an
    ///      unowned roster is one that can never drop an endpoint that has
    ///      gone bad, which is strictly worse than an owned one - the owner's
    ///      power here is to curate a list the page already treats as
    ///      untrusted, not to move anyone's funds.
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

    /// @dev The endpoints, `https://...`, in preference order: the page tries
    ///      position 0 first and fails over down the list.
    ///
    ///      An array of strings, not one `|`-packed string. Packing is cheaper
    ///      per write and it makes every edit a full restatement of the
    ///      roster - which is how a roster ends up broken by a typo in an
    ///      entry nobody meant to touch. It also pushes a parser into the page,
    ///      where a mis-split is a silent one: an entry that loses its scheme
    ///      is not a malformed URL, it is a request somewhere else.
    string[] internal _rpcs;

    error BadIndex();

    /// @dev Emitted by `set` BEFORE the replacement, carrying the length that
    ///      was discarded. Without it a wholesale replacement is invisible to
    ///      anyone rebuilding the roster from logs: `delete` emits nothing, so
    ///      replacing [a,b,c] with [x,y] looks like two overwrites and an
    ///      indexer keeps `c` - an endpoint the curator believes they dropped,
    ///      still being merged into the page's list.
    event Reset(uint256 oldLength);

    event Added(uint256 indexed index, string url);
    event Removed(uint256 indexed index, string url);
    event Moved(uint256 indexed from, uint256 indexed to);

    /// @dev Bounds are checked by name rather than left to the array's own
    ///      panic, so a stale index from a UI built against an older roster
    ///      fails legibly.
    modifier at(uint256 i) {
        if (i >= _rpcs.length) revert BadIndex();
        _;
    }

    /// @param initial The seed curation this roster is born holding. The page
    ///                carries its own seeds too and merges them back in behind
    ///                whatever is here, so this is a starting point, never a
    ///                dependency: an empty roster degrades to exactly the
    ///                behaviour of a page that cannot read this contract.
    /// @param admin   Who may curate from here.
    /// @dev THIS CONTRACT IS DEPLOYED ON ITS OWN, and a version names it by
    ///      address rather than creating it. That is a deliberate trade and
    ///      the cost belongs in the open: a satellite the constructor creates
    ///      cannot be a roster the deployer had already filled with their own
    ///      endpoints, and one passed in by address can be. What buys the
    ///      trade back is that the same is true after deploy anyway - ownership
    ///      here is a transferable two-step, so the roster's contents were
    ///      never fixed by the version that names it, and pretending otherwise
    ///      would be the only real loss. Verify this address before trusting a
    ///      version that points at it; the page pins its own seeds regardless.
    constructor(string[] memory initial, address admin) {
        owner = admin;
        emit OwnershipTransferred(address(0), admin);
        for (uint256 i; i < initial.length; ++i) {
            _push(initial[i]);
        }
    }

    // ------------------------------------------------------------- READS

    /// @notice Every endpoint, in preference order, in one call.
    /// @dev An explicit getter rather than a public array: the compiler's own
    ///      getter returns one element per call - a dozen round trips to learn
    ///      a dozen URLs, made through the very endpoint the page is trying to
    ///      choose an alternative to.
    function rpcs() public view returns (string[] memory) {
        return _rpcs;
    }

    /// @notice How many endpoints are curated.
    function count() public view returns (uint256) {
        return _rpcs.length;
    }

    /// @notice One endpoint by position.
    function get(uint256 i) public view at(i) returns (string memory) {
        return _rpcs[i];
    }

    // -------------------------------------------------------- GOVERNANCE
    //
    // Surgical by default, wholesale as an escape hatch. Making the DAO
    // restate an entire roster to drop one dead node is how a roster ends up
    // dropped by a typo, so each op below is the smallest write that does the
    // job, and `set` exists for the case where the roster has become wrong in
    // every entry.

    /// @notice Append an endpoint at the end of the failover order.
    function add(string calldata url) public onlyOwner {
        _push(url);
    }

    /// @notice Drop an endpoint. PRESERVES ORDER - the tail shifts down rather
    ///         than the last entry being swapped into the hole, because order
    ///         is the curation and a swap-and-pop would silently promote
    ///         whatever sat last.
    function remove(uint256 i) public onlyOwner at(i) {
        emit Removed(i, _rpcs[i]);
        uint256 last = _rpcs.length - 1;
        for (uint256 j = i; j < last; ++j) {
            _rpcs[j] = _rpcs[j + 1];
        }
        _rpcs.pop();
    }

    /// @notice Drop the last endpoint - the cheap case of `remove`, and the
    ///         way an `add` is undone.
    function pop() public onlyOwner {
        if (_rpcs.length == 0) revert BadIndex();
        emit Removed(_rpcs.length - 1, _rpcs[_rpcs.length - 1]);
        _rpcs.pop();
    }

    /// @notice Move an endpoint to another position, shifting what lies
    ///         between. Changing preference cannot change anything else: the
    ///         entry that arrives at `to` is the entry that left `from`.
    function move(uint256 from, uint256 to) public onlyOwner at(from) at(to) {
        if (from == to) return;
        string memory v = _rpcs[from];
        if (from < to) {
            for (uint256 j = from; j < to; ++j) {
                _rpcs[j] = _rpcs[j + 1];
            }
        } else {
            for (uint256 j = from; j > to; --j) {
                _rpcs[j] = _rpcs[j - 1];
            }
        }
        _rpcs[to] = v;
        emit Moved(from, to);
    }

    /// @notice Replace one endpoint in place, keeping its position.
    function setAt(uint256 i, string calldata url) public onlyOwner at(i) {
        emit Removed(i, _rpcs[i]);
        _rpcs[i] = url;
        emit Added(i, url);
    }

    /// @notice Replace the whole roster. The escape hatch, not the default -
    ///         everything above exists so routine curation never needs this.
    ///         The page re-reads once per session, so a change takes effect on
    ///         the next page load, never mid-quote.
    function set(string[] calldata next) public onlyOwner {
        emit Reset(_rpcs.length);
        delete _rpcs;
        for (uint256 i; i < next.length; ++i) {
            _push(next[i]);
        }
    }

    /// @dev No URL validation on chain: a scheme check in Solidity costs gas
    ///      on every write to restate something the page must do anyway on
    ///      input it does not trust. An entry the page cannot parse is skipped
    ///      there, and the page's seeds are merged back in - a malformed write
    ///      degrades to fewer endpoints, never to none.
    function _push(string memory url) internal {
        _rpcs.push(url);
        emit Added(_rpcs.length - 1, url);
    }
}
