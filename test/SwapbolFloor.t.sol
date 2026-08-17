// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapbol} from "../src/forwarders/Swapbol.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// @notice The bid side of the book, through the forwarder.
///
/// @dev These run against the REAL Floorboard rather than a stub, because the
///      thing most likely to be wrong is the one thing a stub would let pass:
///      the asset bindings on a bid are MIRRORED relative to every ask board.
///      `token` is what the bidder buys - our tokenIn - and `quote` is what
///      they pay - our tokenOut. A stub shaped like the ask boards would agree
///      with a forwarder that had them the wrong way round.
contract SwapbolFloorTest is Test {
    address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    Swapbol fwd;
    Swapboard swapboard;
    Dutchboard dutchboard;
    Floorboard floorboard;
    MockERC20 asset; // what the user sells
    MockERC20 quote; // what the user receives
    MockNFT nft;

    address bidder = address(0xB1D);
    address user = address(0xB0B);
    address maker = address(0xA11CE);

    uint128 constant WANT = 100e18;
    uint256 constant START = 200e18;
    uint256 constant END = 200e18; // flat schedule: a plain limit bid
    uint40 constant DUR = 1000;

    function setUp() public {
        vm.warp(10_000);
        MockWETH wethImpl = new MockWETH();
        vm.etch(WETH_ADDR, address(wethImpl).code);
        vm.deal(WETH_ADDR, 1_000 ether);

        swapboard = new Swapboard(WETH_ADDR);
        dutchboard = new Dutchboard(WETH_ADDR);
        floorboard = new Floorboard(WETH_ADDR);
        fwd = new Swapbol(
            address(new VenueStub()), address(swapboard), address(dutchboard), address(floorboard)
        );
        // This repo pins a mainnet fork and these are deterministic CREATE
        // addresses, some of which already hold dust on it. Zero them so the
        // "nothing stranded" assertions measure this suite.
        vm.deal(address(fwd), 0);
        vm.deal(address(floorboard), 0);

        asset = new MockERC20("ASSET", 18);
        quote = new MockERC20("QUOTE", 18);
        nft = new MockNFT();

        quote.mint(bidder, 1_000_000e18);
        vm.prank(bidder);
        quote.approve(address(floorboard), type(uint256).max);
    }

    // ------------------------------------------------------------- fixtures

    function _terms(address token, address q) internal view returns (Floorboard.Terms memory t) {
        t = Floorboard.Terms({
            token: token,
            quote: q,
            want: WANT,
            startPrice: START,
            endPrice: END,
            startTime: 0,
            duration: DUR,
            isNFT: false,
            ids: new uint256[](0)
        });
    }

    /// @dev A live bid: buy `asset`, pay `quote`, 2 quote per asset unit.
    function _bid() internal returns (uint256 id) {
        vm.prank(bidder);
        id = floorboard.bid(_terms(address(asset), address(quote)));
    }

    function _leg(uint256 id, uint256 give, uint256 minProceeds)
        internal
        view
        returns (Swapbol.Fill[] memory fills)
    {
        fills = new Swapbol.Fill[](1);
        fills[0] = Swapbol.Fill(id, address(floorboard), give, minProceeds, false);
    }

    /// snwap forwards tokenIn to the executor, so the forwarder starts holding it.
    function _fund(MockERC20 token, uint256 v) internal {
        fwd.checkpoint(address(token));
        token.mint(address(fwd), v);
    }

    // -------------------------------------------------------------- filling

    function test_sellsIntoAStandingBidAndPaysTheRecipient() public {
        uint256 id = _bid();
        _fund(asset, 40e18);

        fwd.fillPlan(address(asset), address(quote), user, user, 0, _leg(id, 40e18, 0));

        // 40 of 100 units at a flat 200 total => 80 quote.
        assertEq(quote.balanceOf(user), 80e18, "proceeds did not reach the recipient");
        assertEq(asset.balanceOf(bidder), 40e18, "bidder did not receive the asset");
        assertEq(quote.balanceOf(address(fwd)), 0, "proceeds stranded in the forwarder");
        assertEq(asset.balanceOf(address(fwd)), 0, "input stranded in the forwarder");
        assertEq(asset.allowance(address(fwd), address(floorboard)), 0, "approval survived the call");
    }

    /// The payoff of folding this into Swapbol rather than shipping a second
    /// forwarder: one plan, one snwap, asks and bids together.
    function test_mixesAnAskLegAndABidLegInOnePlan() public {
        uint256 bidId = _bid();

        // A resting ask on the other board: maker sells 50 quote, wants 20 asset.
        quote.mint(maker, 50e18);
        vm.startPrank(maker);
        quote.approve(address(swapboard), type(uint256).max);
        uint256 askId = swapboard.createOrder(
            address(quote), 50e18, address(asset), 20e18, true, 0, false, false, address(0)
        );
        vm.stopPrank();

        _fund(asset, 60e18); // 20 into the ask, 40 into the bid

        Swapbol.Fill[] memory fills = new Swapbol.Fill[](2);
        fills[0] = Swapbol.Fill(askId, address(swapboard), 20e18, 50e18, false);
        fills[1] = Swapbol.Fill(bidId, address(floorboard), 40e18, 0, false);

        fwd.fillPlan(address(asset), address(quote), user, user, 0, fills);

        assertEq(quote.balanceOf(user), 130e18, "ask 50 + bid 80 did not both land");
        assertEq(asset.balanceOf(address(fwd)), 0, "input stranded");
        assertEq(quote.balanceOf(address(fwd)), 0, "output stranded");
    }

    function test_partialBudgetReturnsTheRemainderToTheFunder() public {
        uint256 id = _bid();
        // The plan spends exactly what it names, so an over-funded route is an
        // input mismatch rather than a silent refund - the checkpoint is what
        // makes that detectable at all.
        _fund(asset, 50e18);
        vm.expectRevert(abi.encodeWithSelector(Swapbol.InputMismatch.selector, 40e18, 50e18));
        fwd.fillPlan(address(asset), address(quote), user, user, 0, _leg(id, 40e18, 0));
    }

    // --------------------------------------------------------------- native

    function test_nativeInputIsWrappedForTheBid() public {
        vm.prank(bidder);
        uint256 id = floorboard.bid(_terms(WETH_ADDR, address(quote)));

        vm.deal(address(this), 40e18);
        fwd.fillPlan{value: 40e18}(address(0), address(quote), user, user, 0, _leg(id, 40e18, 0));

        assertEq(quote.balanceOf(user), 80e18, "proceeds did not reach the recipient");
        assertEq(MockWETH(payable(WETH_ADDR)).balanceOf(bidder), 40e18, "bidder did not receive WETH");
        assertEq(address(fwd).balance, 0, "ETH stranded");
        assertEq(MockWETH(payable(WETH_ADDR)).balanceOf(address(fwd)), 0, "WETH stranded");
    }

    function test_nativeOutputIsUnwrappedOnceAfterTheLegs() public {
        // A WETH-quoted bid buying `asset`. The board pays WETH; the route asked
        // for ETH, so the forwarder unwraps the delta rather than passing
        // `unwrap` down per leg.
        MockWETH(payable(WETH_ADDR)).deposit{value: 0}();
        vm.deal(bidder, 1_000e18);
        vm.startPrank(bidder);
        MockWETH(payable(WETH_ADDR)).deposit{value: 500e18}();
        MockWETH(payable(WETH_ADDR)).approve(address(floorboard), type(uint256).max);
        uint256 id = floorboard.bid(_terms(address(asset), WETH_ADDR));
        vm.stopPrank();

        _fund(asset, 40e18);
        uint256 before = user.balance;
        fwd.fillPlan(address(asset), address(0), user, user, 0, _leg(id, 40e18, 0));

        assertEq(user.balance - before, 80e18, "ETH proceeds did not reach the recipient");
        assertEq(MockWETH(payable(WETH_ADDR)).balanceOf(address(fwd)), 0, "WETH left unconverted");
        assertEq(address(fwd).balance, 0, "ETH stranded");
    }

    // ------------------------------------------------------------ rejection

    /// The mirrored binding, stated as a test: a bid selling what the user wants
    /// to buy is not a leg of this route, and must not be treated as one.
    function test_rejectsABidWhoseAssetsAreTheWrongWayRound() public {
        vm.startPrank(bidder);
        asset.mint(bidder, 1_000e18);
        asset.approve(address(floorboard), type(uint256).max);
        // Buys `quote`, pays `asset` - the opposite direction.
        uint256 id = floorboard.bid(_terms(address(quote), address(asset)));
        vm.stopPrank();

        _fund(asset, 40e18);
        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fillPlan(address(asset), address(quote), user, user, 0, _leg(id, 40e18, 0));
    }

    function test_rejectsAnNftBid() public {
        vm.startPrank(bidder);
        Floorboard.Terms memory t = _terms(address(nft), address(quote));
        t.isNFT = true;
        t.want = 1;
        uint256 id = floorboard.bid(t);
        vm.stopPrank();

        _fund(asset, 1e18);
        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fillPlan(address(asset), address(quote), user, user, 0, _leg(id, 1e18, 0));
    }

    function test_rejectsABidThatDoesNotExist() public {
        _fund(asset, 1e18);
        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fillPlan(address(asset), address(quote), user, user, 0, _leg(999, 1e18, 0));
    }

    /// The generic `fill` entry point is a typed firewall, not a board call.
    /// `unwrap` would leave ETH here while the sweep measures a token delta for
    /// tokenOut, and the payout would leave as change to `refundTo`.
    function test_genericFillRejectsAnUnwrappingHit() public {
        uint256 id = _bid();
        _fund(asset, 40e18);
        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fill(
            address(floorboard),
            address(asset),
            address(quote),
            user,
            user,
            abi.encodeWithSignature("hit(uint256,uint128,uint256,bool)", id, uint128(40e18), uint256(0), true)
        );
    }

    function test_genericFillRejectsANonHitSelector() public {
        uint256 id = _bid();
        _fund(asset, 40e18);
        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fill(
            address(floorboard),
            address(asset),
            address(quote),
            user,
            user,
            abi.encodeWithSignature("cancel(uint256)", id)
        );
    }

    function test_genericFillAcceptsAWellFormedHit() public {
        uint256 id = _bid();
        _fund(asset, 40e18);
        fwd.fill(
            address(floorboard),
            address(asset),
            address(quote),
            user,
            user,
            abi.encodeWithSignature("hit(uint256,uint128,uint256,bool)", id, uint128(40e18), uint256(0), false)
        );
        assertEq(quote.balanceOf(user), 80e18);
    }

    /// The board's own floor still applies per leg; it is not weakened by the
    /// route-level one that snwap enforces.
    function test_perLegMinProceedsIsEnforcedByTheBoard() public {
        uint256 id = _bid();
        _fund(asset, 40e18);
        vm.expectRevert(abi.encodeWithSelector(Floorboard.ProceedsBelowMin.selector, 80e18, 81e18));
        fwd.fillPlan(address(asset), address(quote), user, user, 0, _leg(id, 40e18, 81e18));
    }

    function test_donatedBalancesCannotBeCapturedByALaterCaller() public {
        uint256 id = _bid();
        address attacker = address(0xBAD);
        asset.mint(address(fwd), 7e18);
        quote.mint(address(fwd), 11e18);

        vm.startPrank(attacker);
        fwd.checkpoint(address(asset));
        asset.mint(address(fwd), 40e18);
        fwd.fillPlan(address(asset), address(quote), attacker, attacker, 0, _leg(id, 40e18, 0));
        vm.stopPrank();

        assertEq(asset.balanceOf(address(fwd)), 7e18, "input baseline was swept");
        assertEq(quote.balanceOf(address(fwd)), 11e18, "output baseline was swept");
        assertEq(quote.balanceOf(attacker), 80e18, "attacker got more than the leg paid");
    }

    function test_rejectsAnExpiredPlanDeadline() public {
        uint256 id = _bid();
        _fund(asset, 40e18);
        vm.expectRevert(Swapbol.DeadlineExpired.selector);
        fwd.fillPlan(address(asset), address(quote), user, user, block.timestamp - 1, _leg(id, 40e18, 0));
    }

    function test_constructorRejectsARepeatedVenue() public {
        vm.expectRevert(Swapbol.BadVenue.selector);
        new Swapbol(address(swapboard), address(swapboard), address(dutchboard), address(floorboard));

        // Hoisted: `new VenueStub()` inside the argument list is itself a
        // creation, and `expectRevert` would arm against that instead.
        address stub = address(new VenueStub());
        vm.expectRevert(Swapbol.BadVenue.selector);
        new Swapbol(stub, address(swapboard), address(dutchboard), address(0));
    }
}

contract VenueStub {
    receive() external payable {}
}
