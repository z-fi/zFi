// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";
import {FeeToken, MockERC20, SenderFeeERC20} from "./SwapboardMocks.sol";

/// @dev ETH/USDC-shaped market: token0 is native ETH (18 dec), token1 is a
/// 6-decimal token, and the range is $1800-$2200 with the decimal adjustment
/// already folded into the bounds, as the pool requires.
///
///   sqrt(1800e6 / 1e18) * 1e18 = 42426406871192
///   sqrt(2000e6 / 1e18) * 1e18 = 44721359549995
///   sqrt(2200e6 / 1e18) * 1e18 = 46904157598234
contract RecordingHook {
    uint256 public calls;
    address public lastSender;
    address public lastTokenIn;
    uint256 public lastAmountIn;
    uint256 public lastAmountOut;
    address public lastTo;

    function afterSwap(address sender, address tokenIn, uint256 amountIn, uint256 amountOut, address to) external {
        ++calls;
        (lastSender, lastTokenIn, lastAmountIn, lastAmountOut, lastTo) = (sender, tokenIn, amountIn, amountOut, to);
    }
}

contract RevertingHook {
    function afterSwap(address, address, uint256, uint256, address) external pure {
        revert("no");
    }
}

contract GasBurnerHook {
    uint256 acc;

    function afterSwap(address, address, uint256, uint256, address) external {
        while (true) {
            acc = acc + 1;
        }
    }
}

contract ReenteringHook {
    PrecisionPool public pool;
    bool public reentered;

    function target(PrecisionPool p) external {
        pool = p;
    }

    function afterSwap(address, address, uint256, uint256, address) external {
        try pool.swapExactIn(address(0), 0, 0, address(this)) {
            reentered = true;
        } catch {}
    }
}

/// @dev Charges a flat surcharge and records nothing else.
contract FeeHook {
    uint256 public surcharge;
    address public lastSender;

    constructor(uint256 s) {
        surcharge = s;
    }

    function feeFor(address sender, address, uint256) external view returns (uint256) {
        return sender == address(0) ? 0 : surcharge;
    }

    function afterSwap(address sender, address, uint256, uint256, address) external {
        lastSender = sender;
    }

    function collect(PrecisionPool p, address to) external {
        p.collectHookFees(to);
    }
}

/// @dev Refuses to answer, which must read as charging nothing.
contract BrokenFeeHook {
    function feeFor(address, address, uint256) external pure returns (uint256) {
        revert("nope");
    }

    function afterSwap(address, address, uint256, uint256, address) external {}
}

/// @dev Charges the designated executor, so a bulk quote proves it is using
/// the actual pool caller rather than the Lens caller.
contract SenderSensitiveFeeHook {
    address immutable expensiveSender;

    constructor(address expensiveSender_) {
        expensiveSender = expensiveSender_;
    }

    function feeFor(address sender, address, uint256) external view returns (uint256) {
        return sender == expensiveSender ? 10_000 : 0;
    }

    function afterSwap(address, address, uint256, uint256, address) external {}
}

