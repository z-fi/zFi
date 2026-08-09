// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

/// @dev A collection that has one NFT escrowed on the board, and therefore holds
///      proceeds-callback authority. This is the attacker's whole foothold in the
///      GPT 5.6 Sol (Pro) report: authority is earned by legitimately listing your
///      own token, so it is permissionless and needs no reentrancy.
contract CallbackCollection is MockNFT {
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
}

/// @dev A standards-compliant ERC-721: it answers ERC-165 for `0x80ac58cd`, which
///      is the only thing distinguishing it from an ERC-20 across the shared
///      `balanceOf` / `transferFrom(address,address,uint256)` surface.
contract Standard721 is MockNFT {
    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd || id == 0x01ffc9a7;
    }
}

/// @notice Regression coverage for the findings in `audit/Dutchboard/gpt56-sol-pro.md`.
///
/// @dev Every test here fails against the pre-patch contract. The existing suites
///      pass either way, because they were written against the old design and never
///      exercise the callback layer adversarially — which is exactly why they are
///      not evidence that these bugs are closed.
contract DutchboardProceedsAuditTest is Test {
    Dutchboard db;
    MockWETH weth;
    MockERC20 lot;
    MockERC20 quote;
    MockNFT victimNFT;
    CallbackCollection evil;

    address victim = address(0xC01D);
    address attacker = address(0xBAD);
    address honest = address(0x400D);
    address buyer = address(0xB0B);
    address outsider = address(0x0175);

    uint256 evilListingId;

    function setUp() public {
        weth = new MockWETH();
        db = new Dutchboard(address(weth));
        lot = new MockERC20("LOT", 18);
        quote = new MockERC20("Q", 18);
        victimNFT = new MockNFT();
        evil = new CallbackCollection(db);

        // The attacker's foothold: one of their own NFTs, legitimately escrowed.
        evil.mint(attacker, 1);
        vm.startPrank(attacker);
        evil.setApprovalForAll(address(db), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        evilListingId = db.listNFT(address(evil), address(quote), ids, 1e18, 1e18, 0, uint40(1 days));
        vm.stopPrank();
    }

    function _listVictimNFT(uint256 tokenId) internal returns (uint256 id) {
        victimNFT.mint(victim, tokenId);
        vm.startPrank(victim);
        victimNFT.setApprovalForAll(address(db), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        id = db.listNFT(address(victimNFT), address(quote), ids, 5e18, 5e18, 0, uint40(1 days));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------- C-01

    /// @dev The reported exploit, verbatim: prove one token id is outside the
    ///      board, then credit a DIFFERENT one that is inside it. Pre-patch this
    ///      handed the attacker an unrelated user's escrowed NFT.
    function test_C01_mismatchedTokenIdBetweenCallbackLegsReverts() public {
        _listVictimNFT(100);
        victimNFT.mint(outsider, 101);

        vm.startPrank(address(evil));
        assertTrue(evil.callBefore(1, address(victimNFT), 101, true), "before accepts the outside id");
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        evil.callAfter(1, address(victimNFT), 100, true);
        vm.stopPrank();

        assertEq(victimNFT.ownerOf(100), address(db), "victim NFT still escrowed");
        assertFalse(db.claimableNFTProceeds(evilListingId, address(victimNFT), 100), "no forged credit");
    }

    /// @dev The same binding must hold for every field, not just the token id.
    function test_C01_everyCallbackFieldIsBound() public {
        victimNFT.mint(outsider, 101);
        MockERC20 other = new MockERC20("OTHER", 18);

        vm.startPrank(address(evil));
        assertTrue(evil.callBefore(1, address(victimNFT), 101, true));

        // Wrong token.
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        evil.callAfter(1, address(other), 101, true);
        // Wrong orderId.
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        evil.callAfter(99, address(victimNFT), 101, true);
        // Wrong nft flag.
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        evil.callAfter(1, address(victimNFT), 101, false);
        vm.stopPrank();
    }

    /// @dev An NFT already backing listing escrow can never be nominated as an
    ///      incoming payment: it is already inside the board.
    function test_C01_cannotNominateAnAlreadyEscrowedNFT() public {
        _listVictimNFT(100);

        vm.prank(address(evil));
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        evil.callBefore(1, address(victimNFT), 100, true);
    }

    /// @dev The board's own receipts are minted, never delivered.
    function test_C01_ownReceiptsCannotBeCreditedAsProceeds() public {
        vm.prank(address(evil));
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        evil.callBefore(1, address(db), evilListingId, true);
    }

    /// @dev The honest path still works, and it is the ONLY one that does: the
    ///      same token id, genuinely transferred in between the two legs.
    function test_C01_honestNFTArrivalIsStillCredited() public {
        victimNFT.mint(outsider, 101);

        vm.prank(address(evil));
        assertTrue(evil.callBefore(1, address(victimNFT), 101, true));

        vm.prank(outsider);
        victimNFT.transferFrom(outsider, address(db), 101);

        vm.prank(address(evil));
        evil.callAfter(1, address(victimNFT), 101, true);

        assertTrue(db.claimableNFTProceeds(evilListingId, address(victimNFT), 101), "credited");
        assertTrue(db.heldAsProceeds(address(victimNFT), 101), "custody state recorded");

        vm.prank(attacker);
        db.claimNFTProceeds(evilListingId, address(victimNFT), 101, attacker);
        assertEq(victimNFT.ownerOf(101), attacker, "claimed");
        assertFalse(db.heldAsProceeds(address(victimNFT), 101), "custody state cleared");
    }

    /// @dev One board-held NFT backs exactly one liability. A collection must not
    ///      be able to open listing escrow over an NFT already owed out as proceeds
    ///      via the verify-don't-move push hook.
    function test_C01_proceedsNFTCannotAlsoBecomeListingEscrow() public {
        victimNFT.mint(outsider, 101);
        vm.prank(address(evil));
        evil.callBefore(1, address(victimNFT), 101, true);
        vm.prank(outsider);
        victimNFT.transferFrom(outsider, address(db), 101);
        vm.prank(address(evil));
        evil.callAfter(1, address(victimNFT), 101, true);

        Dutchboard.PushTerms memory t = Dutchboard.PushTerms({
            quote: address(quote),
            startPrice: 1e18,
            endPrice: 1e18,
            startTime: 0,
            duration: uint40(1 days)
        });
        vm.prank(address(victimNFT));
        vm.expectRevert(Dutchboard.Bad.selector);
        db.onERC721Received(address(victimNFT), attacker, 101, abi.encode(keccak256("Dutchboard.PushTerms.v1"), t));
    }

    // ------------------------------------------------------------------- C-02

    /// @dev The reported drainage sequence. A listing deposit raises the physical
    ///      balance AND `escrowed`, so pre-patch it read as a proceeds arrival and
    ///      created a second liability over the same tokens.
    function test_C02_listingDepositCannotBeCountedAsProceeds() public {
        uint256 B = 1_000e18;
        lot.mint(honest, B);
        vm.startPrank(honest);
        lot.approve(address(db), type(uint256).max);
        db.listERC20(address(lot), address(quote), uint128(B), 10e18, 10e18, 0, uint40(1 days), 0);
        vm.stopPrank();

        assertEq(db.escrowed(address(lot)), B);
        assertEq(db.freeBalance(address(lot)), 0, "no unallocated balance");

        vm.prank(address(evil));
        assertTrue(evil.callBefore(1, address(lot), B, false), "snapshot taken");

        // Flash-funded interleave: real tokens, real balance increase, but the
        // deposit creates its own matching liability.
        lot.mint(attacker, B);
        vm.startPrank(attacker);
        lot.approve(address(db), type(uint256).max);
        db.listERC20For(attacker, address(lot), address(quote), uint128(B), 10e18, 10e18, 0, uint40(1 days), 0);
        vm.stopPrank();

        assertEq(lot.balanceOf(address(db)), 2 * B, "balance really did double");
        assertEq(db.freeBalance(address(lot)), 0, "but nothing is unallocated");

        vm.prank(address(evil));
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        evil.callAfter(1, address(lot), B, false);

        assertEq(db.claimableProceeds(evilListingId, address(lot)), 0, "no forged credit");
        assertEq(db.totalClaimable(address(lot)), 0);
        _assertSolvent(address(lot));
    }

    /// @dev A genuine, unaccounted arrival is still credited.
    function test_C02_honestERC20ArrivalIsCredited() public {
        uint256 amt = 42e18;

        vm.prank(address(evil));
        assertTrue(evil.callBefore(1, address(lot), amt, false));

        lot.mint(address(db), amt); // an arrival that creates no matching liability

        vm.prank(address(evil));
        evil.callAfter(1, address(lot), amt, false);

        assertEq(db.claimableProceeds(evilListingId, address(lot)), amt);
        assertEq(db.totalClaimable(address(lot)), amt);
        assertEq(db.freeBalance(address(lot)), 0, "credited balance is now allocated");

        vm.prank(attacker);
        db.claimSurplus(evilListingId, address(lot), attacker);
        assertEq(lot.balanceOf(attacker), amt);
        assertEq(db.totalClaimable(address(lot)), 0, "aggregate released");
        _assertSolvent(address(lot));
    }

    /// @dev Free balance is invariant under every ordinary operation, which is the
    ///      property the fix actually rests on — not just the one reported sequence.
    function test_C02_freeBalanceIsInvariantUnderOrdinaryOperations() public {
        lot.mint(honest, 500e18);
        quote.mint(buyer, 1_000_000e18);
        vm.prank(honest);
        lot.approve(address(db), type(uint256).max);
        vm.prank(buyer);
        quote.approve(address(db), type(uint256).max);

        vm.prank(honest);
        uint256 id = db.listERC20(address(lot), address(quote), 500e18, 100e18, 100e18, 0, uint40(1 days), 0);
        assertEq(db.freeBalance(address(lot)), 0, "after list");

        vm.prank(buyer);
        db.fill(id, 200e18, buyer, type(uint256).max);
        assertEq(db.freeBalance(address(lot)), 0, "after partial fill");

        vm.prank(honest);
        db.cancel(id);
        assertEq(db.freeBalance(address(lot)), 0, "after cancel");
        _assertSolvent(address(lot));
    }

    /// @dev Two concurrent settlements on the same token must compose, not collide.
    function test_C02_nestedCallbacksOnTheSameTokenCompose() public {
        CallbackCollection evil2 = new CallbackCollection(db);
        evil2.mint(attacker, 7);
        vm.startPrank(attacker);
        evil2.setApprovalForAll(address(db), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        uint256 id2 = db.listNFT(address(evil2), address(quote), ids, 1e18, 1e18, 0, uint40(1 days));
        vm.stopPrank();

        vm.prank(address(evil));
        evil.callBefore(1, address(lot), 10e18, false);
        vm.prank(address(evil2));
        evil2.callBefore(7, address(lot), 20e18, false);

        lot.mint(address(db), 20e18);
        vm.prank(address(evil2));
        evil2.callAfter(7, address(lot), 20e18, false);

        lot.mint(address(db), 10e18);
        vm.prank(address(evil));
        evil.callAfter(1, address(lot), 10e18, false);

        assertEq(db.claimableProceeds(id2, address(lot)), 20e18);
        assertEq(db.claimableProceeds(evilListingId, address(lot)), 10e18);
        assertEq(db.totalClaimable(address(lot)), 30e18);
        _assertSolvent(address(lot));
    }

    /// @dev Reusing one real arrival for two credits must fail on the second.
    function test_C02_oneArrivalCannotSatisfyTwoSettlements() public {
        CallbackCollection evil2 = new CallbackCollection(db);
        evil2.mint(attacker, 7);
        vm.startPrank(attacker);
        evil2.setApprovalForAll(address(db), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        db.listNFT(address(evil2), address(quote), ids, 1e18, 1e18, 0, uint40(1 days));
        vm.stopPrank();

        vm.prank(address(evil));
        evil.callBefore(1, address(lot), 10e18, false);
        vm.prank(address(evil2));
        evil2.callBefore(7, address(lot), 10e18, false);

        lot.mint(address(db), 10e18); // ONE arrival

        vm.prank(address(evil));
        evil.callAfter(1, address(lot), 10e18, false);

        vm.prank(address(evil2));
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        evil2.callAfter(7, address(lot), 10e18, false);

        assertEq(db.totalClaimable(address(lot)), 10e18, "only the real arrival was credited");
        _assertSolvent(address(lot));
    }

    // ------------------------------------------------------------------- M-01

    function test_M01_standardERC721RejectedFromTheERC20SellPath() public {
        Standard721 nft = new Standard721();
        nft.mint(attacker, 1);
        vm.prank(attacker);
        vm.expectRevert(Dutchboard.Bad.selector);
        db.listERC20(address(nft), address(quote), 1, 1e18, 1e18, 0, uint40(1 days), 0);
    }

    function test_M01_standardERC721RejectedAsAQuoteAsset() public {
        Standard721 nft = new Standard721();
        lot.mint(attacker, 1e18);
        vm.startPrank(attacker);
        lot.approve(address(db), type(uint256).max);
        vm.expectRevert(Dutchboard.Bad.selector);
        db.listERC20(address(lot), address(nft), 1e18, 1, 1, 0, uint40(1 days), 0);
        vm.stopPrank();
    }

    /// @dev An ERC-721 lot is still listable through the NFT path — the rejection
    ///      is scoped to the fungible paths, not to ERC-721s generally.
    function test_M01_nftPathStillAcceptsAStandardCollection() public {
        Standard721 nft = new Standard721();
        nft.mint(attacker, 5);
        vm.startPrank(attacker);
        nft.setApprovalForAll(address(db), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 5;
        db.listNFT(address(nft), address(quote), ids, 1e18, 1e18, 0, uint40(1 days));
        vm.stopPrank();
        assertEq(nft.ownerOf(5), address(db));
    }

    /// @dev Documents the accepted limitation: the probe rejects only on an
    ///      affirmative ERC-165 answer, so a collection that does not declare the
    ///      interface still reaches the fungible path. Requiring ERC-165 would make
    ///      pre-165 collections unlistable for no gain — the NFT paths prove custody
    ///      by `ownerOf` rather than by self-report. Non-standard assets remain
    ///      outside the security model.
    function test_M01_nonDeclaringCollectionIsStillOutsideTheModel() public {
        MockNFT quiet = new MockNFT(); // no supportsInterface
        quiet.mint(attacker, 1);
        vm.prank(attacker);
        // Not rejected by the interface probe; it fails later, on the balance delta.
        vm.expectRevert();
        db.listERC20(address(quiet), address(quote), 1, 1e18, 1e18, 0, uint40(1 days), 0);
    }

    // -------------------------------------------------------------------- HELP

    function _assertSolvent(address token) internal view {
        assertGe(
            MockERC20(token).balanceOf(address(db)),
            db.escrowed(token) + db.totalClaimable(token),
            "balanceOf >= escrowed + totalClaimable"
        );
    }
}
