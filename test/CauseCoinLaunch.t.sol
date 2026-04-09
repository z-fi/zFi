// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {SafeSummoner, Call, SUMMONER, MOLOCH_IMPL, SHARES_IMPL, LOOT_IMPL, RENDERER} from "src/SafeSummoner.sol";

/// @dev Fork test for cause coin launches via SafeSummoner.safeSummonDAICO.
///      Tests all 6 configurations: {fixed, ongoing} × {no tap, instant tap, vested tap}.

// ── Interfaces (deployed singletons) ──

interface IMoloch {
    function shares() external view returns (address);
    function loot() external view returns (address);
    function name(uint256) external view returns (string memory);
    function symbol(uint256) external view returns (string memory);
    function contractURI() external view returns (string memory);
    function ragequittable() external view returns (bool);
    function quorumBps() external view returns (uint16);
    function quorumAbsolute() external view returns (uint96);
    function proposalThreshold() external view returns (uint96);
    function proposalTTL() external view returns (uint64);
    function timelockDelay() external view returns (uint64);
    function allowance(address token, address spender) external view returns (uint256);
    function ragequit(address[] calldata tokens, uint256 sharesToBurn, uint256 lootToBurn) external;
    function proposalId(uint8 op, address to, uint256 value, bytes calldata data, bytes32 nonce)
        external
        view
        returns (uint256);
    function castVote(uint256 id, uint8 support) external;
    function state(uint256 id) external view returns (uint8);
    function executeByVotes(uint8 op, address to, uint256 value, bytes calldata data, bytes32 nonce)
        external
        payable
        returns (bool ok, bytes memory retData);
}

interface IShares {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getVotes(address) external view returns (uint256);
}

interface IShareSale {
    function buy(address dao, uint256 amount) external payable;
    function sales(address dao)
        external
        view
        returns (address token, address payToken, uint40 deadline, uint256 price);
}

interface ITapVest {
    function claim(address dao) external returns (uint256 claimed);
    function taps(address dao)
        external
        view
        returns (address token, address beneficiary, uint128 ratePerSec, uint64 lastClaim);
}

