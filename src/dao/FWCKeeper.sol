// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibString} from "../../lib/solady/src/utils/LibString.sol";

/// @notice Minimal Moloch permit interface. Permits are ERC6909 balances on the DAO:
/// `setPermit` (governance) mints uses to a spender, `spendPermit` burns one and runs
/// the exact call the permit was minted for.
interface IMoloch {
    function spendPermit(uint8 op, address to, uint256 value, bytes calldata data, bytes32 nonce)
        external
        payable
        returns (bool ok, bytes memory retData);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function config() external view returns (uint64);
    function castVote(uint256 id, uint8 support) external;
    function chat(string calldata message) external payable;
    function proposalThreshold() external view returns (uint96);
    function shares() external view returns (address);
    function badges() external view returns (address);
}

interface IShares {
    function delegate(address delegatee) external;
    function getVotes(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IBadges {
    function balanceOf(address owner) external view returns (uint256);
}

interface IFeeSplitter {
    function pending(uint256 tokenId) external view returns (uint256);
    function claimed(uint256 tokenId) external view returns (uint256);
}

/**
 * @title FWCKeeper
 * @notice Permissionless trigger for the FWC collector DAO's two recurring treasury
 *         actions: sweeping FWAcore fees into the vault, and spending a full vault
 *         balance on another TokenWorks pass.
 *
 * @dev The DAO mints permits to THIS CONTRACT, so this address must exist before the
 *      `setPermit` proposals are written — the permit id commits to the payload, not to
 *      the caller, and `spendPermit` burns from `msg.sender`.
 *
 *      Every function here is open on purpose. A caller cannot choose a destination, an
 *      amount, or a recipient: the payloads are fixed constants that must hash to what
 *      governance approved, and both actions pay into the vault. The only thing an
 *      outside caller supplies is gas, which is exactly the property that lets a cron
 *      job or a keeper bot run the DAO's chores without holding a privileged key.
 *
 *      Permits are invalidated by `bumpConfig()`, since the DAO derives every permit id
 *      from its `config` counter. After an emergency bump, governance must re-grant these
 *      permits; the ids returned by the view functions below move with `config`, so they
 *      always describe the permits this contract needs right now.
 */
contract FWCKeeper {
    /// @dev The collector DAO, its vault, the FWAcore fee splitter, and the pass contract.
    IMoloch public constant DAO = IMoloch(0xE7Aa6cA3a9Ca3fe92a425dFeaD24900B9BF49853);
    address public constant VAULT = 0xB3B3f4f1535305c5f40F9c0d6bCaf38032bF7F8e;
    address public constant FEES = 0x1C175b9F0e8C73eD3e677e1cBb1B5A2DD4373Bfe;
    address public constant PASS = 0xb33d806a94B6770C9d309E0842a75f8E6edCd5A6;

    /// @dev `remint()` takes exactly one ether; any other value reverts.
    uint256 public constant PASS_PRICE = 1 ether;

    /// @dev Only #156 is claimable today — #343 and #352 revert at the splitter even
    /// though the vault owns them. If that changes, governance grants a permit for the
    /// wider payload and it is spent through `spend()`; no redeploy is needed.
    uint256 public constant CLAIM_ID = 156;

    /// @dev Permit nonces. Governance must use these exact values, or the ids will not match.
    bytes32 public constant CLAIM_NONCE = keccak256("FWC_FEE_CLAIM_156");
    bytes32 public constant REMINT_NONCE = keccak256("FWC_REMINT");

    /// @dev Vault call opcode: 0 = CALL.
    uint8 internal constant OP_CALL = 0;

    /// @dev src_co multisig. It cannot direct this contract, only switch it off: a fast
    /// brake that does not wait on a vote, in the same spirit as its emergency permit.
    /// The DAO keeps the deeper controls — `setPermit(..., 0)` burns the permits outright
    /// and `bumpConfig()` invalidates every one of them — but both need governance.
    address public constant GUARDIAN = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;

    /// @dev When true, this contract will neither spend a permit nor open a proposal.
    /// Reversible: stopping is a pause, not a burn, and nothing here holds funds.
    bool public stopped;

    event FeesClaimed(address indexed caller, uint256 amount);
    event Reminted(address indexed caller, uint256 spent);
    event Spent(address indexed caller, bytes32 indexed nonce);
    event Proposed(address indexed caller, uint256 indexed id);
    event StopSet(bool stopped);
    event Reclaimed(address indexed token, uint256 amount);

    /// @dev Bumped per self-authored proposal so each gets a distinct nonce, and a
    /// re-run after a defeat is a new proposal rather than a collision with the old one.
    uint256 public proposalCount;

    error NoPermit();
    error NotGuardian();
    error NotMember();
    error RescueFailed();
    error Stopped();
    error NothingPending();
    error VaultUnderfunded();

    /**
     * PAYLOADS
     */

    /// @dev `vault.execute(FEES, 0, claim([156]))` — the bytes governance hashes into the permit.
    function claimPayload() public pure returns (bytes memory) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = CLAIM_ID;
        return abi.encodeWithSignature(
            "execute(address,uint256,bytes)", FEES, uint256(0), abi.encodeWithSignature("claim(uint256[])", ids)
        );
    }

    /// @dev `vault.execute(PASS, 1 ether, remint())` — the vault pays from its own balance.
    function remintPayload() public pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "execute(address,uint256,bytes)", PASS, PASS_PRICE, abi.encodeWithSignature("remint()")
        );
    }

    /**
     * ACTIONS
     */

    /// @notice Sweep accrued FWAcore fees into the vault. Anyone may call.
    /// @dev Reverts if nothing has accrued — the splitter rejects a zero claim. A revert
    /// rolls the whole call back, so a premature poke wastes gas but does not burn a use.
    function claimFees() external returns (uint256 claimed) {
        if (pendingFees() == 0) revert NothingPending();
        uint256 before = VAULT.balance;
        _spend(claimPayload(), CLAIM_NONCE);
        claimed = VAULT.balance - before;
        emit FeesClaimed(msg.sender, claimed);
    }

    /// @notice Spend 1 ETH of vault funds on another TokenWorks pass. Anyone may call.
    function remint() external {
        if (VAULT.balance < PASS_PRICE) revert VaultUnderfunded();
        _spend(remintPayload(), REMINT_NONCE);
        emit Reminted(msg.sender, PASS_PRICE);
    }

    /// @notice Spend any other permit governance has granted to this contract.
    /// @dev The escape hatch that keeps this contract useful as the DAO's needs change:
    /// a permit for a payload not known at deploy time is still spendable here. It can
    /// only ever run calls the DAO itself approved and minted a permit for.
    function spend(bytes calldata payload, bytes32 nonce) external returns (bytes memory retData) {
        retData = _spend(payload, nonce);
        emit Spent(msg.sender, nonce);
    }

    function _spend(bytes memory payload, bytes32 nonce) internal returns (bytes memory retData) {
        if (stopped) revert Stopped();
        if (DAO.balanceOf(address(this), _permitId(payload, nonce)) == 0) revert NoPermit();
        bool ok;
        (ok, retData) = DAO.spendPermit(OP_CALL, VAULT, 0, payload, nonce);
        require(ok);
    }

    /**
     * SELF-PROPOSING
     *
     * @dev Two gates stand between this contract and opening its own proposal, and both
     * must be granted once by hand:
     *
     *   1. `openProposal` requires `getVotes(msg.sender) >= proposalThreshold` (10,000
     *      shares today). Shares are transferable, so anyone may send them here; the
     *      contract then has to `selfDelegate()`, since votes follow delegation, not
     *      balance.
     *   2. `chat` requires a Badge, which is soulbound and DAO-minted — it cannot be
     *      transferred in. Governance must pass `mintSeat(address(this), seat)` once.
     *
     * After that this contract can write its own proposals, including the tagged message
     * the dapps parse, and seed them with its own vote. Passage still needs real voters:
     * quorum and majority are unchanged by who authored the proposal.
     */

    /// @notice Point this contract's own share voting power at itself. Anyone may call;
    /// the delegate is hardcoded, so there is nothing to steer.
    function selfDelegate() external {
        IShares(DAO.shares()).delegate(address(this));
    }

    /// @notice Propose that the DAO grant this contract `count` fee-claim permits.
    function proposeClaimPermit(uint256 count) external returns (uint256 id) {
        return _proposePermit(
            claimPayload(),
            CLAIM_NONCE,
            count,
            string.concat(
                "Grant ",
                LibString.toString(count),
                " FWAcore fee-claim permit(s) to FWCKeeper. Each use sweeps pass #",
                LibString.toString(CLAIM_ID),
                " fees into the vault. Proceeds are paid to the vault regardless of caller."
            )
        );
    }

    /// @notice Propose that the DAO grant this contract `count` remint permits.
    function proposeRemintPermit(uint256 count) external returns (uint256 id) {
        return _proposePermit(
            remintPayload(),
            REMINT_NONCE,
            count,
            string.concat(
                "Grant ",
                LibString.toString(count),
                " remint permit(s) to FWCKeeper. Each use spends exactly 1 ETH of vault"
                " funds on another TokenWorks pass, which is held by the vault."
            )
        );
    }

    /// @dev Posts the tagged message first so the parameters are readable before the vote
    /// exists, then opens the proposal by voting for it.
    function _proposePermit(bytes memory payload, bytes32 permitNonce, uint256 count, string memory description)
        internal
        returns (uint256 id)
    {
        if (stopped) revert Stopped();
        // Each call writes a message and opens a proposal, so leaving it open to anyone
        // is an unbounded spam channel into the DAO's chatroom. Members only.
        if (IBadges(DAO.badges()).balanceOf(msg.sender) == 0 && msg.sender != GUARDIAN) revert NotMember();
        uint256 seq = ++proposalCount;
        bytes memory data;
        bytes32 proposalNonce;
        (id, proposalNonce, data) = _buildProposal(payload, permitNonce, count, seq);

        DAO.chat(_proposalMessage(data, proposalNonce, description));
        DAO.castVote(id, 1); // auto-opens the proposal, then votes FOR with our own weight
        emit Proposed(msg.sender, id);
    }

    /// @dev Everything about a proposal from this contract is derived, not chosen: the
    /// calldata from the payload, the nonce from a sequence number, the id from both. The
    /// same inputs always produce the same proposal, and `previewClaimProposal` /
    /// `previewRemintProposal` return exactly what the next call will create.
    function _buildProposal(bytes memory payload, bytes32 permitNonce, uint256 count, uint256 seq)
        internal
        view
        returns (uint256 id, bytes32 proposalNonce, bytes memory data)
    {
        data = abi.encodeWithSignature(
            "setPermit(uint8,address,uint256,bytes,bytes32,address,uint256)",
            OP_CALL,
            VAULT,
            uint256(0),
            payload,
            permitNonce,
            address(this),
            count
        );
        proposalNonce = keccak256(abi.encode(address(this), permitNonce, count, seq));
        id = uint256(
            keccak256(
                abi.encode(
                    address(DAO), OP_CALL, address(DAO), uint256(0), keccak256(data), proposalNonce, DAO.config()
                )
            )
        );
    }

    /// @notice What `proposeClaimPermit(count)` would create if called now. Lets a caller
    /// check the id and calldata before sending, and lets anyone verify afterwards.
    function previewClaimProposal(uint256 count)
        external
        view
        returns (uint256 id, bytes32 proposalNonce, bytes memory data)
    {
        return _buildProposal(claimPayload(), CLAIM_NONCE, count, proposalCount + 1);
    }

    /// @notice What `proposeRemintPermit(count)` would create if called now.
    function previewRemintProposal(uint256 count)
        external
        view
        returns (uint256 id, bytes32 proposalNonce, bytes memory data)
    {
        return _buildProposal(remintPayload(), REMINT_NONCE, count, proposalCount + 1);
    }

    /// @dev The exact envelope the zFi dapps look for. They match
    /// /<<<PROPOSAL_DATA\n([\s\S]*?)\nPROPOSAL_DATA>>>/ and JSON.parse the middle, then
    /// re-hash the fields to check the message against the on-chain proposal id — so
    /// these values have to be the ones actually proposed, not a description of them.
    function _proposalMessage(bytes memory data, bytes32 proposalNonce, string memory description)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "<<<PROPOSAL_DATA\n{\n",
            '  "type": "PROPOSAL",\n',
            '  "op": 0,\n',
            '  "to": "',
            LibString.toHexStringChecksummed(address(DAO)),
            '",\n  "value": "0",\n',
            '  "data": "',
            LibString.toHexString(data),
            '",\n  "nonce": "',
            LibString.toHexString(uint256(proposalNonce), 32),
            '",\n  "description": "',
            description,
            '"\n}\nPROPOSAL_DATA>>>'
        );
    }

    /**
     * GUARDIAN
     */

    /// @notice Send anything this contract holds back to the guardian. Guardian only.
    /// @param token ERC20 to sweep, or address(0) for ETH.
    /// @dev Without this the shares delegated here for proposal rights would be burnt:
    /// nothing else in this contract can move a token or a wei. The destination is fixed
    /// to the guardian, so there is no recipient argument to point somewhere else.
    ///
    /// Note this is the one power the guardian has beyond switching the contract off. It
    /// reaches only what sits at this address — the voting shares someone funded it with —
    /// and never the vault, the treasury, or anything a permit touches.
    function reclaim(address token) external {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        if (token == address(0)) {
            uint256 bal = address(this).balance;
            (bool sent,) = GUARDIAN.call{value: bal}("");
            if (!sent) revert RescueFailed();
            emit Reclaimed(token, bal);
            return;
        }
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSignature("balanceOf(address)", address(this)));
        if (!ok || ret.length < 32) revert RescueFailed();
        uint256 amount = abi.decode(ret, (uint256));
        (ok, ret) = token.call(abi.encodeWithSignature("transfer(address,uint256)", GUARDIAN, amount));
        // Tolerate non-standard tokens that return nothing on success.
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert RescueFailed();
        emit Reclaimed(token, amount);
    }

    /// @dev Accept ETH so a stray send can be reclaimed rather than stranded. Nothing here
    /// spends it: the vault pays for remints out of its own balance.
    receive() external payable {}

    /// @notice Switch this contract off, or back on. Guardian only.
    /// @dev The guardian cannot make this contract do anything — there is no path from
    /// here to a call of the guardian's choosing. It can only take away what the DAO
    /// granted, which is why handing it out is cheap.
    function setStopped(bool value) external {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        stopped = value;
        emit StopSet(value);
    }

    /**
     * VIEWS — for keepers deciding whether a call is worth the gas
     */

    /// @dev True once this contract holds enough delegated voting power to open a proposal.
    function canPropose() external view returns (bool) {
        return IShares(DAO.shares()).getVotes(address(this)) >= DAO.proposalThreshold();
    }

    /// @dev True once the DAO has minted this contract a badge seat, without which
    /// `chat()` reverts and no proposal message can be posted.
    function canChat() external view returns (bool) {
        return IBadges(DAO.badges()).balanceOf(address(this)) != 0;
    }

    /// @dev Unclaimed FWAcore fees on the pass this contract can claim for.
    function pendingFees() public view returns (uint256) {
        return IFeeSplitter(FEES).pending(CLAIM_ID);
    }

    /// @dev Lifetime fees the pass has produced, claimed and unclaimed.
    function lifetimeFees() external view returns (uint256) {
        return IFeeSplitter(FEES).claimed(CLAIM_ID) + IFeeSplitter(FEES).pending(CLAIM_ID);
    }

    /// @dev True when a `claimFees()` call would currently succeed.
    function canClaim() external view returns (bool) {
        return !stopped && pendingFees() != 0 && remainingClaims() != 0;
    }

    /// @dev True when a `remint()` call would currently succeed.
    function canRemint() external view returns (bool) {
        return !stopped && VAULT.balance >= PASS_PRICE && remainingRemints() != 0;
    }

    /// @dev ETH still needed in the vault before another pass can be bought.
    function untilNextPass() external view returns (uint256) {
        uint256 bal = VAULT.balance;
        return bal >= PASS_PRICE ? 0 : PASS_PRICE - bal;
    }

    function remainingClaims() public view returns (uint256) {
        return DAO.balanceOf(address(this), claimPermitId());
    }

    function remainingRemints() public view returns (uint256) {
        return DAO.balanceOf(address(this), remintPermitId());
    }

    /// @dev The permit ids governance must mint to this address. These move with the DAO's
    /// `config`, so after an emergency bump they report the ids that need re-granting.
    function claimPermitId() public view returns (uint256) {
        return _permitId(claimPayload(), CLAIM_NONCE);
    }

    function remintPermitId() public view returns (uint256) {
        return _permitId(remintPayload(), REMINT_NONCE);
    }

    function _permitId(bytes memory payload, bytes32 nonce) internal view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(address(DAO), OP_CALL, VAULT, uint256(0), keccak256(payload), nonce, DAO.config())
            )
        );
    }
}
