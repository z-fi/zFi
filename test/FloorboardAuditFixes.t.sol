// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// A contract holder that opts into the proceeds accounting and can close its
/// own bid, so the `cancelUnwrap` refund path can be observed from the inside.
contract ClosingHolder {
    uint256 public beforeCalls;
    uint256 public afterCalls;
    address public lastToken;
    uint256 public lastAmount;

    function acceptsOrderProceeds(uint256) external pure returns (bool) {
        return true;
    }

    function beforeOrderProceeds(uint256, address token, uint256 amount, bool) external returns (bool) {
        ++beforeCalls;
        (lastToken, lastAmount) = (token, amount);
        return true;
    }

    function afterOrderProceeds(uint256, address, uint256, bool) external {
        ++afterCalls;
    }

    function close(Floorboard board, uint256 id) external {
        board.cancelUnwrap(id);
    }

    receive() external payable {}
}

/// Covers the behaviour changes made in response to the Floorboard audit:
/// the NFT self-hit refusal, duplicate `Terms.ids` rejection, `unwrap`
/// validated at entry, `cancelUnwrap` bracketed by the proceeds callbacks, and
/// `initial` in `legOf`.
contract FloorboardAuditFixesTest is Test {
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
        // `END` is 200e18, which on the ETH-quoted path is 200 ether of escrow.
        vm.deal(address(this), 1000 ether);

        vm.prank(bidder);
        quoteToken.approve(address(board), type(uint256).max);
        quoteToken.approve(address(board), type(uint256).max);
        vm.prank(seller);
        want.approve(address(board), type(uint256).max);
    }

    function _terms(address token, address quote, bool isNFT, uint128 w, uint256[] memory ids)
        internal
        pure
        returns (Floorboard.Terms memory)
    {
        return Floorboard.Terms({
            token: token,
            quote: quote,
            want: w,
            startPrice: START,
            endPrice: END,
            startTime: 0,
            duration: DUR,
            isNFT: isNFT,
            ids: ids
        });
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    // ------------------------------------------------- NFT SELF-HIT REFUSED

    /// A self-hit on the NFT path delivers nothing: seller and holder are the
    /// same address, so `_moveNFT` is a no-op that passes its own checks. The
    /// escrow would drain against a token the hitter keeps.
    function test_nftSelfHitIsRefused() public {
        vm.prank(bidder);
        uint256 id = board.bid(_terms(address(nft), address(quoteToken), true, 2, new uint256[](0)));

        nft.mint(bidder, 1);
        vm.startPrank(bidder);
        nft.setApprovalForAll(address(board), true);
        vm.expectRevert(Floorboard.Bad.selector);
        board.hitNFT(id, _ids(1), 0, false);
        vm.stopPrank();

        assertEq(board.getBid(id).remaining, 2, "nothing settled");
        assertEq(board.escrowed(address(quoteToken)), END, "escrow untouched");
    }

    /// The refusal must not cost an arm's-length seller anything.
    function test_thirdPartyNftHitStillSettles() public {
        vm.prank(bidder);
        uint256 id = board.bid(_terms(address(nft), address(quoteToken), true, 2, new uint256[](0)));

        nft.mint(seller, 7);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(board), true);
        uint256 paid = board.hitNFT(id, _ids(7), 0, false);
        vm.stopPrank();

        assertEq(nft.ownerOf(7), bidder, "delivered to the holder");
        assertEq(paid, START / 2, "half the lot at the opening price");
        assertEq(board.getBid(id).remaining, 1);
    }

    /// The old per-call scan could not see across calls; the refusal can.
    function test_selfHitCannotRepayForOneTokenAcrossCalls() public {
        vm.prank(bidder);
        uint256 id = board.bid(_terms(address(nft), address(quoteToken), true, 2, new uint256[](0)));

        nft.mint(bidder, 3);
        vm.startPrank(bidder);
        nft.setApprovalForAll(address(board), true);
        vm.expectRevert(Floorboard.Bad.selector);
        board.hitNFT(id, _ids(3), 0, false);
        vm.expectRevert(Floorboard.Bad.selector);
        board.hitNFT(id, _ids(3), 0, false);
        vm.stopPrank();

        assertEq(quoteToken.balanceOf(bidder), 1_000_000e18 - END, "no escrow leaked back out");
    }

    // ------------------------------------------------ DUPLICATE IDS AT OPEN

    /// `[1,1]` with `want = 2` reads as a two-token bid and is fillable only
    /// once, so the set is rejected at creation rather than left to strand.
    function test_duplicateAllowedIdsAreRejected() public {
        uint256[] memory dupes = new uint256[](2);
        dupes[0] = 1;
        dupes[1] = 1;
        vm.prank(bidder);
        vm.expectRevert(Floorboard.Bad.selector);
        board.bid(_terms(address(nft), address(quoteToken), true, 2, dupes));
    }

    function test_distinctAllowedIdsStillOpen() public {
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (1, 2, 3);
        vm.prank(bidder);
        uint256 id = board.bid(_terms(address(nft), address(quoteToken), true, 2, ids));
        assertEq(board.getBid(id).ids.length, 3, "the named set survives");
    }

    // ------------------------------------------------- UNWRAP CHECKED EARLY

    /// `unwrap` on a bid that is not WETH-quoted is knowable at entry, so it
    /// reverts before the seller pays for a whole settlement.
    function test_unwrapOnANonWethBidRevertsAtEntry() public {
        vm.prank(bidder);
        uint256 id = board.bid(_terms(address(want), address(quoteToken), false, WANT, new uint256[](0)));

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(Floorboard.NotWETH.selector, address(weth), address(quoteToken))
        );
        board.hit(id, 100e18, 0, true);

        assertEq(want.balanceOf(bidder), 0, "no asset moved");
        assertEq(board.getBid(id).remaining, WANT);
    }

    // ------------------------------------- cancelUnwrap PAYS AN ESCROW IN WETH

    /// The ETH refund path once skipped the callbacks entirely, so an escrow
    /// contract saw a `cancelUnwrap` refund as an unexplained balance. It was
    /// then bracketed as `address(0)` - which named the native asset
    /// consistently but handed counterparties an address their callbacks cannot
    /// use: Dutchboard's `beforeOrderProceeds` reaches `_freeBalance(address(0))`
    /// and reverts on the decode, so `cancelUnwrap` was unusable for exactly the
    /// holders the bracket existed to serve.
    ///
    /// An opted-in holder is now paid in canonical WETH instead - the token its
    /// accounting already tracks - which is the same choice Dutchboard's
    /// `_payQuoteETH` makes. `unwrap` is a request, not a guarantee.
    function test_cancelUnwrapPaysAnOptedInHolderInWETH() public {
        ClosingHolder holder = new ClosingHolder();
        uint256 id = board.bidFor{value: END}(
            address(holder), _terms(address(want), address(0), false, WANT, new uint256[](0))
        );

        holder.close(board, id);

        assertEq(holder.beforeCalls(), 1, "before fired on the refund");
        assertEq(holder.afterCalls(), 1, "and after");
        assertEq(holder.lastToken(), address(weth), "a token the escrow can account for");
        assertEq(holder.lastAmount(), END, "the whole unspent ceiling");
        assertEq(weth.balanceOf(address(holder)), END, "paid as WETH");
        assertEq(address(holder).balance, 0, "and not as native value");
        assertEq(board.escrowed(address(weth)), 0, "escrow cleared");
    }

    /// A holder that does NOT opt into proceeds accounting still gets what
    /// `cancelUnwrap` says on the tin: native ETH, and no callbacks.
    function test_cancelUnwrapStillPaysNativeEthToAPlainBidder() public {
        vm.deal(bidder, END);
        vm.prank(bidder);
        uint256 id = board.bid{value: END}(_terms(address(want), address(0), false, WANT, new uint256[](0)));

        uint256 before = bidder.balance;
        vm.prank(bidder);
        board.cancelUnwrap(id);

        assertEq(bidder.balance - before, END, "paid as ETH");
        assertEq(weth.balanceOf(bidder), 0, "not as WETH");
        assertEq(board.escrowed(address(weth)), 0, "escrow cleared");
    }

    /// `cancel` on the same bid keeps paying WETH, and keeps its brackets.
    function test_plainCancelStillPaysTheQuoteToken() public {
        ClosingHolder holder = new ClosingHolder();
        uint256 id = board.bidFor{value: END}(
            address(holder), _terms(address(want), address(0), false, WANT, new uint256[](0))
        );

        vm.prank(address(holder));
        board.cancel(id);

        assertEq(holder.lastToken(), address(weth), "WETH, not native");
        assertEq(weth.balanceOf(address(holder)), END);
        assertEq(address(holder).balance, 0);
    }

    // --------------------------------------------------- legOf REPORTS initial

    /// `price` is the bid for the FULL INITIAL LOT, so a leg cannot be sized
    /// without `initial` once the bid has been partly filled.
    function test_legOfReportsInitialAfterAPartialFill() public {
        vm.prank(bidder);
        uint256 id = board.bid(_terms(address(want), address(quoteToken), false, WANT, new uint256[](0)));

        vm.prank(seller);
        board.hit(id, WANT / 4, 0, false);

        (,,,, uint128 remaining, uint128 initial, uint256 price) = board.legOf(id);
        assertEq(remaining, WANT - WANT / 4, "three quarters left");
        assertEq(initial, WANT, "the denominator every payment divides by");

        // The leg an executor would size from this read matches what it pays.
        (, uint256 quoted) = board.quoteHit(id, remaining);
        assertEq(quoted, (price * remaining) / initial, "price is the full-lot bid");
    }
}
