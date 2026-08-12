// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Swapbatch} from "../src/forwarders/Swapbatch.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @notice Swapbatch: batch-fill Swapboard orders paying native ETH, which the board's
///         own `multicall` refuses by design (see SwapboardMulticallValue.t.sol).
contract SwapbatchTest is Test {
    Swapboard sb;
    Swapbatch batch;
    MockWETH weth;
    MockERC20 A;
    MockERC20 B;
    LegacyBoard legacyBoard;

    address maker1 = makeAddr("maker1");
    address maker2 = makeAddr("maker2");
    address maker3 = makeAddr("maker3");
    address taker = makeAddr("taker");
    address third = makeAddr("third");

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        A = new MockERC20("AAA", 18);
        B = new MockERC20("BBB", 18);
        legacyBoard = new LegacyBoard(address(weth), A, B);
        batch = new Swapbatch(address(weth), address(legacyBoard), address(sb));
        vm.deal(address(sb), 0);
        vm.deal(address(batch), 0);
        vm.deal(taker, 100 ether);
    }

    function _makeOrder(address maker, uint256 amountA, uint256 amountB, bool allowPartial)
        internal
        returns (uint256 id)
    {
        A.mint(maker, amountA);
        vm.startPrank(maker);
        A.approve(address(sb), amountA);
        id = sb.createOrder(address(A), amountA, address(weth), amountB, allowPartial, 0, false, false, address(0));
        vm.stopPrank();
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        (out[0], out[1]) = (a, b);
    }

    /// @dev No sweep needed: the local board pays the recipient directly.
    function _none() internal pure returns (address[] memory out) {
        out = new address[](0);
    }

    function _one(address t) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = t;
    }

    function _outs(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        (out[0], out[1]) = (a, b);
    }

    function _amts(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        (out[0], out[1]) = (a, b);
    }

    function _mins(uint256 n) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
    }

    /// @dev The helper must end every call holding nothing and granting nothing.
    function _assertClean() internal view {
        assertEq(address(batch).balance, 0, "helper holds ETH");
        assertEq(weth.balanceOf(address(batch)), 0, "helper holds WETH");
        assertEq(A.balanceOf(address(batch)), 0, "helper holds tokenA");
        assertEq(B.balanceOf(address(batch)), 0, "helper holds tokenB");
        assertEq(weth.allowance(address(batch), address(sb)), 0, "helper left an approval");
    }

    // ---------------------------------------------------------------- THE POINT

    function test_batchFillsTwoOrdersWithNativeEth() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256 id2 = _makeOrder(maker2, 200e18, 2 ether, false);

        uint256 before = taker.balance;
        vm.prank(taker);
        bool[] memory filled = batch.fillOrdersWithEth{value: 3 ether}(
            address(sb), _ids(id1, id2), _amts(1 ether, 2 ether), _mins(2), _none(), type(uint256).max, taker, false, false
        );

        assertTrue(filled[0] && filled[1], "both reported filled");
        assertEq(A.balanceOf(taker), 300e18, "both lots delivered");
        assertEq(weth.balanceOf(maker1), 1 ether, "maker1 paid");
        assertEq(weth.balanceOf(maker2), 2 ether, "maker2 paid");
        assertEq(before - taker.balance, 3 ether, "paid exactly the sum of the legs");
        _assertClean();
    }

    /// msg.value is counted once against the sum — the property `multicall` could not give.
    function test_underpaymentReverts() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256 id2 = _makeOrder(maker2, 200e18, 2 ether, false);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapbatch.InsufficientValue.selector, 3 ether, 3 ether - 1));
        batch.fillOrdersWithEth{value: 3 ether - 1}(
            address(sb), _ids(id1, id2), _amts(1 ether, 2 ether), _mins(2), _none(), type(uint256).max, taker, false, false
        );
    }

    function test_overpaymentIsRefunded() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256 id2 = _makeOrder(maker2, 200e18, 2 ether, false);

        uint256 before = taker.balance;
        vm.prank(taker);
        batch.fillOrdersWithEth{value: 10 ether}(
            address(sb), _ids(id1, id2), _amts(1 ether, 2 ether), _mins(2), _none(), type(uint256).max, taker, false, false
        );

        assertEq(before - taker.balance, 3 ether, "overpayment refunded");
        _assertClean();
    }

    /// A skipped leg's ETH must come back as ETH, not be stranded as WETH in the helper.
    function test_skipFailuresRefundsUnspentAsEth() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256 id2 = _makeOrder(maker2, 200e18, 2 ether, false);

        // maker2 pulls their order, so leg two is unfillable.
        vm.prank(maker2);
        sb.cancelOrder(id2);

        uint256 before = taker.balance;
        vm.prank(taker);
        bool[] memory filled = batch.fillOrdersWithEth{value: 3 ether}(
            address(sb), _ids(id1, id2), _amts(1 ether, 2 ether), _mins(2), _none(), type(uint256).max, taker, true, false
        );

        assertTrue(filled[0], "live order filled");
        assertFalse(filled[1], "cancelled order skipped");
        assertEq(A.balanceOf(taker), 100e18, "only the live lot delivered");
        assertEq(before - taker.balance, 1 ether, "only the filled leg was paid for");
        assertEq(weth.balanceOf(taker), 0, "refund arrived as ETH, not WETH");
        _assertClean();
    }

    /// The atomic path must abort rather than partially settle.
    function test_atomicPathRevertsOnBadOrder() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256 id2 = _makeOrder(maker2, 200e18, 2 ether, false);
        vm.prank(maker2);
        sb.cancelOrder(id2);

        vm.prank(taker);
        vm.expectRevert();
        batch.fillOrdersWithEth{value: 3 ether}(
            address(sb), _ids(id1, id2), _amts(1 ether, 2 ether), _mins(2), _none(), type(uint256).max, taker, false, false
        );
        assertEq(A.balanceOf(taker), 0, "nothing settled");
        assertEq(taker.balance, 100 ether, "value returned");
    }

    function test_deliversToNamedRecipient() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256 id2 = _makeOrder(maker2, 200e18, 2 ether, false);

        vm.prank(taker);
        batch.fillOrdersWithEth{value: 5 ether}(
            address(sb), _ids(id1, id2), _amts(1 ether, 2 ether), _mins(2), _none(), type(uint256).max, third, false, false
        );

        assertEq(A.balanceOf(third), 300e18, "lots went to the recipient");
        assertEq(A.balanceOf(taker), 0, "payer received no tokens");
        assertEq(third.balance, 2 ether, "refund followed the recipient");
        _assertClean();
    }

    /// A zero recipient must resolve to the caller, never to the helper — the board maps
    /// a zero recipient to ITS msg.sender, which would be this contract.
    function test_zeroRecipientResolvesToCaller() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256 id2 = _makeOrder(maker2, 200e18, 2 ether, false);

        vm.prank(taker);
        batch.fillOrdersWithEth{value: 3 ether}(
            address(sb), _ids(id1, id2), _amts(1 ether, 2 ether), _mins(2), _none(), type(uint256).max, address(0), false, false
        );

        assertEq(A.balanceOf(taker), 300e18, "lots reached the caller");
        _assertClean();
    }

    function test_partialFillsAcrossBatch() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, true);
        uint256 id2 = _makeOrder(maker2, 200e18, 2 ether, true);

        vm.prank(taker);
        batch.fillOrdersWithEth{value: 1.5 ether}(
            address(sb), _ids(id1, id2), _amts(0.5 ether, 1 ether), _mins(2), _none(), type(uint256).max, taker, false, false
        );

        assertEq(A.balanceOf(taker), 150e18, "half of each lot");
        _assertClean();
    }

    function test_zeroFillAmountIsRejectedInsteadOfUsingAnotherLegBudget() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256 id2 = _makeOrder(maker2, 200e18, 2 ether, false);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapbatch.ZeroFillAmount.selector, 1));
        batch.fillOrdersWithEth{value: 1 ether}(
            address(sb), _ids(id1, id2), _amts(1 ether, 0), _mins(2), _none(), type(uint256).max, taker, true, false
        );
    }

    function test_recipientCannotBeTheHelperOrWeth() public {
        uint256 id = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 1 ether;

        vm.expectRevert(Swapbatch.BadRecipient.selector);
        batch.fillOrdersWithEth{value: 1 ether}(
            address(sb), ids, amts, _mins(1), _none(), type(uint256).max, address(batch), false, false
        );
        vm.expectRevert(Swapbatch.BadRecipient.selector);
        batch.fillOrdersWithEth{value: 1 ether}(
            address(sb), ids, amts, _mins(1), _none(), type(uint256).max, address(weth), false, false
        );
    }

    // ------------------------------------------------------------------- GUARDS

    function test_lengthMismatchReverts() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id1;
        vm.prank(taker);
        vm.expectRevert(Swapbatch.LengthMismatch.selector);
        batch.fillOrdersWithEth{value: 1 ether}(
            address(sb), ids, _amts(1 ether, 2 ether), _mins(2), _none(), type(uint256).max, taker, false, false
        );
    }

    function test_emptyBatchReverts() public {
        vm.prank(taker);
        vm.expectRevert(Swapbatch.NoOrders.selector);
        batch.fillOrdersWithEth{value: 1 ether}(
            address(sb), new uint256[](0), new uint256[](0), new uint256[](0), _none(), type(uint256).max, taker, false, false
        );
    }

    /// Only WETH may push ETH in, so nobody can donate into someone else's sweep.
    function test_refusesDirectEth() public {
        vm.deal(third, 1 ether);
        vm.prank(third);
        (bool ok,) = address(batch).call{value: 1 ether}("");
        assertFalse(ok, "helper accepted a donation");
    }

    // ------------------------------------------------------------ LEGACY BOARD

    /// The deployed board takes no recipient and pays tokenA to its msg.sender — this
    /// helper. `tokensOut` is then the only way the purchase reaches the user.
    function test_legacyBoardDeliversViaSweep() public {
        LegacyBoard legacy = legacyBoard;
        A.mint(address(legacy), 300e18);

        uint256 before = taker.balance;
        vm.prank(taker);
        batch.fillOrdersWithEth{value: 3 ether}(
            address(legacy), _ids(0, 1), _amts(1 ether, 2 ether), _mins(2), _outs(address(A), address(A)),
            type(uint256).max, taker, false, true
        );

        // Two legs at the mock board's flat 100e18 payout. The 300e18 minted
        // above is the board's float, not the purchase.
        assertEq(A.balanceOf(taker), 200e18, "purchase swept to the user");
        assertEq(before - taker.balance, 3 ether, "charged the sum of the legs");
        _assertClean();
    }

    /// Forgetting `tokensOut` against a legacy board would strand the whole purchase,
    /// so it must revert rather than settle.
    function test_legacyBoardRequiresTokensOut() public {
        LegacyBoard legacy = legacyBoard;
        A.mint(address(legacy), 300e18);

        vm.prank(taker);
        vm.expectRevert(Swapbatch.TokensOutLengthMismatch.selector);
        batch.fillOrdersWithEth{value: 3 ether}(
            address(legacy), _ids(0, 1), _amts(1 ether, 2 ether), _mins(2), _none(),
            type(uint256).max, taker, false, true
        );
    }

    function test_legacyBoardValidatesEveryDistinctOutput() public {
        LegacyBoard legacy = legacyBoard;
        A.mint(address(legacy), 100e18);
        B.mint(address(legacy), 100e18);

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(Swapbatch.TokensOutMismatch.selector, 1, address(B), address(A))
        );
        batch.fillOrdersWithEth{value: 2 ether}(
            address(legacy), _ids(0, 2), _amts(1 ether, 1 ether), _mins(2), _outs(address(A), address(A)),
            type(uint256).max, taker, false, true
        );

        vm.prank(taker);
        batch.fillOrdersWithEth{value: 2 ether}(
            address(legacy), _ids(0, 2), _amts(1 ether, 1 ether), _mins(2), _outs(address(A), address(B)),
            type(uint256).max, taker, false, true
        );
        assertEq(A.balanceOf(taker), 100e18);
        assertEq(B.balanceOf(taker), 100e18);
        _assertClean();
    }

    /// Calling a legacy board with the modern encoding must fail loudly, not silently
    /// buy assets into this contract.
    function test_modernEncodingAgainstLegacyBoardReverts() public {
        LegacyBoard legacy = legacyBoard;
        A.mint(address(legacy), 300e18);

        vm.prank(taker);
        vm.expectRevert();
        batch.fillOrdersWithEth{value: 3 ether}(
            address(legacy), _ids(0, 1), _amts(1 ether, 2 ether), _mins(2), _outs(address(A), address(A)),
            type(uint256).max, taker, false, false
        );
    }

    function test_totalRequiredMatchesWhatIsCharged() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256 id2 = _makeOrder(maker2, 200e18, 2 ether, false);
        uint256[] memory amts = _amts(1 ether, 2 ether);
        assertEq(batch.totalRequired(amts), 3 ether, "quote disagrees with the sum");

        // Resolve the quote BEFORE pranking: an inline call in the value expression is
        // evaluated first and would consume the prank.
        uint256 quoted = batch.totalRequired(amts);
        uint256 before = taker.balance;
        vm.prank(taker);
        batch.fillOrdersWithEth{value: quoted}(
            address(sb), _ids(id1, id2), amts, _mins(amts.length), _none(), type(uint256).max, taker, false, false
        );
        assertEq(before - taker.balance, quoted, "charged more than quoted");
    }

    function test_expiredDeadlineReverts() public {
        uint256 id1 = _makeOrder(maker1, 100e18, 1 ether, false);
        uint256 id2 = _makeOrder(maker2, 200e18, 2 ether, false);
        skip(1000);
        vm.prank(taker);
        vm.expectRevert();
        batch.fillOrdersWithEth{value: 3 ether}(
            address(sb), _ids(id1, id2), _amts(1 ether, 2 ether), _mins(2), _none(), block.timestamp - 1, taker, false, false
        );
    }

    /// Scales past two legs, and the helper still ends clean.
    function testFuzz_batchOfThreeSettlesExactly(uint96 a, uint96 b, uint96 c) public {
        uint256 pa = bound(a, 1, 10 ether);
        uint256 pb = bound(b, 1, 10 ether);
        uint256 pc = bound(c, 1, 10 ether);

        uint256[] memory ids = new uint256[](3);
        ids[0] = _makeOrder(maker1, 10e18, pa, false);
        ids[1] = _makeOrder(maker2, 20e18, pb, false);
        ids[2] = _makeOrder(maker3, 30e18, pc, false);

        uint256[] memory amts = new uint256[](3);
        (amts[0], amts[1], amts[2]) = (pa, pb, pc);

        uint256 total = pa + pb + pc;
        vm.deal(taker, total + 1 ether);
        uint256 before = taker.balance;

        vm.prank(taker);
        batch.fillOrdersWithEth{value: total + 1 ether}(
            address(sb), ids, amts, _mins(amts.length), _none(), type(uint256).max, taker, false, false
        );

        assertEq(A.balanceOf(taker), 60e18, "all three lots delivered");
        assertEq(before - taker.balance, total, "charged exactly the sum");
        _assertClean();
    }
}

