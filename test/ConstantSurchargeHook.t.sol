// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";
import {ConstantSurchargeHook} from "../src/pools/ConstantSurchargeHook.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev The launchpad path: one shared hook taxing many markets, where the
/// right to set a market's rate cannot be raced for.
contract ConstantSurchargeHookTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPoolLens lens;
    ConstantSurchargeHook hook;
    MockERC20 usdc;

    uint256 constant SQRT_LOW = 42426406871192;
    uint256 constant SQRT_MID = 44721359549995;
    uint256 constant SQRT_HIGH = 46904157598234;
    uint256 constant FEE = 500;

    address lp = address(0xC11);
    address creator = address(0xC0DE);
    address other = address(0xBAD);
    address trader = address(0x7AD);

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0));
        lens = new PrecisionPoolLens(factory);
        hook = new ConstantSurchargeHook();
        usdc = new MockERC20("USDC", 6);

        usdc.mint(lp, 10_000_000e6);
        usdc.mint(trader, 10_000_000e6);
        vm.deal(lp, 1_000 ether);
        vm.deal(trader, 1_000 ether);

        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        vm.stopPrank();

        // A market naming a creator must be deployed by that creator, so the
        // creator needs funding of its own.
        usdc.mint(creator, 10_000_000e6);
        vm.deal(creator, 1_000 ether);
        vm.prank(creator);
        usdc.approve(address(factory), type(uint256).max);
    }

    function _mkt(uint256 fee_, address recipient) internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(usdc),
            sqrtPLow: SQRT_LOW,
            sqrtPHigh: SQRT_HIGH,
            fee: fee_,
            hook: address(hook),
            feeRecipient: recipient,
            creatorFeeBps: 0
        });
    }

    function _pool(uint256 fee_, address recipient) internal returns (PrecisionPool p) {
        // The factory refuses a market that names somebody else as its creator,
        // so the deployer is the creator whenever one is named.
        vm.startPrank(recipient == address(0) ? lp : recipient);
        (address addr,,,) =
            factory.createAndSeed{value: 10 ether}(_mkt(fee_, recipient), SQRT_MID, 10 ether, 30_000e6, 0, lp);
        vm.stopPrank();
        p = PrecisionPool(payable(addr));
    }

    // ------------------------------------------------------------- authority

    /// @dev The property that makes a shared hook safe. Pool addresses are
    /// deterministic and therefore visible before deployment, so a
    /// first-come registry would be a race the creator loses. There is no
    /// race here because there is nothing to claim.
    function test_OnlyTheMarketsCreatorMaySetItsRate() public {
        PrecisionPool p = _pool(FEE, creator);

        vm.prank(other);
        vm.expectRevert(ConstantSurchargeHook.NotCreator.selector);
        hook.setSurcharge(address(p), 5000);

        vm.prank(creator);
        hook.setSurcharge(address(p), 5000);
        assertEq(hook.surchargeOf(address(p)), 5000);
    }

    /// @dev A market that named no creator can never be taxed by anyone,
    /// because the authority it would be checked against does not exist.
    function test_AMarketWithNoCreatorCanNeverBeTaxed() public {
        PrecisionPool p = _pool(3000, address(0));

        vm.prank(other);
        vm.expectRevert(ConstantSurchargeHook.NotCreator.selector);
        hook.setSurcharge(address(p), 5000);

        assertEq(hook.surchargeOf(address(p)), 0);
        assertEq(p.extraFee(trader, address(0), 1 ether), 0, "and so charges nothing");
    }

    function test_UnconfiguredMarketChargesNothing() public {
        PrecisionPool p = _pool(FEE, creator);
        assertEq(hook.surchargeOf(address(p)), 0);
        assertEq(p.extraFee(trader, address(0), 1 ether), 0, "silent until configured");

        vm.prank(trader);
        p.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertEq(p.hookOwed0(), 0, "nothing accrued");
    }

    function test_RateIsCappedAtTheHooksOwnCeiling() public {
        PrecisionPool p = _pool(FEE, creator);
        vm.prank(creator);
        vm.expectRevert(ConstantSurchargeHook.Bad.selector);
        hook.setSurcharge(address(p), 100_001);
    }

    // ----------------------------------------------------------------- taxing

    function test_TaxAccruesAndTheQuoteStillMatchesTheFill() public {
        PrecisionPool p = _pool(FEE, creator);
        vm.prank(creator);
        hook.setSurcharge(address(p), 10_000); // 1%

        assertEq(p.extraFee(trader, address(0), 1 ether), 10_000, "pool reads the rate");

        uint256 predicted = lens.quoteFor(address(p), trader, address(0), 1 ether);
        vm.prank(trader);
        uint256 actual = p.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);

        assertEq(actual, predicted, "quoting survives a live tax");
        assertEq(p.hookOwed0(), 1 ether * 10_000 / 1_000_000, "exactly 1% of the input");
    }

    /// @dev LPs are untouched by a tax, which is the whole difference from a
    /// fee split: the surcharge comes off the top, then the pool charges its
    /// own fee on what is left.
    function test_TaxCostsTheTakerNotTheLp() public {
        PrecisionPool taxed = _pool(FEE, creator);
        PrecisionPool plain = _pool(3000, address(0));
        vm.prank(creator);
        hook.setSurcharge(address(taxed), 20_000); // 2%

        assertLt(
            lens.quoteFor(address(taxed), trader, address(0), 1 ether),
            lens.quoteFor(address(plain), trader, address(0), 1 ether) * 1005 / 1000,
            "the taxed market quotes materially worse"
        );

        uint256 r0 = taxed.reserve0();
        vm.prank(trader);
        taxed.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        // Reserves grew by the input less the hook's cut only - no LP haircut.
        assertEq(taxed.reserve0(), r0 + 1 ether - taxed.hookOwed0());
    }

    /// @dev One deployment, many markets, independent rates - the pool is the
    /// msg.sender of the pricing call, so no per-market hook is needed.
    function test_OneHookServesManyMarketsIndependently() public {
        PrecisionPool a = _pool(FEE, creator);
        PrecisionPool b = _pool(3000, creator);

        vm.startPrank(creator);
        hook.setSurcharge(address(a), 5_000);
        hook.setSurcharge(address(b), 30_000);
        vm.stopPrank();

        assertEq(a.extraFee(trader, address(0), 1 ether), 5_000);
        assertEq(b.extraFee(trader, address(0), 1 ether), 30_000);
    }

    // ------------------------------------------------------------- collection

    /// @dev Anyone may sweep, because it can only ever land on the creator.
    /// That makes keeper-driven collection safe without any permissioning.
    function test_CollectionIsPermissionlessButPaysOnlyTheCreator() public {
        PrecisionPool p = _pool(FEE, creator);
        vm.prank(creator);
        hook.setSurcharge(address(p), 10_000);

        vm.prank(trader);
        p.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        uint256 owed = p.hookOwed0();
        assertGt(owed, 0);

        uint256 creatorBefore = creator.balance;
        vm.prank(other); // a stranger, or a keeper
        hook.collect(address(p));

        assertEq(creator.balance - creatorBefore, owed, "paid the creator");
        assertEq(other.balance, 0, "and nobody else");
        assertEq(p.hookOwed0(), 0);
        assertEq(address(p).balance, p.reserve0(), "balance back to reserves alone");
    }

    /// @dev The pool refuses anyone but its hook, so the tax cannot be lifted
    /// by calling the pool directly.
    function test_PoolRefusesDirectHookFeeCollection() public {
        PrecisionPool p = _pool(FEE, creator);
        vm.prank(creator);
        vm.expectRevert(PrecisionPool.NotHook.selector);
        p.collectHookFees(creator);
    }
}
