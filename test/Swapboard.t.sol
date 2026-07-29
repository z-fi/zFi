// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH, MockERC721, EvilERC20} from "./SwapboardMocks.sol";

contract SwapboardTest is Test {
    Swapboard sb;
    MockERC20 A;
    MockERC20 B;
    MockWETH weth;

    address maker = address(0xA11CE);
    address taker = address(0xB0B);
    address keeper = address(0xCAFE);

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        A = new MockERC20("AAA", 18);
        B = new MockERC20("BBB", 6);
        A.mint(maker, 1000e18);
        B.mint(taker, 1_000_000e6);
        vm.prank(maker);
        A.approve(address(sb), type(uint256).max);
        vm.prank(taker);
        B.approve(address(sb), type(uint256).max);
    }

    function _mk(bool pf, uint64 expiry) internal returns (uint256 id) {
        vm.prank(maker);
        id = sb.createOrder(address(A), 100e18, address(B), 200e6, pf, expiry, false, false, address(0));
    }

    // ------------------------------------------------------------- expiry

    function test_FillSucceedsBeforeExpiry() public {
        uint256 id = _mk(false, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days - 1);
        vm.prank(taker);
        sb.fillOrder(id, 0, 0, address(0));
        assertEq(A.balanceOf(taker), 100e18, "taker got tokenA");
        assertEq(B.balanceOf(maker), 200e6, "maker got tokenB");
    }

    function test_FillRevertsAfterExpiry() public {
        uint256 id = _mk(false, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderExpired.selector, id));
        sb.fillOrder(id, 0, 0, address(0));
    }

    function test_FillAtExactExpiryStillWorks() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 id = _mk(false, exp);
        vm.warp(exp); // expiry is inclusive: expired only once past it
        vm.prank(taker);
        sb.fillOrder(id, 0, 0, address(0));
        assertEq(A.balanceOf(taker), 100e18);
    }

    function test_ZeroExpiryNeverExpires() public {
        uint256 id = _mk(false, 0);
        vm.warp(block.timestamp + 3650 days);
        vm.prank(taker);
        sb.fillOrder(id, 0, 0, address(0));
        assertEq(A.balanceOf(taker), 100e18);
    }

    function test_CannotCreateAlreadyExpired() public {
        vm.warp(1000);
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.ExpiryInPast.selector, uint64(999)));
        sb.createOrder(address(A), 100e18, address(B), 200e6, false, 999, false, false, address(0));
    }

    function test_ExpiryDoesNotDisturbSlotPacking() public {
        uint256 id = _mk(true, uint64(block.timestamp + 1 days));
        (address m, bool act, bool pf, uint64 exp,,,, address ta, uint256 aa,, uint256 ab) = sb.orders(id);
        assertEq(m, maker);
        assertTrue(act);
        assertTrue(pf);
        assertEq(exp, uint64(block.timestamp + 1 days));
        assertEq(ta, address(A));
        assertEq(aa, 100e18);
        assertEq(ab, 200e6);
    }

    // -------------------------------------------------------------- sweep

    function test_AnyoneCanSweepExpiredBackToMaker() public {
        uint256 id = _mk(false, uint64(block.timestamp + 1 days));
        uint256 before = A.balanceOf(maker);
        vm.warp(block.timestamp + 2 days);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeper); // not the maker
        sb.cancelExpired(ids);

        assertEq(A.balanceOf(maker) - before, 100e18, "escrow returned to maker");
        assertEq(A.balanceOf(keeper), 0, "keeper takes nothing");
        assertFalse(sb.isFillableBy(id, taker));
    }

    function test_CannotSweepLiveOrder() public {
        uint256 id = _mk(false, uint64(block.timestamp + 1 days));
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderNotExpired.selector, id));
        sb.cancelExpired(ids);
    }

    function test_CannotSweepNeverExpiringOrder() public {
        uint256 id = _mk(false, 0);
        vm.warp(block.timestamp + 3650 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderNotExpired.selector, id));
        sb.cancelExpired(ids);
    }

    // ------------------------------------------------------- partial fill

    function test_PartialFillRoundsTowardMaker() public {
        uint256 id = _mk(true, uint64(block.timestamp + 1 days));
        // 1 unit of B against 100e18/200e6 -> 0.5e12 A, exact
        vm.prank(taker);
        sb.fillOrder(id, 0, 1, address(0));
        (,,,,,,,, uint256 remA,, uint256 remB) = sb.orders(id);
        assertEq(remB, 200e6 - 1);
        assertEq(A.balanceOf(taker), 100e18 * 1 / 200e6);
        assertEq(remA, 100e18 - (100e18 * 1 / 200e6));
    }

    function test_PartialRemainderStillExpires() public {
        uint256 id = _mk(true, uint64(block.timestamp + 1 days));
        vm.prank(taker);
        sb.fillOrder(id, 0, 50e6, address(0)); // take a quarter
        assertTrue(sb.isFillableBy(id, taker));
        vm.warp(block.timestamp + 2 days);
        assertFalse(sb.isFillableBy(id, taker), "resting remainder must expire too");
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderExpired.selector, id));
        sb.fillOrder(id, 0, 10e6, address(0));
    }

    function test_PartialFillRejectedOnAllOrNothing() public {
        uint256 id = _mk(false, 0);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.PartialFillNotAllowed.selector, id));
        sb.fillOrder(id, 0, 50e6, address(0));
    }

    function test_DustFillRejected() public {
        // amountA tiny relative to amountB so a 1-unit fill rounds to zero A
        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 1, address(B), 1000e6, true, 0, false, false, address(0));
        vm.prank(taker);
        vm.expectRevert(Swapboard.ZeroFillAmount.selector);
        sb.fillOrder(id, 0, 1, address(0));
    }

    // ------------------------------------------------------ taker deadline

    function test_TakerDeadlineIsSeparateFromOrderExpiry() public {
        uint256 id = _mk(false, 0); // order never expires
        vm.warp(1000);
        vm.prank(taker);
        vm.expectRevert(Swapboard.DeadlineExpired.selector);
        sb.fillOrder(id, 999, 0, address(0)); // but the taker's own deadline has passed
    }

    // ------------------------------------------------------------ batches

    function test_TryFillSkipsExpiredRatherThanReverting() public {
        uint256 live = _mk(true, 0);
        uint256 dead = _mk(true, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);

        uint256[] memory ids = new uint256[](2);
        ids[0] = dead;
        ids[1] = live;
        uint256[] memory amts = new uint256[](2);
        amts[0] = 10e6;
        amts[1] = 10e6;

        vm.prank(taker);
        bool[] memory filled = sb.tryFillOrders(ids, 0, amts, address(0));
        assertFalse(filled[0], "expired skipped");
        assertTrue(filled[1], "live filled");
    }

    function test_CancelStillMakerOnly() public {
        uint256 id = _mk(false, 0);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotMaker.selector, id, taker, maker));
        sb.cancelOrder(id);
    }

    // ------------------------------------------------------------------ NFT

    function _nft() internal returns (MockERC721 n) {
        n = new MockERC721();
        n.mint(maker, 7);
        vm.prank(maker);
        n.setApprovalForAll(address(sb), true);
    }

    function test_NftForTokenOrder() public {
        MockERC721 n = _nft();
        vm.prank(maker);
        uint256 id = sb.createOrder(address(n), 7, address(B), 500e6, false, 0, true, false, address(0));
        assertEq(n.ownerOf(7), address(sb), "NFT escrowed on create");

        vm.prank(taker);
        sb.fillOrder(id, 0, 0, address(0));
        assertEq(n.ownerOf(7), taker, "NFT delivered to taker");
        assertEq(B.balanceOf(maker), 500e6, "maker paid");
    }

    function test_TokenForNftOrder() public {
        MockERC721 n = new MockERC721();
        n.mint(taker, 9);
        vm.prank(taker);
        n.setApprovalForAll(address(sb), true);

        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 50e18, address(n), 9, false, 0, false, true, address(0));
        vm.prank(taker);
        sb.fillOrder(id, 0, 0, address(0));
        assertEq(n.ownerOf(9), maker, "maker receives the NFT");
        assertEq(A.balanceOf(taker), 50e18, "taker receives tokenA");
    }

    function test_NftTokenIdZeroIsValid() public {
        MockERC721 n = new MockERC721();
        n.mint(maker, 0);
        vm.prank(maker);
        n.setApprovalForAll(address(sb), true);
        vm.prank(maker);
        uint256 id = sb.createOrder(address(n), 0, address(B), 100e6, false, 0, true, false, address(0));
        assertEq(n.ownerOf(0), address(sb), "tokenId 0 escrowed, not rejected as ZeroAmount");
        vm.prank(taker);
        sb.fillOrder(id, 0, 0, address(0));
        assertEq(n.ownerOf(0), taker);
    }

    function test_NftCannotBePartialFill() public {
        MockERC721 n = _nft();
        vm.prank(maker);
        vm.expectRevert(Swapboard.NFTNotDivisible.selector);
        sb.createOrder(address(n), 7, address(B), 500e6, true, 0, true, false, address(0));
    }

    function test_NftPartialTakeRejected() public {
        MockERC721 n = new MockERC721();
        n.mint(taker, 9);
        vm.prank(taker);
        n.setApprovalForAll(address(sb), true);
        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 50e18, address(n), 9, false, 0, false, true, address(0));
        vm.prank(taker);
        // amountB is a tokenId; a mismatched value must not read as a full fill
        vm.expectRevert(abi.encodeWithSelector(Swapboard.PartialFillNotAllowed.selector, id));
        sb.fillOrder(id, 0, 5, address(0));
    }

    function test_NftReturnedOnCancelAndSweep() public {
        MockERC721 n = _nft();
        vm.prank(maker);
        uint256 id = sb.createOrder(address(n), 7, address(B), 500e6, false, 0, true, false, address(0));
        vm.prank(maker);
        sb.cancelOrder(id);
        assertEq(n.ownerOf(7), maker, "cancel returns the NFT");

        n.mint(maker, 8);
        vm.prank(maker);
        uint256 id2 = sb.createOrder(address(n), 8, address(B), 500e6, false, uint64(block.timestamp + 1 days), true, false, address(0));
        vm.warp(block.timestamp + 2 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id2;
        vm.prank(keeper);
        sb.cancelExpired(ids);
        assertEq(n.ownerOf(8), maker, "sweep returns the NFT to the maker");
    }

    // -------------------------------------------------------------- private

    function test_PrivateOrderOnlyNamedCounterpartyCanFill() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 100e18, address(B), 200e6, false, 0, false, false, taker);

        B.mint(keeper, 1000e6);
        vm.prank(keeper);
        B.approve(address(sb), type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotCounterparty.selector, id, keeper, taker));
        sb.fillOrder(id, 0, 0, address(0));

        vm.prank(taker);
        sb.fillOrder(id, 0, 0, address(0));
        assertEq(A.balanceOf(taker), 100e18);
    }

    function test_PublicOrderFillableByAnyone() public {
        uint256 id = _mk(false, 0);
        B.mint(keeper, 1000e6);
        vm.prank(keeper);
        B.approve(address(sb), type(uint256).max);
        vm.prank(keeper);
        sb.fillOrder(id, 0, 0, address(0));
        assertEq(A.balanceOf(keeper), 100e18);
    }

    function test_IsFillableByRespectsCounterparty() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 100e18, address(B), 200e6, false, 0, false, false, taker);
        assertTrue(sb.isFillableBy(id, taker));
        assertFalse(sb.isFillableBy(id, keeper));
    }

    function test_TryFillSkipsOrdersReservedForSomeoneElse() public {
        vm.prank(maker);
        uint256 mine = sb.createOrder(address(A), 10e18, address(B), 20e6, false, 0, false, false, keeper);
        uint256 open = _mk(false, 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = mine;
        ids[1] = open;
        uint256[] memory amts = new uint256[](2);
        vm.prank(taker);
        bool[] memory filled = sb.tryFillOrders(ids, 0, amts, address(0));
        assertFalse(filled[0], "reserved for someone else -> skipped");
        assertTrue(filled[1], "public -> filled");
    }

    // ------------------------------------------------- private NFT (compose)

    function test_PrivateNftOrder() public {
        MockERC721 n = _nft();
        vm.prank(maker);
        uint256 id = sb.createOrder(address(n), 7, address(B), 500e6, false, uint64(block.timestamp + 1 days), true, false, taker);

        B.mint(keeper, 1000e6);
        vm.prank(keeper);
        B.approve(address(sb), type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotCounterparty.selector, id, keeper, taker));
        sb.fillOrder(id, 0, 0, address(0));

        vm.prank(taker);
        sb.fillOrder(id, 0, 0, address(0));
        assertEq(n.ownerOf(7), taker, "named counterparty gets the NFT");
    }

    function test_PrivateNftOrderStillExpires() public {
        MockERC721 n = _nft();
        vm.prank(maker);
        uint256 id = sb.createOrder(address(n), 7, address(B), 500e6, false, uint64(block.timestamp + 1 days), true, false, taker);
        vm.warp(block.timestamp + 2 days);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderExpired.selector, id));
        sb.fillOrder(id, 0, 0, address(0));
    }

    // ---- NFT-for-ETH underpayment ----

    /// An NFT order always settles in full, so `fillAmountB` is rewritten to the
    /// full amountB inside _fill. If fillOrderWithEth let a taker send less than
    /// that, the board would pay the maker the full amount out of WETH escrowed
    /// by OTHER orders. This asserts the underpayment is refused outright.
    function test_NftForEthCannotBeUnderpaid() public {
        MockERC721 n = _nft();
        vm.prank(maker);
        uint256 id = sb.createOrder(address(n), 7, address(weth), 10e18, false, 0, true, false, address(0));

        // fund the board with unrelated escrow, which is what an exploit would drain
        vm.deal(address(this), 50e18);
        weth.deposit{value: 20e18}();
        weth.transfer(address(sb), 20e18);
        uint256 boardBefore = weth.balanceOf(address(sb));

        vm.deal(taker, 20e18);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.ETHAmountMismatch.selector, 10e18, 1e18));
        sb.fillOrderWithEth{value: 1e18}(id, 0, address(0));

        assertEq(weth.balanceOf(address(sb)), boardBefore, "no escrow moved");
        assertEq(n.ownerOf(7), address(sb), "NFT still escrowed");
    }

    function test_NftForEthFullPaymentWorks() public {
        MockERC721 n = _nft();
        vm.prank(maker);
        uint256 id = sb.createOrder(address(n), 7, address(weth), 10e18, false, 0, true, false, address(0));
        vm.deal(taker, 20e18);
        uint256 mb = weth.balanceOf(maker);
        vm.prank(taker);
        sb.fillOrderWithEth{value: 10e18}(id, 0, address(0));
        assertEq(n.ownerOf(7), taker, "taker gets the NFT");
        assertEq(weth.balanceOf(maker) - mb, 10e18, "maker paid in full");
    }

    /// An all-or-nothing ERC-20 order has the same shape: it settles in full, so
    /// a short ETH payment must not be accepted either.
    function test_AonOrderCannotBeUnderpaidWithEth() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 100e18, address(weth), 5e18, false, 0, false, false, address(0));
        vm.deal(taker, 10e18);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.ETHAmountMismatch.selector, 5e18, 1e18));
        sb.fillOrderWithEth{value: 1e18}(id, 0, address(0));
    }

    /// A partial-fill order legitimately accepts less, and must pay out pro rata.
    function test_PartialOrderAcceptsShortEthPayment() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 100e18, address(weth), 5e18, true, 0, false, false, address(0));
        vm.deal(taker, 10e18);
        uint256 tb = A.balanceOf(taker);
        vm.prank(taker);
        sb.fillOrderWithEth{value: 1e18}(id, 0, address(0));
        assertEq(A.balanceOf(taker) - tb, 20e18, "20% paid -> 20% of tokenA");
    }

    // ---- recipient (router integration) ----

    function test_FillDeliversToRecipientNotCaller() public {
        uint256 id = _mk(false, 0);
        vm.prank(taker);
        sb.fillOrder(id, 0, 0, keeper); // taker pays, keeper receives
        assertEq(A.balanceOf(keeper), 100e18, "tokenA delivered to recipient");
        assertEq(A.balanceOf(taker), 0, "caller receives nothing");
        assertEq(B.balanceOf(maker), 200e6, "maker still paid by the caller");
    }

    function test_ZeroRecipientMeansCaller() public {
        uint256 id = _mk(false, 0);
        vm.prank(taker);
        sb.fillOrder(id, 0, 0, address(0));
        assertEq(A.balanceOf(taker), 100e18);
    }

    function test_NftFillDeliversToRecipient() public {
        MockERC721 n = _nft();
        vm.prank(maker);
        uint256 id = sb.createOrder(address(n), 7, address(B), 500e6, false, 0, true, false, address(0));
        vm.prank(taker);
        sb.fillOrder(id, 0, 0, keeper);
        assertEq(n.ownerOf(7), keeper, "NFT delivered to recipient");
    }

    function test_BoardCannotBeItsOwnRecipient() public {
        uint256 id = _mk(false, 0);
        vm.prank(taker);
        vm.expectRevert(Swapboard.BadRecipient.selector);
        sb.fillOrder(id, 0, 0, address(sb));
    }

    /// WETH as recipient would re-wrap an unwrapped payout back to the board.
    function test_WethCannotBeRecipient() public {
        uint256 id = _mk(false, 0);
        vm.prank(taker);
        vm.expectRevert(Swapboard.BadRecipient.selector);
        sb.fillOrder(id, 0, 0, address(weth));
    }

    /// The recipient is a delivery address, never authorisation. Naming the
    /// intended counterparty must not let a stranger take a private order.
    function test_RecipientCannotBypassPrivateOrder() public {
        vm.prank(maker);
        uint256 id = sb.createOrder(address(A), 100e18, address(B), 200e6, false, 0, false, false, taker);
        B.mint(keeper, 1000e6);
        vm.prank(keeper);
        B.approve(address(sb), type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotCounterparty.selector, id, keeper, taker));
        sb.fillOrder(id, 0, 0, taker); // pretending to fill "for" the counterparty
    }

    // ---- skipping sweep ----

    /// A keeper's list is read before it is mined; anything settled in between
    /// must not abort the whole sweep.
    function test_TrySweepSkipsStaleEntriesInsteadOfReverting() public {
        uint256 live = _mk(false, uint64(block.timestamp + 1 days));
        uint256 alsoLive = _mk(false, uint64(block.timestamp + 1 days));
        uint256 never = _mk(false, 0);
        vm.warp(block.timestamp + 2 days);

        // one of them gets swept by someone else first
        uint256[] memory first = new uint256[](1);
        first[0] = alsoLive;
        vm.prank(keeper);
        sb.cancelExpired(first);

        uint256[] memory batch = new uint256[](4);
        batch[0] = live;
        batch[1] = alsoLive; // already swept
        batch[2] = never; // never expires
        batch[3] = 9999; // does not exist
        uint256 before = A.balanceOf(maker);
        vm.prank(keeper);
        bool[] memory ok = sb.trySweepExpired(batch);

        assertTrue(ok[0], "expired one swept");
        assertFalse(ok[1], "already settled -> skipped");
        assertFalse(ok[2], "never expires -> skipped");
        assertFalse(ok[3], "missing -> skipped");
        assertEq(A.balanceOf(maker) - before, 100e18, "only the sweepable escrow moved");
    }

    function test_StrictSweepStillRevertsOnStaleEntry() public {
        uint256 id = _mk(false, uint64(block.timestamp + 1 days));
        uint256 never = _mk(false, 0);
        vm.warp(block.timestamp + 2 days);
        uint256[] memory batch = new uint256[](2);
        batch[0] = id;
        batch[1] = never;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderNotExpired.selector, never));
        sb.cancelExpired(batch);
    }

    // ---- adversarial ----

    /// Sending more than the order asks must not overcharge: the fill is clamped
    /// to amountB, not billed at the amount offered.
    function test_OverpayIsClampedNotCharged() public {
        uint256 id = _mk(true, 0); // 100 A for 200 USDC-ish B
        uint256 tb = B.balanceOf(taker);
        vm.prank(taker);
        sb.fillOrder(id, 0, 999_999e6, address(0)); // offers far more than asked
        assertEq(tb - B.balanceOf(taker), 200e6, "charged exactly amountB");
        assertEq(A.balanceOf(taker), 100e18, "received all of tokenA");
    }

    /// A partial fill can never consume all of amountA while leaving the order
    /// active, which would strand a live-but-unfillable entry in the book.
    function test_PartialFillCannotStrandAZombieOrder() public {
        uint256 id = _mk(true, 0);
        vm.prank(taker);
        sb.fillOrder(id, 0, 200e6 - 1, address(0)); // one unit short of everything
        (,,,,,,,, uint256 remA,, uint256 remB) = sb.orders(id);
        assertGt(remA, 0, "remainder still backed by tokenA");
        assertEq(remB, 1, "one unit of tokenB still wanted");
        vm.prank(taker);
        sb.fillOrder(id, 0, 0, address(0)); // and it is still fillable
        (, bool active,,,,,,,,,) = sb.orders(id);
        assertFalse(active, "settles cleanly");
    }

    /// nonReentrant must hold even when tokenA calls back during payout.
    function test_MaliciousTokenCannotReenter() public {
        EvilERC20 evil = new EvilERC20();
        evil.mint(maker, 100e18);
        vm.prank(maker);
        evil.approve(address(sb), type(uint256).max);
        vm.prank(maker);
        uint256 id = sb.createOrder(address(evil), 100e18, address(B), 200e6, false, 0, false, false, address(0));
        evil.arm(address(sb), id); // reenter on the payout transfer
        vm.prank(taker);
        sb.fillOrder(id, 0, 0, address(0)); // EvilERC20 asserts the reentrant call failed
        assertEq(evil.balanceOf(taker), 100e18, "fill still settled correctly");
    }

    /// unwrap is meaningless for an NFT payout; the NFT branch wins and the flag
    /// is ignored rather than reverting. Documented so it is not a surprise.
    function test_UnwrapFlagIsIgnoredForNftPayout() public {
        MockERC721 n = _nft();
        vm.prank(maker);
        uint256 id = sb.createOrder(address(n), 7, address(B), 500e6, false, 0, true, false, address(0));
        vm.prank(taker);
        sb.fillOrderUnwrap(id, 0, 0, address(0));
        assertEq(n.ownerOf(7), taker, "NFT delivered; unwrap ignored");
    }
}
