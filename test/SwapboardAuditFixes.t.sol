// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// @dev A collection that hands the receiver hook an ARBITRARY token id chosen
///      by the caller, without moving anything. Upgradeable proxies, admin
///      rescue functions and plain non-standard implementations can all be
///      induced to do this; it is the shape the escrow registry exists to stop.
contract HookPuppet is MockNFT {
    function safeTransferFrom(address f, address t, uint256 id, bytes calldata data) external {
        require(ownerOf[id] == f, "not owner");
        require(msg.sender == f || isApprovedForAll[f][msg.sender], "not approved");
        ownerOf[id] = t;
        bytes4 got = IERC721Receiver(t).onERC721Received(msg.sender, f, id, data);
        require(got == IERC721Receiver.onERC721Received.selector, "bad receiver");
    }

    /// @dev The abuse: call the hook naming a token the board already escrows.
    function pushId(address board, address from, uint256 id, bytes calldata data) external {
        IERC721Receiver(board).onERC721Received(msg.sender, from, id, data);
    }
}

contract SwapboardAuditFixesTest is Test {
    Swapboard sb;
    MockWETH weth;
    MockERC20 usdc;
    HookPuppet nft;

    address alice = address(0xA11CE);
    address mallory = address(0xBAD);
    address taker = address(0xB0B);

    function setUp() public {
        weth = new MockWETH();
        sb = new Swapboard(address(weth));
        usdc = new MockERC20("USDC", 6);
        nft = new HookPuppet();

        nft.mint(alice, 5);
        usdc.mint(taker, 1_000_000e6);
        vm.prank(taker);
        usdc.approve(address(sb), type(uint256).max);
    }

    function _terms(address tokenB, uint256 amountB) internal pure returns (bytes memory) {
        return abi.encode(
            keccak256("Swapboard.PushOrder.v1"), Swapboard.PushOrder(tokenB, amountB, uint64(0), false, address(0))
        );
    }

    // ------------------------------------------------------------------- M-1

    /// @dev The core of the finding: `ownerOf` is satisfied by escrow the board
    ///      already holds for somebody else, so the push path could mint a
    ///      second order over the first one's backing.
    function test_PushCannotMintOverExistingEscrow() public {
        vm.startPrank(alice);
        nft.safeTransferFrom(alice, address(sb), 5, _terms(address(usdc), 5_000e6));
        vm.stopPrank();
        assertEq(nft.ownerOf(5), address(sb), "alice's NFT is escrowed");

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.NFTTransferFailed.selector, address(nft), uint256(5)));
        nft.pushId(address(sb), mallory, 5, _terms(address(usdc), 1));

        // And alice's order is still whole and still settles.
        vm.prank(taker);
        sb.fillOrder(0, block.timestamp, 5_000e6, 0, taker);
        assertEq(nft.ownerOf(5), taker, "escrow settled to its own taker");
    }

    /// @dev A full fill releases the record, so the token can be listed again.
    function test_RegistryClearsOnFill() public {
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(sb), 5, _terms(address(usdc), 5_000e6));
        vm.prank(taker);
        sb.fillOrder(0, block.timestamp, 5_000e6, 0, taker);

        vm.prank(taker);
        nft.safeTransferFrom(taker, address(sb), 5, _terms(address(usdc), 1_000e6));
        assertEq(nft.ownerOf(5), address(sb), "relisted, so the record was released");
    }

    /// @dev A cancellation releases it too.
    function test_RegistryClearsOnCancel() public {
        vm.startPrank(alice);
        nft.safeTransferFrom(alice, address(sb), 5, _terms(address(usdc), 5_000e6));
        sb.cancelOrder(0);
        vm.stopPrank();

        assertEq(nft.ownerOf(5), alice, "NFT went home");
    }




    /// @dev The same gap on the pull path, against a collection whose `ownerOf`
    ///      would let `_moveNFT` pass twice for one token.
    function test_CreateCannotMintOverExistingEscrow() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(address(sb), true);
        sb.createOrder(address(nft), 5, address(usdc), 5_000e6, false, 0, true, false, address(0));

        vm.expectRevert(abi.encodeWithSelector(Swapboard.NFTTransferFailed.selector, address(nft), uint256(5)));
        sb.createOrder(address(nft), 5, address(usdc), 1, false, 0, true, false, address(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------- L-2

    /// @dev A bare 160-byte payload is no longer terms; only the magic prefix
    ///      is. A wallet or bridge attaching its own metadata to a transfer
    ///      into this board now gets the original refusal rather than a live
    ///      order at a price nobody chose.
    function test_PushRequiresMagicPrefix() public {
        bytes memory unprefixed =
            abi.encode(Swapboard.PushOrder(address(usdc), 1e6, uint64(0), false, address(0)));
        assertEq(unprefixed.length, 160, "the shape that used to be accepted");

        vm.prank(alice);
        vm.expectRevert(Swapboard.DirectNFTTransfer.selector);
        nft.safeTransferFrom(alice, address(sb), 5, unprefixed);

        bytes memory wrongMagic = abi.encode(
            keccak256("not.the.magic"), Swapboard.PushOrder(address(usdc), 1e6, uint64(0), false, address(0))
        );
        assertEq(wrongMagic.length, 192, "right length, wrong word");
        vm.prank(alice);
        vm.expectRevert(Swapboard.DirectNFTTransfer.selector);
        nft.safeTransferFrom(alice, address(sb), 5, wrongMagic);

        assertEq(nft.ownerOf(5), alice, "and nothing was escrowed by either attempt");
    }

    // ------------------------------------------------------------------- L-1

    /// @dev `readDecimals` refuses anything above 36, so the `decimals + 1`
    ///      snapshot cannot overflow its uint8 and a hostile decimals value
    ///      degrades to the raw-units fallback rather than bricking creation.
    function test_AbsurdDecimalsDoesNotBrickCreation() public {
        WideDecimals wide = new WideDecimals();
        wide.mint(alice, 10e18);
        vm.startPrank(alice);
        wide.approve(address(sb), type(uint256).max);
        uint256 id = sb.createOrder(address(wide), 1e18, address(usdc), 5_000e6, false, 0, false, false, address(0));
        vm.stopPrank();
        assertEq(sb.ownerOf(id), alice, "order created against a 255-decimal token");
    }
}

/// @dev Reports 255 decimals - beyond anything `readDecimals` will accept.
contract WideDecimals {
    string public symbol = "WIDE";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 255;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address t, uint256 amt) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= amt;
        balanceOf[f] -= amt;
        balanceOf[t] += amt;
        return true;
    }
}
