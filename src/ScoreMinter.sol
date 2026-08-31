// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Minimal surface of the Wei Name Service this contract needs.
interface INameNFT {
    function registerSubdomain(string calldata label, uint256 parentId) external returns (uint256);
    function setText(uint256 tokenId, string calldata key, string calldata value) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function renew(uint256 tokenId) external payable;
    function isAvailable(string calldata label, uint256 parentId) external view returns (bool);
}

/// @title ScoreMinter
/// @notice Issues one `.wei` subdomain per game result, with the score written
///         onto the name as a text record, in a single transaction.
///
/// @dev WHY THIS CONTRACT EXISTS AT ALL. Two facts in the registry make the
///      obvious approaches impossible:
///
///        1. `setText` requires `ownerOf(tokenId) == msg.sender` exactly. No
///           operator, no approval. Whoever writes the record must own the
///           name at that instant - so a player cannot have the name minted
///           straight to them AND have records written in the same call.
///        2. `_register` uses `_safeMint`, so a contract receiving a name must
///           implement `onERC721Received`. zRouter's `SafeExecutor` can make
///           arbitrary calls but has no receiver hook; zRouter has the hook but
///           always routes outbound calls through the executor. Neither can do
///           both, so no deployed forwarder can carry this.
///
///      This contract does both: it receives the name, writes the record while
///      it is the owner, and hands it on. One signature, any wallet.
///
///      WHAT IT IS AND IS NOT. Because `registerSubdomain` is parent-owner
///      only, a contract holding the parent is the SOLE issuer of everything
///      beneath it. Nobody can mint a lookalike from a block explorer. That is
///      a real property, and it is the reason to deploy this rather than mint
///      under an open parent like `id.wei`.
///
///      It is NOT proof that a score was earned. `claim` believes what it is
///      told. A player can pass any number. This contract makes the namespace
///      exclusive and gives a later revision somewhere to put a verifier; it
///      does not make the number true, and nothing here should be described as
///      if it did.
///
///      ONE PRIVILEGE, AND ONLY ONE. There is no owner and no upgrade path:
///      the rules in `claim` are permanent, and changing them means a new
///      contract and a new parent - a visible act rather than a silent one.
///      The single exception is `recoverParent`, which lets the RECOVERY
///      address pull the parent back out. That exists because an immutable
///      contract holding a name forever is a bet that the contract is right;
///      the escape costs exclusivity, not user property, and the reasoning is
///      set out on RECOVERY below.
contract ScoreMinter {
    /// @notice The Wei Name Service registry.
    INameNFT public constant NAMES = INameNFT(0x0000000000696760E15f265e828DB644A0c242EB);

    /// @notice The name this contract owns and issues beneath. Set once.
    uint256 public immutable PARENT;

    /// @notice The only address the parent may ever be returned to.
    /// @dev A deliberate softening of "no admin". The parent can be pulled
    ///      back, but only BY this address and only TO it - the caller cannot
    ///      choose a destination, so a stolen call achieves nothing a stolen
    ///      key could not already do.
    ///
    ///      SAFE FOR NAMES ALREADY ISSUED. A subdomain stops resolving when its
    ///      `parentEpoch` no longer matches the parent's `epoch`, and the epoch
    ///      advances only on RE-REGISTRATION, never on transfer. Moving the
    ///      parent therefore leaves every name minted beneath it untouched and
    ///      still owned by its player. What recovery costs is EXCLUSIVITY: once
    ///      the parent is out, whoever holds it can issue more names under
    ///      `arcade.wei`, so "only the game issues these" becomes "the game or
    ///      this key". That is the trade, and it is worth making explicit.
    address public constant RECOVERY = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;

    /// @dev A label must exist and stay within what the registry accepts.
    uint256 constant MAX_LABEL = 63;
    /// @dev A score is a short decimal string. Long enough for any real run,
    ///      short enough that the record cannot be used as cheap storage.
    uint256 constant MAX_SCORE = 20;

    error NotRecovery();
    error Taken();
    error BadLabel();
    error BadScore();
    error NotHeld();

    event Claimed(uint256 indexed tokenId, address indexed to, string label, string score);

    constructor(uint256 parent) {
        PARENT = parent;
    }

    /// @notice Mint `label` beneath the parent, record `score` on it, and send
    ///         it to `to`.
    /// @dev The three steps must be one call: the middle one is only permitted
    ///      while this contract owns the name, and the last one is what stops
    ///      it keeping it. A revert anywhere unwinds all three.
    /// @param label The subdomain to mint. Lowercase a-z, 0-9 and hyphen; the
    ///        registry normalises and will reject anything it dislikes.
    /// @param score The value written to the `score` text record.
    /// @param to    Who ends up owning the name.
    function claim(string calldata label, string calldata score, address to)
        external
        returns (uint256 tokenId)
    {
        uint256 n = bytes(label).length;
        if (n == 0 || n > MAX_LABEL) revert BadLabel();
        if (bytes(score).length > MAX_SCORE) revert BadScore();
        if (to == address(0) || to == address(this)) revert BadLabel();
        if (!NAMES.isAvailable(label, PARENT)) revert Taken();

        tokenId = NAMES.registerSubdomain(label, PARENT);
        NAMES.setText(tokenId, "score", score);
        NAMES.transferFrom(address(this), to, tokenId);

        emit Claimed(tokenId, to, label, score);
    }

    /// @notice Return the parent to the recovery address.
    /// @dev The escape from a contract that cannot be changed: if `claim` turns
    ///      out to be wrong, or the namespace is wanted elsewhere, the name is
    ///      not stranded here forever. Names already issued keep working (see
    ///      RECOVERY above) - what stops is this contract's monopoly on issuing
    ///      new ones.
    function recoverParent() external {
        if (msg.sender != RECOVERY) revert NotRecovery();
        NAMES.transferFrom(address(this), RECOVERY, PARENT);
    }

    /// @notice Extend the parent's registration. Anyone may call and pay.
    /// @dev LOAD-BEARING, not a convenience. Names expire - a year, then a
    ///      ninety-day grace - and this contract has no owner to notice. If the
    ///      parent lapsed, every name already minted beneath it would stop
    ///      resolving and the parent itself could be registered by somebody
    ///      else, who would then own the namespace. Leaving renewal to anyone
    ///      willing to pay for it means the namespace outlives our attention.
    function renewParent() external payable {
        NAMES.renew{value: msg.value}(PARENT);
    }

    /// @dev Somewhere for `renew`'s refund to land. Without it the registry's
    ///      transfer back to this contract reverts and no renewal is possible.
    receive() external payable {}

    /// @notice Send any ether resting here to the recovery address.
    /// @dev Refunds and stray transfers would otherwise accumulate with no way
    ///      out. Anyone may call it; it can only pay RECOVERY, so there is
    ///      nothing to race for.
    function sweep() external {
        (bool ok,) = RECOVERY.call{value: address(this).balance}("");
        if (!ok) revert NotRecovery();
    }

    /// @notice Whether `label` can still be minted beneath the parent.
    function available(string calldata label) external view returns (bool) {
        return NAMES.isAvailable(label, PARENT);
    }

    /// @notice Whether this contract actually holds the parent yet.
    /// @dev The parent is transferred in after deployment, so there is a window
    ///      where this contract exists and can do nothing. A frontend should
    ///      check this before offering to mint rather than letting `claim`
    ///      revert deep inside the registry.
    function ready() external view returns (bool) {
        return NAMES.ownerOf(PARENT) == address(this);
    }

    /// @dev `_safeMint` calls this. Accepting only the registry's tokens keeps
    ///      the contract from becoming a resting place for arbitrary NFTs.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(NAMES)) revert NotHeld();
        return this.onERC721Received.selector;
    }
}
