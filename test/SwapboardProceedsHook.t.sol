// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// A maker that opts into the two-phase proceeds accounting. `acceptsOrderProceeds`
/// is probed with a bounded staticcall, and only a clean `true` turns on the
/// stateful callbacks - so this mock is the only way to exercise that branch.
contract ProceedsMaker {
    Swapboard immutable board;

    bool public accepts = true;
    bool public beforeReturns = true;
    bool public revertInBefore;
    bool public revertInAfter;
    bool public reenterInBefore;

    uint256 public beforeCalls;
    uint256 public afterCalls;
    uint256 public balanceSeenInBefore;
    uint256 public balanceSeenInAfter;
    uint256 public lastOrderId;
    address public lastToken;
    uint256 public lastAmount;
    bool public lastNft;
    address public probeToken;

    constructor(Swapboard _board) {
        board = _board;
    }

    function set(bool _accepts, bool _beforeReturns) external {
        accepts = _accepts;
        beforeReturns = _beforeReturns;
    }

    function setReverts(bool inBefore, bool inAfter) external {
        revertInBefore = inBefore;
        revertInAfter = inAfter;
    }

    function setReenter(bool value) external {
        reenterInBefore = value;
    }

    function setProbeToken(address token) external {
        probeToken = token;
    }

    function approve(address token, address spender) external {
        MockERC20(token).approve(spender, type(uint256).max);
    }

    function acceptsOrderProceeds(uint256) external view returns (bool) {
        return accepts;
    }

    function beforeOrderProceeds(uint256 orderId, address token, uint256 amount, bool nft)
        external
        returns (bool)
    {
        if (revertInBefore) revert("before");
        ++beforeCalls;
        (lastOrderId, lastToken, lastAmount, lastNft) = (orderId, token, amount, nft);
        balanceSeenInBefore = MockERC20(probeToken).balanceOf(address(this));
        // The board is mid-settlement; its guard must hold against the maker.
        if (reenterInBefore) board.cancelOrder(orderId);
        return beforeReturns;
    }

    function afterOrderProceeds(uint256 orderId, address, uint256, bool) external {
        if (revertInAfter) revert("after");
        ++afterCalls;
        lastOrderId = orderId;
        balanceSeenInAfter = MockERC20(probeToken).balanceOf(address(this));
    }
}

