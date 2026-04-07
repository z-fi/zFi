// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

/// @dev Fork test verifying the ClassicalCurveSale launch init sequence
///      matches the dapp JS coinLaunch() parameters exactly.

interface IClassicalCurveSale {
    struct CreatorFee {
        address beneficiary;
        uint16 buyBps;
        uint16 sellBps;
        bool buyOnInput;
        bool sellOnInput;
    }

    function launch(
        address creator,
        string calldata name,
        string calldata symbol,
        string calldata uri,
        uint256 supply,
        bytes32 salt,
        uint256 cap,
        uint256 startPrice,
        uint256 endPrice,
        uint16 feeBps,
        uint256 graduationTarget,
        uint256 lpTokens,
        address lpRecipient,
        uint16 poolFeeBps,
        uint16 sniperFeeBps,
        uint16 sniperDuration,
        uint16 maxBuyBps,
        CreatorFee calldata creatorFee,
        uint40 vestCliff,
        uint40 vestDuration
    ) external returns (address token);

    function buy(address token, uint256 amount, uint256 minAmount, uint256 deadline) external payable;
    function sell(address token, uint256 amount, uint256 minProceeds, uint256 deadline) external payable;
    function graduate(address token) external returns (uint256 liquidity);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function approve(address, uint256) external returns (bool);
}

