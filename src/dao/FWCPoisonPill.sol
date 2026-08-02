// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibString} from "../../lib/solady/src/utils/LibString.sol";

interface IMoloch {
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
}

interface IBadges {
    function balanceOf(address owner) external view returns (uint256);
}

/// @dev The FWC collector DAO's vault (`FundingWorksMinter`). Every entry point used
/// here is `onlyDAO`, which is why the pill must run in the DAO's own context.
interface IVault {
    function burnToDAO(uint256 tokenId) external;
    function sweep() external;
}

/// @dev TokenWorks S02 (`FundingWorks`). `burn` is the fund's ragequit: it pays the
/// holder the token's *remaining locked* ETH — a partial refund that shrinks to zero
/// as the vesting period elapses — and only works inside the vesting window.
interface IFundingWorks {
    function ownerOf(uint256 tokenId) external view returns (address);
    function burn(uint256 tokenId) external;
    function getRemainingLockedEth(uint256 tokenId) external view returns (uint256);
    function getCurrentSupply() external view returns (uint256);
    function burnedTokenCount() external view returns (uint256);
    function vestingStarted() external view returns (bool);
    function vestingStartTime() external view returns (uint256);
    function VESTING_PERIOD() external view returns (uint256);
}

/**
 * @title FWCPoisonPill
 * @notice The one-time delegatecall body of the guardian's poison pill: redeem every FW
 *         NFT the collector vault still holds, then sweep the vault dry into the DAO
 *         treasury.
 *
 * @dev This contract is never called directly. It is the `to` of a Moloch permit minted
 *      with `op = 1`, so `spendPermit` reaches it through `delegatecall` and every
 *      instruction below runs *as the DAO*: `address(this)` is the Moloch, and the
 *      vault's `onlyDAO` gate sees `msg.sender == dao`.
 *
 *      Nothing here is a parameter. `pull()` takes no arguments, which is the whole point:
 *      the permit id commits to the exact calldata, so a payload carrying a token list or
 *      an ETH amount would freeze those values at proposal time. Instead the pill reads
 *      the world when it runs — which ids the vault owns, and what balance is left after
 *      the burns — so the amount that moves is whatever is actually there on the day the
 *      guardian pulls it, not a number written into a vote weeks earlier.
 *
 *      HOLDS NO STATE. Under `delegatecall` a storage write here would land in the
 *      Moloch's storage and corrupt the DAO. There are no state variables, only
 *      constants and immutables, both of which live in code rather than storage.
 *
 *      Recovered ETH never touches this contract or the guardian: `burnToDAO` forwards
 *      each refund to the DAO, and `sweep()` sends the vault's balance to the DAO. The
 *      guardian's power is limited to choosing the moment.
 *
 *      DEGRADES, NEVER BRICKS. A redemption the fund refuses is skipped rather than
 *      fatal, so a pull outside S02's vesting window still sweeps instead of reverting
 *      and leaving a permit that can never act. A pull that would move nothing at all
 *      reverts, and since that rolls the permit burn back with it, a mistimed pull costs
 *      gas rather than the guardian's single use.
 */
