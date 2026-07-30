// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH, MockERC721} from "./SwapboardMocks.sol";

/// @notice The `*For` sponsorship surface: zRouter (or anyone) funds an order
///         from its own balance while crediting the book entry to someone else.
///
///         The security claim these functions rest on is that naming a maker
///         cannot debit that maker. Without it, anyone holding a standing
///         approval to the board could be forced into an order on terms they
///         never chose, and self-filled. That claim is the point of this file.
contract SwapboardMakerForTest is Test {
    Swapboard board;
    MockWETH weth;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address sponsor = address(0x5D0);
    address maker = address(0xA11CE);
    address victim = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        board = new Swapboard(address(weth));
        tokenA = new MockERC20("AAA", 18);
        tokenB = new MockERC20("BBB", 6);

        tokenA.mint(sponsor, 1_000e18);
        vm.prank(sponsor);
        tokenA.approve(address(board), type(uint256).max);
    }

    // -------------------------------------------------- THE SECURITY PROPERTY

    /// A victim with an unlimited standing approval must be untouched when a
    /// stranger names them as maker. The escrow comes from the caller.
    function test_namingAMakerCannotDebitThatMaker() public {
        tokenA.mint(victim, 500e18);
        vm.prank(victim);
        tokenA.approve(address(board), type(uint256).max);

        uint256 victimBefore = tokenA.balanceOf(victim);
        uint256 sponsorBefore = tokenA.balanceOf(sponsor);

        vm.prank(sponsor);
        uint256 id = board.createOrderFor(
            victim, address(tokenA), 10e18, address(tokenB), 100e6, true, 0, false, false, address(0)
        );

        assertEq(tokenA.balanceOf(victim), victimBefore, "victim must not be debited");
        assertEq(tokenA.balanceOf(sponsor), sponsorBefore - 10e18, "sponsor funds the escrow");
        assertEq(tokenA.balanceOf(address(board)), 10e18, "board holds the escrow");

        (address m,,,,,,,,,,) = board.orders(id);
        assertEq(m, victim, "order is credited to the named maker");
    }

    /// The gift is real: the named maker owns the order and can cancel it,
    /// receiving escrow the sponsor paid for.
    function test_namedMakerOwnsAndCanCancel() public {
        vm.prank(sponsor);
        uint256 id = board.createOrderFor(
            maker, address(tokenA), 10e18, address(tokenB), 100e6, true, 0, false, false, address(0)
        );

        // The sponsor is not the maker and cannot cancel.
        vm.prank(sponsor);
        vm.expectRevert();
        board.cancelOrder(id);

        uint256 makerBefore = tokenA.balanceOf(maker);
        vm.prank(maker);
        board.cancelOrder(id);
        assertEq(tokenA.balanceOf(maker) - makerBefore, 10e18, "escrow returns to the named maker");
    }

    function test_zeroMakerReverts() public {
        vm.prank(sponsor);
        vm.expectRevert();
        board.createOrderFor(
            address(0), address(tokenA), 10e18, address(tokenB), 100e6, true, 0, false, false, address(0)
        );
    }

    // --------------------------------------------------------------- ETH PATH

    /// createOrderWithEthFor bypasses _createOrder and calls _store directly, so
    /// its guards are duplicated rather than inherited - worth pinning.
    function test_ethSponsorshipCreditsMakerAndEscrowsWeth() public {
        vm.deal(sponsor, 5 ether);
        uint256 sponsorBefore = sponsor.balance;

        vm.prank(sponsor);
        uint256 id =
            board.createOrderWithEthFor{value: 1 ether}(maker, address(tokenB), 100e6, true, 0, false, address(0));

        assertEq(sponsor.balance, sponsorBefore - 1 ether, "sponsor pays the ETH");
        assertEq(weth.balanceOf(address(board)), 1 ether, "ETH is wrapped into board escrow");

        (address m,,,,,,, address tA, uint256 aA,,) = board.orders(id);
        assertEq(m, maker, "order credited to the named maker");
        assertEq(tA, address(weth), "tokenA is WETH");
        assertEq(aA, 1 ether, "escrow equals msg.value");

        // And the maker can retrieve it.
        vm.prank(maker);
        board.cancelOrder(id);
        assertEq(weth.balanceOf(maker), 1 ether, "escrow returns to the named maker");
    }

    function test_ethZeroMakerReverts() public {
        vm.deal(sponsor, 1 ether);
        vm.prank(sponsor);
        vm.expectRevert();
        board.createOrderWithEthFor{value: 1 ether}(address(0), address(tokenB), 100e6, true, 0, false, address(0));
    }

    function test_ethZeroValueReverts() public {
        vm.prank(sponsor);
        vm.expectRevert();
        board.createOrderWithEthFor{value: 0}(maker, address(tokenB), 100e6, true, 0, false, address(0));
    }

    // ------------------------------------------------------------------- NFTs

    /// The NFT leg moves from the caller too, not from the named maker.
    function test_nftSponsorshipMovesTheCallersNft() public {
        MockERC721 nft = new MockERC721();
        nft.mint(sponsor, 7);
        vm.prank(sponsor);
        nft.setApprovalForAll(address(board), true);

        vm.prank(sponsor);
        uint256 id =
            board.createOrderFor(maker, address(nft), 7, address(tokenB), 100e6, false, 0, true, false, address(0));

        assertEq(nft.ownerOf(7), address(board), "board escrows the sponsor's NFT");
        (address m,,,,,,,,,,) = board.orders(id);
        assertEq(m, maker, "NFT order credited to the named maker");

        vm.prank(maker);
        board.cancelOrder(id);
        assertEq(nft.ownerOf(7), maker, "NFT returns to the named maker");
    }
}
