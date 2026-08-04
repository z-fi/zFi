// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Verbatim reproduction of the third-party audit's H-01 counterexample.
contract AuditH01Test is Test {
    PrecisionPoolFactory factory;
    MockERC20 tk;

    uint256 constant SL = 6_712_200_751_245;
    uint256 constant SH = 7_318_035_227_228;
    uint256 constant SEED = 6_728_816_317_444;
    uint256 constant AMT0 = 5_888_859_251;
    uint256 constant AMT1 = 3;

    address lp = address(0xC11);
    address trader = address(0x7AD);

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        tk = new MockERC20("TK", 18);
        tk.mint(lp, 1e30);
        tk.mint(trader, 1e30);
        vm.deal(lp, 100 ether);
        vm.deal(trader, 100 ether);
        vm.prank(lp);
        tk.approve(address(factory), type(uint256).max);
    }

    /// @dev The audit's exact counterexample. Before the postcondition was
    /// added this seeded successfully and left the pool 4.58% below its own
    /// floor with reserve1 == 0, untradeable in both directions:
    ///
    ///   L = 492,138   used0 = 5,888,851,491   used1 = 1 -> corrected to 0
    ///   X = 73,138,869,387   Y = 3
    ///   sqrtPriceCurrent = 6,404,518,818,606
    ///   sqrtPLow         = 6,712,200,751,245
    ///
    /// The seed's two bound corrections run in sequence and the ceiling one
    /// zeroed `used1`, undoing the floor correction that had already run. It is
    /// refused outright now rather than minting a bricked pool.
    function test_H01_DegenerateSeedIsRefusedNotBricked() public {
        PrecisionPoolFactory.Market memory m = PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(tk),
            sqrtPLow: SL,
            sqrtPHigh: SH,
            fee: 0,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });

        vm.prank(lp);
        vm.expectRevert(PrecisionPool.PriceOutOfRange.selector);
        factory.createAndSeed{value: AMT0}(m, SEED, AMT0, AMT1, 0, lp);
    }

    /// @dev And the same market seeds fine with a sane counter-asset amount,
    /// so the guard rejects the degenerate case rather than the band.
    function test_H01_SameBandStillSeedsWithAdequateAmounts() public {
        PrecisionPoolFactory.Market memory m = PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(tk),
            sqrtPLow: SL,
            sqrtPHigh: SH,
            fee: 0,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });

        vm.prank(lp);
        (address p,,,) = factory.createAndSeed{value: 10 ether}(m, SEED, 10 ether, 1e24, 0, lp);
        PrecisionPool pool = PrecisionPool(payable(p));
        assertGe(pool.sqrtPriceCurrent(), SL, "inside the floor");
        assertLe(pool.sqrtPriceCurrent(), SH, "inside the ceiling");
    }
}