contract CurveLaunchTest is Test {
    IClassicalCurveSale constant CURVE = IClassicalCurveSale(0x000000005d9b18764E12E5aeefD6dA73110F85eb);

    // Exact dapp JS parameters
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant CAP = 800_000_000 ether;
    uint256 constant LP_TOKENS = 200_000_000 ether;
    uint256 constant START_PRICE = 1666666667;
    uint256 constant END_PRICE = 26666666672;
    uint16 constant FEE_BPS = 100; // 1%
    uint16 constant POOL_FEE_BPS = 25; // 0.25%
    uint16 constant SNIPER_FEE_BPS = 500; // 5%
    uint16 constant SNIPER_DURATION = 300; // 5 min
    uint16 constant MAX_BUY_BPS = 1000; // 10%

    uint256 constant MAX_BUY = CAP * MAX_BUY_BPS / 10000; // 80M tokens

    address creator;
    address buyer1;
    address buyer2;

    function setUp() public {
        creator = address(uint160(uint256(keccak256("curve_creator"))));
        buyer1 = address(uint160(uint256(keccak256("curve_buyer1"))));
        buyer2 = address(uint160(uint256(keccak256("curve_buyer2"))));
        vm.deal(creator, 1 ether);
        vm.deal(buyer1, 100 ether);
        vm.deal(buyer2, 100 ether);
    }

    function _launch() internal returns (address token) {
        bytes32 salt = keccak256(abi.encode("curve_test", block.timestamp));
        vm.prank(creator);
        token = CURVE.launch(
            creator,
            "TestCurve",
            "TCRV",
            "ipfs://QmTest",
            SUPPLY,
            salt,
            CAP,
            START_PRICE,
            END_PRICE,
            FEE_BPS,
            0, // graduationTarget: sell full cap
            LP_TOKENS,
            address(0), // burn LP
            POOL_FEE_BPS,
            SNIPER_FEE_BPS,
            SNIPER_DURATION,
            MAX_BUY_BPS,
            IClassicalCurveSale.CreatorFee(creator, 5, 5, true, false),
            0,
            0 // no vesting
        );
    }

    // ==================== DEPLOYMENT ====================

    function test_launch_deploys_token() public {
        address token = _launch();
        assertTrue(token != address(0), "token deployed");
        assertEq(IERC20(token).name(), "TestCurve", "name");
        assertEq(IERC20(token).symbol(), "TCRV", "symbol");
        assertEq(IERC20(token).totalSupply(), SUPPLY, "total supply = 1B");
        assertEq(IERC20(token).balanceOf(address(CURVE)), SUPPLY, "curve holds all tokens");
    }

    // ==================== BUYING ====================

    function test_buy_basic() public {
        address token = _launch();
        vm.warp(block.timestamp + 301); // past sniper

        // Buy 10M tokens
        uint256 buyAmt = 10_000_000 ether;
        vm.prank(buyer1);
        CURVE.buy{value: 1 ether}(token, buyAmt, buyAmt, block.timestamp + 300);

        assertEq(IERC20(token).balanceOf(buyer1), buyAmt, "got exact tokens");
        emit log_named_uint("Bought tokens", buyAmt / 1e18);
    }

    function test_buy_capped_at_max_buy() public {
        address token = _launch();
        vm.warp(block.timestamp + 301);

        // Request more than max buy (80M) -- should be clamped
        uint256 requested = 200_000_000 ether;
        vm.prank(buyer1);
        CURVE.buy{value: 10 ether}(token, requested, 0, block.timestamp + 300);

        uint256 received = IERC20(token).balanceOf(buyer1);
        assertEq(received, MAX_BUY, "clamped to 10% of cap");
        emit log_named_uint("Received", received / 1e18);
        emit log_named_uint("Max buy", MAX_BUY / 1e18);
    }

    function test_sniper_fee_decays() public {
        address token = _launch();

        // Buy at launch (5% sniper fee)
        uint256 buyAmt = 10_000_000 ether;
        uint256 ethBefore1 = buyer1.balance;
        vm.prank(buyer1);
        CURVE.buy{value: 5 ether}(token, buyAmt, buyAmt, block.timestamp + 300);
        uint256 costEarly = ethBefore1 - buyer1.balance;

        // Warp past sniper period
        vm.warp(block.timestamp + 301);

        // Buy same amount (1% fee, slightly higher price due to curve)
        uint256 ethBefore2 = buyer2.balance;
        vm.prank(buyer2);
        CURVE.buy{value: 5 ether}(token, buyAmt, buyAmt, block.timestamp + 600);
        uint256 costLate = ethBefore2 - buyer2.balance;

        // Early buyer paid more (5% fee vs 1% fee, even though price is lower)
        emit log_named_uint("Cost at launch (5% sniper)", costEarly);
        emit log_named_uint("Cost after 5min (1% fee)", costLate);
        assertGt(costEarly, costLate, "sniper fee makes early buys more expensive");
    }

    // ==================== SELLING ====================

    function test_sell_basic() public {
        address token = _launch();
        vm.warp(block.timestamp + 301);

        // Buy first
        vm.prank(buyer1);
        CURVE.buy{value: 1 ether}(token, MAX_BUY, 0, block.timestamp + 300);
        uint256 tokens = IERC20(token).balanceOf(buyer1);

        // Sell half
        uint256 sellAmt = tokens / 2;
        vm.prank(buyer1);
        IERC20(token).approve(address(CURVE), sellAmt);

        uint256 ethBefore = buyer1.balance;
        vm.prank(buyer1);
        CURVE.sell(token, sellAmt, 0, block.timestamp + 300);

        uint256 ethReceived = buyer1.balance - ethBefore;
        assertGt(ethReceived, 0, "got ETH back");
        assertEq(IERC20(token).balanceOf(buyer1), tokens - sellAmt, "tokens deducted");
        emit log_named_uint("Sold tokens", sellAmt / 1e18);
        emit log_named_uint("ETH received", ethReceived);
    }

    // ==================== CREATOR FEE ====================

    function test_creator_receives_trading_fee() public {
        address token = _launch();
        vm.warp(block.timestamp + 301);

        uint256 creatorBefore = creator.balance;

        // Buy 10M tokens
        uint256 buyAmt = 10_000_000 ether;
        uint256 ethBefore = buyer1.balance;
        vm.prank(buyer1);
        CURVE.buy{value: 1 ether}(token, buyAmt, buyAmt, block.timestamp + 300);
        uint256 totalPaid = ethBefore - buyer1.balance;

        uint256 creatorFee = creator.balance - creatorBefore;
        assertGt(creatorFee, 0, "creator got fee");

        // Fee should be ~1% of cost (totalPaid includes fee)
        // cost = totalPaid / 1.01, fee = cost * 0.01 = totalPaid * 0.01 / 1.01
        uint256 expectedFee = totalPaid * 100 / 10100;
        emit log_named_uint("Creator fee", creatorFee);
        emit log_named_uint("Expected fee (~1%)", expectedFee);
        assertApproxEqRel(creatorFee, expectedFee, 0.01e18, "~1% fee to creator");
    }

    // ==================== GRADUATION ====================

    function test_full_graduation() public {
        address token = _launch();
        vm.warp(block.timestamp + 301);

        // Buy in max-buy chunks until cap is sold
        uint256 totalETH;
        for (uint256 i; i < 20; i++) {
            uint256 remaining = CAP - _tokensSold(token);
            if (remaining == 0) break;

            uint256 buyAmt = remaining < MAX_BUY ? remaining : MAX_BUY;
            uint256 ethBefore = buyer1.balance;

            vm.prank(buyer1);
            CURVE.buy{value: 20 ether}(token, buyAmt, 0, block.timestamp + 300);

            totalETH += ethBefore - buyer1.balance;
        }

        uint256 tokensBought = IERC20(token).balanceOf(buyer1);
        emit log_named_uint("Total tokens bought", tokensBought / 1e18);
        emit log_named_uint("Total ETH spent", totalETH);

        // Should have bought full cap (800M)
        assertEq(tokensBought, CAP, "bought entire cap");

        // Graduate -- seeds ZAMM LP, burns LP tokens
        uint256 liq = CURVE.graduate(token);
        assertGt(liq, 0, "LP seeded");
        emit log_named_uint("LP liquidity", liq);

        // Total ETH should be ~5.33 + fees
        // Pure cost ~5.33 ETH, + 1% fee = ~5.386 ETH
        emit log_named_uint("Expected ~5.33 ETH + 1% fee", 5.386 ether);
        assertApproxEqRel(totalETH, 5.386 ether, 0.02e18, "~5.33 ETH raised + fee");
    }

    // ==================== PRICE VERIFICATION ====================

    function test_price_at_start() public {
        address token = _launch();
        vm.warp(block.timestamp + 301);

        // Buy 1M tokens at start
        uint256 buyAmt = 1_000_000 ether;
        uint256 ethBefore = buyer1.balance;
        vm.prank(buyer1);
        CURVE.buy{value: 1 ether}(token, buyAmt, buyAmt, block.timestamp + 300);
        uint256 totalPaid = ethBefore - buyer1.balance;

        // cost = totalPaid / 1.01 (remove 1% fee)
        uint256 cost = totalPaid * 10000 / 10100;
        uint256 pricePerToken = cost * 1e18 / buyAmt;

        emit log_named_uint("Price per token (1e18 scaled)", pricePerToken);
        emit log_named_uint("Expected START_PRICE", START_PRICE);
        assertApproxEqRel(pricePerToken, START_PRICE, 0.01e18, "start price matches");
    }

    // ==================== HELPERS ====================

    function _tokensSold(address token) internal view returns (uint256) {
        // tokens sold = SUPPLY - curve balance (curve holds unsold + LP reserve)
        // Actually: sold = CAP - (curve balance - LP_TOKENS)
        // But simpler: buyer1 balance = tokens bought so far
        return IERC20(token).balanceOf(buyer1);
    }
}