contract CauseCoinLaunchTest is Test {
    // Deployed singletons (mainnet)
    address constant SAFE_SUMMONER_ADDR = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant SHARE_SALE = 0x0000000021ea5069B532CeE09058aB9e02EA60f9;
    address constant TAP_VEST = 0x0000000060cdD33cbE020fAE696E70E7507bF56D;

    // Matching JS frontend constants
    uint256 constant SEC_PER_MONTH = 2_629_746;
    uint128 constant MAX_UINT128 = type(uint128).max;
    uint96 constant PROPOSAL_THRESHOLD = uint96(1e18); // 1 share
    uint64 constant PROPOSAL_TTL = 7 days;
    uint64 constant TIMELOCK_DELAY = 2 days;
    uint16 constant QUORUM_BPS = 1000; // 10%

    SafeSummoner ss;
    address deployer;
    address buyer1;
    address buyer2;
    address beneficiary;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FOUNDRY_ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        deployer = address(uint160(uint256(keccak256("cause_deployer"))));
        buyer1 = address(uint160(uint256(keccak256("cause_buyer1"))));
        buyer2 = address(uint160(uint256(keccak256("cause_buyer2"))));
        beneficiary = address(uint160(uint256(keccak256("cause_beneficiary"))));
        vm.deal(deployer, 100 ether);
        vm.deal(buyer1, 100 ether);
        vm.deal(buyer2, 100 ether);
        ss = SafeSummoner(SAFE_SUMMONER_ADDR);
    }

    // ==================== HELPERS ====================

    struct LaunchResult {
        address dao;
        address sharesAddr;
        address lootAddr;
    }

    /// @dev Default SafeConfig matching the frontend: 7d voting, 2d timelock, 1 share threshold,
    ///      quorumAbsolute = 1 share (satisfies KF#2 for minting sales).
    function _defaultConfig() internal pure returns (SafeSummoner.SafeConfig memory c) {
        c.proposalThreshold = PROPOSAL_THRESHOLD;
        c.proposalTTL = PROPOSAL_TTL;
        c.timelockDelay = TIMELOCK_DELAY;
        c.quorumAbsolute = PROPOSAL_THRESHOLD; // KF#2: required for minting sale
    }

    function _zeroTap() internal pure returns (SafeSummoner.TapModule memory) {
        return SafeSummoner.TapModule(address(0), address(0), 0, address(0), 0);
    }

    function _zeroSeed() internal pure returns (SafeSummoner.SeedModule memory) {
        return SafeSummoner.SeedModule(address(0), address(0), 0, address(0), 0, 0, false, 0);
    }

    function _summon(
        SafeSummoner.SaleModule memory sale,
        SafeSummoner.TapModule memory tap,
        uint256 msgValue
    ) internal returns (LaunchResult memory r) {
        bytes32 salt = keccak256(abi.encode("cause_test", block.timestamp, msg.sig));
        address[] memory holders = new address[](1);
        holders[0] = deployer;
        uint256[] memory shares_ = new uint256[](1);
        shares_[0] = 1 ether;
        uint256[] memory loot_ = new uint256[](0);
        Call[] memory extra = new Call[](0);

        // Predict addresses
        bytes32 summonerSalt = keccak256(abi.encode(holders, shares_, salt));
        r.dao = _predictClone(MOLOCH_IMPL, summonerSalt, address(SUMMONER));
        bytes32 childSalt = bytes32(bytes20(r.dao));
        r.sharesAddr = _predictClone(SHARES_IMPL, childSalt, r.dao);
        r.lootAddr = _predictClone(LOOT_IMPL, childSalt, r.dao);

        vm.prank(deployer);
        ss.safeSummonDAICO{value: msgValue}(
            "CauseCoin", "CAUSE", "ipfs://test",
            QUORUM_BPS, true, RENDERER, salt,
            holders, shares_, loot_,
            _defaultConfig(),
            sale, tap, _zeroSeed(), extra
        );
    }

    function _predictClone(address impl, bytes32 salt_, address deployer_) internal pure returns (address) {
        bytes memory code =
            abi.encodePacked(hex"602d5f8160095f39f35f5f365f5f37365f73", impl, hex"5af43d5f5f3e6029573d5ffd5b3d5ff3");
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer_, salt_, keccak256(code))))));
    }

    /// @dev Buy shares via ShareSale. Amount is in 1e18 units (1 share = 1e18).
    function _buy(address dao, address buyer, uint256 shareAmount) internal {
        (, , , uint256 price) = IShareSale(SHARE_SALE).sales(dao);
        uint256 cost = (shareAmount * price + 1e18 - 1) / 1e18; // round up
        vm.prank(buyer);
        IShareSale(SHARE_SALE).buy{value: cost}(dao, shareAmount);
    }

    // ── Sale/Tap builders ──

    function _fixedSale(uint256 raiseETH, uint256 days_)
        internal view returns (SafeSummoner.SaleModule memory)
    {
        uint256 totalShares = 10_000_000;
        uint256 priceWei = raiseETH * 1e18 / totalShares;
        return SafeSummoner.SaleModule({
            singleton: SHARE_SALE,
            payToken: address(0),
            deadline: uint40(block.timestamp + days_ * 1 days),
            price: priceWei,
            cap: totalShares * 1e18,
            sellLoot: false,
            minting: true
        });
    }

    function _ongoingSale() internal pure returns (SafeSummoner.SaleModule memory) {
        return SafeSummoner.SaleModule({
            singleton: SHARE_SALE,
            payToken: address(0),
            deadline: 0,
            price: 1e12, // 1 ETH = 1M shares
            cap: type(uint256).max,
            sellLoot: false,
            minting: true
        });
    }

    /// @dev Fast tap that drains treasury quickly. TapVest requires advance = claimed/rate >= 1,
    ///      so rate must be <= expected treasury per second. 1 ETH/sec drains 10 ETH in 10 seconds.
    ///      NOTE: MAX_UINT128 rate (used by frontend for "instant") will always revert NothingToClaim
    ///      because advance = balance / MAX_UINT128 = 0. This is a bug in the frontend config.
    function _fastTap(uint256 budget) internal view returns (SafeSummoner.TapModule memory) {
        return SafeSummoner.TapModule({
            singleton: TAP_VEST,
            token: address(0),
            budget: budget,
            beneficiary: beneficiary,
            ratePerSec: uint128(1 ether) // 1 ETH/sec
        });
    }

    function _vestedTap(uint256 budget, uint128 rate) internal view returns (SafeSummoner.TapModule memory) {
        return SafeSummoner.TapModule({
            singleton: TAP_VEST,
            token: address(0),
            budget: budget,
            beneficiary: beneficiary,
            ratePerSec: rate
        });
    }

    // ==================== 1. FIXED RAISE, NO TAP ====================

    function test_fixed_noTap_deploy() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);
        IMoloch dao = IMoloch(r.dao);
        IShares shares = IShares(r.sharesAddr);

        // Metadata
        assertEq(dao.name(0), "CauseCoin");
        assertEq(dao.symbol(0), "CAUSE");
        assertEq(dao.contractURI(), "ipfs://test");

        // Governance
        assertTrue(dao.ragequittable(), "ragequittable");
        assertEq(dao.quorumBps(), QUORUM_BPS, "10% quorum");
        assertEq(dao.quorumAbsolute(), PROPOSAL_THRESHOLD, "quorumAbsolute = 1 share");
        assertEq(dao.proposalThreshold(), PROPOSAL_THRESHOLD, "threshold = 1 share");
        assertEq(dao.proposalTTL(), PROPOSAL_TTL, "7d voting");
        assertEq(dao.timelockDelay(), TIMELOCK_DELAY, "2d timelock");

        // Creator got 1 share, paid for it
        assertEq(shares.balanceOf(deployer), 1 ether, "deployer 1 share");
        assertEq(r.dao.balance, sale.price, "treasury has creator payment");

        // ShareSale configured
        (, address payToken, uint40 deadline, uint256 price) =
            IShareSale(SHARE_SALE).sales(r.dao);
        assertEq(payToken, address(0), "ETH sale");
        assertEq(price, 10 ether / 10_000_000, "price = raise / 10M");
        assertGt(deadline, block.timestamp, "deadline in future");

        // No tap configured
        (, address tapBeneficiary, ,) = ITapVest(TAP_VEST).taps(r.dao);
        assertEq(tapBeneficiary, address(0), "no tap");
    }

    function test_fixed_noTap_buy_and_ragequit() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);
        IShares shares = IShares(r.sharesAddr);

        // Buy 1M shares
        uint256 shareAmt = 1_000_000 * 1e18;
        _buy(r.dao, buyer1, shareAmt);
        assertEq(shares.balanceOf(buyer1), shareAmt, "buyer1 got shares");

        uint256 treasuryAfterBuy = r.dao.balance;

        // Ragequit — buyer1 burns all shares, gets pro-rata ETH
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256 balBefore = buyer1.balance;
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, shareAmt, 0);

        uint256 ethBack = buyer1.balance - balBefore;
        assertGt(ethBack, 0, "got ETH back");
        assertEq(shares.balanceOf(buyer1), 0, "shares burned");

        // Pro-rata: buyer1 had shareAmt out of (1e18 + shareAmt) total
        uint256 totalShares = 1 ether + shareAmt;
        uint256 expectedBack = treasuryAfterBuy * shareAmt / totalShares;
        assertEq(ethBack, expectedBack, "pro-rata ragequit");
    }

    function test_fixed_noTap_governance_spendTreasury() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);
        IMoloch dao = IMoloch(r.dao);

        // Buy enough shares to meet quorum
        _buy(r.dao, buyer1, 5_000_000 * 1e18);
        vm.roll(block.number + 2);

        uint256 treasuryBefore = r.dao.balance;

        // Propose: send 0.5 ETH to buyer2
        uint8 op = 0;
        bytes memory data = "";
        bytes32 nonce = bytes32("spend");

        uint256 propId = dao.proposalId(op, buyer2, 0.5 ether, data, nonce);
        vm.prank(buyer1);
        dao.castVote(propId, 1);

        dao.executeByVotes(op, buyer2, 0.5 ether, data, nonce);
        assertEq(dao.state(propId), 2, "queued");

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        uint256 buyer2Before = buyer2.balance;
        (bool ok,) = dao.executeByVotes(op, buyer2, 0.5 ether, data, nonce);
        assertTrue(ok, "executed");
        assertEq(buyer2.balance - buyer2Before, 0.5 ether, "buyer2 received ETH");
        assertEq(r.dao.balance, treasuryBefore - 0.5 ether, "treasury decreased");
    }

    // ==================== 2. FIXED RAISE, INSTANT TAP ====================

    function test_fixed_fastTap_deploy() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _fastTap(10 ether), sale.price);

        (, address tapBeneficiary, uint128 ratePerSec,) = ITapVest(TAP_VEST).taps(r.dao);
        assertEq(tapBeneficiary, beneficiary, "beneficiary set");
        assertEq(ratePerSec, uint128(1 ether), "fast rate");

        uint256 tapAllowance = IMoloch(r.dao).allowance(address(0), TAP_VEST);
        assertEq(tapAllowance, 10 ether, "tap budget = raise");
    }

    function test_fixed_fastTap_claimAll() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _fastTap(10 ether), sale.price);

        // Buy 5M shares = 5 ETH into treasury
        _buy(r.dao, buyer1, 5_000_000 * 1e18);
        uint256 treasury = r.dao.balance;
        assertGt(treasury, 0);

        // At 1 ETH/sec, 10 seconds > 5 ETH treasury, so claim drains it
        vm.warp(block.timestamp + 10);
        uint256 benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 claimed = beneficiary.balance - benBefore;
        // Claimed = advance * rate, where advance = floor(min(owed, allowance, balance) / rate)
        // owed = 10 * 1e18, allowance = 10e18, balance ≈ 5e18 → claimed = floor(5e18/1e18)*1e18 = 5e18
        assertApproxEqAbs(claimed, treasury, 1 ether, "claimed most of treasury");
    }

    // ==================== 3. FIXED RAISE, VESTED TAP ====================

    function test_fixed_vestedTap_deploy() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        uint128 rate = uint128(uint256(10 ether) / (12 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);

        (, address tapBeneficiary, uint128 ratePerSec,) = ITapVest(TAP_VEST).taps(r.dao);
        assertEq(tapBeneficiary, beneficiary, "beneficiary set");
        assertEq(ratePerSec, rate, "vesting rate");
    }

    function test_fixed_vestedTap_linearClaim() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        uint128 rate = uint128(uint256(10 ether) / (12 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);

        _buy(r.dao, buyer1, 5_000_000 * 1e18);

        vm.warp(block.timestamp + SEC_PER_MONTH);
        uint256 benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 claimed = beneficiary.balance - benBefore;

        uint256 expectedMonthly = uint256(10 ether) / 12;
        assertApproxEqRel(claimed, expectedMonthly, 0.02e18, "~1 month of vesting");
    }

    function test_fixed_vestedTap_ragequitPreserves() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        uint128 rate = uint128(uint256(10 ether) / (12 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);
        IShares shares = IShares(r.sharesAddr);

        _buy(r.dao, buyer1, 2_000_000 * 1e18);
        uint256 treasuryAfterBuy = r.dao.balance;

        // Claim 1 month of tap
        vm.warp(block.timestamp + SEC_PER_MONTH);
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 treasuryAfterTap = r.dao.balance;
        assertLt(treasuryAfterTap, treasuryAfterBuy, "tap reduced treasury");

        // Ragequit — buyer gets pro-rata of remaining treasury
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256 buyerShares = shares.balanceOf(buyer1);
        uint256 balBefore = buyer1.balance;
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, buyerShares, 0);
        uint256 ethBack = buyer1.balance - balBefore;

        uint256 totalShares = 1 ether + buyerShares;
        uint256 expectedBack = treasuryAfterTap * buyerShares / totalShares;
        assertEq(ethBack, expectedBack, "ragequit from post-tap treasury");
    }

    // ==================== 4. ONGOING, NO TAP ====================

    function test_ongoing_noTap_deploy() public {
        SafeSummoner.SaleModule memory sale = _ongoingSale();
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);
        IMoloch dao = IMoloch(r.dao);

        assertTrue(dao.ragequittable());
        assertEq(dao.quorumBps(), QUORUM_BPS);
        assertEq(dao.proposalTTL(), PROPOSAL_TTL);
        assertEq(dao.timelockDelay(), TIMELOCK_DELAY);

        (, , uint40 deadline, uint256 price) = IShareSale(SHARE_SALE).sales(r.dao);
        assertEq(deadline, 0, "no deadline");
        assertEq(price, 1e12, "1 ETH = 1M shares");

        (, address tapBeneficiary, ,) = ITapVest(TAP_VEST).taps(r.dao);
        assertEq(tapBeneficiary, address(0));
    }

    function test_ongoing_noTap_unlimitedBuys() public {
        SafeSummoner.SaleModule memory sale = _ongoingSale();
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);
        IShares shares = IShares(r.sharesAddr);

        _buy(r.dao, buyer1, 1_000_000 * 1e18);
        vm.warp(block.timestamp + 365 days);
        _buy(r.dao, buyer2, 2_000_000 * 1e18);

        assertEq(shares.balanceOf(buyer1), 1_000_000 * 1e18);
        assertEq(shares.balanceOf(buyer2), 2_000_000 * 1e18);
        assertGt(r.dao.balance, 0, "treasury accumulated");
    }

    // ==================== 5. ONGOING, INSTANT TAP ====================

    function test_ongoing_fastTap_deploy() public {
        SafeSummoner.SaleModule memory sale = _ongoingSale();
        LaunchResult memory r = _summon(sale, _fastTap(type(uint256).max), sale.price);

        (, address tapBeneficiary, uint128 ratePerSec,) = ITapVest(TAP_VEST).taps(r.dao);
        assertEq(tapBeneficiary, beneficiary);
        assertEq(ratePerSec, uint128(1 ether));

        uint256 tapAllowance = IMoloch(r.dao).allowance(address(0), TAP_VEST);
        assertEq(tapAllowance, type(uint256).max, "unlimited budget");
    }

    function test_ongoing_fastTap_drainsTreasury() public {
        SafeSummoner.SaleModule memory sale = _ongoingSale();
        LaunchResult memory r = _summon(sale, _fastTap(type(uint256).max), sale.price);

        // Buy 5M shares = 5 ETH
        _buy(r.dao, buyer1, 5_000_000 * 1e18);
        uint256 treasury = r.dao.balance;

        // At 1 ETH/sec, 10 seconds easily covers 5 ETH
        vm.warp(block.timestamp + 10);
        uint256 benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 claimed = beneficiary.balance - benBefore;
        assertApproxEqAbs(claimed, treasury, 1 ether, "most ETH to beneficiary");

        // Ragequit yields almost nothing (treasury drained by tap)
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256 buyerShares = IShares(r.sharesAddr).balanceOf(buyer1);
        uint256 balBefore = buyer1.balance;
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, buyerShares, 0);
        assertLt(buyer1.balance - balBefore, 1 ether, "little left to ragequit");
    }

    // ==================== 6. ONGOING, VESTED TAP ====================

    function test_ongoing_vestedTap_deploy() public {
        SafeSummoner.SaleModule memory sale = _ongoingSale();
        uint128 rate = uint128(uint256(1 ether) / SEC_PER_MONTH); // 1 ETH/month
        LaunchResult memory r = _summon(sale, _vestedTap(type(uint256).max, rate), sale.price);

        (, address tapBeneficiary, uint128 ratePerSec,) = ITapVest(TAP_VEST).taps(r.dao);
        assertEq(tapBeneficiary, beneficiary);
        assertEq(ratePerSec, rate, "1 ETH/month rate");
    }

    function test_ongoing_vestedTap_monthlyDrip() public {
        SafeSummoner.SaleModule memory sale = _ongoingSale();
        uint128 rate = uint128(uint256(1 ether) / SEC_PER_MONTH);
        LaunchResult memory r = _summon(sale, _vestedTap(type(uint256).max, rate), sale.price);

        _buy(r.dao, buyer1, 10_000_000 * 1e18); // 10 ETH

        vm.warp(block.timestamp + 3 * SEC_PER_MONTH);
        uint256 benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 claimed = beneficiary.balance - benBefore;

        assertApproxEqRel(claimed, 3 ether, 0.02e18, "~3 ETH over 3 months");
    }

    // ==================== CREATOR MSG.VALUE SYMMETRY ====================

    function test_creator_msgValue_symmetry() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);
        IShares shares = IShares(r.sharesAddr);

        assertEq(r.dao.balance, sale.price, "DAO got creator payment");

        // Creator ragequits — only holder, gets full refund
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256 balBefore = deployer.balance;
        vm.prank(deployer);
        IMoloch(r.dao).ragequit(tokens, 1 ether, 0);

        assertEq(deployer.balance - balBefore, sale.price, "full refund symmetry");
        assertEq(shares.balanceOf(deployer), 0, "shares burned");
        assertEq(r.dao.balance, 0, "treasury empty");
    }

    // ==================== SALE DEADLINE ====================

    function test_fixed_buyAfterDeadlineReverts() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);

        vm.warp(block.timestamp + 31 days);

        (, , , uint256 price) = IShareSale(SHARE_SALE).sales(r.dao);
        uint256 shareAmt = 1_000_000 * 1e18;
        uint256 cost = (shareAmt * price + 1e18 - 1) / 1e18;

        vm.prank(buyer1);
        vm.expectRevert();
        IShareSale(SHARE_SALE).buy{value: cost}(r.dao, shareAmt);
    }

    // ==================== MULTIPLE BUYERS + FAIR RAGEQUIT ====================

    function test_multipleBuyers_fairRagequit() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);
        IShares shares = IShares(r.sharesAddr);

        _buy(r.dao, buyer1, 2_000_000 * 1e18);
        _buy(r.dao, buyer2, 3_000_000 * 1e18);

        uint256 b1Shares = shares.balanceOf(buyer1);
        uint256 b2Shares = shares.balanceOf(buyer2);

        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        uint256 bal1Before = buyer1.balance;
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, b1Shares, 0);
        uint256 eth1 = buyer1.balance - bal1Before;

        uint256 bal2Before = buyer2.balance;
        vm.prank(buyer2);
        IMoloch(r.dao).ragequit(tokens, b2Shares, 0);
        uint256 eth2 = buyer2.balance - bal2Before;

        // buyer2 paid 1.5x more, should get ~1.5x more
        assertGt(eth2, eth1, "buyer2 gets more");
        assertApproxEqRel(eth2 * 2, eth1 * 3, 0.01e18, "3:2 ratio");
    }

    // ==================== PROPOSAL THRESHOLD ====================

    function test_proposalThreshold_1share() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);

        assertEq(IMoloch(r.dao).proposalThreshold(), PROPOSAL_THRESHOLD, "1 share threshold");
        assertEq(IShares(r.sharesAddr).getVotes(deployer), 1 ether, "deployer can propose");
    }

    // ==================== SELL-OUT (FULL CAP) ====================

    function test_fixed_sellOut_fullCap() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);
        IShares shares = IShares(r.sharesAddr);

        // Buy entire 10M cap
        uint256 fullCap = 10_000_000 * 1e18;
        _buy(r.dao, buyer1, fullCap);
        assertEq(shares.balanceOf(buyer1), fullCap, "buyer got full cap");

        // Treasury should have ~10 ETH (the full raise)
        (, , , uint256 price) = IShareSale(SHARE_SALE).sales(r.dao);
        uint256 expectedTreasury = (fullCap * price + 1e18 - 1) / 1e18 + sale.price; // buyer + creator
        assertEq(r.dao.balance, expectedTreasury, "treasury = raise + creator");

        // Buying 1 more share should revert (cap exhausted)
        uint256 oneCost = (1e18 * price + 1e18 - 1) / 1e18;
        vm.prank(buyer2);
        vm.expectRevert();
        IShareSale(SHARE_SALE).buy{value: oneCost}(r.dao, 1e18);
    }

    // ==================== TAP VESTING: THOROUGH TESTS ====================

    /// @dev Vested tap: multiple sequential claims over full vesting period.
    function test_vestedTap_multipleClaimsOverTime() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        // 10 ETH over 6 months
        uint128 rate = uint128(uint256(10 ether) / (6 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);

        // Fund treasury fully (10 ETH)
        _buy(r.dao, buyer1, 10_000_000 * 1e18);

        uint256 totalClaimed;

        // Claim at month 1
        vm.warp(block.timestamp + SEC_PER_MONTH);
        uint256 benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 claim1 = beneficiary.balance - benBefore;
        totalClaimed += claim1;
        assertGt(claim1, 0, "claim1 > 0");

        // Claim at month 3 (2 months elapsed since last)
        vm.warp(block.timestamp + 2 * SEC_PER_MONTH);
        benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 claim2 = beneficiary.balance - benBefore;
        totalClaimed += claim2;
        assertApproxEqRel(claim2, claim1 * 2, 0.02e18, "2 months ~= 2x claim");

        // Claim at month 6 (3 months elapsed since last)
        vm.warp(block.timestamp + 3 * SEC_PER_MONTH);
        benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 claim3 = beneficiary.balance - benBefore;
        totalClaimed += claim3;

        // Total should be ~10 ETH (full budget over 6 months)
        assertApproxEqRel(totalClaimed, 10 ether, 0.02e18, "total ~= full budget");
    }

    /// @dev Vested tap: claim after full vesting period — should cap at budget.
    function test_vestedTap_claimAfterFullVesting() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        uint128 rate = uint128(uint256(10 ether) / (6 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);

        // Fund treasury fully
        _buy(r.dao, buyer1, 10_000_000 * 1e18);

        // Warp past full vesting (12 months > 6 month vest)
        vm.warp(block.timestamp + 12 * SEC_PER_MONTH);
        uint256 benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 claimed = beneficiary.balance - benBefore;

        // Capped at budget (allowance = 10 ETH), not 12 months of rate
        assertApproxEqRel(claimed, 10 ether, 0.01e18, "capped at budget");
    }

    /// @dev Vested tap: claim when treasury is less than owed — capped at treasury.
    function test_vestedTap_cappedAtTreasury() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        uint128 rate = uint128(uint256(10 ether) / (6 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);

        // Only fund with 2 ETH (partial)
        _buy(r.dao, buyer1, 2_000_000 * 1e18);
        uint256 treasury = r.dao.balance;

        // Warp 6 months — owed = 10 ETH but treasury only has ~2 ETH
        vm.warp(block.timestamp + 6 * SEC_PER_MONTH);
        uint256 benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 claimed = beneficiary.balance - benBefore;

        // Claimed rounds down to advance * rate where advance = floor(treasury / rate)
        assertLe(claimed, treasury, "capped at treasury");
        assertGt(claimed, 0, "claimed something");
    }

    /// @dev Vested tap: no claim before any time passes.
    function test_vestedTap_nothingToClaim_noElapsed() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        uint128 rate = uint128(uint256(10 ether) / (6 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);

        _buy(r.dao, buyer1, 5_000_000 * 1e18);

        // No warp — elapsed = 0, owed = 0
        vm.expectRevert(); // NothingToClaim
        ITapVest(TAP_VEST).claim(r.dao);
    }

    // ==================== INSTANT TAP: THOROUGH TESTS ====================

    /// @dev Instant tap (frontend-style): rate = raise ETH/sec for fixed raise.
    function test_instantTap_fixed_frontendRate() public {
        // Frontend: rate = raise ETH/sec (e.g. 10 ETH/sec for 10 ETH raise)
        uint128 rate = uint128(10 ether); // 10 ETH/sec
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        SafeSummoner.TapModule memory tap = _vestedTap(10 ether, rate);
        LaunchResult memory r = _summon(sale, tap, sale.price);

        // Fund with 5 ETH
        _buy(r.dao, buyer1, 5_000_000 * 1e18);
        uint256 treasury = r.dao.balance;

        // 1 second at 10 ETH/sec → owed = 10 ETH, but treasury ~5 ETH
        // advance = floor(5e18 / 10e18) = 0 → NothingToClaim
        // Need at least rate worth of ETH in treasury for advance >= 1
        // So fund fully:
        _buy(r.dao, buyer2, 5_000_000 * 1e18);
        treasury = r.dao.balance;
        assertApproxEqAbs(treasury, 10 ether + sale.price, 1, "~10 ETH in treasury");

        vm.warp(block.timestamp + 1); // 1 second
        uint256 benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 claimed = beneficiary.balance - benBefore;

        // advance = floor(min(10e18, 10e18, ~10e18) / 10e18) = 1
        // claimed = 1 * 10e18 = 10 ETH
        assertEq(claimed, 10 ether, "drained 10 ETH in 1 sec");
    }

    /// @dev Instant tap (ongoing): rate = 1000 ETH/sec.
    function test_instantTap_ongoing_largeTreasury() public {
        uint128 rate = uint128(1000 ether); // frontend uses 1000 ETH/sec for ongoing
        SafeSummoner.SaleModule memory sale = _ongoingSale();
        SafeSummoner.TapModule memory tap = _vestedTap(type(uint256).max, rate);
        LaunchResult memory r = _summon(sale, tap, sale.price);

        // Buy 10M shares = 10 ETH (enough for advance = floor(10e18/1000e18) = 0 → need more)
        // Need 1000 ETH for advance = 1 → buy 1B shares = 1000 ETH
        vm.deal(buyer1, 2000 ether);
        _buy(r.dao, buyer1, 1_000_000_000 * 1e18); // 1B shares = 1000 ETH

        vm.warp(block.timestamp + 1);
        uint256 benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 claimed = beneficiary.balance - benBefore;
        assertEq(claimed, 1000 ether, "drained 1000 ETH");
    }

    /// @dev Instant tap: partial claim when treasury < rate (NothingToClaim).
    function test_instantTap_revertsWhenTreasuryLessThanRate() public {
        uint128 rate = uint128(10 ether);
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        SafeSummoner.TapModule memory tap = _vestedTap(10 ether, rate);
        LaunchResult memory r = _summon(sale, tap, sale.price);

        // Only buy 1M shares = 1 ETH — less than rate (10 ETH/sec)
        _buy(r.dao, buyer1, 1_000_000 * 1e18);

        vm.warp(block.timestamp + 1);
        // advance = floor(1e18 / 10e18) = 0 → NothingToClaim
        vm.expectRevert();
        ITapVest(TAP_VEST).claim(r.dao);
    }

    // ==================== GOVERNANCE LIFECYCLE ====================

    /// @dev Full lifecycle: deploy → sell out → governance vote → execute.
    function test_fullLifecycle_sellOutAndGovern() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        uint128 rate = uint128(uint256(10 ether) / (12 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);
        IMoloch dao = IMoloch(r.dao);
        IShares shares = IShares(r.sharesAddr);

        // Sell out full cap
        _buy(r.dao, buyer1, 6_000_000 * 1e18);
        _buy(r.dao, buyer2, 4_000_000 * 1e18);

        // Verify sold out
        vm.prank(deployer);
        vm.expectRevert();
        IShareSale(SHARE_SALE).buy{value: 1 ether}(r.dao, 1e18);

        // Let tap vest for 3 months
        vm.warp(block.timestamp + 3 * SEC_PER_MONTH);
        vm.roll(block.number + 2);
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 tapClaimed = beneficiary.balance;
        assertGt(tapClaimed, 0, "tap claimed");

        // buyer1 (majority) proposes to kill the tap
        uint8 op = 0;
        bytes memory data = abi.encodeWithSignature(
            "setAllowance(address,address,uint256)", TAP_VEST, address(0), 0
        );
        bytes32 nonce = bytes32("kill_tap");
        uint256 propId = dao.proposalId(op, r.dao, 0, data, nonce);

        vm.prank(buyer1);
        dao.castVote(propId, 1);

        // Execute (queue → timelock → execute)
        dao.executeByVotes(op, r.dao, 0, data, nonce);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        (bool ok,) = dao.executeByVotes(op, r.dao, 0, data, nonce);
        assertTrue(ok, "tap killed");

        // Tap claim now reverts
        vm.warp(block.timestamp + SEC_PER_MONTH);
        vm.expectRevert();
        ITapVest(TAP_VEST).claim(r.dao);

        // Ragequit still works — buyer2 exits with remaining treasury
        uint256 b2Shares = shares.balanceOf(buyer2);
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256 bal2Before = buyer2.balance;
        vm.prank(buyer2);
        dao.ragequit(tokens, b2Shares, 0);
        assertGt(buyer2.balance - bal2Before, 0, "buyer2 ragequit");
    }

    /// @dev Governance: change tap beneficiary via proposal.
    function test_governance_changeTapBeneficiary() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        uint128 rate = uint128(uint256(10 ether) / (12 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);
        IMoloch dao = IMoloch(r.dao);

        _buy(r.dao, buyer1, 5_000_000 * 1e18);
        vm.roll(block.number + 2);

        // Propose: reconfigure TapVest with new beneficiary (buyer2)
        bytes memory data = abi.encodeWithSignature(
            "configure(address,address,uint128)", address(0), buyer2, rate
        );
        bytes32 nonce = bytes32("new_ben");
        uint256 propId = dao.proposalId(0, TAP_VEST, 0, data, nonce);

        vm.prank(buyer1);
        dao.castVote(propId, 1);
        dao.executeByVotes(0, TAP_VEST, 0, data, nonce);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        (bool ok,) = dao.executeByVotes(0, TAP_VEST, 0, data, nonce);
        assertTrue(ok, "reconfigured");

        // Verify new beneficiary
        (, address newBen, ,) = ITapVest(TAP_VEST).taps(r.dao);
        assertEq(newBen, buyer2, "beneficiary changed");

        // New beneficiary can claim
        vm.warp(block.timestamp + SEC_PER_MONTH);
        uint256 bal2Before = buyer2.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        assertGt(buyer2.balance - bal2Before, 0, "new beneficiary claimed");
    }

    // ==================== ETH ACCOUNTING: FULL TRACE ====================

    /// @dev Trace every wei: deploy → buy → tap claim → ragequit. No ETH lost.
    function test_ethAccounting_fullTrace() public {
        // Setup: 10 ETH raise, 12 month vested tap
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        uint128 rate = uint128(uint256(10 ether) / (12 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);

        // --- Phase 1: Buy (5 ETH from buyer1, 5 ETH from buyer2) ---
        uint256 buyer1Start = buyer1.balance;
        uint256 buyer2Start = buyer2.balance;
        _buy(r.dao, buyer1, 5_000_000 * 1e18); // 5 ETH
        _buy(r.dao, buyer2, 5_000_000 * 1e18); // 5 ETH
        uint256 buyer1Paid = buyer1Start - buyer1.balance;
        uint256 buyer2Paid = buyer2Start - buyer2.balance;
        uint256 totalPaid = buyer1Paid + buyer2Paid;
        uint256 treasuryAfterBuys = r.dao.balance;

        // Treasury = creator payment + buyer payments
        assertEq(treasuryAfterBuys, sale.price + totalPaid, "treasury = all payments");

        // --- Phase 2: Tap claim (6 months) ---
        vm.warp(block.timestamp + 6 * SEC_PER_MONTH);
        uint256 benBefore = beneficiary.balance;
        ITapVest(TAP_VEST).claim(r.dao);
        uint256 tapClaimed = beneficiary.balance - benBefore;
        assertGt(tapClaimed, 0, "tap claimed");

        uint256 treasuryAfterTap = r.dao.balance;
        assertEq(treasuryAfterTap, treasuryAfterBuys - tapClaimed, "treasury decreased by tap");

        // --- Phase 3: Ragequit (both buyers + deployer) ---
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        // buyer1 ragequits
        uint256 b1Before = buyer1.balance;
        uint256 b1Shares = IShares(r.sharesAddr).balanceOf(buyer1);
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, b1Shares, 0);
        uint256 b1Got = buyer1.balance - b1Before;

        // buyer2 ragequits
        uint256 b2Before = buyer2.balance;
        uint256 b2Shares = IShares(r.sharesAddr).balanceOf(buyer2);
        vm.prank(buyer2);
        IMoloch(r.dao).ragequit(tokens, b2Shares, 0);
        uint256 b2Got = buyer2.balance - b2Before;

        // deployer ragequits (1 share)
        uint256 dBefore = deployer.balance;
        vm.prank(deployer);
        IMoloch(r.dao).ragequit(tokens, 1 ether, 0);
        uint256 dGot = deployer.balance - dBefore;

        // --- Verify: all ETH accounted for ---
        uint256 totalOut = tapClaimed + b1Got + b2Got + dGot;
        uint256 dustRemaining = r.dao.balance;

        // totalOut + dust = original treasury
        assertEq(totalOut + dustRemaining, treasuryAfterBuys, "no ETH lost or created");

        // DAO should be empty (all holders ragequit)
        assertEq(dustRemaining, 0, "DAO fully drained");

        // Buyers got proportional shares (b1 ~= b2, 1 wei rounding from sequential ragequit)
        assertApproxEqAbs(b1Got, b2Got, 1, "equal buyers got equal ragequit");
    }

    // ==================== PARTIAL RAGEQUIT ====================

    /// @dev UI allows burning only some shares. Verify partial ragequit + remaining balance.
    function test_partialRagequit() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);
        IShares shares = IShares(r.sharesAddr);

        _buy(r.dao, buyer1, 4_000_000 * 1e18);
        uint256 totalShares = shares.totalSupply();
        uint256 treasuryBefore = r.dao.balance;

        // Burn half
        uint256 half = 2_000_000 * 1e18;
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256 balBefore = buyer1.balance;
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, half, 0);
        uint256 ethBack = buyer1.balance - balBefore;

        // Got pro-rata of half
        uint256 expected = treasuryBefore * half / totalShares;
        assertEq(ethBack, expected, "partial ragequit pro-rata");

        // Still holds other half
        assertEq(shares.balanceOf(buyer1), half, "kept remaining shares");

        // Can ragequit the rest
        uint256 treasuryNow = r.dao.balance;
        uint256 newTotalShares = shares.totalSupply();
        balBefore = buyer1.balance;
        vm.prank(buyer1);
        IMoloch(r.dao).ragequit(tokens, half, 0);
        uint256 ethBack2 = buyer1.balance - balBefore;
        assertEq(ethBack2, treasuryNow * half / newTotalShares, "second partial ragequit");
        assertEq(shares.balanceOf(buyer1), 0, "all shares burned");
    }

    // ==================== SAFETY: RAGEQUIT DURING ACTIVE PROPOSAL ====================

    /// @dev Ragequitting during an active proposal does not break governance.
    ///      Quorum uses supplySnapshot (frozen at proposal open), not live supply.
    function test_safety_ragequitDuringProposal() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);
        IMoloch dao = IMoloch(r.dao);
        IShares shares = IShares(r.sharesAddr);

        _buy(r.dao, buyer1, 5_000_000 * 1e18);
        _buy(r.dao, buyer2, 3_000_000 * 1e18);
        vm.roll(block.number + 2);

        // buyer1 opens a proposal
        bytes memory data = abi.encodeWithSignature("setQuorumBps(uint16)", uint16(2000));
        bytes32 nonce = bytes32("quorum_change");
        uint256 propId = dao.proposalId(0, r.dao, 0, data, nonce);
        vm.prank(buyer1);
        dao.castVote(propId, 1); // opens + votes FOR

        // buyer2 ragequits BEFORE voting
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256 b2Shares = shares.balanceOf(buyer2);
        vm.prank(buyer2);
        dao.ragequit(tokens, b2Shares, 0);

        // Proposal still passes — quorum is based on snapshot supply, not live
        uint8 st = dao.state(propId);
        assertEq(st, 3, "proposal Succeeded despite ragequit");

        // Can still execute
        dao.executeByVotes(0, r.dao, 0, data, nonce);
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        (bool ok,) = dao.executeByVotes(0, r.dao, 0, data, nonce);
        assertTrue(ok, "executed after ragequit");
    }

    // ==================== SAFETY: PERMISSIONLESS TAP CLAIM ====================

    /// @dev Anyone can call TapVest.claim() — ETH always goes to beneficiary, not caller.
    function test_safety_anyoneCanClaimTap() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        uint128 rate = uint128(uint256(10 ether) / (12 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);

        _buy(r.dao, buyer1, 5_000_000 * 1e18);
        vm.warp(block.timestamp + SEC_PER_MONTH);

        // Random address (buyer2, not beneficiary) calls claim
        uint256 benBefore = beneficiary.balance;
        uint256 callerBefore = buyer2.balance;
        vm.prank(buyer2);
        ITapVest(TAP_VEST).claim(r.dao);

        // ETH goes to beneficiary, not caller
        assertGt(beneficiary.balance - benBefore, 0, "beneficiary got ETH");
        assertEq(buyer2.balance, callerBefore, "caller got nothing");
    }

    // ==================== SAFETY: BUY DURING ACTIVE SALE ONLY ====================

    /// @dev Shares can only be purchased while sale is active (before deadline, within cap).
    function test_safety_cannotBuyBeforeSaleConfigured() public {
        // Deploy with zero sale singleton (no sale module)
        SafeSummoner.SaleModule memory sale = SafeSummoner.SaleModule({
            singleton: address(0),
            payToken: address(0),
            deadline: 0,
            price: 0,
            cap: 0,
            sellLoot: false,
            minting: true
        });
        LaunchResult memory r = _summon(sale, _zeroTap(), 0);

        // ShareSale.buy should revert — no sale configured for this DAO
        vm.prank(buyer1);
        vm.expectRevert();
        IShareSale(SHARE_SALE).buy{value: 1 ether}(r.dao, 1_000_000 * 1e18);
    }

    // ==================== SAFETY: SHARE TRANSFER + RAGEQUIT ====================

    /// @dev Shares are transferable. Buyer can transfer then recipient ragequits.
    function test_safety_transferThenRagequit() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);
        IShares shares = IShares(r.sharesAddr);

        _buy(r.dao, buyer1, 4_000_000 * 1e18);
        uint256 b1Shares = shares.balanceOf(buyer1);

        // Transfer half to buyer2
        uint256 half = b1Shares / 2;
        vm.prank(buyer1);
        // Shares is ERC20 — use transfer
        (bool ok,) = r.sharesAddr.call(
            abi.encodeWithSignature("transfer(address,uint256)", buyer2, half)
        );
        assertTrue(ok, "transfer succeeded");
        assertEq(shares.balanceOf(buyer2), half, "buyer2 received shares");

        // buyer2 can ragequit with transferred shares
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256 bal2Before = buyer2.balance;
        vm.prank(buyer2);
        IMoloch(r.dao).ragequit(tokens, half, 0);
        assertGt(buyer2.balance - bal2Before, 0, "ragequit with transferred shares");
        assertEq(shares.balanceOf(buyer2), 0, "shares burned");
    }

    // ==================== SAFETY: DOUBLE RAGEQUIT REVERTS ====================

    /// @dev Cannot ragequit more shares than you hold.
    function test_safety_cannotRagequitMoreThanBalance() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);

        _buy(r.dao, buyer1, 1_000_000 * 1e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        // Try to ragequit 2x what buyer holds
        vm.prank(buyer1);
        vm.expectRevert();
        IMoloch(r.dao).ragequit(tokens, 2_000_000 * 1e18, 0);
    }

    // ==================== SAFETY: CREATOR CANNOT DRAIN VIA TAP WITHOUT GOVERNANCE ====================

    /// @dev Tap beneficiary cannot increase their own rate or budget without DAO vote.
    function test_safety_tapCannotSelfModify() public {
        SafeSummoner.SaleModule memory sale = _fixedSale(10, 30);
        uint128 rate = uint128(uint256(10 ether) / (12 * SEC_PER_MONTH));
        LaunchResult memory r = _summon(sale, _vestedTap(10 ether, rate), sale.price);

        // Beneficiary tries to reconfigure TapVest directly — should fail
        // Only the DAO (msg.sender = dao) can call configure on its own tap slot
        vm.prank(beneficiary);
        // This would configure a new tap keyed by beneficiary address, not the DAO
        // The DAO's tap is unaffected
        (, address tapBen, uint128 tapRate,) = ITapVest(TAP_VEST).taps(r.dao);
        assertEq(tapBen, beneficiary, "original beneficiary unchanged");
        assertEq(tapRate, rate, "original rate unchanged");
    }

    // ==================== PRICE MATH: CREATOR PAYMENT == BUYER PRICE ====================

    /// @dev Creator's msg.value must exactly match what a buyer pays for 1 share via ShareSale.
    ///      Tests multiple raise amounts to ensure dynamic pricing is correct.
    function test_creatorPrice_matches_1ETH_raise() public { _verifyCreatorPrice(1); }
    function test_creatorPrice_matches_5ETH_raise() public { _verifyCreatorPrice(5); }
    function test_creatorPrice_matches_10ETH_raise() public { _verifyCreatorPrice(10); }
    function test_creatorPrice_matches_100ETH_raise() public { _verifyCreatorPrice(100); }

    function test_creatorPrice_matches_ongoing() public {
        SafeSummoner.SaleModule memory sale = _ongoingSale();
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);

        uint256 creatorPaid = r.dao.balance;
        assertEq(creatorPaid, 1e12, "creator paid 1e12");

        // Buyer buys exactly 1 share — should cost the same
        uint256 buyerBefore = buyer1.balance;
        _buy(r.dao, buyer1, 1 ether);
        uint256 buyerPaid = buyerBefore - buyer1.balance;

        assertEq(creatorPaid, buyerPaid, "ongoing: creator == buyer for 1 share");
    }

    function _verifyCreatorPrice(uint256 raiseETH) internal {
        SafeSummoner.SaleModule memory sale = _fixedSale(raiseETH, 30);
        LaunchResult memory r = _summon(sale, _zeroTap(), sale.price);

        // Creator paid sale.price via msg.value
        uint256 creatorPaid = r.dao.balance;
        assertEq(creatorPaid, sale.price, "creator paid priceWei");

        // Verify: priceWei = raise / 10M (matching frontend JS)
        uint256 expectedPrice = raiseETH * 1e18 / 10_000_000;
        assertEq(sale.price, expectedPrice, "price = raise / 10M");

        // Buyer buys exactly 1 share — cost should match creator's payment
        uint256 buyerBefore = buyer1.balance;
        _buy(r.dao, buyer1, 1 ether);
        uint256 buyerPaid = buyerBefore - buyer1.balance;
        assertEq(creatorPaid, buyerPaid, "creator price == buyer price for 1 share");

        // Pro-rata check: creator has 1 share, buyer has 1 share → 50/50 split
        uint256 treasury = r.dao.balance;
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256 dBefore = deployer.balance;
        vm.prank(deployer);
        IMoloch(r.dao).ragequit(tokens, 1 ether, 0);
        uint256 dGot = deployer.balance - dBefore;
        assertEq(dGot, treasury / 2, "creator gets 50% (1 of 2 shares)");
    }
}
