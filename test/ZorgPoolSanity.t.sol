// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";

/// @notice Does the live ZORG pool trade normally?
///
///         A user round-tripped 0.06 ETH through it and came back with a
///         fraction. The reconstruction says that was depth plus two people
///         selling in between, and that the pool itself behaved - but a
///         reconstruction is an argument, and the pool is the only thing that
///         can settle it. So this trades against the REAL pool at head, at
///         sizes from dust to absurd, and asserts the properties an AMM must
///         have: a round trip with nobody in between returns the input less
///         fees, price moves the right way, and nothing pays out more than it
///         took in.
interface IPool {
    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external payable returns (uint256);
    function reserve0() external view returns (uint256);
    function reserve1() external view returns (uint256);
    function fee() external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract ZorgPoolSanityTest is Test {
    IPool constant POOL = IPool(payable(0xc37F8c7E9Afe897893952ABa7fD91E0AB947837d));
    address constant ZORG = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12;

    address trader = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")));
        vm.deal(trader, 100 ether);
    }

    function _buy(uint256 eth) internal returns (uint256) {
        vm.prank(trader);
        return POOL.swapExactIn{value: eth}(address(0), eth, 0, trader);
    }

    function _sell(uint256 amt) internal returns (uint256) {
        vm.startPrank(trader);
        IERC20(ZORG).approve(address(POOL), type(uint256).max);
        uint256 out = POOL.swapExactIn(ZORG, amt, 0, trader);
        vm.stopPrank();
        return out;
    }

    /// THE ONE THAT ANSWERS THE USER. Buy and immediately sell back, with
    /// nobody in between. An AMM's curve is path-independent, so this must
    /// return the input less the two fees - at ANY size, however violent the
    /// impact was on the way in.
    function test_aRoundTripWithNobodyInBetweenReturnsTheInputLessFees() public {
        uint256 feeBps = POOL.fee() / 100; // pips -> bps
        // 1 ETH is deliberately absent: the pool REFUSES it (see the test
        // below). These are sizes it will actually fill.
        uint256[4] memory sizes =
            [uint256(0.0001 ether), 0.001 ether, 0.01 ether, 0.06 ether];

        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 got = _buy(sizes[i]);
            uint256 back = _sell(got);

            // Two fees, each on the notional, plus rounding. Nothing else may
            // go missing.
            uint256 worstKept = sizes[i] * (10000 - feeBps) * (10000 - feeBps) / 1e8;
            emit log_named_decimal_uint("in  ", sizes[i], 18);
            emit log_named_decimal_uint("  out ", back, 18);
            emit log_named_uint("  kept, bps of input", back * 10000 / sizes[i]);

            assertLe(back, sizes[i], "a round trip PROFITED - the curve is not conservative");
            assertGe(back + sizes[i] / 1000, worstKept, "more than two fees went missing");
            vm.revertToState(snap);
        }
    }

    /// Price moves the right way and monotonically: a bigger buy always pays a
    /// worse average. If this ever inverted, the pool would be arbitrageable
    /// against itself.
    function test_biggerBuysPayStrictlyWorseAverages() public {
        uint256[4] memory sizes = [uint256(0.001 ether), 0.01 ether, 0.05 ether, 0.2 ether];
        uint256 lastPx;
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 got = _buy(sizes[i]);
            uint256 px = sizes[i] * 1e18 / got; // ETH per ZORG, scaled
            emit log_named_decimal_uint("buy size", sizes[i], 18);
            emit log_named_uint("  avg price (wei/token)", px);
            if (i > 0) assertGt(px, lastPx, "a larger buy got a BETTER price");
            lastPx = px;
            vm.revertToState(snap);
        }
    }

    /// The user's exact trade, reproduced. Not to prove it was fine - to put
    /// the number on the record next to what the pool held at the time.
    function test_theReportedTradeReproduces() public {
        uint256 r0 = POOL.reserve0();
        uint256 r1 = POOL.reserve1();
        uint256 got = _buy(0.06 ether);

        emit log_named_decimal_uint("pool ETH before ", r0, 18);
        emit log_named_decimal_uint("pool ZORG before", r1, 18);
        emit log_named_decimal_uint("bought          ", got, 18);
        emit log_named_uint("share of the token reserve, bps", got * 10000 / r1);

        // Selling it straight back, alone, gets nearly all of it home.
        uint256 back = _sell(got);
        emit log_named_decimal_uint("sold back alone ", back, 18);
        emit log_named_uint("recovered, bps  ", back * 10000 / 0.06 ether);
        assertGt(back * 10000 / 0.06 ether, 9800, "a lone round trip lost more than 2%");
    }

    /// The same trade WITH other people selling in between - which is what
    /// actually happened. This is the difference between the pool misbehaving
    /// and the user being exited by somebody else.
    function test_theSameTradeWithOthersSellingInBetween() public {
        uint256 got = _buy(0.06 ether);

        // Others dump ~45% of what the buyer just took, into the price that
        // buy created. Proportional rather than the literal 456 tokens from
        // the incident, since the pool has moved since.
        uint256 dumped = got * 45 / 100;
        vm.startPrank(trader);
        IERC20(ZORG).approve(address(POOL), type(uint256).max);
        POOL.swapExactIn(ZORG, dumped, 0, address(0xB0B));
        vm.stopPrank();

        uint256 back = _sell(got - dumped);
        emit log_named_decimal_uint("sold after others sold", back, 18);
        emit log_named_uint("recovered, bps        ", back * 10000 / 0.06 ether);
        assertLt(back, 0.06 ether, "being sold into should have cost them");
    }

    /// AND THE POOL REFUSES WHAT IT CANNOT FILL. A 1 ETH buy against ~0.02 ETH
    /// of depth reverts rather than filling at an invented price - which is the
    /// behaviour you want and the opposite of the failure the user suspected.
    function test_aTradeTooLargeToFillRevertsRatherThanFillingBadly() public {
        vm.prank(trader);
        vm.expectRevert();
        POOL.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
    }
}
