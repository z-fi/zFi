// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockNFT} from "./SwapboardMocks.sol";

/// @dev MockNFT is deliberately minimal — one SSTORE per transfer — which understates a
///      production collection badly enough that a bound measured against it is not worth
///      asserting on. This approximates what OpenZeppelin's ERC721 actually touches:
///      owner write, both balance counters, and the per-token approval clear.
contract RealisticERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
        ++balanceOf[to];
    }

    function approve(address to, uint256 id) external {
        getApproved[id] = to;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "not owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender] || getApproved[id] == msg.sender, "not approved");
        delete getApproved[id];
        --balanceOf[from];
        ++balanceOf[to];
        ownerOf[id] = to;
    }
}

/// @notice Gas bounds for the ERC-721 bundle cap.
///
/// @dev `listNFT` documents a maximum of 100 ids. That constant is only honest if a
///      100-id bundle can also be FILLED and CANCELLED — a lot that can be escrowed but
///      never released is a trap, and the seller cannot get out of it by any other path.
///      Dutchboard spends more per id than its predecessor here: `_moveNFT` wraps every
///      transfer in an ownerOf check before and after, so a bundle costs three external
///      calls per id rather than one, and closing a listing clears a 100-slot array.
///
///      These are release invariants, not micro-benchmarks. The thresholds are set well
///      under the 30M block limit but high enough not to trip on ordinary codegen drift;
///      a failure here means the documented cap has stopped being reachable in practice.
contract DutchboardBundleGasTest is Test {
    Dutchboard board;
    MockNFT nft;
    MockERC20 quote;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant CAP = 100; // the cap listNFT documents
    uint256 constant BLOCK_LIMIT = 30_000_000;

    /// Ceiling for any single call touching a full bundle. A call that needs more than a
    /// third of the block is already impractical to land during congestion.
    uint256 constant MAX_PER_CALL = 10_000_000;

    function setUp() public {
        board = new Dutchboard(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        nft = new MockNFT();
        quote = new MockERC20("QUOTE", 18);

        vm.deal(bob, 10_000 ether);
        quote.mint(bob, 1_000_000e18);
        vm.prank(bob);
        quote.approve(address(board), type(uint256).max);
    }

    function _mintAndApprove(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            nft.mint(alice, i + 1);
            ids[i] = i + 1;
        }
        vm.prank(alice);
        nft.setApprovalForAll(address(board), true);
    }

    /// List, then fill, a full-cap bundle — the path a buyer must be able to execute.
    function testFullBundleListAndFillFitInABlock() public {
        uint256[] memory ids = _mintAndApprove(CAP);

        uint256 g = gasleft();
        vm.prank(alice);
        uint256 id = board.listNFT(address(nft), address(0), ids, 100 ether, 0, 0, 1 hours);
        uint256 listGas = g - gasleft();

        g = gasleft();
        vm.prank(bob);
        board.fill{value: 100 ether}(id, 0, bob, 100 ether);
        uint256 fillGas = g - gasleft();

        emit log_named_uint("listNFT(100) gas", listGas);
        emit log_named_uint("fill(100)    gas", fillGas);
        emit log_named_uint("list+fill    gas", listGas + fillGas);

        for (uint256 i; i < CAP; ++i) {
            assertEq(nft.ownerOf(i + 1), bob, "every id delivered");
        }

        assertLt(listGas, MAX_PER_CALL, "listing a full bundle is impractical");
        assertLt(fillGas, MAX_PER_CALL, "filling a full bundle is impractical");
        assertLt(listGas + fillGas, BLOCK_LIMIT, "full bundle round trip exceeds a block");
    }

    /// The seller's exit. If this cannot land, a full-cap listing is unrecoverable.
    function testFullBundleCancelFitsInABlock() public {
        uint256[] memory ids = _mintAndApprove(CAP);

        vm.prank(alice);
        uint256 id = board.listNFT(address(nft), address(0), ids, 100 ether, 0, 0, 1 hours);

        uint256 g = gasleft();
        vm.prank(alice);
        board.cancel(id);
        uint256 cancelGas = g - gasleft();

        emit log_named_uint("cancel(100)  gas", cancelGas);

        for (uint256 i; i < CAP; ++i) {
            assertEq(nft.ownerOf(i + 1), alice, "every id reclaimed");
        }
        assertLt(cancelGas, MAX_PER_CALL, "seller cannot exit a full bundle");
    }

    /// An ERC-20-quoted bundle adds the payment leg's balance-delta checks on top.
    function testFullBundleFillPaidInERC20FitsInABlock() public {
        uint256[] memory ids = _mintAndApprove(CAP);

        vm.prank(alice);
        uint256 id = board.listNFT(address(nft), address(quote), ids, 1000e18, 0, 0, 1 hours);

        uint256 g = gasleft();
        vm.prank(bob);
        board.fill(id, 0, bob, 1000e18);
        uint256 fillGas = g - gasleft();

        emit log_named_uint("fill(100,ERC20) gas", fillGas);
        assertEq(quote.balanceOf(alice), 1000e18, "seller paid");
        assertLt(fillGas, MAX_PER_CALL, "ERC20-quoted bundle fill is impractical");
    }

    /// The number that actually decides whether the documented cap is usable: a full
    /// bundle on a collection with production-shaped storage writes.
    function testFullBundleOnRealisticCollectionFitsInABlock() public {
        RealisticERC721 real = new RealisticERC721();
        uint256[] memory ids = new uint256[](CAP);
        for (uint256 i; i < CAP; ++i) {
            real.mint(alice, i + 1);
            ids[i] = i + 1;
        }
        vm.prank(alice);
        real.setApprovalForAll(address(board), true);

        uint256 g = gasleft();
        vm.prank(alice);
        uint256 id = board.listNFT(address(real), address(0), ids, 100 ether, 0, 0, 1 hours);
        uint256 listGas = g - gasleft();

        g = gasleft();
        vm.prank(bob);
        board.fill{value: 100 ether}(id, 0, bob, 100 ether);
        uint256 fillGas = g - gasleft();

        emit log_named_uint("realistic listNFT(100) gas", listGas);
        emit log_named_uint("realistic fill(100)    gas", fillGas);

        for (uint256 i; i < CAP; ++i) {
            assertEq(real.ownerOf(i + 1), bob, "every id delivered");
        }
        assertLt(listGas, MAX_PER_CALL, "realistic full-bundle listing is impractical");
        assertLt(fillGas, MAX_PER_CALL, "realistic full-bundle fill is impractical");
    }

    /// Same, for the seller's exit.
    function testRealisticCollectionCancelFitsInABlock() public {
        RealisticERC721 real = new RealisticERC721();
        uint256[] memory ids = new uint256[](CAP);
        for (uint256 i; i < CAP; ++i) {
            real.mint(alice, i + 1);
            ids[i] = i + 1;
        }
        vm.prank(alice);
        real.setApprovalForAll(address(board), true);
        vm.prank(alice);
        uint256 id = board.listNFT(address(real), address(0), ids, 100 ether, 0, 0, 1 hours);

        uint256 g = gasleft();
        vm.prank(alice);
        board.cancel(id);
        uint256 cancelGas = g - gasleft();

        emit log_named_uint("realistic cancel(100)  gas", cancelGas);
        assertLt(cancelGas, MAX_PER_CALL, "seller cannot exit a realistic full bundle");
    }

    /// Per-id marginal cost, so a regression in `_moveNFT` shows up as a slope change
    /// rather than only as a threshold breach at the cap.
    function testPerIdMarginalFillCost() public {
        uint256[] memory ids = _mintAndApprove(CAP);
        vm.prank(alice);
        uint256 big = board.listNFT(address(nft), address(0), ids, 100 ether, 0, 0, 1 hours);

        uint256 g = gasleft();
        vm.prank(bob);
        board.fill{value: 100 ether}(big, 0, bob, 100 ether);
        uint256 bigGas = g - gasleft();

        // A fresh single-id listing from a different collection, same code path.
        MockNFT solo = new MockNFT();
        solo.mint(alice, 1);
        vm.prank(alice);
        solo.setApprovalForAll(address(board), true);
        uint256[] memory one = new uint256[](1);
        one[0] = 1;
        vm.prank(alice);
        uint256 small = board.listNFT(address(solo), address(0), one, 1 ether, 0, 0, 1 hours);

        g = gasleft();
        vm.prank(bob);
        board.fill{value: 1 ether}(small, 0, bob, 1 ether);
        uint256 smallGas = g - gasleft();

        uint256 marginal = (bigGas - smallGas) / (CAP - 1);
        emit log_named_uint("marginal gas per extra id", marginal);
        assertLt(marginal, 100_000, "per-id fill cost regressed");
    }
}
