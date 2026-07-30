// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {SwapboardView} from "../src/SwapboardView.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @dev What a full-book plan actually costs. planHybrid is an eth_call helper,
/// so the ceiling that matters is a node's call gas cap - commonly 50M, often
/// 10M on a public endpoint - not the block limit. The matcher is O(n^2) in the
/// candidate count, so this pins the constant rather than trusting the shape.
contract SwapboardScaleTest is Test {
    SwapboardView lens;
    Swapboard board;
    MockERC20 tokenA;
    MockERC20 tokenB;
    address maker = address(0xA11CE);

    function setUp() public {
        lens = new SwapboardView();
        board = new Swapboard(address(new MockWETH()));
        tokenA = new MockERC20("AAA", 18);
        tokenB = new MockERC20("BBB", 6);
        tokenA.mint(maker, 10_000_000e18);
        vm.prank(maker);
        tokenA.approve(address(board), type(uint256).max);
    }

    /// All priced above the AMM floor, so every one is a live candidate and the
    /// matcher does its worst case rather than skipping cheaply.
    function _fill(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(maker);
            board.createOrder(address(tokenA), 200e18, address(tokenB), 100e6, true, 0, false, false, address(0));
        }
    }

    /// Orders on an unrelated pair - board weight that no quote for tokenB
    /// wants, but every scan of the book still pays to load.
    function _pad(uint256 n) internal {
        MockERC20 other = new MockERC20("CCC", 18);
        for (uint256 i; i < n; ++i) {
            vm.prank(maker);
            board.createOrder(address(tokenA), 1e18, address(other), 1e18, true, 0, false, false, address(0));
        }
    }

    function _measure(uint256 n) internal returns (uint256 gas, uint256 fills) {
        _fill(n);
        uint256 before = gasleft();
        (SwapboardView.Fill[] memory f,,,,) = lens.planHybrid(
            address(0), address(board), address(tokenB), address(tokenA), 100e6, address(this), 50e18, 0
        );
        gas = before - gasleft();
        fills = f.length;
        emit log_named_uint(string.concat("orders=", vm.toString(n), " gas"), gas);
    }

    function test_GasAtTheCandidateCeiling() public {
        (uint256 gas,) = _measure(256);
        // 50M is a generous node cap; 10M is a common public one. Staying under
        // 10M keeps the plan readable from any endpoint, not just a good one.
        assertLt(gas, 10_000_000, "a full book must plan within a modest eth_call budget");
    }

    /// The candidate ceiling bounds the O(n²) matcher, not discovery: a deeper
    /// book is still scanned so an older best order and V1 liquidity cannot be
    /// silently excluded. It must remain usable within a generous call budget.
    function test_DeepBookStillPlans() public {
        _measure(256);
        (uint256 over, uint256 fills) = _measure(512); // 768 total
        assertGt(fills, 0, "still plans past the ceiling");
        assertLt(over, 50_000_000, "deep-book planning remains an eth_call helper");
    }
    /// The case that actually scales with adoption: a busy board where almost
    /// nothing is your pair. The candidate cap cannot stop this scan early -
    /// the buffer never fills - so cost tracks the whole book and every quote
    /// pays it, whatever pair is being quoted. Recorded rather than bounded,
    /// because this is the term that decides the UI's architecture.
    function test_AFullScanIsPricedByTheWholeBoardNotTheMarket() public {
        _pad(2000);
        vm.prank(maker); // one real match, buried at the bottom
        board.createOrder(address(tokenA), 200e18, address(tokenB), 100e6, true, 0, false, false, address(0));

        uint256 before = gasleft();
        (SwapboardView.Fill[] memory f,,,,) = lens.planHybrid(
            address(0), address(board), address(tokenB), address(tokenA), 100e6, address(this), 50e18, 0
        );
        uint256 gas = before - gasleft();
        emit log_named_uint("planHybrid, 2000 unrelated orders: gas", gas);
        assertEq(f.length, 1, "the one match is still found");
        // Past a 10M endpoint cap already, and linear from here. Correct, but
        // not something a UI can do on every keystroke.
        assertGt(gas, 10_000_000, "if this ever drops, the UI guidance can relax");
    }

    /// The path a UI should take instead: bounded windows it can run
    /// concurrently and cache, then re-plan locally. Each window must stay
    /// comfortably callable regardless of how large the board has grown.
    function test_AWindowedWalkStaysCheapOnTheSameBoard() public {
        _pad(2000);
        vm.prank(maker);
        board.createOrder(address(tokenA), 200e18, address(tokenB), 100e6, true, 0, false, false, address(0));

        uint256 cursor;
        uint256 windows;
        uint256 worst;
        uint256 found;
        do {
            uint256 before = gasleft();
            (SwapboardView.OrderView[] memory c, uint256 next) = lens.candidatesFrom(
                address(board), true, address(tokenB), address(tokenA), address(this), cursor, 256
            );
            uint256 gas = before - gasleft();
            if (gas > worst) worst = gas;
            found += c.length;
            cursor = next;
            ++windows;
        } while (cursor != 0 && windows < 64);

        emit log_named_uint("windows walked", windows);
        emit log_named_uint("worst single window: gas", worst);
        assertEq(found, 1, "the walk finds the same order the full scan did");
        assertLt(worst, 3_000_000, "any one window is callable from any endpoint");
    }

    /// A walk that stops early must resume where it stopped, or the orders it
    /// did not reach are lost for good rather than merely deferred.
    function test_TheCursorDoesNotSkipWhatItDidNotReach() public {
        _pad(600);
        (, uint256 c1) = lens.candidatesFrom(
            address(board), true, address(tokenB), address(tokenA), address(this), 0, 256
        );
        assertEq(c1, 600 - 256, "resumes exactly below the window just read");
        (, uint256 c2) = lens.candidatesFrom(
            address(board), true, address(tokenB), address(tokenA), address(this), c1, 256
        );
        assertEq(c2, 600 - 512);
        (, uint256 c3) = lens.candidatesFrom(
            address(board), true, address(tokenB), address(tokenA), address(this), c2, 256
        );
        assertEq(c3, 0, "and reports done once id 0 is reached");
    }
}
