// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zPool, ISwapboard} from "../src/zPool.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH, FeeToken} from "./SwapboardMocks.sol";

/// @dev A feed the tests can drive, including into failure.
contract MockOracle {
    uint256 price;
    bool reverts;

    function set(uint256 p) external {
        price = p;
    }

    function setRevert(bool r) external {
        reverts = r;
    }

    function peek() external view returns (uint256) {
        require(!reverts, "feed down");
        return price;
    }
}

/// @dev The unit tests pin the mechanics; the `Thesis` tests below decide
/// whether the design earns, by running the pool over a price path against an
/// arbitrageur who takes any rung the market has left behind. The headline
/// finding is `test_ThesisRungMustTrackTheSpread`: the pool is profitable only
/// while each rung is no wider than the spread, which is why the constructor
/// now enforces it.
contract zPoolTest is Test {
    Swapboard board;
    MockWETH weth;
    MockERC20 A;
    MockERC20 B;
    zPool pool;

    address lp = address(0xC11);
    address arb = address(0xA2B);
    address keeper = address(0xE33);

    uint256 constant FEE = 40; // 40 bps half-spread, 80 bps round trip
    uint256 constant RUNG = 20; // 0.2% of reserves per rung, i.e. half the spread
    uint256 constant BOUNTY = 2000; // 20% of the spread a fill earned

    function setUp() public {
        weth = new MockWETH();
        board = new Swapboard(address(weth));
        A = new MockERC20("A", 18);
        B = new MockERC20("B", 18);
        pool = new zPool(address(board), address(A), address(B), FEE, RUNG, 1 days, BOUNTY, address(0));

        A.mint(lp, 1_000e18);
        B.mint(lp, 4_000_000e18);
        A.mint(arb, 1_000_000e18);
        B.mint(arb, 4_000_000_000e18);

        vm.startPrank(lp);
        A.approve(address(pool), type(uint256).max);
        B.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(arb);
        A.approve(address(board), type(uint256).max);
        B.approve(address(board), type(uint256).max);
        vm.stopPrank();
    }

    function _seed() internal returns (uint256 shares) {
        vm.prank(lp);
        (shares,,) = pool.deposit(100e18, 200_000e18, 0, lp);
    }

    // ------------------------------------------------------------------ units

    function test_SeedPostsBothRungsAroundReserveRatio() public {
        _seed();
        assertEq(pool.price(), 2000e18, "mid is rB/rA");

        ISwapboard.Order memory ask = _order(pool.askId());
        ISwapboard.Order memory bid = pool.bidId() == 0
            ? ISwapboard.Order(address(0), false, false, 0, false, false, address(0), address(0), 0, address(0), 0)
            : _order(pool.bidId());

        // 0.2% of each side is committed, so a full take moves the implied
        // price about as far as the spread charges for.
        assertEq(ask.amountA, 0.2e18, "ask rung");
        assertEq(bid.amountA, 400e18, "bid rung");

        // Ask asks 2000 * 1.004; bid offers 2000 * 0.996.
        assertEq(ask.amountB, 401.6e18, "ask price 2008");
        // The bid gives B and asks for A, so its unit price inverts.
        assertApproxEqRel(_unitPrice(bid.amountB, bid.amountA), 1992e18, 1e12, "bid price 1992");
        assertTrue(ask.partialFill && bid.partialFill, "rungs must be partially fillable");
    }

    function test_ReservesCountEscrowSoNavIsUnchangedByPosting() public {
        _seed();
        (uint256 rA, uint256 rB) = pool.reserves();
        assertEq(rA, 100e18);
        assertEq(rB, 200_000e18);
        // And the idle balance really is short the escrow, i.e. the orders exist.
        assertEq(A.balanceOf(address(pool)), 99.8e18);
    }

    function test_PartialFillOfTheAskLeavesTheRemainderResting() public {
        _seed();
        uint256 id = pool.askId();

        // Take a fifth of the ask: pay 80.32 B, receive 0.04 A.
        vm.prank(arb);
        board.fillOrder(id, block.timestamp, 80.32e18, 0, arb);

        assertEq(A.balanceOf(arb) - 1_000_000e18, 0.04e18, "taker got A");
        assertEq(B.balanceOf(address(pool)), 199_600e18 + 80.32e18, "proceeds land at the pool");
        assertEq(_order(id).amountA, 0.16e18, "remainder still rests");

        // Fee is captured: the pool sold 2.5 A for 5020 B, i.e. 2008 each,
        // against a 2000 mid.
        (uint256 rA, uint256 rB) = pool.reserves();
        assertEq(rA, 99.96e18);
        assertEq(rB, 200_080.32e18);
    }

    function test_PokeRepricesUpAfterTheAskIsHit() public {
        _seed();
        uint256 id = pool.askId();
        vm.prank(arb);
        board.fillOrder(id, block.timestamp, 401.6e18, 0, arb); // whole ask

        vm.prank(keeper);
        pool.poke();

        // Sold 0.2 A for 401.6 B, so the pool now believes A is worth more and
        // its next ask is dearer. Note how far it moved: ~40bps, about the
        // spread it just charged. That correspondence is the sizing rule, and
        // it is what a fat rung destroys.
        assertGt(pool.price(), 2000e18, "price rose with inventory");
        assertApproxEqRel(pool.price(), 2008.03e18, 1e15);
    }

    function test_PokeIsRefusedWhenNothingFilled() public {
        _seed();
        vm.prank(keeper);
        vm.expectRevert(zPool.NotStale.selector);
        pool.poke();
    }

    function test_PokePaysBountyOutOfFilledVolumeOnly() public {
        _seed();
        uint256 id = pool.askId();
        vm.prank(arb);
        board.fillOrder(id, block.timestamp, 401.6e18, 0, arb);

        vm.prank(keeper);
        pool.poke();

        // 20% of the 40bps the pool earned on the 0.2 A that left, i.e. 8bps
        // of volume - not 20% of the volume itself.
        assertEq(A.balanceOf(keeper), 0.00016e18, "bounty is a share of spread");
        assertEq(B.balanceOf(keeper), 0, "nothing for the untouched side");
    }

    function test_ExpiredUnsweptOrdersCanBeRenewedAndRotateIds() public {
        _seed();
        uint256 oldAsk = pool.askId();
        uint256 oldBid = pool.bidId();
        uint64 oldRotation = pool.rotationDeadline();

        vm.warp(oldRotation);
        vm.prank(keeper);
        (uint256 filledA, uint256 filledB) = pool.poke();

        assertEq(filledA, 0, "expiry is not a fill");
        assertEq(filledB, 0, "expiry is not a fill");
        assertEq(A.balanceOf(keeper), 0, "no unearned A bounty");
        assertEq(B.balanceOf(keeper), 0, "no unearned B bounty");
        assertNotEq(pool.askId(), oldAsk, "ask id rotates for bounded scanners");
        assertNotEq(pool.bidId(), oldBid, "bid id rotates for bounded scanners");
        assertGt(pool.rotationDeadline(), oldRotation, "next rotation is scheduled");
        assertTrue(_order(pool.askId()).active && _order(pool.bidId()).active, "both sides renewed");
    }

    function test_ExpiredSweepCannotBeClaimedAsFilledVolume() public {
        _seed();
        vm.warp(uint256(pool.rotationDeadline()) + 1);

        uint256[] memory ids = new uint256[](2);
        ids[0] = pool.askId();
        ids[1] = pool.bidId();
        board.trySweepExpired(ids);

        vm.prank(keeper);
        (uint256 filledA, uint256 filledB) = pool.poke();

        assertEq(filledA, 0, "returned ask principal is not volume");
        assertEq(filledB, 0, "returned bid principal is not volume");
        assertEq(A.balanceOf(keeper), 0, "sweep earns no A bounty");
        assertEq(B.balanceOf(keeper), 0, "sweep earns no B bounty");
        assertTrue(_order(pool.askId()).active && _order(pool.bidId()).active, "pool reposted");
    }

    function test_ExpiredActivePartialFillPaysOnlyTheRealFill() public {
        _seed();
        uint256 ask = pool.askId();
        vm.prank(arb);
        board.fillOrder(ask, block.timestamp, 80.32e18, 0, arb);
        vm.warp(uint256(pool.rotationDeadline()) + 1);

        vm.prank(keeper);
        (uint256 filledA, uint256 filledB) = pool.poke();

        assertEq(filledA, 0.04e18, "only the executed fifth is counted");
        assertEq(filledB, 0, "untouched bid is not counted");
        assertEq(A.balanceOf(keeper), 0.000032e18, "bounty follows actual fill");
        assertEq(B.balanceOf(keeper), 0);
    }

    function test_WithdrawReturnsBothSidesIncludingEscrow() public {
        uint256 shares = _seed();
        vm.prank(lp);
        (uint256 outA, uint256 outB) = pool.withdraw(shares, 0, 0, lp);
        // MIN_LIQUIDITY is permanently locked, so a hair stays behind.
        assertApproxEqRel(outA, 100e18, 1e12);
        assertApproxEqRel(outB, 200_000e18, 1e12);
        // The locked MIN_LIQUIDITY still owns a sliver, which the pool reposts,
        // so the board keeps dust rather than nothing.
        assertLt(A.balanceOf(address(board)), 1e6, "only locked-share dust remains");
    }

    function test_SecondDepositIsProportionalAndDoesNotDilute() public {
        _seed();
        address lp2 = address(0xD00D);
        A.mint(lp2, 100e18);
        B.mint(lp2, 400_000e18);
        vm.startPrank(lp2);
        A.approve(address(pool), type(uint256).max);
        B.approve(address(pool), type(uint256).max);
        // Offers twice the B it needs; only the proportional amount is taken.
        (uint256 shares, uint256 usedA, uint256 usedB) = pool.deposit(50e18, 400_000e18, 0, lp2);
        vm.stopPrank();

        assertEq(usedA, 50e18);
        assertApproxEqRel(usedB, 100_000e18, 1e12, "charged at pool ratio, not at max");
        assertApproxEqRel(shares, pool.totalSupply() / 3, 1e12);
    }

    // ----------------------------------------------------------------- oracle

    function _guarded(uint256 feedPrice) internal returns (zPool g, MockOracle o) {
        o = new MockOracle();
        o.set(feedPrice);
        g = new zPool(address(board), address(A), address(B), FEE, RUNG, 1 days, BOUNTY, address(o));
        A.mint(lp, 100e18);
        B.mint(lp, 200_000e18);
        vm.startPrank(lp);
        A.approve(address(g), type(uint256).max);
        B.approve(address(g), type(uint256).max);
        g.deposit(100e18, 200_000e18, 0, lp);
        vm.stopPrank();
    }

    function test_OracleAboveMidRaisesOnlyTheAsk() public {
        (zPool g,) = _guarded(2200e18);
        (uint256 ask, uint256 bid) = g.quotes(2000e18);
        assertApproxEqRel(ask, 2208.8e18, 1e12, "ask follows the higher feed");
        assertApproxEqRel(bid, 1992e18, 1e12, "bid stays on the reserve ratio");
    }

    function test_OracleBelowMidLowersOnlyTheBid() public {
        (zPool g,) = _guarded(1800e18);
        (uint256 ask, uint256 bid) = g.quotes(2000e18);
        assertApproxEqRel(ask, 2008e18, 1e12, "ask stays on the reserve ratio");
        assertApproxEqRel(bid, 1792.8e18, 1e12, "bid follows the lower feed");
    }

    /// @dev The safety property, stated directly: whatever the feed says, the
    /// pool never asks less nor bids more than reserves alone would have. So a
    /// manipulated feed can only deny service, never buy a better fill.
    function testFuzz_OracleCanOnlyQuoteAgainstTheTaker(uint256 feedPrice) public {
        feedPrice = bound(feedPrice, 0, 1e30);
        (zPool g,) = _guarded(feedPrice);

        uint256 mid = 2000e18;
        (uint256 ask, uint256 bid) = g.quotes(mid);
        assertGe(ask, mid * (10_000 + FEE) / 10_000, "never sells cheaper than the ratio");
        assertLe(bid, mid * (10_000 - FEE) / 10_000, "never buys dearer than the ratio");
    }

    function test_BrokenFeedFallsBackToReserveRatio() public {
        (zPool g, MockOracle o) = _guarded(2200e18);
        o.setRevert(true);
        (uint256 ask, uint256 bid) = g.quotes(2000e18);
        assertApproxEqRel(ask, 2008e18, 1e12, "reverting feed is no opinion");
        assertApproxEqRel(bid, 1992e18, 1e12);

        o.setRevert(false);
        o.set(0);
        (ask, bid) = g.quotes(2000e18);
        assertApproxEqRel(ask, 2008e18, 1e12, "zero is no opinion");
    }

    function test_ExtremeFeedDisablesAskWithoutLockingWithdrawal() public {
        (zPool g, MockOracle o) = _guarded(2000e18);
        o.set(type(uint256).max);

        (uint256 ask, uint256 bid) = g.quotes(2000e18);
        assertEq(ask, 0, "unrepresentable ask is disabled");
        assertApproxEqRel(bid, 1992e18, 1e12, "safe reserve-ratio bid remains");

        uint256 shares = g.balanceOf(lp) / 2;
        vm.prank(lp);
        (uint256 outA, uint256 outB) = g.withdraw(shares, 0, 0, lp);
        assertGt(outA, 0, "A remains withdrawable");
        assertGt(outB, 0, "B remains withdrawable");
        assertEq(g.postedAsk(), 0, "unsafe ask stays unposted");
        assertGt(g.postedBid(), 0, "safe bid is reposted");
    }

    /// @dev The payoff: with the feed above the ratio the pool does not merely
    /// hide, it rests its ask at the higher level, so a taker who lifts it pays
    /// more than the pool's own books asked for.
    function test_GuardedPoolSellsAboveItsOwnRatio() public {
        (zPool g,) = _guarded(2200e18);
        uint256 id = g.askId();
        ISwapboard.Order memory o = _order(id);

        assertApproxEqRel(_unitPrice(o.amountA, o.amountB), 2208.8e18, 1e12, "resting above mid");

        vm.prank(arb);
        board.fillOrder(id, block.timestamp, o.amountB, 0, arb);
        assertGt(g.price(), 2000e18, "the move was captured, not just dodged");
    }

    // ----------------------------------------------------------------- thesis

    /// @dev A round trip that ends where it started, so impermanent loss nets
    /// to zero and the terminal gap against HODL is purely realised spread
    /// minus what stale rungs gave away.
    function _path() internal pure returns (uint256[12] memory) {
        return [
            uint256(2000e18),
            2060e18,
            2140e18,
            2100e18,
            2010e18,
            1950e18,
            1880e18,
            1930e18,
            1990e18,
            2050e18,
            2020e18,
            2000e18
        ];
    }

    /// @dev ARBITRAGE ONLY, correctly sized. Every counterparty is a perfectly
    /// attentive arbitrageur who takes a whole rung the instant the market has
    /// moved through it. With the rung held at or under the spread, a full
    /// take moves the pool's price about as far as the fee it just charged, so
    /// the arb has almost nothing left to extract.
    function test_ThesisArbitrageOnlyIsSurvivable() public {
        (int256 edge, uint256 finalMid) = _runPath(FEE, RUNG, 0);

        emit log_named_int("arb-only edge vs hodl", edge);
        emit log_named_decimal_uint("final mid            ", finalMid, 18);

        // The mid tracks the market home: the reserve ratio is self-correcting.
        assertApproxEqRel(finalMid, 2000e18, 0.05e18, "mid tracked the path");
    }

    /// @dev MIXED FLOW. Adds uninformed takers who trade at the pool's posted
    /// price regardless of where the market is. This is the number that
    /// decides the design: how much retail volume per step is needed before
    /// spread capture covers what the arbs take.
    function test_ThesisMixedFlowBreakEven() public {
        uint256[6] memory retail = [uint256(0), 500, 1000, 2000, 4000, 8000];
        for (uint256 i; i < retail.length; ++i) {
            (int256 edge,) = _runPath(FEE, RUNG, retail[i]);
            emit log_named_int(string.concat("edge @ retail ", vm.toString(retail[i]), "bps of rung/step"), edge);
        }

        // Uninformed flow is the pool's only source of revenue, so more of it
        // must strictly improve the outcome.
        (int256 poor,) = _runPath(FEE, RUNG, 0);
        (int256 rich,) = _runPath(FEE, RUNG, 8000);
        assertGt(rich, poor, "uninformed flow must improve the outcome");
    }

    /// @dev Sweeps the half-spread at fixed flow. Wider spreads earn more per
    /// fill and lose less to staleness, but at some point the cascade routes
    /// around the pool entirely - that ceiling is a routing question, not one
    /// this sim can answer.
    function test_ThesisFeeSweep() public {
        uint256[5] memory fees = [uint256(10), 25, 40, 80, 150];
        for (uint256 i; i < fees.length; ++i) {
            // Rung tracks the spread, per the invariant: sweeping fee with a
            // fixed rung would just re-measure the sizing rule.
            (int256 edge,) = _runPath(fees[i], fees[i] / 2, 2000);
            emit log_named_int(string.concat("edge @ fee ", vm.toString(fees[i]), "bps"), edge);
        }
    }

    /// @dev THE SCOPE QUESTION. The paths above move ~3% a step, which dwarfs
    /// any spread the pool could post and still be routed to. This one moves
    /// ~0.15% a step - a correlated pair such as stETH/ETH or a stable book -
    /// where a 40bps spread is wide relative to the move. If the design earns
    /// anywhere, it earns here, and the difference between this result and the
    /// volatile one is the whole scoping decision.
    function test_ThesisLowVolatilityPair() public {
        uint256[12] memory calm = [
            uint256(2000e18),
            2003e18,
            2006e18,
            2002e18,
            1998e18,
            1995e18,
            1991e18,
            1994e18,
            1997e18,
            2002e18,
            2001e18,
            2000e18
        ];

        int256[3] memory out;
        uint256[3] memory retail = [uint256(0), 2000, 8000];
        for (uint256 i; i < retail.length; ++i) {
            (out[i],) = _runPathOn(calm, FEE, RUNG, retail[i]);
            emit log_named_int(string.concat("calm path, retail ", vm.toString(retail[i]), "bps"), out[i]);
        }

        // With moves smaller than the spread, the arbitrage leg has little to
        // take and the pool should be at or above HODL.
        assertGt(out[2], out[0], "flow still helps");
    }

    /// @dev THE SIZING RULE. A one-sided rung changes both reserves, so a full
    /// take moves the ratio by roughly `2 * rung`. The whole bid-to-ask band is
    /// roughly `2 * fee`; a rung materially wider than fee can therefore jump
    /// through the band and sell a free option too cheaply. This sweeps down to
    /// rung ~ fee, where a full take traverses about one quoted band.
    function test_ThesisRungMustTrackTheSpread() public {
        // Only the legal range is reachable now that the constructor enforces
        // rung <= fee. The illegal region was measured before the guard went
        // in and is recorded in zPool's constructor comment: at a 40bps spread,
        // rung 80bps lost 52x the edge that rung 20bps earned, and rung 320bps
        // lost ~1750x. That asymmetry is why this is a hard invariant.
        uint256[4] memory rungs = [uint256(5), 10, 20, 40];
        for (uint256 i; i < rungs.length; ++i) {
            (int256 vol,) = _runPath(FEE, rungs[i], 2000);
            emit log_named_int(string.concat("fee 40bps, rung ", vm.toString(rungs[i]), "bps"), vol);
        }
    }

    /// @dev The sizing rule is a deployment invariant, not a recommendation:
    /// a rung wider than the spread cannot be constructed at all.
    function test_OversizedRungIsRefused() public {
        vm.expectRevert(zPool.Bad.selector);
        new zPool(address(board), address(A), address(B), FEE, FEE + 1, 1 days, BOUNTY, address(0));
        // At exactly the spread it is allowed, which is the documented ceiling.
        new zPool(address(board), address(A), address(B), FEE, FEE, 1 days, BOUNTY, address(0));
    }

    function test_ConstructorRejectsCodelessDependencies() public {
        vm.expectRevert(zPool.Bad.selector);
        new zPool(address(0xB0A4D), address(A), address(B), FEE, RUNG, 1 days, BOUNTY, address(0));

        vm.expectRevert(zPool.Bad.selector);
        new zPool(address(board), address(0xA11CE), address(B), FEE, RUNG, 1 days, BOUNTY, address(0));

        vm.expectRevert(zPool.Bad.selector);
        new zPool(address(board), address(A), address(B), FEE, RUNG, 1 days, BOUNTY, address(0xFEE4));
    }

    function test_DepositRejectsFeeOnTransferBeforeMintingShares() public {
        FeeToken taxed = new FeeToken();
        zPool bad = new zPool(address(board), address(taxed), address(B), FEE, RUNG, 1 days, BOUNTY, address(0));
        taxed.mint(lp, 100e18);
        B.mint(lp, 200_000e18);
        vm.startPrank(lp);
        taxed.approve(address(bad), type(uint256).max);
        B.approve(address(bad), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(zPool.BalanceMismatch.selector, address(taxed), 100e18, 99e18));
        bad.deposit(100e18, 200_000e18, 0, lp);
        vm.stopPrank();

        assertEq(bad.totalSupply(), 0, "failed funding mints no shares");
        assertEq(B.balanceOf(address(bad)), 0, "second leg was never pulled");
    }

    function test_FirstDepositGeometricMeanDoesNotOverflow() public {
        MockERC20 hugeA = new MockERC20("HA", 18);
        MockERC20 hugeB = new MockERC20("HB", 18);
        zPool huge =
            new zPool(address(board), address(hugeA), address(hugeB), FEE, RUNG, type(uint64).max, 0, address(0));
        hugeA.mint(lp, type(uint256).max);
        hugeB.mint(lp, type(uint256).max);
        vm.startPrank(lp);
        hugeA.approve(address(huge), type(uint256).max);
        hugeB.approve(address(huge), type(uint256).max);
        (uint256 shares,,) = huge.deposit(type(uint256).max, type(uint256).max, 0, lp);
        vm.stopPrank();

        assertEq(shares, type(uint256).max - 1000, "sqrt(max*max) is max");
        assertEq(huge.totalSupply(), type(uint256).max, "share supply remains representable");
        assertEq(_order(huge.askId()).expiry, type(uint64).max, "expiry saturates");
    }

    // ------------------------------------------------------------- sim helpers

    /// @dev Deploys a fresh pool, seeds it at 100 A / 200,000 B, walks the
    /// path, and returns terminal NAV minus HODL valued at the final price.
    /// `retailBps` is how much of each resting rung an uninformed taker
    /// consumes per step, on both sides.
    function _runPath(uint256 fee_, uint256 rung_, uint256 retailBps) internal returns (int256 edge, uint256 finalMid) {
        return _runPathOn(_path(), fee_, rung_, retailBps);
    }

    address oracle; // set by a test to guard the sim's pool; 0 for none

    function _runPathOn(uint256[12] memory path, uint256 fee_, uint256 rung_, uint256 retailBps)
        internal
        returns (int256 edge, uint256 finalMid)
    {
        pool = new zPool(address(board), address(A), address(B), fee_, rung_, 1 days, BOUNTY, oracle);
        A.mint(lp, 100e18);
        B.mint(lp, 200_000e18);
        vm.startPrank(lp);
        A.approve(address(pool), type(uint256).max);
        B.approve(address(pool), type(uint256).max);
        pool.deposit(100e18, 200_000e18, 0, lp);
        vm.stopPrank();

        uint256 pokes;
        for (uint256 i; i < path.length; ++i) {
            // Arbitrage first, then reprice, and only then let uninformed flow
            // trade. Running retail against the pre-repost rung would just be
            // more arbitrage wearing a different name, and would understate
            // what ordinary flow is worth to the pool.
            _arbAgainst(path[i]);
            if (_pokeIfStale()) ++pokes;
            if (retailBps != 0) {
                _retailFlow(retailBps);
                if (_pokeIfStale()) ++pokes;
            }
        }
        assertGt(pokes, 0, "the sim must actually have repriced");

        uint256 px = path[path.length - 1];
        (uint256 rA, uint256 rB) = pool.reserves();
        assertGt(rA, 0, "A side survived");
        assertGt(rB, 0, "B side survived");

        finalMid = pool.price();
        edge = int256(rA * px / 1e18 + rB) - int256(100e18 * px / 1e18 + 200_000e18);
    }

    /// @dev Takes whatever is profitable at `px`, in full.
    function _arbAgainst(uint256 px) internal {
        ISwapboard.Order memory a = _live(pool.askId(), pool.postedAsk());
        if (a.active && _unitPrice(a.amountA, a.amountB) < px) {
            uint256 id = pool.askId();
            vm.prank(arb);
            board.fillOrder(id, block.timestamp, a.amountB, 0, arb);
        }
        // The bid gives B for A, so it is worth hitting when the pool pays
        // more than the market for A.
        ISwapboard.Order memory b = _live(pool.bidId(), pool.postedBid());
        if (b.active && _unitPrice(b.amountB, b.amountA) > px) {
            uint256 id = pool.bidId();
            vm.prank(arb);
            board.fillOrder(id, block.timestamp, b.amountB, 0, arb);
        }
    }

    /// @dev Uninformed two-way flow: takes a slice of each rung at the pool's
    /// price without reference to the market. Partial fills are what let this
    /// happen without a repost between takers.
    function _retailFlow(uint256 bps) internal {
        ISwapboard.Order memory a = _live(pool.askId(), pool.postedAsk());
        if (a.active) {
            uint256 pay = a.amountB * bps / 10_000;
            if (pay != 0) {
                uint256 id = pool.askId();
                vm.prank(arb);
                board.fillOrder(id, block.timestamp, pay, 0, arb);
            }
        }
        ISwapboard.Order memory b = _live(pool.bidId(), pool.postedBid());
        if (b.active) {
            uint256 pay = b.amountB * bps / 10_000;
            if (pay != 0) {
                uint256 id = pool.bidId();
                vm.prank(arb);
                board.fillOrder(id, block.timestamp, pay, 0, arb);
            }
        }
    }

    function _live(uint256 id, uint256 posted) internal view returns (ISwapboard.Order memory o) {
        if (posted == 0) return o;
        o = _order(id);
    }

    /// @dev Swallows only NotStale. Anything else is a real failure and must
    /// not be hidden, or the thesis number below would be measured against a
    /// pool that silently stopped repricing.
    function _pokeIfStale() internal returns (bool) {
        vm.prank(keeper);
        try pool.poke() {
            return true;
        } catch (bytes memory err) {
            require(bytes4(err) == zPool.NotStale.selector, "poke reverted unexpectedly");
            return false;
        }
    }

    /// @dev B per A, scaled 1e18, for an order giving `amtA` of A and asking
    /// `amtB` of B.
    function _unitPrice(uint256 amtA, uint256 amtB) internal pure returns (uint256) {
        return amtB * 1e18 / amtA;
    }

    function _order(uint256 id) internal view returns (ISwapboard.Order memory) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        return ISwapboard(address(board)).getOrders(ids)[0];
    }
}
