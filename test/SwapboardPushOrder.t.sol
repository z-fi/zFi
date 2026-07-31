// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// @dev MockNFT plus the safeTransferFrom overload that drives push orders.
///      Moves the token BEFORE calling the receiver, as a real 721 does, so the
///      board's ownership check sees settled state.
contract SafeMockNFT is MockNFT {
    function safeTransferFrom(address f, address t, uint256 id, bytes calldata data) external {
        require(ownerOf[id] == f, "not owner");
        require(msg.sender == f || isApprovedForAll[f][msg.sender], "not approved");
        ownerOf[id] = t;
        bytes4 got = IERC721Receiver(t).onERC721Received(msg.sender, f, id, data);
        require(got == IERC721Receiver.onERC721Received.selector, "bad receiver");
    }
}

/// @dev A collection that claims the board owns anything asked of it, used to
/// probe whether a fabricated collection can mint an order over real escrow.
contract LyingCollection {
    address board;

    constructor(address b) {
        board = b;
    }

    function ownerOf(uint256) external view returns (address) {
        return board;
    }

    function push(address to, uint256 id, bytes calldata data) external {
        Swapboard(payable(to)).onERC721Received(msg.sender, msg.sender, id, data);
    }
}

contract SwapboardPushOrderTest is Test {
    Swapboard sb;
    MockWETH weth;
    MockERC20 usdc;
    SafeMockNFT nft;

    address maker = address(0xACE);
    address taker = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        usdc = new MockERC20("USDC", 6);
        nft = new SafeMockNFT();

        nft.mint(maker, 1);
        nft.mint(maker, 2);
        usdc.mint(taker, 1_000_000e6);
        vm.prank(taker);
        usdc.approve(address(sb), type(uint256).max);
    }

    function _terms(address tokenB, uint256 amountB, uint64 expiry, bool nftB, address cp)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(Swapboard.PushOrder(tokenB, amountB, expiry, nftB, cp));
    }

    /// @dev The whole point: one transaction, no prior approval, order live.
    function test_PushCreatesAnOrderInOneTransaction() public {
        vm.prank(maker);
        nft.safeTransferFrom(maker, address(sb), 1, _terms(address(usdc), 5_000e6, 0, false, address(0)));

        Swapboard.Order memory o = _order(0);
        assertEq(o.maker, maker, "sender became the maker");
        assertEq(o.tokenA, address(nft), "collection is the caller, not calldata");
        assertEq(o.amountA, 1, "tokenId escrowed");
        assertTrue(o.nftA, "NFT side marked");
        assertFalse(o.partialFill, "an NFT never partially fills");
        assertEq(o.tokenB, address(usdc));
        assertEq(o.amountB, 5_000e6);
        assertTrue(o.active);
        assertEq(nft.ownerOf(1), address(sb), "board holds the escrow");
    }

    function test_PushedOrderFillsNormally() public {
        vm.prank(maker);
        nft.safeTransferFrom(maker, address(sb), 1, _terms(address(usdc), 5_000e6, 0, false, address(0)));

        vm.prank(taker);
        sb.fillOrder(0, block.timestamp, 0, 0, taker);

        assertEq(nft.ownerOf(1), taker, "taker got the NFT");
        assertEq(usdc.balanceOf(maker), 5_000e6, "maker was paid");
    }

    /// @dev An unsolicited token is still refused, so a mistaken send cannot be
    /// silently escrowed with no owner - the behaviour this board had before.
    function test_UnsolicitedPushStillReverts() public {
        vm.prank(maker);
        vm.expectRevert(Swapboard.DirectNFTTransfer.selector);
        nft.safeTransferFrom(maker, address(sb), 1, "");
    }

    function test_MalformedTermsAreRefused() public {
        vm.prank(maker);
        vm.expectRevert(Swapboard.DirectNFTTransfer.selector);
        nft.safeTransferFrom(maker, address(sb), 1, hex"deadbeef");
    }

    function test_PayoutAddressRulesApplyToThePushedMaker() public {
        // The board and the wrapper are refused as makers exactly as they are
        // at ordinary creation: a payout there would be unrecoverable.
        vm.expectRevert(Swapboard.BadMaker.selector);
        vm.prank(address(sb));
        sb.onERC721Received(address(sb), address(sb), 1, _terms(address(usdc), 1e6, 0, false, address(0)));
    }

    function test_DegenerateTermsAreRefused() public {
        bytes memory zeroToken = _terms(address(0), 1e6, 0, false, address(0));
        vm.prank(maker);
        vm.expectRevert(Swapboard.ZeroAddress.selector);
        nft.safeTransferFrom(maker, address(sb), 1, zeroToken);

        bytes memory zeroAmount = _terms(address(usdc), 0, 0, false, address(0));
        vm.prank(maker);
        vm.expectRevert(Swapboard.ZeroAmount.selector);
        nft.safeTransferFrom(maker, address(sb), 1, zeroAmount);

        uint64 past = uint64(block.timestamp);
        bytes memory stale = _terms(address(usdc), 1e6, past, false, address(0));
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.ExpiryInPast.selector, past));
        nft.safeTransferFrom(maker, address(sb), 1, stale);
    }

    /// @dev The hardening that matters. A fabricated collection may mint an
    /// order, but tokenA is ITS OWN address - never the real collection whose
    /// token it lies about - so it cannot list escrow that is already backing
    /// somebody else's order.
    function test_FabricatedCollectionCannotListRealEscrow() public {
        // A genuine order first, so real escrow exists to be targeted.
        vm.prank(maker);
        nft.safeTransferFrom(maker, address(sb), 1, _terms(address(usdc), 5_000e6, 0, false, address(0)));

        LyingCollection liar = new LyingCollection(address(sb));
        liar.push(address(sb), 1, _terms(address(usdc), 1, 0, false, address(0)));

        Swapboard.Order memory forged = _order(1);
        assertEq(forged.tokenA, address(liar), "escrow is the liar's own token, not the real one");
        assertTrue(forged.tokenA != address(nft), "the real collection was not impersonated");

        // The genuine order is untouched and still fillable.
        vm.prank(taker);
        sb.fillOrder(0, block.timestamp, 0, 0, taker);
        assertEq(nft.ownerOf(1), taker, "real escrow still settled to its own taker");
    }

    /// @dev An EOA cannot pose as a collection.
    function test_EoaCannotPoseAsACollection() public {
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NotAContract.selector, maker));
        sb.onERC721Received(maker, maker, 1, _terms(address(usdc), 1e6, 0, false, address(0)));
    }

    function _order(uint256 id) internal view returns (Swapboard.Order memory) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        return sb.getOrders(ids)[0];
    }
}
