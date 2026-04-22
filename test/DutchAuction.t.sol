// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {DutchAuction, TransferFailed, TransferFromFailed, ETHTransferFailed} from "../src/DutchAuction.sol";

/*//////////////////////////////////////////////////////////////
                            MOCKS
//////////////////////////////////////////////////////////////*/

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allow");
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev USDT-style: doesn't return a bool from transfer/transferFrom.
contract MockERC20NoReturn {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allow");
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Returns false from transfer — should cause _safeTransfer to revert.
contract MockERC20ReturnsFalse {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

contract MockERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => address) public getApproved;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function approve(address to, uint256 id) external {
        getApproved[id] = to;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender] || getApproved[id] == msg.sender, "approved");
        ownerOf[id] = to;
        delete getApproved[id];
    }
}

/// @dev Rejects ETH — simulates a seller contract whose receive reverts.
contract RejectETH {}

/// @dev Seller contract that tries to reenter fill() when it receives ETH.
contract ReentrantSeller {
    DutchAuction public auction;
    uint256 public targetId;

    constructor(DutchAuction _auction) {
        auction = _auction;
    }

    function setTarget(uint256 id) external {
        targetId = id;
    }

    receive() external payable {
        // Try to reenter fill on same auction — should revert via guard.
        auction.fill{value: 0}(targetId, 0);
    }
}

/*//////////////////////////////////////////////////////////////
                             TEST
//////////////////////////////////////////////////////////////*/

