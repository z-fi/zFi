// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

/// @dev Minimal interfaces — fork test against deployed contracts (same as CoinLaunch.t.sol)

struct Call {
    address target;
    uint256 value;
    bytes data;
}

struct SummonConfig {
    address summoner;
    address molochImpl;
    address sharesImpl;
    address lootImpl;
}

struct DAICOConfig {
    address tribTkn;
    uint256 tribAmt;
    uint256 saleSupply;
    uint256 forAmt;
    uint40 deadline;
    bool sellLoot;
    uint16 lpBps;
    uint16 maxSlipBps;
    uint256 feeOrHook;
}

struct TapConfig {
    address ops;
    uint128 ratePerSec;
    uint256 tapAllowance;
}

interface IDAICO {
    function summonDAICO(
        SummonConfig calldata summonConfig,
        string calldata orgName,
        string calldata orgSymbol,
        string calldata orgURI,
        uint16 quorumBps,
        bool ragequittable,
        address renderer,
        bytes32 salt,
        address[] calldata initHolders,
        uint256[] calldata initShares,
        bool sharesLocked,
        bool lootLocked,
        DAICOConfig calldata daicoConfig
    ) external payable returns (address dao);

    function summonDAICOWithTapCustom(
        SummonConfig calldata summonConfig,
        string calldata orgName,
        string calldata orgSymbol,
        string calldata orgURI,
        uint16 quorumBps,
        bool ragequittable,
        address renderer,
        bytes32 salt,
        address[] calldata initHolders,
        uint256[] calldata initShares,
        bool sharesLocked,
        bool lootLocked,
        DAICOConfig calldata daicoConfig,
        TapConfig calldata tapConfig,
        Call[] calldata customCalls
    ) external payable returns (address dao);

    function buy(address dao, address tribTkn, uint256 payAmt, uint256 minBuyAmt) external payable;
    function claimTap(address dao) external returns (uint256 claimed);
}

interface IMoloch {
    function shares() external view returns (address);
    function loot() external view returns (address);
    function name(uint256) external view returns (string memory);
    function symbol(uint256) external view returns (string memory);
    function contractURI() external view returns (string memory);
    function ragequittable() external view returns (bool);
    function quorumBps() external view returns (uint16);
    function proposalTTL() external view returns (uint64);
    function timelockDelay() external view returns (uint64);
    function allowance(address token, address spender) external view returns (uint256);
    function ragequit(address[] calldata tokens, uint256 sharesToBurn, uint256 lootToBurn) external;
}

interface IShares {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook;
}

interface IZAMM {
    function swapExactIn(
        PoolKey calldata key,
        uint256 swapAmount,
        uint256 amountLimit,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);
    function pools(uint256 poolId)
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast,
            uint256 price0CumulativeLast,
            uint256 price1CumulativeLast,
            uint256 kLast,
            uint256 supply
        );
    function lockups(bytes32) external view returns (uint256);
}

