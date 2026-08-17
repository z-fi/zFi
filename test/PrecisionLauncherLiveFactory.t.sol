// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";
import {PrecisionLauncherLens} from "../src/pools/PrecisionLauncherLens.sol";

/// @dev The launcher against the REAL factory, not a locally deployed one.
///
/// Every other suite constructs its own `PrecisionPoolFactory`, which differs
/// from the live deployment in ways that could matter and are easy to assume
/// away: the live factory carries a `trustedExecutor` (ours does not), it
/// already holds markets created by other people, and - the one that decides
/// everything - it deploys pools from an SSTORE2 blob mined at a pinned
/// optimizer setting. If this repo's `PrecisionPool` ever stops compiling to
/// that exact blob, the launcher would still work locally while producing
/// pools at addresses nothing else in the system describes.
///
/// PINNED AFTER THE DEPLOYMENT, not at the repo default. The factory landed in
/// block 25,725,625 and the suite's usual pin of 25,640,000 predates it - at
/// that block the address is codeless, the launcher's constructor check fails,
/// and every test here would revert for a reason that has nothing to do with
/// the launcher. See the `fork_block_number` note in foundry.toml, which
/// documents the same trap for the quoter.
contract PrecisionLauncherLiveFactoryTest is Test {
    PrecisionPoolFactory constant FACTORY = PrecisionPoolFactory(0x000000Eb27B557aB426d9E99cFd54EC455799e81);
    address constant BETH = 0x2cb662Ec360C34a45d7cA0126BCd53C9a1fd48F9;
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    /// @dev Recorded from the live factory at deployment; see deploy/Precision.md.
    bytes32 constant EXPECTED_POOL_INIT_HASH = 0x897b0181f6b0a84c801ae9934c3e8219c68bd65d46d2d534068ae4cda61cbf10;

    PrecisionLauncher launcher;
    PrecisionLauncherLens lens;

    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA);
    address alice = address(0xA11CE);

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant START_MCAP = 3 ether;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")), 25_745_000);
        launcher = new PrecisionLauncher(FACTORY, treasury);
        lens = new PrecisionLauncherLens(launcher);
        vm.deal(alice, 1_000 ether);
    }

    // ------------------------------------------------------- COMPATIBILITY

    /// THE CHECK THAT MATTERS. The factory CREATE2s every market from a blob it
    /// was constructed with, so this hash decides every pool address the
    /// launcher will ever produce. A drift here does not fail loudly - it
    /// silently relocates every market away from what the repo, the lens, and
    /// the deploy manifest all describe.
    function testLocalPoolBytecodeStillMatchesTheLiveFactory() public view {
        bytes32 local = keccak256(type(PrecisionPool).creationCode);
        assertEq(local, FACTORY.poolInitCodeHash(), "local PrecisionPool no longer matches the live factory");
        assertEq(local, EXPECTED_POOL_INIT_HASH, "the live factory itself moved");
    }

    /// The live factory differs from a locally built one in exactly one way the
    /// launcher could care about. Assert the difference exists, so this suite
    /// is known to be exercising it rather than a lookalike.
    function testLiveFactoryCarriesAnExecutorAndPriorMarkets() public view {
        assertTrue(FACTORY.trustedExecutor() != address(0), "not the live factory - no executor");
        assertGt(FACTORY.poolCount(), 0, "not the live factory - no prior markets");
    }

    // ------------------------------------------------------------- THE PATH

    /// A launch, end to end, on the real thing.
    function testLaunchAgainstLiveFactory() public {
        uint256 poolsBefore = FACTORY.poolCount();

        (address t, address p) = launcher.launch("Live", "LIVE", "ipfs://live", SUPPLY, 1_000, START_MCAP, creator);
        LaunchToken token = LaunchToken(t);
        PrecisionPool pool = PrecisionPool(payable(p));

        // The factory agrees this is its own market, and agrees on the address.
        assertTrue(FACTORY.isPool(p), "live factory disowns the pool");
        assertEq(FACTORY.poolCount(), poolsBefore + 1, "market was not indexed");
        assertEq(
            FACTORY.poolFor(
                PrecisionPoolFactory.Market({
                    token0: address(0),
                    token1: t,
                    sqrtPLow: pool.sqrtPLow(),
                    sqrtPHigh: pool.sqrtPHigh(),
                    fee: pool.fee(),
                    hook: address(0),
                    feeRecipient: address(launcher),
                    creatorFeeBps: pool.creatorFeeBps()
                })
            ),
            p,
            "market tuple does not derive the deployed address"
        );

        // One-sided, as everywhere else.
        assertEq(pool.reserve0(), 0, "opened with ETH");
        assertGt(pool.reserve1(), 0, "opened with no token");
        assertEq(token.balanceOf(creator), SUPPLY / 10, "allocation not paid");
    }

    /// The whole lifecycle against live infrastructure, including a real burn.
    function testFullPathAgainstLiveInfrastructure() public {
        (address t, address p) = launcher.launch("Live", "LIVE", "", SUPPLY, 0, START_MCAP, creator);
        LaunchToken token = LaunchToken(t);
        PrecisionPool pool = PrecisionPool(payable(p));

        // Buy, then sell, so both fee sides accrue.
        vm.startPrank(alice);
        pool.swapExactIn{value: 30 ether}(address(0), 30 ether, 0, alice);
        token.approve(address(pool), type(uint256).max);
        pool.swapExactIn(address(token), token.balanceOf(alice) / 4, 0, alice);
        vm.stopPrank();

        assertGt(launcher.floorPrice(t), 0, "no floor formed on live infrastructure");

        // Redemption pays, and cannot beat the market.
        uint256 probe = token.balanceOf(alice) / 4;
        (uint256 viaMarket,) = pool.quoteExactIn(alice, t, probe);
        assertLe(launcher.quoteRedeem(t, probe), viaMarket, "floor overtook the market");

        vm.startPrank(alice);
        token.approve(address(launcher), type(uint256).max);
        uint256 ethOut = launcher.redeem(t, probe, 0, alice);
        vm.stopPrank();
        assertGt(ethOut, 0, "redemption paid nothing");

        // Fees sweep, split three ways, tithe burned for real.
        uint256 daoBefore = IERC20(BETH).balanceOf(DAO);
        (uint256 cEth, uint256 pEth, uint256 tEth, uint256 burned,) = launcher.collectFees(t);
        assertGt(cEth, 0);
        assertEq(pEth, tEth, "treasury and tithe are not equal tenths");
        assertGt(burned, 0, "token side did not burn");
        assertEq(IERC20(BETH).balanceOf(DAO) - daoBefore, tEth, "tithe record did not reach the DAO");
    }

    // -------------------------------------------------------- DISCOVERABILITY

    /// Discovery must work against a factory that ALREADY HAS markets in it -
    /// the case a fresh local factory cannot reproduce. Prior pools belong to
    /// other creators, so they must neither enter the registry nor be described
    /// as launches.
    function testDiscoveryIgnoresPriorMarketsOnTheLiveFactory() public {
        uint256 priorPools = FACTORY.poolCount();
        assertEq(lens.launchCount(), 0, "registry was not empty before any launch");

        (address a,) = launcher.launch("A", "A", "", SUPPLY, 0, START_MCAP, creator);
        (address b,) = launcher.launch("B", "B", "", SUPPLY, 0, START_MCAP, alice);

        assertEq(lens.launchCount(), 2, "launches not enumerable on the live factory");
        assertEq(FACTORY.poolCount(), priorPools + 2);

        PrecisionLauncherLens.LaunchInfo[] memory page = lens.launches(0, 10);
        assertEq(page.length, 2, "prior markets leaked into the page");
        assertEq(page[0].token, a);
        assertEq(page[1].token, b);

        // Creator-keyed lookup, the thing the factory index cannot answer.
        assertEq(lens.launchesForCreator(creator, 0, 10).length, 1);
        assertEq(lens.launchesForCreator(alice, 0, 10).length, 1);
        assertEq(FACTORY.poolsForCreatorCount(creator), 0, "factory indexed the real creator");

        // Every pre-existing market must probe as "not a launch".
        for (uint256 i; i < priorPools; ++i) {
            assertEq(lens.infoForPool(FACTORY.allPools(i)).token, address(0), "prior market read as a launch");
        }
    }

    /// The launched token must be routable through the same pool the rest of
    /// the system would find for it.
    function testLaunchedTokenIsIndexedForRouting() public {
        (address t, address p) = launcher.launch("R", "R", "", SUPPLY, 0, START_MCAP, creator);

        address[] memory forToken = FACTORY.poolsForTokenSlice(t, 0, 10);
        assertEq(forToken.length, 1, "token not indexed by the factory");
        assertEq(forToken[0], p, "token indexed to the wrong market");
        assertTrue(FACTORY.isPool(p), "router would reject this pool");
    }
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}