contract DutchAuctionTest is Test {
    DutchAuction auction;
    MockERC20 tok;
    MockERC721 nft;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAFE);

    function setUp() public {
        auction = new DutchAuction();
        tok = new MockERC20();
        nft = new MockERC721();

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
    }

    /*──────────────── listNFT ────────────────*/

    function _listOneNFT(uint256 id, uint128 startP, uint128 endP, uint40 dur) internal returns (uint256) {
        nft.mint(alice, id);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256 aId = auction.listNFT(address(nft), ids, startP, endP, 0, dur);
        vm.stopPrank();
        return aId;
    }

    function testListNFTSingle() public {
        uint256 aId = _listOneNFT(42, 10 ether, 0, 1 hours);
        assertEq(nft.ownerOf(42), address(auction));
        (address seller, address token,,,,,,) = auction.auctions(aId);
        assertEq(seller, alice);
        assertEq(token, address(nft));
    }

    function testListNFTBundle() public {
        for (uint256 i; i < 3; ++i) {
            nft.mint(alice, i + 1);
        }
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        uint256 aId = auction.listNFT(address(nft), ids, 5 ether, 1, 0, 1 hours);
        vm.stopPrank();

        uint256[] memory got = auction.idsOf(aId);
        assertEq(got.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(nft.ownerOf(i + 1), address(auction));
        }
    }

    function testListNFTRevertsEmpty() public {
        uint256[] memory ids = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.listNFT(address(nft), ids, 1 ether, 0, 0, 1 hours);
    }

    function testListNFTRevertsZeroDuration() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(alice);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.listNFT(address(nft), ids, 1 ether, 0, 0, 0);
    }

    function testListNFTRevertsEOAToken() public {
        // EOA token: Solidity's implicit extcodesize check on the typed IERC721 call reverts.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(alice);
        vm.expectRevert();
        auction.listNFT(address(0xbeef), ids, 1 ether, 0, 0, 1 hours);
    }

    function testListNFTRevertsStartBelowEnd() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(alice);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.listNFT(address(nft), ids, 1 ether, 2 ether, 0, 1 hours);
    }

    function testListNFTRevertsOverBundleCap() public {
        uint256[] memory ids = new uint256[](101);
        vm.prank(alice);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.listNFT(address(nft), ids, 1 ether, 0, 0, 1 hours);
    }

    function testListNFTRevertsZeroStartPrice() public {
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.listNFT(address(nft), ids, 0, 0, 0, 1 hours);
        vm.stopPrank();
    }

    function testListNFTRevertsPastStartTime() public {
        vm.warp(10_000);
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.listNFT(address(nft), ids, 1 ether, 0, uint40(block.timestamp - 1), 1 hours);
        vm.stopPrank();
    }

    function testListNFTAcceptsFutureStartTime() public {
        vm.warp(10_000);
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        auction.listNFT(address(nft), ids, 1 ether, 0, uint40(block.timestamp + 1 hours), 1 hours);
        vm.stopPrank();
    }

    /*──────────────── listERC20 ────────────────*/

    function _listERC20(uint128 amount, uint128 startP, uint128 endP, uint40 dur) internal returns (uint256) {
        tok.mint(alice, amount);
        vm.startPrank(alice);
        tok.approve(address(auction), amount);
        uint256 aId = auction.listERC20(address(tok), amount, startP, endP, 0, dur);
        vm.stopPrank();
        return aId;
    }

    function testListERC20() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 1, 1 hours);
        assertEq(tok.balanceOf(address(auction)), 1000e18);
        (,,,,,, uint128 initial, uint128 remaining) = auction.auctions(aId);
        assertEq(initial, 1000e18);
        assertEq(remaining, 1000e18);
    }

    function testListERC20USDTStyle() public {
        MockERC20NoReturn usdt = new MockERC20NoReturn();
        usdt.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdt.approve(address(auction), 1000e6);
        uint256 aId = auction.listERC20(address(usdt), 1000e6, 5 ether, 0, 0, 1 hours);
        vm.stopPrank();
        assertEq(usdt.balanceOf(address(auction)), 1000e6);
        (,,,,,, uint128 initial,) = auction.auctions(aId);
        assertEq(initial, 1000e6);
    }

    function testListERC20RevertsReturnsFalse() public {
        MockERC20ReturnsFalse bad = new MockERC20ReturnsFalse();
        vm.prank(alice);
        vm.expectRevert(TransferFromFailed.selector);
        auction.listERC20(address(bad), 1, 1, 0, 0, 1 hours);
    }

    function testListERC20RevertsZero() public {
        vm.prank(alice);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.listERC20(address(tok), 0, 1 ether, 0, 0, 1 hours);
    }

    function testListERC20RevertsZeroDuration() public {
        vm.prank(alice);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.listERC20(address(tok), 1e18, 1 ether, 0, 0, 0);
    }

    function testListERC20RevertsStartBelowEnd() public {
        vm.prank(alice);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.listERC20(address(tok), 1e18, 1 ether, 2 ether, 0, 1 hours);
    }

    function testListERC20RevertsEOAToken() public {
        // 0xbeef has no code on the forked block — must revert without silently "succeeding".
        vm.prank(alice);
        vm.expectRevert(TransferFromFailed.selector);
        auction.listERC20(address(0xbeef), 1e18, 1 ether, 0, 0, 1 hours);
    }

    function testListERC20RevertsZeroStartPrice() public {
        tok.mint(alice, 1e18);
        vm.startPrank(alice);
        tok.approve(address(auction), 1e18);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.listERC20(address(tok), 1e18, 0, 0, 0, 1 hours);
        vm.stopPrank();
    }

    function testListERC20RevertsPastStartTime() public {
        vm.warp(10_000);
        tok.mint(alice, 1e18);
        vm.startPrank(alice);
        tok.approve(address(auction), 1e18);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.listERC20(address(tok), 1e18, 1 ether, 0, uint40(block.timestamp - 1), 1 hours);
        vm.stopPrank();
    }

    /*──────────────── priceOf decay ────────────────*/

    function testPriceDecay() public {
        uint256 aId = _listOneNFT(1, 10 ether, 0, 1 hours);
        uint40 startT = uint40(block.timestamp);

        assertEq(auction.priceOf(aId), 10 ether);

        vm.warp(startT + 1); // just after start
        // elapsed=1, duration=3600, price = 10e18 - 10e18*1/3600
        assertApproxEqAbs(auction.priceOf(aId), uint256(10 ether) - uint256(10 ether) / 3600, 1);

        vm.warp(startT + 30 minutes);
        assertEq(auction.priceOf(aId), 5 ether);

        vm.warp(startT + 1 hours);
        assertEq(auction.priceOf(aId), 0);

        vm.warp(startT + 2 hours);
        assertEq(auction.priceOf(aId), 0);
    }

    function testPriceBeforeStart() public {
        uint40 future = uint40(block.timestamp + 1000);
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 aId = auction.listNFT(address(nft), ids, 10 ether, 1, future, 1 hours);
        vm.stopPrank();

        assertEq(auction.priceOf(aId), 10 ether); // before start
        vm.warp(future);
        assertEq(auction.priceOf(aId), 10 ether);
        vm.warp(future + 1 hours);
        assertEq(auction.priceOf(aId), 1);
    }

    /*──────────────── fill NFT ────────────────*/

    function testFillNFTAtFullPrice() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);

        uint256 bobBefore = bob.balance;
        uint256 aliceBefore = alice.balance;

        vm.prank(bob);
        auction.fill{value: 10 ether}(aId, 0);

        assertEq(nft.ownerOf(7), bob);
        assertEq(alice.balance, aliceBefore + 10 ether);
        assertEq(bob.balance, bobBefore - 10 ether);

        // auction deleted
        (address seller,,,,,,,) = auction.auctions(aId);
        assertEq(seller, address(0));
    }

    function testFillNFTRefundsExcess() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        uint40 startT = uint40(block.timestamp);
        vm.warp(startT + 30 minutes); // price = 5 ETH

        uint256 bobBefore = bob.balance;
        uint256 aliceBefore = alice.balance;

        vm.prank(bob);
        auction.fill{value: 10 ether}(aId, 0);

        assertEq(nft.ownerOf(7), bob);
        assertEq(alice.balance, aliceBefore + 5 ether);
        assertEq(bob.balance, bobBefore - 5 ether); // 5 ETH refunded
    }

    function testFillNFTAtEndZero() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(bob);
        auction.fill{value: 0}(aId, 0);

        assertEq(nft.ownerOf(7), bob);
    }

    function testFillNFTRevertsInsufficient() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        vm.prank(bob);
        vm.expectRevert(DutchAuction.Insufficient.selector);
        auction.fill{value: 1 ether}(aId, 0);
    }

    function testFillNFTBundle() public {
        for (uint256 i; i < 3; ++i) {
            nft.mint(alice, i + 1);
        }
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        uint256 aId = auction.listNFT(address(nft), ids, 30 ether, 1, 0, 1 hours);
        vm.stopPrank();

        vm.prank(bob);
        auction.fill{value: 30 ether}(aId, 0);

        for (uint256 i; i < 3; ++i) {
            assertEq(nft.ownerOf(i + 1), bob);
        }
    }

    function testFillNFTRevertsUnknownId() public {
        vm.prank(bob);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.fill{value: 1 ether}(999, 0);
    }

    function testFillNFTRejectingSellerReverts() public {
        RejectETH rej = new RejectETH();
        nft.mint(address(rej), 1);
        vm.startPrank(address(rej));
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 aId = auction.listNFT(address(nft), ids, 1 ether, 0, 0, 1 hours);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(ETHTransferFailed.selector);
        auction.fill{value: 1 ether}(aId, 0);
    }

    /*──────────────── fill ERC20 (partial) ────────────────*/

    function testFillERC20Full() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);

        vm.prank(bob);
        auction.fill{value: 10 ether}(aId, 1000e18);

        assertEq(tok.balanceOf(bob), 1000e18);
        (address seller,,,,,,,) = auction.auctions(aId); // deleted
        assertEq(seller, address(0));
    }

    function testFillERC20Partial() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);

        vm.prank(bob);
        auction.fill{value: 1 ether}(aId, 100e18);
        assertEq(tok.balanceOf(bob), 100e18);

        (,,,,,,, uint128 remaining) = auction.auctions(aId);
        assertEq(remaining, 900e18);

        vm.prank(carol);
        auction.fill{value: 1 ether}(aId, 100e18);
        assertEq(tok.balanceOf(carol), 100e18);

        (,,,,,,, remaining) = auction.auctions(aId);
        assertEq(remaining, 800e18);
    }

    function testFillERC20PartialPriceDecays() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        uint40 startT = uint40(block.timestamp);

        vm.warp(startT + 30 minutes); // total price = 5 ETH

        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        auction.fill{value: 1 ether}(aId, 200e18); // cost = 5e18 * 200e18 / 1000e18 = 1 ETH

        assertEq(tok.balanceOf(bob), 200e18);
        assertEq(alice.balance, aliceBefore + 1 ether);
    }

    function testFillERC20RefundsExcess() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        auction.fill{value: 5 ether}(aId, 100e18); // cost = 1 ETH

        assertEq(bob.balance, bobBefore - 1 ether);
    }

    function testFillERC20RevertsOverRemaining() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        vm.prank(bob);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.fill{value: 100 ether}(aId, 1001e18);
    }

    function testFillERC20RevertsZeroTake() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        vm.prank(bob);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.fill{value: 10 ether}(aId, 0);
    }

    function testFillERC20RevertsInsufficient() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        vm.prank(bob);
        vm.expectRevert(DutchAuction.Insufficient.selector);
        auction.fill{value: 0.5 ether}(aId, 100e18); // cost = 1 ETH
    }

    /*──────────────── cancel ────────────────*/

    function testCancelNFT() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        vm.prank(alice);
        auction.cancel(aId);

        assertEq(nft.ownerOf(7), alice);
        (address seller,,,,,,,) = auction.auctions(aId);
        assertEq(seller, address(0));
    }

    function testCancelERC20Full() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        vm.prank(alice);
        auction.cancel(aId);

        assertEq(tok.balanceOf(alice), 1000e18);
    }

    function testCancelERC20AfterPartialFill() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        vm.prank(bob);
        auction.fill{value: 2 ether}(aId, 200e18);

        vm.prank(alice);
        auction.cancel(aId);

        assertEq(tok.balanceOf(alice), 800e18); // reclaim remaining
        assertEq(tok.balanceOf(bob), 200e18);
    }

    function testCancelRevertsNotSeller() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        vm.prank(bob);
        vm.expectRevert(DutchAuction.NotSeller.selector);
        auction.cancel(aId);
    }

    function testCancelRevertsTwice() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        vm.prank(alice);
        auction.cancel(aId);

        vm.prank(alice);
        vm.expectRevert(DutchAuction.NotSeller.selector);
        auction.cancel(aId);
    }

    function testFillAfterCancelReverts() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        vm.prank(alice);
        auction.cancel(aId);

        vm.prank(bob);
        vm.expectRevert(DutchAuction.Bad.selector);
        auction.fill{value: 10 ether}(aId, 0);
    }

    /*──────────────── events ────────────────*/

    event Created(uint256 indexed id, address indexed seller, address indexed token);
    event Filled(uint256 indexed id, address indexed seller, address indexed buyer, uint256 amount, uint256 paid);
    event Cancelled(uint256 indexed id);

    function testEmitsCreatedOnListNFT() public {
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectEmit(true, true, true, false);
        emit Created(0, alice, address(nft));
        auction.listNFT(address(nft), ids, 1 ether, 0, 0, 1 hours);
        vm.stopPrank();
    }

    function testEmitsFilledOnNFTFill() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        vm.expectEmit(true, true, true, true);
        emit Filled(aId, alice, bob, 1, 10 ether);
        vm.prank(bob);
        auction.fill{value: 10 ether}(aId, 0);
    }

    function testEmitsFilledOnERC20Partial() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        vm.expectEmit(true, true, true, true);
        emit Filled(aId, alice, bob, 100e18, 1 ether);
        vm.prank(bob);
        auction.fill{value: 1 ether}(aId, 100e18);
    }

    function testEmitsCancelled() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        vm.expectEmit(true, false, false, false);
        emit Cancelled(aId);
        vm.prank(alice);
        auction.cancel(aId);
    }

    /*──────────────── reentrancy guard ────────────────*/

    function testReentrancyGuardBlocksFillRecurse() public {
        ReentrantSeller rs = new ReentrantSeller(auction);
        nft.mint(address(rs), 11);
        vm.startPrank(address(rs));
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 11;
        uint256 aId = auction.listNFT(address(nft), ids, 1 ether, 0, 0, 1 hours);
        vm.stopPrank();
        rs.setTarget(aId);

        // Fill pushes ETH to ReentrantSeller → receive() calls fill() → guard reverts →
        // safeTransferETH propagates the failure as ETHTransferFailed.
        vm.prank(bob);
        vm.expectRevert(ETHTransferFailed.selector);
        auction.fill{value: 1 ether}(aId, 0);
    }

    /*──────────────── view helpers ────────────────*/

    function testGetAuctionNFT() public {
        uint256 aId = _listOneNFT(7, 10 ether, 1 ether, 1 hours);
        DutchAuction.AuctionView memory v = auction.getAuction(aId);
        assertEq(v.id, aId);
        assertEq(v.seller, alice);
        assertEq(v.token, address(nft));
        assertTrue(v.isNFT);
        assertEq(v.startPrice, 10 ether);
        assertEq(v.endPrice, 1 ether);
        assertEq(v.initial, 0);
        assertEq(v.remaining, 0);
        assertEq(v.ids.length, 1);
        assertEq(v.ids[0], 7);
        assertEq(v.price, 10 ether);
    }

    function testGetAuctionERC20ReflectsPartialFill() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        vm.prank(bob);
        auction.fill{value: 1 ether}(aId, 100e18);

        DutchAuction.AuctionView memory v = auction.getAuction(aId);
        assertFalse(v.isNFT);
        assertEq(v.initial, 1000e18);
        assertEq(v.remaining, 900e18);
        assertEq(v.ids.length, 0);
    }

    function testGetAuctionZeroForUnknown() public view {
        DutchAuction.AuctionView memory v = auction.getAuction(999);
        assertEq(v.seller, address(0));
        assertEq(v.price, 0);
    }

    function testGetAuctionsRange() public {
        uint256 a1 = _listOneNFT(1, 1 ether, 0, 1 hours);
        uint256 a2 = _listOneNFT(2, 2 ether, 0, 1 hours);
        uint256 a3 = _listOneNFT(3, 3 ether, 0, 1 hours);

        DutchAuction.AuctionView[] memory views = auction.getAuctions(0, auction.nextId());
        assertEq(views.length, 3);
        assertEq(views[0].id, a1);
        assertEq(views[0].startPrice, 1 ether);
        assertEq(views[1].id, a2);
        assertEq(views[2].id, a3);
    }

    function testGetAuctionsRangeClampsAndSkipsClosed() public {
        _listOneNFT(1, 1 ether, 0, 1 hours);
        uint256 a2 = _listOneNFT(2, 2 ether, 0, 1 hours);
        vm.prank(alice);
        auction.cancel(a2);

        DutchAuction.AuctionView[] memory views = auction.getAuctions(0, 100); // clamped to nextId
        assertEq(views.length, 2);
        assertEq(views[0].seller, alice);
        assertEq(views[1].seller, address(0)); // cancelled slot zeroed

        DutchAuction.AuctionView[] memory empty = auction.getAuctions(100, 50);
        assertEq(empty.length, 0);
    }

    function testCostOfNFT() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        assertEq(auction.costOf(aId, 0), 10 ether); // take=0 → full lot
        assertEq(auction.costOf(aId, 1), 10 ether); // take==ids.length
        assertEq(auction.costOf(aId, 5), 0); // mismatched take → 0
    }

    function testCostOfERC20MatchesFill() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        uint40 startT = uint40(block.timestamp);
        vm.warp(startT + 30 minutes); // price = 5 ETH

        uint256 cost = auction.costOf(aId, 150e18);
        assertEq(cost, 750000000000000000); // ceil(5e18 * 150 / 1000) = 0.75 ETH

        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        auction.fill{value: cost}(aId, 150e18);
        assertEq(alice.balance, aliceBefore + cost);
    }

    function testCostOfZeroForClosed() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        vm.prank(alice);
        auction.cancel(aId);
        assertEq(auction.costOf(aId, 0), 0);
    }

    function testRemainingCostOfNFT() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        assertEq(auction.remainingCostOf(aId), 10 ether);
    }

    function testRemainingCostOfERC20TracksPartialFill() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        uint40 startT = uint40(block.timestamp);
        vm.warp(startT + 30 minutes); // price = 5 ETH

        // Full remaining: ceil(5e18 * 1000 / 1000) = 5 ETH.
        assertEq(auction.remainingCostOf(aId), 5 ether);

        vm.prank(bob);
        auction.fill{value: 0.75 ether}(aId, 150e18);

        // 850 tokens left: ceil(5e18 * 850 / 1000) = 4.25 ETH.
        assertEq(auction.remainingCostOf(aId), 4.25 ether);
    }

    function testRemainingCostOfClosed() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        vm.prank(alice);
        auction.cancel(aId);
        assertEq(auction.remainingCostOf(aId), 0);
    }

    function testPriceOfUnknownReturnsZero() public view {
        assertEq(auction.priceOf(12345), 0);
    }

    function testPriceOfClosedReturnsZero() public {
        uint256 aId = _listOneNFT(7, 10 ether, 0, 1 hours);
        vm.prank(alice);
        auction.cancel(aId);
        assertEq(auction.priceOf(aId), 0);
    }

    /*──────────────── fuzz ────────────────*/

    function testFuzzPriceMonotonicDecay(uint128 startP, uint128 endP, uint40 dur, uint32 dt) public {
        vm.assume(startP > 0 && startP >= endP && dur > 0);
        uint40 startT = uint40(block.timestamp);

        nft.mint(alice, 999);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;
        uint256 aId = auction.listNFT(address(nft), ids, startP, endP, 0, dur);
        vm.stopPrank();

        uint256 p0 = auction.priceOf(aId);
        assertEq(p0, startP);

        vm.warp(startT + dt);
        uint256 p1 = auction.priceOf(aId);
        assertLe(p1, startP);
        assertGe(p1, endP);
    }

    /// @dev Regression: with floor division, buyer could take initial >> price and get 0 cost.
    ///      Ceiling division must charge at least 1 wei for any nonzero take.
    function testERC20PartialFillNoFreeTakes() public {
        uint128 initial = 1e24; // huge supply
        uint256 aId = _listERC20(initial, 1e18, 0, 1 hours); // price = 1 ETH = 1e18 wei
        // price/initial = 1e-6 ETH per unit; take=1 under floor division → cost=0
        vm.prank(bob);
        vm.expectRevert(DutchAuction.Insufficient.selector);
        auction.fill{value: 0}(aId, 1);
    }

    function testFuzzERC20PartialFillPayout(uint64 take) public {
        uint128 initial = 1000e18;
        vm.assume(take > 0 && take <= initial);

        uint256 aId = _listERC20(initial, 10 ether, 0, 1 hours);
        uint40 startT = uint40(block.timestamp);
        vm.warp(startT + 30 minutes); // price = 5 ETH

        uint256 expectedCost = (uint256(5 ether) * take + initial - 1) / initial;

        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        auction.fill{value: expectedCost}(aId, take);

        assertEq(tok.balanceOf(bob), take);
        assertEq(alice.balance, aliceBefore + expectedCost);
    }

    /*──────────────── gap coverage ────────────────*/

    function testFillNFTExplicitTakeEqualsBundleSize() public {
        nft.mint(alice, 1);
        nft.mint(alice, 2);
        nft.mint(alice, 3);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        uint256 aId = auction.listNFT(address(nft), ids, 3 ether, 0, 0, 1 hours);
        vm.stopPrank();

        vm.prank(bob);
        auction.fill{value: 3 ether}(aId, 3); // take == n explicitly
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.ownerOf(2), bob);
        assertEq(nft.ownerOf(3), bob);
    }

    function testFillNFTExactPriceNoRefund() public {
        uint256 aId = _listOneNFT(42, 10 ether, 0, 1 hours);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        auction.fill{value: 10 ether}(aId, 0);
        assertEq(bob.balance, bobBefore - 10 ether); // no refund path
    }

    function testFillERC20ExactCostNoRefund() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        auction.fill{value: 1 ether}(aId, 100e18); // ceil(10e18*100/1000) = 1 ether
        assertEq(bob.balance, bobBefore - 1 ether);
        assertEq(tok.balanceOf(bob), 100e18);
    }

    /// @dev Drain listing via multiple partial fills; final fill must delete the slot.
    function testFillERC20DrainsViaMultiplePartials() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);

        vm.prank(bob);
        auction.fill{value: 3 ether}(aId, 300e18);
        vm.prank(carol);
        auction.fill{value: 4 ether}(aId, 400e18);
        vm.prank(bob);
        auction.fill{value: 3 ether}(aId, 300e18); // exactly drains

        (address seller,,,,,,, uint128 remaining) = auction.auctions(aId);
        assertEq(seller, address(0)); // listing was deleted
        assertEq(remaining, 0);
        assertEq(tok.balanceOf(bob), 600e18);
        assertEq(tok.balanceOf(carol), 400e18);
        assertEq(tok.balanceOf(address(auction)), 0);
    }

    /// @dev After `duration` elapses with endPrice=0, ERC20 cost rounds to 0 — free drain.
    function testFillERC20FreeAfterDuration() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);
        vm.warp(block.timestamp + 2 hours); // past end
        assertEq(auction.priceOf(aId), 0);
        assertEq(auction.costOf(aId, 1000e18), 0);

        vm.prank(bob);
        auction.fill{value: 0}(aId, 1000e18);
        assertEq(tok.balanceOf(bob), 1000e18);
    }

    function testCancelNFTBundleReturnsAll() public {
        nft.mint(alice, 10);
        nft.mint(alice, 11);
        nft.mint(alice, 12);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 10;
        ids[1] = 11;
        ids[2] = 12;
        uint256 aId = auction.listNFT(address(nft), ids, 5 ether, 0, 0, 1 hours);
        auction.cancel(aId);
        vm.stopPrank();

        assertEq(nft.ownerOf(10), alice);
        assertEq(nft.ownerOf(11), alice);
        assertEq(nft.ownerOf(12), alice);
    }

    function testCancelERC20ReturnsExactRemainingAfterPartial() public {
        uint256 aId = _listERC20(1000e18, 10 ether, 0, 1 hours);

        vm.prank(bob);
        auction.fill{value: 2.5 ether}(aId, 250e18);

        uint256 aliceTokBefore = tok.balanceOf(alice);
        vm.prank(alice);
        auction.cancel(aId);
        assertEq(tok.balanceOf(alice) - aliceTokBefore, 750e18);
        assertEq(tok.balanceOf(address(auction)), 0);
    }

    /// @dev Duplicate id in the listing array: second transferFrom reverts (contract already owns it).
    function testListNFTRevertsDuplicateIds() public {
        nft.mint(alice, 5);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 5;
        ids[1] = 5;
        vm.expectRevert(); // MockERC721 "owner" require fires on second transfer
        auction.listNFT(address(nft), ids, 1 ether, 0, 0, 1 hours);
        vm.stopPrank();
    }

    /// @dev Full round-trip at the declared bundle cap.
    function testListNFTMaxBundleSize() public {
        uint256[] memory ids = new uint256[](100);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        for (uint256 i; i < 100; ++i) {
            nft.mint(alice, 1000 + i);
            ids[i] = 1000 + i;
        }
        uint256 aId = auction.listNFT(address(nft), ids, 50 ether, 0, 0, 1 hours);
        vm.stopPrank();

        vm.prank(bob);
        auction.fill{value: 50 ether}(aId, 0);
        for (uint256 i; i < 100; ++i) {
            assertEq(nft.ownerOf(1000 + i), bob);
        }
    }

    /// @dev startTime == block.timestamp is the boundary — must be accepted, not rejected.
    function testListStartTimeEqualToNowAccepted() public {
        vm.warp(10_000);
        uint256 aId = _listOneNFT(77, 1 ether, 0, 1 hours);
        assertEq(auction.priceOf(aId), 1 ether);
    }

    /// @dev Two independent listings don't interfere — each tracked and closed separately.
    function testMultipleListingsIsolated() public {
        uint256 a1 = _listOneNFT(100, 5 ether, 0, 1 hours);
        uint256 a2 = _listERC20(1000e18, 10 ether, 0, 1 hours);

        vm.prank(bob);
        auction.fill{value: 5 ether}(a1, 0);

        // a2 is untouched.
        (address s2,,,,,,, uint128 rem2) = auction.auctions(a2);
        assertEq(s2, alice);
        assertEq(rem2, 1000e18);
        assertEq(tok.balanceOf(address(auction)), 1000e18);
    }

    function testGetAuctionsStartBeyondNextIdReturnsEmpty() public view {
        DutchAuction.AuctionView[] memory v = auction.getAuctions(100, 200);
        assertEq(v.length, 0);
    }

    function testGetAuctionsEmptyRangeReturnsEmpty() public {
        _listOneNFT(1, 1 ether, 0, 1 hours);
        DutchAuction.AuctionView[] memory v = auction.getAuctions(1, 1);
        assertEq(v.length, 0);
    }

    function testIdsOfReturnsBundle() public {
        nft.mint(alice, 20);
        nft.mint(alice, 21);
        vm.startPrank(alice);
        nft.setApprovalForAll(address(auction), true);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 20;
        ids[1] = 21;
        uint256 aId = auction.listNFT(address(nft), ids, 1 ether, 0, 0, 1 hours);
        vm.stopPrank();

        uint256[] memory got = auction.idsOf(aId);
        assertEq(got.length, 2);
        assertEq(got[0], 20);
        assertEq(got[1], 21);
    }

    function testIdsOfClosedReturnsEmpty() public {
        uint256 aId = _listOneNFT(30, 1 ether, 0, 1 hours);
        vm.prank(alice);
        auction.cancel(aId);
        uint256[] memory got = auction.idsOf(aId);
        assertEq(got.length, 0);
    }

    /// @dev Fuzz N sequential partial fills that sum to exactly `initial`; listing must close
    ///      and token accounting must balance.
    function testFuzzSequentialPartialsDrainAndClose(uint8 takes) public {
        uint8 n = uint8(bound(uint256(takes), 2, 20));
        uint128 initial = 1_000_000e18;
        uint256 aId = _listERC20(initial, 100 ether, 0, 1 hours);

        uint256 chunk = initial / n;
        uint256 totalTaken;
        for (uint256 i; i < n - 1; ++i) {
            uint256 cost = auction.costOf(aId, uint128(chunk));
            vm.deal(bob, cost);
            vm.prank(bob);
            auction.fill{value: cost}(aId, uint128(chunk));
            totalTaken += chunk;
        }
        // Final fill takes the exact remainder.
        uint128 remainder = uint128(initial - totalTaken);
        uint256 finalCost = auction.costOf(aId, remainder);
        vm.deal(bob, finalCost);
        vm.prank(bob);
        auction.fill{value: finalCost}(aId, remainder);

        (address seller,,,,,,, uint128 rem) = auction.auctions(aId);
        assertEq(seller, address(0));
        assertEq(rem, 0);
        assertEq(tok.balanceOf(address(auction)), 0);
        assertEq(tok.balanceOf(bob), initial);
    }
}
