// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {Collectol} from "../src/forwarders/Collectol.sol";
import {CollectolLens} from "../src/forwarders/CollectolLens.sol";

interface IWETH9 {
    function deposit() external payable;
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IZAMMSwap {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function swapExactIn(PoolKey calldata, uint256, uint256, bool, address, uint256)
        external
        payable
        returns (uint256);
}

contract CollectolTest is Test {
    address constant SALE = 0x824d11a46F32cd16cdF46380314343e9697e2491;
    address constant SHARES = 0x883d646d0C8202Aa23F01d4aF45E4E73804c3a49;
    address constant ZAMM = 0x000000000000040470635EB91b7CE4D132D616eD;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FEE = 30;

    Collectol col;
    CollectolLens lens;
    uint256 colEthBase;

    address alice = address(0xA11CE);
    address refund = address(0xBEEF);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        col = new Collectol(SALE, FEE);
        lens = new CollectolLens();
        colEthBase = address(col).balance;
        vm.deal(alice, 1000 ether);
        vm.deal(address(lens), 10 ether);
    }

    function _cap(uint256 rate) internal view returns (uint256) {
        return lens.maxSaleEth(SALE, rate);
    }

    function _rate() internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        uint256 r = lens.probeSaleRate(SALE, 1 ether);
        vm.revertToState(snap);
        return r;
    }

    function testWiring() public view {
        assertEq(col.shares(), SHARES);
        assertEq(col.sale(), SALE);
        assertEq(col.feeOrHook(), FEE);
        (uint256 r0, uint256 r1) = lens.reserves(SHARES, FEE);
        assertGt(r0, 0);
        assertGt(r1, 0);
    }

    function testProbedRate() public {
        uint256 rate = _rate();
        console.log("sale rate (shares per ETH):", rate / 1e18);
        assertGt(rate, 0);
    }

    /// Sale above pool spot: the whole order should mint, nothing to the curve.
    function testExactInPrefersSaleWhenPoolIsWorse() public {
        uint256 rate = _rate();
        CollectolLens.Plan memory p = lens.planExactIn(SHARES, FEE, 1 ether, rate, _cap(rate), 100);
        assertEq(p.poolAmount, 0, "pool should get nothing");
        assertEq(p.ethToSale, 1 ether);

        vm.prank(alice);
        col.buy{value: p.totalIn}(
            p.ethToSale, p.poolAmount, p.poolLimit, p.poolExactOut, p.minTotalOut, alice, refund, block.timestamp + 60
        );
        assertGe(IERC20(SHARES).balanceOf(alice), p.minTotalOut);
        assertEq(IERC20(SHARES).balanceOf(address(col)), 0, "no output stranded");
        assertEq(address(col).balance, colEthBase, "no ETH stranded");
    }

    /// Dump shares into the pool until it trades below the sale rate, then the
    /// optimum must be a genuine split that beats either venue alone.
    function testExactInSplitsAfterPoolIsDumped() public {
        uint256 rate = _rate();

        // Buy a large block from the sale, then sell it into the pool to push
        // the curve down. This is the state the split exists for.
        vm.startPrank(alice);
        (bool ok,) = SALE.call{value: 5 ether}(abi.encodeWithSignature("buy()"));
        require(ok, "sale buy failed");
        uint256 held = IERC20(SHARES).balanceOf(alice);
        IERC20(SHARES).approve(ZAMM, type(uint256).max);
        IZAMMSwap.PoolKey memory key =
            IZAMMSwap.PoolKey({id0: 0, id1: 0, token0: address(0), token1: SHARES, feeOrHook: FEE});
        IZAMMSwap(ZAMM).swapExactIn(key, held, 0, false, alice, block.timestamp + 60);
        vm.stopPrank();

        uint256 spend = 1 ether;
        CollectolLens.Plan memory split = lens.planExactIn(SHARES, FEE, spend, rate, _cap(rate), 100);
        console.log("ethToSale", split.ethToSale);
        console.log("ethToPool", split.poolAmount);
        assertGt(split.poolAmount, 0, "pool should take some");

        // The split must beat both single-venue plans.
        CollectolLens.Plan memory allPool = lens.planExactIn(SHARES, FEE, spend, 0, 0, 100);
        uint256 allSaleOut = spend * rate / 1e18;
        assertGe(split.totalOut, allPool.totalOut, "split beats all-pool");
        assertGe(split.totalOut, allSaleOut, "split beats all-sale");

        address bob = address(0xB0B);
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        col.buy{value: split.totalIn}(
            split.ethToSale,
            split.poolAmount,
            split.poolLimit,
            split.poolExactOut,
            split.minTotalOut,
            bob,
            refund,
            block.timestamp + 60
        );
        assertGe(IERC20(SHARES).balanceOf(bob), split.minTotalOut);
        assertEq(IERC20(SHARES).balanceOf(address(col)), 0);
        assertEq(address(col).balance, colEthBase);
    }

    function testExactOutDeliversAtLeastRequested() public {
        uint256 rate = _rate();
        uint256 want = 2_000_000 ether; // 2M shares
        CollectolLens.Plan memory p = lens.planExactOut(SHARES, FEE, want, rate, _cap(rate), 100);

        vm.prank(alice);
        col.buy{value: p.totalIn}(
            p.ethToSale, p.poolAmount, p.poolLimit, p.poolExactOut, p.minTotalOut, alice, refund, block.timestamp + 60
        );
        assertGe(IERC20(SHARES).balanceOf(alice), want, "short of exact out");
        assertEq(IERC20(SHARES).balanceOf(address(col)), 0);
        assertEq(address(col).balance, colEthBase);
    }

    function testExactOutRefundsUnspentToRefundTo() public {
        uint256 rate = _rate();
        // Force a pool leg so there is an exact-out maximum to refund from.
        CollectolLens.Plan memory p = lens.planExactOut(SHARES, FEE, 50_000 ether, 0, 0, 500);
        assertTrue(p.poolExactOut);
        uint256 before = refund.balance;
        vm.prank(alice);
        col.buy{value: p.totalIn}(
            p.ethToSale, p.poolAmount, p.poolLimit, p.poolExactOut, p.minTotalOut, alice, refund, block.timestamp + 60
        );
        assertGt(refund.balance, before, "slippage headroom not refunded");
        assertEq(address(col).balance, colEthBase);
    }

    /// Overfunding is refunded rather than rejected: leg 1 routinely lands above
    /// the floor the plan was built on, and reverting on that would fail most
    /// token routes. The excess must not buy a bigger position than was quoted.
    function testOverfundingIsRefundedNotRejected() public {
        vm.deal(refund, 1 wei); // fork needs the refund account to exist
        uint256 before = refund.balance;
        vm.prank(alice);
        col.buy{value: 1 ether + 1}(1 ether, 0, 0, false, 0, alice, refund, block.timestamp + 60);
        assertEq(refund.balance - before, 1, "excess not refunded");
    }

    function testRejectsLimitWithoutPoolLeg() public {
        vm.prank(alice);
        vm.expectRevert(Collectol.BadPlan.selector);
        col.buy{value: 1 ether}(1 ether, 0, 1, false, 0, alice, refund, block.timestamp + 60);
    }

    function testRejectsZeroDeadline() public {
        vm.prank(alice);
        vm.expectRevert(Collectol.DeadlineExpired.selector);
        col.buy{value: 1 ether}(1 ether, 0, 0, false, 0, alice, refund, 0);
    }

    function testRejectsSelfRecipient() public {
        vm.prank(alice);
        vm.expectRevert(Collectol.BadPlan.selector);
        col.buy{value: 1 ether}(1 ether, 0, 0, false, 0, address(col), refund, block.timestamp + 60);
    }

    function testRejectsEmptyPlan() public {
        vm.prank(alice);
        vm.expectRevert(Collectol.BadPlan.selector);
        col.buy{value: 0}(0, 0, 0, false, 0, alice, refund, block.timestamp + 60);
    }

    function testMinTotalOutBinds() public {
        uint256 rate = _rate();
        CollectolLens.Plan memory p = lens.planExactIn(SHARES, FEE, 1 ether, rate, _cap(rate), 100);
        vm.prank(alice);
        vm.expectRevert();
        col.buy{value: p.totalIn}(
            p.ethToSale, p.poolAmount, p.poolLimit, p.poolExactOut, p.totalOut * 2, alice, refund, block.timestamp + 60
        );
    }

    /// Shares sitting here before the call are outside the measured delta and
    /// must not be handed to whoever calls next.
    function testDonatedSharesAreNotSwept() public {
        vm.startPrank(alice);
        (bool ok,) = SALE.call{value: 1 ether}(abi.encodeWithSignature("buy()"));
        require(ok, "sale buy failed");
        uint256 donation = IERC20(SHARES).balanceOf(alice);
        IERC20(SHARES).transfer(address(col), donation);
        vm.stopPrank();

        uint256 rate = _rate();
        CollectolLens.Plan memory p = lens.planExactIn(SHARES, FEE, 1 ether, rate, _cap(rate), 100);
        address bob = address(0xB0B);
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        col.buy{value: p.totalIn}(
            p.ethToSale, p.poolAmount, p.poolLimit, p.poolExactOut, p.minTotalOut, bob, refund, block.timestamp + 60
        );
        assertLt(IERC20(SHARES).balanceOf(bob), donation + p.totalOut, "donation leaked to caller");
        assertEq(IERC20(SHARES).balanceOf(address(col)), donation, "donation should stay put");
    }

    /// Pre-existing ETH must not be spendable as someone's change either.
    function testDonatedEthIsNotSwept() public {
        vm.deal(address(col), colEthBase + 3 ether);
        uint256 rate = _rate();
        CollectolLens.Plan memory p = lens.planExactIn(SHARES, FEE, 1 ether, rate, _cap(rate), 100);
        uint256 before = refund.balance;
        vm.prank(alice);
        col.buy{value: p.totalIn}(
            p.ethToSale, p.poolAmount, p.poolLimit, p.poolExactOut, p.minTotalOut, alice, refund, block.timestamp + 60
        );
        assertEq(refund.balance, before, "donated ETH leaked as change");
        assertEq(address(col).balance, colEthBase + 3 ether);
    }

    function testFuzzExactInNeverWorseThanEitherVenue(uint96 amount) public {
        amount = uint96(bound(amount, 0.001 ether, 100 ether));
        uint256 rate = _rate();
        uint256 cap = _cap(rate);
        CollectolLens.Plan memory split = lens.planExactIn(SHARES, FEE, amount, rate, cap, 100);
        CollectolLens.Plan memory allPool = lens.planExactIn(SHARES, FEE, amount, 0, 0, 100);
        assertGe(split.totalOut, allPool.totalOut, "worse than all-pool");
        // All-sale is only a valid comparison while the DAO allowance covers the
        // whole order; past that ceiling it is not a route anyone could take.
        if (amount <= cap) assertGe(split.totalOut, uint256(amount) * rate / 1e18, "worse than all-sale");
        assertLe(split.ethToSale, cap, "sale leg exceeds allowance");
        assertEq(split.ethToSale + split.poolAmount, amount, "plan does not spend the input");
    }
}

