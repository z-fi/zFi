// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";

/// @dev `quoteOf`/`tokenOf` were removed from Dutchboard: `legOf` supersedes
///      them for live listings, and the optimizer inlining their dispatch was
///      part of what put the contract over EIP-170. These read the raw fields,
///      which is what the old getters did - `legOf` reports zeroes for a closed
///      listing and so cannot stand in where a test inspects a dead slot.
function _quoteOf(Dutchboard b, uint256 id) view returns (address q) {
    (,,,,,, q,,,,) = b.listings(id);
}

function _tokenOf(Dutchboard b, uint256 id) view returns (address t) {
    (,,,, t,,,,,,) = b.listings(id);
}


contract FuzzERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Property tests for Dutchboard's pricing and settlement arithmetic. The
///         properties that matter are the ones that make decay and partial fills safe
///         together: the schedule is monotone and time-only, cost prorates off `initial`
///         so fill history cannot move it, and ceiling division never lets a positive
///         price round to a free fill.
contract DutchboardFuzzTest is Test {
    Dutchboard board;
    FuzzERC20 lot; // the asset being sold
    FuzzERC20 quote; // the asset the seller is paid in

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");

    function setUp() public {
        board = new Dutchboard(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        lot = new FuzzERC20();
        quote = new FuzzERC20();
        // The fork's CREATE address can hold real mainnet dust; start from a clean slate
        // so ETH-path assertions are about this contract's behaviour alone.
        vm.deal(address(board), 0);
    }

    function _list(uint128 amount, uint256 sp, uint256 ep, uint40 dur, address quoteAsset)
        internal
        returns (uint256 id)
    {
        lot.mint(maker, amount);
        vm.startPrank(maker);
        lot.approve(address(board), amount);
        id = board.listERC20(address(lot), quoteAsset, amount, sp, ep, 0, dur, 0);
        vm.stopPrank();
    }

    /// Bounded, always-valid listing parameters.
    function _bounded(uint128 amount, uint96 sp, uint96 ep, uint40 dur)
        internal
        pure
        returns (uint128, uint256, uint256, uint40)
    {
        amount = uint128(bound(amount, 1, 1_000_000e18));
        uint256 s = bound(uint256(sp), 1, uint256(type(uint96).max));
        uint256 e = bound(uint256(ep), 0, s);
        dur = uint40(bound(dur, 1, 365 days));
        return (amount, s, e, dur);
    }

    // ------------------------------------------------------------------- PRICING

    /// The schedule never rises. This is what stops a pending fill being repriced
    /// against a taker, and it holds regardless of when it is sampled.
    function testFuzz_priceMonotoneNonIncreasing(uint128 amount, uint96 sp, uint96 ep, uint40 dur, uint32 dt1, uint32 dt2)
        public
    {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, ep, dur);
        uint256 id = _list(amt, s, e, d, address(quote));

        skip(bound(dt1, 0, 400 days));
        uint256 p1 = board.priceOf(id);
        skip(bound(dt2, 0, 400 days));
        uint256 p2 = board.priceOf(id);

        assertLe(p2, p1, "price rose");
        assertLe(p1, s, "price above startPrice");
        assertGe(p2, e, "price below endPrice");
    }

    /// Flat before start, flat after the window closes, strictly inside otherwise.
    function testFuzz_priceClampsOutsideWindow(uint128 amount, uint96 sp, uint96 ep, uint40 dur, uint32 over) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, ep, dur);
        uint256 id = _list(amt, s, e, d, address(quote));

        assertEq(board.priceOf(id), s, "does not open at startPrice");
        skip(uint256(d) + bound(over, 0, 400 days));
        assertEq(board.priceOf(id), e, "does not settle at endPrice");
    }

    // ---------------------------------------------------------------------- COST

    /// A positive price can never round to a free fill, however small the take and
    /// however large `initial`. This is the whole reason for ceiling division.
    function testFuzz_costNeverZeroForPositivePrice(uint128 amount, uint96 sp, uint128 take, uint32 dt) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, 1, 30 days);
        uint256 id = _list(amt, s, e, d, address(quote));
        skip(bound(dt, 0, uint256(d)));

        take = uint128(bound(take, 1, amt));
        uint256 price = board.priceOf(id);
        vm.assume(price > 0);
        assertGt(board.costOf(id, take), 0, "positive price rounded to a free fill");
    }

    /// Taking the whole lot costs exactly the lot price; anything less costs less.
    function testFuzz_costBoundedByLotPrice(uint128 amount, uint96 sp, uint96 ep, uint128 take, uint32 dt) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, ep, dur_(dt));
        uint256 id = _list(amt, s, e, d, address(quote));
        skip(bound(dt, 0, uint256(d)));

        uint256 price = board.priceOf(id);
        assertEq(board.costOf(id, amt), price, "full take is not the lot price");

        take = uint128(bound(take, 1, amt));
        assertLe(board.costOf(id, take), price, "partial take costs more than the lot");
    }

    function dur_(uint32 seed) internal pure returns (uint40) {
        return uint40(bound(seed, 1, 30 days));
    }

    /// Cost is non-decreasing in take at a fixed instant.
    function testFuzz_costMonotoneInTake(uint128 amount, uint96 sp, uint128 t1, uint128 t2, uint32 dt) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, 0, 30 days);
        uint256 id = _list(amt, s, e, d, address(quote));
        skip(bound(dt, 0, uint256(d)));

        uint128 a = uint128(bound(t1, 1, amt));
        uint128 b = uint128(bound(t2, 1, amt));
        if (a > b) (a, b) = (b, a);
        assertLe(board.costOf(id, a), board.costOf(id, b), "cost fell as take grew");
    }

    /// `costOf` returns 0 exactly where a fill would revert, so a UI can rely on it.
    function testFuzz_costOfZeroIffNonFillable(uint128 amount, uint96 sp, uint128 take) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, 0, 30 days);
        uint256 id = _list(amt, s, e, d, address(quote));

        assertEq(board.costOf(id, 0), 0, "take=0 should be non-fillable");
        take = uint128(bound(take, uint256(amt) + 1, uint256(type(uint128).max)));
        assertEq(board.costOf(id, take), 0, "take>remaining should be non-fillable");
        assertEq(board.costOf(id + 1, 1), 0, "unknown id should be non-fillable");
    }

    // --------------------------------------------------------------- SETTLEMENT

    /// The core invariant: cost equals the schedule prorated off `initial`, no matter
    /// how much of the lot has already been taken.
    function testFuzz_unitPriceIndependentOfFillHistory(uint128 amount, uint96 sp, uint128 firstTake, uint32 dt)
        public
    {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, 0, 30 days);
        vm.assume(amt > 1);
        uint256 id = _list(amt, s, e, d, address(quote));

        uint128 take1 = uint128(bound(firstTake, 1, amt - 1));
        quote.mint(taker, type(uint128).max);
        vm.startPrank(taker);
        quote.approve(address(board), type(uint256).max);

        skip(bound(dt, 0, uint256(d)));
        uint256 c1 = board.costOf(id, take1);
        board.fill(id, take1, taker, type(uint256).max);

        // After a partial fill, cost is still priceOf x take / initial — `initial`,
        // not `remaining`, so the reference ratio survives.
        uint128 rest = amt - take1;
        uint256 price = board.priceOf(id);
        assertEq(board.costOf(id, rest), (price * rest + amt - 1) / amt, "cost drifted after a partial fill");
        vm.stopPrank();
        c1;
    }

    /// Escrow is conserved across a sequence of partial fills: what left the board is
    /// exactly what takers received, and `remaining` tracks it.
    function testFuzz_partialFillsConserveEscrow(uint128 amount, uint96 sp, uint8 chunks) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, 0, 30 days);
        uint256 n = bound(uint256(chunks), 1, 10);
        vm.assume(amt >= n);
        uint256 id = _list(amt, s, e, d, address(quote));

        uint128 per = uint128(amt / n);
        quote.mint(taker, type(uint128).max);
        vm.startPrank(taker);
        quote.approve(address(board), type(uint256).max);

        uint128 taken;
        for (uint256 i; i < n; ++i) {
            board.fill(id, per, taker, type(uint256).max);
            taken += per;
            assertEq(lot.balanceOf(taker), taken, "taker balance drifted");
            assertEq(lot.balanceOf(address(board)), amt - taken, "escrow drifted");
            if (taken < amt) assertEq(board.getListing(id).remaining, amt - taken, "remaining drifted");
        }
        vm.stopPrank();
    }

    /// Splitting a fill can only ever cost the taker more, never less — ceiling
    /// division rounds toward the seller on every chunk. Bounded by one wei per chunk.
    function testFuzz_splittingNeverUnderpaysSeller(uint128 amount, uint96 sp, uint8 chunks) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, 0, 30 days);
        uint256 n = bound(uint256(chunks), 2, 10);
        vm.assume(amt >= n && amt % n == 0);
        uint256 id = _list(amt, s, e, d, address(quote));

        uint256 lotPrice = board.priceOf(id);
        uint128 per = uint128(amt / n);

        quote.mint(taker, type(uint128).max);
        vm.startPrank(taker);
        quote.approve(address(board), type(uint256).max);
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            paid += board.costOf(id, per);
            board.fill(id, per, taker, type(uint256).max);
        }
        vm.stopPrank();

        assertGe(paid, lotPrice, "split fills underpaid the seller");
        assertLe(paid - lotPrice, n, "rounding drift exceeded one wei per chunk");
        assertEq(quote.balanceOf(maker), paid, "seller received exactly what was paid");
    }

    /// The board never custodies the quote asset: payment goes straight to the seller.
    function testFuzz_boardNeverHoldsQuote(uint128 amount, uint96 sp, uint128 take, uint32 dt) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, 0, 30 days);
        uint256 id = _list(amt, s, e, d, address(quote));
        skip(bound(dt, 0, uint256(d)));

        take = uint128(bound(take, 1, amt));
        uint256 cost = board.costOf(id, take);
        quote.mint(taker, cost);
        vm.startPrank(taker);
        quote.approve(address(board), cost);
        board.fill(id, take, taker, type(uint256).max);
        vm.stopPrank();

        assertEq(quote.balanceOf(address(board)), 0, "board custodied the quote asset");
        assertEq(quote.balanceOf(maker), cost, "seller was not paid in full");
    }

    /// maxCost is honoured exactly: any bound at or above cost succeeds, any below reverts.
    function testFuzz_maxCostRespected(uint128 amount, uint96 sp, uint128 take, uint256 maxCost, uint32 dt) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, 0, 30 days);
        uint256 id = _list(amt, s, e, d, address(quote));
        skip(bound(dt, 0, uint256(d)));

        take = uint128(bound(take, 1, amt));
        uint256 cost = board.costOf(id, take);
        vm.assume(cost > 0);

        quote.mint(taker, type(uint128).max);
        vm.startPrank(taker);
        quote.approve(address(board), type(uint256).max);

        if (maxCost < cost) {
            vm.expectRevert(abi.encodeWithSelector(Dutchboard.CostExceeded.selector, cost, maxCost));
            board.fill(id, take, taker, maxCost);
        } else {
            board.fill(id, take, taker, maxCost);
            assertEq(quote.balanceOf(maker), cost, "paid something other than cost");
        }
        vm.stopPrank();
    }

    /// ETH-quoted fills forward cost and refund the rest, keeping no residue.
    function testFuzz_ethQuoteRefundsExcess(uint128 amount, uint96 sp, uint128 take, uint256 over, uint32 dt) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, 0, 30 days);
        uint256 id = _list(amt, s, e, d, address(0));
        skip(bound(dt, 0, uint256(d)));

        take = uint128(bound(take, 1, amt));
        uint256 cost = board.costOf(id, take);
        uint256 excess = bound(over, 0, 100 ether);

        vm.deal(taker, cost + excess);
        uint256 makerBefore = maker.balance;
        vm.prank(taker);
        board.fill{value: cost + excess}(id, take, taker, type(uint256).max);

        assertEq(maker.balance - makerBefore, cost, "seller not paid cost");
        assertEq(taker.balance, excess, "excess not refunded");
        assertEq(address(board).balance, 0, "board retained ETH");
    }

    /// Value attached to an ERC20-quoted fill would be stranded, so it is refused.
    function testFuzz_erc20QuoteRefusesValue(uint128 amount, uint96 sp, uint128 take, uint256 value) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, 0, 30 days);
        uint256 id = _list(amt, s, e, d, address(quote));
        take = uint128(bound(take, 1, amt));
        uint256 v = bound(value, 1, 100 ether);

        quote.mint(taker, type(uint128).max);
        vm.deal(taker, v);
        vm.startPrank(taker);
        quote.approve(address(board), type(uint256).max);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill{value: v}(id, take, taker, type(uint256).max);
        vm.stopPrank();
    }

    /// Cancel returns exactly the unsold remainder, never more.
    function testFuzz_cancelReturnsRemainder(uint128 amount, uint96 sp, uint128 take) public {
        (uint128 amt, uint256 s, uint256 e, uint40 d) = _bounded(amount, sp, 0, 30 days);
        vm.assume(amt > 1);
        uint256 id = _list(amt, s, e, d, address(quote));

        take = uint128(bound(take, 1, amt - 1));
        quote.mint(taker, type(uint128).max);
        vm.startPrank(taker);
        quote.approve(address(board), type(uint256).max);
        board.fill(id, take, taker, type(uint256).max);
        vm.stopPrank();

        vm.prank(maker);
        board.cancel(id);
        assertEq(lot.balanceOf(maker), amt - take, "remainder not returned");
        assertEq(lot.balanceOf(address(board)), 0, "escrow left behind");
        assertEq(board.priceOf(id), 0, "listing not closed");
    }

    // ------------------------------------------------------------------- LISTING

    /// A price a maker cannot express must be refused, never truncated into a
    /// silently-cheaper ask over an already-escrowed lot.
    function testFuzz_priceAboveCeilingReverts(uint128 amount, uint256 sp) public {
        uint128 amt = uint128(bound(amount, 1, 1_000_000e18));
        uint256 s = bound(sp, uint256(type(uint96).max) + 1, type(uint256).max);
        lot.mint(maker, amt);
        vm.startPrank(maker);
        lot.approve(address(board), amt);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(address(lot), address(quote), amt, s, 0, 0, 1 hours, 0);
        vm.stopPrank();
    }

    function testFuzz_startPriceBelowEndPriceReverts(uint128 amount, uint96 sp, uint96 ep) public {
        uint128 amt = uint128(bound(amount, 1, 1_000_000e18));
        uint256 s = bound(uint256(sp), 1, uint256(type(uint96).max) - 1);
        uint256 e = bound(uint256(ep), s + 1, uint256(type(uint96).max));
        lot.mint(maker, amt);
        vm.startPrank(maker);
        lot.approve(address(board), amt);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(address(lot), address(quote), amt, s, e, 0, 1 hours, 0);
        vm.stopPrank();
    }

    function testFuzz_startTimeInPastReverts(uint128 amount, uint40 startTime) public {
        uint128 amt = uint128(bound(amount, 1, 1_000_000e18));
        skip(1_000_000);
        uint40 st = uint40(bound(startTime, 1, block.timestamp - 1));
        lot.mint(maker, amt);
        vm.startPrank(maker);
        lot.approve(address(board), amt);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(address(lot), address(quote), amt, 1 ether, 0, st, 1 hours, 0);
        vm.stopPrank();
    }

    /// A future start holds the opening price flat until it opens.
    function testFuzz_futureStartHoldsOpeningPrice(uint128 amount, uint96 sp, uint40 delay, uint32 dt) public {
        uint128 amt = uint128(bound(amount, 1, 1_000_000e18));
        uint256 s = bound(uint256(sp), 1, uint256(type(uint96).max));
        uint40 wait_ = uint40(bound(delay, 1, 30 days));
        uint40 st = uint40(block.timestamp) + wait_;

        lot.mint(maker, amt);
        vm.startPrank(maker);
        lot.approve(address(board), amt);
        uint256 id = board.listERC20(address(lot), address(quote), amt, s, 0, st, 1 hours, 0);
        vm.stopPrank();

        skip(bound(dt, 0, uint256(wait_)));
        assertEq(board.priceOf(id), s, "price moved before the window opened");
    }

    // ------------------------------------------------------------------ FILLMANY

    // `fillMany` is the one place a single `msg.value` is exposed to several settlements,
    // and the guard is that `_settle` is bounded by UNSPENT value rather than msg.value.
    // The properties below are what that guard is supposed to buy.

    /// Build `n` alternating ETH- and ERC20-quoted listings of the same lot token.
    /// @return ids       listing ids, in batch order
    /// @return ethLegs   which of them are ETH-quoted
    function _mixedBatch(uint8 legs, uint96 sp, uint40 dur)
        internal
        returns (uint256[] memory ids, bool[] memory ethLegs, uint128[] memory takes)
    {
        uint256 n = bound(legs, 1, 8);
        ids = new uint256[](n);
        ethLegs = new bool[](n);
        takes = new uint128[](n);
        uint256 s = bound(uint256(sp), 1, 1e24);
        uint40 d = uint40(bound(dur, 1, 30 days));

        for (uint256 i; i < n; ++i) {
            bool isEth = i % 2 == 0;
            ethLegs[i] = isEth;
            uint128 amt = uint128(1_000e18 + i);
            ids[i] = _list(amt, s, 0, d, isEth ? address(0) : address(quote));
            takes[i] = amt;
        }
    }

    function _maxCosts(uint256 n) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = type(uint256).max;
        }
    }

    /// The core accounting property: across a mixed batch, the ETH forwarded to sellers
    /// is exactly the sum of the ETH-quoted legs' costs — never a multiple of it — and
    /// every unspent wei goes back to the taker.
    function testFuzz_fillManyCountsValueOnce(uint8 legs, uint96 sp, uint40 dur, uint256 over, uint32 dt) public {
        (uint256[] memory ids, bool[] memory ethLegs, uint128[] memory takes) = _mixedBatch(legs, sp, dur);
        skip(bound(dt, 0, 30 days));

        uint256 expectedEth;
        uint256 expectedQuote;
        for (uint256 i; i < ids.length; ++i) {
            uint256 c = board.costOf(ids[i], takes[i]);
            if (ethLegs[i]) expectedEth += c;
            else expectedQuote += c;
        }

        uint256 excess = bound(over, 0, 10 ether);
        quote.mint(taker, type(uint128).max);
        vm.deal(taker, expectedEth + excess);
        uint256 makerEthBefore = maker.balance;
        uint256 makerQuoteBefore = quote.balanceOf(maker);

        vm.startPrank(taker);
        quote.approve(address(board), type(uint256).max);
        uint256 spent =
            board.fillMany{value: expectedEth + excess}(ids, takes, _maxCosts(ids.length), taker);
        vm.stopPrank();

        assertEq(spent, expectedEth, "reported spend disagrees with the ETH legs");
        assertEq(maker.balance - makerEthBefore, expectedEth, "sellers over- or under-paid in ETH");
        assertEq(quote.balanceOf(maker) - makerQuoteBefore, expectedQuote, "ERC20 legs mispaid");
        assertEq(taker.balance, excess, "unspent value not refunded");
        assertEq(address(board).balance, 0, "board retained ETH");
    }

    /// One `msg.value` must not settle several ETH legs. Funding a batch one wei short of
    /// the ETH total has to fail rather than let a later leg reuse an earlier leg's value.
    function testFuzz_fillManyCannotReuseValueAcrossLegs(uint8 legs, uint96 sp, uint40 dur) public {
        (uint256[] memory ids, bool[] memory ethLegs, uint128[] memory takes) = _mixedBatch(legs, sp, dur);

        uint256 ethTotal;
        uint256 ethLegCount;
        for (uint256 i; i < ids.length; ++i) {
            if (ethLegs[i]) {
                ethTotal += board.costOf(ids[i], takes[i]);
                ++ethLegCount;
            }
        }
        vm.assume(ethTotal > 0);

        quote.mint(taker, type(uint128).max);
        vm.deal(taker, ethTotal);
        vm.startPrank(taker);
        quote.approve(address(board), type(uint256).max);
        vm.expectRevert(Dutchboard.Insufficient.selector);
        board.fillMany{value: ethTotal - 1}(ids, takes, _maxCosts(ids.length), taker);
        vm.stopPrank();

        // Nothing settled: every listing is still open and the taker still holds its ETH.
        for (uint256 i; i < ids.length; ++i) {
            assertEq(board.getListing(ids[i]).seller, maker, "a leg settled despite the revert");
        }
        assertEq(taker.balance, ethTotal, "taker debited by an aborted batch");
    }

    /// An all-ERC20 batch legitimately carries no ETH, but `fillMany` cannot reject value
    /// outright the way `fill` does — a mixed batch needs it. Whatever arrives unused must
    /// come back rather than strand on the board.
    function testFuzz_fillManyRefundsValueOnAllERC20Batch(uint8 legs, uint96 sp, uint256 value) public {
        uint256 n = bound(legs, 1, 6);
        uint256[] memory ids = new uint256[](n);
        uint128[] memory takes = new uint128[](n);
        uint256 s = bound(uint256(sp), 1, 1e24);
        for (uint256 i; i < n; ++i) {
            uint128 amt = uint128(1_000e18 + i);
            ids[i] = _list(amt, s, 0, 1 hours, address(quote));
            takes[i] = amt;
        }

        uint256 v = bound(value, 1, 100 ether);
        quote.mint(taker, type(uint128).max);
        vm.deal(taker, v);
        vm.startPrank(taker);
        quote.approve(address(board), type(uint256).max);
        uint256 spent = board.fillMany{value: v}(ids, takes, _maxCosts(n), taker);
        vm.stopPrank();

        assertEq(spent, 0, "ERC20-only batch reported an ETH spend");
        assertEq(taker.balance, v, "value stranded on an all-ERC20 batch");
        assertEq(address(board).balance, 0, "board retained ETH");
    }

    /// A batch is atomic: one leg breaching its own `maxCost` aborts everything.
    function testFuzz_fillManyIsAtomicOnMaxCostBreach(uint8 legs, uint96 sp, uint40 dur, uint8 badLeg) public {
        (uint256[] memory ids,, uint128[] memory takes) = _mixedBatch(legs, sp, dur);
        vm.assume(ids.length > 1);
        uint256 bad = bound(badLeg, 0, ids.length - 1);

        uint256[] memory maxCosts = _maxCosts(ids.length);
        uint256 badCost = board.costOf(ids[bad], takes[bad]);
        vm.assume(badCost > 0);
        maxCosts[bad] = badCost - 1;

        uint256 ethTotal;
        for (uint256 i; i < ids.length; ++i) {
            if (_quoteOf(board, ids[i]) == address(0)) ethTotal += board.costOf(ids[i], takes[i]);
        }

        quote.mint(taker, type(uint128).max);
        vm.deal(taker, ethTotal);
        vm.startPrank(taker);
        quote.approve(address(board), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Dutchboard.CostExceeded.selector, badCost, badCost - 1));
        board.fillMany{value: ethTotal}(ids, takes, maxCosts, taker);
        vm.stopPrank();

        for (uint256 i; i < ids.length; ++i) {
            assertEq(board.getListing(ids[i]).seller, maker, "a leg survived an aborted batch");
        }
    }

    /// Batching is not a discount: a mixed batch costs exactly what the same legs cost
    /// filled one at a time in the same block.
    function testFuzz_fillManyMatchesSequentialFills(uint8 legs, uint96 sp, uint40 dur, uint32 dt) public {
        (uint256[] memory idsA, bool[] memory ethA, uint128[] memory takesA) = _mixedBatch(legs, sp, dur);
        (uint256[] memory idsB,, uint128[] memory takesB) = _mixedBatch(legs, sp, dur);
        skip(bound(dt, 0, 30 days));

        quote.mint(taker, type(uint128).max);
        vm.prank(taker);
        quote.approve(address(board), type(uint256).max);

        // Batched.
        uint256 ethA_ = 0;
        for (uint256 i; i < idsA.length; ++i) {
            if (ethA[i]) ethA_ += board.costOf(idsA[i], takesA[i]);
        }
        vm.deal(taker, ethA_);
        uint256 makerEth0 = maker.balance;
        uint256 makerQuote0 = quote.balanceOf(maker);
        vm.prank(taker);
        board.fillMany{value: ethA_}(idsA, takesA, _maxCosts(idsA.length), taker);
        uint256 batchedEth = maker.balance - makerEth0;
        uint256 batchedQuote = quote.balanceOf(maker) - makerQuote0;

        // Sequential, same block, identical schedule.
        makerEth0 = maker.balance;
        makerQuote0 = quote.balanceOf(maker);
        for (uint256 i; i < idsB.length; ++i) {
            uint256 c = board.costOf(idsB[i], takesB[i]);
            bool isEth = _quoteOf(board, idsB[i]) == address(0);
            if (isEth) vm.deal(taker, c);
            vm.prank(taker);
            board.fill{value: isEth ? c : 0}(idsB[i], takesB[i], taker, type(uint256).max);
        }
        assertEq(maker.balance - makerEth0, batchedEth, "batching changed the ETH total");
        assertEq(quote.balanceOf(maker) - makerQuote0, batchedQuote, "batching changed the quote total");
    }
}