/// @dev Mimics the DEPLOYED Swapboard's batch fill: no recipient argument, tokenA paid to
///      msg.sender. Only the selector shape matters here, not the board's full accounting.
contract LegacyBoard {
    address public immutable weth;
    MockERC20 public immutable tokenA;
    MockERC20 public immutable tokenB;

    // Seven words, matching the DEPLOYED legacy board. This mock used to omit
    // `partialFill` exactly as Swapbatch's interface did, so the two agreed with
    // each other and disagreed with mainnet - the unit tests passed against a
    // mock built to the shape of the bug, and the one suite that used the real
    // board was the only one failing.
    struct Order {
        address maker;
        bool active;
        bool partialFill;
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
    }

    constructor(address _weth, MockERC20 _a, MockERC20 _b) {
        weth = _weth;
        tokenA = _a;
        tokenB = _b;
    }

    function fillOrders(uint256[] calldata orderIds, uint256, uint256[] calldata fillAmountsB) external {
        uint256 paid;
        for (uint256 i; i < orderIds.length; ++i) {
            paid += fillAmountsB[i];
        }
        MockERC20(weth).transferFrom(msg.sender, address(this), paid);
        for (uint256 i; i < orderIds.length; ++i) {
            (orderIds[i] < 2 ? tokenA : tokenB).transfer(msg.sender, 100e18);
        }
    }

    function getOrders(uint256[] calldata orderIds) external view returns (Order[] memory out) {
        out = new Order[](orderIds.length);
        for (uint256 i; i < orderIds.length; ++i) {
            if (orderIds[i] < 2) {
                out[i] = Order(address(1), true, false, address(tokenA), 100e18, address(weth), 1 ether);
            } else if (orderIds[i] < 4) {
                out[i] = Order(address(1), true, false, address(tokenB), 100e18, address(weth), 1 ether);
            }
        }
    }
}
