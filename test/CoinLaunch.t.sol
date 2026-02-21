// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

/// @dev Minimal interfaces — no source imports needed (fork test against deployed contracts)

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
    // Governance
    function config() external view returns (uint64);
    function proposalId(uint8 op, address to, uint256 value, bytes calldata data, bytes32 nonce)
        external
        view
        returns (uint256);
    function castVote(uint256 id, uint8 support) external;
    function state(uint256 id) external view returns (uint8); // 0=Unopened,1=Active,2=Queued,3=Succeeded,4=Defeated,5=Expired,6=Executed
    function executeByVotes(uint8 op, address to, uint256 value, bytes calldata data, bytes32 nonce)
        external
        payable
        returns (bool ok, bytes memory retData);
    function setAllowance(address spender, address token, uint256 amount) external;
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
    function swapExactOut(
        PoolKey calldata key,
        uint256 swapAmount,
        uint256 amountLimit,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountIn);
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
    function unlock(address token, address to, uint256 id, uint256 amount, uint256 unlockTime) external;
}

interface IzQuoter {
    function quoteZAMM(
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount
    ) external view returns (uint256 amountIn, uint256 amountOut);
}

contract CoinLaunchTest is Test {
    // Deployed addresses (mainnet)
    address constant SUMMONER = 0x0000000000330B8df9E3bc5E553074DA58eE9138;
    IDAICO constant daico = IDAICO(0x000000000033e92DB97B4B3beCD2c255126C60aC);
    address constant RENDERER = 0x000000000011C799980827F52d3137b4abD6E654;
    IZAMM constant zamm = IZAMM(0x000000000000040470635EB91b7CE4D132D616eD);
    address constant ZAMM = 0x000000000000040470635EB91b7CE4D132D616eD;
    IzQuoter constant zQuoter = IzQuoter(0xBe3d86dc8FFfd8FFC1B6fC7e1320417c9C7F18c5);

    // Impl addresses (for CREATE2 prediction)
    address constant MOLOCH_IMPL = 0x643A45B599D81be3f3A68F37EB3De55fF10673C1;
    address constant SHARES_IMPL = 0x71E9b38d301b5A58cb998C1295045FE276Acf600;
    address constant LOOT_IMPL = 0x6f1f2aF76a3aDD953277e9F369242697C87bc6A5;

    // Template params (matching our dapp exactly)
    uint256 constant COIN_SUPPLY = 1_000_000_000;
    uint256 constant SALE_BPS = 8500;
    uint256 constant TEAM_BPS = 1500;
    uint16 constant LP_BPS = 3300;
    uint256 constant FEE = 30;
    uint16 constant QUORUM_BPS = 1500;
    uint64 constant VOTING_SECS = 7 days;
    uint64 constant TIMELOCK_SECS = 3 days;
    uint256 constant TAP_MONTHS = 3;
    uint256 constant SEC_PER_MONTH = 2_629_746;

    address deployer;
    address buyer1;
    address buyer2;

    function setUp() public {
        // Use explicit EOA addresses to avoid collisions with mainnet contracts
        // (makeAddr("deployer") = 0xaE0bDc4e... is an EOF contract on mainnet)
        deployer = address(uint160(uint256(keccak256("coin_deployer"))));
        buyer1 = address(uint160(uint256(keccak256("coin_buyer1"))));
        buyer2 = address(uint160(uint256(keccak256("coin_buyer2"))));
        vm.deal(deployer, 100 ether);
        vm.deal(buyer1, 100 ether);
        vm.deal(buyer2, 100 ether);
    }

    // ==================== HELPERS ====================

    struct LaunchResult {
        address dao;
        address shares;
        address loot;
        uint256 deployTime;
    }

    function _launch(uint256 raiseETH, uint256 lockMonths) internal returns (LaunchResult memory r) {
        r.deployTime = block.timestamp;

        uint256 saleSupply = (COIN_SUPPLY * SALE_BPS / 10000) * 1e18;
        uint256 teamSupply = (COIN_SUPPLY * TEAM_BPS / 10000) * 1e18;

        // Sale rate: 1 ETH → (saleSupply / raiseETH) shares (same math as dapp JS)
        uint256 tribAmt = 1 ether;
        uint256 forAmt = (COIN_SUPPLY * SALE_BPS / 10000 / raiseETH) * 1e18;

        // Tap: treasury portion over 3 months (matching fixed JS)
        uint256 treasuryBps = 10000 - LP_BPS;
        uint256 expectedTreasury = (raiseETH * 1e18 * treasuryBps) / 10000;
        uint128 tapRate = uint128(expectedTreasury / (SEC_PER_MONTH * TAP_MONTHS));
        if (tapRate == 0 && expectedTreasury > 0) tapRate = 1;

        bytes32 salt = keccak256(abi.encode("test", raiseETH, lockMonths, block.timestamp));
        address[] memory holders = new address[](1);
        holders[0] = deployer;
        uint256[] memory shares_ = new uint256[](1);
        shares_[0] = 1 ether;

        // Predict addresses (same as JS coinPredict)
        bytes32 summonerSalt = keccak256(abi.encode(holders, shares_, salt));
        r.dao = _predictClone(MOLOCH_IMPL, summonerSalt, SUMMONER);
        bytes32 childSalt = bytes32(bytes20(r.dao));
        r.shares = _predictClone(SHARES_IMPL, childSalt, r.dao);
        r.loot = _predictClone(LOOT_IMPL, childSalt, r.dao);

        // Build custom calls (same as JS coinLaunch)
        uint256 unlockTime = block.timestamp + (lockMonths * 30 days);

        Call[] memory customCalls = new Call[](5);
        customCalls[0] = Call(r.dao, 0, abi.encodeWithSignature("setProposalTTL(uint64)", VOTING_SECS));
        customCalls[1] = Call(r.dao, 0, abi.encodeWithSignature("setTimelockDelay(uint64)", TIMELOCK_SECS));
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
            "TestCoin",
            "TEST",
            "ipfs://QmTest",
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
                lpBps: LP_BPS,
                maxSlipBps: 100,
                feeOrHook: FEE
            }),
            TapConfig({ops: deployer, ratePerSec: tapRate, tapAllowance: expectedTreasury}),
            customCalls
        );
    }

    function _predictClone(address impl, bytes32 salt_, address deployer_) internal pure returns (address) {
        bytes memory code =
            abi.encodePacked(hex"602d5f8160095f39f35f5f365f5f37365f73", impl, hex"5af43d5f5f3e6029573d5ffd5b3d5ff3");
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer_, salt_, keccak256(code))))));
    }

    // ==================== DEPLOYMENT TESTS ====================

    function test_deploy_1ETH() public {
        LaunchResult memory r = _launch(1, 6);
        _verifyDeployment(r, 1, 6);
    }

    function test_deploy_10ETH() public {
        LaunchResult memory r = _launch(10, 6);
        _verifyDeployment(r, 10, 6);
    }

    function test_deploy_3mo_lock() public {
        LaunchResult memory r = _launch(5, 3);
        _verifyDeployment(r, 5, 3);
    }

    function test_deploy_12mo_lock() public {
        LaunchResult memory r = _launch(5, 12);
        _verifyDeployment(r, 5, 12);
    }

    function _verifyDeployment(LaunchResult memory r, uint256 raiseETH, uint256 lockMonths) internal view {
        IMoloch dao = IMoloch(r.dao);
        IShares shares = IShares(r.shares);

        uint256 saleSupply = (COIN_SUPPLY * SALE_BPS / 10000) * 1e18;
        uint256 teamSupply = (COIN_SUPPLY * TEAM_BPS / 10000) * 1e18;

        // DAO metadata
        assertEq(dao.name(0), "TestCoin", "name");
        assertEq(dao.symbol(0), "TEST", "symbol");
        assertEq(dao.contractURI(), "ipfs://QmTest", "contractURI");

        // Governance
        assertTrue(dao.ragequittable(), "ragequittable");
        assertEq(dao.quorumBps(), QUORUM_BPS, "quorumBps");
        assertEq(dao.proposalTTL(), VOTING_SECS, "proposalTTL");
        assertEq(dao.timelockDelay(), TIMELOCK_SECS, "timelockDelay");

        // Shares token addresses
        assertEq(dao.shares(), r.shares, "shares addr");
        assertEq(dao.loot(), r.loot, "loot addr");

        // Supply: 1 (deployer) + saleSupply + teamSupply
        assertEq(shares.totalSupply(), 1 ether + saleSupply + teamSupply, "totalSupply");

        // DAO holds exactly the sale supply
        assertEq(shares.balanceOf(r.dao), saleSupply, "DAO holds sale supply");

        // ZAMM holds team shares
        assertEq(shares.balanceOf(ZAMM), teamSupply, "ZAMM holds team shares");

        // Deployer holds 1 init share
        assertEq(shares.balanceOf(deployer), 1 ether, "deployer init shares");

        // ZAMM lockup registered
        uint256 unlockTime = r.deployTime + (lockMonths * 30 days);
        bytes32 lockHash = keccak256(abi.encode(r.shares, deployer, uint256(0), teamSupply, unlockTime));
        assertEq(zamm.lockups(lockHash), unlockTime, "lockup registered");

        // Tap allowance
        uint256 treasuryBps = 10000 - LP_BPS;
        uint256 expectedTreasury = (raiseETH * 1e18 * treasuryBps) / 10000;
        assertEq(dao.allowance(address(0), address(daico)), expectedTreasury, "tap allowance");

        // DAICO approved for sale
        assertEq(shares.allowance(r.dao, address(daico)), saleSupply, "DAICO sale approval");
    }

    // ==================== BUY TESTS ====================

    function test_buy_basic() public {
        LaunchResult memory r = _launch(10, 6);
        IShares shares = IShares(r.shares);

        vm.prank(buyer1);
        daico.buy{value: 1 ether}(r.dao, address(0), 1 ether, 0);

        uint256 received = shares.balanceOf(buyer1);
        assertGt(received, 0, "buyer got shares");
        assertGt(r.dao.balance, 0, "DAO has ETH");

        emit log_named_uint("Shares received for 1 ETH", received / 1e18);
        emit log_named_uint("DAO treasury ETH (wei)", r.dao.balance);
    }

    function test_buy_multiple_buyers() public {
        LaunchResult memory r = _launch(10, 6);
        IShares shares = IShares(r.shares);

        vm.prank(buyer1);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);

        vm.prank(buyer2);
        daico.buy{value: 3 ether}(r.dao, address(0), 3 ether, 0);

        uint256 b1 = shares.balanceOf(buyer1);
        uint256 b2 = shares.balanceOf(buyer2);
        assertGt(b1, 0, "buyer1 got shares");
        assertGt(b2, b1, "buyer2 got more (paid more)");

        emit log_named_uint("Buyer1 shares (2 ETH)", b1 / 1e18);
        emit log_named_uint("Buyer2 shares (3 ETH)", b2 / 1e18);
        emit log_named_uint("DAO treasury", r.dao.balance);
    }

    function test_buy_seeds_zamm_pool() public {
        LaunchResult memory r = _launch(5, 6);

        vm.prank(buyer1);
        daico.buy{value: 1 ether}(r.dao, address(0), 1 ether, 0);

        // Check ZAMM pool: token0=ETH(0), token1=shares, fee=30
        uint256 poolId = uint256(keccak256(abi.encode(uint256(0), uint256(0), address(0), r.shares, FEE)));
        (uint112 res0, uint112 res1,,,,, uint256 supply) = zamm.pools(poolId);

        assertGt(res0, 0, "pool ETH reserves");
        assertGt(res1, 0, "pool share reserves");
        assertGt(supply, 0, "pool LP supply");

        emit log_named_uint("Pool ETH", res0);
        emit log_named_uint("Pool Shares", uint256(res1) / 1e18);
    }

    // ==================== TAP TESTS ====================

    function test_tap_claim_after_30_days() public {
        LaunchResult memory r = _launch(10, 6);

        // Fund treasury
        vm.prank(buyer1);
        daico.buy{value: 5 ether}(r.dao, address(0), 5 ether, 0);
        assertGt(r.dao.balance, 0, "treasury funded");

        vm.warp(block.timestamp + 30 days);

        uint256 opsBefore = deployer.balance;
        daico.claimTap(r.dao);
        uint256 claimed = deployer.balance - opsBefore;
        assertGt(claimed, 0, "ops received ETH");

        // Verify ~1 month of tap
        uint256 treasuryBps = 10000 - LP_BPS;
        uint256 expectedTreasury = (10 ether * treasuryBps) / 10000;
        uint128 tapRate = uint128(expectedTreasury / (SEC_PER_MONTH * TAP_MONTHS));
        uint256 expectedClaim = uint256(tapRate) * 30 days;
        assertApproxEqRel(claimed, expectedClaim, 0.01e18, "~1 month tap");

        emit log_named_uint("Claimed", claimed);
        emit log_named_uint("Expected", expectedClaim);
    }

    function test_tap_capped_at_treasury() public {
        LaunchResult memory r = _launch(1, 6);

        // Tiny buy
        vm.prank(buyer1);
        daico.buy{value: 0.1 ether}(r.dao, address(0), 0.1 ether, 0);
        uint256 treasury = r.dao.balance;

        // Warp way past tap period
        vm.warp(block.timestamp + 365 days);

        uint256 opsBefore = deployer.balance;
        daico.claimTap(r.dao);
        uint256 claimed = deployer.balance - opsBefore;

        assertLe(claimed, treasury, "tap capped at treasury");
        emit log_named_uint("Treasury was", treasury);
        emit log_named_uint("Claimed", claimed);
    }

    // ==================== RAGEQUIT TEST ====================

    function test_ragequit() public {
        LaunchResult memory r = _launch(10, 6);
        IShares shares = IShares(r.shares);

        vm.prank(buyer1);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);

        uint256 buyerShares = shares.balanceOf(buyer1);
        assertGt(buyerShares, 0);

        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        uint256 balBefore = buyer1.balance;
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, buyerShares, 0);
        uint256 ethBack = buyer1.balance - balBefore;

        assertGt(ethBack, 0, "got ETH back");
        assertEq(shares.balanceOf(buyer1), 0, "shares burned");

        emit log_named_uint("Paid", 2 ether);
        emit log_named_uint("Ragequit ETH", ethBack);
    }

    // ==================== LOCKUP TESTS ====================

    function test_lockup_blocks_early_unlock() public {
        LaunchResult memory r = _launch(5, 6);
        uint256 teamSupply = (COIN_SUPPLY * TEAM_BPS / 10000) * 1e18;
        uint256 unlockTime = r.deployTime + (6 * 30 days);

        vm.expectRevert();
        zamm.unlock(r.shares, deployer, 0, teamSupply, unlockTime);
    }

    function test_lockup_succeeds_after_cliff() public {
        LaunchResult memory r = _launch(5, 6);
        IShares shares = IShares(r.shares);
        uint256 teamSupply = (COIN_SUPPLY * TEAM_BPS / 10000) * 1e18;
        uint256 unlockTime = r.deployTime + (6 * 30 days);

        vm.warp(unlockTime + 1);

        uint256 before = shares.balanceOf(deployer);
        zamm.unlock(r.shares, deployer, 0, teamSupply, unlockTime);
        uint256 received = shares.balanceOf(deployer) - before;

        assertEq(received, teamSupply, "team got locked shares");
        emit log_named_uint("Unlocked shares", received / 1e18);
    }

    // ==================== SWAP TESTS (direct ZAMM) ====================

    function _poolKey(address sharesToken) internal pure returns (PoolKey memory) {
        return PoolKey(0, 0, address(0), sharesToken, FEE);
    }

    function test_swap_buy_on_pool() public {
        LaunchResult memory r = _launch(5, 6);
        IShares shares = IShares(r.shares);

        // First buy via DAICO to seed the pool
        vm.prank(buyer1);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);

        // Quote: how many shares for 0.1 ETH?
        (, uint256 qOut) = zQuoter.quoteZAMM(false, FEE, address(0), r.shares, 0, 0, 0.1 ether);
        assertGt(qOut, 0, "quote amountOut > 0");
        emit log_named_uint("Quote: 0.1 ETH buys shares", qOut / 1e18);

        // Swap directly on ZAMM: buyer2 buys shares with ETH
        // zeroForOne=true (ETH=token0 in, shares=token1 out)
        uint256 minOut = qOut * 95 / 100;
        uint256 sharesBefore = shares.balanceOf(buyer2);

        vm.prank(buyer2);
        uint256 amtOut = zamm.swapExactIn{value: 0.1 ether}(
            _poolKey(r.shares), 0.1 ether, minOut, true, buyer2, block.timestamp + 300
        );

        assertGt(amtOut, 0, "swap received shares");
        assertEq(shares.balanceOf(buyer2) - sharesBefore, amtOut, "shares delivered");
        emit log_named_uint("Swapped 0.1 ETH for shares", amtOut / 1e18);
    }

    function test_swap_sell_on_pool() public {
        LaunchResult memory r = _launch(5, 6);
        IShares shares = IShares(r.shares);

        // Buy via DAICO (seeds pool + gives buyer1 shares)
        vm.prank(buyer1);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);

        uint256 sellAmount = 1_000_000 * 1e18; // sell 1M shares
        assertGt(shares.balanceOf(buyer1), sellAmount, "buyer has enough shares");

        // Quote sell
        (, uint256 qOut) = zQuoter.quoteZAMM(false, FEE, r.shares, address(0), 0, 0, sellAmount);
        assertGt(qOut, 0, "quote sell amountOut > 0");
        emit log_named_uint("Quote: 1M shares sells for ETH (wei)", qOut);

        // Approve ZAMM directly to spend shares
        vm.prank(buyer1);
        shares.approve(ZAMM, sellAmount);

        // Swap directly on ZAMM: sell shares for ETH
        // zeroForOne=false (shares=token1 in, ETH=token0 out)
        uint256 ethBefore = buyer1.balance;
        uint256 minOut = qOut * 95 / 100;

        vm.prank(buyer1);
        uint256 amtOut = zamm.swapExactIn(_poolKey(r.shares), sellAmount, minOut, false, buyer1, block.timestamp + 300);

        assertGt(amtOut, 0, "received ETH");
        assertEq(buyer1.balance - ethBefore, amtOut, "ETH delivered");
        emit log_named_uint("Sold 1M shares for ETH (wei)", amtOut);
    }

    function test_swap_exact_out_buy() public {
        LaunchResult memory r = _launch(5, 6);
        IShares shares = IShares(r.shares);

        // Seed pool
        vm.prank(buyer1);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);

        // Quote: how much ETH to get exactly 10M shares?
        uint256 wantShares = 10_000_000 * 1e18;
        (uint256 qIn,) = zQuoter.quoteZAMM(true, FEE, address(0), r.shares, 0, 0, wantShares);
        assertGt(qIn, 0, "quote cost > 0");
        emit log_named_uint("Quote: 10M shares costs ETH (wei)", qIn);

        // Exact out swap: buy exactly 10M shares, pay up to 5% more
        uint256 maxIn = qIn * 105 / 100;
        uint256 sharesBefore = shares.balanceOf(buyer2);

        vm.prank(buyer2);
        uint256 amtIn =
            zamm.swapExactOut{value: maxIn}(_poolKey(r.shares), wantShares, maxIn, true, buyer2, block.timestamp + 300);

        assertEq(shares.balanceOf(buyer2) - sharesBefore, wantShares, "got exact shares");
        assertLe(amtIn, maxIn, "didn't overpay");
        emit log_named_uint("Paid ETH (wei)", amtIn);
        emit log_named_uint("Got shares", wantShares / 1e18);
    }

    function test_swap_exact_out_sell() public {
        LaunchResult memory r = _launch(5, 6);
        IShares shares = IShares(r.shares);

        // Seed pool + give buyer1 shares
        vm.prank(buyer1);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);

        // Quote: how many shares to sell for exactly 0.01 ETH?
        uint256 wantETH = 0.01 ether;
        (uint256 qIn,) = zQuoter.quoteZAMM(true, FEE, r.shares, address(0), 0, 0, wantETH);
        assertGt(qIn, 0, "quote shares cost > 0");
        emit log_named_uint("Quote: 0.01 ETH costs shares", qIn / 1e18);

        // Approve ZAMM for max shares
        uint256 maxIn = qIn * 105 / 100;
        vm.prank(buyer1);
        shares.approve(ZAMM, maxIn);

        // Exact out swap: get exactly 0.01 ETH
        uint256 ethBefore = buyer1.balance;
        vm.prank(buyer1);
        uint256 amtIn = zamm.swapExactOut(_poolKey(r.shares), wantETH, maxIn, false, buyer1, block.timestamp + 300);

        assertEq(buyer1.balance - ethBefore, wantETH, "got exact ETH");
        assertLe(amtIn, maxIn, "didn't oversell");
        emit log_named_uint("Sold shares", amtIn / 1e18);
        emit log_named_uint("Got ETH (wei)", wantETH);
    }

    // ==================== GOVERNANCE TESTS ====================

    function test_governance_turn_off_tap() public {
        LaunchResult memory r = _launch(10, 6);
        IMoloch dao = IMoloch(r.dao);

        // buyer1 buys — gets majority voting power
        vm.prank(buyer1);
        daico.buy{value: 5 ether}(r.dao, address(0), 5 ether, 0);
        assertGt(r.dao.balance, 0, "treasury funded");

        // Advance block so snapshot sees buyer1's shares
        vm.roll(block.number + 2);

        // Proposal: DAO calls setAllowance(daico, address(0), 0) on itself to kill tap
        uint8 op = 0; // call
        address to = r.dao;
        uint256 value = 0;
        bytes memory data =
            abi.encodeWithSignature("setAllowance(address,address,uint256)", address(daico), address(0), 0);
        bytes32 nonce = bytes32("kill_tap");

        // Get proposal ID
        uint256 propId = dao.proposalId(op, to, value, data, nonce);
        assertEq(dao.state(propId), 0, "proposal is Unopened");

        // buyer1 votes FOR (auto-opens proposal)
        vm.prank(buyer1);
        dao.castVote(propId, 1); // 1 = FOR

        // With enough shares voting, proposal should be Succeeded immediately
        uint8 st = dao.state(propId);
        assertEq(st, 3, "proposal Succeeded"); // 3 = Succeeded

        // Execute — first call queues it (timelockDelay = 3 days)
        dao.executeByVotes(op, to, value, data, nonce);
        assertEq(dao.state(propId), 2, "proposal Queued"); // 2 = Queued

        // Wait for timelock
        vm.warp(block.timestamp + TIMELOCK_SECS + 1);

        // Execute again — now it actually runs
        (bool ok,) = dao.executeByVotes(op, to, value, data, nonce);
        assertTrue(ok, "execution succeeded");
        assertEq(dao.state(propId), 6, "proposal Executed"); // 6 = Executed

        // Verify tap is dead — allowance should be 0
        assertEq(dao.allowance(address(0), address(daico)), 0, "tap allowance zeroed");

        // claimTap should now revert
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert();
        daico.claimTap(r.dao);

        emit log("Tap successfully killed by governance vote");
    }

    function test_governance_change_quorum() public {
        LaunchResult memory r = _launch(10, 6);
        IMoloch dao = IMoloch(r.dao);

        // buyer1 buys
        vm.prank(buyer1);
        daico.buy{value: 3 ether}(r.dao, address(0), 3 ether, 0);
        vm.roll(block.number + 2);

        // Proposal: change quorum from 15% to 25%
        uint8 op = 0;
        address to = r.dao;
        bytes memory data = abi.encodeWithSignature("setQuorumBps(uint16)", uint16(2500));
        bytes32 nonce = bytes32("new_quorum");

        uint256 propId = dao.proposalId(op, to, 0, data, nonce);

        // Vote
        vm.prank(buyer1);
        dao.castVote(propId, 1);
        assertEq(dao.state(propId), 3, "Succeeded");

        // Queue + timelock + execute
        dao.executeByVotes(op, to, 0, data, nonce);
        vm.warp(block.timestamp + TIMELOCK_SECS + 1);
        dao.executeByVotes(op, to, 0, data, nonce);

        // Verify
        assertEq(dao.quorumBps(), 2500, "quorum updated to 25%");
        emit log("Quorum changed to 25% by governance");
    }

    // ==================== CONFIGURABLE LAUNCH ====================

    struct CoinConfig {
        uint256 raise;
        uint256 teamBps;
        uint256 lockMonths;
        uint256 tapMonths;
        uint16 lpBps;
    }

    function _launchCustom(CoinConfig memory cfg) internal returns (LaunchResult memory r) {
        r.deployTime = block.timestamp;

        uint256 saleBps = 10000 - cfg.teamBps;
        uint256 saleSupply = (COIN_SUPPLY * saleBps / 10000) * 1e18;
        uint256 teamSupply = (COIN_SUPPLY * cfg.teamBps / 10000) * 1e18;

        uint256 tribAmt = 1 ether;
        uint256 forAmt = (COIN_SUPPLY * saleBps / 10000 / cfg.raise) * 1e18;

        uint256 treasuryBps = 10000 - cfg.lpBps;
        uint256 expectedTreasury = (cfg.raise * 1e18 * treasuryBps) / 10000;
        uint128 tapRate = uint128(expectedTreasury / (SEC_PER_MONTH * cfg.tapMonths));
        if (tapRate == 0 && expectedTreasury > 0) tapRate = 1;

        bytes32 salt =
            keccak256(abi.encode("custom", cfg.raise, cfg.lockMonths, cfg.tapMonths, cfg.lpBps, block.timestamp));
        address[] memory holders = new address[](1);
        holders[0] = deployer;
        uint256[] memory shares_ = new uint256[](1);
        shares_[0] = 1 ether;

        bytes32 summonerSalt = keccak256(abi.encode(holders, shares_, salt));
        r.dao = _predictClone(MOLOCH_IMPL, summonerSalt, SUMMONER);
        bytes32 childSalt = bytes32(bytes20(r.dao));
        r.shares = _predictClone(SHARES_IMPL, childSalt, r.dao);
        r.loot = _predictClone(LOOT_IMPL, childSalt, r.dao);

        uint256 unlockTime = block.timestamp + (cfg.lockMonths * 30 days);

        Call[] memory customCalls = new Call[](5);
        customCalls[0] = Call(r.dao, 0, abi.encodeWithSignature("setProposalTTL(uint64)", VOTING_SECS));
        customCalls[1] = Call(r.dao, 0, abi.encodeWithSignature("setTimelockDelay(uint64)", TIMELOCK_SECS));
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
            "TestCoin",
            "TEST",
            "ipfs://QmTest",
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
                lpBps: cfg.lpBps,
                maxSlipBps: 100,
                feeOrHook: FEE
            }),
            TapConfig({ops: deployer, ratePerSec: tapRate, tapAllowance: expectedTreasury}),
            customCalls
        );
    }

    // ==================== STANDARD TEMPLATE TEST ====================

    function test_standard_template() public {
        emit log("=== STANDARD TEMPLATE: 5 ETH, 15% team, 6mo lock, 3mo tap, 33% LP ===");

        CoinConfig memory std = CoinConfig({raise: 5, teamBps: 1500, lockMonths: 6, tapMonths: 3, lpBps: 3300});
        LaunchResult memory r = _launchCustom(std);
        IShares shares = IShares(r.shares);
        IMoloch dao = IMoloch(r.dao);

        // Verify supply split
        uint256 saleSupply = 850_000_000 * 1e18; // 85%
        uint256 teamSupply = 150_000_000 * 1e18; // 15%
        assertEq(shares.totalSupply(), 1 ether + saleSupply + teamSupply, "total supply");
        assertEq(shares.balanceOf(r.dao), saleSupply, "DAO holds sale supply");
        assertEq(shares.balanceOf(ZAMM), teamSupply, "ZAMM holds team supply");

        // Verify tap allowance = 67% of 5 ETH = 3.35 ETH
        uint256 expectedTreasury = (5 ether * 6700) / 10000;
        assertEq(dao.allowance(address(0), address(daico)), expectedTreasury, "tap allowance = 3.35 ETH");

        // Full raise: 5 ETH of buys
        vm.prank(buyer1);
        daico.buy{value: 3 ether}(r.dao, address(0), 3 ether, 0);
        vm.prank(buyer2);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);

        uint256 treasuryAfterRaise = r.dao.balance;
        emit log_named_uint("Treasury after full raise", treasuryAfterRaise);
        emit log_named_uint("Buyer1 shares", shares.balanceOf(buyer1) / 1e18);
        emit log_named_uint("Buyer2 shares", shares.balanceOf(buyer2) / 1e18);

        // Treasury should be ~67% of raise (rest went to LP)
        assertApproxEqRel(treasuryAfterRaise, expectedTreasury, 0.01e18, "treasury ~67% of raise");

        // Tap claim after 30 days
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 30 days);
        uint256 opsBefore = deployer.balance;
        daico.claimTap(r.dao);
        uint256 tap30d = deployer.balance - opsBefore;
        emit log_named_uint("Tap after 30d", tap30d);

        // Should be ~1/3 of budget (1 month of 3)
        assertApproxEqRel(tap30d, expectedTreasury / 3, 0.02e18, "~1mo of 3mo tap");

        // Tap claim after another 30 days
        vm.warp(t0 + 60 days);
        opsBefore = deployer.balance;
        daico.claimTap(r.dao);
        uint256 tap60d = deployer.balance - opsBefore;
        emit log_named_uint("Tap after 60d", tap60d);

        // Tap claim after final 30 days — drain remainder (may revert if empty)
        vm.warp(t0 + 90 days);
        opsBefore = deployer.balance;
        uint256 treasuryBefore90 = r.dao.balance;
        if (treasuryBefore90 > 0) {
            try daico.claimTap(r.dao) {
                uint256 tap90d = deployer.balance - opsBefore;
                emit log_named_uint("Tap after 90d", tap90d);
            } catch {
                emit log("Tap reverted (treasury empty)");
            }
        }

        emit log_named_uint("Treasury after 3mo tap", r.dao.balance);
        // Treasury should be nearly empty (tap consumed it all)
        assertLt(r.dao.balance, 0.05 ether, "treasury mostly drained after 3mo");

        // Team unlock after 6 months
        uint256 unlockTime = r.deployTime + (6 * 30 days);
        vm.warp(unlockTime + 1);
        uint256 teamBefore = shares.balanceOf(deployer);
        zamm.unlock(r.shares, deployer, 0, teamSupply, unlockTime);
        assertEq(shares.balanceOf(deployer) - teamBefore, teamSupply, "team tokens unlocked");

        emit log("=== Standard template lifecycle complete ===");
    }

    // ==================== CUSTOM CONFIG TEST ====================

    function test_custom_config_high_raise() public {
        emit log("=== CUSTOM: 50 ETH, 10% team, 12mo lock, 6mo tap, 20% LP ===");

        CoinConfig memory cfg = CoinConfig({raise: 50, teamBps: 1000, lockMonths: 12, tapMonths: 6, lpBps: 2000});
        LaunchResult memory r = _launchCustom(cfg);
        IShares shares = IShares(r.shares);
        IMoloch dao = IMoloch(r.dao);

        // Verify supply: 90% sale, 10% team
        uint256 saleSupply = 900_000_000 * 1e18;
        uint256 teamSupply = 100_000_000 * 1e18;
        assertEq(shares.balanceOf(r.dao), saleSupply, "90% sale supply");
        assertEq(shares.balanceOf(ZAMM), teamSupply, "10% team supply");

        // Tap allowance = 80% of 50 ETH = 40 ETH
        uint256 expectedTreasury = (50 ether * 8000) / 10000;
        assertEq(dao.allowance(address(0), address(daico)), expectedTreasury, "tap = 40 ETH");

        // Partial raise: 10 ETH
        vm.prank(buyer1);
        daico.buy{value: 10 ether}(r.dao, address(0), 10 ether, 0);

        emit log_named_uint("Treasury after 10 ETH buy", r.dao.balance);
        emit log_named_uint("Buyer1 shares", shares.balanceOf(buyer1) / 1e18);

        // Tap after 30 days — rate is based on full 50 ETH raise
        vm.warp(block.timestamp + 30 days);
        uint256 opsBefore = deployer.balance;
        daico.claimTap(r.dao);
        uint256 claimed = deployer.balance - opsBefore;
        emit log_named_uint("Tap claimed (30d, partial raise)", claimed);

        // Rate per month = 40 ETH / 6 = ~6.67 ETH/mo
        // But only ~8 ETH in treasury (80% of 10), so capped by balance
        assertGt(claimed, 0, "tap claimed something");

        // Lockup should block before 12mo
        vm.expectRevert();
        zamm.unlock(r.shares, deployer, 0, teamSupply, r.deployTime + (12 * 30 days));

        emit log("=== Custom config test complete ===");
    }

    // ==================== FULL LIFECYCLE ====================

    function test_full_lifecycle() public {
        emit log("=== DEPLOY (5 ETH raise, 6mo lock) ===");
        LaunchResult memory r = _launch(5, 6);
        IShares shares = IShares(r.shares);

        emit log_named_address("DAO", r.dao);
        emit log_named_address("Shares", r.shares);

        // Multiple buys
        vm.prank(buyer1);
        daico.buy{value: 2 ether}(r.dao, address(0), 2 ether, 0);
        emit log_named_uint("Buyer1 shares (2 ETH)", shares.balanceOf(buyer1) / 1e18);

        vm.prank(buyer2);
        daico.buy{value: 1 ether}(r.dao, address(0), 1 ether, 0);
        emit log_named_uint("Buyer2 shares (1 ETH)", shares.balanceOf(buyer2) / 1e18);
        emit log_named_uint("Treasury after buys", r.dao.balance);

        // Tap after 1 month
        vm.warp(block.timestamp + 30 days);
        uint256 claimed = daico.claimTap(r.dao);
        emit log_named_uint("Tap claimed (30d)", claimed);

        // Partial ragequit
        uint256 halfShares = shares.balanceOf(buyer1) / 2;
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        uint256 b1Before = buyer1.balance;
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, halfShares, 0);
        emit log_named_uint("Buyer1 ragequit ETH (half)", buyer1.balance - b1Before);

        // More tap
        vm.warp(block.timestamp + 60 days);
        claimed = daico.claimTap(r.dao);
        emit log_named_uint("Tap claimed (next 60d)", claimed);

        // Unlock team tokens
        uint256 teamSupply = (COIN_SUPPLY * TEAM_BPS / 10000) * 1e18;
        uint256 unlockTime = r.deployTime + (6 * 30 days);
        vm.warp(unlockTime + 1);

        uint256 teamBefore = shares.balanceOf(deployer);
        zamm.unlock(r.shares, deployer, 0, teamSupply, unlockTime);
        emit log_named_uint("Team unlocked", (shares.balanceOf(deployer) - teamBefore) / 1e18);

        emit log("=== FINAL STATE ===");
        emit log_named_uint("Treasury", r.dao.balance);
        emit log_named_uint("Total supply", shares.totalSupply() / 1e18);
        emit log_named_uint("Deployer shares", shares.balanceOf(deployer) / 1e18);
    }
}
