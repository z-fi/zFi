// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";

contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockNFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from);
        ownerOf[id] = to;
    }

    function supportsInterface(bytes4 i) external pure returns (bool) {
        return i == 0x80ac58cd || i == 0x01ffc9a7;
    }

    function symbol() external pure returns (string memory) {
        return "MOCK";
    }
}

/// A collection the attacker controls outright, with TWO positions registered
/// as authorised proceeds sources. It reports the board as the owner of its own
/// token ids, so `onERC721Received` accepts a push listing without any asset
/// moving - the cheap way to obtain two registered `(caller, orderId)` pairs.
contract FakeCollection {
    Dutchboard immutable board;

    constructor(Dutchboard b) {
        board = b;
    }

    function ownerOf(uint256) external view returns (address) {
        return address(board);
    }

    function supportsInterface(bytes4 i) external pure returns (bool) {
        return i == 0x80ac58cd || i == 0x01ffc9a7;
    }

    function symbol() external pure returns (string memory) {
        return "FAKE";
    }

    function register(address seller, address quote, uint256 tokenId) external returns (bytes4) {
        Dutchboard.PushTerms memory t =
            Dutchboard.PushTerms({quote: quote, startPrice: 1 ether, endPrice: 1 ether, startTime: 0, duration: 1 days});
        return board.onERC721Received(address(0), seller, tokenId, abi.encode(keccak256("Dutchboard.PushTerms.v1"), t));
    }

    function snapshot(uint256 orderId, address victimNFT, uint256 tokenId) external {
        board.beforeOrderProceeds(orderId, victimNFT, tokenId, true);
    }

    function credit(uint256 orderId, address victimNFT, uint256 tokenId) external {
        board.afterOrderProceeds(orderId, victimNFT, tokenId, true);
    }
}

/// The board's stated invariant is that ONE BOARD-HELD NFT BACKS EXACTLY ONE
/// LIABILITY. `liveClaimListing` defends the escrow half of that. This is the
/// other half: already-credited proceeds.
contract DutchboardProceedsDoubleCredit is Test {
    Dutchboard board;
    MockWETH weth;
    MockNFT nft;
    FakeCollection fake;

    address attacker = address(0xA11CE);

    function setUp() public {
        weth = new MockWETH();
        board = new Dutchboard(address(weth));
        nft = new MockNFT();
        fake = new FakeCollection(board);
    }

    /// The transient bracket is keyed on the whole `(caller, orderId, token,
    /// amount, nft)` tuple, so two registered positions of one collection open
    /// two INDEPENDENT brackets over the same NFT. Both `before` legs pass (the
    /// board does not hold it yet) and, after a single delivery, both `after`
    /// legs would pass too: the board owns it and it is not listing escrow.
    ///
    /// The fungible branch is immune only as a side effect - crediting there
    /// raises `totalClaimable`, consuming the free balance a second `after` has
    /// to match. Nothing consumes an NFT arrival, so this branch must refuse an
    /// already-credited token explicitly.
    function test_secondCreditOfOneNFTIsRefused() public {
        vm.startPrank(attacker);
        fake.register(attacker, address(weth), 1);
        fake.register(attacker, address(weth), 2);
        vm.stopPrank();

        nft.mint(address(fake), 42);

        // Both brackets open while the board does not hold the NFT.
        fake.snapshot(1, address(nft), 42);
        fake.snapshot(2, address(nft), 42);

        // One physical delivery.
        vm.prank(address(fake));
        nft.transferFrom(address(fake), address(board), 42);

        // The first credit is legitimate.
        fake.credit(1, address(nft), 42);
        assertTrue(board.claimableNFTProceeds(0, address(nft), 42), "first credit stands");

        // The second must be refused rather than minting a phantom claim.
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        fake.credit(2, address(nft), 42);
        assertFalse(board.claimableNFTProceeds(1, address(nft), 42), "no second liability");

        // And the one real claim still settles.
        vm.prank(attacker);
        board.claimNFTProceeds(0, address(nft), 42, attacker);
        assertEq(nft.ownerOf(42), attacker);
    }

    /// Clearing a claim also clears `heldAsProceeds`, so the same NFT can be
    /// delivered as proceeds again later. The guard must reject double-crediting,
    /// not permanently blacklist the token.
    function test_creditIsAllowedAgainAfterTheClaimIsSettled() public {
        vm.prank(attacker);
        fake.register(attacker, address(weth), 1);

        nft.mint(address(fake), 42);

        fake.snapshot(1, address(nft), 42);
        vm.prank(address(fake));
        nft.transferFrom(address(fake), address(board), 42);
        fake.credit(1, address(nft), 42);

        vm.prank(attacker);
        board.claimNFTProceeds(0, address(nft), 42, attacker);
        assertFalse(board.heldAsProceeds(address(nft), 42), "flag cleared on claim");

        // Same token, delivered as proceeds a second time.
        fake.snapshot(1, address(nft), 42);
        vm.prank(attacker);
        nft.transferFrom(attacker, address(board), 42);
        fake.credit(1, address(nft), 42);
        assertTrue(board.claimableNFTProceeds(0, address(nft), 42), "re-credit allowed");
    }
}