contract FWCPoisonPill {
    IMoloch public constant DAO = IMoloch(0xE7Aa6cA3a9Ca3fe92a425dFeaD24900B9BF49853);
    IVault public constant VAULT = IVault(0xB3B3f4f1535305c5f40F9c0d6bCaf38032bF7F8e);
    IFundingWorks public constant FW = IFundingWorks(0xb33d806a94B6770C9d309E0842a75f8E6edCd5A6);

    /// @dev Set at construction to this contract's own address, so a direct call — where
    /// `address(this)` is the pill — is distinguishable from a delegatecall, where it is
    /// the caller's. A direct call could not pass the vault's `onlyDAO` gate anyway; this
    /// just makes the failure legible instead of a bare revert from somewhere downstream.
    address internal immutable _SELF;

    error NotDelegated();
    error WrongContext();
    error NothingToPull();

    event PillPulled(uint256 burned, uint256 skipped, uint256 swept, uint256 recovered);

    constructor() {
        _SELF = address(this);
    }

    /// @notice Redeem every FW NFT the vault holds, then sweep all vault ETH to the DAO.
    /// @dev Reached only through `DAO.spendPermit(1, pill, 0, pull(), nonce)`.
    /// @return burned Passes redeemed for their unvested remainder.
    /// @return skipped Passes the fund refused to redeem this block (see `_tryBurn`).
    /// @return swept Vault ETH moved to the treasury, burns included.
    /// @return recovered Net increase in the treasury's balance.
    function pull() external returns (uint256 burned, uint256 skipped, uint256 swept, uint256 recovered) {
        if (address(this) == _SELF) revert NotDelegated();
        if (address(this) != address(DAO)) revert WrongContext();

        uint256 before = address(this).balance; // the DAO treasury, since we are the DAO

        uint256 top = scanCeiling();
        for (uint256 id = 1; id <= top; ++id) {
            if (_ownedByVault(id)) {
                if (_tryBurn(id)) ++burned;
                else ++skipped;
            }
        }

        // The vault's idle ETH — not the redemption proceeds, which `burnToDAO` already
        // forwarded to the treasury one by one. Read at execution time; the permit never
        // names an amount, and `sweep()` sizes the transfer from this same balance.
        swept = address(VAULT).balance;
        if (swept != 0) VAULT.sweep();

        recovered = address(this).balance - before;
        // A pull that moved nothing would burn the guardian's single use for no effect.
        // Reverting rolls the permit burn back with it, so the one shot is still there.
        if (recovered == 0) revert NothingToPull();

        emit PillPulled(burned, skipped, swept, recovered);
    }

    /// @dev A redemption that fails is skipped, not fatal. The fund refuses `burn`
    /// outside its vesting window and its owner-share payout can revert on its own
    /// accounting — and a single such id, reverting mid-loop, would otherwise take the
    /// sweep down with it and leave the guardian holding a permit that can never do
    /// anything. Tolerating the failure keeps the sweep reachable in every state the
    /// fund can be in, and `recovered == 0` above still rejects a pull that achieved
    /// nothing at all.
    function _tryBurn(uint256 id) internal returns (bool) {
        (bool ok,) = address(VAULT).call(abi.encodeWithSelector(IVault.burnToDAO.selector, id));
        return ok;
    }

    /// @dev `ownerOf` reverts on a burnt id, so this tolerates failure instead of
    /// aborting the whole pull on the first gap in the id space.
    function _ownedByVault(uint256 id) internal view returns (bool) {
        (bool ok, bytes memory ret) = address(FW).staticcall(abi.encodeWithSelector(IFundingWorks.ownerOf.selector, id));
        return ok && ret.length >= 32 && abi.decode(ret, (address)) == address(VAULT);
    }

    /// @notice The highest FW id that can exist, and so the exact end of the scan.
    /// @dev Not an estimate. The fund defines `getCurrentSupply() == currentTokenId - 1 -
    /// burnedTokenCount`, so this sum is `currentTokenId - 1`: every id ever minted,
    /// including burnt ones and remints.
    ///
    /// Ownership is then discovered by scanning this range against the fund itself, never
    /// read from the vault's `nftIds`. That bookkeeping is incomplete by construction: it
    /// is written only by the vault's `_mint`, the primary-mint path, which closed when
    /// the mint period ended. The live strategy acquires passes through
    /// `execute(FW, 1 ether, remint())`, a generic call that mints straight to the vault
    /// and never records the id. Today `allNftIds()` returns `[156]` while the vault owns
    /// three passes; the two remints are invisible to it. `burnToDAO` gates on `ownerOf`
    /// rather than the index, so it redeems them fine — the index is the only thing that
    /// is wrong, which is exactly why nothing here consults it.
    function scanCeiling() public view returns (uint256) {
        return FW.getCurrentSupply() + FW.burnedTokenCount();
    }

    /**
     * VIEWS — what a pull would do right now. Safe to call directly.
     */

    /// @notice The ids the pill would redeem, and the ETH a pull would move, in this
    /// block: every held pass' unvested remainder plus the vault's idle balance.
    /// @dev One scan serves both answers. `heldIds()` and `recoverable()` wrap it, but
    /// anything that wants both — the proposal description especially — should call this
    /// once rather than pay for the scan twice.
    function quote() public view returns (uint256[] memory ids, uint256 total) {
        uint256 top = scanCeiling();
        uint256[] memory buf = new uint256[](top);
        uint256 n;
        for (uint256 id = 1; id <= top; ++id) {
            if (_ownedByVault(id)) buf[n++] = id;
        }
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = buf[i];
            // Safe unguarded: the id was just confirmed to exist by `ownerOf`.
            total += FW.getRemainingLockedEth(ids[i]);
        }
        total += address(VAULT).balance;
    }

    /// @notice The ids the pill would redeem if pulled in this block.
    function heldIds() public view returns (uint256[] memory ids) {
        (ids,) = quote();
    }

    /// @notice ETH a pull would move into the treasury in this block.
    function recoverable() public view returns (uint256 total) {
        (, total) = quote();
    }

    /// @notice Whether the fund will honour a redemption right now.
    /// @dev `burn` works only after vesting starts and before the period ends. Outside
    /// that window every redemption is skipped and a pull degrades to the sweep alone —
    /// which is why the guardian should check this before spending its single use.
    function burnWindowOpen() public view returns (bool) {
        if (!FW.vestingStarted()) return false;
        return block.timestamp < FW.vestingStartTime() + FW.VESTING_PERIOD();
    }

    /// @notice Seconds until the fund's vesting period ends and `burn` stops refunding.
    /// @dev The refund decays linearly to zero across the window, so this is the pill's
    /// shelf life. Zero means the window is shut — or has not opened yet, which
    /// `burnWindowOpen()` distinguishes.
    function pullWindowRemaining() public view returns (uint256) {
        if (!burnWindowOpen()) return 0;
        return FW.vestingStartTime() + FW.VESTING_PERIOD() - block.timestamp;
    }
}

