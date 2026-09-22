// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionFarm} from "../src/pools/PrecisionFarm.sol";

interface IERC20A {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// Scratch audit tests for PrecisionFarm (fork of the live TAC/ETH band).
contract PrecisionFarmAuditTest is Test {
    PrecisionPool constant POOL = PrecisionPool(payable(0x0155358241411dB868BA714aE7c83A27087e3D6E));
    address constant TAC = 0xA1313eb9f3A445606D9583bcAc3ebeB56a858279;
    uint256 constant RATE = uint256(1_000 ether) / 1 days;

    PrecisionFarm farm;
    address ops = address(0x0995);
    address[3] users = [address(0xA1), address(0xB2), address(0xC3)];
    address funder = address(0xF0);
    address mev = address(0xE7);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")), 26_033_781);
        farm = new PrecisionFarm(POOL, TAC, ops, RATE);
        deal(TAC, ops, 1_000_000 ether);
        deal(TAC, funder, 1_000_000 ether);
        for (uint256 i; i < 3; ++i) {
            deal(TAC, users[i], 10_000 ether);
            vm.deal(users[i], 100 ether);
            vm.startPrank(users[i]);
            IERC20A(TAC).approve(address(POOL), type(uint256).max);
            IERC20A(address(POOL)).approve(address(farm), type(uint256).max);
            POOL.addLiquidityExact{value: 0.003 ether}(0, 0.003 ether, 100 ether, 1, users[i]);
            vm.stopPrank();
        }
    }

    function _bal() internal view returns (uint256) {
        return IERC20A(TAC).balanceOf(address(farm));
    }

