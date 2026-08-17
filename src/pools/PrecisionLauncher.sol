// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";
import {PrecisionPoolFactory} from "./PrecisionPoolFactory.sol";
import {ERC20} from "../../lib/solady/src/tokens/ERC20.sol";
import {Ownable} from "../../lib/solady/src/auth/Ownable.sol";
import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "../../lib/solady/src/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";
import {SSTORE2} from "../../lib/solady/src/utils/SSTORE2.sol";
import {LibClone} from "../../lib/solady/src/utils/LibClone.sol";
import {Base64} from "../../lib/solady/src/utils/Base64.sol";
import {LibString} from "../../lib/solady/src/utils/LibString.sol";

/// @title LaunchToken
/// @notice Fixed-supply ERC-20 with owner-editable ERC-7572 contract metadata.
/// @dev The whole supply is minted to the deployer - the launcher - which
///      splits it between the creator's allocation and the pool. There is no
///      mint function, so supply is fixed at construction and only ever falls:
///      `burn` is what redemption and the fee sink use.
///
///      Ownership governs `contractURI` and nothing else. It carries no power
///      over balances, transfers, or the pool, so a creator who renounces
///      merely freezes the metadata.
contract LaunchToken is ERC20, Ownable {
    string internal _name;
    string internal _symbol;
    string internal _contractURI;

    /// @notice SSTORE2 pointer to the raw image bytes, or zero for none.
    /// @dev The image is stored as CONTRACT CODE rather than in a string,
    ///      which is the whole reason an on-chain logo is affordable: code
    ///      costs 200 gas a byte against storage's 20,000 per 32-byte word.
    ///      The bytes are kept RAW and base64'd in `contractURI` - encoding
    ///      here would inflate what is written by a third to save work in a
    ///      view call, where gas is free.
    ///
    ///      EIP-170 caps a data contract at 24,575 bytes, so that is the
    ///      ceiling on an image. Simple marks land far below it: an SVG logo
    ///      is typically 1-3 KB and a lossless WebP of flat cartoon art 2-4 KB.
    address public imagePointer;

    /// @notice Which format `imagePointer` holds. See `_mimeOf`.
    uint8 public imageMime;

    /// @dev ERC-7572. Deliberately argument-free, per the standard: indexers
    ///      re-read `contractURI()` rather than trusting the log.
    event ContractURIUpdated();

    /// @dev Locks the IMPLEMENTATION so it can never be initialized.
    ///
    ///      Clones do not run this - that is the point of a clone - so their
    ///      owner slot starts empty and `initialize` works exactly once. The
    ///      implementation's does not, which is what stops a passer-by from
    ///      claiming the template itself, minting its supply and leaving a
    ///      contract that looks like one of ours behaving like it is.
    constructor() {
        _initializeOwner(address(0xdead));
    }

    /// @notice Set up a freshly cloned token. Callable once, by the launcher.
    /// @dev The constructor's job, moved here because these are minimal proxies
    ///      now. See `PrecisionLauncher.tokenImplementation` for why.
    ///
    ///      ONE GUARD, NOT TWO. `_initializeOwner` already reverts on a second
    ///      call - `_guardInitializeOwner` below returns true - so it does the
    ///      work an `initialized` flag would, and it is called FIRST so nothing
    ///      is written or minted before the check. A separate flag would be a
    ///      storage slot buying a guarantee this contract already has.
    ///
    ///      Not front-runnable: the launcher clones and initializes in a single
    ///      call, so an uninitialized clone never exists between transactions.
    /// @param image Raw image bytes, or empty for none. Set HERE rather than
    ///        through `setImage` because `setImage` is `onlyOwner` and this
    ///        hands ownership to the creator on the line above - so by the time
    ///        the launcher regained control it would no longer be allowed to.
    ///        Which is the whole reason a launch used to cost two signatures.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata uri_,
        uint256 supply,
        address owner_,
        bytes calldata image,
        uint8 mime
    ) external {
        _initializeOwner(owner_);
        (_name, _symbol, _contractURI) = (name_, symbol_, uri_);
        if (image.length != 0) {
            if (mime > 5) revert BadMime();
            imagePointer = SSTORE2.write(image);
            imageMime = mime;
        }
        _mint(msg.sender, supply);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice ERC-7572 collection-level metadata.
    /// @dev `_contractURI` MEANS TWO DIFFERENT THINGS depending on whether an
    ///      image is set, and the switch is silent, so it is stated here rather
    ///      than discovered. With no image it is returned verbatim and is
    ///      whatever the creator supplied - typically an off-chain URI. With an
    ///      image set, the document is assembled on-chain and that same string
    ///      becomes the JSON `description`. A creator who launched with
    ///      `ipfs://Qm...` and later calls `setImage` will therefore find their
    ///      URI rendered as descriptive text. Set the description you want
    ///      before, or alongside, the image.
    /// @dev Two shapes, and which one you get depends on whether an image has
    ///      been stored. With no image this returns whatever string the owner
    ///      set - an `ipfs://` or `https://` URI, exactly as before, which is
    ///      the escape hatch for metadata too large or too rich to hold here.
    ///
    ///      With an image it assembles the whole document inline instead, so
    ///      the token describes itself with no external dependency at all: no
    ///      pinning service to keep paying, no gateway to go dark, nothing to
    ///      rot. The stored string is still honoured as the `description`, so
    ///      setting one is not wasted when an image arrives later.
    ///
    ///      Assembled on READ rather than stored assembled, because a view call
    ///      is free and storage is not. Two base64 passes over a few kilobytes
    ///      is nothing in `eth_call` and would be absurd to pay for on-chain.
    function contractURI() public view returns (string memory) {
        address p = imagePointer;
        if (p == address(0)) return _contractURI;
        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(
                    abi.encodePacked(
                        '{"name":"',
                        LibString.escapeJSON(_name),
                        '","symbol":"',
                        LibString.escapeJSON(_symbol),
                        '","description":"',
                        LibString.escapeJSON(_contractURI),
                        '","image":"data:',
                        _mimeOf(imageMime),
                        ";base64,",
                        Base64.encode(SSTORE2.read(p)),
                        '"}'
                    )
                )
            )
        );
    }

    /// @dev A one-byte code rather than a stored mime string: the set is fixed,
    ///      and a free-form string here would be an owner-controlled value
    ///      injected into a data URI.
    function _mimeOf(uint8 m) internal pure returns (string memory) {
        if (m == 0) return "image/png";
        if (m == 1) return "image/webp";
        if (m == 2) return "image/svg+xml";
        if (m == 3) return "image/gif";
        if (m == 4) return "image/jpeg";
        // `setImage` rejects anything above 5, so this is the last admitted
        // value rather than a default - there is no unreachable fallback here
        // to mislead a reader into thinking an unknown mime is representable.
        return "image/avif";
    }

    /// @notice Repoint the metadata. Owner only.
    /// @dev Doubles as the image's `description` once one is stored, which is
    ///      why this stays useful rather than becoming dead weight.
    function setContractURI(string calldata uri_) external onlyOwner {
        _contractURI = uri_;
        emit ContractURIUpdated();
    }

    /// @notice Store an image on-chain and serve it from `contractURI`.
    /// @param image Raw image bytes. NOT base64 - the encoding happens on read.
    /// @param mime Format code: 0 png, 1 webp, 2 svg, 3 gif, 4 jpeg, 5 avif.
    /// @dev Owner only, and replaceable: a creator can open with a rough mark
    ///      and pay for a better one later, which is the point of leaving this
    ///      editable rather than sealing it at launch.
    ///
    ///      The old pointer is abandoned rather than cleaned up. There is no
    ///      way to reclaim code-deposit gas, so tracking it would cost storage
    ///      to enable nothing.
    ///
    ///      Passing empty bytes clears the image and returns `contractURI` to
    ///      the plain stored string, so this is reversible.
    /// @notice Store the collection image on-chain, or clear it with empty
    ///         bytes. Owner only.
    /// @dev Setting an image switches `contractURI` to an assembled on-chain
    ///      document and repurposes the stored string as its description - see
    ///      `contractURI`.
    function setImage(bytes calldata image, uint8 mime) external onlyOwner {
        if (mime > 5) revert BadMime();
        // `SSTORE2.write` would deploy a 1-byte STOP contract for empty input,
        // which reads back as an empty image and renders as a broken one. Zero
        // is the honest representation of "no image".
        imagePointer = image.length == 0 ? address(0) : SSTORE2.write(image);
        imageMime = mime;
        emit ContractURIUpdated();
    }

    error BadMime();

    /// @notice Burn from the caller. Permissionless: burning is always a gift
    ///         to every remaining holder, since it raises the redemption floor.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @dev Load-bearing for the clone pattern, not merely hygiene. Returning
    ///      true makes `_initializeOwner` revert on a second call, which is
    ///      what gives `initialize` its once-only guarantee WITHOUT a separate
    ///      flag - and it is also what locks the implementation, whose
    ///      constructor claims the slot for `0xdead`. Flip this to false and a
    ///      passer-by can re-initialize any clone, seize ownership, and
    ///      re-mint. Ownership is set in `initialize` for clones and in the
    ///      constructor only for the implementation being locked.
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }
}

