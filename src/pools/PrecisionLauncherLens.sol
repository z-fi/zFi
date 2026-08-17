// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";
import {PrecisionPoolFactory} from "./PrecisionPoolFactory.sol";
import {LaunchToken, PrecisionLauncher} from "./PrecisionLauncher.sol";
import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";

/// @title PrecisionLauncherLens
/// @notice Read-only reader for zSwap-launched tokens. Intended for `eth_call`
///         only - not meant to be called on-chain in transactions.
///
/// @dev WHY THIS EXISTS, given the factory already indexes everything.
///
///      Most of a launch IS discoverable through `PrecisionPoolLens`, and by a
///      route worth stating because it looks like an accident and is not. The
///      factory indexes pools under `_byCreator[feeRecipient]`, and the launcher
///      MUST be the fee recipient of every market it opens - the factory admits
///      a named market only from the recipient itself. So
///      `marketsForCreator(launcher, ...)` already enumerates every launch, in
///      order, paginated. The constraint that forced the launcher into that
///      role is the same one that made it a registry.
///
///      Three things that route cannot give you, which is what this file is:
///
///      1. THE REAL CREATOR. Every launched pool reports the LAUNCHER as its
///         `feeRecipient`, so `marketsForCreator(someone)` returns nothing for
///         the person who actually launched. Creator-keyed discovery is not
///         merely missing, it is WRONG through the factory index - the launcher
///         holds the true owner in `creatorOf`, and only it can answer "show me
///         my launches".
///
///      2. THE FLOOR. `PoolInfo` describes a market; it has no idea redemption
///         exists. The floor is the number this product is actually about, and
///         reading it per token is a call per token.
///
///      3. THE TOKEN ITSELF. Name, symbol, and the ERC-7572 `contractURI` the
///         creator can edit. `PoolInfo` carries addresses.
///
///      The alternative was a reverse index inside the launcher, which would
///      charge storage on every launch to serve a question only an off-chain
///      reader ever asks. This costs nothing at launch time.
///
///      PRICES ARE MARGINAL AND FEE-FREE, in wei per WHOLE token, so
///      `marketPrice` and `floorPrice` are directly comparable - their ratio is
///      the premium the market is paying over backing. Neither is executable:
///      for a number to trade against, quote the size through
///      `PrecisionPoolLens`, which applies the fee and the curve.
contract PrecisionLauncherLens {
    uint256 constant WAD = 1e18;

    /// @notice Everything about one launch, in one read.
    struct LaunchInfo {
        address token;
        address pool;
        /// @notice Who collects the creator fee. NOT the pool's `feeRecipient`,
        ///         which is always the launcher.
        address creator;
        /// @notice Who may edit `contractURI`. Zero once renounced, and
        ///         independent of `creator`.
        address owner;
        string name;
        string symbol;
        /// @notice ERC-7572 metadata. POPULATED ONLY BY THE SINGULAR VIEWS -
        ///         `infoFor` and `infoForPool` - and left empty by `launches`
        ///         and `launchesForCreator`.
        /// @dev Not an oversight, and not a saving worth having on gas grounds
        ///      alone. Once a creator stores an image, `contractURI()` assembles
        ///      an inline `data:` document: the image is read from SSTORE2 and
        ///      base64'd, then the whole JSON is base64'd again, which is around
        ///      44 KB of returned string for a full-size image. Building that
        ///      once per entry inside a page - with memory expansion quadratic
        ///      in the total - lets ONE creator make every page containing their
        ///      token too expensive to `eth_call`, and a caller cannot page past
        ///      it, only shrink `count` and step around it. The lens's whole
        ///      purpose is enumeration, so that is a griefing vector on the
        ///      thing it exists to do.
        ///
        ///      It is also the right shape regardless: a grid wants names,
        ///      symbols and floors, and the detail view is where a 44 KB
        ///      document belongs. Read it per token with `infoFor`.
        string contractURI;
        /// @notice Live supply. Falls as redemptions and fee burns retire it.
        uint256 totalSupply;
        /// @notice Supply outside the locked position - what may be redeemed.
        uint256 circulating;
        /// @notice ETH the locked position would release in full.
        uint256 backingEth;
        /// @notice Wei per whole token at redemption. Zero before the first buy.
        uint256 floorPrice;
        /// @notice Wei per whole token at the pool's marginal price, before
        ///         fees. Zero if the pool holds no token side at all.
        uint256 marketPrice;
        uint256 reserve0;
        uint256 reserve1;
        /// @notice LP shares held by the launcher, which cannot spend them.
        uint256 lpHeld;
        /// @notice The creator's allocation at launch, in bps of supply.
        uint256 allocBps;
        /// @notice Fully diluted valuation at the pool's marginal price.
        /// @dev NOT the same as the launch's `startMcapWei`, which values only
        ///      the POOLED supply - the difference is exactly the allocation,
        ///      and conflating them understates dilution.
        uint256 fullyDilutedWei;
        /// @notice ETH accrued and awaiting `collectFees`, before the split.
        uint256 pendingFeeEth;
        /// @notice Tokens accrued and awaiting `collectFees`, all of which burn.
        uint256 pendingBurn;
    }

    PrecisionLauncher public immutable launcher;
    PrecisionPoolFactory public immutable factory;

    error Bad();

    constructor(PrecisionLauncher launcher_) {
        if (address(launcher_).code.length == 0) revert Bad();
        launcher = launcher_;
        factory = launcher_.factory();
    }

    // ------------------------------------------------------------ ENUMERATION

    /// @notice Total launches ever made by this launcher.
    function launchCount() public view returns (uint256) {
        return factory.poolsForCreatorCount(address(launcher));
    }

    /// @notice A page of launches, oldest first.
    /// @dev `count` is capped by the factory's own page limit. `contractURI` is
    ///      left empty on every entry - see the field's own note for why a page
    ///      must not assemble it.
    function launches(uint256 start, uint256 count) external view returns (LaunchInfo[] memory out) {
        address[] memory pools = factory.poolsForCreatorSlice(address(launcher), start, count);
        out = new LaunchInfo[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            out[i] = _infoForPool(pools[i], false);
        }
    }

    /// @notice A page of launches filtered to those `creator` collects fees on.
    /// @dev The question `marketsForCreator` cannot answer - see the header.
    ///      Filtering happens within the page, so a page may return fewer than
    ///      `count` entries (or none) without meaning the list has ended. Page
    ///      until `start` reaches `launchCount()`.
    function launchesForCreator(address creator, uint256 start, uint256 count)
        external
        view
        returns (LaunchInfo[] memory out)
    {
        address[] memory pools = factory.poolsForCreatorSlice(address(launcher), start, count);

        uint256 n;
        LaunchInfo[] memory buf = new LaunchInfo[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            LaunchInfo memory info = _infoForPool(pools[i], false);
            if (info.creator == creator) buf[n++] = info;
        }

        out = new LaunchInfo[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = buf[i];
        }
    }

    // --------------------------------------------------------------- SINGULAR

    /// @notice Describe one launch by its token.
    /// @dev Returns an empty struct for anything this launcher did not launch,
    ///      rather than reverting, so a caller can probe an unknown address.
    function infoFor(address token) public view returns (LaunchInfo memory o) {
        address pool = launcher.poolOf(token);
        if (pool == address(0)) return o;
        return _describe(token, pool, true);
    }

    /// @notice Describe one launch by its pool.
    /// @dev The launched token is always `token1`, since ETH is `address(0)`
    ///      and sorts first. The round trip back through `poolOf` is what makes
    ///      an empty struct - rather than nonsense - the answer for a pool this
    ///      launcher did not open.
    function infoForPool(address pool) public view returns (LaunchInfo memory o) {
        return _infoForPool(pool, true);
    }

    // ---------------------------------------------------------------- READING

    /// @param withUri Whether to assemble `contractURI`. False from the paged
    ///        views, which must not build a per-entry inline document.
    function _infoForPool(address pool, bool withUri) internal view returns (LaunchInfo memory o) {
        if (!factory.isPool(pool)) return o;
        address token = PrecisionPool(payable(pool)).token1();
        if (launcher.poolOf(token) != pool) return o;
        return _describe(token, pool, withUri);
    }

    function _describe(address token, address pool, bool withUri) internal view returns (LaunchInfo memory o) {
        PrecisionPool p = PrecisionPool(payable(pool));
        LaunchToken t = LaunchToken(token);

        o.token = token;
        o.pool = pool;
        o.creator = launcher.creatorOf(token);
        o.allocBps = launcher.allocBpsOf(token);
        o.owner = t.owner();
        o.name = t.name();
        o.symbol = t.symbol();
        if (withUri) o.contractURI = t.contractURI();

        o.totalSupply = t.totalSupply();
        o.reserve0 = p.reserve0();
        o.reserve1 = p.reserve1();
        o.lpHeld = p.balanceOf(address(launcher));
        o.pendingFeeEth = p.creatorOwed0();
        o.pendingBurn = p.creatorOwed1();

        uint256 lpTotal = p.totalSupply();
        if (lpTotal == 0) return o;

        // The launcher's own claim. Everything else in the pool belongs to
        // outside LPs and is not backing for redemption.
        uint256 tokClaim = FixedPointMathLib.fullMulDiv(o.lpHeld, o.reserve1, lpTotal);
        o.backingEth = FixedPointMathLib.fullMulDiv(o.lpHeld, o.reserve0, lpTotal);
        o.circulating = o.totalSupply - tokClaim;

        // Straight from the launcher rather than recomputed here, so a quote
        // this lens shows can never disagree with what settles.
        o.floorPrice = launcher.quoteRedeem(token, WAD);

        // Marginal price from the full curve, virtual reserves included. Both
        // scale with LP supply, which is why they belong in a price and not in
        // the backing above.
        uint256 x = FixedPointMathLib.fullMulDiv(lpTotal, WAD, p.sqrtPHigh()) + o.reserve0;
        uint256 y = FixedPointMathLib.fullMulDiv(lpTotal, p.sqrtPLow(), WAD) + o.reserve1;
        if (y != 0) {
            o.marketPrice = FixedPointMathLib.fullMulDiv(x, WAD, y);
            o.fullyDilutedWei = FixedPointMathLib.fullMulDiv(o.totalSupply, o.marketPrice, WAD);
        }
    }
}
