// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";

/// @dev The launcher's claims are economic, so this suite is written as a set
/// of PROPERTIES rather than a set of transcripts: each test names an assertion
/// from the contract header and tries to break it.
///
/// TWO THINGS THE FEE DOES TO THESE TESTS, both of which cost time to rediscover
/// and are therefore recorded here rather than in each test.
///
/// 1. A swap's EFFECTIVE price is not the pool's marginal price - it carries the
///    1% fee. So the opening valuation cannot be read back out of a small buy;
///    it is measured from the pool's virtual reserve instead.
///
/// 2. Redemption pays no fee and a market sell does, so once price approaches
///    the floor, redeeming beats selling by up to the fee. That is the mechanism
///    working - the floor becoming the better exit is what a floor IS - so the
///    invariant asserted here is the one that actually has to hold: buying at
///    market and redeeming must always lose money. `testSellingKeepsRoundTrips-
///    Lossy` states it that way rather than comparing the floor against a
///    fee-bearing quote.
contract PrecisionLauncherTest is Test {
    PrecisionPoolFactory factory;
    PrecisionLauncher launcher;

    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant START_MCAP = 3 ether;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        launcher = new PrecisionLauncher(factory, treasury);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _launch(uint256 allocBps) internal returns (LaunchToken token, PrecisionPool pool) {
        (address t, address p) = launcher.launch("Test", "TEST", "ipfs://one", SUPPLY, allocBps, START_MCAP, creator);
        (token, pool) = (LaunchToken(t), PrecisionPool(payable(p)));
    }

    function _buy(address who, PrecisionPool pool, uint256 eth) internal returns (uint256 out) {
        vm.prank(who);
        out = pool.swapExactIn{value: eth}(address(0), eth, 0, who);
    }

    function _sell(address who, PrecisionPool pool, LaunchToken token, uint256 amount) internal returns (uint256 eth) {
        vm.startPrank(who);
        token.approve(address(pool), amount);
        eth = pool.swapExactIn(address(token), amount, 0, who);
        vm.stopPrank();
    }

    function _redeem(address who, LaunchToken token, uint256 amount) internal returns (uint256 eth) {
        vm.startPrank(who);
        token.approve(address(launcher), amount);
        eth = launcher.redeem(address(token), amount, 0, who);
        vm.stopPrank();
    }

    /// @dev The floor, in wei per whole token.
    function _floor(LaunchToken token) internal view returns (uint256) {
        return launcher.floorPrice(address(token));
    }

    /// @dev A resting holder, so that a test's protagonist redeeming their whole
    ///      position does not unwind the entire pool. (Which it correctly does
    ///      when they are the only holder: the sole buyer redeeming everything
    ///      is the launch running in reverse, and afterwards there is nothing
    ///      left to trade against.)
    function _baseline(PrecisionPool pool) internal {
        _buy(bob, pool, 20 ether);
    }

    // ------------------------------------------------------------- THE LAUNCH

    /// The pool must open holding nothing but the token: no ETH is required to
    /// launch, which is the entire point of a one-sided seed.
    function testLaunchIsOneSidedAndNeedsNoEth() public {
        (LaunchToken token, PrecisionPool pool) = _launch(0);

        assertEq(pool.reserve0(), 0, "opened with ETH");
        assertGt(pool.reserve1(), 0, "opened with no token");
        assertEq(address(pool).balance, 0);
        assertEq(token.balanceOf(address(pool)), pool.reserve1());
        assertEq(token.balanceOf(address(launcher)), 0, "launcher retained tokens");
        assertEq(token.balanceOf(creator), 0);
    }

    /// The opening valuation must match the request. Measured from the pool's
    /// virtual ETH reserve - which is what `startMcapWei` sets - rather than
    /// from a trade, since any trade carries the fee.
    ///
    /// The band's lower bound perturbs the derivation by about `1/(2*BAND)`;
    /// 0.01% is two orders of magnitude looser than that and still tight enough
    /// to catch a wrong formula.
    function testOpeningValuationMatchesRequest() public {
        (, PrecisionPool pool) = _launch(0);

        uint256 virtualEth = pool.totalSupply() * 1e18 / pool.sqrtPHigh();
        assertApproxEqRel(virtualEth, START_MCAP, 0.0001e18, "opening valuation drifted");
    }

    /// The same derivation across three orders of magnitude of supply and
    /// valuation, since the formula is the one thing here that cannot be
    /// checked by inspection.
    function testOpeningValuationHoldsAcrossScales() public {
        uint256[3] memory supplies = [uint256(1_000_000 ether), 1_000_000_000 ether, 100_000_000_000 ether];
        uint256[3] memory caps = [uint256(0.1 ether), 3 ether, 250 ether];

        for (uint256 i; i < supplies.length; ++i) {
            for (uint256 j; j < caps.length; ++j) {
                (, address p) = launcher.launch("S", "S", "", supplies[i], 0, caps[j], creator);
                PrecisionPool pool = PrecisionPool(payable(p));
                uint256 virtualEth = pool.totalSupply() * 1e18 / pool.sqrtPHigh();
                assertApproxEqRel(virtualEth, caps[j], 0.0001e18, "valuation drifted at scale");
            }
        }
    }

    function testCreatorAllocationIsPaidAndCapped() public {
        (LaunchToken token,) = _launch(1_000); // 10%
        assertEq(token.balanceOf(creator), SUPPLY / 10);

        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.launch("X", "X", "", SUPPLY, 2_001, START_MCAP, creator);
    }

    // -------------------------------------------------------------- THE FLOOR

    /// Before any buy there is no ETH in the position, so there is nothing to
    /// redeem. Nobody can extract value from a launch that has not traded - in
    /// particular the creator cannot redeem their allocation for a free exit.
    function testFloorIsZeroBeforeFirstBuy() public {
        (LaunchToken token,) = _launch(1_000);
        assertEq(_floor(token), 0);

        vm.startPrank(creator);
        token.approve(address(launcher), type(uint256).max);
        vm.expectRevert();
        launcher.redeem(address(token), SUPPLY / 10, 0, creator);
        vm.stopPrank();
    }

    /// PROPERTY 1: buy-and-redeem must never profit. The floor is the average
    /// price paid by circulating supply; the market quotes the marginal price,
    /// which on a rising curve is at or above it.
    function testBuyAndRedeemIsAlwaysLossy() public {
        (LaunchToken token, PrecisionPool pool) = _launch(0);
        _baseline(pool);

        uint256[6] memory sizes = [uint256(0.01 ether), 0.1 ether, 1 ether, 5 ether, 25 ether, 100 ether];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 got = _buy(alice, pool, sizes[i]);
            uint256 back = _redeem(alice, token, got);
            assertLt(back, sizes[i], "instant round trip profited");
        }
    }

    /// The same, against a market others are actively trading, and with a
    /// creator allocation diluting the floor.
    function testBuyAndRedeemIsLossyAfterOthersTrade() public {
        (LaunchToken token, PrecisionPool pool) = _launch(500);
        _baseline(pool);

        for (uint256 i; i < 8; ++i) {
            _buy(bob, pool, 3 ether);
            uint256 got = _buy(alice, pool, 2 ether);
            uint256 back = _redeem(alice, token, got);
            assertLt(back, 2 ether, "round trip profited mid-market");
        }
    }

    /// PROPERTY 2: redemption is floor-neutral. A holder exiting must not move
    /// the floor for anyone who stays - there is no race to the exit.
    function testRedemptionIsFloorNeutral() public {
        (LaunchToken token, PrecisionPool pool) = _launch(1_000);
        _buy(alice, pool, 20 ether);
        _buy(bob, pool, 7 ether);

        uint256 before = _floor(token);
        assertGt(before, 0);

        uint256 bal = token.balanceOf(alice);
        for (uint256 i; i < 5; ++i) {
            _redeem(alice, token, bal / 10);
            assertApproxEqRel(_floor(token), before, 1e12, "redemption moved the floor");
        }
    }

    /// PROPERTY 3: outside liquidity is floor-neutral, so there is no reason to
    /// forbid it - and no way to grief redeemers with it.
    function testOutsideLiquidityIsFloorNeutral() public {
        (LaunchToken token, PrecisionPool pool) = _launch(1_000);
        _buy(alice, pool, 20 ether);
        uint256 before = _floor(token);

        uint256 tokens = token.balanceOf(creator);
        vm.prank(creator);
        token.transfer(bob, tokens);

        vm.startPrank(bob);
        token.approve(address(pool), type(uint256).max);
        uint256 eth = uint256(pool.reserve0()) * tokens / uint256(pool.reserve1());
        (uint256 lp,,) = pool.addLiquidityExact{value: eth}(0, eth, tokens, 0, bob);
        vm.stopPrank();

        assertApproxEqRel(_floor(token), before, 1e12, "outside deposit moved the floor");

        vm.prank(bob);
        pool.removeLiquidity(lp, 0, 0, bob);
        assertApproxEqRel(_floor(token), before, 1e12, "outside withdrawal moved the floor");
    }

    /// While the market is rising, the floor must stay strictly under it: a
    /// buyer always pays more than the backing they acquire.
    function testFloorStaysUnderARisingMarket() public {
        (LaunchToken token, PrecisionPool pool) = _launch(1_000);

        for (uint256 i; i < 10; ++i) {
            _buy(alice, pool, 5 ether);

            uint256 probe = token.balanceOf(alice) / 20;
            if (probe == 0) continue;

            uint256 viaFloor = launcher.quoteRedeem(address(token), probe);
            (uint256 viaMarket,) = pool.quoteExactIn(alice, address(token), probe);
            assertLe(viaFloor, viaMarket, "floor overtook a rising market");
        }
    }

    /// A sustained selloff drives the market down onto the floor. Redemption
    /// overtaking a fee-bearing market sell there is the mechanism working, so
    /// what is asserted is the invariant that must survive it: buying at market
    /// and redeeming stays lossy at every point of the decline.
    function testSellingKeepsRoundTripsLossy() public {
        (LaunchToken token, PrecisionPool pool) = _launch(0);
        _baseline(pool);
        _buy(alice, pool, 50 ether);

        uint256 chunk = token.balanceOf(alice) / 12;
        for (uint256 i; i < 10; ++i) {
            _sell(alice, pool, token, chunk);

            uint256 got = _buy(bob, pool, 1 ether);
            uint256 back = _redeem(bob, token, got);
            assertLt(back, 1 ether, "round trip profited during a selloff");
        }
    }

    /// PROPERTY 1, fuzzed over launch shape and trade sequence. The two
    /// hand-written cases above fix the parameters; this varies everything that
    /// could plausibly interact - supply, opening valuation, allocation, and
    /// the sizes and order of other people's trades - and asserts the same
    /// thing. If any combination lets a round trip profit, the floor is a leak.
    function testFuzzBuyAndRedeemIsNeverProfitable(
        uint256 supply,
        uint256 startMcap,
        uint256 allocBps,
        uint256 baseline,
        uint256 noise,
        uint256 size
    ) public {
        supply = bound(supply, 1_000 ether, 1_000_000_000_000 ether);
        startMcap = bound(startMcap, 0.01 ether, 500 ether);
        allocBps = bound(allocBps, 0, 2_000);
        baseline = bound(baseline, 0.001 ether, 200 ether);
        noise = bound(noise, 0, 200 ether);
        size = bound(size, 0.0001 ether, 200 ether);

        (address t, address p) = launcher.launch("F", "F", "", supply, allocBps, startMcap, creator);
        (LaunchToken token, PrecisionPool pool) = (LaunchToken(t), PrecisionPool(payable(p)));

        // Someone else establishes the market first, so alice is not the sole
        // holder unwinding the launch. Trades are `try`ed because a band can
        // legitimately refuse a size; a refused setup is not a counterexample.
        vm.deal(bob, 1000 ether);
        vm.prank(bob);
        try pool.swapExactIn{value: baseline}(address(0), baseline, 0, bob) {} catch {
            return;
        }
        if (noise != 0) {
            vm.prank(bob);
            try pool.swapExactIn{value: noise}(address(0), noise, 0, bob) {} catch {}
        }

        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        uint256 got;
        try pool.swapExactIn{value: size}(address(0), size, 0, alice) returns (uint256 o) {
            got = o;
        } catch {
            return;
        }

        vm.startPrank(alice);
        token.approve(address(launcher), got);
        try launcher.redeem(address(token), got, 0, alice) returns (uint256 back) {
            assertLt(back, size, "fuzzed round trip profited");
        } catch {}
        vm.stopPrank();
    }

    /// PROPERTY 2, fuzzed. Whatever the market has done first, one holder's
    /// partial exit must leave the floor where it found it.
    function testFuzzRedemptionIsFloorNeutral(uint256 buyA, uint256 buyB, uint256 exitBps) public {
        buyA = bound(buyA, 0.01 ether, 300 ether);
        buyB = bound(buyB, 0.01 ether, 300 ether);
        exitBps = bound(exitBps, 1, 9_000);

        (LaunchToken token, PrecisionPool pool) = _launch(1_000);
        vm.prank(alice);
        try pool.swapExactIn{value: buyA}(address(0), buyA, 0, alice) {} catch {
            return;
        }
        vm.prank(bob);
        try pool.swapExactIn{value: buyB}(address(0), buyB, 0, bob) {} catch {}

        uint256 before = _floor(token);
        vm.assume(before > 0);

        uint256 amount = token.balanceOf(alice) * exitBps / 10_000;
        vm.assume(amount > 0);

        vm.startPrank(alice);
        token.approve(address(launcher), amount);
        try launcher.redeem(address(token), amount, 0, alice) {
            assertApproxEqRel(_floor(token), before, 1e12, "fuzzed redemption moved the floor");
        } catch {}
        vm.stopPrank();
    }

    /// Dust redemptions round toward the position, so they cannot ratchet the
    /// floor down. Each either pays its exact share or reverts for paying zero.
    function testDustRedemptionsCannotRatchetTheFloorDown() public {
        (LaunchToken token, PrecisionPool pool) = _launch(0);
        _buy(alice, pool, 30 ether);
        uint256 before = _floor(token);

        vm.startPrank(alice);
        token.approve(address(launcher), type(uint256).max);
        for (uint256 i; i < 200; ++i) {
            try launcher.redeem(address(token), 1, 0, alice) {} catch {}
        }
        vm.stopPrank();

        assertGe(_floor(token), before, "dust redemptions lowered the floor");
    }

    /// Redemption removes the position proportionally, and PrecisionPool's
    /// virtual reserves scale with LP supply, so the market price is unmoved
    /// but for the pool's own rounding - which rounds against the redeemer.
    function testRedemptionDoesNotMovePrice() public {
        (LaunchToken token, PrecisionPool pool) = _launch(0);
        _buy(alice, pool, 40 ether);

        uint256 probe = 1000 ether;
        (uint256 priceBefore,) = pool.quoteExactIn(alice, address(token), probe);
        _redeem(alice, token, token.balanceOf(alice) / 2);
        (uint256 priceAfter,) = pool.quoteExactIn(alice, address(token), probe);

        assertApproxEqRel(priceAfter, priceBefore, 0.0001e18, "redemption moved price");
        assertLe(priceAfter, priceBefore, "rounding favoured the redeemer");
    }

    /// The whole point of holding the LP forever: no path exists for anyone to
    /// pull the position out from under holders.
    function testNobodyCanWithdrawTheLockedPosition() public {
        (LaunchToken token, PrecisionPool pool) = _launch(1_000);
        _buy(alice, pool, 20 ether);

        uint256 lp = pool.balanceOf(address(launcher));
        assertGt(lp, 0);

        // The launcher has no owner, so there is no privileged caller at all.
        (bool ok,) = address(launcher).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "launcher has an owner");

        vm.prank(creator);
        vm.expectRevert();
        pool.removeLiquidity(lp, 0, 0, creator);

        // And redemption of one launch cannot reach another's position.
        (LaunchToken other,) = _launch(0);
        vm.startPrank(alice);
        other.approve(address(launcher), type(uint256).max);
        vm.expectRevert();
        launcher.redeem(address(other), 1 ether, 0, alice);
        vm.stopPrank();
        assertEq(pool.balanceOf(address(launcher)), lp, "position was reachable");
    }

    function testRedeemRejectsUnknownTokens() public {
        vm.expectRevert(PrecisionLauncher.NoToken.selector);
        launcher.redeem(address(0xDEAD), 1 ether, 0, alice);
        assertEq(launcher.quoteRedeem(address(0xDEAD), 1 ether), 0);
    }

    // ---------------------------------------------------------------- THE FEE

    function testFeesSplitEthAndBurnTokens() public {
        (LaunchToken token, PrecisionPool pool) = _launch(0);
        _buy(alice, pool, 10 ether);
        _sell(alice, pool, token, token.balanceOf(alice) / 2);

        uint256 supplyBefore = token.totalSupply();
        uint256 floorBefore = _floor(token);
        uint256 creatorBefore = creator.balance;
        uint256 treasuryBefore = treasury.balance;

        (uint256 creatorEth, uint256 protocolEth, uint256 titheEth, uint256 burned,) =
            launcher.collectFees(address(token));

        assertGt(creatorEth, 0, "no creator fee");
        assertGt(protocolEth, 0, "no protocol fee");
        assertGt(titheEth, 0, "no tithe");
        assertGt(burned, 0, "no tokens burned");
        assertEq(creator.balance - creatorBefore, creatorEth, "creator underpaid");
        assertEq(treasury.balance - treasuryBefore, protocolEth, "treasury underpaid");
        // 80 / 10 / 10 across creator, treasury and the burn.
        assertEq(protocolEth, titheEth, "treasury and tithe are not equal tenths");
        assertEq(creatorEth, protocolEth * 8, "creator is not the remaining eight tenths");
        assertEq(token.totalSupply(), supplyBefore - burned, "burn did not reduce supply");
        assertGt(_floor(token), floorBefore, "fee burn did not raise the floor");
    }

    /// Anyone may sweep; the proceeds are not redirectable to the sweeper.
    function testFeeCollectionIsPermissionlessButNotRedirectable() public {
        (LaunchToken token, PrecisionPool pool) = _launch(0);
        _buy(alice, pool, 10 ether);

        uint256 bobBefore = bob.balance;
        uint256 creatorBefore = creator.balance;

        vm.prank(bob);
        (uint256 creatorEth,,,,) = launcher.collectFees(address(token));

        assertEq(bob.balance, bobBefore, "sweeper was paid");
        assertEq(creator.balance - creatorBefore, creatorEth);
    }

    // -------------------------------------------------------------- THE TOKEN

    function testContractURIIsOwnerEditable() public {
        (LaunchToken token,) = _launch(0);

        assertEq(token.contractURI(), "ipfs://one");
        assertEq(token.owner(), creator);

        vm.prank(creator);
        token.setContractURI("ipfs://two");
        assertEq(token.contractURI(), "ipfs://two");

        vm.prank(alice);
        vm.expectRevert(IOwnable.Unauthorized.selector);
        token.setContractURI("ipfs://evil");
    }

    /// Metadata ownership must carry no power over supply, fees, or the market.
    function testOwnershipIsMetadataOnly() public {
        (LaunchToken token, PrecisionPool pool) = _launch(0);
        _buy(alice, pool, 10 ether);

        vm.prank(creator);
        token.renounceOwnership();

        (uint256 creatorEth,,,,) = launcher.collectFees(address(token));
        assertGt(creatorEth, 0, "renouncing stopped the fee stream");
        assertEq(launcher.creatorOf(address(token)), creator);
        _redeem(alice, token, token.balanceOf(alice) / 2);
    }

    /// Supply is fixed at construction and only ever falls. The small shortfall
    /// against `SUPPLY` is the seed's rounding dust, which `launch` burns.
    function testSupplyOnlyEverFalls() public {
        (LaunchToken token, PrecisionPool pool) = _launch(0);

        uint256 opening = token.totalSupply();
        assertLe(opening, SUPPLY, "minted over the stated supply");
        assertApproxEqRel(opening, SUPPLY, 1e12, "seed dust was material");

        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether));
        assertFalse(ok, "a mint path exists");

        _baseline(pool);
        _buy(alice, pool, 10 ether);
        _redeem(alice, token, token.balanceOf(alice));
        assertLt(token.totalSupply(), opening, "redemption did not burn");
    }

    /// Stray ETH cannot accumulate in a contract with no accounting for it.
    function testOnlyPoolsMaySendEth() public {
        vm.prank(alice);
        (bool ok,) = address(launcher).call{value: 1 ether}("");
        assertFalse(ok, "accepted a donation");
    }
}

interface IOwnable {
    error Unauthorized();
}