/// @title PrecisionLauncher
/// @notice One-transaction token launches into a one-sided PrecisionPool,
///         with the LP position held permanently by this contract and
///         redeemable by any holder at the token's ETH-backed floor.
///
/// @dev THE SHAPE. A launch mints a fixed supply, hands the creator their
///      allocation, and seeds the entire remainder into a fresh ETH/token
///      PrecisionPool as ONE-SIDED liquidity. No ETH is required to launch.
///      The pool's `_seed` supports this natively: seeding exactly at the
///      band's upper bound puts `used0` at zero, so the pool opens holding
///      nothing but the token.
///
///      Because ETH is `address(0)` it always sorts first, so the launched
///      token is always `token1` and price - `p = sqrtP^2 / 1e36`, in raw
///      tokens per wei - starts at its maximum and falls as buyers arrive.
///      Falling `p` is the token appreciating.
///
///      THE FLOOR. This contract never sells and never withdraws. It holds the
///      LP forever, and the only way ETH leaves the position is a holder
///      burning tokens for their pro-rata share of it:
///
///          ethClaim = lpHeld * reserve0 / lpTotal
///          tokClaim = lpHeld * reserve1 / lpTotal
///          circulating C = totalSupply - tokClaim
///          floor F = ethClaim / C
///
///      `redeem` burns `lpHeld * amount / C` LP shares, pays out the ETH that
///      releases, and burns BOTH the caller's tokens and the tokens that came
///      back out of the position. Work the post-state through and `C' = C - b`
///      and `F' = F` exactly: redemption is floor-neutral for everyone who
///      does not redeem. There is no race to the exit, which is the property
///      that makes the floor credible rather than merely present.
///
///      Three further properties, verified rather than assumed:
///
///      1. BUY-AND-REDEEM IS NOT PROFITABLE FROM TRADING ALONE. Buying `e` wei
///         for `t` tokens and immediately redeeming pays `t*(E+e)/(C+t)`,
///         which beats `e` only if the buy's AVERAGE execution price is below
///         the floor. The marginal price is at or above the average on a
///         rising curve and starts above the floor, so trading never gets it
///         there; the fee makes it strictly lossy. The floor is the average
///         price paid by circulating supply, the market quotes the marginal
///         price, and the gap between them is the whole mechanism.
///
///         THE QUALIFIER IS LOAD-BEARING and was learned the hard way - the
///         unconditional version of this claim is FALSE, and an invariant
///         runner broke it in three calls on its first run: buy, burn 99% of a
///         holding, sell the rest. Burning collapses `C` without touching the
///         pool, so the floor jumps while the market does not move; the sell
///         then crashes the market underneath it. In that state a round trip
///         does profit.
///
///         It is not an attack, and the reason is worth stating precisely
///         rather than trusting: the profit IS the burner's forfeited backing.
///         Burning destroys a claim on the position and leaves the ETH behind,
///         so whoever buys afterwards collects it. Measured, an attacker who
///         ran the whole sequence spent 240 ETH to recover 0.39, while an
///         uninvolved holder's redeemable value ROSE from 99.5 to 332 ETH.
///         Solvency is untouched throughout. Anything that gifts supply into
///         this system - a voluntary burn, and to a far smaller degree the fee
///         burn in `collectFees` - moves the floor toward the market without
///         moving the market, and that is a transfer to holders rather than a
///         leak out of the position.
///
///      2. THE FLOOR IS AN ATTRACTOR, NOT A RATCHET. It is the average price
///         paid by circulating supply, so it MOVES IN BOTH DIRECTIONS: a buy
///         above it raises it, and a sell above it LOWERS it, because the
///         seller withdraws ETH at the market price while surrendering tokens
///         that carried only the average - the difference comes out of what
///         backs everyone else.
///
///         THE DOWNWARD MOVE IS NOT SMALL and should not be described as
///         rounding. Selling half the circulating supply at 1.5x the floor cuts
///         the floor roughly in half; a measured lifecycle selloff took it down
///         57%. What is bounded is the RELATIONSHIP, not the level: the size of
///         each move scales with `p - F`, so it vanishes exactly as the market
///         approaches the floor. Price therefore converges onto the floor and
///         does not cross it, and redemption is always available at whatever
///         the floor then is - but a holder who reads the floor as a number
///         that only ever rises has misunderstood it.
///
///      3. OUTSIDE LPs ARE FLOOR-NEUTRAL. A proportional deposit scales
///         `reserve0` and `lpTotal` by the same factor, leaving
///         `lpHeld * reserve0 / lpTotal` unchanged. Same on withdrawal. So
///         third-party liquidity neither helps nor harms redeemers, and there
///         is no reason to forbid it.
///
///      NO KEEPER, NO BUYBACK LOOP. When the market trades below the floor,
///      buying and redeeming is riskless profit, so solvers close the gap and
///      the buy pressure IS the buyback. Nothing here needs to be triggered,
///      funded, or trusted to act.
///
///      WHY REDEMPTION DOES NOT MOVE THE PRICE. PrecisionPool's virtual
///      reserves scale with LP supply, so a proportional removal divides both
///      sides of `p = (v1 + r1) / (v0 + r0)` by the same factor. In a pool
///      without virtual reserves this would need separate handling.
///
///      THE ONE DILUTION. The creator's allocation sits in `C` and claims ETH
///      it never paid for, so an allocation of `k` lowers the floor by `k`.
///      This is deliberate and is why `MAX_ALLOC_BPS` exists: excluding the
///      allocation from redemption would require per-address non-redeemable
///      balances, which stop meaning anything the moment the creator sells.
///      One fungible token, one rule, and a cap on the size of the discount.
contract PrecisionLauncher is ReentrancyGuard {
    using SafeTransferLib for address;

    /// @dev Swap fee, in pips (1e6 = 100%). 1%.
    uint256 constant FEE = 10_000;

    /// @dev Share of the swap fee routed here, in bps of the fee. The other
    ///      half stays in the pool as reserves, which is to say it accrues
    ///      directly to the floor.
    uint256 constant CREATOR_FEE_BPS = 5_000;

    /// @dev Share of collected ETH fees taken by the treasury, in bps.
    uint256 constant PROTOCOL_BPS = 1_000;

    /// @dev Share of collected ETH fees burned, in bps. A literal tithe.
    uint256 constant TITHE_BPS = 1_000;

    /// @notice Canonical BETH burner. ETH sent here is destroyed; BETH is
    ///         minted to the named address as the permanent record of it.
    /// @dev Verified on mainnet: real contract, 18 decimals, and it holds a
    ///      ZERO balance against a nonzero BETH supply - the ETH does not sit
    ///      there, it is gone.
    address constant BETH_BURNER = 0x2cb662Ec360C34a45d7cA0126BCd53C9a1fd48F9;

    /// @notice Where the BETH record of this protocol's burns accrues.
    /// @dev Receives BETH, never ETH, so it cannot fail a sweep however it is
    ///      implemented - an ERC-20 credit needs nothing of its recipient.
    address constant TITHE_RECORD = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    /// @dev Ceiling on the creator's allocation, in bps of total supply. See
    ///      "THE ONE DILUTION" above: this is a bound on how far the creator's
    ///      free tokens can discount every buyer's floor.
    uint256 constant MAX_ALLOC_BPS = 2_000;

    /// @dev Width of the price band, as a ratio. `sqrtPLow = sqrtPHigh / 1e6`
    ///      puts the price ceiling 1e12x above the launch price - a 3 ETH
    ///      launch caps at 3e12 ETH, which is not a constraint anyone will
    ///      meet - while keeping the pool's virtual `reserve1` some fifteen
    ///      orders of magnitude above its `MIN_RESOLUTION` floor. A band is
    ///      required (the pool has no unbounded mode), so the question is only
    ///      where to put the far end, and this is far enough to be notional.
    uint256 constant BAND = 1e6;

    /// @dev The pool requires `MIN_RESOLUTION` (1e6) of virtual reserve on
    ///      BOTH sides, and the two sides are floored by different parameters.
    ///      An earlier comment here claimed this constant covered both; it
    ///      does not, and the halves are worth writing out because the answer
    ///      is not the one the shape of the code suggests.
    ///
    ///      The ETH side is the valuation: `v0 = lp*1e18/sh ~= startMcapWei`.
    ///      The TOKEN side is not, and does not involve the valuation at all -
    ///      with `sl = sh/BAND` the `sh` terms cancel:
    ///
    ///          v1 = lp*sl/1e18 = pooled*sh / (BAND*(sh - sl)) = pooled/(BAND-1)
    ///
    ///      So the token side is floored by SUPPLY, at `pooled >= ~1e12` raw
    ///      units, and no valuation however large rescues a supply below it.
    ///      Both are checked in `launch`, so a degenerate launch fails with a
    ///      stated reason instead of reaching `_seed` and reverting there with
    ///      `InsufficientLiquidity` - the same legibility argument as the
    ///      `MAX_SQRT_PRICE` bound beside it.
    uint256 constant MIN_START_MCAP = 1e12;
    /// @dev DOUBLE the derived bound, deliberately. At exactly 1e12 the token
    ///      side lands on `v1 = 1e12/(BAND-1) = 1_000_001` against a floor of
    ///      1_000_000 - correct, and with one single unit of headroom on a
    ///      constant whose entire job is to stop a launch reaching `_seed` and
    ///      reverting there with an error that names none of its parameters.
    ///      2e12 raw units is 1e-6 of one token, so the margin costs nothing
    ///      real and survives a future change to `BAND`.
    uint256 constant MIN_POOLED = 2e12;

    /// @dev Gas ceiling on the tithe's outward call. See `_tithe`.
    uint256 constant TITHE_GAS = 200_000;

    /// @dev Bounds on the metadata that appears in EVERY entry of a paged lens
    ///      read. Not cosmetic: `PrecisionLauncherLens.launches` assembles
    ///      `name` and `symbol` for a whole page into one returned array, and
    ///      memory cost is QUADRATIC, so a single launch carrying a megabyte
    ///      name can push the page past what `eth_call` will serve. Launching
    ///      is permissionless, and the factory index is dense and ordered, so
    ///      that launch poisons the specific page it lands in - and a client
    ///      paging the registry cannot skip past what it cannot decode.
    ///
    ///      Bounded HERE rather than truncated in the lens: the template is the
    ///      product, "a name a UI can render" is part of it, and a creator
    ///      should learn their name is too long at launch rather than have it
    ///      silently clipped afterwards. The URI is deliberately NOT bounded -
    ///      the paged views omit it, so an oversized one costs only its own
    ///      token's single-item read.
    uint256 constant MAX_NAME = 64;
    uint256 constant MAX_SYMBOL = 16;

    uint256 constant BPS = 10_000;
    uint256 constant WAD = 1e18;
    uint256 constant MAX_SQRT_PRICE = 1e36;

    error Bad();
    error NoToken();
    error Slippage();

    /// @notice Factory whose pools this launcher creates and holds LP in.
    PrecisionPoolFactory public immutable factory;

    /// @notice The template every launched token is a minimal proxy of.
    /// @dev Deployed once, here, so a launch pays for a 45-byte PUSH0 clone
    ///      instead of ~6 KB of identical code. Measured on this contract:
    ///      deploying the token outright is the second-largest line item in a
    ///      launch, and cloning removes almost all of it.
    ///
    ///      The trade, stated because it is real and it is paid by someone
    ///      else: a proxy adds a delegatecall to every call the token ever
    ///      receives - about 2,600 gas on the first touch in a transaction,
    ///      ~100 on each after - so roughly a tenth on top of a transfer,
    ///      forever. Cheaper to launch, fractionally dearer to trade. That is
    ///      the right way round for a launchpad, where most tokens are created
    ///      and then barely move, and the cost only becomes material on the
    ///      ones that succeed enough to pay it easily.
    address public immutable tokenImplementation;

    /// @notice Recipient of the protocol share of collected ETH fees.
    address public immutable treasury;

    /// @notice The pool holding a launched token's liquidity.
    mapping(address token => address) public poolOf;

    /// @notice Who collects the creator share of a launched token's fees.
    /// @dev Set at launch and reassignable by its current holder. Separate from
    ///      the token's `owner`, which governs metadata only - transferring or
    ///      renouncing one does not touch the other, because the two are
    ///      different jobs and a project that sells one rarely means both.
    mapping(address token => address) public creatorOf;

    /// @notice Creator awaiting acceptance of a launched token's fee stream.
    mapping(address token => address) public pendingCreatorOf;

    /// @notice The creator's allocation at launch, in bps of supply.
    /// @dev STORED, though nothing on-chain consumes it, because it is the one
    ///      lever a creator has over every buyer's floor and it is otherwise
    ///      recoverable only by replaying the launch trace. `startMcapWei`
    ///      values the POOLED supply, so a reader who mistakes it for fully
    ///      diluted understates the dilution by exactly this number. A
    ///      contract this deliberate about being self-describing should not
    ///      need an archive node to answer "how much did the creator take".
    mapping(address token => uint256) public allocBpsOf;

    event Launched(
        address indexed token,
        address indexed pool,
        address indexed creator,
        uint256 supply,
        uint256 allocBps,
        uint256 startMcapWei
    );
    event Redeemed(address indexed token, address indexed to, uint256 burned, uint256 ethOut);
    /// @param titheRecorded Whether the tithe minted its BETH record, or fell
    ///        back to forcing the ETH to the burner unrecorded. The ETH is
    ///        burned either way; this is the difference between a burn the DAO
    ///        holds a claim on and one nobody does. Emitted because that is the
    ///        single thing `_tithe` is willing to sacrifice, and a sacrifice
    ///        nothing observes is one nobody can notice has started happening.
    event FeesCollected(
        address indexed token,
        uint256 creatorEth,
        uint256 protocolEth,
        uint256 titheEth,
        uint256 tokensBurned,
        bool titheRecorded
    );
    event CreatorSet(address indexed token, address indexed creator);
    event CreatorHandoffStarted(address indexed token, address indexed pending);

    constructor(PrecisionPoolFactory factory_, address treasury_) {
        if (address(factory_).code.length == 0 || treasury_ == address(0)) revert Bad();
        (factory, treasury) = (factory_, treasury_);
        tokenImplementation = address(new LaunchToken());
    }

    /// @notice Launch a token and seed its market in one transaction.
    /// @param name Token name.
    /// @param symbol Token symbol.
    /// @param uri Initial ERC-7572 `contractURI`, editable later by `owner`.
    /// @param supply Total supply, in raw units (the token has 18 decimals).
    /// @param allocBps Creator's allocation, in bps of supply. May be zero.
    /// @param startMcapWei Opening valuation of the pooled supply, in wei.
    ///        This is the pool's initial virtual ETH reserve, so it sets the
    ///        depth of the curve as well as the opening price. Note it values
    ///        the POOLED supply: with an allocation, fully diluted is higher
    ///        by `supply / (supply - allocation)`.
    /// @param owner Owner of the token's metadata, and the creator recorded
    ///        for fee collection. Receives the allocation.
    function launch(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        uint256 supply,
        uint256 allocBps,
        uint256 startMcapWei,
        address owner
    ) external nonReentrant returns (address token, address pool) {
        return _launch(name, symbol, uri, supply, allocBps, startMcapWei, owner, "", 0);
    }

    /// @notice A launch that arrives with its logo already on-chain.
    ///
    /// @dev ONE SIGNATURE, WHICH IS THE ENTIRE POINT. The image lives on the
    ///      TOKEN, and the token does not exist until this call runs - its
    ///      address is CREATE-derived from this contract's nonce - so a page
    ///      could not call `setImage` until the launch had already confirmed.
    ///      That made every launch with a logo two wallet prompts, the second
    ///      of which a user could simply decline, leaving a coin with no art
    ///      and no obvious way to understand why.
    ///
    ///      Passing the bytes through here costs calldata - 16 gas a byte, so
    ///      roughly 65k for a 4 KB mark - on top of the same SSTORE2 write the
    ///      separate call would have made. That is the price of the second
    ///      prompt disappearing, and it is worth it.
    ///
    ///      `launch` is the same function with no art, so there is one body and
    ///      one set of guards rather than two that must be kept in step.
    /// @param image Raw image bytes. NOT base64 - encoding happens on read.
    /// @param mime 0 png, 1 webp, 2 svg, 3 gif, 4 jpeg, 5 avif.
    function launchWithArt(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        uint256 supply,
        uint256 allocBps,
        uint256 startMcapWei,
        address owner,
        bytes calldata image,
        uint8 mime
    ) external nonReentrant returns (address token, address pool) {
        return _launch(name, symbol, uri, supply, allocBps, startMcapWei, owner, image, mime);
    }

    function _launch(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        uint256 supply,
        uint256 allocBps,
        uint256 startMcapWei,
        address owner,
        /* `memory`, not `calldata`: `launch` passes an empty literal and a
           literal has no calldata to point at. The copy is a few words. */
        bytes memory image,
        uint8 mime
    ) internal returns (address token, address pool) {
        if (owner == address(0)) revert Bad();
        {
            uint256 n = bytes(name).length;
            uint256 sy = bytes(symbol).length;
            if (n == 0 || n > MAX_NAME || sy == 0 || sy > MAX_SYMBOL) revert Bad();
        }
        if (allocBps > MAX_ALLOC_BPS) revert Bad();
        if (startMcapWei < MIN_START_MCAP) revert Bad();

        uint256 alloc = supply * allocBps / BPS;
        uint256 pooled = supply - alloc;
        // Not `pooled == 0`: the token side of the pool's resolution floor is a
        // property of SUPPLY, not of valuation. See `MIN_POOLED`.
        if (pooled < MIN_POOLED) revert Bad();

        // `sqrtP` is `sqrt(price) * 1e18` where price is raw token1 per raw
        // token0, so seeding at `sqrtPHigh` with the initial virtual ETH
        // reserve equal to `startMcapWei` means
        //     sqrtPHigh = 1e18 * sqrt(pooled / startMcapWei).
        // The band's lower bound perturbs this by a factor of about
        // `1 + 1/(2 * BAND)` - one part in two million - which is not worth
        // correcting for and is documented rather than compensated.
        uint256 sqrtPHigh = FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(pooled, WAD * WAD, startMcapWei));
        uint256 sqrtPLow = sqrtPHigh / BAND;
        // The factory enforces both of these too; checking here is what makes
        // an out-of-range valuation legible as a launch parameter problem.
        if (sqrtPHigh > MAX_SQRT_PRICE || sqrtPLow == 0) revert Bad();

        token = LibClone.clone_PUSH0(tokenImplementation);
        LaunchToken(token).initialize(name, symbol, uri, supply, owner, image, mime);
        if (alloc != 0) token.safeTransfer(owner, alloc);

        PrecisionPoolFactory.Market memory m = PrecisionPoolFactory.Market({
            token0: address(0),
            token1: token,
            sqrtPLow: sqrtPLow,
            sqrtPHigh: sqrtPHigh,
            fee: FEE,
            hook: address(0),
            // This contract must be the fee recipient: the factory admits a
            // named market only from the recipient itself, and the caller here
            // is this contract. `collectFees` is the forwarder that makes that
            // constraint invisible to the creator.
            feeRecipient: address(this),
            creatorFeeBps: CREATOR_FEE_BPS
        });

        token.safeApprove(address(factory), pooled);
        // `minLP` of 1 rather than a computed bound: the pool address is
        // derived from a tuple containing a token that did not exist a moment
        // ago, so there is no pre-existing state for anyone to front-run into.
        (pool,,,) = factory.createAndSeed(m, sqrtPHigh, 0, pooled, 1, address(this));

        // The seed's bound corrections can round a few units off `used1`. They
        // are refunded here, and burning them is both the tidiest disposal and
        // a marginal gift to the floor.
        uint256 dust = token.balanceOf(address(this));
        if (dust != 0) LaunchToken(token).burn(dust);

        (poolOf[token], creatorOf[token], allocBpsOf[token]) = (pool, owner, allocBps);
        emit Launched(token, pool, owner, supply, allocBps, startMcapWei);
    }

    /// @notice Burn `amount` tokens for their pro-rata share of the ETH held
    ///         in the locked LP position.
    /// @dev Floor-neutral for every holder who does not call it - see the
    ///      contract header. Rounding is toward the position throughout:
    ///      `tokClaim` floors, which rounds `circulating` up, which floors the
    ///      LP shares burned. A stream of dust redemptions therefore cannot
    ///      ratchet the floor down; each either pays its exact share or
    ///      reverts for paying nothing.
    /// @param token A token launched by this contract.
    /// @param amount Tokens to burn. Pulled from the caller.
    /// @param minEthOut Slippage bound on the payout.
    /// @param to ETH recipient.
    function redeem(address token, uint256 amount, uint256 minEthOut, address to)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        address pool = poolOf[token];
        if (pool == address(0)) revert NoToken();
        if (to == address(0) || amount == 0) revert Bad();

        // Pool state is read BEFORE the caller's tokens are pulled. That is
        // safe only because `LaunchToken` is a plain ERC-20 this contract
        // deploys itself, so no code runs during the transfer and none of these
        // reads can go stale underneath it. It is safe by a property of the
        // token rather than by construction - if `LaunchToken` ever gained a
        // transfer hook, this ordering becomes exploitable and must move.
        PrecisionPool p = PrecisionPool(payable(pool));
        uint256 lpHeld = p.balanceOf(address(this));
        uint256 lpTotal = p.totalSupply();
        // Unreachable - a seeded pool always retains the `MIN_LIQUIDITY` burned
        // to `0xdead` - but `quoteRedeem` guards the same division and only one
        // of the two being defensive invites someone to delete the wrong one.
        // `fullMulDiv` by zero raises `MulDivFailed`, which names nothing.
        if (lpTotal == 0) revert Bad();
        uint256 tokClaim = FixedPointMathLib.fullMulDiv(lpHeld, p.reserve1(), lpTotal);

        // Tokens sitting inside this contract's own LP are not circulating,
        // and so have no claim against it. Everything else does - including
        // the pool's permanently burned minimum, whose claim is unreachable
        // and therefore only ever understates the floor.
        uint256 circulating = LaunchToken(token).totalSupply() - tokClaim;
        if (circulating == 0) revert Bad();

        uint256 lpBurn = FixedPointMathLib.fullMulDiv(lpHeld, amount, circulating);
        if (lpBurn == 0) revert Bad();

        token.safeTransferFrom(msg.sender, address(this), amount);
        // Slippage is checked against the payout below, so the pool's own
        // minimums are left open.
        (uint256 amount0, uint256 amount1) = p.removeLiquidity(lpBurn, 0, 0, address(this));

        // The caller's tokens, plus the ones that came back out of the
        // position - the latter were never circulating, so retiring them is
        // what keeps `C' = C - amount` exact.
        LaunchToken(token).burn(amount + amount1);

        ethOut = amount0;
        if (ethOut < minEthOut || ethOut == 0) revert Slippage();
        to.safeTransferETH(ethOut);
        emit Redeemed(token, to, amount, ethOut);
    }

    /// @notice Sweep a launched token's accrued fees. Permissionless.
    /// @dev THE ETH SIDE SPLITS THREE WAYS: 80% creator, 10% treasury, and a
    ///      10% TITHE burned to Ethereum itself through the canonical BETH
    ///      burner. The tithe is expressed as source constants rather than as
    ///      deployment configuration on purpose - a permanent commitment that
    ///      an operator can repoint is not permanent, and reading this contract
    ///      is meant to tell you where the tenth goes without cross-checking a
    ///      deployment. The cost of that choice is that these addresses are
    ///      mainnet's; this contract is not portable to a chain without them.
    ///
    ///      THE ASYMMETRY WITH `treasury` IS DELIBERATE but is worth naming,
    ///      since it means this contract is not fully self-describing about
    ///      where its ETH goes: the treasury takes the same tenth and IS a
    ///      constructor argument. The two are different kinds of thing. The
    ///      treasury is an operational destination that may legitimately need
    ///      to move - a multisig rotates, an entity changes - and misdirecting
    ///      it harms only its own beneficiary. The tithe is a promise made to
    ///      everyone who ever buys a launched token, and a promise that can be
    ///      repointed is not one. Hardcoding both would be more consistent;
    ///      hardcoding the one that is a commitment is the part that matters.
    ///
    ///      THE TOKEN SIDE IS BURNED ENTIRELY rather than split: it is already
    ///      denominated in the thing being valued, and retiring it raises the
    ///      floor for every holder. That makes the fee partly a buyback that
    ///      needs no buyer.
    function collectFees(address token)
        external
        nonReentrant
        returns (uint256 creatorEth, uint256 protocolEth, uint256 titheEth, uint256 tokensBurned, bool titheRecorded)
    {
        address pool = poolOf[token];
        if (pool == address(0)) revert NoToken();

        (uint256 amount0, uint256 amount1) = PrecisionPool(payable(pool)).collectCreatorFees(address(this));

        tokensBurned = amount1;
        if (amount1 != 0) LaunchToken(token).burn(amount1);

        protocolEth = amount0 * PROTOCOL_BPS / BPS;
        titheEth = amount0 * TITHE_BPS / BPS;
        // The creator takes the remainder rather than a computed share, so the
        // three parts always sum to exactly what the pool paid out. Rounding
        // lands with the creator, which is the only one of the three that can
        // notice a wei.
        creatorEth = amount0 - protocolEth - titheEth;
        // FORCED, not plain `safeTransferETH`. This function is the only way to
        // clear `creatorOwed`, the pool pays both sides of it or neither, and
        // the burn below depends on the token side arriving - so a recipient
        // that reverts on receipt does not merely miss a payment, it wedges the
        // fee stream and the burn permanently, stranding value that is neither
        // in the floor nor collectable by anyone.
        //
        // PrecisionPool avoids this by taking the payee as an argument, which
        // is a lever this contract cannot offer: it must be the pool's own
        // `feeRecipient` for the factory to admit a named market at all, so the
        // destination is fixed here rather than chosen per call. Forcing the
        // transfer restores the same guarantee by a different route - it cannot
        // fail so long as the call is left enough gas to run, which for a
        // hostile recipient means the 100k stipend it will consume plus the
        // ~41k of the `CREATE` fallback behind it. See `_tithe` for the same
        // arithmetic stated in full.
        if (creatorEth != 0) creatorOf[token].forceSafeTransferETH(creatorEth);
        if (protocolEth != 0) treasury.forceSafeTransferETH(protocolEth);
        // Defaults true so a sweep with nothing to tithe does not report a
        // record it never tried to make as having been lost.
        titheRecorded = true;
        if (titheEth != 0) titheRecorded = _tithe(titheEth);

        emit FeesCollected(token, creatorEth, protocolEth, titheEth, tokensBurned, titheRecorded);
    }

    /// @notice Sweep many launched tokens in one transaction. Permissionless.
    /// @dev The counterpart to `collectFees` being per-token. The treasury and
    ///      the tithe accrue across EVERY launch, so whoever collects for them
    ///      faces one transaction per token - which is fine at three launches
    ///      and is not at three hundred. Nothing here changes who is paid; it
    ///      only removes the reason not to bother.
    ///
    ///      FAILURES ARE SKIPPED, NOT REVERTED. A batch is a convenience, and a
    ///      convenience that fails whole because one entry in it is unlaunched,
    ///      duplicated, or momentarily unsweepable is worse than no batch at
    ///      all - the caller cannot tell which entry was at fault without
    ///      bisecting. `swept` reports how many actually cleared, so a caller
    ///      that cares can compare it against what it passed in.
    ///      `allRecorded` is false if ANY swept token's burn failed to mint its
    ///      BETH record. Reported because the batch otherwise hides it: the
    ///      per-token event carries the flag, and a caller sweeping thirty
    ///      tokens should not have to read thirty logs to learn the social
    ///      artifact is missing for one of them.
    function collectFeesMany(address[] calldata tokens)
        external
        returns (
            uint256 swept,
            uint256 creatorEth,
            uint256 protocolEth,
            uint256 titheEth,
            uint256 tokensBurned,
            bool allRecorded
        )
    {
        allRecorded = true;
        for (uint256 i; i < tokens.length; ++i) {
            try this.collectFees(tokens[i]) returns (uint256 c, uint256 p, uint256 t, uint256 b, bool rec) {
                unchecked {
                    ++swept;
                    creatorEth += c;
                    protocolEth += p;
                    titheEth += t;
                    tokensBurned += b;
                }
                if (!rec) allRecorded = false;
            } catch {}
        }
    }

    /// @dev Burn `amount` of ETH through the canonical burner, crediting the
    ///      record to `TITHE_RECORD`.
    ///
    ///      `depositTo` rather than a plain send, and the difference is not
    ///      cosmetic: a plain send credits BETH to `msg.sender`, which here is
    ///      THIS CONTRACT - and this contract has no way to move an ERC-20, so
    ///      the record of every burn would be stranded at the exact address
    ///      least able to use it. Naming the recipient is what turns the burn
    ///      into something the DAO holds rather than something nobody holds.
    ///
    ///      The fallback exists because the tithe must not be able to hold a
    ///      sweep hostage - the same failure class as the forced transfers
    ///      above, and one this contract has already been bitten by once. If
    ///      the burner ever refuses the call, the value is forced to it anyway:
    ///      the RECORD is lost in that case, the BURN is not, which is the
    ///      correct thing to sacrifice of the two.
    ///      THE STIPEND IS PART OF THE FALLBACK, not a gas optimisation. An
    ///      unmetered `call` forwards everything, so a burner that CONSUMES gas
    ///      rather than reverting returns `ok == false` with 1/64 of the
    ///      original left - and `forceSafeTransferETH` then has to CREATE a
    ///      self-destructing contract, which it cannot afford. `collectFees`
    ///      would revert out of gas at EVERY gas limit, because raising the
    ///      limit raises the callee's consumption in proportion. That is the
    ///      wedge this function exists to prevent, reintroduced one layer down.
    ///      Capping the call bounds the callee's consumption absolutely, so
    ///      what is left over is whatever the caller supplied minus the cap.
    ///
    ///      Measured: the live burner's `depositTo` costs well under 100k, so
    ///      the cap is roughly double what the happy path needs and cannot
    ///      cause a spurious fallback.
    ///
    ///      WHAT THE CAP DOES NOT PROMISE. "Cannot fail" is conditional on gas,
    ///      and the threshold is larger than it looks: against a hostile burner
    ///      the fallback pays the 100k stipend `forceSafeTransferETH` attempts
    ///      first - which that same burner also consumes - and then the CREATE
    ///      behind it (32000 + 4400 deposit + 5000 SELFDESTRUCT), so roughly
    ///      141k, on top of this call's own cap. A sweep therefore wants about
    ///      342k remaining here to be guaranteed. That is unremarkable for a
    ///      real `collectFees`, and a caller who supplies less gets a revert and
    ///      re-sends - recoverable, which is the whole difference from the
    ///      unmetered version, where no gas limit worked at all.
    ///
    /// @return recorded Whether the BETH record was actually minted. Returned
    ///         rather than swallowed so `collectFees` can emit it: the fallback
    ///         trades the record for the burn, and a trade nothing observes is
    ///         one nobody can notice has silently started happening - which is
    ///         exactly what a gas repricing that lifts `depositTo` past
    ///         `TITHE_GAS` would do.
    ///      THE CODE CHECK IS NOT REDUNDANT, and the ORDER of it is the whole
    ///      point. A `call` to a CODELESS address succeeds and moves the value,
    ///      so without it `recorded` would be true while no BETH was ever
    ///      minted - and `titheRecorded` exists precisely so an indexer can
    ///      trust that the record landed. Note the naive repair is wrong:
    ///      flipping the flag AFTER a successful call routes into the forced
    ///      transfer below and sends the same ETH a second time, out of
    ///      whatever balance happens to be present. Codelessness has to be
    ///      established before the value moves, not after.
    ///
    ///      Unreachable on mainnet today - post-EIP-6780 a live contract cannot
    ///      lose its code - but the flag is meant to be authoritative and the
    ///      check is one branch.
    function _tithe(uint256 amount) internal returns (bool recorded) {
        if (BETH_BURNER.code.length != 0) {
            (recorded,) =
                BETH_BURNER.call{value: amount, gas: TITHE_GAS}(abi.encodeWithSelector(0xb760faf9, TITHE_RECORD));
        }
        if (!recorded) BETH_BURNER.forceSafeTransferETH(amount);
    }

    /// @notice Reassign a launched token's fee stream. Current holder only.
    /// @dev The counterpart to forcing the transfer above: forcing it means the
    ///      payment always lands, and this means it can be pointed somewhere
    ///      useful when the original address stops being one - a rotated key, a
    ///      project that changed hands, a treasury that moved.
    ///
    ///      It confers nothing over holders. The fee rate is immutable in the
    ///      pool's own address, the LP is unreachable, and supply is fixed, so
    ///      the only thing this address controls is where its own income goes.
    ///
    ///      TWO STEPS, not one. The stream is permanent, has no expiry, and no
    ///      authority sits above it, so a mistyped destination is not a
    ///      recoverable error - it silently redirects every future fee for that
    ///      token forever, and nothing in this design can undo it. A one-step
    ///      handoff would have made the MORE consequential of the token's two
    ///      roles weaker than the less consequential one, since `LaunchToken`
    ///      inherits Solady's two-step `Ownable` for metadata alone.
    ///      Requiring the destination to call `acceptCreator` proves it exists,
    ///      is controlled, and can transact.
    function setCreator(address token, address newCreator) external {
        // Read the holder rather than comparing against the mapping directly:
        // an unlaunched token reads zero, and a bare `msg.sender != creatorOf`
        // would then admit a caller of `address(0)` as the holder of every
        // token that does not exist.
        address held = creatorOf[token];
        if (held == address(0) || msg.sender != held) revert Bad();
        // Zero is permitted here, and only here: it cancels a pending handoff.
        pendingCreatorOf[token] = newCreator;
        emit CreatorHandoffStarted(token, newCreator);
    }

    /// @notice Accept a fee stream offered by its current holder.
    function acceptCreator(address token) external {
        address pending = pendingCreatorOf[token];
        if (pending == address(0) || msg.sender != pending) revert Bad();
        delete pendingCreatorOf[token];
        creatorOf[token] = pending;
        emit CreatorSet(token, pending);
    }

    /// @notice ETH a redemption of `amount` would pay right now.
    /// @dev The solver's entry point: compare against the pool's quote for
    ///      selling the same `amount` and take the larger. Returns zero for an
    ///      unknown token rather than reverting, so a scanner can probe
    ///      cheaply.
    function quoteRedeem(address token, uint256 amount) public view returns (uint256 ethOut) {
        address pool = poolOf[token];
        if (pool == address(0)) return 0;

        PrecisionPool p = PrecisionPool(payable(pool));
        uint256 lpHeld = p.balanceOf(address(this));
        uint256 lpTotal = p.totalSupply();
        if (lpTotal == 0) return 0;

        uint256 circulating =
            LaunchToken(token).totalSupply() - FixedPointMathLib.fullMulDiv(lpHeld, p.reserve1(), lpTotal);
        if (circulating == 0) return 0;

        // Mirrors `redeem` exactly, including the double floor, so a quote can
        // never read high against the settlement.
        uint256 lpBurn = FixedPointMathLib.fullMulDiv(lpHeld, amount, circulating);
        return FixedPointMathLib.fullMulDiv(lpBurn, p.reserve0(), lpTotal);
    }

    /// @notice The floor price, in wei per whole token.
    /// @dev Presentation only - `quoteRedeem` is what settles. Zero before the
    ///      first buy, since the position holds no ETH until then.
    function floorPrice(address token) external view returns (uint256) {
        return quoteRedeem(token, WAD);
    }

    /// @dev Payouts arrive natively from the pool, on `removeLiquidity` and on
    ///      `collectCreatorFees`. Accepting only from pools keeps stray ETH
    ///      from accumulating in a contract that has no way to account for it.
    receive() external payable {
        if (!factory.isPool(msg.sender)) revert Bad();
    }
}
