// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {ERC20} from "../lib/solady/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "../lib/solady/src/utils/FixedPointMathLib.sol";
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

contract ArgumentSensitiveFeeHook {
    address immutable expectedSender;
    address immutable expectedToken;
    uint256 immutable expectedAmount;

    constructor(address sender_, address token_, uint256 amount_) {
        (expectedSender, expectedToken, expectedAmount) = (sender_, token_, amount_);
    }

    function feeFor(address sender, address token, uint256 amount) external view returns (uint256) {
        return sender == expectedSender && token == expectedToken && amount == expectedAmount ? 1234 : 0;
    }

    function afterSwap(address, address, uint256, uint256, address) external {}
}

/// @dev Mirrors zRouter's public SafeExecutor property: anyone can make it
/// call a target, so a factory cannot treat its address as proof that a route
/// was freshly funded.
contract PublicExecutor {
    function execute(address target, bytes calldata data) external payable {
        (bool ok, bytes memory result) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
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

    /// @dev A quote of zero means the pool will not take the trade. In
    /// particular, a one-wei input must not become an unnoticed donation just
    /// because integer division rounds the output down.
    function test_RoundedZeroOutputIsRefused() public {
        PrecisionPoolLens lens = _lens();
        assertEq(lens.quote(address(pool), address(0), 1), 0, "lens marks dust unfillable");

        uint256 reserve0Before = pool.reserve0();
        uint256 reserve1Before = pool.reserve1();
        vm.prank(trader);
        vm.expectRevert(PrecisionPool.InsufficientOutput.selector);
        pool.swapExactIn{value: 1}(address(0), 1, 0, trader);

        assertEq(pool.reserve0(), reserve0Before, "dust input was not retained");
        assertEq(pool.reserve1(), reserve1Before, "no output was paid");
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
        (bool ok,) =
            address(pool).call(abi.encodeWithSignature("swap(address,uint256,address)", address(usdc), 0, trader));
        assertFalse(ok, "the removed prefund selector has no callable fallback");
    }

    function test_UntrustedExecutorCannotSpendFactoryTokenDust() public {
        usdc.mint(address(factory), 5_000e6);
        vm.expectRevert(PrecisionPoolFactory.NotExecutor.selector);
        factory.executePrefundedSwap(address(pool), address(usdc), 5_000e6, 0, trader);
    }

    function test_PublicExecutorCannotSpendFactoryDustWithoutAFreshCheckpoint() public {
        PublicExecutor executor = new PublicExecutor();
        PrecisionPoolFactory securedFactory = new PrecisionPoolFactory(address(executor));

        vm.startPrank(lp);
        usdc.approve(address(securedFactory), type(uint256).max);
        (address securedPool,,,) =
            securedFactory.createAndSeed{value: 10 ether}(_mkt(FEE, address(0)), SQRT_MID, 10 ether, 30_000e6, 0, lp);
        vm.stopPrank();

        uint256 dust = 5_000e6;
        usdc.mint(address(securedFactory), dust);
        bytes memory settlement = abi.encodeCall(
            PrecisionPoolFactory.executePrefundedSwap, (securedPool, address(usdc), dust, uint256(0), trader)
        );

        // Anyone can use the public executor, but old factory balances are not
        // route funding and are therefore unavailable to them.
        vm.expectRevert(PrecisionPoolFactory.BadCheckpoint.selector);
        executor.execute(address(securedFactory), settlement);

        // The normal route is explicit: checkpoint first, fund second, consume
        // the exact fresh delta. The old dust stays where it was.
        executor.execute(address(securedFactory), abi.encodeCall(PrecisionPoolFactory.checkpoint, (address(usdc))));
        usdc.mint(address(securedFactory), dust);
        executor.execute(address(securedFactory), settlement);
        assertEq(usdc.balanceOf(address(securedFactory)), dust, "only fresh route input was spent");
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

    function test_NonContractTokensAndHooksAreRefused() public {
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(_mktRaw(address(0), address(0xBEEF), SQRT_LOW, SQRT_HIGH, FEE, address(0)));

        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(_mktRaw(address(0), address(usdc), SQRT_LOW, SQRT_HIGH, FEE, address(0xBEEF)));

        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        new PrecisionPoolFactory(address(0xBEEF));
    }

    function test_InvertedOrEmptyRangeIsRefused() public {
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(_mktRaw(address(0), address(usdc), SQRT_HIGH, SQRT_LOW, FEE, address(0)));
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(_mktRaw(address(0), address(usdc), SQRT_LOW, SQRT_LOW, FEE, address(0)));
    }

    function test_PriceOutsideTheSafeArithmeticDomainIsRefused() public {
        PrecisionPoolFactory.Market memory m = _mktRaw(address(0), address(usdc), 1e36 - 1, 1e36 + 1, FEE, address(0));
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.createPool(m);
    }

    /// @dev A one-unit-wide range can make LP supply grow much faster than the
    /// real reserve. The supply cap keeps its virtual reserves in uint256.
    function test_ExcessiveLiquidityFromAnUltraNarrowRangeIsRefused() public {
        uint256 amount1 = 1e21;
        usdc.mint(lp, amount1);
        PrecisionPoolFactory.Market memory m = _mktRaw(address(0), address(usdc), 1 ether, 1 ether + 1, FEE, address(0));

        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        vm.expectRevert(PrecisionPool.InsufficientLiquidity.selector);
        factory.createAndSeed(m, 1 ether + 1, 0, amount1, 0, lp);
        vm.stopPrank();
    }

    /// @dev If either virtual reserve rounds to zero at inception, a one-sided
    /// pool at that edge cannot quote or move off the edge. Reject it instead
    /// of creating a permanently unusable market.
    function test_SeedRequiresNonzeroVirtualReserves() public {
        uint256 amount0 = 1e21;
        vm.deal(lp, amount0);
        PrecisionPoolFactory.Market memory m = _mktRaw(address(0), address(usdc), 1, 2, FEE, address(0));

        vm.prank(lp);
        vm.expectRevert(PrecisionPool.InsufficientLiquidity.selector);
        factory.createAndSeed{value: amount0}(m, 1, amount0, 0, 0, lp);
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

    function test_NamedMarketCannotBeInitializedAroundTheCreatorCheck() public {
        address creator = address(0xC0DE);
        PrecisionPoolFactory.Market memory m = _mkt(3000, address(0));
        m.feeRecipient = creator;

        vm.prank(creator);
        address named = factory.createPool(m);

        vm.startPrank(trader);
        usdc.approve(named, type(uint256).max);
        vm.expectRevert(PrecisionPool.NotFactory.selector);
        PrecisionPool(payable(named)).addLiquidityExact{value: 1 ether}(SQRT_MID, 1 ether, 3_000e6, 0, trader);
        vm.stopPrank();

        usdc.mint(creator, 3_000e6);
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        usdc.approve(address(factory), type(uint256).max);
        factory.seed{value: 1 ether}(m, SQRT_MID, 1 ether, 3_000e6, 0, creator);
        vm.stopPrank();

        assertGt(PrecisionPool(payable(named)).totalSupply(), 0, "creator initialized through the authenticated path");
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
        assertEq(m[0].effectiveFee0, FEE, "no hook, so nothing on top");
        assertEq(m[0].hook, address(0));
        assertEq(m[0].reserve0, pool.reserve0());
        assertEq(m[0].liquidity, pool.totalSupply());
        assertApproxEqRel(m[0].sqrtPriceCurrent, SQRT_MID, 0.001e18);
    }

    function test_DescribeReportsTheCompoundedEffectiveFee() public {
        FeeHook h = new FeeHook(10_000);
        PrecisionPool fp = _feePool(address(h));
        PrecisionPoolLens l = _lens();
        PrecisionPoolLens.PoolInfo memory m = l.infoFor(address(fp), trader, 1 ether);

        // The surcharge is taken first and the base fee applies to the
        // remainder: 1% + 0.05% - their 0.0005% overlap.
        assertEq(m.effectiveFee0, 10_495);
        assertEq(l.effectiveFeeFor(address(fp), trader, address(usdc), 1_000e6), 10_495);
    }

    function test_LensRejectsAnInvalidFactory() public {
        vm.expectRevert(PrecisionPoolLens.BadFactory.selector);
        new PrecisionPoolLens(PrecisionPoolFactory(address(0)));

        vm.expectRevert(PrecisionPoolLens.BadFactory.selector);
        new PrecisionPoolLens(PrecisionPoolFactory(address(0xBEEF)));
    }

    // ------------------------------------------- one-sided band = limit order

    /// @dev Seeded at its own lower bound with nothing but token0, the band
    /// holds only the asset it intends to sell and sells it as price climbs.
    /// That is a limit order - except it earns fees while it waits and the
    /// claim on it is a fungible ERC-20 rather than an NFT.
    function test_OneSidedBandIsALimitSell() public {
        uint256 balanceBefore = lp.balance;
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p, uint256 lpOut, uint256 used0, uint256 used1) =
            factory.createAndSeed{value: 5 ether}(_mkt(3000, address(0)), SQRT_LOW, 5 ether, 0, 0, lp);
        vm.stopPrank();
        PrecisionPool ask = PrecisionPool(payable(p));

        assertGt(lpOut, 0, "shares minted from one asset alone");
        assertEq(used1, 0, "no counter-asset was required");
        assertEq(ask.reserve1(), 0, "holds only what it is selling");
        assertEq(ask.reserve0(), used0, "reported usage matches reserves");
        assertLe(used0, 5 ether, "seed never consumes more than supplied");
        assertEq(lp.balance, balanceBefore - used0, "rounding excess was refunded");

        // The order fills as buyers lift it: they pay token1, the band sells
        // token0, and its price walks up toward the far bound.
        uint256 startPrice = ask.sqrtPriceCurrent();
        assertGe(startPrice, SQRT_LOW, "seed rounding stayed inside the lower bound");
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
        assertLe(bid.sqrtPriceCurrent(), SQRT_HIGH, "seed rounding stayed inside the upper bound");

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
        uint256 reserveBefore = ask.reserve0();
        uint256 balanceBefore = lp.balance;
        (, uint256 lp2, uint256 used0, uint256 used1) =
            factory.seed{value: 2 ether}(_mkt(3000, address(0)), 0, 2 ether, 0, 0, lp);
        vm.stopPrank();

        assertGt(lp2, 0, "joined the existing order");
        assertEq(used1, 0, "still one-sided");
        assertLe(used0, 2 ether, "rounding never over-consumes");
        assertEq(lp.balance, balanceBefore - used0, "unused input was refunded");
        assertEq(ask.totalSupply(), supplyBefore + lp2);
        assertEq(ask.reserve0(), reserveBefore + used0, "one book, deeper");
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

    function test_PricingHookReceivesEveryEncodedArgument() public {
        uint256 expectedAmount = 123e6;
        ArgumentSensitiveFeeHook h = new ArgumentSensitiveFeeHook(trader, address(usdc), expectedAmount);
        PrecisionPool hp = _hookedPool(address(h));

        assertEq(hp.extraFee(trader, address(usdc), expectedAmount), 1234);
        assertEq(hp.extraFee(lp, address(usdc), expectedAmount), 0);
        assertEq(hp.extraFee(trader, address(0), expectedAmount), 0);
        assertEq(hp.extraFee(trader, address(usdc), expectedAmount + 1), 0);
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

    /// @dev The portfolio read: one call answers "what do I own", and the
    /// amounts are what redeeming would actually pay rather than an estimate.
    function test_PositionsOfIsThePortfolioViewAndMatchesRedemption() public {
        PrecisionPoolLens l = _lens();

        // A second band the LP also holds, and a third they do not.
        vm.startPrank(lp);
        usdc.approve(address(factory), type(uint256).max);
        (address p2,,,) = factory.createAndSeed{value: 5 ether}(
            _mkt(3000, address(0)), SQRT_MID, 5 ether, 20_000e6, 0, lp
        );
        factory.createPool(_mkt(10000, address(0)));
        vm.stopPrank();

        PrecisionPoolLens.Position[] memory pos = l.positionsOf(lp, 0, 100);
        assertEq(pos.length, 2, "only bands actually held, empty ones dropped");
        assertEq(pos[0].pool, address(pool));
        assertEq(pos[1].pool, p2);
        assertEq(pos[0].shares, pool.balanceOf(lp));

        // The reported claim is exactly what redeeming pays.
        uint256 shares = pos[0].shares;
        uint256 expect0 = pos[0].amount0;
        uint256 expect1 = pos[0].amount1;
        vm.prank(lp);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(shares, 0, 0, lp);
        assertEq(a0, expect0, "token0 claim was exact");
        assertEq(a1, expect1, "token1 claim was exact");

        // And a holder of nothing sees nothing.
        assertEq(l.positionsOf(address(0xBEEF11), 0, 100).length, 0);
    }

    // ------------------------------------------------------------- fee drift

    /// @dev The band's floor implies a maximum token0 holding for a given `L`:
    ///      x_max = L * (1/sqrtPLow - 1/sqrtPHigh). Retained fees push the real
    ///      reserve past it, which is what nudges the implied price outside the
    ///      stated bounds.
    function _xMax(uint256 L) internal pure returns (uint256) {
        return
            FixedPointMathLib.fullMulDiv(
                FixedPointMathLib.fullMulDiv(L, SQRT_HIGH - SQRT_LOW, SQRT_HIGH), 1e18, SQRT_LOW
            );
    }

    /// @dev Retained fees grow the reserves while `L` - and the virtual
    ///      offsets derived from it - stay put, so token0 ends up EXCEEDING
    ///      what `L` implies the band holds at its floor. The interesting part
    ///      is that this over-collateralisation does not push the price out of
    ///      the band: containment still holds, and the surplus is simply fees
    ///      the pool kept. Pinned here because the excess is easy to mistake
    ///      for an accounting error when reading reserves directly.
    function test_RetainedFeesOvercollateraliseWithoutBreakingTheBand() public {
        PrecisionPoolLens l = _lens();
        uint256 low = 1;
        uint256 high = 1_000 ether;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (l.quote(address(pool), address(0), mid) == 0) high = mid - 1;
            else low = mid;
        }

        uint256 supply = pool.totalSupply();
        vm.prank(trader);
        pool.swapExactIn{value: low}(address(0), low, 0, trader);

        uint256 p = pool.sqrtPriceCurrent();
        uint256 ppm = p >= SQRT_LOW ? 0 : (SQRT_LOW - p) * 1_000_000 / SQRT_LOW;
        emit log_named_uint("drift below floor (ppm)", ppm);
        emit log_named_uint("reserve0            ", pool.reserve0());
        emit log_named_uint("x_max implied by L  ", _xMax(supply));

        // Small, and in the LPs' favour: the pool holds more token0 than the
        // band's floor implies, which is the retained fee and nothing else.
        assertEq(ppm, 0, "containment holds - the price never leaves the band");
        assertEq(pool.totalSupply(), supply, "no shares were minted by the swap");
        assertGt(pool.reserve0(), _xMax(supply), "and the pool holds MORE than L implies");
    }

    // ---------------------------------------------------------------- permit2

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Solady fixes Permit2's allowance at infinity by default, and the
    /// pool does not override it. So LP shares reach Permit2 with no approval
    /// transaction at all - not a cheaper approval, none.
    function test_LpSharesNeedNoApprovalForPermit2() public view {
        assertEq(pool.allowance(lp, PERMIT2), type(uint256).max, "infinite without approving");
        assertEq(pool.allowance(address(0xDEAD), PERMIT2), type(uint256).max, "for anyone");
    }

    function test_Permit2CanMoveLpSharesWithNoPriorApproval() public {
        uint256 amount = pool.balanceOf(lp) / 4;
        address dst = address(0xD57);

        vm.prank(PERMIT2);
        pool.transferFrom(lp, dst, amount);

        assertEq(pool.balanceOf(dst), amount, "moved on Permit2's authority alone");
        assertEq(pool.allowance(lp, PERMIT2), type(uint256).max, "and stays infinite");
    }

    /// @dev The integration hazard this creates: the usual "approve an exact
    /// amount to Permit2" step does not merely waste gas, it REVERTS. A
    /// frontend carrying that step for ordinary tokens must skip it here.
    function test_ApprovingPermit2AnExactAmountReverts() public {
        vm.prank(lp);
        vm.expectRevert(ERC20.Permit2AllowanceIsFixedAtInfinity.selector);
        pool.approve(PERMIT2, 1_000);

        // Approving the maximum is accepted, as a no-op.
        vm.prank(lp);
        assertTrue(pool.approve(PERMIT2, type(uint256).max));
    }

    /// @dev And the same applies to a 2612 permit aimed at Permit2, which is
    /// the gasless variant of the same mistake.
    function test_Permit2612ToPermit2ForAnExactAmountAlsoReverts() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                pool.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        PERMIT2,
                        uint256(1_000),
                        pool.nonces(signer),
                        block.timestamp + 1 days
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 sig) = vm.sign(pk, digest);
        vm.expectRevert(ERC20.Permit2AllowanceIsFixedAtInfinity.selector);
        pool.permit(signer, PERMIT2, 1_000, block.timestamp + 1 days, v, r, sig);
    }

    /// @dev Each pool still signs in its own domain, despite every pool
    /// sharing the name "Precision LP" - the separator binds the address.
    function test_PermitDomainIsPerPoolDespiteASharedName() public {
        vm.prank(lp);
        address other = factory.createPool(_mkt(3000, address(0)));
        assertEq(pool.name(), PrecisionPool(payable(other)).name(), "same name");
        assertTrue(
            pool.DOMAIN_SEPARATOR() != PrecisionPool(payable(other)).DOMAIN_SEPARATOR(),
            "but signatures cannot cross pools"
        );
    }

    // ------------------------------------------------------------------- fuzz

    function testFuzz_SeedPriceStaysInsideTheBand(uint256 sqrtPriceInit) public {
        sqrtPriceInit = bound(sqrtPriceInit, SQRT_LOW, SQRT_HIGH);
        vm.prank(lp);
        (address p,,,) =
            factory.createAndSeed{value: 10 ether}(_mkt(777, address(0)), sqrtPriceInit, 10 ether, 30_000e6, 0, lp);

        uint256 actual = PrecisionPool(payable(p)).sqrtPriceCurrent();
        assertGe(actual, SQRT_LOW, "seed rounding never starts below the band");
        assertLe(actual, SQRT_HIGH, "seed rounding never starts above the band");
    }

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

    function test_MaximumFillKeepsPriceInsideTheBand() public {
        PrecisionPoolLens lens = _lens();
        uint256 low = 1;
        uint256 high = 1_000 ether;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (lens.quote(address(pool), address(0), mid) == 0) high = mid - 1;
            else low = mid;
        }

        vm.prank(trader);
        pool.swapExactIn{value: low}(address(0), low, 0, trader);

        // Hard containment is NOT a property of this design and asserting it
        // fails for a benign reason. Retained fees grow the reserves while `L`
        // - and therefore the virtual offsets derived from it - stays put, so
        // token0 can exceed what `L` says the band holds at its floor and the
        // implied price slips just below it. The pool is over-collateralised,
        // not under: it holds MORE than `L` implies, and the excess is exactly
        // the fees it kept. See test_FeeDriftIsBoundedAndFavoursLps for the
        // magnitude and the direction.
        assertGe(pool.sqrtPriceCurrent(), SQRT_LOW, "fee retention moved price below the immutable band");
    }

    function test_MaximumReverseFillKeepsPriceInsideTheBand() public {
        PrecisionPoolLens lens = _lens();
        uint256 low = 1;
        uint256 high = 10_000_000e6;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (lens.quote(address(pool), address(usdc), mid) == 0) high = mid - 1;
            else low = mid;
        }

        vm.prank(trader);
        pool.swapExactIn(address(usdc), low, 0, trader);
        assertLe(pool.sqrtPriceCurrent(), SQRT_HIGH, "fee retention moved price above the immutable band");
    }
}
