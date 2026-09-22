// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionFarm} from "../src/pools/PrecisionFarm.sol";

interface IERC20P {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function nonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @dev Runs against the live TAC/ETH full-range band on mainnet.
contract PrecisionFarmTest is Test {
    PrecisionPool constant POOL = PrecisionPool(payable(0x0155358241411dB868BA714aE7c83A27087e3D6E));
    address constant TAC = 0xA1313eb9f3A445606D9583bcAc3ebeB56a858279;
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    PrecisionFarm farm;
    address ops = address(0x0995);
    uint256 aliceKey = 0xA11CE;
    address alice;
    address bob = address(0xB0B);
    uint256 constant RATE = uint256(1_000 ether) / 1 days;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")), 26_033_781);
        alice = vm.addr(aliceKey);
        farm = new PrecisionFarm(POOL, TAC, ops, RATE);
        deal(TAC, ops, 100_000 ether);
        deal(TAC, alice, 1_000 ether);
        deal(TAC, bob, 1_000 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _fund(uint256 amount) internal {
        vm.startPrank(ops);
        IERC20P(TAC).approve(address(farm), amount);
        farm.fund(amount);
        vm.stopPrank();
    }

    function _sig(address token, uint256 key, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(key);
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, address(farm), value, IERC20P(token).nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20P(token).DOMAIN_SEPARATOR(), structHash));
        return vm.sign(key, digest);
    }

    function testRejectsNonPool() public {
        vm.expectRevert();
        new PrecisionFarm(PrecisionPool(payable(TAC)), TAC, ops, RATE);
    }

    function testZapETHStakesAndLeavesDust() public {
        uint256 ethBefore = alice.balance;
        uint256 farmEth = address(farm).balance;
        vm.prank(alice);
        uint256 shares = farm.zapETH{value: 0.005 ether}(0, 1, block.timestamp);
        assertEq(farm.staked(alice), shares);
        assertEq(POOL.balanceOf(address(farm)), shares);
        // Almost everything goes in; the refunds are rounding dust.
        assertGt(ethBefore - alice.balance, 0.005 ether - 1e9);
        assertLt(IERC20P(TAC).balanceOf(alice) - 1_000 ether, 1e9);
        assertEq(address(farm).balance, farmEth);
        assertEq(IERC20P(TAC).balanceOf(address(farm)), 0);
    }

