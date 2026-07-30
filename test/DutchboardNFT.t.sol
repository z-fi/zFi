// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard, ETHTransferFailed} from "../src/Dutchboard.sol";
import {MockERC20, MockNFT} from "./SwapboardMocks.sol";

/// @dev Rejects ETH — a seller contract with neither receive nor fallback.
contract RejectETH {}

/// @dev MockNFT plus the safeTransferFrom overload that drives push listings, including
///      the selector check a compliant ERC-721 performs on the receiver's answer.
contract SafeMockNFT is MockNFT {
    function safeTransferFrom(address f, address t, uint256 id, bytes calldata data) external {
        require(ownerOf[id] == f, "not owner");
        require(msg.sender == f || isApprovedForAll[f][msg.sender], "not approved");
        ownerOf[id] = t;
        bytes4 got = IERC721Receiver(t).onERC721Received(msg.sender, f, id, data);
        require(got == IERC721Receiver.onERC721Received.selector, "bad receiver");
    }
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// @dev Forwards ownerOf to a real collection so it can pose as the owner of a token the
///      board already escrows, then tries to reclaim it. The push hook trusts msg.sender
///      as the collection, so this is the shape an impersonation attack has to take.
contract ImpersonatingCollection {
    MockNFT immutable real;

    constructor(MockNFT _real) {
        real = _real;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return real.ownerOf(id);
    }

    function transferFrom(address from, address to, uint256 id) external {
        real.transferFrom(from, to, id); // msg.sender here is this contract, never approved
    }

    function push(address board, address seller, uint256 id, bytes calldata data) external {
        IERC721Receiver(board).onERC721Received(address(this), seller, id, data);
    }
}

/// @dev Reenters the board's hook from inside the ownership probe. The probe is a
///      STATICCALL, so this cannot succeed even before the guard is consulted.
contract ProbeReenteringCollection {
    address board;

    function arm(address _board) external {
        board = _board;
    }

    function ownerOf(uint256) external view returns (address) {
        // A staticcall frame cannot write state, so the reentrant tstore in the guard
        // reverts here regardless of what the guard would have decided.
        (bool ok,) = board.staticcall(
            abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", address(this), msg.sender, 1, "")
        );
        require(ok, "probe reentry blocked");
        return board;
    }

    function push(uint256 id, bytes calldata data) external {
        IERC721Receiver(board).onERC721Received(address(this), msg.sender, id, data);
    }
}

/// @dev Reenters the hook from `transferFrom`, which the board calls while settling. This
///      is the case the reentrancy guard genuinely exists for: the collection chooses
///      when the hook fires, and could otherwise open a listing mid-fill or mid-cancel.
contract SettlementReenteringCollection {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    address board;
    bytes terms;
    bool armed;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function arm(address _board, bytes calldata _terms) external {
        (board, terms, armed) = (_board, _terms, true);
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "not owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        ownerOf[id] = to;
        if (armed) {
            armed = false;
            IERC721Receiver(board).onERC721Received(address(this), from, id, terms);
        }
    }
}

/// @notice Mainline unit coverage for Dutchboard's ERC-721 path.
///
/// @dev These are the cases DutchAuction.t.sol pins for the ETH-only predecessor, ported
///      to Dutchboard's signatures, plus the ones only Dutchboard can express: a bundle
///      priced in an ERC-20, an explicit `to` recipient, and a taker-supplied `maxCost`.
///      Worth having as unit tests rather than leaving to DutchboardAudit/Invariant,
///      because Dutchboard's NFT path is where it diverges most from its predecessor —
///      `_moveNFT` and `_returnNFT` assert ownership before and after every transfer,
///      which DutchAuction never did.
///
///      Deliberately not forked: the ERC-721 cases need a mock collection, and nothing
///      here touches mainnet state. Dutchboard.t.sol stays the fork file.
contract DutchboardNFTTest is Test {
    Dutchboard board;
    MockNFT nft;
    MockERC20 quote;

    address alice = address(0xA11CE); // seller
    address bob = address(0xB0B); // taker
    address carol = address(0xCAFE); // third party / recipient

    uint256 constant UINT96_MAX = type(uint96).max;

    function setUp() public {
        board = new Dutchboard();
        nft = new MockNFT();
        quote = new MockERC20("QUOTE", 18);
        // This suite's CREATE address collides with a mainnet account holding dust, so
        // "the board retained no ETH" assertions would read that balance instead of this
        // contract's behaviour. Same workaround as DutchboardFuzz.
        vm.deal(address(board), 0);

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);

        quote.mint(bob, 1_000_000e18);
        vm.prank(bob);
        quote.approve(address(board), type(uint256).max);
    }

    // ------------------------------------------------------------------ HELPERS

    function _ids(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _mintTo(address to, uint256 n, uint256 from) internal returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            nft.mint(to, from + i);
            out[i] = from + i;
        }
    }

    /// List a single NFT priced in native ETH, starting now.
    function _listOne(uint256 id, uint256 startP, uint256 endP, uint40 dur) internal returns (uint256) {
        nft.mint(alice, id);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 lid = board.listNFT(address(nft), address(0), _ids(id), startP, endP, 0, dur);
        vm.stopPrank();
        return lid;
    }

    // ------------------------------------------------------------------- LISTING

    function testListNFTSingle() public {
        uint256 id = _listOne(42, 10 ether, 0, 1 hours);
        assertEq(nft.ownerOf(42), address(board), "escrowed");

        Dutchboard.ListingView memory v = board.getListing(id);
        assertEq(v.seller, alice);
        assertEq(v.token, address(nft));
        assertEq(v.quote, address(0), "native ETH quote");
        assertTrue(v.isNFT);
        assertEq(v.ids.length, 1);
        assertEq(v.initial, 0, "NFT lots carry no fungible amount");
        assertEq(v.remaining, 0);
    }

    function testListNFTBundle() public {
        uint256[] memory ids = _mintTo(alice, 3, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(0), ids, 5 ether, 1, 0, 1 hours);
        vm.stopPrank();

        assertEq(board.getListing(id).ids.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(nft.ownerOf(i + 1), address(board));
        }
    }

    /// The order DutchAuction cannot express: a bundle whose seller is paid in an ERC-20.
    function testListNFTPricedInERC20() public {
        uint256[] memory ids = _mintTo(alice, 2, 10);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(quote), ids, 500e18, 100e18, 0, 1 hours);
        vm.stopPrank();

        assertEq(board.getListing(id).quote, address(quote));
        assertEq(board.quoteOf(id), address(quote));
        assertEq(board.tokenOf(id), address(nft));
    }

    function testListNFTRevertsEmpty() public {
        uint256[] memory ids = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listNFT(address(nft), address(0), ids, 1 ether, 0, 0, 1 hours);
    }

    function testListNFTRevertsZeroDuration() public {
        vm.prank(alice);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listNFT(address(nft), address(0), _ids(1), 1 ether, 0, 0, 0);
    }

    function testListNFTRevertsEOAToken() public {
        // Solidity's implicit extcodesize check on the typed ownerOf call reverts.
        vm.prank(alice);
        vm.expectRevert();
        board.listNFT(address(0xbeef), address(0), _ids(1), 1 ether, 0, 0, 1 hours);
    }

    function testListNFTRevertsStartBelowEnd() public {
        vm.prank(alice);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listNFT(address(nft), address(0), _ids(1), 1 ether, 2 ether, 0, 1 hours);
    }

    function testListNFTRevertsOverBundleCap() public {
        uint256[] memory ids = new uint256[](101);
        vm.prank(alice);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listNFT(address(nft), address(0), ids, 1 ether, 0, 0, 1 hours);
    }

    function testListNFTAcceptsBundleCapExactly() public {
        uint256[] memory ids = _mintTo(alice, 100, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(0), ids, 100 ether, 0, 0, 1 hours);
        vm.stopPrank();
        assertEq(board.getListing(id).ids.length, 100);
    }

    function testListNFTRevertsZeroStartPrice() public {
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listNFT(address(nft), address(0), _ids(1), 0, 0, 0, 1 hours);
        vm.stopPrank();
    }

    function testListNFTRevertsPastStartTime() public {
        vm.warp(10_000);
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listNFT(address(nft), address(0), _ids(1), 1 ether, 0, uint40(block.timestamp - 1), 1 hours);
        vm.stopPrank();
    }

    function testListNFTAcceptsFutureStartTime() public {
        vm.warp(10_000);
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        board.listNFT(address(nft), address(0), _ids(1), 1 ether, 0, uint40(block.timestamp + 1 hours), 1 hours);
        vm.stopPrank();
    }

    /// Dutchboard-only: the pair must be two distinct assets.
    function testListNFTRevertsTokenEqualsQuote() public {
        vm.prank(alice);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listNFT(address(nft), address(nft), _ids(1), 1 ether, 0, 0, 1 hours);
    }

    /// Dutchboard-only: a price the uint96 packing cannot hold must fail at listing
    /// rather than escrow the bundle at a silently truncated ask.
    function testListNFTRevertsPriceAboveUint96() public {
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listNFT(address(nft), address(0), _ids(1), UINT96_MAX + 1, 0, 0, 1 hours);
        // The boundary itself is listable.
        board.listNFT(address(nft), address(0), _ids(1), UINT96_MAX, 0, 0, 1 hours);
        vm.stopPrank();
    }

    // --------------------------------------------------------------------- PRICE

    function testPriceDecay() public {
        uint256 id = _listOne(1, 10 ether, 0, 1 hours);
        uint40 startT = uint40(block.timestamp);

        assertEq(board.priceOf(id), 10 ether);

        vm.warp(startT + 1);
        assertApproxEqAbs(board.priceOf(id), uint256(10 ether) - uint256(10 ether) / 3600, 1);

        vm.warp(startT + 30 minutes);
        assertEq(board.priceOf(id), 5 ether);

        vm.warp(startT + 1 hours);
        assertEq(board.priceOf(id), 0);

        vm.warp(startT + 2 hours);
        assertEq(board.priceOf(id), 0, "flat after the window");
    }

    function testPriceBeforeStart() public {
        uint40 future = uint40(block.timestamp + 1000);
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(0), _ids(1), 10 ether, 1, future, 1 hours);
        vm.stopPrank();

        assertEq(board.priceOf(id), 10 ether, "flat before the window");
        vm.warp(future);
        assertEq(board.priceOf(id), 10 ether);
        vm.warp(future + 1 hours);
        assertEq(board.priceOf(id), 1);
    }

    function testPriceOfClosedListingIsZero() public {
        uint256 id = _listOne(1, 10 ether, 0, 1 hours);
        vm.prank(alice);
        board.cancel(id);
        assertEq(board.priceOf(id), 0);
        assertEq(board.costOf(id, 0), 0);
    }

    /// costOf mirrors fill: a mismatched bundle size is reported non-fillable, not priced.
    function testCostOfRejectsMismatchedTake() public {
        uint256[] memory ids = _mintTo(alice, 3, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(0), ids, 30 ether, 0, 0, 1 hours);
        vm.stopPrank();

        assertEq(board.costOf(id, 0), 30 ether, "0 means whole lot");
        assertEq(board.costOf(id, 3), 30 ether, "exact bundle size");
        assertEq(board.costOf(id, 2), 0, "partial bundle is not fillable");
    }

    // ---------------------------------------------------------------- FILL (ETH)

    function testFillNFTAtFullPrice() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        board.fill{value: 10 ether}(id, 0, bob, 10 ether);

        assertEq(nft.ownerOf(7), bob);
        assertEq(alice.balance, aliceBefore + 10 ether);
        assertEq(bob.balance, bobBefore - 10 ether);
        assertEq(board.getListing(id).seller, address(0), "listing closed");
    }

    function testFillNFTRefundsExcess() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        vm.warp(block.timestamp + 30 minutes); // price = 5 ETH

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        board.fill{value: 10 ether}(id, 0, bob, 10 ether);

        assertEq(nft.ownerOf(7), bob);
        assertEq(alice.balance, aliceBefore + 5 ether);
        assertEq(bob.balance, bobBefore - 5 ether, "overpayment refunded");
    }

    function testFillNFTAtEndZero() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(bob);
        board.fill{value: 0}(id, 0, bob, 0);

        assertEq(nft.ownerOf(7), bob, "decayed to free");
    }

    function testFillNFTBundleTransfersEveryId() public {
        uint256[] memory ids = _mintTo(alice, 3, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(0), ids, 30 ether, 1, 0, 1 hours);
        vm.stopPrank();

        vm.prank(bob);
        board.fill{value: 30 ether}(id, 0, bob, 30 ether);

        for (uint256 i; i < 3; ++i) {
            assertEq(nft.ownerOf(i + 1), bob);
        }
    }

    /// Explicit bundle size is accepted; anything else is a mis-encoded call.
    function testFillNFTAcceptsExactBundleSize() public {
        uint256[] memory ids = _mintTo(alice, 3, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(0), ids, 30 ether, 1, 0, 1 hours);
        vm.stopPrank();

        vm.prank(bob);
        board.fill{value: 30 ether}(id, 3, bob, 30 ether);
        assertEq(nft.ownerOf(2), bob);
    }

    function testFillNFTRevertsPartialBundle() public {
        uint256[] memory ids = _mintTo(alice, 3, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(0), ids, 30 ether, 1, 0, 1 hours);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill{value: 30 ether}(id, 2, bob, 30 ether);
    }

    function testFillNFTRevertsInsufficient() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        vm.prank(bob);
        vm.expectRevert(Dutchboard.Insufficient.selector);
        board.fill{value: 1 ether}(id, 0, bob, 10 ether);
    }

    function testFillNFTRevertsUnknownId() public {
        vm.prank(bob);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill{value: 1 ether}(999, 0, bob, 1 ether);
    }

    function testFillNFTRejectingSellerReverts() public {
        RejectETH rej = new RejectETH();
        nft.mint(address(rej), 1);
        vm.startPrank(address(rej));
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(0), _ids(1), 1 ether, 0, 0, 1 hours);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(ETHTransferFailed.selector);
        board.fill{value: 1 ether}(id, 0, bob, 1 ether);
    }

    /// Dutchboard-only: the taker's bound binds before any asset moves.
    function testFillNFTRevertsCostExceeded() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Dutchboard.CostExceeded.selector, 10 ether, 9 ether));
        board.fill{value: 10 ether}(id, 0, bob, 9 ether);

        assertEq(nft.ownerOf(7), address(board), "escrow untouched");
    }

    /// Dutchboard-only: settle straight to an end user rather than taking custody.
    function testFillNFTDeliversToNamedRecipient() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        vm.prank(bob);
        board.fill{value: 10 ether}(id, 0, carol, 10 ether);
        assertEq(nft.ownerOf(7), carol, "delivered to `to`, not msg.sender");
    }

    function testFillNFTRevertsZeroRecipient() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        vm.prank(bob);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill{value: 10 ether}(id, 0, address(0), 10 ether);
    }

    function testFillNFTRevertsBoardAsRecipient() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        vm.prank(bob);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill{value: 10 ether}(id, 0, address(board), 10 ether);
    }

    // -------------------------------------------------------------- FILL (ERC20)

    function testFillNFTPaidInERC20() public {
        uint256[] memory ids = _mintTo(alice, 2, 10);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(quote), ids, 500e18, 100e18, 0, 1 hours);
        vm.stopPrank();

        uint256 aliceBefore = quote.balanceOf(alice);
        uint256 bobBefore = quote.balanceOf(bob);

        vm.prank(bob);
        board.fill(id, 0, bob, 500e18);

        assertEq(nft.ownerOf(10), bob);
        assertEq(nft.ownerOf(11), bob);
        assertEq(quote.balanceOf(alice), aliceBefore + 500e18, "seller paid in quote");
        assertEq(quote.balanceOf(bob), bobBefore - 500e18);
        assertEq(alice.balance, 1000 ether, "no ETH moved");
    }

    function testFillNFTPaidInERC20MidDecay() public {
        uint256[] memory ids = _mintTo(alice, 1, 10);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(quote), ids, 500e18, 100e18, 0, 1 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 minutes);
        uint256 expected = 300e18; // midpoint of 500 -> 100
        assertEq(board.costOf(id, 0), expected);

        uint256 aliceBefore = quote.balanceOf(alice);
        vm.prank(bob);
        board.fill(id, 0, bob, expected);
        assertEq(quote.balanceOf(alice), aliceBefore + expected);
    }

    /// Value attached to an ERC-20-quoted listing buys nothing; rejecting it flags a
    /// mis-encoded call rather than quietly handing the ETH back.
    function testFillNFTRevertsValueOnERC20Quote() public {
        uint256[] memory ids = _mintTo(alice, 1, 10);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(quote), ids, 500e18, 100e18, 0, 1 hours);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill{value: 1 ether}(id, 0, bob, 500e18);
    }

    // -------------------------------------------------------------------- CANCEL

    function testCancelNFTReturnsBundle() public {
        uint256[] memory ids = _mintTo(alice, 3, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(0), ids, 30 ether, 0, 0, 1 hours);
        board.cancel(id);
        vm.stopPrank();

        for (uint256 i; i < 3; ++i) {
            assertEq(nft.ownerOf(i + 1), alice, "reclaimed");
        }
        assertEq(board.getListing(id).seller, address(0));
    }

    function testCancelRevertsNotSeller() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        vm.prank(bob);
        vm.expectRevert(Dutchboard.NotSeller.selector);
        board.cancel(id);
    }

    function testCancelRevertsTwice() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        vm.startPrank(alice);
        board.cancel(id);
        vm.expectRevert(Dutchboard.NotSeller.selector);
        board.cancel(id);
        vm.stopPrank();
    }

    function testFillAfterCancelReverts() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        vm.prank(alice);
        board.cancel(id);

        vm.prank(bob);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill{value: 10 ether}(id, 0, bob, 10 ether);
    }

    /// cancelUnwrap is a fungible-WETH convenience; an NFT lot has nothing to unwrap.
    function testCancelUnwrapRevertsOnNFT() public {
        uint256 id = _listOne(7, 10 ether, 0, 1 hours);
        vm.prank(alice);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.cancelUnwrap(id);
    }

    // ------------------------------------------------------------------ FILLMANY

    // DutchboardFuzz covers the ETH accounting across fungible legs. These pin the cases
    // only an NFT leg produces: a batch that sweeps several bundles, and a mixed batch
    // whose ETH and ERC-20 legs settle out of one call.

    function _listBundle(uint256 first, uint256 n, address quoteAsset, uint256 price)
        internal
        returns (uint256 id)
    {
        uint256[] memory ids = _mintTo(alice, n, first);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(board), true);
        id = board.listNFT(address(nft), quoteAsset, ids, price, price, 0, 1 hours);
        vm.stopPrank();
    }

    function testFillManySweepsSeveralBundles() public {
        uint256 a = _listBundle(1, 2, address(0), 3 ether);
        uint256 b = _listBundle(10, 3, address(0), 5 ether);

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
        uint128[] memory takes = new uint128[](2); // 0 == whole lot
        uint256[] memory maxCosts = new uint256[](2);
        (maxCosts[0], maxCosts[1]) = (3 ether, 5 ether);

        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        uint256 spent = board.fillMany{value: 8 ether}(ids, takes, maxCosts, bob);

        assertEq(spent, 8 ether);
        assertEq(alice.balance, aliceBefore + 8 ether, "seller paid once per bundle");
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.ownerOf(11), bob);
        assertEq(address(board).balance, 0);
    }

    /// An ETH-quoted bundle and an ERC20-quoted bundle in one call. The ETH leg draws
    /// from msg.value; the ERC20 leg must not, and the surplus must come back.
    function testFillManyMixedQuotesSettleIndependently() public {
        uint256 ethLeg = _listBundle(1, 1, address(0), 4 ether);
        uint256 erc20Leg = _listBundle(10, 1, address(quote), 250e18);

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (ethLeg, erc20Leg);
        uint128[] memory takes = new uint128[](2);
        uint256[] memory maxCosts = new uint256[](2);
        (maxCosts[0], maxCosts[1]) = (4 ether, 250e18);

        uint256 aliceEth = alice.balance;
        uint256 aliceQuote = quote.balanceOf(alice);
        uint256 bobEth = bob.balance;

        vm.prank(bob);
        uint256 spent = board.fillMany{value: 6 ether}(ids, takes, maxCosts, bob);

        assertEq(spent, 4 ether, "only the ETH leg draws value");
        assertEq(alice.balance, aliceEth + 4 ether);
        assertEq(quote.balanceOf(alice), aliceQuote + 250e18);
        assertEq(bob.balance, bobEth - 4 ether, "2 ETH surplus refunded");
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.ownerOf(10), bob);
    }

    /// Two ETH-quoted bundles cannot both be paid from one leg's worth of value.
    function testFillManyRejectsUnderfundedEthLegs() public {
        uint256 a = _listBundle(1, 1, address(0), 4 ether);
        uint256 b = _listBundle(10, 1, address(0), 4 ether);

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
        uint128[] memory takes = new uint128[](2);
        uint256[] memory maxCosts = new uint256[](2);
        (maxCosts[0], maxCosts[1]) = (4 ether, 4 ether);

        vm.prank(bob);
        vm.expectRevert(Dutchboard.Insufficient.selector);
        board.fillMany{value: 4 ether}(ids, takes, maxCosts, bob);

        assertEq(nft.ownerOf(1), address(board), "aborted batch moved escrow");
        assertEq(nft.ownerOf(10), address(board));
    }

    function testFillManyRevertsOnLengthMismatch() public {
        uint256 a = _listBundle(1, 1, address(0), 1 ether);
        uint256[] memory ids = _ids(a);
        uint128[] memory takes = new uint128[](2);
        uint256[] memory maxCosts = new uint256[](1);

        vm.prank(bob);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fillMany{value: 1 ether}(ids, takes, maxCosts, bob);
    }

    function testFillManyRevertsOnEmptyBatch() public {
        vm.prank(bob);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fillMany(new uint256[](0), new uint128[](0), new uint256[](0), bob);
    }

    // -------------------------------------------------------------- PUSH LISTING

    // Listing by safeTransferFrom, with the curve carried in the transfer's data. The
    // value of this path is that it needs no approval at all, so the assertions below
    // care as much about what the board is NOT granted as about the listing it creates.

    function _terms(address quoteAsset, uint256 sp, uint256 ep, uint40 st, uint40 dur)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(Dutchboard.PushTerms(quoteAsset, sp, ep, st, dur));
    }

    function testPushListCreatesListingWithoutApproval() public {
        SafeMockNFT safe = new SafeMockNFT();
        safe.mint(alice, 1);

        vm.prank(alice);
        safe.safeTransferFrom(alice, address(board), 1, _terms(address(0), 10 ether, 1 ether, 0, 1 hours));

        Dutchboard.ListingView memory v = board.getListing(0);
        assertEq(v.seller, alice, "seller is the sender, not the operator");
        assertEq(v.token, address(safe));
        assertEq(v.quote, address(0));
        assertTrue(v.isNFT);
        assertEq(v.ids.length, 1);
        assertEq(v.ids[0], 1);
        assertEq(v.startPrice, 10 ether);
        assertEq(v.endPrice, 1 ether);
        assertEq(safe.ownerOf(1), address(board), "escrowed");
        assertFalse(safe.isApprovedForAll(alice, address(board)), "push path granted an approval");
    }

    function testPushListedNFTFillsNormally() public {
        SafeMockNFT safe = new SafeMockNFT();
        safe.mint(alice, 1);
        vm.prank(alice);
        safe.safeTransferFrom(alice, address(board), 1, _terms(address(0), 10 ether, 10 ether, 0, 1 hours));

        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        board.fill{value: 10 ether}(0, 0, bob, 10 ether);

        assertEq(safe.ownerOf(1), bob);
        assertEq(alice.balance, aliceBefore + 10 ether);
    }

    function testPushListedNFTCancelsBackToSeller() public {
        SafeMockNFT safe = new SafeMockNFT();
        safe.mint(alice, 1);
        vm.prank(alice);
        safe.safeTransferFrom(alice, address(board), 1, _terms(address(0), 10 ether, 0, 0, 1 hours));

        vm.prank(alice);
        board.cancel(0);
        assertEq(safe.ownerOf(1), alice, "reclaimed by the pusher");
    }

    function testPushListPricedInERC20() public {
        SafeMockNFT safe = new SafeMockNFT();
        safe.mint(alice, 1);
        vm.prank(alice);
        safe.safeTransferFrom(alice, address(board), 1, _terms(address(quote), 250e18, 250e18, 0, 1 hours));

        uint256 aliceBefore = quote.balanceOf(alice);
        vm.prank(bob);
        board.fill(0, 0, bob, 250e18);
        assertEq(quote.balanceOf(alice), aliceBefore + 250e18);
        assertEq(safe.ownerOf(1), bob);
    }

    /// A stray transfer must bounce rather than mint a listing on terms decoded from
    /// zero bytes. The revert propagates through safeTransferFrom, so the NFT stays put.
    function testPushListRevertsOnEmptyData() public {
        SafeMockNFT safe = new SafeMockNFT();
        safe.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(Dutchboard.Bad.selector);
        safe.safeTransferFrom(alice, address(board), 1, "");
        assertEq(safe.ownerOf(1), alice, "stray transfer consumed the NFT");
    }

    function testPushListRevertsOnShortData() public {
        SafeMockNFT safe = new SafeMockNFT();
        safe.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(Dutchboard.Bad.selector);
        safe.safeTransferFrom(alice, address(board), 1, abi.encode(address(0), uint256(1)));
    }

    function testPushListRevertsOnBadCurve() public {
        SafeMockNFT safe = new SafeMockNFT();
        safe.mint(alice, 1);
        vm.startPrank(alice);

        vm.expectRevert(Dutchboard.Bad.selector); // zero start price
        safe.safeTransferFrom(alice, address(board), 1, _terms(address(0), 0, 0, 0, 1 hours));

        vm.expectRevert(Dutchboard.Bad.selector); // start below end
        safe.safeTransferFrom(alice, address(board), 1, _terms(address(0), 1 ether, 2 ether, 0, 1 hours));

        vm.expectRevert(Dutchboard.Bad.selector); // zero duration
        safe.safeTransferFrom(alice, address(board), 1, _terms(address(0), 1 ether, 0, 0, 0));

        vm.expectRevert(Dutchboard.Bad.selector); // price above the uint96 ceiling
        safe.safeTransferFrom(alice, address(board), 1, _terms(address(0), UINT96_MAX + 1, 0, 0, 1 hours));

        vm.stopPrank();
        assertEq(safe.ownerOf(1), alice);
    }

    function testPushListRevertsWhenQuoteIsTheCollection() public {
        SafeMockNFT safe = new SafeMockNFT();
        safe.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(Dutchboard.Bad.selector);
        safe.safeTransferFrom(alice, address(board), 1, _terms(address(safe), 1 ether, 0, 0, 1 hours));
    }

    function testPushListRevertsOnPastStartTime() public {
        vm.warp(10_000);
        SafeMockNFT safe = new SafeMockNFT();
        safe.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(Dutchboard.Bad.selector);
        safe.safeTransferFrom(
            alice, address(board), 1, _terms(address(0), 1 ether, 0, uint40(block.timestamp - 1), 1 hours)
        );
    }

    /// Calling the hook directly from an EOA transfers nothing. `msg.sender` is then an
    /// account with no code, so the ownership probe cannot succeed.
    function testDirectHookCallFromEOAReverts() public {
        vm.prank(bob);
        vm.expectRevert();
        Dutchboard(payable(address(board))).onERC721Received(
            bob, bob, 1, _terms(address(0), 1 ether, 0, 0, 1 hours)
        );
    }

    /// The attack the ownership probe exists for: a contract posing as a collection,
    /// claiming a token the board already escrows for someone else. It can mint a
    /// listing only over ITSELF as the collection — never over the real one — and the
    /// reclaim it is angling for fails because the board never approved it.
    function testImpersonatingCollectionCannotStealEscrow() public {
        // Victim escrows a real NFT the ordinary way.
        nft.mint(carol, 1);
        vm.startPrank(carol);
        nft.setApprovalForAll(address(board), true);
        uint256 victimListing = board.listNFT(address(nft), address(0), _ids(1), 5 ether, 5 ether, 0, 1 hours);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), address(board));

        // Attacker's contract forwards ownerOf to the real collection, so the probe sees
        // the board as owner and the listing is created — but bound to the impostor.
        ImpersonatingCollection evil = new ImpersonatingCollection(nft);
        evil.push(address(board), address(this), 1, _terms(address(0), 1, 1, 0, 1 hours));

        uint256 fake = board.nextId() - 1;
        assertEq(board.getListing(fake).token, address(evil), "listing bound to the real collection");

        // Cancelling the impostor listing cannot move the real NFT: the board's call
        // lands on the impostor, whose forwarded transferFrom is unapproved.
        vm.expectRevert();
        board.cancel(fake);

        assertEq(nft.ownerOf(1), address(board), "real escrow moved");
        assertEq(board.getListing(victimListing).seller, carol, "victim listing disturbed");
    }

    /// The ownership probe reads `ownerOf`, which is `view` and therefore reached by
    /// STATICCALL. A collection cannot use it to reenter and open a listing, because the
    /// guard's tstore is illegal inside a static frame — the EVM refuses before the
    /// guard's own logic is ever consulted.
    function testProbeCannotBeUsedToReenter() public {
        ProbeReenteringCollection evil = new ProbeReenteringCollection();
        evil.arm(address(board));
        vm.expectRevert(); // static-context violation, so no selector to match on
        evil.push(1, _terms(address(0), 1 ether, 0, 0, 1 hours));
        assertEq(board.nextId(), 0, "reentrant probe created a listing");
    }

    /// What the guard is actually for: the collection controls when the hook fires, and
    /// the board calls into it while settling. Opening a listing from inside a cancel
    /// would mutate the book mid-operation, so the guard refuses.
    function testHookCannotBeEnteredDuringSettlement() public {
        SettlementReenteringCollection evil = new SettlementReenteringCollection();
        evil.mint(alice, 1);

        vm.startPrank(alice);
        evil.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(evil), address(0), _ids(1), 1 ether, 0, 0, 1 hours);
        vm.stopPrank();

        // Arm only now, so the listing itself succeeded and only the exit reenters.
        evil.arm(address(board), _terms(address(0), 1 ether, 0, 0, 1 hours));

        vm.prank(alice);
        vm.expectRevert(Dutchboard.Reentrancy.selector);
        board.cancel(id); // _returnNFT's transferFrom is where the collection reenters
    }
}
