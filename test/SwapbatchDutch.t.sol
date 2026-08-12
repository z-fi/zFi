// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapbatch} from "../src/forwarders/Swapbatch.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @notice `fillDutchWithEth`: the one Dutchboard shape a taker holding ether
///         cannot reach on their own.
///
///         Dutchboard batches ETH natively and needs no help doing it -
///         `fillMany` is payable, threads `msg.value` across the legs and
///         refunds the remainder. That is true only of NATIVE-quoted lots.
///
///         A lot quoted in WETH is a different animal. `fill` reverts `Bad()` if
///         any ETH is attached to an ERC20-quoted listing, and `_settle` pays it
///         with `_payQuoteToken(quote, msg.sender, ...)` - pulling the quote
///         asset from the caller, never looking at `msg.value`. So ether alone
///         cannot buy one: not in a batch, not one at a time. Wrapping first is
///         the entire job, and this is where that is checked.
contract SwapbatchDutchTest is Test {
    MockWETH weth;
    MockERC20 lot;
    MockERC20 other;
    Swapbatch batch;
    MockDutchboard dutch;

    address taker = makeAddr("taker");
    address third = makeAddr("third");
    address seller = makeAddr("seller");

    function setUp() public {
        weth = new MockWETH();
        lot = new MockERC20("LOT", 18);
        other = new MockERC20("OTH", 18);
        dutch = new MockDutchboard(address(weth), lot);
        // legacy and modern are irrelevant here; they only have to be distinct
        // contracts with code.
        batch = new Swapbatch(address(weth), address(new Dummy()), address(new Dummy()), address(dutch));
        vm.deal(taker, 100 ether);
        vm.deal(address(batch), 0);
        lot.mint(address(dutch), 1_000e18);
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory o) {
        o = new uint256[](2);
        (o[0], o[1]) = (a, b);
    }

    function _takes(uint128 a, uint128 b) internal pure returns (uint128[] memory o) {
        o = new uint128[](2);
        (o[0], o[1]) = (a, b);
    }

    function _costs(uint256 a, uint256 b) internal pure returns (uint256[] memory o) {
        o = new uint256[](2);
        (o[0], o[1]) = (a, b);
    }

    function _clean() internal view {
        assertEq(address(batch).balance, 0, "helper holds ETH");
        assertEq(weth.balanceOf(address(batch)), 0, "helper holds WETH");
        assertEq(lot.balanceOf(address(batch)), 0, "helper holds the lot");
        assertEq(weth.allowance(address(batch), address(dutch)), 0, "helper left an approval");
    }

    // ------------------------------------------------------------- THE POINT

    /// Two WETH-quoted lots, one transaction, paid entirely in ether.
    function test_fillsWethQuotedLotsPayingEther() public {
        dutch.list(1, address(weth), 1 ether);
        dutch.list(2, address(weth), 2 ether);

        uint256 before = taker.balance;
        vm.prank(taker);
        bool[] memory filled = batch.fillDutchWithEth{value: 3 ether}(
            _ids(1, 2), _takes(10e18, 20e18), _costs(1 ether, 2 ether), taker, false
        );

        assertTrue(filled[0] && filled[1], "both legs reported filled");
        assertEq(lot.balanceOf(taker), 30e18, "both lots delivered straight to the taker");
        assertEq(weth.balanceOf(seller), 0, "no stray payout");
        assertEq(before - taker.balance, 3 ether, "charged exactly the sum of the bounds");
        _clean();
    }

    /// The board takes a recipient, so unlike the legacy path there is no sweep -
    /// the lot never passes through this contract at all.
    function test_deliversStraightToTheRecipient() public {
        dutch.list(1, address(weth), 1 ether);

        vm.prank(taker);
        batch.fillDutchWithEth{value: 5 ether}(
            _one(1), _oneTake(10e18), _oneCost(1 ether), third, false
        );

        assertEq(lot.balanceOf(third), 10e18, "lot went to the recipient");
        assertEq(lot.balanceOf(taker), 0, "payer received no lot");
        assertEq(third.balance, 4 ether, "refund followed the recipient");
        _clean();
    }

    /// A decaying lot costs whatever it costs when the block lands, so the BOUND
    /// is what gets wrapped and the difference has to come back as ether - not
    /// sit in the helper as WETH for the next caller to find.
    function test_refundsTheUnspentBoundAsEther() public {
        dutch.list(1, address(weth), 1 ether);
        dutch.setActualCost(1, 0.4 ether); // decayed well below the bound

        uint256 before = taker.balance;
        vm.prank(taker);
        batch.fillDutchWithEth{value: 1 ether}(_one(1), _oneTake(10e18), _oneCost(1 ether), taker, false);

        assertEq(before - taker.balance, 0.4 ether, "charged the decayed price, not the bound");
        assertEq(weth.balanceOf(taker), 0, "refund arrived as ether, not WETH");
        _clean();
    }

    /// A NATIVE-quoted lot must be refused here rather than wrapped. Dutchboard
    /// settles those out of `msg.value`, which this path does not forward - so
    /// the wrap would be ether the board never spends, and the failure would
    /// surface as an opaque revert from inside the board.
    function test_refusesNativeQuotedLotsBeforeWrappingAnything() public {
        dutch.list(1, address(0), 1 ether);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapbatch.NotWethQuoted.selector, 0, address(0)));
        batch.fillDutchWithEth{value: 1 ether}(_one(1), _oneTake(10e18), _oneCost(1 ether), taker, false);
        assertEq(taker.balance, 100 ether, "nothing was spent");
    }

    /// And any other ERC20 quote, for the same reason from the other side: the
    /// board would pull an asset this contract does not hold.
    function test_refusesAnyOtherErc20Quote() public {
        dutch.list(1, address(other), 1 ether);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapbatch.NotWethQuoted.selector, 0, address(other)));
        batch.fillDutchWithEth{value: 1 ether}(_one(1), _oneTake(10e18), _oneCost(1 ether), taker, false);
    }

    /// The bad leg is named by INDEX, so a caller batching twenty can find it.
    function test_namesTheOffendingLegByIndex() public {
        dutch.list(1, address(weth), 1 ether);
        dutch.list(2, address(0), 1 ether);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapbatch.NotWethQuoted.selector, 1, address(0)));
        batch.fillDutchWithEth{value: 2 ether}(
            _ids(1, 2), _takes(10e18, 10e18), _costs(1 ether, 1 ether), taker, false
        );
    }

    /// msg.value is counted once against the sum of the bounds.
    function test_underpaymentReverts() public {
        dutch.list(1, address(weth), 1 ether);
        dutch.list(2, address(weth), 2 ether);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapbatch.InsufficientValue.selector, 3 ether, 3 ether - 1));
        batch.fillDutchWithEth{value: 3 ether - 1}(
            _ids(1, 2), _takes(10e18, 20e18), _costs(1 ether, 2 ether), taker, false
        );
    }

    /// A stale leg's share of the wrapped input comes back as ether.
    function test_skipsStaleLegsAndRefundsTheirShare() public {
        dutch.list(1, address(weth), 1 ether);
        dutch.list(2, address(weth), 2 ether);
        dutch.close(2);

        uint256 before = taker.balance;
        vm.prank(taker);
        bool[] memory filled = batch.fillDutchWithEth{value: 3 ether}(
            _ids(1, 2), _takes(10e18, 20e18), _costs(1 ether, 2 ether), taker, true
        );

        assertTrue(filled[0], "live leg filled");
        assertFalse(filled[1], "closed leg skipped");
        assertEq(before - taker.balance, 1 ether, "only the filled leg was paid for");
        assertEq(lot.balanceOf(taker), 10e18, "only the live lot delivered");
        _clean();
    }

    /// The atomic path aborts rather than partially settling.
    function test_atomicPathRevertsOnAStaleLeg() public {
        dutch.list(1, address(weth), 1 ether);
        dutch.list(2, address(weth), 2 ether);
        dutch.close(2);

        vm.prank(taker);
        vm.expectRevert();
        batch.fillDutchWithEth{value: 3 ether}(
            _ids(1, 2), _takes(10e18, 20e18), _costs(1 ether, 2 ether), taker, false
        );
        assertEq(taker.balance, 100 ether, "value returned");
        assertEq(lot.balanceOf(taker), 0, "nothing settled");
    }

    /// Neither the helper nor WETH may be the destination: the first strands the
    /// lot, the second is the wrapper trust root rather than a user address.
    function test_refusesDegenerateRecipients() public {
        dutch.list(1, address(weth), 1 ether);

        vm.startPrank(taker);
        vm.expectRevert(Swapbatch.BadRecipient.selector);
        batch.fillDutchWithEth{value: 1 ether}(_one(1), _oneTake(10e18), _oneCost(1 ether), address(batch), false);

        vm.expectRevert(Swapbatch.BadRecipient.selector);
        batch.fillDutchWithEth{value: 1 ether}(_one(1), _oneTake(10e18), _oneCost(1 ether), address(weth), false);
        vm.stopPrank();
    }

    /// An unbound Dutchboard is not reachable by naming one.
    function test_pathIsClosedWhenNoDutchboardIsBound() public {
        Swapbatch nod = new Swapbatch(address(weth), address(new Dummy()), address(new Dummy()), address(0));
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(Swapbatch.UnknownBoard.selector, address(0)));
        nod.fillDutchWithEth{value: 1 ether}(_one(1), _oneTake(10e18), _oneCost(1 ether), taker, false);
    }

    // ---------------------------------------------------------------- helpers

    function _one(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1);
        o[0] = a;
    }

    function _oneTake(uint128 a) internal pure returns (uint128[] memory o) {
        o = new uint128[](1);
        o[0] = a;
    }

    function _oneCost(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1);
        o[0] = a;
    }
}

