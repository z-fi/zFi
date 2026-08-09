// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// A contract bid holder that opts into the two-phase proceeds accounting.
/// `acceptsOrderProceeds` is probed with a bounded staticcall and only a clean
/// `true` turns the stateful callbacks on, so this mock is the only way to
/// exercise that branch at all.
contract ProceedsHolder {
    bool public accepts = true;
    bool public beforeReturns = true;
    bool public revertInBefore;
    bool public revertInAfter;

    uint256 public beforeCalls;
    uint256 public afterCalls;
    address public lastToken;
    uint256 public lastAmount;
    bool public lastNft;
    uint256 public balanceSeenInBefore;
    address public probe;

    function configure(bool _accepts, bool _beforeReturns) external {
        accepts = _accepts;
        beforeReturns = _beforeReturns;
    }

    function setReverts(bool inBefore, bool inAfter) external {
        revertInBefore = inBefore;
        revertInAfter = inAfter;
    }

    function setProbe(address token) external {
        probe = token;
    }

    function acceptsOrderProceeds(uint256) external view returns (bool) {
        return accepts;
    }

    function beforeOrderProceeds(uint256, address token, uint256 amount, bool nft) external returns (bool) {
        if (revertInBefore) revert("before");
        ++beforeCalls;
        (lastToken, lastAmount, lastNft) = (token, amount, nft);
        balanceSeenInBefore = MockERC20(probe).balanceOf(address(this));
        return beforeReturns;
    }

    function afterOrderProceeds(uint256, address, uint256, bool) external {
        if (revertInAfter) revert("after");
        ++afterCalls;
    }
}

/// Reenters the board while it is paying the seller.
contract ReenteringQuote is MockERC20 {
    Floorboard board;
    uint256 target;
    bool armed;
    bool public reentryRefused;

    constructor() MockERC20("RQ", 18) {}

    function arm(Floorboard b, uint256 id) external {
        board = b;
        target = id;
        armed = true;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        if (armed) {
            armed = false;
            // Catch it here: Floorboard's `safeTransfer` would otherwise
            // repackage the inner revert as a bare `TransferFailed`, and the
            // test could not tell a held guard from a broken token.
            try board.cancel(target) {}
            catch (bytes memory reason) {
                reentryRefused = bytes4(reason) == Floorboard.Reentrancy.selector;
            }
        }
        return super.transfer(to, amt);
    }
}

/// MockNFT does not implement ERC-165, and `_isERC721` is explicitly lenient
/// about that. Detection needs a collection that actually declares itself.
contract Declaring721 {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd;
    }
}

/// Takes a cut on transfer, so the board's exact-delta checks must refuse it.
contract FeeToken is MockERC20 {
    constructor() MockERC20("FEE", 18) {}

    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        uint256 fee = amt / 100;
        super.transferFrom(from, address(0xFEE), fee);
        return super.transferFrom(from, to, amt - fee);
    }
}