contract PrecisionPoolTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPool pool;
    MockERC20 usdc;

    uint256 constant SQRT_LOW = 42426406871192;
    uint256 constant SQRT_MID = 44721359549995;
    uint256 constant SQRT_HIGH = 46904157598234;
    uint256 constant FEE = 500; // 0.05% in pips

    address lp = address(0xC11);
    address trader = address(0x7AD);

    /// @dev Forge's deterministic deploy addresses are not guaranteed to start
    ///      empty, so custody is checked as a delta rather than against zero.
    uint256 factoryEthBefore;
    uint256 factoryTokenBefore;

    function _mkt(uint256 fee_, address hook_) internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(usdc),
            sqrtPLow: SQRT_LOW,
            sqrtPHigh: SQRT_HIGH,
            fee: fee_,
            hook: hook_,
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    function _mktRaw(address t0, address t1, uint256 lo, uint256 hi, uint256 fee_, address hook_)
        internal
        pure
        returns (PrecisionPoolFactory.Market memory)
    {
        return PrecisionPoolFactory.Market({
            token0: t0,
            token1: t1,
            sqrtPLow: lo,
            sqrtPHigh: hi,
            fee: fee_,
            hook: hook_,
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0));
        usdc = new MockERC20("USDC", 6);

        usdc.mint(lp, 10_000_000e6);
        usdc.mint(trader, 10_000_000e6);
        vm.deal(lp, 1_000 ether);
        vm.deal(trader, 1_000 ether);

        vm.prank(lp);
        usdc.approve(address(factory), type(uint256).max);

        factoryEthBefore = address(factory).balance;
        factoryTokenBefore = usdc.balanceOf(address(factory));

        vm.prank(lp);
        (address p,,,) =
            factory.createAndSeed{value: 10 ether}(_mkt(FEE, address(0)), SQRT_MID, 10 ether, 30_000e6, 0, lp);
        pool = PrecisionPool(payable(p));

        vm.prank(trader);
        usdc.approve(address(pool), type(uint256).max);
    }

    // ------------------------------------------------------------------ setup

    function test_SeedsInsideTheRangeAtTheNamedPrice() public view {
        assertApproxEqRel(pool.sqrtPriceCurrent(), SQRT_MID, 0.001e18, "seeded at $2000");
        assertGt(pool.totalSupply(), 0);
        assertGt(pool.balanceOf(lp), 0, "LP holds ERC-20 shares");
        assertEq(pool.balanceOf(address(0xdead)), 1000, "MIN_LIQUIDITY locked");
    }

    function test_ExcessSideIsRefundedNotAbsorbed() public {
        // 10 ETH at $2000 across this band needs well under 30,000 USDC, so
        // the ETH side binds and the rest must come home.
        assertLt(usdc.balanceOf(address(pool)), 30_000e6, "pool kept only what it used");
        assertGt(usdc.balanceOf(lp), 10_000_000e6 - 30_000e6, "remainder refunded to the funder");
    }

    function test_FactoryTookNoCustody() public view {
        assertEq(address(factory).balance, factoryEthBefore, "factory retained ETH");
        assertEq(usdc.balanceOf(address(factory)), factoryTokenBefore, "factory retained token1");
    }

    // ------------------------------------------------------------------- swap

    function test_SwapsBothWaysAndMovesThePrice() public {
        uint256 before = pool.sqrtPriceCurrent();

        vm.prank(trader);
        uint256 out = pool.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertGt(out, 0, "received USDC");
        assertLt(pool.sqrtPriceCurrent(), before, "selling ETH lowers its price");

        uint256 mid = pool.sqrtPriceCurrent();
        vm.prank(trader);
        uint256 back = pool.swapExactIn(address(usdc), 2_000e6, 0, trader);
        assertGt(back, 0, "received ETH");
        assertGt(pool.sqrtPriceCurrent(), mid, "buying ETH raises its price");
    }

    /// @dev The fee is the whole reason an LP is here, so a round trip has to
    /// leave the trader worse off and the pool better off.
    function test_RoundTripLosesTheTraderMoney() public {
        uint256 startEth = trader.balance;

        vm.prank(trader);
        uint256 got = pool.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);

        vm.prank(trader);
        pool.swapExactIn(address(usdc), got, 0, trader);

        assertLt(trader.balance, startEth, "the spread was paid to the pool");
    }

    /// @dev Past the edge of the band the pool is entirely one asset. Refusing
    /// is the documented behaviour; clamping would silently shortchange.
    function test_SwapBeyondTheRangeIsRefusedNotClamped() public {
        vm.prank(trader);
        vm.expectRevert(PrecisionPool.InsufficientOutput.selector);
        pool.swapExactIn{value: 500 ether}(address(0), 500 ether, 0, trader);
    }

    function test_MinOutIsEnforced() public {
        vm.prank(trader);
        vm.expectRevert(PrecisionPool.InsufficientOutput.selector);
        pool.swapExactIn{value: 1 ether}(address(0), 1 ether, type(uint256).max, trader);
    }

    function test_UnknownTokenIsRefused() public {
        MockERC20 other = new MockERC20("X", 18);
        vm.prank(trader);
        vm.expectRevert(PrecisionPool.InvalidToken.selector);
        pool.swapExactIn(address(other), 1, 0, trader);
    }

    /// @dev Surplus can be forced or accidentally sent to a pool. It must not
    /// become a later caller's swap input, and the old balance-delta selector
    /// must remain unusable even when a balance has been prefunded.
    function test_PrefundedBalanceCannotBeClaimedByASwapper() public {
        usdc.mint(address(pool), 1_000e6);
        PrecisionPoolLens lens = _lens();
        uint256 predicted = lens.quoteFor(address(pool), trader, address(usdc), 5_000e6);

        vm.prank(trader);
        uint256 actual = pool.swapExactIn(address(usdc), 5_000e6, 0, trader);
        assertEq(actual, predicted, "only the declared amount moved the curve");

        vm.prank(trader);
        vm.expectRevert(PrecisionPool.LegacyPrefundDisabled.selector);
        pool.swap(address(usdc), 0, trader);
    }

    function test_UntrustedExecutorCannotSpendFactoryTokenDust() public {
        usdc.mint(address(factory), 5_000e6);
        vm.expectRevert(PrecisionPoolFactory.NotExecutor.selector);
        factory.executePrefundedSwap(address(pool), address(usdc), 5_000e6, 0, trader);
    }

    // -------------------------------------------------------------- liquidity

    function test_ProportionalAddRefundsTheOverSuppliedSide() public {
        uint256 supplyBefore = pool.totalSupply();
        uint256 usdcBefore = usdc.balanceOf(lp);

        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (, uint256 lp2, uint256 used0, uint256 used1) =
            factory.seed{value: 1 ether}(_mkt(FEE, address(0)), 0, 1 ether, 1_000_000e6, 0, lp);
        vm.stopPrank();

        assertGt(lp2, 0);
        assertEq(pool.totalSupply(), supplyBefore + lp2);
        assertLt(used1, 1_000_000e6, "did not swallow the oversupply");
        assertApproxEqAbs(usdc.balanceOf(lp), usdcBefore - used1, 1, "only the used amount left the funder");
    }

    /// @dev The same surplus rule applies to LP mints: only the explicit
    /// transfer in this call can buy shares; an older donation remains surplus.
    function test_PrefundedBalanceCannotBeClaimedByALiquidityMinter() public {
        uint256 donation = 1_000e6;
        usdc.mint(address(pool), donation);

        vm.prank(trader);
        pool.addLiquidityExact{value: 1 ether}(0, 1 ether, 3_000e6, 0, trader);

        assertEq(usdc.balanceOf(address(pool)) - pool.reserve1(), donation, "donation was not minted");
    }

    function test_FactoryRejectsFeeOnTransferFunding() public {
        FeeToken feeToken = new FeeToken();
        feeToken.mint(lp, 100 ether);
        PrecisionPoolFactory.Market memory m = _mktRaw(address(0), address(feeToken), 1 ether, 3 ether, FEE, address(0));

        vm.startPrank(lp);
        feeToken.approve(address(factory), type(uint256).max);
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createAndSeed{value: 10 ether}(m, 2 ether, 10 ether, 60 ether, 0, lp);
        vm.stopPrank();
    }

    function test_PoolRejectsSenderFeeOutputToken() public {
        SenderFeeERC20 badToken = new SenderFeeERC20();
        badToken.mint(lp, 100 ether);
        PrecisionPoolFactory.Market memory m = _mktRaw(address(0), address(badToken), 1 ether, 3 ether, FEE, address(0));

        vm.startPrank(lp);
        badToken.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 10 ether}(m, 2 ether, 10 ether, 60 ether, 0, lp);
        vm.stopPrank();

        vm.prank(trader);
        vm.expectRevert(PrecisionPool.UnsupportedToken.selector);
        PrecisionPool(payable(p)).swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
    }

    function test_RemoveReturnsProRataOfBothSides() public {
        uint256 shares = pool.balanceOf(lp);
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        uint256 supply = pool.totalSupply();

        vm.prank(lp);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(shares / 2, 0, 0, lp);

        assertApproxEqRel(a0, r0 * (shares / 2) / supply, 1e12);
        assertApproxEqRel(a1, r1 * (shares / 2) / supply, 1e12);
        assertEq(pool.balanceOf(lp), shares - shares / 2);
    }

    /// @dev Seeding then immediately exiting must never return more than went
    /// in: if it could, liquidity would be mintable out of rounding.
    function test_SeedThenExitCannotProfit() public {
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p2, uint256 lp2, uint256 used0, uint256 used1) =
            factory.createAndSeed{value: 5 ether}(_mkt(3000, address(0)), SQRT_MID, 5 ether, 20_000e6, 0, lp);

        (uint256 out0, uint256 out1) = PrecisionPool(payable(p2)).removeLiquidity(lp2, 0, 0, lp);
        vm.stopPrank();

        assertLe(out0, used0, "no free token0");
        assertLe(out1, used1, "no free token1");
    }

    // ---------------------------------------------------------------- factory

    function test_AddressIsDerivedAndDeterministic() public view {
        assertEq(factory.poolFor(_mkt(FEE, address(0))), address(pool), "poolFor matches what was deployed");
    }

    function test_DuplicateMarketIsRefused() public {
        vm.prank(lp);
        vm.expectRevert(PrecisionPoolFactory.Exists.selector);
        factory.createPool(_mkt(FEE, address(0)));
    }

    function test_NonCanonicalOrderIsRefused() public {
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(_mktRaw(address(usdc), address(0), SQRT_LOW, SQRT_HIGH, FEE, address(0)));
    }

    function test_InvertedOrEmptyRangeIsRefused() public {
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(_mktRaw(address(0), address(usdc), SQRT_HIGH, SQRT_LOW, FEE, address(0)));
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(_mktRaw(address(0), address(usdc), SQRT_LOW, SQRT_LOW, FEE, address(0)));
    }

    function test_SeedingAMarketThatDoesNotExistIsRefused() public {
        vm.prank(lp);
        vm.expectRevert(PrecisionPoolFactory.NoPool.selector);
        factory.seed{value: 1 ether}(_mkt(999, address(0)), 0, 1 ether, 1e6, 0, lp);
    }

    // -------------------------------------------------------------- discovery

    function test_PoolsAreDiscoverableWithoutKnowingTheirParameters() public {
        vm.startPrank(lp);
        factory.createPool(_mkt(3000, address(0)));
        factory.createPool(_mkt(10000, address(0)));
        vm.stopPrank();

        assertEq(factory.poolCount(), 3);
        assertEq(factory.poolsForPairCount(address(0), address(usdc)), 3, "all bands on the pair");

        address[] memory page = factory.poolsSlice(1, 2);
        assertEq(page.length, 2, "paginated");
        assertEq(page[0], factory.allPools(1));

        // Walking past the end terminates rather than reverting.
        assertEq(factory.poolsSlice(99, 5).length, 0);
        // And the details come from the pool, so they cannot disagree.
        assertEq(PrecisionPool(payable(page[0])).fee(), 3000);
    }

    function test_DiscoveryPagesAreBoundedAndOverflowSafe() public {
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.poolsSlice(0, 129);
        assertEq(factory.poolsSlice(type(uint256).max, 1).length, 0, "past-end page is empty");
    }

    function test_NamedMarketCannotBeFrontRunOrSpoofed() public {
        address creator = address(0xC0DE);
        PrecisionPoolFactory.Market memory m = _mkt(3000, address(0));
        m.feeRecipient = creator;

        vm.expectRevert(PrecisionPoolFactory.NotCreator.selector);
        factory.createPool(m);

        vm.prank(creator);
        address named = factory.createPool(m);
        assertEq(PrecisionPool(payable(named)).feeRecipient(), creator);
    }

    // ------------------------------------------------------------------- lens

    function _lens() internal returns (PrecisionPoolLens) {
        return new PrecisionPoolLens(factory);
    }

    /// @dev The property the whole comparison rests on: if a quote and the
    /// fill disagree even slightly, a route built from it either reverts on
    /// amountOutMin or leaves value behind.
    function test_QuoteMatchesTheFillExactly() public {
        PrecisionPoolLens lens = _lens();
        uint256 predicted = lens.quote(address(pool), address(0), 1 ether);
        assertGt(predicted, 0);

        vm.prank(trader);
        uint256 actual = pool.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertEq(actual, predicted, "quote is exact to the wei");
    }

    function test_QuoteMatchesTheFillOnTheOtherSideToo() public {
        PrecisionPoolLens lens = _lens();
        uint256 predicted = lens.quote(address(pool), address(usdc), 5_000e6);
        assertGt(predicted, 0);

        vm.prank(trader);
        uint256 actual = pool.swapExactIn(address(usdc), 5_000e6, 0, trader);
        assertEq(actual, predicted, "quote is exact to the wei");
    }

    /// @dev Zero has to mean "this will revert", not "this is free" - the pool
    /// refuses past its band rather than clamping.
    function test_UnfillableSizeQuotesZeroRatherThanAPartialFill() public {
        PrecisionPoolLens lens = _lens();
        assertEq(lens.quote(address(pool), address(0), 500 ether), 0, "beyond the band");

        vm.prank(trader);
        vm.expectRevert(PrecisionPool.InsufficientOutput.selector);
        pool.swapExactIn{value: 500 ether}(address(0), 500 ether, 0, trader);
    }

    function test_QuoteRejectsUnknownTokenAndEmptyPool() public {
        PrecisionPoolLens lens = _lens();
        assertEq(lens.quote(address(pool), address(0x1234), 1 ether), 0, "not in the pair");
        assertEq(lens.quote(address(0xdead), address(0), 1 ether), 0, "not a pool");

        vm.prank(lp);
        address empty = factory.createPool(_mkt(3000, address(0)));
        assertEq(lens.quote(empty, address(0), 1 ether), 0, "unseeded");
    }

    /// @dev Bands do not share depth, so which one wins is size-dependent.
    function test_BestBandIsChosenAcrossThePair() public {
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        factory.createAndSeed{value: 10 ether}(_mkt(10000, address(0)), SQRT_MID, 10 ether, 30_000e6, 0, lp);
        vm.stopPrank();

        PrecisionPoolLens lens = _lens();
        (address best, uint256 out) = lens.quoteBestFor(address(0), address(usdc), trader, address(0), 1 ether, 0, 16);
        assertEq(best, address(pool), "the 0.05% band beats the 1% band");
        assertEq(out, lens.quote(address(pool), address(0), 1 ether));

        PrecisionPoolLens.Quoted[] memory all =
            lens.quoteAllFor(address(0), address(usdc), trader, address(0), 1 ether, 0, 16);
        assertEq(all.length, 2, "both bands reported, including the loser");
    }

    function test_BulkQuotesUseTheNamedExecutor() public {
        PrecisionPool hp = _feePool(address(new SenderSensitiveFeeHook(address(factory))));
        PrecisionPoolLens lens = _lens();
        uint256 traderQuote = lens.quoteFor(address(hp), trader, address(0), 1 ether);
        uint256 factoryQuote = lens.quoteFor(address(hp), address(factory), address(0), 1 ether);
        assertLt(factoryQuote, traderQuote, "hook prices the executor differently");

        PrecisionPoolLens.Quoted[] memory quotes =
            lens.quoteAllFor(address(0), address(usdc), address(factory), address(0), 1 ether, 0, 16);
        for (uint256 i; i < quotes.length; ++i) {
            if (quotes[i].pool == address(hp)) {
                assertEq(quotes[i].amountOut, factoryQuote, "bulk quote used the supplied executor");
                return;
            }
        }
        fail("hooked pool absent from discovery");
    }

    function test_DescribeGivesTheFrontendOneCall() public {
        PrecisionPoolLens lens = _lens();
        PrecisionPoolLens.PoolInfo[] memory m = lens.marketsForPair(address(0), address(usdc), trader, 0, 16, 1 ether);
        assertEq(m.length, 1);
        assertEq(m[0].pool, address(pool));
        assertEq(m[0].fee, FEE);
        assertEq(m[0].effectiveFee, FEE, "no hook, so nothing on top");
        assertEq(m[0].hook, address(0));
        assertEq(m[0].reserve0, pool.reserve0());
        assertEq(m[0].liquidity, pool.totalSupply());
        assertApproxEqRel(m[0].sqrtPriceCurrent, SQRT_MID, 0.001e18);
    }

    // ------------------------------------------- one-sided band = limit order

    /// @dev Seeded at its own lower bound with nothing but token0, the band
    /// holds only the asset it intends to sell and sells it as price climbs.
    /// That is a limit order - except it earns fees while it waits and the
    /// claim on it is a fungible ERC-20 rather than an NFT.
    function test_OneSidedBandIsALimitSell() public {
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p, uint256 lpOut,, uint256 used1) =
            factory.createAndSeed{value: 5 ether}(_mkt(3000, address(0)), SQRT_LOW, 5 ether, 0, 0, lp);
        vm.stopPrank();
        PrecisionPool ask = PrecisionPool(payable(p));

        assertGt(lpOut, 0, "shares minted from one asset alone");
        assertEq(used1, 0, "no counter-asset was required");
        assertEq(ask.reserve1(), 0, "holds only what it is selling");
        assertEq(ask.reserve0(), 5 ether);

        // The order fills as buyers lift it: they pay token1, the band sells
        // token0, and its price walks up toward the far bound.
        uint256 startPrice = ask.sqrtPriceCurrent();
        vm.startPrank(trader);
        usdc.approve(address(ask), type(uint256).max);
        uint256 got = ask.swapExactIn(address(usdc), 3_000e6, 0, trader);
        vm.stopPrank();

        assertGt(got, 0, "the resting side was sold");
        assertGt(ask.sqrtPriceCurrent(), startPrice, "and the fill walked the price up");
        assertGt(ask.reserve1(), 0, "proceeds accrued to the band");
    }

    /// @dev The other direction has nothing to give, and says so rather than
    /// pretending: a limit sell is not a two-way market.
    function test_OneSidedBandRefusesTheOtherDirection() public {
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 5 ether}(_mkt(3000, address(0)), SQRT_LOW, 5 ether, 0, 0, lp);
        vm.stopPrank();

        vm.prank(trader);
        vm.expectRevert(PrecisionPool.InsufficientOutput.selector);
        PrecisionPool(payable(p)).swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
    }

    /// @dev And the mirror image: seeded at the upper bound with token1 only,
    /// the band is a resting bid that buys token0 as price falls.
    function test_OneSidedBandAtTheUpperBoundIsALimitBuy() public {
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p, uint256 lpOut, uint256 used0,) =
            factory.createAndSeed(_mkt(10000, address(0)), SQRT_HIGH, 0, 20_000e6, 0, lp);
        vm.stopPrank();
        PrecisionPool bid = PrecisionPool(payable(p));

        assertGt(lpOut, 0);
        assertEq(used0, 0, "no ETH required to post a bid");
        assertEq(bid.reserve0(), 0, "holds only the asset it is paying with");
        assertGt(bid.reserve1(), 0);

        // Sellers hit it: they deliver token0 and the band pays out token1.
        vm.prank(trader);
        uint256 got = bid.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertGt(got, 0, "the bid was hit");
        assertEq(bid.reserve0(), 1 ether, "and it accumulated the asset it wanted");
    }

    /// @dev The useful case, and the one that avoids spawning a pool per
    /// order: once a band has been driven to its edge it holds one asset, and
    /// a further one-sided deposit joins it rather than founding a rival
    /// market. A band therefore behaves as a resting order at its bounds and
    /// as a two-way market in between, without changing identity.
    function test_ExistingBandAtItsEdgeAcceptsOneSidedDeposits() public {
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 5 ether}(_mkt(3000, address(0)), SQRT_LOW, 5 ether, 0, 0, lp);
        PrecisionPool ask = PrecisionPool(payable(p));
        assertEq(ask.reserve1(), 0, "resting at the lower bound");

        uint256 supplyBefore = ask.totalSupply();
        (, uint256 lp2, uint256 used0, uint256 used1) =
            factory.seed{value: 2 ether}(_mkt(3000, address(0)), 0, 2 ether, 0, 0, lp);
        vm.stopPrank();

        assertGt(lp2, 0, "joined the existing order");
        assertEq(used1, 0, "still one-sided");
        assertEq(used0, 2 ether);
        assertEq(ask.totalSupply(), supplyBefore + lp2);
        assertEq(ask.reserve0(), 7 ether, "one book, deeper");
    }

    // ------------------------------------------------------- fee compounding

    /// @dev Fees land in the reserves, and `totalSupply` is the liquidity, so
    /// a share's claim grows on its own. There is no fee accumulator to read
    /// and no collect() to call - the LP below does nothing at all and ends up
    /// entitled to more of both assets than it started with.
    function test_FeesCompoundWithNoHarvest() public {
        uint256 shares = pool.balanceOf(lp);
        uint256 supply0 = pool.totalSupply();
        uint256 claim0A = uint256(pool.reserve0()) * shares / supply0;
        uint256 claim0B = uint256(pool.reserve1()) * shares / supply0;

        for (uint256 i; i < 8; ++i) {
            vm.prank(trader);
            uint256 got = pool.swapExactIn{value: 0.5 ether}(address(0), 0.5 ether, 0, trader);
            vm.prank(trader);
            pool.swapExactIn(address(usdc), got, 0, trader);
        }

        assertEq(pool.totalSupply(), supply0, "no shares were minted by trading");
        assertEq(pool.balanceOf(lp), shares, "the LP did nothing");

        uint256 claim1A = uint256(pool.reserve0()) * shares / pool.totalSupply();
        uint256 claim1B = uint256(pool.reserve1()) * shares / pool.totalSupply();

        assertGe(claim1A, claim0A, "claim on token0 never shrank");
        assertGe(claim1B, claim0B, "claim on token1 never shrank");
        assertTrue(claim1A > claim0A || claim1B > claim0B, "and it grew");
    }

    // ------------------------------------------------------------------- hook

    function _hookedPool(address hook) internal returns (PrecisionPool hp) {
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 10 ether}(_mkt(FEE, hook), SQRT_MID, 10 ether, 30_000e6, 0, lp);
        vm.stopPrank();
        hp = PrecisionPool(payable(p));
    }

    function test_HookSeesTheSettledSwap() public {
        RecordingHook h = new RecordingHook();
        PrecisionPool hp = _hookedPool(address(h));

        vm.prank(trader);
        uint256 out = hp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);

        assertEq(h.calls(), 1, "called once");
        assertEq(h.lastSender(), trader, "sees the caller, which for a route is the router");
        assertEq(h.lastTokenIn(), address(0));
        assertEq(h.lastAmountIn(), 1 ether);
        assertEq(h.lastAmountOut(), out, "sees the settled output");
        assertEq(h.lastTo(), trader);
    }

    /// @dev The property that makes permissionless hooks safe to allow: a hook
    /// that reverts cannot take an immutable pool's liquidity hostage.
    function test_RevertingHookCannotBrickThePool() public {
        PrecisionPool hp = _hookedPool(address(new RevertingHook()));

        vm.prank(trader);
        uint256 out = hp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertGt(out, 0, "swap settled anyway");

        // And liquidity is still retrievable, which is the part that matters.
        uint256 shares = hp.balanceOf(lp);
        vm.prank(lp);
        (uint256 a0, uint256 a1) = hp.removeLiquidity(shares, 0, 0, lp);
        assertGt(a0 + a1, 0, "LP can still exit");
    }

    /// @dev A hook cannot tax swaps forever either: it gets a fixed budget and
    /// burning it is indistinguishable from reverting.
    function test_GasBurningHookIsCapped() public {
        PrecisionPool hp = _hookedPool(address(new GasBurnerHook()));

        uint256 before = gasleft();
        vm.prank(trader);
        uint256 out = hp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        uint256 used = before - gasleft();

        assertGt(out, 0, "swap still settled");
        assertLt(used, 400_000, "the burner was capped, not unbounded");
    }

    /// @dev Reached inside the reentrancy guard, so a hook calling back gets
    /// refused - and that refusal is swallowed like any other hook failure.
    function test_HookCannotReenter() public {
        ReenteringHook h = new ReenteringHook();
        PrecisionPool hp = _hookedPool(address(h));
        h.target(hp);

        vm.prank(trader);
        uint256 out = hp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);

        assertGt(out, 0);
        assertFalse(h.reentered(), "the callback did not get back in");
    }

    /// @dev A hook is another axis the same market can be split along, so the
    /// curation argument applies to it exactly as it does to bands.
    function test_DifferentHooksAreDifferentPools() public {
        address a = factory.poolFor(_mkt(FEE, address(0)));
        address b = factory.poolFor(_mkt(FEE, address(0xBEEF)));
        assertTrue(a != b, "the hook is part of the market identity");
        assertEq(a, address(pool));
    }

    // ------------------------------------------------------------- fee hooks

    function _feePool(address h) internal returns (PrecisionPool fp) {
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 10 ether}(_mkt(FEE, h), SQRT_MID, 10 ether, 30_000e6, 0, lp);
        vm.stopPrank();
        fp = PrecisionPool(payable(p));
    }

    /// @dev Rule 1: the surcharge is additive. An LP's terms are the pool's
    /// own fee on what is left, never less, whatever the hook does.
    function test_HookFeeIsAdditiveAndLpTermsAreUnchanged() public {
        FeeHook h = new FeeHook(1000); // +0.1%
        PrecisionPool fp = _feePool(address(h));

        uint256 r1Before = fp.reserve1();
        vm.prank(trader);
        fp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);

        // The hook took 0.1% of the input; the pool kept the rest.
        assertEq(fp.hookOwed0(), 1 ether * 1000 / 1_000_000, "hook paid exactly its slice");
        assertEq(fp.reserve0(), 10 ether + (1 ether - fp.hookOwed0()), "reserves got the remainder");
        assertLt(fp.reserve1(), r1Before, "and paid out against it");
    }

    /// @dev Rule 3, and the one that keeps routing honest: a quote still
    /// predicts the fill to the wei with a pricing hook attached.
    function test_QuoteStillMatchesTheFillWithAFeeHook() public {
        FeeHook h = new FeeHook(2500);
        PrecisionPool fp = _feePool(address(h));
        PrecisionPoolLens l = new PrecisionPoolLens(factory);

        uint256 predicted = l.quoteFor(address(fp), trader, address(0), 1 ether);
        assertGt(predicted, 0);

        vm.prank(trader);
        uint256 actual = fp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertEq(actual, predicted, "exact, hook included");
    }

    /// @dev A surcharge makes the trade worse than the same band without one,
    /// which is the whole point of it being additive.
    function test_SurchargeCostsTheTakerRelativeToNoHook() public {
        FeeHook h = new FeeHook(5000);
        PrecisionPool fp = _feePool(address(h));
        PrecisionPoolLens l = new PrecisionPoolLens(factory);

        assertLt(
            l.quoteFor(address(fp), trader, address(0), 1 ether),
            l.quoteFor(address(pool), trader, address(0), 1 ether),
            "the hooked band quotes worse"
        );
    }

    /// @dev A hostile answer is clamped, not obeyed. And pricing at the
    /// ceiling is how a hook turns flow away without any power to revert.
    function test_AbsurdSurchargeIsClampedAndActsAsASoftVeto() public {
        FeeHook h = new FeeHook(type(uint256).max);
        PrecisionPool fp = _feePool(address(h));

        assertEq(fp.extraFee(trader, address(0), 1 ether), 100_000 - FEE, "clamped to the ceiling");

        // Still settles - it is priced out, not blocked.
        vm.prank(trader);
        uint256 out = fp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertGt(out, 0);
        assertEq(fp.hookOwed0(), 1 ether * (100_000 - FEE) / 1_000_000);
    }

    function test_BrokenPricingHookChargesNothing() public {
        PrecisionPool fp = _feePool(address(new BrokenFeeHook()));
        assertEq(fp.extraFee(trader, address(0), 1 ether), 0, "unanswered means free");

        vm.prank(trader);
        uint256 out = fp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertGt(out, 0, "and the swap is unaffected");
        assertEq(fp.hookOwed0(), 0);
    }

    /// @dev The subtle one: an uncollected hook fee sits in the same balance
    /// as the reserves. If it were not netted out, the next swap would count
    /// somebody else's fee as its own input and pay it out twice.
    function test_UncollectedHookFeeIsNotCountedAsInput() public {
        FeeHook h = new FeeHook(10_000); // 1%, so the residue is obvious
        PrecisionPool fp = _feePool(address(h));

        vm.prank(trader);
        fp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        uint256 owed = fp.hookOwed0();
        assertGt(owed, 0);
        assertEq(address(fp).balance, fp.reserve0() + owed, "fee is sitting in the balance");

        PrecisionPoolLens l = new PrecisionPoolLens(factory);
        uint256 predicted = l.quoteFor(address(fp), trader, address(0), 1 ether);

        vm.prank(trader);
        uint256 actual = fp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertEq(actual, predicted, "the second swap saw only its own input");
        assertEq(fp.hookOwed0(), owed + 1 ether * 10_000 / 1_000_000, "and accrued once more");
    }

    function test_OnlyTheHookMayCollect() public {
        FeeHook h = new FeeHook(1000);
        PrecisionPool fp = _feePool(address(h));
        vm.prank(trader);
        fp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);

        vm.prank(trader);
        vm.expectRevert(PrecisionPool.NotHook.selector);
        fp.collectHookFees(trader);

        address dst = address(0xFEE5);
        uint256 owed = fp.hookOwed0();
        h.collect(fp, dst);
        assertEq(dst.balance, owed, "hook pulled exactly what it earned");
        assertEq(fp.hookOwed0(), 0);
        assertEq(address(fp).balance, fp.reserve0(), "balance back to reserves alone");
    }

    /// @dev Onchain discovery without an indexer: a user typing one ticker,
    /// and a creator opening a dashboard, each get everything in one call.
    function test_SearchByTokenAndByCreatorNeedNoIndexer() public {
        address creator = address(0xC0DE);
        PrecisionPoolFactory.Market memory m = _mkt(3000, address(0));
        m.feeRecipient = creator;
        m.creatorFeeBps = 1000;
        vm.prank(creator);
        factory.createPool(m);

        // One ticker is enough - no counter-asset, no canonical ordering.
        assertEq(factory.poolsForTokenCount(address(usdc)), 2, "both markets on USDC");
        assertEq(factory.poolsForTokenCount(address(0)), 2, "and on ETH");

        address[] memory mine = factory.poolsForCreatorSlice(creator, 0, 16);
        assertEq(mine.length, 1, "only the market naming this creator");

        PrecisionPoolLens l = new PrecisionPoolLens(factory);
        PrecisionPoolLens.PoolInfo[] memory info = l.marketsForCreator(creator, trader, 0, 16, 1 ether);
        assertEq(info.length, 1);
        assertEq(info[0].feeRecipient, creator);
        assertEq(info[0].creatorFeeBps, 1000, "terms readable without events");
    }

    // ---------------------------------------------------------- creator fee

    function _creatorPool(address recipient, uint256 shareBps) internal returns (PrecisionPool cp) {
        PrecisionPoolFactory.Market memory m = _mkt(FEE, address(0));
        m.feeRecipient = recipient;
        m.creatorFeeBps = shareBps;
        usdc.mint(recipient, 30_000e6);
        vm.deal(recipient, 100 ether);
        vm.startPrank(recipient);
        usdc.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 10 ether}(m, SQRT_MID, 10 ether, 30_000e6, 0, lp);
        vm.stopPrank();
        cp = PrecisionPool(payable(p));
    }

    /// @dev The defining property: a split changes who keeps the fee, not what
    /// the trade costs. The hooked pool quotes worse than the plain one; this
    /// one quotes identically.
    function test_CreatorSplitDoesNotChangeThePrice() public {
        address creator = address(0xC0DE);
        PrecisionPool cp = _creatorPool(creator, 2500); // 25% of the fee
        PrecisionPoolLens l = new PrecisionPoolLens(factory);

        assertEq(
            l.quoteFor(address(cp), trader, address(0), 1 ether),
            l.quoteFor(address(pool), trader, address(0), 1 ether),
            "takers are unaffected by the split"
        );
    }

    /// @dev And it is genuinely taken out of the LP's share, not conjured.
    function test_CreatorTakesItsShareOutOfTheFee() public {
        address creator = address(0xC0DE);
        PrecisionPool cp = _creatorPool(creator, 2500);

        vm.prank(trader);
        cp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);

        uint256 feeAmount = 1 ether * FEE / 1_000_000;
        assertEq(cp.creatorOwed0(), feeAmount * 2500 / 10_000, "exactly a quarter of the fee");

        // The pool kept the input less the creator's cut - LPs still earn the
        // other three quarters.
        assertEq(cp.reserve0(), 10 ether + 1 ether - cp.creatorOwed0());
    }

    function test_OnlyTheRecipientMayCollect() public {
        address creator = address(0xC0DE);
        PrecisionPool cp = _creatorPool(creator, 2500);
        vm.prank(trader);
        cp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        uint256 owed = cp.creatorOwed0();
        assertGt(owed, 0);

        vm.prank(trader);
        vm.expectRevert(PrecisionPool.NotFeeRecipient.selector);
        cp.collectCreatorFees(trader);

        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        cp.collectCreatorFees(creator);
        assertEq(creator.balance - creatorBefore, owed);
        assertEq(cp.creatorOwed0(), 0);
        assertEq(address(cp).balance, cp.reserve0(), "balance back to reserves alone");
    }

    /// @dev Uncollected creator fees share a balance with the reserves, same
    /// hazard as the hook's, so they must be netted out of the next input too.
    function test_UncollectedCreatorFeeIsNotCountedAsInput() public {
        PrecisionPool cp = _creatorPool(address(0xC0DE), 5000);
        vm.prank(trader);
        cp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertGt(cp.creatorOwed0(), 0);

        PrecisionPoolLens l = new PrecisionPoolLens(factory);
        uint256 predicted = l.quoteFor(address(cp), trader, address(0), 1 ether);
        vm.prank(trader);
        uint256 actual = cp.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        assertEq(actual, predicted, "second swap saw only its own input");
    }

    function test_IncoherentCreatorConfigIsRefused() public {
        PrecisionPoolFactory.Market memory m = _mkt(3000, address(0));
        // A share with nobody to pay.
        m.creatorFeeBps = 1000;
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(m);

        // A payee owed no split is legitimate, not a mistake: it is how a
        // market names its creator for a surcharge hook to read.
        m.creatorFeeBps = 0;
        m.feeRecipient = address(0xC0DE);
        vm.prank(address(0xC0DE));
        address named = factory.createPool(m);
        assertEq(PrecisionPool(payable(named)).feeRecipient(), address(0xC0DE));
        assertEq(PrecisionPool(payable(named)).creatorFeeBps(), 0);

        // Beyond the ceiling.
        m.fee = 4000; // a different market, so it is not merely a duplicate
        m.creatorFeeBps = 5001;
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(m);
    }

    // ------------------------------------------------------------------- fuzz

    /// @dev The core safety property: whatever the trade, the price stays
    /// inside the band and a swap never hands out more than the pool holds.
    function testFuzz_PriceStaysInsideTheBand(uint256 ethIn, bool buy) public {
        ethIn = bound(ethIn, 1, 50 ether);

        if (buy) {
            uint256 usdcIn = bound(ethIn, 1e6, 60_000e6);
            vm.prank(trader);
            try pool.swapExactIn(address(usdc), usdcIn, 0, trader) {} catch {}
        } else {
            vm.prank(trader);
            try pool.swapExactIn{value: ethIn}(address(0), ethIn, 0, trader) {} catch {}
        }

        uint256 s = pool.sqrtPriceCurrent();
        if (s == 0) return;
        assertGe(s, SQRT_LOW, "never below the band");
        assertLe(s, SQRT_HIGH, "never above the band");
        assertLe(pool.reserve0(), address(pool).balance, "reserves back by real balance");
        assertLe(pool.reserve1(), usdc.balanceOf(address(pool)), "reserves back by real balance");
    }
}
