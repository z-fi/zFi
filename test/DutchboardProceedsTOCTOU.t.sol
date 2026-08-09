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

/// @dev Minimal ERC-721 with the ERC-165 probe Dutchboard uses.
contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
        balanceOf[to]++;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from);
        ownerOf[id] = to;
        balanceOf[from]--;
        balanceOf[to]++;
    }

    function supportsInterface(bytes4 i) external pure returns (bool) {
        return i == 0x80ac58cd || i == 0x01ffc9a7;
    }

    function symbol() external pure returns (string memory) {
        return "MOCK";
    }
}

/// @dev A "collection" the attacker controls entirely. It reports the board as
///      the owner of its token 1 so `onERC721Received` accepts a push listing
///      without any asset actually moving, which registers it as an authorised
///      proceeds source.
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

    function register(address seller, address quote) external returns (bytes4) {
        Dutchboard.PushTerms memory t = Dutchboard.PushTerms({
            quote: quote,
            startPrice: 1 ether,
            endPrice: 1 ether,
            startTime: 0,
            duration: 1 days
        });
        return board.onERC721Received(address(0), seller, 1, abi.encode(keccak256("Dutchboard.PushTerms.v1"), t));
    }

    function snapshot(address victimNFT, uint256 tokenId) external {
        board.beforeOrderProceeds(1, victimNFT, tokenId, true);
    }

    function credit(address victimNFT, uint256 tokenId) external {
        board.afterOrderProceeds(1, victimNFT, tokenId, true);
    }
}

contract DutchboardProceedsTOCTOU is Test {
    Dutchboard board;
    MockWETH weth;
    MockNFT nft;
    FakeCollection fake;

    address attacker = address(0xA11CE);
    address victim = address(0xBEEF);

    function setUp() public {
        weth = new MockWETH();
        board = new Dutchboard(address(weth));
        nft = new MockNFT();
        fake = new FakeCollection(board);
    }

    /// The board's stated invariant is that listing escrow and credited proceeds
    /// are disjoint custody states: "one board-held NFT backs exactly one
    /// liability". The NFT proceeds callbacks check only non-ownership before
    /// and ownership after, so an NFT that becomes listing escrow *between* the
    /// two legs satisfies both and gets credited as proceeds as well.
    function test_nftProceedsCannotCreditListingEscrow() public {
        // Attacker registers their fake collection as an authorised source.
        vm.prank(attacker);
        fake.register(attacker, address(weth));

        // Victim owns the NFT; the board does not hold it yet.
        nft.mint(victim, 42);

        // Leg 1: snapshot while the board does not own the NFT.
        fake.snapshot(address(nft), 42);

        // The victim lists the NFT; the board now holds it as listing escrow.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 42;
        vm.prank(victim);
        board.listNFT(address(nft), address(weth), ids, 1 ether, 1 ether, 0, 1 days);
        assertEq(nft.ownerOf(42), address(board));

        // Leg 2 must refuse: the NFT is listing escrow, not an arrival.
        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        fake.credit(address(nft), 42);

        // Nothing was credited, so there is nothing to claim...
        vm.expectRevert(Dutchboard.NoClaimableProceeds.selector);
        vm.prank(attacker);
        board.claimNFTProceeds(0, address(nft), 42, attacker);

        // ...and the victim's escrow is untouched and still theirs to cancel.
        assertEq(nft.ownerOf(42), address(board));
        vm.prank(victim);
        board.cancel(1);
        assertEq(nft.ownerOf(42), victim);
    }

    /// The board's own address must never be usable as a proceeds asset: its
    /// `balanceOf` is the ERC-721 owner count, so the fungible delta check
    /// would be measuring receipts rather than tokens.
    function test_selfAddressRejectedAsFungibleProceeds() public {
        vm.prank(attacker);
        fake.register(attacker, address(weth));

        vm.expectRevert(Dutchboard.InvalidProceedsCallback.selector);
        vm.prank(address(fake));
        board.beforeOrderProceeds(1, address(board), 0, false);
    }
}