/// @title SimpleCoinLaunch tests — validates the "simple" memecoin-style launch path
/// @dev Uses summonDAICO (no tap, no custom calls) with teamBps=0, lpBps=5000
contract SimpleCoinLaunchTest is Test {
    // Deployed addresses (mainnet)
    address constant SUMMONER = 0x0000000000330B8df9E3bc5E553074DA58eE9138;
    IDAICO constant daico = IDAICO(0x000000000033e92DB97B4B3beCD2c255126C60aC);
    address constant RENDERER = 0x000000000011C799980827F52d3137b4abD6E654;
    IZAMM constant zamm = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    address constant ZAMM = 0x000000000000040470635EB91b7CE4D132D616eD;

    // Impl addresses (for CREATE2 prediction)
    address constant MOLOCH_IMPL = 0x643A45B599D81be3f3A68F37EB3De55fF10673C1;
    address constant SHARES_IMPL = 0x71E9b38d301b5A58cb998C1295045FE276Acf600;
    address constant LOOT_IMPL = 0x6f1f2aF76a3aDD953277e9F369242697C87bc6A5;

    // Simple template params (matching dapp JS COIN_SIMPLE_DEFAULTS)
    uint256 constant COIN_SUPPLY = 1_000_000_000;
    uint16 constant SIMPLE_LP_BPS = 5000; // 50% to LP
    uint256 constant FEE = 30;
    uint16 constant QUORUM_BPS = 1500;

    address deployer;
    address buyer1;
    address buyer2;

    struct LaunchResult {
        address dao;
        address shares;
        address loot;
        uint256 deployTime;
    }

    function setUp() public {
        deployer = address(uint160(uint256(keccak256("simple_deployer"))));
        buyer1 = address(uint160(uint256(keccak256("simple_buyer1"))));
        buyer2 = address(uint160(uint256(keccak256("simple_buyer2"))));
        vm.deal(deployer, 100 ether);
        vm.deal(buyer1, 100 ether);
        vm.deal(buyer2, 100 ether);
    }

    // ==================== HELPERS ====================

    function _launchSimple(uint256 raiseETH, uint16 lpBps) internal returns (LaunchResult memory r) {
        r.deployTime = block.timestamp;

        // Simple mode: teamBps=0 → 100% sale supply
        uint256 saleSupply = COIN_SUPPLY * 1e18;
        uint256 tribAmt = 1 ether;
        uint256 forAmt = (COIN_SUPPLY / raiseETH) * 1e18;

        bytes32 salt = keccak256(abi.encode("simple", raiseETH, lpBps, block.timestamp));
        address[] memory holders = new address[](1);
        holders[0] = deployer;
        uint256[] memory shares_ = new uint256[](1);
        shares_[0] = 1 ether;

        // Predict addresses
        bytes32 summonerSalt = keccak256(abi.encode(holders, shares_, salt));
        r.dao = _predictClone(MOLOCH_IMPL, summonerSalt, SUMMONER);
        bytes32 childSalt = bytes32(bytes20(r.dao));
        r.shares = _predictClone(SHARES_IMPL, childSalt, r.dao);
        r.loot = _predictClone(LOOT_IMPL, childSalt, r.dao);

        // Simple launch: no tap, no custom calls
        vm.prank(deployer);
        daico.summonDAICO(
            SummonConfig(SUMMONER, MOLOCH_IMPL, SHARES_IMPL, LOOT_IMPL),
            "SimpleCoin",
            "SIMPLE",
            "ipfs://QmSimple",
            QUORUM_BPS,
            true, // ragequittable
            RENDERER,
            salt,
            holders,
            shares_,
            false, // sharesLocked
            false, // lootLocked
            DAICOConfig({
                tribTkn: address(0),
                tribAmt: tribAmt,
                saleSupply: saleSupply,
                forAmt: forAmt,
                deadline: 0,
                sellLoot: false,
                lpBps: lpBps,
                maxSlipBps: 100,
                feeOrHook: FEE
            })
        );
    }

    function _predictClone(address impl, bytes32 salt_, address deployer_) internal pure returns (address) {
        bytes memory code =
            abi.encodePacked(hex"602d5f8160095f39f35f5f365f5f37365f73", impl, hex"5af43d5f5f3e6029573d5ffd5b3d5ff3");
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer_, salt_, keccak256(code))))));
    }

    function _poolKey(address sharesToken) internal pure returns (PoolKey memory) {
        return PoolKey(0, 0, address(0), sharesToken, FEE);
    }

    // ==================== DEPLOYMENT TESTS ====================

    function test_simple_deploy() public {
        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);
        IMoloch dao = IMoloch(r.dao);

        // DAO metadata
        assertEq(dao.name(0), "SimpleCoin", "name");
        assertEq(dao.symbol(0), "SIMPLE", "symbol");
        assertEq(dao.contractURI(), "ipfs://QmSimple", "contractURI");

        // Governance basics
        assertTrue(dao.ragequittable(), "ragequittable");
        assertEq(dao.quorumBps(), QUORUM_BPS, "quorumBps");

        // Token addresses
        assertEq(dao.shares(), r.shares, "shares addr");
        assertEq(dao.loot(), r.loot, "loot addr");
    }

    function test_simple_full_sale_supply() public {
        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);
        IShares shares = IShares(r.shares);

        // With teamBps=0: 100% of COIN_SUPPLY goes to sale
        uint256 expectedSaleSupply = COIN_SUPPLY * 1e18;

        // Total supply = 1 deployer share + full sale supply (no team mint)
        assertEq(shares.totalSupply(), 1 ether + expectedSaleSupply, "total supply = 1B + 1 deployer");

        // DAO holds all sale tokens
        assertEq(shares.balanceOf(r.dao), expectedSaleSupply, "DAO holds 1B sale supply");

        // ZAMM holds nothing (no team lockup)
        assertEq(shares.balanceOf(ZAMM), 0, "ZAMM holds 0 (no team)");

        // Deployer holds 1 init share
        assertEq(shares.balanceOf(deployer), 1 ether, "deployer init shares");

        // DAICO approved for full sale
        assertEq(shares.allowance(r.dao, address(daico)), expectedSaleSupply, "DAICO sale approval");
    }

    function test_simple_no_tap_allowance() public {
        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);
        IMoloch dao = IMoloch(r.dao);

        // No tap configured — allowance should be 0
        assertEq(dao.allowance(address(0), address(daico)), 0, "no tap allowance");
    }

    function test_simple_deploy_various_raises() public {
        // 1 ETH raise
        LaunchResult memory r1 = _launchSimple(1, SIMPLE_LP_BPS);
        assertEq(IShares(r1.shares).balanceOf(r1.dao), COIN_SUPPLY * 1e18, "1 ETH: full supply");
        assertEq(IMoloch(r1.dao).allowance(address(0), address(daico)), 0, "1 ETH: no tap");

        // 10 ETH raise
        LaunchResult memory r2 = _launchSimple(10, SIMPLE_LP_BPS);
        assertEq(IShares(r2.shares).balanceOf(r2.dao), COIN_SUPPLY * 1e18, "10 ETH: full supply");
        assertEq(IMoloch(r2.dao).allowance(address(0), address(daico)), 0, "10 ETH: no tap");

        // 100 ETH raise
        LaunchResult memory r3 = _launchSimple(100, SIMPLE_LP_BPS);
        assertEq(IShares(r3.shares).balanceOf(r3.dao), COIN_SUPPLY * 1e18, "100 ETH: full supply");
        assertEq(IMoloch(r3.dao).allowance(address(0), address(daico)), 0, "100 ETH: no tap");
    }

    function test_simple_deploy_various_lp_splits() public {
        // 30% LP (minimum in UI)
        LaunchResult memory r1 = _launchSimple(5, 3000);
        assertEq(IMoloch(r1.dao).allowance(address(0), address(daico)), 0, "30% LP: no tap");

        // 50% LP (default)
        LaunchResult memory r2 = _launchSimple(5, 5000);
        assertEq(IMoloch(r2.dao).allowance(address(0), address(daico)), 0, "50% LP: no tap");

        // 70% LP (maximum in UI)
        LaunchResult memory r3 = _launchSimple(5, 7000);
        assertEq(IMoloch(r3.dao).allowance(address(0), address(daico)), 0, "70% LP: no tap");
    }

    // ==================== BUY TESTS ====================

    function test_simple_buy() public {
        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);
        IShares shares = IShares(r.shares);

        vm.prank(buyer1);
        daico.buy{value: 1 ether}(r.dao, address(0), 1 ether, 0);

        uint256 received = shares.balanceOf(buyer1);
        assertGt(received, 0, "buyer got shares");
        assertGt(r.dao.balance, 0, "DAO has treasury ETH");

        emit log_named_uint("Shares received for 1 ETH", received / 1e18);
        emit log_named_uint("DAO treasury ETH (wei)", r.dao.balance);
    }

    function test_simple_buy_seeds_pool() public {
        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);

        vm.prank(buyer1);
        daico.buy{value: 1 ether}(r.dao, address(0), 1 ether, 0);

        // Check ZAMM pool was seeded
        uint256 poolId = uint256(keccak256(abi.encode(uint256(0), uint256(0), address(0), r.shares, FEE)));
        (uint112 res0, uint112 res1,,,,,) = zamm.pools(poolId);

        assertGt(res0, 0, "pool ETH reserves");
        assertGt(res1, 0, "pool share reserves");

        emit log_named_uint("Pool ETH", res0);
        emit log_named_uint("Pool Shares", uint256(res1) / 1e18);
    }

    function test_simple_treasury_split() public {
        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);

        // Buy 5 ETH (full raise)
        vm.prank(buyer1);
        daico.buy{value: 5 ether}(r.dao, address(0), 5 ether, 0);

        // With 50% LP: treasury should get ~50% of raise = ~2.5 ETH
        uint256 treasuryETH = r.dao.balance;
        uint256 expectedTreasury = 2.5 ether;
        assertApproxEqRel(treasuryETH, expectedTreasury, 0.01e18, "treasury ~50% of raise");

        emit log_named_uint("Treasury ETH", treasuryETH);
        emit log_named_uint("Expected ~50%", expectedTreasury);
    }

    function test_simple_treasury_split_30pct_lp() public {
        LaunchResult memory r = _launchSimple(5, 3000); // 30% LP

        vm.prank(buyer1);
        daico.buy{value: 5 ether}(r.dao, address(0), 5 ether, 0);

        // 30% LP → 70% treasury = 3.5 ETH
        uint256 treasuryETH = r.dao.balance;
        assertApproxEqRel(treasuryETH, 3.5 ether, 0.01e18, "treasury ~70% of raise");
    }

    function test_simple_treasury_split_70pct_lp() public {
        LaunchResult memory r = _launchSimple(5, 7000); // 70% LP

        vm.prank(buyer1);
        daico.buy{value: 5 ether}(r.dao, address(0), 5 ether, 0);

        // 70% LP → 30% treasury = 1.5 ETH
        uint256 treasuryETH = r.dao.balance;
        assertApproxEqRel(treasuryETH, 1.5 ether, 0.01e18, "treasury ~30% of raise");
    }

    // ==================== TAP TESTS (should not work) ====================

    function test_simple_no_tap_claim() public {
        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);

        // Fund treasury
        vm.prank(buyer1);
        daico.buy{value: 3 ether}(r.dao, address(0), 3 ether, 0);
        assertGt(r.dao.balance, 0, "treasury funded");

        // Wait 30 days
        vm.warp(block.timestamp + 30 days);

        // claimTap should revert — no tap was configured
        vm.expectRevert();
        daico.claimTap(r.dao);
    }

    // ==================== RAGEQUIT TESTS ====================

    function test_simple_ragequit() public {
        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);
        IShares shares = IShares(r.shares);

        vm.prank(buyer1);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);

        uint256 buyerShares = shares.balanceOf(buyer1);
        assertGt(buyerShares, 0, "buyer has shares");

        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        uint256 balBefore = buyer1.balance;
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, buyerShares, 0);
        uint256 ethBack = buyer1.balance - balBefore;

        assertGt(ethBack, 0, "got ETH back from ragequit");
        assertEq(shares.balanceOf(buyer1), 0, "shares burned");

        emit log_named_uint("Paid", 2 ether);
        emit log_named_uint("Ragequit ETH", ethBack);
    }

    function test_simple_ragequit_proportional() public {
        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);
        IShares shares = IShares(r.shares);

        // Two buyers
        vm.prank(buyer1);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);
        vm.prank(buyer2);
        daico.buy{value: 3 ether}(r.dao, address(0), 3 ether, 0);

        uint256 b1Shares = shares.balanceOf(buyer1);

        // Buyer1 ragequits half
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        uint256 halfShares = b1Shares / 2;
        uint256 balBefore = buyer1.balance;
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, halfShares, 0);
        uint256 ethBack = buyer1.balance - balBefore;

        assertGt(ethBack, 0, "got ETH from partial ragequit");
        assertEq(shares.balanceOf(buyer1), b1Shares - halfShares, "remaining shares correct");

        emit log_named_uint("Buyer1 ragequit half, got ETH", ethBack);
    }

    // ==================== SWAP TESTS ====================

    function test_simple_swap_on_pool() public {
        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);
        IShares shares = IShares(r.shares);

        // Seed pool via DAICO buy
        vm.prank(buyer1);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);

        // Swap directly on ZAMM: buyer2 buys shares with ETH
        uint256 sharesBefore = shares.balanceOf(buyer2);
        vm.prank(buyer2);
        uint256 amtOut = zamm.swapExactIn{value: 0.1 ether}(
            _poolKey(r.shares), 0.1 ether, 0, true, buyer2, block.timestamp + 300
        );

        assertGt(amtOut, 0, "swap received shares");
        assertEq(shares.balanceOf(buyer2) - sharesBefore, amtOut, "shares delivered");

        emit log_named_uint("Swapped 0.1 ETH for shares", amtOut / 1e18);
    }

    function test_simple_sell_on_pool() public {
        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);
        IShares shares = IShares(r.shares);

        // Get shares via buy
        vm.prank(buyer1);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);

        uint256 sellAmount = 1_000_000 * 1e18;
        assertGt(shares.balanceOf(buyer1), sellAmount, "buyer has enough shares");

        // Approve and sell
        vm.prank(buyer1);
        shares.approve(ZAMM, sellAmount);

        uint256 ethBefore = buyer1.balance;
        vm.prank(buyer1);
        uint256 amtOut =
            zamm.swapExactIn(_poolKey(r.shares), sellAmount, 0, false, buyer1, block.timestamp + 300);

        assertGt(amtOut, 0, "received ETH");
        assertEq(buyer1.balance - ethBefore, amtOut, "ETH delivered");

        emit log_named_uint("Sold 1M shares for ETH (wei)", amtOut);
    }

    // ==================== SIMPLE vs ADVANCED COMPARISON ====================

    function test_simple_vs_advanced_supply_difference() public {
        // Simple: 100% sale, no team
        LaunchResult memory rSimple = _launchSimple(5, SIMPLE_LP_BPS);
        uint256 simpleSaleSupply = IShares(rSimple.shares).balanceOf(rSimple.dao);
        uint256 simpleZammBalance = IShares(rSimple.shares).balanceOf(ZAMM);

        // Advanced: 85% sale, 15% team (via summonDAICOWithTapCustom)
        LaunchResult memory rAdv = _launchAdvanced(5, 6);
        uint256 advSaleSupply = IShares(rAdv.shares).balanceOf(rAdv.dao);
        uint256 advZammBalance = IShares(rAdv.shares).balanceOf(ZAMM);

        // Simple has more sale supply (100% vs 85%)
        assertGt(simpleSaleSupply, advSaleSupply, "simple has more sale supply");
        assertEq(simpleSaleSupply, COIN_SUPPLY * 1e18, "simple = 1B");
        assertEq(advSaleSupply, 850_000_000 * 1e18, "advanced = 850M");

        // Simple has no team lockup in ZAMM
        assertEq(simpleZammBalance, 0, "simple: no team in ZAMM");
        assertEq(advZammBalance, 150_000_000 * 1e18, "advanced: 150M team in ZAMM");

        // Simple has no tap
        assertEq(IMoloch(rSimple.dao).allowance(address(0), address(daico)), 0, "simple: no tap");
        assertGt(IMoloch(rAdv.dao).allowance(address(0), address(daico)), 0, "advanced: has tap");
    }

    // ==================== FULL LIFECYCLE ====================

    function test_simple_full_lifecycle() public {
        emit log("=== SIMPLE LAUNCH: 5 ETH raise, 50% LP, no team, no tap ===");

        LaunchResult memory r = _launchSimple(5, SIMPLE_LP_BPS);
        IShares shares = IShares(r.shares);

        // Verify initial state
        assertEq(shares.balanceOf(r.dao), COIN_SUPPLY * 1e18, "full supply for sale");
        assertEq(shares.balanceOf(ZAMM), 0, "no team lockup");
        assertEq(IMoloch(r.dao).allowance(address(0), address(daico)), 0, "no tap");

        // Multiple buyers
        vm.prank(buyer1);
        daico.buy{value: 3 ether}(r.dao, address(0), 3 ether, 0);
        emit log_named_uint("Buyer1 shares (3 ETH)", shares.balanceOf(buyer1) / 1e18);

        vm.prank(buyer2);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);
        emit log_named_uint("Buyer2 shares (2 ETH)", shares.balanceOf(buyer2) / 1e18);

        uint256 treasuryAfterRaise = r.dao.balance;
        emit log_named_uint("Treasury after full raise", treasuryAfterRaise);

        // Treasury should be ~50% of raise
        assertApproxEqRel(treasuryAfterRaise, 2.5 ether, 0.01e18, "treasury ~50%");

        // Verify pool is seeded
        uint256 poolId = uint256(keccak256(abi.encode(uint256(0), uint256(0), address(0), r.shares, FEE)));
        (uint112 res0, uint112 res1,,,,,) = zamm.pools(poolId);
        assertGt(res0, 0, "pool has ETH");
        assertGt(res1, 0, "pool has shares");
        emit log_named_uint("Pool ETH", res0);
        emit log_named_uint("Pool Shares", uint256(res1) / 1e18);

        // Tap should NOT work
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert();
        daico.claimTap(r.dao);
        emit log("Tap correctly blocked (not configured)");

        // Ragequit: buyer1 exits with half shares
        uint256 halfShares = shares.balanceOf(buyer1) / 2;
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        uint256 b1Before = buyer1.balance;
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, halfShares, 0);
        uint256 rqETH = buyer1.balance - b1Before;
        emit log_named_uint("Buyer1 ragequit half, ETH back", rqETH);
        assertGt(rqETH, 0, "ragequit returned ETH");

        // Swap on secondary market
        vm.prank(buyer2);
        shares.approve(ZAMM, 1_000_000 * 1e18);
        uint256 ethBefore = buyer2.balance;
        vm.prank(buyer2);
        zamm.swapExactIn(_poolKey(r.shares), 1_000_000 * 1e18, 0, false, buyer2, block.timestamp + 300);
        emit log_named_uint("Buyer2 sold 1M shares for ETH", buyer2.balance - ethBefore);

        emit log_named_uint("Final treasury", r.dao.balance);
        emit log("=== Simple lifecycle complete ===");
    }

    // ==================== ADVANCED HELPER (for comparison test) ====================

    function _launchAdvanced(uint256 raiseETH, uint256 lockMonths) internal returns (LaunchResult memory r) {
        r.deployTime = block.timestamp;

        uint256 saleBps = 8500;
        uint256 teamBps = 1500;
        uint256 saleSupply = (COIN_SUPPLY * saleBps / 10000) * 1e18;
        uint256 teamSupply = (COIN_SUPPLY * teamBps / 10000) * 1e18;
        uint256 tribAmt = 1 ether;
        uint256 forAmt = (COIN_SUPPLY * saleBps / 10000 / raiseETH) * 1e18;
        uint16 lpBps = 3300;
        uint256 tapMonths = 3;

        uint256 treasuryBps = 10000 - lpBps;
        uint256 expectedTreasury = (raiseETH * 1e18 * treasuryBps) / 10000;
        uint128 tapRate = uint128(expectedTreasury / (2_629_746 * tapMonths));
        if (tapRate == 0 && expectedTreasury > 0) tapRate = 1;

        bytes32 salt = keccak256(abi.encode("advanced", raiseETH, lockMonths, block.timestamp));
        address[] memory holders = new address[](1);
        holders[0] = deployer;
        uint256[] memory shares_ = new uint256[](1);
        shares_[0] = 1 ether;

        bytes32 summonerSalt = keccak256(abi.encode(holders, shares_, salt));
        r.dao = _predictClone(MOLOCH_IMPL, summonerSalt, SUMMONER);
        bytes32 childSalt = bytes32(bytes20(r.dao));
        r.shares = _predictClone(SHARES_IMPL, childSalt, r.dao);
        r.loot = _predictClone(LOOT_IMPL, childSalt, r.dao);

        uint256 unlockTime = block.timestamp + (lockMonths * 30 days);

        Call[] memory customCalls = new Call[](5);
        customCalls[0] = Call(r.dao, 0, abi.encodeWithSignature("setProposalTTL(uint64)", uint64(7 days)));
        customCalls[1] = Call(r.dao, 0, abi.encodeWithSignature("setTimelockDelay(uint64)", uint64(3 days)));
        customCalls[2] =
            Call(r.shares, 0, abi.encodeWithSignature("mintFromMoloch(address,uint256)", r.dao, teamSupply));
        customCalls[3] = Call(r.shares, 0, abi.encodeWithSignature("approve(address,uint256)", ZAMM, teamSupply));
        customCalls[4] = Call(
            ZAMM,
            0,
            abi.encodeWithSignature(
                "lockup(address,address,uint256,uint256,uint256)", r.shares, deployer, 0, teamSupply, unlockTime
            )
        );

        vm.prank(deployer);
        daico.summonDAICOWithTapCustom(
            SummonConfig(SUMMONER, MOLOCH_IMPL, SHARES_IMPL, LOOT_IMPL),
            "AdvancedCoin",
            "ADV",
            "ipfs://QmAdvanced",
            QUORUM_BPS,
            true,
            RENDERER,
            salt,
            holders,
            shares_,
            false,
            false,
            DAICOConfig({
                tribTkn: address(0),
                tribAmt: tribAmt,
                saleSupply: saleSupply,
                forAmt: forAmt,
                deadline: 0,
                sellLoot: false,
                lpBps: lpBps,
                maxSlipBps: 100,
                feeOrHook: FEE
            }),
            TapConfig({ops: deployer, ratePerSec: tapRate, tapAllowance: expectedTreasury}),
            customCalls
        );
    }
}
