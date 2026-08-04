// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {ERC721} from "../../lib/solady/src/tokens/ERC721.sol";
import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";
import {IZorgConvictionRenderer} from "./IZorgConvictionRenderer.sol";
import {IZorgReceiptArt} from "./IZorgReceiptArt.sol";

interface IERC721Zorgz {
    function ownerOf(uint256 id) external view returns (address);
    function tokenURI(uint256 id) external view returns (string memory);
    function safeTransferFrom(address from, address to, uint256 id) external;
}

interface ITokenListView {
    function isListed(uint256 id) external view returns (bool);
}

interface IWeiNames {
    function ownerOf(uint256 id) external view returns (address);
    function getFullName(uint256 tokenId) external view returns (string memory);
    function computeId(string calldata fullName) external pure returns (uint256);
    function setAddr(uint256 tokenId, address addr) external;
    function setPrimaryName(uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 id) external;
    function registerSubdomainFor(string calldata label, uint256 parentId, address to) external returns (uint256);
}

/// @title ZorgConviction
/// @notice Transferable zOrgz receipts that direct explicit, escrowed zOrg
///         share bonds to existing TokenList listings.
/// @dev A receipt uses the same id as its escrowed zOrgz. Bonding pulls that
///      zOrgz and an explicit amount of zOrg shares into this governor. The
///      receipt is the sole allocation authority, so moving it moves its bond,
///      live support, and withdrawal right: snapshot weight cannot be reused.
contract ZorgConviction is ERC721 {
    using SafeTransferLib for address;

    error Unauthorized();
    error BadInput();
    error DomainAlreadyClaimed();
    error NotZorgWei();
    error DomainNotClaimed();
    error ExecRoleAlreadyInstalled();
    error Reentrancy();
    error UnknownListing();
    error BondAlreadyExists();
    error AllocationExceeded();
    error BondHasActiveAllocations();
    error UnsupportedZorgzTransfer();
    error ProtectedAsset();
    error EscrowReduced();
    error SharesLocked();
    error ExecRoleRevoked();
    error LockTierUnavailable();
    error LockTierOutOfRange();
    error ReceiptLocked(uint64 unlockAt);
    error EthBondTooSmall(uint256 provided, uint256 minimum);
    error EthTermsOutOfRange();
    error NoEthCredit();
    error EthTransferFailed();
    error EthEscrowReduced();
    error PermanentBond();

    string public constant DOMAIN = "zorg.wei";
    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_BOOST_BPS = 15_000;
    uint8 public constant MAX_LOCK_TIER = 3;
    uint64 public constant MAX_EXIT_DELAY = 365 days;
    uint64 public constant MAX_ETH_MATURITY = 365 days;
    uint256 public constant ETERNAL_MIN_ZORG = 10_000 ether;
    uint256 internal constant REWARD_SCALE = 1e27;

    address public immutable shares;
    IERC721Zorgz public immutable zorgz;
    IWeiNames public immutable weiNames;
    address public immutable dao;
    address public immutable tokenList;
    uint256 public immutable zorgWeiId;
    uint256 public immutable execZorgWeiId;

    IZorgConvictionRenderer public renderer;
    IZorgReceiptArt public receiptArt;
    uint64 public halfLife;

    bool public domainClaimed;
    bool public rolesInstalled;
    /// @notice One-way. The exec credential is a transferable name, so the DAO
    ///         needs a way to retire it that does not depend on holding it.
    bool public execRoleRevoked;
    bool public paused;
    bool internal _executing;
    /// @dev Receipt id this contract is mid-escrow of, stored as `id + 1` so
    ///      that zero means "expecting nothing" and id 0 stays bondable. A flag
    ///      would admit any qualifying token for the whole call; naming the id
    ///      keeps the gate exact if a later change adds a second ERC721 hop.
    uint256 internal _expectedZorgzId;

    /// @notice Escrowed zOrg shares bonded to a receipt / underlying zOrgz id.
    mapping(uint256 receiptId => uint256 weight) public bondedWeight;
    /// @notice Total weight allocated by a receipt across current listings.
    mapping(uint256 receiptId => uint256 weight) public allocatedByBond;
    /// @notice A receipt's selected allocation for one existing listing.
    mapping(uint256 receiptId => mapping(uint256 listingId => uint256 weight)) public allocationOf;

    /// @notice DAO-configured terms offered to new bonds. Existing bonds copy
    ///         their terms, so a later DAO change cannot rewrite a holder's
    ///         exit right or support boost.
    struct LockTier {
        uint64 exitDelay;
        uint16 boostBps;
    }
    mapping(uint8 tier => LockTier terms) public lockTiers;

    /// @notice Terms carried by a transferable receipt. `unlockAt` is the end
    ///         of a hard commitment selected at bond time, never a holder-set
    ///         cooldown. Tier zero leaves it at zero.
    struct ReceiptLock {
        uint64 exitDelay;
        uint64 unlockAt;
        uint16 boostBps;
        uint8 tier;
    }
    mapping(uint256 receiptId => ReceiptLock terms) public receiptLocks;
    mapping(uint256 receiptId => bool isEternal) public eternalBonds;

    /// @notice Terms quoted to newly created zOrgz bonds. Moloch may change
    ///         future terms, but every live receipt keeps its original quote.
    struct EthBondTerms {
        uint256 minimumBond;
        uint64 maturity;
        uint16 earlyExitTaxBps;
        uint16 treasuryShareBps;
    }
    EthBondTerms public ethBondTerms;

    /// @notice ETH principal and loyalty accounting that travel with a receipt.
    ///         `rewardIndex` prevents new zOrg shares from claiming old exits.
    struct EthBond {
        uint256 principal;
        uint256 accruedLoyalty;
        uint256 rewardIndex;
        uint64 bondedAt;
        uint64 maturityAt;
        uint64 maturity;
        uint16 earlyExitTaxBps;
        uint16 treasuryShareBps;
    }
    mapping(uint256 receiptId => EthBond bond) public ethBonds;

    /// @notice ETH rewards never affect allocation capacity or conviction.
    ///         They are solely a retention dividend paid from early exits.
    uint256 public totalLoyaltyWeight;
    uint256 public loyaltyRewardPerWeight;
    uint256 public loyaltyRewardReserve;
    uint256 public totalEthPrincipal;
    uint256 public treasuryEth;
    uint256 public totalEthCredits;
    mapping(address account => uint256 amount) public ethCredits;

    /// @notice Aggregate support behind one existing TokenList id.
    struct ListingSupport {
        uint64 lastUpdated;
        uint256 conviction;
        uint256 weight;
    }
    mapping(uint256 listingId => ListingSupport) internal _listingSupport;

    event DomainClaimed(uint256 indexed tokenId, address indexed from, address indexed dao);
    event ExecRoleInstalled(uint256 indexed execTokenId, address indexed execHolder);
    event Bonded(address indexed owner, uint256 indexed receiptId, uint256 weight);
    event BondIncreased(address indexed owner, uint256 indexed receiptId, uint256 amount, uint256 totalWeight);
    event Unbonded(address indexed owner, uint256 indexed receiptId, uint256 weight);
    event Allocated(
        uint256 indexed listingId,
        uint256 indexed receiptId,
        address indexed receiptOwner,
        uint256 amount,
        uint256 available
    );
    event PauseSet(bool paused, address indexed by);
    event Executed(address indexed target, uint256 value, bytes data, address indexed by, bool emergency);
    event BondDecreased(address indexed owner, uint256 indexed receiptId, uint256 amount, uint256 totalWeight);
    event ExecRoleBurned();
    event HalfLifeSet(uint64 halfLife);
    event RendererSet(address indexed renderer);
    event ReceiptArtSet(address indexed receiptArt);
    event LockTierSet(uint8 indexed tier, uint64 exitDelay, uint16 boostBps);
    event BondLockSelected(
        address indexed owner, uint256 indexed receiptId, uint8 indexed tier, uint64 exitDelay, uint16 boostBps
    );
    event CommitmentExtended(uint256 indexed receiptId, uint64 unlockAt);
    event Eternalized(address indexed owner, uint256 indexed receiptId, uint256 permanentlyBondedZorg, uint256 ethToTreasury);
    event EthBondTermsSet(uint256 minimumBond, uint64 maturity, uint16 earlyExitTaxBps, uint16 treasuryShareBps);
    event EthBonded(address indexed owner, uint256 indexed receiptId, uint256 principal, uint64 maturityAt);
    event EthBondMaturityReset(uint256 indexed receiptId, uint64 maturityAt);
    event LoyaltyAccrued(uint256 indexed receiptId, uint256 amount);
    event EarlyExitTaxed(
        uint256 indexed receiptId, uint256 tax, uint256 toTreasury, uint256 toLoyalty, address indexed owner
    );
    event EthCreditClaimed(address indexed account, address indexed recipient, uint256 amount);
    event TreasuryEthReleased(address indexed recipient, uint256 amount);

    constructor(
        address dao_,
        address shares_,
        IERC721Zorgz zorgz_,
        IWeiNames weiNames_,
        address tokenList_,
        IZorgConvictionRenderer renderer_,
        IZorgReceiptArt receiptArt_,
        uint64 halfLife_
    ) {
        if (
            dao_ == address(0) || shares_.code.length == 0 || address(zorgz_) == address(0)
                || address(weiNames_) == address(0) || tokenList_ == address(0) || address(renderer_).code.length == 0
                || address(receiptArt_).code.length == 0 || halfLife_ == 0
        ) revert BadInput();
        // Moloch shares are lockable, and the lock permits transfers only when
        // one side is the DAO. This governor is neither, so a locked share token
        // makes `bondZorgz` impossible and — far worse if it is locked later —
        // makes `unbond` impossible for bonds that already exist. Refuse to
        // deploy against a token that is locked right now; the DAO locking it
        // afterwards is a documented trust assumption, not something a
        // constructor can prevent.
        (bool read, bytes memory locked) = shares_.staticcall(abi.encodeWithSignature("transfersLocked()"));
        if (read && locked.length == 32 && abi.decode(locked, (bool))) revert SharesLocked();
        dao = dao_;
        shares = shares_;
        zorgz = zorgz_;
        weiNames = weiNames_;
        tokenList = tokenList_;
        renderer = renderer_;
        receiptArt = receiptArt_;
        halfLife = halfLife_;
        zorgWeiId = weiNames_.computeId(DOMAIN);
        execZorgWeiId = weiNames_.computeId("exec.zorg.wei");

        // Conservative defaults; Moloch can revise the choices for future
        // receipts, but every receipt snapshots the terms it selected.
        lockTiers[1] = LockTier({exitDelay: 90 days, boostBps: 11_000});
        lockTiers[2] = LockTier({exitDelay: 180 days, boostBps: 12_500});
        lockTiers[3] = LockTier({exitDelay: 365 days, boostBps: 15_000});
        // ETH is a refundable loyalty bond, not voting power. A normal exit
        // after one week returns its full principal; an early exit funds both
        // Moloch's treasury and the other bonded zOrgz positions.
        ethBondTerms = EthBondTerms({
            minimumBond: 0.01 ether,
            maturity: 7 days,
            earlyExitTaxBps: 2_000,
            treasuryShareBps: 5_000
        });
    }

    modifier onlyDAO() {
        if (msg.sender != dao) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_executing) revert Reentrancy();
        _executing = true;
        _;
        _executing = false;
    }

    function name() public pure override returns (string memory) {
        return "zOrgz Bond";
    }

    function symbol() public pure override returns (string memory) {
        return "zORGZ";
    }

    /// @notice The receipt image is the inverse of its escrowed zOrgz SVG.
    /// @dev Held in a separate contract: the string building, SVG rewriting and
    ///      JSON scanning behind this are what put ZorgConviction over EIP-170,
    ///      and none of it touches escrow. Metadata failures only ever affect
    ///      the cosmetic fallback mask; they can never affect a receipt's
    ///      allocation or redemption rights.
    function tokenURI(uint256 receiptId) public view override returns (string memory) {
        ownerOf(receiptId);
        return receiptArt.tokenURI(address(this), receiptId);
    }

    function claimZorgWei() external {
        if (domainClaimed) revert DomainAlreadyClaimed();
        if (keccak256(bytes(weiNames.getFullName(zorgWeiId))) != keccak256(bytes(DOMAIN))) revert NotZorgWei();
        if (weiNames.ownerOf(zorgWeiId) != msg.sender) revert Unauthorized();
        weiNames.transferFrom(msg.sender, address(this), zorgWeiId);
        weiNames.setAddr(zorgWeiId, dao);
        weiNames.setPrimaryName(zorgWeiId);
        domainClaimed = true;
        emit DomainClaimed(zorgWeiId, msg.sender, dao);
    }

    function installExecRoleName(address execHolder) external onlyDAO {
        if (!domainClaimed) revert DomainNotClaimed();
        if (execHolder == address(0)) revert BadInput();
        if (rolesInstalled || execRoleRevoked) revert ExecRoleAlreadyInstalled();
        uint256 execId = weiNames.registerSubdomainFor("exec", zorgWeiId, execHolder);
        if (execId != execZorgWeiId) revert NotZorgWei();
        rolesInstalled = true;
        emit ExecRoleInstalled(execId, execHolder);
    }

    /// @notice Bond with no hard commitment or support boost.
    function bondZorgz(uint256 receiptId, uint256 weight) external payable whenNotPaused nonReentrant {
        _bondZorgz(receiptId, weight, 0);
    }

    /// @notice Bond an owned zOrgz and explicit zOrg share amount, minting a
    ///         transferable receipt with a DAO-configured exit-lock tier.
    /// @dev Both assets must first be approved to this governor. The selected
    ///      terms are copied onto the receipt and travel with every transfer.
    function bondZorgz(uint256 receiptId, uint256 weight, uint8 tier) external payable whenNotPaused nonReentrant {
        _bondZorgz(receiptId, weight, tier);
    }

    function _bondZorgz(uint256 receiptId, uint256 weight, uint8 tier) internal {
        if (weight == 0) revert BadInput();
        if (bondedWeight[receiptId] != 0) revert BondAlreadyExists();
        if (zorgz.ownerOf(receiptId) != msg.sender) revert Unauthorized();
        EthBondTerms memory ethTerms = ethBondTerms;
        if (msg.value < ethTerms.minimumBond) revert EthBondTooSmall(msg.value, ethTerms.minimumBond);
        LockTier memory selected = lockTiers[tier];
        if (tier == 0) {
            selected = LockTier({exitDelay: 0, boostBps: BPS});
        } else if (selected.exitDelay == 0 || selected.boostBps < BPS || selected.boostBps > MAX_BOOST_BPS) {
            revert LockTierUnavailable();
        }
        shares.safeTransferFrom(msg.sender, address(this), weight);
        bondedWeight[receiptId] = weight;
        totalLoyaltyWeight += weight;
        uint64 bondTime = uint64(block.timestamp);
        uint64 maturityAt = bondTime + ethTerms.maturity;
        ethBonds[receiptId] = EthBond({
            principal: msg.value,
            accruedLoyalty: 0,
            rewardIndex: loyaltyRewardPerWeight,
            bondedAt: bondTime,
            maturityAt: maturityAt,
            maturity: ethTerms.maturity,
            earlyExitTaxBps: ethTerms.earlyExitTaxBps,
            treasuryShareBps: ethTerms.treasuryShareBps
        });
        totalEthPrincipal += msg.value;
        uint64 lockedUntil = tier == 0 ? 0 : bondTime + selected.exitDelay;
        receiptLocks[receiptId] =
            ReceiptLock({exitDelay: selected.exitDelay, unlockAt: lockedUntil, boostBps: selected.boostBps, tier: tier});
        _expectedZorgzId = receiptId + 1;
        zorgz.safeTransferFrom(msg.sender, address(this), receiptId);
        _expectedZorgzId = 0;
        if (zorgz.ownerOf(receiptId) != address(this)) revert UnsupportedZorgzTransfer();
        _mint(msg.sender, receiptId);
        emit Bonded(msg.sender, receiptId, weight);
        emit EthBonded(msg.sender, receiptId, msg.value, maturityAt);
        emit BondLockSelected(msg.sender, receiptId, tier, selected.exitDelay, selected.boostBps);
        if (lockedUntil != 0) emit CommitmentExtended(receiptId, lockedUntil);
    }

    /// @notice Let a pre-existing no-lock receipt make a hard commitment before
    ///         it has any live allocation. The selected tier becomes active
    ///         immediately and is immutable on that receipt.
    function selectLockTier(uint256 receiptId, uint8 tier) external {
        if (ownerOf(receiptId) != msg.sender) revert Unauthorized();
        if (eternalBonds[receiptId]) revert PermanentBond();
        if (allocatedByBond[receiptId] != 0) revert BondHasActiveAllocations();
        ReceiptLock storage current = receiptLocks[receiptId];
        if (current.tier != 0 || current.unlockAt != 0) revert BadInput();
        LockTier memory selected = lockTiers[tier];
        if (tier == 0 || selected.exitDelay == 0 || selected.boostBps < BPS || selected.boostBps > MAX_BOOST_BPS) {
            revert LockTierUnavailable();
        }
        current.exitDelay = selected.exitDelay;
        current.boostBps = selected.boostBps;
        current.tier = tier;
        current.unlockAt = uint64(block.timestamp) + selected.exitDelay;
        emit BondLockSelected(msg.sender, receiptId, tier, selected.exitDelay, selected.boostBps);
        emit CommitmentExtended(receiptId, current.unlockAt);
    }

    /// @notice Add zOrg to a receipt without minting another custody NFT.
    /// @dev New shares receive the current reward index, so they can direct
    ///      TokenList support immediately but cannot claim loyalty ETH earned
    ///      before they arrived. The ETH maturity clock renews to make a
    ///      short-lived top-up a real commitment rather than a free harvest.
    function topUpZorg(uint256 receiptId, uint256 amount) external whenNotPaused nonReentrant {
        _increaseBond(receiptId, amount);
    }

    /// @notice Compatibility alias for the first bonded-receipt UI.
    function increaseBond(uint256 receiptId, uint256 amount) external whenNotPaused nonReentrant {
        _increaseBond(receiptId, amount);
    }

    function _increaseBond(uint256 receiptId, uint256 amount) internal {
        if (amount == 0) revert BadInput();
        if (ownerOf(receiptId) != msg.sender) revert Unauthorized();
        _settleLoyalty(receiptId);
        shares.safeTransferFrom(msg.sender, address(this), amount);
        uint256 total = bondedWeight[receiptId] + amount;
        bondedWeight[receiptId] = total;
        totalLoyaltyWeight += amount;
        EthBond storage ethBond = ethBonds[receiptId];
        uint64 maturityAt;
        if (!eternalBonds[receiptId]) {
            maturityAt = uint64(block.timestamp) + ethBond.maturity;
            ethBond.maturityAt = maturityAt;
        }
        ReceiptLock storage terms = receiptLocks[receiptId];
        if (terms.tier != 0 && !eternalBonds[receiptId]) {
            terms.unlockAt = uint64(block.timestamp) + terms.exitDelay;
            emit CommitmentExtended(receiptId, terms.unlockAt);
        }
        emit BondIncreased(msg.sender, receiptId, amount, total);
        if (maturityAt != 0) emit EthBondMaturityReset(receiptId, maturityAt);
    }

    /// @notice Withdraw part of a receipt's bond, down to what it has allocated.
    /// @dev `increaseBond` had no counterpart, so the only way to recover any
    ///      shares at all was to zero every allocation and exit completely. A
    ///      bond cannot be emptied here: a receipt with a zero bond would be a
    ///      live NFT that `bondZorgz` still reads as unbonded, so a full exit
    ///      stays `unbond`'s job, which burns the receipt with it.
    function decreaseBond(uint256 receiptId, uint256 amount) external nonReentrant {
        if (amount == 0) revert BadInput();
        if (ownerOf(receiptId) != msg.sender) revert Unauthorized();
        if (eternalBonds[receiptId]) revert PermanentBond();
        uint64 unlockAt = receiptLocks[receiptId].unlockAt;
        if (unlockAt != 0 && block.timestamp < unlockAt) revert ReceiptLocked(unlockAt);
        // Loyalty is shared by weight at the moment an early exit is taxed, and
        // `_increaseBond` renews this maturity precisely so a short-lived top-up
        // is a real commitment. Gating only on the lock tier left tier-0 receipts
        // able to withdraw a top-up in the very next call, which made every
        // pending early exit free money: front-run it with a large `topUpZorg`,
        // take almost the whole loyalty half of the tax, then `decreaseBond`
        // straight back out for the cost of gas. Honouring the maturity the
        // top-up already reset closes that without a new state variable.
        uint64 maturityAt = ethBonds[receiptId].maturityAt;
        if (maturityAt != 0 && block.timestamp < maturityAt) revert ReceiptLocked(maturityAt);
        _settleLoyalty(receiptId);
        uint256 total = bondedWeight[receiptId] - amount;
        if (total == 0) revert BadInput();
        if (total < allocatedByBond[receiptId]) revert AllocationExceeded();
        bondedWeight[receiptId] = total;
        totalLoyaltyWeight -= amount;
        _sweepEmptyLoyaltyReserve();
        shares.safeTransfer(msg.sender, amount);
        emit BondDecreased(msg.sender, receiptId, amount, total);
    }

    /// @notice Burn a receipt and return its exact shares plus its zOrgz.
    /// @dev Active allocations must first be set to zero. A lock-tier receipt
    ///      must complete its hard commitment set at bond time; an eternal
    ///      receipt is deliberately never redeemable. An approved operator can
    ///      transfer a receipt, but only its actual holder can redeem it.
    function unbond(uint256 receiptId) external nonReentrant {
        if (ownerOf(receiptId) != msg.sender) revert Unauthorized();
        if (eternalBonds[receiptId]) revert PermanentBond();
        if (allocatedByBond[receiptId] != 0) revert BondHasActiveAllocations();
        ReceiptLock memory terms = receiptLocks[receiptId];
        if (terms.unlockAt != 0 && block.timestamp < terms.unlockAt) revert ReceiptLocked(terms.unlockAt);
        uint256 weight = bondedWeight[receiptId];
        _settleLoyalty(receiptId);
        EthBond memory ethBond = ethBonds[receiptId];
        uint256 loyalty = ethBond.accruedLoyalty;
        uint256 principal = ethBond.principal;
        uint256 tax;
        if (block.timestamp < ethBond.maturityAt) {
            tax = FixedPointMathLib.fullMulDiv(principal, ethBond.earlyExitTaxBps, BPS);
            principal -= tax;
        }

        // The exiting receipt can claim everything earned before this call, but
        // never shares in its own early-exit tax. Remove it before distributing
        // that tax to the positions that remain.
        totalLoyaltyWeight -= weight;
        totalEthPrincipal -= ethBond.principal;
        if (loyalty != 0) loyaltyRewardReserve -= loyalty;
        delete bondedWeight[receiptId];
        delete receiptLocks[receiptId];
        delete ethBonds[receiptId];
        delete eternalBonds[receiptId];
        if (tax != 0) _distributeEarlyExitTax(receiptId, tax, ethBond.treasuryShareBps, msg.sender);
        _sweepEmptyLoyaltyReserve();
        _creditEth(msg.sender, principal + loyalty);
        _burn(receiptId);
        shares.safeTransfer(msg.sender, weight);
        zorgz.safeTransferFrom(address(this), msg.sender, receiptId);
        emit Unbonded(msg.sender, receiptId, weight);
    }

    /// @notice Turn a sufficiently large zOrgz bond into an irreversible
    ///         TokenList steward position. The receipt remains transferable and
    ///         can still allocate support, but its zOrgz and zOrg can never be
    ///         redeemed. Its ETH principal becomes DAO treasury capital while
    ///         the receipt continues to earn future loyalty distributions.
    function eternalize(uint256 receiptId) external nonReentrant {
        if (ownerOf(receiptId) != msg.sender) revert Unauthorized();
        if (eternalBonds[receiptId]) revert PermanentBond();
        uint256 weight = bondedWeight[receiptId];
        if (weight < ETERNAL_MIN_ZORG) revert BadInput();
        eternalBonds[receiptId] = true;
        EthBond storage ethBond = ethBonds[receiptId];
        uint256 principal = ethBond.principal;
        ethBond.principal = 0;
        ethBond.maturityAt = 0;
        totalEthPrincipal -= principal;
        treasuryEth += principal;
        emit Eternalized(msg.sender, receiptId, weight, principal);
    }

    /// @notice Claim loyalty ETH without breaking the bonded zOrgz position.
    /// @dev The claim right follows the receipt, not the address that created it.
    function claimLoyalty(uint256 receiptId) external nonReentrant {
        if (ownerOf(receiptId) != msg.sender) revert Unauthorized();
        _settleLoyalty(receiptId);
        EthBond storage ethBond = ethBonds[receiptId];
        uint256 amount = ethBond.accruedLoyalty;
        if (amount == 0) revert NoEthCredit();
        ethBond.accruedLoyalty = 0;
        loyaltyRewardReserve -= amount;
        _creditEth(msg.sender, amount);
        emit LoyaltyAccrued(receiptId, amount);
    }

    /// @notice Withdraw ETH previously credited by a loyalty claim or exit.
    /// @dev Pulling ETH is deliberate: a receiver that rejects ETH can never
    ///      trap a zOrgz, its shares, or its principal inside this governor.
    function withdrawEthCredit(address payable recipient) external nonReentrant {
        if (recipient == address(0)) revert BadInput();
        uint256 amount = ethCredits[msg.sender];
        if (amount == 0) revert NoEthCredit();
        ethCredits[msg.sender] = 0;
        totalEthCredits -= amount;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit EthCreditClaimed(msg.sender, recipient, amount);
    }

    /// @notice Release only the treasury share of early-exit taxes.
    /// @dev User principal, loyalty reserve, and already credited ETH are all
    ///      excluded, including from the DAO's general `execute` escape hatch.
    function releaseTreasuryEth(address payable recipient, uint256 amount) external onlyDAO nonReentrant {
        if (recipient == address(0) || amount == 0 || amount > treasuryEth) revert BadInput();
        treasuryEth -= amount;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit TreasuryEthReleased(recipient, amount);
    }

    function loyaltyOf(uint256 receiptId) public view returns (uint256) {
        EthBond storage ethBond = ethBonds[receiptId];
        uint256 accrued = ethBond.accruedLoyalty;
        uint256 index = loyaltyRewardPerWeight;
        if (index == ethBond.rewardIndex) return accrued;
        return accrued + FixedPointMathLib.fullMulDiv(bondedWeight[receiptId], index - ethBond.rewardIndex, REWARD_SCALE);
    }

    /// @notice The ETH a holder can recover by redeeming now, before a separate
    ///         pull withdrawal. `tax` is zero once the receipt is mature.
    function ethExitQuote(uint256 receiptId)
        external
        view
        returns (uint256 returnedPrincipal, uint256 tax, uint256 loyalty)
    {
        EthBond storage ethBond = ethBonds[receiptId];
        uint256 principal = ethBond.principal;
        if (block.timestamp < ethBond.maturityAt) tax = FixedPointMathLib.fullMulDiv(principal, ethBond.earlyExitTaxBps, BPS);
        return (principal - tax, tax, loyaltyOf(receiptId));
    }

    /// @notice Rejects accidental safe transfers; only bondZorgz may escrow zOrgz.
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (
            msg.sender != address(zorgz) || _expectedZorgzId != tokenId + 1 || operator != address(this)
                || bondedWeight[tokenId] == 0
                || from == address(0)
        ) revert UnsupportedZorgzTransfer();
        return this.onERC721Received.selector;
    }

    /// @notice Set one escrow receipt's direct allocation to an existing listing.
    /// @dev The sum of a receipt's allocations cannot exceed its actual share
    ///      bond, so each unit of voting weight has exactly one source.
    ///
    ///      Only INCREASES are gated. This function is the sole way to reduce an
    ///      allocation and `unbond` refuses to run while any allocation is live,
    ///      so gating the whole function turned two ordinary events — an
    ///      emergency pause, and the curator delisting a token — into permanent
    ///      confiscation of the zOrgz and shares behind every bond pointed at
    ///      it. Withdrawing support from a delisted or paused listing is the one
    ///      thing that must never be blocked.
    function allocate(uint256 receiptId, uint256 listingId, uint256 amount) external nonReentrant {
        if (ownerOf(receiptId) != msg.sender) revert Unauthorized();
        uint256 oldAmount = allocationOf[receiptId][listingId];
        if (amount > oldAmount) {
            if (paused) revert Unauthorized();
            if (!ITokenListView(tokenList).isListed(listingId)) revert UnknownListing();
        }
        uint256 newAllocated = allocatedByBond[receiptId] - oldAmount + amount;
        uint256 weight = bondedWeight[receiptId];
        if (newAllocated > weight) revert AllocationExceeded();

        ListingSupport storage support = _listingSupport[listingId];
        _accrue(support);
        uint16 boostBps = receiptLocks[receiptId].boostBps;
        uint256 oldEffective = _effectiveWeight(oldAmount, boostBps);
        uint256 newEffective = _effectiveWeight(amount, boostBps);
        if (newEffective > oldEffective) support.weight += newEffective - oldEffective;
        else support.weight -= oldEffective - newEffective;
        allocationOf[receiptId][listingId] = amount;
        allocatedByBond[receiptId] = newAllocated;
        emit Allocated(listingId, receiptId, msg.sender, amount, weight - newAllocated);
    }

    function availableBondWeight(uint256 receiptId) external view returns (uint256) {
        uint256 weight = bondedWeight[receiptId];
        return weight == 0 ? 0 : weight - allocatedByBond[receiptId];
    }

    function convictionOf(uint256 listingId) external view returns (uint256) {
        return _accruedConviction(_listingSupport[listingId]);
    }

    /// @notice Live direct support plus accrued conviction. This is the score
    ///         used by the TokenList lens: allocation moves rank now, while
    ///         holding it compounds its standing over time.
    function supportOf(uint256 listingId) external view returns (uint256) {
        return _score(_listingSupport[listingId]);
    }

    function listingState(uint256 listingId) external view returns (uint256 supportScore, uint256 weight) {
        ListingSupport storage support = _listingSupport[listingId];
        return (_score(support), support.weight);
    }

    function setHalfLife(uint64 halfLife_) external onlyDAO {
        if (halfLife_ == 0) revert BadInput();
        halfLife = halfLife_;
        emit HalfLifeSet(halfLife_);
    }

    /// @notice Set a future-bond lock tier. Existing receipt terms are never
    ///         changed retroactively; Moloch governs the menu, not live bonds.
    function setLockTier(uint8 tier, uint64 exitDelay, uint16 boostBps) external onlyDAO {
        if (
            tier == 0 || tier > MAX_LOCK_TIER || exitDelay == 0 || exitDelay > MAX_EXIT_DELAY || boostBps < BPS
                || boostBps > MAX_BOOST_BPS
        ) revert LockTierOutOfRange();
        lockTiers[tier] = LockTier({exitDelay: exitDelay, boostBps: boostBps});
        emit LockTierSet(tier, exitDelay, boostBps);
    }

    /// @notice Set terms for bonds created after this call.
    /// @dev A receipt snapshots these values at mint, so Moloch cannot rewrite
    ///      an existing holder's principal maturity or early-exit quote.
    function setEthBondTerms(uint256 minimumBond, uint64 maturity, uint16 earlyExitTaxBps, uint16 treasuryShareBps)
        external
        onlyDAO
    {
        if (
            minimumBond == 0 || maturity == 0 || maturity > MAX_ETH_MATURITY || earlyExitTaxBps == 0
                || earlyExitTaxBps > BPS || treasuryShareBps == 0 || treasuryShareBps > BPS
        ) revert EthTermsOutOfRange();
        ethBondTerms = EthBondTerms({
            minimumBond: minimumBond,
            maturity: maturity,
            earlyExitTaxBps: earlyExitTaxBps,
            treasuryShareBps: treasuryShareBps
        });
        emit EthBondTermsSet(minimumBond, maturity, earlyExitTaxBps, treasuryShareBps);
    }

    function setRenderer(IZorgConvictionRenderer renderer_) external onlyDAO {
        if (address(renderer_).code.length == 0) revert BadInput();
        renderer = renderer_;
        emit RendererSet(address(renderer_));
    }

    /// @notice Replace the receipt metadata contract. Art is the one part of the
    ///         system that will want to change without migrating anybody's bond.
    function setReceiptArt(IZorgReceiptArt receiptArt_) external onlyDAO {
        if (address(receiptArt_).code.length == 0) revert BadInput();
        receiptArt = receiptArt_;
        emit ReceiptArtSet(address(receiptArt_));
    }

    function html() external view returns (string memory) {
        return renderer.html(address(this), tokenList);
    }

    function emergencyPause() external {
        if (!_hasRole(execZorgWeiId, msg.sender)) revert Unauthorized();
        paused = true;
        emit PauseSet(true, msg.sender);
    }

    /// @notice Retire the emergency credential for good.
    /// @dev The credential is a transferable name, so the DAO cannot retire it
    ///      by holding it. This is the switch that ends the role once the
    ///      system no longer needs an emergency operator.
    function burnExecRole() external onlyDAO {
        execRoleRevoked = true;
        emit ExecRoleBurned();
    }

    function resume() external onlyDAO {
        paused = false;
        emit PauseSet(false, msg.sender);
    }

    /// @dev Bonded zOrg shares and zOrgz are excluded: only unbond can move them.
    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyDAO
        nonReentrant
        returns (bytes memory result)
    {
        result = _execute(target, value, data, false);
    }

    function emergencyExecute(address target, uint256 value, bytes calldata data)
        external
        nonReentrant
        returns (bytes memory result)
    {
        if (!_hasRole(execZorgWeiId, msg.sender) || !paused) revert Unauthorized();
        result = _execute(target, value, data, true);
    }

    function _accrue(ListingSupport storage support) internal {
        uint64 now_ = uint64(block.timestamp);
        support.conviction = _advance(support.conviction, support.weight, now_ - support.lastUpdated);
        support.lastUpdated = now_;
    }

    /// @dev The canonical list ranks live direct support plus earned
    ///      conviction. A fresh allocation takes effect immediately, while the
    ///      accrued component approaches the same effective weight over time.
    function _score(ListingSupport storage support) internal view returns (uint256) {
        return support.weight + _accruedConviction(support);
    }

    function _accruedConviction(ListingSupport storage support) internal view returns (uint256) {
        return _advance(support.conviction, support.weight, uint64(block.timestamp) - support.lastUpdated);
    }

    /// @dev Move `current` toward `target` by closing half the remaining gap
    ///      every `halfLife`: `target + gap * 2^-(elapsed/halfLife)`.
    ///
    ///      The exponential form is not decoration. The rational approximation
    ///      this replaces, `gap * halfLife / (halfLife + elapsed)`, is not
    ///      time-homogeneous: advancing once over `2e` lands somewhere other than
    ///      advancing twice over `e`. Accrual is triggered by callers rather than
    ///      by the clock - `allocate` accrues the listing it touches, and accepts
    ///      a write that changes nothing - so anyone holding any receipt, one wei
    ///      of bond included, could poke a listing once a block to drive its score
    ///      toward the target faster than elapsed time alone permitted, or to
    ///      accelerate a rival's decay. Halving composes exactly, so the result
    ///      depends only on total elapsed time and poking gains nothing.
    ///
    ///      `powWad` saturates to zero long before the exponent can overflow, so
    ///      a very old listing simply arrives at its target.
    function _advance(uint256 current, uint256 target, uint256 elapsed) internal view returns (uint256) {
        if (elapsed == 0 || current == target) return current;
        uint256 remaining =
            uint256(FixedPointMathLib.powWad(0.5e18, int256(FixedPointMathLib.divWad(elapsed, halfLife))));
        uint256 gap = current > target ? current - target : target - current;
        gap = FixedPointMathLib.fullMulDiv(gap, remaining, 1e18);
        return current > target ? target + gap : target - gap;
    }

    function _effectiveWeight(uint256 rawWeight, uint16 boostBps) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(rawWeight, boostBps, BPS);
    }

    function _settleLoyalty(uint256 receiptId) internal {
        EthBond storage ethBond = ethBonds[receiptId];
        uint256 index = loyaltyRewardPerWeight;
        uint256 checkpoint = ethBond.rewardIndex;
        if (index == checkpoint) return;
        ethBond.accruedLoyalty +=
            FixedPointMathLib.fullMulDiv(bondedWeight[receiptId], index - checkpoint, REWARD_SCALE);
        ethBond.rewardIndex = index;
    }

    function _distributeEarlyExitTax(uint256 receiptId, uint256 tax, uint16 treasuryShareBps, address owner_) internal {
        uint256 toTreasury = FixedPointMathLib.fullMulDiv(tax, treasuryShareBps, BPS);
        uint256 toLoyalty = tax - toTreasury;
        if (toLoyalty != 0 && totalLoyaltyWeight != 0) {
            uint256 indexIncrease = FixedPointMathLib.fullMulDiv(toLoyalty, REWARD_SCALE, totalLoyaltyWeight);
            uint256 distributed = FixedPointMathLib.fullMulDiv(indexIncrease, totalLoyaltyWeight, REWARD_SCALE);
            loyaltyRewardPerWeight += indexIncrease;
            loyaltyRewardReserve += distributed;
            // Integer dust should never become an unclaimable hidden balance.
            toTreasury += toLoyalty - distributed;
            toLoyalty = distributed;
        } else {
            toTreasury += toLoyalty;
            toLoyalty = 0;
        }
        treasuryEth += toTreasury;
        emit EarlyExitTaxed(receiptId, tax, toTreasury, toLoyalty, owner_);
    }

    function _sweepEmptyLoyaltyReserve() internal {
        if (totalLoyaltyWeight == 0 && loyaltyRewardReserve != 0) {
            treasuryEth += loyaltyRewardReserve;
            loyaltyRewardReserve = 0;
        }
    }

    function _creditEth(address account, uint256 amount) internal {
        if (amount == 0) return;
        ethCredits[account] += amount;
        totalEthCredits += amount;
    }

    function _ethLiability() internal view returns (uint256) {
        return totalEthPrincipal + loyaltyRewardReserve + treasuryEth + totalEthCredits;
    }

    function _hasRole(uint256 tokenId, address account) internal view returns (bool) {
        if (!rolesInstalled || execRoleRevoked) return false;
        try weiNames.ownerOf(tokenId) returns (address owner_) {
            return owner_ == account;
        } catch {
            return false;
        }
    }

    function _execute(address target, uint256 value, bytes calldata data, bool emergency)
        internal
        returns (bytes memory result)
    {
        if (target == address(0)) revert BadInput();
        if (target == address(zorgz) || target == shares) revert ProtectedAsset();
        // Naming the two escrowed assets is not enough to protect them. Moloch's
        // `ragequit` is public and burns the CALLER's shares, so a call to the
        // DAO itself destroys every bonded share without either forbidden target
        // ever appearing — the bond accounting survives and `unbond` then reverts
        // on an empty balance. Assert the invariant the denylist was standing in
        // for instead: whatever this call does, it may not leave the governor
        // holding fewer shares than it started with.
        uint256 escrow = SafeTransferLib.balanceOf(shares, address(this));
        uint256 ethEscrow = _ethLiability();
        (bool ok, bytes memory returned) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returned, 0x20), mload(returned))
            }
        }
        if (SafeTransferLib.balanceOf(shares, address(this)) < escrow) revert EscrowReduced();
        if (address(this).balance < ethEscrow) revert EthEscrowReduced();
        emit Executed(target, value, data, msg.sender, emergency);
        return returned;
    }

    receive() external payable {}
}
