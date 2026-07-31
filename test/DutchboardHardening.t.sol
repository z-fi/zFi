// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockNFT} from "./SwapboardMocks.sol";

/// @dev A seller contract with neither receive nor fallback.
contract RejectETH {}

/// @dev MockNFT plus the safeTransferFrom overload that drives push listings.
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

/// @notice Regressions for the audit hardening pass:
///           - a scheduled listing is closed until its window opens
///           - the canonical wrapper is refused as a delivery address
///           - codeless lot and quote addresses are refused at the escrow boundary
///           - a lot that decayed to free settles even for a seller that rejects ETH
contract DutchboardHardeningTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    Dutchboard board;
    MockERC20 lot;
    MockERC20 quote;

    address seller = address(0xA11CE);
    address taker = address(0xB0B);

    function setUp() public {
        board = new Dutchboard(WETH);
        lot = new MockERC20("LOT", 18);
        quote = new MockERC20("QUOTE", 18);

        lot.mint(seller, 1_000e18);
        quote.mint(taker, 1_000_000e18);
        vm.prank(seller);
        lot.approve(address(board), type(uint256).max);
        vm.prank(taker);
        quote.approve(address(board), type(uint256).max);
        vm.deal(taker, 100 ether);
    }

    function _one(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }

    // ------------------------------------------------------ THE WRAPPER BINDING

    /// The wrapper is a constructor parameter rather than a hardcoded mainnet
    /// constant. A hardcoded address is codeless off mainnet, which would leave
    /// `cancelUnwrap` permanently broken and `receive` guarding the wrong sender -
    /// a silent deployment footgun rather than a compile error.
    function test_ConstructorRefusesACodelessWrapper() public {
        vm.expectRevert(Dutchboard.Bad.selector);
        new Dutchboard(address(0));

        vm.expectRevert(Dutchboard.Bad.selector);
        new Dutchboard(address(0xDEAD));
    }

    function test_WrapperIsExposedAndBoundAtConstruction() public view {
        assertEq(board.weth(), WETH, "wrapper not bound");
    }

    /// `receive` is bound to the same immutable, so only the wrapper this board was
    /// deployed against may deliver ETH through an ordinary empty call.
    function test_ReceiveOnlyAcceptsTheBoundWrapper() public {
        vm.deal(taker, 1 ether);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Dutchboard.NotWETH.selector, WETH, taker));
        payable(address(board)).call{value: 1 ether}("");
    }

    // ------------------------------------------- SCHEDULED LISTINGS ARE CLOSED

    /// `_priceOf` returns `startPrice` before the window, so without an explicit gate
    /// the schedule would shape only the curve and a lot listed for next week could be
    /// taken today. The taker would pay the maximum, so nothing is stolen - but
    /// `startTime` has to mean what it says.
    function test_ScheduledErc20ListingIsClosedBeforeItOpens() public {
        uint40 start = uint40(block.timestamp + 1 days);
        vm.prank(seller);
        uint256 id = board.listERC20(address(lot), address(quote), 100e18, 100e18, 10e18, start, 1 hours);

        vm.prank(taker);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill(id, 100e18, taker, type(uint256).max);

        assertEq(lot.balanceOf(taker), 0, "lot left escrow before the window opened");
    }

    /// The gate is exactly `block.timestamp < startTime`, so the opening block itself
    /// is fillable - and at `startPrice`, the top of the curve.
    function test_ScheduledListingOpensAtItsStartTime() public {
        uint40 start = uint40(block.timestamp + 1 days);
        vm.prank(seller);
        uint256 id = board.listERC20(address(lot), address(quote), 100e18, 100e18, 10e18, start, 1 hours);

        vm.warp(start);
        assertEq(board.costOf(id, 100e18), 100e18, "did not open at startPrice");

        uint256 before = quote.balanceOf(seller);
        vm.prank(taker);
        board.fill(id, 100e18, taker, type(uint256).max);

        assertEq(lot.balanceOf(taker), 100e18, "lot not delivered");
        assertEq(quote.balanceOf(seller) - before, 100e18, "seller not paid the full ask");
    }

    /// A listing with `startTime == 0` still opens in its creation block: the gate must
    /// not have made every listing wait a second.
    function test_ImmediateListingIsFillableInTheSameBlock() public {
        vm.prank(seller);
        uint256 id = board.listERC20(address(lot), address(quote), 100e18, 100e18, 10e18, 0, 1 hours);

        vm.prank(taker);
        board.fill(id, 100e18, taker, type(uint256).max);
        assertEq(lot.balanceOf(taker), 100e18, "immediate listing did not fill");
    }

    /// The NFT branch shares the gate, which sits ahead of the isNFT split.
    function test_ScheduledNftListingIsClosedBeforeItOpens() public {
        MockNFT nft = new MockNFT();
        nft.mint(seller, 1);
        uint40 start = uint40(block.timestamp + 1 days);

        vm.startPrank(seller);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(quote), _one(1), 100e18, 10e18, start, 1 hours);
        vm.stopPrank();

        vm.prank(taker);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill(id, 0, taker, type(uint256).max);

        assertEq(nft.ownerOf(1), address(board), "bundle left escrow before the window opened");

        vm.warp(start);
        vm.prank(taker);
        board.fill(id, 0, taker, type(uint256).max);
        assertEq(nft.ownerOf(1), taker, "bundle did not settle once open");
    }

    /// `costOf` is what a UI reads to decide fillability, so it has to agree with the
    /// gate rather than quoting a price the fill would refuse.
    function test_CostOfReportsZeroUntilTheWindowOpens() public {
        uint40 start = uint40(block.timestamp + 1 days);
        vm.prank(seller);
        uint256 id = board.listERC20(address(lot), address(quote), 100e18, 100e18, 10e18, start, 1 hours);

        assertEq(board.costOf(id, 100e18), 0, "quoted a cost for a closed window");
        assertEq(board.priceOf(id), 100e18, "schedule price should still be readable");

        vm.warp(start);
        assertEq(board.costOf(id, 100e18), 100e18, "did not quote once open");
    }

    /// A batch is atomic, so one unopened leg aborts the whole plan rather than
    /// settling the rest around it.
    function test_FillManyAbortsOnAnUnopenedLeg() public {
        vm.startPrank(seller);
        uint256 open = board.listERC20(address(lot), address(quote), 10e18, 10e18, 10e18, 0, 1 hours);
        uint256 scheduled = board.listERC20(
            address(lot), address(quote), 10e18, 10e18, 10e18, uint40(block.timestamp + 1 days), 1 hours
        );
        vm.stopPrank();

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (open, scheduled);
        uint128[] memory takes = new uint128[](2);
        (takes[0], takes[1]) = (10e18, 10e18);
        uint256[] memory maxCosts = new uint256[](2);
        (maxCosts[0], maxCosts[1]) = (type(uint256).max, type(uint256).max);

        vm.prank(taker);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fillMany(ids, takes, maxCosts, taker);

        assertEq(lot.balanceOf(taker), 0, "open leg settled despite the aborted batch");
    }

    // ------------------------------------------------ WETH AS A PAYOUT ADDRESS

    /// An unwrapped payout to the wrapper is re-wrapped to whoever sent it, and a lot
    /// delivered there sits outside any accounting. Immutable contract, no recovery.
    function test_FillRefusesTheWrapperAsRecipient() public {
        vm.prank(seller);
        uint256 id = board.listERC20(address(lot), address(quote), 100e18, 100e18, 10e18, 0, 1 hours);

        vm.prank(taker);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill(id, 100e18, WETH, type(uint256).max);

        // The board itself and the zero address stay refused alongside it.
        vm.prank(taker);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill(id, 100e18, address(board), type(uint256).max);

        vm.prank(taker);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill(id, 100e18, address(0), type(uint256).max);

        assertEq(lot.balanceOf(address(board)), 100e18, "escrow moved");
    }

    function test_FillManyRefusesTheWrapperAsRecipient() public {
        vm.prank(seller);
        uint256 id = board.listERC20(address(lot), address(quote), 100e18, 100e18, 10e18, 0, 1 hours);

        uint128[] memory takes = new uint128[](1);
        takes[0] = 100e18;
        uint256[] memory maxCosts = new uint256[](1);
        maxCosts[0] = type(uint256).max;

        vm.prank(taker);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fillMany(_one(id), takes, maxCosts, WETH);
    }

    // ----------------------------------------------------- CODELESS ASSETS

    function test_ListRefusesACodelessLotToken() public {
        vm.prank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(address(0xDEAD), address(quote), 100e18, 100e18, 10e18, 0, 1 hours);

        vm.prank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(address(0), address(quote), 100e18, 100e18, 10e18, 0, 1 hours);
    }

    function test_ListRefusesACodelessQuote() public {
        vm.prank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(address(lot), address(0xDEAD), 100e18, 100e18, 10e18, 0, 1 hours);
    }

    /// address(0) is native ETH, not a codeless token, and is the one exemption.
    function test_ListAcceptsNativeEthQuote() public {
        vm.prank(seller);
        uint256 id = board.listERC20(address(lot), address(0), 100e18, 1 ether, 1 ether, 0, 1 hours);
        assertEq(board.quoteOf(id), address(0), "native quote refused");

        uint256 before = seller.balance;
        vm.prank(taker);
        board.fill{value: 1 ether}(id, 100e18, taker, type(uint256).max);
        assertEq(seller.balance - before, 1 ether, "seller not paid in ETH");
    }

    /// The concrete hole the check closes. `_payQuoteToken` returns early on a zero
    /// amount, so before this a lot quoted in a codeless address and decayed to
    /// `endPrice == 0` would have settled without the quote ever being called -
    /// the one path where a later `balanceOf` revert did not backstop the boundary.
    function test_CodelessQuoteCannotBeSmuggledInViaAFullyDecayedLot() public {
        vm.prank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(address(lot), address(0xDEAD), 100e18, 100e18, 0, 0, 1 hours);
    }

    function test_ListNftRefusesCodelessAssets() public {
        MockNFT nft = new MockNFT();
        nft.mint(seller, 1);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(board), true);

        vm.expectRevert(Dutchboard.Bad.selector);
        board.listNFT(address(nft), address(0xDEAD), _one(1), 100e18, 10e18, 0, 1 hours);

        vm.expectRevert(Dutchboard.Bad.selector);
        board.listNFT(address(0xDEAD), address(quote), _one(1), 100e18, 10e18, 0, 1 hours);
        vm.stopPrank();

        assertEq(nft.ownerOf(1), seller, "escrow moved on a refused listing");
    }

    function test_PushListingRefusesACodelessQuote() public {
        SafeMockNFT nft = new SafeMockNFT();
        nft.mint(seller, 1);

        bytes memory terms = abi.encode(
            Dutchboard.PushTerms({
                quote: address(0xDEAD),
                startPrice: 100e18,
                endPrice: 10e18,
                startTime: 0,
                duration: 1 hours
            })
        );

        vm.prank(seller);
        vm.expectRevert(Dutchboard.Bad.selector);
        nft.safeTransferFrom(seller, address(board), 1, terms);
    }

    function test_PushListingStillAcceptsAGoodQuote() public {
        SafeMockNFT nft = new SafeMockNFT();
        nft.mint(seller, 1);

        bytes memory terms = abi.encode(
            Dutchboard.PushTerms({
                quote: address(quote),
                startPrice: 100e18,
                endPrice: 10e18,
                startTime: 0,
                duration: 1 hours
            })
        );

        vm.prank(seller);
        nft.safeTransferFrom(seller, address(board), 1, terms);

        assertEq(board.getListing(0).seller, seller, "push listing not created");
        assertEq(nft.ownerOf(1), address(board), "escrow not held");
    }

    // ------------------------------------------------ A LOT THAT DECAYED FREE

    /// A lot may decay to free, and a zero-value call still hands the seller control
    /// with all gas. A seller contract with no `receive` would otherwise brick its own
    /// listing at the bottom of the curve.
    function test_FullyDecayedEthLotSettlesForASellerThatRejectsEth() public {
        address rejecting = address(new RejectETH());

        lot.mint(address(this), 100e18);
        lot.approve(address(board), type(uint256).max);
        uint256 id = board.listERC20For(rejecting, address(lot), address(0), 100e18, 1 ether, 0, 0, 1 hours);

        vm.warp(block.timestamp + 1 hours + 1);
        assertEq(board.costOf(id, 100e18), 0, "did not decay to free");

        vm.prank(taker);
        board.fill(id, 100e18, taker, type(uint256).max);

        assertEq(lot.balanceOf(taker), 100e18, "free lot did not settle");
        assertEq(rejecting.balance, 0, "seller was paid something");
    }

    /// The skip is strictly the zero case: a seller that cannot take payment still
    /// blocks a fill that actually owes it something.
    function test_ANonZeroEthPaymentToARejectingSellerStillReverts() public {
        address rejecting = address(new RejectETH());

        lot.mint(address(this), 100e18);
        lot.approve(address(board), type(uint256).max);
        uint256 id = board.listERC20For(rejecting, address(lot), address(0), 100e18, 1 ether, 0, 0, 1 hours);

        vm.prank(taker);
        vm.expectRevert();
        board.fill{value: 1 ether}(id, 100e18, taker, type(uint256).max);
    }

    /// A partial fill priced down to zero must not decrement the lot for free while
    /// still counting as a settlement: `remaining` has to track it exactly.
    function test_FreeFillsStillDecrementRemainingExactly() public {
        address rejecting = address(new RejectETH());

        lot.mint(address(this), 100e18);
        lot.approve(address(board), type(uint256).max);
        uint256 id = board.listERC20For(rejecting, address(lot), address(0), 100e18, 1 ether, 0, 0, 1 hours);

        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(taker);
        board.fill(id, 40e18, taker, type(uint256).max);

        assertEq(board.getListing(id).remaining, 60e18, "remainder not decremented");
        assertEq(board.getListing(id).initial, 100e18, "reference lot size moved");

        vm.prank(taker);
        board.fill(id, 60e18, taker, type(uint256).max);
        assertEq(board.getListing(id).seller, address(0), "listing not closed on the last unit");
        assertEq(lot.balanceOf(taker), 100e18, "lot not fully delivered");
    }
}
