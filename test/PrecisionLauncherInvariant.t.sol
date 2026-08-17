// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";

/// @dev Stateful coverage, which the launcher had none of.
///
/// The existing fuzz tests are STATELESS: each builds one scenario from a clean
/// launch and checks it. That cannot reach a bug which needs a SEQUENCE - a
/// redemption after a fee sweep after an outside LP joined after a selloff -
/// and sequences are exactly where `PrecisionPool`'s own H-01 lived (see the
/// header of `PrecisionPoolInvariant.t.sol`). The launcher composes four
/// contracts across those sequences, so it has strictly more room for that
/// class of bug than the pool does, and had strictly less coverage of it.
///
/// The handler deliberately includes two ADVERSARIAL actions that are not part
/// of any normal flow - stranding tokens on the launcher, and outside parties
/// providing liquidity - because both change the accounting the floor is
/// derived from without going through any of the launcher's own entry points.
contract Handler is Test {
    PrecisionLauncher public launcher;
    PrecisionPool public pool;
    LaunchToken public token;

    address[] actors;
    uint256 public buys;
    uint256 public sells;
    uint256 public redeems;
    uint256 public sweeps;
    uint256 public strands;

    /// @dev C7's counters. The invariant that claimed to test "the position is
    ///      only ever burned" asserted `balanceOf(launcher) <= totalSupply()`,
    ///      which is true of any ERC-20 by arithmetic, plus that three
    ///      addresses no code path can reach hold nothing. It tested nothing.
    ///
    ///      The claim has two halves and both are checked HERE, per action,
    ///      rather than in the invariant - a counter written by the handler
    ///      survives regardless of how the runner treats state an invariant
    ///      function writes:
    ///
    ///        - the position may NEVER grow, under any action;
    ///        - it may only SHRINK inside `redeem`.
    uint256 public positionGrew;
    uint256 public positionMovedOutsideRedeem;

    /// @param isRedeem Whether shrinking is legitimate for this action.
    modifier watchPosition(bool isRedeem) {
        uint256 lpBefore = pool.balanceOf(address(launcher));
        _;
        uint256 lpAfter = pool.balanceOf(address(launcher));
        if (lpAfter > lpBefore) ++positionGrew;
        if (!isRedeem && lpAfter != lpBefore) ++positionMovedOutsideRedeem;
    }

    constructor(PrecisionLauncher l, PrecisionPool p, LaunchToken t) {
        (launcher, pool, token) = (l, p, t);
        for (uint256 i; i < 3; ++i) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            vm.deal(a, 100_000 ether);
            vm.startPrank(a);
            t.approve(address(p), type(uint256).max);
            t.approve(address(l), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function buy(uint256 seed, uint256 amt) public watchPosition(false) {
        amt = bound(amt, 1, 500 ether);
        address a = _actor(seed);
        vm.prank(a);
        try pool.swapExactIn{value: amt}(address(0), amt, 0, a) {
            ++buys;
        } catch {}
    }

    function sell(uint256 seed, uint256 amt) public watchPosition(false) {
        address a = _actor(seed);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(a);
        try pool.swapExactIn(address(token), amt, 0, a) {
            ++sells;
        } catch {}
    }

    function redeem(uint256 seed, uint256 amt) public watchPosition(true) {
        address a = _actor(seed);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(a);
        try launcher.redeem(address(token), amt, 0, a) {
            ++redeems;
        } catch {}
    }

    function sweep() public watchPosition(false) {
        try launcher.collectFees(address(token)) {
            ++sweeps;
        } catch {}
    }

    /// @dev Adversarial: park tokens where they can never be redeemed. Must be
    ///      conservative for the floor, never inflationary.
    function strand(uint256 seed, uint256 amt) public watchPosition(false) {
        address a = _actor(seed);
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(a);
        try token.transfer(address(launcher), amt) {
            ++strands;
        } catch {}
    }

    /// @dev Adversarial: a third party joins the position the floor is drawn
    ///      from. Claimed to be floor-neutral; this is where that gets tested
    ///      against sequences rather than one deposit.
    function outsideAdd(uint256 seed, uint256 amt) public watchPosition(false) {
        address a = _actor(seed);
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        if (r0 == 0 || r1 == 0) return;
        amt = bound(amt, 1, 50 ether);
        uint256 need = amt * r1 / r0;
        if (need == 0 || need > token.balanceOf(a)) return;
        vm.prank(a);
        try pool.addLiquidityExact{value: amt}(0, amt, need, 0, a) {} catch {}
    }

    function outsideRemove(uint256 seed, uint256 shares) public watchPosition(false) {
        address a = _actor(seed);
        uint256 bal = pool.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(a);
        try pool.removeLiquidity(shares, 0, 0, a) {} catch {}
    }

    // NO `burnVoluntarily` HERE, and its absence is a finding rather than an
    // oversight. It was in this handler, and the first run used it to break
    // `invariant_FloorNeverExceedsMarginalPrice` in three calls: buy, burn 99%,
    // sell the rest. Burning collapses `circulating` without touching the pool,
    // so the floor jumps; the sell then crashes the market underneath it.
    //
    // That is REAL - the ordering genuinely does not hold - but it is not an
    // attack, and keeping it here would have wedged a true invariant behind an
    // untrue one. The burner forfeits their own backing; the profit available
    // afterwards IS that forfeited backing. Measured: an attacker running the
    // whole sequence against a real holder spent 240 ETH to recover 0.39, while
    // the bystander's redeemable value ROSE from 99.5 to 332 ETH.
    //
    // So the behaviour lives in `testExternalBurnLiftsFloorOverMarket` as a
    // documented property with its economics pinned, and the sequences here
    // stay confined to operations that cannot gift value into the position.
}

contract PrecisionLauncherInvariantTest is Test {
    PrecisionPoolFactory factory;
    PrecisionLauncher launcher;
    PrecisionPool pool;
    LaunchToken token;
    Handler handler;

    address creator = address(0xC0FFEE);
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 initialSupply;
    uint256 launcherEthAtStart;
    uint256 lpHeldAtLaunch;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        launcher = new PrecisionLauncher(factory, address(0x7EA));
        launcherEthAtStart = address(launcher).balance;

        (address t, address p) = launcher.launch("INV", "INV", "", SUPPLY, 1_000, 3 ether, creator);
        (token, pool) = (LaunchToken(t), PrecisionPool(payable(p)));
        initialSupply = token.totalSupply();
        lpHeldAtLaunch = pool.balanceOf(address(launcher));

        // Spread the creator allocation so the handler's actors start holding.
        uint256 alloc = token.balanceOf(creator);
        vm.startPrank(creator);
        for (uint256 i; i < 3; ++i) {
            token.transfer(address(uint160(0xA000 + i)), alloc / 3);
        }
        vm.stopPrank();

        handler = new Handler(launcher, pool, token);
        targetContract(address(handler));

        // Pin the sender. Left unrestricted the runner invents thousands of
        // random addresses, and under this repo's global mainnet fork every one
        // is an RPC account lookup - which the public endpoint rate-limits long
        // before the run finishes, surfacing as a bogus test failure. Same
        // reasoning as PrecisionPoolInvariant.
        targetSender(address(0xC0FFEE));
    }

    /// @dev The launcher's own claim on the position, and the supply that may
    ///      redeem against it.
    function _claim() internal view returns (uint256 backing, uint256 circulating) {
        uint256 lpTotal = pool.totalSupply();
        if (lpTotal == 0) return (0, token.totalSupply());
        uint256 lpHeld = pool.balanceOf(address(launcher));
        backing = uint256(pool.reserve0()) * lpHeld / lpTotal;
        circulating = token.totalSupply() - (uint256(pool.reserve1()) * lpHeld / lpTotal);
    }

    /// SOLVENCY, stated against the POOL rather than against itself.
    ///
    /// The first version of this compared `quoteRedeem(circulating)` to
    /// `backing` and was very nearly a tautology - `quoteRedeem` of the whole
    /// circulating supply reduces to `lpHeld * r0 / lpTotal`, which is exactly
    /// what `backing` computes. It passed 128,000 calls and proved almost
    /// nothing, which is worse than having no invariant at all: it was cited as
    /// evidence the position was solvent while a different invariant was
    /// failing in the same run.
    ///
    /// The claim has to be anchored to something the launcher does not derive.
    /// The pool's real ETH reserve is that anchor: whatever the launcher thinks
    /// it can pay must be covered by ETH the pool actually holds.
    ///
    /// A SECOND TAUTOLOGY LIVED HERE until an audit pointed it out, which is
    /// worth recording given the paragraph above. `backing` is
    /// `reserve0 * lpHeld / lpTotal` and the assertion was
    /// `backing <= reserve0` - true for any `lpHeld <= lpTotal`, i.e. always,
    /// by arithmetic rather than by anything the launcher does. The docstring
    /// explaining the removal of the first tautology sat directly above the
    /// second one. It is replaced by the question that actually has content:
    /// what the launcher would pay to redeem EVERYTHING must be covered by ETH
    /// the pool really holds.
    function invariant_BackingIsCoveredByRealReserves() public view {
        (, uint256 circulating) = _claim();
        if (circulating != 0) {
            assertLe(
                launcher.quoteRedeem(address(token), circulating),
                address(pool).balance,
                "total claims exceed the pool's real ETH"
            );
        }
        assertLe(uint256(pool.reserve0()), address(pool).balance, "pool reserve is unbacked");
    }

    /// Redemption must remain floor-neutral across arbitrary sequences - the
    /// property every other guarantee rests on, and one no single-operation
    /// test can establish.
    function invariant_RedemptionStaysFloorNeutral() public view {
        (uint256 backing, uint256 circulating) = _claim();
        if (circulating == 0 || backing == 0) return;
        uint256 whole = launcher.quoteRedeem(address(token), 1e18);
        uint256 tenth = launcher.quoteRedeem(address(token), 1e17);
        // Ten dust redemptions must not beat one whole - rounding may only ever
        // favour the position.
        assertLe(tenth * 10, whole + 10, "splitting a redemption extracted more");
    }

    /// The floor stays under the pool's marginal price FOR TRADING SEQUENCES.
    ///
    /// This is the invariant the first run broke, and the qualifier is the
    /// whole finding: it holds for buying, selling, redeeming, sweeping and
    /// outside liquidity, and it does NOT hold once supply is burned outside
    /// redemption. See the note where `burnVoluntarily` used to live, and
    /// `testExternalBurnLiftsFloorOverMarket` for the case it excludes.
    function invariant_FloorStaysUnderMarketForTradingSequences() public view {
        uint256 lpTotal = pool.totalSupply();
        if (lpTotal == 0) return;
        uint256 x = lpTotal * 1e18 / pool.sqrtPHigh() + pool.reserve0();
        uint256 y = lpTotal * pool.sqrtPLow() / 1e18 + pool.reserve1();
        if (y == 0) return;
        assertLe(launcher.floorPrice(address(token)), x * 1e18 / y, "floor overtook the marginal price");
    }

    /// Supply is fixed at construction and only ever falls. No sequence of
    /// redemptions, sweeps or burns may mint.
    function invariant_SupplyOnlyEverFalls() public view {
        assertLe(token.totalSupply(), initialSupply, "supply grew");
    }

    /// The launcher is a conduit, not a vault: it must never accumulate ETH.
    /// Tokens it MAY hold - anyone can send them - but never as a balance it
    /// created itself.
    function invariant_LauncherAccumulatesNoEth() public view {
        assertEq(address(launcher).balance, launcherEthAtStart, "launcher accumulated ETH");
    }

    /// The position is locked. No sequence may move the launcher's LP shares
    /// except by burning them through a redemption.
    function invariant_PositionIsOnlyEverBurned() public view {
        assertEq(handler.positionGrew(), 0, "the locked position grew");
        assertEq(handler.positionMovedOutsideRedeem(), 0, "the position moved outside a redemption");
    }

    /// Redemption must be the only thing that consumes the position, and it
    /// must consume it monotonically. Stated against the launch snapshot so it
    /// holds over the WHOLE sequence, not just call to call.
    function invariant_PositionNeverExceedsItsLaunchSize() public view {
        assertLe(pool.balanceOf(address(launcher)), lpHeldAtLaunch, "position exceeds what the launch minted");
    }

    /// The template is immutable, and no sequence of operations may edit it.
    function invariant_TemplateNeverChanges() public view {
        assertEq(pool.fee(), 10_000);
        assertEq(pool.creatorFeeBps(), 5_000);
        assertEq(pool.hook(), address(0));
        assertEq(pool.feeRecipient(), address(launcher));
        assertEq(pool.sqrtPLow(), pool.sqrtPHigh() / 1e6);
        assertEq(launcher.poolOf(address(token)), address(pool));
    }

    /// From the external review, which derived it and noted nothing asserted
    /// it: the launcher can never burn its ENTIRE position, and the bound is
    /// tight. `amount <= balanceOf(caller) <= S - balanceOf(pool) <= S - r1`,
    /// while `C = S - h*r1/T > S - r1` strictly, because `h < T` forever - the
    /// pool burns `MIN_LIQUIDITY` to `0xdead` at seed and it never returns. So
    /// `lpBurn = floor(h*amount/C) < h` always.
    ///
    /// Two consequences worth pinning: `_burn(launcher, lpBurn)` can never
    /// revert for insufficient balance, and redemption alone can never drive
    /// the pool toward `MIN_LIQUIDITY` - it approaches geometrically and never
    /// arrives. That is the cleanest answer to the band-excursion question the
    /// audit brief ranked as risk #1.
    function invariant_PositionCanNeverBeFullyBurned() public view {
        if (token.totalSupply() == 0) return;
        assertGt(pool.balanceOf(address(launcher)), 0, "the position was fully burned");
        assertGt(pool.totalSupply(), 0, "pool supply reached zero");
    }

    function invariant_CallSummary() public view {
        console2.log("buys     ", handler.buys());
        console2.log("sells    ", handler.sells());
        console2.log("redeems  ", handler.redeems());
        console2.log("sweeps   ", handler.sweeps());
        console2.log("strands  ", handler.strands());
    }
}