    /// forge-config: default.fuzz.runs = 32
    /// Pseudo-random op sequence: reserved never exceeds balance, _update never
    /// reverts, and at the end every staker can exit and claim.
    function testRandomOpsKeepBacking(uint256 seed) public {
        for (uint256 step; step < 60; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = seed % 8;
            address u = users[(seed >> 8) % 3];
            uint256 lp = IERC20A(address(POOL)).balanceOf(u);
            if (op == 0 && lp > 0) {
                vm.prank(u);
                farm.stake(1 + (seed >> 16) % lp);
            } else if (op == 1 && farm.staked(u) > 0) {
                uint256 amt = 1 + (seed >> 16) % farm.staked(u);
                vm.prank(u);
                farm.withdraw(amt);
            } else if (op == 2) {
                vm.prank(u);
                farm.claim();
            } else if (op == 3) {
                vm.prank(funder);
                IERC20A(TAC).transfer(address(farm), (seed >> 16) % 5_000 ether);
                farm.sync();
            } else if (op == 4) {
                vm.prank(ops);
                try farm.setRate(1 + (seed >> 16) % (100 * RATE)) {} catch {}
            } else if (op == 5) {
                uint256 free = _bal() - farm.reserved();
                vm.prank(ops);
                farm.recover(TAC, ops, free / 2);
            } else {
                vm.warp(block.timestamp + (seed >> 16) % 3 days);
            }
            assertLe(farm.reserved(), _bal(), "reserved > balance");
            // Every owed reward is backed.
            uint256 owed;
            for (uint256 i; i < 3; ++i) owed += farm.earned(users[i]);
            assertLe(owed, _bal(), "owed > balance");
        }
        vm.warp(block.timestamp + 400 days);
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(users[i]);
            if (farm.staked(users[i]) > 0) farm.exit();
            else farm.claim();
            vm.stopPrank();
        }
        assertEq(farm.totalStaked(), 0);
        assertEq(IERC20A(address(POOL)).balanceOf(address(farm)), 0);
        assertLe(farm.reserved(), _bal());
        emit log_named_uint("residual reserved dust", farm.reserved());
    }

    /// A rate raise cannot collapse funded rewards into a release the owner
    /// could then recover.
    function testOwnerCannotPullThirdPartyFunding() public {
        vm.prank(users[0]);
        farm.stake(1e15);
        vm.startPrank(funder);
        IERC20A(TAC).approve(address(farm), 50_000 ether);
        farm.fund(50_000 ether);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);

        vm.startPrank(ops);
        vm.expectRevert(PrecisionFarm.Bad.selector);
        farm.setRate(type(uint128).max);
        // A raise to a runway of exactly MIN_RUNWAY is the most allowed.
        uint256 left = farm.reserved() - farm.earned(users[0]);
        vm.expectRevert(PrecisionFarm.Bad.selector);
        farm.setRate(left / 7 days + 1);
        farm.setRate(left / 7 days);
        uint256 free = _bal() - farm.reserved();
        assertLt(free, left / 7 days);
        vm.stopPrank();
    }

    /// The LP token cannot be the reward token.
    function testLpAsRewardTokenRejected() public {
        vm.expectRevert(PrecisionFarm.Bad.selector);
        new PrecisionFarm(POOL, address(POOL), ops, 1);
    }

    function _redeemValue(address u, uint256 shares) internal returns (uint256 inEth) {
        // Value of `shares` at the pool's pre-attack reserves ratio.
        vm.prank(u);
        (uint256 a0, uint256 a1) = farm.withdrawAndRemove(shares, 0, 0, block.timestamp);
        inEth = a0 + a1 * 0.0175 ether / 250 ether;
    }

    /// Sandwich against zapETH guarded only by minShares (minOut = 0).
    function testSandwichZapMinSharesOnly() public {
        address u = users[1];
        uint256 zapIn = 0.002 ether;
        uint256 snap = vm.snapshotState();
        vm.prank(u);
        uint256 clean = farm.zapETH{value: zapIn}(0, 1, block.timestamp);
        vm.revertToState(snap);
        uint256 minShares = clean * 99 / 100;

        // Direction A: attacker dumps ETH (ETH cheap) -> zap reverts on minShares.
        vm.deal(mev, 10 ether);
        vm.prank(mev);
        POOL.swapExactIn{value: 0.01 ether}(address(0), 0.01 ether, 0, mev);
        vm.prank(u);
        vm.expectRevert();
        farm.zapETH{value: zapIn}(0, minShares, block.timestamp);
        vm.revertToState(snap);

        // Direction B: attacker buys ETH with TAC (ETH dear) -> zap passes; back-run.
        deal(TAC, mev, 1_000 ether);
        vm.startPrank(mev);
        IERC20A(TAC).approve(address(POOL), type(uint256).max);
        uint256 got = POOL.swapExactIn(TAC, 100 ether, 0, mev);
        vm.stopPrank();
        vm.prank(u);
        uint256 sh = farm.zapETH{value: zapIn}(0, minShares, block.timestamp);
        vm.prank(mev);
        POOL.swapExactIn{value: got}(address(0), got, 0, mev);
        emit log_named_uint("clean shares", clean);
        emit log_named_uint("sandwiched shares", sh);
        assertGe(sh, minShares);
    }

    /// withdrawTo with funded rewards: the farm's TAC balance and `reserved`
    /// are unchanged by the round trip through its own balance.
    function testWithdrawToLeavesRewardsUntouched() public {
        vm.startPrank(funder);
        IERC20A(TAC).approve(address(farm), 50_000 ether);
        farm.fund(50_000 ether);
        vm.stopPrank();
        address u = users[0];
        vm.prank(u);
        farm.stake(1e17);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(u);
        farm.claim();
        uint256 bal = _bal();
        uint256 res = farm.reserved();
        uint256 eth0 = address(farm).balance;
        emit log_named_uint("farm ETH before", eth0);
        vm.prank(u);
        farm.withdrawTo(false, 5e16, 1, block.timestamp);
        assertEq(_bal(), bal);
        assertEq(farm.reserved(), res);
        vm.prank(u);
        farm.withdrawTo(true, 5e16, 1, block.timestamp);
        assertEq(_bal(), bal);
        assertEq(farm.reserved(), res);
        assertEq(address(farm).balance, eth0);
    }

    /// Sandwich against withdrawTo(toETH) with the single total floor.
    function testSandwichWithdrawToFloor() public {
        address u = users[2];
        vm.prank(u);
        farm.stake(3e17);
        uint256 snap = vm.snapshotState();
        vm.prank(u);
        uint256 clean = farm.withdrawTo(true, 3e17, 0, block.timestamp);
        vm.revertToState(snap);
        uint256 floor = clean * 99 / 100;
        for (uint256 dir; dir < 2; ++dir) {
            vm.revertToState(snap);
            vm.deal(mev, 10 ether);
            deal(TAC, mev, 1_000 ether);
            vm.startPrank(mev);
            IERC20A(TAC).approve(address(POOL), type(uint256).max);
            if (dir == 0) POOL.swapExactIn{value: 0.005 ether}(address(0), 0.005 ether, 0, mev);
            else POOL.swapExactIn(TAC, 60 ether, 0, mev);
            vm.stopPrank();
            vm.prank(u);
            (bool ok, bytes memory ret) =
                address(farm).call(abi.encodeCall(farm.withdrawTo, (true, 3e17, floor, block.timestamp)));
            if (ok) {
                uint256 got = abi.decode(ret, (uint256));
                emit log_named_uint("sandwiched out passed floor", got);
                assertGe(got, floor);
            } else {
                emit log_named_uint("sandwich dir reverted on floor", dir);
            }
        }
        emit log_named_uint("clean out", clean);
    }

    /// A leg too small to swap is paid out as it is rather than reverting.
    function testWithdrawToDustLegPaysThrough() public {
        address u = users[0];
        vm.prank(u);
        farm.stake(1e17);
        uint256 tacBefore = IERC20A(TAC).balanceOf(u);
        vm.prank(u);
        farm.withdrawTo(true, 1, 0, block.timestamp);
        assertEq(farm.staked(u), 1e17 - 1);
        assertGe(IERC20A(TAC).balanceOf(u), tacBefore);
    }
}
