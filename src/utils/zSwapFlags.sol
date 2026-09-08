// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title zSwapFlags
/// @notice Lanes the page may offer but does not switch on for itself, held on
///         chain so the decision can change without a new page.
///
/// WHY THIS EXISTS
///   zSwap ships as immutable bytecode. A lane that depends on somebody ELSE
///   running infrastructure - a relayer, a keeper - therefore has no good
///   default: shipping it on promises a service that may not exist, and
///   shipping it off means it can never start, because nothing can turn it on.
///   The page resolves that with a per-browser opt-in, which is honest but
///   one-directional: a viewer who enabled a lane keeps it forever, and if the
///   contract behind it turned out to be broken there would be no way to
///   withdraw the offer short of deploying a new page and waiting out the
///   resolver's maturity while everyone migrated.
///
///   This is the missing direction. One read tells the page whether a lane is
///   ON for everyone, OFF for everyone, or left to the viewer.
///
/// THE THREE STATES, AND WHY OFF IS THE POINT
///   `UNSET` is not "off" - it is "the page decides", which today means the
///   viewer's own opt-in. `ON` bootstraps a lane once its off-chain half is
///   actually running, without asking anyone to find a setting. `OFF` is the
///   one that could not be expressed any other way: it overrides an opt-in a
///   viewer has already made. That asymmetry is deliberate. Turning a lane on
///   is a convenience; turning it off is the only remedy an immutable page has
///   when the thing it points at goes wrong.
///
/// ROOTED TO MAINNET
///   One deployment, on Ethereum, read from every chain the page runs on - the
///   same shape as the RPC roster and the solver list, and for the same reason:
///   a per-chain deployment is a per-chain divergence, and a lane being on
///   here and off there is a bug nobody would find until it mattered. The page
///   reads this through its mainnet read path, so an L2 visitor gets the same
///   answer as a mainnet one. `chainId` is a KEY here, not the chain this
///   contract sits on, which is what lets one mainnet deployment answer
///   differently for Base and for Robinhood.
///
/// WHAT THIS CANNOT DO
///   It holds no funds, names no contracts and authorises no calls. The worst
///   a hostile owner can do is show a lane that should be hidden or hide one
///   that should be shown - never redirect a transaction, because every
///   address the page transacts against is baked into the page's own bytes.
///   That bound is what makes a mutable admin acceptable here at all, and it
///   is the same bound the RPC roster and the solver list are curated under.
contract zSwapFlags {
    /// @notice The page decides for itself. NOT the same as `OFF`.
    uint8 internal constant UNSET = 0;
    /// @notice Offered to everyone, no opt-in needed.
    uint8 internal constant ON = 1;
    /// @notice Withdrawn from everyone, overriding an opt-in already made.
    uint8 internal constant OFF = 2;

    event Set(bytes32 indexed name, uint256 indexed chainId, uint8 state);
    event OwnerProposed(address indexed pending);
    event OwnerChanged(address indexed from, address indexed to);

    error NotOwner();
    error BadState();
    error LengthMismatch();

    /// @notice Curation. Two-step handoff, because a mistyped owner here is a
    ///         lane nobody can ever withdraw again.
    address public owner;
    address public pendingOwner;

    /// @dev name => chainId => state. Chain 0 is the fallback consulted when a
    ///      chain has no entry of its own, so one write can cover every chain
    ///      and a later per-chain write can carve one out.
    mapping(bytes32 name => mapping(uint256 chainId => uint8 state)) public stateAt;

    modifier onlyOwner() {
        require(msg.sender == owner, NotOwner());
        _;
    }

    constructor(address owner_) payable {
        owner = owner_;
        emit OwnerChanged(address(0), owner_);
    }

    /// @notice The state of `name` on `chainId`: the chain's own entry if it
    ///         has one, otherwise the all-chains fallback at key 0.
    /// @dev The one function the page calls. A chain-specific `OFF` therefore
    ///      overrides an all-chains `ON`, and vice versa - specific beats
    ///      general, which is the only ordering that lets a single chain be
    ///      carved out of a blanket decision.
    function stateOf(bytes32 name, uint256 chainId) public view returns (uint8) {
        uint8 s = stateAt[name][chainId];
        return s == UNSET ? stateAt[name][0] : s;
    }

    /// @notice Set one lane on one chain. `chainId` 0 sets the fallback.
    function set(bytes32 name, uint256 chainId, uint8 state) public onlyOwner {
        require(state <= OFF, BadState());
        stateAt[name][chainId] = state;
        emit Set(name, chainId, state);
    }

    /// @notice The same, across several chains at once, so a lane goes on or
    ///         off everywhere in one transaction rather than in three that a
    ///         reorg or a stuck nonce can leave half-applied.
    function setMany(bytes32 name, uint256[] calldata chainIds, uint8[] calldata states)
        public
        onlyOwner
    {
        require(chainIds.length == states.length, LengthMismatch());
        for (uint256 i; i != chainIds.length; ++i) {
            set(name, chainIds[i], states[i]);
        }
    }

    // ------------------------------------------------------------- OWNERSHIP

    /// @notice Offer the role. Nothing changes until it is accepted.
    /// @dev Two steps rather than one for the reason at the top: the only
    ///      remedy this contract provides is `OFF`, and an owner that is a typo
    ///      is a remedy nobody holds. Proposing `address(0)` is allowed and is
    ///      how a pending handoff is cancelled.
    function transferOwnership(address to) public onlyOwner {
        pendingOwner = to;
        emit OwnerProposed(to);
    }

    /// @notice Take the role that was offered to you.
    function acceptOwnership() public {
        address to = pendingOwner;
        require(msg.sender == to, NotOwner());
        emit OwnerChanged(owner, to);
        owner = to;
        pendingOwner = address(0);
    }
}