contract FloorboardCoverageTest is Test {
    Floorboard board;
    MockWETH weth;
    MockERC20 quoteToken;
    MockERC20 want;
    MockNFT nft;

    address bidder = address(0xB1D);
    address seller = address(0x5E11);

    uint128 constant WANT = 1000e18;
    uint256 constant START = 100e18;
    uint256 constant END = 200e18;
    uint40 constant DUR = 1000;

    function setUp() public {
        vm.warp(10_000);
        weth = new MockWETH();
        quoteToken = new MockERC20("Q", 18);
        want = new MockERC20("W", 18);
        nft = new MockNFT();
        board = new Floorboard(address(weth));

        quoteToken.mint(bidder, 1_000_000e18);
        quoteToken.mint(address(this), 1_000_000e18);
        want.mint(seller, 1_000_000e18);

        vm.prank(bidder);
        quoteToken.approve(address(board), type(uint256).max);
        quoteToken.approve(address(board), type(uint256).max);
        vm.prank(seller);
        want.approve(address(board), type(uint256).max);
    }

    function _terms(address token, address quote, bool isNFT, uint128 w)
        internal
        pure
        returns (Floorboard.Terms memory t)
    {
        t = Floorboard.Terms({
            token: token,
            quote: quote,
            want: w,
            startPrice: START,
            endPrice: END,
            startTime: 0,
            duration: DUR,
            isNFT: isNFT,
            ids: new uint256[](0)
        });
    }

    function _bid() internal returns (uint256 id) {
        vm.prank(bidder);
        id = board.bid(_terms(address(want), address(quoteToken), false, WANT));
    }

    // -------------------------------------------------- PROCEEDS CALLBACKS

    function test_bothPhasesFireOnDeliveryToAContractHolder() public {
        ProceedsHolder holder = new ProceedsHolder();
        holder.setProbe(address(want));
        uint256 id = board.bidFor(address(holder), _terms(address(want), address(quoteToken), false, WANT));

        vm.prank(seller);
        board.hit(id, 400e18, 0, false);

        assertEq(holder.beforeCalls(), 1, "before fired");
        assertEq(holder.afterCalls(), 1, "after fired");
        assertEq(holder.lastToken(), address(want), "the asset bought");
        assertEq(holder.lastAmount(), 400e18, "this leg's size");
        assertFalse(holder.lastNft());
        assertEq(holder.balanceSeenInBefore(), 0, "before runs ahead of the delivery");
        assertEq(want.balanceOf(address(holder)), 400e18, "and the asset landed");
    }

    /// The refund on a full buyout is escrow moving to the holder, so it is
    /// bracketed by the same callbacks rather than arriving unexplained.
    function test_buyoutRefundIsAlsoBracketed() public {
        ProceedsHolder holder = new ProceedsHolder();
        holder.setProbe(address(want));
        uint256 id = board.bidFor(address(holder), _terms(address(want), address(quoteToken), false, WANT));

        vm.prank(seller);
        board.hit(id, WANT, 0, false);

        // One for the asset, one for the unspent ceiling coming back.
        assertEq(holder.beforeCalls(), 2, "asset + refund");
        assertEq(holder.afterCalls(), 2);
        assertEq(holder.lastToken(), address(quoteToken), "the refund is in quote");
    }

    function test_decliningTheProbeSkipsBothPhases() public {
        ProceedsHolder holder = new ProceedsHolder();
        holder.setProbe(address(want));
        holder.configure(false, true);
        uint256 id = board.bidFor(address(holder), _terms(address(want), address(quoteToken), false, WANT));

        vm.prank(seller);
        board.hit(id, 400e18, 0, false);

        assertEq(holder.beforeCalls(), 0, "no before");
        assertEq(holder.afterCalls(), 0, "no after");
        assertEq(want.balanceOf(address(holder)), 400e18, "delivery still happened");
    }

    function test_beforeReturningFalseSuppressesAfter() public {
        ProceedsHolder holder = new ProceedsHolder();
        holder.setProbe(address(want));
        holder.configure(true, false);
        uint256 id = board.bidFor(address(holder), _terms(address(want), address(quoteToken), false, WANT));

        vm.prank(seller);
        board.hit(id, 400e18, 0, false);
        assertEq(holder.beforeCalls(), 1);
        assertEq(holder.afterCalls(), 0, "after is gated on before's answer");
    }

    /// An escrow that opted in and then refused the accounting must not be paid
    /// anyway - the revert bubbles rather than being swallowed.
    function test_callbackRevertBubblesAndVoidsTheHit() public {
        ProceedsHolder holder = new ProceedsHolder();
        holder.setProbe(address(want));
        uint256 id = board.bidFor(address(holder), _terms(address(want), address(quoteToken), false, WANT));
        holder.setReverts(false, true);

        vm.prank(seller);
        vm.expectRevert(bytes("after"));
        board.hit(id, 400e18, 0, false);

        assertEq(want.balanceOf(address(holder)), 0, "nothing delivered");
        assertEq(board.escrowed(address(quoteToken)), END, "escrow untouched");
    }

    /// Known limitation, pinned: `tryHitMany` steps over stale state, not over a
    /// hostile holder. Same trade Swapboard's `tryFillOrders` makes.
    function test_KNOWN_hostileHolderAbortsTheWholeTryHitBatch() public {
        uint256 good = _bid();

        ProceedsHolder holder = new ProceedsHolder();
        holder.setProbe(address(want));
        uint256 bad = board.bidFor(address(holder), _terms(address(want), address(quoteToken), false, WANT));
        holder.setReverts(false, true);

        uint256[] memory ids = new uint256[](2);
        uint128[] memory gives = new uint128[](2);
        uint256[] memory mins = new uint256[](2);
        (ids[0], gives[0]) = (good, 10e18);
        (ids[1], gives[1]) = (bad, 10e18);

        vm.prank(seller);
        vm.expectRevert(bytes("after"));
        board.tryHitMany(ids, gives, mins);
    }

    // ------------------------------------------------------------- BATCHES

    function test_hitManySettlesEveryLeg() public {
        uint256 a = _bid();
        uint256 b = _bid();

        uint256[] memory ids = new uint256[](2);
        uint128[] memory gives = new uint128[](2);
        uint256[] memory mins = new uint256[](2);
        (ids[0], gives[0]) = (a, 100e18);
        (ids[1], gives[1]) = (b, 200e18);

        vm.prank(seller);
        uint256[] memory paid = board.hitMany(ids, gives, mins);

        assertGt(paid[0], 0);
        assertGt(paid[1], 0);
        assertEq(want.balanceOf(bidder), 300e18, "both legs delivered");
    }

    /// An NFT bid cannot settle through the fungible batch path at all. Before
    /// the fix `_quote` reported it takeable, so a router that built its batch
    /// from `quoteHit` got the whole batch reverted on the lot-kind mismatch
    /// instead of the one bad leg being stepped over.
    function test_tryHitManyStepsOverNFTBidsInsteadOfAbortingTheBatch() public {
        uint256 live = _bid();
        vm.prank(bidder);
        uint256 nftBid = board.bid(_terms(address(nft), address(quoteToken), true, 2));

        // The mismatch is invisible to the quote, which is why it had to be
        // screened in the batch loop rather than folded into `_quote`.
        (bool takeable,) = board.quoteHit(nftBid, 1);
        assertTrue(takeable, "NFT bids still quote");

        uint256[] memory ids = new uint256[](2);
        uint128[] memory gives = new uint128[](2);
        uint256[] memory mins = new uint256[](2);
        (ids[0], gives[0]) = (nftBid, 1);
        (ids[1], gives[1]) = (live, 100e18);

        vm.prank(seller);
        (bool[] memory hits, uint256[] memory paid) = board.tryHitMany(ids, gives, mins);

        assertFalse(hits[0], "NFT leg skipped");
        assertEq(paid[0], 0, "nothing paid on the skipped leg");
        assertTrue(hits[1], "fungible leg still landed");
        assertEq(want.balanceOf(bidder), 100e18, "the good leg delivered");
        assertEq(board.escrowed(address(quoteToken)), END * 2 - paid[1], "NFT escrow untouched");
    }

    /// The whole point of the `try` variant: a stale leg is skipped, not fatal.
    function test_tryHitManySkipsStaleLegsAndReportsWhichLanded() public {
        uint256 live = _bid();
        uint256 cancelled = _bid();
        uint256 tooExpensive = _bid();

        vm.prank(bidder);
        board.cancel(cancelled);

        uint256[] memory ids = new uint256[](4);
        uint128[] memory gives = new uint128[](4);
        uint256[] memory mins = new uint256[](4);
        (ids[0], gives[0]) = (live, 100e18);
        (ids[1], gives[1]) = (cancelled, 100e18); // closed
        (ids[2], gives[2]) = (tooExpensive, 100e18);
        mins[2] = type(uint256).max; // priced out of its own bound
        (ids[3], gives[3]) = (live, type(uint128).max); // more than remains

        vm.prank(seller);
        (bool[] memory hits,) = board.tryHitMany(ids, gives, mins);

        assertTrue(hits[0], "live leg landed");
        assertFalse(hits[1], "closed bid skipped");
        assertFalse(hits[2], "min-proceeds miss skipped");
        assertFalse(hits[3], "oversized give skipped");
    }

    // ------------------------------------------------------- GUARD RAILS

    function test_reentrancyGuardHoldsWhilePayingTheSeller() public {
        ReenteringQuote rq = new ReenteringQuote();
        rq.mint(address(this), 1_000_000e18);
        rq.approve(address(board), type(uint256).max);
        uint256 id = board.bidFor(bidder, _terms(address(want), address(rq), false, WANT));

        rq.arm(board, id);
        vm.prank(seller);
        board.hit(id, 100e18, 0, false);
        assertTrue(rq.reentryRefused(), "the board refused the reentrant cancel");
    }

    function test_feeOnTransferQuoteIsRefusedAtBidTime() public {
        FeeToken fee = new FeeToken();
        fee.mint(address(this), 1_000_000e18);
        fee.approve(address(board), type(uint256).max);

        vm.expectRevert();
        board.bidFor(bidder, _terms(address(want), address(fee), false, WANT));
    }

    function test_feeOnTransferAssetIsRefusedAtHitTime() public {
        FeeToken fee = new FeeToken();
        fee.mint(seller, 1_000_000e18);
        vm.prank(seller);
        fee.approve(address(board), type(uint256).max);

        uint256 id = board.bidFor(bidder, _terms(address(fee), address(quoteToken), false, WANT));
        vm.prank(seller);
        vm.expectRevert();
        board.hit(id, 100e18, 0, false);
    }

    function test_bidCannotTargetTheBoardsOwnReceipts() public {
        Floorboard.Terms memory t = _terms(address(board), address(quoteToken), true, 1);
        vm.expectRevert(Floorboard.Bad.selector);
        board.bidFor(bidder, t);
    }

    function test_erc721QuoteIsRefused() public {
        Declaring721 collection = new Declaring721();
        Floorboard.Terms memory t = _terms(address(want), address(collection), false, WANT);
        vm.expectRevert(Floorboard.Bad.selector);
        board.bidFor(bidder, t);
    }

    function test_receiptCannotBeTransferredToTheBoardOrWeth() public {
        uint256 id = _bid();
        vm.startPrank(bidder);
        vm.expectRevert(Floorboard.Bad.selector);
        board.transferFrom(bidder, address(board), id);
        vm.expectRevert(Floorboard.Bad.selector);
        board.transferFrom(bidder, address(weth), id);
        vm.stopPrank();
    }

    // ----------------------------------------------------------- ETH PATHS

    function test_cancelUnwrapReturnsEscrowAsNativeETH() public {
        vm.deal(bidder, 10 ether);
        Floorboard.Terms memory t = _terms(address(want), address(0), false, WANT);
        t.startPrice = 1 ether;
        t.endPrice = 2 ether;

        vm.prank(bidder);
        uint256 id = board.bid{value: 2 ether}(t);
        assertEq(weth.balanceOf(address(board)), 2 ether, "ceiling wrapped");

        uint256 before = bidder.balance;
        vm.prank(bidder);
        board.cancelUnwrap(id);
        assertEq(bidder.balance - before, 2 ether, "returned as native ETH");
    }

    function test_withdrawCanTakeItsRefundAsNativeETH() public {
        vm.deal(bidder, 10 ether);
        Floorboard.Terms memory t = _terms(address(want), address(0), false, WANT);
        t.startPrice = 1 ether;
        t.endPrice = 2 ether;

        vm.prank(bidder);
        uint256 id = board.bid{value: 2 ether}(t);

        uint256 before = bidder.balance;
        vm.prank(bidder);
        board.withdraw(id, WANT / 2, true);
        assertEq(bidder.balance - before, 1 ether, "half the ceiling came back as ETH");
    }

    function test_cancelUnwrapRefusesATokenQuotedBid() public {
        uint256 id = _bid();
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(Floorboard.NotWETH.selector, address(weth), address(quoteToken)));
        board.cancelUnwrap(id);
    }

    // ---------------------------------------------------------------- VIEWS

    function test_legOfReportsLiveTermsAndZeroesAClosedBid() public {
        uint256 id = _bid();
        (address who, address token, address q, bool isNFT, uint128 remaining, uint128 initial, uint256 price) = board.legOf(id);
        assertEq(who, bidder);
        assertEq(token, address(want));
        assertEq(q, address(quoteToken));
        assertFalse(isNFT);
        assertEq(remaining, WANT);
        assertEq(price, START, "opens at startPrice");

        vm.prank(bidder);
        board.cancel(id);
        (who, token, q,, remaining, initial, price) = board.legOf(id);
        assertEq(who, address(0), "closed bids report nothing");
        assertEq(token, address(0));
        assertEq(remaining, 0);
        assertEq(price, 0);
    }

    /// `bidFor` funds from the caller but assigns every right to the bidder.
    function test_bidForFundsFromCallerAndVestsRightsInBidder() public {
        uint256 mine = quoteToken.balanceOf(address(this));
        uint256 id = board.bidFor(bidder, _terms(address(want), address(quoteToken), false, WANT));

        assertEq(quoteToken.balanceOf(address(this)), mine - END, "sponsor paid the ceiling");
        assertEq(board.ownerOf(id), bidder, "receipt to the bidder");

        // The sponsor has no rights over it.
        vm.expectRevert(Floorboard.NotBidder.selector);
        board.cancel(id);

        vm.prank(bidder);
        board.cancel(id);
        assertEq(quoteToken.balanceOf(bidder), 1_000_000e18 + END, "refund went to the bidder");
    }
}