contract SwapboardProceedsHookTest is Test {
    Swapboard board;
    MockWETH weth;
    MockERC20 tokA;
    MockERC20 tokB;
    ProceedsMaker maker;

    address taker = address(0x7A4E);

    function setUp() public {
        weth = new MockWETH();
        board = new Swapboard(address(weth));
        tokA = new MockERC20("A", 18);
        tokB = new MockERC20("B", 18);
        maker = new ProceedsMaker(board);
        maker.setProbeToken(address(tokB));

        tokA.mint(address(maker), 100e18);
        maker.approve(address(tokA), address(board));
        tokB.mint(taker, 100e18);
        vm.prank(taker);
        tokB.approve(address(board), type(uint256).max);
    }

    function _order(bool isPartial) internal returns (uint256 id) {
        vm.prank(address(maker));
        id = board.createOrder(address(tokA), 100e18, address(tokB), 10e18, isPartial, 0, false, false, address(0));
    }

    function _fill(uint256 id, uint256 amountB) internal {
        vm.prank(taker);
        board.fillOrder(id, 0, amountB, 0, taker);
    }

    /// Both phases fire, in order, with the order's own terms - and the
    /// before/after split is real: the proceeds have not arrived in `before`
    /// and have in `after`.
    function test_bothPhasesFireAroundThePayment() public {
        uint256 id = _order(false);
        _fill(id, 10e18);

        assertEq(maker.beforeCalls(), 1, "before fired once");
        assertEq(maker.afterCalls(), 1, "after fired once");
        assertEq(maker.lastOrderId(), id);
        assertEq(maker.lastToken(), address(tokB));
        assertEq(maker.lastAmount(), 10e18);
        assertFalse(maker.lastNft());
        assertEq(maker.balanceSeenInBefore(), 0, "before runs ahead of the payment");
        assertEq(maker.balanceSeenInAfter(), 10e18, "after runs behind it");
    }

    /// The probe is the opt-in. A maker that declines is never called again.
    function test_decliningTheProbeSkipsBothPhases() public {
        maker.set(false, true);
        uint256 id = _order(false);
        _fill(id, 10e18);

        assertEq(maker.beforeCalls(), 0, "no before");
        assertEq(maker.afterCalls(), 0, "no after");
        assertEq(tokB.balanceOf(address(maker)), 10e18, "and the fill still settled");
    }

    /// `before` returning false opts back out of the second phase for this fill.
    function test_beforeReturningFalseSuppressesAfter() public {
        maker.set(true, false);
        uint256 id = _order(false);
        _fill(id, 10e18);

        assertEq(maker.beforeCalls(), 1);
        assertEq(maker.afterCalls(), 0, "after is gated on before's answer");
    }

    /// An ordinary EOA maker never reaches the callbacks: the probe staticcall
    /// returns no data, which reads as "no".
    function test_eoaMakerIsUnaffected() public {
        address eoa = address(0xE0A);
        tokA.mint(eoa, 100e18);
        vm.startPrank(eoa);
        tokA.approve(address(board), type(uint256).max);
        uint256 id = board.createOrder(address(tokA), 100e18, address(tokB), 10e18, false, 0, false, false, address(0));
        vm.stopPrank();

        _fill(id, 10e18);
        assertEq(tokB.balanceOf(eoa), 10e18);
    }

    /// Each partial fill notifies with that leg's amount, not the whole ask.
    function test_partialFillsNotifyPerLeg() public {
        uint256 id = _order(true);
        _fill(id, 4e18);
        assertEq(maker.lastAmount(), 4e18, "the leg, not the ask");
        assertEq(maker.beforeCalls(), 1);

        _fill(id, 6e18);
        assertEq(maker.lastAmount(), 6e18);
        assertEq(maker.beforeCalls(), 2);
        assertEq(maker.afterCalls(), 2);
    }

    /// The board hands the maker control mid-settlement, so the guard has to
    /// hold: the maker cannot cancel the very order being filled.
    function test_makerCannotReenterDuringTheCallback() public {
        maker.setReenter(true);
        uint256 id = _order(false);

        vm.prank(taker);
        vm.expectRevert(); // Reentrancy(), raised by the transient guard.
        board.fillOrder(id, 0, 10e18, 0, taker);

        // Nothing moved.
        assertEq(tokA.balanceOf(address(board)), 100e18, "escrow intact");
        assertEq(tokB.balanceOf(taker), 100e18, "taker not charged");
    }

    // ---------------------------------------------------------------------
    // Known limitation, pinned deliberately.
    //
    // These callbacks are a full-gas call into maker-chosen code, and their
    // revert bubbles. `tryFillOrders` pre-screens only the not-fillable-right-
    // now states, so a hostile maker can abort a whole batch. Catching it needs
    // an external self-call per leg and Swapboard has ~158 B of EIP-170 headroom
    // left, which does not buy one. These tests fail the day that changes -
    // which is the point: they are the record of the trade, not an endorsement.
    // ---------------------------------------------------------------------

    function test_KNOWN_hostileMakerRevertsTheWholeTryFillBatch() public {
        uint256 good = _order(true);

        ProceedsMaker hostile = new ProceedsMaker(board);
        hostile.setProbeToken(address(tokB));
        tokA.mint(address(hostile), 1e18);
        hostile.approve(address(tokA), address(board));
        vm.prank(address(hostile));
        uint256 bad =
            board.createOrder(address(tokA), 1e18, address(tokB), 1, true, 0, false, false, address(0));
        hostile.setReverts(false, true);

        uint256[] memory ids = new uint256[](2);
        uint256[] memory amts = new uint256[](2);
        uint256[] memory mins = new uint256[](2);
        (ids[0], amts[0]) = (good, 1e18);
        (ids[1], amts[1]) = (bad, 1);

        vm.prank(taker);
        vm.expectRevert(bytes("after"));
        board.tryFillOrders(ids, 0, amts, mins, taker);
    }

    function test_KNOWN_revertInBeforeAlsoAbortsTheBatch() public {
        uint256 id = _order(true);
        maker.setReverts(true, false);

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amts = new uint256[](1);
        uint256[] memory mins = new uint256[](1);
        (ids[0], amts[0]) = (id, 1e18);

        vm.prank(taker);
        vm.expectRevert(bytes("before"));
        board.tryFillOrders(ids, 0, amts, mins, taker);
    }
}
