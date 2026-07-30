// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20, MockWETH, MockNFT, OverburnWETH} from "./SwapboardMocks.sol";

contract ShortPayWETH is MockERC20("SHORT_WETH", 18) {
    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount - 1);
    }
}

contract DutchUnwrapObserver {
    Dutchboard immutable board;
    address immutable weth;
    uint256 public id;
    bool public sawDeleted;

    constructor(Dutchboard board_, address weth_) {
        board = board_;
        weth = weth_;
    }

    function list(address quote, uint128 amount) external {
        (bool ok,) = weth.call(abi.encodeWithSignature("approve(address,uint256)", address(board), amount));
        require(ok, "approve");
        id = board.listERC20(weth, quote, amount, 1, 0, 0, 1 hours);
    }

    function cancel() external {
        board.cancelUnwrap(id);
    }

    receive() external payable {
        sawDeleted = board.getListing(id).seller == address(0);
    }
}

contract DutchboardCancelUnwrapTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    Dutchboard board;
    MockWETH weth;
    MockERC20 quote;
    MockERC20 other;

    address maker = address(0xA11CE);
    address victim = address(0xBEEF);
    address attacker = address(0xBAD);

    function setUp() public {
        MockWETH implementation = new MockWETH();
        vm.etch(WETH, address(implementation).code);
        vm.deal(WETH, 1_000 ether);
        weth = MockWETH(payable(WETH));

        board = new Dutchboard();
        // These tests assert the board holds no stray ETH. Forked tests deploy
        // to deterministic CREATE addresses, and this one (0x2e23...470b, the
        // second contract a forge test deploys) holds 1 wei on mainnet at the
        // pinned block. A new contract inherits any balance already at its
        // address, so without this the board starts 1 wei short of empty.
        vm.deal(address(board), 0);
        quote = new MockERC20("QUOTE", 18);
        other = new MockERC20("OTHER", 18);
        vm.deal(maker, 10 ether);
    }

    function _listWeth(address seller, uint128 amount) internal returns (uint256 id) {
        weth.mint(seller, amount);
        vm.startPrank(seller);
        weth.approve(address(board), amount);
        id = board.listERC20(WETH, address(quote), amount, 1, 0, 0, 1 hours);
        vm.stopPrank();
    }

    function test_cancelUnwrapReturnsExactEthAndClosesListing() public {
        uint256 id = _listWeth(maker, 4 ether);
        uint256 before = maker.balance;

        vm.prank(maker);
        board.cancelUnwrap(id);

        assertEq(maker.balance - before, 4 ether);
        assertEq(weth.balanceOf(address(board)), 0);
        assertEq(address(board).balance, 0);
        assertEq(board.getListing(id).seller, address(0));
    }

    function test_cancelUnwrapDeletesBeforeExternalSellerCall() public {
        DutchUnwrapObserver observer = new DutchUnwrapObserver(board, WETH);
        weth.mint(address(observer), 2 ether);
        observer.list(address(quote), 2 ether);

        observer.cancel();

        assertTrue(observer.sawDeleted(), "seller callback saw a live listing");
        assertEq(address(observer).balance, 2 ether);
    }

    function test_cancelUnwrapRejectsNonSeller() public {
        uint256 id = _listWeth(maker, 1 ether);

        vm.prank(attacker);
        vm.expectRevert(Dutchboard.NotSeller.selector);
        board.cancelUnwrap(id);

        assertEq(board.getListing(id).seller, maker);
        assertEq(weth.balanceOf(address(board)), 1 ether);
    }

    function test_cancelUnwrapRejectsNonWethToken() public {
        other.mint(maker, 2 ether);
        vm.startPrank(maker);
        other.approve(address(board), 2 ether);
        uint256 id = board.listERC20(address(other), address(quote), 2 ether, 1, 0, 0, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(Dutchboard.NotWETH.selector, WETH, address(other)));
        board.cancelUnwrap(id);
        vm.stopPrank();

        assertEq(board.getListing(id).seller, maker);
        assertEq(other.balanceOf(address(board)), 2 ether);
    }

    function test_cancelUnwrapRejectsNftListing() public {
        MockNFT nft = new MockNFT();
        nft.mint(maker, 7);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;

        vm.startPrank(maker);
        nft.setApprovalForAll(address(board), true);
        uint256 id = board.listNFT(address(nft), address(quote), ids, 1, 0, 0, 1 hours);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.cancelUnwrap(id);
        vm.stopPrank();

        assertEq(board.getListing(id).seller, maker);
        assertEq(nft.ownerOf(7), address(board));
    }

    function test_receiveAcceptsOnlyCanonicalWeth() public {
        vm.deal(attacker, 2);
        vm.prank(attacker);
        (bool attackerOk,) = payable(address(board)).call{value: 1}("");
        assertFalse(attackerOk);
        assertEq(address(board).balance, 0);

        vm.prank(WETH);
        (bool wethOk,) = payable(address(board)).call{value: 1}("");
        assertTrue(wethOk);
        assertEq(address(board).balance, 1);
    }

    function test_forcedEthIsIsolatedFromSuccessfulUnwrap() public {
        uint256 id = _listWeth(maker, 3 ether);
        vm.deal(address(board), 5 ether);
        uint256 before = maker.balance;

        vm.prank(maker);
        board.cancelUnwrap(id);

        assertEq(maker.balance - before, 3 ether);
        assertEq(address(board).balance, 5 ether, "forced balance was swept");
    }

    function test_forcedEthCannotSubsidizeShortUnwrap() public {
        uint256 id = _listWeth(maker, 3 ether);
        vm.deal(address(board), 5 ether);
        ShortPayWETH shortImplementation = new ShortPayWETH();
        vm.etch(WETH, address(shortImplementation).code);

        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(
                Dutchboard.BalanceDeltaMismatch.selector, address(0), address(board), 3 ether, 3 ether - 1
            )
        );
        board.cancelUnwrap(id);

        assertEq(board.getListing(id).seller, maker, "failed unwrap discarded listing");
        assertEq(weth.balanceOf(address(board)), 3 ether, "failed unwrap changed escrow");
        assertEq(address(board).balance, 5 ether, "forced ETH changed");
    }

    function test_overburnCannotConsumeAnotherListingsEscrow() public {
        uint256 id = _listWeth(maker, 3 ether);
        uint256 victimId = _listWeth(victim, 1 ether);
        OverburnWETH overburnImplementation = new OverburnWETH();
        vm.etch(WETH, address(overburnImplementation).code);

        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(Dutchboard.BalanceDeltaMismatch.selector, WETH, address(board), 3 ether, 3 ether + 1)
        );
        board.cancelUnwrap(id);

        assertEq(board.getListing(id).seller, maker);
        assertEq(board.getListing(victimId).seller, victim);
        assertEq(weth.balanceOf(address(board)), 4 ether);
    }
}