contract Dummy {}

/// @dev Dutchboard's shape as `fillDutchWithEth` addresses it. `listings` is the
///      auto-generated mapping getter, which omits the struct's trailing dynamic
///      `ids` array - eleven values, not twelve.
contract MockDutchboard {
    address public immutable weth;
    MockERC20 public immutable lot;

    struct L {
        address quote;
        uint256 price;
        uint256 actual;
        bool closed;
        bool exists;
    }

    mapping(uint256 => L) internal _l;

    constructor(address _weth, MockERC20 _lot) {
        weth = _weth;
        lot = _lot;
    }

    function list(uint256 id, address quote, uint256 price) external {
        _l[id] = L(quote, price, price, false, true);
    }

    function setActualCost(uint256 id, uint256 cost) external {
        _l[id].actual = cost;
    }

    function close(uint256 id) external {
        _l[id].closed = true;
    }

    function listings(uint256 id)
        external
        view
        returns (
            address seller,
            bool isNFT,
            uint40 startTime,
            uint40 duration,
            address token,
            uint96 startPrice,
            address quote,
            uint96 endPrice,
            uint128 initial,
            uint128 remaining,
            uint40 expiry
        )
    {
        L memory x = _l[id];
        return (
            x.exists ? address(1) : address(0),
            false,
            0,
            0,
            address(lot),
            uint96(x.price),
            x.quote,
            uint96(x.price),
            0,
            0,
            0
        );
    }

    function _settle(uint256 id, uint128 take, address to) internal returns (uint256) {
        L memory x = _l[id];
        require(x.exists && !x.closed, "closed");
        // The behaviour that matters: the quote asset is PULLED from the caller,
        // and msg.value is never consulted.
        IERC20(weth).transferFrom(msg.sender, address(this), x.actual);
        lot.transfer(to, take);
        return x.actual;
    }

    function fillMany(uint256[] calldata ids, uint128[] calldata takes, uint256[] calldata, address to)
        external
        payable
        returns (uint256 spent)
    {
        for (uint256 i; i < ids.length; ++i) {
            spent += _settle(ids[i], takes[i], to);
        }
    }

    function tryFillMany(uint256[] calldata ids, uint128[] calldata takes, uint256[] calldata, address to)
        external
        payable
        returns (bool[] memory filled, uint256 spent)
    {
        filled = new bool[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            L memory x = _l[ids[i]];
            if (!x.exists || x.closed) continue;
            spent += _settle(ids[i], takes[i], to);
            filled[i] = true;
        }
    }
}

interface IERC20 {
    function transferFrom(address, address, uint256) external returns (bool);
}
