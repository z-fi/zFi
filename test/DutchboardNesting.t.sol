// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @notice H-01 and H-02 from `audit/Dutchboard/gpt56-sol-pro.md`, exercised with
///         two real Dutchboards rather than a mock.
///
/// @dev Two boards is the sharpest form of the test. A DBPOS is a live position by
///      construction, so board B escrowing board A's receipt reproduces H-02
///      exactly — and because A settles into B, the same fixture also produces the
///      settlement-while-escrowed event that H-01 is about. No Swapboard needed.
contract DutchboardNestingTest is Test {
    Dutchboard boardA;
    Dutchboard boardB;
    MockWETH weth;
    MockERC20 lot;
    MockERC20 quote;
    MockERC20 outerQuote;

    address alice = address(0xA11CE); // owns the inner listing, then its receipt
    address innerBuyer = address(0x1);
    address outerBuyer = address(0x2);

    function setUp() public {
        weth = new MockWETH();
        boardA = new Dutchboard(address(weth));
        boardB = new Dutchboard(address(weth));
        lot = new MockERC20("LOT", 18);
        quote = new MockERC20("Q", 18);
        outerQuote = new MockERC20("OQ", 18);

        lot.mint(alice, 1_000e18);
        quote.mint(innerBuyer, 1_000_000e18);
        outerQuote.mint(outerBuyer, 1_000_000e18);

        vm.prank(alice);
        lot.approve(address(boardA), type(uint256).max);
        vm.prank(innerBuyer);
        quote.approve(address(boardA), type(uint256).max);
        vm.prank(outerBuyer);
        outerQuote.approve(address(boardB), type(uint256).max);
    }

    /// @dev Inner listing on A quoted in `innerQuote`, its receipt then escrowed
    ///      as an NFT lot on B.
    function _nest(address innerQuote) internal returns (uint256 aId, uint256 bId) {
        vm.startPrank(alice);
        aId = boardA.listERC20(address(lot), innerQuote, 100e18, 10e18, 10e18, 0, uint40(1 days));
        boardA.setApprovalForAll(address(boardB), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = aId;
        bId = boardB.listNFT(address(boardA), address(outerQuote), ids, 50e18, 50e18, 0, uint40(1 days));
        vm.stopPrank();

        assertEq(boardA.ownerOf(aId), address(boardB), "receipt escrowed on B");
        (address storedSeller,,,,,,,,,,) = boardA.listings(aId);
        assertEq(storedSeller, address(boardB), "A's seller followed the receipt");
    }

    // ------------------------------------------------------------------- H-02

    /// @dev Pre-patch, A paid its ERC-20 quote straight to B and B had no idea:
    ///      the balance arrived with no `claimableProceeds` entry and no way out.
    function test_H02_erc20ProceedsOfANestedListingAreAttributedAndRecoverable() public {
        (uint256 aId, uint256 bId) = _nest(address(quote));

        vm.prank(innerBuyer);
        boardA.fill(aId, 100e18, innerBuyer, type(uint256).max);

        uint256 credited = boardB.claimableProceeds(bId, address(quote));
        assertEq(credited, 10e18, "B attributed the payment to the right receipt");
        assertEq(boardB.totalClaimable(address(quote)), 10e18);
        assertEq(quote.balanceOf(address(boardB)), 10e18);

        vm.prank(alice);
        uint256 got = boardB.claimSurplus(bId, address(quote), alice);
        assertEq(got, 10e18);
        assertEq(quote.balanceOf(alice), 10e18, "recoverable, not stranded");
        assertEq(boardB.totalClaimable(address(quote)), 0);
    }

    /// @dev Pre-patch, a native-ETH inner listing did not merely strand the
    ///      proceeds — it reverted the inner fill outright, because B's `receive`
    ///      accepts ETH only from WETH. Now the leg is wrapped and attributed.
    function test_H02_nativeETHProceedsAreWrappedRatherThanBounced() public {
        (uint256 aId, uint256 bId) = _nest(address(0));

        vm.deal(innerBuyer, 100e18);
        vm.prank(innerBuyer);
        boardA.fill{value: 10e18}(aId, 100e18, innerBuyer, type(uint256).max);

        assertEq(boardB.claimableProceeds(bId, address(weth)), 10e18, "delivered as WETH and credited");
        assertEq(weth.balanceOf(address(boardB)), 10e18);
        assertEq(address(boardB).balance, 0, "no unattributable native dust");

        vm.prank(alice);
        boardB.claimSurplus(bId, address(weth), alice);
        assertEq(weth.balanceOf(alice), 10e18);
    }

    /// @dev An ordinary seller must be unaffected by the new callback probe.
    function test_H02_ordinarySellersStillReceiveNativeETH() public {
        vm.prank(alice);
        uint256 id = boardA.listERC20(address(lot), address(0), 100e18, 10e18, 10e18, 0, uint40(1 days));

        vm.deal(innerBuyer, 100e18);
        uint256 before = alice.balance;
        vm.prank(innerBuyer);
        boardA.fill{value: 10e18}(id, 100e18, innerBuyer, type(uint256).max);

        assertEq(alice.balance - before, 10e18, "plain ETH, not WETH");
        assertEq(weth.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------- H-01

    /// @dev The front-run: settle the underlying immediately before the outer fill.
    ///      Pre-patch the outer listing stayed quotable and the buyer paid full
    ///      price for a spent receipt while the seller kept the proceeds.
    function test_H01_settlementFreezesTheOuterListingBeforeItCanBeBought() public {
        (uint256 aId, uint256 bId) = _nest(address(quote));

        (bool fillableBefore,) = boardB.quoteFill(bId, 1);
        assertTrue(fillableBefore, "quotable while the underlying is live");

        vm.prank(innerBuyer);
        boardA.fill(aId, 100e18, innerBuyer, type(uint256).max);

        assertTrue(boardB.frozen(bId), "frozen on settlement");

        (bool fillableAfter, uint256 cost) = boardB.quoteFill(bId, 1);
        assertFalse(fillableAfter, "no longer quotable");
        assertEq(cost, 0);
        (,,,,,, uint256 legPrice) = boardB.legOf(bId);
        assertEq(legPrice, 0, "and invisible to routers");
        (uint128 take,) = boardB.takeFor(bId, type(uint256).max);
        assertEq(take, 0);

        vm.prank(outerBuyer);
        vm.expectRevert(Dutchboard.Bad.selector);
        boardB.fill(bId, 1, outerBuyer, type(uint256).max);
    }

    /// @dev A frozen listing skips rather than reverting a whole route.
    function test_H01_frozenLegIsSkippedByTryFillMany() public {
        (uint256 aId, uint256 bId) = _nest(address(quote));
        vm.prank(innerBuyer);
        boardA.fill(aId, 100e18, innerBuyer, type(uint256).max);

        uint256[] memory ids = new uint256[](1);
        uint128[] memory takes = new uint128[](1);
        uint256[] memory maxCosts = new uint256[](1);
        (ids[0], takes[0], maxCosts[0]) = (bId, 1, type(uint256).max);

        vm.prank(outerBuyer);
        (bool[] memory filled,) = boardB.tryFillMany(ids, takes, maxCosts, outerBuyer);
        assertFalse(filled[0], "skipped, not reverted");
    }

    /// @dev Freezing must not strand anything: the seller can still recover the
    ///      changed position AND the proceeds it threw off. This is why the fix
    ///      freezes rather than closes.
    function test_H01_sellerRecoversBothThePositionAndTheProceeds() public {
        (uint256 aId, uint256 bId) = _nest(address(quote));
        vm.prank(innerBuyer);
        boardA.fill(aId, 100e18, innerBuyer, type(uint256).max);

        vm.startPrank(alice);
        boardB.cancel(bId);
        boardB.claimSurplus(bId, address(quote), alice);
        vm.stopPrank();

        assertEq(boardA.ownerOf(aId), alice, "spent receipt returned");
        assertEq(quote.balanceOf(alice), 10e18, "proceeds claimed");
    }

    /// @dev A partial settlement freezes too — the reported attack works as well
    ///      by draining most of the underlying as by spending all of it — and later
    ///      partials keep crediting the same receipt instead of stranding.
    function test_H01_partialSettlementFreezesAndLaterPartialsStillCredit() public {
        (uint256 aId, uint256 bId) = _nest(address(quote));

        vm.prank(innerBuyer);
        boardA.fill(aId, 40e18, innerBuyer, type(uint256).max);
        assertTrue(boardB.frozen(bId), "frozen on the first partial");
        uint256 afterFirst = boardB.claimableProceeds(bId, address(quote));
        assertGt(afterFirst, 0);

        vm.prank(innerBuyer);
        boardA.fill(aId, 60e18, innerBuyer, type(uint256).max);
        assertGt(boardB.claimableProceeds(bId, address(quote)), afterFirst, "still crediting after the freeze");

        vm.prank(alice);
        boardB.claimSurplus(bId, address(quote), alice);
        assertEq(quote.balanceOf(address(boardB)), 0, "nothing stranded");
    }
}