    function testZapTokenWithPermit() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sig(TAC, aliceKey, 50 ether, deadline);
        uint256 farmEth = address(farm).balance;
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        uint256 shares = farm.zapTokenWithPermit(50 ether, 0, 1, deadline, v, r, s);
        assertEq(farm.staked(alice), shares);
        assertLt(IERC20P(TAC).balanceOf(alice) - 950 ether, 1e9);
        assertLt(alice.balance - ethBefore, 1e9);
        assertEq(address(farm).balance, farmEth);
        assertEq(IERC20P(TAC).balanceOf(address(farm)), 0);
    }

    function testAddAndStakeRefundsExcessSide() public {
        vm.startPrank(bob);
        IERC20P(TAC).approve(address(farm), 100 ether);
        uint256 shares = farm.addAndStake{value: 0.001 ether}(100 ether, 1, block.timestamp);
        vm.stopPrank();
        assertGt(shares, 0);
        // 0.001 ETH pairs with ~14.28 TAC; the rest comes back.
        uint256 used = 1_000 ether - IERC20P(TAC).balanceOf(bob);
        assertApproxEqRel(used, 14.2828 ether, 0.001e18);
        assertEq(IERC20P(TAC).balanceOf(address(farm)), 0);
    }

    function testStakeLPWithPermitAndRemove() public {
        vm.startPrank(alice);
        IERC20P(TAC).approve(address(POOL), 30 ether);
        (uint256 lp,,) = POOL.addLiquidityExact{value: 0.002 ether}(0, 0.002 ether, 30 ether, 1, alice);
        vm.stopPrank();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sig(address(POOL), aliceKey, lp, deadline);
        vm.prank(alice);
        farm.stakeWithPermit(lp, deadline, v, r, s);
        assertEq(farm.staked(alice), lp);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        (uint256 a0, uint256 a1) = farm.exitAndRemove(0, 0, block.timestamp);
        assertEq(farm.staked(alice), 0);
        assertEq(alice.balance - ethBefore, a0);
        assertApproxEqRel(a0, 0.002 ether, 0.001e18);
        assertGt(a1, 0);
    }

    function testExitToETHOnly() public {
        _fund(1_000 ether);
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        farm.zapETH{value: 0.005 ether}(0, 1, block.timestamp);
        vm.warp(block.timestamp + 1 hours);
        uint256 tacBefore = IERC20P(TAC).balanceOf(alice);
        uint256 owed = farm.earned(alice);
        vm.prank(alice);
        uint256 out = farm.exitTo(true, 0.0049 ether, block.timestamp);
        assertEq(farm.staked(alice), 0);
        // Round trip costs two swap legs of 30 bps each plus impact on a tiny pool.
        assertGt(out, 0.0049 ether);
        assertApproxEqAbs(alice.balance, ethBefore - 0.005 ether + out, 1e9);
        // Only rewards arrive in TAC, and the farm keeps no ETH of hers.
        assertApproxEqAbs(IERC20P(TAC).balanceOf(alice) - tacBefore, owed, 1e9);
        assertGe(IERC20P(TAC).balanceOf(address(farm)), farm.reserved());
    }

    function testWithdrawToTokenOnly() public {
        vm.startPrank(bob);
        IERC20P(TAC).approve(address(farm), 100 ether);
        uint256 shares = farm.zapToken(100 ether, 0, 1, block.timestamp);
        uint256 ethBefore = bob.balance;
        uint256 out = farm.withdrawTo(false, shares, 99 ether, block.timestamp);
        vm.stopPrank();
        assertGt(out, 99 ether);
        assertEq(bob.balance, ethBefore);
        assertApproxEqAbs(IERC20P(TAC).balanceOf(bob), 900 ether + out, 1e9);
        assertEq(IERC20P(TAC).balanceOf(address(farm)), 0);
    }

    function testWithdrawToEnforcesMinOut() public {
        vm.prank(alice);
        uint256 shares = farm.zapETH{value: 0.005 ether}(0, 1, block.timestamp);
        vm.expectRevert(PrecisionFarm.Slippage.selector);
        vm.prank(alice);
        farm.withdrawTo(true, shares, 0.005 ether, block.timestamp);
    }

    function testRewardsStreamProRata() public {
        _fund(7_000 ether);
        assertApproxEqAbs(farm.periodFinish(), block.timestamp + 7 days, 1);
        vm.prank(alice);
        farm.zapETH{value: 0.01 ether}(0, 1, block.timestamp);
        vm.prank(bob);
        farm.zapETH{value: 0.01 ether}(0, 1, block.timestamp);
        vm.warp(block.timestamp + 8 days);
        uint256 ea = farm.earned(alice);
        uint256 eb = farm.earned(bob);
        assertApproxEqRel(ea + eb, 7_000 ether, 1e12);
        assertApproxEqRel(ea * farm.staked(bob), eb * farm.staked(alice), 1e12);
        uint256 before = IERC20P(TAC).balanceOf(alice);
        vm.prank(alice);
        farm.claim();
        assertEq(IERC20P(TAC).balanceOf(alice) - before, ea);
        assertEq(farm.earned(alice), 0);
    }

    function testTransferThenSyncExtendsRunway() public {
        _fund(1_000 ether);
        uint256 finish = farm.periodFinish();
        vm.prank(ops);
        IERC20P(TAC).transfer(address(farm), 500 ether);
        farm.sync();
        assertApproxEqAbs(farm.periodFinish(), finish + 12 hours, 1);
        // Nothing new: a second sync is a no-op.
        assertEq(farm.sync(), 0);
    }

    function testSyncAfterGapDoesNotBackfill() public {
        vm.prank(alice);
        farm.zapETH{value: 0.01 ether}(0, 1, block.timestamp);
        _fund(1_000 ether);
        vm.warp(block.timestamp + 3 days);
        assertApproxEqRel(farm.earned(alice), 1_000 ether, 1e12);
        vm.prank(ops);
        IERC20P(TAC).transfer(address(farm), 1_000 ether);
        farm.sync();
        assertApproxEqAbs(farm.periodFinish(), block.timestamp + 1 days, 1);
        // The two idle days between windows pay nothing.
        assertApproxEqRel(farm.earned(alice), 1_000 ether, 1e12);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(farm.earned(alice), 2_000 ether, 1e12);
    }

    function testSetRateRetimesWithoutMinting() public {
        _fund(1_000 ether);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(ops);
        farm.setRate(RATE / 2);
        assertApproxEqAbs(farm.periodFinish(), block.timestamp + 1 days, 2);
        vm.prank(alice);
        farm.zapETH{value: 0.01 ether}(0, 1, block.timestamp);
        vm.warp(block.timestamp + 2 days);
        assertApproxEqRel(farm.earned(alice), 500 ether, 1e12);
        vm.prank(alice);
        farm.claim();
        assertLe(farm.reserved(), IERC20P(TAC).balanceOf(address(farm)));
    }

    function testIdleEmissionIsReleased() public {
        _fund(7_000 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        farm.zapETH{value: 0.01 ether}(0, 1, block.timestamp);
        vm.warp(block.timestamp + 6 days);
        vm.prank(alice);
        farm.claim();
        // One idle day comes back as free balance, to restream or recover.
        uint256 free = IERC20P(TAC).balanceOf(address(farm)) - farm.reserved();
        assertApproxEqRel(free, 1_000 ether, 1e12);
        vm.prank(ops);
        farm.recover(TAC, ops, free);
    }

    function testRecoverCannotTouchReservedOrStake() public {
        _fund(1_000 ether);
        vm.prank(alice);
        farm.zapETH{value: 0.01 ether}(0, 1, block.timestamp);
        vm.startPrank(ops);
        vm.expectRevert(PrecisionFarm.Underfunded.selector);
        farm.recover(TAC, ops, 1e18);
        vm.expectRevert(PrecisionFarm.Bad.selector);
        farm.recover(address(POOL), ops, 1);
        vm.stopPrank();
    }

    function testOnlyOwnerSchedules() public {
        vm.expectRevert(PrecisionFarm.NotOwner.selector);
        vm.prank(alice);
        farm.setRate(1);
    }

    function testExpiredZapReverts() public {
        vm.expectRevert(PrecisionFarm.Expired.selector);
        vm.prank(alice);
        farm.zapETH{value: 0.01 ether}(0, 1, block.timestamp - 1);
    }

    function testRejectsStrayETH() public {
        vm.prank(alice);
        (bool ok,) = address(farm).call{value: 1}("");
        assertFalse(ok);
    }
}
