// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";

/// @notice Where a launched token's 1% swap fee actually ends up, measured.
///
///         The contract SAYS the fee splits in half: half to the creator stream
///         and half "staying in the pool as reserves, which is to say it accrues
///         directly to the floor". The first half is easy to check - an address
///         receives ether. The second half is a claim about an accounting
///         identity, and an accounting identity that nobody measures is a
///         comment.
///
///         So this file asks the sceptical version of the question: does the
///         pool's half do ANYTHING for a holder, or does it merely sit in
///         reserves belonging to a position nobody can reach? The floor a holder
///         actually gets is `quoteRedeem`, so that is what is measured, per
///         token, before and after.
contract LaunchFeeEconomicsTest is Test {
    PrecisionPoolFactory factory;
    PrecisionLauncher launcher;

    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address lp = address(0x1D);

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant START_MCAP = 3 ether;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        launcher = new PrecisionLauncher(factory, treasury);
        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(lp, 100_000 ether);
    }

    function _launch() internal returns (LaunchToken t, PrecisionPool p) {
        (address a, address b) = launcher.launch("Test", "TEST", "", SUPPLY, 0, START_MCAP, creator);
        (t, p) = (LaunchToken(a), PrecisionPool(payable(b)));
    }

    function _buy(address who, PrecisionPool p, uint256 eth) internal returns (uint256) {
        vm.prank(who);
        return p.swapExactIn{value: eth}(address(0), eth, 0, who);
    }

    function _sell(address who, PrecisionPool p, LaunchToken t, uint256 amt) internal returns (uint256) {
        vm.startPrank(who);
        t.approve(address(p), amt);
        uint256 out = p.swapExactIn(address(t), amt, 0, who);
        vm.stopPrank();
        return out;
    }

    /// The floor a holder can actually reach, per token, scaled so two holdings
    /// of different size are comparable.
    function _floorPerToken(LaunchToken t, uint256 held) internal view returns (uint256) {
        return launcher.quoteRedeem(address(t), held) * 1e18 / held;
    }

    // ------------------------------------------------------- the pool's half

    /// The claim, at its narrowest: a holder who does nothing is worth more per
    /// token after other people trade than before. If the pool's half of the fee
    /// were inert, this number would not move.
    function test_theHalfThatStaysInThePoolReachesAHolderWhoNeverTrades() public {
        (LaunchToken t, PrecisionPool p) = _launch();
        uint256 held = _buy(alice, p, 10 ether);
        uint256 before = _floorPerToken(t, held);

        // Somebody else trades, in both directions, and never touches alice.
        for (uint256 i; i < 8; ++i) {
            uint256 got = _buy(bob, p, 20 ether);
            _sell(bob, p, t, got);
        }

        uint256 after_ = _floorPerToken(t, held);
        emit log_named_uint("floor per token, before", before);
        emit log_named_uint("floor per token, after ", after_);
        assertGt(after_, before, "trading did nothing for a passive holder");
    }

    /// And it is not a rounding artefact - but it is NOT LINEAR IN TRADE SIZE
    /// either, which is the part worth knowing. Ten times the trade size gave
    /// under three times the floor gain when this was measured, because a
    /// bigger round trip walks the price up on the way in and the SELL leg
    /// drags the floor back down: a seller withdraws ether at the market price
    /// while surrendering tokens that carried only the average. So whale
    /// round-tripping is worth much less to holders than its volume suggests.
    function test_biggerTradesHelpTheFloorButSublinearly() public {
        (LaunchToken t1, PrecisionPool p1) = _launch();
        uint256 held1 = _buy(alice, p1, 10 ether);
        uint256 base1 = _floorPerToken(t1, held1);
        for (uint256 i; i < 4; ++i) {
            _sell(bob, p1, t1, _buy(bob, p1, 5 ether));
        }
        uint256 small = _floorPerToken(t1, held1) - base1;

        (LaunchToken t2, PrecisionPool p2) = _launch();
        uint256 held2 = _buy(alice, p2, 10 ether);
        uint256 base2 = _floorPerToken(t2, held2);
        for (uint256 i; i < 4; ++i) {
            _sell(bob, p2, t2, _buy(bob, p2, 50 ether));
        }
        uint256 big = _floorPerToken(t2, held2) - base2;

        emit log_named_uint("floor gain, 5 ETH trades ", small);
        emit log_named_uint("floor gain, 50 ETH trades", big);
        emit log_named_uint("ratio x100 for 10x size  ", big * 100 / small);
        assertGt(big, small, "a bigger trade did not help the floor at all");
        assertLt(big, small * 10, "the floor gain became linear in size - the sell drag is gone");
    }

    /// Volume made of MANY SAME-SIZED trades is the case that does compound,
    /// and it is the realistic one. Each round trip is small enough that the
    /// sell drag is small, so the fee accumulates roughly in step with count.
    function test_repeatedTradingCompoundsTheFloor() public {
        (LaunchToken t, PrecisionPool p) = _launch();
        uint256 held = _buy(alice, p, 10 ether);
        uint256 base = _floorPerToken(t, held);

        uint256 afterFour;
        for (uint256 i; i < 20; ++i) {
            _sell(bob, p, t, _buy(bob, p, 5 ether));
            if (i == 3) afterFour = _floorPerToken(t, held) - base;
        }
        uint256 afterTwenty = _floorPerToken(t, held) - base;

        emit log_named_uint("floor gain after 4 trades ", afterFour);
        emit log_named_uint("floor gain after 20 trades", afterTwenty);
        assertGt(afterTwenty, afterFour * 3, "repeated trading stopped compounding");
    }

    // ------------------------------------------------ the creator's half

    /// The headline number: 0.4% of what a buyer spends. Asserted against
    /// measured ether rather than against the constants that produced it, so a
    /// change to the split shows up here as a changed rate.
    function test_theCreatorReceivesFortyBasisPointsOfBuyVolume() public {
        (LaunchToken t, PrecisionPool p) = _launch();
        uint256 spent = 100 ether;
        _buy(alice, p, spent);

        uint256 creatorBefore = creator.balance;
        uint256 treasuryBefore = treasury.balance;
        (uint256 creatorEth, uint256 protocolEth, uint256 titheEth,,) = launcher.collectFees(address(t));

        assertEq(creator.balance - creatorBefore, creatorEth, "the creator was not paid what was reported");
        assertEq(treasury.balance - treasuryBefore, protocolEth);

        emit log_named_uint("bought with (wei)", spent);
        emit log_named_uint("creator got  (wei)", creatorEth);
        emit log_named_uint("bps of spend", creatorEth * 10_000 / spent);
        // 0.4%, within a basis point of rounding.
        assertApproxEqAbs(creatorEth * 10_000 / spent, 40, 1, "not 40 bps");
        assertApproxEqAbs(protocolEth * 10_000 / spent, 5, 1, "treasury is not 5 bps");
        assertApproxEqAbs(titheEth * 10_000 / spent, 5, 1, "the tithe is not 5 bps");
    }

    /// A SELL pays the creator nothing. The fee is charged in the input token,
    /// and the token side is burned rather than split - so a creator's income
    /// tracks buying, not activity. Worth having stated as a test because it is
    /// the part most likely to be assumed away.
    function test_aSellPaysTheCreatorNothingAndBurnsInstead() public {
        (LaunchToken t, PrecisionPool p) = _launch();
        uint256 got = _buy(alice, p, 50 ether);
        launcher.collectFees(address(t)); // clear what the buy earned

        uint256 supplyBefore = t.totalSupply();
        uint256 creatorBefore = creator.balance;
        _sell(alice, p, t, got);

        (uint256 creatorEth,,, uint256 burned,) = launcher.collectFees(address(t));
        assertEq(creatorEth, 0, "a sell paid the creator ether");
        assertEq(creator.balance, creatorBefore);
        assertGt(burned, 0, "the token-side fee was not burned");
        assertEq(supplyBefore - t.totalSupply(), burned, "supply did not fall by what was burned");
    }

    /// Collecting is permissionless, and the money still goes to the creator.
    /// This is what stops a creator being held up by whoever runs the keeper.
    function test_anyoneMaySweepAndTheCreatorStillGetsPaid() public {
        (LaunchToken t, PrecisionPool p) = _launch();
        _buy(alice, p, 25 ether);

        uint256 creatorBefore = creator.balance;
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        (uint256 creatorEth,,,,) = launcher.collectFees(address(t));

        assertGt(creatorEth, 0);
        assertEq(creator.balance - creatorBefore, creatorEth, "a stranger's sweep misdirected the fee");
        assertEq(bob.balance, bobBefore, "the sweeper took a cut");
    }

    // --------------------------------------------- the dilution question

    /// The one that decides whether "accrues to the floor" survives contact
    /// with the world: the pool is PERMISSIONLESS to add liquidity to, so an
    /// outsider can buy a share of the fee stream the floor was relying on.
    ///
    /// Two things have to hold, and they are different. The floor must not FALL
    /// when an outsider joins - `redeem` divides the launcher's own shares by
    /// total supply, so a naive implementation would dilute holders the instant
    /// somebody else LPs. And the floor must still RISE with volume afterwards,
    /// at a slower rate, because the outsider is now taking a cut of the half
    /// that used to go entirely to the position.
    function test_anOutsideLpDoesNotDiluteTheFloorButDoesShareTheFeeStream()
        public
    {
        (LaunchToken t, PrecisionPool p) = _launch();
        uint256 held = _buy(alice, p, 10 ether);
        uint256 before = _floorPerToken(t, held);

        // The rate with the position holding every share.
        for (uint256 i; i < 4; ++i) {
            _sell(bob, p, t, _buy(bob, p, 20 ether));
        }
        uint256 aloneGain = _floorPerToken(t, held) - before;

        // An outsider joins with a comparable stake, in whatever ratio the pool
        // will take at the current price.
        uint256 lpShares;
        {
            uint256 tokensForLp = t.balanceOf(alice) / 2;
            vm.prank(alice);
            t.transfer(lp, tokensForLp);
            vm.startPrank(lp);
            t.approve(address(p), tokensForLp);
            (lpShares,,) = p.addLiquidityExact{value: 50 ether}(0, 50 ether, tokensForLp, 1, lp);
            vm.stopPrank();
        }
        assertGt(lpShares, 0, "the outsider could not join at all");

        held = t.balanceOf(alice);
        uint256 joined = _floorPerToken(t, held);
        assertGe(joined + 1, aloneGain + before, "an outsider joining diluted existing holders");

        for (uint256 i; i < 4; ++i) {
            _sell(bob, p, t, _buy(bob, p, 20 ether));
        }
        uint256 sharedGain = _floorPerToken(t, held) - joined;

        emit log_named_uint("floor gain, position alone  ", aloneGain);
        emit log_named_uint("floor gain, sharing with LP ", sharedGain);
        assertGt(sharedGain, 0, "the floor stopped rising once anyone else LP'd");
    }

    /// The whole thing end to end, as a number a creator would recognise: what
    /// does 1,000 ETH of round-trip volume actually pay?
    function test_whatAThousandEtherOfVolumePays() public {
        (LaunchToken t, PrecisionPool p) = _launch();
        uint256 held = _buy(alice, p, 10 ether);
        uint256 floorBefore = launcher.quoteRedeem(address(t), held);

        uint256 volume;
        for (uint256 i; i < 10; ++i) {
            volume += 100 ether;
            _sell(bob, p, t, _buy(bob, p, 100 ether));
        }
        (uint256 creatorEth, uint256 protocolEth, uint256 titheEth, uint256 burned,) =
            launcher.collectFees(address(t));

        emit log_named_uint("buy volume (ether)     ", volume / 1e18);
        emit log_named_uint("creator (wei)          ", creatorEth);
        emit log_named_uint("treasury (wei)         ", protocolEth);
        emit log_named_uint("burned as BETH (wei)   ", titheEth);
        emit log_named_uint("tokens burned          ", burned);
        emit log_named_uint("holder floor before    ", floorBefore);
        emit log_named_uint("holder floor after     ", launcher.quoteRedeem(address(t), held));
        assertApproxEqAbs(creatorEth * 10_000 / volume, 40, 1, "not 40 bps of buy volume");
    }
}
