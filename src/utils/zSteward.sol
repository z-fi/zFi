// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title zSteward
/// @notice Owner of zSwap's curated lists - zRpcList, zEndpoints, zSolverList
///         and zSwapFlags - that puts a public delay on every change widening
///         what the page talks to. Changes that only narrow it apply at once.
///
/// WHY
///   Each list is read by an immutable page, and an entry added to one is an
///   endpoint every copy of the page starts using on its next read. Owned by a
///   key directly, an entry can appear in one block and be in use in the next,
///   before anyone has seen it. Owned by this contract, an addition is first a
///   `Queued` event and takes effect no sooner than `DELAY` later: anyone
///   watching has that long to inspect it, and the guardian has that long to
///   cancel it.
///
/// OPTIONAL
///   The page reads its lists wherever they are held and works the same
///   whether or not this contract exists. Holding a list here changes only how
///   that list can be changed; anyone can see which lists it holds, because
///   each list's `owner()` names this contract.
///
/// THE ASYMMETRY
///   The page keeps the values built into its own bytes behind every list, so
///   removing an entry, disabling a solver or switching a lane OFF leaves it
///   only with entries already listed, or with those values. Those calls skip
///   the queue (`narrow`), so a node or relay that goes bad is still dropped
///   in one transaction.
///   Everything else waits: adding, replacing, reordering, re-enabling,
///   switching ON, handing ownership on, and changing a role.
///
/// RECEIVING A LIST
///   A list's owner offers it with `transferOwnership(this)`, and `accept`
///   completes the handover at once. Anyone may call `accept`: the offer is
///   the owner's own, and taking a list here only removes instant power over
///   it. A list leaves only through the queue.
///
/// ROLES
///   `steward` queues, narrows, and cancels. `guardian` cancels anything
///   queued, narrows, and replaces the steward at once. The guardian hands its
///   own role on directly; the steward can replace it only through the queue,
///   which the guardian can cancel. `execute` is open to anyone once an
///   operation is due, so a change that has waited out the delay does not
///   depend on any one key to land, and lapses if nobody lands it within
///   `GRACE`.
///
/// SCOPE
///   `narrow` is checked by calldata shape alone, against the list contracts'
///   own functions, so it reaches whatever this contract owns, and this
///   contract owns only what an owner chose to hand it.
contract zSteward {
    /// @notice Seconds between `queue` and the earliest `execute`.
    uint256 public immutable DELAY;

    /// @notice Seconds after an operation falls due during which it can still
    ///         be executed.
    uint256 public constant GRACE = 14 days;

    /// @notice Queues, narrows and cancels.
    address public steward;

    /// @notice Cancels, narrows, and replaces the steward. May be zero.
    address public guardian;

    /// @notice Counter folded into every operation id, so the same call can be
    ///         queued again after it has run or been cancelled.
    uint256 public nonce;

    /// @notice When each queued operation falls due; zero once it has run or
    ///         been cancelled, or if it was never queued.
    mapping(bytes32 id => uint256) public eta;

    error Unauthorized();
    error TooShort();
    error NotQueued();
    error NotDue();
    error Expired();
    error NotNarrowing();
    error NoCode();

    event Queued(bytes32 indexed id, address indexed target, bytes data, uint256 nonce, uint256 eta);
    event Executed(bytes32 indexed id);
    event Cancelled(bytes32 indexed id);
    event Narrowed(address indexed target, bytes data);
    event StewardSet(address indexed steward);
    event GuardianSet(address indexed guardian);

    /// @param steward_  Who queues changes.
    /// @param guardian_ Who can cancel them and replace the steward.
    /// @param delay     Seconds every widening change waits. At least a day.
    constructor(address steward_, address guardian_, uint256 delay) payable {
        require(delay >= 1 days, TooShort());
        DELAY = delay;
        steward = steward_;
        guardian = guardian_;
        emit StewardSet(steward_);
        emit GuardianSet(guardian_);
    }

    // --------------------------------------------------------------- RECEIVE

    /// @notice Take ownership of `target`, which its owner has offered to this
    ///         contract. Open to anyone.
    function accept(address target) public {
        _call(target, abi.encodeWithSelector(0x79ba5097));
    }

    // ----------------------------------------------------------------- QUEUE

    /// @notice The id of `data` sent to `target` as the `n`th queued operation.
    function opId(address target, bytes calldata data, uint256 n) public pure returns (bytes32) {
        return keccak256(abi.encode(target, data, n));
    }

    /// @notice Announce a call. It can run from `block.timestamp + DELAY`.
    function queue(address target, bytes calldata data) public returns (bytes32 id) {
        require(msg.sender == steward, Unauthorized());
        uint256 n = nonce++;
        id = opId(target, data, n);
        uint256 t = block.timestamp + DELAY;
        eta[id] = t;
        emit Queued(id, target, data, n, t);
    }

    /// @notice Run a queued call that is due. Open to anyone.
    function execute(address target, bytes calldata data, uint256 n) public {
        bytes32 id = opId(target, data, n);
        uint256 t = eta[id];
        require(t != 0, NotQueued());
        require(block.timestamp >= t, NotDue());
        require(block.timestamp <= t + GRACE, Expired());
        delete eta[id];
        emit Executed(id);
        _call(target, data);
    }

    /// @notice Drop a queued call before it runs.
    function cancel(bytes32 id) public {
        require(msg.sender == steward || msg.sender == guardian, Unauthorized());
        require(eta[id] != 0, NotQueued());
        delete eta[id];
        emit Cancelled(id);
    }

    // ---------------------------------------------------------------- NARROW

    /// @notice Run a call that can only shrink a list or switch a lane off,
    ///         without waiting.
    function narrow(address target, bytes calldata data) public {
        require(msg.sender == steward || msg.sender == guardian, Unauthorized());
        require(narrows(data), NotNarrowing());
        emit Narrowed(target, data);
        _call(target, data);
    }

    /// @notice Whether `data` is one of the calls `narrow` accepts:
    ///           zRpcList, zSolverList   remove(uint256), pop()
    ///           zEndpoints              remove(bytes32,uint256,uint256), pop(bytes32,uint256)
    ///           zSolverList             setEnabled(uint256,false)
    ///           zSwapFlags              set(bytes32,uint256,2)   2 = OFF
    ///         Lengths are exact, so no other encoding passes.
    function narrows(bytes calldata data) public pure returns (bool) {
        if (data.length < 4) return false;
        bytes4 s = bytes4(data);
        uint256 n = data.length;
        if (s == 0x4cc82215) return n == 36; // remove(uint256)
        if (s == 0xa4ece52c) return n == 4; // pop()
        if (s == 0xaceba3fd) return n == 100; // remove(bytes32,uint256,uint256)
        if (s == 0xb87e183d) return n == 68; // pop(bytes32,uint256)
        if (s == 0xe5c13dd1) return n == 68 && uint256(bytes32(data[36:68])) == 0; // setEnabled(uint256,bool)
        if (s == 0x97f10dcd) return n == 100 && uint256(bytes32(data[68:100])) == 2; // set(bytes32,uint256,uint8)
        return false;
    }

    // ----------------------------------------------------------------- ROLES

    /// @notice Replace the steward: at once by the guardian, or through the
    ///         queue.
    function setSteward(address next) public {
        require(msg.sender == guardian || msg.sender == address(this), Unauthorized());
        steward = next;
        emit StewardSet(next);
    }

    /// @notice Replace the guardian: at once by the guardian itself, or
    ///         through the queue.
    function setGuardian(address next) public {
        require(msg.sender == guardian || msg.sender == address(this), Unauthorized());
        guardian = next;
        emit GuardianSet(next);
    }

    // -------------------------------------------------------------- INTERNAL

    function _call(address target, bytes memory data) internal {
        require(target.code.length != 0, NoCode());
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