contract CollectolWethTest is CollectolTest {
    /// The token-route shape: funding arrives as WETH, not value.
    function testWethFundingBuysTheSamePlan() public {
        uint256 rate = _rate();
        CollectolLens.Plan memory p = lens.planExactIn(SHARES, FEE, 1 ether, rate, _cap(rate), 100);

        // Stand in for snwap sweeping the router's WETH into the executor.
        vm.startPrank(alice);
        IWETH9(WETH).deposit{value: p.totalIn}();
        IWETH9(WETH).transfer(address(col), p.totalIn);
        col.buy(
            p.ethToSale, p.poolAmount, p.poolLimit, p.poolExactOut, p.minTotalOut, alice, refund, block.timestamp + 60
        );
        vm.stopPrank();

        assertGe(IERC20(SHARES).balanceOf(alice), p.minTotalOut, "WETH funding did not buy");
        assertEq(IWETH9(WETH).balanceOf(address(col)), 0, "WETH left unwrapped");
        assertEq(address(col).balance, colEthBase, "ETH stranded");
    }

    /// Leg 1 landing above its quoted floor must come back, not buy more.
    function testOvershootIsRefundedNotSpent() public {
        uint256 rate = _rate();
        CollectolLens.Plan memory p = lens.planExactIn(SHARES, FEE, 1 ether, rate, _cap(rate), 100);
        uint256 overshoot = 0.3 ether;

        uint256 before = refund.balance;
        vm.prank(alice);
        col.buy{value: p.totalIn + overshoot}(
            p.ethToSale, p.poolAmount, p.poolLimit, p.poolExactOut, p.minTotalOut, alice, refund, block.timestamp + 60
        );
        assertEq(refund.balance - before, overshoot, "overshoot not refunded exactly");
        assertEq(IERC20(SHARES).balanceOf(alice), p.totalOut, "overshoot bought extra");
        assertEq(address(col).balance, colEthBase);
    }

    /// Underfunding still fails closed.
    function testUnderfundingReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Collectol.InputMismatch.selector, 1 ether, 1 ether - 1));
        col.buy{value: 1 ether - 1}(1 ether, 0, 0, false, 0, alice, refund, block.timestamp + 60);
    }

    /// A single wei of donated WETH must not be able to break every route.
    function testWethDonationDoesNotGriefRoutes() public {
        vm.startPrank(alice);
        IWETH9(WETH).deposit{value: 1}();
        IWETH9(WETH).transfer(address(col), 1);
        vm.stopPrank();

        uint256 rate = _rate();
        CollectolLens.Plan memory p = lens.planExactIn(SHARES, FEE, 1 ether, rate, _cap(rate), 100);
        uint256 before = refund.balance;
        vm.prank(alice);
        col.buy{value: p.totalIn}(
            p.ethToSale, p.poolAmount, p.poolLimit, p.poolExactOut, p.minTotalOut, alice, refund, block.timestamp + 60
        );
        // The stray wei is unwrapped and leaves with the change rather than
        // reverting the route or being kept.
        assertEq(refund.balance - before, 1, "donated wei not returned as change");
    }
}