/**
 * @title FWCPoisonPillProposer
 * @notice Writes the one proposal that arms the poison pill: grant the guardian a single
 *         permit to run `FWCPoisonPill.pull()` as the DAO.
 *
 * @dev Deterministic by construction. The pill is deployed by this contract's
 *      constructor, so both addresses are fixed the moment this contract exists; the
 *      permit payload, the permit id, the proposal nonce and the proposal id all follow
 *      from constants. `previewProposal()` returns exactly what `propose()` will create,
 *      and the message posted to the chatroom carries the same bytes the dapps re-hash
 *      against the on-chain proposal id — so a voter can check the proposal without
 *      trusting this description of it.
 *
 *      WHAT THE PERMIT IS. `setPermit(1, pill, 0, pull(), nonce, GUARDIAN, 1)`:
 *        - op 1        — delegatecall, the only way the pill can act with the DAO's
 *                        authority over its own vault.
 *        - spender     — the src_co multisig, and only it: `spendPermit` burns from
 *                        `msg.sender`, so nobody else can spend this.
 *        - count 1     — one use, then the balance is zero and the pill is spent.
 *
 *      WHY IT EXISTS. A collector vault whose portfolio can be sold down continuously by
 *      a majority leaves a minority with no exit and no recourse. This permit is that
 *      recourse: a standing, pre-approved liquidation that converts the remaining
 *      collection back into treasury ETH — pro-rata to every holder — the moment a
 *      takeover or a continuous-sale squeeze makes holding worse than exiting. It is
 *      meant not to be used. Its value is that it can be.
 *
 *      WHAT IT CANNOT DO. The guardian picks the timing and nothing else. There is no
 *      recipient argument, no amount argument, and no id list: every wei recovered lands
 *      in the DAO treasury, where it is subject to the DAO's ordinary rules. Governance
 *      keeps the deeper controls — `setPermit(..., 0)` burns the permit outright and
 *      `bumpConfig()` invalidates every permit at once — so the DAO can disarm this at
 *      any time by the same majority that granted it.
 */
