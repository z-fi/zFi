// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// @dev Covers replaceOrder: the in-place reprice added for programmatic
/// makers. The properties that matter are that escrow moves by the difference
/// and only the difference, that the same measurement rules apply as at
/// creation, and that everything identifying the order is immutable so its id
/// stays a stable handle.
contract SwapboardReplaceTest is Test {
    Swapboard sb;
    MockWETH weth;
    MockERC20 A;
    MockERC20 B;

    address maker = address(0xACE);
    address taker = address(0xB0B);
    address stranger = address(0xBAD);

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        A = new MockERC20("A", 18);
        B = new MockERC20("B", 18);

        A.mint(maker, 1_000e18);
        B.mint(taker, 1_000_000e18);

        vm.prank(maker);
        A.approve(address(sb), type(uint256).max);
        vm.prank(taker);
        B.approve(address(sb), type(uint256).max);
    }

    function _order() internal returns (uint256 id) {
        vm.prank(maker);
        id = sb.createOrder(address(A), 100e18, address(B), 200e18, true, 0, false, false, address(0));
    }

    function _get(uint256 id) internal view returns (Swapboard.Order memory) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        return sb.getOrders(ids)[0];
    }

    // ------------------------------------------------------------ escrow math

    function test_GrowPullsExactlyTheDifference() public {
        uint256 id = _order();
        uint256 makerBefore = A.balanceOf(maker);

        vm.prank(maker);
        sb.replaceOrder(id, 150e18, 330e18, 0);

        assertEq(makerBefore - A.balanceOf(maker), 50e18, "only the difference is pulled");
        assertEq(A.balanceOf(address(sb)), 150e18, "escrow matches the new amount");
        assertEq(_get(id).amountA, 150e18);
        assertEq(_get(id).amountB, 330e18);
    }

    function test_ShrinkReturnsExactlyTheDifference() public {
        uint256 id = _order();
        uint256 makerBefore = A.balanceOf(maker);

        vm.prank(maker);
        sb.replaceOrder(id, 40e18, 88e18, 0);

        assertEq(A.balanceOf(maker) - makerBefore, 60e18, "only the difference comes back");
        assertEq(A.balanceOf(address(sb)), 40e18);
        assertEq(_get(id).amountA, 40e18);
    }

    function test_RepriceOnlyMovesNoEscrow() public {
        uint256 id = _order();
        uint256 makerBefore = A.balanceOf(maker);

        // The whole point for a quoting pool: change the price, touch nothing.
        vm.prank(maker);
        sb.replaceOrder(id, 100e18, 250e18, 0);

        assertEq(A.balanceOf(maker), makerBefore, "no escrow movement");
        assertEq(A.balanceOf(address(sb)), 100e18);
        assertEq(_get(id).amountB, 250e18, "price changed");
    }

    function test_ReplacedOrderFillsAtTheNewPrice() public {
        uint256 id = _order();
        vm.prank(maker);
        sb.replaceOrder(id, 100e18, 400e18, 0); // doubled the ask

        vm.prank(taker);
        sb.fillOrder(id, block.timestamp, 400e18, taker);

        assertEq(A.balanceOf(taker), 100e18, "taker got the lot");
        assertEq(B.balanceOf(maker), 400e18, "maker was paid the new price");
    }

    function test_PartialFillThenReplaceUsesTheRemainder() public {
        uint256 id = _order();
        vm.prank(taker);
        sb.fillOrder(id, block.timestamp, 100e18, taker); // half

        assertEq(_get(id).amountA, 50e18);
        uint256 makerBefore = A.balanceOf(maker);

        // Growing back to 100 must pull 50, i.e. measured against what is left
        // resting rather than what was originally posted.
        vm.prank(maker);
        sb.replaceOrder(id, 100e18, 220e18, 0);
        assertEq(makerBefore - A.balanceOf(maker), 50e18);
        assertEq(A.balanceOf(address(sb)), 100e18);
    }

    // ------------------------------------------------------------ what is fixed

    function test_IdentityIsImmutableAcrossReplace() public {
        vm.prank(maker);
        uint256 id =
            sb.createOrder(address(A), 100e18, address(B), 200e18, true, 0, false, false, taker);

        vm.prank(maker);
        sb.replaceOrder(id, 10e18, 20e18, 0);

        Swapboard.Order memory o = _get(id);
        assertEq(o.maker, maker, "owner fixed");
        assertEq(o.tokenA, address(A), "pair fixed");
        assertEq(o.tokenB, address(B), "pair fixed");
        assertEq(o.counterparty, taker, "permissions fixed");
        assertTrue(o.partialFill, "flags fixed");
        assertTrue(o.active);
    }

    function test_ExpiryMayBeRefreshed() public {
        uint256 id = _order();
        uint64 until = uint64(block.timestamp + 1 days);
        vm.prank(maker);
        sb.replaceOrder(id, 100e18, 200e18, until);
        assertEq(_get(id).expiry, until);
    }

    /// @dev An expired order is still the maker's own escrow, and they could
    /// cancel and recreate anyway, so replacing it is allowed.
    function test_ExpiredOrderMayBeReplaced() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(
            address(A), 100e18, address(B), 200e18, true, uint64(block.timestamp + 1), false, false, address(0)
        );
        vm.warp(block.timestamp + 100);

        vm.prank(maker);
        sb.replaceOrder(id, 100e18, 200e18, uint64(block.timestamp + 1 days));
        assertTrue(_get(id).expiry > block.timestamp, "revived with a fresh lifetime");
    }

    // -------------------------------------------------------------------- batch

    function test_BatchRepricesEveryRung() public {
        uint256 a = _order();
        uint256 b = _order();
        uint256 makerBefore = A.balanceOf(maker);

        Swapboard.ReplaceOrderParams[] memory p = new Swapboard.ReplaceOrderParams[](2);
        p[0] = Swapboard.ReplaceOrderParams(a, 120e18, 260e18, 0); // grows by 20
        p[1] = Swapboard.ReplaceOrderParams(b, 80e18, 176e18, 0); // shrinks by 20

        vm.prank(maker);
        sb.replaceOrders(p);

        assertEq(A.balanceOf(maker), makerBefore, "the two deltas net out");
        assertEq(_get(a).amountB, 260e18);
        assertEq(_get(b).amountB, 176e18);
        assertEq(A.balanceOf(address(sb)), 200e18, "total escrow unchanged");
    }

    /// @dev A half-applied ladder would show some rungs at the old price and
    /// some at the new, which is a book the maker never intended.
    function test_BatchIsAtomic() public {
        uint256 a = _order();
        Swapboard.ReplaceOrderParams[] memory p = new Swapboard.ReplaceOrderParams[](2);
        p[0] = Swapboard.ReplaceOrderParams(a, 120e18, 260e18, 0);
        p[1] = Swapboard.ReplaceOrderParams(99, 80e18, 176e18, 0); // unknown id

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderNotFound.selector, uint256(99)));
        sb.replaceOrders(p);

        assertEq(_get(a).amountA, 100e18, "first leg rolled back");
        assertEq(_get(a).amountB, 200e18);
    }

    function test_BatchIsMakerOnlyPerOrder() public {
        uint256 mine = _order();
        vm.prank(stranger);
        A.mint(stranger, 100e18);
        vm.startPrank(stranger);
        A.approve(address(sb), type(uint256).max);
        uint256 theirs =
            sb.createOrder(address(A), 100e18, address(B), 200e18, true, 0, false, false, address(0));

        Swapboard.ReplaceOrderParams[] memory p = new Swapboard.ReplaceOrderParams[](2);
        p[0] = Swapboard.ReplaceOrderParams(theirs, 50e18, 100e18, 0);
        p[1] = Swapboard.ReplaceOrderParams(mine, 50e18, 100e18, 0); // not theirs

        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotMaker.selector, mine, stranger, maker));
        sb.replaceOrders(p);
        vm.stopPrank();

        assertEq(_get(mine).amountA, 100e18, "another maker's order is untouched");
    }

    // ------------------------------------------------------------------ refusals

    function test_OnlyMakerMayReplace() public {
        uint256 id = _order();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotMaker.selector, id, stranger, maker));
        sb.replaceOrder(id, 10e18, 20e18, 0);
    }

    function test_UnknownOrderIsRefused() public {
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderNotFound.selector, uint256(99)));
        sb.replaceOrder(99, 10e18, 20e18, 0);
    }

    function test_ClosedOrderIsRefused() public {
        uint256 id = _order();
        vm.prank(maker);
        sb.cancelOrder(id);

        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderNotActive.selector, id));
        sb.replaceOrder(id, 10e18, 20e18, 0);
    }

    function test_ZeroAmountsAreRefused() public {
        uint256 id = _order();
        vm.startPrank(maker);
        vm.expectRevert(Swapboard.ZeroAmount.selector);
        sb.replaceOrder(id, 0, 20e18, 0);
        vm.expectRevert(Swapboard.ZeroAmount.selector);
        sb.replaceOrder(id, 10e18, 0, 0);
        vm.stopPrank();
    }

    function test_ExpiryInThePastIsRefused() public {
        uint256 id = _order();
        uint64 past = uint64(block.timestamp);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.ExpiryInPast.selector, past));
        sb.replaceOrder(id, 10e18, 20e18, past);
    }

    /// @dev Amounts are tokenIds on an NFT side, so there is no difference to
    /// move and a "resize" would quietly mean a different token.
    function test_NFTOrderIsRefused() public {
        MockNFT n = new MockNFT();
        n.mint(maker, 7);
        vm.startPrank(maker);
        n.setApprovalForAll(address(sb), true);
        uint256 id =
            sb.createOrder(address(n), 7, address(B), 200e18, false, 0, true, false, address(0));

        vm.expectRevert(abi.encodeWithSelector(Swapboard.NFTNotReplaceable.selector, id));
        sb.replaceOrder(id, 8, 200e18, 0);
        vm.stopPrank();
    }

    /// @dev Growing measures what actually arrived, exactly as creation does,
    /// so a token that starts skimming after the order exists cannot leave it
    /// undercollateralised. Creation alone would not catch this: the token
    /// behaves until the grow leg.
    function test_TokenThatStartsSkimmingIsRefusedWhenGrowing() public {
        ToggleFeeERC20 t = new ToggleFeeERC20();
        t.mint(maker, 1_000e18);
        vm.startPrank(maker);
        t.approve(address(sb), type(uint256).max);
        uint256 id =
            sb.createOrder(address(t), 100e18, address(B), 200e18, true, 0, false, false, address(0));

        t.setSkim(true);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.BalanceMismatch.selector, 50e18, 49.5e18));
        sb.replaceOrder(id, 150e18, 330e18, 0);
        vm.stopPrank();

        // The order is untouched, still fully backed at its original size.
        assertEq(_get(id).amountA, 100e18);
    }

    /// @dev Shrinking confirms both ends of the return, so a token that
    /// under-delivers the refund cannot close out the difference for free.
    function test_ShrinkConfirmsTheReturnedDifference() public {
        ToggleFeeERC20 t = new ToggleFeeERC20();
        t.mint(maker, 1_000e18);
        vm.startPrank(maker);
        t.approve(address(sb), type(uint256).max);
        uint256 id =
            sb.createOrder(address(t), 100e18, address(B), 200e18, true, 0, false, false, address(0));

        t.setSkim(true);
        vm.expectRevert();
        sb.replaceOrder(id, 40e18, 88e18, 0);
        vm.stopPrank();

        assertEq(_get(id).amountA, 100e18, "no partial unwind");
    }
}

/// @dev Transfers cleanly until `skim` is set, then keeps 1%. Lets a test put
/// the hostile behaviour on the replace leg rather than on creation.
contract ToggleFeeERC20 is MockERC20("TOG", 18) {
    bool public skim;

    function setSkim(bool s) external {
        skim = s;
    }

    function transferFrom(address f, address t, uint256 amt) public override returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[t] += skim ? amt - amt / 100 : amt;
        return true;
    }

    function transfer(address t, uint256 amt) public override returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[t] += skim ? amt - amt / 100 : amt;
        return true;
    }
}
