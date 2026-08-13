// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";

/// @dev Coverage for the launcher as a PRODUCT rather than as a mechanism.
///
/// `PrecisionLauncher.t.sol` asks whether the floor math is sound. This asks the
/// two questions that matter once it is: is every zSwap-launched token the SAME
/// token but for name, supply and valuation - and does one survive its whole
/// life, from an untraded pool to a fully redeemed one.
///
/// THE TEMPLATE IS THE POINT. A launchpad whose outputs vary is a launchpad
/// whose outputs must each be audited. Every knob that could differ between two
/// launches is either a constant here or absent, and `_assertTemplate` is the
/// executable statement of that: it is applied to every launch this file makes,
/// including fuzzed ones, so a future edit that lets one token differ from the
/// rest fails somewhere in this suite rather than in production.
contract PrecisionLauncherLifecycleTest is Test {
    PrecisionPoolFactory factory;
    PrecisionLauncher launcher;

    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAC01);

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant START_MCAP = 3 ether;

    /// @dev The template, restated here so a change to the contract's constants
    ///      has to be made deliberately in two places.
    uint256 constant T_FEE = 10_000; // 1% in pips
    uint256 constant T_CREATOR_BPS = 5_000; // half the base fee
    uint256 constant T_BAND = 1e6;
    uint256 constant T_MAX_ALLOC_BPS = 2_000;
    uint256 constant T_MIN_MCAP = 1e12;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        launcher = new PrecisionLauncher(factory, treasury);
        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(carol, 100_000 ether);
    }

    // ------------------------------------------------------------- HELPERS

    function _launch(uint256 supply, uint256 allocBps, uint256 mcap)
        internal
        returns (LaunchToken token, PrecisionPool pool)
    {
        (address t, address p) = launcher.launch("Test", "TEST", "ipfs://one", supply, allocBps, mcap, creator);
        (token, pool) = (LaunchToken(t), PrecisionPool(payable(p)));
        _assertTemplate(token, pool);
    }

    function _buy(address who, PrecisionPool pool, uint256 eth) internal returns (uint256) {
        vm.prank(who);
        return pool.swapExactIn{value: eth}(address(0), eth, 0, who);
    }

    function _sell(address who, PrecisionPool pool, LaunchToken token, uint256 amount) internal returns (uint256) {
        vm.startPrank(who);
        token.approve(address(pool), amount);
        uint256 out = pool.swapExactIn(address(token), amount, 0, who);
        vm.stopPrank();
        return out;
    }

    function _redeem(address who, LaunchToken token, uint256 amount) internal returns (uint256) {
        vm.startPrank(who);
        token.approve(address(launcher), amount);
        uint256 out = launcher.redeem(address(token), amount, 0, who);
        vm.stopPrank();
        return out;
    }

    function _floor(LaunchToken token) internal view returns (uint256) {
        return launcher.floorPrice(address(token));
    }

    /// @dev Every property a zSwap-launched token is promised to have.
    function _assertTemplate(LaunchToken token, PrecisionPool pool) internal view {
        // The market tuple, which is also the pool's CREATE2 preimage - so
        // these are not merely current values, they are the address itself.
        assertEq(pool.token0(), address(0), "quote asset is not ETH");
        assertEq(pool.token1(), address(token), "token is not token1");
        assertEq(pool.fee(), T_FEE, "fee off template");
        assertEq(pool.creatorFeeBps(), T_CREATOR_BPS, "creator share off template");
        assertEq(pool.hook(), address(0), "a hook was attached");
        assertEq(pool.feeRecipient(), address(launcher), "fees are not launcher-routed");
        assertEq(pool.sqrtPLow(), pool.sqrtPHigh() / T_BAND, "band off template");
        assertEq(pool.factory(), address(factory), "foreign factory");
        assertTrue(factory.isPool(address(pool)), "not a factory pool");

        // The token.
        assertEq(token.decimals(), 18, "non-18 decimals");
        assertEq(launcher.poolOf(address(token)), address(pool), "unindexed");
        assertTrue(launcher.creatorOf(address(token)) != address(0), "no fee holder");

        // The position. Every LP share except the pool's permanently burned
        // minimum is held by the launcher, which has no way to spend it.
        assertEq(
            pool.balanceOf(address(launcher)) + pool.balanceOf(address(0xdead)),
            pool.totalSupply(),
            "liquidity escaped the launcher"
        );
        assertEq(token.balanceOf(address(launcher)), 0, "launcher holds loose tokens");
    }

    // -------------------------------------------------- TEMPLATE CONFORMANCE

    /// The template must hold whatever the caller asks for. If any input can
    /// move a field `_assertTemplate` pins, tokens stop being interchangeable.
    function testFuzzTemplateHoldsForAnyLaunch(uint256 supply, uint256 allocBps, uint256 mcap, address owner) public {
        supply = bound(supply, 1_000 ether, 1_000_000_000_000 ether);
        allocBps = bound(allocBps, 0, T_MAX_ALLOC_BPS);
        mcap = bound(mcap, T_MIN_MCAP, 1_000 ether);
        vm.assume(owner != address(0));

        (address t, address p) = launcher.launch("F", "F", "", supply, allocBps, mcap, owner);
        _assertTemplate(LaunchToken(t), PrecisionPool(payable(p)));

        assertEq(LaunchToken(t).owner(), owner, "metadata owner not set");
        assertEq(launcher.creatorOf(t), owner, "fee holder not set");
        assertEq(LaunchToken(t).balanceOf(owner), supply * allocBps / 10_000, "allocation wrong");
    }

    /// Two launches with identical metadata must still be distinct markets -
    /// the name is not part of anything load-bearing.
    function testIdenticalMetadataYieldsDistinctMarkets() public {
        (LaunchToken a, PrecisionPool pa) = _launch(SUPPLY, 0, START_MCAP);
        (LaunchToken b, PrecisionPool pb) = _launch(SUPPLY, 0, START_MCAP);

        assertTrue(address(a) != address(b), "token address collided");
        assertTrue(address(pa) != address(pb), "pool address collided");

        // And they do not share state.
        _buy(alice, pa, 10 ether);
        assertGt(_floor(a), 0);
        assertEq(_floor(b), 0, "floor leaked between launches");
    }

    // ------------------------------------------------------ LAUNCH VALIDATION

    function testLaunchRejectsBadParameters() public {
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.launch("X", "X", "", SUPPLY, 0, START_MCAP, address(0)); // no owner

        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.launch("X", "X", "", SUPPLY, T_MAX_ALLOC_BPS + 1, START_MCAP, creator); // over-allocated

        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.launch("X", "X", "", SUPPLY, 0, T_MIN_MCAP - 1, creator); // dust valuation

        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.launch("X", "X", "", 0, 0, START_MCAP, creator); // no supply

        // The token side of the pool's resolution floor is a property of
        // SUPPLY, not of valuation - `MIN_START_MCAP` does not cover it. Before
        // this guard existed the call below passed every launcher check and
        // died inside `_seed` with `InsufficientLiquidity`, which tells a caller
        // nothing about which parameter was wrong. No valuation rescues it.
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.launch("X", "X", "", 5e11, 0, T_MIN_MCAP, creator);
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.launch("X", "X", "", 5e11, 0, 100 ether, creator);

        // And the boundary itself is admissible.
        launcher.launch("X", "X", "", 2e12, 0, T_MIN_MCAP, creator);

        // A supply so large against so small a valuation that the opening price
        // leaves the pool's representable range. Note `type(uint128).max` does
        // NOT do this - it yields a sqrtP of ~1.8e31, comfortably inside the
        // 1e36 ceiling - so the threshold is far higher than it looks and has
        // to be reached deliberately.
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.launch("X", "X", "", 1e50, 0, T_MIN_MCAP, creator);
    }

    /// The boundaries themselves must be admissible, not merely their interiors.
    function testLaunchAcceptsItsOwnBoundaries() public {
        _launch(SUPPLY, T_MAX_ALLOC_BPS, START_MCAP); // max allocation
        _launch(SUPPLY, 0, T_MIN_MCAP); // min valuation
    }

    /// THE SUPPLY FLOOR, which is a separate constraint from the valuation floor
    /// and used to be unguarded.
    ///
    /// The pool needs `MIN_RESOLUTION` (1e6) of virtual reserve on BOTH sides.
    /// Working the launcher's template through, the ETH side is `startMcapWei` -
    /// which `MIN_START_MCAP` covers - but the token side is `pooled / BAND`,
    /// so the binding constraint is `pooled >= 1e12`, a property of SUPPLY.
    /// `MIN_START_MCAP` does not imply it and an earlier comment claimed it did.
    /// Unguarded, a small-supply launch passed every check here and died inside
    /// `_seed` with the pool's `InsufficientLiquidity` instead of the
    /// launcher's own `Bad`.
    /// @dev The floor is `MIN_POOLED`, which is 2e12 rather than the 1e12 the
    ///      arithmetic derives - the launcher doubles it deliberately, so a
    ///      launch cannot squeak past this guard only to revert inside `_seed`
    ///      with an error naming none of its parameters. Written against the
    ///      constant's real value, since a test that asserts the derived bound
    ///      would pass only while the margin did not exist.
    function testLaunchRejectsASupplyBelowTheResolutionFloor() public {
        // Just under, with no allocation so `pooled == supply`.
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.launch("S", "S", "", 2e12 - 1, 0, T_MIN_MCAP, creator);

        // Exactly at the floor is admissible, and must reach a live pool rather
        // than merely passing the launcher's own guard.
        (address t, address p) = launcher.launch("S", "S", "", 2e12, 0, T_MIN_MCAP, creator);
        assertEq(PrecisionPool(payable(p)).reserve1(), LaunchToken(t).balanceOf(p), "pool did not open");

        // And the floor is on POOLED, not on raw supply: an allocation eats into
        // it, so a supply that clears the bound on its own can still fail once
        // 20% is taken off the top.
        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.launch("S", "S", "", 2e12, T_MAX_ALLOC_BPS, T_MIN_MCAP, creator);
    }

    // ------------------------------------------------------------- LIFECYCLE

    /// One token, cradle to grave, asserting the invariant that applies at each
    /// stage. Written as a single walk rather than split up because the point is
    /// that the stages COMPOSE - several of these passed in isolation while a
    /// bug lived in the transition between them.
    function testFullLifecycle() public {
        // Snapshot rather than assert zero at the end, and the reason is worth
        // recording because it misleads on first contact: this repo FORKS
        // MAINNET by default (`eth_rpc_url` + `fork_block_number` in
        // `[profile.default]`), so forge's deterministic CREATE addresses
        // inherit whatever dust those addresses really hold. The launcher lands
        // on 0x2e234DAe..., which owns 1 wei on mainnet. `balance == 0` would
        // therefore be a statement about that address's history rather than
        // about this contract. What matters is that no operation LEAVES ETH
        // behind, which is a delta.
        uint256 launcherEthAtStart = address(launcher).balance;

        (LaunchToken token, PrecisionPool pool) = _launch(SUPPLY, 1_000, START_MCAP);

        // -- Stage 0: launched, untraded. Nothing to extract, including by the
        //    creator holding 10% of supply.
        assertEq(pool.reserve0(), 0);
        assertEq(_floor(token), 0);
        // Hoisted: `expectRevert` arms the NEXT call, and an argument that is
        // itself an external call would consume it.
        uint256 alloc = token.balanceOf(creator);
        vm.startPrank(creator);
        token.approve(address(launcher), type(uint256).max);
        vm.expectRevert();
        launcher.redeem(address(token), alloc, 0, creator);
        vm.stopPrank();

        // -- Stage 1: price discovery. The floor may only rise while buying.
        uint256 floorMark;
        for (uint256 i; i < 8; ++i) {
            _buy(i % 2 == 0 ? alice : bob, pool, 4 ether);
            uint256 f = _floor(token);
            assertGe(f, floorMark, "floor fell during accumulation");
            floorMark = f;
        }
        assertGt(floorMark, 0, "floor never formed");

        // -- Stage 2: fees sweep mid-life, and the burn lifts the floor.
        _sell(alice, pool, token, token.balanceOf(alice) / 10);
        uint256 beforeSweep = _floor(token);
        (uint256 cEth, uint256 pEth,, uint256 burned,) = launcher.collectFees(address(token));
        assertGt(cEth + pEth, 0, "no fees accrued");
        assertGt(burned, 0, "no tokens burned");
        assertGe(_floor(token), beforeSweep, "sweep lowered the floor");

        // -- Stage 3: a holder exits partially. Everyone else is untouched.
        uint256 heldFloor = _floor(token);
        _redeem(bob, token, token.balanceOf(bob) / 2);
        assertApproxEqRel(_floor(token), heldFloor, 1e12, "partial exit moved the floor");

        // -- Stage 4: the creator takes their allocation out. Dilution is
        //    priced in from the start, so this must not move the floor either.
        heldFloor = _floor(token);
        _redeem(creator, token, token.balanceOf(creator));
        assertApproxEqRel(_floor(token), heldFloor, 1e12, "creator exit moved the floor");

        // -- Stage 5: a selloff. The floor FALLS here, and substantially - see
        //    `testSellingAboveTheFloorDilutesIt`. What must survive is that it
        //    stays positive, stays under the market, and keeps round trips
        //    lossy.
        for (uint256 i; i < 5; ++i) {
            _sell(alice, pool, token, token.balanceOf(alice) / 6);

            uint256 probe = 1000 ether;
            uint256 viaFloor = launcher.quoteRedeem(address(token), probe);
            (uint256 viaMarket,) = pool.quoteExactIn(alice, address(token), probe);
            assertLe(viaFloor, viaMarket, "floor overtook the market in a selloff");

            uint256 got = _buy(carol, pool, 1 ether);
            assertLt(_redeem(carol, token, got), 1 ether, "round trip profited late in life");
        }
        assertGt(_floor(token), 0, "floor collapsed to nothing");

        // -- Stage 6: everyone left standing exits. The token ends empty rather
        //    than stuck, and no ETH is stranded in the launcher.
        _redeem(alice, token, token.balanceOf(alice));
        _redeem(bob, token, token.balanceOf(bob));
        assertLt(token.totalSupply(), SUPPLY / 100, "supply survived a full exit");
        assertEq(address(launcher).balance, launcherEthAtStart, "launcher accumulated ETH");
        assertEq(token.balanceOf(address(launcher)), 0, "launcher retained tokens");
    }

    /// Fees must remain sweepable after the holders have gone - the last exit
    /// must not strand the creator's accrued income.
    function testFeesRemainCollectableAfterFullExit() public {
        (LaunchToken token, PrecisionPool pool) = _launch(SUPPLY, 0, START_MCAP);
        _buy(alice, pool, 20 ether);
        _sell(alice, pool, token, token.balanceOf(alice) / 2);
        _redeem(alice, token, token.balanceOf(alice));

        (uint256 cEth,,, uint256 burned,) = launcher.collectFees(address(token));
        assertGt(cEth, 0, "creator income stranded by the last exit");
        assertGt(burned, 0);
    }

    /// A launch that never trades must stay inert and harmless forever, not
    /// become a stuck object.
    function testUntradedLaunchStaysInert() public {
        (LaunchToken token, PrecisionPool pool) = _launch(SUPPLY, 500, START_MCAP);

        vm.warp(block.timestamp + 365 days);

        assertEq(_floor(token), 0);
        assertEq(launcher.quoteRedeem(address(token), 1 ether), 0);

        // Sweeping an empty stream is a no-op rather than a revert.
        (uint256 cEth, uint256 pEth,, uint256 burned,) = launcher.collectFees(address(token));
        assertEq(cEth + pEth + burned, 0, "fees materialised from nothing");

        // And the market still opens normally whenever someone does arrive.
        assertGt(_buy(alice, pool, 1 ether), 0, "stale launch could not be traded");
    }

    /// THE FLOOR IS NOT A RATCHET, and this is the test that says so out loud.
    ///
    /// A sell above the floor withdraws ETH at the market price while giving up
    /// tokens that carried only the average, so the difference comes out of
    /// what backs everyone else. The move is large, not incidental - which is
    /// the opposite of what "floor" suggests to most readers, and is therefore
    /// worth an executable statement rather than a line of prose.
    ///
    /// What IS bounded is the relationship: the move scales with `p - F`, so it
    /// dies out exactly as the market descends onto the floor.
    function testSellingAboveTheFloorDilutesIt() public {
        (LaunchToken token, PrecisionPool pool) = _launch(SUPPLY, 0, START_MCAP);
        _buy(alice, pool, 10 ether);
        _buy(bob, pool, 60 ether); // bob pays up, lifting the average

        uint256 start = _floor(token);
        assertGt(start, 0);

        // A large sale well above the floor cuts it materially.
        _sell(bob, pool, token, token.balanceOf(bob) * 3 / 4);
        uint256 afterSale = _floor(token);
        assertLt(afterSale, start / 2, "a large above-floor sale did not dilute the floor");

        // But it never crosses the market, and the gap keeps closing rather
        // than the floor chasing the price down through it.
        for (uint256 i; i < 6; ++i) {
            uint256 probe = 1000 ether;
            uint256 viaFloor = launcher.quoteRedeem(address(token), probe);
            (uint256 viaMarket,) = pool.quoteExactIn(alice, address(token), probe);
            assertLe(viaFloor, viaMarket, "floor crossed the market");
            _sell(alice, pool, token, token.balanceOf(alice) / 8);
        }

        // And redemption still works, at whatever the floor now is.
        assertGt(_floor(token), 0, "floor vanished");
        assertGt(_redeem(alice, token, token.balanceOf(alice) / 2), 0, "redemption stopped paying");
    }

    // ------------------------------------------------------------ VARIATIONS

    /// The two allocation extremes must behave identically but for the size of
    /// the discount the allocation represents.
    function testAllocationExtremesBehaveTheSame() public {
        (LaunchToken zero, PrecisionPool poolZero) = _launch(SUPPLY, 0, START_MCAP);
        (LaunchToken maxed, PrecisionPool poolMax) = _launch(SUPPLY, T_MAX_ALLOC_BPS, START_MCAP);

        _buy(alice, poolZero, 25 ether);
        _buy(bob, poolMax, 25 ether);

        // Both form a floor; the allocated one's is lower, because the
        // allocation claims backing it never paid for.
        assertGt(_floor(zero), 0);
        assertGt(_floor(maxed), 0);
        assertLt(_floor(maxed), _floor(zero), "allocation did not dilute");

        // And both remain safe.
        uint256 g1 = _buy(carol, poolZero, 5 ether);
        assertLt(_redeem(carol, zero, g1), 5 ether);
        uint256 g2 = _buy(carol, poolMax, 5 ether);
        assertLt(_redeem(carol, maxed, g2), 5 ether);
    }

    /// Outside liquidity present for the whole life must not change any
    /// conclusion - it is neutral at deposit, during, and at withdrawal.
    function testLifecycleWithOutsideLiquidity() public {
        (LaunchToken token, PrecisionPool pool) = _launch(SUPPLY, 1_000, START_MCAP);
        _buy(alice, pool, 30 ether);

        uint256 tokens = token.balanceOf(creator);
        vm.prank(creator);
        token.transfer(bob, tokens);

        vm.startPrank(bob);
        token.approve(address(pool), type(uint256).max);
        uint256 eth = uint256(pool.reserve0()) * tokens / uint256(pool.reserve1());
        (uint256 lp,,) = pool.addLiquidityExact{value: eth}(0, eth, tokens, 0, bob);
        vm.stopPrank();

        uint256 mark = _floor(token);
        _buy(carol, pool, 10 ether);
        assertGe(_floor(token), mark, "outside LP broke floor accretion");

        uint256 got = _buy(carol, pool, 3 ether);
        assertLt(_redeem(carol, token, got), 3 ether, "outside LP enabled a profitable round trip");

        mark = _floor(token);
        vm.prank(bob);
        pool.removeLiquidity(lp, 0, 0, bob);
        assertApproxEqRel(_floor(token), mark, 1e12, "outside LP exit moved the floor");
    }

    /// Several launches must not interfere: redemption and fees are per-token.
    function testConcurrentLaunchesDoNotInterfere() public {
        (LaunchToken a, PrecisionPool pa) = _launch(SUPPLY, 0, START_MCAP);
        (LaunchToken b, PrecisionPool pb) = _launch(SUPPLY / 4, 1_000, 10 ether);
        (LaunchToken c, PrecisionPool pc) = _launch(SUPPLY * 3, 2_000, 0.5 ether);

        _buy(alice, pa, 30 ether);
        _buy(alice, pb, 5 ether);
        _buy(alice, pc, 12 ether);

        uint256 fb = _floor(b);
        uint256 fc = _floor(c);
        uint256 lpB = pb.balanceOf(address(launcher));
        uint256 lpC = pc.balanceOf(address(launcher));

        // Exercise A hard.
        _redeem(alice, a, a.balanceOf(alice) / 2);
        launcher.collectFees(address(a));
        _sell(alice, pa, a, a.balanceOf(alice) / 4);

        assertEq(_floor(b), fb, "B's floor moved");
        assertEq(_floor(c), fc, "C's floor moved");
        assertEq(pb.balanceOf(address(launcher)), lpB, "B's position moved");
        assertEq(pc.balanceOf(address(launcher)), lpC, "C's position moved");
    }

    /// Metadata ownership and the fee stream are independent for their whole
    /// lives: either can move or end without touching the other.
    function testOwnershipAndFeeStreamAreIndependent() public {
        (LaunchToken token, PrecisionPool pool) = _launch(SUPPLY, 0, START_MCAP);
        _buy(alice, pool, 10 ether);

        // Metadata moves; fees do not follow.
        vm.prank(creator);
        token.transferOwnership(bob);
        assertEq(token.owner(), bob);
        assertEq(launcher.creatorOf(address(token)), creator, "fees followed metadata");

        // Fees move; metadata does not follow.
        vm.prank(creator);
        launcher.setCreator(address(token), carol);
        vm.prank(carol);
        launcher.acceptCreator(address(token));
        assertEq(token.owner(), bob, "metadata followed fees");

        uint256 before = carol.balance;
        (uint256 cEth,,,,) = launcher.collectFees(address(token));
        assertEq(carol.balance - before, cEth, "fees did not reach the new holder");

        // Metadata ends; fees continue. A BUY, because the creator fee accrues
        // on the input token - a sell would leave the ETH side at zero and this
        // assertion would fail for a reason that has nothing to do with
        // ownership.
        vm.prank(bob);
        token.renounceOwnership();
        _buy(alice, pool, 5 ether);
        (uint256 cEth2,,,,) = launcher.collectFees(address(token));
        assertGt(cEth2, 0, "renouncing ended the fee stream");
    }
}