contract FWCPoisonPillProposer {
    IMoloch public constant DAO = IMoloch(0xE7Aa6cA3a9Ca3fe92a425dFeaD24900B9BF49853);
    address public constant VAULT = 0xB3B3f4f1535305c5f40F9c0d6bCaf38032bF7F8e;

    /// @dev src_co multisig — the permit's only possible spender.
    address public constant GUARDIAN = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;

    /// @dev Vault call opcodes: 0 = CALL (how the proposal reaches `setPermit` on the
    /// DAO), 1 = DELEGATECALL (how the granted permit reaches the pill).
    uint8 internal constant OP_CALL = 0;
    uint8 internal constant OP_DELEGATECALL = 1;

    /// @dev Governance must use this exact nonce or the permit id will not match.
    bytes32 public constant PILL_NONCE = keccak256("FWC_GUARDIAN_POISON_PILL");

    /// @dev One use. A poison pill that can be swallowed twice is a spending program.
    uint256 public constant PERMIT_COUNT = 1;

    /// @notice The delegatecall body this proposal grants a permit for.
    FWCPoisonPill public immutable PILL;

    /// @dev Bumped per proposal so a re-run after a defeat is a new proposal rather than
    /// a collision with the old one.
    uint256 public proposalCount;

    event Proposed(address indexed caller, uint256 indexed id);
    event Reclaimed(address indexed token, uint256 amount);

    error NotMember();
    error NotGuardian();
    error RescueFailed();

    constructor() {
        PILL = new FWCPoisonPill();
    }

    /**
     * PAYLOAD
     */

    /// @notice The calldata the permit authorises: `pull()`, no arguments.
    function pullPayload() public pure returns (bytes memory) {
        return abi.encodeWithSelector(FWCPoisonPill.pull.selector);
    }

    /// @notice The `setPermit` calldata the DAO would execute if the proposal passes.
    function permitData() public view returns (bytes memory) {
        return abi.encodeWithSignature(
            "setPermit(uint8,address,uint256,bytes,bytes32,address,uint256)",
            OP_DELEGATECALL,
            address(PILL),
            uint256(0),
            pullPayload(),
            PILL_NONCE,
            GUARDIAN,
            PERMIT_COUNT
        );
    }

    /**
     * PROPOSING
     *
     * @dev Two gates, both granted by hand once, exactly as for FWCKeeper: this contract
     * needs delegated shares above `proposalThreshold` to open a proposal, and a badge
     * seat to post the tagged message. Sending it 10,000 FWC shares seats it
     * automatically via `Badges.onSharesChanged`; then call `selfDelegate()`.
     */

    /// @notice Point this contract's own voting power at itself. The delegate is
    /// hardcoded, so there is nothing for a caller to steer.
    function selfDelegate() external {
        IShares(DAO.shares()).delegate(address(this));
    }

    /// @notice Open the proposal granting the guardian the one-time pill permit.
    /// @dev Members and the guardian only — each call writes to the DAO chatroom, which
    /// would otherwise be an unbounded spam channel.
    function propose() external returns (uint256 id) {
        if (IBadges(DAO.badges()).balanceOf(msg.sender) == 0 && msg.sender != GUARDIAN) revert NotMember();

        uint256 seq = ++proposalCount;
        bytes memory data;
        bytes32 proposalNonce;
        (id, proposalNonce, data) = _build(seq);

        DAO.chat(_proposalMessage(data, proposalNonce, _description()));
        DAO.castVote(id, 1); // auto-opens the proposal, then votes FOR with our own weight
        emit Proposed(msg.sender, id);
    }

    /// @notice What `propose()` would create if called now — id, nonce and calldata.
    function previewProposal() external view returns (uint256 id, bytes32 proposalNonce, bytes memory data) {
        return _build(proposalCount + 1);
    }

    function _build(uint256 seq) internal view returns (uint256 id, bytes32 proposalNonce, bytes memory data) {
        data = permitData();
        proposalNonce = keccak256(abi.encode(address(this), PILL_NONCE, PERMIT_COUNT, seq));
        id = uint256(
            keccak256(
                abi.encode(
                    address(DAO), OP_CALL, address(DAO), uint256(0), keccak256(data), proposalNonce, DAO.config()
                )
            )
        );
    }

    /// @dev Written from live state so voters read the real numbers, not stale ones: how
    /// many passes the vault still holds, what a pull would return today, and how long
    /// the fund's refund window stays open.
    function _description() internal view returns (string memory) {
        (uint256[] memory ids, uint256 total) = PILL.quote();
        return string.concat(
            "GUARDIAN POISON PILL. Grant the src_co guardian multisig ONE non-transferable,"
            " single-use permit (op 1 / delegatecall) to run FWCPoisonPill.pull() at ",
            LibString.toHexStringChecksummed(address(PILL)),
            ". One pull redeems every FW NFT the collector vault holds (",
            LibString.toString(ids.length),
            " today) back to TokenWorks S02 for its unvested partial refund, then sweeps"
            " the vault's entire ETH balance into this DAO's treasury. Amounts are read at"
            " execution time, not fixed here: ~",
            LibString.toString(total / 1e15),
            " milliETH recoverable today, decaying to the vault balance alone once the S02"
            " vesting window closes. The guardian chooses only the moment. It cannot name a"
            " recipient, an amount, or a token: all proceeds land in the treasury pro-rata"
            " to every holder. Purpose: liquidate the collection for the benefit of all"
            " holders, and protect minority exit rights against continuous-sale"
            " manipulation or takeover of the vault portfolio. Revocable by this DAO at any"
            " time via setPermit(count 0) or bumpConfig()."
        );
    }

    /// @dev The exact envelope the zFi dapps parse: they match
    /// /<<<PROPOSAL_DATA\n([\s\S]*?)\nPROPOSAL_DATA>>>/, JSON.parse the middle, and
    /// re-hash the fields against the on-chain proposal id.
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

    /// @notice Return whatever this contract holds to the guardian. Guardian only.
    /// @dev Without this the shares delegated here for proposal rights would be burnt —
    /// nothing else in this contract can move a token or a wei. The destination is fixed,
    /// so there is no recipient argument to point elsewhere, and it reaches only what sits
    /// at this address: never the vault, the treasury, or anything the permit touches.
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

    /// @dev Accept ETH so a stray send can be reclaimed rather than stranded.
    receive() external payable {}

    /**
     * VIEWS
     */

    /// @dev The permit id governance mints to the guardian. It moves with the DAO's
    /// `config`, so after an emergency bump this reports the id that needs re-granting.
    function permitId() public view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    address(DAO),
                    OP_DELEGATECALL,
                    address(PILL),
                    uint256(0),
                    keccak256(pullPayload()),
                    PILL_NONCE,
                    DAO.config()
                )
            )
        );
    }

    /// @dev Uses left on the guardian's permit: 1 once granted, 0 before and after.
    function armed() external view returns (bool) {
        return DAO.balanceOf(GUARDIAN, permitId()) != 0;
    }

    function canPropose() external view returns (bool) {
        return IShares(DAO.shares()).getVotes(address(this)) >= DAO.proposalThreshold();
    }

    function canChat() external view returns (bool) {
        return IBadges(DAO.badges()).balanceOf(address(this)) != 0;
    }
}
