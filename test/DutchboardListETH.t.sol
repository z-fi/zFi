// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

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


/// @notice Coverage for the native-ETH sell side.
///
/// @dev The board escrows tokens, never native balance, so `listETH` wraps at
///      the boundary and `cancelUnwrap` unwraps at the exit. These tests pin
///      that round trip: raw ETH in, raw ETH out, with a perfectly ordinary
///      WETH listing in between that every other code path already understands.
contract DutchboardListETHTest is Test {
    Dutchboard db;
    MockWETH weth;
    MockERC20 quote;

    address seller = address(0x5E11);
    address maker = address(0x4A4E);
    address buyer = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        db = new Dutchboard(address(weth));
        quote = new MockERC20("Q", 18);

        vm.deal(seller, 100 ether);
        vm.deal(maker, 100 ether);
        quote.mint(buyer, 1_000e18);
        vm.prank(buyer);
        quote.approve(address(db), type(uint256).max);
    }

    function _list(uint256 value) internal returns (uint256 id) {
        vm.prank(seller);
        id = db.listETH{value: value}(address(quote), 10e18, 10e18, 0, uint40(1 days), 0);
    }

    function test_listETHEscrowsWrappedValue() public {
        // These suites run against a mainnet fork (see `fork_block_number` in
        // foundry.toml), so a freshly deployed address can already hold dust
        // belonging to whatever lives there on chain - this board's address
        // carries 1 wei. "Retains no native balance" is a statement about what
        // THIS call leaves behind, so measure the delta rather than the total.
        uint256 boardEthBefore = address(db).balance;
        uint256 id = _list(5 ether);

        assertEq(_tokenOf(db, id), address(weth), "sold asset is canonical WETH");
        assertEq(_quoteOf(db, id), address(quote), "quote preserved");
        assertEq(db.ownerOf(id), seller, "receipt minted to the seller");
        assertEq(weth.balanceOf(address(db)), 5 ether, "board holds the wrapped lot");
        assertEq(db.escrowed(address(weth)), 5 ether, "escrow accounting matches");
        assertEq(address(db).balance, boardEthBefore, "no native balance retained");
        assertEq(seller.balance, 95 ether, "value left the seller exactly once");
    }

    /// @dev A wrapped lot is an ordinary ERC-20 lot from here on: the buyer pays
    ///      in `quote` and receives WETH, with no ETH-specific branch anywhere
    ///      in settlement.
    function test_wrappedLotFillsLikeAnyERC20Lot() public {
        uint256 id = _list(5 ether);
        uint256 cost = db.costOf(id, 2 ether);

        vm.prank(buyer);
        db.fill(id, 2 ether, buyer, cost);

        assertEq(weth.balanceOf(buyer), 2 ether, "buyer received the wrapped asset");
        assertEq(quote.balanceOf(seller), cost, "seller paid in quote");
        assertEq(db.escrowed(address(weth)), 3 ether, "remainder still escrowed");
    }

    /// @dev The matching exit: whatever did not sell comes back as native ETH,
    ///      so the seller never has to touch WETH on either side.
    function test_cancelUnwrapReturnsRemainderAsNativeETH() public {
        uint256 id = _list(5 ether);
        uint256 cost = db.costOf(id, 2 ether);
        vm.prank(buyer);
        db.fill(id, 2 ether, buyer, cost);

        vm.prank(seller);
        db.cancelUnwrap(id);

        assertEq(seller.balance, 98 ether, "3 ETH remainder returned natively");
        assertEq(weth.balanceOf(seller), 0, "seller holds no wrapper dust");
        assertEq(db.escrowed(address(weth)), 0, "escrow drained");
    }

    function test_listETHForAssignsSellerRights() public {
        vm.prank(maker);
        uint256 id = db.listETHFor{value: 1 ether}(seller, address(quote), 10e18, 10e18, 0, uint40(1 days), 0);

        assertEq(db.ownerOf(id), seller, "receipt goes to the named seller");
        assertEq(maker.balance, 99 ether, "the caller supplied the escrow");

        vm.prank(maker);
        vm.expectRevert(Dutchboard.NotSeller.selector);
        db.cancelUnwrap(id);

        vm.prank(seller);
        db.cancelUnwrap(id);
        assertEq(seller.balance, 101 ether, "seller redeems the lot as ETH");
    }

    /// @dev A native quote would price WETH in ETH, i.e. the lot against itself.
    ///      The shared `token == quote` guard cannot see it, because the sold
    ///      asset is recorded as WETH rather than address(0).
    function test_nativeQuoteRejected() public {
        vm.prank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        db.listETH{value: 1 ether}(address(0), 10e18, 10e18, 0, uint40(1 days), 0);
    }

    function test_zeroValueRejected() public {
        vm.prank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        db.listETH{value: 0}(address(quote), 10e18, 10e18, 0, uint40(1 days), 0);
    }

    /// @dev The board itself is not a valid seller, and neither is the wrapper.
    function test_boardAndWrapperRejectedAsSeller() public {
        vm.startPrank(maker);
        vm.expectRevert(Dutchboard.Bad.selector);
        db.listETHFor{value: 1 ether}(address(db), address(quote), 10e18, 10e18, 0, uint40(1 days), 0);
        vm.expectRevert(Dutchboard.Bad.selector);
        db.listETHFor{value: 1 ether}(address(weth), address(quote), 10e18, 10e18, 0, uint40(1 days), 0);
        vm.stopPrank();
    }

    /// @dev The non-payable list paths are unchanged and cannot receive value;
    ///      only the two ETH entry points are payable, and `receive()` still
    ///      rejects every sender but the wrapper.
    function test_receiveStillRejectsOrdinarySenders() public {
        vm.prank(seller);
        (bool ok,) = address(db).call{value: 1 ether}("");
        assertFalse(ok, "bare ETH sends are still refused");
    }
}
