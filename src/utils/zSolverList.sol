// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title zSolverList
/// @notice The curated off-chain solver endpoints the page may race its own
///         on-chain venues against, held on chain so the curation can change
///         without a new page.
///
/// WHY THIS EXISTS
///   zQuoter, the precision pools and the orderbook answer from the chain and
///   need nothing but a node. They are also not always the best price: a
///   professional solver network sees inventory and private flow that no
///   `eth_call` can reach. The page has always been able to ASK one - what it
///   could not do was change WHICH ones it asks, because an immutable page
///   freezes its endpoint list for the whole of its life. An endpoint that
///   dies, starts charging, or turns hostile could not be dropped until the
///   next version shipped. So the page reads the roster from chain and merges
///   it ahead of anything baked in.
///
/// THIS LIST HOLDS ENDPOINTS, NEVER KEYS
///   Nothing here is secret and nothing here is meant to be. A solver that
///   requires an API key is reached through a proxy that attaches the key on
///   its own side; what is published here is that proxy's URL. There is no
///   scheme by which a secret lives on a public chain - "encrypted on chain"
///   only moves the trust to whoever holds the decryption key, and buys
///   nothing this design does not already have. If an entry ever needs a key
///   the PAGE can send, that solver does not belong on this list.
///
/// TRUST
///   A solver endpoint is an ADVERSARY THAT PROPOSES, never an authority.
///   What it returns is a target address and a blob of calldata; both are
///   untrusted bytes, and both are executed only through the record's
///   zSolverFill-shaped adapter, which measures what actually arrived and
///   reverts below the user's bound. So the worst a lying, degraded or
///   captured endpoint can do is fail to win the race - it cannot move funds,
///   and it cannot make a losing route look like a winning one, because the
///   route it proposes is priced by the same `minOut` that would reject it.
///
///   Two things it CAN do, which curation - not arithmetic - has to answer:
///   it sees the pair, the size and (on quote, not price, legs) the taker; and
///   it can go down, taking its lane with it. The first is why this roster is
///   DAO-curated rather than open. The second is why the on-chain venues are
///   never a fallback the page SWITCHES to on failure but a lane that always
///   runs: an endpoint that never answers costs one deadline, not a quote.
///
/// WHY THIS IS NOT THE RPC ROSTER
///   zRpcList looks superficially identical - a DAO, a roster, the same
///   surgical ops - and is deliberately a separate deploy, because the two sit
///   at opposite ends of the stack. THE RPC ROSTER IS THE BOOTSTRAP: nothing
///   the page displays, including THIS roster, can be read until a node there
///   answers, a node that lies misstates all of it, and an empty roster is a
///   dead page. A solver lane sits at the top of that stack, is bounded at
///   execution, touches one screen, and an empty roster here is a perfectly
///   good steady state - it is what this ships as. Sharing an admin surface
///   and a storage layout between a routing-economics decision and the read
///   path everything depends on would put them one fat-fingered transaction
///   apart for no gain.
///
/// GOVERNING WHICH CODE RUNS, NEVER WHAT THE CODE DOES
///   Every lever here is membership: which endpoints may be asked, in what
///   order, under what handicap, through which adapter. None of it reaches
///   inside an adapter, which has no owner and no upgrade path - see
///   zSolverFill. That split is what lets a user read one fixed set of bytes
///   and know it bounds every fill forever, while the DAO still swaps stale or
///   blocked endpoints freely. A bad adapter is retired the same way a bad
///   endpoint is: `setEnabled(i, false)`, or re-point the lane.
///
///   WHY EVERY LANE MUST SETTLE INSIDE THE USER'S OWN TRANSACTION
///   A lane is only curatable on these terms if what it does can be MEASURED
///   when it happens. That rules out the intent/batch designs - CoW being the
///   obvious one - and it is worth recording that this was considered and
///   declined rather than overlooked. Such a route parks the user's sell
///   tokens in an adapter for minutes while an off-chain order is posted and
///   some third party settles it later. There is no output in the user's
///   transaction, so there is no delta, so `minOut` has nothing to check: the
///   adapter stops being something you verify and becomes something you trust
///   with custody. That may be a fine trade in a page that can be patched next
///   week. It is not one to freeze into a page that cannot be, where the
///   failure mode - deposit succeeded, order never posted, tokens sitting in
///   an adapter - would have no fix at all.
///
///   So the rule is a rule, not a preference: a lane that cannot be priced by
///   the balance it moves in the transaction it moves it in does not belong
///   on this roster.
///
///   ONE CAVEAT, STATED PLAINLY. That argument holds only if the page can
///   trust WHICH adapter it is calling, and this roster cannot give it that:
///   the page reads these records through an RPC it also learned from chain,
///   so a reader who controls that node controls this answer too and can name
///   an adapter that is not the audited one. The page must therefore pin the
///   adapters it will accept - by address or by codehash, baked into its
///   immutable source - and treat the `adapter` field as a selection among
///   pinned choices rather than as an instruction. Curating an address is
///   only "governing which code runs" when the set of code that CAN run is
///   fixed somewhere the curator cannot reach.
contract zSolverList {
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

    /// @notice One curated solver lane.
    /// @param name     Label shown when this lane wins. Free text.
    /// @param endpoint `https://...` base URL - a proxy's URL when the solver
    ///                 needs a key. The page appends its own paths, and a
    ///                 solver whose request/response shape the page does not
    ///                 already know is skipped: adding a record can re-point a
    ///                 protocol the page speaks, never teach it a new one.
    /// @param adapter  The zSolverFill-shaped contract this solver's calldata
    ///                 is executed through. NOT optional and NOT defaulted -
    ///                 the bound check lives there, and a record without one
    ///                 would be a route with no bound at all, so every write
    ///                 rejects the zero address. It is per-record rather than
    ///                 one global address because solvers differ in how output
    ///                 must be routed back, and a new adapter for one of them
    ///                 must not be a migration for all of them.
    /// @param handicapBps Improvement over the best ON-CHAIN quote this lane
    ///                 must beat before the page will offer it. Zero would
    ///                 make the page prefer a one-wei improvement bought with
    ///                 a proxy dependency, a privacy leak and an unfamiliar
    ///                 contract in the path; this is where the DAO prices that
    ///                 trade-off, per solver, without a new page. Capped at
    ///                 `MAX_HANDICAP_BPS` so a fat-fingered value parks a lane
    ///                 rather than silently pricing it out forever.
    /// @param enabled  A kill switch that keeps the record's curation intact:
    ///                 stop a misbehaving endpoint in one transaction, turn it
    ///                 back on later without re-deriving what it was.
    struct Solver {
        string name;
        string endpoint;
        address adapter;
        uint16 handicapBps;
        bool enabled;
    }

    /// @dev The lanes, in priority order. Position 0 is asked first and, on a
    ///      tie inside the handicap, offered first. Order is a curation signal
    ///      (a solver the DAO trusts more, or one that answers faster), never
    ///      a correctness one: every enabled lane is raced in parallel and the
    ///      best bound-checked quote wins wherever it sits.
    ///
    ///      An array of structs, not one packed string. The fields are typed,
    ///      and a mis-split string yielding the wrong `adapter` would not be a
    ///      malformed record - it would be a route through the wrong bound
    ///      check. Packing would also make every edit a full restatement of
    ///      the roster, when the acts this list actually sees are per-record:
    ///      kill the one endpoint that started 403ing, retune one handicap,
    ///      move one lane ahead of another.
    Solver[] internal _solvers;

    /// @notice Ceiling on a handicap, in basis points. 10% - far past any
    ///         honest tuning, and low enough that a stray extra digit cannot
    ///         express "disabled" in a field that is not the kill switch.
    uint16 public constant MAX_HANDICAP_BPS = 1000;

    error NoAdapter();
    error BadIndex();
    error BadHandicap();

    /// @dev Emitted by `set` BEFORE the replacement, carrying the length that
    ///      was discarded. Without it a wholesale replacement is invisible to
    ///      anyone rebuilding the roster from logs: `delete` emits nothing, so
    ///      replacing three lanes with two looks like two overwrites, and an
    ///      indexer keeps a third lane the curator believes they dropped -
    ///      still enabled, still carrying an adapter.
    event Reset(uint256 oldLength);

    /// @dev Carries the WHOLE record, not just its name. An earlier version
    ///      logged only `(index, name, adapter)`, which meant a lane that was
    ///      added and never edited had its endpoint - the one field this
    ///      roster exists to publish - in no log anywhere, and an indexer had
    ///      to fall back to reading state. Every field a curator can set is
    ///      now observable from the event stream alone.
    event Added(
        uint256 indexed index, string name, string endpoint, address adapter, uint16 handicapBps, bool enabled
    );
    event Removed(uint256 indexed index, string name);
    event Moved(uint256 indexed from, uint256 indexed to);
    event Enabled(uint256 indexed index, bool enabled);
    event Retuned(uint256 indexed index, uint16 handicapBps);
    event Repointed(uint256 indexed index, string endpoint, address adapter);

    /// @dev Bounds are checked by name rather than left to the array's own
    ///      panic, so a stale index from a UI built against an older roster
    ///      fails legibly.
    modifier at(uint256 i) {
        if (i >= _solvers.length) revert BadIndex();
        _;
    }

    /// @param initial The seed roster, and it should be EMPTY. A read endpoint
    ///                is reachable by anyone and answers the same to everyone;
    ///                a solver lane is a proxy somebody has to run, behind an
    ///                adapter that has to be deployed and reviewed first. A
    ///                lane added before either exists is a lane the page would
    ///                race against nothing. Add them afterwards, deliberately,
    ///                one public transaction each - which also means a version
    ///                pointing at this roster behaves exactly as its
    ///                predecessor until somebody turns the first lane on.
    /// @param admin   Who may curate from here.
    /// @dev THIS CONTRACT IS DEPLOYED ON ITS OWN, and a version names it by
    ///      address rather than creating it. See the same note on zRpcList:
    ///      the honest reading is that a named roster's contents were never
    ///      fixed by the version naming it, because ownership is transferable
    ///      either way. Here it matters more than it does there, because a
    ///      lane carries an `adapter` the page will call through - which is
    ///      exactly why the page must pin the adapters it accepts rather than
    ///      trusting this roster's answer.
    constructor(Solver[] memory initial, address admin) {
        owner = admin;
        emit OwnershipTransferred(address(0), admin);
        for (uint256 i; i < initial.length; ++i) {
            _push(initial[i]);
        }
    }

    // ------------------------------------------------------------- READS

    /// @notice Every lane, in priority order, in one call. INCLUDES DISABLED
    ///         LANES: the page needs to know a solver exists and is off, and
    ///         an index that shifted with the enabled set would make every
    ///         governance call a race against the page's last read.
    /// @dev An explicit getter rather than a public array: the compiler's own
    ///      getter for an array of structs holding strings does not return the
    ///      roster whole, and the page wants it in one `eth_call`.
    function solvers() public view returns (Solver[] memory) {
        return _solvers;
    }

    /// @notice How many lanes are curated, enabled or not.
    function count() public view returns (uint256) {
        return _solvers.length;
    }

    /// @notice One lane by position.
    function get(uint256 i) public view at(i) returns (Solver memory) {
        return _solvers[i];
    }

    // -------------------------------------------------------- GOVERNANCE
    //
    // Surgical by default, wholesale as an escape hatch. Making the DAO
    // restate the whole roster to disable one solver is how a roster ends up
    // disabled by a typo, so each op below is the smallest write that does the
    // job.

    /// @notice Append a lane at the end of the priority order.
    function add(Solver calldata s) public onlyOwner {
        _push(s);
    }

    /// @notice Drop a lane. PRESERVES ORDER - the tail shifts down rather than
    ///         the last record being swapped into the hole, because order is
    ///         the curation and a swap-and-pop would silently promote whatever
    ///         sat last. Removal is for a solver that is gone; to park one
    ///         that may come back, use `setEnabled` and keep its tuning.
    function remove(uint256 i) public onlyOwner at(i) {
        emit Removed(i, _solvers[i].name);
        uint256 last = _solvers.length - 1;
        for (uint256 j = i; j < last; ++j) {
            _solvers[j] = _solvers[j + 1];
        }
        _solvers.pop();
    }

    /// @notice Drop the last lane - the cheap case of `remove`, and the way an
    ///         `add` is undone.
    function pop() public onlyOwner {
        if (_solvers.length == 0) revert BadIndex();
        emit Removed(_solvers.length - 1, _solvers[_solvers.length - 1].name);
        _solvers.pop();
    }

    /// @notice Move a lane to another position, shifting what lies between.
    ///         The record that arrives at `to` is byte-for-byte the record
    ///         that left `from`, adapter and handicap included.
    function move(uint256 from, uint256 to) public onlyOwner at(from) at(to) {
        if (from == to) return;
        Solver memory s = _solvers[from];
        if (from < to) {
            for (uint256 j = from; j < to; ++j) {
                _solvers[j] = _solvers[j + 1];
            }
        } else {
            for (uint256 j = from; j > to; --j) {
                _solvers[j] = _solvers[j - 1];
            }
        }
        _solvers[to] = s;
        emit Moved(from, to);
    }

    /// @notice The kill switch. One SSTORE, no strings rewritten, tuning kept.
    function setEnabled(uint256 i, bool on) public onlyOwner at(i) {
        _solvers[i].enabled = on;
        emit Enabled(i, on);
    }

    /// @notice Retune one lane's required improvement over the on-chain best.
    function setHandicap(uint256 i, uint16 bps) public onlyOwner at(i) {
        if (bps > MAX_HANDICAP_BPS) revert BadHandicap();
        _solvers[i].handicapBps = bps;
        emit Retuned(i, bps);
    }

    /// @notice Re-point a lane at a new URL and/or a new adapter.
    /// @dev The two move together because they are one decision: an endpoint
    ///      whose response shape changed enough to need a different adapter is
    ///      not the same lane, and letting them drift apart across two
    ///      transactions leaves a window in which the page executes one
    ///      solver's calldata through another solver's bound check. Passing
    ///      the current value for either side is how you change only the other.
    function setEndpoint(uint256 i, string calldata endpoint, address adapter) public onlyOwner at(i) {
        if (adapter == address(0)) revert NoAdapter();
        _solvers[i].endpoint = endpoint;
        _solvers[i].adapter = adapter;
        emit Repointed(i, endpoint, adapter);
    }

    /// @notice Replace a whole lane in place, keeping its position.
    /// @dev Exists because `name` was otherwise immutable after `add`: with
    ///      only the field-wise setters, renaming a lane meant `remove` plus
    ///      `add` plus `move` - three transactions, two shift loops, and a
    ///      window in which the roster's order is wrong - or the wholesale
    ///      `set` the design says should not be routine. Validated through the
    ///      same `_push` rules, restated here because `_push` appends and this
    ///      does not.
    function setAt(uint256 i, Solver calldata s) public onlyOwner at(i) {
        if (s.adapter == address(0)) revert NoAdapter();
        if (s.handicapBps > MAX_HANDICAP_BPS) revert BadHandicap();
        emit Removed(i, _solvers[i].name);
        _solvers[i] = s;
        emit Added(i, s.name, s.endpoint, s.adapter, s.handicapBps, s.enabled);
    }

    /// @notice Replace the whole roster. The escape hatch, not the default -
    ///         everything above exists so routine curation never needs this,
    ///         and this exists so a roster that has become wrong in every
    ///         field is not repaired by twenty transactions in an order that
    ///         matters. The page re-reads once per session, so a change takes
    ///         effect on the next page load, never mid-quote.
    function set(Solver[] calldata next) public onlyOwner {
        emit Reset(_solvers.length);
        delete _solvers;
        for (uint256 i; i < next.length; ++i) {
            _push(next[i]);
        }
    }

    /// @dev The one place a lane is validated, so `add`, `set` and the
    ///      constructor cannot disagree about what a valid lane is. Nothing
    ///      about the URL is checked: a scheme check in Solidity costs gas on
    ///      every write to restate something the page must do anyway on input
    ///      it does not trust, and a record the page cannot use is skipped
    ///      there - a malformed write degrades to fewer lanes, never to a
    ///      broken page, because the on-chain venues do not come from here.
    function _push(Solver memory s) internal {
        if (s.adapter == address(0)) revert NoAdapter();
        if (s.handicapBps > MAX_HANDICAP_BPS) revert BadHandicap();
        _solvers.push(s);
        emit Added(_solvers.length - 1, s.name, s.endpoint, s.adapter, s.handicapBps, s.enabled);
    }
}
