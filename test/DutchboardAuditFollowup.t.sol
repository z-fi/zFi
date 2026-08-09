// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// @dev `MockNFT` moves tokens with plain `transferFrom` only. A counterparty
///      board that pays NFT proceeds with `safeTransferFrom` is the whole point
///      of M-2, so the delivery side needs a collection that actually calls the
///      receiver hook.
contract SafeNFT is MockNFT {
    function safeTransferFrom(address f, address t, uint256 id, bytes memory data) public {
        require(ownerOf[id] == f, "not owner");
        require(msg.sender == f || isApprovedForAll[f][msg.sender], "not approved");
        ownerOf[id] = t;
        if (t.code.length != 0) {
            require(
                IERC721Receiver(t).onERC721Received(msg.sender, f, id, data)
                    == IERC721Receiver.onERC721Received.selector,
                "bad receiver"
            );
        }
    }
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// @dev A collection with proceeds-callback authority, earned the only way it can
///      be: by legitimately escrowing one of its own tokens as a listing.
contract CallbackCollection is SafeNFT {
    Dutchboard immutable board;

    constructor(Dutchboard _board) {
        board = _board;
    }

    function callBefore(uint256 orderId, address token, uint256 amount, bool nft) external returns (bool) {
        return board.beforeOrderProceeds(orderId, token, amount, nft);
    }

    function callAfter(uint256 orderId, address token, uint256 amount, bool nft) external {
        board.afterOrderProceeds(orderId, token, amount, nft);
    }

    /// @dev Deliver an NFT the way a *safe* counterparty board would.
    function pushSafe(address nft, uint256 tokenId) external {
        SafeNFT(nft).safeTransferFrom(address(this), address(board), tokenId, "");
    }
}

/// @dev Answers `true` to every `supportsInterface` query. It is not answering the
///      question, so its `false`-shaped answers are worthless too — including the
///      one the fungible listing path relies on to reject ERC-721s.
contract AlwaysTrue165 is MockERC20("LIAR", 18) {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @dev Opts into the proceeds protocol and then answers with a 2 MB blob.
///      Pre-patch this was copied wholesale into memory by the paying board,
///      whose quadratic expansion cost is what killed the surrounding batch.
contract BlobSeller {
    bool public shouldRevert;

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function acceptsOrderProceeds(uint256) external pure returns (bool) {
        return true;
    }

    fallback() external payable {
        if (shouldRevert) {
            assembly {
                revert(0, 2000000)
            }
        }
        assembly {
            mstore(0, 1)
            return(0, 2000000)
        }
    }

    receive() external payable {}
}

/// @dev A well-behaved escrow seller: it opts in and answers both callback legs
///      exactly as the protocol specifies.
contract EscrowSeller {
    function acceptsOrderProceeds(uint256) external pure returns (bool) {
        return true;
    }

    function beforeOrderProceeds(uint256, address, uint256, bool) external pure returns (bool) {
        return true;
    }

    function afterOrderProceeds(uint256, address, uint256, bool) external pure {}

    receive() external payable {}
}

/// @notice Follow-up regression coverage for the second Dutchboard audit pass.
///
/// @dev One test per fixed finding, each failing against the pre-patch contract.
contract DutchboardAuditFollowupTest is Test {
    Dutchboard db;
    MockWETH weth;
    MockERC20 quote;
    SafeNFT payerNFT;
    CallbackCollection evil;

    address attacker = address(0xBAD);
    address seller = address(0x5E11);
    address buyer = address(0xB0B);

    uint256 evilListingId;

    function setUp() public {
        weth = new MockWETH();
        db = new Dutchboard(address(weth));
        quote = new MockERC20("Q", 18);
        payerNFT = new SafeNFT();
        evil = new CallbackCollection(db);

        evil.mint(attacker, 1);
        vm.startPrank(attacker);
        evil.setApprovalForAll(address(db), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        evilListingId = db.listNFT(address(evil), address(quote), ids, 1e18, 1e18, 0, uint40(1 days));
        vm.stopPrank();
    }

    // --------------------------------------------------------------------- M-5

    /// @dev A zero-amount "arrival" satisfies the fungible delta check trivially
    ///      (`free == snapshot - 2 + 0`) and used to fall straight through to the
    ///      freeze, letting any registered collection permanently disable every
    ///      listing of its own tokens for free.
    function test_M05_zeroAmountProceedsCannotFreezeAListing() public {
        vm.prank(address(evil));
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        evil.callBefore(1, address(quote), 0, false);

        assertFalse(db.frozen(evilListingId), "listing must not be frozen");
    }

    /// @dev The `after` leg has no live slot to land on either, so the freeze is
    ///      unreachable from both directions.
    function test_M05_zeroAmountAfterLegHasNoSlot() public {
        vm.prank(address(evil));
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        evil.callAfter(1, address(quote), 0, false);

        assertFalse(db.frozen(evilListingId), "listing must not be frozen");
    }

    /// @dev The guard must not have broken ordinary crediting.
    function test_M05_nonZeroProceedsStillCreditAndFreeze() public {
        quote.mint(address(evil), 7e18);

        vm.startPrank(address(evil));
        assertTrue(evil.callBefore(1, address(quote), 7e18, false));
        quote.transfer(address(db), 7e18);
        evil.callAfter(1, address(quote), 7e18, false);
        vm.stopPrank();

        assertEq(db.claimableProceeds(evilListingId, address(quote)), 7e18, "credited");
        assertTrue(db.frozen(evilListingId), "settled position freezes its listing");
    }

    // --------------------------------------------------------------------- M-2

    /// @dev A counterparty board paying NFT proceeds delivers with a bare
    ///      `safeTransferFrom` and no terms. Pre-patch `onERC721Received` reverted
    ///      on any non-magic payload, which reverted the PAYER's settlement and
    ///      made the proceeds protocol work only for payers that happened to use
    ///      plain `transferFrom` — an unenforceable requirement on foreign code.
    function test_M02_bareSafeTransferIsAcceptedInsideAProceedsBracket() public {
        payerNFT.mint(address(evil), 55);

        vm.startPrank(address(evil));
        assertTrue(evil.callBefore(1, address(payerNFT), 55, true), "bracket opens");
        evil.pushSafe(address(payerNFT), 55); // would revert pre-patch
        evil.callAfter(1, address(payerNFT), 55, true);
        vm.stopPrank();

        assertEq(payerNFT.ownerOf(55), address(db), "board holds the payment");
        assertTrue(db.claimableNFTProceeds(evilListingId, address(payerNFT), 55), "credited to the position");
        assertTrue(db.heldAsProceeds(address(payerNFT), 55), "custody recorded as proceeds");
    }

    /// @dev The bypass is a settlement path, not a general "anyone may push NFTs
    ///      here" door: outside an open bracket a bare push still reverts.
    function test_M02_bareSafeTransferOutsideABracketStillReverts() public {
        payerNFT.mint(address(evil), 56);

        vm.prank(address(evil));
        vm.expectRevert(Dutchboard.Bad.selector);
        evil.pushSafe(address(payerNFT), 56);
    }

    /// @dev The bracket authorises one delivery, not an open season: once the
    ///      `after` leg closes it, the door shuts again.
    function test_M02_bracketClosesAfterItsDelivery() public {
        payerNFT.mint(address(evil), 57);
        payerNFT.mint(address(evil), 58);

        vm.startPrank(address(evil));
        assertTrue(evil.callBefore(1, address(payerNFT), 57, true));
        evil.pushSafe(address(payerNFT), 57);
        evil.callAfter(1, address(payerNFT), 57, true);

        vm.expectRevert(Dutchboard.Bad.selector);
        evil.pushSafe(address(payerNFT), 58);
        vm.stopPrank();
    }

    /// @dev A push carrying real terms is still a listing, bracket or not.
    function test_M02_termedPushIsStillAListing() public {
        payerNFT.mint(seller, 59);
        bytes memory data = abi.encodePacked(
            keccak256("Dutchboard.PushTerms.v1"),
            abi.encode(address(quote), uint256(3e18), uint256(1e18), uint40(0), uint40(1 days))
        );
        vm.prank(seller);
        payerNFT.safeTransferFrom(seller, address(db), 59, data);

        (, address s,,,,,,) = _leg(db.nextId() - 1);
        assertEq(s, seller, "push created a listing for its sender");
    }

    // --------------------------------------------------------------------- M-3

    /// @dev An always-true ERC-165 responder is not answering the question, so it
    ///      must be refused rather than read. Pre-patch the single positive probe
    ///      caught it on the fungible path only by accident of it also claiming
    ///      `0x80ac58cd`; a liar that claimed everything EXCEPT that id sailed
    ///      through. The negative control closes both.
    function test_M03_alwaysTrue165ResponderIsRefusedOnBothLegs() public {
        AlwaysTrue165 liar = new AlwaysTrue165();
        MockERC20 ok = new MockERC20("OK", 18);

        liar.mint(seller, 10e18);
        ok.mint(seller, 10e18);

        vm.startPrank(seller);
        liar.approve(address(db), type(uint256).max);
        ok.approve(address(db), type(uint256).max);

        // Sell side.
        vm.expectRevert(Dutchboard.Bad.selector);
        db.listERC20(address(liar), address(ok), 1e18, 1e18, 1e18, 0, uint40(1 days), 0);

        // Quote side.
        vm.expectRevert(Dutchboard.Bad.selector);
        db.listERC20(address(ok), address(liar), 1e18, 1e18, 1e18, 0, uint40(1 days), 0);
        vm.stopPrank();
    }

    /// @dev An honest ERC-20, an honest ERC-721 and a non-implementer all report
    ///      `false` for `0xffffffff`, so the control turns away only liars.
    function test_M03_honestTokensStillList() public {
        MockERC20 a = new MockERC20("A", 18);
        MockERC20 b = new MockERC20("B", 18);
        a.mint(seller, 10e18);

        vm.startPrank(seller);
        a.approve(address(db), type(uint256).max);
        uint256 id = db.listERC20(address(a), address(b), 1e18, 1e18, 1e18, 0, uint40(1 days), 0);
        vm.stopPrank();

        (, address s,,,,,,) = _leg(id);
        assertEq(s, seller, "honest ERC-20 pair still lists");
    }

    // --------------------------------------------------------------------- M-1

    /// @dev A 2 MB answer is not a `bool`, so it is not an opt-in: the board must
    ///      treat it as "this seller does not implement the protocol", pay them
    ///      ordinarily, and never copy the blob into its own memory. The gas the
    ///      griefer burns EXPANDING that blob is their own doing and is not
    ///      something the caller can bound short of capping forwarded gas — see
    ///      the note on `_notifyBeforeProceeds`. What the caller controls, and
    ///      what this pins, is that it does not pay to copy it back.
    function test_M01_oversizedCallbackAnswerIsNotAnOptIn() public {
        BlobSeller blob = new BlobSeller();
        MockERC20 lot = new MockERC20("LOT", 18);
        lot.mint(address(this), 10e18);
        lot.approve(address(db), type(uint256).max);

        uint256 id = db.listERC20For(
            address(blob), address(lot), address(quote), 1e18, 1e18, 1e18, 0, uint40(1 days), 0
        );

        quote.mint(buyer, 10e18);
        vm.startPrank(buyer);
        quote.approve(address(db), type(uint256).max);
        db.fill(id, 1e18, buyer, type(uint256).max);
        vm.stopPrank();

        assertEq(lot.balanceOf(buyer), 1e18, "fill still settled");
        assertEq(quote.balanceOf(address(blob)), 1e18, "seller paid ordinarily");
        assertEq(db.claimableProceeds(id, address(quote)), 0, "no proceeds accounting for a non-answer");
    }

    /// @dev The honest limit of `tryFillMany`, pinned so nobody mistakes it for
    ///      failure isolation against a hostile counterparty. It skips STALE-STATE
    ///      refusals only; a seller who reverts inside an accepted callback still
    ///      aborts the batch, exactly as a broken token would. Capping the
    ///      callback's gas would not change this — the seller can simply revert.
    function test_M01_hostileSellerStillAbortsTryFillMany() public {
        BlobSeller blob = new BlobSeller();
        blob.setRevert(true);
        MockERC20 lot = new MockERC20("LOT", 18);
        lot.mint(address(this), 20e18);
        lot.approve(address(db), type(uint256).max);

        uint256 bad = db.listERC20For(
            address(blob), address(lot), address(quote), 1e18, 1e18, 1e18, 0, uint40(1 days), 0
        );
        uint256 good = db.listERC20For(
            seller, address(lot), address(quote), 1e18, 1e18, 1e18, 0, uint40(1 days), 0
        );

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (bad, good);
        uint128[] memory takes = new uint128[](2);
        (takes[0], takes[1]) = (1e18, 1e18);
        uint256[] memory maxes = new uint256[](2);
        (maxes[0], maxes[1]) = (type(uint256).max, type(uint256).max);

        quote.mint(buyer, 10e18);
        vm.startPrank(buyer);
        quote.approve(address(db), type(uint256).max);
        vm.expectRevert();
        db.tryFillMany(ids, takes, maxes, buyer);
        vm.stopPrank();
    }

    /// @dev A revert inside an accepted callback must still abort the payment —
    ///      bounding the bubble must not turn a refusal into a success.
    function test_M01_revertingCallbackStillAbortsTheFill() public {
        BlobSeller blob = new BlobSeller();
        blob.setRevert(true);
        MockERC20 lot = new MockERC20("LOT", 18);
        lot.mint(address(this), 10e18);
        lot.approve(address(db), type(uint256).max);

        uint256 id = db.listERC20For(
            address(blob), address(lot), address(quote), 1e18, 1e18, 1e18, 0, uint40(1 days), 0
        );

        quote.mint(buyer, 10e18);
        vm.startPrank(buyer);
        quote.approve(address(db), type(uint256).max);
        vm.expectRevert();
        db.fill(id, 1e18, buyer, type(uint256).max);
        vm.stopPrank();
    }

    // --------------------------------------------------------------------- M-6

    /// @dev `_close` used to clear `liveClaimListing` for EVERY id in a bundle
    ///      before any of them moved, so while `ids[0]` was in flight the rest sat
    ///      board-owned and unregistered — exactly the state `afterOrderProceeds`
    ///      accepts as "an NFT arrived as proceeds". Each id is now released by its
    ///      own transfer, after the move, so the window never opens.
    function test_M06_bundleIdsStayRegisteredUntilTheirOwnTransfer() public {
        evil.mint(attacker, 2);
        evil.mint(attacker, 3);
        evil.mint(attacker, 4);

        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (2, 3, 4);
        vm.prank(attacker);
        uint256 bundle = db.listNFT(address(evil), address(quote), ids, 1e18, 1e18, 0, uint40(1 days));

        // Cancel returns the whole bundle and clears every registration with it.
        vm.prank(attacker);
        db.cancel(bundle);

        for (uint256 i; i < 3; ++i) {
            assertEq(evil.ownerOf(ids[i]), attacker, "returned");
            // A cleared registration is observable through the callback surface:
            // the board no longer accepts proceeds against this order id.
            vm.prank(address(evil));
            assertFalse(evil.callBefore(ids[i], address(quote), 1e18, false), "registration cleared");
        }
    }

    /// @dev The same for a filled bundle: registrations are gone once delivery
    ///      completes, and never before.
    function test_M06_filledBundleClearsEveryRegistration() public {
        evil.mint(attacker, 5);
        evil.mint(attacker, 6);

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (5, 6);
        vm.prank(attacker);
        uint256 bundle = db.listNFT(address(evil), address(quote), ids, 1e18, 1e18, 0, uint40(1 days));

        quote.mint(buyer, 10e18);
        vm.startPrank(buyer);
        quote.approve(address(db), type(uint256).max);
        db.fill(bundle, 0, buyer, type(uint256).max);
        vm.stopPrank();

        assertEq(evil.ownerOf(5), buyer);
        assertEq(evil.ownerOf(6), buyer);
        for (uint256 i; i < 2; ++i) {
            vm.prank(address(evil));
            assertFalse(evil.callBefore(ids[i], address(quote), 1e18, false), "registration cleared");
        }
    }

    // --------------------------------------------------------------------- L-1

    /// @dev `_payQuoteETH` now wraps through `_wrapETH`, so the exact-credit check
    ///      applies to the escrow-bound branch too. Behaviourally the seller must
    ///      still be paid in canonical WETH.
    function test_L01_ethProceedsToAnEscrowArriveAsWrappedWETH() public {
        EscrowSeller escrow = new EscrowSeller();
        MockERC20 lot = new MockERC20("LOT", 18);
        lot.mint(address(this), 10e18);
        lot.approve(address(db), type(uint256).max);

        uint256 id =
            db.listERC20For(address(escrow), address(lot), address(0), 1e18, 1e18, 1e18, 0, uint40(1 days), 0);

        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        db.fill{value: 1e18}(id, 1e18, buyer, type(uint256).max);

        assertEq(weth.balanceOf(address(escrow)), 1e18, "escrow seller paid in WETH");
        assertEq(address(escrow).balance, 0, "not in native ETH");
    }

    // ------------------------------------------------------------- SCOPE GAPS

    /// @dev The audit could not verify the four hardcoded selectors, and a silent
    ///      mismatch FAILS OPEN — the probe just never opts in — so nothing else
    ///      in the suite would catch it. Pin each to its derivation.
    function test_callbackSelectorsMatchTheirDerivations() public pure {
        assertEq(bytes4(keccak256("acceptsOrderProceeds(uint256)")), bytes4(0x33dbef94));
        assertEq(bytes4(keccak256("beforeOrderProceeds(uint256,address,uint256,bool)")), bytes4(0x8d27ed3f));
        assertEq(bytes4(keccak256("afterOrderProceeds(uint256,address,uint256,bool)")), bytes4(0x2814c622));
        assertEq(bytes4(keccak256("LiveOrderPosition()")), bytes4(0x28a93a2e));
    }

    /// @dev The live-position marker must actually be reported, and the standard
    ///      ERC-721 ids alongside it.
    function test_supportsInterfaceReportsTheLivePositionMarker() public view {
        assertTrue(db.supportsInterface(0x28a93a2e), "LiveOrderPosition");
        assertTrue(db.supportsInterface(0x80ac58cd), "ERC721");
        assertTrue(db.supportsInterface(0x01ffc9a7), "ERC165");
        assertFalse(db.supportsInterface(0xffffffff), "ERC-165 negative control");
    }

    /// @dev `receive()` must fit inside WETH9's 2300-gas `transfer` stipend, which
    ///      it does only because `weth` is an immutable comparison rather than an
    ///      SLOAD. This breaks silently if that ever changes.
    function test_receiveFitsInTheWETH9Stipend() public {
        vm.deal(address(weth), 1 ether);
        vm.prank(address(weth));
        (bool ok,) = address(db).call{value: 1 wei, gas: 2300}("");
        assertTrue(ok, "receive must fit the 2300-gas stipend");
    }

    function _leg(uint256 id)
        internal
        view
        returns (uint256, address seller_, address, address, bool, uint128, uint256, uint256)
    {
        (address s, address t, address q, bool n, uint128 r, uint256 lot_, uint256 p) = db.legOf(id);
        return (id, s, t, q, n, r, lot_, p);
    }
}
