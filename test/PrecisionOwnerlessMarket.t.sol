// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev The ownerless market: `feeRecipient == address(0)`.
///
/// This is the default shape and the one most AMMs only have. Nobody owns the
/// market, anybody may create it, anybody may seed it, and no address can ever
/// extract a creator fee from it. The squat tests next door cover what an
/// attacker can do to the CREATION race; this covers that the resulting market
/// is genuinely unowned for its whole life, which is a different claim and the
/// one an integrator actually relies on.
///
/// Worth stating because the two knobs are easy to conflate: `feeRecipient`
/// decides WHO MAY INITIALISE, and `creatorFeeBps` decides WHO GETS PAID. They
/// are independent, and the interesting combination - a named market taking no
/// fee - is deliberately allowed.
contract PrecisionOwnerlessMarketTest is Test {
    PrecisionPoolFactory factory;
    MockERC20 tk;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAF0);

    uint256 constant SL = 0.5e18;
    uint256 constant SM = 1e18;
    uint256 constant SH = 2e18;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        tk = new MockERC20("TK", 18);
        for (uint256 i; i < 3; ++i) {
            address who = i == 0 ? alice : i == 1 ? bob : carol;
            tk.mint(who, 1e26);
            vm.deal(who, 10_000 ether);
            vm.prank(who);
            tk.approve(address(factory), type(uint256).max);
        }
    }

    function _mkt(address recipient, uint256 bps) internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(tk),
            sqrtPLow: SL,
            sqrtPHigh: SH,
            fee: 3000,
            hook: address(0),
            feeRecipient: recipient,
            creatorFeeBps: bps
        });
    }

    /// @dev The whole lifecycle with three unrelated parties and no owner:
    /// alice creates, BOB seeds, carol provides and exits. None of them is
    /// privileged over the others at any step.
    function test_AnyoneCreatesAnyoneSeedsAnyoneProvides() public {
        PrecisionPoolFactory.Market memory m = _mkt(address(0), 0);

        vm.prank(alice);
        address pool = factory.createPool(m);
        PrecisionPool p = PrecisionPool(payable(pool));
        assertEq(p.feeRecipient(), address(0), "market should be unowned");
        assertEq(p.creatorFeeBps(), 0, "an unowned market cannot carry a creator share");

        // Someone other than the creator seeds it. On a named market this is
        // exactly what `NotCreator` would refuse.
        vm.prank(bob);
        (, uint256 seeded,,) = factory.seed{value: 100 ether}(m, SM, 100 ether, 1e23, 0, bob);
        assertGt(seeded, 0, "a stranger could not seed an unowned market");

        // And a third party can add and exit like any LP.
        vm.startPrank(carol);
        tk.approve(pool, type(uint256).max);
        (uint256 lp,,) = p.addLiquidityExact{value: 10 ether}(0, 10 ether, 1e22, 0, carol);
        assertGt(lp, 0, "third party could not provide");
        (uint256 a0, uint256 a1) = p.removeLiquidity(lp, 0, 0, carol);
        vm.stopPrank();
        assertTrue(a0 != 0 || a1 != 0, "third party could not exit");
    }

    /// @dev No address can ever collect a creator fee from an unowned market -
    /// including address(0) itself, which is what `feeRecipient` is set to.
    /// A caller cannot be address(0), so the guard is total rather than merely
    /// unlikely.
    function test_NobodyCanCollectFromAnUnownedMarket() public {
        PrecisionPoolFactory.Market memory m = _mkt(address(0), 0);
        vm.prank(alice);
        address pool = factory.createPool(m);
        vm.prank(bob);
        factory.seed{value: 100 ether}(m, SM, 100 ether, 1e23, 0, bob);
        PrecisionPool p = PrecisionPool(payable(pool));

        // Trade so a fee is definitely taken.
        vm.prank(carol);
        p.swapExactIn{value: 5 ether}(address(0), 5 ether, 0, carol);

        // The whole fee stayed with the LPs; nothing was earmarked for a creator.
        assertEq(p.creatorOwed0(), 0, "an unowned market accrued a creator fee");
        assertEq(p.creatorOwed1(), 0, "an unowned market accrued a creator fee");

        for (uint256 i; i < 3; ++i) {
            address who = i == 0 ? alice : i == 1 ? bob : carol;
            vm.prank(who);
            vm.expectRevert(PrecisionPool.NotFeeRecipient.selector);
            p.collectCreatorFees(who);
        }
    }

    /// @dev The constructor refuses a creator share with no one to pay it to,
    /// so "unowned but taxed" is unrepresentable rather than merely unused.
    function test_AnUnownedMarketCannotCarryACreatorShare() public {
        vm.prank(alice);
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(_mkt(address(0), 1000));
    }

    /// @dev The combination worth knowing about: a market can be OWNED for the
    /// purpose of deciding who initialises it while taking no fee at all. That
    /// is squat protection with zero cost to traders, and it is the shape to
    /// reach for when a frontend is going to promote the market.
    function test_AMarketCanBeOwnedAndUntaxed() public {
        PrecisionPoolFactory.Market memory m = _mkt(alice, 0);

        vm.prank(alice);
        address pool = factory.createPool(m);
        PrecisionPool p = PrecisionPool(payable(pool));
        assertEq(p.feeRecipient(), alice);
        assertEq(p.creatorFeeBps(), 0, "no tax");

        // Only the owner may initialise it.
        vm.prank(bob);
        vm.expectRevert(PrecisionPoolFactory.NotCreator.selector);
        factory.seed{value: 100 ether}(m, SM, 100 ether, 1e23, 0, bob);

        vm.prank(alice);
        factory.seed{value: 100 ether}(m, SM, 100 ether, 1e23, 0, alice);

        // Once seeded it is open to everyone, and still takes nothing.
        vm.startPrank(bob);
        tk.approve(pool, type(uint256).max);
        (uint256 lp,,) = p.addLiquidityExact{value: 5 ether}(0, 5 ether, 1e22, 0, bob);
        vm.stopPrank();
        assertGt(lp, 0, "a non-owner must still be able to provide after seeding");

        vm.prank(carol);
        p.swapExactIn{value: 2 ether}(address(0), 2 ether, 0, carol);
        assertEq(p.creatorOwed0(), 0, "an untaxed owned market must accrue nothing");
    }

    /// @dev And the taxed case. The creator's cut comes OUT of the base fee
    /// rather than on top of it: `amountOut` is derived from
    /// `inAfterFee = net - feeAmount`, and `creatorCut` appears nowhere in it.
    ///
    /// SO THE TRADER IS UNAFFECTED FOR A GIVEN SWAP AGAINST GIVEN RESERVES -
    /// which is what this test measures, on two freshly seeded identical pools.
    /// It is NOT true that the two markets stay identical. `kept = net -
    /// creatorCut` is what enters the reserves, so a taxed pool accumulates
    /// more slowly and the two drift apart with volume. See the test below,
    /// which measures the drift rather than assuming it away.
    function test_ACreatorShareComesOutOfTheFeeNotOnTopOfIt() public {
        PrecisionPoolFactory.Market memory taxed = _mkt(alice, 5000); // half the fee
        PrecisionPoolFactory.Market memory free = _mkt(address(0), 0);

        vm.prank(alice);
        factory.createAndSeed{value: 100 ether}(taxed, SM, 100 ether, 1e23, 0, alice);
        vm.prank(bob);
        factory.createAndSeed{value: 100 ether}(free, SM, 100 ether, 1e23, 0, bob);

        PrecisionPool pt = PrecisionPool(payable(factory.poolFor(taxed)));
        PrecisionPool pf = PrecisionPool(payable(factory.poolFor(free)));

        vm.prank(carol);
        uint256 outTaxed = pt.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, carol);
        vm.prank(carol);
        uint256 outFree = pf.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, carol);

        // Identical bands, identical fee, identical size: the trader receives
        // the same. Only where the fee lands differs.
        assertEq(outTaxed, outFree, "a creator share changed what the trader received");
        assertGt(pt.creatorOwed0(), 0, "the taxed market accrued nothing");
        assertEq(pf.creatorOwed0(), 0, "the free market accrued something");
    }

    /// @dev WHERE THE CREATOR FEE ACTUALLY LANDS, over time rather than on one
    /// trade. "A taxed and an untaxed market pay the trader the same" is only
    /// true of the FIRST swap; stated generally it is wrong, and the direction
    /// it is wrong in is counterintuitive.
    ///
    /// The cut leaves the pool, so a taxed pool's reserves grow more slowly
    /// than an untaxed twin's. Less input retained means less price impact
    /// accumulated, so the taxed pool ends up marginally CHEAPER to trade
    /// against, not dearer. The cost is borne entirely by its LPs, who are
    /// compounding a smaller share of the same fee.
    ///
    /// Measured rather than argued, because the sign is easy to get backwards.
    function test_ATaxedMarketDivergesFromAnUntaxedTwinWithVolume() public {
        PrecisionPoolFactory.Market memory taxed = _mkt(alice, 5000);
        PrecisionPoolFactory.Market memory free = _mkt(address(0), 0);
        vm.startPrank(alice);
        factory.createAndSeed{value: 100 ether}(taxed, SM, 100 ether, 1e23, 0, alice);
        factory.createAndSeed{value: 100 ether}(free, SM, 100 ether, 1e23, 0, alice);
        vm.stopPrank();

        PrecisionPool pt = PrecisionPool(payable(factory.poolFor(taxed)));
        PrecisionPool pf = PrecisionPool(payable(factory.poolFor(free)));

        uint256 firstT;
        uint256 firstF;
        uint256 lastT;
        uint256 lastF;
        for (uint256 i; i < 40; ++i) {
            vm.prank(carol);
            uint256 ot = pt.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, carol);
            vm.prank(carol);
            uint256 og = pf.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, carol);
            if (i == 0) (firstT, firstF) = (ot, og);
            (lastT, lastF) = (ot, og);
        }

        assertEq(firstT, firstF, "the first swap must be identical - same reserves, same math");
        assertGt(lastT, lastF, "the taxed pool should end up marginally cheaper, not dearer");
        // And the reason: its reserves grew more slowly by exactly the cut.
        assertLt(pt.reserve0(), pf.reserve0(), "the taxed pool should hold less");
        assertGt(pt.creatorOwed0(), 0, "the difference should be sitting in the creator's claim");
    }
}
